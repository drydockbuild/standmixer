#!/bin/sh
# Optional Mac app, built locally from the installed source checkout.
set -eu
umask 077
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/install-common.sh"
OPEN=yes
DESTINATION="${HOME:?HOME must be set}/Applications/StandMixer.app"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-open) OPEN=no; shift ;;
    --destination) [ "$#" -ge 2 ] || standmixer_fail 'Use --destination with an absolute StandMixer.app path.'; DESTINATION=$2; shift 2 ;;
    --help|-h) printf 'Usage: standmixer install-mac [--no-open] [--destination /absolute/path/StandMixer.app]\n'; exit 0 ;;
    *) standmixer_fail "Unknown install-mac option: $1" ;;
  esac
done
standmixer_darwin
SUPPORT_DIR="$HOME/Library/Application Support/StandMixer"
[ "$PROJECT_DIR" = "$SUPPORT_DIR/source" ] || standmixer_fail 'Build the app with the installed standmixer install-mac command. Run the checkout install.sh first.'
standmixer_owned_directory "$PROJECT_DIR"
standmixer_owned_directory "$SUPPORT_DIR/build"
standmixer_owned_file "$PROJECT_DIR/.standmixer-source"
[ "$(cat "$PROJECT_DIR/.standmixer-source")" = 'StandMixer source checkout v1' ] || standmixer_fail 'Reinstall StandMixer from the trusted source checkout.'
case "$DESTINATION" in /*/StandMixer.app) ;; *) standmixer_fail 'Use an absolute destination ending in /StandMixer.app.' ;; esac
DESTINATION_DIR=$(dirname -- "$DESTINATION")
standmixer_owned_directory "$DESTINATION_DIR"
standmixer_owned_directory "$DESTINATION"
RECEIPT="$SUPPORT_DIR/mac-app.receipt"
RECEIPT_BEFORE=
APP_PRESENT=no
APP_BEFORE_HASH=
EXISTING_APP="$DESTINATION"
if [ -e "$RECEIPT" ] || [ -L "$RECEIPT" ]; then
  standmixer_owned_file "$RECEIPT"
  RECEIPT_BEFORE=$(standmixer_hash "$RECEIPT")
fi
if [ -e "$EXISTING_APP" ]; then
  [ -f "$RECEIPT" ] || standmixer_fail "An unowned app was kept at $DESTINATION. Move it aside or choose --destination."
  standmixer_owned_file "$RECEIPT"
  [ "$(sed -n '1p' "$RECEIPT")" = "$EXISTING_APP" ] || standmixer_fail "An unowned app was kept at $DESTINATION. Move it aside or choose --destination."
  standmixer_owned_file "$EXISTING_APP/Contents/MacOS/StandMixer"
  APP_PRESENT=yes
  APP_BEFORE_HASH=$(standmixer_hash "$EXISTING_APP/Contents/MacOS/StandMixer")
  [ "$(sed -n '2p' "$RECEIPT")" = "$APP_BEFORE_HASH" ] || standmixer_fail 'The installed Mac app was modified. It was kept.'
  codesign --verify --deep --strict "$EXISTING_APP" || standmixer_fail 'The installed Mac app was modified. It was kept.'
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
    printf 'Retry after any running installation finishes: "$HOME/Library/Application Support/StandMixer/bin/standmixer" install-mac --no-open\n' >&2
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
[ ! -L "$LOCK" ] || standmixer_fail 'The source install lock is redirected.'
mkdir "$LOCK" 2>/dev/null || standmixer_fail "Another source or Mac installation may be running. Wait for it to finish before retrying. Lock: $LOCK"
LOCK_HELD=yes
LOG_DIR="$SUPPORT_DIR/InstallLogs"
standmixer_owned_directory "$LOG_DIR"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
LOG=$(mktemp "$LOG_DIR/install-mac.XXXXXX")
standmixer_owned_file "$LOG"
chmod 600 "$LOG"
printf 'Mac app install log: %s\n' "$LOG"
if WORK=$(mktemp -d "${TMPDIR:-/tmp}/standmixer-install-mac.XXXXXX" 2>> "$LOG"); then :; else
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
if STANDMIXER_OUTPUT_APP="$WORK/StandMixer.app" STANDMIXER_BUILD_WORK="$SUPPORT_DIR/build" STANDMIXER_BUILD_ARCH=native run_logged /bin/sh "$SCRIPT_DIR/build.sh" release; then :; else
  INSTALL_RESULT=$?
  printf 'StandMixer: local Mac app build failed (exit %s).\n' "$INSTALL_RESULT" >&2
  exit "$INSTALL_RESULT"
fi
codesign --verify --deep --strict "$WORK/StandMixer.app" || standmixer_fail 'The newly built app failed signature verification; the existing app was kept.'
mkdir -p "$DESTINATION_DIR"
standmixer_owned_directory "$DESTINATION_DIR"
DEPLOY_STAGE=$(mktemp -d "$DESTINATION_DIR/.standmixer-deploy.XXXXXX")
ditto "$WORK/StandMixer.app" "$DEPLOY_STAGE/StandMixer.app"
codesign --verify --deep --strict "$DEPLOY_STAGE/StandMixer.app" || standmixer_fail 'The staged app failed signature verification; the existing app was kept.'
printf '%s\n%s\n' "$DESTINATION" "$(standmixer_hash "$DEPLOY_STAGE/StandMixer.app/Contents/MacOS/StandMixer")" > "$WORK/mac-app.receipt"
# Only now replace an owned app. Keep it available for rollback until the receipt is published.
standmixer_owned_directory "$DESTINATION"
if [ -n "$RECEIPT_BEFORE" ]; then
  standmixer_owned_file "$RECEIPT"
  [ "$(standmixer_hash "$RECEIPT")" = "$RECEIPT_BEFORE" ] || standmixer_fail 'The Mac app receipt changed during the build. The existing app was kept.'
else
  [ ! -e "$RECEIPT" ] && [ ! -L "$RECEIPT" ] || standmixer_fail 'A Mac app receipt appeared during the build. The existing app was kept.'
fi
if [ "$APP_PRESENT" = yes ]; then
  standmixer_owned_file "$EXISTING_APP/Contents/MacOS/StandMixer"
  [ "$(standmixer_hash "$EXISTING_APP/Contents/MacOS/StandMixer")" = "$APP_BEFORE_HASH" ] || standmixer_fail 'The Mac app changed during the build. It was kept.'
  codesign --verify --deep --strict "$EXISTING_APP" || standmixer_fail 'The Mac app changed during the build. It was kept.'
else
  [ ! -e "$DESTINATION" ] && [ ! -L "$DESTINATION" ] || standmixer_fail 'An app appeared at the destination during the build. It was kept.'
fi
PUBLISHED=pending
if [ "$APP_PRESENT" = yes ]; then
  BACKUP="$DEPLOY_STAGE/previous.app"
  mv "$EXISTING_APP" "$BACKUP"
  [ "$(standmixer_hash "$BACKUP/Contents/MacOS/StandMixer")" = "$APP_BEFORE_HASH" ] || standmixer_fail 'The prior Mac app changed before replacement. It was restored.'
  codesign --verify --deep --strict "$BACKUP" || standmixer_fail 'The prior Mac app changed before replacement. It was restored.'
fi
PUBLISH_STARTED=yes
mv "$DEPLOY_STAGE/StandMixer.app" "$DESTINATION"
mv "$WORK/mac-app.receipt" "$RECEIPT"
PUBLISHED=yes
printf 'Installed %s\n' "$DESTINATION"
if [ "$OPEN" = yes ]; then open "$DESTINATION"; printf 'Opened StandMixer.\n'; fi
