# Arch Linux 系统配置

## 基础环境初始化

适用于 Arch Linux x86-64 单机。以具备 sudo 权限的普通用户经 IPv4 SSH 登录，保留当前会话并确认带外控制台可用。更新基础包可能重启 sshd；初始化可能改写已有 Bash 历史记录的时间戳。已有 `.bashrc` 语法错误、是符号链接，或基础块标记残缺、重复或与其他块重叠时，先人工处理再初始化。

此脚本是 [nftables 底座](nftables.md) 的唯一首装入口。仅处理无业务片段的宿主，未知防火墙状态会阻断。确认首装后才更新基础包并加载底座；取消不会撤销确认前已进行的 `.ssh` 目录及 `authorized_keys` 权限调整或主机名设置。

SSH 仅放行已核验的 IPv4 地址和端口，不开放 443。此底座不保全 IPv6 邻居发现及依赖它的连接；需要 IPv6 的宿主不要按此入口初始化。底座已合规时仍更新基础包，但不重载防火墙。初始化期间不要并行修改防火墙。

```bash
(
set -Eeuo pipefail

curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/host/archlinux-init.sh -o /tmp/archlinux-init.sh
bash /tmp/archlinux-init.sh
)
```

从新终端验证 IPv4 SSH 登录后再关闭旧会话。使用 DHCPv4 的宿主另核验首次取址和续租。失败时按 [防火墙恢复检查](nftables.md#恢复检查) 核对磁盘与运行态。重载终端配置：

```bash
exec bash -i
```

## 进阶选配

以普通用户执行，需要安装软件的选项使用 sudo。历史去重项会改写 Bash 历史文件的时间戳。选中 Shell 配置项时，已有 `.bashrc` 语法错误、是符号链接，或待更新块的标记残缺、重复或与其他块重叠，均会在执行所选项目之前阻断；先人工处理再重试。

```bash
(
set -Eeuo pipefail

curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/host/archlinux-opt.sh -o /tmp/archlinux-opt.sh
bash /tmp/archlinux-opt.sh
)
```

选配项：Shell 历史同步、Git 分支提示、退出码提示、历史去重、Micro、paru、fnm、uv 和 gh。选装 paru 会保留 `git` 和 `base-devel` 以便继续使用 AUR。构建失败时也可能清理本次新增且已不需要的构建依赖，不清理整机孤立包。构建期间不要并行执行其他包管理操作。

## 网络参数

初始化会配置 BBR／FQ、读写缓冲区和 nofile 上限。以下文件用于检查配置，实际吞吐和内存影响须按负载验证：

- **内核模块**：`/etc/modules-load.d/tcp_bbr.conf`
- **网络参数**：`/etc/sysctl.d/99-network.conf`（BBR + FQ）
- **资源限制**：`/etc/security/limits.d/99-limits.conf`

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max
ulimit -n
```

## Swap

初始化会保留已有活动 Swap；未配置时按硬件信息推荐并交互选择。后续若有调整需求由用户自行通过标准系统命令管理。

- **zram**：`/etc/systemd/zram-generator.conf.d/zram0.conf`，使用压缩内存并停用 zswap。
- **Swapfile**：只新建 `/swapfile`，不会覆盖已有文件。无法创建时停止；若配置失败后留有文件，先核对用途和 Swap 状态。配置使用 `/etc/sysctl.d/99-memory.conf`，`swappiness=10`。
- **无 Swap**：保持纯物理内存运行。

```bash
swapon --show
free -h
```
