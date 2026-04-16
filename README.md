# claude-kit

> These are the skills, personas, and runbooks I use daily in my AI-assisted work. Comments, suggestions, and PRs are always welcome.

A curated collection of reusable building blocks for Claude Code — battle-tested in production across Salesforce automation, MCP server development, VoIP platform integrations, and documentation workflows.

## What's Inside

| Directory | Contents |
|-----------|----------|
| `skills/` | Task-specific skill files that give Claude domain expertise |
| `personas/` | Named personas with distinct specializations and communication styles |
| `runbooks/` | API/CLI quick-reference docs for common services |

## Using These

**Skills** — Copy a `SKILL.md` into `~/.claude/skills/<name>/SKILL.md`. Claude will load it when relevant to your task.

**Personas** — Copy a persona `.md` into `~/.claude/personas/`. Reference it from a command or system prompt to adopt that persona's expertise and style.

**Runbooks** — Copy into your project's `docs/runbooks/` directory. Claude will consult them before making external API calls.

## Customizing

These files use placeholder tokens you should replace with your own values:

| Placeholder | Replace With |
|------------|--------------|
| `<your-email>` | Your email address |
| `<your-username>` | Your GitHub username |
| `<your-org>` | Your organization name |
| `<your-name>` | Your name |
| `<credential-vault>` | Your secret store (Azure KV, AWS SM, 1Password, etc.) |
| `<clickup-list-id>` | Your ClickUp list ID |
| `<credential-id>` | Your credential identifiers |

## License

Apache 2.0 — free to use, attribution required on modifications. See [LICENSE](LICENSE).

## Contributing

Found something useful? Something broken? Open an issue or PR. This repo is a living toolkit — it evolves as my workflows do.
