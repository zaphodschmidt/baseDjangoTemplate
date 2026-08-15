#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/deploy.sh — version, back up, ship, verify, and be able to undo it.
#
# Images are built ON the target box (the production compose file uses `build:`,
# there is no registry), so a deploy is: push a tagged commit, pull it over
# there, rebuild, and bring the stack up. The parts that matter are the ones
# either side of that:
#
#   BEFORE  the working tree must be clean, the tree must PASS tools/verify.sh
#           (typecheck, migrations, API smoke, and a real build of the
#           production images — because the images compile on the target, a
#           broken build otherwise surfaces mid-deploy with the stack down),
#           VERSION gets bumped and tagged, and a verified backup of the target
#           database is taken. Deploying a Django change means `migrate` runs on
#           boot; migrations are the one kind of deploy that a `git revert`
#           alone cannot undo. If the backup fails, the deploy does not happen.
#   AFTER   every service must come up and stay up, and the app has to answer.
#           If it doesn't, you get the exact rollback command — or, with
#           --rollback-on-fail, it runs by itself.
#
# Usage:
#   ./tools/deploy.sh --target test              # ship to the test box
#   ./tools/deploy.sh --target prod --minor
#   ./tools/deploy.sh --target prod --dry-run    # print the plan, change nothing
#   ./tools/deploy.sh --rollback --target prod   # go back to the previous tag
#
# Flags:
#   -t, --target test|prod     Where to deploy                (default: test)
#       --major|--minor|--patch  Version bump                 (default: patch)
#       --no-version           Deploy the current commit, no bump/tag
#       --skip-verify          Do NOT run tools/verify.sh first. Say why in the PR.
#       --quick-verify         Run verify.sh --quick (skips smoke + image build)
#       --no-pull              Do NOT fast-forward onto origin/<branch> first
#       --skip-backup          Do NOT back up first. Say why in the PR.
#       --rollback-on-fail     Auto-revert to the previous tag if health fails
#       --rollback             Just roll back to the previous tag and exit
#       --health-url URL       URL to poll after deploy (default: from .env)
#       --timeout N            Health-check seconds                (default: 180)
#       --force                Skip the clean-worktree gate (implies --no-version)
#   -n, --dry-run              Print every step, execute none
#   -y, --yes                  No prompts
#   -h, --help
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TARGET_ARG="test"; BUMP="patch"; SKIP_BACKUP=0; ROLLBACK_ON_FAIL=0
DO_ROLLBACK=0; HEALTH_URL=""; TIMEOUT=180; FORCE=0; DRY=0; ASSUME_YES=0
SKIP_VERIFY=0; VERIFY_QUICK=0; NO_PULL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)        TARGET_ARG="$2"; shift 2 ;;
    --major)            BUMP="major"; shift ;;
    --minor)            BUMP="minor"; shift ;;
    --patch)            BUMP="patch"; shift ;;
    --no-version)       BUMP="none"; shift ;;
    --skip-verify)      SKIP_VERIFY=1; shift ;;
    --quick-verify)     VERIFY_QUICK=1; shift ;;
    --no-pull)          NO_PULL=1; shift ;;
    --skip-backup)      SKIP_BACKUP=1; shift ;;
    --rollback-on-fail) ROLLBACK_ON_FAIL=1; shift ;;
    --rollback)         DO_ROLLBACK=1; shift ;;
    --health-url)       HEALTH_URL="$2"; shift 2 ;;
    --timeout)          TIMEOUT="$2"; shift 2 ;;
    --force)            FORCE=1; BUMP="none"; shift ;;
    -n|--dry-run)       DRY=1; shift ;;
    -y|--yes)           ASSUME_YES=1; shift ;;
    -h|--help)          sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$TARGET_ARG" == prod || "$TARGET_ARG" == test ]] || die "--target must be prod or test"
cd "$REPO_DIR"
need_bin git ssh

resolve_target "$TARGET_ARG"
SSH_HOST="$TGT_SSH"
REMOTE_DIR="${REMOTE_REPO_DIR}"
COMPOSE_REMOTE="sudo -n docker compose -f $(basename "$COMPOSE_PROD") --env-file ${REMOTE_ENV_FILE}"

run() {  # run <description> <command...> — the dry-run seam
  if [[ "$DRY" -eq 1 ]]; then printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_OFF" "$*"; return 0; fi
  "$@"
}
rssh()  { ssh -o BatchMode=yes "$SSH_HOST" "$1"; }
rrun()  {
  if [[ "$DRY" -eq 1 ]]; then printf '  %s[dry-run]%s %s: %s\n' "$C_DIM" "$C_OFF" "$SSH_HOST" "$1"; return 0; fi
  rssh "$1"
}

# An nginx config that proxy_passes a LITERAL container hostname with no
# `resolver` resolves it ONCE at config-parse time and caches the address for
# the life of the process. A `compose up --build` that recreates the upstream
# hands it a new address on the compose network, and nginx keeps dialling the
# dead one — every request 502s with "connect() failed (111: Connection
# refused)" while `compose ps` shows every service running. A graceful reload
# re-parses the config, which re-resolves.
#
# Non-fatal, and skipped entirely when there is no nginx service: if the reload
# fails the old worker keeps serving, and the health poll below is what catches
# it. Set NGINX_SERVICE='' in tools/project.env if you terminate TLS elsewhere.
NGINX_SERVICE="${NGINX_SERVICE:-nginx}"
reload_nginx() {
  [[ -n "$NGINX_SERVICE" ]] || return 0
  log "Reloading $NGINX_SERVICE (re-resolve upstream container addresses)"
  rrun "cd ${REMOTE_DIR} && ${COMPOSE_REMOTE} exec -T ${NGINX_SERVICE} nginx -t && ${COMPOSE_REMOTE} exec -T ${NGINX_SERVICE} nginx -s reload" \
    || warn "${NGINX_SERVICE} reload failed — if the app 502s, run: ${COMPOSE_REMOTE} up -d --force-recreate ${NGINX_SERVICE}"
}

# ── Rollback (also reused by --rollback-on-fail) ───────────────────────────
previous_tag() {
  # The tag before the one currently deployed. Tags are v<semver>, so sort -V.
  git tag --list 'v*' --sort=-v:refname | sed -n '2p'
}

do_rollback() {
  local to="${1:-$(previous_tag)}"
  [[ -n "$to" ]] || die "no previous tag to roll back to"
  hdr "ROLLING BACK $TARGET_ARG to $to"
  rrun "cd ${REMOTE_DIR} && git fetch --tags --quiet && git checkout --quiet ${to} && ${COMPOSE_REMOTE} up -d --build"
  reload_nginx
  warn "Code is back at ${to}. If that deploy ran a Django migration, the SCHEMA IS STILL FORWARD."
  warn "Restore the pre-deploy database backup as well:"
  warn "  ./tools/db-restore.sh latest --target ${TARGET_ARG}"
}

if [[ "$DO_ROLLBACK" -eq 1 ]]; then
  PREV="$(previous_tag)"
  hdr "Rollback $TARGET_ARG"
  info "current tag:  $(git tag --list 'v*' --sort=-v:refname | sed -n '1p')"
  info "rolling back: $PREV"
  confirm "Proceed?" || die "aborted"
  do_rollback "$PREV"
  exit 0
fi

# ── 1. Preflight ───────────────────────────────────────────────────────────
hdr "$PROJECT_NAME deploy · target=$TARGET_ARG · host=$SSH_HOST"

if [[ "$FORCE" -eq 0 ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    printf '%s\n' "$(git status --short)"
    die "working tree is not clean. Commit or stash first, or use --force --no-version."
  fi
  ok "working tree clean"
else
  warn "--force: skipping the clean-worktree gate and the version bump"
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == main || "$TARGET_ARG" == test ]] \
  || { warn "deploying branch '$BRANCH' (not main) to PROD"; confirm "Really?" || die "aborted"; }

ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" true \
  || die "cannot ssh to '$SSH_HOST' — check ~/.ssh/config (README 'Server info')"
ok "ssh to $SSH_HOST"

rssh "test -f ${REMOTE_DIR}/$(basename "$COMPOSE_PROD")" \
  || die "no repo checkout at ${SSH_HOST}:${REMOTE_DIR} (override with REMOTE_REPO_DIR=...)"
rssh "test -f ${REMOTE_DIR}/${REMOTE_ENV_FILE}" \
  || die "${SSH_HOST}:${REMOTE_DIR}/${REMOTE_ENV_FILE} is missing — the production compose file needs it"
ok "remote checkout at ${REMOTE_DIR}"

rssh "sudo -n docker ps >/dev/null 2>&1" \
  || die "passwordless 'sudo docker' does not work on ${SSH_HOST}"
ok "docker usable on the remote"

# ── 1a2. Sync with origin ──────────────────────────────────────────────────
# A deploy ships THIS tree, so "latest" has to mean latest on origin — not
# latest on whichever box you happen to be sitting at. Without a fetch the
# script cannot tell the difference, and being behind fails in the worst
# possible place: verify passes on stale code, VERSION is bumped and TAGGED off
# the stale commit, and only then does `git push` get rejected as
# non-fast-forward — leaving behind a commit and a tag that should never have
# existed. Fetching first turns that into a fast-forward or a clean refusal.
#
# The fetch runs even under --dry-run: it touches no working file, and a dry
# run whose whole job is to report the plan should report an accurate one.
if [[ "$NO_PULL" -eq 0 ]]; then
  log "Syncing with origin"
  git fetch --quiet origin --tags --prune || die "git fetch origin failed"

  if UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    # left = commits on the upstream we lack, right = ours it lacks.
    read -r BEHIND AHEAD <<<"$(git rev-list --left-right --count "${UPSTREAM}...HEAD")"

    if [[ "$BEHIND" -gt 0 && "$AHEAD" -gt 0 ]]; then
      die "local '$BRANCH' has diverged from ${UPSTREAM} (${AHEAD} ahead, ${BEHIND} behind).
       Rebase or merge before deploying:  git pull --rebase"
    elif [[ "$BEHIND" -gt 0 ]]; then
      if [[ "$FORCE" -eq 1 ]]; then
        # --force means the tree may be dirty, and pulling into a dirty tree
        # either refuses or lands a surprise. Report, don't act.
        warn "local '$BRANCH' is ${BEHIND} commit(s) behind ${UPSTREAM}, and --force
       skips the pull. You are deploying code that is NOT the latest."
        confirm "Deploy the older commit anyway?" || die "aborted"
      elif [[ "$DRY" -eq 1 ]]; then
        info "[dry-run] would fast-forward ${BEHIND} commit(s) from ${UPSTREAM}"
      else
        log "Fast-forwarding ${BEHIND} commit(s) from ${UPSTREAM}"
        git merge --ff-only --quiet "$UPSTREAM" \
          || die "fast-forward onto ${UPSTREAM} failed — resolve it by hand"
        ok "now at $(git rev-parse --short HEAD) ($(git log -1 --pretty=%s))"
      fi
    elif [[ "$AHEAD" -gt 0 ]]; then
      ok "up to date with ${UPSTREAM}, plus ${AHEAD} local commit(s) to ship"
    else
      ok "up to date with ${UPSTREAM}"
    fi
  else
    # A branch with no upstream is normal for a throwaway test deploy; it is
    # only alarming on prod, where the branch gate above has already asked.
    warn "'$BRANCH' has no upstream — nothing to sync against, deploying local HEAD"
  fi
else
  warn "--no-pull: not checking whether origin has moved ahead of this tree"
fi

# ── 1b. Verify ─────────────────────────────────────────────────────────────
# Before ANY mutation — no version bump, no tag, no push, no backup. The images
# are built on the target, so a broken typecheck or a missing migration would
# otherwise be discovered by the production box, after it has already checked
# out the new tag. Failing here costs nothing and changes nothing.
if [[ "$SKIP_VERIFY" -eq 0 ]]; then
  VERIFY_FLAGS=()
  [[ "$VERIFY_QUICK" -eq 1 ]] && VERIFY_FLAGS+=(--quick)
  if [[ "$DRY" -eq 1 ]]; then
    info "[dry-run] would run: tools/verify.sh ${VERIFY_FLAGS[*]}"
  else
    "$TOOLS_DIR/verify.sh" "${VERIFY_FLAGS[@]+"${VERIFY_FLAGS[@]}"}" \
      || die "verification FAILED — refusing to deploy. Fix it, or accept the risk with --skip-verify."
  fi
else
  warn "--skip-verify: deploying a tree that has NOT been typechecked or build-tested"
  confirm "You are sure?" || die "aborted"
fi

# ── 2. Version ─────────────────────────────────────────────────────────────
[[ -f VERSION ]] || { echo "1.0.0" > VERSION; warn "created VERSION at 1.0.0"; }
CURRENT_VERSION="$(tr -d '[:space:]' < VERSION)"
info "current version: $CURRENT_VERSION"

bump_version() {
  local IFS=. ; read -r ma mi pa <<< "$1"
  case "$2" in
    major) ma=$((ma+1)); mi=0; pa=0 ;;
    minor) mi=$((mi+1)); pa=0 ;;
    patch) pa=$((pa+1)) ;;
  esac
  printf '%s.%s.%s' "$ma" "$mi" "$pa"
}

NEW_VERSION="$CURRENT_VERSION"
if [[ "$BUMP" != none ]]; then
  NEW_VERSION="$(bump_version "$CURRENT_VERSION" "$BUMP")"
  log "Bumping $BUMP: $CURRENT_VERSION -> $NEW_VERSION"
  if [[ "$DRY" -eq 0 ]]; then
    echo "$NEW_VERSION" > VERSION
    git add VERSION
    git commit -qm "Bump version to ${NEW_VERSION}"
    git tag -a "v${NEW_VERSION}" -m "Release ${NEW_VERSION}"
    ok "committed and tagged v${NEW_VERSION}"
  else
    info "[dry-run] would commit + tag v${NEW_VERSION}"
  fi
else
  info "no version bump"
fi

DEPLOY_REF="$(git rev-parse --short HEAD)"
[[ "$BUMP" != none ]] && DEPLOY_REF="v${NEW_VERSION}"
[[ "$DRY" -eq 1 && "$BUMP" != none ]] && DEPLOY_REF="$(git rev-parse --short HEAD)"

# Push before deploying: the remote pulls from the origin, so an unpushed tag
# is a deploy that silently ships the previous commit.
if [[ "$DRY" -eq 0 ]]; then
  log "Pushing commits and tags"
  git push --quiet || die "git push failed"
  git push --tags --quiet || die "git push --tags failed"
  ok "origin up to date"
else
  info "[dry-run] would git push && git push --tags"
fi

# ── 3. Pre-deploy backup ───────────────────────────────────────────────────
# The gate. Everything above this line is reversible with git; everything below
# it can run a migration.
if [[ "$SKIP_BACKUP" -eq 0 ]]; then
  hdr "Pre-deploy database backup"
  if [[ "$DRY" -eq 1 ]]; then
    info "[dry-run] would run: tools/db-backup.sh --target $TARGET_ARG --label predeploy"
  else
    "$TOOLS_DIR/db-backup.sh" --target "$TARGET_ARG" --label predeploy \
      || die "pre-deploy backup FAILED — refusing to deploy. Fix the backup, or accept the risk with --skip-backup."
  fi
else
  warn "--skip-backup: deploying with NO pre-deploy database backup"
  confirm "You are sure?" || die "aborted"
fi

# ── 4. Confirm ─────────────────────────────────────────────────────────────
echo
printf '  %-12s %s\n' "target"  "$TARGET_ARG ($SSH_HOST:$REMOTE_DIR)"
printf '  %-12s %s\n' "ref"     "$DEPLOY_REF"
printf '  %-12s %s\n' "branch"  "$BRANCH"
printf '  %-12s %s\n' "version" "$NEW_VERSION"
[[ "$TARGET_ARG" == prod ]] && printf '\n%s⚠  THIS IS PRODUCTION.%s\n' "$C_RED" "$C_OFF"
echo
confirm "Deploy?" || die "aborted"

# ── 5. Ship ────────────────────────────────────────────────────────────────
hdr "Deploying"

PREV_REMOTE_REF="$(rssh "cd ${REMOTE_DIR} && git rev-parse --short HEAD" 2>/dev/null || echo unknown)"
info "remote is currently at $PREV_REMOTE_REF"

log "Fetching ${DEPLOY_REF} on ${SSH_HOST}"
rrun "cd ${REMOTE_DIR} && git fetch --tags --prune --quiet && git checkout --quiet ${DEPLOY_REF} 2>/dev/null || (git checkout --quiet ${BRANCH} && git pull --quiet --ff-only)"

log "Building and starting the stack (this rebuilds the frontend; expect minutes)"
rrun "cd ${REMOTE_DIR} && ${COMPOSE_REMOTE} up -d --build"
reload_nginx

# ── 6. Health ──────────────────────────────────────────────────────────────
hdr "Health check"

deploy_failed() {
  warn "$1"
  echo
  if [[ "$ROLLBACK_ON_FAIL" -eq 1 ]]; then
    do_rollback
    die "deploy failed and was rolled back"
  fi
  warn "To roll back:"
  warn "  ./tools/deploy.sh --rollback --target ${TARGET_ARG}"
  warn "  ./tools/db-restore.sh latest --target ${TARGET_ARG}   # if a migration ran"
  die "deploy failed"
}

if [[ "$DRY" -eq 1 ]]; then
  info "[dry-run] would poll services and health URL for up to ${TIMEOUT}s"
else
  # Services first. `up -d --build` exits 0 even when a container starts and
  # immediately crash-loops, so "the command succeeded" proves nothing.
  sleep 10
  DEADLINE=$(( $(date +%s) + TIMEOUT ))
  read -r -a EXPECTED <<<"${DEPLOY_EXPECT_SERVICES:-$BACKEND_SERVICE}"
  while :; do
    BAD=""
    STATE="$(rssh "cd ${REMOTE_DIR} && ${COMPOSE_REMOTE} ps --format '{{.Service}} {{.State}}'" 2>/dev/null || true)"
    for svc in "${EXPECTED[@]}"; do
      line="$(grep -E "^${svc} " <<<"$STATE" || true)"
      [[ -z "$line" ]]            && { BAD="$BAD ${svc}:missing"; continue; }
      [[ "$line" == *running* ]]  || BAD="$BAD ${svc}:$(awk '{print $2}' <<<"$line")"
    done
    [[ -z "$BAD" ]] && break
    [[ "$(date +%s)" -ge "$DEADLINE" ]] && {
      echo "$STATE"
      rssh "cd ${REMOTE_DIR} && ${COMPOSE_REMOTE} logs --tail=40 ${EXPECTED[*]}" 2>/dev/null || true
      deploy_failed "services not healthy after ${TIMEOUT}s:${BAD}"
    }
    sleep 5
  done
  ok "all services running: ${EXPECTED[*]}"

  # Then the app itself. A container can be 'running' while gunicorn is
  # failing every request.
  if [[ -z "$HEALTH_URL" ]]; then
    ENV_FILE="$(pick_env_file)"
    HOSTNAME_GUESS="$(env_get "$ENV_KEY_ALLOWED_HOSTS" | cut -d, -f1)"
    [[ -n "$HOSTNAME_GUESS" && "$HOSTNAME_GUESS" != "*" ]] && HEALTH_URL="https://${HOSTNAME_GUESS}${HEALTH_PATH}"
  fi
  if [[ -n "$HEALTH_URL" ]]; then
    log "Polling $HEALTH_URL"
    DEADLINE=$(( $(date +%s) + 60 ))
    until curl -fsS -o /dev/null --max-time 10 "$HEALTH_URL"; do
      [[ "$(date +%s)" -ge "$DEADLINE" ]] && deploy_failed "health URL did not respond: $HEALTH_URL"
      sleep 5
    done
    ok "app responding at $HEALTH_URL"
    # The health path proxies to the BACKEND, so the poll above says nothing
    # about whatever serves `/` — the built frontend, usually behind the same
    # nginx. A deploy in which only that upstream was broken passes an API-only
    # gate green while the entire UI 502s. Probe the site root too.
    ROOT_URL="${HEALTH_URL%${HEALTH_PATH}}/"
    if [[ "$ROOT_URL" != "$HEALTH_URL" ]]; then
      log "Polling $ROOT_URL (site root)"
      DEADLINE=$(( $(date +%s) + 120 ))
      until curl -fsS -o /dev/null --max-time 10 "$ROOT_URL"; do
        [[ "$(date +%s)" -ge "$DEADLINE" ]] && deploy_failed "the site root did not serve ${ROOT_URL} (nginx 502 → stale upstream address, or the web container crashed)"
        sleep 5
      done
      ok "site root responding at $ROOT_URL"
    fi
  else
    # The loopback-bound backend port is there even without a public hostname.
    DJP="$(env_get "$ENV_KEY_BACKEND_PORT")"; DJP="${DJP:-$DEFAULT_BACKEND_PORT}"
    if rssh "curl -fsS -o /dev/null --max-time 10 http://127.0.0.1:${DJP}${HEALTH_PATH}"; then
      ok "the backend answers on the remote loopback :${DJP}"
    else
      warn "could not confirm the app responds (no --health-url and loopback probe failed)"
      warn "check manually, then consider passing --health-url next time"
    fi
  fi
fi

# ── 7. Summary ─────────────────────────────────────────────────────────────
hdr "Deployed"
info "target   $TARGET_ARG ($SSH_HOST)"
info "version  $NEW_VERSION  ($DEPLOY_REF)"
info "was at   $PREV_REMOTE_REF"
if   [[ "$SKIP_VERIFY" -eq 1 ]];  then info "verify   SKIPPED"
elif [[ "$VERIFY_QUICK" -eq 1 ]]; then info "verify   quick (no smoke, no image build)"
else info "verify   full"; fi
if   [[ "$DRY" -eq 1 ]];          then info "backup   (dry-run — none taken)"
elif [[ "$SKIP_BACKUP" -eq 1 ]];  then info "backup   SKIPPED"
else info "backup   $(basename "$(latest_backup "$TARGET_ARG")")"; fi
echo
info "logs      ssh $SSH_HOST 'cd ${REMOTE_DIR} && ${COMPOSE_REMOTE} logs -f --tail=100'"
info "rollback  ./tools/deploy.sh --rollback --target ${TARGET_ARG}"
