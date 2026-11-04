#!/bin/sh
# Reproducible local builds: no personal source/cache paths in distributed code.
agentmix_swift_build() {
  if [ "$AGENTMIX_BUILD_CONFIGURATION" != release ]; then
    swift build --build-system native "$@"
    return
  fi
  swift build --build-system native "$@" \
    -Xswiftc -file-prefix-map -Xswiftc "$HOME=/home/builder" \
    -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/home/builder" \
    -Xswiftc -file-prefix-map -Xswiftc "$WORK_DIR=/build" \
    -Xswiftc -debug-prefix-map -Xswiftc "$WORK_DIR=/build" \
    -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_DIR=/AgentMix" \
    -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_DIR=/AgentMix" \
    -Xswiftc -file-compilation-dir -Xswiftc /AgentMix \
    -Xswiftc -Xfrontend -Xswiftc -no-serialize-debugging-options
}
agentmix_verify_release_paths() {
  for agentmix_build_prefix in "$HOME" "$PROJECT_DIR" "$WORK_DIR"; do
    if [ "${#agentmix_build_prefix}" -gt 1 ] && LC_ALL=C grep -aFq -- "$agentmix_build_prefix" "$1"; then
      printf 'StandMixer: release executable still contains a local build path; no signed output was published.\n' >&2
      return 1
    else
      agentmix_grep_status=$?
      [ "$agentmix_grep_status" = 1 ] || { printf 'StandMixer: could not inspect the release executable for local paths.\n' >&2; return 1; }
    fi
  done
}
agentmix_prepare_release_binary() {
  # Keep exported/dynamic symbols and Swift reflection/unwind sections. Local
  # linker symbols are unnecessary at runtime; strip them before ad-hoc signing.
  strip -S -x "$1"
  agentmix_verify_release_paths "$1"
}

# SwiftPM routes multiple --arch flags through XCBuild even with native selected.
# Build one native product per target, then combine thin Mach-O files ourselves.
agentmix_build_executable() {
  agentmix_product=$1
  agentmix_configuration=$2
  agentmix_architecture=$3
  agentmix_scratch=$4
  agentmix_output=$5
  case "$agentmix_architecture" in
    native) agentmix_target_architectures=native ;;
    universal) agentmix_target_architectures='arm64 x86_64' ;;
    arm64|x86_64) agentmix_target_architectures=$agentmix_architecture ;;
    *) printf 'StandMixer: unsupported build architecture.\n' >&2; return 2 ;;
  esac
  for agentmix_target_architecture in $agentmix_target_architectures; do
    agentmix_target_scratch=$agentmix_scratch
    [ "$agentmix_target_architecture" = native ] || agentmix_target_scratch="$agentmix_scratch/$agentmix_target_architecture"
    set -- --product "$agentmix_product" --disable-sandbox -c "$agentmix_configuration" --scratch-path "$agentmix_target_scratch" --cache-path "$WORK_DIR/swiftpm-cache"
    if [ "$agentmix_target_architecture" != native ]; then set -- "$@" --triple "$agentmix_target_architecture-apple-macosx14.0"; fi
    if [ -n "${SDKROOT:-}" ]; then set -- "$@" --sdk "$SDKROOT"; fi
    agentmix_swift_build "$@"
    agentmix_product_bin_dir=$(agentmix_swift_build "$@" --show-bin-path)
    agentmix_thin_binary="$agentmix_product_bin_dir/$agentmix_product"
    [ -x "$agentmix_thin_binary" ] || { printf 'StandMixer: expected executable at %s\n' "$agentmix_thin_binary" >&2; return 1; }
    case "$agentmix_target_architecture" in
      arm64) agentmix_thin_arm64=$agentmix_thin_binary ;;
      x86_64) agentmix_thin_x86_64=$agentmix_thin_binary ;;
    esac
  done
  if [ "$agentmix_architecture" = universal ]; then
    lipo -create "$agentmix_thin_arm64" "$agentmix_thin_x86_64" -output "$agentmix_output"
    lipo "$agentmix_output" -verify_arch arm64
    lipo "$agentmix_output" -verify_arch x86_64
  else
    cp "$agentmix_thin_binary" "$agentmix_output"
  fi
}
# Recent SDKs may require SwiftUI macro plugins that are absent from a CLT
# installation. Test real State/binding expansion, then try installed SDKs in
# the selected developer SDK folder. An explicit SDKROOT remains authoritative.
agentmix_select_app_sdk() {
  agentmix_sdk_probe=$1
  mkdir -p "$agentmix_sdk_probe"
  cat > "$agentmix_sdk_probe/state.swift" <<'SWIFT'
import SwiftUI
struct AgentMixToolchainProbe: View {
    @State private var ready = false
    var body: some View { Toggle("Ready", isOn: $ready) }
}
SWIFT
  agentmix_explicit_sdk=${SDKROOT:-}
  agentmix_default_sdk=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
  agentmix_host_arch=$(uname -m)
  if agentmix_probe_app_sdk "$agentmix_default_sdk"; then SDKROOT=$agentmix_default_sdk; export SDKROOT; return; fi
  if [ -z "$agentmix_explicit_sdk" ]; then
    agentmix_sdk_parent=$(dirname -- "$agentmix_default_sdk")
    agentmix_sdk_count=0
    for agentmix_sdk_candidate in "$agentmix_sdk_parent"/MacOSX[0-9]*.sdk; do
      agentmix_sdk_count=$((agentmix_sdk_count + 1))
      [ "$agentmix_sdk_count" -le 32 ] || break
      [ "$agentmix_sdk_candidate" != "$agentmix_default_sdk" ] || continue
      [ -d "$agentmix_sdk_candidate" ] || continue
      agentmix_sdk_major=$(basename -- "$agentmix_sdk_candidate" | sed 's/^MacOSX\([0-9][0-9]*\).*$/\1/')
      [ "$agentmix_sdk_major" -ge 14 ] || continue
      if agentmix_probe_app_sdk "$agentmix_sdk_candidate"; then
        SDKROOT=$agentmix_sdk_candidate
        export SDKROOT
        printf 'Using compatible macOS SDK: %s\n' "$SDKROOT"
        return
      fi
    done
  fi
  printf 'StandMixer: the selected Apple toolchain cannot compile SwiftUI State and bindings. Install or update compatible Swift 6 Command Line Tools and macOS SDKs, or select a compatible SDK with SDKROOT. The embedded panels still work.\n' >&2
  tail -n 8 "$agentmix_sdk_probe/result.log" >&2
  return 1
}
agentmix_probe_app_sdk() {
  [ -d "$1" ] || return 1
  swiftc -typecheck -target "$agentmix_host_arch-apple-macosx14.0" -sdk "$1" -module-cache-path "$WORK_DIR/app-sdk-probe-cache" "$agentmix_sdk_probe/state.swift" > "$agentmix_sdk_probe/result.log" 2>&1
}
