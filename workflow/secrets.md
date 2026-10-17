# 凭据管理

基于 Vaultwarden 与 Bitwarden CLI（`bw`）的凭据隔离矩阵与零明文调用规范。

## 架构与安全隔离矩阵

按主体与信任等级划分隔离域，集合（Collection）与服务账号 1:1 绑定：

| 资产集合（Collection） | 专属受限账号 | 授权运行实体 | 权限 | 纳管凭证类型 | 隔离安全目标 |
|---|---|---|---|---|---|
| **`llm`**（模型交互） | `svc-llm@[HERE_DOMAIN]` | Pi 智能体宿主机、Windows 开发机 | **只读** | CPA 密钥（`sk-cpa-..`）、外部大模型 API Token | 遭遇 Prompt Injection 时，攻击面锁死在模型额度，物理阻断对主机与运维资产的嗅探 |
| **`ops`**（自动化运维） | `svc-ops@[HERE_DOMAIN]` | 备份服务（Backrest）、证书申请（ACME）、监控探针 | **只读** | S3/B2 存储桶密钥、DNS API 凭据、ntfy Token | 仅限机-机自动化调度，与 AI 运行时彻底物理隔离 |
| **`vault`**（人工核心资产） | **无服务账号**（仅限管理员本人） | 个人受保护设备（手机 App / 个人 PC） | 管理 | 服务器 SSH 私钥、Vaultwarden 管理密码、个人私密凭证 | 仅由管理员配合硬件 2FA 交互访问，**严禁派发任何机器服务账号** |

## 服务端组织与受限账号配置

前置依赖：已部署就绪 `vaultwarden` 容器服务。

1. **创建组织与集合**：Web 管理端进入 **设置** → **组织** → **新组织**（命名 `Infra-Vault`），在 **集合** 中创建 `llm` 与 `ops`；
2. **设立受限服务账号**：在 **成员** 界面邀请 `svc-llm@[HERE_DOMAIN]` 与 `svc-ops@[HERE_DOMAIN]`，分别仅勾选对应单一集合，设为 **只读**。

## 客户端 CLI 接入（跨平台标准）

开发终端统一使用 POSIX Bash（Linux 终端 / Windows Git Bash），纯内存解密流转：

### 1. 安装 CLI 工具（宿主初始化）

- **Arch Linux**：`paru -S --needed --noconfirm bitwarden-cli`
- **Windows（pwsh）**：`scoop install bitwarden-cli`

### 2. 绑定端点与登录专属账号

终端执行（兼容 Linux / Windows Git Bash）：

```bash
# 1. 切换服务端点为自建 Vaultwarden 域名
bw config server https://vw.[HERE_DOMAIN]

# 2. 登录该实体专属账号
bw login svc-llm@[HERE_DOMAIN]
```

### 3. 解锁会话并注入内存

终端执行。解锁凭据仅驻留当前终端 RAM，磁盘全程零明文：

```bash
export BW_SESSION=$(bw unlock --raw)
```

*(注：PowerShell 终端对应语法为 `$env:BW_SESSION = (bw unlock --raw)`)*

验证隔离效果（仅列出 `llm` 集合条目）：

```bash
bw list items
```

## 零明文接入实操

### 1. 智能体模型端点（`llm` 集合）

在 `llm` 集合录入条目 `cpa`（密码存放 API 密钥）。Pi 运行时动态提取，磁盘零明文：

```json
"apiKey": "!bw get password cpa"
```

向导写入：

```bash
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-provider.sh | bash -s -- --mode bw -b cpa
```

### 2. 检索扩展套件（`llm` 集合）

在 `llm` 集合录入信源条目（`search-exa` 等），注入会话后静默填充：

```bash
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/pi-addons.sh | bash -s -- --config-only -y
```

### 3. 服务端自动化运维调用（`ops` 集合）

在 `ops` 集合录入运维凭据（如 `spaceship-api`），脚本在内存读取，用完即弃：

```bash
SPACESHIP_API_KEY=$(bw get username spaceship-api 2>/dev/null || true)
SPACESHIP_API_SECRET=$(bw get password spaceship-api 2>/dev/null || true)
```

## 日常运维速查

```bash
# 检查当前 CLI 登录状态与服务端点
bw status

# 手动同步云端保密库最新条目
bw sync

# 静默读取特定条目凭据
bw get password [HERE_ITEM_NAME]

# 锁定当前保密库（清除内存会话）
bw lock
```
