# Kubernetes Cluster Overview — `oreedo-ubuntu`

> Generated: 2026-03-24 | Host: 162.55.210.53 | Platform: MicroK8s v1.30.14

## Cluster Summary

- **Control plane:** `https://127.0.0.1:16443`
- **Nodes:** 1 (`oreedo-ubuntu`, Ready)
- **OS:** Ubuntu 24.04.4 LTS, kernel 6.8.0-85-generic
- **CNI:** Calico v3.25.1
- **Container runtime:** containerd 1.6.28
- **Ingress:** NGINX (microk8s) v1.8.0 — 2 classes: `nginx`, `public`
- **Storage:** microk8s-hostpath (default, WaitForFirstConsumer)
- **DNS:** CoreDNS 1.10.1

## Namespaces (13)

| Namespace | Purpose |
|---|---|
| `default` | Main workloads |
| `kube-system` | Core components |
| `ingress` | NGINX ingress controller |
| `devtroncd` | Devtron CI/CD platform |
| `devtron-ci`, `devtron-cd`, `devtron-demo` | Devtron aux (empty) |
| `argo` | Argo CD aux (empty) |
| `jenkins` | Jenkins CI |
| `portainer` | Portainer management UI |
| `rentek` | Rentek application |

## Helm Releases (9)

| Release | Namespace | Chart | App Version |
|---|---|---|---|
| `argo` | default | argo-cd 7.7.10 | v2.13.2 |
| `camunda` | default | camunda-platform 12.1.0 | 8.7.x |
| `devtron` | devtroncd | devtron-operator 0.22.86 | 1.3.1 |
| `keycloak` | default | keycloak 24.7.4 | 26.2.5 |
| `mssql` | default | mssql-chart 1.0.0 | 2019 |
| `odoo` | default | odoo 28.1.0 | 18.0 |
| `postgres` | default | postgresql 16.7.11 | 17.5.0 |
| `vault` | default | vault 1.6.8 | 1.18.5 |
| `n8n` | default | — | 1.122.4 (manifest, not helm) |

## Running Workloads

### default namespace
- **Argo CD** (v2.13.2) — server, repo-server, application controller, redis, dex, notifications, applicationset controller
- **Camunda Platform** (8.7.x) — **scaled to 0** (all deployments 0/0); ES master 0/0, zeebe 0/0; services still exist
- **Keycloak** (26.2.5) — **scaled to 0**
- **PostgreSQL** (17.5.0) — **scaled to 0** (bitnami/postgresql:16.6.0)
- **HashiCorp Vault** (1.18.5) — server (1/1) + injector (1/1)
- **MSSQL** (2019) — 1/1, NodePort 31984
- **n8n** (1.122.4) — 1/1, deployed 2 days ago
- **Odoo** (18.0) — **scaled to 0**, LoadBalancer (pending)
- **nginx / nginx-test1** — test deployments (nginx 1/1, standalone nginx pod 0/1 Unknown)

### devtroncd namespace
- **Devtron** (1.3.1) — dashboard, devtron, kubelink, dex, postgresql (1/1)
- **app-sync-cronjob** — runs daily at 19:00 UTC

### jenkins namespace
- **Jenkins** (lts) — 1/1

### portainer namespace
- **Portainer CE** (2.39.0) — 1/1, NodePort 30777/30779

### rentek namespace
- **rentek-app** (`oreedo/rentek:0.6.6`) — 1/1, NodePort 32598
- **rentek-app2** (`oreedo/rentek:0.6.7`) — 1/1
- **gx-redis** (redis:7.2.4-alpine) — 1/1

## Ingress Rules (19)

Domain: `*.oreedo.co`

| Host | Namespace | App |
|---|---|---|
| argocd.oreedo.co | default | Argo CD |
| jenkins.oreedo.co | jenkins | Jenkins |
| k8s.portainer.oreedo.co | portainer | Portainer |
| devtron.oreedo.co | devtroncd | Devtron |
| n8n.oreedo.co | default | n8n |
| vault.oreedo.co | default | Vault |
| keycloak.oreedo.co | default | Keycloak |
| mssql.oreedo.co | default | MSSQL |
| odoo.oreedo.co | default | Odoo |
| app.rentek.oreedo.co | rentek | Rentek |
| \*.camunda.oreedo.co | default | Camunda (7 subdomains) |

## Persistent Volumes (10 PVCs, ~246Gi total)

| PVC | Namespace | Size | StorageClass |
|---|---|---|---|
| mssql-mssql-pvc | default | 50Gi | manual |
| data-camunda-elasticsearch-master-0 | default | 64Gi | microk8s-hostpath |
| data-camunda-zeebe-0 | default | 32Gi | microk8s-hostpath |
| data-postgresql-postgresql-0 | devtroncd | 20Gi | microk8s-hostpath |
| jenkins-pvc | jenkins | 20Gi | microk8s-hostpath |
| data-vault-server-0 | default | 10Gi | microk8s-hostpath |
| data-postgres-0 | default | 8Gi | microk8s-hostpath |
| odoo | default | 10Gi | microk8s-hostpath |
| portainer | portainer | 10Gi | microk8s-hostpath |
| rentek-pictures-pvc | rentek | 2Gi | microk8s-hostpath |

## TLS

- Wildcard cert for `*.oreedo.co` — rotated periodically (latest: 2026-03-01)
- Separate TLS secrets per namespace with matching rotation dates

## Observations

1. **Camunda, Keycloak, PostgreSQL, Odoo are scaled to 0** — intentionally stopped or resource-saving?
2. **Standalone `nginx` pod** in Unknown status (406d old) — cleanup candidate
3. **4 empty namespaces** (`argo`, `devtron-ci`, `devtron-cd`, `devtron-demo`) — could be cleaned up
4. **No HPA** configured on any workload
5. **Single node** — no high availability
6. **n8n** was recently deployed (2 days ago) — possibly a new addition
7. **Rentek** has two app versions running (0.6.6 and 0.6.7) with separate deployments
