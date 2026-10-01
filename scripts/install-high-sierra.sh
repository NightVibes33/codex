#!/bin/sh
set -eu

REPO="NightVibes33/codex"
TAG="high-sierra-latest"
ASSET="codex-high-sierra-x86_64.tar.gz"
BASE_URL="https://github.com/$REPO/releases/download/$TAG"
ROOT="${CODEX_HIGH_SIERRA_HOME:-$HOME/.codex-high-sierra}"
BIN_DIR="$HOME/.local/bin"

if [ "$(uname -m)" != "x86_64" ]; then
  echo "This backport is for Intel x86_64 Macs." >&2
  exit 1
fi

VERSION="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
MAJOR="$(printf '%s' "$VERSION" | awk -F. '{print $1}')"
MINOR="$(printf '%s' "$VERSION" | awk -F. '{print $2}')"
if [ "$MAJOR" = "10" ] && [ "${MINOR:-0}" -lt 13 ]; then
  echo "macOS $VERSION is older than the 10.13 deployment target." >&2
  exit 1
fi

TMP="$(mktemp -d -t codex-high-sierra.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

curl -fL "$BASE_URL/$ASSET" -o "$TMP/$ASSET"
curl -fL "$BASE_URL/SHA256SUMS" -o "$TMP/SHA256SUMS"

EXPECTED="$(awk -v asset="$ASSET" '$2 == asset || $2 == "*" asset { print $1; exit }' "$TMP/SHA256SUMS")"
ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "Checksum verification failed." >&2
  exit 1
fi

tar -xzf "$TMP/$ASSET" -C "$TMP"
PACKAGE="$TMP/codex-high-sierra-x86_64"
"$PACKAGE/bin/codex" --version >/dev/null
"$PACKAGE/codex-path/rg" --version >/dev/null

mkdir -p "$ROOT/releases" "$BIN_DIR"
RELEASE="$ROOT/releases/$ACTUAL"
rm -rf "$RELEASE"
mv "$PACKAGE" "$RELEASE"

rm -f "$ROOT/current.new"
ln -s "$RELEASE" "$ROOT/current.new"
mv -f "$ROOT/current.new" "$ROOT/current"
ln -sfn "$ROOT/current/bin/codex" "$BIN_DIR/codex"

PROFILE="$HOME/.bash_profile"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if [ ! -f "$PROFILE" ] || ! grep -F "$PATH_LINE" "$PROFILE" >/dev/null 2>&1; then
  printf '\n%s\n' "$PATH_LINE" >> "$PROFILE"
fi

echo "Installed Codex High Sierra backport."
echo "Binary: $BIN_DIR/codex"
echo "Run: export PATH=\"$HOME/.local/bin:$PATH\" && codex"
