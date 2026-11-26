#!/usr/bin/env bash
# Pi OpenAI-compatible 配置生成器；协议来自逐模型策略与 Responses API 探测，规格来自 models.dev。
set -Eeuo pipefail

CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
show_help() {
    cat <<'EOF'
用法: bash tools/pi/pi.sh [-h|--help]
通过终端交互输入 Provider ID、Base URL 和 API Key，回车保留已有值。
  -h, --help  显示帮助

有效列表排除媒体/向量类及 gpt-6.2 以下模型，按 models.dev 规格重建目标 Provider；
gpt-6.2 及以上前缀模型逐个询问 Responses API 策略，发现失败、能力未知或无候选模型时不更新配置。
非 gpt- 模型使用 openai-completions；确认或探测支持的 gpt- 模型优先使用 openai-responses。默认模型在 Pi /model 中选择，按 Ctrl+S 保存。
Windows pwsh: sh.exe -c "bash tools/pi/pi.sh"
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        *) printf '✘ 未知参数: %s\n' "$1" >&2; exit 1 ;;
    esac
done

# 阶段一：依赖就绪
IS_WINDOWS=0
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* || -n "${WINDIR:-}" ]]; then
    IS_WINDOWS=1
    command -v scoop >/dev/null 2>&1 || { printf '✘ 请先就绪 Scoop\n' >&2; exit 1; }
    for entry in git:git node:nodejs-lts pi:pi-coding-agent rg:ripgrep fd:fd; do
        if ! command -v "${entry%%:*}" >/dev/null 2>&1; then
            scoop install "${entry#*:}"
        fi
    done
else
    if ! command -v node >/dev/null 2>&1 && command -v fnm >/dev/null 2>&1; then
        FNM_ENV=$(fnm env --shell bash)
        eval "$FNM_ENV"
    fi
    if command -v paru >/dev/null 2>&1 && { ! command -v pi >/dev/null 2>&1 || ! command -v rg >/dev/null 2>&1 || ! command -v fd >/dev/null 2>&1; }; then
        paru -S --needed --noconfirm --skipreview pi-coding-agent-bin ripgrep fd
    fi
fi
for tool in node pi rg fd; do
    command -v "$tool" >/dev/null 2>&1 || { printf '✘ 缺少依赖: %s\n' "$tool" >&2; exit 1; }
done
node -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<22 || (a===22 && b<19)) { console.error("✘ 需要 Node.js 22.19 或更新版本"); process.exit(1); }'

BASH_PATH="$BASH"
if [ "$IS_WINDOWS" -eq 1 ]; then
    CONFIG_DIR=$(cygpath -m "$CONFIG_DIR")
    BASH_PATH=$(cygpath -m "$BASH_PATH")
fi
umask 077
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 阶段二～四：交互配置、模型发现、Responses API 探测与原子写入
cat > "$WORK_DIR/pi.mjs" <<'NODE'
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import { Writable } from "node:stream";
import { pathToFileURL } from "node:url";

const PROBE_MAX_OUTPUT_TOKENS = 256;
const SETTINGS_SCHEMA = "https://pi.dev/schemas/settings.schema.json";
const MODELS_DEV_URL = "https://models.dev/api.json";
const PROVIDER_PRIORITY = ["anthropic", "openai", "google", "deepseek", "meta", "alibaba", "qwen", "mistral"];

const isObject = value => value !== null && typeof value === "object" && !Array.isArray(value);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const isSingleLine = value => typeof value === "string" && !/[\r\n]/.test(value);

export function readConfig(configDir, name, fallback) {
  const file = path.join(configDir, name);
  let text;
  try { text = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""); }
  catch (error) { if (error.code === "ENOENT") return { value: fallback, text: null }; throw error; }
  let value;
  try {
    // models.json：移除行注释和尾逗号，保留字符串。
    const json = name === "models.json" ? text
      .replace(/"(?:\\.|[^"\\])*"|\/\/[^\n]*/g, m => m[0] === '"' ? m : "")
      .replace(/"(?:\\.|[^"\\])*"|,(\s*[}\]])/g, (m, tail) => tail ?? m) : text;
    value = JSON.parse(json);
  } catch { throw new Error(`${name} JSON 无法解析`); }
  check(isObject(value), `${name} 顶层必须为对象`);
  return { value, text };
}

export function validateSettings(settings) {
  for (const key of ["defaultProvider", "shellPath"]) {
    check(settings[key] === undefined || typeof settings[key] === "string", `settings.json ${key} 必须为字符串`);
  }
  for (const key of ["compaction", "terminal", "markdown"]) {
    check(settings[key] === undefined || isObject(settings[key]), `settings.json ${key} 必须为对象`);
  }
}

export function loadConfigs(configDir) {
  const models = readConfig(configDir, "models.json", { providers: {} });
  const auth = readConfig(configDir, "auth.json", {});
  const settings = readConfig(configDir, "settings.json", {});
  check(isObject(models.value.providers), "models.json providers 必须为对象");
  for (const provider of Object.values(models.value.providers)) {
    check(isObject(provider), "models.json Provider 必须为对象");
    check(provider.baseUrl === undefined || typeof provider.baseUrl === "string", "Provider baseUrl 必须为字符串");
    check(provider.models === undefined || (Array.isArray(provider.models) && provider.models.every(m => isObject(m) && typeof m.id === "string" && m.id.trim())), "Provider models 必须包含有效模型 ID");
  }
  for (const credential of Object.values(auth.value)) {
    check(isObject(credential), "auth.json 凭据项必须为对象");
    check(credential.env === undefined || (isObject(credential.env) && Object.values(credential.env).every(v => typeof v === "string")), "auth.json env 必须为字符串映射");
    check((credential.type === "api_key" && (credential.key === undefined || typeof credential.key === "string")) ||
      (credential.type === "oauth" && typeof credential.access === "string" && typeof credential.refresh === "string" && Number.isFinite(credential.expires)), "auth.json 凭据结构无效");
  }
  validateSettings(settings.value);
  return { models, auth, settings };
}

export function prepareSettings(settings, bashPath) {
  const shell = settings.shellPath;
  const detected = process.platform === "win32"
    ? bashPath.replace(/([/\\]apps[/\\]git[/\\])[^/\\]+(?=[/\\])/i, "$1current")
    : bashPath;
  const candidate = shell ? shell.replace(/^~(?=[/\\]|$)/, os.homedir()) : detected;
  let stat;
  try { stat = fs.statSync(candidate); }
  catch { throw new Error("Shell 路径必须指向现有文件"); }
  check(stat.isFile(), "Shell 路径必须指向现有文件");
  try { fs.accessSync(candidate, process.platform === "win32" ? fs.constants.F_OK : fs.constants.X_OK); }
  catch { throw new Error("Shell 路径不可访问"); }
  if (process.platform === "win32" && shell === undefined) settings.shellPath = candidate.replace(/\\/g, "/");
  Object.assign(settings, {
    $schema: SETTINGS_SCHEMA,
    defaultThinkingLevel: "high",
    theme: "system",
    tuiMode: "fullscreen",
    quietStartup: true,
    enableInstallTelemetry: false,
    sessionShareDestination: "auto",
    cacheWarming: "off",
    compaction: { ...settings.compaction, enabled: false },
    terminal: { ...settings.terminal, showImages: false },
    markdown: { ...settings.markdown, mermaid: "off" }
  });
}

export function isObsoleteGpt(id) {
  const match = id.match(/(?:^|\/)gpt-(\d+)(?:\.(\d+))?/i);
  if (!match) return false;
  const major = Number(match[1]);
  const minor = Number(match[2] ?? 0);
  return major < 6 || (major === 6 && minor < 2);
}

export function discoverModels(parsed) {
  const list = Array.isArray(parsed) ? parsed : parsed?.data;
  check(Array.isArray(list), "模型列表结构无效：需要 data 数组或顶层数组");
  check(list.every(m => isObject(m) && typeof m.id === "string" && m.id.trim() && !/[\r\n\t]/.test(m.id)), "模型列表包含无效模型 ID");
  const ids = [...new Set(list.map(m => m.id).filter(id => !/image|embed|tts|audio|whisper|batch/i.test(id) && !isObsoleteGpt(id)))];
  check(ids.length > 0, list.length ? "模型列表经当前名称过滤后没有候选模型" : "端点返回空模型列表");
  return ids;
}

export function makeModels(ids, db, decisions = {}) {
  check(isObject(db) && Object.keys(db).length > 0, "models.dev 参数库必须为非空对象");
  check(isObject(decisions), "Responses API 决策必须为对象");
  for (const id of ids) {
    if (id.startsWith("gpt-") && !(isObject(decisions[id]) && ["openai-completions", "openai-responses"].includes(decisions[id].api))) {
      throw new Error(`gpt- 模型 ${id} 缺少有效 Responses API 决策`);
    }
  }
  const exact = new Map(), canonical = new Map();
  for (const pid of new Set([...PROVIDER_PRIORITY, ...Object.keys(db)])) {
    if (!Object.hasOwn(db, pid)) continue;
    check(isObject(db[pid]) && isObject(db[pid].models), "models.dev Provider models 结构无效");
    for (const [id, spec] of Object.entries(db[pid].models)) {
      for (const key of [id.toLowerCase(), `${pid}/${id}`.toLowerCase()]) {
        if (!exact.has(key)) exact.set(key, spec);
      }
      if (isObject(spec) && typeof spec.canonical_model_id === "string" && !canonical.has(spec.canonical_model_id.toLowerCase())) {
        canonical.set(spec.canonical_model_id.toLowerCase(), spec);
      }
    }
  }
  let unmatched = 0;
  const models = ids.map(id => {
    const clean = id.toLowerCase().trim();
    const bare = clean.includes("/") ? clean.slice(clean.indexOf("/") + 1) : clean;
    const base = bare.replace(/-(thinking|high|low|medium|search)$/, "");
    const spec = [clean, bare, base].map(key => exact.get(key) || canonical.get(key)).find(Boolean);
    const model = { id };
    if (id.startsWith("gpt-")) {
      const decision = decisions[id];
      if (decision.api === "openai-responses") model.api = "openai-responses";
      if (isObject(decision.compat) && Object.keys(decision.compat).length) model.compat = decision.compat;
    }
    if (!spec) {
      unmatched++;
      return model;
    }
    check(isObject(spec), `models.dev 模型规格无效: ${id}`);
    if (spec.name !== undefined) {
      check(typeof spec.name === "string" && spec.name.trim(), `models.dev ${id} name 无效`);
      model.name = spec.name;
    }
    for (const [source, target] of [["context", "contextWindow"], ["output", "maxTokens"]]) {
      const value = spec.limit?.[source];
      if (value === undefined) continue;
      check(Number.isSafeInteger(value) && value > 0, `models.dev ${id} limit.${source} 无效`);
      model[target] = value;
    }
    if (spec.reasoning !== undefined) {
      check(typeof spec.reasoning === "boolean", `models.dev ${id} reasoning 无效`);
      model.reasoning = spec.reasoning;
    }
    if (spec.modalities?.input !== undefined) {
      check(Array.isArray(spec.modalities.input) && spec.modalities.input.every(i => typeof i === "string"), `models.dev ${id} modalities.input 无效`);
      const input = [...new Set(spec.modalities.input.map(i => i.startsWith("image/") ? "image" : i).filter(i => i === "text" || i === "image"))];
      if (input.length) model.input = input;
    }
    if (spec.cost !== undefined) {
      check(isObject(spec.cost), `models.dev ${id} cost 无效`);
      if (spec.cost.input !== undefined && spec.cost.output !== undefined) {
        model.cost = { input: spec.cost.input, output: spec.cost.output, cacheRead: spec.cost.cache_read ?? 0, cacheWrite: spec.cost.cache_write ?? 0 };
        check(Object.values(model.cost).every(n => typeof n === "number" && Number.isFinite(n) && n >= 0), `models.dev ${id} cost 无效`);
      }
    }
    return model;
  });
  return { models, unmatched };
}

export function classifyProbeFailure(status, body) {
  const text = String(body || "").toLowerCase();
  if (status === 401 || status === 403) return "auth-unknown";
  if (status === 429) return "quota-unknown";
  if (status >= 500) return "server-unknown";
  // HTTP 404 也可能是模型不存在，先分类响应体，不将裸 404 直接判为端点不支持。
  if (/model[_ -]?not[_ -]?(found|available)|unknown model|model[^\n]*(not found|does not exist|不存在|不可用|not supported|unsupported|invalid|unknown)/i.test(text)) return "model-unsupported";
  if (/((responses|response)[^\n]*(endpoint|route|path|url)[^\n]*(not found|not supported|unsupported|invalid))|(endpoint|route|path|url)[^\n]*(not found|not supported|unsupported|invalid)|unsupported[^\n]*(endpoint|route|path)|method[^\n]*(not allowed|unsupported)/i.test(text) || status === 405) return "endpoint-unsupported";
  if (/developer[^\n]*(role|message|not supported|unsupported|invalid|unknown)|invalid[^\n]*(developer|role)|unsupported[^\n]*developer/i.test(text)) return "developer-unsupported";
  if (/max[_ -]?output[_ -]?tokens[^\n]*(not supported|unsupported|invalid|unknown|unrecognized)|unknown (field|parameter)[^\n]*max[_ -]?output|unrecognized request argument[^\n]*max[_ -]?output/i.test(text)) return "max-output-unsupported";
  if (/tool[^\n]*(not supported|unsupported|invalid|unknown)|unsupported[^\n]*tool/i.test(text)) return "tools-unsupported";
  return "unknown";
}

function extractSseData(block) {
  return block.split(/\r?\n/).filter(line => line.startsWith("data:")).map(line => line.slice(5).trimStart()).join("\n");
}
function terminalEvent(event) {
  return ["response.completed", "response.failed", "response.incomplete", "error"].includes(event?.type);
}
function createSseState() {
  const events = [];
  let text = "", sawSse = false, malformed = false, stopped = false;
  return {
    consume(block, stopOnTerminal) {
      const data = extractSseData(block);
      if (!data) return;
      sawSse = true;
      text += `data: ${data}\n\n`;
      if (data === "[DONE]") {
        events.push({ type: "done" });
        if (stopOnTerminal) stopped = true;
        return;
      }
      try {
        const event = JSON.parse(data);
        events.push(event);
        if (stopOnTerminal && terminalEvent(event)) stopped = true;
      } catch {
        malformed = true;
        stopped = true;
      }
    },
    get stopped() { return stopped; },
    result(rawText) { return { text: sawSse ? text : (rawText ?? text), events, sawSse, malformed }; }
  };
}

export async function readSseResponse(response) {
  // 保留文本响应 fallback，便于离线替身和不提供 ReadableStream 的实现工作。
  if (!response.body?.getReader) {
    const text = await response.text();
    const state = createSseState();
    for (const block of String(text).split(/\r?\n\r?\n/)) {
      state.consume(block, false);
      if (state.stopped) break;
    }
    return state.result(text);
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const state = createSseState();
  let buffer = "", raw = "";
  try {
    while (!state.stopped) {
      const part = await reader.read();
      if (part.done) {
        const tail = decoder.decode();
        buffer += tail;
        if (!state.sawSse) raw += tail;
        break;
      }
      const chunk = decoder.decode(part.value, { stream: true });
      buffer += chunk;
      if (!state.sawSse && raw.length < 16384) raw += chunk;
      const blocks = buffer.split(/\r?\n\r?\n/);
      buffer = blocks.pop() || "";
      for (const block of blocks) {
        state.consume(block, true);
        if (state.stopped) break;
      }
    }
    if (!state.stopped && buffer) state.consume(buffer, true);
  } finally {
    if (state.stopped) {
      try { await reader.cancel(); } catch { /* 终止事件后取消读取不影响探测结论 */ }
    }
  }
  return state.result(raw);
}

async function probeRequest(fetchImpl, baseUrl, key, payload) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetchImpl(`${baseUrl}/responses`, {
      method: "POST",
      headers: { "content-type": "application/json", ...(key ? { authorization: `Bearer ${key}` } : {}) },
      body: JSON.stringify(payload), signal: controller.signal
    });
    if (!response.ok) {
      const text = await response.text();
      return { status: response.status, text, events: [], sawSse: false, malformed: false };
    }
    return { status: response.status, ...(await readSseResponse(response)) };
  } catch (error) {
    return { status: 0, text: error.name === "AbortError" ? "timeout" : "network error", events: [], sawSse: false, malformed: false };
  } finally { clearTimeout(timer); }
}

const probeText = result => [result.text, ...(result.events || []).map(event => JSON.stringify(event))].filter(Boolean).join("\n");
const probeFailure = result => classifyProbeFailure(result.status, probeText(result));
const successful = result => result.status >= 200 && result.status < 300;
const completed = parsed => parsed.events.some(event => event.type === "response.completed") &&
  !parsed.events.some(event => event.type === "response.failed" || event.type === "response.incomplete" || event.type === "error");
const isProbeComplete = result => successful(result) && result.sawSse && !result.malformed && completed(result);

export function functionCall(parsed) {
  // 按官方 Responses SDK 聚合；不可将 output_item.added 视为完整调用（参数可能为空或未完成）。
  const calls = new Map();
  const keyOf = (event, item) => Number.isSafeInteger(event.output_index)
    ? `index:${event.output_index}`
    : (item?.id || event.item_id) ? `id:${item?.id || event.item_id}` : undefined;
  for (const event of parsed.events) {
    if (event.type === "response.output_item.added" && event.item?.type === "function_call") {
      const key = keyOf(event, event.item);
      if (!key) continue;
      calls.set(key, { ...(calls.get(key) || {}), ...event.item, done: false });
    } else if (event.type === "response.function_call_arguments.delta") {
      const key = keyOf(event, event.item);
      const call = key && calls.get(key);
      if (call && typeof event.delta === "string") call.arguments = `${typeof call.arguments === "string" ? call.arguments : ""}${event.delta}`;
    } else if (event.type === "response.function_call_arguments.done") {
      const key = keyOf(event, event.item);
      const call = key && calls.get(key);
      if (call && typeof event.arguments === "string") call.arguments = event.arguments;
    } else if (event.type === "response.output_item.done" && event.item?.type === "function_call") {
      const key = keyOf(event, event.item);
      if (!key) continue;
      const previous = calls.get(key) || {};
      const call = { ...previous, ...event.item, done: true };
      // 部分网关在 output_item.done 省略最终 arguments，保留此前增量累加值。
      if ((!call.arguments || typeof call.arguments !== "string") && previous.arguments) call.arguments = previous.arguments;
      calls.set(key, call);
    }
  }
  for (const call of calls.values()) {
    if (!call.done || typeof call.call_id !== "string" || !call.call_id || typeof call.name !== "string" || !call.name || typeof call.arguments !== "string") continue;
    try {
      const argumentsValue = JSON.parse(call.arguments);
      if (!isObject(argumentsValue)) continue;
    } catch { continue; }
    const { done, ...complete } = call;
    return complete;
  }
  return undefined;
}

export async function runProbe(baseUrl, model, key, fetchImpl = globalThis.fetch) {
  const user = { role: "user", content: [{ type: "input_text", text: "Reply with exactly RESPONSES_PROBE_OK." }] };
  // 256 是有限但不过分激进的探测预算，限制冗余推理，同时给正常完成和工具调用留出空间。
  let supportsMaxOutputTokens = true;
  const makePayload = body => ({ model, stream: true, store: false, ...(supportsMaxOutputTokens ? { max_output_tokens: PROBE_MAX_OUTPUT_TOKENS } : {}), ...body });
  let result = await probeRequest(fetchImpl, baseUrl, key, makePayload({ input: [user] }));
  if (!isProbeComplete(result) && probeFailure(result) === "max-output-unsupported") {
    supportsMaxOutputTokens = false;
    result = await probeRequest(fetchImpl, baseUrl, key, makePayload({ input: [user] }));
  }
  if (!isProbeComplete(result)) {
    const failure = probeFailure(result);
    if (failure === "endpoint-unsupported" || failure === "model-unsupported") return { status: failure };
    if (!successful(result)) return { status: failure === "unknown" && result.status === 0 ? "server-unknown" : failure };
    return { status: failure === "unknown" ? "malformed" : failure };
  }
  const developerResult = await probeRequest(fetchImpl, baseUrl, key, makePayload({ input: [{ role: "developer", content: "Protocol probe." }, user] }));
  let supportsDeveloperRole = true;
  if (!isProbeComplete(developerResult)) {
    if (probeFailure(developerResult) !== "developer-unsupported") return { status: "developer-unknown" };
    supportsDeveloperRole = false;
    const systemResult = await probeRequest(fetchImpl, baseUrl, key, makePayload({ input: [{ role: "system", content: "Protocol probe." }, user] }));
    if (!isProbeComplete(systemResult)) return { status: "developer-unknown" };
  }
  const instruction = supportsDeveloperRole ? { role: "developer", content: "Protocol probe. Use the tool exactly once." } : { role: "system", content: "Protocol probe. Use the tool exactly once." };
  const toolUser = { role: "user", content: [{ type: "input_text", text: "Call responses_probe_tool with value probe." }] };
  const tool = { type: "function", name: "responses_probe_tool", description: "A no-side-effect protocol probe.", parameters: { type: "object", properties: { value: { type: "string" } }, required: ["value"], additionalProperties: false } };
  const toolResult = await probeRequest(fetchImpl, baseUrl, key, makePayload({ input: [instruction, toolUser], tools: [tool], tool_choice: "required" }));
  let tools = "unknown";
  if (isProbeComplete(toolResult)) {
    const call = functionCall(toolResult);
    if (call) {
      const followup = makePayload({ input: [instruction, toolUser, { type: "function_call", ...(call.id ? { id: call.id } : {}), call_id: call.call_id, name: call.name, arguments: call.arguments }, { type: "function_call_output", call_id: call.call_id, output: JSON.stringify({ value: "probe-ok" }) }] });
      const followupResult = await probeRequest(fetchImpl, baseUrl, key, followup);
      tools = isProbeComplete(followupResult) ? "supported" : "insufficient";
    } else tools = "insufficient";
  } else if (probeFailure(toolResult) === "tools-unsupported") tools = "insufficient";
  const compat = { supportsMaxOutputTokens };
  if (!supportsDeveloperRole) compat.supportsDeveloperRole = false;
  return { status: "supported", tools, compat };
}

function writeConfigs(configDir, entries, log) {
  const changed = entries.filter(e => e.text !== e.content);
  if (!changed.length) { log("○ 配置内容无变化"); return; }
  fs.mkdirSync(configDir, { recursive: true, mode: 0o700 });
  const pending = [], applied = [];
  try {
    // 先写全部候选，再逐文件替换。
    for (const entry of changed) {
      const temp = path.join(configDir, `.${entry.name}.${randomUUID()}.tmp`);
      pending.push({ ...entry, temp });
      fs.writeFileSync(temp, entry.content, { flag: "wx", mode: 0o600 });
    }
    for (const entry of pending) {
      fs.renameSync(entry.temp, path.join(configDir, entry.name));
      applied.push(entry.name);
      log(`  - ${entry.name}: 已更新`);
    }
  } catch (error) {
    const remaining = changed.map(e => e.name).filter(name => !applied.includes(name));
    console.error(`✘ 写入未完成；已替换: ${applied.join(", ") || "无"}；未替换: ${remaining.join(", ")}`);
    throw error;
  } finally {
    for (const entry of pending) {
      try { fs.unlinkSync(entry.temp); }
      catch (error) { if (error.code !== "ENOENT") console.error(`✘ 无法清理候选文件 ${entry.temp}: ${error.message}`); }
    }
  }
}

function reportSettingsPolicy(log) {
  log("○ settings.json 个人偏好覆盖（脚本重复运行会重新应用；不采用此偏好可按下列原生值手动改回）:");
  log("  - defaultThinkingLevel: high ← 原生 medium；更偏向充分推理，增加耗时与用量");
  log("  - quietStartup: true ← 原生 false；隐藏启动头部和资源加载信息");
  log("  - enableInstallTelemetry: false ← 原生 true；关闭安装／更新遥测及 Provider 归因");
  log("  - cacheWarming: off ← 原生 idle；关闭提示缓存预热，可能减少缓存命中");
  log("  - compaction.enabled: false ← 原生 true；关闭自动压缩，长会话可能更早触及上下文限制");
  log("  - terminal.showImages: false ← 原生 true；关闭终端内联图片");
  log("  - markdown.mermaid: off ← 原生 streaming；关闭 Mermaid 图表渲染");
  log("  - Windows shellPath: 缺失时写入已验证的 Bash 路径；已有值不替换（运行必需项，非 Pi 偏好）");
}

export function createPrompter(input = process.stdin, output = process.stdout) {
  let muted = false;
  const proxy = new Writable({ write(chunk, encoding, callback) { if (!muted) output.write(chunk, encoding); callback(); } });
  const rl = createInterface({ input, output: proxy, terminal: Boolean(input.isTTY) });
  const lines = [], waiters = [];
  let closed = false;
  rl.on("line", line => (waiters.length ? waiters.shift().resolve(line) : lines.push(line)));
  rl.on("close", () => {
    closed = true;
    while (waiters.length) waiters.shift().reject(new Error("输入已取消或终端不可用"));
  });
  const nextLine = () => {
    if (lines.length) return Promise.resolve(lines.shift());
    if (closed) return Promise.reject(new Error("输入已取消或终端不可用"));
    return new Promise((resolve, reject) => waiters.push({ resolve, reject }));
  };
  return {
    async ask(prompt) {
      rl.setPrompt(prompt);
      rl.prompt();
      return nextLine();
    },
    async askSecret(prompt) {
      output.write(prompt);
      muted = true;
      rl.setPrompt("");
      rl.prompt();
      try { return await nextLine(); }
      finally { muted = false; output.write("\n"); }
    },
    close() { rl.close(); }
  };
}

function normalizeUrl(raw) {
  const trimmed = raw.trim();
  check(trimmed && isSingleLine(trimmed), "Base URL 必须为非空单行");
  const candidate = (/^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`).replace(/\/+$/, "");
  try { return new URL(candidate).href.replace(/\/+$/, ""); }
  catch { throw new Error("Base URL 格式无效"); }
}

async function fetchJson(fetchImpl, url, init, timeoutMs, label) {
  let response;
  try {
    response = await fetchImpl(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
  } catch (error) {
    throw new Error(`${label}请求失败（${error.name === "TimeoutError" || error.name === "AbortError" ? "超时" : error.message}），未修改 models.json、auth.json、settings.json`);
  }
  if (!response.ok) throw new Error(`${label}请求返回 HTTP ${response.status}，未修改 models.json、auth.json、settings.json`);
  try { return await response.json(); }
  catch { throw new Error(`${label}响应不是有效 JSON，未修改 models.json、auth.json、settings.json`); }
}

async function resolveGptDecisions(gptIds, baseUrl, key, { prompter, fetchImpl, log, errorLog }) {
  const decisions = {};
  let batchMode = null;
  for (let i = 0; i < gptIds.length; i++) {
    const modelId = gptIds[i];
    let choice = batchMode;
    while (choice === null) {
      const remaining = gptIds.length - i;
      const hint = remaining > 1
        ? `[回车]探测，[n]不支持，[y]支持，[a]余下全探测，[na]余下全n，[ya]余下全y`
        : `[回车]探测，[n]不支持，[y]支持`;
      const raw = (await prompter.ask(`模型 ${modelId} 的 Responses API：${hint}: `)).trim().toLowerCase();
      if (raw === "" || raw === "n" || raw === "y") { choice = raw; break; }
      if (raw === "a") { choice = batchMode = ""; break; }
      if (raw === "na") { choice = batchMode = "n"; break; }
      if (raw === "ya") { choice = batchMode = "y"; break; }
      errorLog("✘ 请输入回车、n、y、a、na 或 ya");
    }
    if (choice === "n") {
      decisions[modelId] = { api: "openai-completions" };
      log(`○ ${modelId}: Chat Completions（用户确认）`);
    } else if (choice === "y") {
      decisions[modelId] = { api: "openai-responses" };
      log(`○ ${modelId}: Responses API（用户确认）`);
    } else {
      log(`▶ 正在探测 ${modelId} 的 Responses API（探测请求临时限制 max_output_tokens=${PROBE_MAX_OUTPUT_TOKENS}；该额度包含推理与可见输出）...`);
      const result = await runProbe(baseUrl, modelId, key, fetchImpl).catch(err => ({ status: "server-unknown", error: err.message }));
      if (result.status === "endpoint-unsupported" || result.status === "model-unsupported") {
        decisions[modelId] = { api: "openai-completions" };
        log(`○ ${modelId}: Responses API 明确不支持，使用 Chat Completions`);
      } else if (result.status === "supported") {
        decisions[modelId] = { api: "openai-responses", compat: result.compat || {} };
        log(`✔ ${modelId}: Responses API 可用${result.tools === "supported" ? "，工具调用通过" : "，工具调用能力不足或未知"}`);
      } else {
        throw new Error(`${modelId} 的 Responses API 能力未知（${result.status}），未修改配置`);
      }
    }
  }
  return decisions;
}

export async function runFlow({
  configDir,
  bashPath,
  fetchImpl = globalThis.fetch,
  prompter = createPrompter(),
  log = console.log,
  errorLog = console.error,
  modelsDevUrl = MODELS_DEV_URL
}) {
  let applying = false;
  try {
    const cfg = loadConfigs(configDir);
    prepareSettings(cfg.settings.value, bashPath);

    const defaultProvider = cfg.settings.value.defaultProvider || "openai";
    const providerId = (await prompter.ask(`Provider ID [当前: ${defaultProvider}]: `)).trim() || defaultProvider;
    check(providerId && isSingleLine(providerId), "Provider ID 无效");

    const oldProvider = Object.hasOwn(cfg.models.value.providers, providerId) ? cfg.models.value.providers[providerId] : {};
    const oldCredential = Object.hasOwn(cfg.auth.value, providerId) ? cfg.auth.value[providerId] : undefined;
    let oldKey = "";
    if (oldCredential) {
      if (oldCredential.type === "api_key" && typeof oldCredential.key === "string" && !oldCredential.key.startsWith("!")) oldKey = oldCredential.key;
      else throw new Error("此生成器仅复用字面量 API Key；请先在 auth.json 中移除或替换该凭据");
    }
    check(isSingleLine(oldProvider.baseUrl || "") && isSingleLine(oldKey), "URL 和 API Key 必须为单行");

    const rawUrl = await prompter.ask(`Base URL [当前: ${oldProvider.baseUrl || "未配置"}]: `);
    const targetUrl = normalizeUrl(rawUrl || oldProvider.baseUrl || "");

    const rawKey = await prompter.askSecret(`API Key [当前: ${oldKey ? "已配置" : "未配置"}，回车保留]: `);
    const targetKey = rawKey || oldKey;
    check(isSingleLine(targetKey) && !targetKey.startsWith("!"), "需要单行字面量 API Key");

    log(`▶ 正在探测端点模型 (${providerId})...`);
    const remote = await fetchJson(
      fetchImpl,
      `${targetUrl}/models`,
      { headers: targetKey ? { authorization: `Bearer ${targetKey}` } : {} },
      6000,
      "模型列表"
    );
    const ids = discoverModels(remote);
    const decisions = await resolveGptDecisions(ids.filter(id => id.startsWith("gpt-")), targetUrl, targetKey, { prompter, fetchImpl, log, errorLog });

    log("▶ 正在获取 models.dev 参数库...");
    const db = await fetchJson(fetchImpl, modelsDevUrl, {}, 12000, "models.dev 参数库");

    const { models, unmatched } = makeModels(ids, db, decisions);
    cfg.models.value.$schema = "https://pi.dev/schemas/models.schema.json";
    cfg.models.value.providers = { ...cfg.models.value.providers, [providerId]: { baseUrl: targetUrl, api: "openai-completions", models } };
    if (targetKey) cfg.auth.value = { ...cfg.auth.value, [providerId]: { type: "api_key", key: targetKey } };

    const entries = [["models.json", cfg.models], ...(targetKey ? [["auth.json", cfg.auth]] : []), ["settings.json", cfg.settings]]
      .map(([name, file]) => ({ name, text: file.text, content: JSON.stringify(file.value, null, 2) + "\n" }));
    applying = true;
    writeConfigs(configDir, entries, log);
    reportSettingsPolicy(log);
    log(`✔ 配置生成完成: ${models.length} 个模型；非 gpt- 使用 openai-completions，已确认的 gpt- 模型优先使用 openai-responses`);
    if (unmatched) log(`○ ${unmatched} 个模型未匹配 models.dev，未填规格，由 Pi 使用默认值`);
    log("○ models.dev 为目录参考规格与价格，不代表网关实际限制或账单；默认模型由 Pi 管理");
  } catch (error) {
    errorLog(`✘ ${error.message}`);
    if (!applying) errorLog("未修改 models.json、auth.json、settings.json");
    throw error;
  } finally {
    prompter.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [configDir, bashPath] = process.argv.slice(2);
  runFlow({ configDir, bashPath }).catch(() => { process.exitCode = 1; });
}
NODE

node "$WORK_DIR/pi.mjs" "$CONFIG_DIR" "$BASH_PATH" < /dev/tty
