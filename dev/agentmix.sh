#!/bin/sh
# Managed by AgentMix: stable no-inference command launcher v1.
set -eu
umask 077
BIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SUPPORT_DIR=$(CDPATH= cd -- "$BIN_DIR/.." && pwd)
SOURCE_DIR="$SUPPORT_DIR/source"
ENGINE="$SUPPORT_DIR/runtime/AgentMixHelper"
VERB=${1:-settings}
[ "$#" = 0 ] || shift
case "$VERB" in
  update)
    [ -f "$SOURCE_DIR/.agentmix-source" ] && [ ! -L "$SOURCE_DIR" ] && [ ! -L "$SOURCE_DIR/.agentmix-source" ] || { echo 'StandMixer: reinstall from the trusted source checkout before updating.' >&2; exit 1; }
    exec /bin/sh "$SOURCE_DIR/dev/update.sh" "$@"
    ;;
  install-mac)
    [ -f "$SOURCE_DIR/.agentmix-source" ] && [ ! -L "$SOURCE_DIR" ] && [ ! -L "$SOURCE_DIR/.agentmix-source" ] || { echo 'StandMixer: reinstall from the trusted source checkout before building the Mac app.' >&2; exit 1; }
    exec /bin/sh "$SOURCE_DIR/dev/install-mac.sh" "$@"
    ;;
  web-url)
    [ "$#" = 0 ] || { echo 'Usage: standmixer web-url' >&2; exit 2; }
    exec /bin/sh "$BIN_DIR/open-codex-ui"
    ;;
  settings|open)
    HOST=browser
    OPEN=yes
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --host) [ "$#" -ge 2 ] || exit 2; HOST=$2; shift 2 ;;
        --no-open) OPEN=no; shift ;;
        *) echo 'Usage: standmixer settings [--host codex|claude] [--no-open]' >&2; exit 2 ;;
      esac
    done
    case "$HOST" in codex|claude|browser) ;; *) echo 'StandMixer: host must be codex or claude.' >&2; exit 2 ;; esac
    if [ "$HOST" = claude ]; then
      printf 'Open Claude Code and run /standmixer to display its native settings panel.\n'
      exit 0
    fi
    if [ "$HOST" = codex ]; then
      printf 'Start a new Codex chat and run /standmixer to open its native settings panel. If the plugin has not loaded, restart Codex first.\n'
      exit 0
    fi
    SESSION=$(mktemp "${TMPDIR:-/tmp}/agentmix-panel.XXXXXX")
    trap 'rm -f "$SESSION"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    /bin/sh "$BIN_DIR/open-codex-ui" > "$SESSION"
    URL=$("$ENGINE" --session-url "$SESSION")
    if [ "$HOST" = browser ] && [ "$OPEN" = yes ]; then
      open "$URL"
      printf 'Opened StandMixer settings in your default browser.\n'
    else
      printf '%s\n' "$URL"
    fi
    ;;
  *) exec "$ENGINE" --standmixer "$VERB" "$@" ;;
esac
