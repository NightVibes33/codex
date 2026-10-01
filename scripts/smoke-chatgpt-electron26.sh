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

cleanup() {
  if mount | grep -F "$MOUNT" >/dev/null 2>&1; then
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  fi
  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

rm -rf "$OUT"
mkdir -p "$OUT" "$MOUNT" "$EDIR"

curl -fL --retry 4 "$DMG_URL" -o "$DMG"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly >/dev/null
SOURCE_APP="$(find "$MOUNT" -maxdepth 2 -type d -name 'ChatGPT.app' -print -quit)"
[[ -n "$SOURCE_APP" ]] || { echo "ChatGPT.app missing" >&2; exit 1; }

SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
SOURCE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")"

curl -fL --retry 4   "https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-darwin-x64.zip"   -o "$EZIP"
ditto -x -k "$EZIP" "$EDIR"
ditto "$EDIR/Electron.app" "$APP"

# Keep the real OpenAI application payload. Only the Chromium/Electron runtime is
# replaced with the last upstream Electron line that still supports macOS 10.13.
rm -rf "$APP/Contents/Resources"
ditto "$SOURCE_APP/Contents/Resources" "$APP/Contents/Resources"

# Preserve OpenAI's real application metadata/protocol registrations, while
# pointing it at the Electron 26 launcher and High Sierra deployment floor.
cp "$SOURCE_APP/Contents/Info.plist" "$APP/Contents/Info.plist"
mv "$APP/Contents/MacOS/Electron" "$APP/Contents/MacOS/ChatGPT"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ChatGPT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 10.13" "$APP/Contents/Info.plist" 2>/dev/null ||   /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 10.13" "$APP/Contents/Info.plist"

# Electron 26 ships its own helpers/framework. Keep those intact; they are the
# compatibility runtime. OpenAI's app.asar/app.asar.unpacked remain untouched.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

{
  echo "source_url=$DMG_URL"
  echo "source_version=$SOURCE_VERSION"
  echo "source_build=$SOURCE_BUILD"
  echo "electron_version=$ELECTRON_VERSION"
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

# Confirm the real OpenAI renderer/main payload stayed byte-identical.
shasum -a 256 "$SOURCE_APP/Contents/Resources/app.asar" "$APP/Contents/Resources/app.asar" > "$OUT/app-asar-sha256.txt"

mkdir -p "$TMP/asar-meta"
(
  cd "$TMP/asar-meta"
  npx --yes @electron/asar@3 extract-file "$APP/Contents/Resources/app.asar" package.json >/dev/null 2>&1 || true
)
if [[ -f "$TMP/asar-meta/package.json" ]]; then
  cp "$TMP/asar-meta/package.json" "$OUT/real-app-package.json"
fi

# Run the actual OpenAI app payload under Electron 26. The smoke does not require
# authentication; it only proves whether bootstrap/main survives long enough to
# create the desktop process.
mkdir -p "$TMP/user-data" "$TMP/codex-home"
set +e
CODEX_ELECTRON_USER_DATA_PATH="$TMP/user-data" CODEX_HOME="$TMP/codex-home" ELECTRON_ENABLE_LOGGING=1 ELECTRON_ENABLE_STACK_DUMPING=1 "$APP/Contents/MacOS/ChatGPT" --disable-gpu >"$OUT/stdout.log" 2>"$OUT/stderr.log" &
APP_PID=$!
set -e

survived=false
for i in {1..20}; do
  if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if kill -0 "$APP_PID" >/dev/null 2>&1; then
  survived=true
  kill "$APP_PID" >/dev/null 2>&1 || true
  wait "$APP_PID" >/dev/null 2>&1 || true
  APP_PID=""
else
  set +e
  wait "$APP_PID"
  exit_code=$?
  set -e
  APP_PID=""
  echo "process_exit_code=$exit_code" >> "$OUT/build-info.txt"
fi

echo "launch_survived_20s=$survived" >> "$OUT/build-info.txt"
echo "Built from the real OpenAI app payload; no wrapper/web shell was used." >> "$OUT/build-info.txt"

cat "$OUT/build-info.txt"
echo "--- stderr ---"
tail -200 "$OUT/stderr.log" || true
