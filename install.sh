#!/usr/bin/env bash
set -e

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
DATA_DIR="$PREFIX/share/ai-sandbox"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing ai-sandbox (asb) to $PREFIX"

mkdir -p "$BIN_DIR"
install -m755 "$SCRIPT_DIR/bin/ai-sandbox" "$BIN_DIR/ai-sandbox"
# Short alias and per-tool entrypoints: thin symlinks; the launcher auto-detects
# the chosen tool from the invoked name (asb-claude / asb-codex / asb-opencode).
ln -sf ai-sandbox "$BIN_DIR/asb"
ln -sf ai-sandbox "$BIN_DIR/asb-claude"
ln -sf ai-sandbox "$BIN_DIR/asb-codex"
ln -sf ai-sandbox "$BIN_DIR/asb-opencode"

mkdir -p "$DATA_DIR"
install -m644 "$SCRIPT_DIR/share/ai-sandbox/docker-compose.yml" "$DATA_DIR/docker-compose.yml"
install -m755 "$SCRIPT_DIR/share/ai-sandbox/git-wrapper" "$DATA_DIR/git-wrapper"
install -m644 "$SCRIPT_DIR/share/ai-sandbox/config.example.yaml" "$DATA_DIR/config.example.yaml"
# Launcher for the optional host-side Playwright MCP browser service. It is a
# secondary helper invoked by the systemd user unit, so it lives in the package
# data dir (like git-wrapper) and is referenced by absolute path there.
install -m755 "$SCRIPT_DIR/share/ai-sandbox/playwright-mcp" "$DATA_DIR/playwright-mcp"

# Install the systemd user unit for the host-side Playwright MCP browser service
# into the standard per-user unit directory (already on the systemd user search
# path), so enabling is just `systemctl --user enable --now`. Fill in the
# launcher's absolute path (the unit's @PLAYWRIGHT_MCP_BIN@ marker) at install
# time, since the data dir differs per PREFIX.
USER_UNIT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user"
mkdir -p "$USER_UNIT_DIR"
sed "s|@PLAYWRIGHT_MCP_BIN@|$DATA_DIR/playwright-mcp|g" \
    "$SCRIPT_DIR/share/ai-sandbox/systemd/ai-sandbox-playwright.service" \
    > "$USER_UNIT_DIR/ai-sandbox-playwright.service"
chmod 644 "$USER_UNIT_DIR/ai-sandbox-playwright.service"
echo "Installed systemd user unit to $USER_UNIT_DIR"
echo "Enable the browser service (optional, once):"
echo "  systemctl --user daemon-reload && systemctl --user enable --now ai-sandbox-playwright"

echo "Done. Make sure $BIN_DIR is in your PATH."
