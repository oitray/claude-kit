# UniFi Network Runbook

> **Owner:** <your-name> | **Last verified:** 2026-06-30 (topology + 6 GHz radio tune verified live; Network 10.2.x on UCG Ultra)

Home UniFi setup: UCG-Ultra gateway/console + U7 Pro AP (wired to UCG) + two **UDB Switches** (model `UDBA69F`, "UniFi Device Bridge"). Reachable from primary SSID <VOIP-BRAND> and fallback SSID VOIP2 (AT&T, UniFi WAN). All interaction is local-only — UniFi Cloud/UID is NOT used.

### Topology + the UDB Switch (read before diagnosing "mesh" issues)

A **UDB Switch** (`UDBA69F`, `type: udb`, shortname `UDBSW`) is a Wi-Fi 7 *receiver* with 8 PoE ports. It is a **client** that wirelessly uplinks to a UniFi **AP** (via WiFi Auto-Link); it does **not** broadcast and **cannot backhaul another UDB Switch** ([roles doc](https://help.ui.com/hc/en-us/articles/32064746398999-Understanding-Connectivity-Roles-of-UDB-Devices), [UDB Switch review](https://dongknows.com/ubiquiti-unifi-device-bridge-udb-switch-review/)). UDB↔UDB P2P is a *different* product (UDB **Pro** / Directional Bridge), not this hardware.

```
UCG-Ultra (192.168.1.187) ── wire ── U7 Pro AP (192.168.0.84, 8c:30:66:54:9d:28)
                                          ▲ 6 GHz (6e) uplink  ← INTENDED design, not a fallback
                                          └── FL02SW01 / UDB2 (192.168.0.107, 8c:ed:e1:1a:7b:0a) — cameras
   ("UDB1" 192.168.0.159, 8c:ed:e1:1a:7a:ae — a 2nd UDB Switch, role unverified, may be offline)
```

- `FL02SW01.uplink.uplink_mac == U7 Pro MAC` is **correct**. A UDB Switch uplinking to the U7 Pro is the design — do NOT treat it as degraded, and do NOT "restore UDB1" to fix FL02SW01's link (UDB1 is a separate client switch, not a backhaul anchor).
- Healthy uplink RSSI: **-60 to -65 dBm** (Ubiquiti mesh floor is -70). The dominant lever is the **U7 Pro 6 GHz radio TX power** (see "Tuning the 6 GHz uplink" below).

### Tuning the 6 GHz uplink (raise AP TX power)

The U7 Pro 6 GHz radio (`6e`/`wifi2`) can be pinned to minimum power, which starves the FL02SW01 uplink. Probe the live config:

```bash
# radio_table[6e]: tx_power_mode (custom|auto|high), tx_power, max_txpower, ap_pwr_type
UNIFI_BASE_URL="https://${UNIFI_HOST}/proxy/network/api/s/default" bash scripts/unifi/unifi-curl.sh GET "/stat/device/8c:30:66:54:9d:28"
```

To raise it: `PUT /rest/device/{_id}` with the **full** `radio_table` array, changing only the `6e` entry's `tx_power_mode` to `"high"` (preserve every other field + the other radios verbatim, or `ng`/`na` channels reset). The controller then applies the LPI-capped max (**~21 dBm at 160 MHz**; ~23 dBm ceiling). The `6e` radio carries **0 client stations** (clients live on 2.4/5 GHz), so this is near-zero blast radius — but applying it bounces the 6 GHz radio for a few seconds (cameras reconnect). This edits the **AP**, not the meshed switch, so it does NOT carry the `port_overrides` reprovision hazard.

> **Empirical (2026-06-30, <clickup-task-id>):** FL02SW01 uplink was **-77 dBm** because `6e` was `tx_power_mode: custom, tx_power: 6` (the floor). PUT `6e → high` → controller applied **21 dBm** → uplink **-77 → -63/-64 dBm**, rx ~288 → ~1300-1440 Mbps, stable. `rc: ok`. The gated `apply.sh device.radio` action performs the same PUT: `scripts/unifi/apply.sh device.radio <mac> wifi2 tx_power_mode=high` (dry-run plan), then add `--apply --confirm device.radio`.

## Auth

- **Method:** Local API key (per-admin), sent as `X-API-KEY` header
- **Vault:** `<credential-vault>`
- **Secret name:** `UNIFI-LOCAL-API-KEY`
- **Env var:** `$UNIFI_LOCAL_API_KEY`
- **Fetch creds:** `export UNIFI_LOCAL_API_KEY=$(AZURE_CONFIG_DIR=<azure-config-dir> az keyvault secret show --vault-name <credential-vault> --name UNIFI-LOCAL-API-KEY --query value -o tsv)`
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
| `device.radio` | `<mac> <radioName> <key=value>...` | legacy `GET /stat/device/{mac}` → `scripts/unifi/patch-radio.py` updates only the named `radio_table` entry (others verbatim; `channel`/`ht` as strings) → `PUT /rest/device/{_id}` `{_id, radio_table}`. Exit 3 if the device or radio name is not found. |
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

## Remote access (VOIP2 fallback)

The UniFi gateway is hardwired to the AT&T router. When on VOIP2 (AT&T LAN), the UniFi WAN IP must be reachable and the UniFi console must allow management on WAN from the AT&T subnet. No VPN is used. Fingerprint pin is the same regardless of network path; `UNIFI_HOST` may need to change to the WAN-side address when on VOIP2.

## Gotchas

- **SPKI pin, not cert fingerprint.** Wrappers use `--pinnedpubkey` which hashes the SubjectPublicKeyInfo. The raw `x509 -fingerprint` hex is a different value and will fail with `curl: (90) SSL: public key does not match pinned public key`.
- **`--pinnedpubkey` is combined with `--insecure`.** UniFi's self-signed cert fails chain validation, so chain is skipped; identity is enforced by the SPKI pin. This is stronger than `--insecure` alone.
- **v1 integration API is narrow.** Sites/devices/clients only. Events and alarms (and per-site health) require the legacy `/proxy/network/api/s/{site}/` path, accessed with the same key.
- **Events endpoint 404s on 10.2.x.** Neither v1 nor legacy `/stat/event` is exposed to the integration key on this firmware. Use the UniFi UI for full event history; use `alarms.sh` for actionable issues.
- **Write allowlist is strict.** `apply.sh` rejects any action not in `ALLOWED=(wlan.toggle client.block client.unblock client.set-fixed-ip device.restart device.radio speedtest.run)`.
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
| Works on <VOIP-BRAND>, fails on VOIP2 | UniFi WAN management not enabled, or WAN IP changed — check UniFi → Settings → System → Advanced → Device Authentication |

## Resolved Issues

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| — | — | — | — |
