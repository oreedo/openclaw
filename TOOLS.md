# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## What Goes Here

Things like:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

Add whatever helps you do your job. This is your cheat sheet.

---

## Workspace Context

| Item | Value |
|------|-------|
| **Working Directory** | `D:\Projects\openclaw` |
| **Git Remote** | `origin git@github-oreedo:oreedo/openclaw.git` |
| **Default Branch** | `docs/dbmart_windows_vps` |
| **Docs Path** | `D:\Projects\openclaw\docs` |

---

## MCP Servers (CRITICAL)

These servers are ALWAYS available. Use them according to PRINCIPLES.md.

### Primary MCP Servers

| Server | ID | Purpose | Priority |
|--------|-----|---------|----------|
| **Context7** | `context7` | Library/docs lookup via upstash/context7 | Primary for external tech |
| **Serena** | `serena` | Code intelligence via oraios/serena | Primary for code search |

### Status (Verified 2026-03-25)

| Server | Status | Source |
|--------|--------|--------|
| **Context7** | Working | `~\.cursor\mcp.json` |
| **Serena** | Working | `~\.claude.json` |

### Usage Patterns

```markdown
## Code Intelligence (Serena)
1. Activate project: `serena.activate_project`
2. List memories: `serena.list_memories`
3. Read memory: `serena.read_memory`
4. Search symbols: `serena.search_symbol`
5. Analyze code: `serena.analyze_file`

## Library Docs (Context7)
1. Resolve library ID: `context7.resolveLibraryID`
2. Query docs: `context7.getLibraryDocs`
3. State source: "According to Context7 docs..."
```

### When Servers Are Unavailable

If an MCP server is offline or rate-limited:

1. **State the limitation explicitly** (e.g., "Context7 quota exhausted")
2. **Use fallback approach** (e.g., web search, built-in tools)
3. **Note uncertainty** in response

---

## Project-Specific Notes

### ZoomlionScraper Project

**Location**: `D:\Projects\oreedo-platform\rentek-equipment-data\zoomlion\ZoomlionScraper`

**Memory Location**: `.serena/memories/` (8 memory files)

**Key Files**:
- `docs/ARCHITECTURE.md` - Architecture overview
- `docs/guides/CODE_PATTERNS_AND_CONVENTIONS.md` - Coding standards
- `docs/guides/UNIT_TESTING_GUIDE.md` - Testing patterns

**Startup Workflow** (per project AGENTS.md):
1. Activate Serena project
2. Run initial instructions flow
3. List memories
4. Read relevant memories
5. Only then edit files
6. Update memory at completion

**Core Principle**: AS-IS Data Fidelity (no unit conversions, no defaults, no normalization)

---

*Last updated: 2026-04-03*