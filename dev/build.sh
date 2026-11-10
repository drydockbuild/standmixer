#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

CONFIGURATION=${1:-release}
case "$CONFIGURATION" in
  release|debug) ;;
  *) echo "Usage: $0 [release|debug]" >&2; exit 2 ;;
esac

STANDMIXER_BUILD_CONFIGURATION=$CONFIGURATION
OUTPUT_APP_PATH=${STANDMIXER_OUTPUT_APP:-"$PROJECT_DIR/../StandMixer.app"}
# Assemble and sign outside synced folders so Finder metadata cannot race signing.
APP_WORK=$(mktemp -d "${TMPDIR:-/tmp}/standmixer-build-app.XXXXXX")
APP_PATH="$APP_WORK/StandMixer.app"
trap 'rm -rf "$APP_WORK"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
WORK_DIR=${STANDMIXER_BUILD_WORK:-"$PROJECT_DIR/../../work"}
mkdir -p "$WORK_DIR"
WORK_DIR=$(CDPATH= cd -- "$WORK_DIR" && pwd)
. "$SCRIPT_DIR/build-paths.sh"
standmixer_select_app_sdk "$APP_WORK/sdk-probe"
SCRATCH_PATH="$WORK_DIR/standmixer-build"
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK_DIR/swift-module-cache"

cd "$PROJECT_DIR"
mkdir -p "$SCRATCH_PATH" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
# A host build works with suitable Command Line Tools. Universal builds use
# separate native SwiftPM targets and lipo, without requiring XCBuild.
BUILD_ARCH=${STANDMIXER_BUILD_ARCH:-native}
mkdir -p "$MACOS" "$RESOURCES"
standmixer_build_executable StandMixer "$CONFIGURATION" "$BUILD_ARCH" "$SCRATCH_PATH" "$MACOS/StandMixer"
if [ "$CONFIGURATION" = release ]; then standmixer_prepare_release_binary "$MACOS/StandMixer"; fi

ICON_WORK="$APP_WORK/icon"
ICONSET="$ICON_WORK/StandMixer.iconset"
mkdir -p "$ICONSET"
env CLANG_MODULE_CACHE_PATH="$WORK_DIR/icon-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$WORK_DIR/icon-module-cache" swift -sdk "$SDKROOT" "$SCRIPT_DIR/make-icon.swift" "$ICONSET" dark
iconutil -c icns "$ICONSET" -o "$RESOURCES/StandMixer.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>StandMixer</string>
  <key>CFBundleIconFile</key><string>StandMixer</string>
  <key>CFBundleIdentifier</key><string>build.drydock.StandMixer</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>StandMixer</string>
  <key>CFBundleDisplayName</key><string>StandMixer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.8</string>
  <key>CFBundleVersion</key><string>11</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Generated bundles can inherit Finder metadata in synced workspaces.
# Remove only Finder metadata that prevents ad-hoc signing. Do not alter quarantine.
xattr -dr com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_PATH" 2>/dev/null || true
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
rm -rf "$OUTPUT_APP_PATH"
ditto "$APP_PATH" "$OUTPUT_APP_PATH"
# File providers may attach Finder metadata when the completed app is copied.
xattr -dr com.apple.FinderInfo "$OUTPUT_APP_PATH" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$OUTPUT_APP_PATH" 2>/dev/null || true
codesign --verify --deep --strict "$OUTPUT_APP_PATH"
printf 'Created %s\n' "$OUTPUT_APP_PATH"
