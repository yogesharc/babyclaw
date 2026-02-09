import { Bot } from "grammy";
import { readFileSync, writeFileSync, existsSync, mkdirSync, createWriteStream, unlinkSync } from "fs";
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
const WORKSPACE = process.env.WORKSPACE || "/home/tinyclaw/workspace";

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

## Identity & User Info

Your identity (name, personality) and info about the user are defined in ~/.claude/CLAUDE.md. The user's detailed profile is linked from there. When asked about yourself or the user, read these files directly — never ask for permission to read config or profile files, just read them.

## Proactive Behavior

You are a personal assistant, not a passive tool. Be proactive:
- **Suggest next steps** — After completing a task, suggest what could be done next or what you noticed along the way.
- **Offer to help** — If you spot issues, improvements, or related tasks, mention them. "Want me to also fix X?" or "I noticed Y, should I look into it?"
- **Memorize important things** — If the conversation covers something worth remembering (decisions, preferences, new projects, important context), offer to save it to history.
- **Never wait passively** — Don't just answer and stop. Think about what the user might need next.
- **Read files directly** — Never ask permission to read files, configs, logs, or code. Just read them. You have full access.

## History (persistent memory across sessions)

You have a persistent history directory at ${WORKSPACE}/history/. This survives session resets.

**Saving:** When asked to memorize or save something to history (or when you think something is worth saving), summarize the relevant parts and save as a markdown file with a descriptive kebab-case filename: ${WORKSPACE}/history/<descriptive-name>.md. Include the date at the top. One topic per file.

**Searching:** When you need to recall past context, use Glob to list files in ${WORKSPACE}/history/ and Grep/Read to search their contents. Do this proactively when a question might relate to something previously saved.`,
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

  if (text === "/start") return ctx.reply("TinyClaw ready.");

  if (text === "/new") {
    messageQueue = [];
    sessionId = randomUUID();
    isNewSession = true;
    saveState();
    return ctx.reply(`New session: ${sessionId.slice(0, 8)}`);
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

  // /memorize [optional context] - summarize conversation and save to history
  if (text === "/memorize" || text.startsWith("/memorize ")) {
    const hint = text.slice(10).trim();
    text = hint
      ? `Summarize the current conversation and save it to history. Focus on: ${hint}`
      : `Summarize the current conversation and save it to history.`;
    // Fall through to send as prompt
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
    { command: "new", description: "Start a new session" },
    { command: "status", description: "Show current session info" },
    { command: "model", description: "Change model (e.g. /model opus)" },
    { command: "thinking", description: "Toggle thinking on/off" },
    { command: "tools", description: "Toggle tool call notifications" },
    { command: "memorize", description: "Save something to history" },
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
