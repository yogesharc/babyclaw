#!/bin/bash
set -e

# TinyClaw VPS Setup
# Prerequisites: Ubuntu VPS, root access, git installed
# This script creates the tinyclaw user and sets up the environment.
# After this, switch to tinyclaw user and run install.sh.

echo "=== TinyClaw VPS Setup (root) ==="

if [ "$EUID" -ne 0 ]; then
  echo "Error: Run this as root"
  exit 1
fi

# ─── System packages ─────────────────────────────────────────

echo ">>> Updating system packages..."
apt update && apt upgrade -y

echo ">>> Installing essentials..."
apt install -y curl wget git tmux build-essential unzip jq

echo ">>> Installing Node.js 22..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs

echo ">>> Installing GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt update && apt install -y gh

# ─── Create tinyclaw user ────────────────────────────────────

echo ">>> Creating tinyclaw user..."
id tinyclaw 2>/dev/null || useradd -m -s /bin/bash tinyclaw

# Scoped sudo (install packages only)
cat > /etc/sudoers.d/tinyclaw << 'EOF'
tinyclaw ALL=(ALL) NOPASSWD: /usr/bin/apt-get install *, /usr/bin/apt-get update, /usr/bin/apt-get upgrade, /usr/bin/npm install -g *
EOF
chmod 440 /etc/sudoers.d/tinyclaw
visudo -cf /etc/sudoers.d/tinyclaw

# tmux config
cat > /home/tinyclaw/.tmux.conf << 'EOF'
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
set -g history-limit 50000
EOF
chown tinyclaw:tinyclaw /home/tinyclaw/.tmux.conf

echo ""
echo "=== Root setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Switch to tinyclaw user:  su - tinyclaw"
echo "  2. Clone the repo:           git clone https://github.com/yogesharc/tinyclaw.git ~/tinyclaw"
echo "  3. Run install script:       bash ~/tinyclaw/install.sh"
echo ""
