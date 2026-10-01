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
root=ET.parse(sys.argv[1]).getroot()
for item in root.findall(".//item"):
    enc=item.find("enclosure")
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
for pattern in 'application-network-startup-.*\.js$' 'startup-requirements-.*\.js$' 'early-bootstrap\.js$'; do
  while IFS= read -r p; do
    clean="${p#/}"
    [[ -n "$clean" ]] || continue
    name="$(basename "$clean")"
    npx --yes @electron/asar@3 extract-file "$TMP/app.asar" "$clean" > "$OUT/$name"
    echo "extracted=$clean" | tee -a "$OUT/source.txt"
  done < <(grep -E "$pattern" "$OUT/asar-list.txt" || true)
done

echo "--- startup-requirements ---"
cat "$OUT"/startup-requirements-*.js 2>/dev/null || true
echo
echo "--- application-network-startup ---"
cat "$OUT"/application-network-startup-*.js 2>/dev/null || true
