# Oreedo Infrastructure Documentation

> Branch: `docs/hetzner_vps` | Host: `oreedo-ubuntu` (162.55.210.53)

## Structure

```
├── cluster/
│   └── KUBERNETES_CLUSTER.md    # Full MicroK8s cluster inventory
├── vault/
│   └── VAULT_IMPORT_GUIDE.md    # Loading Vault data into another Vault
├── rentek/
│   └── RENTEK_SOURCE_ANALYSIS.md # Full analysis of the Rentek stack on the source server
├── runbooks/
│   └── RUNBOOKS.md              # Operational procedures (health, backup, TLS, deploy, cutover)
├── principles.md                # Working principles (source of truth)
├── migration-plan.md            # Script-driven plan for migrating off Hetzner
├── assistant-operating-notes.md # Practical working rules for the assistant
├── mcporter-guide.md            # Calling Context7/Serena MCP from the shell
└── README.md                    # This file
```

Scripts live in the top-level `scripts/` folder beside `docs/`, never inside `docs/`.

## Convention

- One doc per folder, update-in-place, remove deprecated lines
- No versioning docs — always current state
