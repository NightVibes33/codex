#!/usr/bin/env bash
set -euo pipefail

APPCAST_URL="${CHATGPT_X64_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml}"
OUT="${1:-$PWD/chatgpt-startup-modules}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

ua="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/605.1.15 Safari/605.1.15"
curl -fsSL --retry 4 --retry-delay 2 -A "$ua" "$APPCAST_URL" -o "$TMP/appcast.xml"

SOURCE_URL="$(python3 - "$TMP/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for item in root.findall(".//item"):
    enc = item.find("enclosure")
    if enc is not None and enc.attrib.get("url"):
        print(enc.attrib["url"])
        break
else:
    raise SystemExit("no x64 enclosure")
PY
)"
echo "source_url=$SOURCE_URL" | tee "$OUT/source.txt"

curl -fL --retry 4 --retry-delay 2 "$SOURCE_URL" -o "$TMP/ChatGPT.zip"
ASAR_PATH="$(unzip -Z1 "$TMP/ChatGPT.zip" | grep -E '/Contents/Resources/app\.asar$' | head -n 1)"
[[ -n "$ASAR_PATH" ]] || { echo "app.asar missing" >&2; exit 1; }
unzip -p "$TMP/ChatGPT.zip" "$ASAR_PATH" > "$TMP/app.asar"

npx --yes @electron/asar@3 list "$TMP/app.asar" > "$OUT/asar-list.txt"
EXTRACTED="$TMP/asar"
mkdir -p "$EXTRACTED"
npx --yes @electron/asar@3 extract "$TMP/app.asar" "$EXTRACTED"

copy_matches() {
  local regex="$1"
  local found=0
  while IFS= read -r member; do
    [[ -n "$member" ]] || continue
    local clean="${member#/}"
    local src="$EXTRACTED/$clean"
    local name
    name="$(basename "$clean")"
    [[ -s "$src" ]] || { echo "extracted ASAR member is missing/empty: $clean" >&2; exit 1; }
    cp "$src" "$OUT/$name"
    echo "extracted=$clean bytes=$(wc -c < "$OUT/$name")" | tee -a "$OUT/source.txt"
    found=1
  done < <(grep -E "$regex" "$OUT/asar-list.txt" || true)
  [[ "$found" == "1" ]] || { echo "no ASAR members matched: $regex" >&2; exit 1; }
}

copy_matches 'application-network-startup-.*\.js$'
copy_matches 'startup-requirements-.*\.js$'
copy_matches 'early-bootstrap\.js$'

echo "--- extracted files ---"
wc -c "$OUT"/*.js
echo "--- startup requirement symbols ---"
grep -hEo 'initializeNodeNetworkPermissions|configRequirements/read|application/network|setPermission[A-Za-z]+|Desktop network requirements prevented startup|app\.exit\([^)]*\)' "$OUT"/*.js | sort -u || true
