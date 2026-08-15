#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/pg-worker-role.sh — give the background worker its own capped DB login.
#
# WHY. One Postgres, several writers, one shared role: a connection leak in a
# background task took all 100 slots on a production database, and the API and
# even `psql` were locked out of a server that was otherwise perfectly healthy.
# Nothing in the system said "a worker may not use every connection" — so
# nothing stopped it.
#
# This is that missing invariant, at layer 1 where CLAUDE.md wants it: a
# dedicated login role with CONNECTION LIMIT. A future leak then exhausts the
# WORKER — background tasks fail, loudly, in one container — instead of the
# whole application. Failure stays inside the thing that failed.
#
# HOW. The role is created IN ROLE <app role> and inherits it, so it needs no
# GRANTs of its own and keeps working when a migration adds a table: it sees
# exactly what the app role sees. It never runs migrations (the backend
# container does), so it has no reason to own objects.
#
# Idempotent: re-running re-applies the limit and sets a fresh password.
#
# Usage:
#   ./tools/pg-worker-role.sh --target prod                 # generates a password
#   ./tools/pg-worker-role.sh --target prod --limit 20
#   ./tools/pg-worker-role.sh --target prod --password-stdin < pw
#   ./tools/pg-worker-role.sh --target prod --show          # report, change nothing
#
# Prints the two lines to add to the target's env file. It does NOT edit that
# file: the deploy owns it, and a half-written credential file breaks boot.
# ---------------------------------------------------------------------------
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

WORKER_ROLE="${WORKER_ROLE:-app_worker}"
LIMIT=20
PW=""
PW_STDIN=0
SHOW_ONLY=0
TARGET_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)      TARGET_ARG="$2"; shift 2 ;;
    --limit)          LIMIT="$2"; shift 2 ;;
    --role)           WORKER_ROLE="$2"; shift 2 ;;
    --password-stdin) PW_STDIN=1; shift ;;
    --show)           SHOW_ONLY=1; shift ;;
    -h|--help)        sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$TARGET_ARG" ]] || die "--target local|prod|test is required"
resolve_target "$TARGET_ARG"
assert_target_reachable

# The app role is what the APP AUTHENTICATES AS — the DB user from the target's
# env file — never the database owner. On a server the owner is usually
# `postgres` (whoever ran the restore), and `IN ROLE postgres` would quietly
# make the worker a superuser-member: the exact opposite of a cap.
case "$TGT_KIND" in
  ssh)  APP_ROLE="$(ssh -o BatchMode=yes "$TGT_SSH" \
          "grep -E '^${ENV_KEY_DB_USER}=' ${REMOTE_REPO_DIR}/${REMOTE_ENV_FILE} 2>/dev/null | tail -1" \
          | cut -d= -f2- | tr -d "'\"")" ;;
  *)    APP_ROLE="$(env_get "$ENV_KEY_DB_USER")" ;;
esac
[[ -n "$APP_ROLE" ]] || die "could not read ${ENV_KEY_DB_USER} from the ${TARGET_ARG} env file"
IS_SUPER="$(tgt_psql "select rolsuper from pg_roles where rolname='${APP_ROLE}'")"
[[ -n "$IS_SUPER" ]] || die "role '${APP_ROLE}' does not exist on ${TARGET_ARG}"
[[ "$IS_SUPER" == "f" ]] \
  || warn "app role '${APP_ROLE}' is a SUPERUSER — the worker will inherit that. Consider stripping it (separate task)."

hdr "Worker DB role · target=${TARGET_ARG} · role=${WORKER_ROLE} · inherits=${APP_ROLE}"

report() {
  info "roles now:"
  tgt_exec "psql -U $(printf '%q' "$DB_USER") -d $(printf '%q' "$DB_NAME") -c \
    \"select rolname, rolconnlimit, rolcanlogin from pg_roles \
      where rolname in ('${WORKER_ROLE}','${APP_ROLE}') order by rolname\""
}

if [[ "$SHOW_ONLY" -eq 1 ]]; then
  report
  exit 0
fi

if [[ "$PW_STDIN" -eq 1 ]]; then
  read -r PW
  [[ -n "$PW" ]] || die "--password-stdin given but nothing was read"
else
  # Alphanumeric only: nothing to escape into SQL, a .env value, or a DSN.
  # head closing the pipe SIGPIPEs tr (exit 141), which pipefail+errexit would
  # turn into a silent death — hence the guard and the explicit length check.
  PW="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 32 || true)"
  [[ ${#PW} -eq 32 ]] || die "password generation produced ${#PW} chars, expected 32"
fi

# CREATE is allowed to fail with "already exists" — that is the idempotent path.
# Everything after it is unconditional, so a re-run repairs a partial state.
if tgt_exec "psql -U $(printf '%q' "$DB_USER") -d $(printf '%q' "$DB_NAME") -v ON_ERROR_STOP=1 -c \
      \"create role ${WORKER_ROLE} login inherit in role ${APP_ROLE}\"" 2>/dev/null; then
  ok "created role ${WORKER_ROLE}"
else
  info "role ${WORKER_ROLE} already exists — reapplying limit and password"
fi

tgt_exec "psql -U $(printf '%q' "$DB_USER") -d $(printf '%q' "$DB_NAME") -v ON_ERROR_STOP=1 \
  -c \"grant ${APP_ROLE} to ${WORKER_ROLE}\" \
  -c \"alter role ${WORKER_ROLE} connection limit ${LIMIT}\" \
  -c \"alter role ${WORKER_ROLE} password '${PW}'\"" >/dev/null

ok "${WORKER_ROLE}: CONNECTION LIMIT ${LIMIT}, inherits ${APP_ROLE}"
report

cat <<EOF

Add these to the target's env file, then restart the worker (or redeploy) so it
picks them up:

  WORKER_DB_USER='${WORKER_ROLE}'
  WORKER_DB_PASSWORD='${PW}'

Wire them up so $(basename "$COMPOSE_PROD") prefers them for the WORKER SERVICE
ONLY, falling back to ${ENV_KEY_DB_USER}/DB_PASSWORD when unset — an environment
without the role then keeps working unchanged.
EOF
