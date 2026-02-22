#!/usr/bin/env bash

set -xe +f

cd "$(dirname "$0")/libsql-c"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.1}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.13}"
export XROS_DEPLOYMENT_TARGET="${XROS_DEPLOYMENT_TARGET:-1.0}"
export TVOS_DEPLOYMENT_TARGET="${TVOS_DEPLOYMENT_TARGET:-15.0}"
export WATCHOS_DEPLOYMENT_TARGET="${WATCHOS_DEPLOYMENT_TARGET:-8.0}"

CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG=true
CFLAGS="-DHAVE_GETHOSTUUID=0"
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG
export CFLAGS

# ---------------------------------------------------------------------------
# Detect host OS
# ---------------------------------------------------------------------------
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

# ---------------------------------------------------------------------------
# Which platform slices to build. Override with e.g.:
#   BUILD_IOS=0 BUILD_LINUX_GNU=1 ./build.sh
#
# Apple targets (only available when building on macOS):
BUILD_IOS="${BUILD_IOS:-0}"
BUILD_MACOS="${BUILD_MACOS:-0}"
BUILD_VISIONOS="${BUILD_VISIONOS:-0}"
BUILD_TVOS="${BUILD_TVOS:-0}"
BUILD_WATCHOS="${BUILD_WATCHOS:-0}"
BUILD_MACCATALYST="${BUILD_MACCATALYST:-0}"

# Linux targets (cross-compiled via cargo-zigbuild on macOS, native on Linux):
BUILD_LINUX_GNU="${BUILD_LINUX_GNU:-0}"
BUILD_LINUX_MUSL="${BUILD_LINUX_MUSL:-0}"

# If nothing was explicitly enabled, pick sensible defaults for the host.
if [ "$BUILD_IOS" -eq 0 ] && [ "$BUILD_MACOS" -eq 0 ] &&
    [ "$BUILD_VISIONOS" -eq 0 ] && [ "$BUILD_TVOS" -eq 0 ] &&
    [ "$BUILD_WATCHOS" -eq 0 ] && [ "$BUILD_MACCATALYST" -eq 0 ] &&
    [ "$BUILD_LINUX_GNU" -eq 0 ] && [ "$BUILD_LINUX_MUSL" -eq 0 ]; then
    case "$HOST_OS" in
    Darwin)
        BUILD_IOS=1
        BUILD_MACOS=1
        ;;
    Linux)
        BUILD_LINUX_GNU=1
        ;;
    esac
fi

# Guard: Apple targets require macOS
if [ "$HOST_OS" != "Darwin" ]; then
    for flag in BUILD_IOS BUILD_MACOS BUILD_VISIONOS BUILD_TVOS BUILD_WATCHOS BUILD_MACCATALYST; do
        if [ "${!flag}" -eq 1 ]; then
            echo "ERROR: $flag=1 but host is $HOST_OS. Apple targets can only be built on macOS."
            exit 1
        fi
    done
fi

CARGO_FLAGS="${CARGO_FLAGS:---release}"

# Where the XCFramework lives
XCFRAMEWORK_OUTPUT="$(cd .. && pwd)/CLibsql.xcframework"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sdk_path() {
    xcrun --sdk "$1" --show-sdk-path 2>/dev/null
}

# Tier-3 Rust targets that require nightly + `-Z build-std` to compile.
# See: https://doc.rust-lang.org/nightly/rustc/platform-support.html
TIER3_TARGETS="aarch64-apple-tvos aarch64-apple-tvos-sim x86_64-apple-tvos \
aarch64-apple-watchos aarch64-apple-watchos-sim x86_64-apple-watchos-sim \
aarch64-apple-visionos aarch64-apple-visionos-sim"

is_tier3() {
    local target="$1"
    for t3 in $TIER3_TARGETS; do
        if [ "$target" = "$t3" ]; then
            return 0
        fi
    done
    return 1
}

ensure_target() {
    local target="$1"

    if is_tier3 "$target"; then
        echo "NOTE: $target is a Rust tier-3 target."
        echo "  It requires nightly Rust and will be built with -Z build-std."
        echo "  Install nightly with: rustup toolchain install nightly"
        return 0
    fi

    if ! rustup target list --installed | grep -q "^${target}\$"; then
        echo "Installing Rust target: $target"
        rustup target add "$target"
    fi
}

cargo_build() {
    local target="$1"
    shift
    ensure_target "$target"

    if is_tier3 "$target"; then
        cargo +nightly build --target "$target" -Z build-std $CARGO_FLAGS "$@"
    else
        cargo build --target "$target" $CARGO_FLAGS "$@"
    fi
}

# Cross-compile to Linux from macOS using cargo-zigbuild, or build natively
# on Linux with regular cargo.
cargo_build_linux() {
    local target="$1"
    shift
    ensure_target "$target"

    if [ "$HOST_OS" = "Darwin" ]; then
        # Cross-compile from macOS — requires zig + cargo-zigbuild
        if ! command -v cargo-zigbuild >/dev/null 2>&1; then
            echo "ERROR: cargo-zigbuild is not installed."
            echo "  Install it with: cargo install cargo-zigbuild"
            echo "  Also install Zig:  brew install zig"
            exit 1
        fi
        if ! command -v zig >/dev/null 2>&1; then
            echo "ERROR: zig is not installed."
            echo "  Install it with: brew install zig"
            exit 1
        fi
        cargo zigbuild --target "$target" $CARGO_FLAGS "$@"
    else
        # Native build on Linux
        cargo build --target "$target" $CARGO_FLAGS "$@"
    fi
}

make_universal() {
    local output_dir="$1"
    shift
    mkdir -p "$output_dir"
    lipo "$@" -create -output "$output_dir/liblibsql.a"
}

# ---------------------------------------------------------------------------
# Install a built Linux library into the XCFramework so that SwiftPM's
# .binaryTarget can resolve it without any manual setup.
#
# Copies into:
#   CLibsql.xcframework/linux-<arch>/liblibsql.a
#   CLibsql.xcframework/linux-<arch>/Headers/libsql.h
#   CLibsql.xcframework/linux-<arch>/Headers/module.modulemap
# ---------------------------------------------------------------------------
install_linux_xcframework() {
    local rust_target="$1"
    local arch="$2" # x86_64 or aarch64
    local lib_path="./target/${rust_target}/release/liblibsql.a"

    if [ ! -f "$lib_path" ]; then
        echo "WARNING: $lib_path not found, skipping XCFramework install for $rust_target."
        return
    fi

    local slice_dir="${XCFRAMEWORK_OUTPUT}/linux-${arch}"
    local headers_dir="${slice_dir}/Headers"

    mkdir -p "$headers_dir"

    cp "$lib_path" "$slice_dir/liblibsql.a"
    echo "  Copied liblibsql.a -> $slice_dir/liblibsql.a"

    cp ./libsql.h "$headers_dir/libsql.h"
    cp ../module.modulemap "$headers_dir/module.modulemap"
    echo "  Copied headers -> $headers_dir/"
}

# ---------------------------------------------------------------------------
# iOS (arm64 device + universal simulator)
# ---------------------------------------------------------------------------
build_ios() {
    local iphone_sdk simulator_sdk

    iphone_sdk="$(sdk_path iphoneos)"
    simulator_sdk="$(sdk_path iphonesimulator)"

    if [ -z "$iphone_sdk" ] || [ -z "$simulator_sdk" ]; then
        echo "ERROR: iOS SDKs not found. Is Xcode installed?"
        exit 1
    fi

    echo "==> Building iOS (device: arm64)"
    SDKROOT="$iphone_sdk" \
        RUSTFLAGS="-C link-arg=-F${iphone_sdk}/System/Library/Frameworks" \
        cargo_build aarch64-apple-ios

    echo "==> Building iOS Simulator (x86_64)"
    SDKROOT="$simulator_sdk" \
        RUSTFLAGS="-C link-arg=-F${simulator_sdk}/System/Library/Frameworks" \
        cargo_build x86_64-apple-ios

    echo "==> Building iOS Simulator (arm64)"
    SDKROOT="$simulator_sdk" \
        RUSTFLAGS="-C link-arg=-F${simulator_sdk}/System/Library/Frameworks" \
        cargo_build aarch64-apple-ios-sim

    echo "==> Creating universal iOS Simulator binary"
    make_universal ./target/universal-ios-sim/release \
        ./target/x86_64-apple-ios/release/liblibsql.a \
        ./target/aarch64-apple-ios-sim/release/liblibsql.a
}

# ---------------------------------------------------------------------------
# macOS (universal: x86_64 + arm64)
# ---------------------------------------------------------------------------
build_macos() {
    echo "==> Building macOS (x86_64)"
    cargo_build x86_64-apple-darwin --features encryption

    echo "==> Building macOS (arm64)"
    cargo_build aarch64-apple-darwin --features encryption
}

# ---------------------------------------------------------------------------
# visionOS (arm64 device + simulator)
# NOTE: Requires Xcode 15.2+ with visionOS platform installed AND
#       Rust nightly (tier-3 targets, built with -Z build-std).
# ---------------------------------------------------------------------------
build_visionos() {
    local xros_sdk xros_sim_sdk

    xros_sdk="$(sdk_path xros)"
    xros_sim_sdk="$(sdk_path xrsimulator)"

    if [ -z "$xros_sdk" ] || [ -z "$xros_sim_sdk" ]; then
        echo "ERROR: visionOS SDKs not found. Xcode 15.2+ with visionOS platform is required."
        exit 1
    fi

    echo "==> Building visionOS (device: arm64)"
    SDKROOT="$xros_sdk" \
        RUSTFLAGS="-C link-arg=-F${xros_sdk}/System/Library/Frameworks" \
        cargo_build aarch64-apple-visionos

    echo "==> Building visionOS Simulator (arm64)"
    SDKROOT="$xros_sim_sdk" \
        RUSTFLAGS="-C link-arg=-F${xros_sim_sdk}/System/Library/Frameworks" \
        cargo_build aarch64-apple-visionos-sim

    # visionOS simulator is arm64-only (no x86_64), so no lipo needed.
    mkdir -p ./target/universal-visionos-sim/release
    cp ./target/aarch64-apple-visionos-sim/release/liblibsql.a \
        ./target/universal-visionos-sim/release/liblibsql.a
}

# ---------------------------------------------------------------------------
# tvOS (arm64 device + universal simulator)
# NOTE: Requires Rust nightly (tier-3 targets, built with -Z build-std).
# ---------------------------------------------------------------------------
build_tvos() {
    local tvos_sdk tvos_sim_sdk

    tvos_sdk="$(sdk_path appletvos)"
    tvos_sim_sdk="$(sdk_path appletvsimulator)"

    if [ -z "$tvos_sdk" ] || [ -z "$tvos_sim_sdk" ]; then
        echo "ERROR: tvOS SDKs not found. Install the tvOS platform in Xcode."
        exit 1
    fi

    echo "==> Building tvOS (device: arm64)"
    SDKROOT="$tvos_sdk" \
        RUSTFLAGS="-C link-arg=-F${tvos_sdk}/System/Library/Frameworks" \
        cargo_build aarch64-apple-tvos

    echo "==> Building tvOS Simulator (x86_64)"
    SDKROOT="$tvos_sim_sdk" \
        RUSTFLAGS="-C link-arg=-F${tvos_sim_sdk}/System/Library/Frameworks" \
        cargo_build x86_64-apple-tvos

    echo "==> Building tvOS Simulator (arm64)"
    SDKROOT="$tvos_sim_sdk" \
        RUSTFLAGS="-C link-arg=-F${tvos_sim_sdk}/System/Library/Frameworks" \
        cargo_build aarch64-apple-tvos-sim

    echo "==> Creating universal tvOS Simulator binary"
    make_universal ./target/universal-tvos-sim/release \
        ./target/x86_64-apple-tvos/release/liblibsql.a \
        ./target/aarch64-apple-tvos-sim/release/liblibsql.a
}

# ---------------------------------------------------------------------------
# watchOS (arm64 device + simulator)
# NOTE: Requires Rust nightly (tier-3 targets, built with -Z build-std).
# ---------------------------------------------------------------------------
build_watchos() {
    local watchos_sdk watchos_sim_sdk

    watchos_sdk="$(sdk_path watchos)"
    watchos_sim_sdk="$(sdk_path watchsimulator)"

    if [ -z "$watchos_sdk" ] || [ -z "$watchos_sim_sdk" ]; then
        echo "ERROR: watchOS SDKs not found. Install the watchOS platform in Xcode."
        exit 1
    fi

    echo "==> Building watchOS (device: arm64)"
    SDKROOT="$watchos_sdk" \
        RUSTFLAGS="-C link-arg=-F${watchos_sdk}/System/Library/Frameworks" \
        cargo_build aarch64-apple-watchos

    echo "==> Building watchOS Simulator (x86_64)"
    SDKROOT="$watchos_sim_sdk" \
        RUSTFLAGS="-C link-arg=-F${watchos_sim_sdk}/System/Library/Frameworks" \
        cargo_build x86_64-apple-watchos-sim

    echo "==> Building watchOS Simulator (arm64)"
    SDKROOT="$watchos_sim_sdk" \
        RUSTFLAGS="-C link-arg=-F${watchos_sim_sdk}/System/Library/Frameworks" \
        cargo_build aarch64-apple-watchos-sim

    echo "==> Creating universal watchOS Simulator binary"
    make_universal ./target/universal-watchos-sim/release \
        ./target/x86_64-apple-watchos-sim/release/liblibsql.a \
        ./target/aarch64-apple-watchos-sim/release/liblibsql.a
}

# ---------------------------------------------------------------------------
# Mac Catalyst (universal: x86_64 + arm64)
# ---------------------------------------------------------------------------
build_maccatalyst() {
    local macos_sdk
    macos_sdk="$(sdk_path macosx)"

    if [ -z "$macos_sdk" ]; then
        echo "ERROR: macOS SDK not found."
        exit 1
    fi

    echo "==> Building Mac Catalyst (x86_64)"
    SDKROOT="$macos_sdk" \
        RUSTFLAGS="-C link-arg=-F${macos_sdk}/System/Library/Frameworks -C link-arg=-target -C link-arg=x86_64-apple-ios-macabi" \
        cargo_build x86_64-apple-ios-macabi

    echo "==> Building Mac Catalyst (arm64)"
    SDKROOT="$macos_sdk" \
        RUSTFLAGS="-C link-arg=-F${macos_sdk}/System/Library/Frameworks -C link-arg=-target -C link-arg=aarch64-apple-ios-macabi" \
        cargo_build aarch64-apple-ios-macabi

    echo "==> Creating universal Mac Catalyst binary"
    make_universal ./target/universal-maccatalyst/release \
        ./target/x86_64-apple-ios-macabi/release/liblibsql.a \
        ./target/aarch64-apple-ios-macabi/release/liblibsql.a
}

# ---------------------------------------------------------------------------
# Linux GNU (glibc) — x86_64 + aarch64
#
# On macOS: cross-compiled via cargo-zigbuild (requires `zig` + `cargo-zigbuild`).
# On Linux: native cargo build.
# ---------------------------------------------------------------------------
build_linux_gnu() {
    echo "==> Building Linux GNU (x86_64)"
    cargo_build_linux x86_64-unknown-linux-gnu --features encryption

    echo "==> Building Linux GNU (aarch64)"
    cargo_build_linux aarch64-unknown-linux-gnu --features encryption
}

# ---------------------------------------------------------------------------
# Linux musl (static) — x86_64 + aarch64
#
# On macOS: cross-compiled via cargo-zigbuild (requires `zig` + `cargo-zigbuild`).
# On Linux: native cargo build.
#
# NOTE: musl builds use -crt-static to produce a dynamically-linked musl
#       binary. Remove the RUSTFLAGS override if you want fully static output.
# ---------------------------------------------------------------------------
build_linux_musl() {
    echo "==> Building Linux musl (x86_64)"
    RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=-crt-static" \
        cargo_build_linux x86_64-unknown-linux-musl --features encryption

    echo "==> Building Linux musl (aarch64)"
    RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=-crt-static" \
        cargo_build_linux aarch64-unknown-linux-musl --features encryption
}

# ===========================================================================
# Build selected platforms
# ===========================================================================

[ "$BUILD_IOS" -eq 1 ] && build_ios
[ "$BUILD_MACOS" -eq 1 ] && build_macos
[ "$BUILD_VISIONOS" -eq 1 ] && build_visionos
[ "$BUILD_TVOS" -eq 1 ] && build_tvos
[ "$BUILD_WATCHOS" -eq 1 ] && build_watchos
[ "$BUILD_MACCATALYST" -eq 1 ] && build_maccatalyst
[ "$BUILD_LINUX_GNU" -eq 1 ] && build_linux_gnu
[ "$BUILD_LINUX_MUSL" -eq 1 ] && build_linux_musl

# ===========================================================================
# Post-build: Universal macOS binary
# ===========================================================================
if [ "$BUILD_MACOS" -eq 1 ]; then
    echo "==> Creating universal macOS binary"
    make_universal ./target/universal-macos/release \
        ./target/x86_64-apple-darwin/release/liblibsql.a \
        ./target/aarch64-apple-darwin/release/liblibsql.a
fi

# ===========================================================================
# Post-build: Assemble XCFramework (Apple platforms only)
#
# xcodebuild -create-xcframework replaces the output directory, so this
# must run BEFORE the Linux slice install below.
# ===========================================================================
ANY_APPLE=0
for flag in BUILD_IOS BUILD_MACOS BUILD_VISIONOS BUILD_TVOS BUILD_WATCHOS BUILD_MACCATALYST; do
    if [ "${!flag}" -eq 1 ]; then
        ANY_APPLE=1
        break
    fi
done

if [ "$ANY_APPLE" -eq 1 ]; then
    include_dir=$(mktemp -d)
    trap 'rm -rf "$include_dir"' EXIT

    cp ./libsql.h "$include_dir/"
    cp ../module.modulemap "$include_dir/"

    rm -rf "$XCFRAMEWORK_OUTPUT"

    xcframework_args=()

    if [ "$BUILD_IOS" -eq 1 ]; then
        xcframework_args+=(
            -library ./target/aarch64-apple-ios/release/liblibsql.a
            -headers "$include_dir"
            -library ./target/universal-ios-sim/release/liblibsql.a
            -headers "$include_dir"
        )
    fi

    if [ "$BUILD_MACOS" -eq 1 ]; then
        xcframework_args+=(
            -library ./target/universal-macos/release/liblibsql.a
            -headers "$include_dir"
        )
    fi

    if [ "$BUILD_VISIONOS" -eq 1 ]; then
        xcframework_args+=(
            -library ./target/aarch64-apple-visionos/release/liblibsql.a
            -headers "$include_dir"
            -library ./target/universal-visionos-sim/release/liblibsql.a
            -headers "$include_dir"
        )
    fi

    if [ "$BUILD_TVOS" -eq 1 ]; then
        xcframework_args+=(
            -library ./target/aarch64-apple-tvos/release/liblibsql.a
            -headers "$include_dir"
            -library ./target/universal-tvos-sim/release/liblibsql.a
            -headers "$include_dir"
        )
    fi

    if [ "$BUILD_WATCHOS" -eq 1 ]; then
        xcframework_args+=(
            -library ./target/aarch64-apple-watchos/release/liblibsql.a
            -headers "$include_dir"
            -library ./target/universal-watchos-sim/release/liblibsql.a
            -headers "$include_dir"
        )
    fi

    if [ "$BUILD_MACCATALYST" -eq 1 ]; then
        xcframework_args+=(
            -library ./target/universal-maccatalyst/release/liblibsql.a
            -headers "$include_dir"
        )
    fi

    echo "==> Creating XCFramework"
    xcodebuild -create-xcframework \
        "${xcframework_args[@]}" \
        -output "$XCFRAMEWORK_OUTPUT"

    echo ""
    echo "XCFramework created at: $XCFRAMEWORK_OUTPUT"
fi

# ===========================================================================
# Post-build: Install Linux libraries into XCFramework
#
# Copies the built .a files + headers into the XCFramework so that
# SwiftPM's .binaryTarget resolves them automatically on Linux — no
# manual install step required.  Runs AFTER the Apple assembly so that
# xcodebuild -create-xcframework doesn't blow away the Linux slices.
# ===========================================================================
BUILT_LINUX=0

if [ "$BUILD_LINUX_GNU" -eq 1 ] || [ "$BUILD_LINUX_MUSL" -eq 1 ]; then
    BUILT_LINUX=1

    echo "==> Installing Linux libraries into XCFramework"

    # For each architecture, prefer GNU, fall back to musl
    for arch in x86_64 aarch64; do
        installed=0
        for libc in gnu musl; do
            candidate="${arch}-unknown-linux-${libc}"
            if [ -f "./target/${candidate}/release/liblibsql.a" ]; then
                install_linux_xcframework "$candidate" "$arch"
                installed=1
                break
            fi
        done
        if [ "$installed" -eq 0 ]; then
            echo "  NOTE: No library built for linux-${arch}, skipping."
        fi
    done
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Build complete."
if [ "$ANY_APPLE" -eq 1 ] || [ "$BUILT_LINUX" -eq 1 ]; then
    echo "  XCFramework: ${XCFRAMEWORK_OUTPUT}"
fi
echo "Done."
