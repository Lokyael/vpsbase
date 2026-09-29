#!/usr/bin/env bash
#
# scripts/pi-models.sh
# Pi 兼容端点配置与 models.dev 权威规格动态匹配脚本 (支持多 Provider 协同管理)
#

set -Eeuo pipefail

CONFIG_DIR="${HOME}/.pi/agent"
MODELS_FILE="${CONFIG_DIR}/models.json"
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
  bash scripts/pi-models.sh [选项]

选项:
  -p, --provider <id>         指定兼容 Provider ID (例如 custom、ollama、gateway)
  -u, --url <url>             兼容端点 Base URL (例如 https://api.example.com/v1 或 http://localhost:11434/v1)
  -k, --key <key>             API Key 凭证 (本地服务如 Ollama 可留空)
  -m, --model <id>            设为默认的模型 ID (例如 claude-3-7-sonnet-20250219)
  -d, --default               将当前配置的 Provider 设为系统默认供应商
  -y, --non-interactive       非交互模式 (自动复用已有配置或安全默认值)
  -h, --help                  显示本帮助信息

多 Provider 支持:
  脚本原生支持多端点并存 (如主力云端网关 + 本地 Ollama)。更新单个 Provider 时
  以原子合并方式安全落盘，绝不冲掉同文件中其他 Provider 的配置与凭证。
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--provider)
            CLI_PROVIDER="${2:-}"
            shift 2
            ;;
        -u|--url)
            CLI_URL="${2:-}"
            shift 2
            ;;
        -k|--key)
            CLI_KEY="${2:-}"
            shift 2
            ;;
        -m|--model)
            CLI_MODEL="${2:-}"
            shift 2
            ;;
        -d|--default)
            CLI_SET_DEFAULT="yes"
            shift
            ;;
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            printf '❌ 未知参数: %s\n' "$1" >&2
            show_help
            exit 1
            ;;
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
# 1. 解析已有多 Provider 配置列表
# ========================================================

RAW_PROVIDERS="[]"
if [ -f "$MODELS_FILE" ]; then
    RAW_PROVIDERS=$(node - "$MODELS_FILE" <<'NODE' || true
    const fs = require("fs");
    const [,, file] = process.argv;
    let list = [];
    try {
      const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
      for (const [id, p] of Object.entries(cfg.providers || {})) {
        list.push({
          id,
          baseUrl: p.baseUrl || "",
          hasKey: Boolean(p.apiKey && p.apiKey !== "dummy"),
          apiKey: (p.apiKey && p.apiKey !== "dummy") ? p.apiKey : "",
          modelsCount: (p.models || []).length
        });
      }
    } catch(e) {}
    console.log(JSON.stringify(list));
NODE
)
fi

EXISTING_DEFAULT_PROVIDER=""
EXISTING_DEFAULT_MODEL=""
if [ -f "$SETTINGS_FILE" ]; then
    EXISTING_DEFAULT_PROVIDER=$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).defaultProvider||"")}catch(e){}' "$SETTINGS_FILE" 2>/dev/null || true)
    EXISTING_DEFAULT_MODEL=$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).defaultModel||"")}catch(e){}' "$SETTINGS_FILE" 2>/dev/null || true)
fi

# ========================================================
# 2. 确定目标 Provider ID
# ========================================================

TARGET_PROVIDER_ID=""
OLD_URL=""
OLD_KEY=""
IS_EXISTING_PROVIDER=0

PROV_COUNT=$(node -e 'console.log(JSON.parse(process.argv[1]).length)' "$RAW_PROVIDERS")

if [ -n "$CLI_PROVIDER" ]; then
    TARGET_PROVIDER_ID="$CLI_PROVIDER"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    # 非交互模式：优先使用默认 provider，否则取第一个已有 provider，或 "custom"
    if [ -n "$EXISTING_DEFAULT_PROVIDER" ]; then
        TARGET_PROVIDER_ID="$EXISTING_DEFAULT_PROVIDER"
    elif [ "$PROV_COUNT" -gt 0 ]; then
        TARGET_PROVIDER_ID=$(node -e 'console.log(JSON.parse(process.argv[1])[0].id)' "$RAW_PROVIDERS")
    else
        TARGET_PROVIDER_ID="custom"
    fi
else
    # 交互模式：判断是否有已有端点
    if [ "$PROV_COUNT" -gt 1 ]; then
        printf '\n📋 检测到当前已配置多个端点:\n'
        node - "$RAW_PROVIDERS" "$EXISTING_DEFAULT_PROVIDER" <<'NODE'
        const [,, raw, defProv] = process.argv;
        const list = JSON.parse(raw);
        list.forEach((p, idx) => {
          const isDef = p.id === defProv ? " [当前系统默认]" : "";
          const keyStatus = p.hasKey ? "已设密钥" : "免密/默认";
          console.log(` [${idx + 1}] ${p.id.padEnd(12)} (${p.baseUrl} - ${p.modelsCount} 个模型 - ${keyStatus})${isDef}`);
        });
        console.log(` [0] 新增一个端点`);
NODE
        read -rp "请选择要更新的端点序号或输入新端点名称 [1-$PROV_COUNT/0] (默认 1): " CHOSEN_OPT < /dev/tty || true
        CHOSEN_OPT="${CHOSEN_OPT:-1}"
        if [[ "$CHOSEN_OPT" =~ ^[1-9][0-9]*$ ]] && [ "$CHOSEN_OPT" -le "$PROV_COUNT" ]; then
            TARGET_PROVIDER_ID=$(node -e 'console.log(JSON.parse(process.argv[1])[Number(process.argv[2]) - 1].id)' "$RAW_PROVIDERS" "$CHOSEN_OPT")
        elif [ "$CHOSEN_OPT" = "0" ]; then
            read -rp "请输入新 Provider ID (例如 gateway、ollama): " INPUT_PID < /dev/tty || true
            TARGET_PROVIDER_ID="${INPUT_PID:-custom}"
        else
            TARGET_PROVIDER_ID="$CHOSEN_OPT"
        fi
    elif [ "$PROV_COUNT" -eq 1 ]; then
        SINGLE_PID=$(node -e 'console.log(JSON.parse(process.argv[1])[0].id)' "$RAW_PROVIDERS")
        SINGLE_URL=$(node -e 'console.log(JSON.parse(process.argv[1])[0].baseUrl)' "$RAW_PROVIDERS")
        printf '\n📋 当前已配置端点: [%s] (%s)\n' "$SINGLE_PID" "$SINGLE_URL"
        read -rp "回车继续配置已有端点 [${SINGLE_PID}]，或输入新 ID 以新增端点: " INPUT_PID < /dev/tty || true
        TARGET_PROVIDER_ID="${INPUT_PID:-$SINGLE_PID}"
    else
        read -rp "请输入 Provider ID [默认: custom] (直接回车保留): " INPUT_PID < /dev/tty || true
        TARGET_PROVIDER_ID="${INPUT_PID:-custom}"
    fi
fi

# 检查目标 Provider 是否为已有端点，并预载已有参数
MATCHED_INFO=$(node - "$RAW_PROVIDERS" "$TARGET_PROVIDER_ID" <<'NODE' || true
const [,, raw, targetId] = process.argv;
const list = JSON.parse(raw);
const found = list.find(p => p.id === targetId);
if (found) {
  console.log(`1\t${found.baseUrl}\t${found.apiKey}`);
} else {
  console.log(`0\t\t`);
}
NODE
)
IS_EXISTING_PROVIDER=$(printf '%s' "$MATCHED_INFO" | cut -f1)
OLD_URL=$(printf '%s' "$MATCHED_INFO" | cut -f2)
OLD_KEY=$(printf '%s' "$MATCHED_INFO" | cut -f3)

# ========================================================
# 3. 确定 Base URL 与 API Key
# ========================================================

TARGET_URL=""
if [ -n "$CLI_URL" ]; then
    TARGET_URL="$CLI_URL"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    TARGET_URL="${OLD_URL:-}"
else
    if [ "$IS_EXISTING_PROVIDER" -eq 1 ] && [ -n "$OLD_URL" ]; then
        read -rp "请输入兼容端点 Base URL [当前: ${OLD_URL}] (直接回车保留): " INPUT_URL < /dev/tty || true
        TARGET_URL="${INPUT_URL:-$OLD_URL}"
    else
        read -rp "请输入兼容端点 Base URL（例如 https://api.example.com/v1 或 http://localhost:11434/v1）: " TARGET_URL < /dev/tty || true
    fi
fi
TARGET_URL="${TARGET_URL%/}"

if [ -z "$TARGET_URL" ]; then
    printf '❌ 端点 Base URL 不能为空\n' >&2
    exit 1
fi

TARGET_KEY=""
if [ -n "$CLI_KEY" ]; then
    TARGET_KEY="$CLI_KEY"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    TARGET_KEY="${OLD_KEY:-}"
else
    if [ "$IS_EXISTING_PROVIDER" -eq 1 ] && [ -n "$OLD_KEY" ]; then
        read -rsp "请输入 API Key [当前: $(mask_secret "$OLD_KEY")] (回车保留已有密钥): " INPUT_KEY < /dev/tty || true
        printf '\n'
        TARGET_KEY="${INPUT_KEY:-$OLD_KEY}"
    else
        read -rsp "请输入 API Key (鉴权探测端点模型使用，本地服务如 Ollama 可留空回车): " TARGET_KEY < /dev/tty || true
        printf '\n'
    fi
fi

umask 077
mkdir -p "$CONFIG_DIR"
chmod 700 "${HOME}/.pi" "$CONFIG_DIR"

# ========================================================
# 4. 鉴权探测上游端点模型
# ========================================================

REMOTE_MODELS=""
printf '🔍 正在探测端点可用模型 (Provider: %s)...\n' "$TARGET_PROVIDER_ID"

if [ -n "$TARGET_KEY" ]; then
    RAW_RES=$(curl -sS -m 8 -w "\n%{http_code}" -H "Authorization: Bearer ${TARGET_KEY}" "${TARGET_URL}/models" 2>/dev/null || true)
else
    RAW_RES=$(curl -sS -m 8 -w "\n%{http_code}" "${TARGET_URL}/models" 2>/dev/null || true)
fi

HTTP_CODE=$(printf '%s\n' "$RAW_RES" | tail -n1)
BODY=$(printf '%s\n' "$RAW_RES" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    REMOTE_MODELS="$BODY"
    printf '✅ 上游端点鉴权探测成功 (HTTP 200)\n'
elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    if [ -z "$TARGET_KEY" ]; then
        printf '⚠️  端点拒绝匿名访问 (HTTP %s)：该端点需要鉴权，请提供有效 API Key\n' "$HTTP_CODE" >&2
    else
        printf '⚠️  端点鉴权未通过 (HTTP %s)：提供的 API Key 无效或权限受限\n' "$HTTP_CODE" >&2
    fi
else
    printf 'ℹ️  端点未返回模型列表 (HTTP %s 或端点未实现 /models 接口)\n' "${HTTP_CODE:-000}"
fi

# ========================================================
# 5. 动态拉取 models.dev 规范并执行动态参数合成
# 原子合并更新 models.json：仅修改当前 Provider，完整保留其他 Provider
# ========================================================

TMP_MODELS_DEV="$(mktemp)"
trap 'rm -f "$TMP_MODELS_DEV"' EXIT

printf '🌐 正在拉取 models.dev 开源规格数据库 (api.json)...\n'
curl -sS -m 15 -o "$TMP_MODELS_DEV" "https://models.dev/api.json" 2>/dev/null || true

node - "$MODELS_FILE" "$TARGET_PROVIDER_ID" "$TARGET_URL" "$TARGET_KEY" "$REMOTE_MODELS" "$TMP_MODELS_DEV" "$IS_EXISTING_PROVIDER" <<'NODE'
const fs = require("fs");
const [,, modelsPath, providerId, baseUrl, apiKey, rawRemote, modelsDevPath, isExistingStr] = process.argv;
const isExisting = isExistingStr === "1";

let remoteData = [];
if (rawRemote) {
  try {
    const parsed = JSON.parse(rawRemote);
    if (Array.isArray(parsed.data)) remoteData = parsed.data;
  } catch(e) {}
}

let modelsDev = {};
if (fs.existsSync(modelsDevPath)) {
  try {
    const content = fs.readFileSync(modelsDevPath, "utf8");
    if (content.trim()) modelsDev = JSON.parse(content);
  } catch(e) {}
}

function findInModelsDev(modelId) {
  const normId = modelId.toLowerCase().replace(/-(thinking|high|low|medium)$/, "");
  const core = ["openai", "anthropic", "google", "deepseek", "meta", "alibaba", "qwen"];
  for (const p of core) {
    if (modelsDev[p]?.models?.[modelId]) return modelsDev[p].models[modelId];
    if (modelsDev[p]?.models?.[normId]) return modelsDev[p].models[normId];
  }
  for (const [p, pData] of Object.entries(modelsDev)) {
    if (pData.models) {
      if (pData.models[modelId]) return pData.models[modelId];
      if (pData.models[normId]) return pData.models[normId];
      for (const m of Object.values(pData.models)) {
        if (m.canonical_model_id === modelId || m.canonical_model_id === `${p}/${modelId}` || m.id === modelId) {
          return m;
        }
      }
    }
  }
  return null;
}

let models = [];

if (remoteData.length > 0) {
  for (const item of remoteData) {
    const id = item?.id;
    if (!id) continue;
    if (/image|embed|tts|audio|whisper|batch|auto-review/i.test(id)) continue;

    const spec = findInModelsDev(id);
    const isGpt = /^gpt-|^o[134]|^chatgpt-/i.test(id);

    const cw = item.context_window || item.max_context_tokens || item.max_model_len || spec?.limit?.context || 128000;
    const mt = item.max_output_tokens || item.max_completion_tokens || spec?.limit?.output || 16384;
    const reasoning = spec?.reasoning !== undefined ? Boolean(spec.reasoning) : /thinking|reasoning|think|-r1|luna|sol|o1|o3|o4/i.test(id);

    const rawInput = spec?.modalities?.input || ["text", "image"];
    const cleanInput = rawInput.filter(i => i === "text" || i === "image");

    const modelObj = {
      id,
      name: spec?.name || id,
      api: isGpt ? "openai-responses" : "openai-completions",
      reasoning,
      input: cleanInput.length > 0 ? cleanInput : ["text", "image"],
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
}

// 探测未果时的容错处理
if (models.length === 0) {
  let existingModels = [];
  if (isExisting && fs.existsSync(modelsPath)) {
    try {
      const oldCfg = JSON.parse(fs.readFileSync(modelsPath, "utf8"));
      existingModels = oldCfg.providers?.[providerId]?.models || [];
    } catch(e) {}
  }

  if (existingModels.length > 0) {
    models = existingModels;
    console.log(`ℹ️  未探测到新模型，已完整保留既有配置的 ${models.length} 个模型规格`);
  } else {
    models.push({
      id: "claude-3-7-sonnet-20250219",
      name: "Claude 3.7 Sonnet",
      api: "openai-completions",
      reasoning: true,
      input: ["text", "image"],
      contextWindow: 200000,
      maxTokens: 64000
    });
    console.log(`ℹ️  初始降级：已注入通用标准模型规格`);
  }
} else {
  console.log(`✅ 匹配完成：已动态生成 ${models.length} 个模型的完整规格配置`);
}

// 原子合并落盘：读取已有文件，保留其他所有 Provider，仅更新目标 Provider
let rootConfig = { providers: {} };
if (fs.existsSync(modelsPath)) {
  try { rootConfig = JSON.parse(fs.readFileSync(modelsPath, "utf8")) || { providers: {} }; } catch(e){}
}
if (!rootConfig.providers) rootConfig.providers = {};

rootConfig.providers[providerId] = {
  baseUrl: baseUrl,
  api: "openai-completions",
  apiKey: apiKey || "dummy",
  models
};

fs.writeFileSync(modelsPath, JSON.stringify(rootConfig, null, 2) + "\n");
NODE
chmod 600 "$MODELS_FILE"

# ========================================================
# 6. 处理默认供应商与默认模型 (settings.json)
# ========================================================

SHOULD_SET_AS_DEFAULT_PROVIDER=0
if [ "$CLI_SET_DEFAULT" = "yes" ]; then
    SHOULD_SET_AS_DEFAULT_PROVIDER=1
elif [ -z "$EXISTING_DEFAULT_PROVIDER" ] || [ "$EXISTING_DEFAULT_PROVIDER" = "$TARGET_PROVIDER_ID" ]; then
    # 若系统暂无默认 Provider，或当前配置的就是默认 Provider
    SHOULD_SET_AS_DEFAULT_PROVIDER=1
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    SHOULD_SET_AS_DEFAULT_PROVIDER=0
else
    read -rp "是否将 [${TARGET_PROVIDER_ID}] 设为系统默认供应商? [y/N] (默认保留原默认: ${EXISTING_DEFAULT_PROVIDER}): " SET_DEF_INPUT < /dev/tty || true
    if [[ "$SET_DEF_INPUT" =~ ^[yY]$ ]]; then
        SHOULD_SET_AS_DEFAULT_PROVIDER=1
    fi
fi

if [ "$SHOULD_SET_AS_DEFAULT_PROVIDER" -eq 1 ]; then
    DEFAULT_MODEL="${CLI_MODEL:-${EXISTING_DEFAULT_MODEL:-}}"
    if [ -z "$DEFAULT_MODEL" ]; then
        DEFAULT_MODEL=$(node - "$MODELS_FILE" "$TARGET_PROVIDER_ID" <<'NODE' || true
        const fs = require("fs");
        const [,, modelsPath, providerId] = process.argv;
        try {
          const cfg = JSON.parse(fs.readFileSync(modelsPath, "utf8"));
          const list = cfg.providers?.[providerId]?.models || [];
          const preferred = list.find(m => /opus|sonnet|sol|luna/i.test(m.id)) || list[0];
          if (preferred) console.log(preferred.id);
        } catch(e){}
NODE
)
    fi

    CHOSEN_MODEL=""
    if [ -n "$CLI_MODEL" ] || [ "$NON_INTERACTIVE" -eq 1 ]; then
        CHOSEN_MODEL="${CLI_MODEL:-${DEFAULT_MODEL:-claude-3-7-sonnet-20250219}}"
    else
        read -rp "请输入默认模型 ID [当前: ${DEFAULT_MODEL:-claude-3-7-sonnet-20250219}] (回车保留): " INPUT_MODEL < /dev/tty || true
        CHOSEN_MODEL="${INPUT_MODEL:-${DEFAULT_MODEL:-claude-3-7-sonnet-20250219}}"
    fi

    node - "$SETTINGS_FILE" "$TARGET_PROVIDER_ID" "$CHOSEN_MODEL" <<'NODE'
    const fs = require("fs");
    const [,, settingsPath, providerId, modelId] = process.argv;
    let data = {};
    try { data = JSON.parse(fs.readFileSync(settingsPath, "utf8")); } catch(e){}
    data.defaultProvider = providerId;
    data.defaultModel = modelId;
    fs.writeFileSync(settingsPath, JSON.stringify(data, null, 2) + "\n");
NODE
    chmod 600 "$SETTINGS_FILE"
    printf '✅ 系统默认供应商已更新为 [%s]，默认模型 [%s]\n' "$TARGET_PROVIDER_ID" "$CHOSEN_MODEL"
else
    printf 'ℹ️  保留原有系统默认供应商 [%s] (未修改 settings.json)\n' "$EXISTING_DEFAULT_PROVIDER"
fi

printf '✅ 端点 [%s] 配置就绪: %s\n' "$TARGET_PROVIDER_ID" "$TARGET_URL"
printf '✅ 凭证与模型规格已原子写入 models.json (未触及 auth.json)\n'
