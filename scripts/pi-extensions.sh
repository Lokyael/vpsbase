#!/usr/bin/env bash
#
# scripts/pi-extensions.sh
# Pi 个人扩展套件 (pi-search & pi-subagents) 部署与检索服务凭证配置脚本
#

set -Eeuo pipefail

SETTINGS_FILE="${HOME}/.pi/agent/settings.json"
CONFIG_FILE="${HOME}/.config/pi-search/config.json"

RECOMMENDED_SEARCH="git:github.com/justhil/pi-search"
RECOMMENDED_SUBAGENTS="npm:pi-subagents"

MODE="all" # all | install-only | config-only | update | uninstall
NON_INTERACTIVE=0

CLI_URL=""
CLI_KEY=""
CLI_MODEL=""
CLI_CTX7=""
CLI_EXA=""
CLI_TAVILY=""
CLI_FIRECRAWL=""

show_help() {
    cat <<'EOF'
用法:
  bash scripts/pi-extensions.sh [选项]

工作模式 (默认执行套件环境检查/安装并引导配置凭证):
  --install-only              仅检查并安装个人标准扩展套件，跳过检索配置
  --config-only               仅配置检索服务凭证，跳过扩展安装与环境检查
  --update                    升级已配置的扩展套件至最新版本 (pi update --extensions)
  --uninstall                 卸载个人标准扩展套件并可选项清理相关配置文件

检索配置参数 (非交互或命令行快速指定):
  -u, --url <url>             Search API 端点 Base URL
  -k, --key <key>             Search API Key 凭证
  -m, --model <id>            检索模型名称 (默认: gemini-2.0-flash 或沿用旧值)
  --context7-key <key>        Context7 API Key (官方文档检索增强，选配)
  --exa-key <key>             Exa API Key (高阶神经搜索，选配)
  --tavily-key <key>          Tavily API Key (事实类 AI 搜索，选配)
  --firecrawl-key <key>       Firecrawl API Key (动态网页正文清洗抓取，选配)

通用选项:
  -y, --non-interactive       非交互模式 (自动复用已有配置或安全默认值)
  -h, --help                  显示本帮助信息
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-only)
            MODE="install-only"
            shift
            ;;
        --config-only)
            MODE="config-only"
            shift
            ;;
        --update)
            MODE="update"
            shift
            ;;
        --uninstall)
            MODE="uninstall"
            shift
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
        --context7-key)
            CLI_CTX7="${2:-}"
            shift 2
            ;;
        --exa-key)
            CLI_EXA="${2:-}"
            shift 2
            ;;
        --tavily-key)
            CLI_TAVILY="${2:-}"
            shift 2
            ;;
        --firecrawl-key)
            CLI_FIRECRAWL="${2:-}"
            shift 2
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

command -v pi >/dev/null 2>&1 || { printf '❌ 未检测到 pi 命令，请先完成 Pi 基础安装\n' >&2; exit 1; }
command -v node >/dev/null 2>&1 || { printf '❌ 未检测到 node 命令，请先确保 Node.js 插件环境就绪\n' >&2; exit 1; }

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
# 模式处理：卸载与更新
# ========================================================

if [ "$MODE" = "uninstall" ]; then
    printf '🗑️  开始卸载个人标准扩展套件...\n'
    pi remove "$RECOMMENDED_SEARCH" 2>/dev/null || true
    pi remove "$RECOMMENDED_SUBAGENTS" 2>/dev/null || true
    printf '✅ 扩展套件卸载完成。\n'
    if [ -f "$CONFIG_FILE" ]; then
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            rm -f "$CONFIG_FILE"
            printf '🧹 已清理检索配置文件: %s\n' "$CONFIG_FILE"
        else
            read -rp "是否同时清理 pi-search 配置文件 ($CONFIG_FILE)? [y/N] " RM_CONF < /dev/tty || true
            if [[ "$RM_CONF" =~ ^[Yy]$ ]]; then
                rm -f "$CONFIG_FILE"
                printf '🧹 已清理检索配置文件: %s\n' "$CONFIG_FILE"
            fi
        fi
    fi
    exit 0
fi

if [ "$MODE" = "update" ]; then
    printf '🔄 正在检查并更新所有扩展套件至最新版本...\n'
    pi update --extensions
    printf '✅ 扩展套件更新完成。当前已配置扩展:\n'
    pi list
    exit 0
fi

# ========================================================
# 阶段一：扩展套件环境诊断与纯净安装
# ========================================================

if [ "$MODE" != "config-only" ]; then
    DIAGNOSTICS=$(node - "$SETTINGS_FILE" <<'NODE'
    const fs = require("fs");
    const [,, file] = process.argv;
    let packages = [];
    if (fs.existsSync(file)) {
      try {
        const data = JSON.parse(fs.readFileSync(file, "utf8"));
        if (Array.isArray(data.packages)) {
          packages = data.packages
            .map(p => typeof p === "string" ? p : (p && p.source ? p.source : ""))
            .filter(Boolean);
        }
      } catch(e) {}
    }

    const hasSearch = packages.some(p => p.includes("justhil/pi-search"));
    const hasSubagents = packages.some(p => p === "npm:pi-subagents" || p === "pi-subagents" || p.includes("pi-subagents"));
    const foreign = packages.filter(p => !p.includes("justhil/pi-search") && !p.includes("pi-subagents"));

    console.log(JSON.stringify({
      total: packages.length,
      hasSearch,
      hasSubagents,
      foreign,
      isClean: packages.length === 0,
      isStandardReady: hasSearch && hasSubagents && foreign.length === 0
    }));
NODE
)

    TOTAL_PKGS=$(node -e 'console.log(JSON.parse(process.argv[1]).total)' "$DIAGNOSTICS")
    HAS_SEARCH=$(node -e 'console.log(JSON.parse(process.argv[1]).hasSearch ? 1 : 0)' "$DIAGNOSTICS")
    HAS_SUBAGENTS=$(node -e 'console.log(JSON.parse(process.argv[1]).hasSubagents ? 1 : 0)' "$DIAGNOSTICS")
    FOREIGN_COUNT=$(node -e 'console.log(JSON.parse(process.argv[1]).foreign.length)' "$DIAGNOSTICS")
    IS_CLEAN=$(node -e 'console.log(JSON.parse(process.argv[1]).isClean ? 1 : 0)' "$DIAGNOSTICS")
    IS_READY=$(node -e 'console.log(JSON.parse(process.argv[1]).isStandardReady ? 1 : 0)' "$DIAGNOSTICS")

    if [ "$IS_READY" -eq 1 ]; then
        printf '✅ 个人标准扩展套件已就绪 (pi-search, pi-subagents)，跳过安装阶段。\n'
    elif [ "$FOREIGN_COUNT" -gt 0 ]; then
        printf '⚠️  检测到当前环境存在非标准扩展 (%d 个):\n' "$FOREIGN_COUNT"
        node - "$DIAGNOSTICS" <<'NODE'
        const data = JSON.parse(process.argv[2]);
        data.foreign.forEach(p => console.log(`   - ${p}`));
NODE
        printf '\n💡 为保障环境纯净与个人套件基线一致，本脚本仅在纯净环境或标准基线环境下执行一键安装。\n'
        printf '   如需手动移除外来扩展，请执行:\n'
        printf '     pi remove <扩展名>\n'
        printf '❌ 检测到非标扩展，已终止安装流程（未对环境做任何修改）。\n'
        exit 1
    else
        printf '📦 当前扩展环境纯净 (%d 个既有扩展)，开始部署个人标准套件...\n' "$TOTAL_PKGS"
        if [ "$HAS_SEARCH" -eq 0 ]; then
            printf '📦 正在安装检索扩展 (pi-search)...\n'
            pi install "$RECOMMENDED_SEARCH"
        fi
        if [ "$HAS_SUBAGENTS" -eq 0 ]; then
            printf '📦 正在安装多智能体协作扩展 (pi-subagents)...\n'
            pi install "$RECOMMENDED_SUBAGENTS"
        fi
        printf '✅ 标准套件安装完成。当前已配置扩展:\n'
        pi list
    fi
fi

if [ "$MODE" = "install-only" ]; then
    exit 0
fi

# ========================================================
# 阶段二：检索服务凭证配置 (pi-search)
# ========================================================

mkdir -p "$(dirname "$CONFIG_FILE")"

OLD_URL=""
OLD_KEY=""
OLD_MODEL=""
OLD_CTX7=""
OLD_EXA=""
OLD_TAVILY=""
OLD_FIRECRAWL=""

if [ -f "$CONFIG_FILE" ]; then
    PREV_JSON=$(node - "$CONFIG_FILE" <<'NODE'
    const fs = require("fs");
    const [,, file] = process.argv;
    try {
      const c = JSON.parse(fs.readFileSync(file, "utf8"));
      console.log(JSON.stringify({
        url: c.apiUrl || "",
        key: c.apiKey || "",
        model: c.model || "",
        ctx7: c.context7ApiKey || "",
        exa: c.exaApiKey || "",
        tavily: c.tavilyApiKey || "",
        fc: c.firecrawlApiKey || ""
      }));
    } catch(e) {
      console.log("{}");
    }
NODE
)
    OLD_URL=$(node -e 'console.log(JSON.parse(process.argv[1]).url || "")' "$PREV_JSON")
    OLD_KEY=$(node -e 'console.log(JSON.parse(process.argv[1]).key || "")' "$PREV_JSON")
    OLD_MODEL=$(node -e 'console.log(JSON.parse(process.argv[1]).model || "")' "$PREV_JSON")
    OLD_CTX7=$(node -e 'console.log(JSON.parse(process.argv[1]).ctx7 || "")' "$PREV_JSON")
    OLD_EXA=$(node -e 'console.log(JSON.parse(process.argv[1]).exa || "")' "$PREV_JSON")
    OLD_TAVILY=$(node -e 'console.log(JSON.parse(process.argv[1]).tavily || "")' "$PREV_JSON")
    OLD_FIRECRAWL=$(node -e 'console.log(JSON.parse(process.argv[1]).fc || "")' "$PREV_JSON")
fi

printf '\n⚙️  配置检索服务凭证 (pi-search):\n'

# 1. 核心 LLM 检索模型配置
TARGET_URL=""
TARGET_KEY=""
TARGET_MODEL=""

if [ -n "$CLI_URL" ]; then
    TARGET_URL="$CLI_URL"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    TARGET_URL="${OLD_URL:-}"
else
    read -rp "请输入 Search API 端点 [当前: ${OLD_URL:-未配置}] (直接回车保留): " INPUT_URL < /dev/tty || true
    TARGET_URL="${INPUT_URL:-$OLD_URL}"
fi

if [ -n "$CLI_KEY" ]; then
    TARGET_KEY="$CLI_KEY"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    TARGET_KEY="${OLD_KEY:-}"
else
    read -rsp "请输入 Search API Key [当前: $(mask_secret "$OLD_KEY")] (回车保留): " INPUT_KEY < /dev/tty || true
    printf '\n'
    TARGET_KEY="${INPUT_KEY:-$OLD_KEY}"
fi

DEFAULT_MODEL_VAL="${OLD_MODEL:-gemini-2.0-flash}"
if [ -n "$CLI_MODEL" ]; then
    TARGET_MODEL="$CLI_MODEL"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    TARGET_MODEL="$DEFAULT_MODEL_VAL"
else
    read -rp "请输入检索模型名称 [当前: ${DEFAULT_MODEL_VAL}] (直接回车保留): " INPUT_MODEL < /dev/tty || true
    TARGET_MODEL="${INPUT_MODEL:-$DEFAULT_MODEL_VAL}"
fi

# 2. 高阶外网信源凭证配置 (Context7 / Exa / Tavily / Firecrawl)
TARGET_CTX7="${CLI_CTX7:-$OLD_CTX7}"
TARGET_EXA="${CLI_EXA:-$OLD_EXA}"
TARGET_TAVILY="${CLI_TAVILY:-$OLD_TAVILY}"
TARGET_FIRECRAWL="${CLI_FIRECRAWL:-$OLD_FIRECRAWL}"

if [ "$NON_INTERACTIVE" -eq 0 ] && [ -z "$CLI_CTX7" ] && [ -z "$CLI_EXA" ] && [ -z "$CLI_TAVILY" ] && [ -z "$CLI_FIRECRAWL" ]; then
    printf '\n📋 高阶外网信源状态:\n'
    printf '   - Context7 API Key : %s\n' "$(mask_secret "$OLD_CTX7")"
    printf '   - Exa API Key      : %s\n' "$(mask_secret "$OLD_EXA")"
    printf '   - Tavily API Key   : %s\n' "$(mask_secret "$OLD_TAVILY")"
    printf '   - Firecrawl API Key: %s\n' "$(mask_secret "$OLD_FIRECRAWL")"

    read -rp "是否需要配置/修改高阶外部信源凭证? [y/N] (默认 N 跳过): " CONF_ADVANCED < /dev/tty || true
    if [[ "$CONF_ADVANCED" =~ ^[Yy]$ ]]; then
        read -rsp "请输入 Context7 API Key [当前: $(mask_secret "$OLD_CTX7")] (回车保留/留空跳过): " IN_CTX7 < /dev/tty || true
        printf '\n'
        TARGET_CTX7="${IN_CTX7:-$OLD_CTX7}"

        read -rsp "请输入 Exa API Key [当前: $(mask_secret "$OLD_EXA")] (回车保留/留空跳过): " IN_EXA < /dev/tty || true
        printf '\n'
        TARGET_EXA="${IN_EXA:-$OLD_EXA}"

        read -rsp "请输入 Tavily API Key [当前: $(mask_secret "$OLD_TAVILY")] (回车保留/留空跳过): " IN_TAVILY < /dev/tty || true
        printf '\n'
        TARGET_TAVILY="${IN_TAVILY:-$OLD_TAVILY}"

        read -rsp "请输入 Firecrawl API Key [当前: $(mask_secret "$OLD_FIRECRAWL")] (回车保留/留空跳过): " IN_FC < /dev/tty || true
        printf '\n'
        TARGET_FIRECRAWL="${IN_FC:-$OLD_FIRECRAWL}"
    fi
fi

# 3. 原子安全落盘
node - "$CONFIG_FILE" "$TARGET_URL" "$TARGET_KEY" "$TARGET_MODEL" "$TARGET_CTX7" "$TARGET_EXA" "$TARGET_TAVILY" "$TARGET_FIRECRAWL" <<'NODE'
const fs = require("fs");
const [,, filePath, apiUrl, apiKey, model, ctx7, exa, tavily, fc] = process.argv;

let current = {};
if (fs.existsSync(filePath)) {
  try { current = JSON.parse(fs.readFileSync(filePath, "utf8")); } catch(e){}
}

const config = {
  apiUrl: apiUrl || current.apiUrl || "",
  apiKey: apiKey || current.apiKey || "",
  apiProtocol: current.apiProtocol || "completions",
  model: model || current.model || "gemini-2.0-flash",
  thinkingLevel: current.thinkingLevel || "off",
  searchProfile: current.searchProfile || "auto",
  fallbackMode: current.fallbackMode || "auto",
  minimumProfile: current.minimumProfile || "standard",
  context7BaseUrl: current.context7BaseUrl || "https://context7.com",
  context7ApiKey: ctx7 || current.context7ApiKey || "",
  context7ResolveTtlHours: current.context7ResolveTtlHours || 168,
  context7DocsTtlHours: current.context7DocsTtlHours || 24,
  exaBaseUrl: current.exaBaseUrl || "https://api.exa.ai",
  exaApiKey: exa || current.exaApiKey || "",
  tavilyApiKey: tavily || current.tavilyApiKey || "",
  firecrawlApiKey: fc || current.firecrawlApiKey || ""
};

fs.writeFileSync(filePath, JSON.stringify(config, null, 2) + "\n");
NODE

chmod 600 "$CONFIG_FILE"
printf '✅ pi-search 配置已落盘: %s\n' "$CONFIG_FILE"
printf '💡 提示：在 Pi 会话内输入 /search-config 可随时调出图形化配置菜单\n'
