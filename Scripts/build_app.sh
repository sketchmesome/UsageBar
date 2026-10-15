#!/bin/bash
# Builds UsageBar in release mode, assembles build/UsageBar.app and ad-hoc
# signs it. ZIP=1 also writes ~/Downloads/UsageBar.zip (for a release);
# UNIVERSAL=1 adds an Intel slice.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Compiler output lives in ~/Library/Caches (purgeable, never synced), not in
# the project folder, which may sit in an iCloud-synced Documents folder.
SCRATCH="${USAGEBAR_BUILD_DIR:-$HOME/Library/Caches/UsageBar-build}"

# Every temp folder this script makes is removed on exit, success or not.
TEMP_DIRS=()
cleanup() { for dir in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do rm -rf "$dir"; done; }
trap cleanup EXIT

# UNIVERSAL=1 builds Apple silicon and Intel explicitly (whatever this Mac is)
# and merges them into one binary, for release downloads. A plain build is
# native-only, which is all install.sh needs.
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    SLICES=()
    for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
        echo "==> swift build -c release ($triple)"
        swift build -c release --scratch-path "$SCRATCH" --triple "$triple"
        SLICES+=("$(swift build -c release --scratch-path "$SCRATCH" --triple "$triple" --show-bin-path)/UsageBar")
    done
    UNI_DIR="$(mktemp -d "${TMPDIR:-/tmp}/usagebar-universal.XXXXXX")"
    TEMP_DIRS+=("$UNI_DIR")
    lipo -create "${SLICES[@]}" -output "$UNI_DIR/UsageBar"
    BIN="$UNI_DIR/UsageBar"
else
    echo "==> swift build -c release"
    swift build -c release --scratch-path "$SCRATCH"
    BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/UsageBar"
fi
if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

# Assemble and sign in a staging directory outside the repo. The repo lives in a
# FileProvider-synced folder, where Finder re-adds com.apple.FinderInfo to a
# freshly created .app directory; codesign refuses that detritus. Staging in a
# temp dir keeps signing deterministic, then we copy the signed bundle back.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/usagebar-stage.XXXXXX")"
TEMP_DIRS+=("$STAGE")

STAGED_APP="$STAGE/UsageBar.app"
echo "==> assembling $STAGED_APP"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

cp "$BIN" "$STAGED_APP/Contents/MacOS/UsageBar"
chmod +x "$STAGED_APP/Contents/MacOS/UsageBar"

# Bundle the service logos (SPEC §15); they are shipped, never downloaded.
if compgen -G "$ROOT/Resources/Logos/*.png" > /dev/null; then
    echo "==> copying logos"
    cp "$ROOT"/Resources/Logos/*.png "$STAGED_APP/Contents/Resources/"
fi

cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>UsageBar</string>
    <key>CFBundleDisplayName</key>
    <string>UsageBar</string>
    <key>CFBundleExecutable</key>
    <string>UsageBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.lanes.usagebar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesigning"
xattr -cr "$STAGED_APP" 2>/dev/null || true
codesign --force -s - "$STAGED_APP"
codesign --verify --verbose=1 "$STAGED_APP"

APP="$ROOT/build/UsageBar.app"
echo "==> installing $APP"
rm -rf "$APP"
mkdir -p "$ROOT/build"
# --norsrc/--noextattr keep the FileProvider-synced destination from gaining
# AppleDouble `._*` siblings of every file.
ditto --norsrc --noextattr "$STAGED_APP" "$APP"
dot_clean "$APP" 2>/dev/null || true

if [[ "${ZIP:-0}" == 1 ]]; then
    DEST="$HOME/Downloads/UsageBar.zip"
    echo "==> zipping to $DEST"
    mkdir -p "$HOME/Downloads"
    rm -f "$DEST"
    # Zip the clean, signed staging copy so the archive carries no detritus.
    ditto -c -k --keepParent --norsrc "$STAGED_APP" "$DEST"
    echo "==> zip:  $DEST"
fi

echo "==> done: $APP"
