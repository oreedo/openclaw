# Conventions

## Doc conventions (from `docs/principles.md` #4 and `docs/README.md`)
- One doc per folder, update-in-place; do not version docs, remove deprecated lines instead of
  appending revisions.
- **Currently violated**: `docs/README.md`'s own "Structure" section only lists
  `cluster/KUBERNETES_CLUSTER.md`, `principles.md`, `README.md`, but `docs/` actually also
  contains `migration-plan.md` and `assistant-operating-notes.md` and `mcporter-guide.md`
  (added in later commits, `docs/README.md` never updated to match). Treat `docs/README.md`'s
  file listing as stale; trust `list_dir` over it.
- `docs/migration-plan.md` explicitly requires scripts to live under top-level `scripts/`,
  never under `docs/`.

## Script conventions (`scripts/cluster/*.sh`)
- `set -euo pipefail`, POSIX-ish bash.
- Configurable via `--kubectl <cmd>` / `--namespace <name>` flags, default kubectl command is
  `/snap/bin/microk8s kubectl`.
- Idempotent by design: `apply-target`/mutating modes use `kubectl apply`, and exported JSON is
  cleaned of server-assigned fields (see `mem:tech_stack`) so re-applying is safe.
- Verification is a separate read-only mode/script from mutation (`verify-target` vs
  `apply-target`; `rentek-verify-live.sh` is entirely read-only) — don't conflate them.

## Working principles (`docs/principles.md`, non-negotiable per the repo owner "Ahmed")
- Context7-first for external/library docs, Serena-first for repo/code search.
- Prefer deterministic, idempotent, scripted operations over ad-hoc manual commands.
- Auto-commit durable work to git with meaningful messages; **remote push must be consulted
  with Ahmed first**, never pushed unilaterally.
- Persist durable operational docs/scripts in `/home/openclaw` (this repo), not in
  `/root/.openclaw/workspace` (session-local scratch — see `docs/assistant-operating-notes.md`).
