#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build -c release
APP="$PWD/build/Activity Agent.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ActivityAgent "$APP/Contents/MacOS/ActivityAgent"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.activityagent.monitor</string>
<key>CFBundleName</key><string>Activity Agent</string>
<key>CFBundleDisplayName</key><string>Activity Agent</string>
<key>CFBundleExecutable</key><string>ActivityAgent</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleIconFile</key><string>ActivityAgent</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>activityagent</string></array><key>CFBundleURLName</key><string>local.activityagent.monitor</string></dict></array>
</dict></plist>
PLIST
swift scripts/make-icon.swift
codesign --force --sign - "$APP"
echo "$APP"
