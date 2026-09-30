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

# Shell completions (bash + zsh). Authoritative copies live in the data dir;
# the shell-specific dirs place them where bash-completion / zsh compinit look
# automatically (for standard prefixes). No user rc files are modified.
mkdir -p "$DATA_DIR/completions"
install -m644 "$SCRIPT_DIR/share/ai-sandbox/completions/ai-sandbox.bash" "$DATA_DIR/completions/ai-sandbox.bash"
install -m644 "$SCRIPT_DIR/share/ai-sandbox/completions/_ai-sandbox" "$DATA_DIR/completions/_ai-sandbox"

# bash-completion: one file per command name (the loader matches by name), so
# the aliases are symlinks, mirroring the $BIN_DIR layout.
mkdir -p "$PREFIX/share/bash-completion/completions"
install -m644 "$SCRIPT_DIR/share/ai-sandbox/completions/ai-sandbox.bash" "$PREFIX/share/bash-completion/completions/ai-sandbox"
for _c in asb asb-claude asb-codex asb-opencode; do
    ln -sf ai-sandbox "$PREFIX/share/bash-completion/completions/$_c"
done

# zsh: a single _ai-sandbox function with a #compdef line covers every name.
mkdir -p "$PREFIX/share/zsh/site-functions"
install -m644 "$SCRIPT_DIR/share/ai-sandbox/completions/_ai-sandbox" "$PREFIX/share/zsh/site-functions/_ai-sandbox"

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
echo "Shell completion: bash-completion/zsh pick up the files in"
echo "  $PREFIX/share/bash-completion/completions and $PREFIX/share/zsh/site-functions"
echo "  automatically. If your shell does not, source or add to fpath the copies in"
echo "  $DATA_DIR/completions (see README)."
