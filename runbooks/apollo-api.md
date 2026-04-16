# Apollo API Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-11

## Auth

- **Method:** API key (stored in Salesforce Custom Metadata, accessed via Apex)
- **Vault:** N/A — key stored in `Apollo_Config__mdt.API_Key__c` (Salesforce)
- **Secret name:** N/A
- **Env var:** N/A
- **Fetch creds:** N/A — accessed via Apex: `Apollo_Config__mdt.getInstance('Default').API_Key__c`
- **MCP server:** N/A — called exclusively from Salesforce Apex
- **Endpoint:** Stored in `Apollo_Config__mdt.Endpoint_URL__c`
- **Apex class:** `ApolloEnrichmentService.cls`
- **Header:** `x-api-key: <API_Key__c>`

Apollo is called exclusively from Salesforce Apex — no direct CLI/MCP usage.

## Common Operations

### Via API / CLI

Apollo is invoked from Salesforce Apex, not directly via CLI. The Apex entry point is `ApolloEnrichmentService.enrich(email, firstName, lastName, company)`.

```bash
# Direct API call (for testing/debugging only — production calls go through Apex)
curl -X POST "https://api.apollo.io/api/v1/people/match" \
  -H "Content-Type: application/json" \
  -H "x-api-key: <API_Key>" \
  -d '{"email": "test@example.com", "first_name": "John", "last_name": "Doe", "organization_name": "Acme"}'
```

### Via MCP

N/A — Apollo has no MCP server. All enrichment flows through Salesforce Apex (`ApolloEnrichmentService`).

## Person Enrichment

**Apex entry point:** `ApolloEnrichmentService.enrich(email, firstName, lastName, company)`

**Request:**
```json
POST <Endpoint_URL__c>
Headers: Content-Type: application/json, x-api-key: <API_Key__c>
Body: { "email": "...", "first_name": "...", "last_name": "...", "organization_name": "..." }
```

**Response fields used:**
- `person.title` → Lead title
- `person.linkedin_url` → Lead LinkedIn
- `person.organization.name` → org name (confidence-checked)
- `person.organization.estimated_num_employees` → employee count
- `person.organization.annual_revenue` → revenue
- `person.organization.industry` → industry
- `person.organization.founded_year` → founded year
- `person.organization.website_url` → website
- `person.organization.current_technologies[].name` → tech stack

## Org Confidence Matching

Returned org is accepted only if Jaccard similarity >= 0.70 between requested and returned company names. Company suffixes (Inc, LLC, Ltd, etc.) are stripped before comparison.

If confidence < 0.70, only person-level fields (title, LinkedIn) are used. Org fields are discarded.

## VoIP Provider Detection

Tech stack is scanned for known VoIP providers:
RingCentral, 8x8, Vonage, Nextiva, Dialpad, GoTo Connect, Zoom Phone, Microsoft Teams Phone, Cisco Webex Calling, Ooma, Grasshopper, Bandwidth, Twilio, Five9, Genesys, NICE, Mitel, Avaya, NetSapiens, Intermedia, Broadvoice, Lumen, Windstream, Comcast Business VoiceEdge, Spectrum Business

Detected provider is stored in `Lead.Current_VoIP_Offering__c`.

## Pipeline

1. Lead created/updated → `LeadEnrichmentQueueable` fires
2. Queueable calls `ApolloEnrichmentService.enrich()`
3. Results mapped back to Lead fields
4. `LeadEnrichmentController` exposes LWC interface for manual enrichment

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| Custom Metadata Type | `Apollo_Config__mdt` (instance: `Default`) |
| Endpoint field | `Apollo_Config__mdt.Endpoint_URL__c` |
| API key field | `Apollo_Config__mdt.API_Key__c` |
| Apex service class | `ApolloEnrichmentService.cls` |
| Queueable class | `LeadEnrichmentQueueable.cls` |
| LWC controller | `LeadEnrichmentController.cls` |
| VoIP provider field | `Lead.Current_VoIP_Offering__c` |

## Gotchas

- **Timeout:** 15 seconds (`req.setTimeout(15000)`)
- **Tech stack field:** Truncated to 5000 chars if longer
- **No direct API key access** — stored in Custom Metadata, not env vars or Key Vault

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Enrichment returns no org data despite valid email | Jaccard similarity < 0.70 between requested and returned company names. Only person fields used. Check threshold in ApolloEnrichmentService |
| Callout timeout | Default is 15s (`req.setTimeout(15000)`). Increase in Apex if Apollo is slow |
| Tech stack field truncated | Field is capped at 5000 chars by design |
| 401 from Apollo API | Check `Apollo_Config__mdt.API_Key__c` value in Salesforce Setup > Custom Metadata Types |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
