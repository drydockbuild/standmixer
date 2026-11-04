#!/bin/sh
# Shared filesystem checks for the local, no-inference installers.
agentmix_fail() { printf 'StandMixer: %s\n' "$*" >&2; exit 1; }
agentmix_safe_path() {
  case "$1" in /*) ;; *) agentmix_fail "Use an absolute path: $1" ;; esac
  case "$1" in *'
'*) agentmix_fail 'Install paths cannot contain newlines.' ;; esac
  agentmix_check=$1
  while [ "$agentmix_check" != / ]; do
    if [ -L "$agentmix_check" ]; then agentmix_fail "Refusing a redirected install path: $agentmix_check"; fi
    if [ -e "$agentmix_check" ] && [ ! -d "$agentmix_check" ]; then agentmix_fail "Expected a directory: $agentmix_check"; fi
    agentmix_check=$(dirname -- "$agentmix_check")
  done
}
agentmix_owned_file() {
  agentmix_safe_path "$(dirname -- "$1")"
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -f %u "$1")" = "$(id -u)" ] && [ "$(stat -f %l "$1")" = 1 ] || agentmix_fail "Refusing an unsafe or unowned file: $1"
}
agentmix_owned_directory() {
  agentmix_safe_path "$1"
  [ ! -e "$1" ] || [ "$(stat -f %u "$1")" = "$(id -u)" ] || agentmix_fail "Refusing an unowned directory: $1"
}
agentmix_hash() {
  agentmix_digest=$(shasum -a 256 "$1") || agentmix_fail "Could not hash $1 safely."
  printf '%s\n' "$agentmix_digest" | awk '{print $1}'
}
agentmix_clean_checkout() {
  agentmix_git_root=$(git -C "$1" rev-parse --show-toplevel) || agentmix_fail "The checkout is unavailable: $1"
  [ "$agentmix_git_root" = "$1" ] || agentmix_fail "Expected the complete StandMixer Git checkout at $1"
  agentmix_git_changes=$(git -C "$1" status --porcelain --untracked-files=all) || agentmix_fail "Could not verify the checkout at $1"
  [ -z "$(printf '%s\n' "$agentmix_git_changes" | sed '/^?? \.agentmix-source$/d')" ] || agentmix_fail "The checkout has local changes. They were kept. Review $1 before installing."
}
agentmix_darwin() {
  [ "$(uname -s)" = Darwin ] || agentmix_fail 'StandMixer requires macOS 14 or newer. The embedded plugins remain available on a supported Mac.'
  agentmix_major=$(sw_vers -productVersion | cut -d . -f 1)
  [ "$agentmix_major" -ge 14 ] || agentmix_fail 'StandMixer requires macOS 14 or newer.'
}
# Prefer the caller's explicit PATH. Fallback probes are fixed executable leaves;
# they never enumerate a home folder, app-data store, or native version store.
agentmix_find_cli() {
  agentmix_platform=$1
  agentmix_selected=$(command -v "$agentmix_platform" || true)
  if [ -n "$agentmix_selected" ]; then printf '%s\n' "$agentmix_selected"; return; fi
  agentmix_candidate="$HOME/.local/bin/$agentmix_platform"
  if [ -f "$agentmix_candidate" ] && [ -x "$agentmix_candidate" ]; then printf '%s\n' "$agentmix_candidate"; return; fi
  agentmix_applications=${AGENTMIX_APPLICATIONS_DIR:-/Applications}
  case "$agentmix_applications" in /*) ;; *) agentmix_fail 'AGENTMIX_APPLICATIONS_DIR must name an absolute application folder.' ;; esac
  case "$agentmix_platform" in
    codex) set -- ChatGPT.app Codex.app ;;
    claude) set -- Claude.app ;;
    *) agentmix_fail 'Unknown CLI platform.' ;;
  esac
  for agentmix_parent in "$HOME/Applications" "$agentmix_applications"; do
    for agentmix_app in "$@"; do
      agentmix_resources="$agentmix_parent/$agentmix_app/Contents/Resources"
      if [ "$agentmix_platform" = codex ]; then
        for agentmix_relative in codex-cli/CodexCLI.app/Contents/MacOS/codex codex-cli/bin/codex codex-cli/codex bin/codex codex; do
          if agentmix_bundled_cli "$agentmix_resources/$agentmix_relative"; then printf '%s\n' "$agentmix_resources/$agentmix_relative"; return; fi
        done
      else
        for agentmix_relative in claude-code/claude.app/Contents/MacOS/claude claude-code/claude bin/claude claude; do
          if agentmix_bundled_cli "$agentmix_resources/$agentmix_relative"; then printf '%s\n' "$agentmix_resources/$agentmix_relative"; return; fi
        done
      fi
    done
  done
}
agentmix_bundled_cli() {
  [ -f "$1" ] && [ -x "$1" ] && [ ! -L "$1" ] || return 1
  agentmix_bundle_parent=$(dirname -- "$1")
  while [ "$agentmix_bundle_parent" != / ]; do
    [ ! -L "$agentmix_bundle_parent" ] || return 1
    agentmix_bundle_parent=$(dirname -- "$agentmix_bundle_parent")
  done
}
