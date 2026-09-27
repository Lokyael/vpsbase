# vps2arch-inplace

仅适用于需保留非根数据分区（如 `/data`）的原地热重装。清空根分区与 ESP 分区，保留其他分区。全盘重装见 [vps2arch.md](vps2arch.md)。

> [!CAUTION]
> 破坏性清空根分区与 ESP 分区。实操前请备份重要数据。

## 一键执行

采用私有挂载命名空间（`unshare`）与官方 Bootstrap + 官方 PGP 签名校验原地重装。在 chroot 环境内一步完成终态安全加固与校验，冷启动即为终态，无网络暴露期。

在目标 VPS 上以 root 执行：

```bash
(
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { printf '❌ 必须以 root 执行\n' >&2; exit 1; }

curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/vps2arch-inplace.sh -o /root/vps2arch-inplace.sh

bash /root/vps2arch-inplace.sh
)
```

重装就绪后重启系统：

```bash
reboot
```

进入 [archlinux.md](archlinux.md)。
