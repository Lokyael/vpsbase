# Pi

Pi（pi-coding-agent 1.5.2）端点配置、工具链就绪与扩展参考。

**前置条件**：Node.js 22.19+、curl；接入端点须提供 `/models` 与 Chat Completions 接口。请勿在运行脚本时与 Pi 并发改写配置。

## 1. 部署与端点配置

- **Linux `[bash]`**：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/pi/pi.sh | bash
  ```
- **Windows `[pwsh]`**：
  ```powershell
  sh.exe -c "curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/pi/pi.sh | bash"
  ```

**交互流程**：
1. 选择目标 Provider，输入 URL 与 API Key（直接回车保留已有值，取消即停止）。
2. 若发现严格小写 `gpt-` 模型，逐一确认协议（回车探测 / `n` 用 Chat Completions / `y` 用 Responses API）。
3. 脚本不写入默认模型；完成后在 Pi 会话输入 `/model` 选择模型并按 `Ctrl+S` 保存。

## 2. 配置文件与结果核验

默认配置目录 `~/.pi/agent/`（可用 `PI_CODING_AGENT_DIR` 覆盖；新文件权限 `0600`/`0700`）：

| 文件 | 作用 |
| :--- | :--- |
| `settings.json` | 写入个人偏好与 Schema（Windows 缺失 `shellPath` 时自动补全），保留其他设置 |
| `models.json` | 写入选定 Provider 的模型规格（不写 `apiKey`），保留其他 Provider |
| `auth.json` | Key 非空时更新目标凭据，保留其他凭据 |

> 模型发现、目录拉取或探测失败时停止，不修改原有配置文件。

## 3. 扩展与规则层叠

- **多源检索扩展（pi-search）**：
  ```bash
  pi install git:github.com/justhil/pi-search
  ```
  启动 Pi 后输入 `/search-config` 配置信源（保存于 `~/.config/pi-search/config.json`）。
- **约束文件加载顺序**：`.pi/APPEND_SYSTEM.md`（项目追加系统提示）→ `~/.pi/agent/AGENTS.md`（全局规则）→ `./AGENTS.md`（按目录由外至内层叠）。
