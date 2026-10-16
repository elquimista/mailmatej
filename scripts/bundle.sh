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

# Signing identity, best first:
#   1. MMJ_SIGN_IDENTITY if set (name or SHA-1 hash).
#   2. An "Apple Development" certificate (free Apple ID in Xcode): has a Team ID, so keychain access
#      survives rebuilds with no prompt.
#   3. The self-signed "MailMateJ Signing" certificate: stable, but the keychain asks once per build.
#   4. Ad hoc.
if [ -n "${MMJ_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$MMJ_SIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')"
  if [ -z "$IDENTITY" ] && security find-identity -p codesigning | grep -q '"MailMateJ Signing"'; then
    IDENTITY="MailMateJ Signing"
  fi
  IDENTITY="${IDENTITY:--}"
fi
codesign --force --deep --sign "$IDENTITY" "$APP"
touch "$APP"  # Make Finder/Dock pick up icon changes.
TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
AUTHORITY="$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [ "$IDENTITY" = "-" ]; then
  echo "Built $APP ($CONFIG, ad-hoc signed: keychain will ask again after each rebuild; see README)"
elif [ "$TEAM" != "not set" ] && [ -n "$TEAM" ]; then
  echo "Built $APP ($CONFIG, signed by \"$AUTHORITY\", Team ID $TEAM)"
else
  echo "Built $APP ($CONFIG, signed with \"${AUTHORITY:-$IDENTITY}\", no Team ID: keychain asks once per build)"
fi
