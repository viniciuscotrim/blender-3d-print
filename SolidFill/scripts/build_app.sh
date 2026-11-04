#!/bin/zsh
# Compila o SolidFill e monta SolidFill.app (assinatura ad-hoc) ao lado deste repositório.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP="SolidFill.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SolidFillApp" "$APP/Contents/MacOS/SolidFill"
cp "$BIN/solidfill" "$APP/Contents/Resources/solidfill"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SolidFill</string>
  <key>CFBundleDisplayName</key><string>SolidFill</string>
  <key>CFBundleIdentifier</key><string>app.solidfill.mac</string>
  <key>CFBundleExecutable</key><string>SolidFill</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array>
    <dict><key>CFBundleTypeName</key><string>Modelo 3D</string><key>CFBundleTypeRole</key><string>Editor</string>
      <key>CFBundleTypeExtensions</key><array><string>3mf</string><string>stl</string><string>obj</string></array></dict>
  </array>
</dict></plist>
P
codesign --force --deep -s - "$APP"
echo "Pronto: $(pwd)/$APP"
