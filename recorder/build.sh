#!/bin/sh
# Builds recorder/build/OatcakeRecorder.app: a windowless app bundle, so macOS asks
# for microphone and system-audio permission for the recorder alone.
set -e
cd "$(dirname "$0")"
APP=build/OatcakeRecorder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/oatcake-recorder" OatcakeRecorder.swift
# Signed with the "Oatcake Release" certificate when it's in your keychain, so macOS keeps the
# recorder's permissions across rebuilds; otherwise ad-hoc, which macOS treats as a new app every
# build. OATCAKE_SIGN_IDENTITY and OATCAKE_SIGN_KEYCHAIN choose another identity.
IDENTITY="${OATCAKE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q '"Oatcake Release"'; then IDENTITY="Oatcake Release"; else IDENTITY=-; fi
fi
codesign --force --sign "$IDENTITY" ${OATCAKE_SIGN_KEYCHAIN:+--keychain "$OATCAKE_SIGN_KEYCHAIN"} "$APP"
echo "Built $APP"
