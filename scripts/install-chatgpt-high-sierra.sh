#!/bin/bash
set -euo pipefail

APPCAST_URL="${CHATGPT_X64_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml}"
ELECTRON_VERSION="${CHATGPT_HIGH_SIERRA_ELECTRON_VERSION:-26.6.10}"
NATIVE_TAG="${CHATGPT_HIGH_SIERRA_NATIVE_TAG:-high-sierra-electron26-native}"
NATIVE_BASE_URL="${CHATGPT_HIGH_SIERRA_NATIVE_BASE_URL:-https://github.com/NightVibes33/codex/releases/download/$NATIVE_TAG}"
INSTALL_BASE="${CHATGPT_HIGH_SIERRA_INSTALL_BASE:-$HOME/Applications}"
DEST="$INSTALL_BASE/ChatGPT.app"
TMP="$(mktemp -d -t chatgpt-high-sierra.XXXXXX)"
MOUNT="$TMP/mount"
SOURCE_DIR="$TMP/source"
ELECTRON_DIR="$TMP/electron"
COMPAT_APP="$TMP/ChatGPT.app"

cleanup() {
  if mount | grep -F "$MOUNT" >/dev/null 2>&1; then
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

version="$(/usr/bin/sw_vers -productVersion)"
arch="$(/usr/bin/uname -m)"
if [[ "$arch" != "x86_64" ]]; then
  echo "This installer is for Intel x86_64 Macs. Detected: $arch" >&2
  exit 1
fi

major="${version%%.*}"
rest="${version#*.}"
minor="${rest%%.*}"
if [[ "$major" == "10" && "$minor" -lt 13 ]]; then
  echo "macOS $version is older than the 10.13 deployment target." >&2
  exit 1
fi

mkdir -p "$MOUNT" "$SOURCE_DIR" "$ELECTRON_DIR" "$INSTALL_BASE"

if [[ -n "${CHATGPT_HIGH_SIERRA_PYTHON:-}" ]]; then
  PYTHON_BIN="$CHATGPT_HIGH_SIERRA_PYTHON"
elif [[ -x /usr/bin/python3 ]]; then
  PYTHON_BIN=/usr/bin/python3
elif [[ -x /usr/bin/python ]]; then
  PYTHON_BIN=/usr/bin/python
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python)"
else
  echo "Python is required to parse the OpenAI appcast and plist metadata." >&2
  exit 1
fi

echo "Finding the latest official OpenAI Intel ChatGPT build..."
curl -fsSL --retry 4 --retry-delay 2 \
  -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/605.1.15 Safari/605.1.15" \
  "$APPCAST_URL" -o "$TMP/appcast.xml"

SOURCE_URL="$("$PYTHON_BIN" - "$TMP/appcast.xml" <<'PY'
from __future__ import print_function
import sys
try:
    import xml.etree.ElementTree as ET
except ImportError:
    raise SystemExit("Python ElementTree is required")
root = ET.parse(sys.argv[1]).getroot()
for item in root.findall(".//item"):
    enclosure = item.find("enclosure")
    if enclosure is not None and enclosure.attrib.get("url"):
        print(enclosure.attrib["url"])
        break
else:
    raise SystemExit("No Intel ChatGPT enclosure found in OpenAI appcast")
PY
)"

echo "Downloading OpenAI ChatGPT:"
echo "$SOURCE_URL"
case "$SOURCE_URL" in
  *.zip)
    curl -fL --retry 4 --retry-delay 2 "$SOURCE_URL" -o "$TMP/ChatGPT.zip"
    ditto -x -k "$TMP/ChatGPT.zip" "$SOURCE_DIR"
    SOURCE_APP="$(/usr/bin/find "$SOURCE_DIR" -type d -name 'ChatGPT.app' -print | /usr/bin/head -n 1)"
    ;;
  *.dmg)
    curl -fL --retry 4 --retry-delay 2 "$SOURCE_URL" -o "$TMP/ChatGPT.dmg"
    hdiutil attach "$TMP/ChatGPT.dmg" -mountpoint "$MOUNT" -nobrowse -readonly >/dev/null
    SOURCE_APP="$(/usr/bin/find "$MOUNT" -type d -name 'ChatGPT.app' -print | /usr/bin/head -n 1)"
    ;;
  *)
    echo "Unsupported official ChatGPT source URL: $SOURCE_URL" >&2
    exit 1
    ;;
esac

if [[ -z "${SOURCE_APP:-}" || ! -d "$SOURCE_APP" ]]; then
  echo "ChatGPT.app was not found in the official OpenAI download." >&2
  exit 1
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$bundle_id" != "com.openai.codex" ]]; then
  echo "Unexpected OpenAI bundle identifier: $bundle_id" >&2
  exit 1
fi

source_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
source_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")"

echo "Downloading Electron $ELECTRON_VERSION (last Electron line supporting macOS 10.13)..."
electron_asset="electron-v$ELECTRON_VERSION-darwin-x64.zip"
electron_urls=(
  "https://github.com/electron/electron/releases/download/v$ELECTRON_VERSION/$electron_asset"
  "https://npmmirror.com/mirrors/electron/v$ELECTRON_VERSION/$electron_asset"
)
electron_downloaded=0
for electron_url in "${electron_urls[@]}"; do
  attempt=1
  while [[ "$attempt" -le 4 ]]; do
    echo "Electron source: $electron_url"
    if curl -fL --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 300 "$electron_url" -o "$TMP/Electron.zip"; then
      if unzip -tq "$TMP/Electron.zip" >/dev/null 2>&1; then
        electron_downloaded=1
        break 2
      fi
      echo "Electron archive validation failed from $electron_url" >&2
    fi
    echo "Electron download attempt $attempt failed; retrying..." >&2
    rm -f "$TMP/Electron.zip"
    sleep 2
    attempt=$((attempt + 1))
  done
done
if [[ "$electron_downloaded" != "1" ]]; then
  echo "Failed to download a valid Electron $ELECTRON_VERSION archive from all configured sources." >&2
  exit 1
fi
ditto -x -k "$TMP/Electron.zip" "$ELECTRON_DIR"

if [[ ! -d "$ELECTRON_DIR/Electron.app" ]]; then
  echo "Electron.app was not found in the Electron release archive." >&2
  exit 1
fi

# Electron 26 supplies the High-Sierra-compatible Chromium/runtime/framework and
# helper layout. OpenAI supplies the real ChatGPT/Codex application payload.
ditto "$ELECTRON_DIR/Electron.app" "$COMPAT_APP"
ditto "$SOURCE_APP/Contents/Resources" "$COMPAT_APP/Contents/Resources"

# Keep OpenAI's real packaged application byte-for-byte and put only a tiny
# runtime-compatibility bootstrap in Electron's conventional Resources/app
# directory. Electron 26 loads this bootstrap, which supplies JS APIs missing
# from its Node 18 runtime and then transfers control to OpenAI's real
# early-bootstrap.js. No renderer/UI code is replaced.
RES="$COMPAT_APP/Contents/Resources"
if [[ ! -f "$RES/app.asar" ]]; then
  echo "Official OpenAI app.asar is missing." >&2
  exit 1
fi
mv "$RES/app.asar" "$RES/original.asar"
if [[ -d "$RES/app.asar.unpacked" ]]; then
  mv "$RES/app.asar.unpacked" "$RES/original.asar.unpacked"
fi

# OpenAI's current native addons are compiled for the Owl/Chromium 154 ABI.
# Electron 26 embeds Node 18 (NODE_MODULE_VERSION 116), so use the rolling,
# checksum-verified x86_64 compatibility pack built from the same package
# versions against Electron 26 headers.
if [[ ! -d "$RES/original.asar.unpacked" ]]; then
  echo "Official OpenAI app.asar.unpacked is missing; native compatibility modules cannot be installed." >&2
  exit 1
fi

native_archive="electron26-native-darwin-x64.tar.gz"
echo "Downloading Electron 26 native compatibility modules..."
curl -fL --retry 4 --retry-delay 2   "$NATIVE_BASE_URL/$native_archive"   -o "$TMP/$native_archive"
curl -fL --retry 4 --retry-delay 2   "$NATIVE_BASE_URL/SHA256SUMS"   -o "$TMP/native-SHA256SUMS"

native_expected="$(awk -v asset="$native_archive" '
  $2 == asset || $2 == "*" asset { print $1; found=1; exit }
  NF >= 1 && !fallback { fallback=$1 }
  END { if (!found && fallback) print fallback }
' "$TMP/native-SHA256SUMS")"
native_actual="$(shasum -a 256 "$TMP/$native_archive" | awk '{print $1}')"
if [[ -z "$native_expected" || "$native_expected" != "$native_actual" ]]; then
  echo "Electron 26 native compatibility pack checksum verification failed." >&2
  exit 1
fi

mkdir -p "$TMP/native-pack"
tar -xzf "$TMP/$native_archive" -C "$TMP/native-pack"

sqlite_dst="$RES/original.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
pty_dst="$RES/original.asar.unpacked/node_modules/node-pty/build/Release/pty.node"
spawn_dst="$RES/original.asar.unpacked/node_modules/node-pty/build/Release/spawn-helper"

for required in "$sqlite_dst" "$pty_dst" "$spawn_dst"; do
  if [[ ! -e "$required" ]]; then
    echo "Expected OpenAI native module path is missing: $required" >&2
    exit 1
  fi
done

cp "$TMP/native-pack/better-sqlite3/build/Release/better_sqlite3.node" "$sqlite_dst"
cp "$TMP/native-pack/node-pty/build/Release/pty.node" "$pty_dst"
cp "$TMP/native-pack/node-pty/build/Release/spawn-helper" "$spawn_dst"
chmod 0755 "$spawn_dst"

# Preserve OpenAI's direct Resources/app.asar.unpacked lookups while keeping
# Electron 26 pointed at the compatibility bootstrap in Resources/app.
rm -rf "$RES/app.asar.unpacked"
ln -s "original.asar.unpacked" "$RES/app.asar.unpacked"

rm -rf "$RES/app"
mkdir -p "$RES/app"
cat > "$RES/app/package.json" <<JSON
{
  "name": "openai-codex-electron",
  "productName": "Codex",
  "author": "OpenAI",
  "version": "$source_version",
  "description": "Codex",
  "main": "main.cjs",
  "codexBuildFlavor": "prod",
  "codexBuildNumber": "$source_build"
}
JSON
cat > "$RES/app/main.cjs" <<'JS'
"use strict";

const path = require("node:path");
const electron = require("electron");
const { app, session, BrowserWindow } = electron;

const originalApp = path.join(process.resourcesPath, "original.asar");
const compatPackage = require("./package.json");

// OpenAI's build-flavor resolver normally reads Resources/app.asar/package.json.
// The compatibility bootstrap must occupy that Electron entrypoint, so the
// untouched OpenAI payload lives at original.asar. Feed the same official
// metadata through the resolver's supported environment path.
if (!process.env.BUILD_FLAVOR) {
  process.env.BUILD_FLAVOR = compatPackage.codexBuildFlavor || "prod";
}
if (!process.env.CODEX_APP_VERSION) {
  process.env.CODEX_APP_VERSION = compatPackage.version;
}
if (!process.env.CODEX_BUILD_NUMBER) {
  process.env.CODEX_BUILD_NUMBER = String(compatPackage.codexBuildNumber || "");
}
if (!process.env.NODE_ENV) {
  process.env.NODE_ENV = "production";
}

// OpenAI's current desktop payload checks for the Owl shell's native
// app.showTaskManager API before loading the main app. Electron 26 predates
// Owl, so provide the compatibility surface while leaving OpenAI's code and UI
// untouched. The task-manager command is non-essential on High Sierra.
if (typeof app.showTaskManager !== "function") {
  Object.defineProperty(app, "showTaskManager", {
    configurable: true,
    enumerable: false,
    value() {},
  });
}

// Owl/Electron 42 exposes a small set of shell capability APIs that do not
// exist in stock Electron 26. Preserve OpenAI's feature-detection semantics:
// unsupported visual/native-shell features report false, setters are harmless
// no-ops, and ordinary Electron behavior remains untouched.
function defineCompat(target, name, value) {
  if (target && typeof target[name] !== "function") {
    Object.defineProperty(target, name, {
      configurable: true,
      enumerable: false,
      writable: false,
      value,
    });
  }
}

defineCompat(app, "setRuntimeFeatures", () => {});
defineCompat(app, "isRuntimeFeatureEnabled", () => false);
defineCompat(app, "setDebugChromePagesEnabled", () => {});
defineCompat(app, "beginNativeMenuTracking", () => {});
defineCompat(app, "endNativeMenuTracking", () => {});

defineCompat(BrowserWindow, "isAlwaysOnTopSupported", () => true);
defineCompat(BrowserWindow, "isSystemBackdropSupported", () => false);
defineCompat(BrowserWindow, "isInputShapeSupported", () => false);

function patchSession(sess) {
  if (!sess) return sess;
  defineCompat(sess, "setWebsiteReportingEnabled", () => {});
  return sess;
}

// Register before OpenAI's bootstrap installs its own session-created handler
// so every session has the compatibility surface before OpenAI touches it.
app.on("session-created", patchSession);
if (session && typeof session.fromPartition === "function") {
  const originalFromPartition = session.fromPartition.bind(session);
  session.fromPartition = function (...args) {
    return patchSession(originalFromPartition(...args));
  };
}
if (app.isReady()) {
  patchSession(session && session.defaultSession);
} else {
  app.whenReady().then(() => patchSession(session && session.defaultSession));
}

// Runtime-only ECMAScript compatibility for Electron 26 / Node 18. These
// helpers match later platform semantics closely enough for OpenAI's current
// desktop bootstrap while leaving the real OpenAI app payload untouched.
if (!Symbol.dispose) Symbol.dispose = Symbol.for("dispose");
if (!Symbol.asyncDispose) Symbol.asyncDispose = Symbol.for("asyncDispose");

if (!Promise.withResolvers) {
  Promise.withResolvers = function withResolvers() {
    let resolve;
    let reject;
    const promise = new Promise((res, rej) => {
      resolve = res;
      reject = rej;
    });
    return { promise, resolve, reject };
  };
}

if (!URL.parse) {
  URL.parse = function parse(input, base) {
    try {
      return new URL(input, base);
    } catch {
      return null;
    }
  };
}
if (!URL.canParse) {
  URL.canParse = function canParse(input, base) {
    try {
      new URL(input, base);
      return true;
    } catch {
      return false;
    }
  };
}

if (!AbortSignal.any) {
  AbortSignal.any = function any(signals) {
    const controller = new AbortController();
    const list = Array.from(signals || []);
    const abort = (signal) => {
      if (controller.signal.aborted) return;
      try {
        controller.abort(signal && "reason" in signal ? signal.reason : undefined);
      } catch {
        controller.abort();
      }
    };
    for (const signal of list) {
      if (!signal) continue;
      if (signal.aborted) {
        abort(signal);
        break;
      }
      signal.addEventListener("abort", () => abort(signal), { once: true });
    }
    return controller.signal;
  };
}

if (!Array.prototype.toSorted) {
  Object.defineProperty(Array.prototype, "toSorted", {
    configurable: true,
    writable: true,
    value: function toSorted(compareFn) { return Array.from(this).sort(compareFn); },
  });
}
if (!Array.prototype.toReversed) {
  Object.defineProperty(Array.prototype, "toReversed", {
    configurable: true,
    writable: true,
    value: function toReversed() { return Array.from(this).reverse(); },
  });
}
if (!Array.prototype.toSpliced) {
  Object.defineProperty(Array.prototype, "toSpliced", {
    configurable: true,
    writable: true,
    value: function toSpliced(start, deleteCount, ...items) {
      const copy = Array.from(this);
      copy.splice(start, deleteCount, ...items);
      return copy;
    },
  });
}
if (!Array.prototype.with) {
  Object.defineProperty(Array.prototype, "with", {
    configurable: true,
    writable: true,
    value: function arrayWith(index, value) {
      const copy = Array.from(this);
      let i = Number(index);
      if (i < 0) i += copy.length;
      if (!Number.isInteger(i) || i < 0 || i >= copy.length) {
        throw new RangeError("Invalid index");
      }
      copy[i] = value;
      return copy;
    },
  });
}

if (!Object.groupBy) {
  Object.groupBy = function groupBy(items, callback) {
    const out = Object.create(null);
    let index = 0;
    for (const item of items) {
      const key = callback(item, index++);
      const propertyKey = typeof key === "symbol" ? key : String(key);
      (out[propertyKey] || (out[propertyKey] = [])).push(item);
    }
    return out;
  };
}
if (!Map.groupBy) {
  Map.groupBy = function groupBy(items, callback) {
    const out = new Map();
    let index = 0;
    for (const item of items) {
      const key = callback(item, index++);
      const group = out.get(key);
      if (group) group.push(item);
      else out.set(key, [item]);
    }
    return out;
  };
}

if (!String.prototype.isWellFormed) {
  Object.defineProperty(String.prototype, "isWellFormed", {
    configurable: true,
    writable: true,
    value: function isWellFormed() {
      const s = String(this);
      for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c >= 0xd800 && c <= 0xdbff) {
          const n = s.charCodeAt(++i);
          if (!(n >= 0xdc00 && n <= 0xdfff)) return false;
        } else if (c >= 0xdc00 && c <= 0xdfff) {
          return false;
        }
      }
      return true;
    },
  });
}
if (!String.prototype.toWellFormed) {
  Object.defineProperty(String.prototype, "toWellFormed", {
    configurable: true,
    writable: true,
    value: function toWellFormed() {
      const s = String(this);
      let out = "";
      for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c >= 0xd800 && c <= 0xdbff) {
          const n = s.charCodeAt(i + 1);
          if (n >= 0xdc00 && n <= 0xdfff) {
            out += s[i] + s[++i];
          } else {
            out += "\ufffd";
          }
        } else if (c >= 0xdc00 && c <= 0xdfff) {
          out += "\ufffd";
        } else {
          out += s[i];
        }
      }
      return out;
    },
  });
}

// Make app.getAppPath() and relative chunk resolution describe the actual
// OpenAI application, not this compatibility bootstrap.
app.setAppPath(originalApp);

if (process.env.CHATGPT_HIGH_SIERRA_DIAGNOSTICS === "1") {
  const Module = require("node:module");
  const originalLoad = Module._load;
  const originalCatch = Promise.prototype.catch;

  const dump = (label, value) => {
    try {
      console.error(
        "[high-sierra-compat]",
        label,
        value instanceof Error ? value.stack || value.message : value
      );
    } catch {}
  };

  Promise.prototype.catch = function (handler) {
    if (typeof handler !== "function") return originalCatch.call(this, handler);
    return originalCatch.call(this, (error) => {
      dump("caught", error);
      return handler(error);
    });
  };

  Module._load = function (request, parent, isMain) {
    const loaded = originalLoad.apply(this, arguments);
    if (
      typeof request === "string" &&
      (request.includes("startup-requirements-") ||
       request.includes("bootstrap-") ||
       request.includes("main-"))
    ) {
      dump("module-loaded", request);
    }
    return loaded;
  };

  for (const method of ["showMessageBox", "showMessageBoxSync", "showErrorBox"]) {
    if (electron.dialog && typeof electron.dialog[method] === "function") {
      const original = electron.dialog[method].bind(electron.dialog);
      electron.dialog[method] = (...args) => {
        dump("dialog:" + method, args);
        return original(...args);
      };
    }
  }

  for (const method of ["exit", "relaunch", "quit"]) {
    if (typeof app[method] === "function") {
      const original = app[method].bind(app);
      app[method] = (...args) => {
        dump("app:" + method, args);
        return original(...args);
      };
    }
  }

  app.on("browser-window-created", (_event, win) => {
    dump("browser-window-created", {
      id: win && win.id,
      destroyed: win && win.isDestroyed && win.isDestroyed(),
    });
  });

  process.on("uncaughtException", (error) => {
    dump("uncaught", error);
    throw error;
  });
  process.on("unhandledRejection", (error) => {
    dump("unhandled", error);
  });
}

require(path.join(originalApp, ".vite", "build", "early-bootstrap.js"));
JS

"$PYTHON_BIN" - \
  "$ELECTRON_DIR/Electron.app/Contents/Info.plist" \
  "$SOURCE_APP/Contents/Info.plist" \
  "$COMPAT_APP/Contents/Info.plist" <<'PY'
from __future__ import print_function
import sys
import plistlib

base_path, source_path, out_path = sys.argv[1:4]

def load_plist(path):
    if hasattr(plistlib, "load"):
        with open(path, "rb") as f:
            return plistlib.load(f)
    return plistlib.readPlist(path)

def save_plist(data, path):
    if hasattr(plistlib, "dump"):
        with open(path, "wb") as f:
            plistlib.dump(data, f)
    else:
        plistlib.writePlist(data, path)

base = load_plist(base_path)
source = load_plist(source_path)

copy_keys = (
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
    "NSUserNotificationAlertStyle",
    "ASWebAuthenticationSessionWebBrowserSupportCapabilities",
)
for key in copy_keys:
    if key in source:
        base[key] = source[key]

for key, value in source.items():
    if key.startswith("NS") and key.endswith("UsageDescription"):
        base[key] = value

base["CFBundleIdentifier"] = "com.openai.codex"
base["CFBundleName"] = "ChatGPT"
base["CFBundleDisplayName"] = "ChatGPT"
base["CFBundleExecutable"] = "Electron"
base["LSMinimumSystemVersion"] = "10.13"

# Do not let Sparkle replace the compatibility runtime with a macOS-13+
# Electron 42 build. Updates for this backport come through this installer.
for key in (
    "SUFeedURL",
    "SUPublicEDKey",
    "SUAutomaticallyUpdate",
    "SUEnableAutomaticChecks",
    "SUScheduledCheckInterval",
    "ElectronAsarIntegrity",
):
    base.pop(key, None)

save_plist(base, out_path)
PY

# Disable Sparkle preference checks for the compatibility bundle.
defaults write com.openai.codex SUEnableAutomaticChecks -bool false >/dev/null 2>&1 || true
defaults write com.openai.codex SUAutomaticallyUpdate -bool false >/dev/null 2>&1 || true

# Remove quarantine inherited from downloaded archives, then ad-hoc sign the
# locally assembled compatibility bundle.
xattr -dr com.apple.quarantine "$COMPAT_APP" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$COMPAT_APP"

# Verify the runtime really carries a High Sierra-compatible deployment target.
minos="$(otool -l "$COMPAT_APP/Contents/MacOS/Electron" | awk '
  /cmd LC_BUILD_VERSION/ { build=1; next }
  build && $1 == "minos" { print $2; exit }
  /cmd LC_VERSION_MIN_MACOSX/ { legacy=1; next }
  legacy && $1 == "version" { print $2; exit }
')"
case "$minos" in
  10.13|10.13.*|10.12|10.12.*|10.11|10.11.*|10.10|10.10.*|10.9|10.9.*) ;;
  *)
    echo "Compatibility runtime unexpectedly targets macOS $minos" >&2
    exit 1
    ;;
esac

if [[ -e "$DEST" ]]; then
  backup="$INSTALL_BASE/ChatGPT.backup.$(date +%Y%m%d-%H%M%S).app"
  echo "Backing up existing ChatGPT.app to: $backup"
  mv "$DEST" "$backup"
fi

ditto "$COMPAT_APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || true

# Verify the exact Codex CLI that ships inside the official OpenAI app package.
# Keep it private to ChatGPT.app so it stays protocol-matched to the current
# desktop payload. The standalone terminal `codex` command is installed from
# this fork by scripts/install-high-sierra.sh.
OFFICIAL_CODEX="$DEST/Contents/Resources/codex-cli/bin/codex"
if [[ ! -f "$DEST/Contents/Resources/original.asar" || ! -f "$DEST/Contents/Resources/app/main.cjs" ]]; then
  echo "High Sierra runtime bootstrap or preserved OpenAI app payload is missing." >&2
  exit 1
fi

if [[ ! -x "$OFFICIAL_CODEX" ]]; then
  echo "Official bundled Codex CLI was not found at: $OFFICIAL_CODEX" >&2
  exit 1
fi
codex_version="$("$OFFICIAL_CODEX" --version)"
"$OFFICIAL_CODEX" --help >/dev/null

echo
echo "Installed real OpenAI ChatGPT/Codex compatibility app:"
echo "  OpenAI version: $source_version ($source_build)"
echo "  Electron runtime: $ELECTRON_VERSION"
echo "  macOS target: $minos"
echo "  Bundle ID: com.openai.codex"
echo "  Path: $DEST"
echo "  Bundled Codex CLI: $codex_version"
if [[ "${CHATGPT_HIGH_SIERRA_NO_LAUNCH:-0}" == "1" ]]; then
  exit 0
fi

echo
echo "Launching ChatGPT..."
open "$DEST"
