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
    --host) [ "$#" -ge 2 ] || standmixer_fail 'Use --host codex or --host claude.'; HOST=$2; shift 2 ;;
    --no-open) OPEN=no; shift ;;
    --help|-h) printf 'Usage: sh install.sh [--host codex|claude] [--no-open]\n'; exit 0 ;;
    *) standmixer_fail "Unknown option: $1" ;;
  esac
done
case "$HOST" in ''|codex|claude) ;; *) standmixer_fail 'Use --host codex or --host claude.' ;; esac
standmixer_darwin
[ -n "${HOME:-}" ] || standmixer_fail 'HOME must name your home directory.'
SUPPORT_DIR="$HOME/Library/Application Support/StandMixer"
SOURCE_DIR="$SUPPORT_DIR/source"
BIN_DIR="$SUPPORT_DIR/bin"
standmixer_owned_directory "$SUPPORT_DIR"
standmixer_owned_directory "$BIN_DIR"
standmixer_owned_directory "$SOURCE_DIR"
CODEX=$(standmixer_find_cli codex)
CLAUDE=$(standmixer_find_cli claude)
[ -n "$CODEX$CLAUDE" ] || standmixer_fail 'Install Codex or Claude Code first, then rerun this installer.'
[ "$HOST" != codex ] || [ -n "$CODEX" ] || standmixer_fail 'Codex was not found in PATH or known installation locations. Install it or use --host claude.'
[ "$HOST" != claude ] || [ -n "$CLAUDE" ] || standmixer_fail 'Claude Code was not found in PATH or known installation locations. Install it or use --host codex.'
# Check only the selected configuration roots; do not inspect accounts or home folders.
[ -z "$CODEX" ] || standmixer_owned_directory "${CODEX_HOME:-$HOME/.codex}"
[ -z "$CLAUDE" ] || standmixer_owned_directory "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
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
[ ! -L "$LOCK" ] || standmixer_fail 'The source install lock is redirected.'
mkdir "$LOCK" 2>/dev/null || standmixer_fail "Another source or Mac installation may be running. Wait for it to finish before retrying. Lock: $LOCK"
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
  fi
  [ -z "$LAUNCH_STAGE" ] || rm -rf "$LAUNCH_STAGE"
  if [ -n "$BACKUP" ] && [ -d "$BACKUP" ] && [ ! -e "$SOURCE_DIR" ]; then mv "$BACKUP" "$SOURCE_DIR"; fi
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  rm -f "$LOCK/marketplaces.json" "$LOCK"/launcher-*
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -e "$SOURCE_DIR" ]; then
  standmixer_owned_file "$SOURCE_DIR/.standmixer-source"
  [ "$(cat "$SOURCE_DIR/.standmixer-source")" = 'StandMixer source checkout v1' ] || standmixer_fail 'An unrecognized source checkout was kept.'
  standmixer_owned_directory "$SOURCE_DIR/.git"
  standmixer_clean_checkout "$SOURCE_DIR"

fi
if [ "$PROJECT_DIR" != "$SOURCE_DIR" ]; then
  standmixer_clean_checkout "$PROJECT_DIR"
  STAGE=$(mktemp -d "$SUPPORT_DIR/.source-stage.XXXXXX")
  git clone --quiet --no-hardlinks "$PROJECT_DIR" "$STAGE/source"
  ORIGIN=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN" ]; then git -C "$STAGE/source" remote set-url origin "$ORIGIN"; else git -C "$STAGE/source" remote remove origin; fi
  printf 'StandMixer source checkout v1\n' > "$STAGE/source/.standmixer-source"
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
  for ITEM in "$COMMAND" "$COMMAND_RECEIPT"; do [ ! -L "$ITEM" ] || standmixer_fail 'A StandMixer launcher path is redirected.'; done
  if [ -e "$COMMAND" ]; then
    standmixer_owned_file "$COMMAND"
    standmixer_owned_file "$COMMAND_RECEIPT"
    [ "$(standmixer_hash "$COMMAND")" = "$(cat "$COMMAND_RECEIPT")" ] || standmixer_fail 'The installed StandMixer launcher was modified. It was kept.'
  elif [ -e "$COMMAND_RECEIPT" ]; then
    standmixer_owned_file "$COMMAND_RECEIPT"
  fi
done
for NAME in $LAUNCH_NAMES; do
  if [ -e "$BIN_DIR/$NAME" ]; then
    standmixer_hash "$BIN_DIR/$NAME" > "$LOCK/launcher-$NAME"
  else
    printf 'absent\n' > "$LOCK/launcher-$NAME"
  fi
done
/bin/sh "$SOURCE_DIR/dev/install-codex-ui.sh"
ENGINE="$SUPPORT_DIR/runtime/StandMixerHelper"
restore_claude_registration() {
  [ -n "$PREVIOUS_CANONICAL" ] || return 0
  "$CLI" plugin marketplace list --json > "$LOCK/marketplaces.json"
  CURRENT=$("$ENGINE" --installer-marketplace-source claude drydock-standmixer < "$LOCK/marketplaces.json") || CURRENT=
  [ "$CURRENT" = "$MARKETPLACE_SOURCE" ] || standmixer_fail 'The Claude marketplace changed during installation. Its registrations were kept for explicit recovery.'
  "$CLI" plugin marketplace remove drydock-standmixer --scope user
  "$CLI" plugin marketplace add "$PREVIOUS_CANONICAL" || standmixer_fail 'Claude could not restore the prior marketplace registration. Its plugin cache and data were kept.'
}
install_plugin() {
  PLATFORM=$1
  CLI=$2
  PREVIOUS_CANONICAL=
  MARKETPLACE_SOURCE="$SOURCE_DIR"
  INVOKING_MARKETPLACE_SOURCE="$PROJECT_DIR"
  if [ "$PLATFORM" = claude ]; then
    MARKETPLACE_SOURCE="$SOURCE_DIR/Plugins/claude-standmixer"
    INVOKING_MARKETPLACE_SOURCE="$PROJECT_DIR/Plugins/claude-standmixer"
  fi
  standmixer_owned_directory "$MARKETPLACE_SOURCE"
  "$CLI" plugin marketplace list --json > "$LOCK/marketplaces.json"
  if REGISTERED=$("$ENGINE" --installer-marketplace-source "$PLATFORM" drydock-standmixer < "$LOCK/marketplaces.json"); then
    if [ "$REGISTERED" != "$MARKETPLACE_SOURCE" ]; then
      [ "$REGISTERED" = "$PROJECT_DIR" ] || [ "$REGISTERED" = "$SOURCE_DIR" ] || [ "$REGISTERED" = "$INVOKING_MARKETPLACE_SOURCE" ] || standmixer_fail "The drydock-standmixer marketplace belongs to another source ($REGISTERED). It was kept. Remove or migrate it explicitly before installing."
      # Migrate only this exact checkout, which the caller explicitly trusted.
      if [ "$PLATFORM" = claude ]; then
        PREVIOUS_CANONICAL=$REGISTERED
        "$CLI" plugin marketplace remove drydock-standmixer --scope user
      else
        "$CLI" plugin marketplace remove drydock-standmixer
      fi
      if ! "$CLI" plugin marketplace add "$MARKETPLACE_SOURCE"; then
        "$CLI" plugin marketplace add "$REGISTERED" || true
        standmixer_fail 'Could not migrate the local marketplace. The prior source was restored where possible.'
      fi
    fi
  else
    PARSE_STATUS=$?
    [ "$PARSE_STATUS" = 3 ] || standmixer_fail "Could not safely identify the $PLATFORM marketplace. Update the CLI, or check plugin marketplace list --json."
    "$CLI" plugin marketplace add "$MARKETPLACE_SOURCE"
  fi
  "$CLI" plugin marketplace list --json > "$LOCK/marketplaces.json"
  REGISTERED=$("$ENGINE" --installer-marketplace-source "$PLATFORM" drydock-standmixer < "$LOCK/marketplaces.json") || REGISTERED=
  [ "$REGISTERED" = "$MARKETPLACE_SOURCE" ] || standmixer_fail 'The CLI did not register the expected owned StandMixer marketplace. Installation stopped before changing plugins.'
  if [ "$PLATFORM" = codex ]; then
    "$CLI" plugin add standmixer@drydock-standmixer

  else
    # Directory plugins load in place, but install alone keeps the old recorded
    # version. Refresh that metadata without removing the plugin or its data.
    if "$CLI" plugin install standmixer@drydock-standmixer --scope user &&
       "$CLI" plugin update standmixer@drydock-standmixer --scope user; then
      :
    else
      restore_claude_registration
      standmixer_fail 'Could not install the StandMixer Claude plugin. The prior registration was restored where possible.'
    fi
  fi
}
# Old releases are removed once, never used as runtime path fallbacks.
/bin/sh "$SOURCE_DIR/dev/retire-old-install.sh"
[ -z "$CODEX" ] || install_plugin codex "$CODEX"
[ -z "$CLAUDE" ] || install_plugin claude "$CLAUDE"
"$ENGINE" --standmixer install --yes
LAUNCH_STAGE=$(mktemp -d "$BIN_DIR/.command-stage.XXXXXX")
cp "$SOURCE_DIR/dev/standmixer.sh" "$LAUNCH_STAGE/standmixer"
chmod 700 "$LAUNCH_STAGE/standmixer"
standmixer_hash "$LAUNCH_STAGE/standmixer" > "$LAUNCH_STAGE/.standmixer-launcher.sha256"
# Preserve prior owned files until launcher publication finishes.
for NAME in $LAUNCH_NAMES; do
  if [ -e "$BIN_DIR/$NAME" ]; then
    standmixer_owned_file "$BIN_DIR/$NAME"
    [ "$(standmixer_hash "$BIN_DIR/$NAME")" = "$(cat "$LOCK/launcher-$NAME")" ] || standmixer_fail 'A launcher changed during installation. It was kept.'
    cp -p "$BIN_DIR/$NAME" "$LAUNCH_STAGE/previous-$NAME"
  else
    [ ! -L "$BIN_DIR/$NAME" ] || standmixer_fail 'A StandMixer launcher path is redirected.'
    [ "$(cat "$LOCK/launcher-$NAME")" = absent ] || standmixer_fail 'A launcher disappeared during installation. It was kept.'
    : > "$LAUNCH_STAGE/absent-$NAME"
  fi
done
LAUNCH_PENDING=yes
for NAME in standmixer .standmixer-launcher.sha256; do
  mv "$LAUNCH_STAGE/$NAME" "$BIN_DIR/$NAME"
done
LAUNCH_PENDING=no
printf 'StandMixer installed. Existing models and presets were kept.\nCommand: "$HOME/Library/Application Support/StandMixer/bin/standmixer"\n'
if [ "$HOST" = codex ]; then
  "$BIN_DIR/standmixer" settings --host codex
elif [ "$OPEN" = yes ]; then
  if [ -n "$HOST" ]; then "$BIN_DIR/standmixer" settings --host "$HOST"; else "$BIN_DIR/standmixer" settings; fi
fi
