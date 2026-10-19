#!/usr/bin/env bash
#
# scripts/pi.sh
# Pi 智能体环境打底、工程首选项与端点模型一键全量对齐脚本
# 跨平台原生兼容 POSIX Bash 与 Windows Git Bash (支持在 pwsh 中通过 sh.exe 调度)
# 依托 models.dev 权威数据库即时补全网关缺失的上下文、输出上限与计费参数
#

set -Eeuo pipefail

CONFIG_DIR="${HOME}/.pi/agent"
MODELS_FILE="${CONFIG_DIR}/models.json"
AUTH_FILE="${CONFIG_DIR}/auth.json"
SETTINGS_FILE="${CONFIG_DIR}/settings.json"

CLI_PROVIDER=""
CLI_URL=""
CLI_KEY=""
CLI_MODEL=""
CLI_SET_DEFAULT=""
NON_INTERACTIVE=0

show_help() {
    cat <<'EOF'
用法:
  bash scripts/pi.sh [选项]

选项:
  -p, --provider <id>         Provider ID (默认: cpa)
  -u, --url <url>             兼容端点 Base URL (例如 https://cpa.example.com/v1)
  -k, --key <key>             API Key 凭据 (存入 auth.json 0600，免密端点可留空)
  -m, --model <id>            设为默认的模型 ID
  -d, --default               将当前 Provider 设为系统默认
  -y, --non-interactive       非交互模式 (复用已有配置或安全默认值)
  -h, --help                  显示帮助信息

跨终端执行示例:
  - Linux 终端:
      bash scripts/pi.sh
  - Windows Git Bash:
      bash scripts/pi.sh
  - Windows pwsh:
      sh.exe -c "bash scripts/pi.sh"
      # 或远程单行无落盘执行:
      sh.exe -c "curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi.sh | bash"
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--provider) CLI_PROVIDER="${2:-}"; shift 2 ;;
        -u|--url)      CLI_URL="${2:-}"; shift 2 ;;
        -k|--key)      CLI_KEY="${2:-}"; shift 2 ;;
        -m|--model)    CLI_MODEL="${2:-}"; shift 2 ;;
        -d|--default)  CLI_SET_DEFAULT="yes"; shift ;;
        -y|--yes|--non-interactive) NON_INTERACTIVE=1; shift ;;
        -h|--help)     show_help; exit 0 ;;
        *)             printf '❌ 未知参数: %s\n' "$1" >&2; show_help; exit 1 ;;
    esac
done

mask_secret() {
    local s="$1"
    local len=${#s}
    if [ "$len" -eq 0 ]; then
        printf '未配置'
    elif [ "$len" -le 8 ]; then
        printf '******'
    else
        printf '%s***%s' "${s:0:3}" "${s: -4}"
    fi
}

# ========================================================
# 阶段一：运行环境与底层依赖就绪
# ========================================================

IS_WINDOWS=0
if [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* || -n "${WINDIR:-}" ]]; then
    IS_WINDOWS=1
fi

if [ "$IS_WINDOWS" -eq 1 ]; then
    command -v scoop >/dev/null 2>&1 || { printf '❌ 未检测到 scoop 命令，请先就绪 Scoop 包管理器环境\n' >&2; exit 1; }

    # 直接依托 Scoop 原生幂等机制对齐全部底层基石工具链 (已装自动跳过)
    scoop install git nodejs-lts pi-coding-agent ripgrep fd >/dev/null 2>&1 || true
else
    # Linux 环境：Node.js 运行时由系统或用户自主纳管，脚本不越权安装 Node 管理器
    if ! command -v node >/dev/null 2>&1; then
        command -v fnm >/dev/null 2>&1 && eval "$(fnm env --shell bash 2>/dev/null)" || true
    fi

    if command -v paru >/dev/null 2>&1; then
        paru -S --needed --noconfirm --skipreview pi-coding-agent-bin ripgrep fd >/dev/null 2>&1 || true
    fi
fi

command -v node >/dev/null 2>&1 || { printf '❌ 未检测到 Node.js 运行环境，请先就绪 Node.js\n' >&2; exit 1; }

umask 077
mkdir -p "$CONFIG_DIR"
chmod 700 "${HOME}/.pi" "$CONFIG_DIR" 2>/dev/null || true

# ========================================================
# 阶段二：解析 Provider ID、Base URL 与 API Key
# ========================================================

EXISTING_DEFAULT_PROVIDER=""
EXISTING_DEFAULT_MODEL=""
if [ -f "$SETTINGS_FILE" ]; then
    EXISTING_DEFAULT_PROVIDER=$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8").replace(/^\uFEFF/,"")).defaultProvider||"")}catch(e){}' "$SETTINGS_FILE" 2>/dev/null || true)
    EXISTING_DEFAULT_MODEL=$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8").replace(/^\uFEFF/,"")).defaultModel||"")}catch(e){}' "$SETTINGS_FILE" 2>/dev/null || true)
fi

OLD_URL=""
if [ -f "$MODELS_FILE" ]; then
    OLD_URL=$(node - "$MODELS_FILE" "${CLI_PROVIDER:-${EXISTING_DEFAULT_PROVIDER:-cpa}}" <<'NODE' 2>/dev/null || true
    const fs = require("fs");
    const [,, file, pid] = process.argv;
    try {
      const cfg = JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
      console.log(cfg.providers?.[pid]?.baseUrl || "");
    } catch(e){}
NODE
)
fi

TARGET_PROVIDER_ID="${CLI_PROVIDER:-}"
if [ -z "$TARGET_PROVIDER_ID" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        TARGET_PROVIDER_ID="${EXISTING_DEFAULT_PROVIDER:-cpa}"
    else
        read -rp "请输入 Provider ID [默认: ${EXISTING_DEFAULT_PROVIDER:-cpa}]: " INPUT_PID < /dev/tty || true
        TARGET_PROVIDER_ID="${INPUT_PID:-${EXISTING_DEFAULT_PROVIDER:-cpa}}"
    fi
fi

TARGET_URL="${CLI_URL:-}"
if [ -z "$TARGET_URL" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        TARGET_URL="${OLD_URL:-}"
    else
        read -rp "端点 Base URL [当前: ${OLD_URL:-https://cpa.example.com/v1}]: " INPUT_URL < /dev/tty || true
        TARGET_URL="${INPUT_URL:-${OLD_URL:-https://cpa.example.com/v1}}"
    fi
fi
TARGET_URL="${TARGET_URL%/}"

if [ -z "$TARGET_URL" ]; then
    printf '❌ 端点 Base URL 不能为空\n' >&2
    exit 1
fi
[[ ! "$TARGET_URL" =~ ^https?:// ]] && TARGET_URL="https://${TARGET_URL}"

OLD_AUTH_KEY=""
if [ -f "$AUTH_FILE" ]; then
    OLD_AUTH_KEY=$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8").replace(/^\uFEFF/,""))[process.argv[2]]?.key||"");}catch(e){}' "$AUTH_FILE" "$TARGET_PROVIDER_ID" 2>/dev/null || true)
fi

TARGET_KEY="${CLI_KEY:-}"
if [ -z "$TARGET_KEY" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        TARGET_KEY="${OLD_AUTH_KEY:-}"
    else
        read -rsp "请输入 API Key [当前: $(mask_secret "$OLD_AUTH_KEY")] (回车保留/留空跳过): " INPUT_KEY < /dev/tty || true
        printf '\n'
        TARGET_KEY="${INPUT_KEY:-$OLD_AUTH_KEY}"
    fi
fi

# ========================================================
# 阶段三：端点模型探测与 models.dev 即时规格对齐
# ========================================================

printf '🔍 正在探测端点可用模型 (%s)...\n' "$TARGET_PROVIDER_ID"
REMOTE_MODELS=""
AUTH_HEADER=()
[ -n "$TARGET_KEY" ] && AUTH_HEADER=(-H "Authorization: Bearer ${TARGET_KEY}")

RAW_RES=$(curl -sS -m 6 -w "\n%{http_code}" "${AUTH_HEADER[@]}" "${TARGET_URL}/models" 2>/dev/null || true)
HTTP_CODE=$(printf '%s\n' "$RAW_RES" | tail -n1)
BODY=$(printf '%s\n' "$RAW_RES" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    REMOTE_MODELS="$BODY"
    printf '✅ 上游端点鉴权与模型列表拉取成功 (HTTP 200)\n'
else
    printf 'ℹ️  端点未返回模型列表 (HTTP %s)，将采用标准预设\n' "${HTTP_CODE:-000}"
fi

TMP_MODELS_DEV="$(mktemp)"
trap 'rm -f "$TMP_MODELS_DEV"' EXIT

printf '🌐 正在即时获取 models.dev 权威模型参数库 (gzip 压缩流)...\n'
if curl -sS --compressed -m 12 -o "$TMP_MODELS_DEV" "https://models.dev/api.json" 2>/dev/null && [ -s "$TMP_MODELS_DEV" ]; then
    printf '✅ models.dev 参数库获取成功\n'
else
    printf '⚠️  未获取到 models.dev 在线库，将采用内置启发式规则推导规格\n'
fi

# ========================================================
# 阶段四：原子落盘 models.json、auth.json 与 settings.json
# ========================================================

node - "$MODELS_FILE" "$AUTH_FILE" "$SETTINGS_FILE" "$TMP_MODELS_DEV" "$TARGET_PROVIDER_ID" "$TARGET_URL" "$TARGET_KEY" "$REMOTE_MODELS" "$CLI_MODEL" "$CLI_SET_DEFAULT" <<'NODE'
const fs = require("fs");
const [,, modelsPath, authPath, settingsPath, dbPath, providerId, baseUrl, rawKey, rawRemote, cliModel, cliSetDef] = process.argv;

let db = {};
if (fs.existsSync(dbPath)) {
  try { db = JSON.parse(fs.readFileSync(dbPath, "utf8")); } catch(e) {}
}

function findModelSpec(rawId) {
  const cleanId = rawId.toLowerCase().trim();
  const withoutProvider = cleanId.includes("/") ? cleanId.split("/")[1] : cleanId;
  const baseId = withoutProvider.replace(/-(thinking|high|low|medium|search)$/, "");
  const candidates = [cleanId, withoutProvider, baseId];

  const coreProviders = ["anthropic", "openai", "google", "deepseek", "meta", "alibaba", "qwen", "mistral"];
  for (const prov of coreProviders) {
    const models = db[prov]?.models || {};
    for (const cand of candidates) {
      if (models[cand]) return { ...models[cand], provider: prov };
    }
  }

  for (const [prov, pData] of Object.entries(db)) {
    const models = pData.models || {};
    for (const cand of candidates) {
      if (models[cand]) return { ...models[cand], provider: prov };
    }
  }

  for (const [prov, pData] of Object.entries(db)) {
    for (const [mId, mData] of Object.entries(pData.models || {})) {
      if (mData.canonical_model_id && candidates.includes(mData.canonical_model_id.toLowerCase())) {
        return { ...mData, provider: prov };
      }
    }
  }
  return null;
}

// 1. 解析模型规格并由 models.dev 补齐参数
let models = [];
if (rawRemote) {
  try {
    const parsed = JSON.parse(rawRemote);
    const list = Array.isArray(parsed.data) ? parsed.data : (Array.isArray(parsed) ? parsed : []);
    for (const m of list) {
      const id = m?.id;
      if (!id || /image|embed|tts|audio|whisper|batch/i.test(id)) continue;

      const spec = findModelSpec(id);
      const cw = spec?.limit?.context || m.context_window || m.max_context_tokens || 128000;
      const mt = spec?.limit?.output || m.max_output_tokens || m.max_tokens || 16384;
      const reasoning = spec?.reasoning !== undefined
        ? Boolean(spec.reasoning)
        : /thinking|reasoning|think|-r1|luna|sol|o[134]|-high|-medium|-low/i.test(id);

      const rawInput = spec?.modalities?.input || ["text"];
      const cleanInput = rawInput.filter(i => i === "text" || i === "image");

      const modelObj = {
        id,
        name: spec?.name || id,
        reasoning,
        input: cleanInput.length > 0 ? cleanInput : ["text"],
        contextWindow: Number(cw),
        maxTokens: Number(mt)
      };

      if (spec?.cost && typeof spec.cost.input === "number" && typeof spec.cost.output === "number") {
        modelObj.cost = {
          input: Number(spec.cost.input),
          output: Number(spec.cost.output),
          cacheRead: typeof spec.cost.cache_read === "number" ? Number(spec.cost.cache_read) : 0,
          cacheWrite: typeof spec.cost.cache_write === "number" ? Number(spec.cost.cache_write) : 0
        };
      }
      models.push(modelObj);
    }
  } catch(e) {}
}

if (models.length === 0 && fs.existsSync(modelsPath)) {
  try {
    const old = JSON.parse(fs.readFileSync(modelsPath, "utf8").replace(/^\uFEFF/, ""));
    models = (old.providers?.[providerId]?.models || []).map(({ apiKey, ...rest }) => rest);
  } catch(e) {}
}

if (models.length === 0) {
  models = [
    {
      id: "claude-3-7-sonnet-20250219",
      name: "Claude 3.7 Sonnet",
      reasoning: true,
      input: ["text", "image"],
      contextWindow: 200000,
      maxTokens: 64000,
      cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 }
    },
    {
      id: "gemini-2.5-flash",
      name: "Gemini 2.5 Flash",
      reasoning: true,
      input: ["text", "image"],
      contextWindow: 1048576,
      maxTokens: 65536,
      cost: { input: 0.075, output: 0.3, cacheRead: 0.01875, cacheWrite: 0 }
    }
  ];
}

// 2. 写入 models.json (规范 schema，绝无 apiKey)
let modelsCfg = { $schema: "https://pi.dev/schemas/models.schema.json", providers: {} };
if (fs.existsSync(modelsPath)) {
  try {
    const p = JSON.parse(fs.readFileSync(modelsPath, "utf8").replace(/^\uFEFF/, ""));
    if (p && typeof p === "object") modelsCfg = { ...modelsCfg, ...p };
  } catch(e) {}
}
if (!modelsCfg.providers) modelsCfg.providers = {};

modelsCfg.providers[providerId] = {
  baseUrl,
  api: "openai-completions",
  models
};
delete modelsCfg.providers[providerId].apiKey;

fs.writeFileSync(modelsPath, JSON.stringify(modelsCfg, null, 2) + "\n");

// 3. 写入 auth.json (仅存 key，0600)
if (rawKey) {
  let authCfg = {};
  if (fs.existsSync(authPath)) {
    try { authCfg = JSON.parse(fs.readFileSync(authPath, "utf8").replace(/^\uFEFF/, "")) || {}; } catch(e) {}
  }
  authCfg[providerId] = { type: "api_key", key: rawKey };
  fs.writeFileSync(authPath, JSON.stringify(authCfg, null, 2) + "\n");
}

// 4. 写入 settings.json (标准工程基线)
let settings = {};
if (fs.existsSync(settingsPath)) {
  try { settings = JSON.parse(fs.readFileSync(settingsPath, "utf8").replace(/^\uFEFF/, "")) || {}; } catch(e) {}
}

settings.$schema = "https://pi.dev/schemas/settings.schema.json";
Object.assign(settings, {
  defaultThinkingLevel: settings.defaultThinkingLevel || "high",
  theme: settings.theme || "system",
  tuiMode: settings.tuiMode || "fullscreen",
  quietStartup: true,
  enableInstallTelemetry: false,
  sessionShareDestination: "auto",
  cacheWarming: "off"
});

settings.compaction = { ...(settings.compaction || {}), enabled: false };
settings.terminal = { ...(settings.terminal || {}), showImages: false };
settings.markdown = { ...(settings.markdown || {}), mermaid: "off" };

const shouldSetDef = cliSetDef === "yes" || !settings.defaultProvider || settings.defaultProvider === providerId;
if (shouldSetDef) {
  settings.defaultProvider = providerId;
  const bestModel = cliModel || (models.find(m => /sonnet|flash|opus/i.test(m.id)) || models[0]).id;
  settings.defaultModel = bestModel;
}

// Windows 环境下自动探测绑定 Git Bash 路径
if (process.platform === "win32" && !settings.shellPath) {
  try {
    const { execSync } = require("child_process");
    let bp = "";
    try {
      const sp = execSync("scoop prefix git 2>/dev/null", { encoding: "utf8" }).trim();
      if (sp && fs.existsSync(`${sp}/bin/bash.exe`)) {
        bp = `${execSync(`cygpath -m "${sp}"`, { encoding: "utf8" }).trim()}/bin/bash.exe`;
      }
    } catch (_) {}
    if (!bp) bp = execSync("cygpath -m $(which bash)", { encoding: "utf8" }).trim();
    if (bp && fs.existsSync(bp)) settings.shellPath = bp;
  } catch (_) {}
}

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
NODE

chmod 600 "$MODELS_FILE" "$SETTINGS_FILE" 2>/dev/null || true
[ -f "$AUTH_FILE" ] && chmod 600 "$AUTH_FILE" 2>/dev/null || true

MODEL_COUNT=$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).providers[process.argv[2]].models.length)}catch(e){console.log(0)}' "$MODELS_FILE" "$TARGET_PROVIDER_ID" 2>/dev/null || echo 0)
printf '\n✅ Pi 全量工程基线对齐成功: %s (%s)\n' "$TARGET_PROVIDER_ID" "$TARGET_URL"
printf '  - models.json   : 已依据 models.dev 补全规格 (%d 个模型)\n' "$MODEL_COUNT"
[ -n "$TARGET_KEY" ] && printf '  - auth.json     : 凭据已存入 (权限 0600)\n'
printf '  - settings.json : 标准基线固化 (ShellPath 自动绑定、思考 high)\n'
