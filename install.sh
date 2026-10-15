#!/bin/bash
# One-step install: builds UsageBar from source, copies it to /Applications,
# and starts it. Re-run any time to update (after `git pull`).
set -euo pipefail

cd "$(dirname "$0")"

if ! xcrun --find swift >/dev/null 2>&1; then
    echo "Swift isn't installed yet. A window will pop up asking to install"
    echo "the Command Line Tools — click Install, wait for it to finish, then"
    echo "run ./install.sh again."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

bash Scripts/build_app.sh

# /Applications needs an admin account; otherwise use ~/Applications.
DEST_DIR=/Applications
if [[ ! -w "$DEST_DIR" ]]; then
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
APP="$DEST_DIR/UsageBar.app"

echo "==> installing to $DEST_DIR"
# Copy and verify the new app first; the old one is only replaced once the
# new one is known good.
rm -rf "$APP.new"
ditto build/UsageBar.app "$APP.new"
codesign --verify "$APP.new"
pkill -x UsageBar 2>/dev/null && sleep 1 || true
# Keep the old app until the new one is in place; put it back on failure.
rm -rf "$APP.old"
if [[ -e "$APP" ]]; then mv "$APP" "$APP.old"; fi
if ! mv "$APP.new" "$APP"; then
    [[ -e "$APP.old" ]] && mv "$APP.old" "$APP"
    echo "Couldn't install to $DEST_DIR; your previous UsageBar was left in place." >&2
    exit 1
fi
rm -rf "$APP.old" || true

# The compiler cache (~800 MB) is only needed to build; remove it. An update
# (git pull && ./install.sh) simply rebuilds.
rm -rf "$HOME/Library/Caches/UsageBar-build" || true

open "$APP"
echo
echo "Done! UsageBar is in your menu bar (top right). Click it, then Settings… to set it up."
