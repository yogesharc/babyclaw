#!/bin/bash
set -e

# BabyClaw Install Script
# Run as the babyclaw user AFTER setup-vps.sh.
# Usage: curl -fsSL https://raw.githubusercontent.com/yogesharc/babyclaw/main/install.sh | bash

echo "=== BabyClaw Install ==="

# ─── Clone repo into home directory ──────────────────────────

if [ ! -f "$HOME/index.js" ]; then
  echo ">>> Cloning BabyClaw into home directory..."
  cd ~
  git init -q
  git remote add origin https://github.com/yogesharc/babyclaw.git 2>/dev/null || true
  git pull origin main
fi

# ─── PATH setup ──────────────────────────────────────────────

if ! grep -q "BabyClaw paths" ~/.bashrc 2>/dev/null; then
  cat >> ~/.bashrc << 'EOF'

# BabyClaw paths
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

# ─── Install agent-browser ───────────────────────────────────

echo ">>> Installing agent-browser..."
npm install -g agent-browser
npx -y playwright install chromium
mkdir -p ~/.claude/skills/agent-browser
curl -o ~/.claude/skills/agent-browser/SKILL.md \
  https://raw.githubusercontent.com/vercel-labs/agent-browser/main/skills/agent-browser/SKILL.md

# ─── Install ClawdHub and skills.sh ─────────────────────────

echo ">>> Installing ClawdHub (skill registry)..."
npm install -g clawdhub

echo ">>> Installing find-skills skill..."
npx skills install vercel-labs/skills/find-skills

# ─── Create workspace ────────────────────────────────────────

echo ">>> Creating workspace..."
mkdir -p ~/workspace
mkdir -p ~/workspace/crons/logs
mkdir -p ~/workspace/crons/locks
mkdir -p ~/workspace/crons/state
mkdir -p ~/workspace/history
mkdir -p ~/workspace/skills
touch ~/workspace/CLAUDE.md

# Copy history templates
echo ">>> Setting up history templates..."
cp ~/history/mood-log.md ~/workspace/history/mood-log.md
cp ~/history/threads.md ~/workspace/history/threads.md

# Copy cron scripts
echo ">>> Installing cron jobs..."
cp ~/crons/pattern-detector.sh ~/workspace/crons/
cp ~/crons/skills-suggester.sh ~/workspace/crons/
cp ~/crons/personality-updater.sh ~/workspace/crons/
cp ~/crons/daily-digest.sh ~/workspace/crons/
chmod +x ~/workspace/crons/*.sh

# Copy skills
echo ">>> Installing skills..."
cp -r ~/skills/* ~/workspace/skills/

# Schedule cron jobs (skip if already set)
if ! crontab -l 2>/dev/null | grep -q "pattern-detector"; then
  (crontab -l 2>/dev/null; cat << 'CRON'

# BabyClaw - pattern detection and skills suggestion (daily at 22:00 and 22:15 NPT)
15 16 * * * ~/workspace/crons/pattern-detector.sh >> ~/workspace/crons/logs/pattern-detector.log 2>&1
30 16 * * * ~/workspace/crons/skills-suggester.sh >> ~/workspace/crons/logs/skills-suggester.log 2>&1

# BabyClaw - personality updater (runs daily, self-limits to every 3 days)
0 17 * * * ~/workspace/crons/personality-updater.sh >> ~/workspace/crons/logs/personality-updater.log 2>&1

# BabyClaw - daily digest (22:30 NPT)
45 16 * * * ~/workspace/crons/daily-digest.sh >> ~/workspace/crons/logs/daily-digest.log 2>&1
CRON
  ) | crontab -
  echo "    Cron jobs installed"
else
  echo "    Cron jobs already installed, skipping"
fi

# ─── Install npm dependencies ────────────────────────────────

echo ">>> Installing dependencies..."
cd ~
npm install

# ─── Claude Code config ──────────────────────────────────────

echo ">>> Setting up Claude Code config..."
mkdir -p ~/.claude

# Global CLAUDE.md (template — Claude fills in User/Identity on first interaction)
if [ ! -f ~/.claude/CLAUDE.md ]; then
  cp ~/global-claude.md ~/.claude/CLAUDE.md
  echo "    Created ~/.claude/CLAUDE.md (template)"
else
  echo "    ~/.claude/CLAUDE.md already exists, skipping"
fi

# Claude settings
if [ ! -f ~/.claude/settings.json ]; then
  cp ~/claude-settings.json ~/.claude/settings.json
  echo "    Created ~/.claude/settings.json"
else
  echo "    ~/.claude/settings.json already exists, skipping"
fi

# ─── .env ─────────────────────────────────────────────────────

if [ ! -f ~/.env ]; then
  cp ~/.env.example ~/.env
  echo ""
  echo ">>> Created .env from template. Edit it now:"
  echo "    nano ~/.env"
  echo ""
fi

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo "=== Install complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit your .env:          nano ~/.env"
echo "  2. Auth Claude Code:        claude setup-token"
echo "  3. Start the bot:"
echo "     tmux new -s main"
echo "     bash ~/start.sh"
echo "     # Detach: Ctrl+B, D"
echo ""
