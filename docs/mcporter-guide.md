# Guide: Using MCPorter for Context7 and Serena MCP

MCPorter is a practical way to inspect, test, and use MCP servers from the shell. This guide focuses on the two MCP servers currently relevant on this cluster: **Context7** and **Serena**.

---

## Prerequisites

- **MCPorter installed** and on your `PATH`
- Working MCP server configuration for the target server(s)
- For **Context7**:
  - either remote HTTP MCP config or local `@upstash/context7-mcp`
  - API key if required by your chosen transport
- For **Serena**:
  - a configured Serena MCP server
  - a local project path to activate before using project-scoped tools

---

## Core MCPorter Commands

### List available MCP servers

```bash
mcporter list
```

### Show tool schema for a server

```bash
mcporter list context7 --schema
mcporter list serena --schema
```

### Call a tool

```bash
mcporter call <server>.<tool> <arg>=<value> --output json
```

Examples:

```bash
mcporter call context7.resolve-library-id libraryName=kubernetes query='persistent volume claim migration' --output json
mcporter call serena.activate_project project=/home/scripts/linux-scripts --output json
```

---

## Context7 Usage Guide

Context7 is best used when you need **current, library-specific, framework-specific, or product-specific documentation** instead of general web search.

### What Context7 is good at

- Resolving the correct doc source for a library/framework/product
- Fetching focused documentation answers from upstream docs
- Supplying examples and implementation patterns
- Reducing hallucinations around APIs and platform behavior

### Typical workflow

#### 1) Inspect available Context7 tools

```bash
mcporter list context7 --schema
```

Typical tools include:
- `resolve-library-id`
- `query-docs`

#### 2) Resolve the library or product first

```bash
mcporter call context7.resolve-library-id \
  libraryName=kubernetes \
  query='persistent volume claim migration another kubernetes cluster' \
  --output json
```

This returns the library identifier to use in later queries.

#### 3) Query the docs

```bash
mcporter call context7.query-docs \
  libraryId=/websites/kubernetes_io \
  query='How do I migrate a PersistentVolumeClaim and its data to another Kubernetes cluster?' \
  --output json
```

### Real example used on this cluster

The following query was tested successfully:

```bash
mcporter call context7.query-docs \
  libraryId=/websites/kubernetes_io \
  query='How do I migrate a PersistentVolumeClaim and its data to another Kubernetes cluster? Include practical approaches using CSI VolumeSnapshots, Velero/restic or filesystem-level copy, storage-class constraints, reclaim policy handling, and cutover considerations.' \
  --output json
```

### Practical tips for Context7

- Resolve the library ID first unless you already know it.
- Use narrow, concrete questions instead of broad prompts.
- Ask for constraints explicitly, like:
  - storage class compatibility
  - version caveats
  - migration limitations
  - security or auth requirements
- Treat Context7 as **documentation retrieval**, not codebase introspection.

### When to prefer Context7 over web search

Use Context7 when:
- you already know the product/library
- you want upstream docs rather than blog posts
- you need examples grounded in official documentation

Use web search when:
- you do not know the product/library yet
- you need community comparison posts or issue threads
- you need broader operational guidance beyond product docs

---

## Configuring Context7 with MCPorter

MCPorter can use Context7 in two main ways:

### 1) Via imported client configs

MCPorter can discover MCP servers from configs used by tools like:
- Codex
- Claude Code
- Cursor
- OpenCode
- other supported clients

That means if Context7 is already configured in a client config, `mcporter list` may surface it automatically.

### 2) Via MCPorter-native config

You can also define Context7 directly in MCPorter instead of relying on imported configs.

General pattern:

```bash
mcporter config add context7 <url-or-server-definition>
```

Then verify:

```bash
mcporter list
mcporter list context7 --schema
```

> Exact config details depend on whether you are using remote HTTP transport or a local stdio server.

---

## Serena Usage Guide

Serena is for **project-aware semantic code navigation and memory**, not documentation lookup.

It is especially useful for:
- repo structure discovery
- symbol-aware code understanding
- targeted search
- project memory capture
- lightweight semantic analysis without manually grepping everything

### Important Serena model

Serena is **project-scoped**.
Before using most Serena tools, activate the project first.

```bash
mcporter call serena.activate_project project=/home/scripts/linux-scripts --output json
```

### Inspect Serena tools

```bash
mcporter list serena --schema
```

Common useful tools:
- `activate_project`
- `initial_instructions`
- `check_onboarding_performed`
- `list_dir`
- `find_file`
- `search_for_pattern`
- `get_symbols_overview`
- `find_symbol`
- `find_referencing_symbols`
- `write_memory`
- `read_memory`
- `list_memories`

### Recommended Serena workflow

#### 1) Activate the target project

```bash
mcporter call serena.activate_project project=/home/scripts/linux-scripts --output json
```

#### 2) Read the Serena instructions once

```bash
mcporter call serena.initial_instructions --output json
```

#### 3) Check onboarding state

```bash
mcporter call serena.check_onboarding_performed --output json
```

#### 4) Explore the repository

```bash
mcporter call serena.list_dir relative_path=. recursive=false --output json
mcporter call serena.find_file file_mask='*.sh' relative_path=. --output json
mcporter call serena.search_for_pattern substring_pattern='kubectl|helm|argocd' --output json
```

#### 5) Write useful project memory

```bash
mcporter call serena.write_memory \
  memory_name=project_overview_deep \
  content='High-level summary of the repo structure and what it is used for.' \
  --output json
```

### Real Serena test on this cluster

Serena was tested against:

```bash
/home/scripts/linux-scripts
```

Observed behavior:
- project activation worked
- Serena identified the repo as primarily **bash**
- existing memories were available
- `initial_instructions` returned correctly
- Serena exposed semantic and memory tools correctly

Additionally, I used Serena memory-write calls to create deeper project notes for this repository, including:
- `project_overview_deep`
- `repo_topics_deep`
- `usage_patterns_deep`

### Important MCPorter caveat with Serena

When using `mcporter call` as a **one-shot CLI invocation**, Serena project activation may not persist across separate commands because each call may start a fresh MCP session/process.

That means this pattern can be unreliable:

```bash
mcporter call serena.activate_project project=/home/scripts/linux-scripts --output json
mcporter call serena.list_dir relative_path=. recursive=false --output json
```

The second call may fail with **No active project** if it runs in a new session.

### Best ways to work around that

#### Option 1: Use a persistent client/session
Best option if your MCP client supports session persistence.

#### Option 2: Prefer Serena from Claude Code/Codex integrations
These clients usually maintain session context better than isolated shell calls.

#### Option 3: Treat one-shot MCPorter calls as spot checks
Use MCPorter to:
- verify Serena is installed
- inspect schemas
- activate/test a project
- do occasional single-call operations

But avoid assuming long-lived project context between separate one-shot invocations.

### When to use Serena vs Context7

Use **Serena** when the question is about:
- your repository
- your symbols/functions/files
- your project structure
- your stored project memory

Use **Context7** when the question is about:
- external libraries/frameworks/products
- official docs
- APIs and platform behavior outside your repository

---

## Quick Verification Commands

### Verify both servers are visible

```bash
mcporter list
```

### Verify Context7 tools

```bash
mcporter list context7 --schema
```

### Verify Serena tools

```bash
mcporter list serena --schema
```

### Test Context7 with Kubernetes docs

```bash
mcporter call context7.resolve-library-id libraryName=kubernetes query='persistent volume claim migration' --output json
mcporter call context7.query-docs libraryId=/websites/kubernetes_io query='How do I migrate a PVC to another cluster?' --output json
```

### Test Serena with linux-scripts

```bash
mcporter call serena.activate_project project=/home/scripts/linux-scripts --output json
mcporter call serena.initial_instructions --output json
```

---

## Summary

- **Context7** = external documentation retrieval
- **Serena** = semantic repo exploration and project memory
- **MCPorter** = a useful shell entrypoint for both, especially for inspection, testing, and targeted calls
- For Serena, remember that **one-shot MCPorter calls may not preserve active project state across invocations**
