#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/db-backup-cron.sh — install / inspect / remove the scheduled backups.
#
# Manages a fenced block in the current user's crontab, so `remove` takes out
# exactly what `install` put in and never touches your other jobs. Re-running
# install is idempotent: it replaces the block rather than appending a second
# copy (the classic way a machine ends up running four backups a night).
#
# Usage:
#   ./tools/db-backup-cron.sh install                  # local nightly + weekly monitor
#   ./tools/db-backup-cron.sh install --target prod --hour 3
#   ./tools/db-backup-cron.sh status
#   ./tools/db-backup-cron.sh remove
#
# Flags (install):
#   -t, --target local|prod|test   What to back up        (default: local)
#       --hour N                   Nightly hour, 0-23     (default: 2)
#       --weekly-sql               Also keep a Sunday plain-SQL dump
#       --no-monitor               Skip the daily health check entry
#   -h, --help
#
# Everything logs to backups/cron.log.
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

CMD="${1:-status}"; shift || true
TARGET_ARG="local"; HOUR=2; WEEKLY_SQL=0; WANT_MONITOR=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)   TARGET_ARG="$2"; shift 2 ;;
    --hour)        HOUR="$2"; shift 2 ;;
    --weekly-sql)  WEEKLY_SQL=1; shift ;;
    --no-monitor)  WANT_MONITOR=0; shift ;;
    -h|--help)     sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need_bin crontab
MARK_BEGIN="# >>> ${BACKUP_PREFIX} backups (tools/db-backup-cron.sh) >>>"
MARK_END="# <<< ${BACKUP_PREFIX} backups <<<"
LOG="$BACKUP_ROOT/cron.log"

current_crontab() { crontab -l 2>/dev/null || true; }
without_block()   { current_crontab | sed "\|${MARK_BEGIN}|,\|${MARK_END}|d"; }

case "$CMD" in

status)
  hdr "Scheduled $PROJECT_NAME backups"
  if current_crontab | grep -qF "$MARK_BEGIN"; then
    current_crontab | sed -n "\|${MARK_BEGIN}|,\|${MARK_END}|p"
  else
    info "(no ${BACKUP_PREFIX} backup block in this user's crontab)"
  fi
  echo
  if [[ -f "$LOG" ]]; then
    hdr "Last 20 lines of $LOG"
    tail -20 "$LOG"
  else
    info "no cron log yet at $LOG"
  fi
  ;;

remove)
  if ! current_crontab | grep -qF "$MARK_BEGIN"; then
    info "nothing to remove"; exit 0
  fi
  without_block | crontab -
  ok "removed the ${BACKUP_PREFIX} backup block from crontab"
  ;;

install)
  [[ "$HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || die "--hour must be 0-23"
  resolve_target "$TARGET_ARG"
  mkdir -p "$BACKUP_ROOT"

  # Cron gets a bare environment: no PATH to docker, no ssh agent, no TERM.
  # Pin PATH explicitly and let each entry cd into the repo so the scripts'
  # own relative paths resolve.
  BK="$TOOLS_DIR/db-backup.sh"
  MON="$TOOLS_DIR/db-backup-monitor.sh"

  {
    echo "$MARK_BEGIN"
    echo "# Managed block — edit via tools/db-backup-cron.sh, not by hand."
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "# nightly custom-format backup of '$TARGET_ARG' (label 'auto', pruned after 30d)"
    echo "0 $HOUR * * *   cd $REPO_DIR && $BK --target $TARGET_ARG --label auto >> $LOG 2>&1"
    if [[ "$WEEKLY_SQL" -eq 1 ]]; then
      echo "# Sunday: same, plus a greppable plain-SQL copy"
      echo "30 $HOUR * * 0  cd $REPO_DIR && $BK --target $TARGET_ARG --label weekly --sql >> $LOG 2>&1"
    fi
    if [[ "$WANT_MONITOR" -eq 1 ]]; then
      # An hour after the nightly run: late enough that a slow prod dump has
      # finished, early enough that a failure is same-morning news.
      echo "# health check — non-zero exit is the alertable signal"
      echo "0 $(( (HOUR + 1) % 24 )) * * *   cd $REPO_DIR && $MON --target $TARGET_ARG --quiet >> $LOG 2>&1"
    fi
    echo "$MARK_END"
  } > /tmp/${BACKUP_PREFIX}_cron_block.$$

  { without_block; cat /tmp/${BACKUP_PREFIX}_cron_block.$$; } | crontab -
  rm -f /tmp/${BACKUP_PREFIX}_cron_block.$$

  ok "installed scheduled backups for target '$TARGET_ARG'"
  echo
  current_crontab | sed -n "\|${MARK_BEGIN}|,\|${MARK_END}|p"
  echo
  if [[ "$TARGET_ARG" != local ]]; then
    warn "target '$TARGET_ARG' backs up over ssh. cron has no ssh-agent, so the key for '${TGT_SSH:-the target}'"
    warn "must be passphrase-less and named in ~/.ssh/config, or these jobs will fail silently at 0${HOUR}:00."
    warn "Verify with:  ssh -o BatchMode=yes ${TGT_SSH:-<host>} true"
  fi
  info "log: $LOG"
  info "check it is working:  ./tools/db-backup-monitor.sh --target $TARGET_ARG"
  ;;

*) die "unknown command '$CMD' (expected: install | status | remove)" ;;
esac
