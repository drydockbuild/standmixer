#!/bin/sh
# Optional Mac app, built locally from the installed source checkout.
set -eu
umask 077
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/install-common.sh"
OPEN=yes
DEFAULT_DESTINATION=yes
DESTINATION="${HOME:?HOME must be set}/Applications/StandMixer.app"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-open) OPEN=no; shift ;;
    --destination) [ "$#" -ge 2 ] || agentmix_fail 'Use --destination with an absolute StandMixer.app path.'; DESTINATION=$2; DEFAULT_DESTINATION=no; shift 2 ;;
    --help|-h) printf 'Usage: standmixer install-mac [--no-open] [--destination /absolute/path/StandMixer.app]\n'; exit 0 ;;
    *) agentmix_fail "Unknown install-mac option: $1" ;;
  esac
done
agentmix_darwin
SUPPORT_DIR="$HOME/Library/Application Support/AgentMix"
[ "$PROJECT_DIR" = "$SUPPORT_DIR/source" ] || agentmix_fail 'Build the app with the installed standmixer install-mac command. Run the checkout install.sh first.'
agentmix_owned_directory "$PROJECT_DIR"
agentmix_owned_directory "$SUPPORT_DIR/build"
agentmix_owned_file "$PROJECT_DIR/.agentmix-source"
[ "$(cat "$PROJECT_DIR/.agentmix-source")" = 'AgentMix source checkout v1' ] || agentmix_fail 'Reinstall StandMixer from the trusted source checkout.'
case "$DESTINATION" in /*/StandMixer.app|/*/AgentMix.app) ;; *) agentmix_fail 'Use an absolute destination ending in /StandMixer.app (or the legacy /AgentMix.app).' ;; esac
DESTINATION_DIR=$(dirname -- "$DESTINATION")
agentmix_owned_directory "$DESTINATION_DIR"
agentmix_owned_directory "$DESTINATION"
RECEIPT="$SUPPORT_DIR/mac-app.receipt"
RECEIPT_BEFORE=
APP_PRESENT=no
APP_BEFORE_HASH=
EXISTING_APP="$DESTINATION"
LEGACY_APP="$HOME/Applications/AgentMix.app"
if [ -e "$RECEIPT" ] || [ -L "$RECEIPT" ]; then
  agentmix_owned_file "$RECEIPT"
  RECEIPT_BEFORE=$(agentmix_hash "$RECEIPT")
fi
# A legacy app is considered only at this fixed leaf and only for the default
# destination. A changed or unowned copy is preserved while StandMixer installs.
if [ "$DEFAULT_DESTINATION" = yes ] && [ ! -e "$DESTINATION" ] && { [ -e "$LEGACY_APP" ] || [ -L "$LEGACY_APP" ]; }; then
  if [ -f "$RECEIPT" ] && [ "$(sed -n '1p' "$RECEIPT")" = "$LEGACY_APP" ] && (
    agentmix_owned_directory "$LEGACY_APP"
    agentmix_owned_file "$LEGACY_APP/Contents/MacOS/AgentMix"
    [ "$(sed -n '2p' "$RECEIPT")" = "$(agentmix_hash "$LEGACY_APP/Contents/MacOS/AgentMix")" ] &&
      codesign --verify --deep --strict "$LEGACY_APP"
  ) >/dev/null 2>&1; then
    EXISTING_APP="$LEGACY_APP"
  else
    printf 'Preserved the modified or unowned legacy app at %s.\n' "$LEGACY_APP"
  fi
fi
if [ -e "$EXISTING_APP" ]; then
  [ -f "$RECEIPT" ] || agentmix_fail "An unowned app was kept at $DESTINATION. Move it aside or choose --destination."
  agentmix_owned_file "$RECEIPT"
  [ "$(sed -n '1p' "$RECEIPT")" = "$EXISTING_APP" ] || agentmix_fail "An unowned app was kept at $DESTINATION. Move it aside or choose --destination."
  agentmix_owned_file "$EXISTING_APP/Contents/MacOS/AgentMix"
  APP_PRESENT=yes
  APP_BEFORE_HASH=$(agentmix_hash "$EXISTING_APP/Contents/MacOS/AgentMix")
  [ "$(sed -n '2p' "$RECEIPT")" = "$APP_BEFORE_HASH" ] || agentmix_fail 'The installed Mac app was modified. It was kept.'
  codesign --verify --deep --strict "$EXISTING_APP" || agentmix_fail 'The installed Mac app was modified. It was kept.'
fi
# Preflight the selected toolchain, including SwiftUI in its selected macOS SDK.
# A suitable CLT installation is enough; this never requires the Xcode app.
LOCK="$SUPPORT_DIR/.source-install.lock"
LOCK_HELD=no
WORK=
LOG=
DEPLOY_STAGE=
BACKUP=
PUBLISHED=no
PUBLISH_STARTED=no
cleanup() {
  INSTALL_RESULT=$?
  if [ "$INSTALL_RESULT" -ne 0 ]; then
    if [ -n "$LOG" ]; then
      printf '\nInstaller exited with status %s.\n' "$INSTALL_RESULT" >> "$LOG" 2>/dev/null || true
      printf 'Mac app install log: %s\n' "$LOG" >&2
    fi
    printf 'Retry after any running installation finishes: "$HOME/Library/Application Support/AgentMix/bin/standmixer" install-mac --no-open\n' >&2
  fi
  if [ "$PUBLISHED" = pending ] && [ -n "$DEPLOY_STAGE" ]; then
    if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
      rm -rf "$DESTINATION"
      mv "$BACKUP" "$EXISTING_APP"
    elif [ "$PUBLISH_STARTED" = yes ]; then
      rm -rf "$DESTINATION"
    fi
  fi
  [ -z "$DEPLOY_STAGE" ] || rm -rf "$DEPLOY_STAGE" || true
  [ -z "$WORK" ] || rm -rf "$WORK" || true
  if [ "$LOCK_HELD" = yes ]; then rmdir "$LOCK" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
[ ! -L "$LOCK" ] || agentmix_fail 'The source install lock is redirected.'
mkdir "$LOCK" 2>/dev/null || agentmix_fail "Another source or Mac installation may be running. Wait for it to finish before retrying. Lock: $LOCK"
LOCK_HELD=yes
LOG_DIR="$SUPPORT_DIR/InstallLogs"
agentmix_owned_directory "$LOG_DIR"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
LOG=$(mktemp "$LOG_DIR/install-mac.XXXXXX")
agentmix_owned_file "$LOG"
chmod 600 "$LOG"
printf 'Mac app install log: %s\n' "$LOG"
if WORK=$(mktemp -d "${TMPDIR:-/tmp}/agentmix-install-mac.XXXXXX" 2>> "$LOG"); then :; else
  INSTALL_RESULT=$?
  tail -n 8 "$LOG" >&2
  exit "$INSTALL_RESULT"
fi
run_logged() (
  set -o pipefail
  "$@" 2>&1 | tee -a "$LOG"
)
toolchain_failure() {
  INSTALL_RESULT=$?
  [ "$INSTALL_RESULT" -ne 0 ] || INSTALL_RESULT=1
  printf 'StandMixer: Mac app preflight failed: %s\n' "$1" | tee -a "$LOG" >&2
  tail -n 8 "$LOG" >&2
  exit "$INSTALL_RESULT"
}
SWIFT=$(xcrun --find swift 2>> "$LOG") || toolchain_failure 'xcrun could not find Swift.'
SWIFTC=$(xcrun --find swiftc 2>> "$LOG") || toolchain_failure 'xcrun could not find the Swift compiler.'
SDK=$(xcrun --sdk macosx --show-sdk-path 2>> "$LOG") || toolchain_failure 'xcrun could not select the macOS SDK.'
[ -x "$SWIFT" ] && [ -x "$SWIFTC" ] && [ -d "$SDK" ] || toolchain_failure 'The selected compiler or SDK path is unavailable.'
SWIFT_VERSION=$("$SWIFT" --version 2>> "$LOG") || toolchain_failure 'The selected Swift executable could not report its version.'
printf 'Swift: %s\nCompiler: %s\nSDK: %s\n%s\n' "$SWIFT" "$SWIFTC" "$SDK" "$SWIFT_VERSION" >> "$LOG"
SWIFT_MAJOR=$(printf '%s\n' "$SWIFT_VERSION" | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | head -n 1)
[ -n "$SWIFT_MAJOR" ] && [ "$SWIFT_MAJOR" -ge 6 ] || toolchain_failure 'This source requires Swift 6 or newer.'
printf 'import AppKit\nimport SwiftUI\n' > "$WORK/toolchain.swift"
run_logged "$SWIFTC" -typecheck -sdk "$SDK" -module-cache-path "$WORK/module-cache" "$WORK/toolchain.swift" || toolchain_failure 'SwiftUI import failed with the selected compiler and SDK.'
printf 'Building StandMixer locally. This may take a few minutes.\n'
# build.sh probes State/binding support and selects a suitable installed SDK.
# Ensure the exact preflighted compiler is used by build.sh and icon generation.
PATH="$(dirname -- "$SWIFT"):$PATH"
export PATH
if AGENTMIX_OUTPUT_APP="$WORK/StandMixer.app" AGENTMIX_BUILD_WORK="$SUPPORT_DIR/build" AGENTMIX_BUILD_ARCH=native run_logged /bin/sh "$SCRIPT_DIR/build.sh" release; then :; else
  INSTALL_RESULT=$?
  printf 'StandMixer: local Mac app build failed (exit %s).\n' "$INSTALL_RESULT" >&2
  exit "$INSTALL_RESULT"
fi
codesign --verify --deep --strict "$WORK/StandMixer.app" || agentmix_fail 'The newly built app failed signature verification; the existing app was kept.'
mkdir -p "$DESTINATION_DIR"
agentmix_owned_directory "$DESTINATION_DIR"
DEPLOY_STAGE=$(mktemp -d "$DESTINATION_DIR/.agentmix-deploy.XXXXXX")
ditto "$WORK/StandMixer.app" "$DEPLOY_STAGE/StandMixer.app"
codesign --verify --deep --strict "$DEPLOY_STAGE/StandMixer.app" || agentmix_fail 'The staged app failed signature verification; the existing app was kept.'
printf '%s\n%s\n' "$DESTINATION" "$(agentmix_hash "$DEPLOY_STAGE/StandMixer.app/Contents/MacOS/AgentMix")" > "$WORK/mac-app.receipt"
# Only now replace an owned app. Keep it available for rollback until the receipt is published.
agentmix_owned_directory "$DESTINATION"
if [ -n "$RECEIPT_BEFORE" ]; then
  agentmix_owned_file "$RECEIPT"
  [ "$(agentmix_hash "$RECEIPT")" = "$RECEIPT_BEFORE" ] || agentmix_fail 'The Mac app receipt changed during the build. The existing app was kept.'
else
  [ ! -e "$RECEIPT" ] && [ ! -L "$RECEIPT" ] || agentmix_fail 'A Mac app receipt appeared during the build. The existing app was kept.'
fi
if [ "$APP_PRESENT" = yes ]; then
  agentmix_owned_file "$EXISTING_APP/Contents/MacOS/AgentMix"
  [ "$(agentmix_hash "$EXISTING_APP/Contents/MacOS/AgentMix")" = "$APP_BEFORE_HASH" ] || agentmix_fail 'The Mac app changed during the build. It was kept.'
  codesign --verify --deep --strict "$EXISTING_APP" || agentmix_fail 'The Mac app changed during the build. It was kept.'
else
  [ ! -e "$DESTINATION" ] && [ ! -L "$DESTINATION" ] || agentmix_fail 'An app appeared at the destination during the build. It was kept.'
fi
# A destination created during a legacy migration belongs to someone else.
if [ "$EXISTING_APP" != "$DESTINATION" ]; then
  [ ! -e "$DESTINATION" ] && [ ! -L "$DESTINATION" ] || agentmix_fail 'An app appeared at the destination during the build. It was kept.'
fi
PUBLISHED=pending
if [ "$APP_PRESENT" = yes ]; then
  BACKUP="$DEPLOY_STAGE/previous.app"
  mv "$EXISTING_APP" "$BACKUP"
  [ "$(agentmix_hash "$BACKUP/Contents/MacOS/AgentMix")" = "$APP_BEFORE_HASH" ] || agentmix_fail 'The prior Mac app changed before replacement. It was restored.'
  codesign --verify --deep --strict "$BACKUP" || agentmix_fail 'The prior Mac app changed before replacement. It was restored.'
fi
PUBLISH_STARTED=yes
mv "$DEPLOY_STAGE/StandMixer.app" "$DESTINATION"
mv "$WORK/mac-app.receipt" "$RECEIPT"
PUBLISHED=yes
printf 'Installed %s\n' "$DESTINATION"
if [ "$OPEN" = yes ]; then open "$DESTINATION"; printf 'Opened StandMixer.\n'; fi
