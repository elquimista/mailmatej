#!/bin/bash
# Builds and launches "MailMateJ Dev" against the local Stalwart (dev/stalwart).
# Its data lives in ~/Library/Application Support/MailMateJ Dev, separate from the release app.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh debug
scripts/bundle.sh   # Keep the release app in step with every Dev build.
pkill -f "MailMateJ Dev.app/Contents/MacOS/MailMateJ" 2>/dev/null || true
MMJ_DEV_ACCOUNTS="${MMJ_DEV_ACCOUNTS:-alice,bob,carol}" "build/MailMateJ Dev.app/Contents/MacOS/MailMateJ" >/dev/null 2>&1 &
