import { Bot } from "grammy";
import { readFileSync, writeFileSync, existsSync, mkdirSync, createWriteStream, unlinkSync, readdirSync, statSync } from "fs";
import { InputFile } from "grammy";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { randomUUID } from "crypto";
import https from "https";
import { query } from "@anthropic-ai/claude-agent-sdk";

// Load .env
const __dirname = dirname(fileURLToPath(import.meta.url));
const envPath = join(__dirname, ".env");
if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, "utf-8").split("\n")) {
    const trimmed = line.trim();
    if (trimmed && !trimmed.startsWith("#")) {
      const [key, ...rest] = trimmed.split("=");
      if (key && rest.length) process.env[key] = rest.join("=");
    }
  }
}

const TELEGRAM_TOKEN = process.env.TELEGRAM_TOKEN;
const ALLOWED_USER_ID = process.env.TELEGRAM_USER_ID;
const WORKSPACE = process.env.WORKSPACE || "/home/babyclaw/workspace";

if (!TELEGRAM_TOKEN) { console.error("TELEGRAM_TOKEN required"); process.exit(1); }

// Persist state to disk
const statePath = join(__dirname, "state.json");
function loadState() {
  if (existsSync(statePath)) {
    try { return JSON.parse(readFileSync(statePath, "utf-8")); } catch { }
  }
  return null;
}
function saveState() {
  writeFileSync(statePath, JSON.stringify({ sessionId, isNewSession, model, thinking, verbose, currentChatId }, null, 2));
}

const saved = loadState();
let currentChatId = saved?.currentChatId || null;
let sessionId = saved?.sessionId || randomUUID();
let isNewSession = saved?.isNewSession ?? true;
let isProcessing = false;
let thinking = saved?.thinking ?? false;
let model = saved?.model || "";
let verbose = saved?.verbose ?? false;
let currentQuery = null;
let messageQueue = []; // queued messages while Claude is busy
saveState(); // persist on startup

const bot = new Bot(TELEGRAM_TOKEN);

function splitMessage(text, max) {
  const chunks = [];
  while (text.length > 0) {
    if (text.length <= max) { chunks.push(text); break; }
    let bp = text.lastIndexOf("\n", max);
    if (bp < max / 2) bp = text.lastIndexOf(" ", max);
    if (bp < max / 2) bp = max;
    chunks.push(text.slice(0, bp));
    text = text.slice(bp).trimStart();
  }
  return chunks;
}

async function interruptClaude() {
  if (currentQuery) {
    try { await currentQuery.interrupt(); } catch {}
    currentQuery = null;
  }
  isProcessing = false;
}

const IMAGE_EXTS = /\.(png|jpg|jpeg|gif|webp|svg|bmp)$/i;

function isImagePath(p) {
  return p && IMAGE_EXTS.test(p);
}

function formatToolCall(name, input) {
  const shortName = name.replace(/^(Bash|Read|Write|Edit|Glob|Grep|WebFetch|WebSearch|Task)$/, (m) => m);
  let summary = shortName;
  if (name === "Bash" && input?.command) {
    summary = `$ ${input.command.slice(0, 200)}`;
  } else if (name === "Read" && input?.file_path) {
    summary = `Read ${input.file_path}`;
  } else if (name === "Write" && input?.file_path) {
    summary = `Write ${input.file_path}`;
  } else if (name === "Edit" && input?.file_path) {
    summary = `Edit ${input.file_path}`;
  } else if ((name === "Glob" || name === "Grep") && input?.pattern) {
    summary = `${name} ${input.pattern}`;
  } else if (name === "Task" && input?.description) {
    summary = `Task: ${input.description}`;
  }
  return summary;
}

async function runClaude(prompt, chatId) {
  console.log(`> claude: ${prompt.slice(0, 100)}`);

  const options = {
    cwd: WORKSPACE,
    permissionMode: "bypassPermissions",
    systemPrompt: {
      type: "preset",
      preset: "claude_code",
      append: `You are being controlled via a Telegram bot. When the user asks you to send/show them an image file, include [SEND_IMAGE: /absolute/path/to/image] in your response and the orchestrator will deliver it to Telegram. Only use this when explicitly asked to send an image.

When the user asks you to send them a file (any file type - markdown, text, code, etc.), include [SEND_FILE: /absolute/path/to/file] in your response and the orchestrator will send it as a Telegram document. Use this for any file the user wants to download/read on their device.

## Identity & User Info

Your identity (name, personality) and info about the user are defined in ~/.claude/CLAUDE.md. The user's detailed profile is linked from there. When asked about yourself or the user, read these files directly — never ask for permission to read config or profile files, just read them.

## Proactive Behavior

You are a personal assistant, not a passive tool. Be proactive:
- **Suggest next steps** — After completing a task, suggest what could be done next or what you noticed along the way.
- **Offer to help** — If you spot issues, improvements, or related tasks, mention them. "Want me to also fix X?" or "I noticed Y, should I look into it?"
- **Never wait passively** — Don't just answer and stop. Think about what the user might need next.
- **Read files directly** — Never ask permission to read files, configs, logs, or code. Just read them. You have full access.

## Personality Adaptation

Observe how the user communicates — their tone, slang, sentence structure, emoji usage, formality level. Gradually adapt your communication style to match theirs.

When you notice distinct patterns in how they talk (e.g., they use "ngl", "tbh", short sentences, or specific phrases), start mirroring those naturally. Don't force it or be cringe about it.

## Browser Automation

Use \`agent-browser\` for web automation. Run \`agent-browser --help\` for all commands.

Core workflow:
1. \`agent-browser open <url>\` - Navigate to page
2. \`agent-browser snapshot -i\` - Get interactive elements with refs (@e1, @e2)
3. \`agent-browser click @e1\` / \`fill @e2 "text"\` - Interact using refs
4. Re-snapshot after page changes

## Mood & Energy Awareness

Pay attention to emotional cues in messages — frustration, low energy, enthusiasm. When you sense the user is off:
- Acknowledge it naturally, don't be clinical
- Offer to just chat if they seem stuck

**Mood log:** Silently update ${WORKSPACE}/history/mood-log.md when you notice mood shifts. Don't ask permission or announce it. Just log:
- Date/time, day of week
- Mood level, trigger, context
- Resolution plan and outcome

Look for patterns over time (e.g., gym day mornings = resistance).

## Open Threads

**Creating threads:** When a topic comes up that's ongoing, paused, or unresolved, silently add it to ${WORKSPACE}/history/threads.md. Don't ask or announce — just do it. Examples:
- User mentions learning something but pauses it
- A project is discussed but not finished
- User expresses a problem without immediate resolution (isolation, motivation, etc.)

**Resurfacing threads:** Check threads.md and bring up relevant topics naturally:
- After completing a task: "btw, still thinking about X?"
- When relevant context comes up
- When user asks "what should I work on"

**Closing threads:** When something is resolved, silently move it to the Resolved section.

Don't force resurfacing. Only mention if genuinely relevant.

## History (persistent memory across sessions)

All conversations are automatically saved. You have a persistent history directory at ${WORKSPACE}/history/ for important summaries and decisions.

**Searching past context:** Use Glob to list files in ${WORKSPACE}/history/ and Grep/Read to search their contents. Do this proactively when a question might relate to something previously discussed.

## Recent Conversations
${(() => { try { return readFileSync(join(WORKSPACE, 'history', 'recent.md'), 'utf-8'); } catch { return 'No recent history.'; } })()}`,
    },
  };

  if (model) options.model = model;
  if (thinking) options.maxThinkingTokens = 10000;
  if (!isNewSession) options.resume = sessionId;

  const q = query({ prompt, options });
  currentQuery = q;

  let resultText = "";
  let resultSessionId = null;

  for await (const message of q) {
    if (message.type === "assistant" && verbose && chatId) {
      const toolBlocks = message.message?.content?.filter((b) => b.type === "tool_use") || [];
      for (const block of toolBlocks) {
        const summary = formatToolCall(block.name, block.input);
        bot.api.sendMessage(chatId, `🔧 ${summary}`).catch(() => {});
      }
    }
    if (message.type === "result") {
      resultSessionId = message.session_id;
      if (message.subtype === "success") {
        resultText = message.result;
      } else {
        const errors = message.errors?.join("; ") || "Unknown error";
        throw new Error(errors);
      }
    }
  }

  // Parse [SEND_IMAGE: /path] markers from result and send to Telegram
  if (chatId) {
    const imageMarkers = resultText.matchAll(/\[SEND_IMAGE:\s*(.+?)\]/g);
    for (const match of imageMarkers) {
      const imgPath = match[1].trim();
      try {
        if (existsSync(imgPath) && isImagePath(imgPath)) {
          await bot.api.sendPhoto(chatId, new InputFile(imgPath));
        }
      } catch (err) {
        console.error(`Failed to send image ${imgPath}:`, err.message);
      }
    }
    resultText = resultText.replace(/\[SEND_IMAGE:\s*.+?\]\n?/g, "").trim();
  }

  // Parse [SEND_FILE: /path] markers from result and send as document
  if (chatId) {
    const fileMarkers = resultText.matchAll(/\[SEND_FILE:\s*(.+?)\]/g);
    for (const match of fileMarkers) {
      const filePath = match[1].trim();
      try {
        if (existsSync(filePath)) {
          await bot.api.sendDocument(chatId, new InputFile(filePath));
        } else {
          await bot.api.sendMessage(chatId, `File not found: ${filePath}`);
        }
      } catch (err) {
        console.error(`Failed to send file ${filePath}:`, err.message);
      }
    }
    resultText = resultText.replace(/\[SEND_FILE:\s*.+?\]\n?/g, "").trim();
  }

  currentQuery = null;

  // Capture session ID from result for future resumes
  if (resultSessionId) {
    sessionId = resultSessionId;
  }
  isNewSession = false;
  saveState();

  console.log(`< claude: ${resultText.slice(0, 100)}...`);
  return resultText;
}

// Fire-and-forget: send prompt to Claude, reply when done, then drain queue
function sendToClaude(chatId, text) {
  isProcessing = true;

  const typingInterval = setInterval(() => {
    bot.api.sendChatAction(chatId, "typing").catch(() => {});
  }, 4000);
  bot.api.sendChatAction(chatId, "typing").catch(() => {});

  runClaude(text, chatId).then((response) => {
    clearInterval(typingInterval);
    if (response) {
      const chunks = splitMessage(response, 4000);
      chunks.reduce((p, chunk) => p.then(() => bot.api.sendMessage(chatId, chunk)), Promise.resolve());
    } else {
      bot.api.sendMessage(chatId, "Done (no output)");
    }
  }).catch((error) => {
    clearInterval(typingInterval);
    console.error("Error:", error.message);
    bot.api.sendMessage(chatId, `Error: ${error.message.slice(0, 500)}`);
  }).finally(() => {
    isProcessing = false;
    drainQueue();
  });
}

// Process queued messages after current task finishes
function drainQueue() {
  if (isProcessing || messageQueue.length === 0) return;
  // Combine all queued messages into a single prompt
  const combined = messageQueue.map((m) => m.text).join("\n\n");
  const chatId = messageQueue[messageQueue.length - 1].chatId;
  messageQueue = [];
  sendToClaude(chatId, combined);
}

// Add a message to the queue (called when Claude is busy)
function enqueueMessage(chatId, text) {
  messageQueue.push({ chatId, text });
  const pos = messageQueue.length;
  bot.api.sendMessage(chatId, `Queued (${pos} pending)`).catch(() => {});
}

// Download a Telegram file to a local path
async function downloadTelegramFile(fileId, destPath) {
  const file = await bot.api.getFile(fileId);
  const url = `https://api.telegram.org/file/bot${TELEGRAM_TOKEN}/${file.file_path}`;
  return new Promise((resolve, reject) => {
    const out = createWriteStream(destPath);
    https.get(url, (res) => {
      res.pipe(out);
      out.on("finish", () => { out.close(); resolve(destPath); });
    }).on("error", (err) => { out.close(); reject(err); });
  });
}

// Transcribe audio file to text via OpenAI Whisper API
async function transcribe(filePath) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) throw new Error("OPENAI_API_KEY not set");

  const fileBuffer = readFileSync(filePath);
  const fileName = filePath.split("/").pop();
  const blob = new Blob([fileBuffer]);

  const form = new FormData();
  form.append("file", blob, fileName);
  form.append("model", "whisper-1");
  form.append("response_format", "text");

  const res = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { "Authorization": `Bearer ${apiKey}` },
    body: form,
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Whisper API error ${res.status}: ${err}`);
  }

  return (await res.text()).trim();
}

const tmpDir = join(__dirname, "tmp");
mkdirSync(tmpDir, { recursive: true });
const botStartTime = Math.floor(Date.now() / 1000);

bot.on("message", async (ctx) => {
  // Ignore messages sent before bot started (prevents /restart loop)
  if (ctx.message.date < botStartTime) return;
  console.log("MSG:", ctx.message.text || "(voice/audio)", "from:", ctx.from.id);
  if (ALLOWED_USER_ID && ctx.from.id.toString() !== ALLOWED_USER_ID) return ctx.reply("Unauthorized");

  // Handle photo messages
  const photo = ctx.message.photo;
  if (photo && photo.length > 0) {
    currentChatId = ctx.chat.id;
    const largest = photo[photo.length - 1]; // highest resolution
    const filePath = join(tmpDir, `photo_${Date.now()}.jpg`);
    try {
      await downloadTelegramFile(largest.file_id, filePath);
      const caption = ctx.message.caption || "I'm sending you this image. Describe what you see or do what I ask.";
      const prompt = `[Image attached at ${filePath}]\n\n${caption}`;
      if (isProcessing) {
        enqueueMessage(ctx.chat.id, prompt);
      } else {
        sendToClaude(ctx.chat.id, prompt);
      }
    } catch (err) {
      try { unlinkSync(filePath); } catch {}
      console.error("Photo error:", err.message);
      return ctx.reply(`Photo error: ${err.message.slice(0, 200)}`);
    }
    return;
  }

  // Handle voice/audio messages
  const voice = ctx.message.voice || ctx.message.audio;
  if (voice && !ctx.message.text) {
    currentChatId = ctx.chat.id;
    const ext = ctx.message.voice ? "ogg" : "mp3";
    const filePath = join(tmpDir, `voice_${Date.now()}.${ext}`);
    try {
      await downloadTelegramFile(voice.file_id, filePath);
      ctx.reply("Transcribing...").catch(() => {});
      const transcribedText = await transcribe(filePath);
      unlinkSync(filePath);
      if (!transcribedText || !transcribedText.trim()) return ctx.reply("Couldn't transcribe audio.");
      ctx.reply(`Heard: ${transcribedText}`).catch(() => {});
      if (isProcessing) {
        enqueueMessage(ctx.chat.id, transcribedText);
      } else {
        sendToClaude(ctx.chat.id, transcribedText);
      }
    } catch (err) {
      try { unlinkSync(filePath); } catch {}
      console.error("Voice error:", err.message);
      return ctx.reply(`Voice error: ${err.message.slice(0, 200)}`);
    }
    return;
  }

  if (!ctx.message.text) return;
  currentChatId = ctx.chat.id;
  let text = ctx.message.text;

  // --- Commands (always processed immediately, never queued) ---

  if (text === "/start") return ctx.reply("BabyClaw ready.");

  if (text === "/new") {
    // If busy, kill current task first
    if (isProcessing) {
      await interruptClaude();
    }
    messageQueue = [];
    // Memorize current session before starting new one
    if (!isNewSession) {
      isProcessing = true;
      ctx.reply("Saving current session...").catch(() => {});
      const typingInterval = setInterval(() => {
        bot.api.sendChatAction(ctx.chat.id, "typing").catch(() => {});
      }, 4000);
      bot.api.sendChatAction(ctx.chat.id, "typing").catch(() => {});
      try {
        await runClaude("Run the /memorize skill to save this conversation to history.", ctx.chat.id);
      } catch (err) {
        console.error("Memorize error:", err.message);
        // Continue anyway - don't block new session creation
      } finally {
        clearInterval(typingInterval);
        isProcessing = false;
      }
    }
    sessionId = randomUUID();
    isNewSession = true;
    saveState();
    return ctx.reply(`New session: ${sessionId.slice(0, 8)}`);
  }

  // /skip - new session without saving to history
  if (text === "/skip") {
    if (isProcessing) {
      await interruptClaude();
    }
    messageQueue = [];
    sessionId = randomUUID();
    isNewSession = true;
    saveState();
    return ctx.reply(`New session (skipped save): ${sessionId.slice(0, 8)}`);
  }

  if (text === "/status") {
    return ctx.reply(
      `Session: ${sessionId.slice(0, 8)}\n` +
      `Model: ${model || "default"}\n` +
      `Thinking: ${thinking ? "on" : "off"}\n` +
      `Verbose: ${verbose ? "on" : "off"}\n` +
      `Busy: ${isProcessing}\n` +
      `Queued: ${messageQueue.length}`
    );
  }

  if (text === "/thinking") {
    thinking = !thinking;
    saveState();
    return ctx.reply(`Thinking: ${thinking ? "on" : "off"}`);
  }

  if (text === "/tools") {
    verbose = !verbose;
    saveState();
    return ctx.reply(`Tool calls: ${verbose ? "on" : "off"}`);
  }

  if (text === "/restart") {
    currentChatId = ctx.chat.id;
    saveState();
    await ctx.reply("Restarting...");
    process.exit(0);
  }

  if (text === "/kill") {
    messageQueue = [];
    if (currentQuery) {
      await interruptClaude();
      return ctx.reply("Killed current task and cleared queue.");
    }
    return ctx.reply("Nothing running.");
  }

  // /interrupt or /interrupt <follow-up message>
  if (text === "/interrupt" || text.startsWith("/interrupt ")) {
    if (currentQuery) {
      await interruptClaude();
      const followUp = text.slice(10).trim();
      if (!followUp) return ctx.reply("Interrupted.");
      text = followUp;
      // Fall through to send as prompt
    } else {
      const followUp = text.slice(10).trim();
      if (!followUp) return ctx.reply("Nothing running.");
      text = followUp;
    }
  }

  // /list <keywords> - search recent sessions (OR matching)
  if (text === "/list" || text.startsWith("/list ")) {
    const keywords = text.slice(6).trim().toLowerCase().split(/\s+/).filter(Boolean);
    const browseMode = keywords.length === 0;

    const homeDir = process.env.HOME || "/home/babyclaw";
    const cwdSlug = WORKSPACE.replace(/\//g, "-");
    const sessDir = join(homeDir, ".claude", "projects", cwdSlug);

    if (!existsSync(sessDir)) return ctx.reply("No sessions found.");

    const twoWeeksAgo = Date.now() - 14 * 24 * 60 * 60 * 1000;
    const files = readdirSync(sessDir)
      .filter((f) => f.endsWith(".jsonl") && !f.startsWith("agent-"))
      .map((f) => ({ name: f, path: join(sessDir, f), mtime: statSync(join(sessDir, f)).mtimeMs }))
      .filter((f) => f.mtime > twoWeeksAgo && statSync(f.path).size > 0)
      .sort((a, b) => b.mtime - a.mtime);

    const matches = [];
    for (const file of files) {
      try {
        const lines = readFileSync(file.path, "utf-8").split("\n").filter(Boolean);
        let firstMsg = "";
        let allText = "";
        for (const line of lines) {
          const obj = JSON.parse(line);
          if (obj.type === "user" && obj.message?.content) {
            const content = obj.message.content;
            let msgText = "";
            if (Array.isArray(content)) {
              const textBlock = content.find((b) => b.type === "text");
              if (textBlock) msgText = textBlock.text;
            } else if (typeof content === "string") {
              msgText = content;
            }
            if (!firstMsg && msgText) firstMsg = msgText;
            allText += " " + msgText;
          }
        }
        if (!browseMode) {
          const lower = allText.toLowerCase();
          if (!keywords.some((kw) => lower.includes(kw))) continue;
        }
        const id = file.name.replace(".jsonl", "");
        const date = new Date(file.mtime).toISOString().slice(0, 10);
        const preview = firstMsg.slice(0, 60).replace(/\n/g, " ");
        matches.push({ date, preview, id });
      } catch {}
    }

    if (matches.length === 0) return ctx.reply(browseMode ? "No recent sessions." : `No sessions matching "${keywords.join(", ")}".`);
    const limit = browseMode ? 5 : 10;
    for (const m of matches.slice(0, limit)) {
      await ctx.reply(`${m.date}\n${m.preview}`, { parse_mode: "HTML" }).catch(() => {});
      await ctx.reply(m.id).catch(() => {});
    }
    return;
  }

  // /resume <session-id> - resume a previous session
  if (text === "/resume" || text.startsWith("/resume ")) {
    const id = text.slice(8).trim();
    if (!id) return ctx.reply("Usage: /resume <session-id>\nUse /list <keyword> to find session IDs.");
    messageQueue = [];
    sessionId = id;
    isNewSession = false;
    saveState();
    return ctx.reply(`Resumed session: ${id.slice(0, 8)}`);
  }

  // /model or /model <name>
  if (text === "/model" || text.startsWith("/model ")) {
    const newModel = text.slice(7).trim();
    if (!newModel) {
      return ctx.reply(`Current model: ${model || "default"}\nUse: /model sonnet or /model opus etc.`);
    }
    model = newModel;
    saveState();
    return ctx.reply(`Model set to: ${model}`);
  }

  // --- Prompt handling (non-blocking, with queueing) ---

  if (isProcessing) {
    enqueueMessage(ctx.chat.id, text);
    return;
  }

  sendToClaude(ctx.chat.id, text);
});

bot.catch((err) => console.error("Bot error:", err.message));

async function main() {
  const me = await bot.api.getMe();

  await bot.api.setMyCommands([
    { command: "new", description: "Start a new session (saves current)" },
    { command: "skip", description: "New session without saving" },
    { command: "status", description: "Show current session info" },
    { command: "model", description: "Change model (e.g. /model opus)" },
    { command: "thinking", description: "Toggle thinking on/off" },
    { command: "tools", description: "Toggle tool call notifications" },
    { command: "list", description: "Search recent sessions (e.g. /list deploy)" },
    { command: "resume", description: "Resume a session (e.g. /resume abc123...)" },
    { command: "restart", description: "Restart the bot" },
    { command: "kill", description: "Kill stuck Claude process" },
    { command: "interrupt", description: "Stop current task (optionally send new message)" },
  ]);

  console.log(`Bot: @${me.username}`);
  bot.start({
    onStart: () => {
      console.log("Polling started");
      if (currentChatId) {
        bot.api.sendMessage(currentChatId, "Restarted.").catch(() => {});
      }
    },
    allowed_updates: ["message"],
  });
  console.log(`Session: ${sessionId} (${isNewSession ? "new" : "resumed"})`);
}
main().catch(console.error);
