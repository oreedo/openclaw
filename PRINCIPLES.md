# PRINCIPLES.md

These principles are ALWAYS in effect. Non-compliance requires explicit justification.

---

## Enforcement Language

| Term | Meaning |
|------|---------|
| **MUST** | Required. No exceptions unless tool/service is unavailable. |
| **MUST NOT** | Prohibited behavior. |
| **ALWAYS** | Applies to every applicable task without omission. |
| **SHOULD** | Strong recommendation. Exceptions require documented reason. |

---

## Principle #1: Read Official Docs First (MUST)

**Never assume — read official docs before making assumptions.**

### Context7-First Strategy (MUST)

1. **MUST** use Context7 MCP first for any library, framework, SDK, API, CLI tool, or cloud service question.
2. **MUST** resolve the Context7 library ID before querying docs (unless user provided valid ID).
3. **MUST** query Context7 official documentation before producing an answer.
4. **MUST** prioritize Context7 docs over model memory for:
   - Versioned syntax
   - Setup and configuration
   - Migration paths
   - Version-specific behavior
5. **MUST** keep queries focused to reduce latency and token usage.
6. **MUST** clearly state when guidance comes from Context7 documentation.
7. **MUST** explicitly disclose if Context7 is unavailable, rate-limited, or quota-exhausted.
   - Then provide best-effort fallback guidance with that limitation noted.

### Fallback

- If Context7 isn't helpful, manually visit the official docs page(s).

---

## Principle #2: Serena-First Code Search (MUST)

**Use Serena MCP as the default strategy for code intelligence.**

### Startup Sequence (MUST complete before editing files)

1. **MUST** activate the Serena project first.
2. **MUST** run the initial Serena instructions flow.
3. **MUST** call `list_memories` at task start.
4. **MUST** read all relevant memories before analysis or implementation.
5. **MUST NOT** edit files until steps 1-4 are completed.
6. **MUST** write or update memory at task completion if new durable knowledge was produced.

### Code Search Strategy

- **MUST** use Serena MCP as the default for:
  - Symbol lookup
  - Code search
  - Code analysis
  - Project structure discovery
  - Targeted search
- **MAY** fall back to built-in search tools only when Serena doesn't cover the case or is unavailable.
- **MUST** clearly state if Serena is offline or unavailable.

---

## Principle #3: Objective, Deterministic, Specs-Driven (ALWAYS)

**Prefer objective, predictable, deterministic, measurable, specs-driven methodologies.**

- **Testing**: Invest in unit, integration, e2e tests with coverage tooling over manual testing.
- **Git operations**: Write idempotent scripts that can be re-run deterministically.
- **Specs-driven**: Use specifications as the source of truth.
- **Measurable**: Prefer approaches with quantifiable outcomes.

Use subjective approaches only when objective methods are impractical or unavailable.

---

## Principle #4: Always Document (ALWAYS)

**Maintain documentation as living artifacts.**

### Documentation Rules

- **MUST** maintain a single documentation file under each folder.
- **MUST** use consistent file naming conventions across all docs.
- **MUST** update existing docs in-place — don't version them.
- **MUST** remove deprecated lines (no outdated content).
- **MUST** document:
  - Analysis and findings
  - Observations
  - Agreements
  - Decisions
  - Getting-started guides
  - Dependencies

---

## Principle #5: Automate What We Repeat (ALWAYS)

**If we do something more than once, automate it.**

- **MUST** create scripts for repetitive operations.
- **MUST** make scripts:
  - Reusable
  - Configurable
  - Idempotent
- **SHOULD** prefer scripts over manual steps.

---

## Principle #6: Maintain History Using Git (ALWAYS)

**Any action MUST be persisted.**

### Persistence Format

- Scripts: `.sh` or `.ps1` files
- Documentation: `.md` files
- Configuration: `.json`, `.yaml`, or code files

### Workspace

- **MUST** persist inside workspace: `D:\Projects\openclaw`
- **MUST** always commit using git.
- **MUST** make commits automatic without confirmation.
- **MUST** ensure commits are well commented.
- **MUST** consult and agree with Ahmad before remote push.

### Git Repository

- **Working Directory**: `D:\Projects\openclaw`
- **Git Remote**: `origin git@github-oreedo:oreedo/openclaw.git`
- **Branch**: `docs/dbmart_windows_vps`

---

## Quick Reference

| Task | Primary Tool | Fallback |
|------|-------------|----------|
| Library/framework docs | Context7 MCP | Official website |
| Code search/analysis | Serena MCP | Built-in search |
| Persistence | Git (auto-commit) | — |
| Documentation | Single file per folder | — |

---

## MCP Server Status

| Server | Status | Source |
|--------|--------|--------|
| **Context7** | Working | `~\.cursor\mcp.json` |
| **Serena** | Working | `~\.claude.json` |

---

## Non-Compliance Protocol

If a principle cannot be followed:

1. **MUST** document the reason.
2. **MUST** state the limitation explicitly.
3. **MUST** provide best-effort alternative.
4. **SHOULD** note how to fix for future.

---

*Last updated: 2026-04-03*
*Version: 2.0 — Consolidated with enforcement language from ZoomlionScraper project (Serena/Context7 sections only)*
*Original principles preserved from 2026-03-25*