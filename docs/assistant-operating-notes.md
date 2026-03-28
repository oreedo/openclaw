# Assistant Operating Notes

This file exists to reduce repeat mistakes and preserve practical working habits across sessions.

---

## Core Working Rules

### 1) Use the real git workspace
When work should persist, prefer:
- `/home/openclaw`

Do not leave important documentation only in:
- `/root/.openclaw/workspace`

Use `/root/.openclaw/workspace` for session-local continuity, but persist durable operational docs/scripts in `/home/openclaw`.

### 2) Read the local principles first
Before substantial work in `/home/openclaw`, read:
- `/home/openclaw/docs/principles.md`

Key rules from there:
- update existing docs instead of duplicating them
- persist changes in `/home/openclaw`
- commit changes to git automatically with a meaningful message
- consult Ahmed before pushing remote

### 3) Keep memory updated frequently
Ahmed explicitly wants memory read and updated frequently.

At minimum, when learning stable preferences or important environment details, update:
- `/root/.openclaw/workspace/memory/YYYY-MM-DD.md`

---

## Tooling Strategy

### Context7 first for external docs
Use Context7 when the task is about:
- external libraries
- frameworks
- APIs
- official product documentation
- current configuration/behavior of a technology

Preferred MCPorter flow:

```bash
mcporter call context7.resolve-library-id libraryName=<name> query='<specific question>' --output json
mcporter call context7.query-docs libraryId=<resolved-id> query='<specific question>' --output json
```

### Serena first for repo-aware analysis
Use Serena when the task is about:
- repository structure
- code search
- symbols/functions/classes
- semantic analysis of a project
- project memory

Preferred MCPorter flow:

```bash
mcporter call serena.activate_project project=<project-path> --output json
mcporter call serena.initial_instructions --output json
```

Then use Serena tools like:
- `list_dir`
- `find_file`
- `search_for_pattern`
- `get_symbols_overview`
- `find_symbol`
- `find_referencing_symbols`
- `write_memory`
- `read_memory`

### Important Serena caveat
One-shot `mcporter call` commands may not preserve active project state across separate invocations.

Implication:
- Context7 via one-shot MCPorter calls is usually fine
- Serena via one-shot MCPorter calls is fine for spot checks, but persistent-session clients are better for multi-step work

Reference guide:
- `/home/openclaw/docs/mcporter-guide.md`

---

## Shell and Cluster Notes

### MicroK8s path
`microk8s` may exist even when not on PATH:
- `/snap/bin/microk8s`

### Ahmed aliases in `~/.bashrc`
Ahmed configured:
- `kubectl` -> `microk8s kubectl`
- `helm` -> `microk8s helm`

If using aliases in shell commands:

```bash
source ~/.bashrc
kubectl ...
helm ...
```

For robust automation, absolute paths are still safe:

```bash
/snap/bin/microk8s kubectl ...
```

---

## Rentek Notes

Confirmed public path:
- `rentek-ingress` -> `rentek-svc` -> selector `app=rentek-app2`

Confirmed active app:
- deployment: `rentek-app2`
- image: `oreedo/rentek:0.6.7`
- pull secret: `registry-1`
- ConfigMap: `assetlinks-config`

Important caveat:
- `rentek-app` mounts `rentek-pictures-pvc`
- active `rentek-app2` does not
- this should be validated in any migration or functionality review

Migration plan location:
- `/home/openclaw/docs/migration-plan.md`

---

## Why this file exists

This file is here because forgetting these patterns wastes time and causes avoidable mistakes.
Update it when repeated lessons show up.
