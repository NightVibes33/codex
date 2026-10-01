#!/usr/bin/env bash
set -euo pipefail

APPCAST_URL="${CHATGPT_X64_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml}"
OUT="${1:-$PWD/official-chatgpt-baseline}"
TMP="$(mktemp -d -t official-chatgpt-baseline.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$OUT" "$TMP/source"

ua="Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_9) AppleWebKit/605.1.15 Safari/605.1.15"
curl -fsSL --retry 4 --retry-delay 2 -A "$ua" "$APPCAST_URL" -o "$TMP/appcast.xml"
SOURCE_URL="$(python3 - "$TMP/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot()
for item in root.findall(".//item"):
    enc=item.find("enclosure")
    if enc is not None and enc.attrib.get("url"):
        print(enc.attrib["url"]); break
else:
    raise SystemExit("no x64 ChatGPT enclosure")
PY
)"
echo "source_url=$SOURCE_URL" | tee "$OUT/info.txt"
curl -fL --retry 4 --retry-delay 2 "$SOURCE_URL" -o "$TMP/ChatGPT.zip"
ditto -x -k "$TMP/ChatGPT.zip" "$TMP/source"
APP="$(find "$TMP/source" -type d -name ChatGPT.app -print | head -n 1)"
[[ -d "$APP" ]] || { echo "official ChatGPT.app missing" >&2; exit 1; }

/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" | sed 's/^/version=/' | tee -a "$OUT/info.txt"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" | sed 's/^/build=/' | tee -a "$OUT/info.txt"

EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
"$EXE" --remote-debugging-port=9241 --disable-gpu --no-sandbox --enable-logging=stderr >"$OUT/stdout.log" 2>"$OUT/stderr.log" &
pid=$!
cleanup_app() { kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; }
trap 'cleanup_app; rm -rf "$TMP"' EXIT HUP INT TERM

captured=false
alive=false
for _ in {1..30}; do
  if kill -0 "$pid" >/dev/null 2>&1; then
    alive=true
  else
    alive=false
    break
  fi
  if curl -fsS "http://127.0.0.1:9241/json/list" -o "$OUT/cdp.json" 2>/dev/null; then
    if python3 - "$OUT/cdp.json" <<'PY'
import json,sys
items=json.load(open(sys.argv[1]))
pages=[x for x in items if x.get("type") in ("page","webview")]
print(json.dumps([{"type":x.get("type"),"title":x.get("title"),"url":x.get("url")} for x in pages],indent=2))
raise SystemExit(0 if pages else 1)
PY
    then
      captured=true
      break
    fi
  fi
  sleep 1
done

echo "alive=$alive" | tee -a "$OUT/info.txt"
echo "renderer_captured=$captured" | tee -a "$OUT/info.txt"
if [[ "$captured" != true ]]; then
  tail -300 "$OUT/stderr.log" >&2 || true
  exit 1
fi
