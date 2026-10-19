# Pi

Pi 智能体（pi-coding-agent）全生命周期工程部署、端点模型纳管与检索套件基线。

## 一键部署与全量基线对齐

通过 `pi.sh` 单一主线脚本，一键完成环境依赖对齐、Git Bash 路径绑定、工程偏好固化、以及依托 `models.dev` 权威数据库即时补全端点模型规格（上下文上限、输出限制与计费参数）：

### 1. 多终端执行方式

- **Linux 终端（Bash）**：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi.sh | bash
  ```

- **Windows 工作站（pwsh）**：
  ```powershell
  sh.exe -c "curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi.sh | bash"
  ```

- **Windows Git Bash**：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi.sh | bash
  ```

> **本地执行**：在仓库根目录直接运行 `bash scripts/pi.sh`（pwsh 环境下运行 `sh.exe scripts/pi.sh`）。

### 2. 命令行静默调用速查

```bash
# 指定 Provider ID、端点 Base URL 与 Key，自动对齐全量基线
bash scripts/pi.sh -p cpa -u https://cpa.[HERE_DOMAIN]/v1 -k "[HERE_KEY]" -d -y
```

## 配置文件拓扑与受控权限

脚本执行后，在 `~/.pi/agent/` 生成三份职责分立的受控配置（物理权限严格锁定 `0600`）：

| 配置文件路径 | 受控职责与核心语义 | 规范契约 |
|---|---|---|
| `~/.pi/agent/settings.json` | 全局首选项、Git Bash 路径绑定 | 挂载官方 Settings Schema，关闭遥测与缓存预热 |
| `~/.pi/agent/models.json` | 兼容端点定义与可用模型规格（纯净元数据，绝无 `apiKey`） | 挂载官方 Models Schema，由 models.dev 补全上下文与计费 |
| `~/.pi/agent/auth.json` | 原生凭据存储（按 Provider ID 索引对应 API Key / Token） | 敏感凭据独立物理隔离，运行时内存直接匹配 |

## 扩展生态与规则注入

### 1. 多源检索扩展（pi-search）

挂载 Web 事实搜索、技术规范检索（`docs_search`）与网页抓取清洗（`web_fetch`）：

```bash
pi install git:github.com/justhil/pi-search
```

安装后启动 Pi，在会话中输入 `/search-config` 调出交互式菜单配置信源凭据与开关，配置自动落盘于 `~/.config/pi-search/config.json`。

### 2. 规则注入与层叠机制

Pi 通过不同维度的配置文件向模型注入约束，加载与生效顺序如下：

1. **系统设定追加（`.pi/APPEND_SYSTEM.md`）**：受信任项目向顶层 System Prompt 追加的硬性规则；
2. **用户全局规则（`~/.pi/agent/AGENTS.md`）**：跨项目生效的个人通用开发习惯与基线；
3. **项目工程规则（`./AGENTS.md`）**：从当前目录向上寻访父级目录，按由外至内的顺序层叠载入。
