# Pi

Pi（pi-coding-agent）兼容端点配置与工程基线。

## 一键部署与全量基线对齐

`pi.sh` 以端点模型 ID 和 models.dev 规格生成固定 `openai-completions` 配置，并就绪依赖、绑定 Bash、设置工程偏好。

端点须支持 Chat Completions 与 `/models`。依赖为 Node.js 22.19+、curl、Pi、ripgrep 和 fd；Windows 使用 Scoop，Linux 已有 paru 时以 `--needed` 对齐 Pi、ripgrep 与 fd，安装失败即停止。

### 1. 多终端执行方式

- **Linux 终端（Bash）**：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/pi/pi.sh | bash
  ```

- **Windows 工作站（pwsh）**：
  ```powershell
  sh.exe -c "curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/pi/pi.sh | bash"
  ```

- **Windows Git Bash**：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/pi/pi.sh | bash
  ```

> **本地执行**：在仓库根目录直接运行 `bash tools/pi/pi.sh`（pwsh 环境下运行 `sh.exe tools/pi/pi.sh`）。

### 2. 命令行静默调用速查

```bash
# 复用该 Provider 的已有 Key，不在命令行填写凭据
bash tools/pi/pi.sh -p cpa -u https://cpa.[HERE_DOMAIN]/v1 -y
```

## 模型发现与配置更新边界

- **模型与规格**：读取端点 `/models` 并过滤非聊天候选，使用 models.dev 规格。选定 Provider 整体替换，包括旧协议、headers、compat 和覆写；其他 Provider 保留。发现失败、无候选模型、规格目录获取或校验失败时停止，不修改 models.json、auth.json、settings.json，也不拿旧列表代替。未匹配到规格的模型仍保留 ID、缺失字段省略；参考限制和价格不代表网关能力或账单。
- **默认模型**：脚本不选择、不写入，已有默认保留。在 Pi `/model` 中选择并按 `Ctrl+S` 保存。自建网关宜用独立 Provider ID；内置 ID 会叠加 Pi 内置目录。
- **连接输入**：先选 Provider，再读取 URL／Key，回车保留，取消停止。只复用字面量 Key；优先隐藏输入，避免用 `--key` 将明文放入历史或进程参数。
- **写入与失败**：已有配置损坏或不可读时停止。预检通过后才写候选并逐文件替换；落盘阶段失败可能已有部分文件替换，以完成范围提示为准，不自动回滚或备份。

依赖安装可能先于发现执行。避免与 Pi 并发改写配置；列表过滤和离线校验不证明推理或工具调用可用。

## 配置文件拓扑与受控权限

默认目录 `~/.pi/agent/`，可由 `PI_CODING_AGENT_DIR` 覆盖。新文件／目录模式为 `0600`／`0700`；Windows 访问边界取决于 ACL。

| 文件 | 职责 |
|---|---|
| `settings.json` | 工程偏好、Bash 路径；保留默认模型 |
| `models.json` | 端点与模型规格；目标 Provider 不写 `apiKey` |
| `auth.json` | Key 非空时更新目标项，否则不改；保留其他凭据 |

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
