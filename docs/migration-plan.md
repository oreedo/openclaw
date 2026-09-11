# Kubernetes Cluster Migration Plan

**Source Cluster:** hosted on Hetzner Cloud (~59 EUR/month)  
**Target:** TBD (self-hosted or alternative cloud environment)

---

## Overview
This document outlines a deterministic migration plan for the Kubernetes cluster, with special focus on the critical components:
- **Vault**
- **MSSQL**
- **Rentek**

This document is intentionally script-driven. The goal is to avoid copy/paste-heavy migration work and replace it with reusable, idempotent scripts.

---

## Guiding Principle
For repeated operations, prefer:
- reusable scripts
- parameterized execution
- idempotent `apply` behavior
- verification scripts

Avoid migration steps that depend on ad-hoc manual shell snippets when a stable script can do the same job.

Scripts should live under the top-level `scripts/` folder beside `docs/`, not inside `docs/`.

---

## Step 1: Assess Current Cluster

### 1.1 Backup Cluster Configuration
Create cluster reference exports for disaster recovery and comparison:

```bash
kubectl get all -A -o yaml > all-resources.yaml
kubectl get ingress,svc,deploy,cm,secret,pvc -A -o yaml > core-resources.yaml
helm list -A > helm-list-summary.txt
```

These are reference exports, not the preferred migration mechanism.

### 1.2 Capture Object-Level State for Critical Namespaces
Export targeted manifests for critical namespaces:

```bash
kubectl -n default get deploy,svc,ingress,cm,secret,pvc -o yaml > default-core.yaml
kubectl -n rentek get deploy,svc,ingress,cm,secret,pvc -o yaml > rentek-core.yaml
kubectl -n devtroncd get deploy,svc,ingress,cm,secret,pvc -o yaml > devtroncd-core.yaml
kubectl -n jenkins get deploy,svc,ingress,cm,secret,pvc -o yaml > jenkins-core.yaml
kubectl -n portainer get deploy,svc,ingress,cm,secret,pvc -o yaml > portainer-core.yaml
```

### 1.3 Specific Components

#### Vault
Source: Bitnami chart, `bitnami/vault:1.18.5`, StatefulSet `default/vault-server` (1 replica), Raft integrated storage, Shamir seal (5 shares / threshold 3), reachable at `https://vault.oreedo.co`.

Backup = Raft snapshot, taken by the userpass identity `claude-code`. Its `claude-code-policy` stays read-only; the snapshot line is the only addition to its `gx/*` read/list rule:

```hcl
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]   # GET = download a snapshot; restore needs update, deliberately not granted
}
```

```bash
bash scripts/vault/install-vault-cli.sh          # verified Vault CLI 1.18.5 (idempotent)
# human, in their own SSH terminal (needs a real TTY; the password never passes through the assistant):
unset VAULT_TOKEN; VAULT_ADDR=https://vault.oreedo.co vault login -no-print -method=userpass username=claude-code
bash scripts/vault/vault-backup.sh --revoke-token  # -> /root/backups/vault/<cluster>-<UTC>.snap (+ .sha256, .inspect.txt)
```

A portable plaintext copy of the `gx/` KV secrets — for a target Vault that keeps its own unseal keys — comes from `scripts/vault/vault-kv-export.sh`; see `docs/vault/VAULT_IMPORT_GUIDE.md`.

The password prompt runs in raw mode: Backspace is taken literally, so on a typo press Ctrl-C and retype. `-no-print` keeps the token out of the terminal (it lands in `/root/.vault-token`, 0600). The script checks the token's capability first, validates the snapshot with `vault operator raft snapshot inspect`, and writes root-only files outside the repo. First backup: 2026-09-11, Raft index 4054 (current at capture). Copy snapshots off this host.

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

Use the verification script instead of manually re-running audit commands:

- `scripts/cluster/rentek-verify-live.sh`

Example:

```bash
source ~/.bashrc
bash scripts/cluster/rentek-verify-live.sh --kubectl kubectl
```

---

## Step 1.5: Transition architecture, pilot and gradual migration

A single big-bang move of Rentek is risky for one reason: the database endpoint and every credential are GeneXus-encrypted **inside the image** (`docs/rentek/RENTEK_SOURCE_ANALYSIS.md` §4.1, finding F1), so the app cannot simply be told to use a new database. This section turns that into a sequence of small, reversible steps.

### The enabler: the app talks to a routable address

The app connects to `162.55.210.53:31984` — the node's public IP on the MSSQL NodePort — proven from SQL Server itself (`oreedo_user` connecting from that address). Because that is a *routable* destination rather than a cluster DNS name, it can be redirected **per pod**, with no image change:

```yaml
# init container in the app pod; the rule lives only in THIS pod's network namespace
initContainers:
- name: db-redirect
  image: alpine:3.20
  securityContext: { capabilities: { add: ["NET_ADMIN"] } }
  command: ["sh","-c","apk add --no-cache iptables >/dev/null &&     iptables -t nat -A OUTPUT -p tcp -d 162.55.210.53 --dport 31984     -j DNAT --to-destination ${TARGET_DB_HOST}:${TARGET_DB_PORT}"]
```

This is a **temporary shim**, not the destination: it is invisible to anyone reading the Deployment casually, it must be re-applied on every pod start (the init container does that), and it should be removed once the image is rebuilt with a proper datasource. Its value is that it decouples "move the workload" from "rebuild in GeneXus", and it is reversible by deleting the init container.

If instead the encrypted datasource turns out to be a *hostname*, the same job is done more cleanly with `hostAliases` — which is why the probe below runs first.

### P0 — Datasource probe (answers open question O1)

Cheapest possible experiment, isolated from production: an app pod in its own namespace with **all egress blocked except DNS**. Its startup error tells us which mechanism to use:

| Observed in the pod log | Meaning | Mechanism for every later step |
|---|---|---|
| DNS resolution failure for a name | datasource is a hostname | `hostAliases` — clean, no privileges |
| TCP timeout to `162.55.210.53:31984` | datasource is an IP literal | pod-local DNAT init container |

**Safety rule:** verify the egress policy with a throwaway `busybox` pod *before* starting the application image. An unrestricted second instance of the app against the production database could attempt GeneXus reorganisation or GAM initialisation. Procedure: `docs/runbooks/RUNBOOKS.md` RB-10.

### P1 — Pilot on the source server (no new hardware)

Prove the manifests, the redirect and the full user journey without touching production objects:

| Component | Pilot choice | Why it is safe |
|---|---|---|
| Namespace | `rentek-pilot` | production objects untouched; rollback = delete the namespace |
| Database | a second MSSQL pod with `Ren_DB`/`Ren_GAM` **restored from backup** | real data, zero risk to the live database |
| Redirect | P0's mechanism, pointing at the pilot database | proves the technique that the migration depends on |
| Hostname | `pilot.rentek.oreedo.co` | already resolves (wildcard A record) and is already covered by the `*.rentek.oreedo.co` certificate — no DNS or TLS work |
| Redis | its own deployment | sessions never mix |
| **OneSignal** | **egress blocked** | otherwise the pilot sends push notifications to real users |
| **Azure Blob** | same account (credentials are baked in) — read freely, avoid destructive tests, or block egress and accept that uploads fail | the one dependency a pilot cannot fully isolate |

What P1 validates: the exported manifests deploy cleanly, GAM login works against restored data, the redirect works, and the app behaves with a database that is not the original. What it does not validate: cross-host latency.

### P2–P4 — Target build, deploy and rehearsal

- **P2 Build the target**: Kubernetes, ingress controller, storage class, cert-manager with the DNSimple webhook (reuse `setup-cert-manager-oreedo-co.sh`). DNS-01 issues certificates **before** any traffic moves, so TLS is ready in advance.
- **P3 Deploy and test without DNS**: bring the stack up on the target and exercise it through a client-side override — `curl --resolve app.rentek.oreedo.co:443:<NEW_IP>` and a hosts entry for browsers. Production DNS is untouched, so there is nothing to roll back.
- **P4 Rehearse the data cutover and time it**: final backup → restore → verify table counts (232 / 85). Today's data is ~0.4 GB and compresses to a few MB, so the window should be minutes; measure it rather than assume.

### P5 — Choose how gradual to be

| Strategy | Sequence | Best when | Trade-off |
|---|---|---|---|
| **A. Split move, database first** (recommended gradual path) | move DB to target → app on the source redirects to it → later move the app | you want two small reversible steps | every query crosses hosts until the app follows; needs a fast private link |
| **B. Lift and shift with the shim** | move app + DB together in one window, shim in place, rebuild the image later | you want the shortest exposure and a single window | the shim is live in production until the rebuild |
| **C. Rebuild first** | GeneXus rebuild with the target datasource → then move | GeneXus access and a build pipeline are available now | slowest to start; needs the build environment |

All three converge on P7. **B is the pragmatic default**; A is the answer if a single window is unacceptable; C is the cleanest if the rebuild can happen soon.

A true parallel run (both sites serving users at once) is **not** available here: two app instances would need two databases, and there is no replication between them. Keep the canary phase read-mostly and short.

### P6 — Cutover

Follow `docs/runbooks/RUNBOOKS.md` RB-6 (lower TTL to 60 s a day ahead, freeze writes, final delta restore, switch the A record, verify, keep the source intact for the agreed rollback window).

### P7 — Remove the scaffolding

1. Rebuild the image in GeneXus with the target datasource and drop the redirect init container.
2. Rotate what the image exposes: OneSignal REST key, Azure Storage keys, the `oreedo_user` password (F6).
3. Move off SQL Server Developer Edition (F3), enable scheduled backups (`scripts/cluster/mssql-backup.sh`, F4), add probes and resource limits (F7), and close the NodePort exposure (F2).

### Decision checkpoints

| After | Question | If the answer is bad |
|---|---|---|
| P0 | IP literal or hostname? | either is workable; it only selects the mechanism |
| P1 | Does the app run against a restored database via the redirect? | stop and go to strategy C — a GeneXus rebuild is then on the critical path |
| P4 | Is the measured cutover window acceptable? | add log shipping or schedule a longer maintenance window |
| P6 | Does the target serve real traffic correctly within the rollback window? | switch the A record back; the source is still intact |

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
Two options, both with step-by-step commands in `docs/vault/VAULT_IMPORT_GUIDE.md`:

1. **Snapshot restore** — everything (engines, policies, auth methods and users, identity). Deploy Vault 1.18.5 with Raft storage and initialize it, then restore with a token allowed `update` on `sys/storage/raft/snapshot-force`: `vault operator raft snapshot restore -force <cluster>-<UTC>.snap`, through a `kubectl port-forward` rather than the ingress (its 1 MiB body limit answers `413`). `-force` is required because the new cluster has different unseal keys. Afterwards the cluster unseals with the **source** cluster's Shamir keys (3 of 5), the target's init root token stops working, and anything written to the source after the snapshot is lost.
2. **KV JSON import** — only the `gx/` secrets, into a Vault that keeps its own fresh unseal keys: `scripts/vault/vault-kv-export.sh` on the source, then `scripts/vault/vault-kv-import.sh` against the target. Policies, auth methods and users have to be recreated by hand.

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
Rentek migration should be done in two layers.

#### Layer A: Portable configuration
Use the idempotent script:
- `scripts/cluster/rentek-config-migrate.sh`

This script handles:
- namespace
- `assetlinks-config` ConfigMap
- pull secret `registry-1`
- optional `docker-auth-config`
- optional ingress TLS secret

##### Source-side bundle creation

```bash
source ~/.bashrc
bash scripts/cluster/rentek-config-migrate.sh bundle-source \
  --kubectl kubectl \
  --namespace rentek \
  --bundle-dir ./rentek-config-bundle \
  --include-tls
```

##### Target-side apply

```bash
source ~/.bashrc
bash scripts/cluster/rentek-config-migrate.sh apply-target \
  --kubectl kubectl \
  --namespace rentek \
  --bundle-dir ./rentek-config-bundle
```

##### Target-side verification

```bash
source ~/.bashrc
bash scripts/cluster/rentek-config-migrate.sh verify-target \
  --kubectl kubectl \
  --namespace rentek
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
Use the read-only verification script:

```bash
source ~/.bashrc
bash scripts/cluster/rentek-verify-live.sh --kubectl kubectl --namespace rentek
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

### Script inventory
- `scripts/cluster/rentek-config-migrate.sh` — idempotent bundle/apply/verify for portable Rentek config
- `scripts/cluster/rentek-verify-live.sh` — read-only live verification of active Rentek routing and deployment state

---

_End of Document_
