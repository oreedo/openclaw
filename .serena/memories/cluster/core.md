# Cluster module: oreedo-ubuntu MicroK8s

Full inventory lives in `docs/cluster/KUBERNETES_CLUSTER.md` (generated 2026-03-24) — read that
file directly for current namespace/workload/PVC/ingress detail; do not duplicate it here since
it's a point-in-time snapshot likely to drift. Durable facts:

- Single-node MicroK8s v1.30.14 cluster, host `oreedo-ubuntu` (162.55.210.53), being migrated
  off Hetzner Cloud per `docs/migration-plan.md` (target TBD as of last read).
- Storage class in use is `microk8s-hostpath` (WaitForFirstConsumer) almost everywhere except
  `mssql-mssql-pvc` (`manual`) — hostpath-only assumptions must be revisited for any multi-node
  target.
- Critical components called out by the migration plan: Vault, MSSQL, Rentek (see
  `mem:cluster/rentek`).
- Migration plan's guiding principle: prefer reusable/parameterized/idempotent scripts and
  verification scripts over ad-hoc manual migration steps; scripts belong in top-level
  `scripts/`, not `docs/`.
- At last inventory: Camunda, Keycloak, PostgreSQL, Odoo were all scaled to 0 (status/reason
  not documented — verify current state, don't assume still true or still intentional).
