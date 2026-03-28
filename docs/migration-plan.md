# Kubernetes Cluster Migration Plan

**Source Cluster:** hosted on Hetzner Cloud (~59 EUR/month)  
**Target:** TBD (self-hosted or alternative cloud environment)

---

## Overview
This document outlines a deterministic migration plan for the Kubernetes cluster, with special focus on the critical components:
- **Vault**
- **MSSQL**
- **Rentek**

This document has been updated to reflect the actual observed state of the current cluster, especially the Rentek namespace.

---

## Step 1: Assess Current Cluster

### 1.1 Backup Cluster Configuration
Export the current cluster resources for reference and disaster recovery:

```bash
kubectl get all -A -o yaml > all-resources.yaml
kubectl get ingress,svc,deploy,cm,secret,pvc -A -o yaml > core-resources.yaml
helm list -A > helm-list-summary.txt
```

### 1.2 Capture Object-Level State for Critical Namespaces
For critical namespaces, export targeted manifests rather than relying only on `get all`:

```bash
kubectl -n default get deploy,svc,ingress,cm,secret,pvc -o yaml > default-core.yaml
kubectl -n rentek get deploy,svc,ingress,cm,secret,pvc -o yaml > rentek-core.yaml
kubectl -n devtroncd get deploy,svc,ingress,cm,secret,pvc -o yaml > devtroncd-core.yaml
kubectl -n jenkins get deploy,svc,ingress,cm,secret,pvc -o yaml > jenkins-core.yaml
kubectl -n portainer get deploy,svc,ingress,cm,secret,pvc -o yaml > portainer-core.yaml
```

### 1.3 Specific Components

#### Vault
Create a backup of Vault:

```bash
vault operator snapshot save vault-backup.snap
```

Also secure separately:
- unseal keys
- root token / recovery credentials
- Helm values used for Vault deployment

#### MSSQL
Backup MSSQL databases:

```bash
BACKUP DATABASE [YourDB] TO DISK = N'/var/opt/mssql/backups/YourDB.bak'
```

Also export:
- SQL logins/users if needed
- linked server config (if used)
- MSSQL Helm/manifests
- PVC and storage assumptions

#### Rentek
Do **not** assume the active app is a deployment called `rentek`. The current namespace state is:

- `rentek-app` → image `oreedo/rentek:0.6.6` → running but **not** on the active public path
- `rentek-app2` → image `oreedo/rentek:0.6.7` → **actual active public app**
- `gx-redis-app` → Redis dependency
- `rentek-svc` selector → `app=rentek-app2`
- `rentek-ingress` → `rentek-svc`
- active public hostname → `app.rentek.oreedo.co`
- active pull secret → `registry-1`
- active ConfigMap → `assetlinks-config`

Export the Rentek namespace with the correct objects:

```bash
kubectl -n rentek get deploy rentek-app rentek-app2 gx-redis-app -o yaml > rentek-deployments.yaml
kubectl -n rentek get svc rentek-svc gx-redis-svc -o yaml > rentek-services.yaml
kubectl -n rentek get ingress rentek-ingress -o yaml > rentek-ingress.yaml
kubectl -n rentek get cm assetlinks-config -o yaml > rentek-configmaps.yaml
kubectl -n rentek get secret registry-1 docker-auth-config -o yaml > rentek-pull-secrets.yaml
kubectl -n rentek get pvc rentek-pictures-pvc -o yaml > rentek-pvc.yaml
kubectl -n rentek get endpoints,endpointslice -o yaml > rentek-endpoints.yaml
```

Important: `rentek-app2` is the main deployment lineage and the actual public app. `rentek-app` is a secondary/leftover deployment and must not be treated as the active service target during migration planning.

---

## Step 2: Prepare Target Environment

### 2.1 Install Kubernetes
Choose the destination Kubernetes distribution:
- MicroK8s
- K3s
- kubeadm-based cluster

Minimum baseline:
- working CNI (Calico or equivalent)
- CoreDNS
- ingress controller
- storage class strategy

### 2.2 Replicate Storage Strategy
Review and replicate the storage assumptions per application:
- `microk8s-hostpath` is currently used in the source cluster for several workloads
- destination storage may use a different class, but PVC semantics must remain compatible
- if migrating to a multi-node setup, replace hostpath-only assumptions where appropriate

### 2.3 Install Critical Tools
Install the required control-plane tooling on destination:

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx
```

Also ensure:
- Helm is installed
- wildcard/domain TLS strategy is decided
- secret management plan is defined

---

## Step 3: Restore Critical Components

### 3.1 Vault
1. Deploy Vault using Helm on the new cluster.
2. Restore snapshot:

```bash
vault operator snapshot restore vault-backup.snap
```

3. Verify:
- unseal flow
- policies
- auth methods
- secrets engines
- clients depending on Vault

### 3.2 MSSQL
1. Deploy MSSQL using the target deployment method (Helm or manifests).
2. Restore database backups:

```bash
RESTORE DATABASE [YourDB] FROM DISK = N'/var/opt/mssql/backups/YourDB.bak'
```

3. Verify:
- data integrity
- logins/users
- application connectivity
- storage sizing and IOPS expectations

### 3.3 Rentek
Rentek migration should be done in two layers:

#### Layer A: Portable configuration
Migrate the namespace configuration first:
- namespace
- `assetlinks-config` ConfigMap
- pull secret `registry-1`
- optional `docker-auth-config`
- TLS secret if reusing the same cert strategy

Recommended helper script:
- `docs/cluster/rentek-export-import-config.sh`

Example:

```bash
bash docs/cluster/rentek-export-import-config.sh export \
  --kubectl "kubectl" \
  --namespace rentek \
  --out ./rentek-config-bundle \
  --include-tls
```

Then on destination:

```bash
bash docs/cluster/rentek-export-import-config.sh import \
  --kubectl "kubectl" \
  --namespace rentek \
  --from ./rentek-config-bundle
```

#### Layer B: Workload deployment
Deploy the actual active application objects in this order:

1. `gx-redis-app` + `gx-redis-svc`
2. `rentek-app2`
3. `rentek-svc`
4. `rentek-ingress`

The active production path must remain:
- `rentek-ingress` → `rentek-svc` → selector `app=rentek-app2`

#### Rentek migration caution
There is an important unresolved functional question in the current cluster:

- `rentek-app` mounts `rentek-pictures-pvc` at `/app/Pictures`
- `rentek-app2` does **not** mount that PVC
- yet `rentek-app2` is the active public app

Before production cutover, confirm one of the following:
1. `rentek-app2` no longer requires picture storage, or
2. `rentek-app2` stores files differently, or
3. `rentek-app2` is missing a required volume mount and must be fixed before migration

This is the most important Rentek-specific validation point remaining.

#### What not to do
Do not migrate Rentek by blindly applying an assumed `deployment/rentek` manifest. That object does not represent the actual active public app in the current cluster.

---

## Step 4: Validate and Test

### 4.1 Smoke Testing
#### Vault
- verify pod readiness
- verify unseal process
- verify secret read/write

#### MSSQL
- verify database restore success
- run sanity queries
- validate app login connectivity

#### Rentek
Validate the actual active route and objects:

```bash
kubectl -n rentek get ingress rentek-ingress -o wide
kubectl -n rentek get svc rentek-svc -o wide
kubectl -n rentek get endpoints,endpointslice
kubectl -n rentek get deploy rentek-app2 -o wide
```

Confirm:
- ingress backend points to `rentek-svc`
- `rentek-svc` selector is still `app=rentek-app2`
- endpoints resolve only to `rentek-app2`
- deployed image is the intended version
- `assetlinks-config` is mounted correctly
- pull secret `registry-1` exists and works
- public hostname responds correctly
- any picture/media functionality works as expected

### 4.2 Functional Testing
- test login / session handling
- test mobile app link behavior if relevant
- test any upload/media flows
- test Redis-dependent behavior

### 4.3 Performance Testing
- basic load test or representative smoke load
- verify CPU/memory behavior
- verify ingress response stability

---

## Step 5: Switch Over

### 5.1 Update DNS Records
Point domains to the new target IP(s):
- `app.rentek.oreedo.co`
- other cluster-hosted application domains as needed

### 5.2 Final Validation After DNS Cutover
After DNS cutover:
- verify TLS
- verify ingress routing
- verify external reachability
- verify logs on active services

### 5.3 Decommission Old Cluster
Only decommission the source cluster after:
- Vault validated
- MSSQL validated
- Rentek validated
- DNS stable
- rollback window accepted

---

## Rentek Migration Summary

### Confirmed active production path
- Ingress: `rentek-ingress`
- Service: `rentek-svc`
- Selector: `app=rentek-app2`
- Active image: `oreedo/rentek:0.6.7`
- Pull secret: `registry-1`
- ConfigMap: `assetlinks-config`

### Operational note
`rentek-app` (`0.6.6`) is running in the namespace but is **not** the active public app path. Treat it as a special-case leftover/secondary deployment unless its purpose is explicitly documented before migration.

---

_End of Document_
