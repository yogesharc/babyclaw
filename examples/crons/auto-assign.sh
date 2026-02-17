#!/bin/bash
# Auto-assigns unassigned issues to @maxxclaw if AI determines they can be handled autonomously
# Runs every 2 minutes via cron
# Tracks issues to skip AI call if no new issues since last run
# If nothing can be auto-assigned, notifies with list of issues needing human input

export PATH="/home/tinyclaw/.local/bin:/home/tinyclaw/.bun/bin:/usr/local/bin:/usr/bin:/bin"
set -euo pipefail

source /home/tinyclaw/.env
CHAT_ID=1602530365
LOCK_DIR="/home/tinyclaw/workspace/crons/locks"
LOG_DIR="/home/tinyclaw/workspace/crons/logs"
STATE_DIR="/home/tinyclaw/workspace/crons/state"
REPO="yogesharc/supalytics"

mkdir -p "$LOCK_DIR" "$LOG_DIR" "$STATE_DIR"

LAST_ISSUES_FILE="$STATE_DIR/supalytics-last-issues.txt"

# Skip if any supalytics issue is already being worked on (checker will handle it)
if ls "$LOCK_DIR"/issue-*.lock 1>/dev/null 2>&1; then
  exit 0
fi

# Query project board for all items
ITEMS=$(gh api graphql -f query='
{
  node(id: "PVT_kwHOAot7484BN6hm") {
    ... on ProjectV2 {
      items(first: 50) {
        nodes {
          id
          content {
            ... on Issue {
              number
              title
              assignees(first: 5) { nodes { login } }
              url
            }
          }
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
        }
      }
    }
  }
}' 2>/dev/null)

# Check if maxxclaw already has assigned issues - if so, skip auto-assign
ASSIGNED_COUNT=$(echo "$ITEMS" | jq '
  [.data.node.items.nodes[]
  | select(.fieldValueByName.name == "Backlog" or .fieldValueByName.name == "Todo")
  | select(.content.assignees.nodes[]?.login == "maxxclaw")]
  | length
' 2>/dev/null)

if [ "$ASSIGNED_COUNT" -gt 0 ]; then
  exit 0
fi

# Get unassigned Backlog/Todo issues
UNASSIGNED_JSON=$(echo "$ITEMS" | jq -c '
  [.data.node.items.nodes[]
  | select(.fieldValueByName.name == "Backlog" or .fieldValueByName.name == "Todo")
  | select(.content.assignees.nodes | length == 0)
  | select(.content.number != null)
  | {number: .content.number, title: .content.title, url: .content.url, item_id: .id}]
' 2>/dev/null)

# Check if there are any unassigned issues
ISSUE_COUNT=$(echo "$UNASSIGNED_JSON" | jq 'length' 2>/dev/null)
if [ "$ISSUE_COUNT" -eq 0 ] || [ -z "$ISSUE_COUNT" ]; then
  # Clear state file if no issues
  rm -f "$LAST_ISSUES_FILE"
  exit 0
fi

# Format issues for AI prompt
ISSUES_LIST=$(echo "$UNASSIGNED_JSON" | jq -r '.[] | "#\(.number): \(.title)"' 2>/dev/null)

# Create hash of current issues to detect changes
CURRENT_HASH=$(echo "$ISSUES_LIST" | md5sum | cut -d' ' -f1)
LAST_HASH=$(cat "$LAST_ISSUES_FILE" 2>/dev/null || echo "")

# Check if hash file is older than 2 hours (re-ask even if no changes)
HASH_EXPIRED=false
if [ -f "$LAST_ISSUES_FILE" ]; then
  FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$LAST_ISSUES_FILE") ))
  if [ "$FILE_AGE" -gt 7200 ]; then
    HASH_EXPIRED=true
  fi
fi

# Skip AI call if issues haven't changed and hash hasn't expired
if [ "$CURRENT_HASH" = "$LAST_HASH" ] && [ "$HASH_EXPIRED" = false ]; then
  exit 0
fi

# Save current hash for next run
echo "$CURRENT_HASH" > "$LAST_ISSUES_FILE"

# Ask Claude to decide which issue (if any) can be handled autonomously
AI_PROMPT="You are an AI coding assistant deciding which GitHub issue to work on autonomously.

Here are the open unassigned issues:
${ISSUES_LIST}

RULES for auto-assignment (pick ONLY if you're confident you can complete it without human input):
- Refactoring, cleanup, optimization, linting, formatting
- Documentation, comments, types, JSDoc
- Tests, test coverage
- Dependency updates, package upgrades
- Config, CI/CD, workflows, build setup
- Error handling, logging, validation (backend)
- API endpoints, CRUD operations, database migrations
- Utilities, helpers, middleware
- Removing dead code, deprecations

DO NOT auto-assign (these need human input):
- Bugs that need testing/verification to confirm fix
- New features that need product vision/decisions
- UI/UX/design/styling/layout changes (needs visual review)
- Auth, security, payments (sensitive, needs approval)
- Anything ambiguous or needing clarification

Respond with ONLY valid JSON, no other text:
{\"auto_assign\": <issue_number or null>, \"reason\": \"<brief reason>\", \"human_issues\": [\"#1: title\", \"#2: title\"]}"

AI_RESPONSE=$(claude -p "$AI_PROMPT" --model sonnet --output-format text 2>/dev/null | tr -d '\n')

# Parse AI response
AUTO_NUMBER=$(echo "$AI_RESPONSE" | jq -r '.auto_assign // empty' 2>/dev/null)
REASON=$(echo "$AI_RESPONSE" | jq -r '.reason // empty' 2>/dev/null)
HUMAN_ISSUES=$(echo "$AI_RESPONSE" | jq -r '.human_issues // [] | .[0:5] | join("\n")' 2>/dev/null)

if [ -n "$AUTO_NUMBER" ] && [ "$AUTO_NUMBER" != "null" ]; then
  # Get issue details
  AUTO_ISSUE=$(echo "$UNASSIGNED_JSON" | jq -c ".[] | select(.number == $AUTO_NUMBER)" 2>/dev/null)

  if [ -n "$AUTO_ISSUE" ]; then
    NUMBER=$(echo "$AUTO_ISSUE" | jq -r '.number')
    TITLE=$(echo "$AUTO_ISSUE" | jq -r '.title')
    URL=$(echo "$AUTO_ISSUE" | jq -r '.url')

    # Assign to maxxclaw
    gh issue edit "$NUMBER" --repo "$REPO" --add-assignee maxxclaw 2>/dev/null || true

    # Notify
    MSG="🤖 [Supalytics] Auto-assigning #${NUMBER}: ${TITLE}
${URL}

${REASON}"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d chat_id="$CHAT_ID" \
      --data-urlencode "text=$MSG" > /dev/null

    exit 0
  fi
fi

# No auto-assignable issues - ask about human-needed ones
if [ -n "$HUMAN_ISSUES" ]; then
  MSG="👋 [Supalytics] Nothing I can pick up autonomously. These need your input:

${HUMAN_ISSUES}

Want me to work on anything?"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode "text=$MSG" > /dev/null
fi
