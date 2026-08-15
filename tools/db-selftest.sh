#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/db-selftest.sh — prove the backup/restore path works, before you need it.
#
# Two levels:
#   default    read-only preflight. Checks every prerequisite the other scripts
#              depend on and reports what would fail. Safe anywhere, any time.
#   --full     the only check that actually means anything: take a real backup,
#              restore it into a THROWAWAY database on the same server, and
#              compare table counts. Never touches the live database.
#
# An untested backup is a hypothesis. --full is what turns it into a fact, and
# it is cheap enough to run monthly.
#
# Usage:
#   ./tools/db-selftest.sh                     # preflight, local
#   ./tools/db-selftest.sh --target prod       # preflight against prod (read-only)
#   ./tools/db-selftest.sh --full              # round-trip into ${BACKUP_PREFIX}_selftest
#
# Flags:
#   -t, --target local|prod|test   (default: local)
#       --full                     Do the real backup+restore round trip
#       --keep                     Leave the scratch database behind
#   -h, --help
#
# Exit: 0 all good · 1 something is wrong
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TARGET_ARG="local"; FULL=0; KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target) TARGET_ARG="$2"; shift 2 ;;
    --full)      FULL=1; shift ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

FAILED=0
check() {  # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$desc"
  else
    printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$desc"
    FAILED=1; return 1
  fi
}
note() { printf '  %s·%s %s\n' "$C_DIM" "$C_OFF" "$*"; }

hdr "$PROJECT_NAME backup self-test · target=$TARGET_ARG"

# ── 1. Host tooling ────────────────────────────────────────────────────────
hdr "1. Host prerequisites"
check "sha256sum present"  command -v sha256sum
check "docker reachable"   bash -c 'docker ps >/dev/null 2>&1 || sudo -n docker ps >/dev/null 2>&1'
[[ "$TARGET_ARG" != local ]] && check "ssh present" command -v ssh
check "crontab present"    command -v crontab

# ── 2. Target reachable ────────────────────────────────────────────────────
hdr "2. Target"
if resolve_target "$TARGET_ARG" 2>/dev/null; then
  printf '  %s✓%s target resolves (%s)\n' "$C_GREEN" "$C_OFF" \
    "$([[ "$TGT_KIND" == container ]] && echo "container ${TGT_CONTAINER:0:12}" || echo "ssh $TGT_SSH")"
else
  printf '  %s✗%s target does not resolve — is the stack up?\n' "$C_RED" "$C_OFF"
  exit 1
fi

if assert_target_reachable 2>/dev/null; then
  printf '  %s✓%s postgres accepting connections\n' "$C_GREEN" "$C_OFF"
else
  printf '  %s✗%s cannot reach postgres on target "%s"\n' "$C_RED" "$C_OFF" "$TARGET_ARG"
  assert_target_reachable || true
  exit 1
fi

SRV_VER="$(tgt_server_version)"
note "server   PostgreSQL $SRV_VER"
note "database $DB_NAME as $DB_USER"
if tgt_db_exists; then
  note "contents $(tgt_table_count) tables, $(tgt_db_size)"
else
  printf '  %s✗%s database "%s" does not exist\n' "$C_RED" "$C_OFF" "$DB_NAME"; FAILED=1
fi

# ── 3. pg tooling on the target ────────────────────────────────────────────
hdr "3. Postgres tooling on the target"
on_target() { tgt_exec "$1"; }   # named wrapper so check()'s output reads well
check "pg_dump available"    on_target "pg_dump --version"
check "pg_restore available" on_target "pg_restore --version"
check "gzip available"       on_target "gzip --version"

# The client on THIS box is only used for reading dumps locally, but a client
# older than the server is the exact trap tools/db-refresh-test-server.sh documents.
if command -v pg_restore >/dev/null 2>&1; then
  LOCAL_PG="$(pg_restore --version | grep -oE '[0-9]+' | head -1)"
  SRV_MAJ="${SRV_VER%%.*}"
  if [[ "$LOCAL_PG" -lt "$SRV_MAJ" ]]; then
    note "local pg_restore is $LOCAL_PG, target server is $SRV_MAJ — fine, because every dump/restore runs ON the target"
  fi
fi

# ── 4. Backup storage ──────────────────────────────────────────────────────
hdr "4. Backup storage"
DEST="$(backup_dir_for "$TARGET_ARG")"
mkdir -p "$DEST"
check "backup dir writable" test -w "$DEST"
FREE_GB=$(( $(df -Pk "$DEST" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
if [[ "$FREE_GB" -lt 5 ]]; then
  printf '  %s✗%s only %sGB free at %s\n' "$C_RED" "$C_OFF" "$FREE_GB" "$DEST"; FAILED=1
else
  printf '  %s✓%s %sGB free at %s\n' "$C_GREEN" "$C_OFF" "$FREE_GB" "$DEST"
fi
if grep -qE '^/?backups/?$' "$REPO_DIR/.gitignore" 2>/dev/null; then
  printf '  %s✓%s backups/ is gitignored\n' "$C_GREEN" "$C_OFF"
else
  printf '  %s✗%s backups/ is NOT in .gitignore — database dumps would be committed\n' "$C_RED" "$C_OFF"; FAILED=1
fi

# ── 5. Scripts executable ──────────────────────────────────────────────────
hdr "5. Toolset"
for s in db-backup.sh db-restore.sh db-backup-monitor.sh db-backup-cron.sh \
         db-refresh-local.sh db-refresh-test-server.sh deploy.sh pg-upgrade.sh sync-django.sh; do
  check "$s executable" test -x "$TOOLS_DIR/$s"
done
# The moved-in scripts resolve the repo root as ../ from tools/. If someone
# relocates them again, this is the check that notices before a 3am restore does.
check "scripts resolve the repo root" test -f "$REPO_DIR/$(basename "$COMPOSE_LOCAL")"

# ── 6. The real test ───────────────────────────────────────────────────────
if [[ "$FULL" -eq 1 ]]; then
  hdr "6. Round trip (backup -> restore into a scratch database)"
  [[ "$FAILED" -eq 0 ]] || die "preflight failed — fix the above before running --full"

  SCRATCH="${DB_NAME}_selftest"
  log "Taking a backup labelled 'selftest'"
  "$TOOLS_DIR/db-backup.sh" --target "$TARGET_ARG" --label selftest --no-prune \
    || die "backup step failed"

  ARCHIVE="$(ls -1t "$DEST"/"${BACKUP_PREFIX}"_"${TARGET_ARG}"_selftest_*.dump | head -1)"
  SRC_TABLES="$(tgt_table_count)"

  log "Restoring into scratch database '$SCRATCH' (the live database is untouched)"
  REMOTE_TMP="/tmp/${BACKUP_PREFIX}_selftest_$$.dump"
  tgt_stream_in "$REMOTE_TMP" < "$ARCHIVE"

  tgt_psql_maint "DROP DATABASE IF EXISTS \"${SCRATCH}\" WITH (FORCE);" >/dev/null
  tgt_psql_maint "CREATE DATABASE \"${SCRATCH}\" OWNER \"${DB_USER}\";"  >/dev/null

  set +e
  tgt_exec "pg_restore -U $(printf '%q' "$DB_USER") -d $(printf '%q' "$SCRATCH") \
              --no-owner --no-privileges -j 4 ${REMOTE_TMP}" >/tmp/${BACKUP_PREFIX}_selftest_restore.$$ 2>&1
  RC=$?
  set -e
  tgt_exec "rm -f ${REMOTE_TMP}" >/dev/null 2>&1 || true

  RESTORED="$(trim "$(tgt_exec "psql -U $(printf '%q' "$DB_USER") -d $(printf '%q' "$SCRATCH") -tAc 'select count(*) from pg_stat_user_tables'" 2>/dev/null || echo 0)")"

  if [[ "$KEEP" -eq 0 ]]; then
    tgt_psql_maint "DROP DATABASE IF EXISTS \"${SCRATCH}\" WITH (FORCE);" >/dev/null
    note "scratch database dropped"
  else
    note "scratch database '$SCRATCH' left in place (--keep)"
  fi

  echo
  printf '  live database : %s tables\n' "$SRC_TABLES"
  printf '  restored copy : %s tables\n' "$RESTORED"
  if [[ "$RESTORED" == "$SRC_TABLES" && "$RESTORED" -gt 0 ]]; then
    ok "ROUND TRIP PASSED — this backup can actually be restored"
  else
    printf '  %s✗%s round trip FAILED (rc=%s)\n' "$C_RED" "$C_OFF" "$RC"
    head -20 "/tmp/${BACKUP_PREFIX}_selftest_restore.$$" >&2
    FAILED=1
  fi
  rm -f "/tmp/${BACKUP_PREFIX}_selftest_restore.$$"
else
  hdr "6. Round trip"
  note "skipped — re-run with --full to actually prove a backup restores"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then ok "self-test passed"; exit 0
else warn "self-test FAILED — see the ✗ lines above"; exit 1; fi
