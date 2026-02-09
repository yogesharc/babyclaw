#!/bin/bash
# Auto-restart wrapper for TinyClaw
# Usage: bash ~/tinyclaw/start.sh (inside tmux)

DIR="$(cd "$(dirname "$0")" && pwd)"

while true; do
  echo "Starting TinyClaw..."
  node "$DIR/index.js"
  echo "Process exited. Restarting in 2s..."
  sleep 2
done
