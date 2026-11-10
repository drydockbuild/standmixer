#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR=$(CDPATH= cd -- "$PROJECT_DIR/.." && pwd)
if [ "${1:-}" != --skip-build ]; then "$SCRIPT_DIR/build-claude-plugin.sh"; fi
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/standmixer-plugin-package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/StandMixer-plugin/.claude-plugin" "$STAGE/StandMixer-plugin/Plugins"
cp "$PROJECT_DIR/README.md" "$STAGE/StandMixer-plugin/README.md"
cp "$PROJECT_DIR/LICENSE" "$STAGE/StandMixer-plugin/LICENSE"
cp "$PROJECT_DIR/.claude-plugin/marketplace.json" "$STAGE/StandMixer-plugin/.claude-plugin/marketplace.json"
ditto "$PROJECT_DIR/Plugins/claude-standmixer" "$STAGE/StandMixer-plugin/Plugins/claude-standmixer"
ditto -c -k --keepParent "$STAGE/StandMixer-plugin" "$OUTPUT_DIR/StandMixer-Claude-plugin.zip"
printf 'Created %s\n' "$OUTPUT_DIR/StandMixer-Claude-plugin.zip"
