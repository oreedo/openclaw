# Project: openclaw (oreedo infrastructure docs/ops)

Git repo `oreedo/openclaw` (remote alias `github-oreedo`). Not an application codebase — it's
an ops/docs repo: migration plans + idempotent bash scripts for the `oreedo-ubuntu` MicroK8s
cluster (single node, host `162.55.210.53`).

## Top-level layout
- `docs/` — markdown docs (source of truth). See `mem:conventions` for the doc-per-folder rule
  and its current violation.
- `scripts/` — bash automation, currently only `scripts/cluster/*.sh` (Rentek migration helpers)
  and a personal utility `scripts/delete_cached_sessions.sh` (unrelated to the cluster).
- `.serena/` — Serena project data (memories, cache); not part of the deployed docs/scripts.
- Root `README.md` is a one-line stub (`# openclaw`); real content lives under `docs/`.

## Branch model (non-obvious)
Branches are per-host documentation sets, not feature branches:
`main`, `docs/hetzner_vps` (current), `docs/hostinger_vps`, `docs/dbmart_windows_vps`,
`docs/dbmart_ubuntu_vps`, `docs/oci_vps`. Each `docs/<host>` branch presumably documents a
different VPS/target independently — do not assume content on one branch applies to another.
Current branch `docs/hetzner_vps` documents the Hetzner-hosted `oreedo-ubuntu` cluster that is
being migrated away (see `mem:cluster/core`).

## Further reading
- `mem:tech_stack` — what actually runs here (no app build/test system).
- `mem:suggested_commands` — git orientation + cluster script invocation forms.
- `mem:conventions` — doc/script conventions, including a stale-doc inconsistency.
- `mem:task_completion` — what "done" means in this repo (docs+git, no CI).
- `mem:cluster/core` — MicroK8s cluster inventory and where its doc lives.
- `mem:cluster/rentek` — Rentek app migration specifics and the unresolved PVC-mount gotcha.
