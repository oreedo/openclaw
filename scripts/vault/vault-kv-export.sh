#!/usr/bin/env bash
set -euo pipefail

# Export a KV secrets engine to one PLAINTEXT JSON file (offline copy).
#
# Walks the mount recursively using only list + read, e.g. a policy of
#   path "gx/*" { capabilities = ["read", "list"] }
# and writes:
#   { exported_at, vault_addr, source_cluster_id, mount, kv_version,
#     mount_config, secret_count, secrets: { "<path>": { data, metadata, versions? } } }
# KV v2: data = current version (null when deleted or destroyed), metadata =
# full KV metadata, versions = every readable version with --all-versions.
# Liveness is decided by reading a version: versions carrying a future
# deletion_time (delete_version_after) are live. KV v1: data only.
#
# Secret values never reach stdout, stderr or argv: they flow from vault into
# files inside a 0700 directory (0600 files). Afterwards every secret is
# re-read from Vault and compared by hash. The file is not encrypted: move it
# offline and delete the server copy.

VAULT_ADDR="${VAULT_ADDR:-https://vault.oreedo.co}"
MOUNT="gx"
OUT_DIR="/root/backups/vault"
ALL_VERSIONS="false"
REVOKE="false"

KV_VERSION=""
TMP=""
PATHS=()

usage() {
  cat <<'EOF'
Usage:
  vault-kv-export.sh [options]

Options:
  --addr <url>        Vault address (default: $VAULT_ADDR or https://vault.oreedo.co)
  --mount <name>      KV mount to export, without slashes (default: gx)
  --out-dir <dir>     output directory, created 0700 (default: /root/backups/vault)
  --all-versions      KV v2: also export every live older version
  --revoke-token      revoke the token used (vault token revoke -self) when done, even on failure
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

cleanup() {
  [[ -n "$TMP" ]] && rm -rf "$TMP"
  if [[ "$REVOKE" == "true" ]]; then
    vault token revoke -self >/dev/null 2>&1 && log "Token revoked"
    # revoke -self doesn't erase the CLI token helper file; drop it when it was the source
    [[ -z "${VAULT_TOKEN:-}" ]] && rm -f "${HOME}/.vault-token"
  fi
  return 0
}

hash_json() {
  jq -S -c . | sha256sum | cut -d' ' -f1
}

NULL_HASH="$(echo null | hash_json)"

# Prints the keys under <mount>/<rel> (names only). An empty mount or folder is
# not an error; anything else (e.g. 403) aborts so the export can't be partial.
list_keys() {
  local rel="$1" out rc=0
  out="$(vault kv list -format=json "${MOUNT}/${rel}" 2>"$TMP/list.err")" || rc=$?
  if (( rc == 0 )); then
    jq -r '.[]' <<<"$out"
    return 0
  fi
  if [[ "$out" == "{}" && ! -s "$TMP/list.err" ]] || grep -q '^No value found at ' "$TMP/list.err"; then
    return 0
  fi
  die "list failed for ${MOUNT}/${rel} (rc=$rc): $(head -c 400 "$TMP/list.err")"
}

walk() {
  local rel="$1" keys k
  keys="$(list_keys "$rel")"
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if [[ "$k" == */ ]]; then
      walk "${rel}${k}"
    else
      PATHS+=("${rel}${k}")
    fi
  done <<<"$keys"
}

export_secret() {
  local p="$1" cur vlist v
  local vfile="$TMP/versions.json" mfile="$TMP/meta.json"

  if [[ "$KV_VERSION" != "2" ]]; then
    vault kv get -format=json "${MOUNT}/${p}" \
      | jq -c --arg path "$p" '{path: $path, data: .data}' >> "$TMP/secrets.ndjson"
    return
  fi

  vault kv metadata get -format=json "${MOUNT}/${p}" | jq -c '.data' > "$mfile"
  cur="$(jq -r '.current_version // 0' "$mfile")"
  if [[ "$ALL_VERSIONS" == "true" ]]; then
    vlist="$(jq -r '(.versions // {}) | to_entries[] | select(.value.destroyed != true) | .key' "$mfile" | sort -n)"
  else
    vlist="$(jq -r --arg c "$cur" '(.versions // {})[$c] // empty | select(.destroyed != true) | $c' "$mfile")"
  fi

  echo '{}' > "$vfile"
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    # a soft-deleted version reads back with data null: liveness is decided by reading
    vault kv get -format=json -version="$v" "${MOUNT}/${p}" \
      | jq -c --arg v "$v" --slurpfile acc "$vfile" \
          '$acc[0] + (if .data.data == null then {} else {($v): .data.data} end)' > "$vfile.new"
    mv "$vfile.new" "$vfile"
  done <<<"$vlist"

  jq -c -n --arg path "$p" --arg cur "$cur" --arg all "$ALL_VERSIONS" \
    --slurpfile meta "$mfile" --slurpfile vers "$vfile" \
    '{path: $path, data: ($vers[0][$cur] // null), metadata: $meta[0]}
     + (if $all == "true" then {versions: $vers[0]} else {} end)' >> "$TMP/secrets.ndjson"
}

# Hash of Vault's current data for <path>; NULL_HASH when deleted or never written.
current_hash() {
  local p="$1" h filter='.data.data'
  [[ "$KV_VERSION" == "2" ]] || filter='.data'
  if h="$(vault kv get -format=json "${MOUNT}/${p}" 2>"$TMP/get.err" | jq "$filter" | hash_json)"; then
    echo "$h"
  elif grep -q '^No value found at ' "$TMP/get.err"; then
    echo "$NULL_HASH"
  else
    die "read failed for ${MOUNT}/${p}: $(head -c 400 "$TMP/get.err")"
  fi
}

# Re-reads every secret's current data from Vault and compares hashes with the
# export (deleted secrets included). Prints counts and failing paths, never values.
verify_export() {
  local file="$1" p want got bad=0 checked=0
  for p in "${PATHS[@]}"; do
    want="$(jq --arg p "$p" '.secrets[$p].data' "$file" | hash_json)"
    got="$(current_hash "$p")"
    checked=$((checked + 1))
    [[ "$want" == "$got" ]] || { echo "  MISMATCH: ${MOUNT}/${p}" >&2; bad=$((bad + 1)); }
  done
  (( bad == 0 )) || die "$bad secret(s) differ from Vault (changed during export?); run it again"
  log "Verified $checked secret(s) against Vault: all match"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --addr) VAULT_ADDR="$2"; shift 2 ;;
      --mount) MOUNT="${2%/}"; shift 2 ;;
      --out-dir) OUT_DIR="$2"; shift 2 ;;
      --all-versions) ALL_VERSIONS="true"; shift ;;
      --revoke-token) REVOKE="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
  done
  export VAULT_ADDR
  unset VAULT_WRAP_TTL   # a wrapping TTL would turn every read into a wrapping token
  trap cleanup EXIT

  for c in vault jq sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done

  log "Preflight against $VAULT_ADDR"
  vault token lookup >/dev/null 2>&1 \
    || die "no valid token: log in first (vault login -method=userpass username=<user>)"
  local mount_info
  mount_info="$(vault read -format=json "sys/internal/ui/mounts/${MOUNT}" 2>/dev/null)" \
    || die "mount ${MOUNT}/ not visible to this token"
  [[ "$(jq -r '.data.type' <<<"$mount_info")" == "kv" ]] || die "${MOUNT}/ is not a KV mount"
  [[ "$(jq -r '.data.path' <<<"$mount_info")" == "${MOUNT}/" ]] \
    || die "${MOUNT} is not a mount root (it is inside mount $(jq -r '.data.path' <<<"$mount_info"))"
  KV_VERSION="$(jq -r '.data.options.version // "1"' <<<"$mount_info")"
  log "Mount ${MOUNT}/ is KV v${KV_VERSION}"

  umask 077
  install -d -m 700 "$OUT_DIR"
  local stale
  stale="$(find "$OUT_DIR" -maxdepth 1 -type d -name '.export.*' -mmin +60)"
  if [[ -n "$stale" ]]; then
    log "Removing stale plaintext temp dir(s) from an interrupted run: $(tr '\n' ' ' <<<"$stale")"
    find "$OUT_DIR" -maxdepth 1 -type d -name '.export.*' -mmin +60 -exec rm -rf {} +
  fi
  TMP="$(mktemp -d "$OUT_DIR/.export.XXXXXX")"
  : > "$TMP/secrets.ndjson"

  if [[ "$KV_VERSION" == "2" ]] \
     && vault read -format=json "${MOUNT}/config" 2>/dev/null | jq -c '.data' > "$TMP/mount_config.json"; then
    :
  else
    echo null > "$TMP/mount_config.json"
  fi

  walk ""
  log "Found ${#PATHS[@]} secret(s); reading"
  local p
  for p in "${PATHS[@]}"; do
    export_secret "$p"
  done

  local stamp out cluster_id
  stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  out="$OUT_DIR/${MOUNT}-kv-export-${stamp}.json"
  cluster_id="$(vault status -format=json | jq -r '.cluster_id // ""')"
  jq -s --arg at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg addr "$VAULT_ADDR" --arg cid "$cluster_id" \
    --arg mount "${MOUNT}/" --arg kv "$KV_VERSION" --slurpfile mcfg "$TMP/mount_config.json" \
    '(sort_by(.path) | map({key: .path, value: del(.path)}) | from_entries) as $s
     | {exported_at: $at, vault_addr: $addr, source_cluster_id: $cid, mount: $mount,
        kv_version: ($kv | tonumber), mount_config: $mcfg[0], secret_count: ($s | length), secrets: $s}' \
    "$TMP/secrets.ndjson" > "$TMP/export.json"

  [[ "$(jq -r '.secret_count' "$TMP/export.json")" == "${#PATHS[@]}" ]] \
    || die "secret count mismatch between listing and export"
  verify_export "$TMP/export.json"

  mv "$TMP/export.json" "$out"
  (cd "$OUT_DIR" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")

  log "Export complete (PLAINTEXT — move it offline, then delete the server copy)"
  echo "  file:     $out"
  echo "  size:     $(du -h "$out" | cut -f1)"
  echo "  secrets:  $(jq -r '.secret_count' "$out") ($(jq -r '[.secrets[] | select(.data == null)] | length' "$out") deleted in source)"
  echo "  keys:     $(jq -r '[.secrets[] | (.data // {}) | keys | length] | add // 0' "$out") (current versions)"
  if [[ "$ALL_VERSIONS" == "true" ]]; then
    echo "  versions: $(jq -r '[.secrets[] | (.versions // {}) | keys | length] | add // 0' "$out") (live)"
  fi
}

main "$@"
