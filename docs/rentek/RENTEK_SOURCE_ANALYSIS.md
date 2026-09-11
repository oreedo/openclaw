# Rentek — Source Server Analysis

> Host `oreedo-ubuntu` (162.55.210.53), MicroK8s v1.30.14. Everything below was verified **live on 2026-09-11** with read-only commands; where a doc elsewhere in this repo disagrees, this file is the observed truth. Re-collect with `scripts/cluster/rentek-source-inventory.sh`. Operational procedures live in `docs/runbooks/RUNBOOKS.md`.

## 1. Executive summary

Rentek is a **GeneXus .NET application** served from a single namespace, backed by SQL Server **outside** that namespace, with sessions in Redis and user files in **Azure Blob Storage**. The public path is:

```
app.rentek.oreedo.co (DNSimple A -> 162.55.210.53, no AAAA)
  -> ingress-nginx (class "public", hostPort 80/443)  [TLS: secret tls-oreedo-co]
    -> Service rentek-svc (NodePort 32598, port 5000)
      -> Deployment rentek-app2 (oreedo/rentek:0.6.8), 1 replica
         |- session   -> gx-redis-svc:6379            (in-namespace, no persistence)
         |- database  -> 162.55.210.53:31984          (NodePort of MSSQL in ns default)
         |- files     -> Azure Blob Storage           (external, credentials inside the image)
         `- push      -> OneSignal                    (external, API key inside the image)
```

The three facts that dominate any migration:

1. **The database endpoint and all credentials are baked into the container image**, GeneXus-encrypted in `/app/appsettings.json`. There are **no environment variables and no ConfigMap** for them. Changing the DB host requires a **rebuild from GeneXus**, not a Kubernetes change.
2. **The app reaches SQL Server through the node's public IP on NodePort 31984**, not through a cluster Service name. SQL Server confirms the client address as `162.55.210.53`.
3. **Persistent state is only in SQL Server** (`/home/mssql/data`, 2.1 GB) **and Azure Blob**. The `rentek-pictures-pvc` is empty and unused; Redis and the Lucene index are disposable.

## 2. Host and platform

| Item | Value |
|---|---|
| Hostname / provider | `oreedo-ubuntu`, Hetzner Cloud |
| IPv4 | `162.55.210.53` (all app DNS points here) |
| IPv6 | `2a01:4f8:1c1b:7dd6::1`, default route via `fe80::1` — **not used by any service** |
| OS / kernel | Ubuntu 24.04.5 LTS, 6.8.0-85-generic |
| Resources | 8 vCPU, 30 GiB RAM (~21 GiB free), disk 226 GB with 163 GB used (76%) |
| Uptime | ~48 weeks (no reboot since kernel updates) |
| Kubernetes | MicroK8s v1.30.14 rev 8566, single node, Calico CNI, containerd 1.6.28, CoreDNS 1.10.1 |
| Enabled addons | dns, ingress, hostpath-storage, cert-manager, metrics-server, rbac, ha-cluster, helm/helm3, dashboard, community/portainer |
| Host firewall | **`ufw` inactive** — NodePorts are reachable from the internet (see F2) |

## 3. Namespace `rentek`

Labels carry `genby=genexus` and Portainer ownership (`io.portainer.kubernetes.application.owner=aabuabdou`), i.e. the namespace was originally created through Portainer.

### 3.1 Workloads

| Object | Image | Role | Notes |
|---|---|---|---|
| `deployment/rentek-app2` | `oreedo/rentek:0.6.8` @ `sha256:e61d2e8983562130a24c1932d281a4439f0f9551b5afdd509306d2e9db27a062` | **ACTIVE public app** | 1 replica, strategy `Recreate`, container port 5000 (`external-port`), pull secret `registry-1`, `imagePullPolicy: Always` |
| `deployment/rentek-app` | `oreedo/rentek:0.6.6` | legacy, **not routed** | same DB and services; mounts the empty `rentek-pictures-pvc` at `/app/Pictures` |
| `deployment/gx-redis-app` | `redis:7.2.4-alpine` | session store | no args, **no volume**, `appendonly no`, `save 3600 1 300 100 60 10000`, DBSIZE 2 |

Neither app defines **liveness/readiness probes** nor **resource requests/limits**. Observed usage: `rentek-app2` ~2 m CPU / 318 MiB, `rentek-app` ~1 m / 77 MiB, redis ~2 m / 3 MiB.

`rentek-app2` runs one init container:

```yaml
initContainers:
- name: setup-assetlinks
  image: busybox:latest
  command: ["sh","-c","mkdir -p /shared/.well-known && cp /tmp/configmap/assetlinks.json /shared/.well-known/assetlinks.json"]
```

Volumes: `assetlinks-volume` (ConfigMap `assetlinks-config`) mounted read-only at `/app/.well-known/assetlinks.json` via `subPath`, and `shared-volume` (`emptyDir`) at `/app/.well-known`. The init container exists because a `subPath` ConfigMap mount alone would not create the directory.

### 3.2 Services and endpoints

| Service | Type | ClusterIP | Ports | Selector | Endpoint |
|---|---|---|---|---|---|
| `rentek-svc` | NodePort | 10.152.183.23 | 5000 → 5000, **nodePort 32598** | `app=rentek-app2` | 10.1.156.158:5000 |
| `gx-redis-svc` | ClusterIP | 10.152.183.63 | 6379 → 6379 | `app=gx-redis-app,tier=redis` | 10.1.156.185:6379 |

NodePort 32598 is publicly reachable: the app log contains internet scanner hits such as `GET http://162.55.210.53:32598/robots.txt`.

### 3.3 Ingress

```yaml
name: rentek-ingress          # ingressClassName: public
host: app.rentek.oreedo.co
path: /(.*)                   # pathType: Exact
backend: rentek-svc:5000
tls:  [{hosts: [app.rentek.oreedo.co], secretName: tls-oreedo-co}]
annotations:
  nginx.ingress.kubernetes.io/app-root: /mobilewebapp.mwapphome
  nginx.ingress.kubernetes.io/rewrite-target: /$1
  nginx.ingress.kubernetes.io/use-regex: "true"
```

`app-root` produces the observed `302` from `/` to `/mobilewebapp.mwapphome`. The ingress has **no `proxy-body-size` annotation**, so the controller default of **1 MiB** applies while the app advertises `MaxFileUploadSize = 528000000` (see F10). The ingress object has no `last-applied-configuration`, i.e. it was created through Portainer/the API rather than `kubectl apply`.

### 3.4 ConfigMaps and Secrets

| Object | Type | Content / purpose |
|---|---|---|
| `cm/assetlinks-config` | — | `assetlinks.json` for Android App Links: package `com.genexus.renteknew.rentek`, one SHA-256 signing fingerprint. Served at `/.well-known/assetlinks.json` |
| `secret/registry-1` | dockerconfigjson | Docker Hub (`https://index.docker.io/v1/`) pull credentials — **used by both app deployments** |
| `secret/docker-auth-config` | dockerconfigjson | Same registry, **not referenced by any pod** (leftover) |
| `secret/tls-oreedo-co` | kubernetes.io/tls | Wildcard cert, **a replica** of `platform-tls/tls-oreedo-co` (identical SHA-256 fingerprint `CC:9E:9D:A2…AF:E4`) |
| `secret/tls-rentek-secret-oreedo-co-multi-wildcard-2025…/2026…` (5) | kubernetes.io/tls | Historic certificates from an older naming scheme, **unreferenced** |

### 3.5 Storage

`pvc/rentek-pictures-pvc` — 2 GiB, `microk8s-hostpath`, RWO, bound to a PV with `hostPath: /var/snap/microk8s/common/default-storage/rentek-rentek-pictures-pvc-pvc-3aa6a181-…`, reclaim **Delete**. It is mounted only by the legacy `rentek-app` and is **empty (0 files, 4 KB)**. The active app stores files in Azure Blob instead.

## 4. Application internals (what lives inside the image)

Runtime: ASP.NET Core on **Debian 12 (bookworm)**, GeneXus generated code, app root `/app`. Configuration is **baked into the image**, not injected:

| File | Purpose |
|---|---|
| `/app/appsettings.json` | datastores, connection parameters, app behaviour |
| `/app/CloudServices.config` | external providers: OneSignal, Azure Storage, Redis session, web notifications |
| `/app/web.config`, `/app/log.config`, `/app/rewrite.config` | hosting, logging, URL rewriting |
| `/app/GeneXus.services` | exposes `OfflineEventReplicator` for offline sync |

### 4.1 Datastores

Four datastores are declared; three point at the same SQL Server instance on **port 31984**:

| Datastore | DBMS | Database | Notes |
|---|---|---|---|
| `Default` | sqlserver | `Ren_DB` | main application data |
| `GAM` | sqlserver | `Ren_GAM` | GeneXus Access Manager (identity/authorisation) |
| `GXFLOW` | sqlserver | `Ren_DB` | GeneXus workflow tables (`WF*`) |
| `GXOfflineStore` | sqlite | `GXOfflineStoredb.sqlite` | offline/mobile sync store, inside the container |

`Datasource`, `User`, `Password` and `Schema` are **GeneXus-encrypted strings** (e.g. `Connection-Default-Datasource: /mKyEdKQikwNoCrjrjQLwou/…`), decrypted by the app at runtime. They cannot be edited in place — see F1. `Opts` is `;Integrated Security=no;`.

Proven at the database side (`sys.dm_exec_connections`): client address **162.55.210.53**, login **`oreedo_user`**, program `Core Microsoft SqlClient Data Provider`, host name `rentek-app2-8d5487b69-449h6`. So the pod egresses to the node's public IP and re-enters through the NodePort.

### 4.2 External providers (`CloudServices.config`)

| Service | Type | Configuration |
|---|---|---|
| `AZURESTORAGE` | Storage | `GeneXus.Storage.GXAzureStorage.AzureStorageExternalProvider`; account name, access key and public/private container names are **GeneXus-encrypted**; default ACL `Default`, signed-URL expiration 1440 min |
| `REDIS` | Session | `SESSION_PROVIDER_ADDRESS = gx-redis-svc:6379`, instance `MyAPP`, **no password** |
| `ONESIGNAL` | Notifications | `APP_ID` and `REST_API_KEY` stored **in plaintext** (see F6) |
| `INPROCESS` | WebNotifications | WebSocket handlers `EquipmentRentalModule.NewMessages` etc. |

### 4.3 Behavioural settings worth carrying over

`HTTP_PROTOCOL=Secure`, `SAMESITE_COOKIE=Lax`, `SessionTimeout=20` min, `MaxFileUploadSize=528000000`, `EnableIntegratedSecurity=1` with login object `gamexamplelogin`, `Culture=en-US`, `DateFormat=MDY`, `Theme=WorkWithPlusDS`, `SMTPSession=MailKit`, `LOG_OUTPUT=RollingFile`, `SMART_CACHING=1`, `CACHE_CONTENT_EXPIRATION=36`, `EXPOSE_METADATA=0`, `CORS_ALLOW_ORIGIN` empty, `VER_STAMP=20260127.091126`, `GX_BUILD_NUMBER=751240`.

`LUCENE_INDEX_DIRECTORY` is `..\Web\LuceneIndex` — a Windows-style path that on Linux creates a literal directory named `..\Web\LuceneIndex` inside `/app`. The search index therefore lives in the container filesystem and is lost on every restart (F14).

## 5. Container image and provenance

| Item | Value |
|---|---|
| Registry / repo | Docker Hub, **private** `docker.io/oreedo/rentek` |
| Active tag / digest | `0.6.8` @ `sha256:e61d2e8983562130a24c1932d281a4439f0f9551b5afdd509306d2e9db27a062` |
| Pull secret | `registry-1` (`index.docker.io`), also present as the unused `docker-auth-config` |
| Local cache | containerd on this node holds many historic tags (`0.1.0` … `0.6.8`), ~200–340 MB each |
| Build pipeline | **None in this cluster.** Argo CD manages only `n8n` and `portainer`; no Jenkins job builds Rentek. Images are built externally (GeneXus deploy) and pushed to Docker Hub |
| Deployment method | raw `kubectl apply` / Portainer — Rentek objects carry no Helm or Argo ownership labels |

Because the image is the only source of configuration, **the image is the deployment unit**: a DB move, a storage-account change or a credential rotation all require a new image build.

## 6. Database (SQL Server, namespace `default`)

| Item | Value |
|---|---|
| Helm release | `mssql`, chart `mssql-chart-1.0.0`, installed 2024-10-25 |
| Image / version | `mcr.microsoft.com/mssql/server:2019-latest` → **15.0.4395.2 RTM, Developer Edition (64-bit)** |
| Deployment | `mssql-mssql-deployment`, 1 replica, env `ACCEPT_EULA=Y`, `MSSQL_PID=Developer`, `SA_PASSWORD` as a **literal value in the manifest** |
| Service | `mssql-mssql-service`, NodePort **1433 → 31984**, ClusterIP 10.152.183.241 |
| Storage | PVC `mssql-mssql-pvc` 50 GiB, SC `manual` → PV `mssql-mssql-pv`, `hostPath: /home/mssql/data`, reclaim **Retain**; 2.1 GB used on disk |
| Ingress | `mssql-mssql-ingress` on class `nginx` → **inert**, the controller only serves class `public` (F11) |

Databases:

| DB | Size | Recovery | Collation | Compat | Created | Tables |
|---|---|---|---|---|---|---|
| `Ren_DB` | 144 MB | FULL | `SQL_Latin1_General_CP1_CI_AS` | 150 | 2024-11-04 | 232 |
| `Ren_GAM` | 272 MB | FULL | `SQL_Latin1_General_CP1_CI_AS` | 150 | 2024-11-04 | 85 |

Files: `/var/opt/mssql/data/{Ren_DB.mdf 72 MB, Ren_DB_log.ldf 72 MB, Ren_GAM.mdf 72 MB, Ren_GAM_log.ldf 200 MB}`. Largest `Ren_DB` tables by rows: `WWP_Mail` (250), `WFPref1` (215), `WFCAppAct` (163), `WFPref` (126), `UserCustomizations` (114) — the dataset is small.

Logins: `sa`, **`oreedo_user`** (the application login, created 2024-10-25), `BUILTIN\Administrators`. **0 SQL Agent jobs.**

Backups: last recorded **`Ren_DB` 2025-10-12**, **`Ren_GAM` 2024-11-09**. Stale files exist at `/home/mssql/data/data/Ren_DB.bak` and `/home/mssql/data/data/backups/{Ren_DB,Ren_GAM}.bak`. Both databases run **FULL recovery with no log backups**, which is why `Ren_GAM_log.ldf` (200 MB) is larger than its data file (F4).

`@@SERVERNAME` still reports `mssql-mssql-deployment-8477888d5-z6jlj`, a pod name from an earlier ReplicaSet — cosmetic, but backup history and any server-name-dependent script will show it.

## 7. TLS and certificate lifecycle

```
cert-manager v1.8.0 (ns cert-manager)
  + webhook neoskop/cert-manager-webhook-dnsimple:0.1.2
  ClusterIssuer letsencrypt-dnsimple-prod   (ACME v02 production, admin@oreedo.co)
  ClusterIssuer letsencrypt-dnsimple-staging
      solver: DNS-01 via DNSimple, accountID 10450, token from secret cert-manager/dnsimple-api-token (key: token)
      ACME account keys: cert-manager/letsencrypt-key-{prod,staging}-dnsimple
        |
        v
Certificate platform-tls/oreedo-co  ->  Secret platform-tls/tls-oreedo-co
   SANs (11): oreedo.co, *.oreedo.co, *.bpm, *.camunda, *.consultene, *.convera,
              *.facilitytech, *.keycloak, *.mail, *.portainer, *.rentek.oreedo.co
   notAfter 2026-10-23T03:51:25Z    renewalTime 2026-10-16T03:51:25Z
        |
        v
CronJob platform-tls/tls-secret-replicator-co   (*/30 * * * *, bitnami/kubectl:latest,
   SA tls-replicator + ClusterRole tls-replicator-co, concurrencyPolicy Forbid)
   copies tls-oreedo-co -> default, portainer, argocd*, kie-system*, rentek, devtroncd, jenkins
   (* namespaces do not exist; the job logs a warning and continues)
        |
        v
Secret rentek/tls-oreedo-co  ->  used by rentek-ingress  ->  ingress-nginx reloads automatically
```

The renewal path is fully automatic: cert-manager renews ~7 days before expiry using a DNS-01 challenge against DNSimple, the CronJob republishes the secret into `rentek` within at most 30 minutes, and ingress-nginx picks up the change without a restart. The replicator is **idempotent** (`kubectl create secret tls --dry-run=client | kubectl apply -f -`); its last run logged `secret/tls-oreedo-co unchanged` for every target namespace.

Verified: the certificate in `rentek` is byte-identical to the source (same SHA-256 fingerprint and `notAfter`).

Unrelated to Rentek but visible: the Camunda, Keycloak and n8n ingresses in `default` still reference older `tls-secret-oreedo-co-multi-wildcard-*` secrets that the replicator does **not** maintain.

## 8. DNS

| Item | Value |
|---|---|
| Authoritative NS | DNSimple edge: `ns1.dnsimple-edge.com`, `ns2…net`, `ns3…io`, `ns4…org` |
| SOA | `ns1.dnsimple-edge.com. admin.dnsimple.com.` (negative TTL 300) |
| `app.rentek.oreedo.co` | **A 162.55.210.53**, TTL **3600 s**, no CNAME |
| Wildcard | `*.rentek.oreedo.co` also resolves to 162.55.210.53 (verified with a random label) |
| Other app hosts | `vault`, `mssql`, `argocd`, `jenkins`, `devtron`, `k8s.portainer`, `n8n`, `keycloak`, `odoo` → all A 162.55.210.53 |
| `oreedo.co` apex | 151.101.1.195 / 151.101.65.195 (**Fastly** — the marketing site, not this server) |
| **AAAA records** | **None exist for any host on this server** |
| CAA | **None** — any CA may issue for the domain |

IPv6 status: the host has a routable address (`2a01:4f8:1c1b:7dd6::1`), but the ingress publishes **no IPv6 hostPort rules** and `curl -6 https://app.rentek.oreedo.co` fails. Publishing AAAA today would break IPv6-capable clients, because they would prefer AAAA and reach a port that does not answer. IPv6 support is therefore a **deliberate target-side decision**, not a copy-over item (F12).

The DNS cutover lever for migration is the A record with its 3600 s TTL — lower it well before the move (see the DNS runbook).

## 9. State and data inventory

| State | Where it lives | Survives pod restart? | Migration action |
|---|---|---|---|
| Application + workflow data | `Ren_DB` on the MSSQL PV (`/home/mssql/data`) | yes | backup/restore (`.bak`) |
| Identity / users / sessions-of-record | `Ren_GAM` | yes | backup/restore (`.bak`) |
| Uploaded files and images | **Azure Blob Storage** (external account) | yes | nothing to copy; keep account or migrate blobs + rebuild image |
| Web sessions | Redis `gx-redis-app` | **no** (no volume) | nothing; users re-login |
| Search index | `/app/..\Web\LuceneIndex` in the container | **no** | nothing; rebuilt by the app |
| Offline sync store | `GXOfflineStoredb.sqlite` in the container | **no** | nothing |
| `rentek-pictures-pvc` | hostPath, **empty** | yes | nothing to copy (confirm before deleting) |
| TLS material | `platform-tls` + replicas | yes | re-issue on target, do not copy |

## 10. External dependencies

Docker Hub (private image pull) · Azure Blob Storage (files) · OneSignal (push) · Let's Encrypt (ACME) · DNSimple (DNS + DNS-01 API token) · SMTP via MailKit (server configured inside GAM/app, not in Kubernetes — **open question O4**).

## 10a. Source-of-truth repository (`linux-scripts`)

A second repository holds the deployment sources: **`github.com/oreedo/linux-scripts`**, checked out at `/home/scripts/linux-scripts`.

| Path | Contents | Matches production? |
|---|---|---|
| `rentek/K8s-Rentek-App.yaml` | PVC `rentek-pictures-pvc`, Service `rentek-svc` (selector already `app=rentek-app2`), Deployment **`rentek-app` 0.6.6 only** | **No** — the live `rentek-app2`, its init container, `assetlinks-config` and `rentek-ingress` exist **only in the cluster** |
| `rentek/K8s-rentek-Redis.yaml` | `gx-redis-svc` + `gx-redis-app` | Yes |
| `rentek/K8s-rentek-Namespace.yaml` | namespace `rentek` | Yes (live also carries Portainer labels) |
| `mssql/mssql-chart/` + `install.sh` | Helm chart; `helm install mssql ./mssql-chart` | **No** — chart says nodePort `31433`, path `/home/aabuabdou/Projects/mssql/data`, host `mssql.oreedo.local`; live is `31984`, `/home/mssql/data`, `mssql.oreedo.co`. `values.yaml` also contains the **SA password in clear text** |
| `keys/certs/oreedo-co/ngnix/setup-cert-manager-oreedo-co.sh` | The full TLS automation (5 phases: namespace + DNSimple token secret → ClusterIssuers → source Certificate → RBAC + replicator CronJob → verify), plus `--cleanup-old-secrets` | Yes — this script produced the live setup described in §7 |
| `keys/certs/oreedo-co/ngnix/proposed-plan.md` | Design rationale for replacing the old manual quarterly certificate swap | — |
| `jenkins/Dockerfile-genexus` | Jenkins LTS image with `genexus` + `msbuild` plugins, intended for GeneXus CI | Built, but **no Jenkins job exists**; images are produced outside the cluster |

The DNSimple API token is read from a `.env` file next to the script (`DNSIMPLE_API_TOKEN`), which is also what `secret/cert-manager/dnsimple-api-token` holds.

**Consequence for migration:** re-deploying Rentek from Git alone would bring up the *wrong* (0.6.6, no ingress, no assetlinks) application. The authoritative definition of the running app is the cluster itself — which is why this analysis ships exported manifests (§13) rather than pointing at the repo.

## 11. Findings and risks

| # | Severity | Finding |
|---|---|---|
| F1 | **Blocker (migration)** | DB endpoint, DB user/password, Azure keys are GeneXus-encrypted **inside the image**. Nothing can be re-pointed from Kubernetes; a new DB address requires a GeneXus rebuild + new image |
| F2 | **High (security)** | `ufw` inactive and NodePorts bind all interfaces: **SQL Server is exposed on 162.55.210.53:31984** and the app on :32598. Internet scanners already reach :32598 (seen in logs). Protection depends entirely on a Hetzner Cloud Firewall — verify in the console |
| F3 | **High (licensing)** | SQL Server runs **Developer Edition**, which Microsoft licenses for development/test only — not for production. Migration is the moment to move to Express (10 GB limit, data is 0.4 GB) or a licensed Standard |
| F4 | **High (data)** | Both databases are in FULL recovery with **no log backups** and no backup job at all (last full backup `Ren_DB` 2025-10-12, `Ren_GAM` 2024-11-09). Logs grow unbounded; a crash today loses ~11 months of changes |
| F5 | **High (security)** | `SA_PASSWORD` is a plaintext literal in the Deployment spec; readable by anyone with `get deploy` in `default`, and stored in Helm release history |
| F6 | **High (security)** | The image embeds secrets: the **OneSignal REST API key in plaintext** and GeneXus-encrypted Azure credentials. Anyone who can pull the image obtains them — rotate on migration |
| F7 | Medium | No liveness/readiness probes, no resource requests/limits, 1 replica with `Recreate` → every deploy is a hard outage and a hung process is never restarted |
| F8 | Medium | Redis has no volume: a restart drops all sessions (users are logged out) |
| F9 | Medium | Mutable tags with `imagePullPolicy: Always` and no digest pinning: a re-pushed `0.6.8` silently changes production; rollback depends on the node's containerd cache |
| F10 | Medium | Ingress has no `proxy-body-size`, so the nginx default **1 MiB** caps uploads while the app advertises 528 MB. Verify real upload paths before/after migration |
| F11 | Low | The controller runs `--ingress-class=public`; `mssql-mssql-ingress` (class `nginx`) is dead configuration |
| F12 | Low | No AAAA records and no IPv6 ingress path, although the host has IPv6 |
| F13 | Low | Leftovers: `rentek-app` 0.6.6 still running, empty `rentek-pictures-pvc`, unused `docker-auth-config`, 5 obsolete TLS secrets |
| F14 | Low | Lucene search index is ephemeral (Windows-style path inside the container) |
| F15 | Low | TLS delivery depends on one CronJob; if it fails silently the replica ages out up to 7 days after renewal before anything breaks |
| F16 | Low | No NetworkPolicies anywhere in `rentek`; any pod in the cluster can reach Redis and the app |
| F18 | **High (security)** | `linux-scripts` contains **54 committed private keys/PFX/PEM files**, including `STAR_oreedo_co.key` and `tls-rentek-secret.yaml` with `tls.key`, plus the MSSQL SA password in `mssql-chart/values.yaml`. Verify the GitHub repo's visibility and rotate anything that was ever public |
| F19 | **High (operations)** | **Manifest drift**: the running `rentek-app2`, its init container, `assetlinks-config` ConfigMap and `rentek-ingress` are not in Git; the MSSQL chart values do not match the deployed release. There is no reproducible "deploy from source" path today |
| F17 | Low | cert-manager v1.8.0 (2022) and ingress-nginx v1.8.0 are far behind; host has 48 weeks of uptime without a reboot |

## 12. Migration implications and open questions

1. **The database address problem (F1).** Options, in order of preference: (a) rebuild the image in GeneXus with the target datasource — the only clean answer; (b) keep a DNS name as the datasource so the target can move transparently — only possible if the encrypted value is a hostname, which cannot be read from outside; (c) preserve `162.55.210.53:31984` reachability from the new cluster during transition. **Decide this before anything else** — it determines whether the app can be moved at all without a GeneXus build.
2. **Azure Blob.** Keep the existing storage account (zero data movement, fastest) or migrate blobs and rebuild the image with new keys.
3. **Database platform.** Moving off Developer Edition (F3) may change the connection port/host and therefore forces the image rebuild anyway — sequence the two together.
4. **Cutover lever.** One A record at TTL 3600. Lower to 60 s at least a day ahead.
5. **TLS on the target.** Re-issue with the same DNSimple DNS-01 setup (the API token is the only secret to carry); do not copy certificates. DNS-01 works before the target is publicly reachable, so certificates can be ready in advance.

Open questions to answer with the application owner:

- **O1** Is the encrypted `Connection-*-Datasource` an IP literal or a hostname? Only the GeneXus project shows this, and it decides the migration path.
- **O2** Can `rentek-app` (0.6.6) and `rentek-pictures-pvc` be deleted? Both appear unused and the PVC is empty — note that `rentek/K8s-Rentek-App.yaml` in `linux-scripts` still defines *only* that deployment, so the repo must be updated at the same time.
- **O3** Which Azure Storage account/containers are in use, and who holds the keys?
- **O4** Where is SMTP configured (GAM tables or app), and which relay does it use?
- **O5** Does any real upload exceed 1 MiB today (F10)?

## 13. Exported manifests and how to re-collect

Live manifests for every object named here were exported during this analysis with `scripts/cluster/rentek-source-inventory.sh`, which writes a timestamped, secret-free bundle (Secrets are listed by name/type/keys only) to `/root/backups/rentek-inventory/`. Re-run it before any migration step so the bundle reflects the current cluster:

```bash
bash scripts/cluster/rentek-source-inventory.sh            # -> /root/backups/rentek-inventory/<UTC>/
bash scripts/cluster/rentek-source-inventory.sh --out-dir /root/backups/rentek-inventory --include-mssql-query
```

The bundle is the input for the migration runbooks in `docs/runbooks/RUNBOOKS.md`.
