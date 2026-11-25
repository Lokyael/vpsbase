# vps2arch

将 Linux VPS 全盘重装为 Arch Linux（仅 x86-64 已验收，ARM 不保证支持）。

**前置条件**：确认带外控制台可用、备妥重要数据；源系统须具备 `ssh-keygen` 与 util-linux `blkid`；`443/tcp` 预留给业务入口，勿作新系统 SSH 端口。

## 1. 客户端密钥与配置 `[工作站 pwsh]`

生成专用 Ed25519 密钥对：

```pwsh
. {
    $ErrorActionPreference = 'Stop'
    $n = Read-Host "密钥文件名（默认 vps）"
    if (-not $n) { $n = "vps" }
    $p = Join-Path "$env:USERPROFILE\.ssh" $n
    New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
    if ((Test-Path -LiteralPath $p) -or (Test-Path -LiteralPath "$p.pub")) { throw "密钥已存在：$p，请自行删除后重试。" }
    ssh-keygen -t ed25519 -f $p -C $n
    if ($LASTEXITCODE) { throw "ssh-keygen 失败。" }
    icacls $p /inheritance:r /grant:r "${env:USERNAME}:F" | Out-Null
    Get-Content -LiteralPath "$p.pub"
}
```

写入 `~/.ssh/config`（若有通配 `Host` 块，将本块置于其前）：

```pwsh
. {
    $ErrorActionPreference = 'Stop'
    $name = if ($n) { $n } else { Read-Host "连接名（与密钥名一致，默认 vps）" }; if (-not $name) { $name = "vps" }
    $h = Read-Host "服务器地址"; if (-not $h) { throw "服务器地址不能为空。" }
    $u = Read-Host "登录用户名"; if (-not $u) { throw "登录用户名不能为空。" }
    $port = Read-Host "端口（默认 22）"; if (-not $port) { $port = "22" }

    $cfg = Join-Path "$env:USERPROFILE\.ssh" "config"
    New-Item -ItemType Directory -Force -Path (Split-Path $cfg) | Out-Null
    if (Test-Path -LiteralPath $cfg) {
        $hit = Select-String -LiteralPath $cfg -Pattern "^\s*Host\s+$([regex]::Escape($name))\s*$"
        if ($hit) { throw "配置中已存在 Host $name（$cfg 第 $($hit.LineNumber -join ',') 行），已终止。" }
        icacls $cfg /inheritance:r /grant:r "${env:USERNAME}:F" | Out-Null
    }

    Add-Content -LiteralPath $cfg -Encoding ASCII -Value @"

# ---------- $name ----------
Host $name
    HostName $h
    User $u
    Port $port
    IdentityFile ~/.ssh/$name
    IdentitiesOnly yes
"@
    Write-Host "连接命令：ssh $name"
}
```

核验匹配规则仅使用专用密钥（确认 `identitiesonly yes` 与 `identityfile`）：

```pwsh
ssh -G [HERE_SSH_ALIAS]
```

## 2. 执行全盘重装 `[源机 root]`

> [!CAUTION]
> 清空**整块目标硬盘**并重建分区表，原数据全部清除。手动操作请使用交互向导；若不清楚服务商是 `dhcp` 保留地址还是手填 `static`，或重装中目标盘存在热插拔/克隆冲突，请停止操作。

```bash
[[ $EUID -eq 0 ]] || { printf '✘ 必须以 root 执行\n' >&2; exit 1; }
URL=https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/reinstall/vps2arch.sh
if command -v wget >/dev/null; then wget -q --show-progress -O /root/vps2arch.sh "$URL"
else curl -fL --progress-bar "$URL" -o /root/vps2arch.sh; fi
bash /root/vps2arch.sh
```

**结果核验**：
1. 仅在脚本输出 `本次已安排重装` 后执行 `reboot`（如需重启前撤销，执行脚本打印的 `reset` 命令）。
2. 重装期间若失败，通过带外控制台查看磁盘与安装日志，已尝试擦除时勿盲目重试。
3. 新系统就绪后，先在控制台核对实际 IPv4 地址，再从新终端验证 SSH 公钥登录与 `sudo` 密码。

## 3. 退租整盘销毁（可选）`[源机 root]`

> [!CAUTION]
> **绝对不可逆**：仅用于退租交还 VPS（重装前勿执行）。执行后凭据、空闲空间与磁盘头部将被物理抹除并立即断联。

交互确认需输入 `DESTROY`，完成后在服务商控制台销毁实例：

```bash
[[ $EUID -eq 0 ]] || { printf '✘ 必须以 root 执行\n' >&2; exit 1; }
URL=https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/reinstall/vps-wipe.sh
if command -v wget >/dev/null; then wget -q --show-progress -O /root/vps-wipe.sh "$URL"
else curl -fL --progress-bar "$URL" -o /root/vps-wipe.sh; fi
bash /root/vps-wipe.sh
```
