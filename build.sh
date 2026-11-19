#!/bin/zsh
# Builds Termos.app (release) into ./build
set -euo pipefail
cd "$(dirname "$0")"
INSTALL=0
[[ "${1:-}" == "--install" ]] && { INSTALL=1; shift; }
CONFIG=${1:-release}
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)/Termos
APP=build/Termos.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Termos"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Termos</string>
  <key>CFBundleDisplayName</key><string>Termos</string>
  <key>CFBundleIdentifier</key><string>local.termos.app</string>
  <key>CFBundleExecutable</key><string>Termos</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Termos Layout</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>local.termos.layout</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>local.termos.pane</string>
    <key>UTTypeDescription</key><string>Termos Terminal</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict><dict>
    <key>UTTypeIdentifier</key><string>local.termos.layout</string>
    <key>UTTypeDescription</key><string>Termos Layout</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>termos</string></array>
    </dict>
  </dict></array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $PWD/$APP"
if (( INSTALL )); then
  ditto "$APP" /Applications/Termos.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Termos.app
  echo "Installed: /Applications/Termos.app (restart Termos to pick it up)"
fi
