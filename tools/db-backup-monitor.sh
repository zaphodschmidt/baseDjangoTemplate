#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/db-backup-monitor.sh — is the backup system actually working?
#
# A backup script that silently stopped running looks exactly like one that
# never had a problem, so this is the piece that turns "we have backups" into
# something checkable. Designed to be run by hand OR from cron/monitoring: it
# exits non-zero when something is wrong, so it can drive an alert.
#
# Usage:
#   ./tools/db-backup-monitor.sh                    # all targets that have backups
#   ./tools/db-backup-monitor.sh --target prod
#   ./tools/db-backup-monitor.sh --max-age-hours 48 --quiet
#
# Flags:
#   -t, --target local|prod|test|all   (default: all)
#       --max-age-hours N              Stale threshold        (default: 26)
#       --min-count N                  Alert below this many  (default: 2)
#       --min-free-gb N                Alert below this much free disk (default: 5)
#       --quiet                        Only print problems
#   -h, --help
#
# Exit: 0 healthy · 1 WARN (aging / thin / low disk) · 2 CRITICAL (no backups,
#       stale past 2x the threshold, or a checksum that no longer matches)
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

WHICH="all"; MAX_AGE_H=26; MIN_COUNT=2; MIN_FREE_GB=5; QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)      WHICH="$2"; shift 2 ;;
    --max-age-hours)  MAX_AGE_H="$2"; shift 2 ;;
    --min-count)      MIN_COUNT="$2"; shift 2 ;;
    --min-free-gb)    MIN_FREE_GB="$2"; shift 2 ;;
    --quiet)          QUIET=1; shift ;;
    -h|--help)        sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

STATUS=0
bump() { [[ "$1" -gt "$STATUS" ]] && STATUS="$1"; return 0; }
say()  { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"; }

if [[ "$WHICH" == all ]]; then TARGETS=(local prod test); else TARGETS=("$WHICH"); fi

[[ "$QUIET" -eq 1 ]] || hdr "$PROJECT_NAME backup monitor  ($(date -Iseconds))"

# ── Disk headroom for the backup root ──────────────────────────────────────
# Checked once, up front: a full disk is the single most common way a backup
# cron dies quietly, and it fails every target at the same time.
if [[ -d "$BACKUP_ROOT" ]]; then
  FREE_KB="$(df -Pk "$BACKUP_ROOT" | awk 'NR==2 {print $4}')"
  FREE_GB=$(( FREE_KB / 1024 / 1024 ))
  USED="$(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)"
  if [[ "$FREE_GB" -lt "$MIN_FREE_GB" ]]; then
    warn "only ${FREE_GB}GB free on the backup volume (threshold ${MIN_FREE_GB}GB)"; bump 1
  else
    say "  disk: ${FREE_GB}GB free, backups occupy ${USED}"
  fi
else
  warn "backup root does not exist: $BACKUP_ROOT"; bump 2
fi

# ── Per target ─────────────────────────────────────────────────────────────
ANY=0
for t in "${TARGETS[@]}"; do
  dir="$(backup_dir_for "$t")"
  shopt -s nullglob; files=("$dir"/"${BACKUP_PREFIX}"_*.dump); shopt -u nullglob

  # With --target all we don't know which targets this box is even supposed to
  # back up. An empty directory for a target you never use is not a failure;
  # only an explicitly-named empty target is.
  if [[ ${#files[@]} -eq 0 ]]; then
    if [[ "$WHICH" != all ]]; then
      printf '%s[CRITICAL]%s no backups at all for target "%s" (%s)\n' "$C_RED" "$C_OFF" "$t" "$dir" >&2
      bump 2
    fi
    continue
  fi
  ANY=1

  latest="$(ls -1t "$dir"/"${BACKUP_PREFIX}"_*.dump | head -1)"
  age_h=$(( ( $(date +%s) - $(stat -c %Y "$latest") ) / 3600 ))
  count=${#files[@]}
  size="$(du -sh "$dir" | cut -f1)"

  say ""
  say "  target: $t"
  say "    latest : $(basename "$latest")  ($(human_size "$latest"))"
  say "    age    : ${age_h}h"
  say "    count  : ${count} archive(s), ${size} total"

  if   [[ "$age_h" -gt $(( MAX_AGE_H * 2 )) ]]; then
    printf '%s[CRITICAL]%s %s: newest backup is %sh old (>%sh)\n' "$C_RED" "$C_OFF" "$t" "$age_h" "$(( MAX_AGE_H * 2 ))" >&2; bump 2
  elif [[ "$age_h" -gt "$MAX_AGE_H" ]]; then
    printf '%s[WARN]%s %s: newest backup is %sh old (>%sh)\n' "$C_YELLOW" "$C_OFF" "$t" "$age_h" "$MAX_AGE_H" >&2; bump 1
  fi

  [[ "$count" -lt "$MIN_COUNT" ]] && {
    printf '%s[WARN]%s %s: only %s archive(s) retained (want >=%s)\n' "$C_YELLOW" "$C_OFF" "$t" "$count" "$MIN_COUNT" >&2; bump 1; }

  # Integrity of the newest archive. Cheap (sha256 of one file) and it is the
  # one check that catches silent bit-rot or a truncated transfer — the failure
  # mode where you find out during the restore you're doing at 3am.
  meta="${latest}.meta"
  if [[ -f "$meta" ]]; then
    want="$(grep -m1 '^sha256=' "$meta" | cut -d= -f2- || true)"
    if [[ -n "$want" ]]; then
      have="$(sha256sum "$latest" | cut -d' ' -f1)"
      if [[ "$have" == "$want" ]]; then
        say "    sha256 : ok"
      else
        printf '%s[CRITICAL]%s %s: newest archive no longer matches its recorded sha256 — it is corrupt\n' "$C_RED" "$C_OFF" "$t" >&2
        bump 2
      fi
    fi
  else
    printf '%s[WARN]%s %s: newest archive has no .meta sidecar (written by an older tool?)\n' "$C_YELLOW" "$C_OFF" "$t" >&2; bump 1
  fi

  # Label breakdown — makes it obvious when the nightly 'auto' job has stopped
  # but somebody's manual backups are keeping the age check green.
  if [[ "$QUIET" -eq 0 ]]; then
    printf '    labels : '
    for f in "${files[@]}"; do label_of "$f"; done | sort | uniq -c | awk '{printf "%s=%s  ", $2, $1}'
    printf '\n'
  fi
done

# ── Scheduled job present? ─────────────────────────────────────────────────
CRON_LINES="$(crontab -l 2>/dev/null | grep -c 'db-backup.sh' || true)"
if [[ "${CRON_LINES:-0}" -eq 0 ]]; then
  printf '%s[WARN]%s no db-backup.sh entry in crontab — nothing is running automatically (./tools/db-backup-cron.sh install)\n' "$C_YELLOW" "$C_OFF" >&2
  bump 1
else
  say ""
  say "  cron   : ${CRON_LINES} scheduled backup job(s)"
fi

[[ "$ANY" -eq 0 && "$WHICH" == all ]] && { printf '%s[CRITICAL]%s no backups found for any target\n' "$C_RED" "$C_OFF" >&2; bump 2; }

case "$STATUS" in
  0) [[ "$QUIET" -eq 1 ]] || { echo; ok "backup system healthy"; } ;;
  1) echo; warn "backup system DEGRADED" ;;
  2) echo; printf '%s[CRITICAL]%s backup system is NOT protecting you\n' "$C_RED" "$C_OFF" >&2 ;;
esac
exit "$STATUS"
