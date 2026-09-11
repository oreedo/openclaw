#!/usr/bin/env bash
set -euo pipefail

# Exports the RUNNING Rentek stack as an apply-ready, ordered manifest set.
#
# Why this exists: the app was deployed by hand through Portainer, so neither
# Git (linux-scripts) nor Portainer's own stack files match production — the
# live rentek-app2 has an init container and assetlinks volumes that both of
# them lack. The cluster is the only source of truth, so this regenerates the
# manifests from it (see docs/rentek/RENTEK_SOURCE_ANALYSIS.md).
#
# Secrets are NEVER exported: registry-1 and tls-oreedo-co are prerequisites,
# documented in the generated README. Output is deterministic, so re-running
# after a change produces a reviewable git diff.

KUBECTL_CMD="/snap/bin/microk8s kubectl"
NAMESPACE="rentek"
OUT_DIR="manifests/rentek"
INCLUDE_LEGACY="false"

usage() {
  cat <<'EOF'
Usage:
  rentek-export-manifests.sh [options]

Options:
  --kubectl <cmd>     kubectl command (default: /snap/bin/microk8s kubectl)
  --namespace <ns>    source namespace (default: rentek)
  --out-dir <dir>     output directory (default: manifests/rentek)
  --include-legacy    also export the unused rentek-app 0.6.6 + its PVC
  -h, --help          show help
EOF
}

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
run_k() { eval "$KUBECTL_CMD $*"; }

# Removes cluster-assigned and server-managed fields so the manifest can be
# applied to any cluster, while keeping everything functional.
clean_manifest() {
  jq 'del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid,
          .metadata.generation, .metadata.creationTimestamp, .metadata.selfLink,
          .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
          .metadata.annotations."deployment.kubernetes.io/revision",
          .status, .spec.clusterIP, .spec.clusterIPs, .spec.ipFamilies,
          .spec.ipFamilyPolicy, .spec.internalTrafficPolicy,
          .spec.template.metadata.creationTimestamp)
     | if .kind == "PersistentVolumeClaim" then del(.spec.volumeName, .metadata.annotations."pv.kubernetes.io/bind-completed", .metadata.annotations."pv.kubernetes.io/bound-by-controller", .metadata.annotations."volume.beta.kubernetes.io/storage-provisioner", .metadata.annotations."volume.kubernetes.io/storage-provisioner") else . end'
}

emit() { # emit <kind> <name> <file> <comment>
  local kind="$1" name="$2" file="$3" comment="$4"
  run_k "-n $NAMESPACE get $kind $name -o json" 2>/dev/null | clean_manifest \
    | "$KUBECTL_NEUTRAL_YAML" > "$OUT_DIR/$file" || die "failed to export $kind/$name"
  sed -i "1i # $comment\n# Generated from the live cluster by scripts/cluster/rentek-export-manifests.sh — do not hand-edit." "$OUT_DIR/$file"
  echo "  $OUT_DIR/$file"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubectl) KUBECTL_CMD="$2"; shift 2 ;;
      --namespace) NAMESPACE="$2"; shift 2 ;;
      --out-dir) OUT_DIR="$2"; shift 2 ;;
      --include-legacy) INCLUDE_LEGACY="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die "missing required command: jq"

  # json -> yaml without extra dependencies
  KUBECTL_NEUTRAL_YAML="$(mktemp)"
  cat > "$KUBECTL_NEUTRAL_YAML" <<'PY'
#!/usr/bin/env python3
import json, sys
try:
    import yaml
except ImportError:
    sys.exit("python3-yaml is required (apt-get install -y python3-yaml)")
yaml.safe_dump(json.load(sys.stdin), sys.stdout, default_flow_style=False, sort_keys=False, width=100)
PY
  chmod +x "$KUBECTL_NEUTRAL_YAML"
  trap 'rm -f "$KUBECTL_NEUTRAL_YAML"' EXIT

  mkdir -p "$OUT_DIR"
  log "Exporting namespace $NAMESPACE -> $OUT_DIR"

  run_k "get namespace $NAMESPACE -o json" | clean_manifest | "$KUBECTL_NEUTRAL_YAML" > "$OUT_DIR/00-namespace.yaml"
  sed -i "1i # Namespace (Portainer stack 1).\n# Generated from the live cluster by scripts/cluster/rentek-export-manifests.sh — do not hand-edit." "$OUT_DIR/00-namespace.yaml"
  echo "  $OUT_DIR/00-namespace.yaml"

  emit configmap assetlinks-config 10-configmap-assetlinks.yaml "Android App Links file, served at /.well-known/assetlinks.json (Portainer stack 14)."
  emit deployment gx-redis-app     20-redis-deployment.yaml     "Session store. No volume by design: a restart logs every user out."
  emit service    gx-redis-svc     21-redis-service.yaml        "In-namespace session endpoint used by the app as gx-redis-svc:6379."
  emit deployment rentek-app2      30-rentek-app2-deployment.yaml "ACTIVE app. The init container + assetlinks volumes exist ONLY here: Portainer stack 13 and linux-scripts both lack them."
  emit service    rentek-svc       31-rentek-service.yaml       "NodePort service selecting app=rentek-app2."
  emit ingress    rentek-ingress   40-rentek-ingress.yaml       "Public entry point; TLS secret tls-oreedo-co is replicated in by the platform-tls CronJob."

  if [[ "$INCLUDE_LEGACY" == "true" ]]; then
    emit persistentvolumeclaim rentek-pictures-pvc 90-legacy-pictures-pvc.yaml "LEGACY: empty PVC, only the unused rentek-app mounts it."
    emit deployment rentek-app 91-legacy-rentek-app.yaml "LEGACY: rentek-app 0.6.6, not on the public path. Do not deploy on the target without confirming."
  fi

  cat > "$OUT_DIR/README.md" <<'EOF'
# Rentek manifests (generated from the live cluster)

Regenerate with `bash scripts/cluster/rentek-export-manifests.sh` (add `--include-legacy` for the unused 0.6.6 deployment and its empty PVC). Do not hand-edit: change the cluster, then re-export, so the diff shows what actually changed.

These files exist because the application was deployed by hand through Portainer. Neither `github.com/oreedo/linux-scripts` nor Portainer's own stack files describe what is running: both omit the init container and the assetlinks volumes that the live `rentek-app2` depends on.

## Prerequisites (not in these files)

| Prerequisite | How it is provided |
|---|---|
| `secret/registry-1` | Docker Hub pull credentials — create before applying, or images fail with `ImagePullBackOff` |
| `secret/tls-oreedo-co` | Wildcard certificate, copied in every 30 min by the `platform-tls` replicator CronJob |
| SQL Server reachable on the address baked into the image | see `docs/rentek/RENTEK_SOURCE_ANALYSIS.md` §4.1 |

## Apply order

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 10-configmap-assetlinks.yaml
kubectl apply -f 20-redis-deployment.yaml -f 21-redis-service.yaml
kubectl apply -f 30-rentek-app2-deployment.yaml -f 31-rentek-service.yaml
kubectl apply -f 40-rentek-ingress.yaml
```

Verify with `bash scripts/cluster/rentek-verify-live.sh`.

## Warning about Portainer

Pressing **Update the stack** on Portainer stack 13 re-applies a stored file that has no init container and no assetlinks volumes, which silently breaks `/.well-known/assetlinks.json` (Android App Links). After any Portainer change, re-run the export and review the diff.
EOF
  echo "  $OUT_DIR/README.md"
  log "Export complete"
}

main "$@"
