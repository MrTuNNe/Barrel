#!/bin/zsh
# Builds build/Barrel.app (ad-hoc signed) from the Swift package and the CLI.
set -euo pipefail
cd "${0:A:h}"

VERSION=${VERSION:-0.1.0}
swift build -c release --package-path app --arch arm64 --arch x86_64

app=build/Barrel.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp app/.build/apple/Products/Release/Barrel "$app/Contents/MacOS/Barrel"
cp cli/barrel "$app/Contents/Resources/barrel"
cp branding/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Barrel</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>app.barrel.Barrel</string>
  <key>CFBundleName</key><string>Barrel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --deep -s - "$app"
echo "Built $app"
