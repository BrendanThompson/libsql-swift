#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
VARIANT="gnu" # gnu | musl
COMMAND=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $0 [options] [command]"
    echo ""
    echo "Cross-compile the libsql-swift Rust library for Linux from macOS"
    echo "using cargo-zigbuild."
    echo ""
    echo "Options:"
    echo "  --musl          Build for musl instead of GNU (default: gnu)"
    echo ""
    echo "Commands:"
    echo "  build           Build the Rust library (default)"
    echo "  setup           Install prerequisites for cross-compilation"
    echo ""
    echo "Examples:"
    echo "  $0                  # build for Linux GNU"
    echo "  $0 --musl build     # build for Linux musl"
    echo "  $0 setup            # install cross-compilation tools"
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
    --musl)
        VARIANT="musl"
        shift
        ;;
    --help | -h | help)
        usage
        ;;
    *)
        POSITIONAL+=("$1")
        shift
        ;;
    esac
done

COMMAND="${POSITIONAL[0]:-build}"

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
check_deps() {
    local missing=0

    if ! command -v rustup >/dev/null 2>&1; then
        echo "ERROR: rustup is not installed."
        echo "  Install it from https://rustup.rs"
        missing=1
    fi

    if ! command -v zig >/dev/null 2>&1; then
        echo "ERROR: zig is not installed."
        echo "  Install it with: brew install zig"
        missing=1
    fi

    if ! command -v cargo-zigbuild >/dev/null 2>&1; then
        echo "ERROR: cargo-zigbuild is not installed."
        echo "  Install it with: cargo install cargo-zigbuild"
        missing=1
    fi

    if [ "$missing" -eq 1 ]; then
        echo ""
        echo "Run '$0 setup' to install all prerequisites."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
do_build() {
    check_deps

    local build_var
    if [ "$VARIANT" = "musl" ]; then
        build_var="BUILD_LINUX_MUSL"
    else
        build_var="BUILD_LINUX_GNU"
    fi

    echo "==> Cross-compiling Rust library for Linux ($VARIANT)"
    echo ""

    (
        cd "$SCRIPT_DIR/Sources/CLibsql"
        export BUILD_IOS=0
        export BUILD_MACOS=0
        export "$build_var=1"
        ./build.sh
    )

    echo ""
    echo "Build complete. Linux libraries installed into XCFramework."
    echo ""
    echo "XCFramework slices:"

    local xcf="Sources/CLibsql/CLibsql.xcframework"
    for arch in x86_64 aarch64; do
        local lib="${xcf}/linux-${arch}/liblibsql.a"
        if [ -f "$SCRIPT_DIR/$lib" ]; then
            echo "  $lib"
        fi
    done

    echo ""
    echo "The package is now ready — consumers can add it as a dependency"
    echo "and 'swift build' will just work on Linux, no manual steps needed."
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
do_setup() {
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "ERROR: This setup is for macOS cross-compilation."
        echo "  On Linux, just install build-essential, pkg-config, and Rust."
        exit 1
    fi

    echo "==> Setting up cross-compilation (macOS → Linux)"
    echo ""

    (
        cd "$SCRIPT_DIR/Sources/CLibsql"
        ./setup.sh --linux
    )
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$COMMAND" in
build)
    do_build
    ;;

setup)
    do_setup
    ;;

*)
    echo "Unknown command: $COMMAND"
    echo ""
    usage
    ;;
esac
