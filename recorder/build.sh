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
codesign --force --sign - "$APP"
echo "Built $APP"
