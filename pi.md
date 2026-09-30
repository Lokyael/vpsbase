# Pi

Linux Headless 终端环境下 Pi 智能体（pi-coding-agent）的安装部署、模型端点配置、扩展套件与多智能体协作环境。

## 基础环境安装

前置依赖：已按 [archlinux.md](archlinux.md) 选配就绪 `paru` 与 `fnm`（Node.js LTS 插件环境）。

整段复制执行。校验基础环境并静默安装 Pi 二进制与代码检索依赖：

```bash
(
set -euo pipefail

command -v paru >/dev/null 2>&1 || { printf '❌ 未检测到 paru，请先参考 archlinux.md 完成基础选配\n' >&2; exit 1; }
command -v fnm  >/dev/null 2>&1 || { printf '❌ 未检测到 fnm，请先参考 archlinux.md 启用 Node.js (fnm)\n' >&2; exit 1; }

paru -S --needed --noconfirm --skipreview pi-coding-agent-bin ripgrep

printf '✅ Pi 主体就绪: %s\n' "$(pi --version)"
printf '✅ Node 插件环境 (fnm): %s (npm %s)\n' "$(node -v)" "$(npm -v)"
)
```

## 模型端点与凭证配置

适用于兼容反向代理、聚合网关或本地服务（Ollama / vLLM）。配置后即完成核心闭环，可独立进行日常开发对话。

支持两种凭证安全模式（`models.json` 均零明文落盘）：
- **Bitwarden 模式**：`models.json` 写入 `!bw get password <item>` 标志引用，详见 [secrets.md](secrets.md)；
- **Pi 原生金库模式**：密钥存入 `auth.json`（权限 `0600`），`models.json` 彻底移除 `apiKey`，Pi 运行时自动回退匹配。

整段复制执行。自动下载配置脚本并动态匹配参数，执行后自动清理临时文件：

```bash
(
set -Eeuo pipefail

SCRIPT_FILE=$(mktemp)
trap 'rm -f "$SCRIPT_FILE"' EXIT

curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-models.sh -o "$SCRIPT_FILE"
bash "$SCRIPT_FILE"
)
```

常用 CLI 选项与速查：

```bash
# 查看端点配置脚本全部选项
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-models.sh | bash -s -- -h

# 命令行指定 Bitwarden 标志引用模式
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-models.sh | bash -s -- -p cpa -u https://cpa.[DOMAIN]/v1 --mode bw -b cpa

# 命令行指定原生金库模式 (密钥存入 auth.json)
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-models.sh | bash -s -- -p cpa -u https://cpa.[DOMAIN]/v1 --mode direct -k "[KEY]"
```

## 扩展套件与检索配置

在核心智能体基础上，组合多源检索引擎与独立上下文子智能体，打造低摩擦通用助手环境：

```text
Pi 原生（低摩擦通用主控：日常命令执行、代码生成与主会话管理）
├── justhil/pi-search（多源网络与文档检索引擎）
│   ├── search（AI 深度搜索）
│   ├── docs_search（官方规范与权威库检索）
│   ├── web_fetch（网页正文抓取与智能降级清洗）
│   └── 底层信源（Context7 / Exa / Tavily / Firecrawl）
└── pi-subagents（独立上下文多智能体协作）
    ├── scout（代码库快速侦察：定位关键路径与调用链，只读压缩上下文）
    ├── researcher（外网事实与多源调研：调用检索工具输出高密度简报）
    ├── reviewer（代码质量审查：排查逻辑缺陷、边缘异常与过度设计）
    └── oracle（决策质询与架构评估：提供第二意见，风险攻防与假设挑战）
```

整段复制执行。自动校验纯净扩展环境，一键部署个人标准套件（`pi-search` 与 `pi-subagents`）：

```bash
(
set -Eeuo pipefail

SCRIPT_FILE=$(mktemp)
trap 'rm -f "$SCRIPT_FILE"' EXIT

curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-extensions.sh -o "$SCRIPT_FILE"
bash "$SCRIPT_FILE"
)
```

### 检索服务配置 (/search-config)

套件部署完成后，支持两种配置模式：
- **Bitwarden CLI 自动化模式（推荐）**：前置已按 [secrets.md](secrets.md) 录入信源对应条目，解锁保密库后执行脚本自动从内存提取并静默填充，全链路零明文；
- **Pi 会话内图形交互模式**：启动 Pi 后直接输入 `/search-config` 调出交互式图形菜单，按需手工输入各检索信源。

| 信源 / 选项 | 默认 Base URL / 端点 | 核心定位与用途 | 必要性 | Bitwarden 条目名 |
|---|---|---|---|---|
| **Search API** | 自定义（兼容 OpenAI 端点） | 用于对检索内容进行结构化提炼的 LLM 端点（支持 Gemini / DeepSeek 等） | **必选**（检索基础） | `cpa` |
| **Context7** | `https://context7.com` | 官方技术库与规范文档检索，自动版本适配并本地缓存 | 选配（开发文档增强） | `search-context7` |
| **Exa** | `https://api.exa.ai` | 高阶 AI 神经搜索引擎，精准获取前沿技术博文与社区深度见解（支持中转代理） | 选配（技术事实调研） | `search-exa` |
| **Tavily** | `https://api.tavily.com` | 事实类 AI 搜索引擎，快速聚合实时新闻与时效事实 | 选配（时效资讯查证） | `search-tavily` |
| **Firecrawl** | `https://api.firecrawl.dev` | 动态网页清洗抓取，智能剔除广告与噪点，提取干净 Markdown | 选配（正文分析抓取） | `search-firecrawl` |

配置说明：
- **Exa Base URL**：官方直连端点为 `https://api.exa.ai`（默认直接回车保留）。

常用 CLI 命令与维护速查：

```bash
# 查看已配置扩展
pi list

# Bitwarden CLI 自动化静默配置 (需先执行 export BW_SESSION=$(bw unlock --raw))
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-extensions.sh | bash -s -- --config-only -y

# 交互式向导配置 (自动以已存凭据或 bw 条目为默认值，支持回车确认或微调)
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-extensions.sh | bash -s -- --config-only

# 命令行显式指定参数 (配合 bw 动态提取注入)
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-extensions.sh | bash -s -- --config-only \
-u https://cpa.[DOMAIN]/v1 \
-k "$(bw get password cpa)" \
--exa-key "$(bw get password search-exa)"

# 全局更新已配置的扩展套件至最新版
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-extensions.sh | bash -s -- --update

# 卸载个人标准套件
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-extensions.sh | bash -s -- --uninstall
```

## 多智能体协作分工

直接在 Pi 主会话中以自然语言调度子智能体，隔离上下文，保障主会话低摩擦：

| 智能体 | 核心定位与职责 | 自然语言触发范例 |
|---|---|---|
| `scout` | **快速勘探**：只读遍历代码库结构、定位调用链与关键路径，输出压缩上下文摘要。 | `让 scout 梳理身份验证模块的调用链路与依赖关系` |
| `researcher` | **深度调研**：联动 `pi-search` 检索外网权威文档与技术规范，产出结构化事实简报。 | `让 researcher 调研 [库名] 最新版本的破坏性变更与迁移指引` |
| `reviewer` | **代码复查**：针对工作区或 Git Diff 做细致代码审查，排查逻辑缺陷、边缘异常与过度设计。 | `让 reviewer 审查本次提交的 diff，重点检查资源泄漏与边界异常` |
| `oracle` | **决策质询**：技术方案设计与架构选型时的“第二意见”，挑战既有假设，开展攻防推演，不直接修改代码。 | `让 oracle 评估当前方案的可行性并挑战假设` |

进阶协作模式：

- **并行执行（批量任务）**：`并行运行 2 个 scout，分别排查端点路由与数据模型`
- **链式流水线（调研到质询）**：`先让 researcher 调研最新规范，再让 oracle 评估方案风险`
- **后台自主推进**：耗时任务自动转入后台执行，主会话可继续交互，完成后按提示唤回核对。

## 持续运行与状态通知 (herdr + ntfy)

基于 `herdr` 实现 SSH 断联会话保活，选配自建私有 `ntfy` 在任务阻塞（`blocked`）与结算（`done`）时异步推送通知。

整段复制执行。自动安装 `herdr-bin`，按向导选配自建 ntfy 状态监控（若无需通知直接跳过）：

```bash
(
set -Eeuo pipefail

SCRIPT_FILE=$(mktemp)
trap 'rm -f "$SCRIPT_FILE"' EXIT

curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-herdr.sh -o "$SCRIPT_FILE"
bash "$SCRIPT_FILE"
)
```

常用 CLI 命令与维护速查：

```bash
# 启动或连入会话 (SSH 断开不影响后台任务)
herdr

# 快捷分离会话: Ctrl+B 然后按 q

# 仅更新/配置自建 ntfy 状态通知服务 (选配)
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-herdr.sh | bash -s -- --config-ntfy

# 仅安装 herdr (跳过 ntfy 配置)
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-herdr.sh | bash -s -- --skip-ntfy

# 查看通知监控服务状态
systemctl --user status herdr-ntfy

# 卸载监控服务与相关配置
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-herdr.sh | bash -s -- --uninstall
```

