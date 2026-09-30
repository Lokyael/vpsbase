#!/usr/bin/env bash
#
# scripts/pi-models.sh
# Pi 兼容端点配置与 models.dev 规格动态匹配脚本 (支持 Bitwarden 标志与 auth.json 两种零泄露模式)
#

set -Eeuo pipefail

CONFIG_DIR="${HOME}/.pi/agent"
MODELS_FILE="${CONFIG_DIR}/models.json"
AUTH_FILE="${CONFIG_DIR}/auth.json"
SETTINGS_FILE="${CONFIG_DIR}/settings.json"

CLI_PROVIDER=""
CLI_URL=""
CLI_MODE="" # "bw" | "direct"
CLI_KEY=""
CLI_BW_ITEM=""
CLI_MODEL=""
CLI_SET_DEFAULT=""
NON_INTERACTIVE=0

show_help() {
    cat <<'EOF'
用法:
  bash scripts/pi-models.sh [选项]

选项:
  --mode <bw|direct>          凭证管理模式 (默认优先推荐 bw):
                                bw     - Bitwarden 标志引用 (models.json 写入 !bw get password)
                                direct - Pi 原生金库 (密钥存入 auth.json 0600，models.json 零明文)
  -p, --provider <id>         指定兼容 Provider ID (例如 cpa、custom、gateway)
  -u, --url <url>             兼容端点 Base URL (例如 https://cpa.example.com/v1)
  -b, --bw-item <name>        Bitwarden 条目名称 (用于 bw 模式，默认与 provider 同名)
  -k, --key <key>             API Key (用于 direct 模式或临时探测)
  -m, --model <id>            设为默认的模型 ID (例如 claude-3-7-sonnet-20250219)
  -d, --default               将当前 Provider 设为系统默认供应商
  -y, --non-interactive       非交互模式 (自动复用已有配置或安全默认值)
  -h, --help                  显示本帮助信息

凭证安全规范:
  无论选用哪种模式，models.json 磁盘文件中均绝不出现任何明文 API Key。
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            CLI_MODE="${2:-}"
            shift 2
            ;;
        -p|--provider)
            CLI_PROVIDER="${2:-}"
            shift 2
            ;;
        -u|--url)
            CLI_URL="${2:-}"
            shift 2
            ;;
        -b|--bw-item)
            CLI_BW_ITEM="${2:-}"
            CLI_MODE="bw"
            shift 2
            ;;
        -k|--key)
            CLI_KEY="${2:-}"
            CLI_MODE="direct"
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

umask 077
mkdir -p "$CONFIG_DIR"
chmod 700 "${HOME}/.pi" "$CONFIG_DIR"

# ========================================================
# 阶段一：凭证管理模式决策与依赖检查 (意图先行)
# ========================================================

FINAL_MODE=""
DEFAULT_MODE="bw"
command -v bw >/dev/null 2>&1 || DEFAULT_MODE="direct"

if [ -n "$CLI_MODE" ]; then
    FINAL_MODE="$CLI_MODE"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    FINAL_MODE="$DEFAULT_MODE"
else
    printf '\n🔐 请选择凭证管理模式 (models.json 绝不写入明文):\n'
    printf '  [1] Bitwarden 标志模式 (推荐: models.json 仅写入 !bw get password，零明文落盘)\n'
    printf '  [2] Pi 原生金库模式 (密钥安全存入 auth.json 0600，models.json 彻底不留 key)\n'
    read -rp "请选择模式 [1/2] (默认: $([ "$DEFAULT_MODE" = "bw" ] && printf '1' || printf '2')): " CHOSEN_MODE < /dev/tty || true
    case "${CHOSEN_MODE:-}" in
        1) FINAL_MODE="bw" ;;
        2) FINAL_MODE="direct" ;;
        "") FINAL_MODE="$DEFAULT_MODE" ;;
        *) FINAL_MODE="bw" ;;
    esac
fi

prompt_switch_or_exit() {
    local reason="$1"
    printf '⚠️  %s\n' "$reason"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        exit 1
    fi
    read -rp "是否切换为模式二 (Pi 原生金库模式) 继续? [y/N]: " SWITCH_TO_DIRECT < /dev/tty || true
    if [[ "$SWITCH_TO_DIRECT" =~ ^[Yy]$ ]]; then
        FINAL_MODE="direct"
    else
        printf '🚫 已退出配置。\n'
        exit 0
    fi
}

# 检查 Bitwarden 模式下的 CLI 依赖 (仅支持 paru / scoop)
if [ "$FINAL_MODE" = "bw" ] && ! command -v bw >/dev/null 2>&1; then
    PKG_MGR=""
    PKG_INSTALL_CMD=""

    if command -v paru >/dev/null 2>&1; then
        PKG_MGR="paru"
        PKG_INSTALL_CMD="paru -S --needed --noconfirm --skipreview bitwarden-cli"
    elif command -v scoop >/dev/null 2>&1; then
        PKG_MGR="scoop"
        PKG_INSTALL_CMD="scoop install bitwarden-cli"
    fi

    if [ -n "$PKG_MGR" ]; then
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            $PKG_INSTALL_CMD || prompt_switch_or_exit "非交互安装 bitwarden-cli 失败"
        else
            printf '⚠️  未检测到 bw 命令 (已检测到 %s)\n' "$PKG_MGR"
            read -rp "是否立即自动安装 bitwarden-cli? [Y/n]: " DO_INSTALL < /dev/tty || true
            if [[ ! "$DO_INSTALL" =~ ^[Nn]$ ]] && $PKG_INSTALL_CMD; then
                printf '✅ bitwarden-cli 安装成功\n'
            else
                prompt_switch_or_exit "未安装 bitwarden-cli"
            fi
        fi
    else
        prompt_switch_or_exit "未检测到 bw，且系统中未安装 paru 或 scoop"
    fi
fi

# ========================================================
# 阶段二：解析已有 Provider 并确定目标端点与 Base URL
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
          apiKey: p.apiKey || "",
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

TARGET_PROVIDER_ID=""
OLD_URL=""
OLD_APIKEY_FIELD=""
IS_EXISTING_PROVIDER=0

PROV_COUNT=$(node -e 'console.log(JSON.parse(process.argv[1]).length)' "$RAW_PROVIDERS")

if [ -n "$CLI_PROVIDER" ]; then
    TARGET_PROVIDER_ID="$CLI_PROVIDER"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    if [ -n "$EXISTING_DEFAULT_PROVIDER" ]; then
        TARGET_PROVIDER_ID="$EXISTING_DEFAULT_PROVIDER"
    elif [ "$PROV_COUNT" -gt 0 ]; then
        TARGET_PROVIDER_ID=$(node -e 'console.log(JSON.parse(process.argv[1])[0].id)' "$RAW_PROVIDERS")
    else
        TARGET_PROVIDER_ID="cpa"
    fi
else
    if [ "$PROV_COUNT" -gt 1 ]; then
        printf '\n📋 当前已配置的端点:\n'
        node - "$RAW_PROVIDERS" "$EXISTING_DEFAULT_PROVIDER" <<'NODE'
        const [,, raw, defProv] = process.argv;
        const list = JSON.parse(raw);
        list.forEach((p, idx) => {
          const isDef = p.id === defProv ? " [当前默认]" : "";
          const modeTag = p.apiKey.startsWith("!bw") ? "Bitwarden" : (p.apiKey ? "内联" : "auth.json");
          console.log(` [${idx + 1}] ${p.id.padEnd(12)} (${p.baseUrl} - ${p.modelsCount} 个模型 - ${modeTag})${isDef}`);
        });
        console.log(` [0] 新增一个端点`);
NODE
        read -rp "请选择序号或输入新 Provider ID [1-$PROV_COUNT/0] (默认 1): " CHOSEN_OPT < /dev/tty || true
        CHOSEN_OPT="${CHOSEN_OPT:-1}"
        if [[ "$CHOSEN_OPT" =~ ^[1-9][0-9]*$ ]] && [ "$CHOSEN_OPT" -le "$PROV_COUNT" ]; then
            TARGET_PROVIDER_ID=$(node -e 'console.log(JSON.parse(process.argv[1])[Number(process.argv[2]) - 1].id)' "$RAW_PROVIDERS" "$CHOSEN_OPT")
        elif [ "$CHOSEN_OPT" = "0" ]; then
            read -rp "请输入新 Provider ID (例如 cpa、custom): " INPUT_PID < /dev/tty || true
            TARGET_PROVIDER_ID="${INPUT_PID:-cpa}"
        else
            TARGET_PROVIDER_ID="$CHOSEN_OPT"
        fi
    elif [ "$PROV_COUNT" -eq 1 ]; then
        SINGLE_PID=$(node -e 'console.log(JSON.parse(process.argv[1])[0].id)' "$RAW_PROVIDERS")
        SINGLE_URL=$(node -e 'console.log(JSON.parse(process.argv[1])[0].baseUrl)' "$RAW_PROVIDERS")
        printf '\n📋 当前已配置端点: [%s] (%s)\n' "$SINGLE_PID" "$SINGLE_URL"
        read -rp "回车继续配置已有端点 [${SINGLE_PID}]，或输入新 ID: " INPUT_PID < /dev/tty || true
        TARGET_PROVIDER_ID="${INPUT_PID:-$SINGLE_PID}"
    else
        read -rp "请输入 Provider ID [默认: cpa] (直接回车保留): " INPUT_PID < /dev/tty || true
        TARGET_PROVIDER_ID="${INPUT_PID:-cpa}"
    fi
fi

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
OLD_APIKEY_FIELD=$(printf '%s' "$MATCHED_INFO" | cut -f3)

TARGET_URL=""
if [ -n "$CLI_URL" ]; then
    TARGET_URL="$CLI_URL"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    TARGET_URL="${OLD_URL:-}"
else
    if [ "$IS_EXISTING_PROVIDER" -eq 1 ] && [ -n "$OLD_URL" ]; then
        read -rp "端点 Base URL [当前: ${OLD_URL}] (回车保留): " INPUT_URL < /dev/tty || true
        TARGET_URL="${INPUT_URL:-$OLD_URL}"
    else
        read -rp "端点 Base URL (例如 https://cpa.example.com/v1 或 http://localhost:8317/v1): " TARGET_URL < /dev/tty || true
    fi
fi
TARGET_URL="${TARGET_URL%/}"

if [ -z "$TARGET_URL" ]; then
    printf '❌ 端点 Base URL 不能为空\n' >&2
    exit 1
fi

# ========================================================
# 阶段三：提取探测凭据与端点模型嗅探
# ========================================================

PROBE_KEY=""
FINAL_BW_ITEM=""

if [ "$FINAL_MODE" = "bw" ]; then
    DETECTED_BW_ITEM="$TARGET_PROVIDER_ID"
    if [[ "$OLD_APIKEY_FIELD" =~ ^!bw\ get\ password\ (.+)$ ]]; then
        DETECTED_BW_ITEM="${BASH_REMATCH[1]}"
    fi

    if [ -n "$CLI_BW_ITEM" ]; then
        FINAL_BW_ITEM="$CLI_BW_ITEM"
    elif [ "$NON_INTERACTIVE" -eq 1 ]; then
        FINAL_BW_ITEM="$DETECTED_BW_ITEM"
    else
        read -rp "Bitwarden 条目名称 [当前: ${DETECTED_BW_ITEM}] (回车保留): " INPUT_BW < /dev/tty || true
        FINAL_BW_ITEM="${INPUT_BW:-$DETECTED_BW_ITEM}"
    fi

    if command -v bw >/dev/null 2>&1; then
        PROBE_KEY=$(bw get password "$FINAL_BW_ITEM" 2>/dev/null || true)
    fi

    if [ -z "$PROBE_KEY" ] && [ "$NON_INTERACTIVE" -eq 0 ]; then
        printf '⚠️  未能从 bw 读取到 [%s] (保密库可能处于锁定状态或条目不存在)\n' "$FINAL_BW_ITEM"
        printf '💡 提示: 若已设置条目，可在另一终端执行: export BW_SESSION=$(bw unlock --raw)\n'
        read -rsp "请输入探测用临时 API Key (仅用于本次探测，绝不落盘，留空则跳过探测): " PROBE_KEY < /dev/tty || true
        printf '\n'
    fi

else
    OLD_AUTH_KEY=""
    if [ -f "$AUTH_FILE" ]; then
        OLD_AUTH_KEY=$(node -e 'try{const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(a[process.argv[2]]?.key||"");}catch(e){}' "$AUTH_FILE" "$TARGET_PROVIDER_ID" 2>/dev/null || true)
    fi

    if [ -n "$CLI_KEY" ]; then
        PROBE_KEY="$CLI_KEY"
    elif [ "$NON_INTERACTIVE" -eq 1 ]; then
        PROBE_KEY="${OLD_AUTH_KEY:-}"
    else
        if [ -n "$OLD_AUTH_KEY" ]; then
            read -rsp "请输入 API Key [当前: $(mask_secret "$OLD_AUTH_KEY")] (回车保留已存密钥): " INPUT_KEY < /dev/tty || true
            printf '\n'
            PROBE_KEY="${INPUT_KEY:-$OLD_AUTH_KEY}"
        else
            read -rsp "请输入 API Key (存入 auth.json 0600，models.json 零明文): " PROBE_KEY < /dev/tty || true
            printf '\n'
        fi
    fi
fi

REMOTE_MODELS=""
printf '🔍 正在探测端点可用模型 (Provider: %s)...\n' "$TARGET_PROVIDER_ID"

if [ -n "$PROBE_KEY" ]; then
    RAW_RES=$(curl -sS -m 8 -w "\n%{http_code}" -H "Authorization: Bearer ${PROBE_KEY}" "${TARGET_URL}/models" 2>/dev/null || true)
else
    RAW_RES=$(curl -sS -m 8 -w "\n%{http_code}" "${TARGET_URL}/models" 2>/dev/null || true)
fi

HTTP_CODE=$(printf '%s\n' "$RAW_RES" | tail -n1)
BODY=$(printf '%s\n' "$RAW_RES" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    REMOTE_MODELS="$BODY"
    printf '✅ 上游端点鉴权探测成功 (HTTP 200)\n'
elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    printf '⚠️  端点鉴权未通过 (HTTP %s)，将按规范模板生成基础模型规格\n' "$HTTP_CODE"
else
    printf 'ℹ️  端点未返回模型列表 (HTTP %s 或未实现 /models 路由)\n' "${HTTP_CODE:-000}"
fi

TMP_MODELS_DEV="$(mktemp)"
trap 'rm -f "$TMP_MODELS_DEV"' EXIT
printf '🌐 正在拉取 models.dev 权威规格数据库...\n'
curl -sS -m 15 -o "$TMP_MODELS_DEV" "https://models.dev/api.json" 2>/dev/null || true

# ========================================================
# 阶段四：原子落盘 models.json 与凭据归位
# ========================================================

node - "$MODELS_FILE" "$AUTH_FILE" "$TARGET_PROVIDER_ID" "$TARGET_URL" "$FINAL_MODE" "$FINAL_BW_ITEM" "$PROBE_KEY" "$REMOTE_MODELS" "$TMP_MODELS_DEV" "$IS_EXISTING_PROVIDER" <<'NODE'
const fs = require("fs");
const [,, modelsPath, authPath, providerId, baseUrl, mode, bwItem, rawKey, rawRemote, modelsDevPath, isExistingStr] = process.argv;
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
    if (!id || /image|embed|tts|audio|whisper|batch|auto-review/i.test(id)) continue;

    const spec = findInModelsDev(id);
    const cw = item.context_window || item.max_context_tokens || item.max_model_len || spec?.limit?.context || 128000;
    const mt = item.max_output_tokens || item.max_completion_tokens || spec?.limit?.output || 16384;
    const reasoning = spec?.reasoning !== undefined
      ? Boolean(spec.reasoning)
      : /thinking|reasoning|think|-r1|luna|sol|o[134]|-high|-medium|-low/i.test(id);

    const rawInput = spec?.modalities?.input || ["text", "image"];
    const cleanInput = rawInput.filter(i => i === "text" || i === "image");

    const modelObj = {
      id,
      name: spec?.name || id,
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

if (models.length === 0) {
  let existingModels = [];
  if (isExisting && fs.existsSync(modelsPath)) {
    try {
      const oldCfg = JSON.parse(fs.readFileSync(modelsPath, "utf8"));
      existingModels = (oldCfg.providers?.[providerId]?.models || []).map(m => {
        const { api, ...rest } = m;
        return rest;
      });
    } catch(e) {}
  }

  if (existingModels.length > 0) {
    models = existingModels;
    console.log(`ℹ️  未探测到新模型列表，已完整保留既有的 ${models.length} 个模型规格`);
  } else {
    models.push({
      id: "claude-3-7-sonnet-20250219",
      name: "Claude 3.7 Sonnet",
      reasoning: true,
      input: ["text", "image"],
      contextWindow: 200000,
      maxTokens: 64000
    });
    console.log(`ℹ️  已注入通用标准模型规格`);
  }
} else {
  console.log(`✅ 匹配完成：已动态生成 ${models.length} 个模型的完整规格配置`);
}

let rootConfig = { providers: {} };
if (fs.existsSync(modelsPath)) {
  try { rootConfig = JSON.parse(fs.readFileSync(modelsPath, "utf8")) || { providers: {} }; } catch(e){}
}
if (!rootConfig.providers) rootConfig.providers = {};

const providerEntry = {
  baseUrl: baseUrl,
  api: "openai-completions",
  models
};

if (mode === "bw") {
  providerEntry.apiKey = `!bw get password ${bwItem}`;
}

rootConfig.providers[providerId] = providerEntry;
fs.writeFileSync(modelsPath, JSON.stringify(rootConfig, null, 2) + "\n");

let authConfig = {};
if (fs.existsSync(authPath)) {
  try { authConfig = JSON.parse(fs.readFileSync(authPath, "utf8")) || {}; } catch(e){}
}

if (mode === "direct" && rawKey) {
  authConfig[providerId] = {
    type: "api_key",
    key: rawKey
  };
  fs.writeFileSync(authPath, JSON.stringify(authConfig, null, 2) + "\n");
} else if (mode === "bw" && authConfig[providerId]) {
  delete authConfig[providerId];
  fs.writeFileSync(authPath, JSON.stringify(authConfig, null, 2) + "\n");
}
NODE

chmod 600 "$MODELS_FILE"
[ -f "$AUTH_FILE" ] && chmod 600 "$AUTH_FILE"

unset PROBE_KEY

# ========================================================
# 阶段五：设置默认供应商与默认模型
# ========================================================

SHOULD_SET_AS_DEFAULT_PROVIDER=0
if [ "$CLI_SET_DEFAULT" = "yes" ]; then
    SHOULD_SET_AS_DEFAULT_PROVIDER=1
elif [ -z "$EXISTING_DEFAULT_PROVIDER" ] || [ "$EXISTING_DEFAULT_PROVIDER" = "$TARGET_PROVIDER_ID" ]; then
    SHOULD_SET_AS_DEFAULT_PROVIDER=1
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    SHOULD_SET_AS_DEFAULT_PROVIDER=0
else
    read -rp "是否将 [${TARGET_PROVIDER_ID}] 设为默认供应商? [y/N] (当前默认: ${EXISTING_DEFAULT_PROVIDER}): " SET_DEF_INPUT < /dev/tty || true
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
        read -rp "默认模型 ID [当前: ${DEFAULT_MODEL:-claude-3-7-sonnet-20250219}] (回车保留): " INPUT_MODEL < /dev/tty || true
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
    printf '✅ 系统默认供应商已设为 [%s]，默认模型 [%s]\n' "$TARGET_PROVIDER_ID" "$CHOSEN_MODEL"
fi

printf '\n✅ 端点 [%s] 配置完成: %s\n' "$TARGET_PROVIDER_ID" "$TARGET_URL"
if [ "$FINAL_MODE" = "bw" ]; then
    printf '  - 凭证模式: Bitwarden 标志引用 (!bw get password %s)\n' "$FINAL_BW_ITEM"
    printf '  - models.json: 零明文落盘\n'
else
    printf '  - 凭证模式: Pi 原生金库 (仅保存于 auth.json 0600)\n'
    printf '  - models.json: 零明文落盘 (无 apiKey 字段，Pi 运行时自动回退匹配)\n'
fi
