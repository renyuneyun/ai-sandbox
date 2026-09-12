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
install -m755 "$SCRIPT_DIR/share/claude-sandboxed/install-playwright-systemd" "$DATA_DIR/install-playwright-systemd"
mkdir -p "$DATA_DIR/systemd"
install -m644 "$SCRIPT_DIR/share/claude-sandboxed/systemd/claude-sandboxed-playwright.service" "$DATA_DIR/systemd/claude-sandboxed-playwright.service"

echo "Done. Make sure $BIN_DIR is in your PATH."
