#!/bin/bash
# Changelog worker: checks merged PRs, writes changelog entries if needed
# Runs daily after work hours
#
# Schedule: 35 16 * * * (adjust to your timezone)
# What it does:
#   - Fetches PRs merged today from your repo
#   - Asks Claude Code to analyze if any are user-facing / changelog-worthy
#   - If yes, Claude writes a changelog entry, commits it, and creates a PR
#   - Sends a Telegram notification with the PR link

set -euo pipefail

export PATH="/home/tinyclaw/.local/bin:/home/tinyclaw/.bun/bin:/usr/local/bin:/usr/bin:/bin"
source /home/tinyclaw/.env
TODAY=$(TZ=Asia/Kathmandu date +%Y-%m-%d)

REPO="your-org/your-repo"
WORK_DIR="/home/tinyclaw/workspace/issues/changelog-${TODAY}"
LOCK_FILE="/home/tinyclaw/workspace/crons/locks/changelog-${TODAY}.lock"
BRANCH="changelog/${TODAY}"

notify() {
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$1" > /dev/null
}

cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT

# Skip if already running
if [ -f "$LOCK_FILE" ]; then exit 0; fi
touch "$LOCK_FILE"

# Get merged PRs for today
PRS_JSON=$(gh api search/issues --method GET \
  -f q="is:pr is:merged repo:${REPO} merged:${TODAY}" \
  -f per_page=50 \
  --jq '[.items[] | {number: .number, title: .title, body: .body}]' 2>/dev/null)

PR_COUNT=$(echo "$PRS_JSON" | jq 'length')
if [ "$PR_COUNT" -eq 0 ]; then exit 0; fi

PR_SUMMARY=$(echo "$PRS_JSON" | jq -r '.[] | "PR #\(.number): \(.title)\n\(.body // "No description")\n---"')

# Clone repo and set up
mkdir -p /home/tinyclaw/workspace/issues
[ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
gh repo clone "$REPO" "$WORK_DIR" -- --depth=50 2>/dev/null
cd "$WORK_DIR"
git checkout -b "$BRANCH"

# Ask Claude to analyze PRs and write changelog
CLAUDE_PROMPT="You are analyzing today's merged PRs to decide if any warrant a changelog entry.

Today's date: ${TODAY}

Merged PRs today:
${PR_SUMMARY}

Instructions:
1. Look at existing changelog entries to understand the format and style
2. Decide if each PR is user-facing/changelog-worthy
3. If yes, create a changelog entry matching the existing format
4. Commit with message: 'Add changelog entry for ${TODAY}'
5. If nothing is changelog-worthy, output 'NO_CHANGELOG_NEEDED'"

CLAUDE_OUTPUT=$(/home/tinyclaw/.local/bin/claude -p "$CLAUDE_PROMPT" \
  --dangerously-skip-permissions \
  --output-format text \
  2>&1) || true

if echo "$CLAUDE_OUTPUT" | grep -q "NO_CHANGELOG_NEEDED"; then
  rm -rf "$WORK_DIR"
  exit 0
fi

COMMIT_COUNT=$(git log --oneline main..HEAD 2>/dev/null | wc -l)
if [ "$COMMIT_COUNT" -eq 0 ]; then
  rm -rf "$WORK_DIR"
  exit 0
fi

# Push and create PR
git push origin "$BRANCH" 2>/dev/null

PR_URL=$(gh pr create \
  --repo "$REPO" \
  --base main \
  --head "$BRANCH" \
  --title "Add changelog entry for ${TODAY}" \
  --body "Automated changelog entry for PRs merged on ${TODAY}.

$(git log --oneline main..HEAD | sed 's/^/- /')" 2>/dev/null)

notify "Changelog PR created for ${TODAY}
${PR_URL}"

rm -rf "$WORK_DIR"
