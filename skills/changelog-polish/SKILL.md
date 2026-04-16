---
description: Rewrite CHANGELOG.md entries using the <your-org> voice persona
disable-model-invocation: true
---
Fetch the voice persona from the private GitHub repo and apply it to rewrite CHANGELOG.md entries.

## Steps

1. Read `CHANGELOG.md` from the repo root
2. Fetch voice rules from `<your-username>/dotclaude` via the GitHub MCP tool:
   - Use `mcp__github__get_file_contents` with owner=`<your-username>`, repo=`dotclaude`, path=`personas/<author>-voice.md`
   - Decode the base64 `content` field to get the raw text
3. Identify all entries added since the last release to `main` (entries above the oldest `## [version]` that hasn't been polished yet)
4. For each entry's bullet point(s), rewrite the description in <your-name>'s voice:
   - Keep the version header, date, category (Added/Changed/Fixed/Removed), PR link, and diff link exactly as-is
   - Only rewrite the descriptive text of each bullet
   - Keep it to one line per bullet — short, direct, no filler
   - Strip any conventional commit prefix cruft that survived
5. Show a diff of before/after for approval before saving
6. If approved, write the updated CHANGELOG.md

## Rules

- Never change version numbers, dates, links, or category headers
- Never remove or reorder entries
- Never add entries that don't exist
- The voice file is personal — never reference it in commits or PR descriptions
