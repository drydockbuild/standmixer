#!/bin/sh
# Reproducible local builds: no personal source/cache paths in distributed code.
standmixer_swift_build() {
  if [ "$STANDMIXER_BUILD_CONFIGURATION" != release ]; then
    swift build --build-system native "$@"
    return
  fi
  swift build --build-system native "$@" \
    -Xswiftc -file-prefix-map -Xswiftc "$HOME=/home/builder" \
    -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/home/builder" \
    -Xswiftc -file-prefix-map -Xswiftc "$WORK_DIR=/build" \
    -Xswiftc -debug-prefix-map -Xswiftc "$WORK_DIR=/build" \
    -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_DIR=/StandMixer" \
    -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_DIR=/StandMixer" \
    -Xswiftc -file-compilation-dir -Xswiftc /StandMixer \
    -Xswiftc -Xfrontend -Xswiftc -no-serialize-debugging-options
}
standmixer_verify_release_paths() {
  for standmixer_build_prefix in "$HOME" "$PROJECT_DIR" "$WORK_DIR"; do
    if [ "${#standmixer_build_prefix}" -gt 1 ] && LC_ALL=C grep -aFq -- "$standmixer_build_prefix" "$1"; then
      printf 'StandMixer: release executable still contains a local build path; no signed output was published.\n' >&2
      return 1
    else
      standmixer_grep_status=$?
      [ "$standmixer_grep_status" = 1 ] || { printf 'StandMixer: could not inspect the release executable for local paths.\n' >&2; return 1; }
    fi
  done
}
standmixer_prepare_release_binary() {
  # Keep exported/dynamic symbols and Swift reflection/unwind sections. Local
  # linker symbols are unnecessary at runtime; strip them before ad-hoc signing.
  strip -S -x "$1"
  standmixer_verify_release_paths "$1"
}

# SwiftPM routes multiple --arch flags through XCBuild even with native selected.
# Build one native product per target, then combine thin Mach-O files ourselves.
standmixer_build_executable() {
  standmixer_product=$1
  standmixer_configuration=$2
  standmixer_architecture=$3
  standmixer_scratch=$4
  standmixer_output=$5
  case "$standmixer_architecture" in
    native) standmixer_target_architectures=native ;;
    universal) standmixer_target_architectures='arm64 x86_64' ;;
    arm64|x86_64) standmixer_target_architectures=$standmixer_architecture ;;
    *) printf 'StandMixer: unsupported build architecture.\n' >&2; return 2 ;;
  esac
  for standmixer_target_architecture in $standmixer_target_architectures; do
    standmixer_target_scratch=$standmixer_scratch
    [ "$standmixer_target_architecture" = native ] || standmixer_target_scratch="$standmixer_scratch/$standmixer_target_architecture"
    set -- --product "$standmixer_product" --disable-sandbox -c "$standmixer_configuration" --scratch-path "$standmixer_target_scratch" --cache-path "$WORK_DIR/swiftpm-cache"
    if [ "$standmixer_target_architecture" != native ]; then set -- "$@" --triple "$standmixer_target_architecture-apple-macosx14.0"; fi
    if [ -n "${SDKROOT:-}" ]; then set -- "$@" --sdk "$SDKROOT"; fi
    standmixer_swift_build "$@"
    standmixer_product_bin_dir=$(standmixer_swift_build "$@" --show-bin-path)
    standmixer_thin_binary="$standmixer_product_bin_dir/$standmixer_product"
    [ -x "$standmixer_thin_binary" ] || { printf 'StandMixer: expected executable at %s\n' "$standmixer_thin_binary" >&2; return 1; }
    case "$standmixer_target_architecture" in
      arm64) standmixer_thin_arm64=$standmixer_thin_binary ;;
      x86_64) standmixer_thin_x86_64=$standmixer_thin_binary ;;
    esac
  done
  if [ "$standmixer_architecture" = universal ]; then
    lipo -create "$standmixer_thin_arm64" "$standmixer_thin_x86_64" -output "$standmixer_output"
    lipo "$standmixer_output" -verify_arch arm64
    lipo "$standmixer_output" -verify_arch x86_64
  else
    cp "$standmixer_thin_binary" "$standmixer_output"
  fi
}
# Recent SDKs may require SwiftUI macro plugins that are absent from a CLT
# installation. Test real State/binding expansion, then try installed SDKs in
# the selected developer SDK folder. An explicit SDKROOT remains authoritative.
standmixer_select_app_sdk() {
  standmixer_sdk_probe=$1
  mkdir -p "$standmixer_sdk_probe"
  cat > "$standmixer_sdk_probe/state.swift" <<'SWIFT'
import SwiftUI
struct StandMixerToolchainProbe: View {
    @State private var ready = false
    var body: some View { Toggle("Ready", isOn: $ready) }
}
SWIFT
  standmixer_explicit_sdk=${SDKROOT:-}
  standmixer_default_sdk=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
  standmixer_host_arch=$(uname -m)
  if standmixer_probe_app_sdk "$standmixer_default_sdk"; then SDKROOT=$standmixer_default_sdk; export SDKROOT; return; fi
  if [ -z "$standmixer_explicit_sdk" ]; then
    standmixer_sdk_parent=$(dirname -- "$standmixer_default_sdk")
    standmixer_sdk_count=0
    for standmixer_sdk_candidate in "$standmixer_sdk_parent"/MacOSX[0-9]*.sdk; do
      standmixer_sdk_count=$((standmixer_sdk_count + 1))
      [ "$standmixer_sdk_count" -le 32 ] || break
      [ "$standmixer_sdk_candidate" != "$standmixer_default_sdk" ] || continue
      [ -d "$standmixer_sdk_candidate" ] || continue
      standmixer_sdk_major=$(basename -- "$standmixer_sdk_candidate" | sed 's/^MacOSX\([0-9][0-9]*\).*$/\1/')
      [ "$standmixer_sdk_major" -ge 14 ] || continue
      if standmixer_probe_app_sdk "$standmixer_sdk_candidate"; then
        SDKROOT=$standmixer_sdk_candidate
        export SDKROOT
        printf 'Using compatible macOS SDK: %s\n' "$SDKROOT"
        return
      fi
    done
  fi
  printf 'StandMixer: the selected Apple toolchain cannot compile SwiftUI State and bindings. Install or update compatible Swift 6 Command Line Tools and macOS SDKs, or select a compatible SDK with SDKROOT. The embedded panels still work.\n' >&2
  tail -n 8 "$standmixer_sdk_probe/result.log" >&2
  return 1
}
standmixer_probe_app_sdk() {
  [ -d "$1" ] || return 1
  swiftc -typecheck -target "$standmixer_host_arch-apple-macosx14.0" -sdk "$1" -module-cache-path "$WORK_DIR/app-sdk-probe-cache" "$standmixer_sdk_probe/state.swift" > "$standmixer_sdk_probe/result.log" 2>&1
}
