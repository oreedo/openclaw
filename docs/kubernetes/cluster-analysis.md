# Kubernetes Cluster Analysis

**Date:** 2026-03-24  
**Node:** srv1199105 (72.62.93.145)  
**Platform:** Ubuntu 25.10 / Linux 6.17.0-8-generic (x64)  
**Runtime:** MicroK8s v1.33.9 / containerd 1.7.27  
**HA:** Single node (no HA configured)  
**CNI:** Calico  
**Ingress:** NGINX (microk8s built-in, daemonset)  
**Domain:** `*.oreedo.app`

## Cluster Resources
- **CPU:** 6% utilized (484m cores)
- **Memory:** 30% utilized (~9.9 GiB)
- **StorageClass:** microk8s-hostpath (default, WaitForFirstConsumer)

## Namespaces (11)

| Namespace | Purpose |
|---|---|
| argocd | ArgoCD GitOps |
| container-registry | Docker registry (localhost:32000) |
| default | — |
| ingress | NGINX ingress controller |
| kie-system | Kogito/jBPM workflow platform |
| kube-node-lease | — |
| kube-public | — |
| kube-system | Core components |
| portainer | Portainer management UI |
| sonataflow-operator-system | SonataFlow operator |
| strimzi-system | Strimzi Kafka operator |

## Enabled Addons
argocd, portainer, community, dns, ha-cluster, helm, helm3, hostpath-storage, ingress, metrics-server, rbac, registry, storage

## Helm Releases (6)

| Release | Namespace | Chart | App Version | Updated |
|---|---|---|---|---|
| argo-cd | argocd | argo-cd-5.34.3 | v2.7.2 | 2026-02-07 |
| kafka-ui | kie-system | kafka-ui-0.7.6 | v0.7.2 | 2026-02-22 |
| kie-consoles | kie-system | incubator-kie-runtime-tools-consoles-10.1.0 | 10.1.0 | 2026-02-22 |
| kogito-postgresql | kie-system | postgresql-18.4.0 | 18.2.0 | 2026-02-22 (rev 2) |
| portainer | portainer | portainer-2.33.6 | ce-latest-ee-2.33.6 | 2026-02-07 |
| strimzi-kafka-operator | strimzi-system | strimzi-kafka-operator-0.50.1 | 0.50.1 | 2026-02-22 (rev 3) |

## ArgoCD Applications (1)
- **portainer** — Synced, Healthy (only app managed via ArgoCD currently)

## Workloads Summary

### Deployments (22 total)
- **argocd** (6): applicationset-controller, dex-server, notifications-controller, redis, repo-server, server
- **container-registry** (1): registry
- **kie-system** (7): data-index, drools-rules-service, jbpm-service, jobs-service, kafka-ui, kie-consoles-management-console, kogito-kafka-entity-operator, timefold-solver-service
- **kube-system** (4): calico-kube-controllers, coredns, hostpath-provisioner, metrics-server
- **portainer** (1): portainer
- **sonataflow-operator-system** (1): sonataflow-operator-controller-manager
- **strimzi-system** (1): strimzi-cluster-operator

### StatefulSets (2)
- **argocd**: argo-cd-argocd-application-controller
- **kie-system**: kogito-postgresql (PostgreSQL for Kogito)

### DaemonSets (2)
- nginx-ingress-microk8s-controller (ingress ns)
- calico-node (kube-system)

### Kafka (Strimzi)
- **Cluster:** kogito-kafka (kie-system) — 1 broker pool, entity/user/topic operators
- **Kafka UI:** kafka-ui deployment for browsing

## Ingress Rules (8) — all on `*.oreedo.app`

| Host | Namespace | Backend Service |
|---|---|---|
| argo.oreedo.app | argocd | argo-cd-argocd-server |
| data.bpm.oreedo.app | kie-system | data-index |
| rules.bpm.oreedo.app | kie-system | drools-rules-service |
| process.bpm.oreedo.app | kie-system | jbpm-service |
| ui.kafka.oreedo.app | kie-system | kafka-ui |
| console.bpm.oreedo.app | kie-system | kie-consoles-management-console |
| planner.bpm.oreedo.app | kie-system | timefold-solver-service |
| k8s.portainer.oreedo.app | portainer | portainer |

## Persistent Volumes (5)

| PVC | Namespace | Size | Access Mode |
|---|---|---|---|
| registry-claim | container-registry | 20Gi | RWX |
| data-0-kogito-kafka-kogito-kafka-pool-0 | kie-system | 10Gi | RWO |
| data-kogito-postgresql-0 | kie-system | 8Gi | RWO |
| sonataflow-platform | kie-system | 1Gi | RWO |
| portainer | portainer | 10Gi | RWO |

## TLS
- Wildcard cert: `tls-secret-oreedo-app-multi-wildcard-20260221211941` (portainer ns)
- Shared BPM TLS: `bpm-tls-secret` in argocd, kie-system, portainer namespaces

## Notable Observations
1. **Failed pods** in kie-system: `img-jbpm-quay` (ErrImagePull), `img-kogex` (ImagePullBackOff), `jit-test` (ContainerStatusUnknown) — appear to be init/one-off pods, not critical
2. **High restarts** on kogito-kafka-entity-operator (35) and some kie-system pods — may need investigation
3. **ArgoCD** only manages Portainer via GitOps — kie-system and strimzi were deployed manually via Helm
4. **No cert-manager** addon enabled — TLS certs are manually managed
5. **No MetalLB** — LoadBalancer services won't get external IPs; NodePort used instead
6. **No monitoring stack** (prometheus/grafana) enabled

## CRDs Installed
- ArgoCD (applications, applicationsets, appprojects)
- Calico (network policies, BGP, IPAM)
- Strimzi Kafka (kafkas, topics, users, connectors, etc.)
- SonataFlow
