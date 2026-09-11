#!/usr/bin/env bash
set -euo pipefail

# Read-only inventory of the Rentek source stack (app, Redis, ingress, TLS
# pipeline, MSSQL, DNS, host). Writes a timestamped bundle of live manifests
# plus a summary to --out-dir. Secrets are recorded by name/type/keys ONLY:
# no secret value, certificate key or password is ever written or printed.
#
# Nothing in this script mutates the cluster.

KUBECTL_CMD="/snap/bin/microk8s kubectl"
NAMESPACE="rentek"
MSSQL_NS="default"
OUT_DIR="/root/backups/rentek-inventory"
INCLUDE_MSSQL_QUERY="false"

usage() {
  cat <<'EOF'
Usage:
  rentek-source-inventory.sh [options]

Options:
  --kubectl <cmd>          kubectl command (default: /snap/bin/microk8s kubectl)
  --namespace <ns>         app namespace (default: rentek)
  --mssql-namespace <ns>   MSSQL namespace (default: default)
  --out-dir <dir>          bundle root, created 0700 (default: /root/backups/rentek-inventory)
  --include-mssql-query    also query SQL Server for databases/logins/backup history
  -h, --help               show help
EOF
}

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
run_k() { eval "$KUBECTL_CMD $*"; }

# Strips server-managed noise so exports are comparable between runs/clusters.
# Strips server-managed noise AND redacts credential-shaped literal env values
# (e.g. SA_PASSWORD in the MSSQL Deployment) so the bundle never carries secrets.
clean() { jq '
  def scrub_env:
    if type == "object" and has("env") then
      .env = [ .env[]? |
        if (.value? and (.name | test("password|secret|key|token|pwd"; "i")))
        then .value = "***REDACTED (\(.value|length) chars)***" else . end ]
    else . end;
  walk(if type == "object" and (has("env") and has("image")) then scrub_env else . end)
  | del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid,
        .metadata.generation, .metadata.creationTimestamp, .metadata.selfLink,
        .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
        .status)'; }

dump() { # dump <kind> <name> <namespace|-> <outfile>
  local kind="$1" name="$2" ns="$3" out="$4" nsflag=""
  [[ "$ns" != "-" ]] && nsflag="-n $ns"
  run_k "$nsflag get $kind $name -o json" 2>/dev/null | clean > "$out" || echo "{}" > "$out"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubectl) KUBECTL_CMD="$2"; shift 2 ;;
      --namespace) NAMESPACE="$2"; shift 2 ;;
      --mssql-namespace) MSSQL_NS="$2"; shift 2 ;;
      --out-dir) OUT_DIR="$2"; shift 2 ;;
      --include-mssql-query) INCLUDE_MSSQL_QUERY="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
  done

  command -v jq >/dev/null 2>&1 || die "missing required command: jq"
  run_k "version --request-timeout=10s >/dev/null 2>&1" || die "cluster not reachable with: $KUBECTL_CMD"

  umask 077
  local stamp bundle
  stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  bundle="$OUT_DIR/$stamp"
  install -d -m 700 "$OUT_DIR" "$bundle" "$bundle/manifests"
  log "Collecting into $bundle"

  # --- application namespace -------------------------------------------------
  run_k "get ns $NAMESPACE -o json" | clean > "$bundle/manifests/namespace.json"
  local kind name
  for kind in deployment service ingress configmap persistentvolumeclaim serviceaccount; do
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      dump "$kind" "$name" "$NAMESPACE" "$bundle/manifests/${kind}-${name}.json"
    done < <(run_k "-n $NAMESPACE get $kind -o jsonpath='{range .items[*]}{.metadata.name}{\"\\n\"}{end}'")
  done

  # Secrets: metadata only, never values.
  run_k "-n $NAMESPACE get secret -o json" \
    | jq '[.items[] | {name: .metadata.name, type: .type, keys: (.data|keys),
                       created: .metadata.creationTimestamp}]' > "$bundle/secrets-metadata.json"

  run_k "-n $NAMESPACE get pods -o wide" > "$bundle/pods.txt" 2>&1 || true
  run_k "-n $NAMESPACE get endpoints -o wide" > "$bundle/endpoints.txt" 2>&1 || true
  run_k "-n $NAMESPACE top pods --no-headers" > "$bundle/top-pods.txt" 2>&1 || true

  # Running images with their resolved digests: the real deployment identity.
  run_k "-n $NAMESPACE get pods -o json" \
    | jq -r '.items[] | .metadata.name as $p | (.status.containerStatuses//[])[] |
             "\($p)\t\(.image)\t\(.imageID)"' > "$bundle/images.tsv" 2>/dev/null || true

  # --- database --------------------------------------------------------------
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dump deployment "$name" "$MSSQL_NS" "$bundle/manifests/mssql-deployment-${name}.json"
  done < <(run_k "-n $MSSQL_NS get deployment -o jsonpath='{range .items[*]}{.metadata.name}{\"\\n\"}{end}'" | grep -i mssql || true)
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dump service "$name" "$MSSQL_NS" "$bundle/manifests/mssql-service-${name}.json"
  done < <(run_k "-n $MSSQL_NS get service -o jsonpath='{range .items[*]}{.metadata.name}{\"\\n\"}{end}'" | grep -i mssql || true)
  run_k "get pv -o json" | jq '[.items[] | select((.spec.claimRef.name//"")|test("mssql|rentek";"i")) |
      {name: .metadata.name, capacity: .spec.capacity.storage, reclaim: .spec.persistentVolumeReclaimPolicy,
       hostPath: (.spec.hostPath.path//null), sc: .spec.storageClassName,
       claim: "\(.spec.claimRef.namespace)/\(.spec.claimRef.name)"}]' > "$bundle/persistent-volumes.json"

  # --- TLS pipeline ----------------------------------------------------------
  run_k "get clusterissuer -o json" 2>/dev/null | clean > "$bundle/manifests/clusterissuers.json" || true
  run_k "get certificate -A -o json" 2>/dev/null \
    | jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name, secret: .spec.secretName,
                       dnsNames: .spec.dnsNames, issuer: .spec.issuerRef.name,
                       notAfter: .status.notAfter, renewalTime: .status.renewalTime,
                       ready: ((.status.conditions//[])[0].status)}]' > "$bundle/certificates.json" || true
  run_k "-n platform-tls get cronjob -o json" 2>/dev/null | clean > "$bundle/manifests/tls-replicator-cronjob.json" || true

  # Certificate actually served in the app namespace (public data only).
  local crt
  crt="$(run_k "-n $NAMESPACE get secret tls-oreedo-co -o jsonpath='{.data.tls\\.crt}'" 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -n "$crt" ]]; then
    printf '%s' "$crt" | openssl x509 -noout -subject -issuer -enddate -fingerprint -sha256 \
      > "$bundle/served-certificate.txt" 2>/dev/null || true
    printf '%s' "$crt" | openssl x509 -noout -ext subjectAltName >> "$bundle/served-certificate.txt" 2>/dev/null || true
  fi

  # --- ingress + platform ----------------------------------------------------
  run_k "get ingress -A -o json" | jq '[.items[] | {ns: .metadata.namespace, name: .metadata.name,
      class: (.spec.ingressClassName // .metadata.annotations."kubernetes.io/ingress.class"),
      hosts: [.spec.rules[]?.host], tls: [(.spec.tls//[])[].secretName],
      annotations: .metadata.annotations}]' > "$bundle/ingresses.json"
  run_k "-n ingress get daemonset -o json" 2>/dev/null \
    | jq -r '.items[] | "\(.metadata.name)\t\(.spec.template.spec.containers[0].image)\t\((.spec.template.spec.containers[0].args//[])|join(" "))"' \
    > "$bundle/ingress-controller.txt" 2>/dev/null || true
  { /snap/bin/microk8s helm list -A 2>/dev/null || true; } > "$bundle/helm-releases.txt"

  # --- DNS + host ------------------------------------------------------------
  {
    local host
    for host in app.rentek.oreedo.co vault.oreedo.co mssql.oreedo.co oreedo.co; do
      printf '%-24s A=%s AAAA=%s CNAME=%s TTL=%s\n' "$host" \
        "$(dig +short A "$host" | tr '\n' ' ')" "$(dig +short AAAA "$host" | tr '\n' ' ')" \
        "$(dig +short CNAME "$host" | tr '\n' ' ')" \
        "$(dig +noall +answer A "$host" | awk 'NR==1{print $2}')"
    done
    echo "NS:  $(dig +short NS oreedo.co | tr '\n' ' ')"
    echo "CAA: $(dig +short CAA oreedo.co | tr '\n' ' ')"
  } > "$bundle/dns.txt" 2>&1

  {
    echo "hostname: $(hostname)"
    echo "os:       $(. /etc/os-release; echo "$PRETTY_NAME") / $(uname -r)"
    echo "cpu/ram:  $(nproc) cores, $(free -g | awk '/Mem:/{print $2"Gi"}')"
    echo "ipv4:     $(ip -4 addr show scope global | grep -oP 'inet \K[\d.]+' | head -1)"
    echo "ipv6:     $(ip -6 addr show scope global | grep -oP 'inet6 \K[0-9a-f:]+' | head -1)"
    echo "k8s:      $(/snap/bin/microk8s version 2>/dev/null | head -1)"
    echo "firewall: $(ufw status 2>/dev/null | head -1)"
    df -h / | tail -1
  } > "$bundle/host.txt" 2>&1

  # --- optional database query (no credentials printed) ----------------------
  if [[ "$INCLUDE_MSSQL_QUERY" == "true" ]]; then
    local mpod
    mpod="$(run_k "-n $MSSQL_NS get pod -o name" | grep mssql-mssql-deployment | head -1 || true)"
    if [[ -n "$mpod" ]]; then
      cat <<'SQL' | run_k "-n $MSSQL_NS exec -i $mpod -- bash -c 'cat > /tmp/inv.sql; S=\$(ls /opt/mssql-tools*/bin/sqlcmd|head -1); \$S -S localhost -U sa -P \"\$SA_PASSWORD\" -C -h -1 -W -s\"|\" -i /tmp/inv.sql; rm -f /tmp/inv.sql'" > "$bundle/mssql-databases.txt" 2>&1 || true
SET NOCOUNT ON;
SELECT 'VERSION', CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')), CONVERT(varchar(60), SERVERPROPERTY('Edition'));
SELECT 'DB', d.name, CAST(SUM(mf.size)*8/1024 AS varchar(20))+' MB', d.recovery_model_desc, d.collation_name
FROM sys.databases d JOIN sys.master_files mf ON mf.database_id=d.database_id
GROUP BY d.name, d.recovery_model_desc, d.collation_name ORDER BY d.name;
SELECT 'LOGIN', name, type_desc FROM sys.server_principals
WHERE type IN ('S','U','G') AND name NOT LIKE '##%' AND name NOT LIKE 'NT %' ORDER BY name;
SELECT 'LASTBACKUP', database_name, MAX(CONVERT(varchar(19), backup_finish_date, 120))
FROM msdb.dbo.backupset GROUP BY database_name;
SQL
    fi
  fi

  # --- summary ---------------------------------------------------------------
  {
    echo "# Rentek source inventory — $stamp"
    echo
    echo "## Running images"; sed 's/^/    /' "$bundle/images.tsv" 2>/dev/null
    echo; echo "## Served certificate"; sed 's/^/    /' "$bundle/served-certificate.txt" 2>/dev/null
    echo; echo "## DNS"; sed 's/^/    /' "$bundle/dns.txt"
    echo; echo "## Host"; sed 's/^/    /' "$bundle/host.txt"
    echo; echo "## Secrets present (names/types only)"
    jq -r '.[] | "    \(.name)  type=\(.type)  keys=\(.keys|join(","))"' "$bundle/secrets-metadata.json"
    echo; echo "Manifests: $(ls "$bundle/manifests" | wc -l) files in $bundle/manifests"
  } > "$bundle/SUMMARY.md"

  log "Inventory complete"
  echo "  bundle:    $bundle"
  echo "  manifests: $(ls "$bundle/manifests" | wc -l)"
  echo "  summary:   $bundle/SUMMARY.md"
}

main "$@"
