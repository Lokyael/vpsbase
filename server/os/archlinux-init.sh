#!/usr/bin/env bash
#
# server/os/archlinux-init.sh
# Arch Linux 基础环境初始化脚本
#

set -Eeuo pipefail

BASHRC="$HOME/.bashrc"

# ========================================================
# 受控分界标记块工具函数 (Managed Block Utilities)
# 基于 awk 流式原样读取，杜绝特殊字符与正则转义异常
# ========================================================

validate_bashrc() {
    [[ ! -L "$BASHRC" ]] || { printf '❌ ~/.bashrc 是符号链接，停止\n' >&2; return 1; }
    [[ ! -e "$BASHRC" || ( -f "$BASHRC" && -r "$BASHRC" && -w "$BASHRC" ) ]] || { printf '❌ ~/.bashrc 无法读写，停止\n' >&2; return 1; }
    [[ ! -e "$BASHRC" ]] || bash -n "$BASHRC" || { printf '❌ 已有 ~/.bashrc 语法异常，停止\n' >&2; return 1; }
}

upsert_managed_block() {
    local target_file="$1"
    local tag="$2"
    local content="$3"
    local begin_mark="# >>> managed:${tag} >>>"
    local end_mark="# <<< managed:${tag} <<<"

    validate_bashrc || return 1

    local content_file tmp_file input_file="${4:-$target_file}"
    [[ -e "$target_file" ]] || input_file=/dev/null
    content_file=$(mktemp "${target_file}.content.XXXXXX") || return 1
    tmp_file=$(mktemp "${target_file}.tmp.XXXXXX") || { rm -f -- "$content_file"; return 1; }

    if ! printf '%s\n' "$content" > "$content_file"; then
        rm -f -- "$content_file" "$tmp_file"
        return 1
    fi

    if ! awk -v b="$begin_mark" -v e="$end_mark" -v cfile="$content_file" '
        BEGIN { in_block=0; replaced=0 }
        $0 == b {
            in_block=1
            print b
            while ((getline line < cfile) > 0) {
                print line
            }
            close(cfile)
            print e
            replaced=1
            next
        }
        $0 == e {
            in_block=0
            next
        }
        !in_block { print }
        END {
            if (!replaced) {
                print ""
                print b
                while ((getline line < cfile) > 0) {
                    print line
                }
                close(cfile)
                print e
            }
        }
    ' "$input_file" > "$tmp_file"; then
        rm -f -- "$content_file" "$tmp_file"
        return 1
    fi

    rm -f -- "$content_file"
    if ! bash -n "$tmp_file"; then
        rm -f -- "$tmp_file"
        printf '❌ %s 受控块语法校验失败，请检查配置\n' "$target_file" >&2
        return 1
    fi
    if [[ -e "$target_file" ]] && cmp -s -- "$target_file" "$tmp_file"; then
        rm -f -- "$tmp_file"
        return 0
    fi
    if [[ -e "$target_file" ]] && ! cp --attributes-only --preserve=mode,ownership "$target_file" "$tmp_file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    mv -f -- "$tmp_file" "$target_file" || { rm -f -- "$tmp_file"; return 1; }
}

# ========================================================
# 历史记录格式化清洗工具 (Normalize History)
# ========================================================

normalize_history() {
    local histfile="${HISTFILE:-$HOME/.bash_history}"
    [[ -f "$histfile" && -s "$histfile" && -r "$histfile" && -w "$histfile" && ! -L "$histfile" ]] || return 0
    history -a 2>/dev/null || true

    local has_unformatted=0
    if awk '
        BEGIN { bad=0 }
        /^#[0-9]+$/ { have_stamp=1; next }
        { if (!have_stamp) { bad=1; exit 0 } }
        END { if (bad) exit 0; exit 1 }
    ' "$histfile" 2>/dev/null; then
        has_unformatted=1
    fi

    [[ "$has_unformatted" -eq 1 ]] || return 0

    local base_time tmp_norm
    base_time=$(stat -c '%Y' "$histfile" 2>/dev/null || date +%s)
    tmp_norm=$(mktemp "${histfile%/*}/.bash_history.norm.XXXXXX") || return 0

    if awk -v btime="$base_time" '
        BEGIN { count=0; has_cmd=0; has_stamp=0; stamp="" }
        function flush_line() {
            if (!has_cmd) return
            print (has_stamp ? stamp : "#" (btime + count))
            print cmd
            count++
            has_cmd=0; has_stamp=0; stamp=""; cmd=""
        }
        /^#[0-9]+$/ {
            if (has_cmd) flush_line()
            has_stamp=1; stamp=$0; next
        }
        {
            if (has_stamp) {
                if (!has_cmd) { cmd=$0; has_cmd=1 }
                else { cmd=cmd "\n" $0 }
            } else {
                if (has_cmd) flush_line()
                cmd=$0; has_cmd=1; has_stamp=0; stamp=""
            }
        }
        END { flush_line() }
    ' "$histfile" > "$tmp_norm" && [[ -s "$tmp_norm" ]]; then
        cp --attributes-only --preserve=mode,ownership "$histfile" "$tmp_norm" 2>/dev/null || true
        mv -f "$tmp_norm" "$histfile"
        history -c 2>/dev/null || true
        history -r 2>/dev/null || true
        printf '  ℹ️  已自动规范化已有历史记录的时间戳格式\n'
    else
        rm -f "$tmp_norm"
    fi
}

# ========================================================
# 阶段 1: 绝对通用的基础环境初始化
# ========================================================

run_base_init() {
    local user_name
    user_name="$(id -un)"
    [[ "$user_name" != "root" ]] || {
        printf '❌ 请以具备 sudo 权限的普通用户执行，禁止直接以 root 执行\n' >&2
        exit 1
    }

    # 1. 验证用户环境与权限基线
    printf '\n==> [1/7] 验证用户权限与 SSH 基线...\n'
    IFS=: read -r _ _ _ _ _ expected_home _ < <(getent passwd "$user_name")
    [[ "$HOME" == "$expected_home" ]] || {
        printf '❌ HOME 环境变量 (%s) 与系统家目录 (%s) 不一致\n' "$HOME" "$expected_home" >&2
        exit 1
    }
    cd "$expected_home" || exit 1

    id -nG "$user_name" | tr ' ' '\n' | grep -Fxq wheel || {
        printf '❌ 当前用户不在 wheel 组\n' >&2
        exit 1
    }
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    [[ -f "$HOME/.ssh/authorized_keys" ]] || {
        printf '❌ 未找到 ~/.ssh/authorized_keys\n' >&2
        exit 1
    }
    chmod 600 "$HOME/.ssh/authorized_keys"

    sudo -v || {
        printf '❌ sudo 提权验证失败\n' >&2
        exit 1
    }

    # 2. 设置主机名
    printf '==> [2/7] 配置系统主机名...\n'
    local current_host input_host new_host
    current_host=$(hostnamectl hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || true)
    input_host=""
    if [[ -t 0 || -e /dev/tty ]]; then
        read -rp "主机名 (Hostname) [当前: ${current_host:-archlinux}，回车保持]: " input_host < /dev/tty || input_host=""
    fi
    new_host="${input_host:-${current_host:-archlinux}}"
    [[ -n "$new_host" ]] || {
        printf '❌ 主机名不能为空\n' >&2
        exit 1
    }
    sudo hostnamectl set-hostname "$new_host"

    # 3. 官方密钥环与基础更新
    printf '==> [3/7] 更新官方密钥环与基础系统包...\n'
    sudo pacman-key --init
    sudo pacman-key --populate archlinux
    sudo pacman -Sy --needed --noconfirm archlinux-keyring
    sudo pacman -Syu --needed --noconfirm sudo which less bash-completion

    # 4. 本地化与时区
    printf '==> [4/7] 配置系统 Locale (en_US.UTF-8)、统一时区 (UTC) 与 NTP 时间同步...\n'
    sudo sed -i 's/^#[[:space:]]*\(en_US\.UTF-8[[:space:]]\+UTF-8\)/\1/' /etc/locale.gen
    grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' | sudo tee -a /etc/locale.gen >/dev/null
    sudo locale-gen
    sudo localectl set-locale LANG=en_US.UTF-8
    sudo timedatectl set-timezone UTC
    sudo timedatectl set-ntp true

    # 5. ~/.bashrc 通用受控配置
    printf '==> [5/7] 写入 ~/.bashrc 通用受控基础配置...\n'
    validate_bashrc || return 1

    local default_skeleton base_input="$BASHRC"
    default_skeleton=$'#\n# ~/.bashrc\n#\n\n# If not running interactively, don\'t do anything\n[[ $- != *i* ]] && return\n\nalias ls=\'ls --color=auto\'\nalias grep=\'grep --color=auto\'\nPS1=\'[\u@\h \W]\$ \''
    if [[ -f "$BASHRC" ]] && [[ "$(< "$BASHRC")" == "$default_skeleton" ]]; then
        base_input=/dev/null
    fi

    local base_content
    base_content=$(cat <<'EOF'
# 非交互式 Shell 跳过
[[ $- != *i* ]] && return

# 历史记录
HISTCONTROL=ignoreboth
HISTSIZE=100000
HISTFILESIZE=200000
HISTTIMEFORMAT="%F %T %z "
HISTIGNORE='ls:cd:exit:clear:history:la:ll'
shopt -s histappend
shopt -s checkwinsize

# 常用别名
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
command -v ss >/dev/null 2>&1 && alias ports='ss -tulanp'
command -v df >/dev/null 2>&1 && alias df='df -h'
command -v free >/dev/null 2>&1 && alias free='free -h'

# 彩色输出与快捷键
test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'

# 自动补全
if ! shopt -oq posix; then
    if [[ -f /usr/share/bash-completion/bash_completion ]]; then
        . /usr/share/bash-completion/bash_completion
    elif [[ -f /etc/bash_completion ]]; then
        . /etc/bash_completion
    fi
fi

# 终端提示符 (精简双色: 绿主机 + 蓝路径)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    PS1='\[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '
else
    PS1='[\u@\h \W]\$ '
fi

# 环境变量
export LESS='-R -F'
export PAGER=less
export MANPAGER='less -R'

# 用户驻留 (Linger) 运行时目录防御式补齐
if [[ -z "${XDG_RUNTIME_DIR:-}" && -d "/run/user/$(id -u)" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
EOF
    )

    upsert_managed_block "$BASHRC" "archlinux-base" "$base_content" "$base_input"

    # 对已有历史记录做首次时间戳合规化清洗（避免未配置 HISTTIMEFORMAT 前产生的裸指令造成格式断层）
    normalize_history

    # 6. 内核网络自适应调优 (BBR + 内存自适应长管道缓冲区 + 资源限制)
    printf '==> [6/7] 配置内核网络参数与系统资源上限...\n'
    local total_ram_kb total_ram_mb buffer_size somaxconn nofile_soft nofile_hard tier_desc
    total_ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    total_ram_mb=$(( total_ram_kb / 1024 ))

    if [[ $total_ram_mb -le 1024 ]]; then
        buffer_size=4194304
        somaxconn=4096
        nofile_soft=4096
        nofile_hard=65536
        tier_desc="4MB (≤1GB RAM 紧凑保命档)"
    elif [[ $total_ram_mb -le 2048 ]]; then
        buffer_size=8388608
        somaxconn=8192
        nofile_soft=8192
        nofile_hard=262144
        tier_desc="8MB (1~2GB RAM 均衡基线档)"
    elif [[ $total_ram_mb -le 4096 ]]; then
        buffer_size=16777216
        somaxconn=8192
        nofile_soft=65535
        nofile_hard=1048576
        tier_desc="16MB (2~4GB RAM 高速性能档)"
    else
        buffer_size=33554432
        somaxconn=16384
        nofile_soft=65535
        nofile_hard=1048576
        tier_desc="32MB (>4GB RAM 极速压榨档)"
    fi

    sudo modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" | sudo tee /etc/modules-load.d/tcp_bbr.conf > /dev/null
    sudo rm -f /etc/modules-load.d/bbr.conf 2>/dev/null || true

    sudo tee /etc/sysctl.d/99-network.conf > /dev/null <<EOF
# 开启 TCP 窗口缩放 (RFC 1323)
net.ipv4.tcp_window_scaling = 1

# 适配物理内存的精准套接字缓冲区上限 (小内存防 OOM，大内存跑满单流)
net.core.rmem_max = $buffer_size
net.core.wmem_max = $buffer_size
net.ipv4.tcp_rmem = 4096 87380 $buffer_size
net.ipv4.tcp_wmem = 4096 65536 $buffer_size

# 默认 FQ 排队规则 + BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 调大系统连接队列与网卡积压队列
net.core.somaxconn = $somaxconn
net.core.netdev_max_backlog = $somaxconn
net.ipv4.tcp_max_syn_backlog = $somaxconn

# 开启宽松反向路径过滤与火星包防御 (防内网伪造 IP 并保障 WireGuard 互通)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.log_martians = 1
EOF

    sudo rm -f /etc/sysctl.d/99-network-tuning.conf /etc/sysctl.d/99-bbr.conf 2>/dev/null || true
    sudo sysctl --system > /dev/null

    sudo mkdir -p /etc/security/limits.d
    sudo tee /etc/security/limits.d/99-limits.conf > /dev/null <<EOF
# 用户级文件描述符与进程上限 (契合内存网络调优档位)
* soft nofile $nofile_soft
* hard nofile $nofile_hard
* soft nproc  $nofile_soft
* hard nproc  $nofile_hard
EOF

    printf '  ✅ 内核网络与资源上限已生效 (内存: %s MB | 缓冲区: %s | 队列: %s | nofile: %s)\n' \
      "$total_ram_mb" \
      "$tier_desc" \
      "$(sysctl -n net.core.somaxconn 2>/dev/null || echo "$somaxconn")" \
      "$nofile_soft"

    # 7. 内存管理与 Swap 策略 (先检后配，单向打底)
    printf '==> [7/7] 检查系统内存管理与 Swap 状态...\n'

    local active_swap
    active_swap=$(swapon --show=NAME,TYPE,SIZE --noheadings 2>/dev/null | head -n1)
    if [[ -n "$active_swap" ]]; then
        printf '  ℹ️  检测到活动 Swap 已就绪: %s，保持现状跳过\n' "$active_swap"
    else
        local cpu_cores suggest_mode mode_desc
        cpu_cores=$(nproc 2>/dev/null || echo 1)

        if [[ $total_ram_mb -le 1024 || $cpu_cores -le 1 ]]; then
            suggest_mode=1
            mode_desc="经典磁盘 Swapfile (1GB, 适合弱单核/小内存，零 CPU 争抢防假死)"
        elif [[ $total_ram_mb -le 4096 && $cpu_cores -ge 2 ]]; then
            suggest_mode=2
            mode_desc="zram 压缩内存盘 (1/2 内存, 适合多核网关/代理，零磁盘磨损)"
        else
            suggest_mode=3
            mode_desc="纯物理内存运行 (不配置 Swap，适合大内存主机)"
        fi

        printf '  🖥️  硬件探针: %s MB RAM | %s vCPU | 未配置 Swap\n' "$total_ram_mb" "$cpu_cores"
        printf '  💡 智能推荐模式: [%s] %s\n' "$suggest_mode" "$mode_desc"
        printf '  模式选项:\n'
        printf '    1) 经典磁盘 Swapfile (1GB, 零 CPU 开销, 支持休眠, 兜底防 OOM)\n'
        printf '    2) zram 压缩内存盘 (1/2 内存, zstd 极速, 零磁盘磨损, 不支持休眠)\n'
        printf '    3) 纯物理内存运行 (不配置 Swap)\n'

        local chosen_mode=""
        if [[ -t 0 || -e /dev/tty ]]; then
            read -rp "  请选择内存模式 [1-3, 默认 $suggest_mode]: " chosen_mode < /dev/tty || chosen_mode=""
        fi
        chosen_mode="${chosen_mode:-$suggest_mode}"

        case "$chosen_mode" in
            1)
                printf '  ==> 配置 1GB 经典磁盘 Swapfile...\n'
                sudo fallocate -l 1G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
                sudo chmod 0600 /swapfile
                sudo mkswap /swapfile >/dev/null
                sudo swapon /swapfile
                grep -qE '^[[:space:]]*/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap defaults 0 0' | sudo tee -a /etc/fstab >/dev/null
                sudo mkdir -p /etc/sysctl.d
                echo "vm.swappiness = 10" | sudo tee /etc/sysctl.d/99-memory.conf >/dev/null
                sudo sysctl -w vm.swappiness=10 >/dev/null
                printf '  ✅ 经典磁盘 Swapfile (1GB) 已激活并持久化\n'
                ;;
            2)
                printf '  ==> 配置 zram-generator 压缩内存盘...\n'
                sudo pacman -S --needed --noconfirm zram-generator
                sudo mkdir -p /etc/systemd/zram-generator.conf.d
                sudo tee /etc/systemd/zram-generator.conf.d/zram0.conf >/dev/null <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
                sudo systemctl daemon-reload
                sudo systemctl start dev-zram0.swap
                if [[ "$(cat /sys/module/zswap/parameters/enabled 2>/dev/null)" == "Y" ]]; then
                    echo 0 | sudo tee /sys/module/zswap/parameters/enabled >/dev/null 2>&1 || true
                    if [[ -f /etc/default/grub ]] && ! grep -q 'zswap\.enabled=0' /etc/default/grub; then
                        sudo sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)/\1 zswap.enabled=0/' /etc/default/grub
                        sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
                        printf '  ℹ️  已即时停用 zswap 并为 GRUB 注入持久化参数\n'
                    fi
                fi
                printf '  ✅ zram 压缩内存盘已激活 (1/2 内存, zstd 算法)\n'
                printf '  ℹ️  注意事项：基于易失性 RAM，不支持休眠至磁盘 (Hibernate)\n'
                ;;
            3)
                printf '  ⏭️  保持纯物理内存运行，未配置 Swap\n'
                ;;
            *)
                printf '  ⚠️  输入无效，保持原样未配置 Swap\n'
                ;;
        esac
    fi

    printf '\n✅ 基础环境初始化完成。\n'
    printf '   用户: %s | 主机名: %s | 时区: UTC (NTP 同步) | 语言: en_US.UTF-8 | 网络缓冲: %s\n' "$user_name" "$new_host" "$tier_desc"
}

# ========================================================
# 主入口
# ========================================================

main() {
    if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--help" ]]; }; then
        printf '❌ 不支持的参数: %s\n' "$*" >&2
        printf '用法: %s [--help]\n' "$0" >&2
        return 2
    fi
    case "${1:-}" in
        "")
            run_base_init
            printf '\n👉 执行 exec bash -i 重载当前终端即可生效。\n'
            ;;
        --help)
            printf '用法: %s [--help]\n' "$0"
            printf '执行 Arch Linux 基础环境初始化。\n'
            ;;
    esac
}

main "$@"
