#!/bin/bash
set -e

# BabyClaw VPS Setup
# Prerequisites: Ubuntu VPS, root access, git installed
# This script creates the babyclaw user and sets up the environment.
# After this, switch to babyclaw user and run install.sh.

echo "=== BabyClaw VPS Setup (root) ==="

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

# ─── Create babyclaw user ────────────────────────────────────

echo ">>> Creating babyclaw user..."
id babyclaw 2>/dev/null || useradd -m -s /bin/bash babyclaw

# Scoped sudo (install packages only)
cat > /etc/sudoers.d/babyclaw << 'EOF'
babyclaw ALL=(ALL) NOPASSWD: /usr/bin/apt-get install *, /usr/bin/apt-get update, /usr/bin/apt-get upgrade, /usr/bin/npm install -g *
EOF
chmod 440 /etc/sudoers.d/babyclaw
visudo -cf /etc/sudoers.d/babyclaw

# tmux config
cat > /home/babyclaw/.tmux.conf << 'EOF'
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
set -g history-limit 50000
EOF
chown babyclaw:babyclaw /home/babyclaw/.tmux.conf

echo ""
echo "=== Root setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Switch to babyclaw user:  su - babyclaw"
echo "  2. Clone the repo:           git clone https://github.com/yogesharc/babyclaw.git ~/babyclaw"
echo "  3. Run install script:       bash ~/babyclaw/install.sh"
echo ""
