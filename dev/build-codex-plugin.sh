#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
"$SCRIPT_DIR/build-claude-plugin.sh"
mkdir -p "$PROJECT_DIR/Plugins/codex-standmixer/bin"
PUBLISH=$(mktemp "$PROJECT_DIR/Plugins/codex-standmixer/bin/.StandMixerHelper.XXXXXX")
trap 'rm -f "$PUBLISH"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$PROJECT_DIR/Plugins/claude-standmixer/bin/StandMixerHelper" "$PUBLISH"
chmod 755 "$PUBLISH"
codesign --verify --strict "$PUBLISH"
mv -f "$PUBLISH" "$PROJECT_DIR/Plugins/codex-standmixer/bin/StandMixerHelper"
chmod 755 "$PROJECT_DIR/Plugins/codex-standmixer/scripts/"*.sh
codesign --verify --strict "$PROJECT_DIR/Plugins/codex-standmixer/bin/StandMixerHelper"
printf 'Built embedded Codex plugin.\n'
