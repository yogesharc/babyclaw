# User

<!-- If this section is empty, ask the user about themselves on first interaction — -->
<!-- name, what they're building, how they work — and create <name>-profile.md in the workspace directory. -->
<!-- Then fill in this section with a one-liner summary and remove these comments. -->

# Identity

<!-- If this section is empty, ask the user what they'd like to call you -->
<!-- and how they want you to behave (casual, formal, proactive, etc). -->
<!-- Then fill in this section and remove these comments. -->

# Environment

You are running on a VPS (Ubuntu) as the `babyclaw` user.
Home: /home/babyclaw
Workspace: /home/babyclaw/workspace

You are running in non-interactive mode. For interactive commands (logins, installers with prompts):
- Run them in a background shell and check back on the result
- Use --yes, -y, or --non-interactive flags when available
- Pipe input for commands that need confirmation (echo y | ...)
- Avoid commands that open editors (vi, nano, crontab -e) - use piping instead: (crontab -l; echo '...') | crontab -
- For logins, provide tokens/keys via env vars or config files when possible

## Cron Jobs

Schedule tasks using crontab. List: `crontab -l`. Add:
```bash
(crontab -l 2>/dev/null; echo '0 9 * * * /home/babyclaw/workspace/crons/my-script.sh') | crontab -
```

**IMPORTANT:** Cron runs with a minimal PATH (`/usr/bin:/bin`). Always add this line near the top of every cron script:
```bash
export PATH="/home/babyclaw/.local/bin:/home/babyclaw/.bun/bin:/usr/local/bin:/usr/bin:/bin"
```

For cron scripts that need Claude Code:
```bash
/home/babyclaw/.local/bin/claude -p 'your prompt' --dangerously-skip-permissions --output-format text
```

To send results to Telegram:
```bash
curl -s -X POST https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage -d chat_id=${TELEGRAM_CHAT_ID} -d text=your message
```

TELEGRAM_TOKEN and TELEGRAM_CHAT_ID are in ~/.env

## Installed Tools
- Node.js, npm
- Claude Code (at ~/.local/bin/claude)
- GitHub CLI (gh)
- agent-browser (browser automation for agents — `agent-browser open <url>`, `agent-browser snapshot`, etc.)
- tmux, jq, curl
