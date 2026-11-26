#!/bin/bash
# Builds the app into ./build without Xcode.
#   scripts/bundle.sh            # release → build/MailMateJ.app
#   scripts/bundle.sh debug      # debug   → build/MailMateJ Dev.app (own bundle id, data folder and icon)
#   MMJ_VERSION=1.2.0 scripts/bundle.sh   # stamps that version (the release workflow passes the tag;
#                                         # without it, the latest v-tag's)
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
if [ "$CONFIG" = "release" ]; then
  # Drops the debug map (the paths of the object files in .build; the debug info itself stays there),
  # 2.4 MB of it; function names stay, so crash reports still name them. The linker's signature goes
  # first, as stripping breaks it (the app is signed below).
  codesign --remove-signature "$APP/Contents/MacOS/MailMateJ"
  strip -S "$APP/Contents/MacOS/MailMateJ"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleName $NAME" -c "Set :CFBundleDisplayName $NAME" -c "Set :CFBundleIdentifier $BUNDLE_ID" \
  "$APP/Contents/Info.plist"
# MMJ_VERSION (e.g. from a release tag, "1.2.0") stamps the version, else the latest v-tag does; the
# build number counts commits, so builds after a tag still tell apart.
VERSION="${MMJ_VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)}"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"
# The commit it's built from, shown in About ("+": with changes not yet committed).
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || true)"
if [ -n "$COMMIT" ]; then
  git diff --quiet HEAD -- 2>/dev/null || COMMIT="$COMMIT+"
  /usr/libexec/PlistBuddy -c "Add :MMJCommit string $COMMIT" "$APP/Contents/Info.plist"
fi
# Where Check for Update looks: the public GitHub repository ("owner/name") the release workflow publishes
# releases to (this one is private): MMJ_UPDATE_REPOSITORY, else this one's name with "-releases" (from
# GITHUB_REPOSITORY in the workflow, else this checkout's origin).
SOURCE="${GITHUB_REPOSITORY:-$(git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#.*[:/]([^/:]+/[^/:]+)$#\1#' || true)}"
REPOSITORY="${MMJ_UPDATE_REPOSITORY:-${SOURCE:+$SOURCE-releases}}"
if [ -n "$REPOSITORY" ]; then
  /usr/libexec/PlistBuddy -c "Add :MMJUpdateRepository string $REPOSITORY" "$APP/Contents/Info.plist"
fi
# The Google OAuth client for Gmail accounts: the JSON file Google Cloud downloads for a "Desktop app"
# client, at google-oauth-client.json (not in git) or MMJ_GOOGLE_OAUTH_JSON. Without it, adding a Gmail
# account says so.
GOOGLE_JSON="${MMJ_GOOGLE_OAUTH_JSON:-google-oauth-client.json}"
if [ -f "$GOOGLE_JSON" ]; then
  GOOGLE_ID="$(plutil -extract installed.client_id raw -o - "$GOOGLE_JSON" 2>/dev/null || true)"
  GOOGLE_SECRET="$(plutil -extract installed.client_secret raw -o - "$GOOGLE_JSON" 2>/dev/null || true)"
  if [ -n "$GOOGLE_ID" ]; then
    /usr/libexec/PlistBuddy -c "Add :MMJGoogleClientID string $GOOGLE_ID" \
      -c "Add :MMJGoogleClientSecret string $GOOGLE_SECRET" "$APP/Contents/Info.plist"
  else
    echo "warning: $GOOGLE_JSON has no installed.client_id (is it a Desktop app client?)" >&2
  fi
fi
cp "Resources/$ICON.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Licenses "$APP/Contents/Resources/"  # the open-source libraries' notices (linked from About)
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
