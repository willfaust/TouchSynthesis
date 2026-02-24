#!/bin/bash
# Build libidevice_ffi.a for iOS (arm64).
# Uses all features but swaps aws-lc for ring (aws-lc doesn't support iOS).
# Requires: Rust toolchain + aarch64-apple-ios target.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FFI_DIR="$PROJECT_DIR/vendor/idevice/ffi"
OUTPUT_DIR="$PROJECT_DIR/TouchSynthesis/idevice"

# full + ring (instead of default aws-lc which doesn't support iOS cross-compilation)
FEATURES="full,ring"

TARGET="aarch64-apple-ios"

# Check prerequisites
if ! command -v cargo &>/dev/null; then
    echo "Error: Rust is not installed."
    echo "Install with: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
fi

if ! rustup target list --installed | grep -q "$TARGET"; then
    echo "Adding iOS target: $TARGET"
    rustup target add "$TARGET"
fi

# Check submodule is initialized
if [ ! -f "$FFI_DIR/Cargo.toml" ]; then
    echo "Initializing git submodule..."
    (cd "$PROJECT_DIR" && git submodule update --init --recursive)
fi

# Apply patch to add readwrite_send/readwrite_recv FFI functions
PATCH_FILE="$SCRIPT_DIR/readwrite-ffi.patch"
IDEVICE_DIR="$PROJECT_DIR/vendor/idevice"
if [ -f "$PATCH_FILE" ]; then
    echo "Applying readwrite-ffi patch..."
    (cd "$IDEVICE_DIR" && git apply --check "$PATCH_FILE" 2>/dev/null && git apply "$PATCH_FILE") || echo "Patch already applied, skipping."
fi

echo "Building idevice-ffi for $TARGET with features: $FEATURES"
echo "This may take a few minutes on first build..."

(cd "$FFI_DIR" && cargo build \
    --target "$TARGET" \
    --release \
    --no-default-features \
    --features "$FEATURES")

# Copy artifacts
LIB_PATH="$PROJECT_DIR/vendor/idevice/target/$TARGET/release/libidevice_ffi.a"
HEADER_PATH="$FFI_DIR/idevice.h"

if [ ! -f "$LIB_PATH" ]; then
    echo "Error: Build succeeded but $LIB_PATH not found"
    exit 1
fi

cp "$LIB_PATH" "$OUTPUT_DIR/libidevice_ffi.a"
echo "Copied libidevice_ffi.a ($(du -h "$OUTPUT_DIR/libidevice_ffi.a" | cut -f1))"

if [ -f "$HEADER_PATH" ]; then
    cp "$HEADER_PATH" "$OUTPUT_DIR/idevice.h"
    echo "Copied idevice.h"
else
    echo "Warning: idevice.h not generated — using existing header"
fi

echo "Done. Build artifacts in $OUTPUT_DIR"
