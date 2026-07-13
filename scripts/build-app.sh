#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${1:-release}"
BUILD_ROOT="$ROOT/build"
APP="$BUILD_ROOT/Desklog.app"
ENTITLEMENTS="$ROOT/Resources/Desklog.entitlements"

if (( ${+CODESIGN_IDENTITY} )); then
    if [[ -z "$CODESIGN_IDENTITY" ]]; then
        echo "error: CODESIGN_IDENTITY was provided but is empty." >&2
        exit 2
    fi
    SIGNING_IDENTITY="$CODESIGN_IDENTITY"
elif [[ "$CONFIGURATION" == "debug" ]]; then
    IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGNING_IDENTITY="$(
        print -r -- "$IDENTITY_LIST" |
            sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]+) "Apple Development:.*$/\1/p' |
            head -n 1
    )"
    if [[ -n "$SIGNING_IDENTITY" ]]; then
        echo "Using Apple Development signing identity $SIGNING_IDENTITY for the debug build." >&2
    else
        SIGNING_IDENTITY="-"
    fi
else
    SIGNING_IDENTITY="-"
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "warning: Falling back to ad-hoc signing." >&2
    echo "warning: macOS may ask for Microphone permission again after the app changes." >&2
    echo 'warning: Set CODESIGN_IDENTITY="Apple Development: Name (TEAMID)" to preserve privacy permissions across development builds.' >&2
fi

cd "$ROOT"
swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Desklog" "$APP/Contents/MacOS/Desklog"
cp "$BIN_DIR/DesklogSpeakerHelper" "$APP/Contents/MacOS/DesklogSpeakerHelper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign \
    --force \
    --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$APP/Contents/MacOS/DesklogSpeakerHelper"
codesign \
    --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$APP"
codesign --verify --deep --strict "$APP"

echo "$APP"
