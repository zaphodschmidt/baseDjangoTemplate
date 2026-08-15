#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/pg-upgrade.sh — move the LOCAL containerized Postgres to a new major
# version, via dump/restore.
#
# Postgres refuses to start on a data directory written by a different major
# version, so bumping `image: postgres:16` to `:17` in the local compose file
# doesn't upgrade anything — it just makes the container crash-loop. The volume
# has to be dumped, destroyed, and refilled.
#
#   1. dump the current database (via tools/db-backup.sh, so it is verified,
#      checksummed and kept — this is your only copy for the next few minutes)
#   2. tear the stack down and DELETE the postgres volume
#   3. bring the new major version up on an empty volume
#   4. restore
#
# LOCAL ONLY, on purpose. Prod and test run Postgres on the host, not in a
# container; upgrading those is a package-manager job (pg_upgradecluster), and
# a script that deleted a docker volume there would delete the wrong thing.
#
# Usage:
#   # edit the local compose file: image: postgres:17
#   ./tools/pg-upgrade.sh
#   ./tools/pg-upgrade.sh --to 17        # also patches the compose file for you
#
# Flags:
#   --to N        Target major version; rewrites the local compose file
#   --from-file F Restore from an existing archive instead of dumping now
#   -y, --yes     No prompts (the volume deletion still prints loudly)
#   -h, --help
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TO_MAJOR=""; FROM_FILE=""; ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)        TO_MAJOR="$2"; shift 2 ;;
    --from-file) FROM_FILE="$2"; shift 2 ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    -h|--help)   sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

cd "$REPO_DIR"
resolve_target local
resolve_docker

CURRENT_IMAGE="$(grep -oE 'image: *postgres:[0-9.]+' "$COMPOSE_LOCAL" | head -1 | awk '{print $2}')"
CURRENT_MAJOR="${CURRENT_IMAGE##*:}"; CURRENT_MAJOR="${CURRENT_MAJOR%%.*}"

# Ask DOCKER which volume holds the data directory, rather than deriving the
# name from the repo directory. Compose lowercases the project name and prefixes
# it, so `baseDjangoTemplate` + `postgres_data` is really
# `basedjangotemplate_postgres_data` — a derived guess is wrong for any repo
# with a capital letter in its name, and `docker volume rm` on a wrong name
# fails open: the upgrade proceeds onto the OLD data directory and the new
# major crash-loops. Set DB_VOLUME in project.env to override.
VOLUME="${DB_VOLUME:-$(dock inspect "$TGT_CONTAINER" \
  --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)}"
[[ -n "$VOLUME" ]] || die "cannot determine the postgres data volume from container ${TGT_CONTAINER} — set DB_VOLUME in tools/project.env"

# The real "from" version is what the RUNNING SERVER reports, not what the
# compose file says. The pin becomes the DESTINATION the moment `--to N` rewrites
# it — or the moment someone edits it by hand — so treating the pin as the source
# both prints "PostgreSQL 18 -> 18" and, worse, makes the "nothing to do" check
# below refuse an upgrade that is genuinely pending.
RUNNING_VER=""; RUNNING_MAJOR=""
if dock ps -q --filter "id=${TGT_CONTAINER}" 2>/dev/null | grep -q .; then
  RUNNING_VER="$(tgt_server_version || true)"
  RUNNING_MAJOR="$(pg_major "$RUNNING_VER")"
fi
FROM_MAJOR="${RUNNING_MAJOR:-$CURRENT_MAJOR}"

hdr "Local Postgres major upgrade"
info "compose file  $COMPOSE_LOCAL"
info "compose pin   $CURRENT_IMAGE"
info "running now   PostgreSQL ${RUNNING_VER:-<container not up, falling back to the compose pin>}"
info "volume        $VOLUME"

# ── Step 1: dump ───────────────────────────────────────────────────────────
if [[ -n "$FROM_FILE" ]]; then
  [[ -f "$FROM_FILE" ]] || die "no such file: $FROM_FILE"
  ARCHIVE="$FROM_FILE"
  log "Using existing archive: $ARCHIVE"
else
  hdr "1/4 · Dump the current database"
  assert_target_reachable
  RUNNING_VER="$(tgt_server_version)"
  info "server reports PostgreSQL $RUNNING_VER, $(tgt_table_count) tables, $(tgt_db_size)"
  "$TOOLS_DIR/db-backup.sh" --target local --label pgupgrade --no-prune \
    || die "dump failed — not touching the volume"
  ARCHIVE="$(ls -1t "$(backup_dir_for local)"/"${BACKUP_PREFIX}"_local_pgupgrade_*.dump | head -1)"
fi
ok "archive: $ARCHIVE ($(human_size "$ARCHIVE"))"

# ── Step 2: point the compose file at the new major ────────────────────────
if [[ -n "$TO_MAJOR" ]]; then
  if [[ "$TO_MAJOR" == "$CURRENT_MAJOR" ]]; then
    info "compose file already on postgres:${TO_MAJOR}"
  else
    hdr "2/4 · Point $(basename "$COMPOSE_LOCAL") at postgres:${TO_MAJOR}"
    cp "$COMPOSE_LOCAL" "${COMPOSE_LOCAL}.pre-pg${TO_MAJOR}"
    sed -i -E "s|(image: *)postgres:[0-9.]+|\1postgres:${TO_MAJOR}|" "$COMPOSE_LOCAL"
    ok "updated (previous file kept as $(basename "${COMPOSE_LOCAL}").pre-pg${TO_MAJOR})"
    grep -nE 'image: *postgres' "$COMPOSE_LOCAL" | sed 's/^/    /'
  fi
else
  TARGET_IMAGE="$(grep -oE 'image: *postgres:[0-9.]+' "$COMPOSE_LOCAL" | head -1 | awk '{print $2}')"
  TO_MAJOR="${TARGET_IMAGE##*:}"; TO_MAJOR="${TO_MAJOR%%.*}"
  # Compared against the RUNNING major, so an already-edited compose file still
  # upgrades instead of being mistaken for "nothing to do".
  if [[ "$TO_MAJOR" == "$FROM_MAJOR" ]]; then
    die "the running server is already PostgreSQL ${FROM_MAJOR} and $(basename "$COMPOSE_LOCAL") says postgres:${TO_MAJOR} — nothing to upgrade. Pass --to N to change majors."
  fi
fi

# ── Step 3: destroy and recreate the volume ────────────────────────────────
hdr "3/4 · Destroy the ${FROM_MAJOR} data volume and start ${TO_MAJOR} empty"
printf '%s⚠  This DELETES docker volume "%s". Everything in the local database\n' "$C_RED" "$VOLUME"
printf '   goes away and comes back only from the archive above.%s\n\n' "$C_OFF"
info "archive to restore from: $ARCHIVE"
confirm "Delete the volume and continue?" || die "aborted — nothing was changed"

log "Stopping the stack"
dock compose -f "$COMPOSE_LOCAL" down

log "Removing volume $VOLUME"
dock volume rm "$VOLUME" >/dev/null 2>&1 || warn "volume $VOLUME was already gone"

log "Starting postgres:${TO_MAJOR}"
dock compose -f "$COMPOSE_LOCAL" up -d "$DB_SERVICE"

log "Waiting for the new server"
resolve_target local
for _ in $(seq 1 60); do
  dock exec "$TGT_CONTAINER" pg_isready -U "$DB_USER" -d postgres >/dev/null 2>&1 && break
  sleep 1
done
dock exec "$TGT_CONTAINER" pg_isready -U "$DB_USER" -d postgres >/dev/null 2>&1 \
  || die "postgres:${TO_MAJOR} did not come up — check: $DOCKER compose -f $(basename "$COMPOSE_LOCAL") logs $DB_SERVICE"

NEW_VER="$(trim "$(dock exec "$TGT_CONTAINER" psql -U "$DB_USER" -d postgres -tAc 'show server_version')")"
ok "PostgreSQL $NEW_VER up on an empty volume"

# ── Step 4: restore ────────────────────────────────────────────────────────
hdr "4/4 · Restore"
# The entrypoint creates the database on first boot, so it usually
# already exists and is empty; db-restore.sh drops and recreates it either way.
ASSUME_YES=1 "$TOOLS_DIR/db-restore.sh" full "$ARCHIVE" --target local --no-safety-dump --yes \
  || die "restore failed. The archive is still at: $ARCHIVE"

log "Bringing the rest of the stack up (Django will re-run migrate)"
dock compose -f "$COMPOSE_LOCAL" up -d

hdr "Upgrade complete: PostgreSQL ${FROM_MAJOR} -> ${TO_MAJOR}"
info "archive kept at $ARCHIVE — delete it once you've used the app and are happy"
info "if this went wrong: ./tools/db-restore.sh full $(basename "$ARCHIVE") --target local"
