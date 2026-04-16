# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this repository — especially leaked credentials, PII, or internal references that should have been sanitized — please report it privately:

1. **GitHub Security Advisories** (preferred): Use the "Report a vulnerability" button on this repository's Security tab
2. **Email**: Contact the repository owner directly

## Response Time

- Acknowledgement within 48 hours
- Fix deployed within 7 days for credential leaks
- Public disclosure after fix is confirmed

## Scope

This repository is a sanitized mirror of internal tooling. Security concerns include:
- Leaked credentials, API keys, or tokens
- Internal URLs, hostnames, or infrastructure details
- Personal information (names, emails, IDs) that should have been redacted
- Internal product names or references that bypass the sanitizer
