# Arch Linux 系统配置

适用 Arch Linux x86-64 单机，以具备 sudo 权限的普通用户经 IPv4 SSH 登录执行。

**前置条件**：已有 `.bashrc` 若为符号链接、存在语法错误或受控块标记残缺，先人工修正再执行；若更新升级了内核，先 `sudo reboot` 再初始化防火墙或验收 BBR/zram。

## 1. 基础环境初始化

配置 Locale、时区、基础系统包、网络参数（BBR/FQ）与交互选配 Swap（`btrfs` 根分区不支持 Swapfile）：

```bash
script=$(mktemp "${TMPDIR:-/tmp}/archlinux-init.XXXXXX")
trap 'rm -f -- "$script"' EXIT
curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/host/archlinux-init.sh -o "$script"
bash "$script"
```

重载当前终端配置：

```bash
exec bash -i
```

## 防火墙底座初始化

[nftables 底座](nftables.md)的唯一首装入口（仅用于无业务片段的空白宿主；不支持保留 IPv6 邻居发现）。执行前保留当前会话并确认带外控制台可用：

```bash
script=$(mktemp "${TMPDIR:-/tmp}/nftables-init.XXXXXX")
trap 'rm -f -- "$script"' EXIT
curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/host/nftables-init.sh -o "$script"
bash "$script"
```

**结果核验**：从新终端验证 IPv4 SSH 登录后再关闭旧会话（DHCPv4 宿主另核验取址与续租）；异常按[恢复检查](nftables.md#恢复检查)排查。

## 2. 进阶选配（按需）

选配 Shell 历史同步/去重、Git/退出码提示、Micro、paru、fnm、uv 与 gh：

```bash
script=$(mktemp "${TMPDIR:-/tmp}/archlinux-opt.XXXXXX")
trap 'rm -f -- "$script"' EXIT
curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/host/archlinux-opt.sh -o "$script"
bash "$script"
```

## 3. 结果核验

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max
ulimit -n
swapon --show
free -h
```
