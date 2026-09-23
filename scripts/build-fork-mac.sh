#!/bin/zsh
# Ferdium fork build: esbuild bundle + electron-builder dir target (unsigned) + manual Developer ID signing.
# Signing is done by hand because electron-builder's signing step can block on a keychain prompt in a
# non-interactive session. Run from the repo root.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
CERT="Developer ID Application: Antal Perity (Y2A9BT9TUZ)"
OUT="$REPO/out/mac-arm64/Ferdium.app"
# Same entitlements electron-builder applies (mac.entitlements) - note it uses the
# "mas" plists even for the non-MAS build, so these are the right ones.
ENT_APP="$REPO/build-helpers/entitlements.mas.plist"
ENT_INHERIT="$REPO/build-helpers/entitlements.mas.inherit.plist"

echo "==> 1/5 esbuild bundle (build/)"
node esbuild.mjs

echo "==> 2/5 electron-builder dir target (unsigned, arm64)"
CSC_IDENTITY_AUTO_DISCOVERY=false \
  ./node_modules/.bin/electron-builder --mac dir --arm64 --publish never -c.mac.notarize=false

echo "==> 3/5 verify unsigned app exists"
test -d "$OUT" || { echo "MISSING: $OUT"; exit 1; }

echo "==> 4/5 sign (nested components deepest-first, then the app)"
# NFS leaves stale .nfs* placeholders behind when a file is unlinked while open;
# they land inside the bundle and break the code seal.
find "$OUT" -name ".nfs*" -delete 2>/dev/null || true

# Order by path depth and seal every nested component BEFORE its parent.
# Entitlements are mandatory on the nested binaries too: V8 needs
# com.apple.security.cs.allow-jit, and a nested binary signed without it makes the
# main process fail with SIGTRAP in v8::Isolate::Initialize (blank window / instant
# crash). Verified failure mode, 2026-09-23.
sign_bin() {
  codesign --force --sign "$CERT" --options runtime --timestamp \
    --entitlements "$ENT_INHERIT" "$1" >/dev/null 2>&1 || \
  codesign --force --sign "$CERT" --options runtime --entitlements "$ENT_INHERIT" "$1" >/dev/null 2>&1 || \
    { echo "FAILED to sign binary: $1"; exit 1; }
}
sign_bundle() {
  codesign --force --sign "$CERT" --options runtime --timestamp \
    --entitlements "$ENT_INHERIT" "$1" >/dev/null 2>&1 || \
  codesign --force --sign "$CERT" --options runtime --entitlements "$ENT_INHERIT" "$1" >/dev/null 2>&1 || \
    { echo "FAILED to sign bundle: $1"; exit 1; }
}

# 1) Loose Mach-O files (dylibs, .node native modules, executables), deepest first.
find "$OUT/Contents" -type f -perm -u+x -print0 2>/dev/null |
  xargs -0 -n1 -I{} sh -c 'file -b "$1" | grep -q "Mach-O" && printf "%s\n" "$1"' _ {} 2>/dev/null |
  awk -F/ '{print NF" "$0}' | sort -rn | cut -d' ' -f2- |
  while IFS= read -r bin; do sign_bin "$bin"; done

# 2) Nested bundles (.app helpers, .framework dirs), deepest first.
find "$OUT/Contents/Frameworks" -maxdepth 3 \( -name "*.app" -o -name "*.framework" \) -print 2>/dev/null |
  awk -F/ '{print NF" "$0}' | sort -rn | cut -d' ' -f2- |
  while IFS= read -r bundle; do sign_bundle "$bundle"; done

# 3) The outer bundle, with the app entitlements.
codesign --force --sign "$CERT" --options runtime --timestamp \
  --entitlements "$ENT_APP" "$OUT"

echo "==> 5/5 verify"
codesign --verify --deep --strict -v "$OUT" 2>&1 | tail -5
codesign -dv --verbose=2 "$OUT" 2>&1 | grep -E "Identifier=|TeamIdentifier="
# allow-jit must be present on the main binary, or V8 SIGTRAPs at launch.
codesign -d --entitlements - "$OUT/Contents/MacOS/Ferdium" 2>/dev/null | grep -q "allow-jit" \
  && echo "entitlements: allow-jit present" \
  || { echo "MISSING allow-jit on main binary - the app will crash at launch"; exit 1; }
echo "BUILD_AND_SIGN_OK: $OUT"
