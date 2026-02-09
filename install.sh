#!/bin/bash
set -e

# TinyClaw Install Script
# Run as the tinyclaw user AFTER setup-vps.sh and cloning the repo.
# Usage: bash ~/tinyclaw/install.sh

echo "=== TinyClaw Install ==="

TINYCLAW_DIR="$HOME/tinyclaw"

if [ ! -f "$TINYCLAW_DIR/index.js" ]; then
  echo "Error: Run this from the tinyclaw user after cloning the repo to ~/tinyclaw"
  exit 1
fi

# ─── PATH setup ──────────────────────────────────────────────

if ! grep -q "TinyClaw paths" ~/.bashrc 2>/dev/null; then
  cat >> ~/.bashrc << 'EOF'

# TinyClaw paths
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"
EOF
fi

export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"

# ─── npm global prefix ───────────────────────────────────────

mkdir -p "$HOME/.npm-global"
npm config set prefix "$HOME/.npm-global"

# ─── Install Claude Code ─────────────────────────────────────

echo ">>> Installing Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"

# ─── Create workspace ────────────────────────────────────────

echo ">>> Creating workspace..."
mkdir -p ~/workspace
mkdir -p ~/workspace/crons/logs
mkdir -p ~/workspace/history
touch ~/workspace/CLAUDE.md

# ─── Install npm dependencies ────────────────────────────────

echo ">>> Installing dependencies..."
cd "$TINYCLAW_DIR"
npm install

# ─── Claude Code config ──────────────────────────────────────

echo ">>> Setting up Claude Code config..."
mkdir -p ~/.claude

# Global CLAUDE.md (template — Claude fills in User/Identity on first interaction)
if [ ! -f ~/.claude/CLAUDE.md ]; then
  cp "$TINYCLAW_DIR/global-claude.md" ~/.claude/CLAUDE.md
  echo "    Created ~/.claude/CLAUDE.md (template)"
else
  echo "    ~/.claude/CLAUDE.md already exists, skipping"
fi

# Claude settings
if [ ! -f ~/.claude/settings.json ]; then
  cp "$TINYCLAW_DIR/claude-settings.json" ~/.claude/settings.json
  echo "    Created ~/.claude/settings.json"
else
  echo "    ~/.claude/settings.json already exists, skipping"
fi

# ─── .env ─────────────────────────────────────────────────────

if [ ! -f "$TINYCLAW_DIR/.env" ]; then
  cp "$TINYCLAW_DIR/.env.example" "$TINYCLAW_DIR/.env"
  echo ""
  echo ">>> Created .env from template. Edit it now:"
  echo "    nano $TINYCLAW_DIR/.env"
  echo ""
fi

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo "=== Install complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit your .env:          nano ~/tinyclaw/.env"
echo "  2. Auth Claude Code:        claude setup-token"
echo "  3. Start the bot:"
echo "     tmux new -s main"
echo "     bash ~/tinyclaw/start.sh"
echo "     # Detach: Ctrl+B, D"
echo ""
