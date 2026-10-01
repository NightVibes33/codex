#!/usr/bin/env bash
set -euo pipefail

DMG_URL="${CHATGPT_X64_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/ChatGPT-latest-x64.dmg}"
OUT="${1:-$PWD/chatgpt-high-sierra-audit}"
TMP="$(mktemp -d -t chatgpt-high-sierra-audit.XXXXXX)"
MOUNT="$TMP/mount"
DMG="$TMP/ChatGPT-latest-x64.dmg"

cleanup() {
  if mount | grep -F "$MOUNT" >/dev/null 2>&1; then
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

rm -rf "$OUT"
mkdir -p "$OUT" "$MOUNT"

echo "Downloading official OpenAI Intel ChatGPT bundle:"
echo "$DMG_URL"
curl -fL --retry 4 --retry-delay 2 "$DMG_URL" -o "$DMG"

hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly >/dev/null
APP="$(find "$MOUNT" -maxdepth 2 -type d -name 'ChatGPT.app' -print -quit)"
if [[ -z "$APP" ]]; then
  echo "error: ChatGPT.app not found in official x64 DMG" >&2
  exit 1
fi

INFO="$APP/Contents/Info.plist"
RES="$APP/Contents/Resources"
MACOS="$APP/Contents/MacOS"
MAIN="$(find "$MACOS" -type f -perm +111 -maxdepth 1 -print -quit)"

{
  echo "# Official ChatGPT/Codex Intel bundle audit"
  echo
  echo "Source: $DMG_URL"
  echo "Audit date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## Bundle metadata"
  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion CFBundleExecutable SUFeedURL SUScheduledCheckInterval SUEnableAutomaticChecks; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO" 2>/dev/null || true)"
    printf '%s: %s\n' "$key" "$value"
  done

  echo
  echo "## Updater-related Info.plist keys"
  plutil -p "$INFO" | grep -Ei 'sparkle|feed|update|SU[A-Z]' || true
  echo
  echo "## Main executable"
  file "$MAIN"
  otool -L "$MAIN" || true
  echo
  echo "## Main executable load commands"
  otool -l "$MAIN" | awk '
    /cmd LC_BUILD_VERSION/ {show=1; print; next}
    /cmd LC_VERSION_MIN_MACOSX/ {show=1; print; next}
    show && /^(      cmd|  cmdsize)/ {show=0}
    show {print}
  ' || true
  echo
  echo "## Embedded runtime markers"
  if [[ -d "$APP/Contents/Frameworks" ]]; then
    find "$APP/Contents/Frameworks" -maxdepth 3 -name Info.plist -print | while read -r plist; do
      name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist" 2>/dev/null || basename "$(dirname "$plist")")"
      version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
      printf '%s: %s\n' "$name" "$version"
    done
  fi
  echo
  if [[ -x "$RES/codex" ]]; then
    echo "Bundled Codex:"
    file "$RES/codex"
    "$RES/codex" --version 2>&1 || true
    otool -l "$RES/codex" | awk '
      /cmd LC_BUILD_VERSION/ {show=1; print; next}
      /cmd LC_VERSION_MIN_MACOSX/ {show=1; print; next}
      show && /^(      cmd|  cmdsize)/ {show=0}
      show {print}
    ' || true
  fi
} > "$OUT/report.txt"

# Inventory every Mach-O in the official bundle and record its minimum macOS.
python3 - "$APP" "$OUT/macho-minos.tsv" <<'PY'
import os, subprocess, sys
app, out = sys.argv[1:3]
rows=[]
for root, dirs, files in os.walk(app):
    for name in files:
        p=os.path.join(root,name)
        try:
            ft=subprocess.check_output(["file",p], text=True, stderr=subprocess.DEVNULL)
        except Exception:
            continue
        if "Mach-O" not in ft:
            continue
        try:
            text=subprocess.check_output(["otool","-l",p], text=True, stderr=subprocess.DEVNULL)
        except Exception:
            text=""
        minos=""
        lines=text.splitlines()
        for i,line in enumerate(lines):
            s=line.strip()
            if s=="cmd LC_BUILD_VERSION":
                for j in range(i+1,min(i+10,len(lines))):
                    parts=lines[j].strip().split()
                    if parts and parts[0]=="minos" and len(parts)>1:
                        minos=parts[1]; break
            if s=="cmd LC_VERSION_MIN_MACOSX":
                for j in range(i+1,min(i+8,len(lines))):
                    parts=lines[j].strip().split()
                    if parts and parts[0]=="version" and len(parts)>1:
                        minos=parts[1]; break
            if minos:
                break
        rows.append((os.path.relpath(p,app),minos,ft.strip()))
with open(out,"w") as f:
    f.write("path\tmin_macos\tfile\n")
    for row in sorted(rows):
        f.write("\t".join(row)+"\n")
PY

# Extract real Electron/app metadata without modifying the official app.
if [[ -f "$RES/app.asar" ]]; then
  mkdir -p "$OUT/asar"
  npx --yes @electron/asar@3 extract-file "$RES/app.asar" package.json > "$OUT/asar/package.json" 2>/dev/null || true
fi

if [[ -f "$OUT/asar/package.json" ]]; then
  python3 - "$OUT/asar/package.json" "$OUT/report.txt" <<'PY'
import json, sys
p, report = sys.argv[1:3]
try:
    data=json.load(open(p))
except Exception:
    raise SystemExit
with open(report,"a") as f:
    f.write("\n## app.asar package metadata\n")
    for k in ("name","version","main"):
        f.write(f"{k}: {data.get(k)}\n")
    deps=data.get("dependencies") or {}
    for k in ("electron","better-sqlite3","@electron/remote"):
        if k in deps:
            f.write(f"{k}: {deps[k]}\n")
PY
fi

# List native Node addons and their architectures/minimum OS.
{
  echo -e "path\tfile"
  find "$APP" -type f -name '*.node' -print | while read -r node; do
    printf '%s\t%s\n' "${node#$APP/}" "$(file "$node")"
  done
} > "$OUT/native-node-modules.tsv"

# Summarize High Sierra blockers.
python3 - "$OUT/macho-minos.tsv" "$OUT/high-sierra-blockers.txt" <<'PY'
import csv, sys
src, out = sys.argv[1:3]
bad=[]
with open(src,newline="") as f:
    for r in csv.DictReader(f,delimiter="\t"):
        v=r["min_macos"].strip()
        if not v:
            continue
        try:
            parts=tuple(int(x) for x in v.split(".")[:2])
        except ValueError:
            continue
        if parts > (10,13):
            bad.append((r["path"],v))
with open(out,"w") as f:
    f.write(f"Mach-O files requiring newer than macOS 10.13: {len(bad)}\n")
    for p,v in bad:
        f.write(f"{v}\t{p}\n")
PY

cat "$OUT/report.txt"
echo
cat "$OUT/high-sierra-blockers.txt"
