# AGY StatusLine

极简、零第三方依赖、纯外部显示的 Google Antigravity CLI（`agy`）状态栏插件。

**前置条件**：Node.js 22.19+、已安装 `agy`。

## 1. 展示指标与口径

- **纯外部协议、零侵入**：通过 `agy` 原生 `statusLine` 协议从 `stdin` 读取会话 JSON，向 `stdout` 输出文本并始终正常退出（零报错、零中断、不干预 Agent 任何行为）。
- **零会话注入**：插件仅含 `plugin.json` 与运行时脚本，不携带 `skills/`、`rules/`、`hooks.json`、`mcp_config.json` 或 `sidecars/`，不向对话或系统提示词注入任何内容。
- **极简英文紧凑 UI（严格单行）**：纯数字 + 语义色（`Ctx`：`<60%` 青 / `60%–80%` 黄 / `>=80%` 红；`5h`/`Wk`：`>40%` 绿 / `15%–40%` 黄 / `<=15%` 红；`Est` 与冲突估值黄、常规校准后青），零中文、零 emoji 与进度条；插件自身**永远严格单行输出**（不换行、超宽硬截断防终端软折行），配合 `"stack_with_default": true` 固定呈 **原生 1 行 + 插件 1 行**。
  ```text
  # 采样中（~ 表示本机消费待配额刷新确认）
  Ctx 24.6% │ 5h 82.0%(2h10m) │ Wk 100.0%(4d12h) │ $0.35 │ Est ~$0.35/0.0%
  # 已校准（>= 0.5% 有效周跌幅后，~ 表示基于样本外推估值）
  Ctx 18.0% │ 5h 90.0%(4h43m) │ Wk 89.0%(5d18h) │ $2.20 │ ~$106.8/$120
  # 异常执行预警（统一走末尾槽位：宽屏与周估值共存，中窄屏优先替换周估值；idle 时自动降暗）
  Ctx 24.6% │ 5h 90.0%(4h43m) │ Wk 89.0%(5d18h) │ $3.40 │ ~$106.8/$120 │ ! Slow work 2m10s
  ```
- **唯一权威口径与去重策略**（`Ctx │ 5h │ Wk │ Cost │ Wk Est │ Alert`）：
  1. **内部配额池路由（跨行去重）**：依据 `model.id` 显式匹配池归属（`gemini` 覆盖 Gemini / Argon / Carbon / Neon / Hydrogen / Flash，`3p` 覆盖 Claude / GPT）并独立读写账本；因原生第一行已显示完整模型名，插件不再重复输出 `GEM`/`3P` 前缀；无法识别模型时不输出 `5h`/`Wk` 数值，也不写入池账本。
  2. **`Ctx`**：仅读取 `context_window.used_percentage`；缺失时显示 `Ctx --`，不使用备用字段推算。
  3. **`5h`**：仅读取 `remaining_fraction` 与 `reset_in_seconds`（周额度归零且 5h 标为 `disabled` 时显式显示 `0.0%`）；无 `remaining_fraction` 时显示 `5h --`，无 `reset_in_seconds` 时省略括号倒计时。
  4. **`Wk`**：同 `5h` 口径。
  5. **会话花费（`$X.XX` / `~$X.XX`）**：仅读取 `agy` 上报的 `cost.total_usd`（含子智能体）；当 `cost.estimated === true` 时前缀 `~`；未上报（如首轮回答前或企业级账户未开启服务端计费）时直接省略该列，不通过本地价表估算伪造花费。
  6. **周额度估值（`~$rem/$tot`、`~$rem?/$tot?` 或 `Est ...`）**：以本机观测到的有效配对样本（单批 `>= 0.2%`，累计一致跌幅 `>= 0.5%`）外推当前剩余与周期总额度等价美元。尚无任何本机样本时省略该列；支持 2 分钟配额/成本异步错峰配对与中位数一致簇离群剔除；一致簇未过半时标 `?`（黄色）提示估值不可信。
- **行尾统一异常告警槽位（直白英文、零查表、零阻断）**：
  - 上下文与配额危险度已通过红色粗体直出在对应数值上，行尾告警只专注捕捉**卡顿、循环与突发烧钱**（同一时刻仅展示最高优先级 1 条：`LOOP > TOOL/THK/WRK > BURN`；达到严重阈值时前缀升级为 `!!`）：
    - `! Loop 10 tools (2m10s)`（工具空转）：同回合未回 `idle` 且工具步数与时长越过宽限（`>=10` 次且 `>=120s`，或 `>=16` 次升级 `!!`）。
    - `! Slow tool 1m40s`（工具耗时过长）：`tool_use` 阶段跨步 `>= 90s`（`>= 180s` 升级 `!!`）。
    - `! Slow think 2m10s`（长思考）：`thinking` 阶段跨步 `>= 90s`（`>= 180s` 升级 `!!`）。
    - `! Slow work 2m10s`（工作阶段过长，结合 `$Cost` 判断是在生成还是卡顿等待）：`working` 阶段跨步 `>= 90s`（`>= 180s` 升级 `!!`）。
    - `! High spend +$1.80`（单回合/单步高消费）：累计消费陡增（已校准时 `>= max($0.80, 周总额 * 3%)`，未校准时 `>= $1.50`；`>= 2x` 升级 `!!`）。
  - **宽度让位与消退策略**：宽屏下与周估值共存；中窄屏优先由告警替换周估值槽位，再逐档收窄小数位、倒计时、`$Cost` 并缩略告警为 `! Slow work` / `! Loop 10 tools` / `! High spend`，最终按 `terminal_width` 安全截断防折行。进入 `idle` 等非活跃态后告警自动降暗（dim）保留显示，直到下一轮发起新请求或空闲满 10 分钟后消退。

## 2. 适用前提与约束

- **只影响用户判断、绝不干扰 Agent**：脚本完全被动接收 `stdin` 并在 `stdout` 展示结果；由于 `agy` 仅在状态/数据变更时触发 `statusLine`（300 ms 节流），彻底挂死无事件期间的实时进度与计时仍依赖 `agy` 原生界面及开启 `"stack_with_default": true` 后保留的内置第一行。
- **本机多开并发**：同一系统用户下多终端并发使用同账号时共享同一账本文件，通过原子文件锁合并各终端本地消费与配额掉额，互不覆盖。
- **非并发同账号多机接力**：上午在机器 A、下午在机器 B 非并发使用同一账号时，各机仅保留本机观测到的配对样本；跨机产生的空档掉额超过配对窗口后自动舍弃并推进基线，不触发虚假污染告警，两机相互零干扰。
- **同系统用户切换多账户**：当载荷提供 `email` 时，按邮箱单向哈希指纹与 `reset_time` 独立分槽（账本不落盘明文邮箱），跨账号及 `plan_tier` 升降档均互不污染与覆写；若省略 `email`，则回退为按 `reset_time` 分槽并在同周期额度回升时自动重置基线（无邮箱标识且两账号重置时间恰好相同时，若单价差异较大周估值将标 `?`）。

## 3. 精准安装与启用

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

因 `agy` 插件规范暂不支持在 `plugin.json` 内直接声明 `statusLine`，首次安装插件后须在 `~/.gemini/antigravity-cli/settings.json`（Windows 为 `%USERPROFILE%\.gemini\antigravity-cli\settings.json`）绑定已安装插件目录下的脚本（后续插件更新保留此配置）。示例开启 `"stack_with_default": true` 以保留内置第一行（快捷键提示、模型与思考强度、执行模式及任务/子智能体计数）；若希望仅显示本插件输出，省略该字段或设为 `false` 即可：

- **Linux / macOS `[bash]`**：
  ```json
  {
    "statusLine": {
      "type": "command",
      "command": "node $HOME/.gemini/config/plugins/agy-statusline/agy-statusline.mjs",
      "stack_with_default": true
    }
  }
  ```
- **Windows `[pwsh]`**：
  ```json
  {
    "statusLine": {
      "type": "command",
      "command": "node %USERPROFILE%/.gemini/config/plugins/agy-statusline/agy-statusline.mjs",
      "stack_with_default": true
    }
  }
  ```

> **Windows 注意**：`agy` 通过 `cmd /c` 调用状态栏命令并转义双引号，命令中避免使用双引号；若 `%USERPROFILE%` 含空格，请改用无空格固定路径并用正斜杠分隔。

## 4. 账本与环境变量

- 默认账本路径：`~/.gemini/antigravity-cli/statusline-ledger.json`（与插件目录分离，重装或更新插件不会清空历史基线）。
- `AGY_STATUSLINE_LEDGER`：可选环境变量，覆盖默认账本文件路径。
- `NO_COLOR`：设置非空值（如 `NO_COLOR=1`）时关闭 ANSI 颜色输出。
