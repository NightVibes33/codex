#!/usr/bin/env bash
set -euo pipefail

URL="${1:-https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-x64-26.623.141536.zip}"
OUT="${2:-$PWD/historical-chatgpt-audit}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

ZIP="$TMP/app.zip"
curl -fL --retry 4 --retry-delay 2 "$URL" -o "$ZIP"

APP_ROOT="$(unzip -Z1 "$ZIP" | awk -F/ '/\.app\/Contents\/Info\.plist$/ {print $1; exit}')"
[[ -n "$APP_ROOT" ]] || { echo "No .app bundle found" >&2; exit 1; }

unzip -p "$ZIP" "$APP_ROOT/Contents/Info.plist" > "$TMP/Info.plist"
python3 - "$TMP/Info.plist" "$OUT/info.txt" <<'PY'
import plistlib,sys
p=plistlib.load(open(sys.argv[1],"rb"))
keys=["CFBundleIdentifier","CFBundleShortVersionString","CFBundleVersion","LSMinimumSystemVersion","CFBundleExecutable"]
with open(sys.argv[2],"w") as f:
    for k in keys: f.write(f"{k}={p.get(k)}\n")
PY

unzip -p "$ZIP" "$APP_ROOT/Contents/Resources/app.asar" > "$TMP/app.asar"
mkdir -p "$TMP/asar-meta"
(
  cd "$TMP/asar-meta"
  npx --yes @electron/asar@3 extract-file "$TMP/app.asar" package.json >/dev/null
)
cp "$TMP/asar-meta/package.json" "$OUT/package.json"

python3 - "$OUT/package.json" "$OUT/summary.txt" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
with open(sys.argv[2],"w") as f:
    f.write(f"name={j.get('name')}\n")
    f.write(f"version={j.get('version')}\n")
    f.write(f"main={j.get('main')}\n")
    d=j.get("devDependencies") or {}
    f.write(f"electron={d.get('electron')}\n")
PY

{
 echo "source_url=$URL"
 cat "$OUT/info.txt"
 cat "$OUT/summary.txt"
} | tee "$OUT/result.txt"
