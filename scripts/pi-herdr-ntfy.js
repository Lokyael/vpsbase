import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const ENV_FILE = path.join(os.homedir(), ".config", "herdr-ntfy", "herdr-ntfy.env");
const LOG_FILE = path.join(os.homedir(), ".cache", "pi-ntfy.log");

function readEnv() {
  const values = {};
  try {
    for (const line of fs.readFileSync(ENV_FILE, "utf8").split("\n")) {
      const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)\s*$/);
      if (!match) continue;
      values[match[1]] = match[2].replace(/^(['"])(.*)\1$/, "$2");
    }
  } catch {
    // Missing optional configuration disables notifications.
  }
  return values;
}

function log(message) {
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true, mode: 0o700 });
    fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${message}\n`, { mode: 0o600 });
  } catch {
    // Notification diagnostics must never affect Pi.
  }
}

async function sendNotification(title, tags, message, priority = "default") {
  const env = readEnv();
  const server = env.NTFY_SERVER?.replace(/\/+$/, "");
  const topic = env.NTFY_TOPIC;
  const token = env.NTFY_TOKEN;

  if (!server || !topic) {
    log("推送跳过: 未配置 NTFY_SERVER 或 NTFY_TOPIC");
    return;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 3000);

  try {
    const response = await fetch(`${server}/${encodeURIComponent(topic)}`, {
      method: "POST",
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        "Content-Type": "text/plain; charset=utf-8",
        "X-Title": title,
        "X-Priority": priority,
        "X-Tags": tags,
      },
      body: message,
      signal: controller.signal,
    });

    if (!response.ok) {
      log(`推送失败: HTTP ${response.status} (${title})`);
      return;
    }
    log(`推送成功: ${title}`);
  } catch (error) {
    log(`推送异常: ${error instanceof Error ? error.message : String(error)}`);
  } finally {
    clearTimeout(timeout);
  }
}

function projectName(ctx) {
  const cwd = typeof ctx?.cwd === "string" && ctx.cwd ? ctx.cwd : process.cwd();
  return path.basename(path.resolve(cwd)) || "当前目录";
}

function completionMessage(ctx) {
  return `项目: ${projectName(ctx)}\n状态: 已完成`;
}

function blockedMessage(project, label) {
  return `项目: ${project}\n状态: 等待确认\n${label}`;
}

export default function (pi) {
  let tuiSession = false;
  let blocked = false;
  let sessionProject = "当前目录";

  pi.on("session_start", (_event, ctx) => {
    tuiSession = ctx?.mode === "tui";
    sessionProject = projectName(ctx);
    blocked = false;
  });

  pi.on("agent_settled", async (_event, ctx) => {
    if (!tuiSession || ctx?.mode !== "tui") return;
    await sendNotification("Pi 回答完成", "white_check_mark", completionMessage(ctx));
  });

  pi.events.on("herdr:blocked", async (data) => {
    if (data?.active === false) {
      blocked = false;
      return;
    }
    if (!tuiSession || !data?.active || blocked) return;
    blocked = true;
    const label = typeof data.label === "string" && data.label ? data.label : "任务等待人工确认";
    await sendNotification("Agent 等待确认", "warning,stop_sign", blockedMessage(sessionProject, label), "high");
  });
}
