# vps2arch

将 VPS 跨发行版全盘重装为 Arch Linux。验收基线为 x86-64；ARM 未验收，不保证支持。重装前需在客户端生成 Ed25519 登录密钥。`443/tcp` 预留给业务入口，不能用作新系统的 SSH 端口。

## 客户端准备（生成登录密钥）

在本地工作站的 pwsh 中生成专用 Ed25519 密钥对：

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

### 客户端主机配置 (SSH Config)

```pwsh
. {
    $ErrorActionPreference = 'Stop'
    $name = if ($n) { $n } else { Read-Host "连接名（与密钥名一致，默认 vps）" }
    if (-not $name) { $name = "vps" }
    $h    = Read-Host "服务器地址"; if (-not $h) { throw "服务器地址不能为空。" }
    $u    = Read-Host "登录用户名"; if (-not $u) { throw "登录用户名不能为空。" }
    $port = Read-Host "端口（默认 22）"; if (-not $port) { $port = "22" }

    $cfg = Join-Path "$env:USERPROFILE\.ssh" "config"
    New-Item -ItemType Directory -Force -Path (Split-Path $cfg) | Out-Null
    if (Test-Path -LiteralPath $cfg) { icacls $cfg /inheritance:r /grant:r "${env:USERNAME}:F" | Out-Null }

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

如果已有匹配该别名的通配 `Host` 块，将专用块放在它们之前。连接前运行 `ssh -G [HERE_SSH_ALIAS]`（替换为实际别名），确认显示 `identitiesonly yes`，且 `identityfile` 只列专用密钥；若其他匹配块也设置了 `IdentityFile`，缩小这些块的匹配范围。

## 全盘自动化重装（抹盘重建）

> [!CAUTION]
> 清空**整块硬盘**并重建分区表，所有原有数据均会被格式化。实操前请备份重要数据。

Arch x86-64 面向服务商已分配固定 IPv4 的 VPS。先查服务商说明：由 DHCP 保留固定地址就选 `dhcp`，要求手填地址、前缀和网关才选 `static`；地址长期不变不代表手填静态。向导和 CLI 都会显示源机采集的 IPv4 参数。若 `/etc/network/interfaces` 中明确声明所选网卡使用静态 IPv4，且地址、前缀和网关与实时采集值吻合、没有 DHCP 迹象，脚本会显示并自动采用 `static`；否则仍要求手选，没有默认值。若源机网络改过，先核对其配置是否符合服务商要求；不清楚取址方式，或显示的地址与应配置在网卡上的地址不符时，不要继续。救援按上游方式取址，可能临时尝试旧参数；擦盘前若地址改变、取址方式不符或无法核验，就停止。先确认能使用带外控制台；救援取址成功不保证新系统首启取得相同地址。

源系统须为 Linux，并有 `ssh-keygen` 和 util-linux 的 `blkid`。目标盘必须有唯一的分区表 ID（PTUUID），不要求磁盘序列号或 WWID；有整盘探测失败则停止。Btrfs／bcachefs 根或无法唯一推断根盘时，须用 `--target-disk` 显式指定整盘。BIOS 源系统还必须能从 `/boot` 所在的文件系统确认唯一的引导候选盘；`--target-disk` 只指定擦除目标，不能覆盖这项检查。若 Extlinux 或 Limine 需要将救援 initrd 复制到独立引导分区，该目录必须能实际创建由 root 所有、权限为 `0600` 的文件；否则不会安排本次重装。向导和 CLI 都要求原样输入显示的设备路径；救援会按 PTUUID 重新查找目标盘，并在擦盘前复核。重装期间不要替换、热插拔目标盘或接入其克隆盘：如果原盘被换成保留同一 PTUUID 的克隆，脚本无法区分。也不要并行改变网络。进入救援后失败时，从控制台查看磁盘和安装日志；若已尝试擦除，不要盲目重试。

向导收集新运维用户名、sudo 密码、Ed25519 公钥及端口。用户名不能与救援系统或新装系统中的现有账号重名；源系统是否已有同名账号不限制选名。CLI 必须显式给出 `--username`、`--password`、`--ssh-key`；端口省略时为 22，远程公钥来源只接受 HTTPS。sudo 密码不得为空、包含换行或回车，且最多 256 字节。CLI 密码会进入进程参数；直接键入明文还可能被 Shell 历史记录。手动操作优先使用向导。重装入口不接受 `--debug` 或 `-x`。新系统只允许非 root 用户用普通 Ed25519 公钥登录。

在目标 VPS 上以 root 执行：

```bash
(
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { printf '❌ 必须以 root 执行\n' >&2; exit 1; }

curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/reinstall/vps2arch.sh -o /root/vps2arch.sh

bash /root/vps2arch.sh
)
```

仅在脚本成功退出并显示 `本次已安排重装` 后，才执行 `reboot` 或通过控制台冷重启。需要在重启前撤销安排时，使用脚本打印的 `reset` 命令。`已取消` 也会退出 0，但没有安排本次重装，也不会清除先前安排的任务；若曾安排旧任务，请先核对引导状态再决定是否重启。进入新系统后先在控制台核对实际 IPv4 地址，再从新终端验证 SSH 和 sudo 密码。
