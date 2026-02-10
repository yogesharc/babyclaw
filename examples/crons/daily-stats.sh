#!/bin/bash
# Daily stats report: website analytics + competitor monitoring + merged PRs
# Runs at 10:30 PM local time, gives you a full picture of the day
#
# Schedule: 45 16 * * * (16:45 UTC = 22:30 Nepal time, adjust to your timezone)
# What it does:
#   - Pulls website analytics via Supalytics CLI (visitors, revenue, conversions)
#   - Lists top traffic sources and signup sources
#   - Monitors competitor changelog for new updates
#   - Shows PRs merged today across your org
#   - Sends everything as a single Telegram message

export PATH="/home/tinyclaw/.local/bin:/home/tinyclaw/.bun/bin:/usr/local/bin:/usr/bin:/bin"
set -euo pipefail

source /home/tinyclaw/.env
TODAY=$(TZ=Asia/Kathmandu date +%Y-%m-%d)
TZ_OPT="--timezone Asia/Kathmandu"

# --- Website analytics via Supalytics CLI (https://www.supalytics.co) ---
STATS_JSON=$(supalytics query -m visitors,revenue,conversions,conversion_rate --start "$TODAY" --end "$TODAY" $TZ_OPT --json 2>/dev/null)
VISITORS=$(echo "$STATS_JSON" | jq '.data[0].metrics.visitors // 0')
REVENUE=$(echo "$STATS_JSON" | jq '.data[0].metrics.revenue // 0')
CONVERSIONS=$(echo "$STATS_JSON" | jq '.data[0].metrics.conversions // 0')
CONV_RATE=$(echo "$STATS_JSON" | jq '.data[0].metrics.conversion_rate // 0')

REFS_JSON=$(supalytics query -d referrer -m visitors --start "$TODAY" --end "$TODAY" $TZ_OPT -l 3 --json 2>/dev/null)
TOP_SOURCES=$(echo "$REFS_JSON" | jq -r '.data[] | "  \(.dimensions.referrer): \(.metrics.visitors)"')
[ -z "$TOP_SOURCES" ] && TOP_SOURCES="  None"

# --- Secondary site analytics ---
SITE2_STATS=$(supalytics query -m visitors -s your-other-site.com --start "$TODAY" --end "$TODAY" $TZ_OPT --json 2>/dev/null)
SITE2_VISITORS=$(echo "$SITE2_STATS" | jq '.data[0].metrics.visitors // 0')

SITE2_REFS_JSON=$(supalytics query -d referrer -m visitors -s your-other-site.com --start "$TODAY" --end "$TODAY" $TZ_OPT -l 3 --json 2>/dev/null)
SITE2_SOURCES=$(echo "$SITE2_REFS_JSON" | jq -r '.data[] | "  \(.dimensions.referrer): \(.metrics.visitors)"')
[ -z "$SITE2_SOURCES" ] && SITE2_SOURCES="  None"

# --- Signups ---
SIGNUP_JSON=$(supalytics query -d referrer -f "event:is:signup" -m visitors --start "$TODAY" --end "$TODAY" $TZ_OPT --json 2>/dev/null)
SIGNUPS_TOTAL=$(echo "$SIGNUP_JSON" | jq '[.data[].metrics.visitors] | add // 0')
SIGNUP_SOURCES=$(echo "$SIGNUP_JSON" | jq -r '.data[] | select(.dimensions.referrer != "") | "  \(.dimensions.referrer): \(.metrics.visitors)"')
[ -z "$SIGNUP_SOURCES" ] && SIGNUP_SOURCES="  Direct only"

# --- Competitor changelog monitoring ---
# Fetches a competitor's changelog page and detects new entries
COMPETITOR_CACHE="/home/tinyclaw/workspace/crons/competitor-changelog.txt"
COMPETITOR_SECTION=""

COMPETITOR_HTML=$(curl -s "https://competitor.example.com/changelog" 2>/dev/null || echo "")
if [ -n "$COMPETITOR_HTML" ]; then
  LATEST_ENTRY=$(echo "$COMPETITOR_HTML" | grep -oP '(January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}' | head -1)

  if [ -n "$LATEST_ENTRY" ]; then
    CACHED_ENTRY=""
    [ -f "$COMPETITOR_CACHE" ] && CACHED_ENTRY=$(cat "$COMPETITOR_CACHE")

    if [ "$LATEST_ENTRY" != "$CACHED_ENTRY" ] && [ -n "$CACHED_ENTRY" ]; then
      FEATURE_TITLE=$(echo "$COMPETITOR_HTML" | grep -oP '(?<=<h3[^>]*>)[^<]+' | head -1 || echo "New update")
      COMPETITOR_SECTION="
Competitor Update
  ${LATEST_ENTRY}: ${FEATURE_TITLE}"
    fi

    echo "$LATEST_ENTRY" > "$COMPETITOR_CACHE"
  fi
fi

# --- Merged PRs (grouped by repo) ---
REPO_ORG="your-org"
PRS_RAW=$(gh api search/issues --method GET \
  -f q="is:pr is:merged org:${REPO_ORG} merged:${TODAY}" \
  -f per_page=50 \
  --jq '.items[] | "\(.repository_url | split("/") | .[-1])\t\(.title)"' 2>/dev/null)

if [ -z "$PRS_RAW" ]; then
  PRS_SECTION="None today"
else
  PRS_SECTION=""
  PREV_REPO=""
  while IFS=$'\t' read -r repo title; do
    if [ "$repo" != "$PREV_REPO" ]; then
      [ -n "$PREV_REPO" ] && PRS_SECTION="${PRS_SECTION}
"
      PRS_SECTION="${PRS_SECTION}${repo}:"
      PREV_REPO="$repo"
    fi
    PRS_SECTION="${PRS_SECTION}
  - ${title}"
  done <<< "$(echo "$PRS_RAW" | sort)"
fi

# --- Build and send message ---
MESSAGE="Daily Report - ${TODAY}

Main Site
  Visitors: ${VISITORS}
  Revenue: \$${REVENUE}
  Conversions: ${CONVERSIONS} (${CONV_RATE}%)
  Top Sources:
${TOP_SOURCES}

Signups: ${SIGNUPS_TOTAL}
  Sources:
${SIGNUP_SOURCES}

Secondary Site
  Visitors: ${SITE2_VISITORS}
  Top Sources:
${SITE2_SOURCES}

PRs Merged
${PRS_SECTION}${COMPETITOR_SECTION}"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -d chat_id="$TELEGRAM_CHAT_ID" \
  --data-urlencode "text=$MESSAGE" > /dev/null
