#!/bin/zsh
# Install the freshly built Ferdium fork over /Applications/Ferdium.app, with a
# verified backup of the outgoing app first. Tony's rule: never chain the delete
# into the same command as the copy, and verify the backup before removing anything.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="$PWD/out/mac-arm64/Ferdium.app"
DEST="/Applications/Ferdium.app"
BK="$HOME/.backup/ferdium-app/$(date +%Y%m%d-%H%M%S)"

test -d "$SRC" || { echo "NO BUILD at $SRC"; exit 1; }

echo "==> verifying the new build's signature before touching /Applications"
codesign --verify --deep --strict -v "$SRC" 2>&1 | tail -3

echo "==> backing up the outgoing app to $BK"
mkdir -p "$BK"
ditto "$DEST" "$BK/Ferdium.app"
codesign --verify --deep --strict "$BK/Ferdium.app" >/dev/null 2>&1 \
  && echo "backup verifies OK" \
  || { echo "BACKUP DOES NOT VERIFY — aborting, nothing removed"; exit 1; }

echo "==> quitting the running Ferdium"
osascript -e 'tell application "Ferdium" to quit' 2>/dev/null || true
for _ in $(seq 1 15); do
  pgrep -f "Applications/Ferdium.app" >/dev/null || break
  sleep 1
done
pgrep -f "Applications/Ferdium.app" >/dev/null && pkill -f "Applications/Ferdium.app" && sleep 2

echo "==> swapping in the fork build (ditto, not cp -R: preserves codesign fidelity)"
rm -rf /Applications/Ferdium.app.new
ditto "$SRC" /Applications/Ferdium.app.new
rm -rf /Applications/Ferdium.app
mv /Applications/Ferdium.app.new /Applications/Ferdium.app

echo "==> verify installed"
codesign --verify --deep --strict -v "$DEST" 2>&1 | tail -3
codesign -dv --verbose=2 "$DEST" 2>&1 | grep -E "Identifier=|TeamIdentifier="
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST/Contents/Info.plist"

echo "==> installed asar must be byte-identical to the built one"
shasum -a 256 "$DEST/Contents/Resources/app.asar" "$SRC/Contents/Resources/app.asar"

echo "INSTALL_OK"
