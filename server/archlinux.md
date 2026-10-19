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

## 进阶选配向导（Shell 增强与工具链）

脚本内置受控分界标记块（Managed Block），采用原位安全替换机制，反复运行不会造成配置污染：

```bash
bash /tmp/archlinux-init.sh --opt
```

向导支持分段细化的选配组件：

- **Shell 体验增强**：
  - `__sync_history`：多终端历史实时回车同步
  - `__git_info`：提示符展示 Git 分支名与改动标识
  - `__exit_status`：提示符高亮上一条命令非零错误退出码
  - `dedup-history`：历史记录倒序去重运维函数
- **常用工具链与软件源**：
  - **Micro**：现代化终端编辑器（4 空格、软换行与系统剪贴板支持，设为默认 `EDITOR`）
  - **archlinuxcn 源与 paru**：配置 archlinuxcn 镜像源，安装编译工具链与 paru (AUR 助手)
  - **fnm**：基于 Rust 的原生极速 Node.js 多版本管理器，安装 Node LTS
  - **uv**：高性能 Python 包与虚拟环境管理器
  - **gh**：GitHub 官方终端客户端

## 内核网络调优（BBR）

开启 BBR 拥塞控制与 FQ 队列调度，优化 TCP 吞吐与弱网抗丢包：

```bash
(
set -euo pipefail

sudo modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" | sudo tee /etc/modules-load.d/bbr.conf > /dev/null
sudo tee /etc/sysctl.d/99-bbr.conf > /dev/null <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sudo sysctl --system > /dev/null
printf '✅ 内核网络参数已生效 (拥塞控制: %s, 队列: %s)\n' \
  "$(sysctl -n net.ipv4.tcp_congestion_control)" \
  "$(sysctl -n net.core.default_qdisc)"
)
```

## 内存管理（zswap 与 zram）

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

## 常用运维操作

需要 root shell 时：

```bash
sudo -i
```

确认要删除用户及其家目录时执行：

```bash
sudo userdel -r [HERE_USERNAME]
```
