#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
"$SCRIPT_DIR/build-claude-plugin.sh"
mkdir -p "$PROJECT_DIR/Plugins/codex-agentmix/bin"
PUBLISH=$(mktemp "$PROJECT_DIR/Plugins/codex-agentmix/bin/.AgentMixHelper.XXXXXX")
trap 'rm -f "$PUBLISH"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$PROJECT_DIR/Plugins/claude-agentmix/bin/AgentMixHelper" "$PUBLISH"
chmod 755 "$PUBLISH"
codesign --verify --strict "$PUBLISH"
mv -f "$PUBLISH" "$PROJECT_DIR/Plugins/codex-agentmix/bin/AgentMixHelper"
chmod 755 "$PROJECT_DIR/Plugins/codex-agentmix/scripts/"*.sh
codesign --verify --strict "$PROJECT_DIR/Plugins/codex-agentmix/bin/AgentMixHelper"
printf 'Built embedded Codex plugin.\n'
