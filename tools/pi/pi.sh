#!/usr/bin/env bash
# Pi 固定 openai-completions 配置生成器；模型 ID 来自端点，规格来自 models.dev。
set -Eeuo pipefail

CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
CLI_PROVIDER=""
CLI_URL=""
CLI_KEY=""
NON_INTERACTIVE=0

show_help() {
    cat <<'EOF'
用法: bash tools/pi/pi.sh [选项]
  -p, --provider <id>    Provider ID (复用已有默认，否则 cpa)
  -u, --url <url>        OpenAI Chat Completions 兼容端点 Base URL
  -k, --key <key>        API Key；优先使用静默提示或已有 auth.json，避免命令行历史记录
  -y, --non-interactive  复用已有连接配置，不提示输入
  -h, --help             显示帮助

有效列表按 models.dev 规格重建目标 Provider；发现失败或无候选模型时不更新配置。
协议固定 openai-completions；默认模型在 Pi /model 中选择，按 Ctrl+S 保存。
Windows pwsh: sh.exe -c "bash tools/pi/pi.sh"
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--provider|-u|--url|-k|--key)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { printf '❌ 参数 %s 缺少有效值\n' "$1" >&2; exit 1; }
            case "$1" in
                -p|--provider) CLI_PROVIDER="$2" ;;
                -u|--url) CLI_URL="$2" ;;
                -k|--key) CLI_KEY="$2" ;;
            esac
            shift 2 ;;
        -y|--yes|--non-interactive) NON_INTERACTIVE=1; shift ;;
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
function check(condition, message) { if (!condition) throw new Error(message); }
function readConfig(name, fallback) {
  const file = path.join(configDir, name);
  let text;
  try { text = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""); }
  catch (error) { if (error.code === "ENOENT") return { value: fallback, text: null }; throw error; }
  let value;
  try {
    // Pi 1.4.0 models.json：移除行注释和尾逗号，保留字符串。
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
  for (const key of ["compaction", "terminal", "markdown"]) {
    check(settings.value[key] === undefined || object(settings.value[key]), `settings.json ${key} 必须为对象`);
  }
  for (const key of ["defaultProvider", "defaultModel", "shellPath", "defaultThinkingLevel", "theme", "tuiMode"]) {
    check(settings.value[key] === undefined || typeof settings.value[key] === "string", `settings.json ${key} 必须为字符串`);
  }
  return { models, auth, settings };
}
function prepareSettings(settings, bashPath) {
  const shell = settings.shellPath;
  const detected = process.platform === "win32"
    ? bashPath.replace(/([/\\]apps[/\\]git[/\\])[^/\\]+(?=[/\\])/i, "$1current")
    : bashPath;
  const candidate = shell ? shell.replace(/^~(?=[/\\]|$)/, os.homedir()) : detected;
  check(typeof candidate === "string" && fs.statSync(candidate).isFile(), "Shell 路径必须指向现有文件");
  fs.accessSync(candidate, process.platform === "win32" ? fs.constants.F_OK : fs.constants.X_OK);
  if (process.platform === "win32" && !shell) settings.shellPath = candidate.replace(/\\/g, "/");
  Object.assign(settings, {
    $schema: "https://pi.dev/schemas/settings.schema.json",
    defaultThinkingLevel: settings.defaultThinkingLevel || "high",
    theme: settings.theme || "system", tuiMode: settings.tuiMode || "fullscreen",
    quietStartup: true, enableInstallTelemetry: false, sessionShareDestination: "auto", cacheWarming: "off",
    compaction: { ...settings.compaction, enabled: false },
    terminal: { ...settings.terminal, showImages: false },
    markdown: { ...settings.markdown, mermaid: "off" }
  });
}
function discover(file) {
  let parsed;
  try { parsed = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch { throw new Error("模型列表不是有效 JSON"); }
  const list = Array.isArray(parsed) ? parsed : parsed?.data;
  check(Array.isArray(list), "模型列表结构无效：需要 data 数组或顶层数组");
  check(list.every(m => object(m) && typeof m.id === "string" && m.id.trim()), "模型列表包含无效模型 ID");
  const ids = [...new Set(list.map(m => m.id).filter(id => !/image|embed|tts|audio|whisper|batch/i.test(id)))];
  check(ids.length > 0, list.length ? "模型列表经当前名称过滤后没有候选模型" : "端点返回空模型列表");
  return ids;
}
function makeModels(ids, db) {
  check(object(db) && Object.keys(db).length > 0, "models.dev 参数库必须为非空对象");
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
    if (!spec) { unmatched++; return { id }; }
    const model = { id };
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
  } else {
    const cfg = loadConfigs();
    if (command === "inspect") {
      prepareSettings(cfg.settings.value, providerId);
      console.log(cfg.settings.value.defaultProvider || "cpa");
    } else if (command === "connection") {
      check(providerId.trim() && !/[\r\n]/.test(providerId), "Provider ID 无效");
      const provider = Object.hasOwn(cfg.models.value.providers, providerId) ? cfg.models.value.providers[providerId] : {};
      const credential = Object.hasOwn(cfg.auth.value, providerId) ? cfg.auth.value[providerId] : undefined;
      let key = "";
      if (args[0] !== "supplied" && credential) {
        check(credential.type === "api_key" && typeof credential.key === "string" && !credential.key.startsWith("!"), "此生成器仅复用字面量 API Key；请显式提供 Key，不执行凭据命令或解析 OAuth");
        key = credential.key;
      }
      check(!/[\r\n]/.test(provider.baseUrl || "") && !/[\r\n]/.test(key), "URL 和 API Key 必须为单行");
      process.stdout.write(`${provider.baseUrl || ""}\n${key}`);
    } else if (command === "apply") {
      const [baseUrl, idsPath, dbPath, bashPath] = args;
      const key = fs.readFileSync(0, "utf8");
      check(!/[\r\n]/.test(key) && !key.startsWith("!"), "需要单行字面量 API Key");
      prepareSettings(cfg.settings.value, bashPath);
      const { models, unmatched } = makeModels(JSON.parse(fs.readFileSync(idsPath, "utf8")), JSON.parse(fs.readFileSync(dbPath, "utf8")));
      cfg.models.value.$schema = "https://pi.dev/schemas/models.schema.json";
      cfg.models.value.providers = { ...cfg.models.value.providers, [providerId]: { baseUrl, api: "openai-completions", models } };
      if (key) cfg.auth.value = { ...cfg.auth.value, [providerId]: { type: "api_key", key } };
      const entries = [["models.json", cfg.models], ...(key ? [["auth.json", cfg.auth]] : []), ["settings.json", cfg.settings]]
        .map(([name, file]) => ({ name, text: file.text, content: JSON.stringify(file.value, null, 2) + "\n" }));
      writeConfigs(entries);
      console.log(`✅ 配置生成完成: ${models.length} 个模型，协议 openai-completions`);
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
TARGET_PROVIDER_ID="$CLI_PROVIDER"
if [ -z "$TARGET_PROVIDER_ID" ]; then
    if [ "$NON_INTERACTIVE" -eq 0 ]; then
        read -rp "Provider ID [当前: $DEFAULT_PROVIDER]: " TARGET_PROVIDER_ID < /dev/tty || exit 1
    fi
    TARGET_PROVIDER_ID="${TARGET_PROVIDER_ID:-$DEFAULT_PROVIDER}"
fi
KEY_SOURCE="stored"
[ -z "$CLI_KEY" ] || KEY_SOURCE="supplied"
OLD_CONNECTION=$(node "$WORK_DIR/config.cjs" connection "$CONFIG_DIR" "$TARGET_PROVIDER_ID" "$KEY_SOURCE")
OLD_URL="${OLD_CONNECTION%%$'\n'*}"
OLD_KEY="${OLD_CONNECTION#*$'\n'}"
TARGET_URL="$CLI_URL"
if [ -z "$TARGET_URL" ]; then
    if [ "$NON_INTERACTIVE" -eq 0 ]; then
        read -rp "Base URL [当前: ${OLD_URL:-未配置}]: " TARGET_URL < /dev/tty || exit 1
    fi
    TARGET_URL="${TARGET_URL:-$OLD_URL}"
fi
[[ -n "$TARGET_URL" && "$TARGET_URL" != *$'\n'* && "$TARGET_URL" != *$'\r'* ]] || { printf '❌ Base URL 必须为非空单行\n' >&2; exit 1; }
[[ "$TARGET_URL" =~ ^https?:// ]] || TARGET_URL="https://$TARGET_URL"
TARGET_URL="${TARGET_URL%/}"
TARGET_KEY="$CLI_KEY"
if [ -z "$TARGET_KEY" ]; then
    if [ "$NON_INTERACTIVE" -eq 0 ]; then
        read -rsp "API Key [当前: $([ -n "$OLD_KEY" ] && printf 已配置 || printf 未配置)，回车保留]: " TARGET_KEY < /dev/tty || exit 1
        printf '\n'
    fi
    TARGET_KEY="${TARGET_KEY:-$OLD_KEY}"
fi
[[ "$TARGET_KEY" != *$'\n'* && "$TARGET_KEY" != *$'\r'* && "$TARGET_KEY" != '!'* ]] || { printf '❌ 需要单行字面量 API Key\n' >&2; exit 1; }
unset CLI_KEY OLD_KEY OLD_CONNECTION

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
printf '🌐 正在获取 models.dev 参数库...\n'
curl -fsS --compressed -m 12 -o "$WORK_DIR/models-dev.json" https://models.dev/api.json

# 阶段四：预检与配置更新
printf '%s' "$TARGET_KEY" | node "$WORK_DIR/config.cjs" apply "$CONFIG_DIR" "$TARGET_PROVIDER_ID" "$TARGET_URL" "$WORK_DIR/ids.json" "$WORK_DIR/models-dev.json" "$BASH_PATH"
