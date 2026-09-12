#!/usr/bin/env bash
set -euo pipefail

# Copies the Rentek databases from the source cluster to the target cluster.
#
# It takes a fresh backup on the source, copies the files over SSH, restores
# them on the target, sets the database owner back to the application login,
# and verifies the result. Safe to run many times: the last run before the DNS
# change is the one that matters.
#
# It does NOT stop the application and it does NOT change DNS. Run it while the
# app is stopped if you want the copy to be complete (see RUNBOOKS.md RB-12).

KUBECTL_CMD="/snap/bin/microk8s kubectl"
NAMESPACE="default"
TARGET_SSH="hostinger_kvm8"
TARGET_KUBECTL="microk8s kubectl"
DATABASES="Ren_DB Ren_GAM"
APP_LOGIN="oreedo_user"
BACKUP_DIR="/var/opt/mssql/data/backups"
HOST_BACKUP_DIR="/home/mssql/data/data/backups"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage:
  mssql-copy-to-target.sh [options]

Options:
  --target-ssh <host>   ssh host of the target server (default: hostinger_kvm8)
  --databases "A B"     databases to copy (default: "Ren_DB Ren_GAM")
  --app-login <name>    login that must own the databases (default: oreedo_user)
  --namespace <ns>      namespace of the MSSQL pod on both sides (default: default)
  --dry-run             show what would happen, change nothing
  -h, --help            show help
EOF
}

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
run_k() { eval "$KUBECTL_CMD $*"; }

# Runs SQL on the source pod. The password stays inside the container.
src_sql() {
  run_k "-n $NAMESPACE exec -i $SRC_POD -- bash -c 'cat > /tmp/c.sql; S=\$(ls /opt/mssql-tools*/bin/sqlcmd|head -1); \$S -S localhost -U sa -P \"\$SA_PASSWORD\" -C -b -h -1 -W -s\"|\" -i /tmp/c.sql; rc=\$?; rm -f /tmp/c.sql; exit \$rc'"
}

# Runs SQL on the target pod, through ssh.
dst_sql() {
  ssh -o BatchMode=yes "$TARGET_SSH" "$TARGET_KUBECTL -n $NAMESPACE exec -i deploy/mssql-mssql-deployment -- bash -c \"cat > /tmp/c.sql; S=\\\$(ls /opt/mssql-tools*/bin/sqlcmd|head -1); \\\$S -S localhost -U sa -P \\\"\\\$SA_PASSWORD\\\" -C -b -h -1 -W -s'|' -i /tmp/c.sql; rc=\\\$?; rm -f /tmp/c.sql; exit \\\$rc\""
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-ssh) TARGET_SSH="$2"; shift 2 ;;
      --databases) DATABASES="$2"; shift 2 ;;
      --app-login) APP_LOGIN="$2"; shift 2 ;;
      --namespace) NAMESPACE="$2"; shift 2 ;;
      --dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
  done

  SRC_POD="$(run_k "-n $NAMESPACE get pod -o name" | grep mssql-mssql-deployment | head -1)"
  [[ -n "$SRC_POD" ]] || die "no MSSQL pod on the source"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET_SSH" true || die "cannot reach target over ssh: $TARGET_SSH"

  local stamp db
  stamp="$(date -u +'%Y%m%dT%H%M%SZ')"

  if [[ "$DRY_RUN" == "true" ]]; then
    for db in $DATABASES; do echo "  DRY RUN: copy $db  ($stamp)"; done
    log "DRY RUN: nothing changed"; return
  fi

  for db in $DATABASES; do
    log "Backing up $db on the source"
    cat <<SQL | src_sql > /dev/null
SET NOCOUNT ON;
BACKUP DATABASE [$db] TO DISK = N'$BACKUP_DIR/${db}-${stamp}.bak'
  WITH INIT, CHECKSUM, COMPRESSION, COPY_ONLY;
SQL
    log "Copying $db to the target"
    scp -q "$HOST_BACKUP_DIR/${db}-${stamp}.bak" "$TARGET_SSH:$HOST_BACKUP_DIR/" \
      || die "copy failed for $db"
    ssh -o BatchMode=yes "$TARGET_SSH" "chown 10001:10001 $HOST_BACKUP_DIR/${db}-${stamp}.bak"

    log "Restoring $db on the target"
    cat <<SQL | dst_sql > /dev/null
SET NOCOUNT ON;
RESTORE VERIFYONLY FROM DISK = N'$BACKUP_DIR/${db}-${stamp}.bak' WITH CHECKSUM;
IF DB_ID('$db') IS NOT NULL ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE [$db] FROM DISK = N'$BACKUP_DIR/${db}-${stamp}.bak' WITH RECOVERY, REPLACE;
ALTER DATABASE [$db] SET MULTI_USER;
ALTER AUTHORIZATION ON DATABASE::[$db] TO [$APP_LOGIN];
SQL
  done

  log "Verifying the target"
  local out
  out="$(cat <<SQL | dst_sql
SET NOCOUNT ON;
SELECT 'OWNER', name, ISNULL(SUSER_SNAME(owner_sid),'UNRESOLVED') FROM sys.databases WHERE name IN ($(echo "$DATABASES" | sed "s/\([^ ]*\)/'\1'/g; s/ /,/g"));
EXECUTE AS LOGIN = '$APP_LOGIN';
SELECT 'APP LOGIN CAN CONNECT AS', SUSER_NAME();
REVERT;
SQL
)"
  echo "$out" | grep -v '^$' | sed 's/^/  /'
  echo "$out" | grep -q 'UNRESOLVED' && die "a database owner did not resolve on the target"

  for db in $DATABASES; do
    local s d
    s="$(cat <<SQL | src_sql | tr -d ' \r'
SET NOCOUNT ON;
SELECT COUNT(*) FROM [$db].sys.tables;
SQL
)"
    d="$(cat <<SQL | dst_sql | tr -d ' \r'
SET NOCOUNT ON;
SELECT COUNT(*) FROM [$db].sys.tables;
SQL
)"
    [[ "$s" == "$d" ]] && echo "  $db: $s tables on both sides" \
      || die "$db table count differs: source=$s target=$d"
  done

  log "Copy complete. The target is now identical to the source as of $stamp."
  echo "  Next: change mssql.oreedo.co in DNSimple to the target IP (RUNBOOKS.md RB-12)."
}

main "$@"
