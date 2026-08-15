#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/db-restore.sh — restore the database from a tools/db-backup.sh
# archive.
#
# The dangerous half of the toolset, so it is deliberately noisy:
#   1. it takes a SAFETY DUMP of whatever is currently in the database first —
#      a restore is itself a destructive write, and the state you are about to
#      overwrite is not in any backup unless you make one;
#   2. it verifies the archive before dropping anything;
#   3. it stops the app containers so nothing can reconnect and write into a
#      half-restored schema — a web worker that reconnects mid-restore inserts
#      against tables pg_restore has not finished creating;
#   4. it restarts exactly the services that were running, and no others.
#
# Usage:
#   ./tools/db-restore.sh list                              # what's available
#   ./tools/db-restore.sh latest                            # newest for target
#   ./tools/db-restore.sh full  app_local_manual_....dump
#   ./tools/db-restore.sh sql   app_local_manual_....sql.gz
#   ./tools/db-restore.sh full  /abs/path/to.dump --target test
#
# A bare filename is looked up in backups/<target>/; a path is used as given.
#
# Flags:
#   -t, --target local|prod|test   Which database         (default: local)
#   -j, --jobs N                   Parallel restore jobs  (default: 4)
#   -y, --yes                      Skip confirmations (scripted use)
#       --no-safety-dump           Don't dump the current db first  (don't)
#       --no-restart               Leave app containers alone
#       --no-verify                Skip the post-restore comparison
#   -h, --help
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

CMD="${1:-}"; shift || true
TARGET_ARG="local"; JOBS=4; ASSUME_YES=0
SAFETY=1; RESTART=1; VERIFY=1; ARCHIVE=""

# The first positional after the command is the archive, if it isn't a flag.
if [[ -n "${1:-}" && "${1:0:1}" != "-" ]]; then ARCHIVE="$1"; shift; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)       TARGET_ARG="$2"; shift 2 ;;
    -j|--jobs)         JOBS="$2"; shift 2 ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    --no-safety-dump)  SAFETY=0; shift ;;
    --no-restart)      RESTART=0; shift ;;
    --no-verify)       VERIFY=0; shift ;;
    -h|--help)         sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$CMD" in
  list|latest|full|sql) ;;
  ""|-h|--help) sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown command '$CMD' (expected: list | latest | full | sql)" ;;
esac

resolve_target "$TARGET_ARG"
DEST="$(backup_dir_for "$TARGET")"

# ── list ───────────────────────────────────────────────────────────────────
if [[ "$CMD" == list ]]; then
  exec "$TOOLS_DIR/db-backup.sh" --target "$TARGET" --list
fi

# ── resolve the archive ────────────────────────────────────────────────────
if [[ "$CMD" == latest ]]; then
  ARCHIVE="$(latest_backup "$TARGET")"
  [[ -n "$ARCHIVE" ]] || die "no backups found in $DEST — run ./tools/db-backup.sh --target $TARGET"
  CMD=full
fi
[[ -n "$ARCHIVE" ]] || die "no archive given. Try: ./tools/db-restore.sh list --target $TARGET"
[[ -f "$ARCHIVE" ]] || ARCHIVE="$DEST/$ARCHIVE"
[[ -f "$ARCHIVE" ]] || die "archive not found: $ARCHIVE"
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"

hdr "$PROJECT_NAME restore · target=$TARGET · $(basename "$ARCHIVE")"
assert_target_reachable

# ── Show what is about to be lost, and what replaces it ────────────────────
if tgt_db_exists; then
  CUR_SIZE="$(tgt_db_size)"; CUR_TABLES="$(tgt_table_count)"
else
  CUR_SIZE="(absent)"; CUR_TABLES=0
fi
SRV_VER="$(tgt_server_version)"

META="${ARCHIVE}.meta"
if [[ -f "$META" ]]; then
  A_TAKEN="$(grep -m1 '^taken=' "$META" | cut -d= -f2- || true)"
  A_VER="$(grep -m1 '^server_version=' "$META" | cut -d= -f2- || true)"
  A_SIZE="$(grep -m1 '^source_size=' "$META" | cut -d= -f2- || true)"
  A_TABLES="$(grep -m1 '^source_tables=' "$META" | cut -d= -f2- || true)"
  A_SUM="$(grep -m1 '^sha256=' "$META" | cut -d= -f2- || true)"
  A_COMMIT="$(grep -m1 '^repo_commit=' "$META" | cut -d= -f2- || true)"
else
  A_TAKEN="unknown"; A_VER="unknown"; A_SIZE="unknown"; A_TABLES="?"; A_SUM=""; A_COMMIT="unknown"
fi

printf '  %-14s %s\n' "current db:"  "${CUR_TABLES} tables, ${CUR_SIZE}  (PostgreSQL ${SRV_VER})"
printf '  %-14s %s\n' "archive:"     "${A_TABLES} tables, ${A_SIZE}  (written by PostgreSQL ${A_VER})"
printf '  %-14s %s\n' "taken:"       "${A_TAKEN}"
printf '  %-14s %s\n' "repo commit:" "${A_COMMIT}"

# ── Integrity: does the file still match what we wrote? ────────────────────
if [[ -n "$A_SUM" ]]; then
  log "Checking archive checksum"
  NOW_SUM="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
  [[ "$NOW_SUM" == "$A_SUM" ]] || die "archive checksum does not match its .meta — the file changed on disk. Refusing to restore."
  ok "sha256 matches the recorded value"
fi

# A dump written by a NEWER server than the one we're restoring into will fail
# partway through, after the drop. Catch it while everything is still intact.
maj() { printf '%s' "${1%%.*}"; }
if [[ "$A_VER" != "unknown" && -n "$SRV_VER" ]]; then
  if (( $(maj "$A_VER") > $(maj "$SRV_VER") )); then
    warn "archive is from PostgreSQL $(maj "$A_VER") but the target runs $(maj "$SRV_VER") — downgrade restores routinely fail"
    confirm "Continue anyway?" || die "aborted"
  fi
fi

echo
printf '%s⚠  This DROPS and replaces database "%s" on target "%s".%s\n' "$C_YELLOW" "$DB_NAME" "$TARGET" "$C_OFF"
[[ "$TARGET" == prod ]] && printf '%s⚠  THIS IS PRODUCTION.%s\n' "$C_RED" "$C_OFF"
confirm "Proceed?" || die "aborted"

# ── 1. Safety dump ─────────────────────────────────────────────────────────
if [[ "$SAFETY" -eq 1 ]] && tgt_db_exists; then
  log "Safety dump of the CURRENT database first"
  "$TOOLS_DIR/db-backup.sh" --target "$TARGET" --label safety --quick --no-prune \
    || die "safety dump failed — refusing to restore over a database we can't get back"
else
  [[ "$SAFETY" -eq 1 ]] || warn "safety dump skipped (--no-safety-dump)"
fi

# ── 2. Stop the writers ────────────────────────────────────────────────────
# Every service in APP_SERVICES_* writes this database, so a reconnect
# mid-restore can interleave its own writes with pg_restore's.
STOPPED=()
if [[ "$RESTART" -eq 1 ]]; then
  log "Stopping app services"
  mapfile -t STOPPED < <(tgt_app_stop_running)
  # tgt_app_stop_running emits an empty line when nothing was running.
  STOPPED=("${STOPPED[@]/#/}"); readarray -t STOPPED < <(printf '%s\n' "${STOPPED[@]}" | grep -v '^$' || true)
  if [[ ${#STOPPED[@]} -gt 0 ]]; then info "stopped: ${STOPPED[*]}"; else info "nothing was running"; fi
fi

restart_apps() {
  if [[ "$RESTART" -eq 1 && ${#STOPPED[@]} -gt 0 ]]; then
    log "Restarting: ${STOPPED[*]}"
    tgt_app_start "${STOPPED[@]}"
  fi
}
# Whatever happens below, the app comes back up. A failed restore that also
# leaves the stack down turns a recoverable problem into an outage.
trap restart_apps EXIT

# ── 3. Push the archive to the target ──────────────────────────────────────
REMOTE_TMP="/tmp/${BACKUP_PREFIX}_restore_$$.$(basename "${ARCHIVE##*.}")"
log "Uploading archive to the target"
tgt_stream_in "$REMOTE_TMP" < "$ARCHIVE" || die "could not copy the archive to the target"
cleanup_remote() { tgt_exec "rm -f ${REMOTE_TMP}" >/dev/null 2>&1 || true; }

RBYTES="$(trim "$(tgt_exec "stat -c %s ${REMOTE_TMP}" || echo 0)")"
LBYTES="$(stat -c %s "$ARCHIVE")"
[[ "$RBYTES" == "$LBYTES" ]] || { cleanup_remote; die "upload truncated (${RBYTES}B of ${LBYTES}B)"; }

if [[ "$CMD" == full ]]; then
  tgt_exec "pg_restore --list ${REMOTE_TMP} > /dev/null" \
    || { cleanup_remote; die "the target cannot read this archive — nothing was dropped"; }
  ok "archive verified on the target"
fi

# ── 4. Drop / recreate ─────────────────────────────────────────────────────
log "Recreating database '$DB_NAME'"
# Terminate stragglers first: a single idle psql session is enough to make
# DROP DATABASE hang forever.
tgt_exec "psql -U $(printf '%q' "$DB_USER") -d postgres -c \
  \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid<>pg_backend_pid();\"" \
  >/dev/null 2>&1 || true
# REFRESH COLLATION VERSION: CREATE DATABASE fails outright on a libc collation
# mismatch, which happens whenever the image's glibc moves under an old volume.
tgt_exec "psql -U $(printf '%q' "$DB_USER") -d postgres -c 'ALTER DATABASE template1 REFRESH COLLATION VERSION;'" \
  >/dev/null 2>&1 || true
tgt_psql_maint "DROP DATABASE IF EXISTS \"${DB_NAME}\" WITH (FORCE);" >/dev/null
tgt_psql_maint "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\";"  >/dev/null

# ── 5. Restore ─────────────────────────────────────────────────────────────
RESTORE_LOG="$(mktemp "${TMPDIR:-/tmp}/${BACKUP_PREFIX}_restore.XXXXXX.log")"
set +e
if [[ "$CMD" == full ]]; then
  log "Restoring (pg_restore, ${JOBS} parallel jobs)"
  tgt_exec "pg_restore -U $(printf '%q' "$DB_USER") -d $(printf '%q' "$DB_NAME") \
              --no-owner --no-privileges -j ${JOBS} ${REMOTE_TMP}" >"$RESTORE_LOG" 2>&1
else
  log "Restoring (psql, plain SQL)"
  tgt_exec "gunzip -c ${REMOTE_TMP} 2>/dev/null || cat ${REMOTE_TMP}" \
    | tgt_exec "psql -U $(printf '%q' "$DB_USER") -d $(printf '%q' "$DB_NAME") -f -" >"$RESTORE_LOG" 2>&1
fi
RC=$?
set -e
cleanup_remote

# pg_restore exits non-zero for benign things too. transaction_timeout is a
# PG17+ GUC that older servers reject, and the trailing "errors ignored on
# restore" line is a summary, not an error.
REAL_ERRS="$(grep -iE 'error|fatal' "$RESTORE_LOG" 2>/dev/null \
  | grep -viE 'transaction_timeout|errors ignored on restore' || true)"
if [[ -n "$REAL_ERRS" ]]; then
  warn "restore reported errors:"; echo "$REAL_ERRS" | head -20 >&2
  warn "full log: $RESTORE_LOG"
  [[ "$RC" -ne 0 ]] && die "restore failed (rc=$RC) — the safety dump above is your way back"
else
  rm -f "$RESTORE_LOG"
fi
ok "restore complete"

# ── 6. Bring the app back (also runs on any exit path above) ───────────────
trap - EXIT
restart_apps

# ── 7. Verify ──────────────────────────────────────────────────────────────
if [[ "$VERIFY" -eq 1 ]]; then
  NEW_TABLES="$(tgt_table_count)"; NEW_SIZE="$(tgt_db_size)"
  echo
  printf '  %-14s %s\n' "archive said:" "${A_TABLES} tables, ${A_SIZE}"
  printf '  %-14s %s\n' "database now:" "${NEW_TABLES} tables, ${NEW_SIZE}"
  if [[ "$A_TABLES" == "?" ]]; then
    info "no .meta to compare against"
  elif [[ "$NEW_TABLES" == "$A_TABLES" ]]; then
    ok "table counts match"
  else
    warn "table counts differ — expected if Django re-ran migrations on restart, suspicious otherwise"
  fi
fi

hdr "Done. '$DB_NAME' on target '$TARGET' restored from $(basename "$ARCHIVE")"
