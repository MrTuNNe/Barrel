#!/bin/zsh
# Builds build/Barrel.app (ad-hoc signed) from the Swift package and the CLI.
set -euo pipefail
cd "${0:A:h}"

# The release workflow passes VERSION; local builds take it from the newest vX.Y.Z tag.
VERSION=${VERSION:-$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//')}
VERSION=${VERSION:-0.0.0}
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
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Windows program</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Default</string>
    <key>LSItemContentTypes</key>
    <array>
      <string>com.microsoft.windows-executable</string>
      <string>com.microsoft.msi-installer</string>
      <string>com.microsoft.bat</string>
      <string>com.microsoft.windows-shortcut</string>
      <string>com.microsoft.windows-cmd</string>
    </array>
  </dict></array>
  <!-- macOS has no types for .lnk and .cmd; describe them so Barrel can open them. -->
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.microsoft.windows-shortcut</string>
      <key>UTTypeDescription</key><string>Windows shortcut</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>lnk</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.microsoft.windows-cmd</string>
      <key>UTTypeDescription</key><string>Windows command script</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>cmd</string></array></dict>
    </dict>
  </array>
</dict></plist>
EOF
codesign --force --deep -s - "$app"
echo "Built $app"
