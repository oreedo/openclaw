# Migration log and rollback plan

> Every change made to a live system, in order, with the exact way to undo it. Newest day first. Keep this file updated **as changes happen**, not afterwards.

## Where things stand right now (2026-09-12 05:45 UTC)

| Item | State |
|---|---|
| Website `app.rentek.oreedo.co` | **UP** on the new server, HTTP 200, valid certificate, assetlinks identical to before |
| App version | 0.6.8 |
| Where the app runs | **NEW server** 72.62.93.145 |
| Database | **NEW server**, app connected to it |
| Old server | app and database **stopped (0 replicas)**, all data kept (2.1 GB + 12 backups). Redis still running |
| `mssql.oreedo.co` | 72.62.93.145 |
| `app.rentek.oreedo.co` | answered by your wildcard `*.rentek`; **3 of 4 DNSimple nameservers answer, `ns1` still returns empty** |
| Certificate on the new server | a **copy** of the old wildcard certificate (valid to 2026-10-23). Automatic renewal is **not** set up yet |

**Both migration steps are done: the database and the application now run on the new server.** Remaining work is listed under "Open items".

### Problem 1 (SOLVED 04:33): the Docker Hub token had expired

The stored Docker Hub credential for user `oreedo` is rejected with **HTTP 401**. Both `rentek/registry-1` and `rentek/docker-auth-config` hold the same expired token, and `/root/.docker/config.json` on the old server has it too.

Consequence: the image `oreedo/rentek:0.6.8` cannot be pulled, so the normal app version cannot start. The site runs on 0.6.6 until this is fixed.

Ahmed logged in to Docker again at 04:31. The new credential was verified against Docker Hub, written into the `registry-1` secret, and the image pulled in 630 ms. Version 0.6.8 is running again.

### How the outage happened (honest summary)

1. The app pod had been running for 137 days. Its image was only in the node's local cache.
2. Stopping and starting the app forced Kubernetes to pull the image again, because the policy is `Always`.
3. The pull failed (expired token). Docker Hub returned an **HTML error page**, and containerd stored that page as if it were the image.
4. To clear that corruption I deleted the cached Rentek images from the node. **This was my mistake:** it removed the last working copy of 0.6.8, so the app can no longer start without a valid token.
5. Service was restored by pointing the website at the 0.6.6 app, which was still running untouched.

**Lesson, now a rule:** never delete a cached image while it is the only copy, and never restart a pod whose image cannot be pulled again. Check that the registry login works *before* restarting anything.

---

## Changes made on 2026-09-12, with rollback

Times are UTC.

| # | Time | Change | Where | How to undo it |
|---|---|---|---|---|
| 1 | 03:44 | Created SQL Server: PV, PVC, Deployment, Service (NodePort 1433:31984) | new server, namespace `default` | `ssh hostinger_kvm8 "microk8s kubectl -n default delete deploy/mssql-mssql-deployment svc/mssql-mssql-service pvc/mssql-mssql-pvc; microk8s kubectl delete pv mssql-mssql-pv"` — data stays in `/home/mssql/data` |
| 2 | 03:45 | Restored `Ren_DB` and `Ren_GAM` from backup | new server | nothing to undo; the old database was never touched |
| 3 | 03:46 | Created login `oreedo_user` (copied password hash + SID) | new server | `DROP LOGIN [oreedo_user];` |
| 4 | 03:47 | Set database owner to `oreedo_user` (was `sa` after restore) | new server | `ALTER AUTHORIZATION ON DATABASE::[Ren_DB] TO [sa];` (same for `Ren_GAM`) |
| 5 | ~03:52 | **Ahmed** changed `mssql.oreedo.co` A record to 72.62.93.145 | DNSimple | set the record back to 162.55.210.53 |
| 6 | 03:55 | Stopped the app (`scale --replicas=0`) | old server | `kubectl -n rentek scale deploy/rentek-app2 --replicas=1` |
| 7 | 03:55 | Final data copy old → new | both | nothing to undo |
| 8 | 03:56 | Cleared the DNS cache on the old server | old server | nothing to undo |
| 9 | 03:58 | **Added a CoreDNS entry** in the old cluster: `mssql.oreedo.co -> 72.62.93.145` | old server, `kube-system/coredns` | `kubectl apply -f /tmp/claude-0/.../scratchpad/coredns-backup.yaml` then `kubectl -n kube-system rollout restart deploy/coredns`. A copy is also in this repo: `manifests/backups/coredns-before-override.yaml` |
| 10 | 04:03 | Init container image `busybox:latest` → `busybox:1.36`, pull policy `IfNotPresent` | old server, `rentek-app2` | `kubectl -n rentek patch deploy rentek-app2 --type=json -p '[{"op":"replace","path":"/spec/template/spec/initContainers/0/image","value":"busybox:latest"}]'` |
| 11 | 04:05 | Main container pull policy changed (`Always` → `IfNotPresent` → `Always`) | old server, `rentek-app2` | it is back at `Always`, the original value |
| 12 | 04:10 | **Deleted all cached `oreedo/rentek` images from the node** (my mistake) | old server | **cannot be undone.** The images must be pulled again from Docker Hub with a valid token |
| 13 | 04:13 | Deleted the corrupt blob `sha256:543319d2…` (an HTML page) from containerd | old server | nothing to undo; it was not a real image |
| 14 | 04:22 | Pointed `rentek-svc` at the 0.6.6 app to restore service | old server | done in step 16 |
| 15 | 04:33 | Replaced the `registry-1` pull secret with the new Docker login | old server, namespace `rentek` | `kubectl -n rentek get secret registry-1-backup-20260912 -o json \| jq '.metadata.name="registry-1"' \| kubectl apply -f -` |
| 16 | 04:38 | Pointed `rentek-svc` back at 0.6.8; site verified HTTP 200 | old server | `kubectl -n rentek patch svc rentek-svc -p '{"spec":{"selector":{"app":"rentek-app"}}}'` |
| 19 | 05:12 | Deployed the app on the **new** server: namespace `rentek`, pull secret, ConfigMap `assetlinks-config`, Redis, `rentek-app2` 0.6.8, `rentek-svc` (NodePort 32598) | new server | `ssh hostinger_kvm8 "microk8s kubectl delete namespace rentek"` |
| 20 | 05:20 | Added the `oreedo.co` zone to the new server's `letsencrypt-dnsimple-prod` issuer (it only allowed `oreedo.app`, so no certificate could be issued for our name) | new server | patch the list back to `["oreedo.app"]` |
| 21 | 05:25 | Copied the valid wildcard certificate from the old server into the new one as `tls-oreedo-co-copy`, and created the ingress for `app.rentek.oreedo.co` using it | new server | `microk8s kubectl -n rentek delete ingress rentek-ingress secret/tls-oreedo-co-copy` |
| 22 | 05:35 | Deleted the stuck single-name Certificate `rentek-app-cert` | new server | recreate it, or better, create a wildcard certificate (see Open items) |
| 23 | 05:40 | **Deleted one DNS record** in DNSimple: `_acme-challenge.app.rentek` TXT (id 83976593). cert-manager created it and never removed it; while it existed, `app.rentek.oreedo.co` had no address because a wildcard cannot answer for a name that already exists | DNSimple, zone `oreedo.co` | the record is disposable; cert-manager creates a fresh one whenever a certificate is requested |
| 18 | 05:10 | **Stopped the old stack**: `rentek-app2`, `rentek-app` and `mssql-mssql-deployment` scaled to 0 on the old server. Checked first: no database connections, last write in July/August, fresh backup taken at 05:08 | old server | `kubectl -n rentek scale deploy/rentek-app2 --replicas=1`, `kubectl -n rentek scale deploy/rentek-app --replicas=1`, `kubectl -n default scale deploy/mssql-mssql-deployment --replicas=1`. All data stays on disk; the volumes are untouched and set to Retain |
| 17 | 04:45 | Updated the unused `docker-auth-config` secret with the new Docker login (it still held the expired token) | old server, namespace `rentek` | `kubectl -n rentek get secret docker-auth-config-backup-20260912 -o json \| jq '.metadata.name="docker-auth-config"' \| kubectl apply -f -` |

### Full rollback: return everything to how it was this morning

In this order:

```bash
K="/snap/bin/microk8s kubectl"
# 1. website back to the 0.6.8 app (only after that app can start again)
$K -n rentek patch svc rentek-svc -p '{"spec":{"selector":{"app":"rentek-app2"}}}'
# 2. remove the cluster DNS entry, so the name resolves publicly again
$K apply -f manifests/backups/coredns-before-override.yaml
$K -n kube-system rollout restart deploy/coredns
# 3. Ahmed: set mssql.oreedo.co back to 162.55.210.53 in DNSimple
# 4. the old database is untouched and complete; the app uses it again automatically
```

The only data written to the new database since the switch is what users have done since 04:22. Copy it back before rolling back if that matters.

---

## Planned next steps, each with its rollback

| Step | What happens | Rollback |
|---|---|---|
| ~~N1~~ **done 04:33** | Docker login refreshed and `registry-1` updated | backup secret `registry-1-backup-20260912` |
| ~~N2~~ **done 04:38** | 0.6.8 pulled and serving again | point the service at `app=rentek-app` |
| **N3** Copy the app to the new server (**in progress, started 04:50**) | On the new server only: namespace `rentek`, pull secret, ConfigMap, Redis, app 0.6.8, service, its own certificate, and an ingress for `app.rentek.oreedo.co` that receives no traffic until DNS changes. Tested with a client-side host override. | `ssh hostinger_kvm8 "microk8s kubectl delete namespace rentek"` plus deleting the certificate in `platform-tls`. The old server is not touched at any point. |
| **N4** Test on the new server | Reach it with a host override, not public DNS | nothing to undo |
| **N5** Change `app.rentek.oreedo.co` to the new IP | DNSimple A record (and AAAA if IPv6 is wanted) | set the A record back to 162.55.210.53 |
| **N6** Clean up | Remove the CoreDNS entry once the app and database are on the same server | re-add the entry |

### Rules for every future step

1. Write the step and its rollback here **before** doing it.
2. Never restart a pod before checking that its image can still be pulled.
3. Take a database backup before any step that touches data.
4. After each step, check the website and which database it is using.

### Two small improvements kept from the incident

- The init container now uses **`busybox:1.36`** instead of `busybox:latest`. A fixed version is not re-downloaded on every restart, so a registry problem can no longer stop the app from starting.
- `docker-auth-config` was updated with the working login on 2026-09-12 04:45 (step 17). No pod uses it, but it no longer holds a dead token. Both secrets were verified against Docker Hub afterwards: **both valid**.

---

## Step N3 in detail — copy the app to the new server

Started 2026-09-12 04:50. **The old server is not touched by any sub-step.** The new app receives no real users until the DNS record changes in step N5, which Ahmed does by hand.

### Pre-checks (both passed before anything was built)

| Check | Why it matters | Result |
|---|---|---|
| Can the new server pull `oreedo/rentek:0.6.8`? | today's outage happened because an image could not be pulled | **yes**, complete image, 10 of 10 layers, same digest as production |
| Can a pod there reach `mssql.oreedo.co:31984`? | the database address is locked inside the image | **yes**, by name and by IP |

### Sub-steps, each with its rollback

| # | Action | Rollback |
|---|---|---|
| N3.1 | Create namespace `rentek` on the new server | `ssh hostinger_kvm8 "microk8s kubectl delete namespace rentek"` — removes everything from N3.1 to N3.7 at once |
| N3.2 | Create pull secret `registry-1` from the refreshed Docker login | deleted with the namespace |
| N3.3 | Create ConfigMap `assetlinks-config` (identical to the old server) | deleted with the namespace |
| N3.4 | Deploy Redis (`gx-redis-app` + `gx-redis-svc`) | deleted with the namespace |
| N3.5 | Deploy the app `rentek-app2` (0.6.8, same init container, same volumes) and `rentek-svc` | deleted with the namespace |
| N3.6 | Request a certificate for `app.rentek.oreedo.co` from Let's Encrypt through DNSimple | `microk8s kubectl -n rentek delete certificate rentek-app-cert` and its secret. Creates only a temporary TXT record in DNS, which cert-manager removes itself |
| N3.7 | Create the ingress for `app.rentek.oreedo.co` on the new server | `microk8s kubectl -n rentek delete ingress rentek-ingress`. **It cannot steal traffic**: the public DNS record still points to the old server |
| N3.8 | Test the new app with a client-side host override (`curl --resolve`), not DNS | nothing to undo |

### What is deliberately NOT done in N3

- No DNS change. `app.rentek.oreedo.co` keeps pointing to the old server until Ahmed changes it in N5.
- No change to the old server, so the live site is unaffected throughout.
- The old app keeps running after N5 as the way back.

### Step N5 when it comes (Ahmed changes DNS by hand)

Change `app.rentek.oreedo.co` from `162.55.210.53` to `72.62.93.145` at DNSimple. Lower the TTL to 60 seconds a day earlier, so the change takes effect quickly and can be reversed quickly.

**Rollback for N5:** set the record back to `162.55.210.53`. The old app still runs and still uses the same database, so it keeps working. Only sessions are lost, because each server has its own Redis.

---

## What we learned today (worth keeping)

### A certificate check can take a wildcard name offline

`app.rentek.oreedo.co` has no record of its own; it is answered by the wildcard `*.rentek.oreedo.co`. When cert-manager asked Let's Encrypt for a certificate for that exact name, it created `_acme-challenge.app.rentek.oreedo.co`. From that moment DNS considered `app.rentek.oreedo.co` to "exist with no address", and stopped using the wildcard (RFC 4592). The name went dark until the record was removed.

**This would repeat at every renewal.** Two ways to prevent it, and we should do at least one:

1. Ask for a **wildcard certificate** (`*.rentek.oreedo.co`), as the old server does. Its check record sits at `_acme-challenge.rentek.oreedo.co`, one level higher, which does not block the app name.
2. Add a real A record for `app.rentek`, so the name never depends on the wildcard.

### Never restart a pod before checking its image can be pulled

Today's outage: the app had run for 137 days from a cached image. Restarting it forced a new download, the Docker token had expired, Docker Hub returned an HTML error page, and containerd stored that page as the image. Check the registry login first; keep image tags pinned (`busybox:1.36`, not `busybox:latest`).

---

## Open items

| # | Item | Why it matters |
|---|---|---|
| 1 | Add `app.rentek` A record -> 72.62.93.145 in DNSimple | one DNSimple nameserver (`ns1`) still answers empty for the wildcard name, so some users cannot reach the site |
| 2 | Set up the **wildcard certificate** on the new server | the copied certificate expires 2026-10-23 and does not renew itself |
| 3 | Android app test | Ahmed is testing; assetlinks verified identical and served correctly |
| 4 | Stop Redis on the old server | only remaining running piece there |
| 5 | Rotate the secrets shown in chat: Docker token, Azure keys, GAM and MSSQL passwords | they appeared in a transcript |
| 6 | Securely delete `/root/backups/vault/gx-kv-export-*.json` from the old server | plaintext copy of Vault secrets |
| 7 | Optional: remove ~30 leftover `_acme-challenge` records in the `oreedo.co` zone | old renewal leftovers; harmless but untidy |
| 8 | Decide when to decommission the old server | data is still there; it is the way back |

---

## Before the old server can be shut down

The old server is planned for retirement. Rentek has moved, but the machine still runs other things. Work through this list first.

### 1. What still runs there (checked 2026-09-12)

| Service | Public address | Status |
|---|---|---|
| **Vault** (`vault-server` + injector) | `vault.oreedo.co` | running — **holds the secrets used by Rentek and others** |
| Argo CD (7 parts) | `argocd.oreedo.co` | running |
| Jenkins | `jenkins.oreedo.co` | running |
| Devtron (+ its PostgreSQL) | `devtron.oreedo.co` | running |
| Portainer | `k8s.portainer.oreedo.co` | running |
| n8n | `n8n.oreedo.co` | running |
| Redis of the old Rentek | — | running, no longer needed |
| `nginx-test1` | — | test leftover |
| Keycloak, Odoo, Camunda, PostgreSQL | several `.oreedo.co` names | already scaled to 0, ingresses still exist |
| MSSQL, `rentek-app`, `rentek-app2` | — | **stopped, migrated** |

### 2. The certificate problem (do this first)

The certificate `oreedo-co` in namespace `platform-tls` covers **all** `oreedo.co` names, including `*.rentek.oreedo.co`. It is issued **on the old server** and copied into other namespaces there every 30 minutes.

When the old server is switched off:

- that certificate stops renewing;
- the copy now used by Rentek on the new server (`tls-oreedo-co-copy`) still works until **2026-10-23**, then expires;
- every other `.oreedo.co` service that stays alive elsewhere loses automatic renewal too.

**Action:** set up issuance on the new server before retirement. The new server already has cert-manager, the DNSimple webhook, the API token and, since step 20, permission for the `oreedo.co` zone. Request a wildcard certificate for `*.rentek.oreedo.co` (and any other names that must survive), then point the ingress at it instead of the copy.

### 3. Vault

Vault holds the credentials used by Rentek (Azure storage, OneSignal, Docker, GAM, MSSQL). It must move or be replaced before shutdown. The procedure is written: `docs/vault/VAULT_IMPORT_GUIDE.md` (snapshot restore for everything, or the KV export/import for the `gx/` secrets). A verified snapshot and a plaintext export already exist under `/root/backups/vault/`.

### 4. Data still on the old machine

All of these are hostpath volumes on the old server. Copy or discard each deliberately:

- `/home/mssql/data` — 2.1 GB, the old database plus 12 backups (already copied to the new server)
- Vault storage (`data-vault-server-0`)
- Jenkins (20 GiB), Devtron PostgreSQL (20 GiB), Portainer (10 GiB), Odoo, Camunda Elasticsearch and Zeebe, PostgreSQL

### 5. DNS names pointing at the old server

These still resolve to 162.55.210.53 and must be repointed or removed: `argocd`, `jenkins`, `devtron`, `k8s.portainer`, `n8n`, `keycloak`, `odoo`, `vault`, and the `*.camunda` names. `mssql` and `app.rentek` already point to the new server.

### 6. Final sequence

1. Move or retire each service above, and repoint its DNS name.
2. Set up certificate issuance on the new server (section 2).
3. Move Vault (section 3).
4. Take final backups of every volume in section 4 and copy them off the machine.
5. Leave the server switched on but idle for an agreed period as the way back.
6. Only then shut it down and cancel the subscription.
