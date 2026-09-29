# Arch Linux 系统配置

x86_64 Arch Linux 服务器 / VPS 初始配置与进阶选配。

## 基础环境初始化

以重装时配置的普通用户 SSH 登录后整段执行：

```bash
(
set -Eeuo pipefail

curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/scripts/archlinux-init.sh -o /tmp/archlinux-init.sh
bash /tmp/archlinux-init.sh
)
```

脚本自动化完成：
1. **身份与安全基线检查**（非 root、`wheel` 组、`~/.ssh` 700 / `authorized_keys` 600 权限、`sudo -v`）；
2. **主机名配置**（交互确认，回车保持）；
3. **官方密钥环与基础包更新**（`archlinux-keyring`、`sudo`、`which`、`less`、`bash-completion`）；
4. **本地化与时区**（固化 `en_US.UTF-8`、统一 `UTC` 时区）；
5. **标准通用 `~/.bashrc` 受控配置**（10 万条带时间戳历史、方向键历史前缀搜索、标准运维别名 `ll/ports/df/free`、轻量双色提示符、Linger 用户驻留安全防御补齐）。

执行完成后重载终端生效：

```bash
exec bash -i
```

基础装机流水线完成，直接进入 [nftables.md](nftables.md)。以下章节均为可选按需选配。

## 进阶选配向导（Shell 增强与工具链）

脚本内置受控分界标记块（Managed Block），采用原位安全替换机制，反复运行不会造成配置污染或重复追加。随时可通过选配模式启动交互向导：

```bash
bash /tmp/archlinux-init.sh --opt
```

向导支持分段细化的组件如下：

### Shell 体验增强

- **多终端历史实时同步 (`__sync_history`)**：
  并发开启多个 SSH 终端时，任意终端回车后立即同步历史，其它终端敲击回车即可直接读取最新命令，无需等待退出登出。
- **Git 分支状态提示符 (`__git_info`)**：
  进入 Git 仓库目录时在终端提示符末尾黄色高亮显示当前分支名；若有未提交改动则追加 `*` 标识。
- **非零退出码错误高亮 (`__exit_status`)**：
  上一条命令执行失败（返回非 0 状态码）时，在提示符前端以红色方括号标注错误退出码（如 `[1]` / `[127]`），便于即时排障。
- **历史记录去重函数 (`dedup-history`)**：
  基于 awk 状态机对 `~/.bash_history` 倒序去重并保留最新时间戳，彻底清理高频重复命令。注入函数后在终端手动输入 `dedup-history` 触发。

### 常用工具链与软件源

- **Micro 终端编辑器**：
  现代化终端文本编辑器，具备鼠标滚轮与直观快捷键，自动配置 4 空格缩进、软换行与系统终端剪贴板支持，并设置为系统默认 `EDITOR`。
- **archlinuxcn 社区源与 paru (AUR 助手)**：
  配置镜像站的 `archlinuxcn` 源并安装官方密钥环、开发编译工具链与 `paru`，便于快速安装与维护 AUR 软件包。
- **Node.js LTS 环境 (fnm)**：
  基于 Rust 编写的原生极速 Node.js 多版本管理器，自动安装并设置默认 Node LTS 版本，并在 Shell 中注入目录环境钩子。
- **Python 极速工具链 (uv)**：
  现代高性能单二进制 Python 包与虚拟环境管理器，开箱即用。
- **GitHub CLI 官方客户端 (gh)**：
  GitHub 官方终端工具，用于仓库克隆、Issue/PR 处理与身份认证。

## 内存管理 (zswap 与 zram)

适用于小内存 VPS，通过 GRUB 禁用内核 zswap 并启用 `zstd` 算法的 `zram-generator` 压缩内存盘。

### 状态体检

```bash
printf '=== zswap 状态 ===\n'
cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "不支持"

printf '\n=== 活动 Swap ===\n'
swapon --show
zramctl

printf '\n=== /etc/fstab Swap ===\n'
grep -nE '^[[:space:]]*[^#[:space:]]+[[:space:]]+[^#[:space:]]+[[:space:]]+swap([[:space:]]|$)' /etc/fstab 2>/dev/null || echo "无未注释磁盘 Swap"

printf '\n=== 引导器 ===\n'
grep -q "BOOT_IMAGE=" /proc/cmdline && echo "GRUB" || echo "非 GRUB 或未知"
```

### 禁用 zswap（GRUB）

若 zswap 为 `Y`，需直接修改主配置文件 `/etc/default/grub` 禁用并重启生效：

```bash
(
set -euo pipefail
if ! grep -q 'zswap\.enabled=0' /etc/default/grub; then
    sudo sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)/\1 zswap.enabled=0/' /etc/default/grub
fi
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo reboot
)
```

### 配置 zram-generator

重启后确认 zswap 为 `N` 且无活动磁盘 Swap 后执行：

```bash
(
set -euo pipefail
sudo pacman -S --needed --noconfirm zram-generator

sudo mkdir -p /etc/systemd/zram-generator.conf.d
sudo tee /etc/systemd/zram-generator.conf.d/zram0.conf > /dev/null <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

sudo systemctl daemon-reload
sudo systemctl start dev-zram0.swap

# 验证状态与算法
systemctl is-active --quiet dev-zram0.swap && echo "dev-zram0.swap: active" || echo "dev-zram0.swap: failed"
swapon --show
cat /sys/block/zram0/comp_algorithm
)
```

## 后续管理

需要 root shell 时：

```bash
sudo -i
```

确认要删除用户及其家目录时执行：

```bash
sudo userdel -r [HERE_USERNAME]
```
