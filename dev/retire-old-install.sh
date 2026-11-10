#!/bin/sh
# One-time removal only. The running product never falls back to this old root.
set -eu
umask 077
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/install-common.sh"
OLD="$HOME/Library/Application Support/AgentMix"
NEW="$HOME/Library/Application Support/StandMixer"
[ -e "$OLD" ] || [ -L "$OLD" ] || exit 0
standmixer_owned_directory "$OLD"
standmixer_owned_file "$OLD/source/.agentmix-source"
[ "$(cat "$OLD/source/.agentmix-source")" = 'AgentMix source checkout v1' ] || standmixer_fail 'The old installation is unrecognized; it was kept.'
OLD_ENGINE="$OLD/runtime/AgentMixHelper"
standmixer_owned_file "$OLD_ENGINE"
standmixer_owned_file "$OLD/runtime/.engine.sha256"
[ "$(standmixer_hash "$OLD_ENGINE")" = "$(cat "$OLD/runtime/.engine.sha256")" ] || standmixer_fail 'The old helper was modified; it was kept.'
codesign --verify --strict "$OLD_ENGINE" || standmixer_fail 'The old helper signature is invalid; it was kept.'
standmixer_owned_directory "$NEW"
ENGINE="$NEW/runtime/StandMixerHelper"
standmixer_owned_file "$ENGINE"
LOCK="$OLD/.source-install.lock"
standmixer_owned_directory "$LOCK"
mkdir "$LOCK" 2>/dev/null || standmixer_fail 'An old installation is still running. Wait for it to finish, then retry.'
cleanup() { rm -f "$LOCK/marketplaces.json" "$LOCK/state.json"; rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
registrations() {
for PLATFORM in codex claude; do
  CLI=$(standmixer_find_cli "$PLATFORM")
  [ -n "$CLI" ] || continue
  for MARKETPLACE in drydock-standmixer drydock-agentmix; do
    "$CLI" plugin marketplace list --json > "$LOCK/marketplaces.json"
    if SOURCE=$("$ENGINE" --installer-marketplace-source "$PLATFORM" "$MARKETPLACE" < "$LOCK/marketplaces.json"); then
      case "$SOURCE" in "$OLD/source"|"$OLD/source/Plugins/claude-agentmix") ;; *) standmixer_fail "The $MARKETPLACE marketplace uses another source; it was kept." ;; esac
      [ "$1" != check ] || continue
      PLUGIN=standmixer
      [ "$MARKETPLACE" != drydock-agentmix ] || PLUGIN=agentmix
      if [ "$PLATFORM" = codex ]; then
        "$CLI" plugin remove "$PLUGIN@$MARKETPLACE"
      else
        "$CLI" plugin uninstall "$PLUGIN@$MARKETPLACE" --scope user
      fi
      # Some hosts retire the marketplace with its final plugin.
      "$CLI" plugin marketplace list --json > "$LOCK/marketplaces.json"
      if REMAINING=$("$ENGINE" --installer-marketplace-source "$PLATFORM" "$MARKETPLACE" < "$LOCK/marketplaces.json"); then
        [ "$REMAINING" = "$SOURCE" ] || standmixer_fail 'The old marketplace changed during removal; its new registration was kept.'
        if [ "$PLATFORM" = codex ]; then "$CLI" plugin marketplace remove "$MARKETPLACE";
        else "$CLI" plugin marketplace remove "$MARKETPLACE" --scope user; fi
      else
        [ "$?" = 3 ] || standmixer_fail 'Could not verify marketplace removal; its registration was kept.'
      fi
    else
      STATUS=$?
      [ "$STATUS" = 3 ] || standmixer_fail 'Could not verify the old plugin registration; it was kept.'
    fi
  done
done
}
# Validate registrations before changing settings; recheck them before removal.
registrations check
"$ENGINE" --installer-keep-native-defaults
# The old release knows its own receipts. Use its safe uninstall instead of
# importing obsolete file paths or recreating its migration rules here.
printf 'Retiring the old installation. Close old StandMixer panels and reload plugins after installation.\n'
"$OLD_ENGINE" --standmixer uninstall --yes
printf '{"action":"state"}\n' | "$OLD_ENGINE" > "$LOCK/state.json"
[ "$(plutil -extract state.installation.hasInstallation raw -o - "$LOCK/state.json")" = false ] || standmixer_fail 'Old settings have conflicts and were kept. Resolve them in the old Uninstall review, then retry.'
registrations remove
# Preserve editable preferences only. Receipts remain with the retired files;
# a fresh Apply establishes the new installation's baseline.
for NAME in configuration.json presets.json previous-draft.json; do
  if [ -e "$OLD/$NAME" ] || [ -L "$OLD/$NAME" ]; then
    standmixer_owned_file "$OLD/$NAME"
    [ "$(stat -f %z "$OLD/$NAME")" -le 1048576 ] || standmixer_fail 'An old preferences file is unexpectedly large; it was kept.'
    plutil -convert xml1 -o /dev/null "$OLD/$NAME" || standmixer_fail 'Old preferences could not be read; they were kept.'
    if [ ! -e "$NEW/$NAME" ] && [ ! -L "$NEW/$NAME" ]; then cp -p "$OLD/$NAME" "$NEW/$NAME"; fi
  fi
done
RECOVERY_ROOT="$NEW/Retired"
standmixer_owned_directory "$RECOVERY_ROOT"
mkdir -p "$RECOVERY_ROOT"
RECOVERY=$(mktemp -d "$RECOVERY_ROOT/old-install.XXXXXX")
# Move an old Mac app only when its receipt and signature prove ownership.
if [ -f "$OLD/mac-app.receipt" ] && [ ! -L "$OLD/mac-app.receipt" ]; then
  standmixer_owned_file "$OLD/mac-app.receipt"
  APP=$(sed -n '1p' "$OLD/mac-app.receipt")
  case "$APP" in "$HOME/Applications/StandMixer.app"|"$HOME/Applications/AgentMix.app"|/Applications/StandMixer.app|/Applications/AgentMix.app)
    if (
      standmixer_owned_directory "$APP"
      standmixer_owned_file "$APP/Contents/MacOS/AgentMix"
      [ "$(sed -n '2p' "$OLD/mac-app.receipt")" = "$(standmixer_hash "$APP/Contents/MacOS/AgentMix")" ] && codesign --verify --deep --strict "$APP"
    ) >/dev/null 2>&1; then mv "$APP" "$RECOVERY/previous.app"; fi ;;
  esac
fi
cleanup
trap - EXIT
mv "$OLD" "$RECOVERY/support"
printf 'Old installation retired. Recovery files: %s\nSaved preferences retained. Review and Apply your preset to enable the new installation.\n' "$RECOVERY"
