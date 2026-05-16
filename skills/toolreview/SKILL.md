---
description: Evaluate an external tool/service for addition to OCC or CCA — assesses fit for both AI-assisted and non-AI <your-org> use cases, then orchestrates installation if approved
---

# /toolreview — Tool Evaluation & Onboarding

Evaluate an external tool or service for addition to the <your-org> stack. Input: $ARGUMENTS

**Spec:** `docs/superpowers/plans/2026-04-10-toolreview-command.md`

## Input

The user provides a URL. Parse the argument:
- If no URL provided → ask: "What tool do you want to evaluate? Provide a URL (GitHub repo, product page, blog post, etc.)"
- If URL provided → proceed to Phase 1

## Scraping Setup

Check if `firecrawl_scrape` is available as an MCP tool in this session:
- **If available:** Use `mcp__firecrawl__firecrawl_scrape` with `formats: ["markdown"]` and `onlyMainContent: true` for all URL scraping
- **If not available:** Use `WebFetch` for direct URLs, `WebSearch` for discovery queries

This check happens once at the start. Do not re-check per operation.

## Phase 1: Evaluate

### Step 1.1: Identify the Tool

Detect the URL type and extract the tool identity:

| URL Pattern | Action |
|-------------|--------|
| `github.com/{org}/{repo}` | Tool name = repo name. Scrape README. Check npm for `{repo}` and `{org}/{repo}`. |
| `*.com` / product site | Scrape the main page. Extract the product/service name from the title or H1. Then attempt to discover and scrape the pricing page (try `{domain}/pricing`, `{domain}/plans`) and docs page (try `{domain}/docs`, `{domain}/documentation`). Use `mcp__firecrawl__firecrawl_map` or link extraction to find these if standard paths fail. |
| Blog / article / Reddit | Scrape the article. Identify the tool being discussed. Pivot to the tool's primary site/repo for evaluation. |

If the URL is an article about a tool (not the tool itself), scrape it first, identify the tool, then scrape the tool's primary site. Tell the user: "This is an article about {Name}. Evaluating the tool itself at {primary URL}."

### Step 1.2: Research (run in parallel where possible)

Use the Agent tool to dispatch parallel research where tasks are independent:

1. **Scrape the input URL** — extract capabilities, pricing, auth model, license. Identify both AI-integration features (APIs, SDKs, MCP servers, webhooks for agent pipelines) AND non-AI features (CLI tools, dashboards, browser UIs, team collaboration, direct productivity gains).
2. **npm search** — run `npm search {name} mcp` and `npm view {name}-mcp version` to find MCP packages
3. **GitHub search** — search for `{name} mcp server` repos via `mcp__github__search_repositories` or `gh search repos`
4. **MCP directories** — web search for `site:mcp.so {name}`, `site:smithery.ai {name}`, `site:glama.ai {name}`
5. **CLI/API/SDK search** — check if the vendor offers a CLI tool (`npm search {name}-cli`, `brew search {name}`) or SDK (`npm search {name}`, `pip search {name}`)
6. **Official MCP check** — check the vendor's GitHub org for an MCP server repo
7. **Security check** — for npm MCP candidates: `npm audit --json` on the package, check license field, verify publisher identity
8. **Overlap check** — read `~/claude-config/catalog.json` (both `mcpServers` and `plugins` keys) AND `~/.claude.json` (installed MCP servers) AND `docs/runbooks/` (existing runbooks). Flag any matches or near-matches.

For each MCP candidate found, collect: package name, npm version, weekly downloads, GitHub stars, last commit date, license, auth model, tool count.

### Step 1.3: Score and Recommend

Rate each criterion on a 1-5 scale using filled/empty blocks:

| Criteria | Weight | What to assess |
|----------|--------|----------------|
| AI Use Value | High | How useful is this tool when integrated into AI-assisted workflows (Claude Code skills, MCP servers, agent pipelines, n8n AI nodes, <internal-bot>/<internal-bot>)? Score 1 if no meaningful AI integration path, 5 if it unlocks capabilities AI agents can't achieve without it. |
| Non-AI Use Value | High | How useful is this tool for direct human use outside AI workflows (CLI scripts, browser dashboards, manual API calls, team productivity)? Score 1 if only useful through AI, 5 if it's a standalone productivity win for <your-org> staff. |
| <your-org> Domain Fit | High | Does it serve VoIP, MSP, Salesforce, support, or sales workflows? Score 1 if generic with no clear <your-org> use case, 5 if directly serves a core <your-org> function. A tool can score high here even if only one of AI/Non-AI value is high. |
| Integration Options | High | Rank available paths by reliability: API > CLI > MCP. Score 1 if only an unreliable community MCP exists, 5 if vendor-maintained API + CLI + official MCP. |
| Cost | Medium | Score 5 if free/open-source, 4 if freemium with adequate free tier, 3 if paid but < $20/mo, 2 if $20-100/mo, 1 if > $100/mo or enterprise-only. |
| Overlap | Medium | Score 5 if no overlap with existing stack, 3 if partial overlap but adds unique capabilities, 1 if fully duplicates an installed tool. |
| Security & License | Medium | Score 5 for MIT/Apache with clean npm audit from a known publisher. Deduct for: AGPL (3), no license (2), audit warnings (2), unknown publisher (1). **Known developer modifier:** If the user confirms personal knowledge of the developer + explicit permission to use, restore up to 2 points deducted for unknown publisher / no license. Note this in the scorecard. |
| Maintenance | Low | Score 5 if commits within 30 days, 4 within 90 days, 3 within 6 months, 2 within 1 year, 1 if older. |

**Use-case classification:** Based on AI Use Value and Non-AI Use Value scores, classify the tool:
- **AI-primary:** AI Use >= 4, Non-AI Use <= 2 — value is almost entirely in AI agent workflows
- **Non-AI-primary:** Non-AI Use >= 4, AI Use <= 2 — value is in direct human use; AI integration is bonus
- **Dual-use:** Both AI Use >= 3 AND Non-AI Use >= 3 — meaningful value in both lanes
- **AI-enhanced:** Non-AI Use >= 3, AI Use 2-3 — useful standalone, AI integration adds moderate value

This classification drives the outcome type and recommendation card but does NOT gate approval — a tool that scores 5 on AI Use and 1 on Non-AI Use is still valid if the AI use case is compelling.

**Determine the outcome type:**
- **MCP Catalog Entry:** A maintained MCP server exists (score >= 3 on Integration Options with an MCP path) AND <your-org> Domain Fit >= 3 AND AI Use Value >= 3
- **Runbook Only:** Best integration path is CLI or API (no good MCP, or MCP is unreliable) AND <your-org> Domain Fit >= 3 AND (AI Use Value >= 3 OR Non-AI Use Value >= 3)
- **Follow-Up Build Issue:** <your-org> Domain Fit >= 4 AND AI Use Value >= 3 but no adequate integration exists yet (worth building later)
- **Methodology Import:** The tool's technique or pattern is worth adopting into existing <your-org> skills/workflows, but the package itself isn't worth installing (high overlap, wrong tracker integration, no license, etc.). Create a ClickUp task scoped to importing the specific methodology.
- **Non-AI Tool Only:** Non-AI Use Value >= 4 AND AI Use Value <= 2 AND <your-org> Domain Fit >= 3 — worth adopting for human use but no MCP/agent integration needed. Create a runbook focused on CLI/dashboard/manual workflows.
- **Skip:** <your-org> Domain Fit < 3, OR Overlap == 1, OR Cost is unjustified relative to use cases, OR both AI Use Value < 3 AND Non-AI Use Value < 3

### Step 1.4: Present Recommendation

Display this card to the user AND write it to `working/{tool-key}-review.md` (kebab-case tool name):

~~~
## Tool Review: {Name}

**Verdict:** {✅ Add / ⚠️ Maybe / ❌ Skip}
**Outcome:** {MCP Catalog Entry / Runbook Only / Follow-Up Build Issue / Non-AI Tool Only / Skip}
**Use-case class:** {AI-primary / Non-AI-primary / Dual-use / AI-enhanced}
**Target:** {OCC / CCA / Both} *(advisory — not a catalog field)*
**Why:** {1-2 sentence justification}

| Criteria | Score | Notes |
|----------|-------|-------|
| AI Use Value | {⬛⬛⬛⬛⬜} | {note} |
| Non-AI Use Value | {⬛⬛⬛⬜⬜} | {note} |
| <your-org> Domain Fit | {⬛⬛⬛⬛⬜} | {note} |
| Integration Options | {⬛⬛⬛⬛⬛} | {note} |
| Cost | {⬛⬛⬛⬜⬜} | {note} |
| Overlap | {⬛⬛⬛⬛⬛} | {note} |
| Security & License | {⬛⬛⬛⬛⬜} | {note} |
| Maintenance | {⬛⬛⬛⬜⬜} | {note} |

### AI Use Cases for <your-org>
{Bulleted list of specific ways this tool adds value inside AI agent workflows — Claude Code skills, MCP integrations, n8n AI nodes, <internal-bot>/<internal-bot> pipelines. Write "None identified" if AI Use Value <= 1.}

### Non-AI Use Cases for <your-org>
{Bulleted list of specific ways this tool adds value for direct human use — CLI productivity, browser dashboards, manual API calls, team workflows. Write "None identified" if Non-AI Use Value <= 1.}

**Integration options (ranked by reliability):**
1. {path}: {details} ⭐ recommended
2. {path}: {details}
3. {path}: {details}

**Cost:** {free/pricing details}
**Overlaps with:** {existing catalog entries, installed tools, or "none"}

Proceed? (yes / no / need more info)
~~~

The `working/{tool-key}-review.md` file is the durable artifact of this evaluation. Write the full card content as markdown (not fenced). This file persists regardless of the verdict — it documents both approvals and skips.

### GATE 1

- **"yes"** → proceed to Phase 2
- **"no"** → create a ClickUp task with outcome "Skip", document the reasoning, stop
- **"need more info"** → ask what specific aspect to research further, run additional research, update the card, re-present

## Phase 2: Plan

### Step 2.1: Create ClickUp Task

On Gate 1 approval, create a task using `mcp__clickup__clickup_create_task`:

- **list_id:** `<clickup-list-id>` (Automations & Engineering)
- **name:** `Tool Review: {Name}`
- **tags:** `["tool-review"]`
- **priority:** `normal`
- **markdown_description:** Include the full evaluation scorecard from Phase 1 (including use-case classification and both AI/Non-AI use case lists), the outcome type, and a checklist of implementation steps (populated based on outcome type).

For **Skip** outcomes: create the task, add the skip reasoning to the description, then close it immediately with `mcp__clickup__clickup_update_task` setting `status: "completed"`. Stop here — no Phase 3.

For all other outcomes: proceed to Step 2.2.

### Step 2.2: Present Implementation Plan

Present the plan specific to the outcome type. Always lead with your recommendation for each decision point.

#### If outcome = MCP Catalog Entry

Present this plan:

1. **Derive catalog key** — lowercase kebab-case from tool name (e.g., `firecrawl`). Confirm with user.
2. **Add catalog.json entry** — branch `feat/tool-{key}` on `~/claude-config`. Add to `mcpServers` section following existing entry patterns:
   - `name`, `description`, `recommended: false`, `category` (recommend based on tool type)
   - `authType` matching the tool's auth model (`"key"`, `"oauth"`, or omit for none)
   - `command: "bash"`, `args` with `fetch-secrets.sh` wrapper: `["-c", "eval \"$($HOME/.claude/scripts/fetch-secrets.sh {key})\"; exec npx -y {npm-package}"]` (note: `args` starts with `"-c"`, not `"bash"` — `command` already specifies `"bash"`)
   - `visibility` (ask user: `"public"`, `"private"`, or `"internal"`)
   - `requiredKeys`, `keyDescriptions`, `setupInstructions`, `promptExamples` (3 realistic <your-org> examples)
   - `roi` block
   - `keyVaults` mapping each key to vault type (`"user"` → `<credential-vault>`, `"bot"` → `<credential-vault>`, `"company"` → `<credential-vault>`)
3. **Create tool doc** — `~/claude-config/docs/tools/{key}.md` with capabilities, setup, affected roles, ROI
4. **Create runbook** — `docs/runbooks/{key}.md` in the automations repo using the template at `docs/runbooks/_template.md`. Cover all integration paths (MCP tools + API/CLI).
5. **Commit, push, open PR** — `gh pr create` on claude-config with title `feat: add {name} MCP server to catalog`
6. **Merge PR** — admin merge after user confirmation
7. **Pull latest** — `git pull` on local claude-config to sync
8. **Store secret** — run `! store-secret --vault {vault} --name {SECRET-NAME}` (one `--name` per key). The `!` prefix runs it in the user's terminal for secure input. Secret name normalization is handled automatically. Vault determined by `keyVaults` field. For multiple keys in the same vault, batch: `! store-secret --vault {vault} --name KEY1 --name KEY2`.
9. **Install** — direct user to run `~/claude-config/scripts/catalog.sh add {key}` in their terminal. Pause and wait for them to confirm.
10. **Verify** — check `claude mcp list` for the new server, confirm tools appear, run a test operation.

#### If outcome = Runbook Only

Present this plan:

1. **Create runbook** — `docs/runbooks/{key}.md` in the automations repo using `docs/runbooks/_template.md`. Cover: auth method, CLI/API commands, <your-org>-specific IDs, gotchas.
2. **Commit** — commit to automations repo on current branch
3. **Verify** — run a test CLI command or API call using the runbook instructions to confirm they work

#### If outcome = Non-AI Tool Only

Present this plan:

1. **Create runbook** — `docs/runbooks/{key}.md` in the automations repo using `docs/runbooks/_template.md`. Focus on CLI commands, dashboard URLs, manual API patterns, and team workflows. Omit MCP/agent integration sections.
2. **Store secret (if needed)** — run `! store-secret --vault {vault} --name {SECRET-NAME}` if the tool requires API credentials for CLI/script use.
3. **Commit** — commit to automations repo on current branch
4. **Verify** — run a test CLI command or API call using the runbook instructions to confirm they work

#### If outcome = Follow-Up Build Issue

Present this plan:

1. **Document research** — update the ClickUp task body with detailed API capabilities, potential MCP architecture, estimated build effort
2. **Tag for follow-up** — add `needs-build` tag to the ClickUp task
3. **Stop** — no further implementation. Tell user: "Tracked for future build in ClickUp."

### GATE 2

Present the plan and ask: "Proceed with this plan? (yes / no / adjust)"

- **"yes"** → proceed to Codex review
- **"no"** → ask what to change, revise the plan, re-present
- **"adjust"** → ask which specific steps to modify, update, re-present

### Step 2.3: Codex Review

After Gate 2 approval:

1. Write the approved plan to `docs/superpowers/plans/` in the automations repo as `YYYY-MM-DD-toolreview-{key}.md`. This is a spec requirement — the ClickUp task tracks progress, but the spec file is the durable record.
2. Run `codex:rescue` with this prompt:
   > Review the /toolreview implementation plan for {Name}. The plan is: {paste the plan steps}. Check for: missing steps, incorrect vault/path references, security concerns with the MCP package, and whether the plan matches the catalog.json entry patterns in ~/claude-config/catalog.json. Report findings.
3. Present Codex findings to the user.
4. Incorporate any adjustments into the plan.

### GATE 3

Present the final (post-Codex) plan and ask: "Final plan approved? (yes / no / adjust)"

- **"yes"** → proceed to Phase 3
- **"no"** → revise based on feedback, re-present
- **"adjust"** → modify specific steps, re-present

## Phase 3: Implement

Execute the approved plan step by step. After each step completes, update the ClickUp task checklist.

### Execution Rules

- Execute steps in order. Do not skip steps.
- After each step, update the ClickUp task with a comment noting completion (use `mcp__clickup__clickup_create_task_comment`).
- For the "Install" step (MCP Catalog Entry outcome): tell the user to run the command in their terminal. Do NOT attempt to run `catalog.sh add` or `setup.sh` from the agent — these require interactive input. Wait for user confirmation before proceeding.
- For the "Store secret" step: the user must provide the actual secret value. Ask them for it. Never guess or fabricate API keys.
- For the "Verify" step: check that the tool is functional, not just installed. Run an actual test operation (e.g., a simple scrape, a test query, a health check).

### Failure Handling

On failure at any step:

1. **Stop immediately** — do not proceed to the next step
2. **Notify the user** with:
   - Which step failed
   - The error message or unexpected output
   - Which steps completed successfully
   - Suggested fix or next action
3. **Update the ClickUp task** — add a comment with the failure details and remaining uncompleted steps
4. **Leave the task open** — do not close it

### Completion

When all steps succeed:

1. Update the ClickUp task description with a summary of all artifacts created:
   - Review file: `working/{tool-key}-review.md`
   - PR link (if applicable)
   - Runbook path
   - Tool doc path (if applicable)
   - Vault secret name (if applicable)
   - Verification result
2. Close the ClickUp task with `mcp__clickup__clickup_update_task` setting `status: "completed"`
3. Tell the user: "Tool review complete. {Name} is installed and verified. ClickUp task closed: {task_url}"

## Rules

- **Always lead with recommendations** when asking the user questions. Present your preferred option first with reasoning.
- **Never run `catalog.sh add` or `setup.sh` from the agent** — these require interactive terminal input. Always direct the user to run them.
- **Never fabricate API keys or secrets** — always ask the user to provide them.
- **Never commit directly to main on claude-config** — always use a feature branch + PR.
- **Secret naming convention:** Replace underscores with hyphens for Azure Key Vault (e.g., `FIRECRAWL_API_KEY` → `FIRECRAWL-API-KEY`).
- **Vault selection:** Determine from `keyVaults` field — `"user"` → `<credential-vault>`, `"bot"` → `<credential-vault>`, `"company"` → `<credential-vault>`.
- **Azure CLI isolation:** Always use `AZURE_CONFIG_DIR=~/.azure-admin` for vault operations — never bare `az` commands.
- **catalog.json is on claude-config repo** at `~/claude-config/catalog.json` — not the automations repo.
- **Runbooks are on the automations repo** at `docs/runbooks/` — use the template at `docs/runbooks/_template.md`.
- **Tool docs are on claude-config repo** at `~/claude-config/docs/tools/`.
- **If the tool already exists in the catalog** — show the existing entry and ask if the user wants to install it instead. Do not create a duplicate.
- **If a runbook already exists** — show it and ask if the user wants to update it rather than create a new one.
- **ClickUp list ID for all tasks:** `<clickup-list-id>` (Automations & Engineering).
