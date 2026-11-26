# Arch Linux 系统配置

适用 Arch Linux x86-64 单机，以具备 sudo 权限的普通用户经交互式 IPv4 SSH 会话执行（拒绝非交互执行）。

**前置条件**：已有 `~/.bashrc` 或 `~/.config/environment.d/50-archlinux-init.conf` 若为符号链接、存在语法错误或受控块标记残缺，先人工修正再执行；若更新升级了内核，先 `sudo reboot` 再初始化防火墙或验收 BBR/zram。

## 1. 系统初始化与工具链选配

依次执行基础检查、主机名、密钥环与系统更新、Locale/时区/NTP、`.bashrc` 基础块、网络参数（BBR/FQ）、交互选配 Swap（`btrfs` 根分区不支持 Swapfile），并在第 `8` 步按需选配 Git、Shell 体验增强（历史同步/去重、退出码高亮；已安装 git 时附带分支提示符）、Micro、paru、fnm/Node.js、Go、uv 与 gh（回车跳过全部选配；静态环境变量与 `PATH` 统一写入 `~/.config/environment.d/50-archlinux-init.conf` 并由 `~/.bashrc` 前置加载，`systemd --user` 需重新登录生效）：

```bash
script=$(mktemp "${TMPDIR:-/tmp}/archlinux-init.XXXXXX")
trap 'rm -f -- "$script"' EXIT
curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/host/archlinux-init.sh -o "$script"
bash "$script"
```

重载当前终端配置（若提示已升级内核则先 `sudo reboot`）：

```bash
exec bash -i
```

## 2. 防火墙底座初始化

[nftables 底座](nftables.md)的唯一首装入口（仅用于无业务片段的空白宿主；不支持保留 IPv6 邻居发现）。执行前保留当前会话并确认带外控制台可用：

```bash
script=$(mktemp "${TMPDIR:-/tmp}/nftables-init.XXXXXX")
trap 'rm -f -- "$script"' EXIT
curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/host/nftables-init.sh -o "$script"
bash "$script"
```

**结果核验**：从新终端验证 IPv4 SSH 登录后再关闭旧会话（DHCPv4 宿主另核验取址与续租）；异常按[恢复检查](nftables.md#恢复检查)排查。

## 3. 结果核验

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max
ulimit -n
swapon --show
free -h
```
