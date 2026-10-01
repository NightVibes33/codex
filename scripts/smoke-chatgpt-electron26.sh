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

# IMPORTANT: keep Electron 26's runtime/helper metadata. Copying the Electron 42
# plist wholesale makes Electron 26 look for the wrong helper bundle layout and
# exits before the OpenAI app can finish launching. Merge only product-facing
# OpenAI metadata onto the compatible runtime plist.
python3 - "$EDIR/Electron.app/Contents/Info.plist" "$SOURCE_APP/Contents/Info.plist" "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
base_path, source_path, out_path = sys.argv[1:4]
with open(base_path, "rb") as f:
    base = plistlib.load(f)
with open(source_path, "rb") as f:
    source = plistlib.load(f)

for key in (
    "CFBundleIdentifier",
    "CFBundleName",
    "CFBundleDisplayName",
    "CFBundleShortVersionString",
    "CFBundleVersion",
    "CFBundleIconFile",
    "CFBundleIconName",
    "CFBundleURLTypes",
    "CFBundleDocumentTypes",
    "LSApplicationCategoryType",
    "LSMultipleInstancesProhibited",
    "NSUserActivityTypes",
):
    if key in source:
        base[key] = source[key]

# Preserve the real app's privacy prompts without importing Electron-42-only
# runtime keys such as ElectronAsarIntegrity / helper identifiers.
for key, value in source.items():
    if key.startswith("NS") and key.endswith("UsageDescription"):
        base[key] = value

base["LSMinimumSystemVersion"] = "10.13"
# Keep Electron 26's actual launcher name and helper layout.
base["CFBundleExecutable"] = "Electron"

with open(out_path, "wb") as f:
    plistlib.dump(base, f, sort_keys=False)
PY

# The OpenAI icon lives in the copied Resources directory. The current app
# payload, authentication callback schemes, and renderer are unchanged.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

{
  echo "source_url=$DMG_URL"
  echo "source_version=$SOURCE_VERSION"
  echo "source_build=$SOURCE_BUILD"
  echo "source_electron=42.3.0"
  echo "compat_electron=$ELECTRON_VERSION"
  echo "source_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")"
  echo "compat_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  echo "compat_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
  echo "compat_min_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
  file "$APP/Contents/MacOS/Electron"
  otool -l "$APP/Contents/MacOS/Electron" | awk '
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

# Diagnostic bootstrap: preserve OpenAI's app.asar byte-for-byte as
# original.asar, then use a tiny temporary CI-only app.asar to expose the first
# Electron 42 -> Electron 26 incompatibility before handing control to the real
# OpenAI early bootstrap.
ORIGINAL_ASAR="$APP/Contents/Resources/original.asar"
mv "$APP/Contents/Resources/app.asar" "$ORIGINAL_ASAR"
if [[ -d "$APP/Contents/Resources/app.asar.unpacked" ]]; then
  mv "$APP/Contents/Resources/app.asar.unpacked" "$APP/Contents/Resources/original.asar.unpacked"
fi

DIAG_ROOT="$TMP/diagnostic-bootstrap"
mkdir -p "$DIAG_ROOT"
cat > "$DIAG_ROOT/package.json" <<'JSON'
{
  "name": "openai-codex-high-sierra-diagnostic-bootstrap",
  "version": "1.0.0",
  "main": "main.cjs"
}
JSON

cat > "$DIAG_ROOT/main.cjs" <<'JS'
const path = require("node:path");
const util = require("node:util");

const dump = (label, value) => {
  try {
    const rendered =
      typeof value === "string"
        ? value
        : util.inspect(value, { depth: 8, breakLength: 160 });
    console.error("[high-sierra-diag]", label, rendered);
  } catch {}
};

dump("versions", process.versions);
dump("resourcesPath", process.resourcesPath);
dump("argv", process.argv);

process.on("uncaughtException", (error) => {
  dump("uncaughtException", error && (error.stack || error));
  process.exitCode = 91;
});
process.on("unhandledRejection", (error) => {
  dump("unhandledRejection", error && (error.stack || error));
  process.exitCode = 92;
});
process.on("warning", (warning) => {
  dump("warning", warning && (warning.stack || warning));
});
process.on("beforeExit", (code) => dump("beforeExit", code));
process.on("exit", (code) => dump("exit", code));

const target = path.join(
  process.resourcesPath,
  "original.asar",
  ".vite",
  "build",
  "early-bootstrap.js"
);
dump("loading-real-openai-bootstrap", target);

try {
  require(target);
  dump("real-openai-bootstrap-returned", target);
} catch (error) {
  dump("real-openai-bootstrap-threw", error && (error.stack || error));
  process.exitCode = 93;
  setTimeout(() => process.exit(process.exitCode || 93), 250);
}
JS

npx --yes @electron/asar@3 pack "$DIAG_ROOT" "$APP/Contents/Resources/app.asar"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

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
run_probe bundle "$APP/Contents/MacOS/Electron"

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
echo "--- diagnostic markers ---"
grep -E '\[high-sierra-diag\]' "$OUT/bundle-stderr.log" || true
echo "--- bundle stderr ---"
tail -300 "$OUT/bundle-stderr.log" || true
echo "--- direct stderr ---"
tail -200 "$OUT/direct-stderr.log" || true
