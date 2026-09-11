# Vault Import Guide

> Loading Vault data exported from `oreedo-ubuntu` (`https://vault.oreedo.co`, Vault 1.18.5, Raft storage, Shamir seal 5 shares / threshold 3) into another Vault. Scripts: `scripts/vault/`. How the files are produced: `docs/migration-plan.md` → Step 1.3, Vault.

## Choose a method

| | A. JSON import (`vault-kv-import.sh`) | B. Snapshot restore |
|---|---|---|
| Input file | `gx-kv-export-<UTC>.json` — **plaintext** | `vault-cluster-<id>-<UTC>.snap` — encrypted by Vault |
| What moves | the KV secrets of one mount (`gx/`) and their KV metadata | everything: all secret engines, policies, auth methods and users, identity, tokens, config |
| Target Vault | any Vault, any storage; keeps its own unseal keys | a fresh Vault with Raft storage; afterwards it unseals with **this** cluster's keys (3 of 5) |
| Permission needed on the target | write on `gx/` only | `update` on `sys/storage/raft/snapshot-force` (root token of the fresh Vault) |
| Use it when | you want a clean Vault and will create policies and logins again yourself | you want an exact clone, identities and policies included |

## The files

Kept on `oreedo-ubuntu` in `/root/backups/vault/` (directory 0700, files 0600, never in git):

| File | Content |
|---|---|
| `gx-kv-export-20260911T213856Z.json` + `.sha256` | 9 secrets of `gx/`, current versions, exported 2026-09-11 |
| `vault-cluster-b86c583f-20260911T205551Z.snap` + `.sha256` + `.inspect.txt` | full snapshot, Raft index 4054, taken 2026-09-11 |

To refresh the export first, log in with the read-only `claude-code` identity in your own SSH terminal, then export:

```bash
unset VAULT_TOKEN; VAULT_ADDR=https://vault.oreedo.co vault login -no-print -method=userpass username=claude-code
bash scripts/vault/vault-kv-export.sh --revoke-token        # add --all-versions to include older live versions
```

## A. JSON import

Runs on any Linux machine with bash, the `vault` CLI, `jq` and network access to the target Vault (on Windows use WSL). If the target is reachable from `oreedo-ubuntu`, run it there and skip step 1.

### 1. Copy the export and verify it

From the machine that will run the import:

```bash
scp 'root@162.55.210.53:/root/backups/vault/gx-kv-export-20260911T213856Z.json*' .
sha256sum -c gx-kv-export-20260911T213856Z.json.sha256      # must print: OK
```

### 2. Install the tools

```bash
git clone <this repo> && cd <repo>                # or copy scripts/vault/*.sh
sudo bash scripts/vault/install-vault-cli.sh      # Ubuntu/Debian: signature-verified Vault CLI 1.18.5
sudo apt-get install -y jq
```

### 3. Prepare the target Vault (as an admin of the target)

```bash
export VAULT_ADDR=https://<target-vault>
vault login                                        # target admin
vault secrets enable -path=gx kv-v2
vault policy write kv-import - <<'EOF'
path "gx/data/*"     { capabilities = ["create", "update", "read"] }
path "gx/metadata/*" { capabilities = ["create", "update", "read", "list"] }
EOF
export VAULT_TOKEN="$(vault token create -policy=kv-import -ttl=1h -field=token)"
```

The last line switches this shell to a one-hour, import-only token without printing it. Importing with the admin token also works. Add `read` and `update` on `gx/config` if you plan to use `--apply-mount-config`.

### 4. Dry run

```bash
bash scripts/vault/vault-kv-import.sh --file gx-kv-export-20260911T213856Z.json --addr "$VAULT_ADDR" --dry-run
```

Prints one line per secret — `create`, `update`, `unchanged`, `skip` — and which secrets would get metadata changes. It writes nothing and shows secret paths, never values.

### 5. Import

```bash
bash scripts/vault/vault-kv-import.sh --file gx-kv-export-20260911T213856Z.json --addr "$VAULT_ADDR"
```

A clean first run into an empty `gx/` ends with `created: 9 … verified: data 9/9, metadata 9/9 match the export`.

How it behaves:

- `--addr` is mandatory; a `VAULT_ADDR` set in the environment is ignored. Importing back into the Vault the file came from is refused unless you add `--allow-same-vault` (a deliberate rollback).
- Values reach Vault on stdin only — never on the command line, in the process list or in the output.
- Idempotent: secrets whose data and metadata already match are left alone, so a failed or interrupted run can simply be repeated.
- Every write uses check-and-set against the target's current version: a concurrent change makes the write fail instead of being overwritten, and mounts that require check-and-set work.
- KV metadata (`max_versions`, `cas_required`, `delete_version_after`, `custom_metadata`) is applied before the data.
- A secret that already exists with different data gets a new version; its older versions stay in the target's history.
- Version numbers start again at 1 in the target. `--all-versions` (needs an export made with `--all-versions`) replays the live history oldest to newest.
- Secrets whose current version is deleted in the source are not imported; only their metadata is copied. To bring one over, undelete it in the source (`vault kv undelete -versions=<n> gx/<path>`) and export again.
- `--mount <name>` imports into a mount with another name. It must be a mount root: a sub-path such as `gx/sub` is refused, because Vault would resolve the writes into `gx/` itself.
- The mount-level config (`max_versions`, `cas_required`, `delete_version_after`) is reported when it differs from the source's; `--apply-mount-config` copies it.
- At the end it re-reads every secret and compares data and metadata with the file.

### 6. Afterwards

```bash
vault kv list gx/                                              # the imported paths
vault kv get -format=json gx/<path> | jq '.data.data | keys'  # key names only, no values
vault token revoke -self; unset VAULT_TOKEN                    # drop the import token
shred -u gx-kv-export-*.json                                   # every plaintext copy you no longer need
```

The JSON does not carry policies, auth methods and their users (for example userpass `claude-code` with `claude-code-policy`), identity entities or other secret engines. Recreate them on the target.

## B. Snapshot restore

1. Deploy Vault 1.18.5 with Raft storage, run `vault operator init` (these keys are throwaway), unseal, and `vault login` with its root token.
2. Copy `vault-cluster-b86c583f-20260911T205551Z.snap` and its `.sha256` to where you run the CLI; `sha256sum -c` it.
3. Restore through a port-forward — ingress-nginx rejects request bodies over 1 MiB with `413`:

   ```bash
   kubectl -n <namespace> port-forward svc/<vault-service> 8200:8200 &
   VAULT_ADDR=http://127.0.0.1:8200 vault operator raft snapshot restore -force vault-cluster-b86c583f-20260911T205551Z.snap
   ```

   `-force` is required because the new cluster has different unseal keys; without it Vault answers `could not verify hash file`.
4. The restored data is encrypted with the source keyring: from now on (and after every restart) unseal with the **source** cluster's Shamir keys, 3 of 5. The target's init root token and throwaway keys stop working — log in with credentials from the source.
5. Check: `vault status`, `vault secrets list`, `vault policy list`, `vault kv list gx/`.

Anything written to the source after the snapshot was taken is not in it.

## Troubleshooting

| Message | Cause and fix |
|---|---|
| `no valid token for <addr>` | log in to the target, or export `VAULT_TOKEN` for it |
| `mount gx/ not visible on target` | enable it (`vault secrets enable -path=gx kv-v2`), or the token has no access to it |
| `… is not a KV v2 mount` | the target mount is KV v1 or another engine; use `--mount` with a KV v2 mount |
| `permission denied` / `Code: 403` | the token lacks the policy from step 3 |
| `… is not a mount root` | `--mount` points inside a mount (e.g. `gx/sub`); name the mount itself |
| `refusing to import into the source Vault` | `--addr` equals the export's source address; use `--allow-same-vault` only for a deliberate rollback |
| `N secret(s) differ from the export after import` | something else wrote to the target during the import; run it again |
| `check-and-set parameter did not match the current version` | a concurrent writer changed that secret; run it again |
| `could not verify hash file` (B) | add `-force` |
| `413 Request Entity Too Large` (B) | restore through the port-forward, not the ingress |
| `vault login` fails after a typo | the password prompt takes Backspace literally; press Ctrl-C and retype |
