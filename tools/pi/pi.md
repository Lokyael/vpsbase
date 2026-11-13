# Pi

Pi（pi-coding-agent）兼容端点配置与工程基线。

## 一键部署与全量基线对齐

Pi 版本 1.5.2。`pi.sh` 以端点模型 ID 和 models.dev 规格生成配置并就绪依赖。Provider 默认使用 `openai-completions`；严格小写 `gpt-` 模型可由用户确认或探测后改用模型级 `openai-responses`。脚本同时应用本人的 Pi 偏好，并逐项报告与 Pi 原生默认值的差异。

端点须提供 `/models` 和 Chat Completions；Responses 探测仅用于用户选择的 `gpt-` 模型，正式模型规格仍来自 models.dev。依赖为 Node.js 22.19+、curl、Pi、ripgrep 和 fd；Windows 使用 Scoop，Linux 已有 paru 时以 `--needed` 对齐 Pi、ripgrep 与 fd，安装失败即停止。

### 执行方式

- **Linux 终端（Bash）**：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/pi/pi.sh | bash
  ```

- **Windows 工作站（pwsh）**：
  ```powershell
  sh.exe -c "curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/pi/pi.sh | bash"
  ```

## 模型发现与配置更新边界

- **模型与规格**：读取并过滤 `/models` 候选，使用 models.dev 规格。Provider 默认使用 `openai-completions`；严格小写 `gpt-` 模型逐个选择回车探测、`n` 保持 Chat Completions 或 `y` 使用 Responses。选定 Provider 整体替换，其他 Provider 保留；发现失败、无候选模型、规格目录获取或校验失败时不修改 models.json、auth.json、settings.json；Responses 能力未知或规格无效时停止，不用旧列表代替。未匹配到规格的模型仍保留 ID，目录限制和价格不代表网关能力或账单。
- **默认模型**：脚本不选择、不写入，已有默认保留。在 Pi `/model` 中选择并按 `Ctrl+S` 保存。自建网关宜用独立 Provider ID；内置 ID 会叠加 Pi 内置目录。
- **连接输入**：先选 Provider，再读取 URL／Key；回车保留，取消或终端不可用时停止。只复用字面量 Key，凭据经 stdin 传给临时 Node 进程。
- **`settings.json` 管理**：读取后先做结构校验，再保留未知字段、默认 Provider／模型、工具、扩展和项目相关设置；脚本的个人偏好会覆盖对应字段，重复运行会重新应用。成功后输出每项偏好、Pi 原生默认值及简要影响：高推理级别、静默启动、关闭安装遥测、关闭缓存预热、关闭自动压缩、关闭终端图片与 Mermaid。仅维护 `$schema`；Windows 上仅在没有 `shellPath` 时写入已验证的 Bash 路径，已有路径只校验不替换。
- **探测与失败**：默认协议不由模型目录代证。Responses 探测覆盖 SSE、消息角色、输出上限和函数工具续接；只有明确判定端点或模型不支持时才使用 Chat Completions，其他未知结果均阻断。兼容字段写入模型级 `compat`；工具能力不足不取消已确认的 Responses API。已有配置损坏时停止；预检通过后才逐文件替换，落盘阶段失败可能已有部分文件替换，按完成范围报告，不自动回滚。

依赖安装可能先于发现执行。避免与 Pi 并发改写配置；列表过滤和离线校验不证明端点能力。

## 配置文件拓扑与受控权限

默认目录 `~/.pi/agent/`，可由 `PI_CODING_AGENT_DIR` 覆盖。新文件／目录模式为 `0600`／`0700`；Windows 访问边界取决于 ACL。

| 文件 | 职责 |
|---|---|
| `settings.json` | 应用上述个人偏好和 Schema；Windows 缺失时补写检测到的 `shellPath`，保留其他设置 |
| `models.json` | 端点与模型规格；目标 Provider 不写 `apiKey` |
| `auth.json` | Key 非空时更新目标项，否则不改；保留其他凭据 |

## 扩展生态与规则注入

### 多源检索扩展（pi-search）

挂载 Web 事实搜索、技术规范检索（`docs_search`）与网页抓取清洗（`web_fetch`）：

```bash
pi install git:github.com/justhil/pi-search
```

安装后启动 Pi，在会话中输入 `/search-config` 调出交互式菜单配置信源凭据与开关，配置自动落盘于 `~/.config/pi-search/config.json`。

### 规则注入与层叠机制

Pi 通过不同维度的配置文件向模型注入约束，加载与生效顺序如下：

1. **系统设定追加（`.pi/APPEND_SYSTEM.md`）**：受信任项目向顶层 System Prompt 追加的硬性规则；
2. **用户全局规则（`~/.pi/agent/AGENTS.md`）**：跨项目生效的个人通用开发习惯与基线；
3. **项目工程规则（`./AGENTS.md`）**：从当前目录向上寻访父级目录，按由外至内的顺序层叠载入。
