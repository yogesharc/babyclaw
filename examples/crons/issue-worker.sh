#!/bin/bash
# Issue worker: clones repo, runs Claude Code to fix an issue, creates PR
# Spawned by issue-checker.sh — not run directly via cron
#
# What it does:
#   1. Clones your repo, creates a feature branch
#   2. Runs Claude Code with the issue context as prompt
#   3. Pushes the branch and creates a PR
#   4. Optionally loops through automated code review (e.g. Devin)
#   5. Adds you as reviewer when done
#   6. Updates the project board status at each stage

set -euo pipefail

export PATH="/home/babyclaw/.local/bin:/home/babyclaw/.bun/bin:/usr/local/bin:/usr/bin:/bin"
source /home/babyclaw/.env
ISSUE_NUMBER="$1"
ISSUE_TITLE="$2"
PROJECT_ITEM_ID="$3"

REPO="your-org/your-repo"
WORK_DIR="/home/babyclaw/workspace/issues/issue-${ISSUE_NUMBER}"
LOCK_FILE="/home/babyclaw/workspace/crons/locks/issue-${ISSUE_NUMBER}.lock"
BRANCH="fix/issue-${ISSUE_NUMBER}"

# Your GitHub Project V2 IDs
PROJECT_ID="your_project_id"
STATUS_FIELD_ID="your_status_field_id"
STATUS_IN_PROGRESS="your_in_progress_option_id"
STATUS_REVIEW="your_review_option_id"

notify() {
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$1" > /dev/null
}

cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT

# Move issue to In Progress on project board
gh api graphql -f query="
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: \"$PROJECT_ID\"
    itemId: \"$PROJECT_ITEM_ID\"
    fieldId: \"$STATUS_FIELD_ID\"
    value: { singleSelectOptionId: \"$STATUS_IN_PROGRESS\" }
  }) { projectV2Item { id } }
}" > /dev/null 2>&1

# Clone repo and create branch
mkdir -p /home/babyclaw/workspace/issues
[ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
gh repo clone "$REPO" "$WORK_DIR" -- --depth=50 2>/dev/null
cd "$WORK_DIR"
git checkout -b "$BRANCH"

# Get issue details
ISSUE_BODY=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json body --jq '.body' 2>/dev/null)

# Run Claude Code to fix the issue
notify "Running Claude Code on #${ISSUE_NUMBER}..."

CLAUDE_PROMPT="You are working on issue #${ISSUE_NUMBER} in the ${REPO} repo.

Issue title: ${ISSUE_TITLE}

Issue description:
${ISSUE_BODY}

Instructions:
1. Read and understand the codebase relevant to this issue
2. Implement the fix/feature described in the issue
3. Make sure your changes are correct and don't break existing functionality
4. Commit your changes with a clear commit message referencing #${ISSUE_NUMBER}
5. Do NOT push to main. Only commit to the current branch."

CLAUDE_JSON=$(/home/babyclaw/.local/bin/claude -p "$CLAUDE_PROMPT" \
  --dangerously-skip-permissions \
  --output-format json \
  2>&1) || true

SESSION_ID=$(echo "$CLAUDE_JSON" | jq -r '.session_id // empty')
CLAUDE_OUTPUT=$(echo "$CLAUDE_JSON" | jq -r '.result // empty')

COMMIT_COUNT=$(git log --oneline main..HEAD 2>/dev/null | wc -l)
if [ "$COMMIT_COUNT" -eq 0 ]; then
  notify "#${ISSUE_NUMBER}: Claude didn't produce any commits. Check logs."
  exit 1
fi

# Push and create PR
git push origin "$BRANCH" 2>/dev/null

PR_URL=$(gh pr create \
  --repo "$REPO" \
  --base main \
  --head "$BRANCH" \
  --title "Fix #${ISSUE_NUMBER}: ${ISSUE_TITLE}" \
  --body "Closes #${ISSUE_NUMBER}

## Changes
$(git log --oneline main..HEAD | sed 's/^/- /')

Generated with Claude Code" 2>/dev/null)

PR_NUMBER=$(echo "$PR_URL" | grep -oP '\d+$')

# Add yourself as reviewer and move to Review
gh pr edit "$PR_NUMBER" --repo "$REPO" --add-reviewer your-username 2>/dev/null || true

gh api graphql -f query="
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: \"$PROJECT_ID\"
    itemId: \"$PROJECT_ITEM_ID\"
    fieldId: \"$STATUS_FIELD_ID\"
    value: { singleSelectOptionId: \"$STATUS_REVIEW\" }
  }) { projectV2Item { id } }
}" > /dev/null 2>&1

notify "#${ISSUE_NUMBER}: PR ready for review!
${PR_URL}"

rm -rf "$WORK_DIR"
