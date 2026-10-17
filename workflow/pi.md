# Pi

Pi 智能体（pi-coding-agent）部署、端点配置、扩展套件。

## 基础环境安装

### 1. Linux 终端环境（AUR）

依赖 AUR 包管理器（如 `paru`）与 Node.js 运行环境。安装 Pi 智能体与检索依赖：

```bash
(
set -euo pipefail

command -v paru >/dev/null 2>&1 || { printf '❌ 未检测到 paru 包管理器，请先就绪 AUR 环境\n' >&2; exit 1; }
command -v node >/dev/null 2>&1 || { printf '❌ 未检测到 Node.js 运行环境，请先就绪 Node.js LTS（建议 fnm）\n' >&2; exit 1; }

paru -S --needed --noconfirm --skipreview pi-coding-agent-bin ripgrep fd

printf '✅ Pi 主体就绪: %s\n' "$(pi --version)"
printf '✅ Node 插件环境: %s (npm %s)\n' "$(node -v)" "$(npm -v)"
)
```

### 2. Windows 工作站环境（Scoop）

依赖 Scoop 包管理器与 Git Bash 终端环境。安装 Pi 智能体、检索依赖并绑定 Git Bash 路径：

```bash
(
set -euo pipefail

command -v scoop >/dev/null 2>&1 || { printf '❌ 未检测到 scoop 命令，请先就绪 Scoop 包管理器环境\n' >&2; exit 1; }

scoop install git nodejs-lts pi-coding-agent ripgrep fd

GIT_PREFIX=$(scoop prefix git 2>/dev/null || true)
if [[ -n "$GIT_PREFIX" && -f "$GIT_PREFIX/bin/bash.exe" ]]; then
    BASH_PATH="$(cygpath -m "$GIT_PREFIX")/bin/bash.exe"
else
    BASH_PATH="$(cygpath -m "$(which bash)")"
fi

AGENT_DIR="${HOME}/.pi/agent"
mkdir -p "$AGENT_DIR"
SETTINGS_FILE="${AGENT_DIR}/settings.json"

node - "$SETTINGS_FILE" "$BASH_PATH" <<'NODE'
const fs = require("fs");
const [,, settingsPath, shellPath] = process.argv;
let settings = {};
try {
  settings = JSON.parse(fs.readFileSync(settingsPath, "utf8").replace(/^\uFEFF/, ""));
} catch (e) {}

settings.shellPath = shellPath;

if (!settings.defaultThinkingLevel) {
  Object.assign(settings, {
    defaultThinkingLevel: "high",
    theme: "system",
    cacheWarming: "off",
    quietStartup: true,
    enableInstallTelemetry: false,
    compaction: { enabled: false },
    terminal: { showImages: false },
    markdown: { mermaid: "off" }
  });
}

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n", "utf8");
NODE

printf '✅ settings.json 已绑定 Git Bash: %s\n' "$BASH_PATH"
printf '✅ Pi 主体就绪: %s\n' "$(pi --version)"
printf '✅ Node 插件环境: %s (npm %s)\n' "$(node -v)" "$(npm -v)"
)
```

## 核心配置：Provider、模型与 Pi 偏好

通过 `pi-provider.sh` 配置 Provider、模型端点与偏好，支持两种零明文模式：
- **Bitwarden 模式**：Bitwarden CLI 运行时从内存动态注入，磁盘零明文；
- **Pi 原生金库模式**：密钥存入 `auth.json`（`0600`），`models.json` 零明文。

终端执行（兼容 Linux / Windows Git Bash）：

```bash
(
set -Eeuo pipefail

SCRIPT_FILE=$(mktemp)
trap 'rm -f "$SCRIPT_FILE"' EXIT

curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-provider.sh -o "$SCRIPT_FILE"
bash "$SCRIPT_FILE"
)
```

常用 CLI 选项与速查：

```bash
# 查看端点配置脚本全部选项
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-provider.sh | bash -s -- -h

# Bitwarden 标志引用模式 (models.json 写入动态引用)
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-provider.sh | bash -s -- -p cpa -u https://cpa.[HERE_DOMAIN]/v1 --mode bw -b cpa

# Pi 原生金库模式 (密钥存入 auth.json 0600)
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-provider.sh | bash -s -- -p cpa -u https://cpa.[HERE_DOMAIN]/v1 --mode direct -k "[HERE_KEY]"
```

## 扩展套件与检索配置

组合多源检索工具与独立上下文子智能体：

```text
Pi 原生（低摩擦通用主控：日常命令执行、代码生成与主会话管理）
├── justhil/pi-search（多源网络与文档检索引擎）
│   ├── search（AI 深度搜索）
│   ├── docs_search（官方规范与权威库检索）
│   ├── web_fetch（网页正文抓取与智能降级清洗）
│   └── 底层信源（Context7 / Exa / Tavily / Firecrawl）
└── pi-subagents（独立上下文多智能体协作）
    ├── scout（代码库快速侦察：定位关键路径与调用链，只读压缩上下文）
    ├── researcher（互联网公开事实与多源技术调研：调用检索工具输出高密度简报）
    ├── reviewer（代码质量审查：排查逻辑缺陷、边缘异常与过度设计）
    └── oracle（决策质询与架构评估：提供第二意见，风险攻防与假设挑战）
```

终端执行（兼容 Linux / Windows Git Bash）。部署标准扩展套件（`pi-search` 与 `pi-subagents`）：

```bash
(
set -Eeuo pipefail

SCRIPT_FILE=$(mktemp)
trap 'rm -f "$SCRIPT_FILE"' EXIT

curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-addons.sh -o "$SCRIPT_FILE"
bash "$SCRIPT_FILE"
)
```

### 检索服务配置（/search-config）

支持通过 BW 自动化静默配置或 Pi 会话内输入 `/search-config` 交互配置：

| 信源 / 选项 | 默认 Base URL / 端点 | 核心定位与用途 | 必要性 | Bitwarden 条目名 |
|---|---|---|---|---|
| **Search API** | 自定义（兼容 OpenAI 端点） | 提炼检索结果的 LLM 端点 | **必选**（检索基础） | `cpa` |
| **Context7** | `https://context7.com` | 官方技术库与规范文档检索 | 选配（开发文档增强） | `search-context7` |
| **Exa** | `https://api.exa.ai` | AI 神经搜索引擎，精准事实调研 | 选配（技术事实调研） | `search-exa` |
| **Tavily** | `https://api.tavily.com` | 事实类 AI 搜索引擎，时效资讯检索 | 选配（时效资讯查证） | `search-tavily` |
| **Firecrawl** | `https://api.firecrawl.dev` | 动态网页清洗抓取，提取干净 Markdown | 选配（正文分析抓取） | `search-firecrawl` |

常用 CLI 命令与维护速查：

```bash
# 查看已配置扩展
pi list

# 交互式向导配置 (自动以已有凭据或 bw 条目为默认值，支持回车确认)
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-addons.sh | bash -s -- --config-only

# Bitwarden CLI 自动化静默配置 (需预先执行 export BW_SESSION=$(bw unlock --raw))
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-addons.sh | bash -s -- --config-only -y

# 全局更新扩展套件至最新版
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-addons.sh | bash -s -- --update

# 卸载扩展套件
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-addons.sh | bash -s -- --uninstall
```
