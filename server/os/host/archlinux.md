# Arch Linux 系统配置

## 基础环境初始化

适用于 Arch Linux x86-64 单机。以具备 sudo 权限的普通用户经 IPv4 SSH 登录；初始化本身不配置防火墙，可在部署业务后幂等重跑以更新系统包与宿主基线。初始化可能改写已有 Bash 历史记录的时间戳。已有 `.bashrc` 语法错误、是符号链接，或基础块标记残缺、重复或与其他块重叠时，先人工处理再初始化。

此脚本直接修改以下系统主配置并覆盖受控 drop-in（带 `# managed-by: archlinux-init` 标记；若目标路径已有未纳管文件或符号链接则阻断，不覆盖）：

- **直接修改主配置**：`/etc/locale.gen`（取消 `en_US.UTF-8` 注释或追加）、`/etc/locale.conf`（由 `localectl` 重置为 `LANG=en_US.UTF-8`）、`/etc/fstab`（仅磁盘 Swapfile 模式追加 `/swapfile` 挂载行）。

若第 3 步 `pacman -Syu` 耗时超过 sudo 默认 5 分钟凭据缓存，第 4／6／7 步会再次提示输入密码。若包更新升级了内核导致当前运行内核模块目录被移除，脚本仍会落盘配置并提示先执行 `sudo reboot`，再继续初始化防火墙或验证 BBR／zram。

```bash
(
set -Eeuo pipefail

script=$(mktemp "${TMPDIR:-/tmp}/archlinux-init.XXXXXX")
trap 'rm -f -- "$script"' EXIT
curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/host/archlinux-init.sh -o "$script"
bash "$script"
)
```

重载终端配置：

```bash
exec bash -i
```

## 防火墙底座初始化

`nftables-init.sh` 是 [nftables 底座](nftables.md) 的唯一首装入口，建议在完成基础环境初始化（若升级过内核则先重启）后执行。仅处理无业务片段的空白宿主，未知防火墙状态会阻断。首次安装前及包更新后若检测到当前运行内核模块目录缺失（如内核已升级尚未重启），脚本会直接阻断并提示先 `sudo reboot`。确认首装后才更新并加载底座；请保留当前会话并确认带外控制台可用。

SSH 仅放行已核验的 IPv4 地址和端口，不开放 443。此底座不保全 IPv6 邻居发现及依赖它的连接；需要 IPv6 的宿主不要按此入口初始化。底座已合规时仍更新 `nftables` 包，但不重载防火墙。初始化期间不要并行修改防火墙。

```bash
(
set -Eeuo pipefail

script=$(mktemp "${TMPDIR:-/tmp}/nftables-init.XXXXXX")
trap 'rm -f -- "$script"' EXIT
curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/host/nftables-init.sh -o "$script"
bash "$script"
)
```

从新终端验证 IPv4 SSH 登录后再关闭旧会话。使用 DHCPv4 的宿主另核验首次取址和续租。失败时按 [防火墙恢复检查](nftables.md#恢复检查) 核对磁盘与运行态。

## 进阶选配

以普通用户执行，需要安装软件的选项使用 sudo。历史去重项会改写 Bash 历史文件的时间戳。注入 `~/.bashrc` 的受控块（含 `EDITOR=micro`、`fnm` 环境初始化等）位于基础块 `[[ $- != *i* ]] && return` 之后，仅对交互式 Shell 会话生效。选中 Shell 配置项时，已有 `.bashrc` 语法错误、是符号链接，或待更新块的标记残缺、重复或与其他块重叠，均会在执行所选项目之前阻断；先人工处理再重试。

```bash
(
set -Eeuo pipefail

script=$(mktemp "${TMPDIR:-/tmp}/archlinux-opt.XXXXXX")
trap 'rm -f -- "$script"' EXIT
curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/host/archlinux-opt.sh -o "$script"
bash "$script"
)
```

选配项：Shell 历史同步、Git 分支提示、退出码提示、历史去重、Micro、paru、fnm、uv 和 gh。选装 paru 会保留 `git` 和 `base-devel` 以便继续使用 AUR。构建失败时也可能清理本次新增且已不需要的构建依赖，不清理整机孤立包。构建期间不要并行执行其他包管理操作。

## 网络参数

初始化会配置 BBR／FQ、读写缓冲区和 PAM 会话级资源上限。`99-limits.conf` 仅作用于 PAM 用户会话（如 SSH 登录与用户级服务），不影响系统级 systemd 单元：

- **内核模块**：`/etc/modules-load.d/tcp_bbr.conf`
- **网络参数**：`/etc/sysctl.d/99-network.conf`（BBR + FQ）
- **资源限制**：`/etc/security/limits.d/99-limits.conf`

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max
ulimit -n
```

## Swap

初始化会保留已有活动 Swap；未配置时按硬件信息推荐并交互选择。后续若有调整需求由用户自行通过标准系统命令管理。

- **zram**：`/etc/systemd/zram-generator.conf.d/zram0.conf`，使用压缩内存；通过 `/etc/sysctl.d/99-memory.conf` 按两档设置内存参数（`1024 < RAM ≤ 4096 MiB` 且 `vCPU ≥ 2` 时 `vm.swappiness = 180`，其余场景 `vm.swappiness = 100`，统一 `vm.page-cluster = 0`）。若内核暴露 `/sys/module/zswap/parameters/enabled`，会写入引导器无关的 `/etc/tmpfiles.d/zswap.conf` 持久化停用 zswap（不再修改 `/etc/default/grub`），并在当前为开启态时立即于运行时写 `0` 停用。若写后激活或应用内存参数失败，已写入的 `zram0.conf` 会保留且重跑脚本会跳过 Swap 配置（若运行时 zswap 已被停用会一并提示），需手工排查并激活 `dev-zram0.swap`。
- **Swapfile**：创建前检测根文件系统类型，若为 `btrfs` 则直接阻断。只新建 `/swapfile`，不会覆盖已有文件。无法创建时停止；若配置失败后留有文件，先核对用途和 Swap 状态。写入 `/etc/fstab` 并使用 `/etc/sysctl.d/99-memory.conf`（`swappiness=10`）。
- **无 Swap**：保持纯物理内存运行。

```bash
swapon --show
free -h
```
