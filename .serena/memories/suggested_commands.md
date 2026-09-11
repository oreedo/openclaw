# Suggested commands

## Orientation
- `git log --oneline -20` — recent history.
- `git branch -a` / `git remote -v` — see the per-host doc branches (`mem:core`) and confirm
  which one is checked out before trusting doc content.

## Using the MicroK8s aliases in a fresh non-interactive shell
Bare `kubectl`/`helm` are NOT on PATH by default in a plain shell invocation; the aliases live
in `~/.bashrc`. Either:
- `source ~/.bashrc && kubectl ...` / `helm ...`, or
- use the absolute path directly: `/snap/bin/microk8s kubectl ...` (safer for automation/scripts).

## Cluster scripts (all under `scripts/cluster/`)
Read-only live check of the active Rentek routing/deployment state:
```
source ~/.bashrc
bash scripts/cluster/rentek-verify-live.sh --kubectl kubectl --namespace rentek
```
Idempotent Rentek portable-config migration (three modes):
```
bash scripts/cluster/rentek-config-migrate.sh bundle-source --kubectl kubectl --namespace rentek --bundle-dir ./rentek-config-bundle --include-tls
bash scripts/cluster/rentek-config-migrate.sh apply-target  --kubectl kubectl --namespace rentek --bundle-dir ./rentek-config-bundle
bash scripts/cluster/rentek-config-migrate.sh verify-target --kubectl kubectl --namespace rentek
```
Both scripts default `--kubectl` to `/snap/bin/microk8s kubectl` if omitted; both accept
`--dry-run` on `apply-target`/mutating modes where applicable.
