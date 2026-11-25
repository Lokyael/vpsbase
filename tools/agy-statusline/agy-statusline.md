# AGY StatusLine

极简、零第三方依赖、纯外部显示的 Google Antigravity CLI（`agy`）状态栏插件。

**前置条件**：Node.js 22.19+、已安装 `agy`。

## 1. 展示指标与口径

- **纯外部协议**：通过 `agy` 原生 `statusLine` 协议从 `stdin` 读取会话 JSON，向 `stdout` 输出单行文本并退出。
- **零会话注入**：插件仅含 `plugin.json` 与运行时脚本，不携带 `skills/`、`rules/`、`hooks.json`、`mcp_config.json` 或 `sidecars/`，不向对话或系统提示词注入任何内容。
- **核心输出字段**：
  1. `Ctx`：当前会话上下文占用百分比（优先读 `context_window.used_percentage`，缺失时由 `context_window_size` 与 `current_usage` 兜底）。
  2. `5h`：当前 5 小时配额窗口剩余 / 已用百分比与重置倒计时（周额度归零且 5h 标为 `disabled` 时显示 `余0.0%/用100.0%`）。
  3. `周`：当前周配额窗口剩余 / 已用百分比与重置倒计时。
  4. `周估`：按模型池（`gemini` / `argon` / `carbon` / `3p`）统计本地等效花费与周配额有效跌幅；有效跌幅达到 $\ge 0.5\%$ 后输出 `周估 ≈$fullUsd (余$remUsd · ~X.XM eqIn)`（以当前模型标准 Input 单价归一化等价可用 Token）；优先取 `cost.total_usd`，缺失时回退到本地阶梯价表加权估算，并过滤无本地消费增量但周跌幅 $\ge 0.3\%$ 的异地消耗。

## 2. 精准安装与启用

### 1. 从 GitHub 仓库直接安装插件

无需整仓克隆，直接指定公开仓库子目录 URL 安装（仅拉取 `tools/agy-statusline/` 内的运行文件）：

```bash
agy plugin install https://github.com/Lokyael/vpsbase/tree/main/tools/agy-statusline
```

> 若从本地克隆调试安装，则在仓库根目录执行 `agy plugin install ./tools/agy-statusline`。

安装后可通过以下命令确认状态、更新或卸载：

```bash
# 查看已安装插件列表
agy plugin list

# 覆盖更新（重新执行安装即可；不会覆盖用户 settings.json 或周账本）
agy plugin install https://github.com/Lokyael/vpsbase/tree/main/tools/agy-statusline

# 卸载插件
agy plugin uninstall agy-statusline
```

插件统一安装至：
- **Linux / macOS**：`~/.gemini/config/plugins/agy-statusline/`
- **Windows**：`%USERPROFILE%\.gemini\config\plugins\agy-statusline\`

### 2. 绑定 `statusLine`（仅首次安装执行一次）

因 `agy` 插件规范暂不支持在 `plugin.json` 内直接声明 `statusLine`，首次安装插件后须在 `~/.gemini/antigravity-cli/settings.json`（Windows 为 `%USERPROFILE%\.gemini\antigravity-cli\settings.json`）绑定已安装插件目录下的脚本（后续插件更新保留此配置）：

- **Linux / macOS `[bash]`**：
  ```json
  {
    "statusLine": {
      "type": "command",
      "command": "node $HOME/.gemini/config/plugins/agy-statusline/agy-statusline.mjs"
    }
  }
  ```
- **Windows `[pwsh]`**：
  ```json
  {
    "statusLine": {
      "type": "command",
      "command": "node %USERPROFILE%/.gemini/config/plugins/agy-statusline/agy-statusline.mjs"
    }
  }
  ```

> **Windows 注意**：`agy` 通过 `cmd /c` 调用状态栏命令并转义双引号，命令中避免使用双引号；若 `%USERPROFILE%` 含空格，请改用无空格固定路径并用正斜杠分隔。

## 3. 账本与环境变量

- 默认账本路径：`~/.gemini/antigravity-cli/statusline-ledger.json`（与插件目录分离，重装或更新插件不会清空历史基线）。
- `AGY_STATUSLINE_LEDGER`：可选环境变量，覆盖默认账本文件路径。
