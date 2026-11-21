#!/usr/bin/env bash
# Pi OpenAI-compatible 配置生成器；协议来自逐模型策略与 Responses API 探测，规格来自 models.dev。
set -Eeuo pipefail

CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
show_help() {
    cat <<'EOF'
用法: bash tools/pi/pi.sh [-h|--help]
通过终端交互输入 Provider ID、Base URL 和 API Key，回车保留已有值。
  -h, --help  显示帮助

有效列表按 models.dev 规格重建目标 Provider；gpt- 前缀模型逐个询问 Responses API 策略，发现失败、能力未知或无候选模型时不更新配置。
非 gpt- 模型使用 openai-completions；确认或探测支持的 gpt- 模型优先使用 openai-responses。默认模型在 Pi /model 中选择，按 Ctrl+S 保存。
Windows pwsh: sh.exe -c "bash tools/pi/pi.sh"
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        *) printf '❌ 未知参数: %s\n' "$1" >&2; exit 1 ;;
    esac
done

# 阶段一：依赖就绪
IS_WINDOWS=0
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* || -n "${WINDIR:-}" ]]; then
    IS_WINDOWS=1
    command -v scoop >/dev/null 2>&1 || { printf '❌ 请先就绪 Scoop\n' >&2; exit 1; }
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
    if command -v paru >/dev/null 2>&1; then
        paru -S --needed --noconfirm --skipreview pi-coding-agent-bin ripgrep fd
    fi
fi
for tool in node curl pi rg fd; do
    command -v "$tool" >/dev/null 2>&1 || { printf '❌ 缺少依赖: %s\n' "$tool" >&2; exit 1; }
done
node -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<22 || (a===22 && b<19)) { console.error("❌ 需要 Node.js 22.19 或更新版本"); process.exit(1); }'

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

# 配置读取、规格转换与写入
cat > "$WORK_DIR/config.cjs" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { randomUUID } = require("node:crypto");
const [command, configDir, providerId, ...args] = process.argv.slice(2);
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const PROBE_MAX_OUTPUT_TOKENS = 256;
const SETTINGS_SCHEMA = "https://pi.dev/schemas/settings.schema.json";
function check(condition, message) { if (!condition) throw new Error(message); }
function readConfig(name, fallback) {
  const file = path.join(configDir, name);
  let text;
  try { text = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""); }
  catch (error) { if (error.code === "ENOENT") return { value: fallback, text: null }; throw error; }
  let value;
  try {
    // models.json：移除行注释和尾逗号，保留字符串。
    const json = name === "models.json" ? text
      .replace(/"(?:\\.|[^"\\])*"|\/\/[^\n]*/g, m => m[0] === '"' ? m : "")
      .replace(/"(?:\\.|[^"\\])*"|,(\s*[}\]])/g, (m, tail) => tail ?? (m[0] === '"' ? m : "")) : text;
    value = JSON.parse(json);
  } catch { throw new Error(`${name} JSON 无法解析`); }
  check(object(value), `${name} 顶层必须为对象`);
  return { value, text };
}
function loadConfigs() {
  const models = readConfig("models.json", { providers: {} });
  const auth = readConfig("auth.json", {});
  const settings = readConfig("settings.json", {});
  check(object(models.value.providers), "models.json providers 必须为对象");
  for (const provider of Object.values(models.value.providers)) {
    check(object(provider), "models.json Provider 必须为对象");
    check(provider.baseUrl === undefined || typeof provider.baseUrl === "string", "Provider baseUrl 必须为字符串");
    check(provider.models === undefined || (Array.isArray(provider.models) && provider.models.every(m => object(m) && typeof m.id === "string" && m.id.trim())), "Provider models 必须包含有效模型 ID");
  }
  for (const credential of Object.values(auth.value)) {
    check(object(credential), "auth.json 凭据项必须为对象");
    check(credential.env === undefined || (object(credential.env) && Object.values(credential.env).every(v => typeof v === "string")), "auth.json env 必须为字符串映射");
    check((credential.type === "api_key" && (credential.key === undefined || typeof credential.key === "string")) ||
      (credential.type === "oauth" && typeof credential.access === "string" && typeof credential.refresh === "string" && Number.isFinite(credential.expires)), "auth.json 凭据结构无效");
  }
  validateSettings(settings.value);
  return { models, auth, settings };
}
function validateSettings(settings) {
  const strings = [
    "defaultProvider", "defaultModel", "theme", "shellPath", "shellCommandPrefix", "externalEditor",
    "sessionDir", "httpProxy", "markdown.codeBlockIndent"
  ];
  for (const key of strings) {
    const value = key.includes(".") ? settings[key.split(".")[0]]?.[key.split(".")[1]] : settings[key];
    check(value === undefined || typeof value === "string", `settings.json ${key} 必须为字符串`);
  }
  const enums = {
    defaultThinkingLevel: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
    tuiMode: ["regular", "fullscreen"],
    sessionShareDestination: ["auto", "gist", "radius"],
    cacheWarming: ["off", "streaming", "idle"],
    steeringMode: ["all", "one-at-a-time"],
    followUpMode: ["all", "one-at-a-time"],
    doubleEscapeAction: ["tree", "fork", "none"],
    treeFilterMode: ["default", "no-tools", "user-only", "labeled-only", "all"],
    defaultProjectTrust: ["ask", "always", "never"],
    transport: ["auto", "sse", "websocket", "websocket-cached"]
  };
  for (const [key, values] of Object.entries(enums)) {
    check(settings[key] === undefined || values.includes(settings[key]), `settings.json ${key} 值无效`);
  }
  const booleans = [
    "hideThinkingBlock", "showCacheMissNotices", "enableInstallTelemetry", "enableAnalytics",
    "collapseChangelog", "enableSkillCommands", "fullscreenCopyOnSelect", "showHardwareCursor"
  ];
  for (const key of booleans) check(settings[key] === undefined || typeof settings[key] === "boolean", `settings.json ${key} 必须为布尔值`);
  check(settings.quietStartup === undefined || typeof settings.quietStartup === "boolean" || settings.quietStartup === "header", "settings.json quietStartup 值无效");
  for (const key of ["compaction", "branchSummary", "terminal", "markdown", "images", "retry", "codemode", "warnings"]) {
    check(settings[key] === undefined || object(settings[key]), `settings.json ${key} 必须为对象`);
  }
  for (const key of ["defaultTools", "packages", "extensions", "skills", "prompts", "themes", "npmCommand", "selfUpdateCommand"]) {
    check(settings[key] === undefined || (Array.isArray(settings[key]) && settings[key].every(value => typeof value === "string")), `settings.json ${key} 必须为字符串数组`);
  }
  const nonNegativeInteger = (value, key) => check(value === undefined || (Number.isSafeInteger(value) && value >= 0), `settings.json ${key} 必须为非负安全整数`);
  if (settings.compaction) {
    check(settings.compaction.enabled === undefined || typeof settings.compaction.enabled === "boolean", "settings.json compaction.enabled 必须为布尔值");
    nonNegativeInteger(settings.compaction.reserveTokens, "compaction.reserveTokens");
    nonNegativeInteger(settings.compaction.keepRecentTokens, "compaction.keepRecentTokens");
    check(settings.compaction.modelOverrides === undefined || object(settings.compaction.modelOverrides), "settings.json compaction.modelOverrides 必须为对象");
  }
  if (settings.branchSummary) {
    nonNegativeInteger(settings.branchSummary.reserveTokens, "branchSummary.reserveTokens");
    check(settings.branchSummary.skipPrompt === undefined || typeof settings.branchSummary.skipPrompt === "boolean", "settings.json branchSummary.skipPrompt 必须为布尔值");
  }
  if (settings.terminal) {
    check(settings.terminal.showImages === undefined || typeof settings.terminal.showImages === "boolean", "settings.json terminal.showImages 必须为布尔值");
    check(settings.terminal.clearOnShrink === undefined || typeof settings.terminal.clearOnShrink === "boolean", "settings.json terminal.clearOnShrink 必须为布尔值");
    check(settings.terminal.showTerminalProgress === undefined || typeof settings.terminal.showTerminalProgress === "boolean", "settings.json terminal.showTerminalProgress 必须为布尔值");
    check(settings.terminal.hyperlinks === undefined || typeof settings.terminal.hyperlinks === "boolean" || settings.terminal.hyperlinks === "auto", "settings.json terminal.hyperlinks 值无效");
    check(settings.terminal.images === undefined || settings.terminal.images === false || ["kitty", "iterm2", "auto"].includes(settings.terminal.images), "settings.json terminal.images 值无效");
    check(settings.terminal.trueColor === undefined || typeof settings.terminal.trueColor === "boolean" || settings.terminal.trueColor === "auto", "settings.json terminal.trueColor 值无效");
  }
  if (settings.markdown) check(settings.markdown.mermaid === undefined || ["off", "final", "streaming"].includes(settings.markdown.mermaid), "settings.json markdown.mermaid 值无效");
  if (settings.images) {
    check(settings.images.autoResize === undefined || typeof settings.images.autoResize === "boolean", "settings.json images.autoResize 必须为布尔值");
    check(settings.images.blockImages === undefined || typeof settings.images.blockImages === "boolean", "settings.json images.blockImages 必须为布尔值");
  }
  if (settings.retry) check(settings.retry.enabled === undefined || typeof settings.retry.enabled === "boolean", "settings.json retry.enabled 必须为布尔值");
}
function prepareSettings(settings, bashPath) {
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
function reportSettingsPolicy() {
  console.log("ℹ️ settings.json 个人偏好覆盖（脚本重复运行会重新应用；不采用此偏好可按下列原生值手动改回）:");
  console.log("  - defaultThinkingLevel: high ← 原生 medium；更偏向充分推理，增加耗时与用量");
  console.log("  - quietStartup: true ← 原生 false；隐藏启动头部和资源加载信息");
  console.log("  - enableInstallTelemetry: false ← 原生 true；关闭安装／更新遥测及 Provider 归因");
  console.log("  - cacheWarming: off ← 原生 idle；关闭提示缓存预热，可能减少缓存命中");
  console.log("  - compaction.enabled: false ← 原生 true；关闭自动压缩，长会话可能更早触及上下文限制");
  console.log("  - terminal.showImages: false ← 原生 true；关闭终端内联图片");
  console.log("  - markdown.mermaid: off ← 原生 streaming；关闭 Mermaid 图表渲染");
  console.log("  - Windows shellPath: 缺失时写入已验证的 Bash 路径；已有值不替换（运行必需项，非 Pi 偏好）");
}
function discover(file) {
  let parsed;
  try { parsed = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch { throw new Error("模型列表不是有效 JSON"); }
  const list = Array.isArray(parsed) ? parsed : parsed?.data;
  check(Array.isArray(list), "模型列表结构无效：需要 data 数组或顶层数组");
  check(list.every(m => object(m) && typeof m.id === "string" && m.id.trim() && !/[\r\n\t]/.test(m.id)), "模型列表包含无效模型 ID");
  const ids = [...new Set(list.map(m => m.id).filter(id => !/image|embed|tts|audio|whisper|batch/i.test(id)))];
  check(ids.length > 0, list.length ? "模型列表经当前名称过滤后没有候选模型" : "端点返回空模型列表");
  return ids;
}
function applyDecision(model, id, decisions) {
  if (!id.startsWith("gpt-")) return;
  const decision = decisions[id];
  if (decision.api === "openai-responses") model.api = "openai-responses";
  if (object(decision.compat) && Object.keys(decision.compat).length) model.compat = decision.compat;
}
function makeModels(ids, db, decisions = {}) {
  check(object(db) && Object.keys(db).length > 0, "models.dev 参数库必须为非空对象");
  check(object(decisions), "Responses API 决策必须为对象");
  for (const id of ids) {
    if (id.startsWith("gpt-") && (!object(decisions[id]) || !["openai-completions", "openai-responses"].includes(decisions[id].api))) {
      throw new Error(`gpt- 模型 ${id} 缺少有效 Responses API 决策`);
    }
  }
  const exact = new Map(), canonical = new Map();
  const providers = [...new Set(["anthropic", "openai", "google", "deepseek", "meta", "alibaba", "qwen", "mistral", ...Object.keys(db)])];
  for (const pid of providers) {
    if (!Object.hasOwn(db, pid)) continue;
    check(object(db[pid]) && object(db[pid].models), "models.dev Provider models 结构无效");
    for (const [id, spec] of Object.entries(db[pid].models)) {
      check(object(spec), "models.dev 模型规格必须为对象");
      for (const key of [id.toLowerCase(), `${pid}/${id}`.toLowerCase()]) {
        if (!exact.has(key)) exact.set(key, spec);
      }
      if (typeof spec.canonical_model_id === "string" && !canonical.has(spec.canonical_model_id.toLowerCase())) {
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
    if (!spec) {
      unmatched++;
      const model = { id };
      applyDecision(model, id, decisions);
      return model;
    }
    const model = { id };
    applyDecision(model, id, decisions);
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
      check(object(spec.cost), `models.dev ${id} cost 无效`);
      if (spec.cost.input !== undefined && spec.cost.output !== undefined) {
        model.cost = { input: spec.cost.input, output: spec.cost.output, cacheRead: spec.cost.cache_read ?? 0, cacheWrite: spec.cost.cache_write ?? 0 };
        check(Object.values(model.cost).every(n => typeof n === "number" && Number.isFinite(n) && n >= 0), `models.dev ${id} cost 无效`);
      }
    }
    return model;
  });
  return { models, unmatched };
}
function readJsonFile(file, message) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); }
  catch { throw new Error(message); }
}
function saveDecision(file, id, decision) {
  check(typeof id === "string" && id && !/[\r\n\t]/.test(id), "模型 ID 无效");
  const decisions = fs.existsSync(file) ? readJsonFile(file, "Responses API 决策文件无效") : {};
  check(object(decisions), "Responses API 决策必须为对象");
  decisions[id] = decision;
  fs.writeFileSync(file, JSON.stringify(decisions));
}
function checkDecisions(idsFile, decisionsFile) {
  const ids = readJsonFile(idsFile, "模型 ID 文件无效");
  const decisions = readJsonFile(decisionsFile, "Responses API 决策文件无效");
  check(Array.isArray(ids) && object(decisions), "Responses API 决策结构无效");
  for (const id of ids.filter(id => id.startsWith("gpt-"))) {
    check(object(decisions[id]) && ["openai-completions", "openai-responses"].includes(decisions[id].api), `gpt- 模型 ${id} 的 Responses API 决策未完成`);
  }
}
function classifyProbeFailure(status, body) {
  const text = String(body || "").toLowerCase();
  if (status === 401 || status === 403) return "auth-unknown";
  if (status === 429) return "quota-unknown";
  if (status >= 500) return "server-unknown";
  // A model-not-found response can also be HTTP 404. Classify the body first;
  // a bare 404 is not evidence that the Responses endpoint is unsupported.
  if (/model[_ -]?not[_ -]?(found|available)|unknown model|model[^\n]*(not found|does not exist|不存在|不可用|not supported|unsupported|invalid|unknown)/i.test(text)) return "model-unsupported";
  if (/((responses|response)[^\n]*(endpoint|route|path|url)[^\n]*(not found|not supported|unsupported|invalid))|(endpoint|route|path|url)[^\n]*(not found|not supported|unsupported|invalid)|unsupported[^\n]*(endpoint|route|path)|method[^\n]*(not allowed|unsupported)/i.test(text) || status === 405) return "endpoint-unsupported";
  if (/developer[^\n]*(role|message|not supported|unsupported|invalid|unknown)|invalid[^\n]*(developer|role)|unsupported[^\n]*developer/i.test(text)) return "developer-unsupported";
  if (/max[_ -]?output[_ -]?tokens[^\n]*(not supported|unsupported|invalid|unknown|unrecognized)|unknown (field|parameter)[^\n]*max[_ -]?output|unrecognized request argument[^\n]*max[_ -]?output/i.test(text)) return "max-output-unsupported";
  if (/tool[^\n]*(not supported|unsupported|invalid|unknown)|unsupported[^\n]*tool/i.test(text)) return "tools-unsupported";
  return "unknown";
}
function parseSse(text) {
  const events = [];
  let sawSse = false;
  for (const block of String(text).split(/\r?\n\r?\n/)) {
    const data = block.split(/\r?\n/).filter(line => line.startsWith("data:")).map(line => line.slice(5).trimStart()).join("\n");
    if (!data) continue;
    sawSse = true;
    if (data === "[DONE]") { events.push({ type: "done" }); continue; }
    try { events.push(JSON.parse(data)); }
    catch { return { events, sawSse, malformed: true }; }
  }
  return { events, sawSse, malformed: false };
}
function terminalEvent(event) {
  return ["response.completed", "response.failed", "response.incomplete", "error"].includes(event?.type);
}
async function readSseResponse(response) {
  // 保留文本响应 fallback，便于离线替身和不提供 ReadableStream 的实现工作。
  if (!response.body?.getReader) {
    const text = await response.text();
    return { text, ...parseSse(text) };
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const events = [];
  let buffer = "", text = "", sawSse = false, malformed = false, stopped = false;
  const consume = block => {
    const data = block.split(/\r?\n/).filter(line => line.startsWith("data:"))
      .map(line => line.slice(5).trimStart()).join("\n");
    if (!data) return;
    sawSse = true;
    text += `data: ${data}\n\n`;
    if (data === "[DONE]") { events.push({ type: "done" }); stopped = true; return; }
    try {
      const event = JSON.parse(data);
      events.push(event);
      if (terminalEvent(event)) stopped = true;
    } catch {
      malformed = true;
      stopped = true;
    }
  };
  try {
    while (!stopped) {
      const part = await reader.read();
      if (part.done) {
        buffer += decoder.decode();
        break;
      }
      buffer += decoder.decode(part.value, { stream: true });
      const blocks = buffer.split(/\r?\n\r?\n/);
      buffer = blocks.pop() || "";
      for (const block of blocks) {
        consume(block);
        if (stopped) break;
      }
    }
    if (!stopped && buffer) consume(buffer);
  } finally {
    if (stopped) {
      try { await reader.cancel(); } catch { /* 终止事件后取消读取不影响探测结论 */ }
    }
  }
  return { text, events, sawSse, malformed };
}
async function probeRequest(baseUrl, key, payload) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetch(`${baseUrl}/responses`, {
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
function probeText(result) {
  return [result.text, ...(result.events || []).map(event => JSON.stringify(event))].filter(Boolean).join("\n");
}
function probeFailure(result) { return classifyProbeFailure(result.status, probeText(result)); }
function successful(result) { return result.status >= 200 && result.status < 300; }
function completed(parsed) {
  return parsed.events.some(event => event.type === "response.completed") &&
    !parsed.events.some(event => event.type === "response.failed" || event.type === "response.incomplete" || event.type === "error");
}
function functionCall(parsed) {
  // Follow the official Responses SDK accumulator: added creates a partial
  // item, argument deltas are appended, done supplies the authoritative item.
  // Never treat output_item.added as executable because its arguments may be
  // empty or incomplete.
  const calls = new Map();
  const keyOf = (event, item) => Number.isSafeInteger(event.output_index)
    ? `index:${event.output_index}`
    : item?.id ? `id:${item.id}` : undefined;
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
      // Some gateways omit the final arguments on output_item.done. Preserve
      // the SDK-style accumulated value in that narrow compatibility case.
      if ((!call.arguments || typeof call.arguments !== "string") && previous.arguments) call.arguments = previous.arguments;
      calls.set(key, call);
    }
  }
  for (const call of calls.values()) {
    if (!call.done || typeof call.call_id !== "string" || !call.call_id || typeof call.name !== "string" || !call.name || typeof call.arguments !== "string") continue;
    try {
      const argumentsValue = JSON.parse(call.arguments);
      if (!object(argumentsValue)) continue;
    } catch { continue; }
    const { done, ...complete } = call;
    return complete;
  }
  return undefined;
}
async function runProbe(baseUrl, model, key) {
  const user = { role: "user", content: [{ type: "input_text", text: "Reply with exactly RESPONSES_PROBE_OK." }] };
  // 256 是有限但不过分激进的探测预算，限制冗余推理，同时给正常完成和工具调用留出空间。
  const base = { model, input: [user], stream: true, store: false, max_output_tokens: PROBE_MAX_OUTPUT_TOKENS };
  let result = await probeRequest(baseUrl, key, base);
  if (!successful(result)) {
    const failure = probeFailure(result);
    if (failure === "endpoint-unsupported" || failure === "model-unsupported") return { status: failure };
    return { status: failure === "unknown" && result.status === 0 ? "server-unknown" : failure };
  }
  if (!result.sawSse || result.malformed || !completed(result)) {
    const failure = probeFailure(result);
    if (failure === "endpoint-unsupported" || failure === "model-unsupported") return { status: failure };
    return { status: failure === "unknown" ? "malformed" : failure };
  }
  const developerInput = [{ role: "developer", content: "Protocol probe." }, user];
  const developerPayload = { model, input: developerInput, stream: true, store: false, max_output_tokens: PROBE_MAX_OUTPUT_TOKENS };
  const developerResult = await probeRequest(baseUrl, key, developerPayload);
  let supportsDeveloperRole = true;
  const developerFailure = probeFailure(developerResult);
  if (!successful(developerResult) || !developerResult.sawSse || developerResult.malformed || !completed(developerResult)) {
    if (developerFailure !== "developer-unsupported") return { status: "developer-unknown" };
    supportsDeveloperRole = false;
    const systemPayload = { model, input: [{ role: "system", content: "Protocol probe." }, user], stream: true, store: false, max_output_tokens: PROBE_MAX_OUTPUT_TOKENS };
    const systemResult = await probeRequest(baseUrl, key, systemPayload);
    if (!successful(systemResult) || !systemResult.sawSse || systemResult.malformed || !completed(systemResult)) return { status: "developer-unknown" };
  }
  const instruction = supportsDeveloperRole ? { role: "developer", content: "Protocol probe. Use the tool exactly once." } : { role: "system", content: "Protocol probe. Use the tool exactly once." };
  const tool = { type: "function", name: "responses_probe_tool", description: "A no-side-effect protocol probe.", parameters: { type: "object", properties: { value: { type: "string" } }, required: ["value"], additionalProperties: false } };
  const toolPayload = { model, input: [instruction, { role: "user", content: [{ type: "input_text", text: "Call responses_probe_tool with value probe." }] }], tools: [tool], tool_choice: "required", stream: true, store: false, max_output_tokens: PROBE_MAX_OUTPUT_TOKENS };
  const toolResult = await probeRequest(baseUrl, key, toolPayload);
  let tools = "unknown";
  if (successful(toolResult) && toolResult.sawSse && !toolResult.malformed && completed(toolResult)) {
    const call = functionCall(toolResult);
    if (call) {
      const followup = { model, input: [instruction, { role: "user", content: [{ type: "input_text", text: "Call responses_probe_tool with value probe." }] }, { type: "function_call", ...(call.id ? { id: call.id } : {}), call_id: call.call_id, name: call.name, arguments: call.arguments }, { type: "function_call_output", call_id: call.call_id, output: JSON.stringify({ value: "probe-ok" }) }], stream: true, store: false, max_output_tokens: PROBE_MAX_OUTPUT_TOKENS };
      const followupResult = await probeRequest(baseUrl, key, followup);
      tools = successful(followupResult) && followupResult.sawSse && !followupResult.malformed && completed(followupResult) ? "supported" : "insufficient";
    } else tools = "insufficient";
  } else if (probeFailure(toolResult) === "tools-unsupported") tools = "insufficient";
  else tools = "unknown";
  const compat = { supportsMaxOutputTokens: true };
  if (!supportsDeveloperRole) compat.supportsDeveloperRole = false;
  return { status: "supported", tools, compat };
}
function writeConfigs(entries) {
  const changed = entries.filter(e => e.text !== e.content);
  if (!changed.length) { console.log("ℹ️ 配置内容无变化"); return; }
  fs.mkdirSync(configDir, { recursive: true, mode: 0o700 });
  const pending = [], completed = [];
  try {
    // 先写全部候选，再逐文件替换。
    for (const entry of changed) {
      const temp = path.join(configDir, `.${entry.name}.${randomUUID()}.tmp`);
      pending.push({ ...entry, temp });
      fs.writeFileSync(temp, entry.content, { flag: "wx", mode: 0o600 });
    }
    for (const entry of pending) {
      fs.renameSync(entry.temp, path.join(configDir, entry.name));
      completed.push(entry.name);
      console.log(`  - ${entry.name}: 已更新`);
    }
  } catch (error) {
    const remaining = changed.map(e => e.name).filter(name => !completed.includes(name));
    console.error(`❌ 写入未完成；已替换: ${completed.join(", ") || "无"}；未替换: ${remaining.join(", ")}`);
    throw error;
  } finally {
    for (const entry of pending) {
      try { fs.unlinkSync(entry.temp); }
      catch (error) { if (error.code !== "ENOENT") console.error(`❌ 无法清理候选文件 ${entry.temp}: ${error.message}`); }
    }
  }
}
try {
  if (command === "discover") {
    fs.writeFileSync(args[0], JSON.stringify(discover(providerId)));
  } else if (command === "list-gpt") {
    const ids = readJsonFile(providerId, "模型 ID 文件无效");
    check(Array.isArray(ids), "模型 ID 文件必须为数组");
    process.stdout.write(ids.filter(id => id.startsWith("gpt-")).join("\n"));
  } else if (command === "decision") {
    saveDecision(configDir, providerId, { api: args[0], source: "user" });
    console.log(`ℹ️ ${providerId}: ${args[0] === "openai-responses" ? "Responses API" : "Chat Completions"}（用户确认）`);
  } else if (command === "probe") {
    const key = fs.readFileSync(0, "utf8");
    check(!/[\r\n]/.test(key) && !key.startsWith("!"), "需要单行字面量 API Key");
    runProbe(providerId, args[0], key).then(result => {
      process.stdout.write(JSON.stringify(result));
    }).catch(error => {
      process.stdout.write(JSON.stringify({ status: "server-unknown", error: error.message }));
    });
  } else if (command === "record-probe") {
    const result = readJsonFile(0, "Responses API 探测结果无效");
    check(object(result) && typeof result.status === "string", "Responses API 探测结果无效");
    if (result.status === "endpoint-unsupported" || result.status === "model-unsupported") {
      saveDecision(configDir, providerId, { api: "openai-completions", source: "probe", result });
      console.log(`ℹ️ ${providerId}: Responses API 明确不支持，使用 Chat Completions`);
    } else if (result.status === "supported") {
      saveDecision(configDir, providerId, { api: "openai-responses", source: "probe", compat: result.compat || {} });
      console.log(`✅ ${providerId}: Responses API 可用${result.tools === "supported" ? "，工具调用通过" : "，工具调用能力不足或未知"}`);
    } else {
      throw new Error(`${providerId} 的 Responses API 能力未知（${result.status}），未修改配置`);
    }
  } else if (command === "check-decisions") {
    checkDecisions(providerId, args[0]);
  } else {
    const cfg = loadConfigs();
    if (command === "inspect") {
      prepareSettings(cfg.settings.value, providerId);
      console.log(cfg.settings.value.defaultProvider || "openai");
    } else if (command === "connection") {
      check(providerId.trim() && !/[\r\n]/.test(providerId), "Provider ID 无效");
      const provider = Object.hasOwn(cfg.models.value.providers, providerId) ? cfg.models.value.providers[providerId] : {};
      const credential = Object.hasOwn(cfg.auth.value, providerId) ? cfg.auth.value[providerId] : undefined;
      let key = "";
      if (credential) {
        if (credential.type === "api_key" && typeof credential.key === "string" && !credential.key.startsWith("!")) key = credential.key;
        else throw new Error("此生成器仅复用字面量 API Key；请先在 auth.json 中移除或替换该凭据");
      }
      check(!/[\r\n]/.test(provider.baseUrl || "") && !/[\r\n]/.test(key), "URL 和 API Key 必须为单行");
      process.stdout.write(`${provider.baseUrl || ""}\n${key}`);
    } else if (command === "apply") {
      const [baseUrl, idsPath, dbPath, bashPath, decisionsPath] = args;
      const key = fs.readFileSync(0, "utf8");
      check(!/[\r\n]/.test(key) && !key.startsWith("!"), "需要单行字面量 API Key");
      prepareSettings(cfg.settings.value, bashPath);
      const { models, unmatched } = makeModels(JSON.parse(fs.readFileSync(idsPath, "utf8")), JSON.parse(fs.readFileSync(dbPath, "utf8")), readJsonFile(decisionsPath, "Responses API 决策文件无效"));
      cfg.models.value.$schema = "https://pi.dev/schemas/models.schema.json";
      cfg.models.value.providers = { ...cfg.models.value.providers, [providerId]: { baseUrl, api: "openai-completions", models } };
      if (key) cfg.auth.value = { ...cfg.auth.value, [providerId]: { type: "api_key", key } };
      const entries = [["models.json", cfg.models], ...(key ? [["auth.json", cfg.auth]] : []), ["settings.json", cfg.settings]]
        .map(([name, file]) => ({ name, text: file.text, content: JSON.stringify(file.value, null, 2) + "\n" }));
      writeConfigs(entries);
      reportSettingsPolicy();
      console.log(`✅ 配置生成完成: ${models.length} 个模型；非 gpt- 使用 openai-completions，已确认的 gpt- 模型优先使用 openai-responses`);
      if (unmatched) console.log(`ℹ️ ${unmatched} 个模型未匹配 models.dev，未填规格，由 Pi 使用默认值`);
      console.log("ℹ️ models.dev 为目录参考规格与价格，不代表网关实际限制或账单；默认模型由 Pi 管理");
    } else {
      throw new Error("未知配置操作");
    }
  }
} catch (error) {
  console.error(`❌ ${error.message}`);
  if (command !== "apply") console.error("未修改 models.json、auth.json、settings.json");
  process.exitCode = 1;
}
NODE

# 阶段二：选定 Provider 并读取连接配置
DEFAULT_PROVIDER=$(node "$WORK_DIR/config.cjs" inspect "$CONFIG_DIR" "$BASH_PATH")
read -rp "Provider ID [当前: $DEFAULT_PROVIDER]: " TARGET_PROVIDER_ID < /dev/tty || { printf '❌ 无法读取 Provider ID，输入已取消或终端不可用\n' >&2; exit 1; }
TARGET_PROVIDER_ID="${TARGET_PROVIDER_ID:-$DEFAULT_PROVIDER}"
OLD_CONNECTION=$(node "$WORK_DIR/config.cjs" connection "$CONFIG_DIR" "$TARGET_PROVIDER_ID")
OLD_URL="${OLD_CONNECTION%%$'\n'*}"
OLD_KEY="${OLD_CONNECTION#*$'\n'}"
read -rp "Base URL [当前: ${OLD_URL:-未配置}]: " TARGET_URL < /dev/tty || { printf '❌ 无法读取 Base URL，输入已取消或终端不可用\n' >&2; exit 1; }
TARGET_URL="${TARGET_URL:-$OLD_URL}"
[[ -n "$TARGET_URL" && "$TARGET_URL" != *$'\n'* && "$TARGET_URL" != *$'\r'* ]] || { printf '❌ Base URL 必须为非空单行\n' >&2; exit 1; }
[[ "$TARGET_URL" =~ ^https?:// ]] || TARGET_URL="https://$TARGET_URL"
TARGET_URL="${TARGET_URL%/}"
read -rsp "API Key [当前: $([ -n "$OLD_KEY" ] && printf 已配置 || printf 未配置)，回车保留]: " TARGET_KEY < /dev/tty || { printf '\n❌ 无法读取 API Key，输入已取消或终端不可用\n' >&2; exit 1; }
printf '\n'
TARGET_KEY="${TARGET_KEY:-$OLD_KEY}"
[[ "$TARGET_KEY" != *$'\n'* && "$TARGET_KEY" != *$'\r'* && "$TARGET_KEY" != '!'* ]] || { printf '❌ 需要单行字面量 API Key\n' >&2; exit 1; }
unset OLD_KEY OLD_CONNECTION

# 阶段三：模型发现；凭据走 stdin，列表走文件
printf '🔍 正在探测端点模型 (%s)...\n' "$TARGET_PROVIDER_ID"
emit_auth_header() {
    if [ -n "$TARGET_KEY" ]; then printf 'Authorization: Bearer %s\n' "$TARGET_KEY"; fi
}
if HTTP_CODE=$(emit_auth_header | curl -sS -m 6 --header @- -o "$WORK_DIR/remote.json" -w '%{http_code}' "${TARGET_URL}/models"); then
    if [ "$HTTP_CODE" != "200" ]; then
        printf '❌ 模型列表请求返回 HTTP %s，未修改 models.json、auth.json、settings.json\n' "$HTTP_CODE" >&2
        exit 1
    fi
else
    CURL_STATUS=$?
    printf '❌ 模型列表请求失败 (curl 退出码 %s)，未修改 models.json、auth.json、settings.json\n' "$CURL_STATUS" >&2
    exit 1
fi
node "$WORK_DIR/config.cjs" discover "$CONFIG_DIR" "$WORK_DIR/remote.json" "$WORK_DIR/ids.json"
GPT_IDS=$(node "$WORK_DIR/config.cjs" list-gpt "$CONFIG_DIR" "$WORK_DIR/ids.json")
printf '{}' > "$WORK_DIR/decisions.json"
while IFS= read -r MODEL_ID; do
    [[ -n "$MODEL_ID" ]] || continue
    while true; do
        read -rp "模型 $MODEL_ID 的 Responses API：[回车]探测，[n]不支持，[y]支持: " RESPONSES_CHOICE < /dev/tty || { printf '❌ 输入已取消，未修改配置\n' >&2; exit 1; }
        case "$RESPONSES_CHOICE" in
            "")
                printf '🔍 正在探测 %s 的 Responses API（探测请求临时限制 max_output_tokens=256；该额度包含推理与可见输出）...\n' "$MODEL_ID"
                PROBE_RESULT=$(printf '%s' "$TARGET_KEY" | node "$WORK_DIR/config.cjs" probe "$CONFIG_DIR" "$TARGET_URL" "$MODEL_ID")
                printf '%s' "$PROBE_RESULT" | node "$WORK_DIR/config.cjs" record-probe "$WORK_DIR/decisions.json" "$MODEL_ID"
                break ;;
            n|N)
                node "$WORK_DIR/config.cjs" decision "$WORK_DIR/decisions.json" "$MODEL_ID" openai-completions
                break ;;
            y|Y)
                node "$WORK_DIR/config.cjs" decision "$WORK_DIR/decisions.json" "$MODEL_ID" openai-responses
                break ;;
            *) printf '❌ 请输入回车、n 或 y\n' >&2 ;;
        esac
    done
done <<< "$GPT_IDS"
node "$WORK_DIR/config.cjs" check-decisions "$WORK_DIR" "$WORK_DIR/ids.json" "$WORK_DIR/decisions.json"
printf '🌐 正在获取 models.dev 参数库...\n'
curl -fsS --compressed -m 12 -o "$WORK_DIR/models-dev.json" https://models.dev/api.json

# 阶段四：预检与配置更新
printf '%s' "$TARGET_KEY" | node "$WORK_DIR/config.cjs" apply "$CONFIG_DIR" "$TARGET_PROVIDER_ID" "$TARGET_URL" "$WORK_DIR/ids.json" "$WORK_DIR/models-dev.json" "$BASH_PATH" "$WORK_DIR/decisions.json"
