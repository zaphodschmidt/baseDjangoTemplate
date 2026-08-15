#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/db-refresh-local.sh — refresh the LOCAL dev database from PRODUCTION.
#
# Flow: pg_dump ON prod (peer auth as `postgres`, no password anywhere) streams
# a custom-format archive here, then tools/db-restore.sh loads it into the local
# container. This script does no dropping, no restoring and no container
# juggling of its own — db-restore.sh already verifies the archive on the target
# BEFORE dropping, takes a safety dump, stops both writers, and restarts exactly
# the services that were running.
#
# The obvious alternative — an SSH tunnel to prod's Postgres, then this box's
# own pg_dump across it — has two dead ends, and both are why this script does
# not do that:
#
#   1. AUTH. The tunnel authenticates as the application role, whose password
#      lives only in the server's own env file. Nothing a developer can type
#      will work, so the script prompts and then fails. Peer-auth
#      `sudo -u postgres` on the server needs no secret at all.
#   2. VERSION. A pg_dump client older than the server aborts with "server
#      version mismatch" before writing a byte, and the two drift the moment
#      either box is upgraded. Dumping with the SERVER's own pg_dump tracks its
#      version for free — the rule lib/common.sh states and every tool follows.
#
# A newer archive still cannot be restored into an older container, so the major
# versions are compared UP FRONT, before the dump and long before anything is
# dropped. If the local container is older, --upgrade-pg does the whole job in
# one pass: dump, bump the compose image, recreate the volume, and restore into
# the new empty cluster.
#
# Usage:
#   ./tools/db-refresh-local.sh                    # prod -> local
#   ./tools/db-refresh-local.sh -y                 # non-interactive
#   ./tools/db-refresh-local.sh --upgrade-pg       # ...also bump local PG major
#   ./tools/db-refresh-local.sh --dump-only        # just fetch the archive
#   ./tools/db-refresh-local.sh --from test        # pull from the test box
#
# Flags:
#   --from prod|test     Where to pull from                  (default: prod)
#   -y, --yes            Skip confirmations
#   -j, --jobs N         Parallel restore jobs               (default: 4)
#   -f, --dump-file PATH Archive path on this box            (default: /tmp/${BACKUP_PREFIX}_prod.dump)
#       --dump-only      Create the archive, restore nothing
#       --upgrade-pg     If local PG is older, upgrade it and restore in one pass
#       --no-safety-dump Don't back up the local db first    (don't)
#       --no-restart     Leave the local app containers alone
#       --no-verify      Skip the post-restore comparison
#   -h, --help
#
# Env overrides:
#   PROD_SSH / TEST_SSH   ssh aliases                       (tools/project.env)
#   PG_SUPERUSER          peer-auth OS user on the source   (default: postgres)
#   DB_NAME / SRC_DB      database name                     (default: from .env)
#   ENV_FILE              env file for the local db name
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SRC_ARG="prod"; JOBS=4; ASSUME_YES=0
DUMP_FILE=""; DUMP_ONLY=0; UPGRADE_PG=0
SAFETY=1; RESTART=1; VERIFY=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)            SRC_ARG="$2"; shift 2 ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    -j|--jobs)         JOBS="$2"; shift 2 ;;
    -f|--dump-file)    DUMP_FILE="$2"; shift 2 ;;
    --dump-only)       DUMP_ONLY=1; shift ;;
    --upgrade-pg)      UPGRADE_PG=1; shift ;;
    --no-safety-dump)  SAFETY=0; shift ;;
    --no-restart)      RESTART=0; shift ;;
    --no-verify)       VERIFY=0; shift ;;
    -h|--help)         sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

cd "$REPO_DIR"
need_bin ssh sha256sum
resolve_docker
resolve_target local
src_resolve "$SRC_ARG"
DUMP_FILE="${DUMP_FILE:-/tmp/${BACKUP_PREFIX}_${SRC}.dump}"

hdr "$PROJECT_NAME refresh · ${SRC} -> local"

# ── 1. Both ends reachable before a single byte moves ──────────────────────
src_assert_reachable
assert_target_reachable

SRC_VER="$(src_server_version)"
[[ -n "$SRC_VER" ]] || die "could not query ${SRC_SSH} as ${PG_SUPERUSER} (is database '${SRC_DB}' present?)"
SRC_SIZE="$(src_db_size)"; SRC_TABLES="$(src_table_count)"
LOC_VER="$(tgt_server_version)"

printf '  %-14s %s\n' "source:" "${SRC_SSH} — PostgreSQL ${SRC_VER}, ${SRC_SIZE}, ${SRC_TABLES} tables"
if tgt_db_exists; then
  printf '  %-14s %s\n' "local now:" "PostgreSQL ${LOC_VER}, $(tgt_db_size), $(tgt_table_count) tables"
else
  printf '  %-14s %s\n' "local now:" "PostgreSQL ${LOC_VER}, database '${DB_NAME}' absent"
fi

# ── 2. Major-version preflight, before the dump and before any drop ────────
# A newer archive restored into an older server fails PARTWAY THROUGH, i.e.
# after the database has already been dropped. Catch it while everything is
# still intact and the only cost is a message.
SRC_MAJ="$(pg_major "$SRC_VER")"; LOC_MAJ="$(pg_major "$LOC_VER")"
[[ -n "$SRC_MAJ" && -n "$LOC_MAJ" ]] || die "could not read both server versions (source='${SRC_VER}' local='${LOC_VER}')"

if (( LOC_MAJ < SRC_MAJ )) && [[ "$DUMP_ONLY" -ne 1 && "$UPGRADE_PG" -ne 1 ]]; then
  warn "local Postgres is ${LOC_MAJ} but ${SRC} is ${SRC_MAJ} — a PG${SRC_MAJ} archive cannot be restored into PG${LOC_MAJ}."
  die "$(printf 'upgrade the local container first. Either:\n       ./tools/db-refresh-local.sh --upgrade-pg     (one pass: dump, bump to PG%s, restore)\n     or, if you want to inspect the archive first:\n       ./tools/db-refresh-local.sh --dump-only\n       ./tools/pg-upgrade.sh --to %s --from-file %s' "$SRC_MAJ" "$SRC_MAJ" "$DUMP_FILE")"
fi
if (( LOC_MAJ > SRC_MAJ )); then
  info "local PG${LOC_MAJ} is newer than ${SRC}'s PG${SRC_MAJ} — that direction restores fine"
fi

# ── 3. Dump on the source ──────────────────────────────────────────────────
log "Dumping ${SRC} (pg_dump ${SRC_VER} on ${SRC_SSH}, peer auth — no password)"
src_dump_to "$DUMP_FILE"
ok "archive: $DUMP_FILE ($(human_size "$DUMP_FILE"))"

write_source_meta "$DUMP_FILE" "$SRC_VER" "$SRC_SIZE" "$SRC_TABLES"
info "sidecar: ${DUMP_FILE}.meta (records the source version, so the restore's downgrade guard can fire)"

if [[ "$DUMP_ONLY" -eq 1 ]]; then
  hdr "Dump-only mode; nothing was restored."
  info "the archive is a full copy of ${SRC} — it is mode 0600, delete it when done"
  exit 0
fi

# ── 4. Hand off ────────────────────────────────────────────────────────────
# Either pg-upgrade.sh (which rebuilds the volume on the new major and restores
# into it) or db-restore.sh. Both run pg_restore INSIDE the container, so the
# client version always matches the server — this box's psql 16 is never used.
if (( LOC_MAJ < SRC_MAJ )); then
  hdr "Local PG${LOC_MAJ} -> PG${SRC_MAJ}, restoring ${SRC}'s data into the new cluster"
  UPGRADE_ARGS=(--to "$SRC_MAJ" --from-file "$DUMP_FILE")
  [[ "$ASSUME_YES" -eq 1 ]] && UPGRADE_ARGS+=(--yes)
  exec "$TOOLS_DIR/pg-upgrade.sh" "${UPGRADE_ARGS[@]}"
fi

RESTORE_ARGS=(full "$DUMP_FILE" --target local --jobs "$JOBS")
[[ "$ASSUME_YES" -eq 1 ]] && RESTORE_ARGS+=(--yes)
[[ "$SAFETY"     -eq 0 ]] && RESTORE_ARGS+=(--no-safety-dump)
[[ "$RESTART"    -eq 0 ]] && RESTORE_ARGS+=(--no-restart)
[[ "$VERIFY"     -eq 0 ]] && RESTORE_ARGS+=(--no-verify)

"$TOOLS_DIR/db-restore.sh" "${RESTORE_ARGS[@]}" || die "restore failed — the archive is still at $DUMP_FILE"

hdr "Done. Local '${DB_NAME}' now mirrors ${SRC}."
info "Django re-runs migrate on restart; watch it with: $DOCKER compose -f $(basename "$COMPOSE_LOCAL") logs -f $BACKEND_SERVICE"
info "archive kept at $DUMP_FILE (0600, full copy of ${SRC}) — delete it once you're happy"
