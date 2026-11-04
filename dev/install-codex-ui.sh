#!/bin/sh
# Install only the embedded UI launcher/assets. Native model settings stay put.
set -eu
umask 077
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/install-common.sh"
PLUGIN_DIR="$PROJECT_DIR/Plugins/codex-agentmix"
ENGINE=$("$PLUGIN_DIR/bin/AgentMixHelper" --bootstrap)
[ "$ENGINE" = "$HOME/Library/Application Support/AgentMix/runtime/AgentMixHelper" ] || agentmix_fail 'This package contains an older AgentMix helper. Rebuild or reinstall the complete package before updating.'
SUPPORT_DIR=$(CDPATH= cd -- "$(dirname -- "$ENGINE")/.." && pwd)
BIN_DIR="$SUPPORT_DIR/bin"
agentmix_owned_directory "$BIN_DIR"
agentmix_owned_directory "$SUPPORT_DIR/CodexUI"
mkdir -p "$BIN_DIR"
chmod 700 "$BIN_DIR"
UI_LOCK="$SUPPORT_DIR/.ui-install.lock"
agentmix_owned_directory "$UI_LOCK"
mkdir "$UI_LOCK" 2>/dev/null || agentmix_fail 'Another embedded UI installation is running.'
STAGE=
GENERATION_STAGE=
cleanup() {
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  [ -z "$GENERATION_STAGE" ] || rm -rf "$GENERATION_STAGE"
  rmdir "$UI_LOCK" 2>/dev/null || true
}
trap cleanup EXIT
STAGE=$(mktemp -d "$BIN_DIR/.launcher.XXXXXX")
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cat "$PLUGIN_DIR/ui/index.html" "$PLUGIN_DIR/scripts/open-ui.sh" "$PLUGIN_DIR/bin/AgentMixHelper" > "$STAGE/ui-bytes"
UI_HASH=$(agentmix_hash "$STAGE/ui-bytes")
GENERATION="$SUPPORT_DIR/CodexUI/$UI_HASH"
for path in "$GENERATION" "$GENERATION/ui" "$GENERATION/scripts" "$GENERATION/bin"; do agentmix_owned_directory "$path"; done
GENERATION_COMPLETE=yes
for relative in ui/index.html scripts/open-ui.sh bin/AgentMixHelper; do
  path="$GENERATION/$relative"
  if [ -e "$path" ] || [ -L "$path" ]; then
    agentmix_owned_file "$path"
    cmp -s "$PLUGIN_DIR/$relative" "$path" || agentmix_fail 'The installed UI assets were modified. They were kept.'
  else
    GENERATION_COMPLETE=no
  fi
done
LAUNCHER="$BIN_DIR/open-codex-ui"
RECEIPT="$BIN_DIR/.codex-ui-launcher.sha256"
for path in "$LAUNCHER" "$RECEIPT"; do [ ! -L "$path" ] || agentmix_fail 'An embedded UI launcher path is redirected.'; done
write_launcher() {
  printf '#!/bin/sh\n# Managed by AgentMix\nROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../CodexUI/%s" && pwd)\nexec /bin/sh "$ROOT/scripts/open-ui.sh"\n' "$1" > "$2"
}
if [ -e "$LAUNCHER" ]; then
  agentmix_owned_file "$LAUNCHER"
  if [ -e "$RECEIPT" ]; then
    agentmix_owned_file "$RECEIPT"
    [ "$(agentmix_hash "$LAUNCHER")" = "$(cat "$RECEIPT")" ] || agentmix_fail 'The embedded UI launcher was modified. It was kept.'
  else
    # Upgrade the original launcher only when every byte matches our fixed
    # generated format, including a single 64-character generation hash.
    LEGACY_HASH=$(sed -n 's|^ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../CodexUI/\([0-9a-f]\{64\}\)" && pwd)$|\1|p' "$LAUNCHER")
    [ "${#LEGACY_HASH}" = 64 ] || agentmix_fail 'An unowned embedded UI launcher was kept.'
    write_launcher "$LEGACY_HASH" "$STAGE/legacy-launcher"
    cmp -s "$LAUNCHER" "$STAGE/legacy-launcher" || agentmix_fail 'An unowned embedded UI launcher was kept.'
  fi
elif [ -e "$RECEIPT" ]; then
  agentmix_owned_file "$RECEIPT"
fi
# This parser exits3 for a known-empty list without reading settings or starting
# a model/service. Offline signature checks alone miss stale executable vnodes.
printf '{"marketplaces":[]}\n' > "$STAGE/empty-marketplaces.json"
helper_launches() {
  if ("$1" --installer-marketplace-source codex < "$STAGE/empty-marketplaces.json") >/dev/null 2>&1; then
    return 1
  else
    [ "$?" = 3 ]
  fi
}
if [ "$GENERATION_COMPLETE" != yes ] || ! helper_launches "$GENERATION/bin/AgentMixHelper"; then
  mkdir -p "$SUPPORT_DIR/CodexUI"
  GENERATION_STAGE=$(mktemp -d "$SUPPORT_DIR/CodexUI/.generation.XXXXXX")
  mkdir "$GENERATION_STAGE/ui" "$GENERATION_STAGE/scripts" "$GENERATION_STAGE/bin"
  cp "$PLUGIN_DIR/ui/index.html" "$GENERATION_STAGE/ui/index.html"
  cp "$PLUGIN_DIR/scripts/open-ui.sh" "$GENERATION_STAGE/scripts/open-ui.sh"
  cp "$PLUGIN_DIR/bin/AgentMixHelper" "$GENERATION_STAGE/bin/AgentMixHelper"
  chmod 700 "$GENERATION_STAGE/bin/AgentMixHelper"
  helper_launches "$GENERATION_STAGE/bin/AgentMixHelper" || agentmix_fail 'The staged UI helper could not launch; the existing UI was kept.'
  if [ "$GENERATION_COMPLETE" = yes ]; then
    # Repair only an exact-owned, execution-bad helper with an atomic fresh inode.
    # Existing HTML/scripts and any process using the old inode remain untouched.
    agentmix_owned_file "$GENERATION/bin/AgentMixHelper"
    cmp -s "$PLUGIN_DIR/bin/AgentMixHelper" "$GENERATION/bin/AgentMixHelper" || agentmix_fail 'The installed UI helper changed during repair. It was kept.'
    mv -f "$GENERATION_STAGE/bin/AgentMixHelper" "$GENERATION/bin/AgentMixHelper"
  else
    if [ -e "$GENERATION" ]; then
      # Preserve an interrupted partial generation rather than deleting its files.
      PREVIOUS=$(mktemp -d "$SUPPORT_DIR/CodexUI/.previous.XXXXXX")
      mv "$GENERATION" "$PREVIOUS/generation"
    fi
    mv "$GENERATION_STAGE" "$GENERATION"
    GENERATION_STAGE=
  fi
fi
write_launcher "$UI_HASH" "$STAGE/open-codex-ui"
chmod 700 "$STAGE/open-codex-ui"
agentmix_hash "$STAGE/open-codex-ui" > "$STAGE/receipt"
if ! cmp -s "$STAGE/open-codex-ui" "$LAUNCHER"; then mv -f "$STAGE/open-codex-ui" "$LAUNCHER"; fi
if ! cmp -s "$STAGE/receipt" "$RECEIPT"; then mv -f "$STAGE/receipt" "$RECEIPT"; fi
printf 'Installed embedded Codex launcher. No model defaults changed.\n'
