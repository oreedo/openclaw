# ZoomlionScraper Project Context Memory

**Created**: 2026-04-03
**Purpose**: Persistent learning about the ZoomlionScraper project for model continuity

---

## Project Overview

**Project**: ZoomlionScraper
**Location**: `D:\Projects\oreedo-platform\rentek-equipment-data\zoomlion\ZoomlionScraper`
**Purpose**: Production-ready web scraping system for extracting Zoomlion construction equipment data from `en-product.zoomlion.com`
**Status**: Production Ready ✅

### Mission
Extract equipment data into structured, per-model JSON with **AS-IS Data Fidelity** - no unit conversions, no synthetic defaults, no normalization. Preserve data exactly as it appears on source website.

---

## Architecture: 4-Layer DDD

### Dependency Flow (Inward Only)
```
Presentation (.NET 10) → Application → Domain ← Infrastructure
```

**CRITICAL**: Domain layer has **ZERO external dependencies** - pure BCL only.

### Layer Breakdown

| Layer | Project | Framework | Key Components |
|-------|---------|-----------|----------------|
| **Domain** | `ZoomlionScraper.Domain` | .NET Standard 2.0 | Entities, Value Objects, Specifications, Parsers, Repository Interfaces, Services |
| **Application** | `ZoomlionScraper.Application` | .NET Standard 2.0 | Use Cases (5), DTOs, Configuration |
| **Infrastructure** | `ZoomlionScraper.Infrastructure` | .NET Standard 2.0 | Playwright scraping, Polly resilience, File repositories, Mapping |
| **Presentation** | `ZoomlionScraper.Presentation` | .NET 10 | CLI commands (6), DI container, Spectre.Console UI |

### Project Structure
```
src/
├── ZoomlionScraper.Domain/
│   ├── Aggregates/          # Manifest, EquipmentCatalog
│   ├── Entities/            # BaseEquipment + 8 concrete types, Category, ProgressState
│   ├── Factories/           # SpecificationFactory
│   ├── Interfaces/          # Repository interfaces (IEquipmentRepository, etc.)
│   ├── Parsing/             # WeightParser, LengthParser, VolumeParser, etc.
│   ├── Services/            # DataFidelityValidator, GeographicPrioritizationService
│   ├── Specifications/      # Specification hierarchy (typed)
│   └── ValueObjects/        # WeightValue, LengthValue, GeographicRegion, etc.
├── ZoomlionScraper.Application/
│   ├── DTOs/
│   ├── Logging/
│   └── UseCases/            # 5 use cases
├── ZoomlionScraper.Infrastructure/
│   ├── Configuration/
│   ├── Mapping/
│   ├── Playwright/
│   ├── Repositories/
│   ├── Resilience/
│   ├── Scraping/
│   └── Serialization/
└── ZoomlionScraper.Presentation/
    └── Commands/            # 6 CLI commands
```

---

## Domain Layer Details

### Entities (8 Concrete Equipment Types)
1. **MiniExcavator** - Earthmoving category
2. **CrawlerCrane** - Mobile Crane category
3. **PlacingBoom** - Concrete Machinery
4. **FlatTopTowerCrane** - Construction Hoisting
5. **ElectricArticulatingBoomLift** - MEWPs
6. **ElectricForklift** - Industrial Vehicle
7. **MiningDumpTruck** - Mining Machinery
8. **AerialLadderFirefightingVehicle** - Emergency Equipment
9. **ZoomlionEquipment** - Generic fallback

**Base Class**: `BaseEquipment` (abstract)
- `Id` (Guid), `ModelName`, `ManufacturerName` ("Zoomlion")
- `GetDomainSpecifications()`, `GetSpecifications()` methods
- Named property shortcuts for common specs

### Specifications (Typed Hierarchy)
- **Base**: `Specification` record (preserves `OriginalFieldName`, `OriginalValueString`)
- **Typed**: `WeightSpecification`, `LengthSpecification`, `VolumeSpecification`, `PowerSpecification`, `SpeedSpecification`, `PressureSpecification`, `ForceSpecification`, `VelocitySpecification`, `RangeSpecification`, `DimensionSpecification`
- **Fallback**: `StringSpecification` (for unparseable values)

**Key Method**: `SpecificationFactory.Create(fieldName, value, specType, order)` - auto-detects type

### Parsers (AS-IS Preservation)
- `WeightParser.Parse("1500 kg")` → `WeightValue { Value=1500, Unit=Kilogram, OriginalString="1500 kg" }`
- `LengthParser`, `VolumeParser`, `PowerParser`, `SpeedParser`, `RangeParser`
- All preserve `OriginalString` for data fidelity

### Services
- **`DataFidelityValidator`** - Detects unit conversions, translation artifacts, normalized field names
- **`GeographicPrioritizationService`** - Priority: Saudi Arabia → Middle East → Global

### Repository Interfaces
- `IEquipmentRepository` - Save/Get/Exists/List/Delete/Count
- `IManifestRepository` - Load/Save/Exists/Delete manifest per region
- `ICategoryRepository` - Save one/many, Load by id/all
- `IProgressStateRepository` - Session persistence for resume functionality

---

## Application Layer Details

### Use Cases (5)
| Use Case | Purpose | Key Dependencies |
|----------|---------|-------------------|
| `DiscoverCategoryHierarchyUseCase` | Discovers category hierarchy from website | `IWebScraperService`, `IManifestRepository`, `ICategoryRepository` |
| `ScrapeEquipmentDetailsUseCase` | Scrapes equipment specifications | `IEquipmentRepository`, `IProgressStateRepository` |
| `CheckScraperStatusUseCase` | Shows progress/statistics | `IProgressStateRepository` |
| `ResumeScrapingSessionUseCase` | Resumes interrupted sessions | `IProgressStateRepository`, `ScrapeEquipmentDetailsUseCase` |
| `GenerateJsonSchemaUseCase` | Generates JSON schemas from data | `IEquipmentRepository` |

---

## Infrastructure Layer Details

### Scraping Components
- **`PlaywrightWebScraperService`** - Browser lifecycle, retry orchestration
- **`ZoomlionCategoryScraper`** - Discovers `sCat`/`fCat` categories via `/ext/ajax_proList.jsp` AJAX endpoint
- **`ZoomlionEquipmentScraper`** - Extracts model, image, description, tabbed specifications
- **`PageNavigator`** - URL navigation, load-state waits, selector waits
- **`ElementExtractor`** - DOM element extraction helpers

### Resilience (Polly)
- **Retry**: Exponential backoff (1s → 2s → 4s), 3 max retries
- **Circuit Breaker**: Opens after 5 consecutive failures, 30s duration

### Repositories (File-System)
- **Atomic writes**: Write to temp file → move to final path
- **Region folders**: `output/<region>/`
- **Equipment path**: `output/<region>/<category>/<model-slug>.json`
- **Progress path**: `output/.progress/<session-id>.json`

### Equipment Type Mapping
- Driven by `(sCat, fCat)` tuple from category URLs
- `EquipmentMapper.MapToEquipmentType(sCat, fCat)` returns concrete type

---

## Presentation Layer Details

### CLI Commands (6)
| Command | Handler | Description |
|---------|---------|-------------|
| `discover` | `DiscoverCommandHandler` | Discover category hierarchy |
| `scrape` | `ScrapeCommandHandler` | Scrape equipment details |
| `status` | `StatusCommandHandler` | Show scraping progress |
| `resume` | `ResumeCommandHandler` | Resume interrupted session |
| `generate-schemas` | `GenerateSchemasCommandHandler` | Generate JSON schemas |
| `demo` | `DemoCommandHandler` | Demo mode (direct) |

**Entry Point**: `Program.cs` - builds root command, handles exceptions, sets exit codes

### Dependency Injection
- `ServiceRegistration.CreateServiceProvider(config)` wires all layers
- Use cases registered as transient
- Command handlers resolved from DI

---

## Core Principles (Non-Negotiable)

### 1. AS-IS Data Fidelity
- **NO unit conversions**: "8500 kg" stays "8500 kg"
- **NO defaults**: Missing fields are omitted entirely
- **NO normalization**: Preserve exact formatting
- **Preserve tab structure**: Maintain specification hierarchy

### 2. Domain Layer Independence
- Zero external dependencies
- Persistence ignorance
- Infrastructure ignorance

### 3. Geographic Prioritization
1. Saudi Arabia
2. Middle East
3. Global

### 4. Resumability
- Progress persisted atomically
- Incomplete sessions queryable
- Resume from last checkpoint

---

## Testing

- **Framework**: xUnit + FluentAssertions + NSubstitute
- **Coverage**: **96%** Domain layer (2,532/2,635 lines)
- **Tests**: 744 total
- **Pattern**: AAA (Arrange-Act-Assert)
- **Naming**: `<MethodName>_<Scenario>_<ExpectedResult>`

### Test Commands
```bash
dotnet build
dotnet test
dotnet test --collect:"XPlat Code Coverage" --results-directory CoverageReport
reportgenerator -reports:"CoverageReport/coverage.cobertura.xml" -targetdir:"CoverageReport"
```

---

## Key Files to Know

### Domain Layer
- `src/ZoomlionScraper.Domain/Entities/BaseEquipment.cs` - Abstract base for all equipment
- `src/ZoomlionScraper.Domain/Entities/MiniExcavator.cs` - Example typed entity with specs
- `src/ZoomlionScraper.Domain/Specifications/Specification.cs` - Base specification record
- `src/ZoomlionScraper.Domain/Factories/SpecificationFactory.cs` - Auto-detects spec types
- `src/ZoomlionScraper.Domain/Services/DataFidelityValidator.cs` - Enforces AS-IS rules
- `src/ZoomlionScraper.Domain/Interfaces/IEquipmentRepository.cs` - Repository contract

### Infrastructure Layer
- `src/ZoomlionScraper.Infrastructure/Scraping/ZoomlionEquipmentScraper.cs` - Equipment page scraper
- `src/ZoomlionScraper.Infrastructure/Scraping/ZoomlionCategoryScraper.cs` - Category discovery
- `src/ZoomlionScraper.Infrastructure/Repositories/FileSystemEquipmentRepository.cs` - Persistence

### Presentation Layer
- `src/ZoomlionScraper.Presentation/Program.cs` - CLI entry point
- `src/ZoomlionScraper.Presentation/Commands/*.cs` - Command handlers

### Documentation
- `docs/ARCHITECTURE.md` - Complete architecture overview
- `docs/adr/` - Architecture Decision Records (5 ADRs)
- `docs/guides/CODE_PATTERNS_AND_CONVENTIONS.md` - Coding standards
- `docs/guides/UNIT_TESTING_GUIDE.md` - Testing patterns
- `.serena/memories/` - Serena AI memory files (8 files)

---

## Serena Memory System

The project uses **Serena MCP** for persistent AI context:

### Memory Files Location
`D:\Projects\oreedo-platform\rentek-equipment-data\zoomlion\ZoomlionScraper\.serena\memories\`

### Memory Files (8)
1. `project_overview.md` - Tech stack, commands, core principles
2. `domain_architecture.md` - 4-layer DDD, coverage status
3. `scraper_pipeline_details.md` - Discovery and scrape pipeline
4. `repository_contracts.md` - Repository interfaces/implementations
5. `testing_patterns.md` - Test conventions, coverage
6. `task_completion_criteria.md` - Definition of done
7. `command_handler_map.md` - CLI command mapping
8. `docs_and_instructions_map.md` - Documentation topology

### Agent Startup Workflow (MUST)
1. Activate Serena project
2. Run initial instructions flow
3. List memories
4. Read relevant memories
5. Only then implement

---

## Discovery Results

**Categories Discovered**: 10 (9 verified working)

| Category | sCat | Status |
|----------|------|--------|
| Earthmoving Machinery | 57 | ✅ Verified |
| MEWPs | 59 | ✅ Verified |
| Mobile Crane Machinery | 54 | ✅ Verified |
| Construction Hoisting | 56 | ✅ Verified |
| Concrete Machinery | 55 | ✅ Verified |
| Agricultural Machinery | 61 | ✅ Verified |
| Industrial Vehicle | 60 | ✅ Verified |
| Foundation Machinery | 58 | ✅ Verified |
| Mining Machinery | 64 | ✅ Verified |
| Emergency Equipment | 234 | ⚠️ Empty |

**Estimated Equipment**: 260-520 units

---

## Output Structure

```
output/
├── saudi-arabia/
│   ├── manifests/
│   │   ├── discovery-manifest-nested.json
│   │   └── discovery-manifest-flat.json
│   ├── mobile-cranes/
│   │   ├── qy25k5-i.json
│   │   └── mobile-cranes-json-schema.json
│   └── .progress/
│       └── <session-id>.json
└── logs/
    └── scraper-YYYY-MM-DD.log
```

---

## Common Commands

```bash
# Build
dotnet build

# Test
dotnet test

# Discover categories
dotnet run --project src/ZoomlionScraper.Presentation -- discover

# Scrape equipment
dotnet run --project src/ZoomlionScraper.Presentation -- scrape

# Check status
dotnet run --project src/ZoomlionScraper.Presentation -- status

# Resume session
dotnet run --project src/ZoomlionScraper.Presentation -- resume

# Generate schemas
dotnet run --project src/ZoomlionScraper.Presentation -- generate-schemas
```

---

## Key Technical Patterns

### Equipment Type Resolution
```csharp
// Equipment type determined by (sCat, fCat) tuple
var equipmentType = EquipmentMapper.MapToEquipmentType(sCat, fCat);
```

### Specification Auto-Detection
```csharp
// SpecificationFactory tries parsers in order:
// Weight → Length → Volume → Speed → Power → Range → Dimension → String (fallback)
var spec = SpecificationFactory.Create(fieldName, value, specType, order);
```

### AS-IS Data Validation
```csharp
var result = DataFidelityValidator.ValidateScrapedData(specifications);
if (!result.IsValid) {
    // Log violations
}
```

### Resumability Pattern
```csharp
var sessions = await progressRepo.GetIncompleteSessionsAsync();
var session = sessions.FirstOrDefault() ?? await progressRepo.CreateSessionAsync();
// Resume from session.ProcessedUrls
```

---

## Important Notes for AI Agents

1. **Always read `.serena/memories/` before making changes** - this is the persistent context
2. **Domain layer has NO dependencies** - never add external packages to Domain
3. **AS-IS fidelity is non-negotiable** - never convert units or normalize values
4. **Use Context7 for library questions** - query official docs first
5. **Run tests after changes** - `dotnet test` must pass
6. **Update memories when architecture changes** - keep `.serena/memories/` in sync

---

## Related Documentation

- `docs/ARCHITECTURE.md` - Full architecture
- `docs/adr/001-four-layer-ddd-architecture.md` - Why 4-layer DDD
- `docs/adr/002-as-is-data-fidelity.md` - Why AS-IS principle
- `docs/adr/003-serena-memory-system.md` - Why Serena for AI context
- `docs/guides/INSTRUCTIONS_GUIDE.md` - Copilot instruction migration

---

**Last Updated**: 2026-04-03
**Next Review**: When architecture changes or new equipment types added