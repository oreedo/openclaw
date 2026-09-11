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
