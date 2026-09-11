#!/usr/bin/env bash
set -euo pipefail

# Backs up the SQL Server databases used by Rentek (Ren_DB, Ren_GAM) from the
# in-cluster MSSQL pod, verifies each backup with RESTORE VERIFYONLY, and
# applies retention. Backups are written inside the pod to a directory on the
# MSSQL PersistentVolume, so they survive pod restarts and land on the host at
# /home/mssql/data/... (see docs/rentek/RENTEK_SOURCE_ANALYSIS.md §6).
#
# COPY_ONLY by default so the script never disturbs an existing backup chain.
# The SA password is read from the pod's own environment and never printed.

KUBECTL_CMD="/snap/bin/microk8s kubectl"
NAMESPACE="default"
DATABASES="Ren_DB Ren_GAM"
BACKUP_DIR="/var/opt/mssql/data/backups"
KEEP=7
COPY_ONLY="true"
LOG_BACKUP="false"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage:
  mssql-backup.sh [options]

Options:
  --kubectl <cmd>      kubectl command (default: /snap/bin/microk8s kubectl)
  --namespace <ns>     namespace of the MSSQL pod (default: default)
  --databases "A B"    databases to back up (default: "Ren_DB Ren_GAM")
  --backup-dir <dir>   directory inside the pod, on the PV (default: /var/opt/mssql/data/backups)
  --keep <n>           keep the newest n backups per database (default: 7, 0 = keep all)
  --full-chain         take a normal (non-COPY_ONLY) full backup, starting/continuing a chain
  --log-backup         also back up the transaction log (requires a prior full backup)
  --dry-run            print what would run, change nothing
  -h, --help           show help
EOF
}

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
run_k() { eval "$KUBECTL_CMD $*"; }

# Runs SQL inside the pod; the password never leaves the container.
sqlcmd_in_pod() {
  run_k "-n $NAMESPACE exec -i $POD -- bash -c 'cat > /tmp/bk.sql; S=\$(ls /opt/mssql-tools*/bin/sqlcmd|head -1); \$S -S localhost -U sa -P \"\$SA_PASSWORD\" -C -b -h -1 -W -s\"|\" -i /tmp/bk.sql; rc=\$?; rm -f /tmp/bk.sql; exit \$rc'"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubectl) KUBECTL_CMD="$2"; shift 2 ;;
      --namespace) NAMESPACE="$2"; shift 2 ;;
      --databases) DATABASES="$2"; shift 2 ;;
      --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
      --keep) KEEP="$2"; shift 2 ;;
      --full-chain) COPY_ONLY="false"; shift ;;
      --log-backup) LOG_BACKUP="true"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
  done
  [[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep must be a non-negative integer"

  POD="$(run_k "-n $NAMESPACE get pod -o name" | grep mssql-mssql-deployment | head -1)"
  [[ -n "$POD" ]] || die "no MSSQL pod found in namespace $NAMESPACE"
  log "Using pod ${POD#pod/}"

  local stamp db target copy_clause
  stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  copy_clause=""
  [[ "$COPY_ONLY" == "true" ]] && copy_clause=", COPY_ONLY"

  if [[ "$DRY_RUN" == "true" ]]; then
    for db in $DATABASES; do
      echo "  DRY RUN: BACKUP DATABASE [$db] TO DISK='$BACKUP_DIR/${db}-${stamp}.bak' WITH INIT, CHECKSUM, COMPRESSION${copy_clause}"
      [[ "$LOG_BACKUP" == "true" ]] && echo "  DRY RUN: BACKUP LOG [$db] TO DISK='$BACKUP_DIR/${db}-${stamp}.trn' WITH CHECKSUM, COMPRESSION"
    done
    log "DRY RUN: nothing written"
    return
  fi

  run_k "-n $NAMESPACE exec $POD -- mkdir -p $BACKUP_DIR" >/dev/null

  for db in $DATABASES; do
    target="$BACKUP_DIR/${db}-${stamp}.bak"
    log "Backing up $db -> $target"
    cat <<SQL | sqlcmd_in_pod > /dev/null
SET NOCOUNT ON;
BACKUP DATABASE [$db] TO DISK = N'$target'
  WITH INIT, CHECKSUM, COMPRESSION, STATS = 25$copy_clause;
SQL
    log "Verifying $db backup"
    cat <<SQL | sqlcmd_in_pod > /dev/null
SET NOCOUNT ON;
RESTORE VERIFYONLY FROM DISK = N'$target' WITH CHECKSUM;
SQL
    if [[ "$LOG_BACKUP" == "true" ]]; then
      log "Backing up transaction log of $db"
      cat <<SQL | sqlcmd_in_pod > /dev/null
SET NOCOUNT ON;
BACKUP LOG [$db] TO DISK = N'$BACKUP_DIR/${db}-${stamp}.trn' WITH CHECKSUM, COMPRESSION;
SQL
    fi
  done

  if (( KEEP > 0 )); then
    # NOTE: expand the skip count HERE; inside the pod KEEP does not exist and
    # "tail -n +1" would delete every backup, including the one just taken.
    local skip=$(( KEEP + 1 ))
    for db in $DATABASES; do
      run_k "-n $NAMESPACE exec $POD -- bash -c 'ls -1t $BACKUP_DIR/${db}-*.bak 2>/dev/null | tail -n +$skip | xargs -r rm -f'" \
        2>/dev/null || true
    done
    log "Retention applied (keeping newest $KEEP per database)"
  fi

  log "Backup complete; files on the PV (host path /home/mssql/data/data/backups):"
  run_k "-n $NAMESPACE exec $POD -- bash -c 'ls -lh $BACKUP_DIR | tail -10'"
}

main "$@"
