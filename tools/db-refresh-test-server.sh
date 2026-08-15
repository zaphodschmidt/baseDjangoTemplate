#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/db-refresh-test-server.sh — refresh the TEST SERVER's database from
# PRODUCTION. RUN FROM THE DEV BOX, the one machine that can ssh to both.
#
# Flow: pg_dump ON prod (peer auth as `postgres`, no password) streams a
# custom-format archive to this box, then tools/db-restore.sh --target test
# loads it onto the test VM's HOST Postgres. Dev only relays the file; it never
# runs pg_dump or pg_restore against the data, because prod and test are
# PostgreSQL 18 and this box's client is 16.
#
# This used to carry its own ~80-line remote restore heredoc. Everything it did
# now comes from db-restore.sh, which does it in a safer order — and that
# reordering is the point of the rewrite:
#
#   * it verifies the archive is READABLE on the test box (pg_restore --list)
#     BEFORE dropping the database. The old script dropped first, so a truncated
#     scp left the test box with no database and no way back.
#   * it takes a safety dump of what it is about to destroy (--no-safety-dump
#     to skip on a box you genuinely don't care about).
#   * it terminates stray sessions, so DROP DATABASE cannot hang forever on one
#     idle psql.
#   * it restarts exactly the services that were running, from an EXIT trap, so
#     a failed restore never also leaves the test stack down.
#
# Major versions are compared UP FRONT, before the dump — a newer archive fails
# partway into an older server, i.e. after the drop.
#
# Requirements: ssh to $PROD_SSH and $TEST_SSH both work with key auth;
# passwordless `sudo -u postgres` on both; a repo checkout with $REMOTE_ENV_FILE
# at $REMOTE_REPO_DIR on the test box, and passwordless `sudo docker` there.
#
# Usage:
#   ./tools/db-refresh-test-server.sh                 # prod -> test
#   ./tools/db-refresh-test-server.sh -y              # non-interactive
#   ./tools/db-refresh-test-server.sh --dump-only     # just fetch the archive
#   ./tools/db-refresh-test-server.sh --no-safety-dump
#
# Flags:
#   -y, --yes            Skip confirmations
#   -j, --jobs N         Parallel restore jobs on the test box  (default: 4)
#   -f, --dump-file PATH Archive path on this box               (default: /tmp/${BACKUP_PREFIX}_prod.dump)
#       --dump-only      Create the archive, restore nothing
#       --no-safety-dump Don't back up the test db first
#       --no-restart     Leave the test box's containers alone
#       --no-verify      Skip the post-restore comparison
#   -h, --help
#
# Env overrides:
#   PROD_SSH          ssh alias for prod                 (tools/project.env)
#   TEST_SSH          ssh alias for the TEST server      (tools/project.env)
#   REMOTE_REPO_DIR   repo path on the test server       (tools/project.env)
#   PG_SUPERUSER      peer-auth OS user                  (default: postgres)
#   DB_NAME / SRC_DB  database name                      (default: from .env)
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

JOBS=4; ASSUME_YES=0; DUMP_FILE=""; DUMP_ONLY=0
SAFETY=1; RESTART=1; VERIFY=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)          ASSUME_YES=1; shift ;;
    -j|--jobs)         JOBS="$2"; shift 2 ;;
    -f|--dump-file)    DUMP_FILE="$2"; shift 2 ;;
    --dump-only)       DUMP_ONLY=1; shift ;;
    --no-safety-dump)  SAFETY=0; shift ;;
    --no-restart)      RESTART=0; shift ;;
    --no-verify)       VERIFY=0; shift ;;
    -h|--help)         sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

cd "$REPO_DIR"
need_bin ssh sha256sum
resolve_target test          # where we write: the test VM's host Postgres, over ssh
src_resolve prod             # where the data comes from
DUMP_FILE="${DUMP_FILE:-/tmp/${BACKUP_PREFIX}_prod.dump}"

hdr "$PROJECT_NAME refresh · prod -> test (${TGT_SSH})"

# ── 1. Both hops reachable before a single byte moves ──────────────────────
src_assert_reachable
[[ "$DUMP_ONLY" -eq 1 ]] || assert_target_reachable

SRC_VER="$(src_server_version)"
[[ -n "$SRC_VER" ]] || die "could not query ${SRC_SSH} as ${PG_SUPERUSER} (is database '${SRC_DB}' present?)"
SRC_SIZE="$(src_db_size)"; SRC_TABLES="$(src_table_count)"
printf '  %-14s %s\n' "source:" "${SRC_SSH} — PostgreSQL ${SRC_VER}, ${SRC_SIZE}, ${SRC_TABLES} tables"

if [[ "$DUMP_ONLY" -ne 1 ]]; then
  TST_VER="$(tgt_server_version)"
  if tgt_db_exists; then
    printf '  %-14s %s\n' "test now:" "PostgreSQL ${TST_VER}, $(tgt_db_size), $(tgt_table_count) tables"
  else
    printf '  %-14s %s\n' "test now:" "PostgreSQL ${TST_VER}, database '${DB_NAME}' absent"
  fi

  # ── 2. Major-version preflight, before the dump and before any drop ──────
  SRC_MAJ="$(pg_major "$SRC_VER")"; TST_MAJ="$(pg_major "$TST_VER")"
  [[ -n "$SRC_MAJ" && -n "$TST_MAJ" ]] || die "could not read both server versions (prod='${SRC_VER}' test='${TST_VER}')"
  if (( TST_MAJ < SRC_MAJ )); then
    warn "the test box runs PostgreSQL ${TST_MAJ} but prod is ${SRC_MAJ} — a PG${SRC_MAJ} archive cannot be restored into PG${TST_MAJ}."
    die "upgrade the test cluster first (pg_upgradecluster ${TST_MAJ} main, on ${TGT_SSH} — it runs host Postgres, so tools/pg-upgrade.sh does NOT apply there)"
  fi
fi

# ── 3. Dump on prod ────────────────────────────────────────────────────────
log "Dumping prod (pg_dump ${SRC_VER} on ${SRC_SSH}, peer auth — no password)"
src_dump_to "$DUMP_FILE"
ok "archive: $DUMP_FILE ($(human_size "$DUMP_FILE"))"

write_source_meta "$DUMP_FILE" "$SRC_VER" "$SRC_SIZE" "$SRC_TABLES"
info "sidecar: ${DUMP_FILE}.meta"

if [[ "$DUMP_ONLY" -eq 1 ]]; then
  hdr "Dump-only mode; nothing was restored."
  info "reuse it for the local box with: ./tools/pg-upgrade.sh --to $(pg_major "$SRC_VER") --from-file $DUMP_FILE"
  info "the archive is a full copy of prod — it is mode 0600, delete it when done"
  exit 0
fi

# ── 4. Hand off to db-restore.sh ───────────────────────────────────────────
# It uploads, verifies on the far side, stops every service in
# APP_SERVICES_PROD, drops, recreates, restores with $JOBS parallel jobs using
# the test box's OWN pg_restore, and restarts exactly what it stopped.
RESTORE_ARGS=(full "$DUMP_FILE" --target test --jobs "$JOBS")
[[ "$ASSUME_YES" -eq 1 ]] && RESTORE_ARGS+=(--yes)
[[ "$SAFETY"     -eq 0 ]] && RESTORE_ARGS+=(--no-safety-dump)
[[ "$RESTART"    -eq 0 ]] && RESTORE_ARGS+=(--no-restart)
[[ "$VERIFY"     -eq 0 ]] && RESTORE_ARGS+=(--no-verify)

"$TOOLS_DIR/db-restore.sh" "${RESTORE_ARGS[@]}" || die "restore failed — the archive is still at $DUMP_FILE"

hdr "Done. '${DB_NAME}' on ${TGT_SSH} now mirrors prod."
info "Django re-runs migrate on restart — that IS the schema conversion. Watch it:"
info "  ssh ${TGT_SSH} sudo docker logs -f $BACKEND_SERVICE"
info "archive kept at $DUMP_FILE (0600, full copy of prod) — delete it once you're happy"
