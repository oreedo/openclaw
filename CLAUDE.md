# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure documentation and ops scripts for Oreedo's VPS hosts — not an application, so there is no build, test suite, or CI. Branch `docs/hetzner_vps` covers host `oreedo-ubuntu` (162.55.210.53): a single-node MicroK8s v1.30 cluster running **production** workloads (Vault, MSSQL, Argo CD, Jenkins, Devtron, Portainer, n8n, Rentek). Anything you run against the cluster hits production.

Branch model: `main` is a three-file skeleton. Each `docs/<host>` branch documents one machine — `hetzner_vps`, `hostinger_vps`, `oci_vps`, `dbmart_ubuntu_vps`, `dbmart_windows_vps` (only `hetzner_vps` is checked out here). They branch from `main`, except `oci_vps`, which was branched from `hostinger_vps` and still carries its cluster analysis. Shared files (`principles.md`, `mcporter-guide.md`) are copied per branch, so port a change by editing each branch rather than merging between them.

## Working rules (`docs/principles.md` — the owner's non-negotiable defaults)

- External docs: Context7 first, then the official site. Repo search/symbols: Serena first, built-in search as fallback.
- Anything done more than once becomes a reusable, parameterized, idempotent script — no ad-hoc command sequences for repeatable ops.
- Docs: one doc per folder, update in place, delete deprecated lines, never create versioned copies. Record findings, decisions, and getting-started steps.
- Persist every action as a file in `/home/openclaw` (`.sh`/`.ps1` scripts, `.md` docs, `.json`/`.yaml` config) and **commit automatically** with a descriptive message — no confirmation needed. **Never push** without Ahmed's agreement.
- `/root/.openclaw/workspace` is the OpenClaw agent's session-local workspace; durable docs and scripts belong in this repo, not there.

## Cluster access

- `kubectl` is an alias in `~/.bash_aliases` that only loads in interactive shells, so it doesn't exist in Claude Code's Bash tool, and `source ~/.bashrc` doesn't help (Ubuntu's `.bashrc` returns early when non-interactive). Bare `helm` is worse: it resolves to an unrelated `/usr/local/bin/helm` with no kubeconfig, which fails with "cluster unreachable". Use `/snap/bin/microk8s kubectl` and `/snap/bin/microk8s helm`.
- The invocation shown in the docs, `source ~/.bashrc && bash scripts/cluster/<script> --kubectl kubectl`, fails with `kubectl: command not found` even from an interactive terminal, because aliases aren't inherited by the child `bash`. Omit `--kubectl` (the default is `/snap/bin/microk8s kubectl`) or pass `--kubectl "microk8s kubectl"`.
- The `kubernetes-mcp-server` MCP is **write-enabled**: it authenticates as ServiceAccount `mcp/mcp-admin` (cluster-admin) via `/root/.kube/mcp-admin.kubeconfig`, with the `core,config,helm` toolsets. Its create/update/delete/exec and helm tools act on production immediately. `/root/.kube/mcp-viewer.kubeconfig` (ClusterRole `view`) is the read-only fallback.
- `docs/cluster/KUBERNETES_CLUSTER.md` is a dated snapshot (2026-03-24) that has drifted — it misses the `cert-manager`, `platform-tls` and `mcp` namespaces, and its Rentek image is stale. Verify live before relying on it, and update it in place when you find drift.

## Scripts

Scripts live in top-level `scripts/` (never inside `docs/`): `cluster/` for cluster operations, `vault/` for Vault. Conventions to keep in new scripts: `set -euo pipefail`; `--kubectl <cmd>` / `--namespace <ns>` / `-h` flags; a `run_k` helper that `eval`s the kubectl command so multi-word commands work; `--dry-run` on anything that mutates; objects exported as JSON through a `jq` filter that strips server-managed metadata (`uid`, `resourceVersion`, `managedFields`, `status`, …) so they re-`apply` idempotently. `jq` is required.

```bash
# Syntax check (shellcheck is not installed; `bash -n a.sh b.sh` only parses the first file)
for f in scripts/*/*.sh; do bash -n "$f" || echo "SYNTAX FAIL: $f"; done

# Read-only live check of the Rentek production path
bash scripts/cluster/rentek-verify-live.sh

# Portable Rentek config: bundle on the source cluster, apply + verify on the target
bash scripts/cluster/rentek-config-migrate.sh bundle-source --bundle-dir /root/rentek-config-bundle --include-tls
bash scripts/cluster/rentek-config-migrate.sh apply-target  --bundle-dir /root/rentek-config-bundle --dry-run
bash scripts/cluster/rentek-config-migrate.sh verify-target
```

`rentek-config-migrate.sh` caveats: every mode defaults to this host's production cluster and there is no `--context` flag, so `apply-target`/`verify-target` act on production unless `--kubectl` points elsewhere. `--dry-run` only affects `apply-target`; `bundle-source` always writes Secrets (`registry-1`, optional `docker-auth-config`, the ingress TLS secret) as plain JSON, and `.gitignore` doesn't cover them — keep bundles outside the repo, since commits here are automatic.

`manifests/rentek/` holds an apply-ready copy of the **running** Rentek stack, generated by `scripts/cluster/rentek-export-manifests.sh` and verified with `kubectl diff`. It exists because the app is deployed by hand through Portainer: Git and Portainer's own stack file both omit the init container that serves `/.well-known/assetlinks.json`. Re-export after any change rather than hand-editing.

`scripts/delete_cached_sessions.sh` wipes the OpenClaw agent's cached sessions under `~/.openclaw/agents/main/sessions/`.

## Vault

Vault 1.18.5 (Bitnami chart, StatefulSet `default/vault-server`) on Raft storage, Shamir seal 5/3, at `https://vault.oreedo.co`. Backups and exports live in `/root/backups/vault/` (0700, files 0600) and must never enter the repo. `scripts/vault/`: `install-vault-cli.sh` (signature-verified CLI), `vault-backup.sh` (Raft snapshot, the only complete backup), `vault-kv-export.sh` / `vault-kv-import.sh` (plaintext JSON copy of a KV mount, for a target Vault with its own keys). Procedures: `docs/vault/VAULT_IMPORT_GUIDE.md` and `docs/migration-plan.md` Step 1.3.

The `claude-code` userpass identity is read-only by design (`gx/*` read+list, plus `read` on `sys/storage/raft/snapshot` — never `update`, which would be restore). A human logs in from a real TTY; the assistant never handles the password.

## Rentek (the trickiest workload to migrate)

- Production path: `rentek-ingress` → `rentek-svc` → selector `app=rentek-app2` (pull secret `registry-1`, ConfigMap `assetlinks-config`), backed by `gx-redis-app`. `rentek-app` (0.6.6) still runs but is **not** on the public path, and there is no `deployment/rentek` — never migrate from an assumed manifest.
- The live image of `rentek-app2` was `oreedo/rentek:0.6.8` on 2026-09-11 while every doc still says `0.6.7`; read the image from the cluster.
- Unresolved pre-cutover blocker: `rentek-app` mounts `rentek-pictures-pvc` at `/app/Pictures`; the active `rentek-app2` does not.

## Docs

- `docs/migration-plan.md` — the script-driven migration plan off Hetzner (Vault, MSSQL, Rentek focus).
- `docs/vault/VAULT_IMPORT_GUIDE.md` — loading Vault data into another Vault (JSON import or snapshot restore).
- `docs/assistant-operating-notes.md` and `docs/mcporter-guide.md` are written for the shell-only OpenClaw assistant, which reaches Context7/Serena through `mcporter`. Claude Code has those MCP servers natively — call the MCP tools directly.
