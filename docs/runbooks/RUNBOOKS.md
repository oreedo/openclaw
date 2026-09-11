# Runbooks — Rentek stack on `oreedo-ubuntu`

> Operational procedures for the source server. Background and the full inventory: `docs/rentek/RENTEK_SOURCE_ANALYSIS.md`. Every command assumes you are root on `oreedo-ubuntu` and in `/home/openclaw`.
>
> **Cluster access:** use `/snap/bin/microk8s kubectl`. `kubectl` is an interactive-only shell alias and bare `helm` is an unrelated binary (see `CLAUDE.md`). The repo scripts already default to the right command.
>
> **Anything here marked _mutating_ affects production immediately.** There is one replica of each workload and no staging environment.

| # | Runbook | Mutating? |
|---|---|---|
| RB-1 | Health check and triage | no |
| RB-2 | Collect the source inventory | no |
| RB-3 | Database backup and restore | backup: yes (safe) · restore: **destructive** |
| RB-4 | TLS: verify, force renewal, repair replication | verify: no · force: yes |
| RB-5 | Deploy a new application version / roll back | **yes, causes downtime** |
| RB-6 | DNS cutover | **yes** |
| RB-7 | Migrate the stack to a new cluster | **yes** |
| RB-8 | Redis restart and session loss | **yes** |
| RB-9 | Changing the app through Portainer without losing configuration | **yes** |

---

## RB-1 — Health check and triage (read-only)

Run this first for any "the app is down/slow" report.

```bash
bash scripts/cluster/rentek-verify-live.sh            # inventory, routing, image, assetlinks
/snap/bin/microk8s kubectl -n rentek get pods -o wide
/snap/bin/microk8s kubectl -n rentek logs deploy/rentek-app2 --tail=50
curl -s -o /dev/null -w 'public: HTTP %{http_code} in %{time_total}s\n' https://app.rentek.oreedo.co/mobilewebapp.mwapphome
```

Expected: `/` returns **302** to `/mobilewebapp.mwapphome`, which returns **200**; one `rentek-app2` pod `1/1 Running`; `rentek-svc` endpoint equals that pod's IP.

Triage table:

| Symptom | Most likely cause | Next step |
|---|---|---|
| 503 from nginx | pod not ready / endpoint empty | `kubectl -n rentek get endpoints rentek-svc`; check pod events |
| 502 with pod running | app crashed inside the container (no probes exist to catch it) | check logs, then RB-5 restart |
| TLS warning or expired cert | replication stalled | RB-4 |
| App loads, data errors | database unreachable or full | RB-3 checks, `kubectl -n default get pod | grep mssql` |
| Everyone logged out | Redis restarted (no persistence, by design) | RB-8 |
| Slow first request after idle | GeneXus warm-up + new DB pool | normal; ~300 ms observed warm |

Database reachability from the app's perspective (the app connects via the node IP, not a Service):

```bash
/snap/bin/microk8s kubectl -n rentek exec deploy/rentek-app2 -c rentek -- \
  bash -c 'timeout 3 bash -c "</dev/tcp/162.55.210.53/31984" && echo "DB port reachable"'
```

---

## RB-2 — Collect the source inventory (read-only)

Produces a timestamped, secret-free bundle of live manifests plus a summary. Run before any change, and always before a migration step.

```bash
bash scripts/cluster/rentek-source-inventory.sh --include-mssql-query
# -> /root/backups/rentek-inventory/<UTC>/{SUMMARY.md,manifests/,dns.txt,host.txt,...}
```

Secrets appear by **name/type/keys only**, and credential-shaped env values (e.g. `SA_PASSWORD`) are redacted. The bundle is safe to copy to the target server, but keep it out of Git.

---

## RB-3 — Database backup and restore

### 3a. Backup (safe, run any time)

```bash
bash scripts/cluster/mssql-backup.sh                 # COPY_ONLY full backup of Ren_DB + Ren_GAM, verified, keep 7
bash scripts/cluster/mssql-backup.sh --dry-run       # show what would run
bash scripts/cluster/mssql-backup.sh --keep 14 --databases "Ren_DB"
```

Each backup is written to `/var/opt/mssql/data/backups` inside the pod — on the host that is `/home/mssql/data/data/backups`, on the PV, so it survives pod restarts. Every backup is checked with `RESTORE VERIFYONLY ... WITH CHECKSUM` before retention runs. Compressed sizes are ~2–4 MB per database.

**Copy backups off the server** — they are useless if the host dies:

```bash
scp 'root@162.55.210.53:/home/mssql/data/data/backups/*.bak' .
```

Recommended regular schedule (not yet configured — see finding F4): a daily full plus, while the databases stay in FULL recovery, a log backup every few hours; otherwise switch them to SIMPLE. To automate on the host:

```bash
# /etc/cron.d/mssql-backup
0 2 * * * root /bin/bash /home/openclaw/scripts/cluster/mssql-backup.sh --full-chain --keep 7 >> /var/log/mssql-backup.log 2>&1
```

### 3b. Restore (destructive — overwrites the database)

Verify the file first, take a fresh backup of the current state, then restore:

```bash
K="/snap/bin/microk8s kubectl"; MPOD=$($K -n default get pod -o name | grep mssql-mssql-deployment | head -1)
cat <<'SQL' | $K -n default exec -i $MPOD -- bash -c 'cat > /tmp/r.sql; S=$(ls /opt/mssql-tools*/bin/sqlcmd|head -1); $S -S localhost -U sa -P "$SA_PASSWORD" -C -b -i /tmp/r.sql; rm -f /tmp/r.sql'
RESTORE VERIFYONLY FROM DISK = N'/var/opt/mssql/data/backups/Ren_DB-<STAMP>.bak' WITH CHECKSUM;
ALTER DATABASE [Ren_DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE [Ren_DB] FROM DISK = N'/var/opt/mssql/data/backups/Ren_DB-<STAMP>.bak' WITH REPLACE, RECOVERY;
ALTER DATABASE [Ren_DB] SET MULTI_USER;
SQL
```

Restoring into a **different** server additionally needs the `oreedo_user` login recreated and mapped (the login lives in `master`, the user in the database):

```sql
CREATE LOGIN [oreedo_user] WITH PASSWORD = N'<password>';   -- from the app owner / GeneXus config
USE [Ren_DB]; ALTER USER [oreedo_user] WITH LOGIN = [oreedo_user];
USE [Ren_GAM]; ALTER USER [oreedo_user] WITH LOGIN = [oreedo_user];
```

Verify afterwards: `SELECT COUNT(*) FROM Ren_DB.sys.tables;` → **232**, `Ren_GAM` → **85**, then RB-1.

---

## RB-4 — TLS: verify, force renewal, repair replication

The chain is: cert-manager (DNS-01 via DNSimple) → `platform-tls/tls-oreedo-co` → CronJob every 30 min → `rentek/tls-oreedo-co` → ingress-nginx.

### 4a. Verify (read-only)

```bash
K="/snap/bin/microk8s kubectl"
$K get certificate -A                                     # READY=True, check RENEWAL/NOTAFTER
$K -n platform-tls get cronjob,job --sort-by=.metadata.creationTimestamp | tail -5
$K -n platform-tls logs $($K -n platform-tls get pod --sort-by=.metadata.creationTimestamp -o name | tail -1)
# the certificate actually served to users:
echo | openssl s_client -connect app.rentek.oreedo.co:443 -servername app.rentek.oreedo.co 2>/dev/null \
  | openssl x509 -noout -subject -enddate -fingerprint -sha256
# must match the source secret:
$K -n platform-tls get secret tls-oreedo-co -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -enddate -fingerprint -sha256
```

Fingerprints must be identical. If `rentek` lags behind `platform-tls`, the replicator is the problem, not cert-manager.

### 4b. Force a renewal (mutating, safe)

```bash
/snap/bin/microk8s kubectl -n platform-tls delete secret tls-oreedo-co   # cert-manager re-issues within ~minutes
/snap/bin/microk8s kubectl -n platform-tls describe certificate oreedo-co | tail -20
```

DNS-01 requires the DNSimple API token in `cert-manager/dnsimple-api-token` to be valid; renewal fails silently at the Order/Challenge level if it is not. Check with `kubectl get order,challenge -A`.

### 4c. Repair replication

```bash
/snap/bin/microk8s kubectl -n platform-tls create job --from=cronjob/tls-secret-replicator-co tls-replicate-manual
/snap/bin/microk8s kubectl -n platform-tls logs job/tls-replicate-manual
```

The job is idempotent (`create secret tls --dry-run=client | kubectl apply -f -`) and logs a warning for namespaces that do not exist (`argocd`, `kie-system` — expected). ingress-nginx reloads automatically; no restart is needed.

The whole pipeline can be rebuilt from `/home/scripts/linux-scripts/keys/certs/oreedo-co/ngnix/setup-cert-manager-oreedo-co.sh` (phases 1–5, `--verify`, `--cleanup-old-secrets`).

---

## RB-5 — Deploy a new application version / roll back

**The image *is* the configuration.** Database endpoint, credentials, Azure Storage keys and OneSignal keys all live inside it (analysis §4). A new database or storage account therefore requires a **GeneXus rebuild**, not a Kubernetes edit.

With `strategy: Recreate` and one replica, **every deploy is a short outage**.

```bash
K="/snap/bin/microk8s kubectl"
# 1. record what is running now (for rollback)
$K -n rentek get deploy rentek-app2 -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
$K -n rentek get pod -l app=rentek-app2 -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'

# 2. deploy (mutating)
$K -n rentek set image deploy/rentek-app2 rentek=oreedo/rentek:<NEW_TAG>
$K -n rentek annotate deploy/rentek-app2 kubernetes.io/change-cause="oreedo/rentek:<NEW_TAG>" --overwrite
$K -n rentek rollout status deploy/rentek-app2 --timeout=180s

# 3. verify
bash scripts/cluster/rentek-verify-live.sh && curl -s -o /dev/null -w '%{http_code}\n' https://app.rentek.oreedo.co/mobilewebapp.mwapphome
```

Rollback:

```bash
/snap/bin/microk8s kubectl -n rentek rollout undo deploy/rentek-app2
# or pin the exact previous build by digest (tags are mutable — see finding F9):
/snap/bin/microk8s kubectl -n rentek set image deploy/rentek-app2 rentek=oreedo/rentek@sha256:<PREVIOUS_DIGEST>
```

Restarting without changing the version: `kubectl -n rentek rollout restart deploy/rentek-app2` (still an outage; also clears the in-container Lucene index and the offline SQLite store, both of which the app rebuilds).

---

## RB-6 — DNS cutover

`app.rentek.oreedo.co` is a single **A record at DNSimple, TTL 3600**, pointing at 162.55.210.53. There is no AAAA record and the ingress has no IPv6 path, so do not add AAAA unless the target serves IPv6.

1. **At least 24 h before:** lower the TTL to 60 s in DNSimple, then confirm: `dig +noall +answer A app.rentek.oreedo.co`.
2. **Prepare the target:** application running, certificate already issued there (DNS-01 works before any traffic moves), database restored and verified.
3. **Freeze writes** if data consistency matters, take a final backup (RB-3a) and restore it to the target.
4. **Switch** the A record to the new IP.
5. **Verify** from outside the servers:
   ```bash
   dig +short A app.rentek.oreedo.co
   curl -sI https://app.rentek.oreedo.co/mobilewebapp.mwapphome | head -3
   echo | openssl s_client -connect app.rentek.oreedo.co:443 -servername app.rentek.oreedo.co 2>/dev/null | openssl x509 -noout -issuer -enddate
   ```
6. **Keep the old server running** for at least the old TTL plus a safety margin; clients and the mobile app cache DNS. Watch the old app's logs for stragglers: `kubectl -n rentek logs deploy/rentek-app2 --tail=20 -f`.
7. **Raise the TTL** back to 3600 once stable.

Rollback is switching the A record back — which is why the old stack must stay intact and the database must not have diverged.

---

## RB-7 — Migrate the stack to a new cluster

Order matters; steps 1–3 answer questions that can block everything else.

1. **Resolve the datasource question (analysis O1/F1).** Open the GeneXus project and read `Connection-Default-Datasource`. If it is a literal IP, the app **cannot** move without a rebuild. Decide: rebuild with the target endpoint (preferred), or make the target reachable at the old address.
2. **Confirm external accounts:** Azure Storage (keep the account or migrate blobs), OneSignal, Docker Hub pull credentials, DNSimple API token. Rotate the OneSignal key and Azure keys if the image ever leaked (F6).
3. **Decide the SQL Server edition** (Developer is not licensed for production — F3). Express fits today's 0.4 GB of data.
4. **Target platform:** Kubernetes with an ingress controller, a storage class for the database PV, and cert-manager plus the DNSimple webhook. Reuse `setup-cert-manager-oreedo-co.sh`.
5. **Recreate the namespace objects** from the inventory bundle (RB-2), not from `linux-scripts` — the repo is missing `rentek-app2`, the init container, `assetlinks-config` and the ingress (F19):
   ```
   namespace -> secret registry-1 -> configmap assetlinks-config -> gx-redis-app + gx-redis-svc
     -> rentek-app2 -> rentek-svc -> rentek-ingress
   ```
6. **Database:** restore `Ren_DB` and `Ren_GAM` (RB-3b), recreate the `oreedo_user` login, verify table counts (232 / 85).
7. **Expose SQL the way the app expects** — the app connects to a node address on a NodePort; keep the port number stable or rebuild the image.
8. **Test before DNS:** override DNS locally and exercise the app end-to-end:
   ```bash
   curl -sI --resolve app.rentek.oreedo.co:443:<NEW_IP> https://app.rentek.oreedo.co/mobilewebapp.mwapphome
   ```
   Check login (GAM), a file upload (Azure), push notifications, and Redis-backed sessions.
9. **Cut over** with RB-6, then keep the source server intact for the agreed rollback window.
10. **Decommission** only after the checklist in `docs/migration-plan.md` Step 5.3.

Do **not** carry over: TLS secrets (re-issue), Redis data, the Lucene index, `rentek-pictures-pvc` (empty), `rentek-app` 0.6.6 and the unused `docker-auth-config` — unless the owner confirms otherwise (O2).

---

## RB-8 — Redis restart and session loss

`gx-redis-app` has **no volume**: restarting it drops every session and logs all users out. There is no data to back up.

```bash
/snap/bin/microk8s kubectl -n rentek rollout restart deploy/gx-redis-app     # mutating: logs everyone out
/snap/bin/microk8s kubectl -n rentek exec deploy/gx-redis-app -- redis-cli DBSIZE
```

The app reconnects on its own; no restart of `rentek-app2` is required. Prefer a low-traffic window. If sessions must survive restarts, add a PVC and enable AOF — a change to make on the target, not here.

---

## RB-9 — Changing the app through Portainer without losing configuration

Deployments here are made in place through the Portainer UI (analysis §10b). Portainer keeps its own copy of each stack's YAML, and for `rentek-app2` **that copy is wrong**: it lacks the init container and the `.well-known` volumes that serve `/.well-known/assetlinks.json`.

**Before touching stack 13 in Portainer**, know that *Update the stack* re-applies the stored file and removes that configuration. Symptoms afterwards: the app still serves pages, but `https://app.rentek.oreedo.co/.well-known/assetlinks.json` returns 404 and Android App Links stop verifying.

Safe ways to change the running app:

```bash
# Preferred: change the cluster, then re-export so Git reflects reality
/snap/bin/microk8s kubectl -n rentek set image deploy/rentek-app2 rentek=oreedo/rentek:<NEW_TAG>   # RB-5
bash scripts/cluster/rentek-export-manifests.sh
git -C /home/openclaw diff manifests/rentek/        # review, then commit

# Or apply the known-good manifest set directly
/snap/bin/microk8s kubectl apply -f manifests/rentek/
```

After **any** Portainer change, verify nothing was lost and re-export:

```bash
curl -s -o /dev/null -w 'assetlinks: HTTP %{http_code}\n' https://app.rentek.oreedo.co/.well-known/assetlinks.json   # expect 200
/snap/bin/microk8s kubectl -n rentek get deploy rentek-app2 -o jsonpath='{.spec.template.spec.initContainers[*].name}{"\n"}'  # expect setup-assetlinks
/snap/bin/microk8s kubectl diff -f manifests/rentek/ || bash scripts/cluster/rentek-export-manifests.sh
```

To make the UI safe again, paste the contents of `manifests/rentek/30-rentek-app2-deployment.yaml` and `31-rentek-service.yaml` into stack 13's editor so Portainer's stored copy matches production (open question O1a).
