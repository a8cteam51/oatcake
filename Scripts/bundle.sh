#!/bin/bash
# Builds build/Oatcake.app: the app, with the recorder as its own app bundle inside it so macOS asks
# for microphone and system-audio permission for "OatcakeRecorder" alone.
#
#   Scripts/bundle.sh            release build
#   Scripts/bundle.sh debug      debug build
#
# Signed with the "Oatcake Release" certificate when it's in a keychain (OATCAKE_SIGN_IDENTITY and
# OATCAKE_SIGN_KEYCHAIN choose another), otherwise ad-hoc. macOS ties the recorder's permissions and
# Oatcake's Keychain items to that identity: an ad-hoc build is a new app to macOS every time, and
# only a release-signed copy can update itself. OATCAKE_REQUIRE_SIGNING=1 refuses to fall back to ad-hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$ROOT/build/Oatcake.app"
cd "$ROOT"

swift build -c "$CONFIG" --product Oatcake
swift build -c "$CONFIG" --product OatcakeRecorder
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Oatcake" "$APP/Contents/MacOS/Oatcake"
sed "s/VERSION/$VERSION/g" Resources/Oatcake-Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp assets/Oatcake.icns "$APP/Contents/Resources/Oatcake.icns"

RECORDER="$APP/Contents/Resources/OatcakeRecorder.app"
mkdir -p "$RECORDER/Contents/MacOS"
cp "$BIN/OatcakeRecorder" "$RECORDER/Contents/MacOS/oatcake-recorder"
sed "s/VERSION/$VERSION/g" Resources/OatcakeRecorder-Info.plist > "$RECORDER/Contents/Info.plist"

IDENTITY="${OATCAKE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q '"Oatcake Release"'; then IDENTITY="Oatcake Release"; else IDENTITY=-; fi
fi
if [[ "$IDENTITY" == "-" && -n "${OATCAKE_REQUIRE_SIGNING:-}" ]]; then
    echo 'error: OATCAKE_REQUIRE_SIGNING is set, but no "Oatcake Release" signing identity was found.' >&2
    exit 1
fi
KEYCHAIN=()
if [[ -n "${OATCAKE_SIGN_KEYCHAIN:-}" ]]; then KEYCHAIN=(--keychain "$OATCAKE_SIGN_KEYCHAIN"); fi
# The recorder sits in Resources, where --deep doesn't reach, so it's signed on its own first.
codesign --force --sign "$IDENTITY" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} "$RECORDER"
codesign --force --sign "$IDENTITY" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} "$APP"
echo "Built $APP $VERSION, signed $([[ "$IDENTITY" == "-" ]] && echo ad-hoc || echo "with \"$IDENTITY\"")"
