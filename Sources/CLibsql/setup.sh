#!/usr/bin/env bash

set -e

# setup.sh — Install all prerequisites for building CLibsql without Nix.
#
# Requirements:
#   - Rust installed via rustup (https://rustup.rs)
#   - On macOS: Xcode installed (including Command Line Tools)
#   - On Linux: standard build tools (gcc/clang, pkg-config)
#
# Usage:
#   ./setup.sh              # Set up defaults for your host OS
#   ./setup.sh --all        # Set up everything (Apple + Linux targets)
#   ./setup.sh --linux      # Set up Linux cross-compilation targets only
#   ./setup.sh --apple      # Set up Apple targets only (macOS required)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

SETUP_APPLE=0
SETUP_LINUX=0

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if [ $# -eq 0 ]; then
    # Default: set up what makes sense for this host
    case "$HOST_OS" in
    Darwin)
        SETUP_APPLE=1
        ;;
    Linux)
        SETUP_LINUX=1
        ;;
    *)
        echo "Unknown host OS: $HOST_OS"
        exit 1
        ;;
    esac
else
    for arg in "$@"; do
        case "$arg" in
        --all)
            SETUP_APPLE=1
            SETUP_LINUX=1
            ;;
        --apple)
            SETUP_APPLE=1
            ;;
        --linux)
            SETUP_LINUX=1
            ;;
        --help | -h)
            echo "Usage: $0 [--all | --apple | --linux]"
            echo ""
            echo "  (no args)   Set up defaults for your host OS"
            echo "  --all       Set up everything (Apple + Linux)"
            echo "  --apple     Set up Apple targets (requires macOS)"
            echo "  --linux     Set up Linux targets (cross-compile on macOS, native on Linux)"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Run '$0 --help' for usage."
            exit 1
            ;;
        esac
    done
fi

echo "========================================"
echo "  libsql-swift build setup"
echo "========================================"
echo ""
echo "  Host OS:   $HOST_OS"
echo "  Host Arch: $HOST_ARCH"
echo "  Apple:     $([ "$SETUP_APPLE" -eq 1 ] && echo 'yes' || echo 'no')"
echo "  Linux:     $([ "$SETUP_LINUX" -eq 1 ] && echo 'yes' || echo 'no')"
echo ""

# ---------------------------------------------------------------------------
# 1. Check for rustup
# ---------------------------------------------------------------------------
echo "--- Checking for rustup ---"
if ! command -v rustup >/dev/null 2>&1; then
    echo "ERROR: rustup is not installed."
    echo "Install it from https://rustup.rs and re-run this script."
    exit 1
fi
echo "  rustup: $(rustup --version 2>/dev/null | head -1)"

# ---------------------------------------------------------------------------
# 2. Ensure the stable toolchain is installed
# ---------------------------------------------------------------------------
echo ""
echo "--- Installing/updating Rust stable toolchain ---"
rustup toolchain install stable
rustup default stable

# ---------------------------------------------------------------------------
# 3. Apple targets
# ---------------------------------------------------------------------------
if [ "$SETUP_APPLE" -eq 1 ]; then
    echo ""
    echo "--- Setting up Apple targets ---"

    if [ "$HOST_OS" != "Darwin" ]; then
        echo "WARNING: Apple targets can only be built on macOS."
        echo "  Skipping Apple setup (host is $HOST_OS)."
    else
        # Check for Xcode
        echo ""
        echo "Checking for Xcode..."
        if ! command -v xcodebuild >/dev/null 2>&1; then
            echo "ERROR: xcodebuild is not found."
            echo "Install Xcode from the App Store and run: xcode-select --install"
            exit 1
        fi
        echo "  xcodebuild: $(xcodebuild -version 2>/dev/null | head -1)"

        # Install Rust targets for Apple platforms
        echo ""
        echo "Installing Apple Rust targets..."

        apple_targets=(
            # iOS device
            aarch64-apple-ios
            # iOS simulator
            x86_64-apple-ios
            aarch64-apple-ios-sim
            # macOS
            x86_64-apple-darwin
            aarch64-apple-darwin
        )

        for target in "${apple_targets[@]}"; do
            echo "  Adding: $target"
            rustup target add "$target"
        done

        # Verify SDK availability
        echo ""
        echo "Checking SDK availability..."
        missing=0

        check_sdk() {
            local name="$1"
            local sdk="$2"
            local path
            path=$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null || true)
            if [ -z "$path" ] || [ ! -d "$path" ]; then
                echo "  WARNING: $name SDK not found ($sdk). Related builds will fail."
                missing=1
            else
                echo "  $name: $path"
            fi
        }

        check_sdk "iPhoneOS" "iphoneos"
        check_sdk "iPhoneSimulator" "iphonesimulator"
        check_sdk "macOS" "macosx"

        if [ "$missing" -eq 1 ]; then
            echo ""
            echo "Some SDKs are missing. Make sure Xcode is fully installed and run:"
            echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 4. Linux targets
# ---------------------------------------------------------------------------
if [ "$SETUP_LINUX" -eq 1 ]; then
    echo ""
    echo "--- Setting up Linux targets ---"

    # Install Rust targets for Linux
    linux_targets=(
        x86_64-unknown-linux-gnu
        aarch64-unknown-linux-gnu
        x86_64-unknown-linux-musl
        aarch64-unknown-linux-musl
    )

    echo ""
    echo "Installing Linux Rust targets..."
    for target in "${linux_targets[@]}"; do
        echo "  Adding: $target"
        rustup target add "$target"
    done

    if [ "$HOST_OS" = "Darwin" ]; then
        # Cross-compiling from macOS — need zig + cargo-zigbuild
        echo ""
        echo "--- Setting up cross-compilation toolchain (macOS -> Linux) ---"
        echo ""
        echo "Cross-compiling to Linux from macOS requires:"
        echo "  1. Zig (provides C cross-compiler + Linux sysroots)"
        echo "  2. cargo-zigbuild (integrates Zig with Cargo)"
        echo ""

        # Check / install Zig
        if command -v zig >/dev/null 2>&1; then
            echo "  zig: $(zig version) (already installed)"
        else
            echo "  zig: not found"
            if command -v brew >/dev/null 2>&1; then
                echo "  Installing zig via Homebrew..."
                brew install zig
            else
                echo ""
                echo "  Please install Zig manually:"
                echo "    - Homebrew: brew install zig"
                echo "    - Direct:   https://ziglang.org/download/"
                echo ""
                echo "  After installing Zig, re-run this script."
                exit 1
            fi
        fi

        # Check / install cargo-zigbuild
        if command -v cargo-zigbuild >/dev/null 2>&1; then
            echo "  cargo-zigbuild: $(cargo zigbuild --version 2>/dev/null || echo 'installed')"
        else
            echo "  cargo-zigbuild: not found"
            echo "  Installing cargo-zigbuild..."
            cargo install cargo-zigbuild
        fi

        echo ""
        echo "Cross-compilation toolchain is ready."
        echo "You can now build Linux targets from macOS with:"
        echo "  BUILD_LINUX_GNU=1 ./build.sh"
        echo "  BUILD_LINUX_MUSL=1 ./build.sh"

    elif [ "$HOST_OS" = "Linux" ]; then
        # Native Linux — check for basic build tools
        echo ""
        echo "Checking native Linux build tools..."

        tools_ok=1

        if command -v cc >/dev/null 2>&1; then
            echo "  cc: $(cc --version 2>/dev/null | head -1)"
        elif command -v gcc >/dev/null 2>&1; then
            echo "  gcc: $(gcc --version 2>/dev/null | head -1)"
        else
            echo "  WARNING: No C compiler found. Install gcc or clang."
            tools_ok=0
        fi

        if command -v pkg-config >/dev/null 2>&1; then
            echo "  pkg-config: $(pkg-config --version 2>/dev/null)"
        else
            echo "  WARNING: pkg-config not found."
            tools_ok=0
        fi

        # For cross-compiling between Linux architectures, check for cross-gcc
        if [ "$HOST_ARCH" = "x86_64" ]; then
            cross_target="aarch64-linux-gnu"
        else
            cross_target="x86_64-linux-gnu"
        fi

        if command -v "${cross_target}-gcc" >/dev/null 2>&1; then
            echo "  ${cross_target}-gcc: found (cross-compilation supported)"
        else
            echo ""
            echo "  NOTE: ${cross_target}-gcc not found."
            echo "  To cross-compile for the other Linux architecture, install it:"
            if command -v apt-get >/dev/null 2>&1; then
                echo "    sudo apt-get install gcc-${cross_target}"
            elif command -v dnf >/dev/null 2>&1; then
                echo "    sudo dnf install gcc-${cross_target}"
            elif command -v pacman >/dev/null 2>&1; then
                echo "    sudo pacman -S ${cross_target}-gcc"
            else
                echo "    Install the cross-compilation GCC for ${cross_target} via your package manager."
            fi
            echo ""
            echo "  Alternatively, install cargo-zigbuild + zig for easy cross-compilation:"
            echo "    cargo install cargo-zigbuild"
            echo "    # Install zig from https://ziglang.org/download/"
        fi

        if [ "$tools_ok" -eq 0 ]; then
            echo ""
            echo "Some build tools are missing. On Debian/Ubuntu:"
            echo "  sudo apt-get install build-essential pkg-config"
            echo "On Fedora:"
            echo "  sudo dnf install gcc pkg-config"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "  Setup summary"
echo "========================================"
echo ""
echo "Rust toolchain:"
rustc --version
cargo --version
echo ""
echo "Installed Rust targets:"
rustup target list --installed | sed 's/^/  /'
echo ""

echo "You can now run the build script:"
echo ""
if [ "$HOST_OS" = "Darwin" ]; then
    echo "  # Default (iOS + macOS):"
    echo "  ./build.sh"
    echo ""
    echo "  # macOS only:"
    echo "  BUILD_IOS=0 BUILD_MACOS=1 ./build.sh"
    echo ""
    if [ "$SETUP_LINUX" -eq 1 ]; then
        echo "  # Linux GNU (cross-compiled via zigbuild):"
        echo "  BUILD_IOS=0 BUILD_MACOS=0 BUILD_LINUX_GNU=1 ./build.sh"
        echo ""
        echo "  # Linux musl (cross-compiled via zigbuild):"
        echo "  BUILD_IOS=0 BUILD_MACOS=0 BUILD_LINUX_MUSL=1 ./build.sh"
        echo ""
        echo "  # Everything:"
        echo "  BUILD_LINUX_GNU=1 BUILD_LINUX_MUSL=1 ./build.sh"
        echo ""
    fi
elif [ "$HOST_OS" = "Linux" ]; then
    echo "  # Default (Linux GNU, native arch):"
    echo "  ./build.sh"
    echo ""
    echo "  # Linux GNU + musl:"
    echo "  BUILD_LINUX_GNU=1 BUILD_LINUX_MUSL=1 ./build.sh"
    echo ""
fi
echo "Setup complete."
