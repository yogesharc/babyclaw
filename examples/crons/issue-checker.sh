#!/bin/bash
# Issue checker: monitors GitHub project board, auto-assigns work to Claude
# Runs every 15 minutes
#
# Schedule: */15 * * * *
# What it does:
#   - Checks your GitHub project board for issues assigned to your bot account
#   - Moves them from Backlog → Todo → In Progress
#   - Spawns a worker (issue-worker.sh) that clones the repo, runs Claude Code
#     to fix the issue, creates a PR, and optionally loops through code review
#   - Sends Telegram notifications at each stage

export PATH="/home/babyclaw/.local/bin:/home/babyclaw/.bun/bin:/usr/local/bin:/usr/bin:/bin"
set -euo pipefail

source /home/babyclaw/.env
LOCK_DIR="/home/babyclaw/workspace/crons/locks"
LOG_DIR="/home/babyclaw/workspace/crons/logs"
WORKER_SCRIPT="/home/babyclaw/workspace/crons/issue-worker.sh"

# Your GitHub Project V2 IDs (get from GitHub GraphQL API)
PROJECT_ID="your_project_id"
STATUS_FIELD_ID="your_status_field_id"
STATUS_TODO="your_todo_option_id"

# The GitHub account that gets assigned issues for Claude to work on
BOT_USERNAME="your-bot-account"

mkdir -p "$LOCK_DIR" "$LOG_DIR"

# Skip if any issue is already being worked on
if ls "$LOCK_DIR"/issue-*.lock 1>/dev/null 2>&1; then
  exit 0
fi

# Query project board for items
ITEMS=$(gh api graphql -f query='
{
  node(id: "'"$PROJECT_ID"'") {
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

# Find Backlog issues assigned to bot and move to Todo
BACKLOG_ISSUES=$(echo "$ITEMS" | jq -c "
  [.data.node.items.nodes[]
  | select(.fieldValueByName.name == \"Backlog\")
  | select(.content.assignees.nodes[]?.login == \"$BOT_USERNAME\")
  | {number: .content.number, title: .content.title, url: .content.url, item_id: .id}]
  | .[]
" 2>/dev/null)

if [ -n "$BACKLOG_ISSUES" ]; then
  echo "$BACKLOG_ISSUES" | while read -r issue; do
    ITEM_ID=$(echo "$issue" | jq -r '.item_id')
    gh api graphql -f query="
    mutation {
      updateProjectV2ItemFieldValue(input: {
        projectId: \"$PROJECT_ID\"
        itemId: \"$ITEM_ID\"
        fieldId: \"$STATUS_FIELD_ID\"
        value: { singleSelectOptionId: \"$STATUS_TODO\" }
      }) { projectV2Item { id } }
    }" > /dev/null 2>&1
  done
fi

# Pick the first Todo issue to work on
ISSUE=$(echo "$ITEMS" | jq -c "
  [.data.node.items.nodes[]
  | select(.fieldValueByName.name == \"Todo\")
  | select(.content.assignees.nodes[]?.login == \"$BOT_USERNAME\")
  | {number: .content.number, title: .content.title, url: .content.url, item_id: .id}]
  | first // empty
")

if [ -z "$ISSUE" ]; then exit 0; fi

NUMBER=$(echo "$ISSUE" | jq -r '.number')
TITLE=$(echo "$ISSUE" | jq -r '.title')
URL=$(echo "$ISSUE" | jq -r '.url')
ITEM_ID=$(echo "$ISSUE" | jq -r '.item_id')
LOCK_FILE="$LOCK_DIR/issue-${NUMBER}.lock"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK_FILE"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -d chat_id="$TELEGRAM_CHAT_ID" \
  --data-urlencode "text=Starting work on #${NUMBER}: ${TITLE}
${URL}" > /dev/null

# Spawn worker in background
nohup bash "$WORKER_SCRIPT" "$NUMBER" "$TITLE" "$ITEM_ID" \
  > "${LOG_DIR}/issue-${NUMBER}.log" 2>&1 &
