#!/bin/sh
# Shared filesystem checks for the local, no-inference installers.
standmixer_fail() { printf 'StandMixer: %s\n' "$*" >&2; exit 1; }
standmixer_safe_path() {
  case "$1" in /*) ;; *) standmixer_fail "Use an absolute path: $1" ;; esac
  case "$1" in *'
'*) standmixer_fail 'Install paths cannot contain newlines.' ;; esac
  standmixer_check=$1
  while [ "$standmixer_check" != / ]; do
    if [ -L "$standmixer_check" ]; then standmixer_fail "Refusing a redirected install path: $standmixer_check"; fi
    if [ -e "$standmixer_check" ] && [ ! -d "$standmixer_check" ]; then standmixer_fail "Expected a directory: $standmixer_check"; fi
    standmixer_check=$(dirname -- "$standmixer_check")
  done
}
standmixer_owned_file() {
  standmixer_safe_path "$(dirname -- "$1")"
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -f %u "$1")" = "$(id -u)" ] && [ "$(stat -f %l "$1")" = 1 ] || standmixer_fail "Refusing an unsafe or unowned file: $1"
}
standmixer_owned_directory() {
  standmixer_safe_path "$1"
  [ ! -e "$1" ] || [ "$(stat -f %u "$1")" = "$(id -u)" ] || standmixer_fail "Refusing an unowned directory: $1"
}
standmixer_hash() {
  standmixer_digest=$(shasum -a 256 "$1") || standmixer_fail "Could not hash $1 safely."
  printf '%s\n' "$standmixer_digest" | awk '{print $1}'
}
standmixer_clean_checkout() {
  standmixer_git_root=$(git -C "$1" rev-parse --show-toplevel) || standmixer_fail "The checkout is unavailable: $1"
  [ "$standmixer_git_root" = "$1" ] || standmixer_fail "Expected the complete StandMixer Git checkout at $1"
  standmixer_git_changes=$(git -C "$1" status --porcelain --untracked-files=all) || standmixer_fail "Could not verify the checkout at $1"
  [ -z "$(printf '%s\n' "$standmixer_git_changes" | sed '/^?? \.standmixer-source$/d')" ] || standmixer_fail "The checkout has local changes. They were kept. Review $1 before installing."
}
standmixer_darwin() {
  [ "$(uname -s)" = Darwin ] || standmixer_fail 'StandMixer requires macOS 14 or newer. The embedded plugins remain available on a supported Mac.'
  standmixer_major=$(sw_vers -productVersion | cut -d . -f 1)
  [ "$standmixer_major" -ge 14 ] || standmixer_fail 'StandMixer requires macOS 14 or newer.'
}
# Prefer the caller's explicit PATH. Fallback probes are fixed executable leaves;
# they never enumerate a home folder, app-data store, or native version store.
standmixer_find_cli() {
  standmixer_platform=$1
  standmixer_selected=$(command -v "$standmixer_platform" || true)
  if [ -n "$standmixer_selected" ]; then printf '%s\n' "$standmixer_selected"; return; fi
  standmixer_candidate="$HOME/.local/bin/$standmixer_platform"
  if [ -f "$standmixer_candidate" ] && [ -x "$standmixer_candidate" ]; then printf '%s\n' "$standmixer_candidate"; return; fi
  standmixer_applications=${STANDMIXER_APPLICATIONS_DIR:-/Applications}
  case "$standmixer_applications" in /*) ;; *) standmixer_fail 'STANDMIXER_APPLICATIONS_DIR must name an absolute application folder.' ;; esac
  case "$standmixer_platform" in
    codex) set -- ChatGPT.app Codex.app ;;
    claude) set -- Claude.app ;;
    *) standmixer_fail 'Unknown CLI platform.' ;;
  esac
  for standmixer_parent in "$HOME/Applications" "$standmixer_applications"; do
    for standmixer_app in "$@"; do
      standmixer_resources="$standmixer_parent/$standmixer_app/Contents/Resources"
      if [ "$standmixer_platform" = codex ]; then
        for standmixer_relative in codex-cli/CodexCLI.app/Contents/MacOS/codex codex-cli/bin/codex codex-cli/codex bin/codex codex; do
          if standmixer_bundled_cli "$standmixer_resources/$standmixer_relative"; then printf '%s\n' "$standmixer_resources/$standmixer_relative"; return; fi
        done
      else
        for standmixer_relative in claude-code/claude.app/Contents/MacOS/claude claude-code/claude bin/claude claude; do
          if standmixer_bundled_cli "$standmixer_resources/$standmixer_relative"; then printf '%s\n' "$standmixer_resources/$standmixer_relative"; return; fi
        done
      fi
    done
  done
}
standmixer_bundled_cli() {
  [ -f "$1" ] && [ -x "$1" ] && [ ! -L "$1" ] || return 1
  standmixer_bundle_parent=$(dirname -- "$1")
  while [ "$standmixer_bundle_parent" != / ]; do
    [ ! -L "$standmixer_bundle_parent" ] || return 1
    standmixer_bundle_parent=$(dirname -- "$standmixer_bundle_parent")
  done
}
