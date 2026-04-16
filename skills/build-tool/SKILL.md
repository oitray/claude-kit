---
description: Add a tool to the <your-org> catalog — discovers public MCPs, evaluates security and utility, then recommends before building
---

Add or install a tool/MCP server for the <your-org> team. Input: $ARGUMENTS

## Step 1: Check the Catalog

Read `catalog.json` in the claude-config repo root. Search both `plugins` and `mcpServers` keys for a match on the user's request (match by key, name, or description keywords).

**If found:**
1. Show the existing entry (name, description, category, required keys)
2. Ask: "This already exists in the catalog. Want me to walk you through installing it?"
3. If yes → instruct the user to open the **VSCode integrated terminal** (`` Ctrl+` ``) and run: `~/claude-config/scripts/catalog.sh add {server-id}`
4. Show the setup instructions from the catalog entry so they know what credentials to have ready
5. Stop here — do not create a new entry

> **Important:** Never attempt to run `setup.sh` or `catalog.sh add` from the agent Bash tool. These scripts require interactive terminal input that the agent cannot provide. Always direct the user to the VSCode integrated terminal.

**If NOT found:** proceed to Step 2.

## Step 2: Public MCP Discovery

Before collecting details or building anything, search for existing public MCP servers that already solve the need. **Never build what you can install.**

### 2a: Search

Run all of these in parallel:

1. **npm registry**: Search for `{name} mcp` and `@{name}` on npm (use `npm search` or web search)
2. **GitHub**: Search for `{name} mcp server` repositories
3. **MCP directories**: Check [mcp.so](https://mcp.so), [glama.ai/mcp/servers](https://glama.ai/mcp/servers), and [smithery.ai](https://smithery.ai) for listings
4. **Service docs**: Check if the service itself offers an official MCP server (e.g. ClickUp, Cloudflare, Stripe all have official MCPs)

### 2b: Evaluate Candidates

For each candidate found, assess:

| Criteria | Check |
|----------|-------|
| **Exists on npm** | `npm view {package} version` succeeds |
| **Actively maintained** | Last commit within 6 months |
| **Repo accessible** | GitHub repo exists and is public (not deleted/private) |
| **Security** | No known vulnerabilities (`npm audit`), no suspicious dependencies, published by identifiable author/org |
| **License** | Open source (MIT, Apache, ISC) preferred. Flag paid/proprietary. |
| **Auth model** | API key or OAuth — matches what the service supports |
| **Tool coverage** | How much of the service API does it expose? List key capabilities. |
| **Stars/adoption** | GitHub stars, npm weekly downloads as social proof |

### 2c: Present Findings

Show the user a comparison table of all viable options ranked by: maintenance status > security > tool coverage > cost.

**If viable options exist:**
- Recommend the best option with reasoning
- Ask: "Want me to add {package} to the catalog, or do you need something it doesn't cover?"
- If yes → proceed to Step 3 with the selected package as source
- If no → ask what's missing and whether a custom build is justified

**If no viable options exist:**
- State clearly: "No public MCP server found for {name}. Options: (1) build a custom one if the service has an API, or (2) skip if the ROI doesn't justify it."
- Check whether the service even has a public API. If no API exists → stop and tell the user.
- If API exists → proceed to Step 3 with `source type: custom`

**If only paid options exist:**
- Present the cost and what you get
- Ask: "Is the cost justified, or should we look at building a free alternative?"

## Step 3: Collect Details

Gather these fields from the user (do not assume — ask explicitly):

| Field | Description | Example |
|-------|------------|---------|
| **name** | Display name | "ClickUp" |
| **description** | One-line summary | "Project management — tasks, spaces, lists" |
| **auth type** | API key, OAuth, none | "OAuth (Client ID + Secret)" |
| **time saved** | Estimate per week per user | "15 min/week" |
| **affected role** | Who benefits | "Operations" or "All" |
| **visibility** | `public` (shared) or `private` (personal) | "public" |
| **source type** | `npm` (published package) or `custom` (local build) | "npm" |
| **npm package or command** | The MCP server package (npm only) | "@hauptsache.net/clickup-mcp" |

Wait for explicit approval before proceeding.

## Step 3b: Custom Build Gate

**If source type is `custom`:** The MCP server must be built and verified before it can be added to the catalog. Do NOT proceed to Step 5 until:

1. The server repo exists (e.g. `<your-org>/{name}-mcp-server`)
2. The server builds successfully (`npm run build`)
3. The built artifact exists at the expected path (validate with `ls`)
4. A basic connectivity test passes (e.g. health check endpoint or startup without error)

If the server does not exist yet:

- Create a GitHub issue for the build (if one doesn't exist already)
- Document the planned catalog entry details (name, keys, setup instructions, ROI) as a comment on the issue so nothing is lost
- Tell the user: "The catalog entry will be added after the server is built and tested. Tracked in [issue link]."
- **STOP HERE** — do not create a branch, catalog entry, or docs

**If source type is `npm`:** proceed directly to Step 4 (the package already exists).

## Step 4: Build

1. Create branch: `feat/tool-{name-lowercase}`
2. Add entry to `catalog.json` under `mcpServers` following the existing entry pattern:
   - `name`, `description`, `recommended: false`, `category: "optional"`
   - `command: "bash"` with standard env-sourcing args wrapper
   - `requiredKeys`, `keyDescriptions`, `setupInstructions`
   - `promptExamples` (3 realistic examples)
   - `visibility`, `roi` block with `role`, `hrs_saved_per_week`, `user_count`
3. Create `docs/tools/{name}.md` with:
   - What it does
   - Setup instructions (reference `setup.sh` for key collection — never tell users to edit .env)
   - Time Saved section with ROI calculation
4. Update the main README ROI rollup if one exists

## Step 5: Open PR

- PR title: `feat: add {name} MCP server to catalog`
- Label: `minor`
- Body: summary, setup instructions, ROI estimate
- Do NOT merge — user approves and merges

## Rules

- Never commit directly to main
- Never tell users to manually edit `.env` — all key ingestion goes through `~/claude-config/scripts/setup.sh`
- Never run `setup.sh` or `catalog.sh add` from the agent Bash tool — always direct users to the VSCode integrated terminal
- Never assume visibility — always ask
- Follow existing `catalog.json` entry structure exactly

## MCP Path Rules (MANDATORY)

When registering a local MCP server (not an npm package), enforce these:

1. **Always use absolute paths** with `$HOME` — never relative paths like `../`. Relative paths break when the user's CWD changes.
2. **Standard base for local MCP builds:** `$HOME/Library/CloudStorage/OneDrive-<your-org>/Documents/Projects/`
3. **Validate the path exists** before registering — run `ls` on the target `build/index.js` and abort if missing.
4. **Standard command wrapper:** All local MCP servers must use the bash env-sourcing pattern:

   ```bash
   bash -c 'set -a; [ -f ~/.claude/.env ] && source ~/.claude/.env; [ -f ~/.claude/.env.local ] && source ~/.claude/.env.local; set +a; exec node "$HOME/Library/CloudStorage/OneDrive-<your-org>/Documents/Projects/{server-name}/build/index.js"'
   ```

5. **After registering**, run `claude mcp get {name}` to confirm `Status: ✓ Connected` before reporting success.
