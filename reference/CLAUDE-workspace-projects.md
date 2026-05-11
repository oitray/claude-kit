# CLAUDE.md — <your-org> Projects Workspace

Multi-project workspace: `automations`, `CloudieMcCloudieBot`, `<voip-mcp>-mcp-server`, `<knowledge-base>-mcp`, `apollo-io-mcp-server`, `calendly-mcp-server`, `clickup-mcp-server`, `wordpress-mcp`, `nsapiv2-mcp`, `claude-code-team-commander`.

## Cross-Project Standards

### Release Notes
- Max 2 paragraphs: technical fix/feature + business impact
- Include date/timestamp, quantify time savings, write for staff audience

### MCP Server Pattern
All MCP servers follow:
- TypeScript + MCP SDK, ES2022/Node16, build to `build/`
- Env vars via Azure Key Vault (`<credential-vault>`) + `fetch-secrets.sh` — no `.env` files
- JSON schema validation on tool inputs, rate limiting, HTTPS-only

### Security
- All secrets in Azure Key Vault — requires `az login`
- Validate inputs at boundaries, escape arguments, minimal permissions
- No secrets in code or config

## AI Agents & Routing

| Agent | Domain | Trigger |
|-------|--------|---------|
| Flo Rivers | Salesforce automation/flows | GSD Record Type |
| Holly Helpdesk | Technical support | Support Request RT |
| Paige Turner | Documentation | Doc tasks |
| Stan Dardson | Standards/compliance | Quality/SOP tasks |
| Stella Fullstack | Dev/APIs/MCP | Programming tasks |

### Salesforce CLI
- Installed: `/usr/local/bin/sf`, org: `<your-email>` (Production)
- All agents can query SF via CLI
