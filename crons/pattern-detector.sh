#!/bin/bash
# Analyzes daily conversation history for patterns and automation opportunities
# Runs daily at 22:00 NPT

export PATH="/home/tinyclaw/.local/bin:/home/tinyclaw/.bun/bin:/usr/local/bin:/usr/bin:/bin"
set -euo pipefail

source /home/tinyclaw/.env
CHAT_ID="${TELEGRAM_CHAT_ID:-1602530365}"
STATE_DIR="/home/tinyclaw/workspace/crons/state"
HISTORY_DIR="/home/tinyclaw/workspace/history"
WORKSPACE="/home/tinyclaw/workspace"

mkdir -p "$STATE_DIR"

TODAY=$(date +%Y-%m-%d)
LAST_RUN_FILE="$STATE_DIR/pattern-detector-last.txt"
LAST_DATE=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "")

# Skip if already ran today
if [ "$TODAY" = "$LAST_DATE" ]; then
  exit 0
fi

# Get today's session files
HOME_DIR="/home/tinyclaw"
CWD_SLUG=$(echo "$WORKSPACE" | tr '/' '-')
SESS_DIR="$HOME_DIR/.claude/projects/$CWD_SLUG"

if [ ! -d "$SESS_DIR" ]; then
  exit 0
fi

# Find sessions modified in last 7 days
RECENT_SESSIONS=$(find "$SESS_DIR" -name "*.jsonl" -not -name "agent-*" -mtime -7 2>/dev/null | head -20 || true)

if [ -z "$RECENT_SESSIONS" ]; then
  echo "$TODAY" > "$LAST_RUN_FILE"
  exit 0
fi

# Extract user messages from recent sessions
CONVERSATIONS=""
for sess in $RECENT_SESSIONS; do
  MSGS=$(cat "$sess" | jq -r 'select(.type == "user") | .message.content | if type == "array" then map(select(.type == "text") | .text) | join(" ") else . end' 2>/dev/null | head -50 || true)
  if [ -n "$MSGS" ]; then
    CONVERSATIONS="$CONVERSATIONS
---
$MSGS"
  fi
done

if [ -z "$CONVERSATIONS" ]; then
  echo "$TODAY" > "$LAST_RUN_FILE"
  exit 0
fi

# Also read recent history for context
RECENT_HISTORY=$(cat "$HISTORY_DIR/recent.md" 2>/dev/null | head -20 || echo "")
THREADS=$(cat "$HISTORY_DIR/threads.md" 2>/dev/null | head -30 || echo "")

AI_PROMPT="You are analyzing a user's daily conversations with their AI assistant to find automation opportunities.

TODAY'S CONVERSATIONS:
${CONVERSATIONS}

RECENT HISTORY:
${RECENT_HISTORY}

OPEN THREADS:
${THREADS}

Look for:
1. Repeated tasks the user does manually (e.g., checking stats, running commands)
2. Workflows that could be cron jobs
3. Patterns in what they ask for

Respond with ONLY valid JSON:
{
  \"found_pattern\": true/false,
  \"suggestion\": \"Brief description of what could be automated\",
  \"implementation\": \"How to implement it (cron, script, etc.)\"
}

If nothing worth automating, set found_pattern to false."

AI_RAW=$(claude -p "$AI_PROMPT" --model sonnet --output-format text 2>/dev/null || echo '{"found_pattern": false}')
# Strip markdown code blocks and newlines
AI_RESPONSE=$(echo "$AI_RAW" | sed 's/```json//g; s/```//g' | tr -d '\n')

FOUND=$(echo "$AI_RESPONSE" | jq -r '.found_pattern // false' 2>/dev/null)
SUGGESTION=$(echo "$AI_RESPONSE" | jq -r '.suggestion // empty' 2>/dev/null)
IMPLEMENTATION=$(echo "$AI_RESPONSE" | jq -r '.implementation // empty' 2>/dev/null)

if [ "$FOUND" = "true" ] && [ -n "$SUGGESTION" ]; then
  MSG="💡 Pattern detected:

$SUGGESTION

$IMPLEMENTATION

Want me to set this up?"

  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode "text=$MSG" > /dev/null
fi

echo "$TODAY" > "$LAST_RUN_FILE"
