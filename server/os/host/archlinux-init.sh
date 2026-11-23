#!/usr/bin/env bash
#
# server/os/host/archlinux-init.sh
# Arch Linux 基础环境初始化脚本
#

set -Eeuo pipefail

BASHRC="$HOME/.bashrc"

validate_arch_host() {
    local machine release=/etc/os-release
    machine=$(uname -m) || return 1
    [[ "$machine" == x86_64 ]] || {
        printf '❌ 仅支持 Arch Linux x86-64，检测到架构：%s\n' "$machine" >&2
        return 1
    }
    if [[ ! -e "$release" && ! -L "$release" ]]; then release=/usr/lib/os-release; fi
    if [[ ! -f "$release" || ! -r "$release" ]] || ! awk '
        /^ID=/ { count++; if ($0 ~ /^ID=(arch|"arch"|\047arch\047)$/) good++ }
        END { exit (count != 1 || good != 1) }
    ' "$release"; then
        printf '❌ 无法确认当前系统是 Arch Linux：%s\n' "$release" >&2
        return 1
    fi
}

# ========================================================
# 受控分界标记块工具函数 (Managed Block Utilities)
# 基于 awk 流式原样读取，杜绝特殊字符与正则转义异常
# ========================================================

validate_bashrc() {
    [[ ! -L "$BASHRC" ]] || { printf '❌ ~/.bashrc 是符号链接，停止\n' >&2; return 1; }
    [[ ! -e "$BASHRC" || ( -f "$BASHRC" && -r "$BASHRC" && -w "$BASHRC" ) ]] || { printf '❌ ~/.bashrc 无法读写，停止\n' >&2; return 1; }
    [[ ! -e "$BASHRC" ]] || bash -n "$BASHRC" || { printf '❌ 已有 ~/.bashrc 语法异常，停止\n' >&2; return 1; }
}

process_managed_block() {
    local input_file="$1" tag="$2" content_file="${3:-}"
    MANAGED_BLOCK_CONTENT="$content_file" awk -v b="# >>> managed:${tag} >>>" -v e="# <<< managed:${tag} <<<" '
        BEGIN { cfile = ENVIRON["MANAGED_BLOCK_CONTENT"] }
        function reject_markers() {
            printf "❌ 受控块标记残缺、重复或重叠：%s\n", b > "/dev/stderr"
            failed = 1
            exit 1
        }
        function emit_block(    line, status) {
            print b
            while ((status = (getline line < cfile)) > 0) print line
            close(cfile)
            if (status < 0) {
                printf "❌ 无法读取受控块内容：%s\n", b > "/dev/stderr"
                failed = 1
                exit 1
            }
            print e
        }
        $0 == b {
            if (seen) reject_markers()
            seen = in_block = 1
            if (cfile != "") emit_block()
            next
        }
        $0 == e {
            if (!in_block) reject_markers()
            in_block = 0
            next
        }
        /^# >>> managed:[^[:space:]]+ >>>$/ {
            if (in_block) reject_markers()
            opened[$3, (seen ? 1 : 0)]++
        }
        /^# <<< managed:[^[:space:]]+ <<<$/ {
            if (in_block) reject_markers()
            # 其他块从目标块之前起、到目标块之后止才构成重叠。
            if (opened[$3, 1] > 0) opened[$3, 1]--
            else if (opened[$3, 0] > 0) {
                if (seen) reject_markers()
                opened[$3, 0]--
            }
        }
        !in_block && cfile != "" { print }
        END {
            if (failed) exit 1
            if (in_block) reject_markers()
            if (!seen && cfile != "") {
                print ""
                emit_block()
            }
        }
    ' "$input_file"
}

validate_bashrc_block() {
    validate_bashrc || return 1
    [[ ! -e "$BASHRC" ]] || process_managed_block "$BASHRC" "$1"
}

upsert_managed_block() {
    local target_file="$1" tag="$2" content="$3"
    validate_bashrc || return 1

    local content_file tmp_file input_file="${4:-$target_file}"
    [[ -e "$target_file" ]] || input_file=/dev/null
    content_file=$(mktemp "${target_file}.content.XXXXXX") || return 1
    tmp_file=$(mktemp "${target_file}.tmp.XXXXXX") || { rm -f -- "$content_file"; return 1; }

    if ! printf '%s\n' "$content" > "$content_file"; then
        rm -f -- "$content_file" "$tmp_file"
        return 1
    fi

    if ! process_managed_block "$input_file" "$tag" "$content_file" > "$tmp_file"; then
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

    # 快速预检：仅当首个时间戳前出现裸行，或任意时间戳块包含多行时才进入解析
    if ! awk '
        /^#[0-9]+$/ { have_stamp=1; lines=0; next }
        {
            if (!have_stamp) { need=1; exit 0 }
            lines++
            if (lines > 1) { need=1; exit 0 }
        }
        END { exit (need ? 0 : 1) }
    ' "$histfile" 2>/dev/null; then
        return 0
    fi

    local base_time
    base_time=$(stat -c '%Y' -- "$histfile" 2>/dev/null || date +%s)

    local -a raw_lines=() out_lines=() block_lines=()
    mapfile -t raw_lines < "$histfile"

    local count=0 needs_rewrite=0 seen_stamp=0 current_stamp=""
    local line cand err j k n split_end tail_bs tmp_l complete_end

    # 按行扫描：单行时间戳条目零开销原样保留；多行块用 bash -n 区分真多行命令与混入的裸行
    local total=${#raw_lines[@]} idx=0
    while (( idx <= total )); do
        if (( idx == total )) || [[ "${raw_lines[idx]}" =~ ^#[0-9]+$ ]]; then
            n=${#block_lines[@]}
            if (( seen_stamp == 0 )); then
                if (( n > 0 )); then
                    needs_rewrite=1
                    j=0
                    while (( j < n )); do
                        cand=""
                        complete_end=-1
                        for (( k = j; k < n; k++ )); do
                            cand+="${cand:+$'\n'}${block_lines[k]}"
                            tail_bs=0
                            tmp_l="${block_lines[k]}"
                            while [[ "$tmp_l" == *\\ ]]; do
                                tmp_l="${tmp_l%?}"
                                tail_bs=$(( tail_bs + 1 ))
                            done
                            if (( tail_bs % 2 == 1 && k < n - 1 )); then continue; fi
                            if err=$(printf '%s\n' "$cand" | bash -n 2>&1) && [[ -z "$err" ]]; then
                                complete_end=$k
                                break
                            fi
                        done
                        if (( complete_end < 0 )); then
                            complete_end=$j
                        fi
                        out_lines+=("#$(( base_time + count ))")
                        count=$(( count + 1 ))
                        for (( k = j; k <= complete_end; k++ )); do
                            out_lines+=("${block_lines[k]}")
                        done
                        j=$(( complete_end + 1 ))
                    done
                fi
            else
                if (( n == 0 )); then
                    out_lines+=("$current_stamp")
                elif (( n == 1 )); then
                    out_lines+=("$current_stamp" "${block_lines[0]}")
                else
                    cand=""
                    split_end=-1
                    for (( k = 0; k < n; k++ )); do
                        cand+="${cand:+$'\n'}${block_lines[k]}"
                        tail_bs=0
                        tmp_l="${block_lines[k]}"
                        while [[ "$tmp_l" == *\\ ]]; do
                            tmp_l="${tmp_l%?}"
                            tail_bs=$(( tail_bs + 1 ))
                        done
                        if (( tail_bs % 2 == 1 && k < n - 1 )); then continue; fi
                        if err=$(printf '%s\n' "$cand" | bash -n 2>&1) && [[ -z "$err" ]]; then
                            split_end=$k
                            break
                        fi
                    done
                    if (( split_end < 0 )); then
                        split_end=0
                    fi
                    out_lines+=("$current_stamp")
                    for (( k = 0; k <= split_end; k++ )); do
                        out_lines+=("${block_lines[k]}")
                    done
                    if (( split_end < n - 1 )); then
                        needs_rewrite=1
                        j=$(( split_end + 1 ))
                        while (( j < n )); do
                            cand=""
                            complete_end=-1
                            for (( k = j; k < n; k++ )); do
                                cand+="${cand:+$'\n'}${block_lines[k]}"
                                tail_bs=0
                                tmp_l="${block_lines[k]}"
                                while [[ "$tmp_l" == *\\ ]]; do
                                    tmp_l="${tmp_l%?}"
                                    tail_bs=$(( tail_bs + 1 ))
                                done
                                if (( tail_bs % 2 == 1 && k < n - 1 )); then continue; fi
                                if err=$(printf '%s\n' "$cand" | bash -n 2>&1) && [[ -z "$err" ]]; then
                                    complete_end=$k
                                    break
                                fi
                            done
                            if (( complete_end < 0 )); then
                                complete_end=$j
                            fi
                            out_lines+=("#$(( base_time + count ))")
                            count=$(( count + 1 ))
                            for (( k = j; k <= complete_end; k++ )); do
                                out_lines+=("${block_lines[k]}")
                            done
                            j=$(( complete_end + 1 ))
                        done
                    fi
                fi
            fi
            block_lines=()
            if (( idx < total )); then
                seen_stamp=1
                current_stamp="${raw_lines[idx]}"
            fi
        else
            block_lines+=("${raw_lines[idx]}")
        fi
        idx=$(( idx + 1 ))
    done

    if [[ "$needs_rewrite" -ne 1 ]]; then
        return 0
    fi

    local histdir="${histfile%/*}" tmp_norm
    [[ "$histdir" != "$histfile" ]] || histdir=.
    tmp_norm=$(mktemp "$histdir/.bash_history.norm.XXXXXX") || return 0

    if printf '%s\n' "${out_lines[@]}" > "$tmp_norm" && [[ -s "$tmp_norm" ]]; then
        cp --attributes-only --preserve=mode,ownership -- "$histfile" "$tmp_norm" 2>/dev/null || true
        mv -f -- "$tmp_norm" "$histfile"
        history -c 2>/dev/null || true
        history -r 2>/dev/null || true
        printf '  ℹ️  已自动规范化已有历史记录的时间戳格式\n'
    else
        rm -f -- "$tmp_norm"
    fi
}

# ========================================================
# 系统 drop-in 安全发布与内核模块状态辅助
# ========================================================

running_kernel_modules_available() {
    local kver
    kver=$(uname -r) || return 1
    [[ -d "/usr/lib/modules/$kver" ]]
}

write_managed_dropin() {
    local target="$1" mode="$2" content="$3"
    local parent="${target%/*}"
    if sudo test -L "$target"; then
        printf '❌ 受控配置路径是符号链接，停止：%s\n' "$target" >&2
        return 1
    fi
    if sudo test -e "$target"; then
        sudo test -f "$target" || {
            printf '❌ 受控配置路径不是普通文件，停止：%s\n' "$target" >&2
            return 1
        }
        sudo grep -Fqx '# managed-by: archlinux-init' "$target" || {
            printf '❌ 存在未纳管的同名配置文件，拒绝覆盖：%s\n' "$target" >&2
            return 1
        }
    fi
    sudo install -d -m 0755 -- "$parent" || return 1
    if sudo test -e "$target" && printf '%s\n' "$content" | sudo cmp -s -- "$target" -; then
        sudo chmod "$mode" -- "$target" || return 1
        return 0
    fi
    local tmp
    tmp=$(sudo mktemp "${parent}/.${target##*/}.XXXXXX") || return 1
    if ! printf '%s\n' "$content" | sudo tee "$tmp" >/dev/null ||
       ! sudo chmod "$mode" -- "$tmp" ||
       ! sudo mv -fT -- "$tmp" "$target"; then
        sudo rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
}

# ========================================================
# 官方密钥环与基础系统包更新
# ========================================================

run_package_init() {
    sudo /usr/bin/bash --noprofile --norc -s <<'ROOT'
set -Eeuo pipefail
export PATH=/usr/bin LC_ALL=C

pacman-key --init
pacman-key --populate archlinux
pacman -Sy --needed --noconfirm archlinux-keyring
pacman -Syu --needed --noconfirm sudo which less bash-completion
ROOT
}

# ========================================================
# 内核网络自适应调优与资源上限
# ========================================================

configure_network_and_limits() {
    local total_ram_kb total_ram_mb buffer_size somaxconn
    local nofile_soft nofile_hard nproc_soft nproc_hard tier_desc
    total_ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    total_ram_mb=$(( total_ram_kb / 1024 ))

    if [[ $total_ram_mb -le 1024 ]]; then
        buffer_size=4194304
        somaxconn=4096
        nofile_soft=4096
        nofile_hard=524288
        nproc_soft=4096
        nproc_hard=65536
        tier_desc="4MB (≤1GB RAM)"
    elif [[ $total_ram_mb -le 2048 ]]; then
        buffer_size=8388608
        somaxconn=8192
        nofile_soft=8192
        nofile_hard=524288
        nproc_soft=8192
        nproc_hard=65536
        tier_desc="8MB (1~2GB RAM)"
    elif [[ $total_ram_mb -le 4096 ]]; then
        buffer_size=16777216
        somaxconn=8192
        nofile_soft=65535
        nofile_hard=1048576
        nproc_soft=16384
        nproc_hard=131072
        tier_desc="16MB (2~4GB RAM)"
    else
        buffer_size=33554432
        somaxconn=16384
        nofile_soft=65535
        nofile_hard=1048576
        nproc_soft=32768
        nproc_hard=262144
        tier_desc="32MB (>4GB RAM)"
    fi

    local bbr_conf net_conf limits_conf
    bbr_conf=$(cat <<'EOF'
# managed-by: archlinux-init
tcp_bbr
EOF
    )
    write_managed_dropin /etc/modules-load.d/tcp_bbr.conf 0644 "$bbr_conf" || return 1

    net_conf=$(cat <<EOF
# managed-by: archlinux-init
# 适配物理内存的精准套接字缓冲区上限 (小内存防 OOM，大内存跑满单流)
net.core.rmem_max = $buffer_size
net.core.wmem_max = $buffer_size
net.ipv4.tcp_rmem = 4096 131072 $buffer_size
net.ipv4.tcp_wmem = 4096 65536 $buffer_size

# 默认 FQ 排队规则 + BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 调大系统连接队列与网卡积压队列
net.core.somaxconn = $somaxconn
net.core.netdev_max_backlog = $somaxconn
net.ipv4.tcp_max_syn_backlog = $somaxconn

# 启用宽松反向路径过滤；关闭火星包日志以避免大量扫描日志
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0
EOF
    )
    write_managed_dropin /etc/sysctl.d/99-network.conf 0644 "$net_conf" || return 1

    limits_conf=$(cat <<EOF
# managed-by: archlinux-init
# PAM 用户会话级文件描述符与进程上限 (hard nofile 不低于 systemd 默认 524288)
* soft nofile $nofile_soft
* hard nofile $nofile_hard
* soft nproc  $nproc_soft
* hard nproc  $nproc_hard
EOF
    )
    write_managed_dropin /etc/security/limits.d/99-limits.conf 0644 "$limits_conf" || return 1

    if running_kernel_modules_available; then
        sudo modprobe tcp_bbr
        sudo sysctl --system > /dev/null
        printf '  ✅ 内核网络与资源上限已生效 (内存: %s MB | 缓冲区: %s | 队列: %s | nofile: %s/%s)\n' \
            "$total_ram_mb" \
            "$tier_desc" \
            "$(sysctl -n net.core.somaxconn 2>/dev/null || echo "$somaxconn")" \
            "$nofile_soft" \
            "$nofile_hard"
    else
        printf '  ⚠️  当前运行内核 (%s) 的模块目录缺失（通常因本次升级了内核），配置已落盘；将在重启进入新内核后生效。\n' "$(uname -r)"
    fi
    NETWORK_TIER_DESC="$tier_desc"
}

# ========================================================
# 基础环境初始化
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
    validate_bashrc_block archlinux-base || return 1
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
    if [[ -t 0 ]] || { true < /dev/tty; } 2>/dev/null; then
        read -rp "主机名 (Hostname) [当前: ${current_host:-archlinux}，回车保持]: " input_host < /dev/tty || input_host=""
    fi
    new_host="${input_host:-${current_host:-archlinux}}"
    [[ -n "$new_host" ]] || {
        printf '❌ 主机名不能为空\n' >&2
        exit 1
    }
    sudo hostnamectl set-hostname "$new_host"

    # 3. 官方密钥环与基础包更新
    printf '==> [3/7] 初始化官方密钥环并更新基础系统包...\n'
    run_package_init || return 1

    # 4. 本地化与时区
    printf '==> [4/7] 配置系统 Locale (en_US.UTF-8)、统一时区 (UTC) 与 NTP 时间同步...\n'
    # 直接修改系统主配置：取消 /etc/locale.gen 中 en_US.UTF-8 的注释并重置 /etc/locale.conf
    sudo sed -i 's/^#[[:space:]]*\(en_US\.UTF-8[[:space:]]\+UTF-8\)/\1/' /etc/locale.gen
    grep -qE '^[[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8([[:space:]]|$)' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' | sudo tee -a /etc/locale.gen >/dev/null
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
HISTIGNORE='ls:cd:exit:clear:history:ll'
shopt -s histappend
shopt -s checkwinsize

# 常用别名
alias ll='ls -alF'

# 彩色输出与快捷键
test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
alias ls='ls --color=auto'
alias grep='grep --color=auto'

bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'

# 自动补全
if ! shopt -oq posix && [[ -f /usr/share/bash-completion/bash_completion ]]; then
    . /usr/share/bash-completion/bash_completion
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

    upsert_managed_block "$BASHRC" "archlinux-base" "$base_content" "$base_input" || return 1

    # 对已有历史记录做首次时间戳合规化清洗（避免未配置 HISTTIMEFORMAT 前产生的裸指令造成格式断层）
    normalize_history

    # 6. 内核网络自适应调优 (BBR + 内存自适应长管道缓冲区 + 资源限制)
    printf '==> [6/7] 配置内核网络参数与系统资源上限...\n'
    NETWORK_TIER_DESC=""
    configure_network_and_limits || return 1

    # 7. 内存管理与 Swap 策略 (先检后配，单向打底)
    printf '==> [7/7] 检查系统内存管理与 Swap 状态...\n'
    manage_swap

    printf '\n✅ 基础环境初始化完成。\n'
    printf '   用户: %s | 主机名: %s | 时区: UTC (NTP 同步) | 语言: en_US.UTF-8 | 网络缓冲: %s\n' "$user_name" "$new_host" "$NETWORK_TIER_DESC"
    if ! running_kernel_modules_available; then
        printf '   ⚠️  检测到内核已升级（当前运行内核模块目录已移除），请先执行 sudo reboot 重启后再初始化防火墙或验证 BBR/zram。\n'
    fi
}

# ========================================================
# Swap 内存管理打底模块 (先检后配，有则保持，无则推荐配置)
# ========================================================

manage_swap() {
    local total_ram_kb total_ram_mb
    local swap_dev f_spec f_file f_vfstype
    total_ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    total_ram_mb=$(( total_ram_kb / 1024 ))

    # 采集系统当前活动 Swap 设备及 fstab 静态定义
    local active_swaps=()
    if [[ -f /proc/swaps ]]; then
        while read -r swap_dev _ || [[ -n "$swap_dev" ]]; do
            [[ "$swap_dev" == "Filename" ]] && continue
            [[ -n "$swap_dev" ]] && active_swaps+=("$swap_dev")
        done < /proc/swaps
    fi

    local fstab_swaps=()
    if [[ -f /etc/fstab ]]; then
        while read -r f_spec f_file f_vfstype _ || [[ -n "$f_spec" ]]; do
            [[ -z "$f_spec" || "$f_spec" =~ ^# ]] && continue
            if [[ "$f_vfstype" == "swap" || "$f_file" == "swap" ]]; then
                fstab_swaps+=("$f_spec")
            fi
        done < /etc/fstab
    fi

    # 常规初始化打底逻辑：已有 Swap 则保持现状跳过
    if (( ${#active_swaps[@]} > 0 )); then
        printf '  ℹ️  检测到活动 Swap 已就绪: %s，保持现状跳过\n' "${active_swaps[*]}"
        return 0
    fi
    if (( ${#fstab_swaps[@]} > 0 )); then
        printf '  ℹ️  检测到 /etc/fstab 中已声明 Swap (%s)，跳过自动配置以防冲突\n' "${fstab_swaps[*]}"
        return 0
    fi
    if [[ -f /etc/systemd/zram-generator.conf.d/zram0.conf ]]; then
        printf '  ℹ️  检测到 zram-generator 配置已存在，保持现状跳过\n'
        return 0
    fi

    local cpu_cores suggest_mode
    cpu_cores=$(nproc 2>/dev/null || echo 1)

    if [[ $total_ram_mb -le 1024 || $cpu_cores -le 1 ]]; then
        suggest_mode=1
    elif [[ $total_ram_mb -le 4096 && $cpu_cores -ge 2 ]]; then
        suggest_mode=2
    else
        suggest_mode=3
    fi

    printf '  🖥️  硬件信息: %s MB RAM | %s vCPU\n' "$total_ram_mb" "$cpu_cores"
    printf '  模式选项 (推荐 [%s]):\n' "$suggest_mode"
    printf '    1) 经典磁盘 Swapfile (1GB, 低 CPU 开销)\n'
    printf '    2) zram 压缩内存盘 (1/2 内存, zstd, 零磁盘磨损)\n'
    printf '    3) 纯物理内存运行 (不配置 Swap)\n'

    local chosen_mode="" tty_fd="" close_tty=0
    if { exec {tty_fd}</dev/tty; } 2>/dev/null; then
        close_tty=1
    elif [[ -t 0 ]]; then
        tty_fd=0
    fi
    if [[ -n "$tty_fd" ]]; then
        while true; do
            if ! read -r -u "$tty_fd" -p "  请选择内存模式 [1-3, 默认 $suggest_mode]: " chosen_mode; then
                (( close_tty )) && exec {tty_fd}<&-
                printf '\n❌ 未读取到有效的内存模式选择，停止配置 Swap\n' >&2
                return 1
            fi
            chosen_mode="${chosen_mode:-$suggest_mode}"
            case "$chosen_mode" in
                1|2|3) break ;;
                *) printf '  ⚠️  输入无效 (%s)，请输入 1、2 或 3\n' "$chosen_mode" >&2 ;;
            esac
        done
        (( close_tty )) && exec {tty_fd}<&-
    else
        chosen_mode="$suggest_mode"
    fi

    case "$chosen_mode" in
        1)
            printf '  ==> 配置 1GB 经典磁盘 Swapfile...\n'
            local root_fstype=""
            root_fstype=$(findmnt -no FSTYPE / 2>/dev/null) || root_fstype=""
            if [[ "$root_fstype" == "btrfs" ]]; then
                printf '❌ 检测到根文件系统为 btrfs，不支持直接 fallocate + swapon 创建 /swapfile；请选择 zram 或按 Btrfs swapfile 规范单独配置子卷\n' >&2
                return 1
            fi
            if ! sudo dd if=/dev/null of=/swapfile count=0 conv=excl status=none; then
                printf '❌ 无法新建 /swapfile，请核对该路径及权限。\n' >&2
                return 1
            fi
            sudo chmod 0600 /swapfile
            sudo fallocate -l 1G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
            sudo mkswap /swapfile >/dev/null
            sudo swapon /swapfile
            # 直接修改系统主配置：向 /etc/fstab 追加 /swapfile 持久化挂载项
            grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab 2>/dev/null || echo '/swapfile none swap defaults 0 0' | sudo tee -a /etc/fstab >/dev/null
            local mem_conf
            mem_conf=$(cat <<'EOF'
# managed-by: archlinux-init
vm.swappiness = 10
EOF
            )
            write_managed_dropin /etc/sysctl.d/99-memory.conf 0644 "$mem_conf" || return 1
            sudo sysctl -w vm.swappiness=10 >/dev/null
            printf '  ✅ 经典磁盘 Swapfile (1GB) 已激活并持久化\n'
            ;;
        2)
            printf '  ==> 配置 zram-generator 压缩内存盘...\n'
            local zswap_exists=0 zswap_active=0
            if [[ -e /sys/module/zswap/parameters/enabled ]]; then
                zswap_exists=1
                if [[ -r /sys/module/zswap/parameters/enabled ]] && [[ "$(< /sys/module/zswap/parameters/enabled)" == "Y" ]]; then
                    zswap_active=1
                fi
            fi
            sudo pacman -S --needed --noconfirm zram-generator

            local zram_swappiness=100
            if (( total_ram_mb > 1024 && total_ram_mb <= 4096 && cpu_cores >= 2 )); then
                zram_swappiness=180
            fi
            local mem_conf
            mem_conf=$(cat <<EOF
# managed-by: archlinux-init
vm.swappiness = $zram_swappiness
vm.page-cluster = 0
EOF
            )
            write_managed_dropin /etc/sysctl.d/99-memory.conf 0644 "$mem_conf" || return 1

            if (( zswap_exists )); then
                local zswap_conf
                zswap_conf=$(cat <<'EOF'
# managed-by: archlinux-init
w /sys/module/zswap/parameters/enabled - - - - 0
EOF
                )
                write_managed_dropin /etc/tmpfiles.d/zswap.conf 0644 "$zswap_conf" || return 1
            fi

            local zram_conf
            zram_conf=$(cat <<'EOF'
# managed-by: archlinux-init
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
            )
            write_managed_dropin /etc/systemd/zram-generator.conf.d/zram0.conf 0644 "$zram_conf" || return 1

            local zswap_runtime_disabled=0
            if (( zswap_active )); then
                local rc=0
                echo 0 | sudo tee /sys/module/zswap/parameters/enabled >/dev/null || rc=$?
                if (( rc != 0 )); then
                    printf '❌ 运行时停用 zswap 失败；已保留 /etc/systemd/zram-generator.conf.d/zram0.conf，重跑脚本将跳过已有 Swap 配置，请手工停用 zswap 并激活 dev-zram0.swap\n' >&2
                    return "$rc"
                fi
                zswap_runtime_disabled=1
            fi

            if running_kernel_modules_available || [[ -d /sys/module/zram ]]; then
                local rc=0
                sudo sysctl -p /etc/sysctl.d/99-memory.conf >/dev/null || rc=$?
                if (( rc == 0 )); then
                    sudo systemctl daemon-reload || rc=$?
                fi
                if (( rc == 0 )); then
                    sudo systemctl start dev-zram0.swap || rc=$?
                fi
                if (( rc != 0 )); then
                    if (( zswap_runtime_disabled )); then
                        printf '❌ zram 激活或内存参数应用失败（运行时 zswap 已被停用）；已保留 /etc/systemd/zram-generator.conf.d/zram0.conf，重跑脚本将跳过已有 Swap 配置，请手工完成校验并激活 dev-zram0.swap\n' >&2
                    else
                        printf '❌ zram 激活或内存参数应用失败；已保留 /etc/systemd/zram-generator.conf.d/zram0.conf，重跑脚本将跳过已有 Swap 配置，请手工完成校验并激活 dev-zram0.swap\n' >&2
                    fi
                    return "$rc"
                fi
                printf '  ✅ zram 压缩内存盘已激活 (1/2 内存, zstd 算法, swappiness=%s, page-cluster=0)\n' "$zram_swappiness"
            else
                printf '  ⚠️  当前运行内核模块目录缺失，zram 与内存参数配置已落盘 (swappiness=%s, page-cluster=0)，将在重启进入新内核后自动激活\n' "$zram_swappiness"
            fi
            ;;
        3)
            printf '  ⏭️  保持纯物理内存运行，未配置 Swap\n'
            ;;
        *)
            return 1
            ;;
    esac
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
            validate_arch_host || return 1
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
