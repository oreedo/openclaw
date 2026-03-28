#!/usr/bin/env bash
set -euo pipefail

# Read-only live verification for Rentek active path and deployment state.

KUBECTL_CMD="/snap/bin/microk8s kubectl"
NAMESPACE="rentek"

usage() {
  cat <<'EOF'
Usage:
  rentek-verify-live.sh [options]

Options:
  --kubectl <cmd>      kubectl command to use
                       default: /snap/bin/microk8s kubectl
  --namespace <name>   namespace
                       default: rentek
  -h, --help           show help
EOF
}

run_k() {
  # shellcheck disable=SC2086
  eval "$KUBECTL_CMD $*"
}

main() {
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

  echo "== Rentek inventory =="
  run_k "-n $NAMESPACE get deploy,svc,ingress,pods,cm,secret,pvc"
  echo

  echo "== Active ingress path =="
  run_k "-n $NAMESPACE get ingress rentek-ingress -o wide"
  run_k "-n $NAMESPACE get svc rentek-svc -o wide"
  run_k "-n $NAMESPACE get endpoints,endpointslice"
  echo

  echo "== Active image and pull secret =="
  run_k "-n $NAMESPACE get deploy rentek-app2 -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}pullSecret={.spec.template.spec.imagePullSecrets[0].name}{"\n"}'"
  echo

  echo "== Secondary deployment comparison =="
  run_k "-n $NAMESPACE get deploy rentek-app -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}volumeMount={.spec.template.spec.containers[0].volumeMounts[0].mountPath}{"\n"}'" || true
  echo

  echo "== Assetlinks config =="
  run_k "-n $NAMESPACE get configmap assetlinks-config -o jsonpath='{.data.assetlinks\.json}'" || true
  echo
}

main "$@"
