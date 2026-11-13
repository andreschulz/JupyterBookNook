#!/bin/sh
# Builds JupyterBookNook.app (release) with its icon into dist/:
#   Scripts/make-app.sh
# The app is not signed for distribution (ad-hoc signature only); it runs on this Mac.
set -e
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=dist/JupyterBookNook.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/JupyterBookNook" "$APP/Contents/MacOS/"
cp -R "$BIN/JupyterBookNook_JupyterBookNook.bundle" "$APP/Contents/Resources/"
cp Design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.jupyterbooknook.app</string>
<key>CFBundleName</key><string>JupyterBookNook</string>
<key>CFBundleDisplayName</key><string>JupyterBookNook</string>
<key>CFBundleExecutable</key><string>JupyterBookNook</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.8</string>
<key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
