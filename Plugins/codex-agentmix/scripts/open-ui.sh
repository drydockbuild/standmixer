#!/bin/sh
# Explicit Web launch only. Native Codex panels use the plugin's MCP tool.
set -eu
umask 077
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ENGINE="$PLUGIN_DIR/bin/AgentMixHelper"
if [ ! -f "$ENGINE" ] || [ -L "$ENGINE" ] || [ ! -x "$ENGINE" ]; then
  echo 'The StandMixer engine is missing. Install the complete plugin package.' >&2
  exit 1
fi
UI_ROOT="$PLUGIN_DIR/ui"
RUNTIME="$HOME/Library/Application Support/AgentMix/CodexSessions"
SERVER_PID=
folder_error() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  printf "StandMixer Web cannot write its private session folder: %s. Check the folder's ownership and permissions, or use /standmixer in Codex for the native panel.\n" "$RUNTIME" >&2
  exit 1
}
CHECK="$RUNTIME"
while [ "$CHECK" != / ]; do
  if [ -L "$CHECK" ]; then echo 'StandMixer will not use a redirected session folder.' >&2; exit 1; fi
  CHECK=$(dirname -- "$CHECK")
done
mkdir -p "$RUNTIME" 2>/dev/null || folder_error
chmod 700 "$RUNTIME" 2>/dev/null || folder_error
RECORD="$RUNTIME/current.json"
STAMP="$RUNTIME/current-ui.sha256"
if [ -L "$RECORD" ] || [ -L "$STAMP" ]; then echo 'StandMixer will not replace a session symlink.' >&2; exit 1; fi
UI_HASH=$(cat "$UI_ROOT/index.html" "$ENGINE" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
if [ -f "$RECORD" ] && [ ! -L "$RECORD" ] && [ -f "$STAMP" ] && [ ! -L "$STAMP" ] && [ "$(cat "$STAMP")" = "$UI_HASH" ]; then
  URL=$("$ENGINE" --session-url "$RECORD" 2>/dev/null || true)
  if printf '%s' "$URL" | /usr/bin/grep -Eq '^http://127\.0\.0\.1:[0-9]+/#token=[A-Za-z0-9_-]+$'; then
    ORIGIN=${URL%%/#*}
    TOKEN=${URL##*token=}
    CODE=$(/usr/bin/curl --silent --max-time 2 --output /dev/null --write-out '%{http_code}' \
      --header "Origin: $ORIGIN" --header "Authorization: Bearer $TOKEN" \
      --header 'Content-Type: application/json' --data '{"action":"state"}' "$ORIGIN/api" || true)
    if [ "$CODE" = 200 ]; then cat "$RECORD"; exit 0; fi
  fi
fi
STAGE=$(mktemp -d "$RUNTIME/launch.XXXXXX" 2>/dev/null) || folder_error
server_error() {
  if LC_ALL=C /usr/bin/grep -Eiq 'NWError.*(error[[:space:]]+(1|13)([^[:digit:]]|$)|EPERM|EACCES|rawValue:[[:space:]]*(1|13)([^[:digit:]]|$))' "$STAGE/server.log"; then
    printf 'StandMixer Web could not open a local listener because this host denied network permission. Use /standmixer in Codex for the native panel, or run standmixer web-url from a terminal that permits local loopback connections.\n' >&2
  else
    cat "$STAGE/server.log" >&2
    printf 'StandMixer Web did not start its local listener.\n' >&2
  fi
  exit 1
}
/usr/bin/nohup "$ENGINE" --serve-ui --detached-ui --ui-root "$UI_ROOT" > "$STAGE/session.json" 2> "$STAGE/server.log" < /dev/null &
SERVER_PID=$!
COUNT=0
while [ "$COUNT" -lt 100 ]; do
  if [ -s "$STAGE/session.json" ] && "$ENGINE" --session-url "$STAGE/session.json" >/dev/null 2>&1; then
    cp "$STAGE/session.json" "$STAGE/current.json" 2>/dev/null || folder_error
    chmod 600 "$STAGE/current.json" 2>/dev/null || folder_error
    mv -f "$STAGE/current.json" "$RECORD" 2>/dev/null || folder_error
    printf '%s\n' "$UI_HASH" > "$STAMP" || folder_error
    cat "$RECORD"
    exit 0
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then server_error; fi
  COUNT=$((COUNT + 1))
  sleep 0.1
done
kill "$SERVER_PID" 2>/dev/null || true
printf 'StandMixer Web did not start its local listener within 10 seconds. Diagnostics: %s\n' "$STAGE/server.log" >&2
exit 1
