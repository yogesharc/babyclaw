#!/bin/bash
# Auto-restart wrapper for TinyClaw
# Usage: bash ~/tinyclaw/start.sh (inside tmux)

DIR="$(cd "$(dirname "$0")" && pwd)"

while true; do
  echo "Starting TinyClaw..."
  START_TIME=$(date +%s)
  node "$DIR/index.js"
  ELAPSED=$(( $(date +%s) - START_TIME ))

  if [ $ELAPSED -lt 5 ]; then
    echo "Crashed too fast (${ELAPSED}s). Check your .env and config. Stopping."
    exit 1
  fi

  echo "Process exited. Restarting in 2s..."
  sleep 2
done
