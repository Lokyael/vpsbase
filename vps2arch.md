# vps2arch

将 VPS 重装为 Arch Linux。本地客户端生成 Ed25519 密钥见 [ssh.md](ssh.md)。

> [!CAUTION]
> 清空**整块硬盘**并重建分区表，所有原有数据均会被格式化。实操前请备份重要数据。

## 一键交互重装

内置参数交互采集（普通用户、提权密码、公钥、端口）与抹盘确认，原生固化终态安全加固（仅 Ed25519 密钥、禁用 root 与密码认证）。

在目标 VPS 上以 root 执行：

```bash
(
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { printf '❌ 必须以 root 执行\n' >&2; exit 1; }

curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/vps2arch.sh -o /root/vps2arch.sh

bash /root/vps2arch.sh
)
```

重装就绪后重启系统：

```bash
reboot
```

进入 [archlinux.md](archlinux.md)。

保留非根数据分区原地重装见 [vps2arch-inplace.md](vps2arch-inplace.md)。

## 静态脚本构建与维护

更新上游或修改加固逻辑后本地构建：

```bash
bash scripts/build-vps2arch.sh
```

构建默认生成全量审计补丁 `scripts/vps2arch.patch`。产物 `scripts/vps2arch.sh` 为只读静态文件，通过 `git diff` 审查变更并提交。
