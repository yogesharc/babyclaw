#!/bin/bash
# Sends a daily summary of today's conversations to Telegram
# Runs at 22:30 NPT

export PATH="/home/tinyclaw/.local/bin:/home/tinyclaw/.bun/bin:/usr/local/bin:/usr/bin:/bin"
set -euo pipefail

source /home/tinyclaw/.env
CHAT_ID="${TELEGRAM_CHAT_ID:-1602530365}"
HISTORY_DIR="/home/tinyclaw/workspace/history"

TODAY=$(date +%Y-%m-%d)
TODAY_START=$(date -d "$TODAY" +%s)

TOPICS=""

# Check all history files (exclude meta files)
for f in "$HISTORY_DIR"/*.md; do
  [ -f "$f" ] || continue
  BASENAME=$(basename "$f")

  # Skip non-conversation files
  case "$BASENAME" in
    recent.md|threads.md|mood-log.md) continue ;;
  esac

  # Check if created today (filename starts with today's date)
  CREATED_TODAY=false
  if [[ "$BASENAME" == "$TODAY"* ]]; then
    CREATED_TODAY=true
  fi

  # Check if modified today (for resumed sessions)
  MODIFIED_TODAY=false
  FILE_MTIME=$(stat -c %Y "$f" 2>/dev/null)
  if [ -n "$FILE_MTIME" ] && [ "$FILE_MTIME" -ge "$TODAY_START" ]; then
    MODIFIED_TODAY=true
  fi

  # Include if created or modified today
  if [ "$CREATED_TODAY" = true ] || [ "$MODIFIED_TODAY" = true ]; then
    # Extract title from filename: 2026-02-17-some-topic.md -> some topic
    TITLE=$(echo "$BASENAME" | sed 's/\.md$//' | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//' | tr '-' ' ')
    TOPICS="$TOPICS
• $TITLE"
  fi
done

if [ -z "$TOPICS" ]; then
  exit 0
fi

MSG="📋 Today's conversations:
$TOPICS"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" \
  --data-urlencode "text=$MSG" > /dev/null
