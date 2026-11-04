#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_DIR="$PROJECT_DIR/../../work"
mkdir -p "$WORK_DIR"
WORK_DIR=$(CDPATH= cd -- "$WORK_DIR" && pwd)
SCRATCH_PATH="$WORK_DIR/agentmix-test"
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK_DIR/swift-module-cache"

cd "$PROJECT_DIR"
mkdir -p "$SCRATCH_PATH" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
swift test --build-system native --disable-sandbox --scratch-path "$SCRATCH_PATH" --cache-path "$WORK_DIR/swiftpm-cache"
