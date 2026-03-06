#!/bin/sh
set -e

REPO="tedkoomen/zails"
INSTALL_DIR="$HOME/.zails/bin"

# Detect OS
OS=$(uname -s)
case "$OS" in
    Linux)  OS_TAG="linux" ;;
    Darwin) OS_TAG="macos" ;;
    *)
        echo "Error: unsupported OS: $OS"
        exit 1
        ;;
esac

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)  ARCH_TAG="x86_64" ;;
    arm64|aarch64) ARCH_TAG="aarch64" ;;
    *)
        echo "Error: unsupported architecture: $ARCH"
        exit 1
        ;;
esac

TARGET="${ARCH_TAG}-${OS_TAG}"
ASSET="zails-${TARGET}.tar.gz"

echo "Detected platform: ${TARGET}"

# Get latest release download URL
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep "browser_download_url.*${ASSET}" \
    | cut -d '"' -f 4)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "Error: could not find release asset ${ASSET}"
    echo "Check https://github.com/${REPO}/releases for available downloads."
    exit 1
fi

echo "Downloading ${ASSET}..."
mkdir -p "$INSTALL_DIR"
curl -fsSL "$DOWNLOAD_URL" | tar -xz -C "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/zails"

echo ""
echo "Installed zails to ${INSTALL_DIR}/zails"
echo ""

# Check if already in PATH
case ":$PATH:" in
    *":${INSTALL_DIR}:"*)
        echo "zails is ready to use!"
        ;;
    *)
        echo "Add zails to your PATH by adding this to your shell profile:"
        echo ""
        echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
        echo ""
        ;;
esac
