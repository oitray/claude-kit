#!/usr/bin/env bash
# Bundle Teams app manifest + icons into a sideload-ready zip.
# Usage: ./make-zip.sh [output.zip]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-${HERE}/bot.zip}"

if grep -q "{{BOT_APP_ID}}" "${HERE}/manifest.json"; then
  echo "ERR: manifest.json still has {{BOT_APP_ID}} placeholder — fill it in first." >&2
  exit 1
fi
if grep -q "{{BOT_NAME}}" "${HERE}/manifest.json"; then
  echo "ERR: manifest.json still has {{BOT_NAME}} placeholder — fill it in first." >&2
  exit 1
fi

cd "${HERE}"
rm -f "${OUT}"
zip -q "${OUT}" manifest.json color.png outline.png
echo "Built: ${OUT}"
