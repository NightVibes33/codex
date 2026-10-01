#!/usr/bin/env bash
set -euo pipefail

DMG_URL="${CHATGPT_X64_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/ChatGPT-latest-x64.dmg}"
ELECTRON_VERSION="${ELECTRON_VERSION:-26.6.10}"
OUT="${1:-$PWD/chatgpt-electron26-smoke}"
TMP="$(mktemp -d -t chatgpt-electron26.XXXXXX)"
MOUNT="$TMP/mount"
DMG="$TMP/ChatGPT-latest-x64.dmg"
EZIP="$TMP/electron.zip"
EDIR="$TMP/electron"
APP="$TMP/ChatGPT-High-Sierra.app"
ASAR_ROOT="$TMP/asar-root"

cleanup() {
  if mount | grep -F "$MOUNT" >/dev/null 2>&1; then
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  fi
  for pid_var in APP_PID DIRECT_PID; do
    pid="${!pid_var:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

rm -rf "$OUT"
mkdir -p "$OUT" "$MOUNT" "$EDIR" "$ASAR_ROOT"

curl -fL --retry 4 --retry-delay 2 "$DMG_URL" -o "$DMG"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly >/dev/null
SOURCE_APP="$(find "$MOUNT" -maxdepth 2 -type d -name 'ChatGPT.app' -print -quit)"
[[ -n "$SOURCE_APP" ]] || { echo "ChatGPT.app missing" >&2; exit 1; }

SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
SOURCE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")"
SOURCE_RES="$SOURCE_APP/Contents/Resources"

curl -fL --retry 4 --retry-delay 2 \
  "https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-darwin-x64.zip" \
  -o "$EZIP"
ditto -x -k "$EZIP" "$EDIR"
ditto "$EDIR/Electron.app" "$APP"

# Keep the real OpenAI application payload byte-for-byte. Only replace the
# Electron/Chromium runtime with the final Electron line that supports 10.13.
rm -rf "$APP/Contents/Resources"
ditto "$SOURCE_RES" "$APP/Contents/Resources"

cp "$SOURCE_APP/Contents/Info.plist" "$APP/Contents/Info.plist"
mv "$APP/Contents/MacOS/Electron" "$APP/Contents/MacOS/ChatGPT"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ChatGPT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 10.13" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 10.13" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

{
  echo "source_url=$DMG_URL"
  echo "source_version=$SOURCE_VERSION"
  echo "source_build=$SOURCE_BUILD"
  echo "source_electron=42.3.0"
  echo "compat_electron=$ELECTRON_VERSION"
  echo "source_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")"
  echo "compat_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  echo "compat_min_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
  file "$APP/Contents/MacOS/ChatGPT"
  otool -l "$APP/Contents/MacOS/ChatGPT" | awk '
    /cmd LC_BUILD_VERSION/ {show=1; print; next}
    /cmd LC_VERSION_MIN_MACOSX/ {show=1; print; next}
    show && /^(      cmd|  cmdsize)/ {show=0}
    show {print}
  '
} > "$OUT/build-info.txt"

# Prove the OpenAI application payload itself was not replaced.
shasum -a 256 "$SOURCE_RES/app.asar" "$APP/Contents/Resources/app.asar" > "$OUT/app-asar-sha256.txt"

# Extract the real app only inside this ephemeral runner for diagnostics.
npx --yes @electron/asar@3 extract "$SOURCE_RES/app.asar" "$ASAR_ROOT" >/dev/null
cp "$ASAR_ROOT/package.json" "$OUT/real-app-package.json"

python3 - "$ASAR_ROOT/.vite/build/early-bootstrap.js" "$OUT/early-bootstrap-signals.txt" <<'PY'
import re, sys
src, out = sys.argv[1:3]
text = open(src, "r", encoding="utf-8", errors="replace").read()
patterns = [
    r"process\.versions\.electron", r"process\.exit", r"app\.exit", r"app\.quit",
    r"unsupported", r"minimum", r"electron", r"owl", r"native", r"darwin"
]
hits=[]
for pat in patterns:
    for m in re.finditer(pat, text, re.I):
        lo=max(0,m.start()-180); hi=min(len(text),m.end()+260)
        snippet=" ".join(text[lo:hi].split())
        hits.append((pat,snippet))
        if len(hits) >= 80:
            break
    if len(hits) >= 80:
        break
with open(out,"w") as f:
    for pat,s in hits:
        f.write(f"[{pat}] {s}\n")
PY

# Record native addons the real app may attempt to load. These must either be
# rebuilt for Electron 26 / macOS 10.13 or gated if they rely on newer APIs.
find "$SOURCE_RES" -type f -name '*.node' -print | sort > "$OUT/native-addons.txt"

mkdir -p "$TMP/user-data" "$TMP/codex-home"

run_probe() {
  local label="$1"
  shift
  local stdout="$OUT/${label}-stdout.log"
  local stderr="$OUT/${label}-stderr.log"
  local status_file="$OUT/${label}-status.txt"

  set +e
  CODEX_ELECTRON_USER_DATA_PATH="$TMP/user-data" \
  CODEX_HOME="$TMP/codex-home" \
  ELECTRON_ENABLE_LOGGING=1 \
  ELECTRON_ENABLE_STACK_DUMPING=1 \
  "$@" --enable-logging=stderr --v=1 --disable-gpu --no-sandbox >"$stdout" 2>"$stderr" &
  probe_pid=$!
  set -e

  survived=false
  for _ in {1..20}; do
    if ! kill -0 "$probe_pid" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if kill -0 "$probe_pid" >/dev/null 2>&1; then
    survived=true
    kill "$probe_pid" >/dev/null 2>&1 || true
    wait "$probe_pid" >/dev/null 2>&1 || true
    exit_code=0
  else
    set +e
    wait "$probe_pid"
    exit_code=$?
    set -e
  fi

  {
    echo "label=$label"
    echo "exit_code=$exit_code"
    echo "survived_20s=$survived"
  } > "$status_file"
}

# Probe A: compatibility app bundle carrying the real OpenAI resources.
run_probe bundle "$APP/Contents/MacOS/ChatGPT"

# Probe B: pristine Electron 26 launcher pointed directly at the real OpenAI
# app.asar. This separates bundle-plist/codesign issues from JS/runtime issues.
run_probe direct "$EDIR/Electron.app/Contents/MacOS/Electron" "$SOURCE_RES/app.asar"

# Capture dyld resolution for the direct probe path without allowing a
# successful GUI launch to hold the CI job open indefinitely.
set +e
DYLD_PRINT_LIBRARIES=1 \
ELECTRON_ENABLE_LOGGING=1 \
"$EDIR/Electron.app/Contents/MacOS/Electron" "$SOURCE_RES/app.asar" \
  --disable-gpu --no-sandbox --enable-logging=stderr \
  >"$OUT/dyld-stdout.log" 2>"$OUT/dyld-stderr.log" &
DYLD_PID=$!
set -e
for _ in {1..8}; do
  if ! kill -0 "$DYLD_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if kill -0 "$DYLD_PID" >/dev/null 2>&1; then
  kill "$DYLD_PID" >/dev/null 2>&1 || true
  wait "$DYLD_PID" >/dev/null 2>&1 || true
  echo "dyld_probe_exit_code=alive_after_8s" > "$OUT/dyld-status.txt"
else
  set +e
  wait "$DYLD_PID"
  echo "dyld_probe_exit_code=$?" > "$OUT/dyld-status.txt"
  set -e
fi

# Electron/Chromium frequently reports early failures only to unified logging.
log show --last 5m --style compact \
  --predicate '(process == "ChatGPT") OR (process == "Electron") OR (process CONTAINS "Helper")' \
  2>/dev/null | tail -800 > "$OUT/unified-log.txt" || true

cat "$OUT/build-info.txt"
cat "$OUT/bundle-status.txt"
cat "$OUT/direct-status.txt"
echo "--- bundle stderr ---"
tail -200 "$OUT/bundle-stderr.log" || true
echo "--- direct stderr ---"
tail -200 "$OUT/direct-stderr.log" || true
