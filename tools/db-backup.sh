#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/db-backup.sh — back up the project's Postgres database.
#
# Works against all three targets (local container / prod VM / test VM). The
# dump, the integrity check and the checksum all run ON THE TARGET, then the
# archive is streamed back and re-checksummed here. That ordering is the whole
# point: a dump is only a backup once something has proved it can be read, and
# proving it needs a pg_restore of the same major version as the server that
# wrote it — which is exactly what you don't have locally when prod is PG18 and
# this box's client is PG16.
#
# Usage:
#   ./tools/db-backup.sh                          # local, label 'manual'
#   ./tools/db-backup.sh --target prod            # prod, over ssh
#   ./tools/db-backup.sh --target prod --label predeploy
#   ./tools/db-backup.sh --quick                  # skip the plain-SQL copy
#   ./tools/db-backup.sh --list                   # show what's already there
#
# Flags:
#   -t, --target local|prod|test   Which database                (default: local)
#   -l, --label NAME               Tag baked into the filename   (default: manual)
#                                  Retention treats 'auto' (cron) separately.
#       --sql                      Also write a gzipped plain-SQL dump
#       --quick                    Custom-format only, skip verification re-read
#       --keep-days N              Prune this label older than N days (default: 30
#                                  for 'auto', 90 for everything else)
#       --keep-min N               Never prune below N newest per label (default: 5)
#       --no-prune                 Keep everything
#       --out DIR                  Backup root (default: ./backups/<target>)
#       --list                     List existing backups and exit
#   -h, --help
#
# Exit codes: 0 ok · 1 failed (nothing usable was written)
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TARGET_ARG="local"; LABEL="manual"; WANT_SQL=0; QUICK=0
KEEP_DAYS=""; KEEP_MIN=5; PRUNE=1; DO_LIST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)  TARGET_ARG="$2"; shift 2 ;;
    -l|--label)   LABEL="$2"; shift 2 ;;
    --sql)        WANT_SQL=1; shift ;;
    --quick)      QUICK=1; shift ;;
    --keep-days)  KEEP_DAYS="$2"; shift 2 ;;
    --keep-min)   KEEP_MIN="$2"; shift 2 ;;
    --no-prune)   PRUNE=0; shift ;;
    --out)        BACKUP_ROOT="$2"; shift 2 ;;
    --list)       DO_LIST=1; shift ;;
    -h|--help)    sed -n '2,/^# -\{20,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Label goes into a filename and is parsed back out by label_of(); an
# underscore would make that ambiguous.
[[ "$LABEL" =~ ^[A-Za-z0-9-]+$ ]] || die "--label must be alphanumeric/dashes (got '$LABEL')"

resolve_target "$TARGET_ARG"
DEST="$(backup_dir_for "$TARGET")"
mkdir -p "$DEST"

# ── --list ─────────────────────────────────────────────────────────────────
if [[ "$DO_LIST" -eq 1 ]]; then
  hdr "Backups for target '$TARGET'  ($DEST)"
  shopt -s nullglob
  files=("$DEST"/"${BACKUP_PREFIX}"_*.dump)
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then info "(none)"; exit 0; fi
  printf '%-11s %-9s %-46s %s\n' "LABEL" "SIZE" "FILE" "TAKEN"
  while read -r f; do
    taken="$(grep -m1 '^taken=' "${f}.meta" 2>/dev/null | cut -d= -f2- || true)"
    printf '%-11s %-9s %-46s %s\n' "$(label_of "$f")" "$(human_size "$f")" "$(basename "$f")" "${taken:-?}"
  done < <(ls -1t "$DEST"/"${BACKUP_PREFIX}"_*.dump)
  echo; info "total: $(du -sh "$DEST" | cut -f1)"
  exit 0
fi

# ── Preflight ──────────────────────────────────────────────────────────────
hdr "$PROJECT_NAME backup · target=$TARGET · label=$LABEL"
assert_target_reachable
tgt_db_exists || die "database '$DB_NAME' does not exist on target '$TARGET'"

SRV_VER="$(tgt_server_version)"
SRV_SIZE="$(tgt_db_size)"
SRV_TABLES="$(tgt_table_count)"
log "Source: PostgreSQL ${SRV_VER}, db '${DB_NAME}', ${SRV_TABLES} tables, ${SRV_SIZE}"

STAMP="$(date +%Y%m%d_%H%M%S)"
STEM="$(backup_stem "$TARGET" "$LABEL" "$STAMP")"
REMOTE_TMP="/tmp/${STEM}.dump"
OUT="$DEST/${STEM}.dump"

# Clean up the target-side temp file no matter how we exit. Nothing is left
# owned by postgres in /tmp on a production box.
cleanup_remote() { tgt_exec "rm -f ${REMOTE_TMP} ${REMOTE_TMP%.dump}.sql.gz" >/dev/null 2>&1 || true; }
trap cleanup_remote EXIT

# ── 1. Dump on the target ──────────────────────────────────────────────────
log "Dumping (pg_dump ${SRV_VER}, custom format, compress=6)"
tgt_exec "pg_dump -U $(printf '%q' "$DB_USER") -d $(printf '%q' "$DB_NAME") \
            --format=custom --compress=6 --no-owner --no-privileges \
            --file=${REMOTE_TMP}" \
  || die "pg_dump failed on target '$TARGET'"

# ── 2. Verify + checksum on the target, BEFORE transferring ────────────────
# pg_restore --list is the cheapest proof the archive's TOC is intact. Doing it
# here means a corrupt dump never becomes a file that looks like a backup.
if [[ "$QUICK" -eq 0 ]]; then
  log "Verifying archive on the target (pg_restore --list)"
  tgt_exec "pg_restore --list ${REMOTE_TMP} > /dev/null" \
    || { cleanup_remote; die "archive failed verification on the target — NOT saved"; }
  ok "archive is readable"
fi

REMOTE_SUM="$(trim "$(tgt_exec "sha256sum ${REMOTE_TMP} | cut -d' ' -f1" || true)")"
REMOTE_BYTES="$(trim "$(tgt_exec "stat -c %s ${REMOTE_TMP}" || true)")"
[[ -n "$REMOTE_BYTES" && "$REMOTE_BYTES" -gt 0 ]] || die "dump is empty on the target"

# ── 3. Stream it back ──────────────────────────────────────────────────────
log "Retrieving -> $(basename "$OUT")"
tgt_stream_out "$REMOTE_TMP" > "$OUT" || { rm -f "$OUT"; die "transfer failed"; }

LOCAL_BYTES="$(stat -c %s "$OUT")"
LOCAL_SUM="$(sha256sum "$OUT" | cut -d' ' -f1)"
if [[ "$LOCAL_BYTES" != "$REMOTE_BYTES" ]]; then
  rm -f "$OUT"; die "size mismatch after transfer (target ${REMOTE_BYTES}B, here ${LOCAL_BYTES}B) — NOT saved"
fi
if [[ -n "$REMOTE_SUM" && "$LOCAL_SUM" != "$REMOTE_SUM" ]]; then
  rm -f "$OUT"; die "checksum mismatch after transfer — NOT saved"
fi
ok "$(human_size "$OUT") transferred, sha256 matches"

# ── 4. Optional plain-SQL copy ─────────────────────────────────────────────
# Human-readable and greppable — useful for "what did this column look like
# before the migration" without a restore. Gzipped; it is several times the
# size of the custom archive.
SQL_OUT=""
if [[ "$WANT_SQL" -eq 1 ]]; then
  log "Writing plain-SQL copy"
  SQL_OUT="$DEST/${STEM}.sql.gz"
  tgt_exec "pg_dump -U $(printf '%q' "$DB_USER") -d $(printf '%q' "$DB_NAME") \
              --format=plain --no-owner --no-privileges | gzip -6 > ${REMOTE_TMP%.dump}.sql.gz" \
    || warn "plain-SQL dump failed (the custom archive above is still good)"
  if tgt_exec "test -s ${REMOTE_TMP%.dump}.sql.gz"; then
    tgt_stream_out "${REMOTE_TMP%.dump}.sql.gz" > "$SQL_OUT" && ok "$(human_size "$SQL_OUT") $(basename "$SQL_OUT")"
  else
    SQL_OUT=""
  fi
fi

# ── 5. Sidecar metadata ────────────────────────────────────────────────────
# Everything you need to decide whether a given archive is the one you want,
# without opening it: what server wrote it, how big the db was, and which
# commit the app was on at the time.
GIT_SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_TAG="$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || echo none)"
cat > "${OUT}.meta" <<META
target=$TARGET
label=$LABEL
database=$DB_NAME
taken=$(date -Iseconds)
server_version=$SRV_VER
source_size=$SRV_SIZE
source_tables=$SRV_TABLES
archive_bytes=$LOCAL_BYTES
sha256=$LOCAL_SUM
sql_copy=$([[ -n "$SQL_OUT" ]] && basename "$SQL_OUT" || echo none)
repo_commit=$GIT_SHA
repo_tag=$GIT_TAG
taken_by=${USER:-unknown}@$(hostname -s 2>/dev/null || echo unknown)
restore_cmd=./tools/db-restore.sh full $(basename "$OUT") --target $TARGET
META

# ── 6. Prune ───────────────────────────────────────────────────────────────
# Retention is per label. A nightly 'auto' backup ages out in a month; a
# 'predeploy' or 'safety' archive is something a human deliberately created at
# a moment that mattered, so it lives three times as long. Either way the
# newest --keep-min are never deleted, so an outage that stops backups for six
# weeks cannot also delete the last good one.
if [[ "$PRUNE" -eq 1 ]]; then
  eff_days="$KEEP_DAYS"
  if [[ -z "$eff_days" ]]; then
    [[ "$LABEL" == "auto" ]] && eff_days=30 || eff_days=90
  fi
  mapfile -t same_label < <(ls -1t "$DEST"/"${BACKUP_PREFIX}"_"${TARGET}"_"${LABEL}"_*.dump 2>/dev/null || true)
  pruned=0
  for ((i = KEEP_MIN; i < ${#same_label[@]}; i++)); do
    f="${same_label[$i]}"
    if [[ -n "$(find "$f" -mtime "+${eff_days}" -print -quit 2>/dev/null)" ]]; then
      rm -f "$f" "${f}.meta" "${f%.dump}.sql.gz"
      pruned=$((pruned + 1))
    fi
  done
  [[ "$pruned" -gt 0 ]] && info "pruned $pruned '$LABEL' backup(s) older than ${eff_days}d (kept newest $KEEP_MIN)"
fi

# ── 7. Summary ─────────────────────────────────────────────────────────────
hdr "Backup complete"
info "file    $OUT"
info "size    $(human_size "$OUT")  (source db was $SRV_SIZE)"
info "sha256  $LOCAL_SUM"
info "restore ./tools/db-restore.sh full $(basename "$OUT") --target $TARGET"
exit 0
