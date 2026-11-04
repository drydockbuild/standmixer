#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR=$(CDPATH= cd -- "$PROJECT_DIR/.." && pwd)
if [ "${1:-}" != --skip-build ]; then "$SCRIPT_DIR/build-claude-plugin.sh"; fi
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/agentmix-plugin-package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/AgentMix-plugin/.claude-plugin" "$STAGE/AgentMix-plugin/Plugins"
cp "$PROJECT_DIR/README.md" "$STAGE/AgentMix-plugin/README.md"
cp "$PROJECT_DIR/LICENSE" "$STAGE/AgentMix-plugin/LICENSE"
cp "$PROJECT_DIR/.claude-plugin/marketplace.json" "$STAGE/AgentMix-plugin/.claude-plugin/marketplace.json"
ditto "$PROJECT_DIR/Plugins/claude-agentmix" "$STAGE/AgentMix-plugin/Plugins/claude-agentmix"
ditto -c -k --keepParent "$STAGE/AgentMix-plugin" "$OUTPUT_DIR/AgentMix-Claude-plugin.zip"
printf 'Created %s\n' "$OUTPUT_DIR/AgentMix-Claude-plugin.zip"
