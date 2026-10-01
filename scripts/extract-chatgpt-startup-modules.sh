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

copy_matches() {
  local regex="$1"
  local found=0
  while IFS= read -r member; do
    [[ -n "$member" ]] || continue
    local clean="${member#/}"
    local name
    local work
    name="$(basename "$clean")"
    work="$(mktemp -d "$TMP/extract-one.XXXXXX")"
    (
      cd "$work"
      npx --yes @electron/asar@3 extract-file "$TMP/app.asar" "$clean"
    )
    [[ -s "$work/$name" ]] || {
      echo "targeted ASAR extraction is missing/empty: $clean" >&2
      find "$work" -maxdepth 3 -type f -print >&2 || true
      exit 1
    }
    cp "$work/$name" "$OUT/$name"
    rm -rf "$work"
    echo "extracted=$clean bytes=$(wc -c < "$OUT/$name")" | tee -a "$OUT/source.txt"
    found=1
  done < <(grep -E "$regex" "$OUT/asar-list.txt" || true)
  [[ "$found" == "1" ]] || { echo "no ASAR members matched: $regex" >&2; exit 1; }
}

copy_matches '^/?package\.json$'
copy_matches 'application-network-startup-.*\.js$'
copy_matches 'startup-requirements-.*\.js$'
copy_matches 'desktop-open-path-queue-.*\.js$'
copy_matches '/?\.vite/build/bootstrap-[^/]+\.js$'
copy_matches '/?\.vite/build/main-[^/]+\.js$'
copy_matches 'early-bootstrap\.js$'

# build-flavor may be folded into another Vite chunk in some releases.
while IFS= read -r member; do
  [[ -n "$member" ]] || continue
  clean="${member#/}"
  name="$(basename "$clean")"
  work="$(mktemp -d "$TMP/extract-optional.XXXXXX")"
  (
    cd "$work"
    npx --yes @electron/asar@3 extract-file "$TMP/app.asar" "$clean"
  )
  if [[ -s "$work/$name" ]]; then
    cp "$work/$name" "$OUT/$name"
    echo "extracted=$clean bytes=$(wc -c < "$OUT/$name")" | tee -a "$OUT/source.txt"
  fi
  rm -rf "$work"
done < <(grep -E 'build-flavor-.*\.js$' "$OUT/asar-list.txt" || true)

extract_named() {
  local member="$1"
  local destination="$2"
  local work
  local name
  work="$(mktemp -d "$TMP/extract-named.XXXXXX")"
  name="$(basename "$member")"
  (
    cd "$work"
    npx --yes @electron/asar@3 extract-file "$TMP/app.asar" "$member"
  )
  if [[ -s "$work/$name" ]]; then
    cp "$work/$name" "$OUT/$destination"
    echo "extracted=$member as=$destination bytes=$(wc -c < "$OUT/$destination")" | tee -a "$OUT/source.txt"
  fi
  rm -rf "$work"
}

extract_named 'node_modules/better-sqlite3/.codex-native-module-build.json' 'better-sqlite3-native-build.json'
extract_named 'node_modules/better-sqlite3/package.json' 'better-sqlite3-package.json'
extract_named 'node_modules/node-pty/.codex-native-module-build.json' 'node-pty-native-build.json'
extract_named 'node_modules/node-pty/package.json' 'node-pty-package.json'

echo "--- extracted files ---"
wc -c "$OUT"/* 2>/dev/null || true
echo "--- package metadata ---"
cat "$OUT/package.json" || true
echo
echo "--- startup requirement symbols ---"
grep -hEo 'initializeNodeNetworkPermissions|configRequirements/read|application/network|setPermission[A-Za-z]+|Desktop network requirements prevented startup|app\.exit\([^)]*\)' "$OUT"/*.js | sort -u || true
