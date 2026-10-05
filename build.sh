#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="InstantReplay"
APP_BUNDLE="build/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Library/LaunchAgents"
cp "$BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/LaunchAgent.plist "$APP_BUNDLE/Contents/Library/LaunchAgents/com.yildiz.InstantReplay.agent.plist"

codesign --force --sign "$SIGN_IDENTITY" --identifier com.yildiz.InstantReplay "$APP_BUNDLE"

if [[ "${1:-}" == "install" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP_BUNDLE" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "Installed to /Applications/${APP_NAME}.app"
else
    echo "Built $APP_BUNDLE"
fi
