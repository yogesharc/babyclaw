# BabyClaw

Claude Code on a VPS, controlled from Telegram. A lightweight, single-file alternative to [OpenClaw](https://github.com/anthropics/openclaw). Built on the official Claude Agent SDK.

## Features

- **Always-on Claude Code** — Runs on a VPS, accessible from anywhere via Telegram
- **Talk to it** — Send text, voice messages, or images. Voice is transcribed automatically via Whisper
- **Get files back** — Ask Claude to send you any file (images, code, docs) and it delivers them directly in Telegram
- **Persistent memory** — Conversations auto-save when starting a new session with `/new`. Context survives session resets
- **Personality adaptation** — Claude mirrors your communication style over time and evolves its personality
- **Message queueing** — Send follow-ups while Claude is busy. They queue up and get sent together
- **Cron automation** — Schedule tasks. Claude can set up and manage cron jobs that run scripts, send reports, check issues
- **Model switching** — Swap between Sonnet, Opus, etc. on the fly
- **Remote restart** — `/restart` from Telegram. No SSH needed
- **Single file** — One `index.js`. No framework, no database. Uses the official Claude Agent SDK

## Prerequisites

- A VPS (Ubuntu recommended, any provider works)
- [Claude Code](https://claude.ai/download) with a Claude subscription (Pro, Max) or API key
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- Your Telegram user ID (from [@userinfobot](https://t.me/userinfobot))
- (Optional) OpenAI API key for voice message transcription

## Setup

### 1. Run the setup script (as root)

This installs system packages (Node.js, git, tmux, GitHub CLI) and creates the `babyclaw` user.

```bash
curl -fsSL https://raw.githubusercontent.com/yogesharc/babyclaw/main/setup-vps.sh | bash
```

### 2. Run the install script (as babyclaw)

This clones the repo into the home directory, installs Claude Code, npm dependencies, creates the workspace, and copies config templates.

```bash
su - babyclaw
curl -fsSL https://raw.githubusercontent.com/yogesharc/babyclaw/main/install.sh | bash
```

### 3. Authenticate Claude Code

```bash
claude setup-token
```

### 4. Configure

```bash
nano ~/.env
```

You need at minimum:
- `TELEGRAM_TOKEN` — From @BotFather
- `TELEGRAM_USER_ID` — Your Telegram user ID (locks the bot to only you)

Optional:
- `CLAUDE_CODE_OAUTH_TOKEN` — From `claude setup-token` (for subscription auth)
- `OPENAI_API_KEY` — For voice message transcription
- `TELEGRAM_CHAT_ID` — For cron scripts that send Telegram notifications
- `WORKSPACE` — Directory where Claude Code works (default: `/home/babyclaw/workspace`)

### 5. Start

```bash
tmux new -s main
bash ~/start.sh
# Detach: Ctrl+B, D
```

Open Telegram, find your bot, and send a message. On your first message, Claude will ask your name and what you want to call it, then set up your profile automatically.

## Telegram Commands

| Command | Description |
|---------|-------------|
| `/new` | Start a new session (clears queue) |
| `/status` | Show session, model, thinking state, queue |
| `/model <name>` | Switch model (e.g. `/model opus`) |
| `/thinking` | Toggle extended thinking on/off |
| `/tools` | Toggle tool call notifications |
| `/list` | Show 5 most recent sessions |
| `/list <keywords>` | Search sessions from last 2 weeks (OR match) |
| `/resume <id>` | Resume a previous session by ID |
| `/interrupt` | Stop current task (optionally follow with new message) |
| `/restart` | Restart the bot (auto-restarts via start.sh) |
| `/kill` | Kill stuck task and clear queue |

## Configuration

The install script copies `global-claude.md` to `~/.claude/CLAUDE.md`. This is the global instruction file Claude reads on every interaction. It has three sections:

- **User** — Empty by default. Claude asks who you are on first interaction and fills this in, plus creates a `<name>-profile.md` in your workspace.
- **Identity** — Empty by default. Claude asks what you want to call it and how you want it to behave.
- **Environment** — VPS info, cron job patterns, installed tools. Pre-filled by the template.

## Memory

BabyClaw has three layers of memory:

**Session continuity** — Within a session, Claude remembers everything. Sessions persist across bot restarts via `state.json`. Use `/list` to browse or search past sessions, and `/resume <id>` to pick one back up with full context.

**History** — Long-term memory that survives session resets. Automatically saved when you start a new session with `/new`. Each entry is saved as a dated markdown file (`2026-02-10-topic-name.md`) in `~/workspace/history/`. Claude searches these when a question might relate to something discussed before.

**Recent conversations** — A rolling list of the last 50 history entries is kept in `history/recent.md` and loaded into every new session automatically. This gives Claude awareness of what's been discussed recently without having to search.

## Deploying Updates

```bash
# From your local machine
scp index.js yourserver:/home/babyclaw/
```

Then send `/restart` in Telegram. The bot picks up the new code automatically.

## How It Works

1. Telegram message arrives
2. If Claude is busy, the message is queued (you get a "Queued" confirmation)
3. `query()` is called with the prompt, workspace path, and session ID
4. The async generator yields events until a result message arrives
5. The result is split into 4000-char chunks and sent back to Telegram
6. Any queued messages are combined into a single prompt and sent next

Session IDs are persisted to `state.json` so sessions survive bot restarts.

## Example Crons

The `examples/crons/` folder has real cron scripts I use daily. You don't need to set these up manually — just tell Claude via Telegram what you want automated and it'll create the script, set up crontab, and wire up Telegram notifications.

Here's what I run:

**Daily stats report** (`daily-stats.sh`) — Runs at 10:30 PM. Pulls website analytics via [Supalytics](https://www.supalytics.co?utm_source=babyclaw_repo) CLI (visitors, revenue, conversions, top sources, signups), monitors competitor changelogs for new updates, lists PRs merged that day, and sends a single summary to Telegram. A quick end-of-day review of everything that happened.

**Changelog worker** (`changelog-worker.sh`) — Runs at 10:20 PM, just before the daily stats report. Checks merged PRs, asks Claude Code if any are user-facing, and if so, writes a changelog entry matching the existing format, commits it, and creates a PR. By the time I check the daily stats, the changelog PR is already waiting for review.

**Issue checker + worker** (`issue-checker.sh`, `issue-worker.sh`) — Runs every 15 minutes. Monitors my GitHub project board for issues assigned to a bot account. When it finds one, it clones the repo, runs Claude Code to implement the fix, creates a PR, loops through automated code review, and notifies me when it's ready for final review. Fully autonomous issue resolution.

To set up your own crons, just ask Claude:
> "Set up a cron job that checks my GitHub for new issues every hour and notifies me on Telegram"

Claude will create the script, make it executable, and add it to crontab.

## Built by

[Yogesh](https://yogesh.co?utm_source=babyclaw_repo) — [@yogesharc](https://twitter.com/yogesharc)

## License

MIT
