# TalentLMS (<your-org> Learning Academy) Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-11

## Auth

- **Method:** HTTP Basic Auth — API key as username, EMPTY password
- **Vault:** N/A — credentials in n8n only
- **Secret name:** N/A
- **Env var:** N/A
- **Fetch creds:** N/A — managed in n8n credential store only
- **MCP server:** N/A
- **n8n credential:** `TalentLMS` (type `httpBasicAuth`, ID `tBNGML4lbREzW9tC`)
- **Base URL:** `https://<your-org-subdomain>/api/v1`

## Common Operations

### Via API / CLI

```bash
# List all users
curl -s https://<your-org-subdomain>/api/v1/users \
  -u "$TALENTLMS_API_KEY:"
```

```bash
# Get a specific user by ID
curl -s https://<your-org-subdomain>/api/v1/users/id:123 \
  -u "$TALENTLMS_API_KEY:"
```

```bash
# Get user by email
curl -s "https://<your-org-subdomain>/api/v1/users/email:user@example.com" \
  -u "$TALENTLMS_API_KEY:"
```

```bash
# List all courses
curl -s https://<your-org-subdomain>/api/v1/courses \
  -u "$TALENTLMS_API_KEY:"
```

```bash
# Get a specific course by ID
curl -s https://<your-org-subdomain>/api/v1/courses/id:456 \
  -u "$TALENTLMS_API_KEY:"
```

```bash
# Get course completions (users who completed a course)
# Returns user list with completion_status and completion_date
curl -s https://<your-org-subdomain>/api/v1/courses/id:456 \
  -u "$TALENTLMS_API_KEY:" | jq '.users[] | select(.completion_status == "completed")'
```

```bash
# Get user's enrolled courses and status
curl -s https://<your-org-subdomain>/api/v1/users/id:123 \
  -u "$TALENTLMS_API_KEY:" | jq '.courses'
```

```bash
# List all categories
curl -s https://<your-org-subdomain>/api/v1/categories \
  -u "$TALENTLMS_API_KEY:"
```

```bash
# Get site info (verify credentials work)
curl -s https://<your-org-subdomain>/api/v1/siteinfo \
  -u "$TALENTLMS_API_KEY:"
```

### Via MCP

N/A — no TalentLMS MCP server configured. All calls go through n8n HTTP Request nodes.

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| Base URL | `https://<your-org-subdomain>/api/v1` |
| Portal URL | `https://<your-org-subdomain>` |
| n8n credential name | `TalentLMS` |
| n8n credential ID | `tBNGML4lbREzW9tC` |
| n8n credential type | `httpBasicAuth` (generic) |

## Active Code Paths

| Location | Usage |
|----------|-------|
| `<internal-workflow>.json` | "Get All TalentLMS Users" — fetches user list to build email-to-name map |
| `<internal-workflow>.json` | "Get Course Completions" — fetches per-course completion data to sync with Salesforce |

## WLP Training Sync Workflow

The `wlp-training-completion-sync` workflow:

1. Fetches all TalentLMS users → builds email-to-name map
2. Iterates over mapped WLP courses → fetches completions per course
3. Matches completed users to Salesforce Contacts by email
4. Updates Account checkbox fields for each completed course
5. Closes the associated Salesforce training task
6. If no Contact match found → sends Postmark email alert to `<service-email>`

## Gotchas

- **Basic Auth with empty password.** The API key is the username and the password is literally empty. In curl: `-u "API_KEY:"` (note the trailing colon). In n8n, the httpBasicAuth credential stores the key as username with a blank password field.
- **Rate limits apply.** TalentLMS enforces rate limits (typically documented as ~200 requests/hour on standard plans). The n8n workflow fetches all users and all course completions on each run — monitor for 429 responses if course count grows.
- **User IDs are numeric.** Endpoints use `id:123` format (colon-separated), not query params.
- **Email lookups are exact match.** `users/email:user@example.com` is case-insensitive but must be an exact email.
- **Course user data is nested.** When you GET a course, user completions are in `.users[]` with `completion_status` and `completed_on` fields, not a separate endpoint.
- **No webhook support.** TalentLMS does not push completion events. The n8n workflow polls on a schedule (Schedule Trigger node).
- **Pagination:** The `/users` endpoint returns all users by default (no pagination required unless you have 10,000+ users). <your-org>'s user count is well under this threshold.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| 401 Unauthorized from curl | Check format: `-u "API_KEY:"` (trailing colon is required — password is empty) |
| n8n credential fails | httpBasicAuth credential: API key in username field, password field BLANK |
| 429 Rate limit | Typically ~200 req/hour on standard plans. Batch where possible |
| `users/id:123` returns 404 | Use exact format `id:NUMERIC` (colon, not slash). Email lookup: `users/email:user@example.com` |
| Missing course completions | Course user data is nested in `.users[]` with `completion_status`, not a separate endpoint |
| No webhook events | TalentLMS has no webhook support — workflow must poll on schedule |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
