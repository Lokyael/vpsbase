# Secrets

基于自建 Vaultwarden 与 Bitwarden CLI (`bw`) 的凭据管理中枢、权限隔离体系与智能体零明文调用规范。

## 架构与安全隔离矩阵

按执行主体与信任等级划分隔离域，机器端实行**集合（Collection）与受限服务账号 1:1 绑定**，杜绝跨域横向移动：

| 资产集合 (Collection) | 专属受限账号 | 授权运行实体 | 权限 | 纳管凭证类型 | 隔离安全目标 |
|---|---|---|---|---|---|
| **`llm`** (模型交互) | `svc-llm@[DOMAIN]` | Pi 智能体宿主机、Windows 开发机 | **只读** | CPA 密钥 (`sk-cpa-..`)、外部大模型 API Token | 遭遇 Prompt Injection 时，攻击面锁死在模型额度，物理阻断对主机与运维资产的嗅探 |
| **`ops`** (自动化运维) | `svc-ops@[DOMAIN]` | 备份服务（Backrest）、证书申请（ACME）、监控探针 | **只读** | S3/B2 存储桶密钥、DNS API 凭据、ntfy Token | 仅限机-机自动化调度，与 AI 运行时彻底物理隔离 |
| **`vault`** (人工核心资产) | **无服务账号**（仅限管理员本人） | 个人受保护设备（手机 App / 个人 PC） | 管理 | 服务器 SSH 私钥、Vaultwarden 管理密码、个人私密凭证 | 仅由管理员配合硬件 2FA 交互访问，**严禁派发任何机器服务账号** |

## 服务端组织与受限账号配置

前置依赖：已部署就绪 `vaultwarden` 容器服务。

1. **创建组织与集合**：
   - 登录 Web 管理端 `https://vw.[DOMAIN]`；
   - 点击 **设置** -> **组织** -> **新组织**，命名为 `Infra-Vault`；
   - 在组织面板的 **集合** 中，创建 `llm` 与 `ops` 两个集合。
2. **设立受限机器服务账号**：
   - 在组织 **成员** 界面邀请 `svc-llm@[DOMAIN]` 与 `svc-ops@[DOMAIN]`，通过链接设置独立服务密码；
   - 编辑 `svc-llm@[DOMAIN]`：集合权限**仅勾选 `llm`**，设为 **只读**，取消勾选其余集合；
   - 编辑 `svc-ops@[DOMAIN]`：集合权限**仅勾选 `ops`**，设为 **只读**，取消勾选其余集合。

## 客户端 CLI 接入 (Linux / Windows)

Bitwarden 官方 CLI 跨平台通用，支持纯内存解密流转。以运行 Pi 智能体的终端为例：

### 1. 安装 CLI 工具

- **Arch Linux**：
  ```bash
  paru -S --needed --noconfirm bitwarden-cli
  ```
- **Windows (PowerShell)**：
  ```powershell
  scoop install bitwarden-cli
  ```

### 2. 绑定端点与登录专属账号

双端命令通用。在需运行智能体的机器上执行：

```bash
# 1. 切换服务端点为自建 Vaultwarden 域名
bw config server https://vw.[DOMAIN]

# 2. 登录该实体专属账号
bw login svc-llm@[DOMAIN]
```

### 3. 解锁会话并注入内存

解锁凭据仅驻留于当前终端进程 RAM，磁盘全程零明文：

- **Linux / macOS (Bash / Zsh)**：
  ```bash
  export BW_SESSION=$(bw unlock --raw)
  ```
- **Windows (PowerShell)**：
  ```powershell
  $env:BW_SESSION = (bw unlock --raw)
  ```

验证隔离效果（输出应仅包含 `llm` 集合下的条目）：
```bash
bw list items
```

## 零明文接入实操

### 1. 智能体模型端点 (Pi + CPA)

将反向代理或聚合网关（如 CPA）的 API 密钥录入 `llm` 集合（条目 `cpa`，密码 `sk-cpa-...`）。

在 [pi.md](pi.md) 的 `~/.pi/agent/models.json` 中配置标志指令，彻底废弃明文密钥与 `auth.json`：

```json
{
  "providers": {
    "cpa": {
      "baseUrl": "https://cpa.[DOMAIN]/v1",
      "api": "openai-completions",
      "apiKey": "!bw get password cpa",
      "models": [
        {
          "id": "claude-3-7-sonnet-20250219",
          "name": "Claude 3.7 Sonnet",
          "api": "openai-completions",
          "reasoning": true,
          "contextWindow": 200000,
          "maxTokens": 64000
        }
      ]
    }
  }
}
```

Pi 仅在发起请求瞬间在内存派生子进程调用 `bw` 注入 Token，用完即焚；端点密钥轮换仅需在 Vaultwarden 修改一次。

### 2. 检索扩展套件 (pi-search)

将 Exa、Tavily、Context7 等 Key 录入 `llm` 集合（条目 `search-exa`、`search-tavily` 等）。

运行 [pi.md](pi.md) 检索配置向导时，脚本自动从 `bw` 内存提取并填充，免去手动输入：

```bash
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-addons.sh | bash -s -- --config-only
```

### 3. 服务端自动化运维调用 (svc-ops)

在 `ops` 集合录入条目 `spaceship-api`（用户名存放 Key，密码存放 Secret）。

在部署或恢复配置向导时，脚本由 `svc-ops` 账号在内存中读取凭据作为默认值，重装恢复无需手动翻找控制台：

```bash
SPACESHIP_API_KEY=$(bw get username spaceship-api 2>/dev/null || true)
SPACESHIP_API_SECRET=$(bw get password spaceship-api 2>/dev/null || true)
```

## 日常运维速查

```bash
# 检查当前 CLI 登录状态与服务端点
bw status

# 静默检索特定密码
bw get password cpa

# 锁定当前保密库 (清理内存解密会话)
bw lock
```
