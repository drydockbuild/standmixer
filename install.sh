#!/bin/sh
# Installation from this trusted source checkout. Never starts inference.
set -eu
umask 077
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$PROJECT_DIR/dev/install-common.sh"
HOST=
if [ -n "${CODEX_THREAD_ID:-}" ]; then
  HOST=codex
elif [ "${CLAUDECODE:-}" = 1 ]; then
  HOST=claude
fi
OPEN=yes
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) [ "$#" -ge 2 ] || agentmix_fail 'Use --host codex or --host claude.'; HOST=$2; shift 2 ;;
    --no-open) OPEN=no; shift ;;
    --help|-h) printf 'Usage: sh install.sh [--host codex|claude] [--no-open]\n'; exit 0 ;;
    *) agentmix_fail "Unknown option: $1" ;;
  esac
done
case "$HOST" in ''|codex|claude) ;; *) agentmix_fail 'Use --host codex or --host claude.' ;; esac
agentmix_darwin
[ -n "${HOME:-}" ] || agentmix_fail 'HOME must name your home directory.'
SUPPORT_DIR="$HOME/Library/Application Support/AgentMix"
SOURCE_DIR="$SUPPORT_DIR/source"
BIN_DIR="$SUPPORT_DIR/bin"
agentmix_owned_directory "$SUPPORT_DIR"
agentmix_owned_directory "$BIN_DIR"
agentmix_owned_directory "$SOURCE_DIR"
CODEX=$(agentmix_find_cli codex)
CLAUDE=$(agentmix_find_cli claude)
[ -n "$CODEX$CLAUDE" ] || agentmix_fail 'Install Codex or Claude Code first, then rerun this installer.'
[ "$HOST" != codex ] || [ -n "$CODEX" ] || agentmix_fail 'Codex was not found in PATH or known installation locations. Install it or use --host claude.'
[ "$HOST" != claude ] || [ -n "$CLAUDE" ] || agentmix_fail 'Claude Code was not found in PATH or known installation locations. Install it or use --host codex.'
# Check only the selected configuration roots; do not inspect accounts or home folders.
[ -z "$CODEX" ] || agentmix_owned_directory "${CODEX_HOME:-$HOME/.codex}"
[ -z "$CLAUDE" ] || agentmix_owned_directory "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "$CODEX" ]; then
  CODEX_HOME=${CODEX_HOME:-"$HOME/.codex"}
  export CODEX_HOME
  mkdir -p "$CODEX_HOME"
fi
if [ -n "$CLAUDE" ]; then
  CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-"$HOME/.claude"}
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR"
fi
mkdir -p "$SUPPORT_DIR" "$BIN_DIR"
chmod 700 "$SUPPORT_DIR" "$BIN_DIR"
LOCK="$SUPPORT_DIR/.source-install.lock"
[ ! -L "$LOCK" ] || agentmix_fail 'The source install lock is redirected.'
mkdir "$LOCK" 2>/dev/null || agentmix_fail "Another source or Mac installation may be running. Wait for it to finish before retrying. Lock: $LOCK"
STAGE=
BACKUP=
LAUNCH_STAGE=
LAUNCH_PENDING=no
LAUNCH_NAMES="standmixer .standmixer-launcher.sha256"
cleanup() {
  if [ "$LAUNCH_PENDING" = yes ]; then
    for NAME in standmixer .standmixer-launcher.sha256; do
      if [ -f "$LAUNCH_STAGE/previous-$NAME" ]; then
        mv -f "$LAUNCH_STAGE/previous-$NAME" "$BIN_DIR/$NAME"
      elif [ -f "$LAUNCH_STAGE/absent-$NAME" ]; then
        rm -f "$BIN_DIR/$NAME"
      fi
    done
    # Legacy files are only removed, never replaced. Restore a removed leaf,
    # but preserve any replacement the user created while installation ran.
    for NAME in agentmix .agentmix-launcher.sha256; do
      if [ -f "$LAUNCH_STAGE/previous-$NAME" ] && [ ! -e "$BIN_DIR/$NAME" ] && [ ! -L "$BIN_DIR/$NAME" ]; then
        mv "$LAUNCH_STAGE/previous-$NAME" "$BIN_DIR/$NAME"
      fi
    done
  fi
  [ -z "$LAUNCH_STAGE" ] || rm -rf "$LAUNCH_STAGE"
  if [ -n "$BACKUP" ] && [ -d "$BACKUP" ] && [ ! -e "$SOURCE_DIR" ]; then mv "$BACKUP" "$SOURCE_DIR"; fi
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  rm -f "$LOCK/marketplaces.json" "$LOCK/legacy-codex-plan.json" "$LOCK/codex-plugins.json" "$LOCK/legacy-command-expected" "$LOCK/legacy-command-alias" "$LOCK"/launcher-*
  rm -rf "$LOCK/legacy-codex-expected"
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -e "$SOURCE_DIR" ]; then
  agentmix_owned_file "$SOURCE_DIR/.agentmix-source"
  [ "$(cat "$SOURCE_DIR/.agentmix-source")" = 'AgentMix source checkout v1' ] || agentmix_fail 'An unrecognized source checkout was kept.'
  agentmix_owned_directory "$SOURCE_DIR/.git"
  agentmix_clean_checkout "$SOURCE_DIR"
  if [ -f "$SOURCE_DIR/dev/agentmix.sh" ]; then
    agentmix_owned_file "$SOURCE_DIR/dev/agentmix.sh"
    cp "$SOURCE_DIR/dev/agentmix.sh" "$LOCK/legacy-command-expected"
  fi
  # Preserve only this bounded package from the clean owned prior checkout,
  # before the durable source is replaced with the newly named plugin.
  if [ -n "$CODEX" ] && [ -d "$SOURCE_DIR/Plugins/codex-agentmix" ]; then
    agentmix_owned_directory "$SOURCE_DIR/Plugins/codex-agentmix"
    ditto "$SOURCE_DIR/Plugins/codex-agentmix" "$LOCK/legacy-codex-expected"
  fi
fi
if [ "$PROJECT_DIR" != "$SOURCE_DIR" ]; then
  agentmix_clean_checkout "$PROJECT_DIR"
  STAGE=$(mktemp -d "$SUPPORT_DIR/.source-stage.XXXXXX")
  git clone --quiet --no-hardlinks "$PROJECT_DIR" "$STAGE/source"
  ORIGIN=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN" ]; then git -C "$STAGE/source" remote set-url origin "$ORIGIN"; else git -C "$STAGE/source" remote remove origin; fi
  printf 'AgentMix source checkout v1\n' > "$STAGE/source/.agentmix-source"
  if [ -e "$SOURCE_DIR" ]; then
    BACKUP="$STAGE/previous-source"
    mv "$SOURCE_DIR" "$BACKUP"
  fi
  mv "$STAGE/source" "$SOURCE_DIR"
fi
# All subsequent paths live in the durable checkout, independent of the clone's location.
for NAME in standmixer; do
  COMMAND="$BIN_DIR/$NAME"
  COMMAND_RECEIPT="$BIN_DIR/.$NAME-launcher.sha256"
  for ITEM in "$COMMAND" "$COMMAND_RECEIPT"; do [ ! -L "$ITEM" ] || agentmix_fail 'A StandMixer launcher path is redirected.'; done
  if [ -e "$COMMAND" ]; then
    agentmix_owned_file "$COMMAND"
    agentmix_owned_file "$COMMAND_RECEIPT"
    [ "$(agentmix_hash "$COMMAND")" = "$(cat "$COMMAND_RECEIPT")" ] || agentmix_fail 'The installed StandMixer launcher was modified. It was kept.'
  elif [ -e "$COMMAND_RECEIPT" ]; then
    agentmix_owned_file "$COMMAND_RECEIPT"
  fi
done
# Retire only a byte-exact generated alias (or the launcher from the clean owned
# previous checkout) with its matching receipt. Never adopt a user replacement.
cat > "$LOCK/legacy-command-alias" <<'ALIAS'
#!/bin/sh
# Managed by AgentMix: legacy command alias v1.
set -eu
BIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$BIN_DIR/standmixer" "$@"
ALIAS
RETIRE_LEGACY=no
LEGACY_COMMAND="$BIN_DIR/agentmix"
LEGACY_RECEIPT="$BIN_DIR/.agentmix-launcher.sha256"
if [ -e "$LEGACY_COMMAND" ] || [ -L "$LEGACY_COMMAND" ] || [ -e "$LEGACY_RECEIPT" ] || [ -L "$LEGACY_RECEIPT" ]; then
  if (
    agentmix_owned_file "$LEGACY_COMMAND"
    agentmix_owned_file "$LEGACY_RECEIPT"
    [ "$(stat -f %z "$LEGACY_RECEIPT")" = 65 ] || exit 1
    { cmp -s "$LOCK/legacy-command-alias" "$LEGACY_COMMAND" ||
      { [ -f "$LOCK/legacy-command-expected" ] && cmp -s "$LOCK/legacy-command-expected" "$LEGACY_COMMAND"; }; } &&
      [ "$(agentmix_hash "$LEGACY_COMMAND")" = "$(cat "$LEGACY_RECEIPT")" ]
  ) >/dev/null 2>&1; then
    RETIRE_LEGACY=yes
    LAUNCH_NAMES="$LAUNCH_NAMES agentmix .agentmix-launcher.sha256"
  else
    printf 'Preserved the modified, unowned, or unverified legacy command at %s.\n' "$LEGACY_COMMAND"
  fi
fi
for NAME in $LAUNCH_NAMES; do
  if [ -e "$BIN_DIR/$NAME" ]; then
    agentmix_hash "$BIN_DIR/$NAME" > "$LOCK/launcher-$NAME"
  else
    printf 'absent\n' > "$LOCK/launcher-$NAME"
  fi
done
/bin/sh "$SOURCE_DIR/dev/install-codex-ui.sh"
ENGINE="$SUPPORT_DIR/runtime/AgentMixHelper"
rollback_new_codex() {
  ROLLBACK_CLI=$1
  "$ROLLBACK_CLI" plugin list --json --marketplace drydock-standmixer > "$LOCK/codex-plugins.json"
  "$ENGINE" --installer-codex-package canonical-check "$SOURCE_DIR" < "$LOCK/codex-plugins.json" || agentmix_fail 'The new Codex plugin changed during migration. Both named caches and the private legacy backup were kept. Resolve the two named plugins explicitly.'
  "$ROLLBACK_CLI" plugin remove standmixer@drydock-standmixer || agentmix_fail 'Codex could not remove the unchanged new plugin during rollback. The named caches and private legacy backup were kept.'
}
restore_claude_registration() {
  [ -n "$PREVIOUS_CANONICAL" ] || return 0
  "$CLI" plugin marketplace list --json > "$LOCK/marketplaces.json"
  CURRENT=$("$ENGINE" --installer-marketplace-source claude drydock-standmixer < "$LOCK/marketplaces.json") || CURRENT=
  [ "$CURRENT" = "$MARKETPLACE_SOURCE" ] || agentmix_fail 'The Claude marketplace changed during installation. Its registrations were kept for explicit recovery.'
  "$CLI" plugin marketplace remove drydock-standmixer --scope user
  "$CLI" plugin marketplace add "$PREVIOUS_CANONICAL" || agentmix_fail 'Claude could not restore the prior marketplace registration. Its plugin cache and data were kept.'
}
install_plugin() {
  PLATFORM=$1
  CLI=$2
  PREVIOUS_CANONICAL=
  MARKETPLACE_SOURCE="$SOURCE_DIR"
  INVOKING_MARKETPLACE_SOURCE="$PROJECT_DIR"
  if [ "$PLATFORM" = claude ]; then
    # Claude deduplicates a declared directory before reading a renamed
    # manifest. A distinct owned root lets the legacy registration remain
    # usable until the new plugin has installed successfully.
    MARKETPLACE_SOURCE="$SOURCE_DIR/Plugins/claude-agentmix"
    INVOKING_MARKETPLACE_SOURCE="$PROJECT_DIR/Plugins/claude-agentmix"
  fi
  agentmix_owned_directory "$MARKETPLACE_SOURCE"
  "$CLI" plugin marketplace list --json > "$LOCK/marketplaces.json"
  LEGACY_REGISTERED=
  if LEGACY_REGISTERED=$("$ENGINE" --installer-marketplace-source "$PLATFORM" drydock-agentmix < "$LOCK/marketplaces.json"); then
    [ "$LEGACY_REGISTERED" = "$SOURCE_DIR" ] || [ "$LEGACY_REGISTERED" = "$PROJECT_DIR" ] || agentmix_fail "The legacy drydock-agentmix marketplace belongs to another source ($LEGACY_REGISTERED). It was kept. Migrate it explicitly before installing StandMixer."
    if [ "$PLATFORM" = codex ]; then
      [ -d "$LOCK/legacy-codex-expected" ] || agentmix_fail 'The legacy Codex plugin was kept. Its unchanged prior package is unavailable; no duplicate was installed.'
      "$CLI" plugin list --json --marketplace drydock-agentmix > "$LOCK/codex-plugins.json"
      "$ENGINE" --installer-codex-package prepare "$LEGACY_REGISTERED" < "$LOCK/codex-plugins.json" > "$LOCK/legacy-codex-plan.json"
      chmod 600 "$LOCK/legacy-codex-plan.json"
    fi
  else
    PARSE_STATUS=$?
    [ "$PARSE_STATUS" = 3 ] || agentmix_fail "Could not safely identify the legacy $PLATFORM marketplace. It was kept."
    LEGACY_REGISTERED=
  fi
  if REGISTERED=$("$ENGINE" --installer-marketplace-source "$PLATFORM" drydock-standmixer < "$LOCK/marketplaces.json"); then
    if [ "$REGISTERED" != "$MARKETPLACE_SOURCE" ]; then
      [ "$REGISTERED" = "$PROJECT_DIR" ] || [ "$REGISTERED" = "$SOURCE_DIR" ] || [ "$REGISTERED" = "$INVOKING_MARKETPLACE_SOURCE" ] || agentmix_fail "The drydock-standmixer marketplace belongs to another source ($REGISTERED). It was kept. Remove or migrate it explicitly before installing."
      # Migrate only this exact checkout, which the caller explicitly trusted.
      if [ "$PLATFORM" = claude ]; then
        [ "$REGISTERED" != "$LEGACY_REGISTERED" ] || agentmix_fail 'Two Claude marketplace names share the same declared directory. They were kept; resolve that existing alias before retargeting.'
        PREVIOUS_CANONICAL=$REGISTERED
        "$CLI" plugin marketplace remove drydock-standmixer --scope user
      else
        "$CLI" plugin marketplace remove drydock-standmixer
      fi
      if ! "$CLI" plugin marketplace add "$MARKETPLACE_SOURCE"; then
        "$CLI" plugin marketplace add "$REGISTERED" || true
        agentmix_fail 'Could not migrate the local marketplace. The prior source was restored where possible.'
      fi
    fi
  else
    PARSE_STATUS=$?
    [ "$PARSE_STATUS" = 3 ] || agentmix_fail "Could not safely identify the $PLATFORM marketplace. Update the CLI, or check plugin marketplace list --json."
    "$CLI" plugin marketplace add "$MARKETPLACE_SOURCE"
  fi
  "$CLI" plugin marketplace list --json > "$LOCK/marketplaces.json"
  REGISTERED=$("$ENGINE" --installer-marketplace-source "$PLATFORM" drydock-standmixer < "$LOCK/marketplaces.json") || REGISTERED=
  [ "$REGISTERED" = "$MARKETPLACE_SOURCE" ] || agentmix_fail 'The CLI did not register the expected owned StandMixer marketplace. Installation stopped before changing plugins.'
  if [ "$PLATFORM" = codex ]; then
    "$CLI" plugin add standmixer@drydock-standmixer
    if [ -n "$LEGACY_REGISTERED" ]; then
      "$CLI" plugin marketplace list --json > "$LOCK/marketplaces.json"
      CURRENT_LEGACY=$("$ENGINE" --installer-marketplace-source codex drydock-agentmix < "$LOCK/marketplaces.json") || CURRENT_LEGACY=
      "$CLI" plugin list --json --marketplace drydock-agentmix > "$LOCK/codex-plugins.json"
      if [ "$CURRENT_LEGACY" = "$LEGACY_REGISTERED" ] &&
         "$ENGINE" --installer-codex-package check "$LEGACY_REGISTERED" < "$LOCK/codex-plugins.json"; then
        if ! "$CLI" plugin remove agentmix@drydock-agentmix; then
          rollback_new_codex "$CLI"
          agentmix_fail 'The legacy Codex plugin could not be retired. The unchanged new copy was removed; legacy files and the private backup were kept.'
        fi
      else
        rollback_new_codex "$CLI"
        agentmix_fail 'The legacy Codex plugin changed during migration. The unchanged new copy was removed; all legacy files and the private backup were kept.'
      fi
      "$CLI" plugin marketplace remove drydock-agentmix
    fi
  else
    # Directory plugins load in place, but install alone keeps the old recorded
    # version. Refresh that metadata without removing the plugin or its data.
    if "$CLI" plugin install standmixer@drydock-standmixer --scope user &&
       "$CLI" plugin update standmixer@drydock-standmixer --scope user; then
      :
    else
      if [ -n "$LEGACY_REGISTERED" ]; then
        "$CLI" plugin disable standmixer@drydock-standmixer --scope user || true
      fi
      restore_claude_registration
      agentmix_fail 'Could not install the StandMixer Claude plugin. The legacy plugin, cached files, and data were kept.'
    fi
    if [ -n "$LEGACY_REGISTERED" ]; then
      # Native disable keeps cached files and persistent plugin data. Only after
      # the new plugin succeeds do we retire the exact owned legacy identity.
      if ! "$CLI" plugin disable agentmix@drydock-agentmix --scope user; then
        "$CLI" plugin disable standmixer@drydock-standmixer --scope user || agentmix_fail 'Could not disable either plugin. Review the two named Claude plugins before continuing.'
        agentmix_fail 'The legacy Claude plugin could not be disabled. The new StandMixer plugin was disabled; legacy files and data were kept.'
      fi
      "$CLI" plugin marketplace remove drydock-agentmix --scope user
    fi
  fi
}
[ -z "$CODEX" ] || install_plugin codex "$CODEX"
[ -z "$CLAUDE" ] || install_plugin claude "$CLAUDE"
"$ENGINE" --standmixer install --yes
LAUNCH_STAGE=$(mktemp -d "$BIN_DIR/.command-stage.XXXXXX")
cp "$SOURCE_DIR/dev/agentmix.sh" "$LAUNCH_STAGE/standmixer"
chmod 700 "$LAUNCH_STAGE/standmixer"
agentmix_hash "$LAUNCH_STAGE/standmixer" > "$LAUNCH_STAGE/.standmixer-launcher.sha256"
# Preserve prior owned files until canonical publication and retirement finish.
for NAME in $LAUNCH_NAMES; do
  if [ -e "$BIN_DIR/$NAME" ]; then
    agentmix_owned_file "$BIN_DIR/$NAME"
    [ "$(agentmix_hash "$BIN_DIR/$NAME")" = "$(cat "$LOCK/launcher-$NAME")" ] || agentmix_fail 'A launcher changed during installation. It was kept.'
    cp -p "$BIN_DIR/$NAME" "$LAUNCH_STAGE/previous-$NAME"
  else
    [ ! -L "$BIN_DIR/$NAME" ] || agentmix_fail 'A StandMixer launcher path is redirected.'
    [ "$(cat "$LOCK/launcher-$NAME")" = absent ] || agentmix_fail 'A launcher disappeared during installation. It was kept.'
    : > "$LAUNCH_STAGE/absent-$NAME"
  fi
done
RETIRED_BACKUP=
if [ "$RETIRE_LEGACY" = yes ]; then
  RETIRED_ROOT="$SUPPORT_DIR/retired-commands"
  agentmix_owned_directory "$RETIRED_ROOT"
  mkdir -p "$RETIRED_ROOT"
  RETIRED_BACKUP=$(mktemp -d "$RETIRED_ROOT/agentmix.XXXXXX")
  cp -p "$LAUNCH_STAGE/previous-agentmix" "$RETIRED_BACKUP/agentmix"
  cp -p "$LAUNCH_STAGE/previous-.agentmix-launcher.sha256" "$RETIRED_BACKUP/.agentmix-launcher.sha256"
fi
LAUNCH_PENDING=yes
for NAME in standmixer .standmixer-launcher.sha256; do
  mv "$LAUNCH_STAGE/$NAME" "$BIN_DIR/$NAME"
done
if [ "$RETIRE_LEGACY" = yes ]; then
  agentmix_owned_file "$LEGACY_COMMAND"
  agentmix_owned_file "$LEGACY_RECEIPT"
  [ "$(agentmix_hash "$LEGACY_COMMAND")" = "$(cat "$LOCK/launcher-agentmix")" ] &&
    [ "$(agentmix_hash "$LEGACY_RECEIPT")" = "$(cat "$LOCK/launcher-.agentmix-launcher.sha256")" ] || agentmix_fail 'The legacy command changed during installation. It was kept.'
  rm "$LEGACY_COMMAND" "$LEGACY_RECEIPT"
fi
LAUNCH_PENDING=no
[ -z "$RETIRED_BACKUP" ] || printf 'Retired the verified owned legacy command. Recovery copies: %s\n' "$RETIRED_BACKUP"
printf 'StandMixer installed. Existing models and presets were kept.\nCommand: "$HOME/Library/Application Support/AgentMix/bin/standmixer"\n'
if [ "$HOST" = codex ]; then
  "$BIN_DIR/standmixer" settings --host codex
elif [ "$OPEN" = yes ]; then
  if [ -n "$HOST" ]; then "$BIN_DIR/standmixer" settings --host "$HOST"; else "$BIN_DIR/standmixer" settings; fi
fi
