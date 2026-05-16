#!/usr/bin/env bash
# Send a Teams DM as the bot. Outbound-only — uses the cached conversation
# reference written by fetch-conv-ref.sh.
#
# Usage:
#   ./send-dm.sh "message body"           # plain text
#   ./send-dm.sh --markdown "**hi**"      # rendered as markdown
set -euo pipefail

CONFIG_DIR="${HOME}/.config/teams-dm"
CONV_REF="${CONFIG_DIR}/conv-ref.json"
ENV_FILE="${CONFIG_DIR}/env"
TOKEN_CACHE="${TMPDIR:-/tmp}/teams-dm-token"

[[ -f "${CONV_REF}" ]] || { echo "ERR: ${CONV_REF} not found. Run fetch-conv-ref.sh first." >&2; exit 1; }
[[ -f "${ENV_FILE}" ]] || { echo "ERR: ${ENV_FILE} not found. See README for required vars." >&2; exit 1; }

# shellcheck disable=SC1090
source "${ENV_FILE}"
: "${BOT_APP_ID:?BOT_APP_ID missing in ${ENV_FILE}}"
: "${BOT_APP_SECRET:?BOT_APP_SECRET missing in ${ENV_FILE}}"
: "${<credential-env>:?<credential-env> missing in ${ENV_FILE}}"

text_format="plain"
if [[ "${1:-}" == "--markdown" ]]; then
  text_format="markdown"
  shift
fi
text="${1:?usage: send-dm.sh [--markdown] \"message\"}"

# Reuse cached token. Cache stores access_token + absolute expiry epoch on two
# lines. Honor the token endpoint's expires_in minus a 60s clock-skew margin.
# Atomic write via mktemp+mv. mkdir-based lock prevents concurrent invocations
# from stampeding the token endpoint when the cache expires (mkdir is atomic
# on all POSIX filesystems — no flock/portable lock-file dance needed).
LOCK_DIR="${TOKEN_CACHE}.lock"
acquire_lock() {
  local tries=0
  until mkdir "${LOCK_DIR}" 2>/dev/null; do
    tries=$((tries + 1))
    [[ $tries -gt 50 ]] && { echo "ERR: could not acquire token lock after 5s" >&2; return 1; }
    sleep 0.1
  done
  trap 'rmdir "${LOCK_DIR}" 2>/dev/null' EXIT
}
release_lock() {
  rmdir "${LOCK_DIR}" 2>/dev/null || true
  trap - EXIT
}

get_token() {
  if [[ -f "${TOKEN_CACHE}" ]]; then
    local cached_exp cached_token
    cached_exp="$(sed -n '2p' "${TOKEN_CACHE}" 2>/dev/null || echo 0)"
    cached_token="$(sed -n '1p' "${TOKEN_CACHE}" 2>/dev/null || true)"
    if [[ -n "${cached_token}" && "${cached_exp}" =~ ^[0-9]+$ ]]; then
      if (( cached_exp - 60 > $(date +%s) )); then
        echo "${cached_token}"
        return
      fi
    fi
  fi
  # Cache miss or expired — serialize the refresh.
  acquire_lock || return 1
  # Re-check after acquiring lock — another process may have refreshed.
  if [[ -f "${TOKEN_CACHE}" ]]; then
    local cached_exp cached_token
    cached_exp="$(sed -n '2p' "${TOKEN_CACHE}" 2>/dev/null || echo 0)"
    cached_token="$(sed -n '1p' "${TOKEN_CACHE}" 2>/dev/null || true)"
    if [[ -n "${cached_token}" && "${cached_exp}" =~ ^[0-9]+$ ]] && (( cached_exp - 60 > $(date +%s) )); then
      release_lock
      echo "${cached_token}"
      return
    fi
  fi
  local response
  response="$(curl -sS -X POST \
    "https://login.microsoftonline.com/${<credential-env>}/oauth2/v2.0/token" \
    -d "client_id=${BOT_APP_ID}" \
    -d "client_secret=${BOT_APP_SECRET}" \
    -d "scope=https://api.botframework.com/.default" \
    -d "grant_type=client_credentials")"
  local parsed
  parsed="$(echo "${response}" | python3 -c "
import json, sys, time
d = json.load(sys.stdin)
if 'access_token' not in d:
    sys.exit('ERR: token response missing access_token: ' + json.dumps(d))
exp = int(time.time()) + int(d.get('expires_in', 3600))
print(d['access_token'])
print(exp)
")"
  local tmp
  tmp="$(mktemp "${TOKEN_CACHE}.XXXXXX")"
  printf '%s\n' "${parsed}" > "${tmp}"
  chmod 600 "${tmp}"
  mv "${tmp}" "${TOKEN_CACHE}"
  release_lock
  echo "${parsed%%$'\n'*}"
}

token="$(get_token)"
conv_id="$(python3 -c "import json; print(json.load(open('${CONV_REF}'))['conversationId'])")"
service_url="$(python3 -c "import json; print(json.load(open('${CONV_REF}'))['serviceUrl'].rstrip('/'))")"

body="$(python3 -c "
import json, sys
print(json.dumps({
  'type': 'message',
  'textFormat': sys.argv[1],
  'text': sys.argv[2],
}))
" "${text_format}" "${text}")"

http_code="$(curl -sS -o /tmp/teams-dm-resp -w "%{http_code}" \
  -X POST "${service_url}/v3/conversations/${conv_id}/activities" \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json" \
  -d "${body}")"

if [[ "${http_code}" == "401" ]]; then
  # Token may have rotated — bust cache and retry once.
  rm -f "${TOKEN_CACHE}"
  token="$(get_token)"
  http_code="$(curl -sS -o /tmp/teams-dm-resp -w "%{http_code}" \
    -X POST "${service_url}/v3/conversations/${conv_id}/activities" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${body}")"
fi

if [[ "${http_code}" != "200" && "${http_code}" != "201" ]]; then
  echo "ERR: send failed (HTTP ${http_code})" >&2
  cat /tmp/teams-dm-resp >&2
  exit 1
fi
echo "Sent."
