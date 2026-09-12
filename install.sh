#!/usr/bin/env bash
set -e

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
DATA_DIR="$PREFIX/share/claude-sandboxed"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing claude-sandboxed to $PREFIX"

mkdir -p "$BIN_DIR"
install -m755 "$SCRIPT_DIR/bin/claude-sandboxed" "$BIN_DIR/claude-sandboxed"

mkdir -p "$DATA_DIR"
install -m644 "$SCRIPT_DIR/share/claude-sandboxed/docker-compose.yml" "$DATA_DIR/docker-compose.yml"
install -m755 "$SCRIPT_DIR/share/claude-sandboxed/git-wrapper" "$DATA_DIR/git-wrapper"
install -m644 "$SCRIPT_DIR/share/claude-sandboxed/config.example.yaml" "$DATA_DIR/config.example.yaml"

# Install the systemd user unit for the host-side Playwright MCP browser service
# into the standard per-user unit directory (already on the systemd user search
# path), so enabling is just `systemctl --user enable --now`.
USER_UNIT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user"
mkdir -p "$USER_UNIT_DIR"
install -m644 "$SCRIPT_DIR/share/claude-sandboxed/systemd/claude-sandboxed-playwright.service" "$USER_UNIT_DIR/claude-sandboxed-playwright.service"
echo "Installed systemd user unit to $USER_UNIT_DIR"
echo "Enable the browser service (optional, once):"
echo "  systemctl --user daemon-reload && systemctl --user enable --now claude-sandboxed-playwright"

echo "Done. Make sure $BIN_DIR is in your PATH."
