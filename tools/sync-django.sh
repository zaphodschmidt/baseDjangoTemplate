#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/sync-django.sh — apply Django schema changes and refresh the typed
# frontend client, each in the place it actually works:
#
#   1. makemigrations + migrate  → INSIDE the backend container. It has the
#      Python dependencies and can resolve the `db` host; the host shell can do
#      neither.
#   2. generate-api              → ON THE HOST, in the frontend, against the
#      running container's /api/schema/.
#
# Both halves in one command, because doing only the first is the failure this
# script exists to prevent: the schema moves, the committed client does not, and
# the frontend's types keep describing an API that no longer exists. They still
# compile. Nothing errors until a field is missing at runtime.
#
# Run it after changing a model, a serializer, a view, or a route.
#
# Usage:
#   ./tools/sync-django.sh                 # all apps
#   ./tools/sync-django.sh core billing    # only these app LABELS
#   ./tools/sync-django.sh --no-api        # migrations only, skip codegen
#
# Note that an app LABEL is not always its module name — `apps/precast` with
# `label = 'rings'` is migrated as `rings`. `makemigrations <name>` for a name
# that is not a label SILENTLY DOES NOTHING and exits 0, so the default here is
# every app.
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

WANT_API=1
APPS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-api)  WANT_API=0; shift ;;
    -h|--help) sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown flag: $1" ;;
    *)         APPS+=("$1"); shift ;;
  esac
done

cd "$REPO_DIR"
resolve_docker
ENV_FILE="$(pick_env_file)"
BACKEND_PORT="$(env_get "$ENV_KEY_BACKEND_PORT")"
BACKEND_PORT="${BACKEND_PORT:-$DEFAULT_BACKEND_PORT}"

dock compose "${COMPOSE_LOCAL_ARGS[@]}" ps --status running --services 2>/dev/null \
  | grep -qx "$BACKEND_SERVICE" \
  || die "service '$BACKEND_SERVICE' is not running. Start it first:
       $DOCKER compose -f $(basename "$COMPOSE_LOCAL") up -d $BACKEND_SERVICE"

bex() { dock compose "${COMPOSE_LOCAL_ARGS[@]}" exec -T "$BACKEND_SERVICE" "$@"; }

# ── 1. Migrations (inside the container) ───────────────────────────────────
if [[ ${#APPS[@]} -gt 0 ]]; then
  hdr "makemigrations ${APPS[*]}"
  bex python manage.py makemigrations "${APPS[@]}"
else
  hdr "makemigrations (all apps)"
  bex python manage.py makemigrations
fi

hdr "migrate"
bex python manage.py migrate

if [[ "$WANT_API" -eq 0 ]]; then
  ok "Migrations applied (--no-api: the client was NOT regenerated)."
  exit 0
fi

# ── 2. Wait for the API, then regenerate the client (on the host) ──────────
hdr "waiting for http://localhost:${BACKEND_PORT}${HEALTH_PATH}"
ready=""
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://localhost:${BACKEND_PORT}${HEALTH_PATH}" 2>/dev/null; then
    ready=1; break
  fi
  sleep 1
done
[[ -n "$ready" ]] || die "the API did not answer on port ${BACKEND_PORT} after 30s (is the port published, and ${ENV_KEY_BACKEND_PORT} correct?)"

hdr "$PKG_MANAGER run generate-api ($FRONTEND_DIR → src/api/)"
( cd "$REPO_DIR/$FRONTEND_DIR" && "$PKG_MANAGER" run generate-api )

ok "Migrations applied and $FRONTEND_DIR/src/api regenerated."
info "Commit the regenerated client with the change that caused it — tools/verify.sh fails on a diff."
