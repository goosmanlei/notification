#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build --build-system native -c release --product Notification
mkdir -p build
swiftc Sources/NotificationApp/Artwork.swift scripts/render-icons.swift -o build/render-icons
build/render-icons build/artwork
iconutil -c icns build/artwork/Notification.iconset -o build/Notification.icns
app_dir="$project_dir/build/Notification.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/release/Notification "$app_dir/Contents/MacOS/Notification"
cp build/Notification.icns "$app_dir/Contents/Resources/Notification.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>me.leiguoguo.notification</string>
<key>CFBundleName</key><string>Notification</string>
<key>CFBundleDisplayName</key><string>Notification</string>
<key>CFBundleExecutable</key><string>Notification</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>Notification</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
