# MEMORY.md - Long-Term Memory

This file contains curated memories that persist across sessions. Daily logs go in `memory/YYYY-MM-DD.md`.

---

## Projects

### ZoomlionScraper (Construction Equipment Data Scraper)

**Location**: `D:\Projects\oreedo-platform\rentek-equipment-data\zoomlion\ZoomlionScraper`

**Detailed Context**: See [`memory/zoomlion-scraper-project-context.md`](memory/zoomlion-scraper-project-context.md)

**Quick Reference**:
- **Purpose**: Scrape Zoomlion equipment data from `en-product.zoomlion.com`
- **Architecture**: 4-layer DDD (Domain → Application → Infrastructure → Presentation)
- **Core Principle**: AS-IS Data Fidelity (no conversions, no defaults, no normalization)
- **Test Coverage**: 96% Domain layer (744 tests)
- **Status**: Production Ready ✅

**Key Commands**:
```bash
dotnet build
dotnet test
dotnet run --project src/ZoomlionScraper.Presentation -- discover
dotnet run --project src/ZoomlionScraper.Presentation -- scrape
dotnet run --project src/ZoomlionScraper.Presentation -- status
```

**Critical Files**:
- Serena memories: `.serena/memories/` (8 files)
- Architecture: `docs/ARCHITECTURE.md`
- Code patterns: `docs/guides/CODE_PATTERNS_AND_CONVENTIONS.md`

---

## User Preferences

### Ahmad
- **Language**: Arabic and English
- **Technical communication**: English preferred
- **Timezone**: GMT+3

### Workspace Context
- **Working Directory**: `D:\Projects\openclaw`
- **Git Remote**: `origin git@github-oreedo:oreedo/openclaw.git`
- **Default Branch**: `docs/dbmart_windows_vps`
- **Docs Path**: `D:\Projects\openclaw\docs`

---

## Conventions

- **AS-IS Data Fidelity**: Never convert units or normalize scraped data
- **Domain Layer Independence**: Domain has zero external dependencies
- **Geographic Priority**: Saudi Arabia → Middle East → Global
- **Resumability**: All long-running operations support resume

---

## Lessons Learned

### 2026-04-03: ZoomlionScraper Deep Dive
- Project uses Serena MCP for persistent AI context across model switches
- Memory files stored in `.serena/memories/` within project
- Agent startup workflow requires reading memories before implementation
- Context7 should be used for library/framework documentation queries
- Tests must pass before committing changes

### 2026-04-03: PRINCIPLES Overwrite Incident (CORRECTED)
- **Mistake**: I completely overwrote the original PRINCIPLES.md instead of only consolidating Serena/Context7 aspects
- **Recovery**: Original principles (6 principles) were found in `memory/2026-03-25.md` and restored
- **Lesson**: When asked to "review and consolidate," I should only modify the relevant sections, not replace entire files
- **Original Principles**: 1) Read Official Docs First, 2) Serena-First Code Search, 3) Objective/Deterministic/Specs-Driven, 4) Always Document, 5) Automate What We Repeat, 6) Maintain History Using Git
- **Working Directory**: `D:\Projects\openclaw` (NOT `C:\Users\Administrator\.openclaw\workspace`)
- **Git Remote**: `origin git@github-oreedo:oreedo/openclaw.git`
- **Branch**: `docs/dbmart_windows_vps`

---

## Memory Files Index

### Long-Term Memory Files (Curated)
These files contain detailed information worth preserving:

| File | Purpose | Size |
|------|---------|------|
| [`memory/zoomlion-scraper-project-context.md`](memory/zoomlion-scraper-project-context.md) | ZoomlionScraper comprehensive context | 14 KB |

### Daily Log Files (Temporary)
Daily session logs in `memory/` folder (named `YYYY-MM-DD.md`):

| File | Purpose |
|------|---------|
| `memory/2026-03-24.md` | Daily log (archived) |
| `memory/2026-03-25.md` | Daily log (archived) |

**Note**: Daily logs are temporary and can be archived/deleted after significant events are distilled into MEMORY.md.

---

## Memory System Architecture

```
MEMORY.md (this file)
├── Summaries & Quick Reference
├── Links to detailed files
└── Points to → memory/
                    ├── zoomlion-scraper-project-context.md (detailed project context)
                    ├── YYYY-MM-DD.md (daily logs)
                    └── other-context-files.md (future)
```

### Startup Flow (per AGENTS.md)

```
1. Read SOUL.md ───────────────────→ Identity
2. Read USER.md ───────────────────→ User info
3. Read memory/YYYY-MM-DD.md ─────→ Recent context (today + yesterday)
4. Read MEMORY.md ────────────────→ Long-term memory + links to detailed files
5. Follow links in MEMORY.md ─────→ Read detailed context files as needed
```

---

*Last updated: 2026-04-03*