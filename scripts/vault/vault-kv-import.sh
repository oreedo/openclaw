#!/usr/bin/env bash
set -euo pipefail

# Import a vault-kv-export.sh JSON file into a KV v2 mount of (another) Vault.
#
# Idempotent: secrets whose data and KV metadata already match the export are
# left alone, so re-runs create no new versions and a failed run can simply be
# repeated. Every data write uses check-and-set against the target's current
# version. KV metadata (max_versions, cas_required, delete_version_after,
# custom_metadata) is applied before the data. --all-versions replays the
# exported live history oldest -> newest for secrets new to the target (needs
# an export made with --all-versions). Secrets whose current version is deleted
# in the source are not imported (metadata only).
#
# Target prerequisites:
#   vault secrets enable -path=<mount> kv-v2
#   path "<mount>/data/*"     { capabilities = ["create", "update", "read"] }
#   path "<mount>/metadata/*" { capabilities = ["create", "update", "read", "list"] }
#   (read/update on <mount>/config for --apply-mount-config)
#
# Secret values reach vault on stdin only (never argv or stdout).

VAULT_ADDR=""   # set by --addr only: an exported VAULT_ADDR is deliberately ignored
FILE=""
MOUNT=""
ALL_VERSIONS="false"
DRY_RUN="false"
ALLOW_SAME="false"
APPLY_MOUNT_CONFIG="false"

TMP=""
PATHS=()

usage() {
  cat <<'EOF'
Usage:
  vault-kv-import.sh --file <export.json> --addr <target-vault-url> [options]

Options:
  --file <path>         export produced by vault-kv-export.sh (required)
  --addr <url>          TARGET Vault address (required; VAULT_ADDR is ignored)
  --mount <name>        target KV v2 mount (default: the mount recorded in the export)
  --all-versions        replay exported version history for secrets new to the target
  --dry-run             show the action per secret without writing
  --allow-same-vault    allow importing into the Vault the export came from (rollback)
  --apply-mount-config  also copy the mount-level config (max_versions, cas_required,
                        delete_version_after) recorded in the export
  -h, --help            show help
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
  return 0
}

hash_json() {
  jq -S -c . | sha256sum | cut -d' ' -f1
}

NULL_HASH="$(echo null | hash_json)"

# Hash of the target's current data (NULL_HASH when the current version is
# deleted); "absent" when the path has no version at all.
target_hash() {
  local p="$1" h
  if h="$(vault kv get -format=json "${MOUNT}/${p}" 2>"$TMP/get.err" </dev/null \
          | jq '.data.data' | hash_json)"; then
    echo "$h"
  elif grep -q '^No value found at ' "$TMP/get.err"; then
    echo absent
  else
    die "read failed for ${MOUNT}/${p}: $(head -c 400 "$TMP/get.err")"
  fi
}

META_FIELDS='{max_versions: (.max_versions // 0), cas_required: (.cas_required // false),
              delete_version_after: (.delete_version_after // "0s"),
              custom_metadata: (.custom_metadata // {})}'

desired_meta() {
  jq -S -c --arg p "$1" ".secrets[\$p].metadata // {} | $META_FIELDS" "$FILE"
}

target_meta() {
  local p="$1" out
  if out="$(vault kv metadata get -format=json "${MOUNT}/${p}" 2>"$TMP/meta.err" </dev/null)"; then
    jq -S -c ".data | $META_FIELDS" <<<"$out"
  elif grep -q '^No value found at ' "$TMP/meta.err"; then
    jq -S -c -n "{} | $META_FIELDS"
  else
    die "metadata read failed for ${MOUNT}/${p}: $(head -c 400 "$TMP/meta.err")"
  fi
}

# Converges the target's KV metadata to the export (writes only on a real
# difference). Prints "changed" when it differed.
sync_meta() {
  local p="$1" want have
  want="$(desired_meta "$p")"
  have="$(target_meta "$p")"
  [[ "$want" == "$have" ]] && return 0
  if [[ "$DRY_RUN" != "true" ]]; then
    vault write "${MOUNT}/metadata/${p}" - >/dev/null <<<"$want"
  fi
  echo changed
}

target_version() {
  local p="$1" out
  if out="$(vault kv metadata get -format=json "${MOUNT}/${p}" 2>"$TMP/ver.err" </dev/null)"; then
    jq -r '.data.current_version // 0' <<<"$out"
  elif grep -q '^No value found at ' "$TMP/ver.err"; then
    echo 0
  else
    die "metadata read failed for ${MOUNT}/${p}: $(head -c 400 "$TMP/ver.err")"
  fi
}

# Writes the JSON object on stdin as the next version of <path>, check-and-set
# against the target's current version (0 = the path must have no versions yet).
put_stdin() {
  local p="$1" cas
  cas="$(target_version "$p")"
  vault kv put -cas="$cas" "${MOUNT}/${p}" - >/dev/null
}

# Replays the exported live versions oldest -> newest; prints how many.
replay_versions() {
  local p="$1" v vers n=0
  vers="$(jq -r --arg p "$p" '(.secrets[$p].versions // {}) | keys[]' "$FILE" | sort -n)"
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    jq -c --arg p "$p" --arg v "$v" '.secrets[$p].versions[$v]' "$FILE" | put_stdin "$p"
    n=$((n + 1))
  done <<<"$vers"
  echo "$n"
}

# Mount-level config recorded in the export vs the target: applies it with
# --apply-mount-config, otherwise warns when it differs (or can't be compared).
check_mount_config() {
  local want have
  want="$(jq -S -c '.mount_config // null | if . == null then null
                    else {max_versions, cas_required, delete_version_after} end' "$FILE")"
  [[ "$want" == "null" ]] && return 0
  if have="$(vault read -format=json "${MOUNT}/config" 2>/dev/null </dev/null \
             | jq -S -c '.data | {max_versions, cas_required, delete_version_after}')"; then
    [[ "$want" == "$have" ]] && return 0
  else
    have="(not readable with this token)"
  fi
  if [[ "$APPLY_MOUNT_CONFIG" == "true" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY RUN: would set ${MOUNT}/config to $want"
    else
      vault write "${MOUNT}/config" - >/dev/null <<<"$want"
      log "Mount config of ${MOUNT}/ set to $want"
    fi
  else
    log "WARNING: mount config differs — source $want, target $have; add --apply-mount-config to copy it"
  fi
}

report() {
  [[ "$DRY_RUN" == "true" ]] && printf '  %-26s %s\n' "$1" "$2"
  return 0
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) FILE="$2"; shift 2 ;;
      --addr) VAULT_ADDR="$2"; shift 2 ;;
      --mount) MOUNT="${2%/}"; shift 2 ;;
      --all-versions) ALL_VERSIONS="true"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
      --allow-same-vault) ALLOW_SAME="true"; shift ;;
      --apply-mount-config) APPLY_MOUNT_CONFIG="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
  done
  [[ -n "$FILE" ]] || { usage; die "--file is required"; }
  [[ -n "$VAULT_ADDR" ]] || { usage; die "--addr (target Vault) is required"; }
  [[ -f "$FILE" ]] || die "file not found: $FILE"
  export VAULT_ADDR
  unset VAULT_WRAP_TTL   # a wrapping TTL would turn every read into a wrapping token

  for c in vault jq sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done

  # Validate the structure up front (quietly: jq type errors can quote values).
  jq -e '(.secrets | type == "object")
         and all(.secrets[]; type == "object"
                 and (.data == null or (.data | type) == "object")
                 and ((.versions // {}) | type == "object" and all(.[]; type == "object"))
                 and ((.metadata // {}) | type == "object"))' "$FILE" >/dev/null 2>&1 \
    || die "$FILE is not a well-formed vault-kv-export.sh file"
  [[ -n "$MOUNT" ]] || MOUNT="$(jq -r '.mount | rtrimstr("/")' "$FILE")"
  mapfile -t PATHS < <(jq -r '.secrets | keys[]' "$FILE")
  [[ "${#PATHS[@]}" == "$(jq -r '.secrets | length' "$FILE")" ]] \
    || die "could not enumerate the secret paths in $FILE (path names containing newlines?)"

  log "Preflight against $VAULT_ADDR (target mount ${MOUNT}/)"
  vault token lookup >/dev/null 2>&1 || die "no valid token for $VAULT_ADDR"

  local src_addr src_id dst_id
  src_addr="$(jq -r '.vault_addr // ""' "$FILE")"
  src_id="$(jq -r '.source_cluster_id // ""' "$FILE")"
  dst_id="$(vault status -format=json 2>/dev/null | jq -r '.cluster_id // ""' || true)"
  if [[ "$ALLOW_SAME" != "true" ]] \
     && { [[ "${VAULT_ADDR%/}" == "${src_addr%/}" ]] || [[ -n "$src_id" && "$src_id" == "$dst_id" ]]; }; then
    die "refusing to import into the source Vault ($src_addr); add --allow-same-vault for a deliberate rollback"
  fi

  local mount_info
  mount_info="$(vault read -format=json "sys/internal/ui/mounts/${MOUNT}" 2>/dev/null)" \
    || die "mount ${MOUNT}/ not visible on target (create it: vault secrets enable -path=${MOUNT} kv-v2)"
  [[ "$(jq -r '.data.type' <<<"$mount_info")" == "kv" && "$(jq -r '.data.options.version' <<<"$mount_info")" == "2" ]] \
    || die "${MOUNT}/ on target is not a KV v2 mount"
  [[ "$(jq -r '.data.path' <<<"$mount_info")" == "${MOUNT}/" ]] \
    || die "${MOUNT} is not a mount root (it is inside mount $(jq -r '.data.path' <<<"$mount_info")); writes would land in that mount's root"

  umask 077
  TMP="$(mktemp -d)"
  trap cleanup EXIT

  check_mount_config

  local created=0 updated=0 unchanged=0 skipped=0 replayed=0 meta=0
  local p want have now m nvers n
  for p in "${PATHS[@]}"; do
    want="$(jq --arg p "$p" '.secrets[$p].data' "$FILE" | hash_json)"
    have="$(target_hash "$p")"
    nvers="$(jq -r --arg p "$p" '(.secrets[$p].versions // {}) | length' "$FILE")"
    m="$(sync_meta "$p")"
    [[ -n "$m" ]] && meta=$((meta + 1))
    m="${m:+ (+metadata)}"

    if [[ "$want" == "$NULL_HASH" ]]; then
      # current version deleted in the source: not imported (metadata only).
      # Undelete it in the source and re-export to bring it over.
      report "skip (deleted in source)$m" "$p"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "$have" == "$want" ]]; then
      unchanged=$((unchanged + 1))
      report "unchanged$m" "$p"
      continue
    fi

    if [[ "$have" == "absent" ]]; then report "create$m" "$p"; else report "update$m" "$p"; fi
    if [[ "$DRY_RUN" != "true" ]]; then
      if [[ "$have" == "absent" && "$ALL_VERSIONS" == "true" && "$nvers" -gt 0 ]]; then
        n="$(replay_versions "$p")"
        replayed=$((replayed + n))
        # the last write must be the source's current data
        now="$(target_hash "$p")"
        [[ "$now" == "$want" ]] || jq -c --arg p "$p" '.secrets[$p].data' "$FILE" | put_stdin "$p"
      else
        jq -c --arg p "$p" '.secrets[$p].data' "$FILE" | put_stdin "$p"
      fi
    fi
    if [[ "$have" == "absent" ]]; then created=$((created + 1)); else updated=$((updated + 1)); fi
  done

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN: nothing written ($created create, $updated update, $unchanged unchanged, $skipped skip, $meta metadata change(s))"
    return
  fi

  # Verify data (non-deleted secrets) and metadata (all secrets) against the export.
  local bad=0 data_checked=0 data_expected meta_checked=0 mw mh
  data_expected="$(jq -r '[.secrets[] | select(.data != null)] | length' "$FILE")"
  for p in "${PATHS[@]}"; do
    want="$(jq --arg p "$p" '.secrets[$p].data' "$FILE" | hash_json)"
    if [[ "$want" != "$NULL_HASH" ]]; then
      have="$(target_hash "$p")"
      data_checked=$((data_checked + 1))
      [[ "$have" == "$want" ]] || { echo "  MISMATCH (data): ${MOUNT}/${p}" >&2; bad=$((bad + 1)); }
    fi
    mw="$(desired_meta "$p")"
    mh="$(target_meta "$p")"
    meta_checked=$((meta_checked + 1))
    [[ "$mw" == "$mh" ]] || { echo "  MISMATCH (metadata): ${MOUNT}/${p}" >&2; bad=$((bad + 1)); }
  done
  (( bad == 0 )) || die "$bad secret(s) differ from the export after import"
  (( data_checked == data_expected )) || die "verified $data_checked of $data_expected secrets"

  log "Import complete into $VAULT_ADDR ${MOUNT}/"
  echo "  created: $created  updated: $updated  unchanged: $unchanged  skipped (deleted in source): $skipped"
  echo "  metadata changed: $meta"
  [[ "$ALL_VERSIONS" == "true" ]] && echo "  versions replayed: $replayed"
  echo "  verified: data $data_checked/$data_expected, metadata $meta_checked/${#PATHS[@]} match the export"
}

main "$@"
