#!/bin/bash
set -e

echo "Building Kopya.app..."

# Build release binary
echo "→ Building release binary..."
swift build -c release -Xswiftc -parse-as-library --product kopya

# Create .app structure
APP_DIR="build/Kopya.app"
echo "→ Creating .app bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
echo "→ Copying executable..."
cp .build/release/kopya "$APP_DIR/Contents/MacOS/kopya"

# Copy Info.plist
echo "→ Copying Info.plist..."
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

# Sign the app (ad-hoc for local use)
echo "→ Code signing..."
codesign --force --deep --sign - "$APP_DIR"

echo "✓ Built Kopya.app at $APP_DIR"
echo ""
echo "To install: cp -r $APP_DIR /Applications/"
echo "To test: open $APP_DIR"
