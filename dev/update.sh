#!/bin/sh
# Explicit updates use the public source and the existing checked installer.
set -eu
umask 077
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
. "$SCRIPT_DIR/install-common.sh"
WITH_MAC=no
case "$#:${1:-}" in
  0:) ;;
  1:--mac) WITH_MAC=yes ;;
  1:--help|1:-h) printf 'Usage: standmixer update [--mac]\nUpdate installed plugins and source; --mac also builds the optional Mac app. Presets and model defaults are kept.\n'; exit 0 ;;
  *) standmixer_fail 'Usage: standmixer update [--mac]' ;;
esac
standmixer_darwin
SUPPORT_DIR="${HOME:?HOME must be set}/Library/Application Support/StandMixer"
SOURCE_DIR="$SUPPORT_DIR/source"
[ "$PROJECT_DIR" = "$SOURCE_DIR" ] || standmixer_fail 'Use the installed StandMixer launcher to update. Run install.sh from your trusted checkout first.'
standmixer_owned_directory "$SUPPORT_DIR"
standmixer_owned_directory "$SOURCE_DIR"
standmixer_owned_directory "$SOURCE_DIR/.git"
standmixer_owned_file "$SOURCE_DIR/.standmixer-source"
[ "$(cat "$SOURCE_DIR/.standmixer-source")" = 'StandMixer source checkout v1' ] || standmixer_fail 'The installed source is unrecognized; it was kept.'
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
standmixer_clean_checkout "$SOURCE_DIR"
ORIGIN=$(git -C "$SOURCE_DIR" remote get-url origin) || standmixer_fail 'The installed source has no update origin. Rerun the official installer.'
case "$ORIGIN" in
  https://github.com/drydockbuild/standmixer|https://github.com/drydockbuild/standmixer.git|git@github.com:drydockbuild/standmixer.git|ssh://git@github.com/drydockbuild/standmixer.git) ;;
  *) standmixer_fail 'This installation uses another source repository. Update that checkout manually; it was kept.' ;;
esac
CURRENT=$(git -C "$SOURCE_DIR" rev-parse HEAD)
STAGE=
cleanup() { [ -z "$STAGE" ] || rm -rf "$STAGE"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/standmixer-update.XXXXXX")
printf 'Checking for StandMixer updates…\n'
GIT_TERMINAL_PROMPT=0 git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=60 clone --depth 1 --branch main https://github.com/drydockbuild/standmixer.git "$STAGE/source"
NEXT=$(git -C "$STAGE/source" rev-parse HEAD)
if [ "$CURRENT" = "$NEXT" ]; then
  printf 'Source is current; refreshing installed plugins.\n'
else
  printf 'Updating StandMixer from %.12s to %.12s…\n' "$CURRENT" "$NEXT"
fi
# Always reconcile the install, even when a previous attempt staged this commit
# but stopped before finishing plugin registration. The installer owns its lock.
/bin/sh "$STAGE/source/install.sh" --no-open
if [ "$WITH_MAC" = yes ]; then
  if /bin/sh "$SOURCE_DIR/dev/install-mac.sh" --no-open; then :; else
    RESULT=$?
    printf 'StandMixer plugins were updated, but the Mac app update did not finish. Check the build output above, then retry install-mac.\n' >&2
    exit "$RESULT"
  fi
fi
printf 'StandMixer updated to %.12s. Presets and model defaults were kept.\n' "$NEXT"
printf 'Reload plugins in Claude Code or restart Codex if the new version has not loaded.\n'
if [ "$WITH_MAC" = yes ]; then printf 'Reopen the Mac app to use its updated build.\n'; fi
