# TinyClaw

Claude Code on your VPS, controlled from Telegram. Text, voice, images — all from your phone.

## Features

- **Text, voice, images** — Send any message type, Claude handles it
- **Voice transcription** — Voice messages transcribed via Whisper, then sent to Claude
- **Session continuity** — Conversations persist across messages. `/new` to reset
- **Message queue** — Send follow-up messages while Claude is working. They get combined and sent after
- **Model switching** — Switch between Sonnet, Opus, etc. on the fly
- **Thinking mode** — Toggle extended thinking
- **Memory** — `/memorize` saves conversation context to persistent files that survive session resets
- **Interrupt** — Stop Claude mid-task and optionally send a new message

## Architecture

```
Telegram → Node.js (grammY) → Claude Agent SDK → Claude Code on VPS
```

Single `index.js` file. No framework, no database. Uses the official `@anthropic-ai/claude-agent-sdk` to call Claude Code programmatically.

## Prerequisites

- A VPS (Ubuntu recommended, any provider works)
- [Claude Code](https://claude.ai/download) with a Max subscription or API key
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- Your Telegram user ID (from [@userinfobot](https://t.me/userinfobot))
- (Optional) OpenAI API key for voice message transcription

## Setup

### 1. Run the setup script (as root)

This installs system packages (Node.js, git, tmux, GitHub CLI) and creates the `tinyclaw` user.

```bash
curl -fsSL https://raw.githubusercontent.com/yogesharc/tinyclaw/main/setup-vps.sh | bash
```

### 2. Run the install script (as tinyclaw)

This installs Claude Code, npm dependencies, creates the workspace, and copies config templates.

```bash
su - tinyclaw
git clone https://github.com/yogesharc/tinyclaw.git ~/tinyclaw
bash ~/tinyclaw/install.sh
```

### 3. Configure

```bash
nano ~/tinyclaw/.env
```

You need at minimum:
- `TELEGRAM_TOKEN` — From @BotFather
- `TELEGRAM_USER_ID` — Your Telegram user ID (locks the bot to only you)

Optional:
- `OPENAI_API_KEY` — For voice message transcription
- `TELEGRAM_CHAT_ID` — For cron scripts that send Telegram notifications
- `WORKSPACE` — Directory where Claude Code works (default: `/home/tinyclaw/workspace`)

### 4. Authenticate Claude Code

```bash
claude setup-token
```

### 5. Start

```bash
tmux new -s main
bash ~/tinyclaw/start.sh
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
| `/memorize` | Save conversation summary to persistent history |
| `/interrupt` | Stop current task (optionally follow with new message) |
| `/restart` | Restart the bot (auto-restarts via start.sh) |
| `/kill` | Kill stuck task and clear queue |

## Configuration

The install script copies `global-claude.md` to `~/.claude/CLAUDE.md`. This is the global instruction file Claude reads on every interaction. It has three sections:

- **User** — Empty by default. Claude asks who you are on first interaction and fills this in, plus creates a `<name>-profile.md` in your workspace.
- **Identity** — Empty by default. Claude asks what you want to call it and how you want it to behave.
- **Environment** — VPS info, cron job patterns, installed tools. Pre-filled by the template.

## Deploying Updates

```bash
# From your local machine
scp index.js yourserver:/home/tinyclaw/tinyclaw/
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

## License

MIT
