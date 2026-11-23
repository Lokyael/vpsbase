#!/usr/bin/env bash
#
# vps-wipe.sh - VPS 在线安全销毁与整盘抹除脚本
#
# 适用场景：VPS 退租、回收或弃用前，在线粉碎隐私数据、填零所有磁盘空闲空间并破坏分区表。
# 无需进入服务商控制台救援系统（Rescue Mode）。
#
# 警告：此操作不可逆！执行后系统将立即瘫痪，所有数据将无法恢复！
#

set -Eeuo pipefail

show_help() {
    cat <<'EOF'
用法:
  vps-wipe.sh [选项]

选项:
  -f, --force        跳过交互式确认，直接执行全盘销毁（高危，慎用）
  -d, --disk <设备>  显式指定待抹除的底层整盘设备（例如 /dev/vda、/dev/nvme0n1）
  -h, --help         显示此帮助信息

示例:
  bash vps-wipe.sh
  bash vps-wipe.sh --force
EOF
}

# 1. 帮助查看（允许非 root 执行）
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        show_help
        exit 0
    fi
done

# 2. Root 权限门禁
if [[ $EUID -ne 0 ]]; then
    printf '❌ 必须以 root 权限执行此脚本。\n' >&2
    exit 1
fi

# 3. 参数解析
FORCE=0
TARGET_DISK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE=1
            shift
            ;;
        -d|--disk)
            [[ $# -ge 2 ]] || { printf '❌ --disk 需要指定设备路径\n' >&2; exit 1; }
            TARGET_DISK="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            printf '❌ 未知参数: %s\n' "$1" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

# 3. 目标整盘探测
resolve_root_disk() {
    local src dev pk
    src=$(findmnt -nvo SOURCE / 2>/dev/null || df -P / 2>/dev/null | awk 'NR==2 {print $1}')
    [[ -n "$src" ]] || return 1
    src=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")

    if command -v lsblk >/dev/null 2>&1; then
        pk=$(lsblk -no pkname "$src" 2>/dev/null | head -n 1)
        if [[ -n "$pk" ]]; then
            printf '/dev/%s\n' "$pk"
            return 0
        fi
        if [[ "$(lsblk -no type "$src" 2>/dev/null)" == "disk" ]]; then
            printf '%s\n' "$src"
            return 0
        fi
    fi

    if [[ "$src" =~ ^(/dev/nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    elif [[ "$src" =~ ^(/dev/[a-z]+)[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    elif [[ "$src" =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    [[ -b "$src" ]] && { printf '%s\n' "$src"; return 0; }
    return 1
}

if [[ -z "$TARGET_DISK" ]]; then
    if ! TARGET_DISK=$(resolve_root_disk); then
        printf '❌ 无法自动探测根文件系统所在的底层整盘设备，请使用 --disk 显式指定。\n' >&2
        exit 1
    fi
fi

if [[ ! -b "$TARGET_DISK" ]]; then
    printf '❌ 指定的目标磁盘设备不存在或不是块设备: %s\n' "$TARGET_DISK" >&2
    exit 1
fi

# 4. 高危二次确认门禁
if [[ $FORCE -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
        printf '❌ 非交互式终端且未指定 --force，已阻断退出以防误操作。\n' >&2
        exit 1
    fi

    cat <<EOF

============================================================
⚠️  高危警告：VPS 在线自毁与整盘抹除
============================================================
目标整盘设备: $TARGET_DISK
此操作将依次执行：
  1. 彻底粉碎 SSH 密钥、密码凭据、用户数据与系统日志；
  2. 用全零（0x00）填满所有未分配的磁盘扇区并强制落盘；
  3. 物理抹除底层磁盘的分区表、引导扇区与超级块；
  4. 输出完成报告并指导前往云控制台终结销毁。

此操作绝对不可逆！所有数据将彻底无法恢复！
============================================================

EOF
    printf '若确认销毁整台 VPS，请输入大写 "DESTROY" 并回车: '
    read -r confirm
    if [[ "$confirm" != "DESTROY" ]]; then
        printf '已取消操作，未对系统做出任何修改。\n'
        exit 0
    fi
fi

printf '\n>>> [1/4] 开始粉碎关键凭据与清理业务数据...\n'

wipe_path() {
    local p="$1"
    [[ -e "$p" ]] || return 0
    if command -v shred >/dev/null 2>&1; then
        shred -u -z "$p" 2>/dev/null || rm -f "$p" 2>/dev/null || true
    else
        local sz
        sz=$(wc -c < "$p" 2>/dev/null || printf '0')
        if [[ "$sz" -gt 0 ]]; then
            head -c "$sz" /dev/zero > "$p" 2>/dev/null || true
        fi
        rm -f "$p" 2>/dev/null || true
    fi
}

# 粉碎关键安全凭据
wipe_path /etc/shadow
wipe_path /etc/gshadow
wipe_path /etc/shadow-
wipe_path /etc/gshadow-
for k in /etc/ssh/ssh_host_* /root/.ssh/* /home/*/.ssh/*; do
    wipe_path "$k"
done

# 清理业务数据、容器与日志（保留系统核心命令与动态库，确保后续 dd 与 sync 正常执行）
rm -rf /home/* /root/* /opt/* /srv/* /tmp/* /var/tmp/* 2>/dev/null || true
rm -rf /var/lib/containers /var/lib/docker /var/lib/mysql /var/lib/postgresql /var/lib/redis 2>/dev/null || true
apt-get clean 2>/dev/null || pacman -Scc --noconfirm 2>/dev/null || dnf clean all 2>/dev/null || true
journalctl --rotate 2>/dev/null && journalctl --vacuum-time=1s 2>/dev/null || true
rm -rf /var/log/* 2>/dev/null || true

printf '>>> [2/4] 正在将全部未分配空闲扇区填零（请耐心等待写满）...\n'

# 填零所有可用空闲空间，覆盖所有已删除文件的历史残留
dd if=/dev/zero of=/zero.fill bs=4M status=progress 2>/dev/null || true
sync 2>/dev/null || true
rm -f /zero.fill
sync 2>/dev/null || true

printf '\n>>> [3/4] 正在物理抹除磁盘头部（MBR/GPT/超级块）: %s ...\n' "$TARGET_DISK"

# 物理抹除底层整盘前 200MB（销毁分区表、引导代码与文件系统超级块）
dd if=/dev/zero of="$TARGET_DISK" bs=1M count=200 conv=fsync 2>/dev/null || true

printf '\n>>> [4/4] 全盘销毁完成！\n'
printf '  - 关键凭据与业务数据已粉碎\n'
printf '  - 全部磁盘空闲空间已物理填零\n'
printf '  - 磁盘分区表、引导代码与超级块已抹除: %s\n\n' "$TARGET_DISK"
printf '✅ 本机数据已无恢复可能。请立即前往云服务商控制台彻底【销毁 / 删除实例（Destroy / Terminate）】。\n'
