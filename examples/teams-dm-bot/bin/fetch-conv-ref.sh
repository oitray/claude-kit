#!/usr/bin/env bash
# One-shot bootstrap helper.
# Fetches the cached conversation reference from the Worker (or Function)
# using the setup secret and writes it to ~/.config/teams-dm/conv-ref.json.
#
# Usage:
#   WORKER_URL=https://my-bot.example.workers.dev \
#   SETUP_SECRET=hunter2 \
#     ./fetch-conv-ref.sh
set -euo pipefail

: "${WORKER_URL:?WORKER_URL must be set to your Worker or Function URL}"
: "${SETUP_SECRET:?SETUP_SECRET must be set to the value you wrangled into the worker}"

CONFIG_DIR="${HOME}/.config/teams-dm"
mkdir -p "${CONFIG_DIR}"

response_file="$(mktemp)"
trap 'rm -f "${response_file}"' EXIT

http_code="$(curl -sS -o "${response_file}" -w "%{http_code}" \
  -H "X-Setup-Secret: ${SETUP_SECRET}" \
  "${WORKER_URL%/}/conv-ref")"

if [[ "${http_code}" != "200" ]]; then
  echo "ERR: Worker returned ${http_code}" >&2
  cat "${response_file}" >&2
  exit 1
fi

# Sanity-check that we got JSON with a conversationId.
if ! python3 -c "import json,sys; d=json.load(open('${response_file}')); sys.exit(0 if d.get('conversationId') and d.get('serviceUrl') else 1)"; then
  echo "ERR: response did not contain conversationId + serviceUrl" >&2
  cat "${response_file}" >&2
  exit 1
fi

mv "${response_file}" "${CONFIG_DIR}/conv-ref.json"
chmod 600 "${CONFIG_DIR}/conv-ref.json"
echo "Saved: ${CONFIG_DIR}/conv-ref.json"
