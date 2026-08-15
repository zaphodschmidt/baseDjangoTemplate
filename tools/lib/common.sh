#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/lib/common.sh — shared plumbing for every script in tools/.
#
# Sourced, never executed. Everything here is the stuff that would otherwise be
# copy-pasted into six scripts and then drift: env parsing, logging, and — the
# real reason this file exists — the TARGET ABSTRACTION.
#
# A project has two Postgres topologies and they are not interchangeable:
#
#   local  containerized. The $DB_SERVICE container from $COMPOSE_LOCAL.
#          Auth: the DB user/password in .env.
#   prod   HOST postgres on the server, port 5432, NO container. Reached over
#   test   ssh ($PROD_SSH / $TEST_SSH) and driven as the peer-auth `postgres`
#          superuser — no password anywhere.
#
# Every script below talks to a target through tgt_* functions only, so the
# same backup/restore/monitor logic works against all three. Crucially, pg_dump
# and pg_restore always run ON the target: a client older than the server
# refuses the dump outright, and the two boxes drift apart the moment one is
# upgraded. Running them on the far side also means the verification pass uses
# a pg_restore that actually understands the archive it just wrote.
#
# Everything project-specific lives in tools/project.env, not here.
# ---------------------------------------------------------------------------

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$TOOLS_DIR/.." && pwd)"

# shellcheck source=/dev/null
[[ -f "$TOOLS_DIR/project.env" ]] && source "$TOOLS_DIR/project.env"

BACKUP_ROOT="${BACKUP_ROOT:-$REPO_DIR/backups}"
COMPOSE_LOCAL="$REPO_DIR/${COMPOSE_LOCAL:-docker-compose.yml}"
COMPOSE_PROD="$REPO_DIR/${COMPOSE_PROD:-docker-compose.prod.yml}"

# A remote target deploys and restores through the production compose file. It
# is not in this template, so say so once, clearly, instead of failing later
# with a compose error nobody can map back to a missing file.
require_prod_compose() {
  [[ -f "$COMPOSE_PROD" ]] || die "$(basename "$COMPOSE_PROD") does not exist.
       Remote targets (--target prod|test) need a production compose file.
       Create it, or set COMPOSE_PROD in tools/project.env. See tools/README.md."
}

# ── Logging ────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'; C_CYAN=$'\033[0;36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_BLUE=''; C_YELLOW=''; C_RED=''; C_GREEN=''; C_CYAN=''; C_DIM=''; C_OFF=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE"   "$C_OFF" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN"  "$C_OFF" "$*"; }
info() { printf '%s    %s%s\n' "$C_DIM"    "$*"     "$C_OFF"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
hdr()  { printf '\n%s%s%s\n' "$C_CYAN" "$*" "$C_OFF"; }

# Trim leading/trailing whitespace only — keeps the spaces inside values like
# "18.4 (Ubuntu 18.4-1.pgdg24.04+1)".
trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

confirm() {
  local prompt="$1"
  [[ "${ASSUME_YES:-0}" -eq 1 ]] && return 0
  local ans
  read -r -p "$prompt [y/N] " ans || true
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

need_bin() {
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || die "$b not found in PATH"
  done
}

# ── .env parsing ───────────────────────────────────────────────────────────
# Values may be single-quoted, double-quoted, or bare with a trailing
# "# comment". One parser, so every script agrees on what .env says.
pick_env_file() {
  if   [[ -n "${ENV_FILE:-}" ]]; then :
  elif [[ -f "$REPO_DIR/.env.local" ]]; then ENV_FILE="$REPO_DIR/.env.local"
  elif [[ -f "$REPO_DIR/.env" ]];       then ENV_FILE="$REPO_DIR/.env"
  else ENV_FILE=""; fi
  printf '%s' "$ENV_FILE"
}

env_get() {
  local key="$1" raw
  [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]] || return 0
  raw="$(grep -m1 "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '\r')" || true
  [[ -n "$raw" ]] || return 0
  if   [[ "$raw" =~ ^\'([^\']*)\' ]]; then printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^\"([^\"]*)\" ]]; then printf '%s' "${BASH_REMATCH[1]}"
  else printf '%s' "$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$raw")"
  fi
}

# ── docker, with or without sudo ───────────────────────────────────────────
# Resolved once. Override with DOCKER="docker" on a box where you're in the
# docker group.
resolve_docker() {
  if [[ -n "${DOCKER:-}" ]]; then return 0; fi
  if docker ps >/dev/null 2>&1; then DOCKER="docker"
  elif sudo -n docker ps >/dev/null 2>&1; then DOCKER="sudo docker"
  elif command -v docker >/dev/null 2>&1; then DOCKER="sudo docker"
  else die "docker not found in PATH"; fi
  export DOCKER
}
dock() { resolve_docker; $DOCKER "$@"; }

# ── Target resolution ──────────────────────────────────────────────────────
# Sets: TARGET, TGT_KIND (container|ssh), TGT_SSH, DB_NAME, DB_USER,
#       TGT_CONTAINER (container kind), PG_SUPERUSER (ssh kind).
PROD_SSH_DEFAULT="${PROD_SSH:-prod-app}"
TEST_SSH_DEFAULT="${TEST_SSH:-test-app}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"

resolve_target() {
  TARGET="${1:-local}"
  # The prod-compose check runs FIRST for remote targets. It is the one that
  # says "this template does not ship a production stack yet", and reporting a
  # missing env key instead would send you off editing .env for a target that
  # was never going to work.
  if [[ "$TARGET" == prod || "$TARGET" == test ]]; then require_prod_compose; fi

  ENV_FILE="$(pick_env_file)"
  DB_NAME="${DB_NAME:-$(env_get "$ENV_KEY_DB_NAME")}"
  [[ -n "$DB_NAME" ]] || die "$ENV_KEY_DB_NAME missing in ${ENV_FILE:-<no env file>} (set ENV_KEY_DB_NAME in tools/project.env if your key is named differently)"

  case "$TARGET" in
    local)
      TGT_KIND="container"
      DB_USER="${DB_USER:-$(env_get "$ENV_KEY_DB_USER")}"
      [[ -n "$DB_USER" ]] || die "$ENV_KEY_DB_USER missing in ${ENV_FILE:-<no env file>}"
      TGT_CONTAINER="$(dock compose -f "$COMPOSE_LOCAL" ps -q "$DB_SERVICE" 2>/dev/null | head -1)"
      if [[ -z "$TGT_CONTAINER" ]]; then
        # Compose can't see it (different project dir, or the stack is down but
        # the container exists). Fall back to the literal container name.
        TGT_CONTAINER="$(dock ps -aq --filter "name=${DB_SERVICE}" 2>/dev/null | head -1)"
      fi
      [[ -n "$TGT_CONTAINER" ]] || die "local postgres container not found — start it with: $DOCKER compose -f $(basename "$COMPOSE_LOCAL") up -d $DB_SERVICE"
      ;;
    prod|test)
      TGT_KIND="ssh"
      TGT_SSH="$([[ "$TARGET" == prod ]] && printf '%s' "$PROD_SSH_DEFAULT" || printf '%s' "$TEST_SSH_DEFAULT")"
      DB_USER="$PG_SUPERUSER"
      need_bin ssh
      ;;
    *) die "unknown target '$TARGET' (expected: local | prod | test)" ;;
  esac
  export TARGET TGT_KIND DB_NAME DB_USER
}

# Fail fast and with a useful message BEFORE moving any data.
assert_target_reachable() {
  case "$TGT_KIND" in
    container)
      dock ps --format '{{.ID}}' | grep -q "^${TGT_CONTAINER:0:12}" \
        || die "postgres container is not running — $DOCKER compose -f $(basename "$COMPOSE_LOCAL") up -d $DB_SERVICE"
      dock exec "$TGT_CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 \
        || die "postgres container is up but not accepting connections for ${DB_USER}/${DB_NAME}"
      ;;
    ssh)
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$TGT_SSH" true \
        || die "cannot ssh to '${TGT_SSH}' — check ~/.ssh/config and key auth (tools/project.env sets the alias)"
      ssh -o BatchMode=yes "$TGT_SSH" "sudo -n -u $PG_SUPERUSER true" 2>/dev/null \
        || die "passwordless 'sudo -u ${PG_SUPERUSER}' does not work on '${TGT_SSH}' — needed for peer-auth pg_dump"
      ;;
  esac
}

# ── Uniform psql/pg_dump/pg_restore over the resolved target ───────────────
# tgt_psql <sql>            -> one scalar, trimmed
# tgt_exec <shell command>  -> run a command in the target's postgres context
# NOTE: `bash -c`, never `bash -lc`. A login shell sources profile scripts, and
# anything they echo lands in stdout — which for tgt_stream_out is the backup
# archive itself. pg_* are on the default PATH in both contexts anyway.
tgt_exec() {
  case "$TGT_KIND" in
    container) dock exec -i "$TGT_CONTAINER" bash -c "$1" ;;
    ssh)       ssh -o BatchMode=yes "$TGT_SSH" "sudo -n -u $PG_SUPERUSER bash -c $(printf '%q' "$1")" ;;
  esac
}

# Binary-safe copy of a file on the target to our stdout. Used to pull the
# archive back; keep it free of any shell that might prepend a byte.
tgt_stream_out() {
  case "$TGT_KIND" in
    container) dock exec -i "$TGT_CONTAINER" cat "$1" ;;
    ssh)       ssh -o BatchMode=yes "$TGT_SSH" "sudo -n -u $PG_SUPERUSER cat $(printf '%q' "$1")" ;;
  esac
}

# ...and the reverse, for restore: our stdin -> a file on the target.
tgt_stream_in() {
  case "$TGT_KIND" in
    container) dock exec -i "$TGT_CONTAINER" bash -c "cat > $(printf '%q' "$1")" ;;
    ssh)       ssh -o BatchMode=yes "$TGT_SSH" "sudo -n -u $PG_SUPERUSER bash -c $(printf '%q' "cat > $(printf '%q' "$1")")" ;;
  esac
}

tgt_psql() {
  local sql="$1"
  trim "$(tgt_exec "psql -U $(printf '%q' "$DB_USER") -d $(printf '%q' "$DB_NAME") -tAc $(printf '%q' "$sql")" 2>/dev/null || true)"
}

# psql against the maintenance db, for DROP/CREATE DATABASE.
tgt_psql_maint() {
  local sql="$1"
  tgt_exec "psql -U $(printf '%q' "$DB_USER") -d postgres -v ON_ERROR_STOP=1 -c $(printf '%q' "$sql")"
}

tgt_server_version() { tgt_psql "show server_version"; }
tgt_db_size()        { tgt_psql "select pg_size_pretty(pg_database_size('${DB_NAME}'))"; }
tgt_table_count()    { tgt_psql "select count(*) from pg_stat_user_tables"; }
tgt_db_exists()      { [[ "$(tgt_psql "select 1 from pg_database where datname='${DB_NAME}'")" == "1" ]]; }

# ── Compose control on the target ──────────────────────────────────────────
# Local uses $COMPOSE_LOCAL here in the repo; prod/test use $COMPOSE_PROD in
# the checkout on that box.
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-~/app}"
REMOTE_ENV_FILE="${REMOTE_ENV_FILE:-.env}"
read -r -a APP_SERVICES_LOCAL_ARR <<<"${APP_SERVICES_LOCAL:-backend}"
read -r -a APP_SERVICES_PROD_ARR  <<<"${APP_SERVICES_PROD:-backend}"

tgt_compose() {
  case "$TGT_KIND" in
    container) dock compose -f "$COMPOSE_LOCAL" "$@" ;;
    ssh)       ssh -o BatchMode=yes "$TGT_SSH" \
                 "cd ${REMOTE_REPO_DIR} && sudo -n docker compose -f $(basename "$COMPOSE_PROD") --env-file ${REMOTE_ENV_FILE} $*" ;;
  esac
}

tgt_app_services() {
  if [[ "$TGT_KIND" == container ]]; then printf '%s\n' "${APP_SERVICES_LOCAL_ARR[@]}"
  else printf '%s\n' "${APP_SERVICES_PROD_ARR[@]}"; fi
}

# Stop only the services that are actually running, and echo them so the caller
# can start exactly those back up (never more).
tgt_app_stop_running() {
  local running=() svc names
  names="$(tgt_compose ps --services --filter status=running 2>/dev/null || true)"
  while read -r svc; do
    [[ -n "$svc" ]] || continue
    grep -qx "$svc" <<<"$names" && running+=("$svc")
  done < <(tgt_app_services)
  if [[ ${#running[@]} -gt 0 ]]; then
    tgt_compose stop "${running[@]}" >/dev/null 2>&1 || warn "could not stop ${running[*]}; continuing"
  fi
  printf '%s\n' "${running[@]:-}"
}

tgt_app_start() {
  local svcs=("$@")
  [[ ${#svcs[@]} -gt 0 ]] || return 0
  tgt_compose start "${svcs[@]}" >/dev/null 2>&1 \
    || warn "could not restart ${svcs[*]} — bring them up manually"
}

# ── Source abstraction: pulling data FROM a live server ────────────────────
# resolve_target says where we WRITE. This says where the data COMES FROM, and
# it exists so the two refresh scripts stop carrying their own tunnel/ssh
# logic. Only ssh-kind sources exist (prod, test): a refresh always pulls from
# a host Postgres reached over ssh and driven as the peer-auth superuser.
#
# pg_dump runs ON the source for the same reason it runs on the target — a
# client older than the server aborts with a version mismatch before writing a
# byte. It also means NO PASSWORD is involved at any point: peer auth as
# `postgres` needs no secret, so there is nothing to prompt for and nothing to
# get wrong. A tunnel-and-prompt path instead asks for a password that exists
# only in the server's own env file, which nobody can type from here.
pg_major() { local v="${1%%.*}"; printf '%s' "${v//[!0-9]/}"; }

src_resolve() {
  SRC="${1:-prod}"
  case "$SRC" in
    prod) SRC_SSH="$PROD_SSH_DEFAULT" ;;
    test) SRC_SSH="$TEST_SSH_DEFAULT" ;;
    *) die "unknown source '$SRC' (expected: prod | test)" ;;
  esac
  SRC_DB="${SRC_DB:-${DB_NAME:-}}"
  [[ -n "$SRC_DB" ]] || die "no source database name — set SRC_DB or $ENV_KEY_DB_NAME"
  export SRC SRC_SSH SRC_DB
}

src_assert_reachable() {
  need_bin ssh
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$SRC_SSH" true \
    || die "cannot ssh to '${SRC_SSH}' — check ~/.ssh/config and key auth (tools/project.env sets the alias)"
  ssh -o BatchMode=yes "$SRC_SSH" "sudo -n -u $PG_SUPERUSER true" 2>/dev/null \
    || die "passwordless 'sudo -u ${PG_SUPERUSER}' does not work on '${SRC_SSH}' — needed for the peer-auth pg_dump"
}

src_psql() {
  trim "$(ssh -o BatchMode=yes "$SRC_SSH" \
    "sudo -n -u $PG_SUPERUSER psql -d $(printf '%q' "$SRC_DB") -tAc $(printf '%q' "$1")" 2>/dev/null || true)"
}
src_server_version() { src_psql 'show server_version'; }
src_db_size()        { src_psql "select pg_size_pretty(pg_database_size('${SRC_DB}'))"; }
src_table_count()    { src_psql 'select count(*) from pg_stat_user_tables'; }

# Stream a custom-format archive from the source straight into a local file.
# Nothing is written on the source (stdout stream), so no postgres-owned temp
# file is ever left behind on a production box. The file is created 0600 first:
# it is a complete copy of the production database and must not land
# world-readable in /tmp.
src_dump_to() {
  local out="$1"
  install -m 600 /dev/null "$out" || die "cannot create $out"
  ssh -o BatchMode=yes "$SRC_SSH" \
    "sudo -n -u $PG_SUPERUSER pg_dump -d $(printf '%q' "$SRC_DB") -Fc --no-owner --no-privileges" > "$out" \
    || die "pg_dump on ${SRC_SSH} failed — nothing on the target was touched"
  [[ -s "$out" ]] || die "dump is empty — pg_dump on ${SRC_SSH} produced no output"
}

# Write the .meta sidecar db-restore.sh reads. Without it a refresh archive has
# no recorded server_version, so db-restore.sh's major-DOWNGRADE guard silently
# never fires — the one check that matters most when pulling a PG18 prod dump
# onto a box whose container is still PG16.
write_source_meta() {
  local out="$1" ver="$2" size="$3" tables="$4" sum
  sum="$(sha256sum "$out" | cut -d' ' -f1)"
  cat > "${out}.meta" <<META
target=$SRC
label=refresh
database=$SRC_DB
taken=$(date -Iseconds)
server_version=$ver
source_size=$size
source_tables=$tables
archive_bytes=$(stat -c %s "$out")
sha256=$sum
sql_copy=none
repo_commit=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
repo_tag=$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || echo none)
taken_by=${USER:-unknown}@$(hostname -s 2>/dev/null || echo unknown)
restore_cmd=./tools/db-restore.sh full $out --target <local|test>
META
  chmod 600 "${out}.meta"
}

# ── Backup file naming ─────────────────────────────────────────────────────
# <prefix>_<target>_<label>_<YYYYmmdd_HHMMSS>.dump  (+ .meta sidecar)
# The label is load-bearing: pruning treats scheduled 'auto' backups and
# deliberate ones (predeploy, safety, manual) as different retention classes.
BACKUP_PREFIX="${BACKUP_PREFIX:-app}"

backup_dir_for() { printf '%s/%s' "$BACKUP_ROOT" "${1:-local}"; }

backup_stem() { printf '%s_%s_%s_%s' "$BACKUP_PREFIX" "$1" "$2" "$3"; }

# Every archive for a target, newest first. One definition, so a change to the
# naming scheme cannot leave one script globbing for the old shape.
backup_glob() { printf '%s/%s_*.dump' "$(backup_dir_for "$1")" "$BACKUP_PREFIX"; }

# Parse the label back out of a filename. app_prod_predeploy_2026....dump
label_of() {
  local b; b="$(basename "$1")"
  b="${b#"${BACKUP_PREFIX}"_}"; b="${b#*_}"   # strip prefix, then "<target>_"
  printf '%s' "${b%%_*}"
}

latest_backup() {
  local dir; dir="$(backup_dir_for "$1")"
  ls -1t "$dir"/"${BACKUP_PREFIX}"_*.dump 2>/dev/null | head -1 || true
}

human_size() {
  local b; b="$(stat -c %s "$1" 2>/dev/null)" || return 0
  [[ -n "$b" ]] || return 0
  numfmt --to=iec --format='%.1f' "$b" 2>/dev/null || printf '%s bytes' "$b"
}
