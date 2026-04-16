---
description: Browse, filter, install, and uninstall OCC catalog tools from the session
---

# /catalog — In-Session Tool Management

Manage OCC catalog tools without leaving the session. Supports browsing, filtering, installing, and uninstalling MCP servers and plugins.

## Arguments

The user may pass arguments after `/catalog`. Parse them as follows:

| Argument | Effect |
|----------|--------|
| *(none)* | List all tools with install status |
| `install <name>` | Install the named tool |
| `uninstall <name>` | Uninstall the named tool |
| `info <name>` | Show detailed info for a tool |
| `--category <cat>` | Filter by category (core, optional, workflow, quality, tools, integrations, development, git) |
| `--installed` | Show only installed tools |
| `--available` | Show only tools not yet installed |
| `--recommended` | Show only recommended tools |

Arguments can be combined: `/catalog --category core --installed`

## Step 1: Load Catalog

Read `~/claude-config/catalog.json`. Extract all entries from `mcpServers` and `plugins`.

## Step 2: Check Install Status

**MCP servers:** Read `~/.claude.json`. For each `mcpServers` key in `catalog.json`, check if a matching key exists under `mcpServers` in `~/.claude.json`. If found → installed. If not → available.

**Plugins:** Read `~/.claude/settings.local.json`. For each key in `plugins` from `catalog.json`, check if a matching entry exists under `plugins` in `settings.local.json`. If found → installed. If not → available.

## Step 3: Check API Keys (for MCP servers)

Read `~/.claude/.env` and `~/.claude/.env.local` (if they exist). For each MCP server, check if all `requiredKeys` have corresponding non-empty entries in the env files.

- All keys present → keys OK
- Some missing → keys missing (list which ones)
- No required keys → no keys needed

## Step 4: Handle Action

### List (default)

Apply any filters from arguments. Display a table sorted by category, then name:

```
## OCC Catalog

| Status | Type | Name | Category | Keys | Description |
|--------|------|------|----------|------|-------------|
| ✅     | MCP  | Salesforce DX | core | OK | Salesforce org management, metadata, data queries |
| ⬜     | MCP  | Cloudflare | optional | N/A | Full Cloudflare API — DNS, Workers, WARP, Registrar |
| ✅     | Plugin | Superpowers | workflow | — | Brainstorming, TDD, debugging, code review |

✅ = installed  ⬜ = available  ⚠️ = installed but missing keys
{X} installed, {Y} available, {Z} total

Tip: /catalog info <name> for details · /catalog install <name> to add
```

### Info

Show full details for the named tool:

```
## {name}

| Field | Value |
|-------|-------|
| **Type** | MCP Server / Plugin |
| **Status** | Installed / Available |
| **Category** | {category} |
| **Recommended** | Yes / No |
| **Visibility** | {visibility} |
| **Roles** | {roles or "all"} |

### Setup Instructions
{setupInstructions as numbered list}

### Required Keys
{requiredKeys with keyDescriptions — flag any missing from .env}

### Prompt Examples
{promptExamples as bulleted list}

### ROI
{roi.hrs_saved_per_week} hrs/week × {roi.user_count} users = {calculated} hrs/year
```

### Install

1. Look up the tool by key name in `catalog.json`. If not found, suggest close matches and stop.

2. Check if already installed. If so, say "Already installed" and stop.

3. **For MCP servers:**
   - Read `~/.claude.json` (create `{"mcpServers": {}}` structure if it doesn't exist)
   - Build the MCP entry from the catalog: `command`, `args`, and `env` fields
   - If the catalog entry has an `env` block, include it
   - Write the updated JSON back to `~/.claude.json`
   - Check `~/.claude/.env` for required keys. If any are missing, warn:
     ```
     ⚠️ Missing keys: {list}
     Add them to ~/.claude/.env before using this tool.
     Setup instructions:
     {setupInstructions}
     ```

4. **For plugins:**
   - Read `~/.claude/settings.local.json`
   - Add the plugin entry under `plugins` using the catalog key as the identifier
   - Write the updated JSON back

5. After writing, display:
   ```
   ✅ {name} installed.
   ⚠️ Restart Claude Code to activate.
   ```

### Uninstall

1. Look up the tool. If not found, suggest close matches and stop.

2. Check if installed. If not, say "Not currently installed" and stop.

3. **For MCP servers:**
   - Read `~/.claude.json`
   - Remove the matching key from `mcpServers`
   - Write the updated JSON back

4. **For plugins:**
   - Read `~/.claude/settings.local.json`
   - Remove the matching entry from `plugins`
   - Write the updated JSON back

5. After writing, display:
   ```
   🗑️ {name} uninstalled.
   ⚠️ Restart Claude Code to apply.
   ```

## Important Rules

- NEVER modify `catalog.json` — it's the source of truth, managed via PRs
- ONLY modify `~/.claude.json` (MCP servers) and `~/.claude/settings.local.json` (plugins)
- Always pretty-print JSON with 2-space indentation when writing config files
- Preserve all existing entries in config files — only add/remove the target tool
- The `env` block from catalog entries must be included in the MCP server config when installing
- For MCP servers with the `bash -c` command pattern that sources env files, preserve the exact `args` array from the catalog
