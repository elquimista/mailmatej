#!/bin/bash
# Builds the app into ./build without Xcode.
#   scripts/bundle.sh            # release → build/MailMateJ.app
#   scripts/bundle.sh debug      # debug   → build/MailMateJ Dev.app (own bundle id, data folder and icon)
# Signing: uses the "MailMateJ Signing" certificate if it is in your keychain (see README), so
# keychain "Always Allow" survives rebuilds; otherwise ad-hoc. MMJ_SIGN_IDENTITY overrides the name.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if [ "$CONFIG" = "debug" ]; then
  NAME="MailMateJ Dev"; BUNDLE_ID="app.mailmatej.MailMateJ.dev"; ICON="AppIcon-Dev"
else
  NAME="MailMateJ"; BUNDLE_ID="app.mailmatej.MailMateJ"; ICON="AppIcon"
fi

swift build -c "$CONFIG" --product MailMateJ
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MailMateJ" "$APP/Contents/MacOS/MailMateJ"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleName $NAME" -c "Set :CFBundleDisplayName $NAME" -c "Set :CFBundleIdentifier $BUNDLE_ID" \
  "$APP/Contents/Info.plist"
cp "Resources/$ICON.icns" "$APP/Contents/Resources/AppIcon.icns"
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

IDENTITY="${MMJ_SIGN_IDENTITY:-MailMateJ Signing}"
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  [ -n "${MMJ_SIGN_IDENTITY:-}" ] && { echo "Signing identity \"$IDENTITY\" not found" >&2; exit 1; }
  IDENTITY="-"
fi
codesign --force --deep --sign "$IDENTITY" "$APP"
touch "$APP"  # Make Finder/Dock pick up icon changes.
if [ "$IDENTITY" = "-" ]; then
  echo "Built $APP ($CONFIG, ad-hoc signed: keychain will ask again after each rebuild; see README)"
else
  echo "Built $APP ($CONFIG, signed with \"$IDENTITY\")"
fi
