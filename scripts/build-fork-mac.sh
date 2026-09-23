#!/bin/zsh
# Ferdium fork build: esbuild bundle + electron-builder dir target (unsigned) + manual Developer ID signing.
# Signing is done by hand because electron-builder's signing step can block on a keychain prompt in a
# non-interactive session. Run from the repo root.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
CERT="Developer ID Application: Antal Perity (Y2A9BT9TUZ)"
OUT="$REPO/out/mac-arm64/Ferdium.app"

echo "==> 1/4 esbuild bundle (build/)"
node esbuild.mjs

echo "==> 2/4 electron-builder dir target (unsigned, arm64)"
CSC_IDENTITY_AUTO_DISCOVERY=false \
  ./node_modules/.bin/electron-builder --mac dir --arm64 --publish never -c.mac.notarize=false

echo "==> 3/4 verify unsigned app exists"
test -d "$OUT" || { echo "MISSING: $OUT"; exit 1; }

echo "==> 4/4 sign nested Mach-O binaries and nested bundles, deepest path first, then the app"
# Order by path depth, not by a depth bound: an Electron bundle nests Helper .app
# bundles inside Framework version dirs inside the top-level Frameworks dir, and
# sealing any parent before its children invalidates the parent's own seal.
sign_one() {
  codesign --force --sign "$CERT" --options runtime --timestamp "$1" >/dev/null 2>&1 || \
    codesign --force --sign "$CERT" --options runtime "$1" >/dev/null 2>&1 || \
    { echo "FAILED to sign: $1"; exit 1; }
}

# 1) Loose Mach-O files (dylibs, .node native modules, executables).
find "$OUT/Contents" -type f -perm -u+x -print0 2>/dev/null |
  xargs -0 -n1 -I{} sh -c 'file -b "$1" | grep -q "Mach-O" && printf "%s\n" "$1"' _ {} |
  awk -F/ '{print NF" "$0}' | sort -rn | cut -d' ' -f2- |
  while IFS= read -r bin; do sign_one "$bin"; done

# 2) Nested bundles (.app helpers, .framework dirs) - deepest first.
find "$OUT/Contents" -maxdepth 4 \( -name "*.app" -o -name "*.framework" \) -print 2>/dev/null |
  awk -F/ '{print NF" "$0}' | sort -rn | cut -d' ' -f2- |
  while IFS= read -r bundle; do sign_one "$bundle"; done

# 3) The outer bundle, with hardened runtime and the app's entitlements.
codesign --force --sign "$CERT" --options runtime --timestamp \
  --entitlements build-helpers/entitlements.mas.plist "$OUT"

echo "==> signature check"
codesign --verify --deep --strict -v "$OUT" 2>&1 | tail -5
codesign -dv --verbose=2 "$OUT" 2>&1 | grep -E "Identifier=|TeamIdentifier=|Authority="
echo "BUILD_AND_SIGN_OK: $OUT"
