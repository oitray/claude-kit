# Salesforce CLI Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-11

## Auth

- **Method:** Browser-based OAuth (`sf org login web`)
- **Vault:** N/A — `sf` CLI manages its own token refresh
- **Secret name:** N/A
- **Env var:** N/A
- **Fetch creds:** N/A — authenticate via: `sf org login web --set-default --alias <your-email>`
- **MCP server:** N/A — use `sf` CLI directly
- **CLI binary:** `/opt/homebrew/bin/sf`
- **Default org:** `<your-email>` (Production)
- **API version:** 66.0
- **Re-auth:** `sf org login web --set-default --alias <your-email>`

## Common Operations

### Via API / CLI

#### Deploy & Validate

```bash
# Validate (dry run — no changes applied)
sf project deploy validate --source-path force-app --target-org <your-email> --test-level RunLocalTests

# Deploy
sf project deploy start --source-path force-app --target-org <your-email> --test-level RunLocalTests

# Destructive deploy (remove metadata)
sf project deploy start --manifest deploy-package.xml \
  --post-destructive-changes destructiveChangesPost.xml \
  --target-org <your-email>

# Check deploy status
sf project deploy report
```

#### Retrieve

```bash
sf project retrieve start --source-path force-app --target-org <your-email>
sf project retrieve start --metadata ApexClass:MyClass --target-org <your-email>
```

#### SOQL Queries

```bash
sf data query --query "SELECT Id, Name FROM Account LIMIT 5" --target-org <your-email>
sf data query --query "..." --target-org <your-email> --result-format csv
```

#### Describe Metadata

```bash
sf sobject describe --sobject Case --target-org <your-email>
sf org list metadata-types --target-org <your-email>
```

### Via MCP

N/A — Salesforce is accessed via `sf` CLI. No MCP server (do not use claude.ai/Zapier MCP for SF).

## Key SOQL Patterns

### Case number (users give partial numbers)
```sql
SELECT Id, CaseNumber, Subject FROM Case WHERE CaseNumber LIKE '%222448'
```

### Churn / cancelled accounts
```sql
SELECT Id, Name, Cancellation_Reason__c, Agreement_End_Date__c
FROM Account
WHERE Status__c = 'Cancelled'
  AND Agreement_End_Date__c >= 2026-01-01 AND Agreement_End_Date__c <= 2026-03-31
ORDER BY Agreement_End_Date__c
```

### MRR (Closed Won Opportunity Amount — highest per account)
```sql
SELECT Account.Name, Account.Agreement_End_Date__c, Amount, Name
FROM Opportunity
WHERE Account.Status__c = 'Cancelled' AND Amount != null AND Amount > 0
  AND StageName = 'Closed Won'
ORDER BY Account.Agreement_End_Date__c, Amount DESC
```

### Dynamic dashboards
```sql
SELECT Id, Title FROM Dashboard WHERE Type != 'SpecifiedUser'
```
Limits: Enterprise = 5, Performance/Unlimited = 10, Developer = 3.

### Account health fields
- `Partner_Engagement__c` — Red/Yellow/Green
- `Delinquency_Date__c`, `No_Support_Date__c`, `Renewal_Date__c`
- `Status__c = 'Cancelled'`, `Agreement_End_Date__c`

## <your-org>-Specific IDs

| Resource | ID / Value |
|----------|------------|
| Production org alias | `<your-email>` |
| API version | `66.0` |
| CLI path | `/opt/homebrew/bin/sf` |
| Repo | `<your-org>/automations` |
| Metadata directory | `salesforce/force-app/` |

## Gotchas

- **FLS after deploy:** `sf project deploy` does NOT grant Field-Level Security. After deploying custom fields, grant FLS via Apex `FieldPermissions` insert or deploy a profile XML alongside.
- **SOQL safety:** Use `WITH SECURITY_ENFORCED` in all Apex SOQL.
- **Test coverage:** Minimum 85%, bulk test with 200+ records.
- **Deploy timing:** Avoid major deploys 9 AM - 5 PM EST.
- **MRR is NOT on Account** — `AnnualRevenue` = company revenue, `Est_Revenue__c` = empty. Use Opportunity Amount.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `ERROR: The org <your-email> is expired or doesn't exist` | Re-auth: `sf org login web --set-default --alias <your-email>` |
| Deploy succeeds but new fields aren't visible | FLS not granted. Deploy profile XML alongside, or insert `FieldPermissions` via Apex |
| `INVALID_SESSION_ID` in SOQL queries | Session expired. Re-auth with `sf org login web` |
| Test coverage below 85% | Check per-class: `sf apex run test --code-coverage --result-format human -n MyTestClass` |
| `sf project deploy start` reports success but fields missing from UI | Field Level Security not granted — profile XML must be deployed separately, or use FieldPermissions sobject |

## Resolved Issues

> Log fixes here when an API/CLI/MCP call fails and you figure out why. Future sessions check this before re-investigating.

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
