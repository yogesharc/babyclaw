#!/bin/bash
# Analyzes recent conversations to suggest relevant skills from ClawHub/skills.sh
# Runs daily at 22:15 NPT

export PATH="/home/tinyclaw/.local/bin:/home/tinyclaw/.bun/bin:/usr/local/bin:/usr/bin:/bin"
set -euo pipefail

source /home/tinyclaw/.env
CHAT_ID="${TELEGRAM_CHAT_ID:-1602530365}"
STATE_DIR="/home/tinyclaw/workspace/crons/state"
HISTORY_DIR="/home/tinyclaw/workspace/history"
WORKSPACE="/home/tinyclaw/workspace"
SKILLS_DIR="/home/tinyclaw/workspace/skills"

mkdir -p "$STATE_DIR" "$SKILLS_DIR"

TODAY=$(date +%Y-%m-%d)
LAST_RUN_FILE="$STATE_DIR/skills-suggester-last.txt"
SUGGESTED_FILE="$STATE_DIR/skills-suggested.txt"
LAST_DATE=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "")

# Skip if already ran today
if [ "$TODAY" = "$LAST_DATE" ]; then
  exit 0
fi

# Get recent session files (last 3 days)
HOME_DIR="/home/tinyclaw"
CWD_SLUG=$(echo "$WORKSPACE" | tr '/' '-')
SESS_DIR="$HOME_DIR/.claude/projects/$CWD_SLUG"

if [ ! -d "$SESS_DIR" ]; then
  exit 0
fi

RECENT_SESSIONS=$(find "$SESS_DIR" -name "*.jsonl" -not -name "agent-*" -mtime -3 2>/dev/null | head -10 || true)

if [ -z "$RECENT_SESSIONS" ]; then
  echo "$TODAY" > "$LAST_RUN_FILE"
  exit 0
fi

# Extract topics from recent sessions
CONVERSATIONS=""
for sess in $RECENT_SESSIONS; do
  MSGS=$(cat "$sess" | jq -r 'select(.type == "user") | .message.content | if type == "array" then map(select(.type == "text") | .text) | join(" ") else . end' 2>/dev/null | head -30 || true)
  if [ -n "$MSGS" ]; then
    CONVERSATIONS="$CONVERSATIONS
$MSGS"
  fi
done

if [ -z "$CONVERSATIONS" ]; then
  echo "$TODAY" > "$LAST_RUN_FILE"
  exit 0
fi

# Get already suggested skills to avoid repeating
ALREADY_SUGGESTED=$(cat "$SUGGESTED_FILE" 2>/dev/null || echo "")

# Get installed skills
INSTALLED_SKILLS=$(npx clawhub list 2>/dev/null | grep -v "No installed" || echo "")

AI_PROMPT="You are analyzing a user's recent conversations to identify if any specialized skill could help them.

RECENT CONVERSATIONS:
${CONVERSATIONS}

ALREADY INSTALLED SKILLS:
${INSTALLED_SKILLS}

ALREADY SUGGESTED (don't repeat):
${ALREADY_SUGGESTED}

Skills come from two sources:
1. ClawHub (clawhub.ai) - actual integrations: APIs, external services, automation tools
2. skills.sh - best practices and guidelines for frameworks/domains

Look for:
- External services they're working with (YouTube, Twitter, trading, etc.)
- Frameworks where best practices would help (React, Next.js, etc.)
- Domains that have specialized skills (design, marketing, security, etc.)

Respond with ONLY valid JSON:
{
  \"should_search\": true/false,
  \"search_queries\": [\"query1\", \"query2\"],
  \"source\": \"clawhub\" or \"skills.sh\",
  \"reason\": \"Why this skill would help\"
}

Only suggest if genuinely useful. Don't force it."

AI_RAW=$(claude -p "$AI_PROMPT" --model sonnet --output-format text 2>/dev/null || echo '{"should_search": false}')
# Strip markdown code blocks and newlines
AI_RESPONSE=$(echo "$AI_RAW" | sed 's/```json//g; s/```//g' | tr -d '\n')

SHOULD_SEARCH=$(echo "$AI_RESPONSE" | jq -r '.should_search // false' 2>/dev/null)
QUERIES=$(echo "$AI_RESPONSE" | jq -r '.search_queries // [] | .[]' 2>/dev/null)
SOURCE=$(echo "$AI_RESPONSE" | jq -r '.source // "clawhub"' 2>/dev/null)
REASON=$(echo "$AI_RESPONSE" | jq -r '.reason // empty' 2>/dev/null)

if [ "$SHOULD_SEARCH" != "true" ] || [ -z "$QUERIES" ]; then
  echo "$TODAY" > "$LAST_RUN_FILE"
  exit 0
fi

# Search for skills
FOUND_SKILLS=""
for query in $QUERIES; do
  if [ "$SOURCE" = "clawhub" ]; then
    RESULTS=$(npx clawhub search "$query" --limit 3 2>/dev/null | head -5 || true)
  else
    RESULTS=$(npx skills find "$query" 2>/dev/null | head -5 || true)
  fi

  if [ -n "$RESULTS" ]; then
    FOUND_SKILLS="$FOUND_SKILLS
$RESULTS"
  fi
done

if [ -z "$FOUND_SKILLS" ]; then
  echo "$TODAY" > "$LAST_RUN_FILE"
  exit 0
fi

# Pick the best skill and vet it
BEST_SKILL=$(echo "$FOUND_SKILLS" | head -1 | awk '{print $1}')

if [ -z "$BEST_SKILL" ]; then
  echo "$TODAY" > "$LAST_RUN_FILE"
  exit 0
fi

# Run skill-vetter
VET_PROMPT="Vet this skill before suggesting to user: $BEST_SKILL from $SOURCE

Run the skill-vetter protocol. Check for red flags. Output ONLY JSON:
{
  \"safe\": true/false,
  \"red_flags\": [\"list if any\"],
  \"risk_level\": \"low/medium/high\"
}"

VET_RAW=$(claude -p "$VET_PROMPT" --model sonnet --output-format text 2>/dev/null || echo '{"safe": false}')
# Strip markdown code blocks and newlines
VET_RESPONSE=$(echo "$VET_RAW" | sed 's/```json//g; s/```//g' | tr -d '\n')

SAFE=$(echo "$VET_RESPONSE" | jq -r '.safe // false' 2>/dev/null)
RISK=$(echo "$VET_RESPONSE" | jq -r '.risk_level // "unknown"' 2>/dev/null)

# Only suggest if safe and low/medium risk
if [ "$SAFE" != "true" ] || [ "$RISK" = "high" ]; then
  echo "$TODAY" > "$LAST_RUN_FILE"
  exit 0
fi

# Track this suggestion
echo "$BEST_SKILL" >> "$SUGGESTED_FILE"

MSG="🔧 Found a skill that might help:

$BEST_SKILL

$REASON

Install with: npx clawhub install $BEST_SKILL"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" \
  --data-urlencode "text=$MSG" > /dev/null

echo "$TODAY" > "$LAST_RUN_FILE"
