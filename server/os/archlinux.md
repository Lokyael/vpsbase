# Arch Linux 系统配置

x86_64 Arch Linux 服务器 / VPS 初始配置与进阶选配。

## 基础环境初始化

以重装时配置的普通用户 SSH 登录。

执行前确认：脚本会更新基础包、配置主机名、en_US.UTF-8／UTC／校时、Shell、内核网络参数与资源限制。基础初始化还可能规范化并改写已有 Bash 历史文件的时间戳格式，不只是调整 `.bashrc`。已有活动 Swap 保持；无 Swap 时按交互选择 zram、磁盘文件或无 Swap。配置更新可能影响现有会话和工作负载，按提示确认，不将推荐分档视为性能保证。

确认后整段执行：

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

## 进阶选配向导（Shell 增强与工具链）

需要 Shell 增强或额外工具时运行选配向导：

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
  - **paru**：从 AUR 源码独立构建 paru (AUR 助手)，构建完成自动卸载编译依赖并固化 `CleanAfter` 缓存自洁
  - **fnm**：基于 Rust 的原生极速 Node.js 多版本管理器，安装 Node LTS
  - **uv**：高性能 Python 包与虚拟环境管理器
  - **gh**：GitHub 官方终端客户端

## 内核网络调优（自适应 BBR 与长管道缓冲区）

初始化会配置 BBR／FQ、读写缓冲区和 nofile 上限。以下文件用于检查配置，实际吞吐和内存影响须按负载验证：

- **内核模块**：`/etc/modules-load.d/tcp_bbr.conf`
- **网络参数**：`/etc/sysctl.d/99-network.conf`（BBR + FQ）
- **资源限制**：`/etc/security/limits.d/99-limits.conf`

### 状态验证

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max
ulimit -n
```

## 内存管理（负载特征与 Swap 策略）

已由基础环境初始化脚本全自动纳管（先检后配：已有活动 Swap 保持现状跳过；未配置则根据硬件参数智能推荐并单向打底）：

- **zram 压缩内存盘**：`/etc/systemd/zram-generator.conf.d/zram0.conf`；使用内存压缩，会消耗 CPU，不支持保留断电状态；
  *注：zram 即时挂载生效，zswap 已在运行态即时停用，并通过 GRUB 固化持久生效。*
- **经典磁盘 Swapfile**：`/swapfile` 与 `/etc/sysctl.d/99-memory.conf`，swappiness=10；会产生磁盘 I/O，休眠另需完整配置与验证；
- **纯物理内存运行**：大内存主机保持原生 No Swap 状态。

### 状态验证

```bash
swapon --show
free -h
```

### 注销受控 Swap

- **注销磁盘 Swapfile（释放文件、注销 fstab 并恢复原生内核参数）**：
  ```bash
  sudo swapoff /swapfile && sudo rm -f /swapfile /etc/sysctl.d/99-memory.conf && sudo sed -i '\|/swapfile|d' /etc/fstab && sudo sysctl -w vm.swappiness=60 >/dev/null
  ```
- **注销 zram 内存盘（重置内核块设备归还内存、清理配置并还原 GRUB）**：
  ```bash
  sudo swapoff /dev/zram0 2>/dev/null || true
  sudo zramctl --reset /dev/zram0 2>/dev/null || true
  sudo rm -f /etc/systemd/zram-generator.conf.d/zram0.conf && sudo systemctl daemon-reload
  sudo sed -i 's/[[:space:]]*zswap\.enabled=0//g' /etc/default/grub && sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
  echo 1 | sudo tee /sys/module/zswap/parameters/enabled >/dev/null 2>&1 || true
  ```

## 常用运维操作

### 包管理与孤立依赖清理

```bash
# 检查并清理系统孤立依赖包 (Orphans)
sudo pacman -Rns $(pacman -Qtdq) 2>/dev/null || true

# 清理 pacman 历史包缓存 (需安装 pacman-contrib，保留最近 3 个版本)
sudo pacman -S --needed --noconfirm pacman-contrib && sudo paccache -r
```

需要 root shell 时：

```bash
sudo -i
```

确认要删除用户及其家目录时执行：

```bash
sudo userdel -r [HERE_USERNAME]
```
