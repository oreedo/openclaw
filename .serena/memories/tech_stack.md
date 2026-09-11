# Tech stack

- No application code, package manager, build system, or CI in this repo. Content is Markdown
  docs + standalone Bash scripts (Serena language server here is "bash").
- Target runtime is a MicroK8s v1.30.14 cluster (see `mem:cluster/core`), so scripts assume
  `kubectl`/`helm` semantics via MicroK8s, not a generic K8s distro.
- `microk8s` binary may not be on `PATH`; it is always reachable at `/snap/bin/microk8s`.
  Scripts default `KUBECTL_CMD` to `/snap/bin/microk8s kubectl` for this reason.
- The user's `~/.bashrc` defines shell aliases `kubectl -> microk8s kubectl` and
  `helm -> microk8s helm`; these only exist in an interactive shell that has sourced
  `~/.bashrc` (see `mem:suggested_commands`).
- `scripts/cluster/rentek-config-migrate.sh` requires `jq` (used to strip server-side metadata
  like `resourceVersion`/`uid`/`managedFields` from exported K8s objects before re-apply).
