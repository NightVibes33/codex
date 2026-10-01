#!/usr/bin/env bash
set -euo pipefail

APPCAST_URL="${CHATGPT_X64_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml}"
SOURCE_URL="${CHATGPT_X64_SOURCE_URL:-}"
ELECTRON_VERSION="${ELECTRON_VERSION:-26.6.10}"
OUT="${1:-$PWD/chatgpt-electron26-smoke}"
TMP="$(mktemp -d -t chatgpt-electron26.XXXXXX)"
MOUNT="$TMP/mount"
SOURCE_ARCHIVE="$TMP/chatgpt-source"
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

if [[ -z "$SOURCE_URL" ]]; then
  curl -fsSL --retry 4 --retry-delay 2 \
    -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15" \
    "$APPCAST_URL" -o "$TMP/appcast.xml"
  SOURCE_URL="$(python3 - "$TMP/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for item in root.findall(".//item"):
    enclosure = item.find("enclosure")
    if enclosure is not None and enclosure.attrib.get("url"):
        print(enclosure.attrib["url"])
        break
else:
    raise SystemExit("no x64 ChatGPT enclosure found in appcast")
PY
)"
fi

case "$SOURCE_URL" in
  *.zip)
    curl -fL --retry 4 --retry-delay 2 "$SOURCE_URL" -o "$SOURCE_ARCHIVE.zip"
    mkdir -p "$TMP/source"
    ditto -x -k "$SOURCE_ARCHIVE.zip" "$TMP/source"
    SOURCE_APP="$(find "$TMP/source" -maxdepth 3 -type d -name 'ChatGPT.app' -print -quit)"
    ;;
  *.dmg)
    curl -fL --retry 4 --retry-delay 2 "$SOURCE_URL" -o "$SOURCE_ARCHIVE.dmg"
    hdiutil attach "$SOURCE_ARCHIVE.dmg" -mountpoint "$MOUNT" -nobrowse -readonly >/dev/null
    SOURCE_APP="$(find "$MOUNT" -maxdepth 2 -type d -name 'ChatGPT.app' -print -quit)"
    ;;
  *)
    echo "Unsupported official ChatGPT source URL: $SOURCE_URL" >&2
    exit 1
    ;;
esac
[[ -n "$SOURCE_APP" ]] || { echo "ChatGPT.app missing from official source" >&2; exit 1; }

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
  echo "source_url=$SOURCE_URL"
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

# Read only the two real OpenAI ASAR files needed for diagnostics. Avoid
# extracting the entire application payload on every compatibility smoke.
npx --yes @electron/asar@3 extract-file "$SOURCE_RES/app.asar" package.json \
  > "$OUT/real-app-package.json"
npx --yes @electron/asar@3 extract-file "$SOURCE_RES/app.asar" .vite/build/early-bootstrap.js \
  > "$TMP/early-bootstrap.js"
npx --yes @electron/asar@3 list "$SOURCE_RES/app.asar" > "$TMP/asar-list.txt"
while IFS= read -r module_path; do
  clean_path="${module_path#/}"
  case "$clean_path" in
    *application-network-startup-*.js|*startup-requirements-*.js)
      out_name="$(basename "$clean_path")"
      npx --yes @electron/asar@3 extract-file "$SOURCE_RES/app.asar" "$clean_path" \
        > "$OUT/$out_name"
      ;;
  esac
done < "$TMP/asar-list.txt"

python3 - "$TMP/early-bootstrap.js" "$OUT/early-bootstrap-signals.txt" <<'PY'
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

// Observe the real OpenAI startup modules without replacing their behavior.
const Module = require("node:module");
const electron = require("electron");
const originalLoad = Module._load;

const originalNodeExtension = Module._extensions[".node"];
if (originalNodeExtension) {
  Module._extensions[".node"] = function (module, filename) {
    dump("native-addon-load-start", filename);
    try {
      const result = originalNodeExtension(module, filename);
      dump("native-addon-load-ok", filename);
      return result;
    } catch (error) {
      dump("native-addon-load-error", {
        filename,
        error: error && (error.stack || error),
      });
      throw error;
    }
  };
}

if (electron && electron.dialog) {
  for (const method of ["showErrorBox", "showMessageBox", "showMessageBoxSync"]) {
    if (typeof electron.dialog[method] !== "function") continue;
    const original = electron.dialog[method].bind(electron.dialog);
    electron.dialog[method] = (...args) => {
      dump("electron-dialog-" + method, args);
      return original(...args);
    };
  }
}

function wrapLoggerNamespace(namespace, request) {
  if (!namespace || typeof namespace !== "object") return;
  if (typeof namespace.getLogger !== "function") return;
  try {
    const originalGetLogger = namespace.getLogger;
    namespace.getLogger = function (...args) {
      const logger = originalGetLogger.apply(this, args);
      if (logger && typeof logger.error === "function" && !logger.__highSierraWrapped) {
        const originalError = logger.error.bind(logger);
        try {
          Object.defineProperty(logger, "__highSierraWrapped", { value: true });
        } catch {}
        logger.error = (...errorArgs) => {
          dump("openai-logger-error", { request, errorArgs });
          return originalError(...errorArgs);
        };
      }
      return logger;
    };
    dump("wrapped-getLogger", request);
  } catch (error) {
    dump("wrap-getLogger-failed", { request, error: error && (error.stack || error) });
  }
}

function wrapStartupRequirements(namespace, request) {
  if (!namespace || typeof namespace !== "object") return;
  if (typeof namespace.initializeNodeNetworkPermissions !== "function") return;
  try {
    const original = namespace.initializeNodeNetworkPermissions;
    namespace.initializeNodeNetworkPermissions = async function (...args) {
      dump("initializeNodeNetworkPermissions-start", { request });
      try {
        const result = await original.apply(this, args);
        dump("initializeNodeNetworkPermissions-result", result);
        return result;
      } catch (error) {
        dump("initializeNodeNetworkPermissions-error", error && (error.stack || error));
        throw error;
      }
    };
    dump("wrapped-initializeNodeNetworkPermissions", request);
  } catch (error) {
    dump("wrap-startup-requirements-failed", {
      request,
      error: error && (error.stack || error),
    });
  }
}

Module._load = function (request, parent, isMain) {
  const loaded = originalLoad.apply(this, arguments);
  if (typeof request === "string") {
    if (request.includes("application-network-startup-")) {
      dump("loaded-application-network-startup", {
        request,
        keys: loaded && typeof loaded === "object" ? Object.keys(loaded) : [],
        namespaceKeys:
          loaded && loaded.n && typeof loaded.n === "object" ? Object.keys(loaded.n) : [],
      });
      wrapLoggerNamespace(loaded, request);
      wrapLoggerNamespace(loaded && loaded.n, request);
    }
    if (request.includes("startup-requirements-")) {
      dump("loaded-startup-requirements", {
        request,
        keys: loaded && typeof loaded === "object" ? Object.keys(loaded) : [],
        namespaceKeys:
          loaded && loaded.n && typeof loaded.n === "object" ? Object.keys(loaded.n) : [],
      });
      wrapStartupRequirements(loaded, request);
      wrapStartupRequirements(loaded && loaded.n, request);
    }
  }
  return loaded;
};

if (electron && electron.app && typeof electron.app.exit === "function") {
  const originalExit = electron.app.exit.bind(electron.app);
  electron.app.exit = (code) => {
    dump("electron.app.exit", { code, stack: new Error("app.exit").stack });
    return originalExit(code);
  };
}

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
  "$@" --enable-logging=stderr --v=1 --disable-gpu --no-sandbox --remote-debugging-port=9229 >"$stdout" 2>"$stderr" &
  probe_pid=$!
  set -e

  survived=false
  cdp_captured=false
  for _ in {1..20}; do
    if ! kill -0 "$probe_pid" >/dev/null 2>&1; then
      break
    fi
    if [[ "$cdp_captured" == "false" ]] && curl -fsS "http://127.0.0.1:9229/json/list" > "$OUT/${label}-cdp.json" 2>/dev/null; then
      cdp_captured=true
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
    echo "renderer_cdp_captured=$cdp_captured"
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
