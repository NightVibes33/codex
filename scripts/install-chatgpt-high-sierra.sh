#!/bin/bash
set -euo pipefail

APPCAST_URL="${CHATGPT_X64_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml}"
ELECTRON_VERSION="${CHATGPT_HIGH_SIERRA_ELECTRON_VERSION:-26.6.10}"
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
rm -rf "$RES/app"
mkdir -p "$RES/app"
cat > "$RES/app/package.json" <<'JSON'
{
  "name": "openai-codex-high-sierra-runtime-compat",
  "version": "1.0.0",
  "main": "main.cjs"
}
JSON
cat > "$RES/app/main.cjs" <<'JS'
"use strict";

const path = require("node:path");
const { app } = require("electron");

const originalApp = path.join(process.resourcesPath, "original.asar");

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
  const originalCatch = Promise.prototype.catch;
  Promise.prototype.catch = function (handler) {
    if (typeof handler !== "function") return originalCatch.call(this, handler);
    return originalCatch.call(this, (error) => {
      try {
        console.error("[high-sierra-compat] caught", error && (error.stack || error));
      } catch {}
      return handler(error);
    });
  };
  process.on("uncaughtException", (error) => {
    console.error("[high-sierra-compat] uncaught", error && (error.stack || error));
    throw error;
  });
  process.on("unhandledRejection", (error) => {
    console.error("[high-sierra-compat] unhandled", error && (error.stack || error));
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
