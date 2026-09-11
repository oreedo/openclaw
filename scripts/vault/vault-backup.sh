#!/usr/bin/env bash
set -euo pipefail

# Vault Raft snapshot backup.
#
# Takes a snapshot via `vault operator raft snapshot save`, validates it with
# `vault operator raft snapshot inspect`, and writes it with a sha256 sidecar
# into a root-only directory. Uses the token from VAULT_TOKEN or the CLI token
# helper (~/.vault-token); the token's policy needs:
#
#   path "sys/storage/raft/snapshot" { capabilities = ["read"] }
#
# Snapshots are encrypted by Vault's keyring: restoring one requires the
# cluster's unseal keys. Keep backups out of git and copy them off-host.

VAULT_ADDR="${VAULT_ADDR:-https://vault.oreedo.co}"
OUT_DIR="/root/backups/vault"
KEEP=0
REVOKE="false"

usage() {
  cat <<'EOF'
Usage:
  vault-backup.sh [options]

Options:
  --addr <url>        Vault address (default: $VAULT_ADDR or https://vault.oreedo.co)
  --out-dir <dir>     backup directory, created 0700 (default: /root/backups/vault)
  --keep <n>          keep only the newest n snapshots in --out-dir (default: 0 = keep all)
  --revoke-token      revoke the token used (vault token revoke -self) after a successful backup
  -h, --help          show help
EOF
}

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --addr) VAULT_ADDR="$2"; shift 2 ;;
      --out-dir) OUT_DIR="$2"; shift 2 ;;
      --keep) KEEP="$2"; shift 2 ;;
      --revoke-token) REVOKE="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
  done
  [[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep must be a non-negative integer"
  export VAULT_ADDR

  for c in vault jq sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done

  log "Preflight against $VAULT_ADDR"
  vault status -format=json | jq -e '.sealed == false and .storage_type == "raft"' >/dev/null \
    || die "Vault is sealed or not using raft storage"
  vault token lookup >/dev/null 2>&1 \
    || die "no valid token: log in first (vault login -method=userpass username=<user>)"
  local caps
  caps="$(vault token capabilities sys/storage/raft/snapshot)"
  [[ "$caps" == *read* || "$caps" == *root* ]] \
    || die "token lacks read on sys/storage/raft/snapshot (capabilities: $caps)"

  umask 077
  install -d -m 700 "$OUT_DIR"

  local cluster stamp base tmp
  cluster="$(vault status -format=json | jq -r '.cluster_name // "vault"')"
  stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  base="$OUT_DIR/${cluster}-${stamp}.snap"
  tmp="$base.partial"

  log "Saving snapshot to $tmp"
  vault operator raft snapshot save "$tmp"

  log "Validating snapshot"
  vault operator raft snapshot inspect "$tmp" > "$base.inspect.txt" \
    || { rm -f "$tmp" "$base.inspect.txt"; die "snapshot inspect failed; partial file removed"; }

  mv "$tmp" "$base"
  (cd "$OUT_DIR" && sha256sum "$(basename "$base")" > "$(basename "$base").sha256")

  if (( KEEP > 0 )); then
    local old
    while IFS= read -r old; do
      log "Retention: removing $old"
      rm -f "$old" "$old.sha256" "$old.inspect.txt"
    done < <(ls -1t "$OUT_DIR"/*.snap 2>/dev/null | tail -n +"$((KEEP + 1))")
  fi

  log "Backup complete"
  echo "  file:   $base"
  echo "  size:   $(du -h "$base" | cut -f1)"
  echo "  sha256: $(cut -d' ' -f1 "$base.sha256")"
  cat "$base.inspect.txt" | sed 's/^/  /'

  if [[ "$REVOKE" == "true" ]]; then
    vault token revoke -self >/dev/null && log "Token revoked"
    # revoke -self doesn't erase the CLI token helper file; drop it when it was the source
    [[ -z "${VAULT_TOKEN:-}" ]] && rm -f "${HOME}/.vault-token"
  fi
}

main "$@"
