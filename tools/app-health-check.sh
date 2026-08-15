#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/app-health-check.sh — the production watchdog, tracked and targeted.
#
# It exists because of the watchdog it replaces: an untracked script on the
# server whose only recovery was, on ANY health failure:
#
#     docker compose down && systemctl restart postgresql && up -d --build
#
# That turned a single leaking container into a repeating site-wide outage. A
# background worker leaked Postgres connections until it held all 100 slots;
# the web container then could not connect and crash-looped; the watchdog saw
# 502 and "recovered" by rebuilding every image, restarting the database under
# every healthy client, and starting the leaking worker again — which refilled
# all 100 slots in about four minutes. It ran that loop every 15 minutes
# instead of fixing anything.
#
# What this version does differently:
#   * DIAGNOSES before acting, and always logs the connection census. The
#     census is what identified the culprit in minutes; the old script threw
#     that evidence away by restarting everything.
#   * Acts NARROWLY: restart the one container that is hogging connection
#     slots, or the ones that aren't running. Escalate only if that failed.
#   * Never restarts PostgreSQL. It is shared by every client on the box, and
#     an app-level leak is not a database fault.
#   * Never rebuilds images. A rebuild is a deploy (tools/deploy.sh), not a
#     recovery — it is slow, needs a clean tree, and can fail with the stack
#     down.
#   * Has a COOLDOWN. If it already intervened recently and things are broken
#     again, it stops and fails loudly instead of flapping. A watchdog that
#     hides a recurring fault is worse than no watchdog.
#
# Runs ON the server, from a systemd timer, so it is deliberately standalone —
# it sources nothing from tools/lib and configures itself from the environment:
#
#   HEALTH_URL   what to poll                    (required)
#   REPO_DIR     the checkout on that box
#   COMPOSE_FILE the production compose file, relative to REPO_DIR
#   ENV_FILE     the env file compose is invoked with
#   APP_CONTAINERS  space-separated, most disposable first, NEVER the database
#
# Install it as a timer (see tools/README.md § The watchdog) rather than cron:
# systemd records a failed unit, and a watchdog whose failures are invisible is
# the failure mode this file exists to prevent.
#
# Exit codes: 0 healthy (or recovered), 1 still unhealthy (systemd records the
# failure and the log says what was tried).
# ---------------------------------------------------------------------------
set -uo pipefail

HEALTH_URL="${HEALTH_URL:?set HEALTH_URL to the health endpoint of the app itself}"
REPO_DIR="${REPO_DIR:-$HOME/app}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"
ENV_FILE="${ENV_FILE:-.env}"
LOG_FILE="${LOG_FILE:-$HOME/app_health_check.log}"
STATE_FILE="${STATE_FILE:-$HOME/.app-health-check.state}"

ATTEMPTS="${ATTEMPTS:-3}"          # probes before we call it unhealthy
INTERVAL="${INTERVAL:-20}"         # seconds between probes
TIMEOUT="${TIMEOUT:-30}"           # per-probe curl timeout
COOLDOWN="${COOLDOWN:-3600}"       # seconds before we're willing to act again
HOG_SHARE="${HOG_SHARE:-50}"       # % of max_connections that marks a hog
SETTLE="${SETTLE:-25}"             # seconds to wait after a restart

# App containers, most disposable first. The DATABASE is deliberately absent:
# it is shared by every client on the box, and an app-level leak is not a
# database fault.
read -r -a APP_CONTAINERS <<<"${APP_CONTAINERS:-backend nginx}"

log() { printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE"; }

probe() { # 0 iff the app answers 200
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$HEALTH_URL" 2>/dev/null)"
  [[ "$code" == "200" ]]
}

healthy_after_settle() {
  sleep "$SETTLE"
  probe
}

# ── Diagnosis ──────────────────────────────────────────────────────────────
# Read the census from process titles, NOT from psql: when the slots are full,
# psql cannot connect either (the app role is a superuser here, so it eats the
# superuser reserve too). `ps` always works.
max_connections() {
  sudo -n grep -hoP '^\s*max_connections\s*=\s*\K[0-9]+' \
    /etc/postgresql/*/main/postgresql.conf 2>/dev/null | tail -1
}

# Emits "<count> <container>" per client, busiest first.
census() {
  local ip name counts
  counts="$(ps -C postgres -o args= 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq -c | sort -rn)"
  [[ -z "$counts" ]] && return 0
  while read -r n ip; do
    [[ -z "${n:-}" ]] && continue
    # Match the address as a LITERAL, not a regex: the dots in an awk regex are
    # wildcards, so 172.18.0.4 would also match 172.18.0.41 and name the wrong
    # container — which is the one thing this function exists to get right.
    name="$(sudo -n docker ps -q 2>/dev/null | while read -r c; do
              sudo -n docker inspect -f \
                '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$c"
            done | awk -v want=" $ip " 'index(" " $0 " ", want) {print substr($1,2); exit}')"
    printf '%s %s\n' "$n" "${name:-$ip}"
  done <<< "$counts"
}

not_running() { # app containers that exist in compose but aren't up
  local up c out=()
  up="$(sudo -n docker ps --format '{{.Names}}' 2>/dev/null)"
  for c in "${APP_CONTAINERS[@]}"; do
    grep -qx "$c" <<< "$up" || out+=("$c")
  done
  printf '%s\n' "${out[@]}"
}

restart_container() {
  log "  → restarting container: $1"
  sudo -n docker restart "$1" >/dev/null 2>&1 \
    || (cd "$REPO_DIR" && sudo -n docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d "$1" >/dev/null 2>&1)
}

# ── Probe ──────────────────────────────────────────────────────────────────
for i in $(seq 1 "$ATTEMPTS"); do
  if probe; then
    [[ "$i" -gt 1 ]] && log "healthy on attempt $i"
    rm -f "$STATE_FILE"
    exit 0
  fi
  log "health probe $i/$ATTEMPTS failed ($HEALTH_URL)"
  [[ "$i" -lt "$ATTEMPTS" ]] && sleep "$INTERVAL"
done

log "UNHEALTHY after $ATTEMPTS probes — diagnosing before touching anything"

MAXC="$(max_connections)"; MAXC="${MAXC:-100}"
TOTAL="$(ps -C postgres -o args= 2>/dev/null | grep -cE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
log "postgres: ${TOTAL:-0}/${MAXC} connections in use"
while read -r n who; do
  [[ -n "${n:-}" ]] && log "  ${n} connections  ${who}"
done <<< "$(census)"

# ── Cooldown: refuse to flap ───────────────────────────────────────────────
NOW="$(date +%s)"
if [[ -f "$STATE_FILE" ]]; then
  LAST="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
  if (( NOW - LAST < COOLDOWN )); then
    log "ALREADY intervened $(( (NOW - LAST) / 60 ))m ago and it is broken again."
    log "NOT restarting: this is a recurring fault that needs a human, and"
    log "restarting on a loop would only hide it. Census above names the culprit."
    exit 1
  fi
fi

# ── Narrowest effective action ─────────────────────────────────────────────
ACTED=0

# 1. A single container hogging the connection pool: restart just that one.
HOG_LINE="$(census | head -1)"
HOG_N="$(awk '{print $1}' <<< "$HOG_LINE")"
HOG_WHO="$(awk '{print $2}' <<< "$HOG_LINE")"
if [[ -n "${HOG_N:-}" ]] && (( HOG_N * 100 / MAXC >= HOG_SHARE )); then
  log "$HOG_WHO holds $HOG_N/$MAXC connections (>= ${HOG_SHARE}%) — it is the fault, not the victim"
  if printf '%s\n' "${APP_CONTAINERS[@]}" | grep -qx "$HOG_WHO"; then
    restart_container "$HOG_WHO"; ACTED=1
    echo "$NOW" > "$STATE_FILE"
    if healthy_after_settle; then log "RECOVERED by restarting $HOG_WHO alone"; exit 0; fi
  else
    log "  (not an app container — leaving it alone)"
  fi
fi

# 2. Containers that simply aren't running.
DOWN="$(not_running | grep -v '^$')"
if [[ -n "$DOWN" ]]; then
  log "not running: $(tr '\n' ' ' <<< "$DOWN")"
  while read -r c; do [[ -n "$c" ]] && restart_container "$c"; done <<< "$DOWN"
  ACTED=1; echo "$NOW" > "$STATE_FILE"
  if healthy_after_settle; then log "RECOVERED by starting the stopped containers"; exit 0; fi
fi

# 3. Escalate: restart the app containers in place. Still no rebuild, and the
#    database is left alone.
log "escalating: restarting all app containers (postgres untouched, no rebuild)"
for c in "${APP_CONTAINERS[@]}"; do restart_container "$c"; done
echo "$NOW" > "$STATE_FILE"
if healthy_after_settle; then log "RECOVERED by restarting the app containers"; exit 0; fi

log "STILL UNHEALTHY after intervention (acted=$ACTED). Needs a human."
log "Start here:  cd $REPO_DIR && sudo docker compose -f $COMPOSE_FILE logs --tail=100"
exit 1
