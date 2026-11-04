#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR=$(CDPATH= cd -- "$PROJECT_DIR/.." && pwd)
if [ "${1:-}" != --skip-build ]; then "$SCRIPT_DIR/build-codex-plugin.sh"; fi
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/agentmix-codex-package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/AgentMix-Codex/.agents/plugins" "$STAGE/AgentMix-Codex/Plugins"
cp "$PROJECT_DIR/.agents/plugins/marketplace.json" "$STAGE/AgentMix-Codex/.agents/plugins/marketplace.json"
cp "$PROJECT_DIR/README.md" "$STAGE/AgentMix-Codex/README.md"
cp "$PROJECT_DIR/LICENSE" "$STAGE/AgentMix-Codex/LICENSE"
ditto "$PROJECT_DIR/Plugins/codex-agentmix" "$STAGE/AgentMix-Codex/Plugins/codex-agentmix"
ditto -c -k --keepParent "$STAGE/AgentMix-Codex" "$OUTPUT_DIR/AgentMix-Codex-plugin.zip"
printf 'Created %s\n' "$OUTPUT_DIR/AgentMix-Codex-plugin.zip"
