# Arch Linux 系统配置

## 基础环境初始化

以普通用户 SSH 登录。脚本会更新基础包、主机名、Locale、时区、NTP、Shell、网络参数和资源限制；已有 Swap 保持，未配置时交互选择。初始化也可能改写已有 Bash 历史记录的时间戳，并影响现有会话和工作负载。

确认后执行：

```bash
(
set -Eeuo pipefail

curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/archlinux-init.sh -o /tmp/archlinux-init.sh
bash /tmp/archlinux-init.sh
)
```

执行完成后重载终端生效：

```bash
exec bash -i
```

## 进阶选配

以普通用户执行即可。历史去重项会改写 Bash 历史文件的时间戳；Shell 配置写入前会检查，已有语法错误或符号链接需先人工处理。

```bash
(
set -Eeuo pipefail

curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/os/archlinux-opt.sh -o /tmp/archlinux-opt.sh
bash /tmp/archlinux-opt.sh
)
```

选配项：Shell 历史同步、Git 分支提示、退出码提示、历史去重、Micro、paru、fnm、uv 和 gh。

## 网络参数

初始化会配置 BBR／FQ、读写缓冲区和 nofile 上限。以下文件用于检查配置，实际吞吐和内存影响须按负载验证：

- **内核模块**：`/etc/modules-load.d/tcp_bbr.conf`
- **网络参数**：`/etc/sysctl.d/99-network.conf`（BBR + FQ）
- **资源限制**：`/etc/security/limits.d/99-limits.conf`

### 状态验证

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max
ulimit -n
```

## Swap

初始化会保留已有活动 Swap；未配置时按硬件信息推荐并交互选择 zram、磁盘 Swapfile 或不配置。

- zram：`/etc/systemd/zram-generator.conf.d/zram0.conf`，使用压缩内存；即时停用 zswap 并通过 GRUB 持久化。
- Swapfile：`/swapfile`、`/etc/sysctl.d/99-memory.conf`，`swappiness=10`。
- 无 Swap：保持纯物理内存运行。

### 状态验证

```bash
swapon --show
free -h
```

### 注销 Swap

- 注销磁盘 Swapfile（释放文件、注销 fstab 并恢复原生内核参数）：
  ```bash
  sudo swapoff /swapfile && sudo rm -f /swapfile /etc/sysctl.d/99-memory.conf && sudo sed -i '\|/swapfile|d' /etc/fstab && sudo sysctl -w vm.swappiness=60 >/dev/null
  ```
- 注销 zram 内存盘（重置内核块设备归还内存、清理配置并还原 GRUB）：
  ```bash
  sudo swapoff /dev/zram0 2>/dev/null || true
  sudo zramctl --reset /dev/zram0 2>/dev/null || true
  sudo rm -f /etc/systemd/zram-generator.conf.d/zram0.conf && sudo systemctl daemon-reload
  sudo sed -i 's/[[:space:]]*zswap\.enabled=0//g' /etc/default/grub && sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
  echo 1 | sudo tee /sys/module/zswap/parameters/enabled >/dev/null 2>&1 || true
  ```

## 常用运维操作

### 包与缓存清理

```bash
# 检查并清理系统孤立依赖包 (Orphans)
sudo pacman -Rns $(pacman -Qtdq) 2>/dev/null || true

# 清理 pacman 历史包缓存 (需安装 pacman-contrib，保留最近 3 个版本)
sudo pacman -S --needed --noconfirm pacman-contrib && sudo paccache -r
```
