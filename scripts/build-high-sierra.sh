#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="x86_64-apple-darwin"
MIN_MACOS="10.13"
OUT="${1:-$ROOT/dist/high-sierra}"
WORK="${RUNNER_TEMP:-/tmp}/codex-high-sierra-build"

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS="-C link-arg=-mmacosx-version-min=$MIN_MACOS"

rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK"

cd "$ROOT/codex-rs"
cargo build --locked --release --target "$TARGET" -p codex-cli --bin codex
cargo build --locked --release --target "$TARGET" -p codex-code-mode-host --bin codex-code-mode-host

RG_ROOT="$WORK/rg-root"
cargo install ripgrep --version 14.1.1 --locked --root "$RG_ROOT" --target "$TARGET"

PACKAGE="$OUT/codex-high-sierra-x86_64"
mkdir -p "$PACKAGE/bin" "$PACKAGE/codex-path"
cp "target/$TARGET/release/codex" "$PACKAGE/bin/codex"
cp "target/$TARGET/release/codex-code-mode-host" "$PACKAGE/bin/codex-code-mode-host"
cp "$RG_ROOT/bin/rg" "$PACKAGE/codex-path/rg"
chmod 0755 "$PACKAGE/bin/codex" "$PACKAGE/bin/codex-code-mode-host" "$PACKAGE/codex-path/rg"

VERSION="$(awk -F'"' '/^version = / { print $2; exit }' Cargo.toml)"
cat > "$PACKAGE/codex-package.json" <<EOF
{
  "layoutVersion": 1,
  "version": "$VERSION",
  "target": "$TARGET",
  "variant": "codex",
  "entrypoint": "bin/codex",
  "resourcesDir": "codex-resources",
  "pathDir": "codex-path"
}
EOF

verify_minos() {
  local binary="$1"
  local minos
  minos="$(otool -l "$binary" | awk '
    /cmd LC_BUILD_VERSION/ { build=1; next }
    build && $1 == "minos" { print $2; exit }
    /cmd LC_VERSION_MIN_MACOSX/ { legacy=1; next }
    legacy && $1 == "version" { print $2; exit }
  ')"
  echo "$(basename "$binary"): macOS minimum $minos"
  case "$minos" in
    10.13|10.13.*) ;;
    *)
      echo "error: $(basename "$binary") is not linked for macOS 10.13 (got $minos)" >&2
      exit 1
      ;;
  esac
}

verify_minos "$PACKAGE/bin/codex"
verify_minos "$PACKAGE/bin/codex-code-mode-host"
verify_minos "$PACKAGE/codex-path/rg"

"$PACKAGE/bin/codex" --version
"$PACKAGE/bin/codex" --help >/dev/null
"$PACKAGE/codex-path/rg" --version

ARCHIVE="$OUT/codex-high-sierra-x86_64.tar.gz"
tar -C "$OUT" -czf "$ARCHIVE" "$(basename "$PACKAGE")"
(
  cd "$OUT"
  shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS
)

echo "Built $ARCHIVE"
