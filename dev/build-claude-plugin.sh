#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
AGENTMIX_BUILD_CONFIGURATION=release
WORK_DIR=${AGENTMIX_BUILD_WORK:-"$PROJECT_DIR/../../work"}
mkdir -p "$WORK_DIR"
WORK_DIR=$(CDPATH= cd -- "$WORK_DIR" && pwd)
. "$SCRIPT_DIR/build-paths.sh"
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK_DIR/swift-module-cache"

cd "$PROJECT_DIR"
PLUGIN_DIR="$PROJECT_DIR/Plugins/claude-agentmix"
mkdir -p "$PLUGIN_DIR/bin"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/agentmix-plugin.XXXXXX")
PUBLISH=
cleanup() { rm -rf "$STAGE"; [ -z "$PUBLISH" ] || rm -f "$PUBLISH"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
agentmix_build_executable AgentMixHelper release universal "$WORK_DIR/agentmix-plugin-build" "$STAGE/AgentMixHelper"
agentmix_prepare_release_binary "$STAGE/AgentMixHelper"
xattr -d com.apple.FinderInfo "$STAGE/AgentMixHelper" 2>/dev/null || true
xattr -d com.apple.ResourceFork "$STAGE/AgentMixHelper" 2>/dev/null || true
codesign --force --sign - "$STAGE/AgentMixHelper"
codesign --verify --strict "$STAGE/AgentMixHelper"
# Publish a fresh inode; overwriting a signed executable can leave a stale
# kernel signature cache even when its new bytes verify successfully.
PUBLISH=$(mktemp "$PLUGIN_DIR/bin/.AgentMixHelper.XXXXXX")
cp "$STAGE/AgentMixHelper" "$PUBLISH"
chmod 755 "$PUBLISH"
codesign --verify --strict "$PUBLISH"
mv -f "$PUBLISH" "$PLUGIN_DIR/bin/AgentMixHelper"
PUBLISH=
chmod 755 "$PLUGIN_DIR/scripts/bootstrap.sh"
printf 'Built %s\n' "$PLUGIN_DIR"
