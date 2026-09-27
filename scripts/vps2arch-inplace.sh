#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

die() { printf '\n❌ %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
say() { printf '\n▶ %s\n' "$*"; }
info() { printf '  ℹ️ %s\n' "$*"; }
notice() { printf '  ⚠️ %s\n' "$*"; }
success() { printf '  ✅ %s\n' "$*"; }
action() { printf '  👉 %s' "$*"; }

on_error() {
    local status=$? line=${BASH_LINENO[0]:-?} command=${BASH_COMMAND:-?}
    printf '\n❌ 失败：退出码=%s，脚本行=%s，命令：%s\n' "$status" "$line" "$command" >&2
    exit "$status"
}
trap on_error ERR
WARNINGS=()

# 私有挂载命名空间隔离与环境重入
if [[ "${VPS2ARCH_MOUNT_NS:-0}" != 1 ]]; then
    [[ $EUID -eq 0 ]] || die '必须以 root 执行'

    if command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
        HOST_PM=apt
        HOST_PKGS=(bash curl gnupg coreutils tar zstd util-linux iproute2 grep sed ca-certificates)
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        HOST_PM=rpm
        RPM_BIN=$(command -v dnf 2>/dev/null || command -v yum 2>/dev/null)
        HOST_PKGS=(bash curl gnupg2 coreutils tar zstd util-linux iproute grep sed gawk ca-certificates)
    elif command -v pacman >/dev/null 2>&1; then
        HOST_PM=pacman
        HOST_PKGS=(bash curl gnupg coreutils tar zstd util-linux iproute2 grep sed gawk ca-certificates)
    else
        die '只支持 apt/dpkg、dnf/yum 或 pacman 系统，未找到可用的包管理器'
    fi

    MISSING_PKGS=()
    for pkg in "${HOST_PKGS[@]}"; do
        if [[ "$HOST_PM" == apt ]]; then
            status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
            [[ "$status" == 'install ok installed' ]] || MISSING_PKGS+=("$pkg")
        elif [[ "$HOST_PM" == rpm ]]; then
            rpm -q "$pkg" >/dev/null 2>&1 || MISSING_PKGS+=("$pkg")
        else
            pacman -Qq "$pkg" >/dev/null 2>&1 || MISSING_PKGS+=("$pkg")
        fi
    done

    if ((${#MISSING_PKGS[@]} > 0)); then
        say "安装宿主依赖"
        if [[ "$HOST_PM" == apt ]]; then
            apt-get update
            apt-get install -y "${MISSING_PKGS[@]}"
        elif [[ "$HOST_PM" == rpm ]]; then
            "$RPM_BIN" install -y "${MISSING_PKGS[@]}"
        else
            pacman -Syu --needed --noconfirm "${MISSING_PKGS[@]}"
        fi
    fi

    command -v unshare >/dev/null 2>&1 || die '缺少 unshare 命令（util-linux）'

    SCRIPT_PATH=$(readlink -f "$0")
    export VPS2ARCH_MOUNT_NS=1
    exec unshare --mount --propagation private -- "$BASH" "$SCRIPT_PATH" "$@"
fi

# ============================================================
# Phase 1: 环境检查
# ============================================================
say "Phase 1: 环境检查"

HOST_PACKAGE_MANAGER=''
if command -v apt-get >/dev/null 2>&1; then
    HOST_PACKAGE_MANAGER=apt
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    HOST_PACKAGE_MANAGER=rpm
elif command -v pacman >/dev/null 2>&1; then
    HOST_PACKAGE_MANAGER=pacman
fi
info "宿主包管理器：${HOST_PACKAGE_MANAGER:-未知}"

for c in curl gpg sha256sum tar zstd mount umount unshare chroot findmnt lsblk blkid ip awk sed grep sort od tr cp mkdir dirname basename mktemp timeout sync; do
    need "$c"
done

ARCH=$(uname -m)
[[ "$ARCH" == x86_64 ]] || die "只支持 x86_64，检测到：$ARCH"

ROOT_DEV=$(findmnt -n -o SOURCE /)
[[ -L "$ROOT_DEV" ]] && ROOT_DEV=$(readlink -f "$ROOT_DEV")
if [[ "$ROOT_DEV" == "/dev/root" ]]; then
    dev_num=$(stat -c '%t:%T' / 2>/dev/null || true)
    if [[ -n "$dev_num" ]]; then
        maj=$((16#${dev_num%%:*}))
        min=$((16#${dev_num##*:}))
        real_dev=$(lsblk -lno NAME,MAJ:MIN | awk -v mm="$maj:$min" '$2 == mm {print "/dev/" $1; exit}')
        [[ -n "$real_dev" ]] && ROOT_DEV="$real_dev"
    fi
fi

ROOT_FS=$(findmnt -n -o FSTYPE /)
info "架构：$ARCH；根设备：$ROOT_DEV；根文件系统：$ROOT_FS"
ROOT_TYPE=$(lsblk -ndo TYPE -- "$ROOT_DEV" 2>/dev/null || true)
ROOT_DISK_NAME=$(lsblk -ndo PKNAME -- "$ROOT_DEV" 2>/dev/null || true)
ROOT_DISK=/dev/$ROOT_DISK_NAME
ROOT_UUID=$(blkid -s UUID -o value -- "$ROOT_DEV" 2>/dev/null || true)
[[ "$ROOT_DEV" == /dev/* && "$ROOT_TYPE" == part && "$ROOT_FS" == ext4 ]] || die "只支持直接 ext4 根分区：$ROOT_DEV ($ROOT_FS)"
[[ -b "$ROOT_DISK" && "$ROOT_UUID" =~ ^[[:xdigit:]-]+$ ]] || die '根设备信息无效'

ROOT_FREE_KB=$(df -k --output=avail / | tail -1 | tr -d ' ')
[[ "$ROOT_FREE_KB" =~ ^[0-9]+$ && "$ROOT_FREE_KB" -ge 2621440 ]] \
    || die "根分区剩余空间不足 2.5GB（当前可用: $((ROOT_FREE_KB/1024))MB）"

PTTYPE=$(blkid -p -o value -s PTTYPE -- "$ROOT_DISK" 2>/dev/null || true)
PTTYPE=$(printf '%s' "$PTTYPE" | tr 'A-Z' 'a-z')
[[ "$PTTYPE" =~ ^(gpt|dos|msdos)$ ]] || die "不支持的分区表类型：$PTTYPE"

BOOT_MODE=BIOS
ESP_MOUNT=''
ESP_DEV=''
ESP_UUID=''
if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE=UEFI
    for candidate in /boot/efi /efi /boot; do
        candidate_info=$(findmnt -n -o SOURCE,FSTYPE --mountpoint "$candidate" 2>/dev/null || true)
        [[ -n "$candidate_info" ]] || continue
        read -r src fs <<< "$candidate_info"
        if [[ "$src" == /dev/* && "$fs" =~ ^(vfat|fat|msdos)$ ]]; then
            candidate_type=$(lsblk -ndo TYPE -- "$src" 2>/dev/null || true)
            candidate_disk_name=$(lsblk -ndo PKNAME -- "$src" 2>/dev/null || true)
            candidate_disk=/dev/$candidate_disk_name
            [[ "$candidate_type" == part && "$candidate_disk_name" == "$ROOT_DISK_NAME" ]] \
                || die "UEFI ESP 不是根磁盘上的直接分区：$candidate ($src)"
            candidate_disk_pttype=$(blkid -p -o value -s PTTYPE -- "$candidate_disk" 2>/dev/null || true)
            candidate_disk_pttype=$(printf '%s' "$candidate_disk_pttype" | tr 'A-Z' 'a-z')
            [[ "$candidate_disk_pttype" == "$PTTYPE" ]] \
                || die "UEFI ESP 与根分区的分区表不一致：$candidate ($candidate_disk_pttype / $PTTYPE)"
            candidate_part_type=$(blkid -p -o value -s PART_ENTRY_TYPE -- "$src" 2>/dev/null || true)
            candidate_part_type=$(printf '%s' "$candidate_part_type" | tr 'A-Z' 'a-z')
            candidate_part_type=${candidate_part_type#0x}
            if [[ "$PTTYPE" == gpt ]]; then
                [[ "$candidate_part_type" == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] \
                    || die "挂载点 $candidate 不是 GPT ESP 分区：$candidate_part_type"
            else
                [[ "$candidate_part_type" == ef ]] \
                    || die "挂载点 $candidate 不是 MBR ESP 分区：$candidate_part_type"
            fi
            [[ -z "$ESP_MOUNT" ]] || die "检测到多个候选 ESP：$ESP_MOUNT 和 $candidate"
            ESP_MOUNT="$candidate"
            ESP_DEV="$src"
            ESP_UUID=$(blkid -s UUID -o value -- "$ESP_DEV" 2>/dev/null || true)
        fi
    done
    [[ -n "$ESP_MOUNT" && "$ESP_UUID" =~ ^[[:xdigit:]-]+$ ]] || die 'UEFI 未找到已挂载的 FAT ESP'
else
    [[ -z "$(findmnt -n -o SOURCE --mountpoint /boot 2>/dev/null || true)" ]] || die 'BIOS 不支持独立 /boot'
fi
info "启动模式：$BOOT_MODE；ESP：${ESP_DEV:-无}；ESP 挂载点：${ESP_MOUNT:-无}"

if [[ "$BOOT_MODE" == BIOS && "$PTTYPE" == gpt ]]; then
    grep -qiE '21686148-6449-6e6f-744e-656564454649|BIOS boot' \
        < <(lsblk -rno PARTTYPE,PARTTYPENAME -- "$ROOT_DISK") \
        || die 'BIOS + GPT 缺少 BIOS boot 分区'
fi

# ============================================================
# Phase 2: 采集网络参数
# ============================================================
say "Phase 2: 采集网络参数"

ROUTE=$(ip -4 route show default)
[[ $(grep -c . <<< "$ROUTE" || true) -eq 1 ]] || die 'IPv4 默认路由不是唯一一条'

IS_DHCP=0
if [[ "$ROUTE" == *" proto dhcp "* ]] \
    || ( [[ -f /etc/network/interfaces ]] && grep -qE '^[[:space:]]*iface[[:space:]]+.*[[:space:]]+inet[[:space:]]+dhcp' /etc/network/interfaces 2>/dev/null ) \
    || ( [[ -d /etc/systemd/network ]] && grep -rqE '^[[:space:]]*DHCP=(yes|ipv4|true)' /etc/systemd/network/ 2>/dev/null ); then
    IS_DHCP=1
fi

IFACE=$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}' <<< "$ROUTE")
GATEWAY=$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1);exit}}' <<< "$ROUTE")
[[ "$IFACE" =~ ^[[:alnum:]_.:-]+$ ]] || die "网卡异常：$IFACE"
[[ "$GATEWAY" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "网关异常：$GATEWAY"
IP_CIDR=$(ip -4 -o addr show dev "$IFACE" scope global | awk '{print $4; exit}')
[[ "$IP_CIDR" =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ ]] || die "IPv4 异常或未检测到有效 IPv4：$IP_CIDR"
STATIC_IPV4_COUNT=$(ip -4 -o addr show dev "$IFACE" scope global | awk '{count++} END {print count + 0}')
IPV6_COUNT=$(ip -6 -o addr show dev "$IFACE" scope global | awk 'END {print NR + 0}')
if [[ "$STATIC_IPV4_COUNT" -gt 1 ]]; then
    WARNINGS+=("检测到 $STATIC_IPV4_COUNT 个 IPv4，仅配置首个：$IP_CIDR")
fi
if [[ "$IPV6_COUNT" -gt 0 ]]; then
    WARNINGS+=("检测到 $IPV6_COUNT 个全局 IPv6 地址，未迁移到新系统网络配置")
fi
IFACE_MAC=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null || true)
[[ "$IFACE_MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || IFACE_MAC=''

info "网络参数：接口=$IFACE，MAC=${IFACE_MAC:-未知}，IPv4=$IP_CIDR，网关=$GATEWAY，网络模式=$([[ "$IS_DHCP" -eq 1 ]] && echo 'DHCP' || echo '静态')"

# ============================================================
# Phase 3: 配置与连通性测试
# ============================================================
say "Phase 3: 配置与连通性测试"

is_valid_public_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    case "$ip" in
        0.*|127.*|10.*|192.168.*|169.254.*|224.*|240.*|255.*) return 1 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 1 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 1 ;;
        *) return 0 ;;
    esac
}

test_dns_resolve() {
    local res_ip
    res_ip=$(timeout 3s getent ahostsv4 archlinux.org 2>/dev/null | awk '{print $1; exit}' || true)
    if [[ -n "$res_ip" ]] && is_valid_public_ip "$res_ip"; then
        return 0
    fi
    res_ip=$(timeout 3s getent ahostsv4 kernel.org 2>/dev/null | awk '{print $1; exit}' || true)
    if [[ -n "$res_ip" ]] && is_valid_public_ip "$res_ip"; then
        return 0
    fi
    return 1
}

test_dns_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    case "$ip" in
        0.*|127.*|255.*) return 1 ;;
    esac
    local tmp_conf target_file ok=0
    tmp_conf=$(mktemp)
    printf 'nameserver %s\noptions timeout:3 attempts:1\n' "$ip" > "$tmp_conf"
    target_file=$(readlink -f /etc/resolv.conf 2>/dev/null || printf '/etc/resolv.conf')
    [[ -e "$target_file" ]] || target_file=/etc/resolv.conf
    touch "$target_file" 2>/dev/null || true
    if mount --bind "$tmp_conf" "$target_file" 2>/dev/null; then
        test_dns_resolve && ok=1
        umount "$target_file" 2>/dev/null || true
    fi
    rm -f "$tmp_conf"
    return $((1 - ok))
}

DEFAULT_DNS=''
for f in /etc/resolv.conf /run/systemd/resolve/resolv.conf; do
    [[ -s "$f" ]] || continue
    while read -r line; do
        ns=$(awk '$1 == "nameserver" && $2 ~ /^[0-9]+(\.[0-9]+){3}$/ {print $2; exit}' <<< "$line")
        if [[ -n "$ns" && "$ns" != 127.* ]]; then
            DEFAULT_DNS="$ns"
            break 2
        fi
    done < "$f"
done

DNS_LIST=''
DNS_CANDIDATES=()
[[ -n "$DEFAULT_DNS" ]] && DNS_CANDIDATES+=("$DEFAULT_DNS")
DNS_CANDIDATES+=(1.1.1.1 8.8.8.8)

for cand in "${DNS_CANDIDATES[@]}"; do
    if test_dns_ip "$cand"; then
        DNS_LIST="$cand"
        success "DNS 校验通过：$DNS_LIST"
        break
    fi
done

if [[ -z "$DNS_LIST" ]]; then
    notice '默认与备选公共 DNS 测试均失败（超时 >3000ms 或被阻断）'
    dns_ok=0
    for ((attempt=1; attempt<=3; attempt++)); do
        action "[$attempt/3] 请输入自定义 DNS 服务器 IPv4 地址: "
        input_dns=''
        if read -r input_dns < /dev/tty && [[ -n "$input_dns" ]]; then
            if test_dns_ip "$input_dns"; then
                DNS_LIST="$input_dns"
                dns_ok=1
                success "DNS 校验通过：$DNS_LIST"
                break
            else
                notice "输入的 DNS [$input_dns] 测试失败"
            fi
        else
            notice "输入为空"
        fi
    done
    ((dns_ok)) || die 'DNS 可用性测试连续 3 次失败，终止操作'
fi

test_mirror() {
    local url="${1%/}"
    [[ "$url" =~ ^https?://[A-Za-z0-9._~:/?#@!$\&\+\-=%]+$ ]] || return 1
    local sample
    sample=$(curl --fail --location --proto '=http,https' --connect-timeout 3 --max-time 3 \
        --silent --show-error --range 0-511 "$url/iso/latest/sha256sums.txt" 2>/dev/null || true)
    if [[ -n "$sample" ]] && grep -qiE '[0-9a-f]{64}[[:space:]]+archlinux' <<< "$sample" \
        && ! grep -qiE '<!doctype|<html|<head|<body' <<< "$sample"; then
        return 0
    fi
    sample=$(curl --fail --location --proto '=http,https' --connect-timeout 3 --max-time 3 \
        --silent --show-error --range 0-127 "$url/core/os/x86_64/core.db" 2>/dev/null || true)
    if [[ -n "$sample" ]] && ! grep -qiE '<!doctype|<html|<head|<body' <<< "$sample"; then
        return 0
    fi
    return 1
}

DEFAULT_MIRROR=''
if [[ "$HOST_PACKAGE_MANAGER" == pacman && -s /etc/pacman.d/mirrorlist ]]; then
    raw_url=$(grep -E '^[[:space:]]*Server[[:space:]]*=' /etc/pacman.d/mirrorlist 2>/dev/null \
        | head -1 | sed -E 's/^[[:space:]]*Server[[:space:]]*=[[:space:]]*//; s|/\$repo.*||')
    DEFAULT_MIRROR="${raw_url%/}"
fi
[[ -n "$DEFAULT_MIRROR" ]] || DEFAULT_MIRROR='https://geo.mirror.pkgbuild.com'

ARCH_MIRRORS=()
if test_mirror "$DEFAULT_MIRROR"; then
    ARCH_MIRRORS=("$DEFAULT_MIRROR")
else
    notice "镜像源 [$DEFAULT_MIRROR] 测试失败（响应超时 >3000ms 或被阻断）"
    mirror_ok=0
    for ((attempt=1; attempt<=3; attempt++)); do
        action "[$attempt/3] 请输入 Arch 镜像源 URL: "
        input_mirror=''
        if read -r input_mirror < /dev/tty && [[ -n "$input_mirror" ]]; then
            input_mirror="${input_mirror%/}"
            if test_mirror "$input_mirror"; then
                ARCH_MIRRORS=("$input_mirror")
                mirror_ok=1
                success "源镜像校验通过：$input_mirror"
                break
            else
                notice "输入的镜像源 [$input_mirror] 测试失败"
            fi
        else
            notice "输入为空"
        fi
    done
    ((mirror_ok)) || die '镜像源测试连续 3 次失败，终止操作'
fi

say "配置新系统终态安全参数"

ADMIN_USER=''
while true; do
    action "新系统登录普通用户名 (禁止为 root): "
    read -r ADMIN_USER < /dev/tty || true
    ADMIN_USER=$(printf '%s' "$ADMIN_USER" | tr -d '[:space:]')
    [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ && "$ADMIN_USER" != "root" ]] && break
    notice "用户名不合法（小写字母开头，且不能为 root），请重新输入"
done

ADMIN_PASSWORD=''
while true; do
    action "新用户 sudo 提权密码: "
    read -r -s p1 < /dev/tty || true; printf '\n'
    action "再次输入确认密码: "
    read -r -s p2 < /dev/tty || true; printf '\n'
    if [[ -n "$p1" && "$p1" == "$p2" ]]; then
        ADMIN_PASSWORD="$p1"
        break
    fi
    notice "两次密码输入不匹配或为空，请重新输入"
done

TARGET_SSH_PORT=''
action "新系统 SSH 端口 [默认 22]: "
read -r TARGET_SSH_PORT < /dev/tty || true
TARGET_SSH_PORT="${TARGET_SSH_PORT:-22}"
[[ "$TARGET_SSH_PORT" =~ ^[0-9]+$ && "$TARGET_SSH_PORT" -ge 1 && "$TARGET_SSH_PORT" -le 65535 ]] \
    || die "SSH 端口无效: $TARGET_SSH_PORT"

DEFAULT_ADMIN_KEY=''
if [[ -s /root/.ssh/authorized_keys ]] && grep -qE '^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]{68,}={0,2}([[:space:]].*)?$' /root/.ssh/authorized_keys; then
    DEFAULT_ADMIN_KEY=$(grep -m1 -E '^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]{68,}={0,2}([[:space:]].*)?$' /root/.ssh/authorized_keys)
    info "检测到宿主有效 Ed25519 公钥"
fi

ADMIN_PUBKEY=''
while true; do
    if [[ -n "$DEFAULT_ADMIN_KEY" ]]; then
        action "新系统登录 Ed25519 公钥 [回车默认使用宿主公钥]: "
        read -r ADMIN_PUBKEY < /dev/tty || true
        ADMIN_PUBKEY="${ADMIN_PUBKEY:-$DEFAULT_ADMIN_KEY}"
    else
        action "请输入新系统登录的 Ed25519 公钥文本: "
        read -r ADMIN_PUBKEY < /dev/tty || true
    fi
    ADMIN_PUBKEY=$(printf '%s' "$ADMIN_PUBKEY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ "$ADMIN_PUBKEY" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]{68,}={0,2}([[:space:]].*)?$ ]] && break
    notice "公钥无效（必须为 ssh-ed25519 格式），请重新输入"
done

printf '\n  ── 配置确认 ──\n'
notice '即将原地重装，旧根分区与 ESP 将被清空且不可逆！'
info "目标磁盘：$ROOT_DISK"
info "根分区：$ROOT_DEV ($ROOT_FS)"
info "启动模式：$BOOT_MODE"
if [[ -n "$ESP_MOUNT" ]]; then
    info "ESP 挂载：$ESP_MOUNT ($ESP_DEV)"
else
    info 'ESP 挂载：无'
fi
info "网卡接口：$IFACE"
info "网卡 MAC：${IFACE_MAC:-未知}"
info "网络配置：$([[ "$IS_DHCP" -eq 1 ]] && echo "DHCP (当前: $IP_CIDR)" || echo "静态 $IP_CIDR via $GATEWAY")"
info "DNS 服务器：$DNS_LIST"
info "软件源镜像：${ARCH_MIRRORS[*]}"
info "登录用户：$ADMIN_USER"
info "SSH 端口：$TARGET_SSH_PORT"
info "登录认证：仅 Ed25519 公钥 (禁用 root 登录与密码认证)"
if ((${#WARNINGS[@]} > 0)); then
    notice '预检告警列表：'
    for warning in "${WARNINGS[@]}"; do
        notice "$warning"
    done
fi
notice '请确认已准备好控制台/VNC，并已备份重要数据。'
action '输入 REINSTALL-ARCH 继续，其他输入取消: '
CONFIRMATION=''
if ! read -r CONFIRMATION < /dev/tty; then
    die '无法读取终端确认，操作已取消'
fi
[[ "$CONFIRMATION" == REINSTALL-ARCH ]] || die '确认字符串不匹配，操作已取消'

# ============================================================
# Phase 4: 下载并验证 bootstrap
# ============================================================
say "Phase 4: 下载并验证 bootstrap"

WORKDIR=/root.vps2arch.$ARCH.$$
PRESERVE=$WORKDIR/preserve
mkdir -m 0700 "$WORKDIR"
mkdir -m 0700 "$PRESERVE"
printf '%s\n' "$ADMIN_PUBKEY" > "$PRESERVE/authorized_keys"
chmod 0600 "$PRESERVE/authorized_keys"
printf '%s\n' "$ADMIN_PASSWORD" > "$PRESERVE/password"
chmod 0600 "$PRESERVE/password"
unset ADMIN_PASSWORD p1 p2

fetch() {
    local rel="$1" out="$2" base
    for base in "${ARCH_MIRRORS[@]}"; do
        curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 \
            --connect-timeout 15 --speed-time 15 --speed-limit 1024 \
            --silent --show-error --output "$out" "$base/$rel" && return 0
    done
    die "下载失败：$rel"
}

NAME=archlinux-bootstrap-$ARCH.tar.zst
fetch iso/latest/$NAME "$WORKDIR/$NAME"
fetch iso/latest/$NAME.sig "$WORKDIR/$NAME.sig"
fetch iso/latest/sha256sums.txt "$WORKDIR/sha256sums.txt"

GNUPGHOME=$WORKDIR/gnupg
mkdir -m 700 "$GNUPGHOME"
FPR="${ARCH_RELEASE_FPR:-3E80CA1A8B89F69CBA57D98A76A5EF9054449A5C}"

if ! gpg --homedir "$GNUPGHOME" --batch --auto-key-locate clear,wkd \
    --locate-external-key pierre@archlinux.org >/dev/null 2>&1; then
    gpg --homedir "$GNUPGHOME" --batch \
        --keyserver keyserver.ubuntu.com --recv-keys "$FPR" >/dev/null 2>&1 \
        || gpg --homedir "$GNUPGHOME" --batch \
        --keyserver keys.openpgp.org --recv-keys "$FPR" >/dev/null 2>&1 \
        || die '获取 Arch 发布密钥失败'
fi

ACTUAL=$(gpg --homedir "$GNUPGHOME" --with-colons --fingerprint | awk -F: '$1=="fpr"{print toupper($10);exit}')
[[ "$ACTUAL" == "$FPR" ]] || die "发布密钥指纹不匹配：$ACTUAL"
STATUS=$(gpg --homedir "$GNUPGHOME" --batch --status-fd=1 \
    --verify "$WORKDIR/$NAME.sig" "$WORKDIR/$NAME" 2>"$WORKDIR/gpg.log" || true)
grep -Fq "VALIDSIG $FPR " <<< "$STATUS" || { cat "$WORKDIR/gpg.log" >&2; die 'PGP 验签失败'; }

awk -v name="$NAME" '$2 == name {print; found=1} END {exit !found}' \
    "$WORKDIR/sha256sums.txt" > "$WORKDIR/sum" \
    || die 'SHA256 清单中缺少 bootstrap 条目'
(cd "$WORKDIR" && sha256sum -c sum)
tar -xpf "$WORKDIR/$NAME" -C "$WORKDIR"

# 动态链接器封装：绕过宿主旧 glibc 兼容性限制
BOOTSTRAP=$WORKDIR/root.$ARCH
LD=''
for f in "$BOOTSTRAP"/usr/lib/ld-linux-*.so.2; do LD="$f"; break; done
[[ -x "$BOOTSTRAP/bin/bash" && -x "$LD" ]] || die 'bootstrap 解压结果异常'
bhost() { local bin="$1"; shift; "$LD" --library-path "$BOOTSTRAP/usr/lib" "$BOOTSTRAP/usr/bin/$bin" "$@"; }
bchroot() { "$LD" --library-path "$BOOTSTRAP/usr/lib" "$BOOTSTRAP/usr/bin/chroot" "$BOOTSTRAP" "$@"; }

# ============================================================
# Phase 5: 准备隔离环境
# ============================================================
say "Phase 5: 准备隔离环境"

swapoff -a 2>/dev/null || true

while read -r target source fstype; do
    [[ "$target" == / ]] && continue
    case "$target" in /dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*) continue ;; esac
    if [[ "$BOOT_MODE" == UEFI && ( "$target" == "$ESP_MOUNT" || "$target" == "$ESP_MOUNT"/* ) ]]; then
        continue
    fi
    info "卸载：$target ($source)"
    umount -- "$target" 2>/dev/null || umount -l -- "$target" || die "无法卸载：$target"
done < <(findmnt -R / -rn -o TARGET,SOURCE,FSTYPE | awk '$1 != "/"' | sort -r)

mkdir -p "$BOOTSTRAP/mnt" "$BOOTSTRAP/proc" "$BOOTSTRAP/sys" "$BOOTSTRAP/dev" "$BOOTSTRAP/run"
mount --bind / "$BOOTSTRAP/mnt"
mount --make-rslave "$BOOTSTRAP/mnt"
mount -t proc proc "$BOOTSTRAP/proc" -o nosuid,noexec,nodev
mount --rbind /sys "$BOOTSTRAP/sys"; mount --make-rslave "$BOOTSTRAP/sys"
mount --rbind /dev "$BOOTSTRAP/dev"; mount --make-rslave "$BOOTSTRAP/dev"
mount --bind /run "$BOOTSTRAP/run"; mount --make-rslave "$BOOTSTRAP/run"
if [[ "$BOOT_MODE" == UEFI ]]; then
    mkdir -p "$BOOTSTRAP/mnt$ESP_MOUNT"
    mount --bind "$ESP_MOUNT" "$BOOTSTRAP/mnt$ESP_MOUNT"
fi

for target in "$BOOTSTRAP/mnt/dev" "$BOOTSTRAP/mnt/proc" \
    "$BOOTSTRAP/mnt/sys" "$BOOTSTRAP/mnt/run"; do
    umount -R -l -- "$target" 2>/dev/null || true
done
info '挂载状态：'
findmnt -R "$BOOTSTRAP/mnt" -rn -o TARGET,SOURCE,FSTYPE || true

rm -f "$BOOTSTRAP/etc/resolv.conf"
for dns in $DNS_LIST; do
    printf 'nameserver %s\n' "$dns"
done > "$BOOTSTRAP/etc/resolv.conf"

MIRROR=$BOOTSTRAP/etc/pacman.d/mirrorlist
mkdir -p "$(dirname "$MIRROR")"
: > "$MIRROR"
for server in "${ARCH_MIRRORS[@]}"; do
    printf 'Server = %s/$repo/os/$arch\n' "$server" >> "$MIRROR"
done

if grep -q '^[#[:space:]]*ParallelDownloads' "$BOOTSTRAP/etc/pacman.conf"; then
    sed -i 's/^[#[:space:]]*ParallelDownloads.*/ParallelDownloads = 5/' "$BOOTSTRAP/etc/pacman.conf"
else
    sed -i '/^\[options\]/a ParallelDownloads = 5' "$BOOTSTRAP/etc/pacman.conf"
fi
if ! grep -q '^DisableDownloadTimeout' "$BOOTSTRAP/etc/pacman.conf"; then
    sed -i '/^\[options\]/a DisableDownloadTimeout' "$BOOTSTRAP/etc/pacman.conf"
fi

# ============================================================
# Phase 6: 清理旧根文件系统
# ============================================================
say "Phase 6: 清理旧根文件系统"

WORK_NAME=$(basename "$WORKDIR")
ESP_TARGET=''
ESP_PARENT=''
if [[ -n "$ESP_MOUNT" ]]; then
    ESP_TARGET=/mnt$ESP_MOUNT
    ESP_PARENT=$(dirname "$ESP_TARGET")
fi

bchroot /bin/bash -s -- /mnt/$WORK_NAME "$ESP_TARGET" "$ESP_PARENT" <<'WIPE'
set -Eeuo pipefail
shopt -s dotglob nullglob
work="$1"; esp="$2"; parent="$3"

die() { printf '\n❌ %s\n' "$*" >&2; exit 1; }
info() { printf '  ℹ️ %s\n' "$*"; }

on_wipe_error() {
    local status=$? line=${BASH_LINENO[0]:-?} command=${BASH_COMMAND:-?}
    printf '\n❌ 清理失败：退出码=%s，脚本行=%s，命令：%s\n' "$status" "$line" "$command" >&2
    exit "$status"
}
trap on_wipe_error ERR

clear_attrs() {
    command -v chattr >/dev/null 2>&1 || return 0
    find "$1" -xdev -exec chattr -i -a -- {} + 2>/dev/null || true
}

for item in /mnt/* /mnt/.[!.]* /mnt/..?*; do
    [[ -e "$item" || -L "$item" ]] || continue
    [[ "$item" == "$work" ]] && continue
    [[ -n "$esp" && "$item" == "$esp" ]] && continue
    [[ -n "$parent" && "$item" == "$parent" ]] && continue
    case "$item" in
        /mnt/dev|/mnt/proc|/mnt/sys|/mnt/run) continue ;;
    esac
    info "清理：$item"
    umount -R -l -- "$item" 2>/dev/null || true
    clear_attrs "$item"
    rm -rf -- "$item"
done

if [[ -n "$esp" && -n "$parent" && "$parent" != /mnt ]]; then
    for item in "$parent"/* "$parent"/.[!.]* "$parent"/..?*; do
        [[ -e "$item" || -L "$item" ]] || continue
        if [[ "$item" != "$esp" ]]; then
            info "清理：$item"
            umount -R -l -- "$item" 2>/dev/null || true
            clear_attrs "$item"
            rm -rf -- "$item"
        fi
    done
fi

if [[ -n "$esp" ]]; then
    for item in "$esp"/* "$esp"/.[!.]* "$esp"/..?*; do
        [[ -e "$item" || -L "$item" ]] || continue
        clear_attrs "$item"
        rm -rf -- "$item"
    done
fi

for item in /mnt/* /mnt/.[!.]* /mnt/..?*; do
    [[ -e "$item" || -L "$item" ]] || continue
    allowed=0
    [[ "$item" == "$work" ]] && allowed=1
    [[ -n "$esp" && "$item" == "$esp" ]] && allowed=1
    [[ -n "$parent" && "$item" == "$parent" ]] && allowed=1
    case "$item" in
        /mnt/dev|/mnt/proc|/mnt/sys|/mnt/run|/mnt/lost+found) allowed=1 ;;
    esac
    if ((allowed == 0)); then
        die "清理后仍有未豁免内容：$item"
    fi
done
WIPE

# ============================================================
# Phase 7: 安装基础系统
# ============================================================
say "Phase 7: 安装基础系统"

umask 022
bhost mkdir -p "$BOOTSTRAP/mnt/etc/pacman.d"
bhost cp -f "$MIRROR" "$BOOTSTRAP/mnt/etc/pacman.d/mirrorlist"
bchroot pacman-key --init
bchroot pacman-key --populate archlinux

PACKAGES='base linux openssh grub sudo which'
EFI_VARS_WRITABLE=0
if [[ "$BOOT_MODE" == UEFI && -d "$BOOTSTRAP/sys/firmware/efi/efivars" && -w "$BOOTSTRAP/sys/firmware/efi/efivars" ]]; then
    EFI_VARS_WRITABLE=1
    PACKAGES="$PACKAGES efibootmgr"
fi
if [[ "$BOOT_MODE" == UEFI && "$EFI_VARS_WRITABLE" == 0 ]]; then
    WARNINGS+=('EFI NVRAM 不可写，依赖 BOOTX64.EFI 回退启动')
fi
bchroot pacstrap -K -M /mnt $PACKAGES

# ============================================================
# Phase 8: 配置新系统
# ============================================================
say "Phase 8: 配置新系统"

mount -t proc proc "$BOOTSTRAP/mnt/proc" -o nosuid,noexec,nodev
mount --rbind /sys "$BOOTSTRAP/mnt/sys"; mount --make-rslave "$BOOTSTRAP/mnt/sys"
mount --rbind /dev "$BOOTSTRAP/mnt/dev"; mount --make-rslave "$BOOTSTRAP/mnt/dev"
mount --bind /run "$BOOTSTRAP/mnt/run"; mount --make-rslave "$BOOTSTRAP/mnt/run"
if [[ "$BOOT_MODE" == UEFI ]]; then
    mkdir -p "$BOOTSTRAP/mnt$ESP_MOUNT"
    mountpoint -q "$BOOTSTRAP/mnt$ESP_MOUNT" || mount --bind "$ESP_MOUNT" "$BOOTSTRAP/mnt$ESP_MOUNT"
fi

bhost mkdir -p "$BOOTSTRAP/mnt/tmp"
bhost cp -a "$PRESERVE/authorized_keys" "$BOOTSTRAP/mnt/tmp/admin_authorized_keys"
bhost cp -a "$PRESERVE/password" "$BOOTSTRAP/mnt/tmp/admin_password"
bhost chmod 0600 "$BOOTSTRAP/mnt/tmp/admin_authorized_keys" "$BOOTSTRAP/mnt/tmp/admin_password"

bchroot /usr/bin/chroot /mnt /bin/bash -s -- \
    "$BOOT_MODE" "$ROOT_UUID" "$ROOT_DISK" "$ESP_MOUNT" "$ESP_UUID" \
    "$IFACE" "$IFACE_MAC" "$IP_CIDR" "$GATEWAY" "$DNS_LIST" \
    "$ADMIN_USER" "$TARGET_SSH_PORT" "$WORK_NAME" "$IS_DHCP" <<'CONFIG'
set -Eeuo pipefail
umask 022
mode="$1"; root_uuid="$2"; root_disk="$3"; esp_mount="$4"; esp_uuid="$5"
iface="$6"; iface_mac="$7"; ip_cidr="$8"; gateway="$9"; dns_list="${10}"
admin_user="${11}"; target_ssh_port="${12}"; work_name="${13}"; is_dhcp="${14:-0}"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

die() { printf '\n❌ %s\n' "$*" >&2; exit 1; }
info() { printf '  ℹ️ %s\n' "$*"; }
notice() { printf '  ⚠️ %s\n' "$*"; }
success() { printf '  ✅ %s\n' "$*"; }

on_config_error() {
    local status=$? line=${BASH_LINENO[0]:-?} command=${BASH_COMMAND:-?}
    printf '\n❌ 新系统配置失败：退出码=%s，脚本行=%s，命令：%s\n' "$status" "$line" "$command" >&2
    exit "$status"
}
trap on_config_error ERR

efi_vars_writable=0
if [[ "$mode" == UEFI && -d /sys/firmware/efi/efivars && -w /sys/firmware/efi/efivars ]]; then
    efi_vars_writable=1
fi
mkdir -p /etc/systemd/network /boot/grub
chmod 0755 /etc /etc/systemd /etc/systemd/network
cd /

printf 'UUID=%s / ext4 defaults,errors=remount-ro 0 1\n' "$root_uuid" > /etc/fstab
if [[ "$mode" == UEFI ]]; then
    printf 'UUID=%s %s vfat umask=0077 0 2\n' "$esp_uuid" "$esp_mount" >> /etc/fstab
fi

if [[ -n "$iface_mac" ]]; then
    match_rule="MACAddress=$iface_mac"
else
    match_rule="Name=$iface"
fi

if [[ "$is_dhcp" -eq 1 ]]; then
    cat > /etc/systemd/network/10-network.network <<EOF
[Match]
$match_rule

[Network]
DHCP=yes
DNS=$dns_list
EOF
else
    cat > /etc/systemd/network/10-network.network <<EOF
[Match]
$match_rule

[Network]
DHCP=no
Address=$ip_cidr
DNS=$dns_list

[Route]
Destination=0.0.0.0/0
Gateway=$gateway
GatewayOnLink=yes
EOF
fi

chmod 0644 /etc/systemd/network/10-network.network
NETWORK_FILE=/etc/systemd/network/10-network.network
[[ -s "$NETWORK_FILE" ]] || die "网络配置不存在：$NETWORK_FILE"
[[ -x /usr/lib/systemd/systemd-networkd ]] || die '缺少 systemd-networkd'
id systemd-network >/dev/null 2>&1 || die '缺少 systemd-network 用户'

grep -Fxq "$match_rule" "$NETWORK_FILE" || die "网络配置缺少匹配规则：$match_rule"
if [[ "$is_dhcp" -eq 1 ]]; then
    grep -Fxq "DHCP=yes" "$NETWORK_FILE" || die "网络配置缺少 DHCP=yes"
else
    grep -Fxq "Address=$ip_cidr" "$NETWORK_FILE" || die "网络配置缺少 Address"
    grep -Fxq "Gateway=$gateway" "$NETWORK_FILE" || die "网络配置缺少 Gateway"
    for section in '[Match]' '[Network]' '[Route]'; do
        grep -Fxq "$section" "$NETWORK_FILE" || die "网络配置缺少节：$section"
    done
fi

info "网络配置校验通过：$match_rule $([[ "$is_dhcp" -eq 1 ]] && echo 'DHCP=yes' || echo "$ip_cidr via $gateway") (DNS: $dns_list)"

printf 'archlinux\n' > /etc/hostname
if [[ -f /etc/locale.gen ]]; then
    sed -i 's/^#[[:space:]]*\(en_US\.UTF-8[[:space:]]\+UTF-8\)/\1/' /etc/locale.gen
    locale-gen >/dev/null 2>&1 || true
fi
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf

rm -f /etc/resolv.conf
for dns in $dns_list; do printf 'nameserver %s\n' "$dns"; done > /etc/resolv.conf
chmod 644 /etc/resolv.conf

# 1. 创建普通用户并授权 wheel
if id "$admin_user" &>/dev/null; then
    usermod -aG wheel "$admin_user"
else
    useradd -m -G wheel -s /bin/bash "$admin_user"
fi

mkdir -p "/home/$admin_user/.ssh"
cp -f /tmp/admin_authorized_keys "/home/$admin_user/.ssh/authorized_keys"
rm -f /tmp/admin_authorized_keys
chmod 0700 "/home/$admin_user/.ssh"
chmod 0600 "/home/$admin_user/.ssh/authorized_keys"
chown -R "$admin_user:$admin_user" "/home/$admin_user/.ssh"

printf '%s:%s\n' "$admin_user" "$(< /tmp/admin_password)" | chpasswd
rm -f /tmp/admin_password

# 2. 锁定 root 账户并清理 root 密钥
passwd -l root
rm -rf /root/.ssh

# 3. 配置 wheel 组 sudo
mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

# 4. 生成专属 Ed25519 主机密钥，清理其他算法
rm -f /etc/ssh/ssh_host_*
ssh-keygen -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key

# 5. 写入终态 SSH 加固配置
sshd_cfg=/etc/ssh/sshd_config
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-hardened.conf <<EOF
# 端口与主机密钥
Port $target_ssh_port
HostKey /etc/ssh/ssh_host_ed25519_key

# 身份认证加固
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers $admin_user

# 安全与防暴力破解
MaxAuthTries 2
LoginGraceTime 20

# 连接保活
ClientAliveInterval 120
ClientAliveCountMax 3

# SFTP 子系统
Subsystem sftp internal-sftp
EOF
chmod 0600 /etc/ssh/sshd_config.d/00-hardened.conf

if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$sshd_cfg"; then
    die '发行版未启用 /etc/ssh/sshd_config.d drop-in；为避免改写主配置，请先在安装环境启用 Include 后重试'
fi

sshd -t
effective=$(sshd -T | tr '[:upper:]' '[:lower:]')
grep -q '^permitrootlogin no$' <<< "$effective" || die 'sshd 未生效 permitrootlogin no'
grep -q '^passwordauthentication no$' <<< "$effective" || die 'sshd 未生效 passwordauthentication no'
grep -q '^pubkeyauthentication yes$' <<< "$effective" || die 'sshd 未生效 pubkeyauthentication yes'
grep -q "^port $target_ssh_port$" <<< "$effective" || die "sshd 未生效端口: $target_ssh_port"
grep -q "^allowusers $admin_user$" <<< "$effective" || die "sshd 未生效 allowusers: $admin_user"

host_key_count=0
for host_key in /etc/ssh/ssh_host_*_key; do
    [[ -s "$host_key" ]] || continue
    host_key_count=$((host_key_count + 1))
done
[[ "$host_key_count" -gt 0 ]] || die '未找到有效的 SSH 主机私钥'

printf '%s\n' "$target_ssh_port" > "/$work_name/ssh-ports"

if grep -q '^[#[:space:]]*ParallelDownloads' /etc/pacman.conf; then
    sed -i 's/^[#[:space:]]*ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
else
    sed -i '/^\[options\]/a ParallelDownloads = 5' /etc/pacman.conf
fi

if [[ "$mode" == BIOS ]]; then
    if [[ "$(blkid -p -o value -s PTTYPE -- "$root_disk" 2>/dev/null || true)" == gpt ]]; then
        grep -qiE '21686148-6449-6e6f-744e-656564454649|BIOS boot' < <(lsblk -rno PARTTYPE,PARTTYPENAME -- "$root_disk") || exit 1
    fi
    grub-install --target=i386-pc --recheck "$root_disk"
else
    [[ -d /sys/firmware/efi ]] || die 'UEFI 环境不可用'
    if [[ "$efi_vars_writable" == 1 ]]; then
        grub-install --target=x86_64-efi --efi-directory="$esp_mount" --bootloader-id=GRUB --recheck
    else
        grub-install --target=x86_64-efi --efi-directory="$esp_mount" --bootloader-id=GRUB --recheck --no-nvram --removable
        [[ -s "$esp_mount/EFI/BOOT/BOOTX64.EFI" ]] \
            || die 'UEFI 可移动介质回退文件缺失：EFI/BOOT/BOOTX64.EFI'
    fi
    [[ -s "$esp_mount/EFI/GRUB/grubx64.efi" ]] \
        || die 'UEFI GRUB 文件缺失：EFI/GRUB/grubx64.efi'
fi
GRUB_CFG=/boot/grub/grub.cfg
KERNEL=/boot/vmlinuz-linux
INITRAMFS=/boot/initramfs-linux.img

grub-mkconfig -o "$GRUB_CFG"

[[ -s "$GRUB_CFG" ]] || die "GRUB 配置不存在或为空：$GRUB_CFG"
grep -q '^menuentry ' "$GRUB_CFG" || die "GRUB 配置没有 menuentry：$GRUB_CFG"
command -v grub-script-check >/dev/null 2>&1 || die '缺少 grub-script-check，无法完成 GRUB 语法校验'
grub-script-check "$GRUB_CFG" || die "GRUB 配置语法检查失败：$GRUB_CFG"

[[ -s "$KERNEL" ]] || die "缺少主内核：$KERNEL"
[[ -s "$INITRAMFS" ]] || die "缺少主 initramfs：$INITRAMFS"
grep -q 'vmlinuz-linux' "$GRUB_CFG" || die "GRUB 配置未引用主内核：$KERNEL"
grep -q 'initramfs-linux\.img' "$GRUB_CFG" || die "GRUB 配置未引用主 initramfs：$INITRAMFS"

systemctl unmask systemd-networkd.service
systemctl enable systemd-networkd.service sshd.service getty@tty1.service
systemctl mask sshdgenkeys.service 2>/dev/null || true
[[ "$(systemctl is-enabled systemd-networkd.service 2>/dev/null || true)" == enabled ]] \
    || die 'systemd-networkd 未成功启用'
[[ "$(systemctl is-enabled sshd.service 2>/dev/null || true)" == enabled ]] \
    || die 'sshd 未成功启用'
info '核心服务已启用 (systemd-networkd, sshd, getty@tty1)'
CONFIG

SSH_PORTS=$(bhost cat "$BOOTSTRAP/mnt/$WORK_NAME/ssh-ports")
[[ -n "$SSH_PORTS" ]] || die '无法读取 SSH 监听端口'
rm -f "$WORKDIR/ssh-ports"

# ============================================================
# Phase 9: 收尾清理
# ============================================================
say "Phase 9: 收尾清理"

bchroot /usr/bin/chroot /mnt /bin/sync
for target in "$BOOTSTRAP/mnt" "$BOOTSTRAP/run" "$BOOTSTRAP/sys" \
    "$BOOTSTRAP/dev" "$BOOTSTRAP/proc"; do
    info "卸载临时挂载：$target"
    umount -R -l -- "$target" 2>/dev/null || true
done
REMAINING_MOUNTS=$(findmnt -R "$BOOTSTRAP" -rn -o TARGET 2>/dev/null || true)
[[ -z "$REMAINING_MOUNTS" ]] || die "无法卸载 bootstrap 挂载：$REMAINING_MOUNTS"
rm -rf -- "$WORKDIR"
sync

printf '\n════════════════════════════════════════════════════════\n'
printf '✅ 重装完成\n'
info "启动模式：$BOOT_MODE"
printf '  ℹ️ SSH 登录端口：%s\n' "$SSH_PORTS"
printf '  👤 SSH 登录用户：%s\n' "$ADMIN_USER"
info 'SSH 认证：仅 Ed25519 公钥（root 登录已禁用）'
printf '  🌐 软件源镜像：%s\n' "${ARCH_MIRRORS[*]}"
printf '  🌐 DNS 服务器：%s\n' "$DNS_LIST"
if ((${#WARNINGS[@]} == 0)); then
    info '预检告警：无'
else
    notice '预检告警列表：'
    for warning in "${WARNINGS[@]}"; do
        notice "$warning"
    done
fi
notice '请勿在当前 SSH 会话操作，直接通过控制台冷重启。'
notice "冷重启后登录：ssh -p $SSH_PORTS $ADMIN_USER@[HERE_SERVER_IP]"
printf '════════════════════════════════════════════════════════\n'
