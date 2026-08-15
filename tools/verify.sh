#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/verify.sh — prove the tree is deployable BEFORE anything touches a
# server. This is `make check`.
#
# It exists because of one fact about how this stack deploys: there is no image
# registry. The production compose file uses `build:`, so the images are
# compiled ON the server, during `up -d --build`, AFTER the pre-deploy backup
# has been taken and AFTER the remote checkout has already moved to the new tag.
# A TypeScript error or a missing migration is therefore not caught at deploy
# time — it is caught halfway through a production deploy, with the stack down.
#
# So everything that can fail the build runs here first, on this box, cheapest
# gate first, aborting on the first failure. Nothing in this script writes to a
# server or to the database.
#
# Usage:
#   ./tools/verify.sh                # every gate
#   ./tools/verify.sh --quick        # skip the slow two (tests + image build)
#   ./tools/verify.sh --no-image     # skip only the production image build
#   ./tools/verify.sh --no-tests     # skip only the test suite
#
# Gates, in order:
#   1  django check              — system checks; a misconfigured setting here
#                                  is a container that boots and 500s
#   2  makemigrations --check    — a model edited with no migration deploys
#                                  cleanly, runs migrate, and then serves
#                                  against a schema that does not match the ORM
#   3  tsc --noEmit              — the frontend type gate, including the
#                                  generated client
#   4  generated client is fresh — regenerates from the live schema and fails on
#                                  a diff. A stale committed client still
#                                  compiles; it just describes an API that no
#                                  longer exists, which is the one failure
#                                  codegen cannot catch by itself
#   5  test suite                — whatever backend/ is configured to run
#   6  production image build    — compiles the ACTUAL production images here
#
# Gates 1, 2 and 4 need the local stack; it is started if it isn't up.
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RUN_IMAGE=1; RUN_TESTS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)     RUN_IMAGE=0; RUN_TESTS=0; shift ;;
    --no-image)  RUN_IMAGE=0; shift ;;
    --no-tests)  RUN_TESTS=0; shift ;;
    -h|--help)   sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

cd "$REPO_DIR"
need_bin git docker
resolve_docker

STAGE=0
stage() { STAGE=$((STAGE+1)); hdr "[$STAGE] $*"; }

ENV_FILE="$(pick_env_file)"
BACKEND_PORT="$(env_get "$ENV_KEY_BACKEND_PORT")"
BACKEND_PORT="${BACKEND_PORT:-$DEFAULT_BACKEND_PORT}"
BASE="http://localhost:${BACKEND_PORT}"

# The backend container is where `check`, `makemigrations --check` and the test
# suite run — it has the Python dependencies and can resolve the `db` host, and
# the host shell can do neither.
ensure_backend_up() {
  if dock compose -f "$COMPOSE_LOCAL" ps --status running --services 2>/dev/null \
       | grep -qx "$BACKEND_SERVICE"; then return 0; fi
  log "$BACKEND_SERVICE is not running — starting $DB_SERVICE + $BACKEND_SERVICE"
  dock compose -f "$COMPOSE_LOCAL" up -d "$DB_SERVICE" "$BACKEND_SERVICE" >/dev/null 2>&1 \
    || die "could not start the local stack (gates 1, 2 and 4 need it)"
  local deadline=$(( $(date +%s) + 120 ))
  until curl -fsS -o /dev/null "${BASE}${HEALTH_PATH}" 2>/dev/null; do
    [[ "$(date +%s)" -ge "$deadline" ]] \
      && die "$BACKEND_SERVICE did not answer ${BASE}${HEALTH_PATH} within 120s"
    sleep 2
  done
  ok "$BACKEND_SERVICE up"
}

# Run a command inside the backend container.
bex() { dock compose -f "$COMPOSE_LOCAL" exec -T "$BACKEND_SERVICE" "$@"; }

# ── 1. Django system checks ────────────────────────────────────────────────
stage "Django system checks"
ensure_backend_up
bex python manage.py check || die "manage.py check failed"
ok "no system check issues"

# ── 2. Missing migrations ──────────────────────────────────────────────────
# The container runs `migrate` on boot. A model change with no migration file
# deploys cleanly and then serves against a schema that doesn't match the ORM —
# and you find out from a 500 on a column that isn't there.
stage "Missing migrations"
bex python manage.py makemigrations --check --dry-run \
  || die "model changes have no migration — run: make migrate"
ok "no unmigrated model changes"

# ── 3. Frontend typecheck ──────────────────────────────────────────────────
stage "Frontend typecheck (tsc)"
if [[ -d "$FRONTEND_DIR/node_modules" ]]; then
  ( cd "$FRONTEND_DIR" && "$PKG_MANAGER" exec tsc --noEmit ) \
    || die "tsc failed — the production image build would fail the same way"
  ok "types clean"
else
  warn "$FRONTEND_DIR/node_modules missing — run: cd $FRONTEND_DIR && $PKG_MANAGER install"
  die "cannot typecheck without dependencies installed"
fi

# ── 4. Generated client matches the schema ─────────────────────────────────
# Regenerate, then diff. Order matters: hand-editing src/api/ proves nothing,
# because the regeneration overwrites it — what this catches is an API change
# that was never regenerated. `git diff` only sees TRACKED files, so this gate
# is inert until src/api/ has been committed once.
stage "Generated API client is current"
if git ls-files --error-unmatch "$FRONTEND_DIR/src/api" >/dev/null 2>&1; then
  ( cd "$FRONTEND_DIR" && "$PKG_MANAGER" run generate-api >/dev/null ) \
    || die "codegen failed — is the backend serving /api/schema/ on :${BACKEND_PORT}?"
  git diff --exit-code --stat -- "$FRONTEND_DIR/src/api" \
    || die "the committed API client does not match the schema. Commit the regenerated client."
  ok "client matches the schema"
else
  warn "$FRONTEND_DIR/src/api is not tracked by git — gate skipped (commit it once to arm this)"
fi

# ── 5. Tests ───────────────────────────────────────────────────────────────
# Whichever runner the backend is configured for. pytest if there is a config
# for it, else Django's own runner — so this gate works from day one and keeps
# working after you add pytest.
if [[ "$RUN_TESTS" -eq 1 ]]; then
  stage "Backend tests"
  if [[ -f "$BACKEND_DIR/pytest.ini" || -f "$BACKEND_DIR/pyproject.toml" ]] \
     && bex python -c 'import pytest' >/dev/null 2>&1; then
    bex pytest -q || die "pytest failed"
  else
    bex python manage.py test --noinput || die "manage.py test failed"
  fi
  ok "tests pass"
else
  info "skipping tests (--no-tests/--quick)"
fi

# ── 6. Production image build ──────────────────────────────────────────────
# The gate this script mostly exists for. Same Dockerfile, same compose file,
# same build args the server will use — so a build that succeeds here is the one
# that will succeed there.
#
# The frontend's build-time env values come from THIS box's env file, so the
# bundle is not byte-identical to production's. That is fine: what is being
# proved is that the build COMPILES, not what it compiled against.
if [[ "$RUN_IMAGE" -eq 1 ]]; then
  stage "Production image build"
  if [[ -f "$COMPOSE_PROD" ]]; then
    [[ -n "$ENV_FILE" ]] || die "no .env — the production compose file needs one for its build args"
    info "using $ENV_FILE for build args"
    dock compose -f "$COMPOSE_PROD" --env-file "$ENV_FILE" build \
      || die "production image build FAILED — this is exactly what would have failed on the server, mid-deploy"
    ok "production images build"
  else
    warn "$(basename "$COMPOSE_PROD") does not exist — gate skipped."
    warn "Until it does, nothing proves the production images compile. See tools/README.md."
  fi
else
  info "skipping production image build (--no-image/--quick)"
fi

hdr "Verified"
ok "$STAGE gates passed — this tree is safe to deploy"
