#!/bin/zsh
# Builds ClaudeUsage.app (menu-bar only, no Dock icon).
set -e
cd "$(dirname "$0")"
APP=ClaudeUsage.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O main.swift MenuBarArt.swift -o $APP/Contents/MacOS/ClaudeUsage
# App icon (generated from the pixel mascot)
ICONSET=$(mktemp -d)/ClaudeUsage.iconset
swiftc -O makeicon.swift -o "$(dirname "$ICONSET")/makeicon"
"$(dirname "$ICONSET")/makeicon" "$ICONSET"
iconutil -c icns "$ICONSET" -o $APP/Contents/Resources/ClaudeUsage.icns
cp "$ICONSET/icon_512x512@2x.png" preview-icon.png
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>ClaudeUsage</string>
<key>CFBundleExecutable</key><string>ClaudeUsage</string>
<key>CFBundleIdentifier</key><string>local.claude-usage</string>
<key>CFBundleName</key><string>ClaudeUsage</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1.0.1</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF
codesign --force --sign - $APP
echo "Built $APP"
