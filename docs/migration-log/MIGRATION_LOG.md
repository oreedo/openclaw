# Migration log and rollback plan

> Every change made to a live system, in order, with the exact way to undo it. Newest day first. Keep this file updated **as changes happen**, not afterwards.

## Where things stand right now (2026-09-12 04:40 UTC)

| Item | State |
|---|---|
| Website `app.rentek.oreedo.co` | **UP**, HTTP 200, assetlinks HTTP 200 |
| App version serving users | **0.6.8** (normal version, restored) |
| Where the app runs | still the **old** server |
| Database used by the app | **NEW server** 72.62.93.145 (confirmed from the database side) |
| Old database | still running, no longer used, data still complete |
| `mssql.oreedo.co` | points to 72.62.93.145 (public DNS) **and** is overridden inside the old cluster |

**Step one of the migration (database first) is complete and working.**

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
| **N3** Copy the app to the new server | Create namespace, secret, ConfigMap, Redis, app and ingress on the new server from `manifests/rentek/`, using a test name first | delete the namespace on the new server; the old server keeps serving |
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
