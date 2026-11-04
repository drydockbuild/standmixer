#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ENGINE="$PLUGIN_DIR/bin/AgentMixHelper"
if [ ! -f "$ENGINE" ] || [ -L "$ENGINE" ] || [ ! -x "$ENGINE" ]; then
  echo 'The StandMixer engine is missing. Install the complete plugin package.' >&2
  exit 1
fi
# A cached plugin must stay bound to its matching bundled engine. Publishing
# the canonical command runtime belongs to explicit source installation only.
printf '%s\n' "$ENGINE"
