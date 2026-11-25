#!/usr/bin/env bash
# server/os/reinstall/vps-wipe.sh - VPS 在线整盘销毁脚本（退租回收专用，不可逆）。

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

FORCE=0
TARGET_DISK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE=1
            shift
            ;;
        -d|--disk)
            [[ $# -ge 2 ]] || { printf '✘ %s\n' '--disk 需要指定设备路径' >&2; exit 1; }
            TARGET_DISK="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            printf '✘ 未知参数: %s\n' "$1" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    printf '✘ %s\n' '必须以 root 权限执行此脚本。' >&2
    exit 1
fi

resolve_root_disk() {
    local src pk
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
        printf '✘ %s\n' '无法自动探测根文件系统所在的底层整盘设备，请使用 --disk 显式指定。' >&2
        exit 1
    fi
fi

if [[ ! -b "$TARGET_DISK" ]]; then
    printf '✘ 指定的目标磁盘设备不存在或不是块设备: %s\n' "$TARGET_DISK" >&2
    exit 1
fi

if [[ $FORCE -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
        printf '✘ %s\n' '非交互式终端且未指定 --force，已阻断退出以防误操作。' >&2
        exit 1
    fi

    cat <<EOF

▲ 高危警告：VPS 在线整盘抹除（不可逆，所有数据将无法恢复）
目标整盘设备: $TARGET_DISK
将依次执行：
  1. 粉碎 SSH 密钥、密码凭据、用户数据与系统日志；
  2. 填零全部未分配磁盘空间并同步落盘；
  3. 抹除底层整盘前 200MB（分区表、引导代码与超级块）。

EOF
    printf '若确认销毁整台 VPS，请输入大写 "DESTROY" 并回车: '
    read -r confirm
    if [[ "$confirm" != "DESTROY" ]]; then
        printf '▲ %s\n' '已取消操作，未对系统做出任何修改。'
        exit 0
    fi
fi

printf '\n▶ [1/3] 粉碎关键凭据与业务数据...\n'

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

wipe_path /etc/shadow
wipe_path /etc/gshadow
wipe_path /etc/shadow-
wipe_path /etc/gshadow-
for k in /etc/ssh/ssh_host_* /root/.ssh/* /home/*/.ssh/*; do
    wipe_path "$k"
done

# 保留系统核心命令与动态库，确保后续 dd 与 sync 正常执行
rm -rf /home/* /root/* /opt/* /srv/* /tmp/* /var/tmp/* 2>/dev/null || true
rm -rf /var/lib/containers /var/lib/docker /var/lib/mysql /var/lib/postgresql /var/lib/redis 2>/dev/null || true
apt-get clean 2>/dev/null || pacman -Scc --noconfirm 2>/dev/null || dnf clean all 2>/dev/null || true
journalctl --rotate 2>/dev/null && journalctl --vacuum-time=1s 2>/dev/null || true
rm -rf /var/log/* 2>/dev/null || true

printf '▶ [2/3] 填零未分配空闲扇区...\n'
dd if=/dev/zero of=/zero.fill bs=4M status=progress 2>/dev/null || true
sync 2>/dev/null || true
rm -f /zero.fill
sync 2>/dev/null || true

printf '\n▶ [3/3] 物理抹除磁盘头部: %s ...\n' "$TARGET_DISK"
dd if=/dev/zero of="$TARGET_DISK" bs=1M count=200 conv=fsync 2>/dev/null || true

printf '\n✔ 销毁完成（%s）；请立即前往云服务商控制台删除实例（Destroy / Terminate）。\n' "$TARGET_DISK"
