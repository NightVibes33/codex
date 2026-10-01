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

echo "Finding the latest official OpenAI Intel ChatGPT build..."
curl -fsSL --retry 4 --retry-delay 2 \
  -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/605.1.15 Safari/605.1.15" \
  "$APPCAST_URL" -o "$TMP/appcast.xml"

SOURCE_URL="$(/usr/bin/python - "$TMP/appcast.xml" <<'PY'
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
curl -fL --retry 4 --retry-delay 2 \
  "https://github.com/electron/electron/releases/download/v$ELECTRON_VERSION/electron-v$ELECTRON_VERSION-darwin-x64.zip" \
  -o "$TMP/Electron.zip"
ditto -x -k "$TMP/Electron.zip" "$ELECTRON_DIR"

if [[ ! -d "$ELECTRON_DIR/Electron.app" ]]; then
  echo "Electron.app was not found in the Electron release archive." >&2
  exit 1
fi

# Electron 26 supplies the High-Sierra-compatible Chromium/runtime/framework and
# helper layout. OpenAI supplies the real ChatGPT/Codex application payload.
ditto "$ELECTRON_DIR/Electron.app" "$COMPAT_APP"
ditto "$SOURCE_APP/Contents/Resources" "$COMPAT_APP/Contents/Resources"

/usr/bin/python - \
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

# Expose the exact Codex CLI that ships inside the official OpenAI app package.
# Its x86_64 native Codex binary, code-mode host, and rg are linked with a
# macOS 10.12 deployment target, so High Sierra 10.13 is above their Mach-O floor.
OFFICIAL_CODEX="$DEST/Contents/Resources/codex-cli/bin/codex"
if [[ ! -x "$OFFICIAL_CODEX" ]]; then
  echo "Official bundled Codex CLI was not found at: $OFFICIAL_CODEX" >&2
  exit 1
fi

LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
ln -sfn "$OFFICIAL_CODEX" "$LOCAL_BIN/codex"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
for profile in "$HOME/.bash_profile" "$HOME/.profile"; do
  if [[ ! -f "$profile" ]] || ! grep -F "$PATH_LINE" "$profile" >/dev/null 2>&1; then
    printf '\n%s\n' "$PATH_LINE" >> "$profile"
  fi
done

# Verify the real packaged CLI itself starts before calling the install complete.
codex_version="$("$OFFICIAL_CODEX" --version)"
"$OFFICIAL_CODEX" --help >/dev/null

echo
echo "Installed real OpenAI ChatGPT/Codex compatibility app:"
echo "  OpenAI version: $source_version ($source_build)"
echo "  Electron runtime: $ELECTRON_VERSION"
echo "  macOS target: $minos"
echo "  Bundle ID: com.openai.codex"
echo "  Path: $DEST"
echo "  Codex CLI: $codex_version"
echo "  Codex command: $LOCAL_BIN/codex"
if [[ "${CHATGPT_HIGH_SIERRA_NO_LAUNCH:-0}" == "1" ]]; then
  exit 0
fi

if [[ "${CHATGPT_HIGH_SIERRA_NO_LAUNCH:-0}" != "1" ]]; then
  echo
  echo "Launching ChatGPT..."
  open "$DEST"
fi
