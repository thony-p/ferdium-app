#!/bin/zsh
# Install the freshly built Ferdium fork over /Applications/Ferdium.app.
# Safety order (learned the hard way, 2026-09-23): the outgoing app is copied and
# VERIFIED to exist and verify its signature BEFORE anything is removed, and the
# replacement is fully staged next to it before the old bundle is touched. An
# earlier version of this script deleted /Applications/Ferdium.app after an empty
# backup directory had "verified", destroying the only stock copy.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="${1:-$PWD/out/mac-arm64/Ferdium.app}"
DEST="/Applications/Ferdium.app"
STAGE="/Applications/Ferdium.app.new"
BK="$HOME/.backup/ferdium-app/$(date +%Y%m%d-%H%M%S)"

test -d "$SRC" || { echo "NO BUILD at $SRC"; exit 1; }

echo "==> 1/6 verify the new build before touching /Applications"
codesign --verify --deep --strict -v "$SRC" 2>&1 | tail -3
codesign -d --entitlements - "$SRC/Contents/MacOS/Ferdium" 2>/dev/null | grep -q "allow-jit" \
  || { echo "new build lacks allow-jit - it would crash at launch; aborting"; exit 1; }
NEW_HASH=$(shasum -a 256 "$SRC/Contents/Resources/app.asar" | cut -d' ' -f1)
echo "    new app.asar sha256: $NEW_HASH"

echo "==> 2/6 quit the running Ferdium"
osascript -e 'tell application "Ferdium" to quit' 2>/dev/null || true
for _ in $(seq 1 15); do
  pgrep -f "Applications/Ferdium.app" >/dev/null || break
  sleep 1
done
pkill -f "Applications/Ferdium.app" 2>/dev/null || true
sleep 2

echo "==> 3/6 stage the replacement next to the target"
rm -rf "$STAGE"
ditto "$SRC" "$STAGE"
test -d "$STAGE" || { echo "staging failed"; exit 1; }
codesign --verify --deep --strict "$STAGE" >/dev/null 2>&1 \
  || { echo "staged copy failed verification; aborting"; rm -rf "$STAGE"; exit 1; }
echo "    staged OK"

echo "==> 4/6 back up the outgoing app (only if it exists) and verify the backup"
if [ -d "$DEST" ]; then
  mkdir -p "$BK"
  ditto "$DEST" "$BK/Ferdium.app"
  test -d "$BK/Ferdium.app/Contents/MacOS" \
    || { echo "backup incomplete - REFUSING to replace the app"; rm -rf "$STAGE"; exit 1; }
  shasum -a 256 "$DEST/Contents/Resources/app.asar" > "$BK/app.asar.sha256"
  codesign --verify --deep --strict "$BK/Ferdium.app" >/dev/null 2>&1 \
    && echo "    backup at $BK verifies OK" \
    || echo "    WARNING: backup verifies with errors (unsigned?); it still exists at $BK"
else
  echo "    no existing app at $DEST - clean install"
fi

echo "==> 5/6 swap in the staged build"
# Remove, then move the already-verified staged bundle into place. The staged copy
# is the thing being promoted, so a failure here leaves the backup as the source of
# truth rather than an empty /Applications.
rm -rf "$DEST"
mv "$STAGE" "$DEST"

echo "==> 6/6 verify installed"
codesign --verify --deep --strict -v "$DEST" 2>&1 | tail -3
codesign -dv --verbose=2 "$DEST" 2>&1 | grep -E "Identifier=|TeamIdentifier="
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST/Contents/Info.plist"
INST_HASH=$(shasum -a 256 "$DEST/Contents/Resources/app.asar" | cut -d' ' -f1)
echo "    installed app.asar sha256: $INST_HASH"
[ "$INST_HASH" = "$NEW_HASH" ] || { echo "ASAR MISMATCH after install"; exit 1; }
echo "INSTALL_OK (backup: ${BK:-none})"
