#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR=$(CDPATH= cd -- "$PROJECT_DIR/.." && pwd)
if [ "${1:-}" != --skip-build ]; then "$SCRIPT_DIR/build-codex-plugin.sh"; fi
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/standmixer-codex-package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/StandMixer-Codex/.agents/plugins" "$STAGE/StandMixer-Codex/Plugins"
cp "$PROJECT_DIR/.agents/plugins/marketplace.json" "$STAGE/StandMixer-Codex/.agents/plugins/marketplace.json"
cp "$PROJECT_DIR/README.md" "$STAGE/StandMixer-Codex/README.md"
cp "$PROJECT_DIR/LICENSE" "$STAGE/StandMixer-Codex/LICENSE"
ditto "$PROJECT_DIR/Plugins/codex-standmixer" "$STAGE/StandMixer-Codex/Plugins/codex-standmixer"
ditto -c -k --keepParent "$STAGE/StandMixer-Codex" "$OUTPUT_DIR/StandMixer-Codex-plugin.zip"
printf 'Created %s\n' "$OUTPUT_DIR/StandMixer-Codex-plugin.zip"
