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

echo "==> installing to /Applications"
pkill -x UsageBar 2>/dev/null && sleep 1 || true
rm -rf /Applications/UsageBar.app
ditto build/UsageBar.app /Applications/UsageBar.app

open /Applications/UsageBar.app
echo
echo "Done! UsageBar is in your menu bar (top right). Click it, then Settings… to set it up."
