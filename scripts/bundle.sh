#!/bin/bash
# Assembles and signs tick.app from the Rust binary and the TickNative
# Swift framework.
#
#   scripts/bundle.sh            # debug build → "tick Debug.app" (com.dipxsy.tick.debug)
#   scripts/bundle.sh release    # release build → "tick.app" (com.dipxsy.tick)
#
# Signing identity: $TICK_SIGN_IDENTITY, else the first "Apple Development"
# identity (stable TCC grants while developing), else ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-debug}"

if [ "$CONFIG" = "release" ]; then
  cargo build --release -p tick-app
  BINARY="$ROOT/target/release/tick"
  APP_NAME="tick"
  BUNDLE_ID="com.dipxsy.tick"
else
  cargo build -p tick-app
  BINARY="$ROOT/target/debug/tick"
  APP_NAME="tick Debug"
  BUNDLE_ID="com.dipxsy.tick.debug"
fi

PRODUCTS="$ROOT/target/native/Build/Products/Release"
APP="$ROOT/target/bundle/$CONFIG/$APP_NAME.app"
CONTENTS="$APP/Contents"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"
BUILD_NUMBER="${TICK_BUILD_NUMBER:-82}"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/tick"

# Frameworks: the Swift bridge, Sparkle, and the Swift back-deployment shim.
ditto "$PRODUCTS/PackageFrameworks/TickNative.framework" "$CONTENTS/Frameworks/TickNative.framework"
ditto "$PRODUCTS/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
SPAN="$(find "$(dirname "$(dirname "$(xcrun --find swift)")")/lib" -path '*macosx/libswiftCompatibilitySpan.dylib' | head -1)"
if [ -n "$SPAN" ]; then
  cp "$SPAN" "$CONTENTS/Frameworks/"
fi

# SwiftPM resource bundles (MLX Metal shaders, PermissionFlow, Hub, Crypto).
for bundle in "$PRODUCTS"/*.bundle; do
  ditto "$bundle" "$CONTENTS/Resources/$(basename "$bundle")"
done

# App icon from the 1024 px source.
ICONSET="$ROOT/target/bundle/AppIcon.iconset"
if [ ! -f "$ROOT/target/bundle/AppIcon.icns" ]; then
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  SOURCE="$ROOT/resources/AppIcon.png"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ROOT/target/bundle/AppIcon.icns"
fi
cp "$ROOT/target/bundle/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>tick</string>
	<key>CFBundleExecutable</key><string>tick</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>tick</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>AudioHardwarePowerHint</key><string>None</string>
	<key>NSMicrophoneUsageDescription</key><string>tick needs microphone access to transcribe your voice.</string>
	<key>NSAccessibilityUsageDescription</key><string>tick needs accessibility access to detect your hotkey and type transcriptions.</string>
	<key>NSInputMonitoringUsageDescription</key><string>tick needs Input Monitoring permission so your global hotkey works in every app.</string>
	<key>NSAppleEventsUsageDescription</key><string>tick reads the current browser tab and the system volume to format and record cleanly.</string>
	<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
	<key>SUEnableInstallerLauncherService</key><true/>
	<key>SUFeedURL</key><string>https://hex-updates.s3.amazonaws.com/appcast.xml</string>
	<key>SUPublicEDKey</key><string>mIek27lttJe8cIBqVZFhh6reRKjpTx1h9ZY9OKWPtuM=</string>
</dict>
</plist>
PLIST

IDENTITY="${TICK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"
ENTITLEMENTS="$ROOT/resources/tick.entitlements"
echo "Signing with: $IDENTITY"
sign() { codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$@"; }
for dylib in "$CONTENTS/Frameworks"/*.dylib; do [ -e "$dylib" ] && sign "$dylib"; done
for helper in "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/XPCServices/"*.xpc \
              "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
              "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Updater.app"; do
  [ -e "$helper" ] && sign "$helper"
done
sign "$CONTENTS/Frameworks/Sparkle.framework"
sign "$CONTENTS/Frameworks/TickNative.framework"
for bundle in "$CONTENTS/Resources"/*.bundle; do sign "$bundle"; done
sign --entitlements "$ENTITLEMENTS" "$APP"

echo "Built $APP"
