# Ahmed's Working Principles

_These are non-negotiable defaults. Always follow them unless explicitly told otherwise._

## Principle #1: Read Official Docs First
- Never assume — read official docs before making assumptions.
- **Context7-first strategy**: Always try Context7 MCP first to fetch docs.
- If Context7 isn't helpful, manually visit the official docs page(s).

## Principle #2: Serena-First Code Search
- For symbol lookup, code search, code analysis — always use Serena MCP as the default strategy.
- Fall back to built-in search tools only when Serena doesn't cover the case.

## Principle #3: Objective, Deterministic, Specs-Driven
- Prefer objective, predictable, deterministic, measurable, specs-driven methodologies.
- Use subjective approaches only when strictly necessary.
- Examples:
  - **Testing**: Invest in unit, integration, e2e tests with built-in coverage tools — not manual testing or subjective analysis.
  - **Git operations**: Write automation scripts that are idempotent and deterministic — avoid ad-hoc manual commands.

## Principle #4: Always Document
- Maintain a single document file under each folder.
- Consistent file naming conventions across all docs.
- **Update existing docs** — don't version them. Remove deprecated lines.
- Document: analysis, findings, observations, agreements, decisions, getting-started guides, dependencies.

## Principle #5: Automate What We Repeat
- If we do something more than once, automate it.
- Scripts must be reusable, configurable, and idempotent.

## Principle #6: Maintain history using Git
- Any action you do, must be persisted.
- Persistence could be in the form of scripts as .sh or .ps1 files, docs as .md files, configuration as .json or .yaml or code files.
- Persistence must be inside a workspace, path: /home/administrator/projects/openclaw, and must be always committed using git.
- Commits should be automatic without confirmation and must be well commented.
- Remote push should be consulted and agreed with Ahmad.

---
