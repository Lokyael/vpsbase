# vps2arch

将 VPS 跨发行版自动化重装为 Arch Linux。支持全盘抹盘重装与保留数据分区的原地热重装。重装前需在客户端生成 Ed25519 登录密钥。

## 客户端准备（生成登录密钥）

在本地工作站的pwsh中生成专用 Ed25519 密钥对：

```pwsh
$n = Read-Host "密钥文件名（默认 server_login）"
if (-not $n) { $n = "server_login" }
$p = "$env:USERPROFILE\.ssh\$n"
New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
ssh-keygen -t ed25519 -f $p -C $n
icacls $p /inheritance:r /grant:r "${env:USERNAME}:R" | Out-Null
Get-Content "$p.pub"
```

配置快速连接

```pwsh
$alias = Read-Host "连接别名（如 myserver）"
$h     = Read-Host "服务器地址"
$u     = Read-Host "登录用户名"
$port  = Read-Host "端口（默认 22）"; if (-not $port) { $port = "22" }
$key   = Read-Host "密钥文件名（默认 server_login）"; if (-not $key) { $key = "server_login" }

$cfg = "$env:USERPROFILE\.ssh\config"
New-Item -ItemType Directory -Force -Path (Split-Path $cfg) | Out-Null
Add-Content $cfg -Encoding ASCII -Value @"

# ---------- $alias ----------
Host $alias
    HostName $h
    User $u
    Port $port
    IdentityFile ~/.ssh/$key
"@
icacls $cfg /inheritance:r /grant:r "${env:USERNAME}:R" | Out-Null
Write-Host "已配置，连接命令：ssh $alias"
```

## 模式一：全盘自动化重装（抹盘重建）

> [!CAUTION]
> 清空**整块硬盘**并重建分区表，所有原有数据均会被格式化。实操前请备份重要数据。

内置参数交互采集（普通用户、提权密码、公钥、端口）与抹盘确认，原生固化终态安全加固（仅 Ed25519 密钥、禁用 root 与密码认证）。

在目标 VPS 上以 root 执行：

```bash
(
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { printf '❌ 必须以 root 执行\n' >&2; exit 1; }

curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/vps2arch.sh -o /root/vps2arch.sh

bash /root/vps2arch.sh
)
```

重装就绪后重启系统：

```bash
reboot
```

## 模式二：保留数据分区原地热重装

仅适用于需保留非根数据分区（如 `/data`）的原地热重装。清空根分区与 ESP 分区，保留其他分区。

> [!CAUTION]
> 破坏性清空根分区与 ESP 分区。实操前请备份重要数据。

使用官方 Bootstrap 与签名校验，在隔离挂载环境中重装并配置 SSH。完成后仍须核验启动、分区和新 SSH 登录，不因脚本完成推断运行健康。

在目标 VPS 上以 root 执行：

```bash
(
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { printf '❌ 必须以 root 执行\n' >&2; exit 1; }

curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/vps2arch-inplace.sh -o /root/vps2arch-inplace.sh

bash /root/vps2arch-inplace.sh
)
```

重装就绪后重启系统：

```bash
reboot
```