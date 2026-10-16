#!/bin/bash
# Regenerates Resources/AppIcon.icns and Resources/AppIcon-Dev.icns from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift scripts/make-icon.swift "$WORK/AppIcon.iconset"
swift scripts/make-icon.swift "$WORK/AppIcon-Dev.iconset" --dev
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
iconutil -c icns "$WORK/AppIcon-Dev.iconset" -o Resources/AppIcon-Dev.icns
cp "$WORK/AppIcon.iconset/icon_512x512@2x.png" "${ICON_PREVIEW_DIR:-$WORK}/AppIcon.png" 2>/dev/null || true
cp "$WORK/AppIcon-Dev.iconset/icon_512x512@2x.png" "${ICON_PREVIEW_DIR:-$WORK}/AppIcon-Dev.png" 2>/dev/null || true
echo "Wrote Resources/AppIcon.icns and Resources/AppIcon-Dev.icns"
