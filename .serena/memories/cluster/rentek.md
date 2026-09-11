# Rentek app — migration gotchas

Full narrative in `docs/migration-plan.md` (Rentek sections) and
`docs/assistant-operating-notes.md` ("Rentek Notes"); scripts in `scripts/cluster/`
(`rentek-config-migrate.sh`, `rentek-verify-live.sh` — see `mem:suggested_commands` for
invocation forms).

## Confirmed active production path (do not assume `deployment/rentek` is it)
`rentek-ingress` -> `rentek-svc` (selector `app=rentek-app2`) -> deployment `rentek-app2`,
pull secret `registry-1`, ConfigMap `assetlinks-config`, public hostname
`app.rentek.oreedo.co`.

Image: `oreedo/rentek:0.6.8` as verified live on 2026-09-11. The docs
(`migration-plan.md`, `assistant-operating-notes.md`, `cluster/KUBERNETES_CLUSTER.md`) still
say `0.6.7` — read the image from the cluster rather than from any doc or this memory:
`bash scripts/cluster/rentek-verify-live.sh`.

## Leftover/secondary deployment
`rentek-app` (image `0.6.6`) is also running in the `rentek` namespace but is **not** on the
active public path. Treat as leftover unless its purpose is documented before migration/removal.

## Unresolved functional question (must be checked before any production cutover)
`rentek-app` mounts `rentek-pictures-pvc` at `/app/Pictures`; the *active* `rentek-app2` does
**not** mount it. Before cutover, confirm whether `rentek-app2` (a) no longer needs picture
storage, (b) stores files differently, or (c) is actually missing a required volume mount. This
was still open as of the last migration-plan read — re-check `docs/migration-plan.md` for
updates rather than assuming it's resolved.

## Script split
- `rentek-config-migrate.sh {bundle-source|apply-target|verify-target}` — portable config layer
  only (namespace, `assetlinks-config`, `registry-1`, optional `docker-auth-config`/TLS secret).
- `rentek-verify-live.sh` — read-only live verification of routing/deployment state; use this
  instead of re-running ad-hoc audit `kubectl` commands.
- Workload deployment (Layer B, not yet scripted as of last read) must be applied in order:
  `gx-redis-app`+`gx-redis-svc` -> `rentek-app2` -> `rentek-svc` -> `rentek-ingress`.
