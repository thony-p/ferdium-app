#!/bin/zsh
# Re-sign an already-built Ferdium fork .app in place (no rebuild).
# Use when only the signing step needs redoing - e.g. after fixing entitlements.
# Order matters: nested Mach-O files, then nested bundles, then the outer bundle,
# each with the inherit entitlements so V8 keeps its allow-jit grant.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
OUT="${1:-$REPO/out/mac-arm64/Ferdium.app}"
CERT="Developer ID Application: Antal Perity (Y2A9BT9TUZ)"
ENT_APP="$REPO/build-helpers/entitlements.mas.plist"
ENT_INHERIT="$REPO/build-helpers/entitlements.mas.inherit.plist"

test -d "$OUT" || { echo "no app at $OUT"; exit 1; }
find "$OUT" -name ".nfs*" -delete 2>/dev/null || true

sign_bin() {
  codesign --force --sign "$CERT" --options runtime --timestamp \
    --entitlements "$ENT_INHERIT" "$1" >/dev/null 2>&1 || \
  codesign --force --sign "$CERT" --options runtime --entitlements "$ENT_INHERIT" "$1" >/dev/null 2>&1 || \
    { echo "FAILED binary: $1"; exit 1; }
}
sign_bundle() {
  codesign --force --sign "$CERT" --options runtime --timestamp \
    --entitlements "$ENT_INHERIT" "$1" >/dev/null 2>&1 || \
  codesign --force --sign "$CERT" --options runtime --entitlements "$ENT_INHERIT" "$1" >/dev/null 2>&1 || \
    { echo "FAILED bundle: $1"; exit 1; }
}

echo "==> loose Mach-O binaries (deepest first)"
find "$OUT/Contents" -type f -perm -u+x -print0 2>/dev/null |
  xargs -0 -n1 -I{} sh -c 'file -b "$1" | grep -q "Mach-O" && printf "%s\n" "$1"' _ {} 2>/dev/null |
  awk -F/ '{print NF" "$0}' | sort -rn | cut -d' ' -f2- |
  while IFS= read -r bin; do sign_bin "$bin"; done

echo "==> nested bundles (deepest first)"
find "$OUT/Contents/Frameworks" -maxdepth 3 \( -name "*.app" -o -name "*.framework" \) -print 2>/dev/null |
  awk -F/ '{print NF" "$0}' | sort -rn | cut -d' ' -f2- |
  while IFS= read -r bundle; do sign_bundle "$bundle"; done

echo "==> outer bundle"
codesign --force --sign "$CERT" --options runtime --timestamp --entitlements "$ENT_APP" "$OUT"

echo "==> verify"
codesign --verify --deep --strict -v "$OUT" 2>&1 | tail -3
codesign -d --entitlements - "$OUT/Contents/MacOS/Ferdium" 2>/dev/null | grep -q "allow-jit" \
  && echo "allow-jit: present" \
  || { echo "allow-jit MISSING - app will crash at launch"; exit 1; }
codesign -d --entitlements - "$OUT/Contents/Frameworks/Ferdium Helper.app" 2>/dev/null | grep -q "allow-jit" \
  && echo "helper allow-jit: present" \
  || { echo "helper allow-jit MISSING"; exit 1; }
echo "RESIGN_OK: $OUT"
