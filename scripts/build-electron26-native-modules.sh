#!/bin/bash
set -euo pipefail

ELECTRON_VERSION="${ELECTRON_VERSION:-26.6.10}"
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-10.13}"
OUT="${1:-$PWD/dist/electron26-native}"
TMP="$(mktemp -d -t codex-electron26-native.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export npm_config_arch=x64
export npm_config_platform=darwin

mkdir -p "$OUT" "$TMP/work"
cd "$TMP/work"

cat > package.json <<'JSON'
{
  "private": true,
  "dependencies": {
    "better-sqlite3": "12.11.1",
    "node-pty": "1.1.0"
  },
  "devDependencies": {
    "@electron/rebuild": "3.7.2"
  }
}
JSON

npm install --ignore-scripts --no-audit --no-fund
npx electron-rebuild --version "$ELECTRON_VERSION" --arch x64 --force   --module-dir "$TMP/work"   --which-module better-sqlite3   --which-module node-pty

mkdir -p "$OUT/better-sqlite3/build/Release" "$OUT/node-pty/build/Release"
cp node_modules/better-sqlite3/build/Release/better_sqlite3.node   "$OUT/better-sqlite3/build/Release/better_sqlite3.node"
cp node_modules/node-pty/build/Release/pty.node   "$OUT/node-pty/build/Release/pty.node"
cp node_modules/node-pty/build/Release/spawn-helper   "$OUT/node-pty/build/Release/spawn-helper"
chmod 0755 "$OUT/node-pty/build/Release/spawn-helper"

verify_minos() {
  local binary="$1"
  local minos
  minos="$(otool -l "$binary" | awk '
    /cmd LC_BUILD_VERSION/ { build=1; next }
    build && $1 == "minos" { print $2; exit }
    /cmd LC_VERSION_MIN_MACOSX/ { legacy=1; next }
    legacy && $1 == "version" { print $2; exit }
  ')"
  echo "$(basename "$binary"): macOS minimum ${minos:-unknown}"
  case "$minos" in
    10.13|10.13.*|10.12|10.12.*|10.11|10.11.*|10.10|10.10.*|10.9|10.9.*|10.8|10.8.*|10.7|10.7.*) ;;
    *) echo "error: incompatible deployment target for $binary: ${minos:-missing}" >&2; exit 1 ;;
  esac
}

verify_minos "$OUT/better-sqlite3/build/Release/better_sqlite3.node"
verify_minos "$OUT/node-pty/build/Release/pty.node"
verify_minos "$OUT/node-pty/build/Release/spawn-helper"

{
  echo "electron=$ELECTRON_VERSION"
  echo "target=x86_64-apple-darwin"
  echo "macos_min=$MIN_MACOS"
  shasum -a 256     "$OUT/better-sqlite3/build/Release/better_sqlite3.node"     "$OUT/node-pty/build/Release/pty.node"     "$OUT/node-pty/build/Release/spawn-helper"
} > "$OUT/BUILD-INFO.txt"

tar -C "$OUT" -czf "$OUT/electron26-native-darwin-x64.tar.gz"   better-sqlite3 node-pty BUILD-INFO.txt
shasum -a 256 "$OUT/electron26-native-darwin-x64.tar.gz" > "$OUT/SHA256SUMS"
