#!/bin/bash
# Analyzes recent conversations to update AI personality/communication style
# Runs every 3 days

export PATH="/home/tinyclaw/.local/bin:/home/tinyclaw/.bun/bin:/usr/local/bin:/usr/bin:/bin"
set -euo pipefail

source /home/tinyclaw/.env
STATE_DIR="/home/tinyclaw/workspace/crons/state"
WORKSPACE="/home/tinyclaw/workspace"
CLAUDE_MD="/home/tinyclaw/.claude/CLAUDE.md"

mkdir -p "$STATE_DIR"

LAST_RUN_FILE="$STATE_DIR/personality-updater-last.txt"
LAST_RUN=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "0")
NOW=$(date +%s)
THREE_DAYS=$((3 * 24 * 60 * 60))

# Skip if ran within last 3 days
if [ $((NOW - LAST_RUN)) -lt $THREE_DAYS ]; then
  exit 0
fi

# Get recent session files (last 7 days)
HOME_DIR="/home/tinyclaw"
CWD_SLUG=$(echo "$WORKSPACE" | tr '/' '-')
SESS_DIR="$HOME_DIR/.claude/projects/$CWD_SLUG"

if [ ! -d "$SESS_DIR" ]; then
  exit 0
fi

RECENT_SESSIONS=$(find "$SESS_DIR" -name "*.jsonl" -not -name "agent-*" -mtime -7 2>/dev/null | head -15 || true)

if [ -z "$RECENT_SESSIONS" ]; then
  echo "$NOW" > "$LAST_RUN_FILE"
  exit 0
fi

# Extract user messages to analyze communication style
USER_MESSAGES=""
for sess in $RECENT_SESSIONS; do
  MSGS=$(cat "$sess" | jq -r 'select(.type == "user") | .message.content | if type == "array" then map(select(.type == "text") | .text) | join(" ") else . end' 2>/dev/null | head -30 || true)
  if [ -n "$MSGS" ]; then
    USER_MESSAGES="$USER_MESSAGES
$MSGS"
  fi
done

if [ -z "$USER_MESSAGES" ]; then
  echo "$NOW" > "$LAST_RUN_FILE"
  exit 0
fi

# Read current CLAUDE.md
CURRENT_CLAUDE=$(cat "$CLAUDE_MD" 2>/dev/null || echo "")

AI_PROMPT="You are analyzing a user's communication style from their recent messages to update an AI assistant's personality config.

USER'S RECENT MESSAGES:
${USER_MESSAGES}

CURRENT PERSONALITY CONFIG (CLAUDE.md):
${CURRENT_CLAUDE}

Analyze the user's communication patterns:
- Tone (casual, formal, blunt, friendly)
- Common slang or phrases they use
- Sentence length/structure
- Emoji usage
- How they give instructions (detailed vs brief)
- Any preferences you can infer

If you notice patterns worth capturing, output JSON with updates to make:
{
  \"should_update\": true/false,
  \"observations\": \"What you noticed about their style\",
  \"identity_update\": \"New content for the Identity section (or null if no change needed)\"
}

Only suggest updates if there are meaningful patterns. Don't force it."

AI_RAW=$(claude -p "$AI_PROMPT" --model sonnet --output-format text 2>/dev/null || echo '{"should_update": false}')
AI_RESPONSE=$(echo "$AI_RAW" | sed 's/```json//g; s/```//g' | tr -d '\n')

SHOULD_UPDATE=$(echo "$AI_RESPONSE" | jq -r '.should_update // false' 2>/dev/null)
OBSERVATIONS=$(echo "$AI_RESPONSE" | jq -r '.observations // empty' 2>/dev/null)
IDENTITY_UPDATE=$(echo "$AI_RESPONSE" | jq -r '.identity_update // empty' 2>/dev/null)

if [ "$SHOULD_UPDATE" = "true" ] && [ -n "$IDENTITY_UPDATE" ] && [ "$IDENTITY_UPDATE" != "null" ]; then
  # Update the Identity section in CLAUDE.md
  # Find and replace the Identity section
  python3 << EOF
import re

with open("$CLAUDE_MD", "r") as f:
    content = f.read()

new_identity = """# Identity

$IDENTITY_UPDATE"""

# Replace Identity section (from # Identity to next # or end)
pattern = r'# Identity\n.*?(?=\n# |\Z)'
if re.search(pattern, content, re.DOTALL):
    content = re.sub(pattern, new_identity.strip(), content, flags=re.DOTALL)
else:
    # Append if not found
    content = content + "\n\n" + new_identity

with open("$CLAUDE_MD", "w") as f:
    f.write(content)

print("Updated")
EOF

fi

echo "$NOW" > "$LAST_RUN_FILE"
