#!/usr/bin/env bash
set -euo pipefail

# Idempotent Rentek config migration helper
#
# Modes:
#   bundle-source  - export portable config objects from the source cluster
#   apply-target   - apply the exported portable config objects to a target cluster
#   verify-target  - verify the expected target-side config state
#
# Default kubectl command uses MicroK8s directly for reliability.

KUBECTL_CMD="/snap/bin/microk8s kubectl"
NAMESPACE="rentek"
BUNDLE_DIR=""
TLS_SECRET_NAME=""
INCLUDE_TLS="false"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage:
  rentek-config-migrate.sh <mode> [options]

Modes:
  bundle-source   Export portable Rentek config objects from source cluster
  apply-target    Apply bundle into destination cluster
  verify-target   Verify destination cluster config state

Options:
  --kubectl <cmd>        kubectl command to use
                         default: /snap/bin/microk8s kubectl
  --namespace <name>     namespace
                         default: rentek
  --bundle-dir <dir>     bundle directory for export/import
  --include-tls          export/apply ingress TLS secret too
  --tls-secret <name>    explicit TLS secret name
  --dry-run              print actions without changing cluster
  -h, --help             show help

Examples:
  source ~/.bashrc && bash rentek-config-migrate.sh bundle-source --kubectl kubectl --bundle-dir ./bundle --include-tls
  source ~/.bashrc && bash rentek-config-migrate.sh apply-target --kubectl kubectl --bundle-dir ./bundle
  source ~/.bashrc && bash rentek-config-migrate.sh verify-target --kubectl kubectl
EOF
}

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

run_k() {
  # shellcheck disable=SC2086
  eval "$KUBECTL_CMD $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

json_cleanup_filter='del(
  .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
  .metadata.creationTimestamp,
  .metadata.deletionGracePeriodSeconds,
  .metadata.deletionTimestamp,
  .metadata.finalizers,
  .metadata.generateName,
  .metadata.generation,
  .metadata.managedFields,
  .metadata.ownerReferences,
  .metadata.resourceVersion,
  .metadata.selfLink,
  .metadata.uid,
  .status
)'

ensure_namespace_manifest() {
  local out="$1"
  run_k "get ns $NAMESPACE -o json" \
    | jq '{apiVersion,kind,metadata:{name:.metadata.name,labels:(.metadata.labels // {})}}' \
    > "$out"
}

export_object() {
  local kind="$1"
  local name="$2"
  local out="$3"
  run_k "-n $NAMESPACE get $kind $name -o json" | jq "$json_cleanup_filter" > "$out"
}

apply_file() {
  local file="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN: would apply $file"
  else
    run_k "apply -f $file"
  fi
}

bundle_source() {
  [[ -n "$BUNDLE_DIR" ]] || { echo "--bundle-dir is required" >&2; exit 1; }
  mkdir -p "$BUNDLE_DIR"

  log "Bundling source config into $BUNDLE_DIR"
  ensure_namespace_manifest "$BUNDLE_DIR/00-namespace.json"
  export_object configmap assetlinks-config "$BUNDLE_DIR/10-configmap-assetlinks-config.json"
  export_object secret registry-1 "$BUNDLE_DIR/20-secret-registry-1.json"

  if run_k "-n $NAMESPACE get secret docker-auth-config >/dev/null 2>&1"; then
    export_object secret docker-auth-config "$BUNDLE_DIR/21-secret-docker-auth-config.json"
  fi

  if [[ "$INCLUDE_TLS" == "true" ]]; then
    local tls_name="$TLS_SECRET_NAME"
    if [[ -z "$tls_name" ]]; then
      tls_name="$(run_k "-n $NAMESPACE get ingress rentek-ingress -o jsonpath='{.spec.tls[0].secretName}'")"
    fi
    if [[ -n "$tls_name" ]]; then
      export_object secret "$tls_name" "$BUNDLE_DIR/30-secret-${tls_name}.json"
    fi
  fi

  cat > "$BUNDLE_DIR/README.md" <<EOF
# Rentek Config Bundle

Namespace: $NAMESPACE
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
Kubectl: $KUBECTL_CMD

Included:
- namespace
- assetlinks-config ConfigMap
- registry-1 pull secret
- docker-auth-config secret (if present)
$( [[ "$INCLUDE_TLS" == "true" ]] && echo "- ingress TLS secret" )

Designed for idempotent apply on the target cluster.
EOF

  log "Bundle complete"
}

apply_target() {
  [[ -n "$BUNDLE_DIR" ]] || { echo "--bundle-dir is required" >&2; exit 1; }
  [[ -d "$BUNDLE_DIR" ]] || { echo "Bundle dir not found: $BUNDLE_DIR" >&2; exit 1; }

  if [[ -f "$BUNDLE_DIR/00-namespace.json" ]]; then
    apply_file "$BUNDLE_DIR/00-namespace.json"
  else
    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY RUN: would create namespace $NAMESPACE"
    else
      run_k "create namespace $NAMESPACE --dry-run=client -o yaml | $KUBECTL_CMD apply -f -"
    fi
  fi

  shopt -s nullglob
  local files=(
    "$BUNDLE_DIR"/10-configmap-*.json
    "$BUNDLE_DIR"/20-secret-*.json
    "$BUNDLE_DIR"/21-secret-*.json
    "$BUNDLE_DIR"/30-secret-*.json
  )
  shopt -u nullglob

  for f in "${files[@]}"; do
    apply_file "$f"
  done

  log "Target apply complete"
}

verify_target() {
  log "Verifying target namespace and core Rentek config objects"

  run_k "get ns $NAMESPACE >/dev/null"
  run_k "-n $NAMESPACE get configmap assetlinks-config >/dev/null"
  run_k "-n $NAMESPACE get secret registry-1 >/dev/null"

  echo
  echo "== Object presence =="
  run_k "-n $NAMESPACE get configmap assetlinks-config"
  run_k "-n $NAMESPACE get secret registry-1"
  run_k "-n $NAMESPACE get secret docker-auth-config || true"

  echo
  echo "== Assetlinks preview =="
  run_k "-n $NAMESPACE get configmap assetlinks-config -o jsonpath='{.data.assetlinks\.json}'" || true
  echo

  if run_k "-n $NAMESPACE get ingress rentek-ingress >/dev/null 2>&1"; then
    echo
    echo "== Ingress TLS reference =="
    run_k "-n $NAMESPACE get ingress rentek-ingress -o jsonpath='{.spec.tls[0].secretName}'" || true
    echo
  fi

  log "Verify complete"
}

main() {
  need_cmd jq

  local mode="${1:-}"
  [[ -n "$mode" ]] || { usage; exit 1; }
  shift || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubectl)
        KUBECTL_CMD="$2"
        shift 2
        ;;
      --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --bundle-dir)
        BUNDLE_DIR="$2"
        shift 2
        ;;
      --include-tls)
        INCLUDE_TLS="true"
        shift
        ;;
      --tls-secret)
        TLS_SECRET_NAME="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  case "$mode" in
    bundle-source) bundle_source ;;
    apply-target) apply_target ;;
    verify-target) verify_target ;;
    *) echo "Unknown mode: $mode" >&2; usage; exit 1 ;;
  esac
}

main "$@"
