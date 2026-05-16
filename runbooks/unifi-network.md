# UniFi Network Runbook

> **Owner:** <your-name> | **Last verified:** 2026-05-13 (tested against Network 10.2.105 on UCG Ultra)

Home UniFi setup: gateway/console + 2 switches + 1 AP. Reachable from primary SSID <VOIP-BRAND> and fallback SSID OITVOIP2 (AT&T, UniFi WAN). All interaction is local-only — UniFi Cloud/UID is NOT used.

## Auth

- **Method:** Local API key (per-admin), sent as `X-API-KEY` header
- **Vault:** `<credential-vault>`
- **Secret name:** `UNIFI-LOCAL-API-KEY`
- **Env var:** `$UNIFI_LOCAL_API_KEY`
- **Fetch creds:** `eval "$($HOME/.claude/scripts/fetch-secrets.sh unifi)"`
- **MCP server:** N/A (shell scripts at `scripts/unifi/`)
- **Provisioning:** In the UniFi **Network** app → **Settings** → **Control Plane** → **Integrations** → **Create API Key** (console-wide, not per-admin). Save with `store-secret --vault user --name UNIFI-LOCAL-API-KEY`.

### Local config

Copy `scripts/unifi/config.sh.example` → `scripts/unifi/config.sh` (gitignored) and set:

| Var | Value |
|-----|-------|
| `UNIFI_HOST` | Gateway LAN IP or hostname (e.g. `192.168.1.1`) |
| `UNIFI_TLS_SPKI_SHA256` | Base64 SPKI SHA-256 of the server cert (what `curl --pinnedpubkey` wants). Combined with `--insecure` to skip chain validation of the self-signed cert while still pinning identity. |
| `UNIFI_ALLOW_INSECURE` | `1` to allow `--insecure` without a pin (NOT recommended); default `0` |
| `UNIFI_SITE` | Site `internalReference` for legacy paths (usually `default`). `sites.sh` prints both the v1 UUID `id` and `internalReference`. |
| `UNIFI_TIMEOUT` | Per-request seconds (default 15) |

**Capture SPKI once (what `--pinnedpubkey` expects):**

```bash
echo | openssl s_client -connect "$UNIFI_HOST:443" -servername "$UNIFI_HOST" 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | openssl enc -base64
```

> The raw cert fingerprint (`x509 -fingerprint -sha256`) is **not** compatible with `--pinnedpubkey` — that flag hashes the `SubjectPublicKeyInfo`, not the whole cert.

## Base URLs

Two APIs are in play on the same controller, using the **same** integration key:

| URL prefix | Purpose | Shape |
|------------|---------|-------|
| `/proxy/network/integration/v1` | Official Integrations API (sites, devices, clients) | `{offset,limit,count,totalCount,data:[...]}` |
| `/proxy/network/api/s/{site}` | Legacy app API (health, alarms, stats) | `{meta:{rc},data:[...]}` |

`unifi-base-url.sh` probes v1 first and is what most read helpers use. Legacy-only helpers (`health.sh`, `alarms.sh`, `events.sh`) set `UNIFI_BASE_URL` directly before calling `unifi-curl.sh`.

### v1 endpoints confirmed on Network 10.2.105

| Path | Works | Notes |
|------|-------|-------|
| `GET /info` | ✓ | Returns `applicationVersion` |
| `GET /sites` | ✓ | `id` (UUID) + `internalReference` (e.g. `default`) |
| `GET /sites/{id}/devices` | ✓ | APs, switches, gateway |
| `GET /sites/{id}/clients` | ✓ | Wired + wireless |
| `GET /sites/{id}` | ✗ 404 | Use legacy `/stat/health` instead |
| `GET /sites/{id}/events` | ✗ 404 | Not exposed to integration key |
| `GET /sites/{id}/alarms` | ✗ 404 | Use legacy `/list/alarm` instead |

## Common Operations

### Read (via scripts/unifi/)

| Script | Endpoint | Purpose |
|--------|----------|---------|
| `sites.sh` | v1 `GET /sites` | Discover site IDs + `internalReference` |
| `devices.sh [SITE_ID]` | v1 `GET /sites/{id}/devices` | List gateway/switches/APs |
| `clients.sh [SITE_ID]` | v1 `GET /sites/{id}/clients` | Active wired + wireless clients |
| `health.sh [SITE]` | legacy `GET /stat/health` | Per-subsystem status (wlan/wan/www/lan/vpn) |
| `alarms.sh [SITE]` | legacy `GET /list/alarm` | Active alarms |
| `events.sh [SITE]` | legacy `GET /stat/event` | **404 on 10.2.x** — stub kept for forward compat |
| `backup.sh [path]` | (multiple) | Snapshot sites+devices+clients+health → `.baseline.json` |

All wrappers call `unifi-curl.sh`, which pins TLS, injects `X-API-KEY`, retries 5xx with exp backoff (1s/2s/4s, max 3 attempts), and treats 400/401/403/404/409/422 as non-retryable.

### Write (via apply.sh gate)

Every mutation goes through `apply.sh`. Dry-run by default; execution requires `--apply --confirm <action>`. A baseline snapshot is captured before each apply, and the call is recorded to `.last-apply.json`.

| Action | Args | Endpoint |
|--------|------|----------|
| `wlan.toggle` | `<wlanId> <true|false>` | `PUT /sites/{id}/wlans/{wlanId}` |
| `client.block` | `<macOrId>` | `POST /sites/{id}/clients/{id}/block` |
| `client.unblock` | `<macOrId>` | `POST /sites/{id}/clients/{id}/unblock` |
| `client.set-fixed-ip` | `<mac> <ip>` | legacy `GET /rest/user` (resolve `_id`+`network_id`) → `PUT /rest/user/{_id}` `{use_fixedip:true, fixed_ip, network_id}` (**empirical** 2026-05-13: arcade `b0:6b:11:11:20:5a` → `192.168.0.171`, `rc:ok`) |
| `device.restart` | `<deviceId>` | `POST /sites/{id}/devices/{id}/restart` |
| `speedtest.run` | — | `POST /sites/{id}/speedtest` |

```bash
# dry-run
scripts/unifi/apply.sh speedtest.run

# execute
scripts/unifi/apply.sh speedtest.run --apply --confirm speedtest.run

# DHCP reservation by MAC (resolves _id + network_id from legacy /rest/user)
scripts/unifi/apply.sh client.set-fixed-ip b0:6b:11:11:20:5a 192.168.0.171
scripts/unifi/apply.sh client.set-fixed-ip b0:6b:11:11:20:5a 192.168.0.171 \
  --apply --confirm client.set-fixed-ip
```

`speedtest.sh` is a thin shortcut over `apply.sh speedtest.run`.

### DHCP reservation gotchas

- `client.set-fixed-ip` requires the client to have a `network_id` in `/rest/user` — i.e. it has at minimum been seen on a known DHCP network. Cold-MAC adds (a device that has never associated) error with `resolve: client <mac> has no network_id`.
- The IP must be outside the network's DHCP pool **or** the lease must already belong to this client. UniFi accepts in-pool reservations only if the lease is free or already held by this MAC.
- Re-PUT of the same `(mac, ip)` is idempotent (server state unchanged); observed API response for repeated same-state PUT is `rc:ok` with `data:[]`.

## Remote access (OITVOIP2 fallback)

The UniFi gateway is hardwired to the AT&T router. When on OITVOIP2 (AT&T LAN), the UniFi WAN IP must be reachable and the UniFi console must allow management on WAN from the AT&T subnet. No VPN is used. Fingerprint pin is the same regardless of network path; `UNIFI_HOST` may need to change to the WAN-side address when on OITVOIP2.

## Gotchas

- **SPKI pin, not cert fingerprint.** Wrappers use `--pinnedpubkey` which hashes the SubjectPublicKeyInfo. The raw `x509 -fingerprint` hex is a different value and will fail with `curl: (90) SSL: public key does not match pinned public key`.
- **`--pinnedpubkey` is combined with `--insecure`.** UniFi's self-signed cert fails chain validation, so chain is skipped; identity is enforced by the SPKI pin. This is stronger than `--insecure` alone.
- **v1 integration API is narrow.** Sites/devices/clients only. Events and alarms (and per-site health) require the legacy `/proxy/network/api/s/{site}/` path, accessed with the same key.
- **Events endpoint 404s on 10.2.x.** Neither v1 nor legacy `/stat/event` is exposed to the integration key on this firmware. Use the UniFi UI for full event history; use `alarms.sh` for actionable issues.
- **Write allowlist is strict.** `apply.sh` rejects any action not in `ALLOWED=(wlan.toggle client.block client.unblock client.set-fixed-ip device.restart speedtest.run)`.
- **API key rotation.** Rotating the admin's local key revokes in-flight sessions. After rotation: `store-secret --vault ray --name UNIFI-LOCAL-API-KEY`.
- **Speedtest cadence.** Don't run `speedtest.run` more than once per ~5 min — it saturates the WAN.
- **Rate limits.** The local API has no documented limit, but 5xx bursts trigger backoff. Scripts cap at 3 retries.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `refusing to connect: no UNIFI_TLS_SPKI_SHA256` | Capture SPKI (see Auth section) and set in `config.sh` |
| `curl: (90) SSL: public key does not match pinned public key` | You stored the cert SHA-256 fingerprint instead of the SPKI hash — recapture using the openssl pipeline in Auth |
| `HTTP 401` from any call | Rotate/regenerate local API key; re-seed `UNIFI-LOCAL-API-KEY` |
| `HTTP 403` from write ops | Admin role lacks Super Admin or Site Admin → check UniFi Admins |
| `probe failed: v1 and legacy both unreachable` | `UNIFI_HOST` wrong or firewall blocking; verify `ping $UNIFI_HOST` and port 443 |
| Works on <VOIP-BRAND>, fails on OITVOIP2 | UniFi WAN management not enabled, or WAN IP changed — check UniFi → Settings → System → Advanced → Device Authentication |

## Resolved Issues

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| — | — | — | — |
