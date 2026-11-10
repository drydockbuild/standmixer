#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
STANDMIXER_BUILD_CONFIGURATION=release
WORK_DIR=${STANDMIXER_BUILD_WORK:-"$PROJECT_DIR/../../work"}
mkdir -p "$WORK_DIR"
WORK_DIR=$(CDPATH= cd -- "$WORK_DIR" && pwd)
. "$SCRIPT_DIR/build-paths.sh"
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK_DIR/swift-module-cache"

cd "$PROJECT_DIR"
PLUGIN_DIR="$PROJECT_DIR/Plugins/claude-standmixer"
mkdir -p "$PLUGIN_DIR/bin"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/standmixer-plugin.XXXXXX")
PUBLISH=
cleanup() { rm -rf "$STAGE"; [ -z "$PUBLISH" ] || rm -f "$PUBLISH"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
standmixer_build_executable StandMixerHelper release universal "$WORK_DIR/standmixer-plugin-build" "$STAGE/StandMixerHelper"
standmixer_prepare_release_binary "$STAGE/StandMixerHelper"
xattr -d com.apple.FinderInfo "$STAGE/StandMixerHelper" 2>/dev/null || true
xattr -d com.apple.ResourceFork "$STAGE/StandMixerHelper" 2>/dev/null || true
codesign --force --sign - "$STAGE/StandMixerHelper"
codesign --verify --strict "$STAGE/StandMixerHelper"
# Publish a fresh inode; overwriting a signed executable can leave a stale
# kernel signature cache even when its new bytes verify successfully.
PUBLISH=$(mktemp "$PLUGIN_DIR/bin/.StandMixerHelper.XXXXXX")
cp "$STAGE/StandMixerHelper" "$PUBLISH"
chmod 755 "$PUBLISH"
codesign --verify --strict "$PUBLISH"
mv -f "$PUBLISH" "$PLUGIN_DIR/bin/StandMixerHelper"
PUBLISH=
chmod 755 "$PLUGIN_DIR/scripts/bootstrap.sh"
printf 'Built %s\n' "$PLUGIN_DIR"
