#!/usr/bin/env bash
#
# server/os/host/archlinux-init.sh
# Arch Linux 基础环境初始化与扩展工具链选配脚本
#

set -Eeuo pipefail

normalize_dir_path() {
    local p="$1"
    while [[ "$p" == */ && "$p" != "/" ]]; do
        p="${p%/}"
    done
    printf '%s\n' "$p"
}

parent_dir_of() {
    local p
    p=$(normalize_dir_path "$1")
    if [[ "$p" == */* ]]; then
        local d="${p%/*}"
        normalize_dir_path "${d:-/}"
    else
        printf '.\n'
    fi
}

validate_non_symlink_dir() {
    local dir_path="$1" label="$2"
    [[ ! -L "$dir_path" ]] || { printf '✘ %s是符号链接，停止：%s\n' "$label" "$dir_path" >&2; return 1; }
    [[ ! -e "$dir_path" || -d "$dir_path" ]] || { printf '✘ %s路径不是目录，停止：%s\n' "$label" "$dir_path" >&2; return 1; }
}

validate_dir_chain() {
    local target_dir="$1" need_write="${2:-1}"
    shift 2
    local -a paths=() labels=()
    while (( $# >= 2 )); do
        paths+=("$1")
        labels+=("$2")
        shift 2
    done

    local i
    for (( i = 0; i < ${#paths[@]}; i++ )); do
        validate_non_symlink_dir "${paths[i]}" "${labels[i]}" || return 1
    done

    if (( need_write )); then
        local cur="$target_dir" next_cur
        while [[ ! -e "$cur" && "$cur" != "/" && "$cur" != "." ]]; do
            [[ ! -L "$cur" ]] || { printf '✘ 祖先路径是符号链接，停止：%s\n' "$cur" >&2; return 1; }
            next_cur=$(parent_dir_of "$cur")
            [[ "$next_cur" != "$cur" ]] || break
            cur="$next_cur"
        done
        [[ ! -L "$cur" ]] || { printf '✘ 祖先路径是符号链接，停止：%s\n' "$cur" >&2; return 1; }
        [[ -d "$cur" ]] || { printf '✘ 祖先路径不是目录，停止：%s\n' "$cur" >&2; return 1; }
        [[ -w "$cur" ]] || { printf '✘ 目录不可写，停止：%s\n' "$cur" >&2; return 1; }
    fi
}

BASHRC="$HOME/.bashrc"
_xdg_config_home=$(normalize_dir_path "${XDG_CONFIG_HOME:-$HOME/.config}")
ENV_CONF="${_xdg_config_home%/}/environment.d/50-archlinux-init.conf"
unset _xdg_config_home
readonly ENV_PATH_FALLBACK='/usr/local/sbin:/usr/local/bin:/usr/bin'
BASHRC_CHANGED=0
ENV_CHANGED=0
OPTIONAL_FAILURE_HINT_SHOWN=0
declare -a _CLEANUP_DIRS=()

cleanup_temp_dirs() {
    (( ${#_CLEANUP_DIRS[@]} == 0 )) || rm -rf -- "${_CLEANUP_DIRS[@]}"
}
trap cleanup_temp_dirs EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

validate_arch_host() {
    local machine release=/etc/os-release
    machine=$(uname -m) || return 1
    [[ "$machine" == x86_64 ]] || {
        printf '✘ 仅支持 Arch Linux x86-64，检测到架构：%s\n' "$machine" >&2
        return 1
    }
    if [[ ! -e "$release" && ! -L "$release" ]]; then release=/usr/lib/os-release; fi
    if [[ ! -f "$release" || ! -r "$release" ]] || ! awk '
        /^ID=/ { count++; if ($0 ~ /^ID=(arch|"arch"|\047arch\047)$/) good++ }
        END { exit (count != 1 || good != 1) }
    ' "$release"; then
        printf '✘ 无法确认当前系统是 Arch Linux：%s\n' "$release" >&2
        return 1
    fi
}

# ========================================================
# 受控分界标记块工具函数 (Managed Block Utilities)
# 基于 awk 流式原样读取，杜绝特殊字符与正则转义异常
# ========================================================

validate_bashrc() {
    validate_managed_file_and_parents "$BASHRC" "~/.bashrc " "~/.bashrc 父" "" 1 1 1
}

process_managed_block() {
    local input_file="$1" tag="$2" content_file="${3:-}"
    MANAGED_BLOCK_CONTENT="$content_file" awk -v b="# >>> managed:${tag} >>>" -v e="# <<< managed:${tag} <<<" '
        BEGIN { cfile = ENVIRON["MANAGED_BLOCK_CONTENT"] }
        function reject_markers() {
            printf "✘ 受控块标记残缺、重复或重叠：%s\n", b > "/dev/stderr"
            failed = 1
            exit 1
        }
        function emit_block(    line, status) {
            print b
            while ((status = (getline line < cfile)) > 0) print line
            close(cfile)
            if (status < 0) {
                printf "✘ 无法读取受控块内容：%s\n", b > "/dev/stderr"
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
    local input_file="${4:-$target_file}" change_var="${5:-}" default_mode="${6:-0644}"
    [[ "$target_file" != "$BASHRC" ]] || validate_bashrc || return 1

    local existed=0
    if [[ -e "$target_file" ]]; then
        existed=1
    else
        input_file=/dev/null
    fi
    write_checked_managed_file "$target_file" "$existed" "$change_var" "$default_mode" "$content" \
        process_managed_block "$input_file" "$tag"
}

has_managed_block() {
    local target_file="$1"
    local tag="$2"
    [[ -f "$target_file" && ! -L "$target_file" && -r "$target_file" ]] || return 1
    awk -v b="# >>> managed:${tag} >>>" -v e="# <<< managed:${tag} <<<" '
        $0 == b { if (seen || in_b) { bad = 1; exit 1 }; seen = in_b = 1; next }
        $0 == e { if (!in_b) { bad = 1; exit 1 }; in_b = 0; next }
        END { exit (bad || !seen || in_b ? 1 : 0) }
    ' "$target_file"
}

managed_block_contains() {
    local target_file="$1" tag="$2" needle="$3"
    [[ -f "$target_file" && ! -L "$target_file" && -r "$target_file" ]] || return 1
    awk -v b="# >>> managed:${tag} >>>" -v e="# <<< managed:${tag} <<<" -v needle="$needle" '
        $0 == b { in_b = 1; next }
        $0 == e { in_b = 0; next }
        in_b && index($0, needle) { found = 1; exit 0 }
        END { exit (found ? 0 : 1) }
    ' "$target_file"
}

apply_bashrc_block() {
    local tag="$1" content="$2" input_file="${3:-$BASHRC}"
    upsert_managed_block "$BASHRC" "$tag" "$content" "$input_file" BASHRC_CHANGED 0644
}

commit_checked_managed_file() {
    local target_file="$1" tmp_file="$2" existed="$3" change_var="$4" default_mode="${5:-}"
    if ! bash -n "$tmp_file"; then
        rm -f -- "$tmp_file"
        printf '✘ %s 受控块语法校验失败，请检查配置\n' "$target_file" >&2
        return 1
    fi
    if (( existed )) && cmp -s -- "$target_file" "$tmp_file"; then
        rm -f -- "$tmp_file"
        return 0
    fi
    if (( existed )); then
        if ! cp --attributes-only --preserve=mode,ownership "$target_file" "$tmp_file"; then
            rm -f -- "$tmp_file"
            return 1
        fi
    elif [[ -n "$default_mode" ]]; then
        chmod "$default_mode" "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    fi
    mv -f -- "$tmp_file" "$target_file" || { rm -f -- "$tmp_file"; return 1; }
    if [[ -n "$change_var" ]]; then
        local -n _changed_ref="$change_var"
        _changed_ref=1
    fi
}

validate_managed_file_and_parents() {
    local target_file="$1" file_label="$2" parent_label="$3" root_label="$4"
    local check_bash="${5:-0}" require_writable="${6:-1}" parent_levels="${7:-2}"
    local parent_dir root_dir need_dir_write=0
    local -a chain_args=()
    parent_dir=$(parent_dir_of "$target_file")
    if (( parent_levels >= 2 )); then
        root_dir=$(parent_dir_of "$parent_dir")
        chain_args+=("$root_dir" "$root_label")
    fi
    chain_args+=("$parent_dir" "$parent_label")
    if (( require_writable )) || [[ ! -e "$target_file" ]]; then
        need_dir_write=1
    fi
    validate_dir_chain "$parent_dir" "$need_dir_write" "${chain_args[@]}" || return 1
    [[ ! -L "$target_file" ]] || { printf '✘ %s是符号链接，停止：%s\n' "$file_label" "$target_file" >&2; return 1; }
    if [[ -e "$target_file" ]]; then
        local perm_ok=0
        if (( require_writable )); then
            [[ -f "$target_file" && -r "$target_file" && -w "$target_file" ]] && perm_ok=1
        else
            [[ -f "$target_file" && -r "$target_file" ]] && perm_ok=1
        fi
        (( perm_ok )) || {
            printf '✘ %s无法%s，停止：%s\n' "$file_label" "$( (( require_writable )) && echo "读写" || echo "读取" )" "$target_file" >&2
            return 1
        }
    fi
    if (( check_bash )) && [[ -e "$target_file" ]]; then
        bash -n "$target_file" || {
            printf '✘ 已有 %s 语法异常，停止\n' "$target_file" >&2
            return 1
        }
    fi
}

validate_env_conf() {
    validate_managed_file_and_parents "$ENV_CONF" "environment.d 配置文件" "environment.d " "配置目录" 1 1
}

validate_env_block() {
    validate_env_conf || return 1
    [[ ! -e "$ENV_CONF" ]] || process_managed_block "$ENV_CONF" "$1"
}

write_checked_managed_file() {
    local target_file="$1" existed="$2" change_var="$3" default_mode="$4" content="$5"
    shift 5
    local content_file tmp_file
    content_file=$(mktemp "${target_file}.content.XXXXXX") || return 1
    tmp_file=$(mktemp "${target_file}.tmp.XXXXXX") || { rm -f -- "$content_file"; return 1; }

    if ! printf '%s\n' "$content" > "$content_file" ||
       ! "$@" "$content_file" > "$tmp_file"; then
        rm -f -- "$content_file" "$tmp_file"
        return 1
    fi
    rm -f -- "$content_file"

    commit_checked_managed_file "$target_file" "$tmp_file" "$existed" "$change_var" "$default_mode"
}

apply_env_block() {
    local tag="$1" content="$2"
    validate_env_conf || return 1
    mkdir -p "$(parent_dir_of "$ENV_CONF")" || return 1
    upsert_managed_block "$ENV_CONF" "$tag" "$content" "$ENV_CONF" ENV_CHANGED 0644
}

apply_env_path_block() {
    local tag="$1" prefix_expr="$2"
    apply_env_block "$tag" "PATH=${prefix_expr}:\${PATH:-${ENV_PATH_FALLBACK}}"
}

insert_block_before_guard() {
    local input_file="$1" tag="$2" content_file="$3"
    # 插入至 archlinux-base 受控块或首个非交互守卫之前，保证非交互加载生效且不与已有块重叠
    MANAGED_BLOCK_CONTENT="$content_file" awk -v b="# >>> managed:${tag} >>>" -v e="# <<< managed:${tag} <<<" '
        BEGIN { cfile = ENVIRON["MANAGED_BLOCK_CONTENT"] }
        function emit_block(    line, status) {
            print b
            while ((status = (getline line < cfile)) > 0) print line
            close(cfile)
            if (status < 0) {
                printf "✘ 无法读取受控块内容：%s\n", b > "/dev/stderr"
                failed = 1
                exit 1
            }
            print e
        }
        /^# >>> managed:[^[:space:]]+ >>>$/ {
            if (!inserted && $3 == "managed:archlinux-base") {
                emit_block()
                print ""
                inserted = 1
            }
            in_other = 1
            print
            next
        }
        /^# <<< managed:[^[:space:]]+ <<<$/ {
            in_other = 0
            print
            next
        }
        !inserted && !in_other && /^[[:space:]]*(\[\[[[:space:]]+\$-[[:space:]]+!=[[:space:]]+\*i\*[[:space:]]+\]\]|\[[[:space:]]+\$-[[:space:]]+!=[[:space:]]+\*i\*[[:space:]]+\])[[:space:]]+&&[[:space:]]+return([[:space:]]+[0-9]+)?([[:space:]]*;?[[:space:]]*(#.*)?$|;)/ {
            emit_block()
            print ""
            inserted = 1
        }
        { print }
        END {
            if (failed) exit 1
            if (!inserted) {
                print ""
                emit_block()
            }
        }
    ' "$input_file"
}

ensure_bashrc_block_before_guard() {
    local tag="$1" content="$2"
    validate_bashrc_block "$tag" || return 1
    if [[ ! -e "$BASHRC" ]] || has_managed_block "$BASHRC" "$tag"; then
        apply_bashrc_block "$tag" "$content"
        return $?
    fi

    write_checked_managed_file "$BASHRC" 1 BASHRC_CHANGED "" "$content" \
        insert_block_before_guard "$BASHRC" "$tag"
}

ensure_bashrc_env_loader() {
    local content
    content=$(cat <<'EOF'
# 非交互式与交互式共用单一用户环境真源 (environment.d)
if [[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/50-archlinux-init.conf" && ! -L "${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/50-archlinux-init.conf" ]]; then
    _arch_was_allexport=0
    if [[ $- == *a* ]]; then
        _arch_was_allexport=1
    fi
    set -a
    # shellcheck source=/dev/null
    . "${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/50-archlinux-init.conf"
    (( _arch_was_allexport )) || set +a
    unset _arch_was_allexport
    _arch_dedup_path() {
        local _rem="${PATH:-}:" _p _out="" _seen=":"
        while [[ -n "$_rem" ]]; do
            _p="${_rem%%:*}"
            _rem="${_rem#*:}"
            [[ -n "$_p" && "$_seen" != *":$_p:"* ]] && { _out="${_out:+$_out:}$_p"; _seen+="$_p:"; }
        done
        PATH="$_out"
    }
    _arch_dedup_path
    unset -f _arch_dedup_path
fi
EOF
    )
    ensure_bashrc_block_before_guard "archlinux:env" "$content"
}

ensure_local_bin_path() {
    mkdir -p "$HOME/.local/bin" || return $?
    apply_env_path_block "archlinux:local-bin" '${HOME}/.local/bin'
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
    local cand err j k n use_existing_stamp tail_bs tmp_l complete_end

    # 按行扫描：单行时间戳条目零开销原样保留；多行块用 bash -n 区分真多行命令与混入的裸行
    local total=${#raw_lines[@]} idx=0
    while (( idx <= total )); do
        if (( idx == total )) || [[ "${raw_lines[idx]}" =~ ^#[0-9]+$ ]]; then
            n=${#block_lines[@]}
            if (( seen_stamp == 1 && n == 0 )); then
                out_lines+=("$current_stamp")
            elif (( seen_stamp == 1 && n == 1 )); then
                out_lines+=("$current_stamp" "${block_lines[0]}")
            elif (( n > 0 )); then
                use_existing_stamp=$seen_stamp
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
                    if (( use_existing_stamp )); then
                        out_lines+=("$current_stamp")
                        use_existing_stamp=0
                        if (( complete_end < n - 1 )); then
                            needs_rewrite=1
                        fi
                    else
                        needs_rewrite=1
                        out_lines+=("#$(( base_time + count ))")
                        count=$(( count + 1 ))
                    fi
                    for (( k = j; k <= complete_end; k++ )); do
                        out_lines+=("${block_lines[k]}")
                    done
                    j=$(( complete_end + 1 ))
                done
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
        printf '  ○ 已自动规范化已有历史记录的时间戳格式\n'
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
        printf '✘ 受控配置路径是符号链接，停止：%s\n' "$target" >&2
        return 1
    fi
    if sudo test -e "$target"; then
        sudo test -f "$target" || {
            printf '✘ 受控配置路径不是普通文件，停止：%s\n' "$target" >&2
            return 1
        }
        sudo grep -Fqx '# managed-by: archlinux-init' "$target" || {
            printf '✘ 存在未纳管的同名配置文件，拒绝覆盖：%s\n' "$target" >&2
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
        printf '  ✔ 内核网络与资源上限已生效 (内存: %s MB | 缓冲区: %s | 队列: %s | nofile: %s/%s)\n' \
            "$total_ram_mb" \
            "$tier_desc" \
            "$(sysctl -n net.core.somaxconn 2>/dev/null || echo "$somaxconn")" \
            "$nofile_soft" \
            "$nofile_hard"
    else
        printf '  ▲ 当前运行内核 (%s) 的模块目录缺失（通常因本次升级了内核），配置已落盘；将在重启进入新内核后生效。\n' "$(uname -r)"
    fi
    NETWORK_TIER_DESC="$tier_desc"
}

# ========================================================
# 宿主初始化主流程
# ========================================================

validate_user_environment() {
    local user_name expected_home
    user_name=$(id -un) || return 1
    [[ "$user_name" != "root" ]] || {
        printf '✘ 请以具备 sudo 权限的普通用户执行，禁止直接以 root 执行\n' >&2
        return 1
    }
    IFS=: read -r _ _ _ _ _ expected_home _ < <(getent passwd "$user_name") || {
        printf '✘ 无法查询当前用户的系统家目录\n' >&2
        return 1
    }
    [[ -n "$expected_home" && "$HOME" == "$expected_home" ]] || {
        printf '✘ HOME 环境变量 (%s) 与系统家目录 (%s) 不一致\n' "$HOME" "$expected_home" >&2
        return 1
    }
    cd "$expected_home" || return 1
    id -nG "$user_name" | tr ' ' '\n' | grep -Fxq wheel || {
        printf '✘ 当前用户不在 wheel 组\n' >&2
        return 1
    }
}

run_host_init() {
    # 1. 验证用户环境与权限基线
    printf '\n▶ [1/8] 验证用户权限与 SSH 基线...\n'
    validate_user_environment || return 1
    local user_name
    user_name="$(id -un)" || return 1
    validate_bashrc_block archlinux-base || return 1
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    [[ -f "$HOME/.ssh/authorized_keys" ]] || {
        printf '✘ 未找到 ~/.ssh/authorized_keys\n' >&2
        return 1
    }
    chmod 600 "$HOME/.ssh/authorized_keys"

    sudo -v || {
        printf '✘ sudo 提权验证失败\n' >&2
        return 1
    }

    # 2. 设置主机名
    printf '▶ [2/8] 配置系统主机名...\n'
    local current_host input_host new_host tty_fd="" close_tty=0
    current_host=$(hostnamectl hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || true)
    input_host=""
    open_interactive_tty tty_fd close_tty "未检测到交互终端，拒绝非交互执行" || return 1
    if ! read -r -u "$tty_fd" -p "主机名 (Hostname) [当前: ${current_host:-archlinux}，回车保持]: " input_host; then
        close_interactive_tty "$tty_fd" "$close_tty"
        printf '\n✘ 未读取到有效的主机名输入，停止初始化\n' >&2
        return 1
    fi
    close_interactive_tty "$tty_fd" "$close_tty"
    new_host="${input_host:-${current_host:-archlinux}}"
    [[ -n "$new_host" ]] || {
        printf '✘ 主机名不能为空\n' >&2
        return 1
    }
    sudo hostnamectl set-hostname "$new_host"

    # 3. 官方密钥环与基础包更新
    printf '▶ [3/8] 初始化官方密钥环并更新基础系统包...\n'
    run_package_init || return 1

    # 4. 本地化与时区
    printf '▶ [4/8] 配置系统 Locale (en_US.UTF-8)、统一时区 (UTC) 与 NTP 时间同步...\n'
    # 直接修改系统主配置：取消 /etc/locale.gen 中 en_US.UTF-8 的注释并重置 /etc/locale.conf
    sudo sed -i 's/^#[[:space:]]*\(en_US\.UTF-8[[:space:]]\+UTF-8\)/\1/' /etc/locale.gen
    grep -qE '^[[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8([[:space:]]|$)' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' | sudo tee -a /etc/locale.gen >/dev/null
    sudo locale-gen
    sudo localectl set-locale LANG=en_US.UTF-8
    sudo timedatectl set-timezone UTC
    sudo timedatectl set-ntp true

    # 5. ~/.bashrc 通用受控配置
    printf '▶ [5/8] 写入 ~/.bashrc 通用受控基础配置...\n'
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

    apply_bashrc_block "archlinux-base" "$base_content" "$base_input" || return 1

    # 对已有历史记录做首次时间戳合规化清洗（避免未配置 HISTTIMEFORMAT 前产生的裸指令造成格式断层）
    normalize_history

    # 6. 内核网络自适应调优 (BBR + 内存自适应长管道缓冲区 + 资源限制)
    printf '▶ [6/8] 配置内核网络参数与系统资源上限...\n'
    NETWORK_TIER_DESC=""
    configure_network_and_limits || return 1

    # 7. 内存管理与 Swap 策略 (先检后配，单向打底)
    printf '▶ [7/8] 检查系统内存管理与 Swap 状态...\n'
    manage_swap || return $?

    # 8. 可选扩展与工具链选配 (回车默认跳过)
    printf '▶ [8/8] 可选扩展与工具链选配...\n'
    run_optional_menu || return $?

    printf '\n✔ 系统初始化与选配阶段完成。\n'
    printf '   用户: %s | 主机名: %s | 时区: UTC (NTP 同步) | 语言: en_US.UTF-8 | 网络缓冲: %s\n' "$user_name" "$new_host" "$NETWORK_TIER_DESC"
    if ! running_kernel_modules_available; then
        printf '   ▲ 检测到内核已升级（当前运行内核模块目录已移除），请先执行 sudo reboot 重启后再初始化防火墙或验证 BBR/zram（重启后所有 Shell 与环境配置将一并生效）。\n'
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
        printf '  ○ 检测到活动 Swap 已就绪: %s，保持现状跳过\n' "${active_swaps[*]}"
        return 0
    fi
    if (( ${#fstab_swaps[@]} > 0 )); then
        printf '  ○ 检测到 /etc/fstab 中已声明 Swap (%s)，跳过自动配置以防冲突\n' "${fstab_swaps[*]}"
        return 0
    fi
    if [[ -f /etc/systemd/zram-generator.conf.d/zram0.conf ]]; then
        printf '  ○ 检测到 zram-generator 配置已存在，保持现状跳过\n'
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

    printf '  ○ 硬件信息: %s MB RAM | %s vCPU\n' "$total_ram_mb" "$cpu_cores"
    printf '  模式选项 (推荐 [%s]):\n' "$suggest_mode"
    printf '    1) 经典磁盘 Swapfile (1GB, 低 CPU 开销)\n'
    printf '    2) zram 压缩内存盘 (1/2 内存, zstd, 零磁盘磨损)\n'
    printf '    3) 纯物理内存运行 (不配置 Swap)\n'

    local chosen_mode="" tty_fd="" close_tty=0
    open_interactive_tty tty_fd close_tty "未检测到交互终端，停止配置 Swap" || return 1
    while true; do
        if ! read -r -u "$tty_fd" -p "  请选择内存模式 [1-3, 默认 $suggest_mode]: " chosen_mode; then
            close_interactive_tty "$tty_fd" "$close_tty"
            printf '\n✘ 未读取到有效的内存模式选择，停止配置 Swap\n' >&2
            return 1
        fi
        chosen_mode="${chosen_mode:-$suggest_mode}"
        case "$chosen_mode" in
            1|2|3) break ;;
            *) printf '  ▲ 输入无效 (%s)，请输入 1、2 或 3\n' "$chosen_mode" >&2 ;;
        esac
    done
    close_interactive_tty "$tty_fd" "$close_tty"

    case "$chosen_mode" in
        1)
            printf '  ▶ 配置 1GB 经典磁盘 Swapfile...\n'
            local root_fstype=""
            root_fstype=$(findmnt -no FSTYPE / 2>/dev/null) || root_fstype=""
            if [[ "$root_fstype" == "btrfs" ]]; then
                printf '✘ 检测到根文件系统为 btrfs，不支持直接 fallocate + swapon 创建 /swapfile；请选择 zram 或按 Btrfs swapfile 规范单独配置子卷\n' >&2
                return 1
            fi
            if ! sudo dd if=/dev/null of=/swapfile count=0 conv=excl status=none; then
                printf '✘ 无法新建 /swapfile，请核对该路径及权限。\n' >&2
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
            printf '  ✔ 经典磁盘 Swapfile (1GB) 已激活并持久化\n'
            ;;
        2)
            printf '  ▶ 配置 zram-generator 压缩内存盘...\n'
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
                    printf '✘ 运行时停用 zswap 失败；已保留 /etc/systemd/zram-generator.conf.d/zram0.conf，重跑脚本将跳过已有 Swap 配置，请手工停用 zswap 并激活 dev-zram0.swap\n' >&2
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
                        printf '✘ zram 激活或内存参数应用失败（运行时 zswap 已被停用）；已保留 /etc/systemd/zram-generator.conf.d/zram0.conf，重跑脚本将跳过已有 Swap 配置，请手工完成校验并激活 dev-zram0.swap\n' >&2
                    else
                        printf '✘ zram 激活或内存参数应用失败；已保留 /etc/systemd/zram-generator.conf.d/zram0.conf，重跑脚本将跳过已有 Swap 配置，请手工完成校验并激活 dev-zram0.swap\n' >&2
                    fi
                    return "$rc"
                fi
                printf '  ✔ zram 压缩内存盘已激活 (1/2 内存, zstd 算法, swappiness=%s, page-cluster=0)\n' "$zram_swappiness"
            else
                printf '  ▲ 当前运行内核模块目录缺失，zram 与内存参数配置已落盘 (swappiness=%s, page-cluster=0)，将在重启进入新内核后自动激活\n' "$zram_swappiness"
            fi
            ;;
        3)
            printf '  ○ 保持纯物理内存运行，未配置 Swap\n'
            ;;
    esac
}

# ========================================================
# 可选扩展与工具链选配 (1-8，回车默认跳过)
# ========================================================

setup_git() {
    install_simple_cli_tool "Git 版本控制 (git)" "Git" git git
}

setup_shell_enhance() {
    local action="配置" has_git=0
    has_managed_block "$BASHRC" "archlinux:shell-enhance" && action="覆盖更新"
    command -v git >/dev/null 2>&1 && has_git=1
    printf '▶ [%s] Shell 体验增强 (历史同步/去重与退出码高亮%s)...\n' \
        "$action" "$( (( has_git )) && echo "、Git 分支提示" || echo "" )"

    # 首次注入前规范化历史时间戳格式，防止去重校验因裸行失败
    normalize_history || return $?
    local content
    content=$(cat <<'EOF'
shopt -s histappend
__sync_history() {
    local saved_status=$?
    history -a
    history -n
    return "$saved_status"
}
if [[ " ${PROMPT_COMMAND[*]-} " != *" __sync_history "* ]]; then
    _arch_pc=(__sync_history)
    for _arch_pc_item in ${PROMPT_COMMAND[@]+"${PROMPT_COMMAND[@]}"}; do
        [[ -n "$_arch_pc_item" ]] && _arch_pc+=("$_arch_pc_item")
    done
    PROMPT_COMMAND=("${_arch_pc[@]}")
    unset _arch_pc _arch_pc_item
fi

[[ -n "${HISTTIMEFORMAT:-}" ]] || HISTTIMEFORMAT="%F %T %z "
dedup-history() {
    local histfile=${HISTFILE:-$HOME/.bash_history}
    local tmpfile
    [[ -L "$histfile" ]] && { printf 'HISTFILE 是符号链接：%s；停止。\n' "$histfile"; return 1; }
    [[ -e "$histfile" ]] || { printf 'HISTFILE 不存在：%s；暂无历史记录，安全结束。\n' "$histfile"; return 0; }
    [[ -f "$histfile" && -r "$histfile" && -w "$histfile" ]] || { printf 'HISTFILE 不是当前用户可读写的普通文件：%s；停止。\n' "$histfile"; return 1; }
    [[ -s "$histfile" ]] || { printf 'HISTFILE 为空：%s；安全结束。\n' "$histfile"; return 0; }
    history -a || { printf '%s\n' 'history -a 失败，未执行去重。'; return 1; }
    local histdir=${histfile%/*}
    [[ "$histdir" != "$histfile" ]] || histdir=.
    tmpfile=$(command mktemp "$histdir/.bash_history.tmp.XXXXXX") || { printf '%s\n' '无法创建历史临时文件，未执行去重。'; return 1; }
    if ! command awk '
        function fail(msg) {
            printf "历史文件第 %d 行格式异常：%s；未执行去重。\n", NR, msg > "/dev/stderr"
            bad=1
            exit 2
        }
        /^#[0-9]+$/ {
            if (have_stamp && !have_cmd) fail("时间戳后缺少对应命令")
            if (have_cmd) {
                count++
                stamp[count] = curr_stamp
                text[count] = curr_cmd
            }
            have_stamp = 1
            have_cmd = 0
            curr_stamp = $0
            curr_cmd = ""
            next
        }
        {
            if (!have_stamp) fail("首条命令前缺少 #数字 时间戳")
            if (!have_cmd) {
                curr_cmd = $0
                have_cmd = 1
            } else {
                curr_cmd = curr_cmd "\n" $0
            }
        }
        END {
            if (bad) exit 2
            if (have_stamp && !have_cmd) fail("文件末尾时间戳后缺少对应命令")
            if (have_cmd) {
                count++
                stamp[count] = curr_stamp
                text[count] = curr_cmd
            }
            if (count == 0) fail("未解析到有效命令记录")
            for (i = 1; i <= count; i++) last[text[i]] = i
            for (i = 1; i <= count; i++) {
                if (last[text[i]] == i) {
                    print stamp[i]
                    print text[i]
                }
            }
        }' "$histfile" > "$tmpfile"; then
        command rm -f -- "$tmpfile"
        return 1
    fi
    if [[ ! -s "$tmpfile" ]]; then
        command rm -f -- "$tmpfile"
        printf '%s\n' '去重后结果为空，原文件未修改。'
        return 1
    fi
    if ! command cp --attributes-only --preserve=mode,ownership -- "$histfile" "$tmpfile"; then
        command rm -f -- "$tmpfile"
        printf '%s\n' '无法保留历史文件权限或所有者，原文件未修改。'
        return 1
    fi
    command mv -f -- "$tmpfile" "$histfile" || { command rm -f -- "$tmpfile"; printf '%s\n' '历史文件替换失败，停止。'; return 1; }
    history -c
    history -r || { printf '%s\n' '历史文件已更新，但当前 Shell 重新加载失败。'; return 1; }
    printf '%s\n' '历史记录已去重；重复命令保留最后一次记录。'
}

__prompt_color=0
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    __prompt_color=1
fi
__exit_status() {
    local status=$?
    if (( status != 0 )); then
        if (( __prompt_color )); then
            printf '\001\e[01;31m\002[%s]\001\e[00m\002 ' "$status"
        else
            printf '[%s] ' "$status"
        fi
    fi
}
if [[ "${PS1:-}" != *'$(__exit_status)'* ]]; then
    PS1='$(__exit_status)'"${PS1:-}"
fi
EOF
    )
    if (( has_git )); then
        local git_prompt_block
        git_prompt_block=$(cat <<'EOF'
__git_info() {
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return
    [[ -n "$branch" ]] || return
    if git status --porcelain -uno --ignore-submodules 2>/dev/null | command grep -q .; then
        printf ' (%s*)' "$branch"
    else
        printf ' (%s)' "$branch"
    fi
}
if [[ "${PS1:-}" != *'$(__git_info)'* ]]; then
    if (( __prompt_color )); then
        __git_prompt_seg='\[\e[01;33m\]$(__git_info)\[\e[00m\]'
    else
        __git_prompt_seg='$(__git_info)'
    fi
    if [[ "${PS1:-}" == *'\$ ' ]]; then
        PS1="${PS1%'\$ '}${__git_prompt_seg}"'\$ '
    elif [[ "${PS1:-}" == *'$ ' ]]; then
        PS1="${PS1%'$ '}${__git_prompt_seg}"'$ '
    else
        PS1="${PS1:-}${__git_prompt_seg}"
    fi
    unset __git_prompt_seg
fi
EOF
        )
        content+=$'\n\n'"$git_prompt_block"
    fi
    apply_bashrc_block "archlinux:shell-enhance" "$content" || return $?
    if (( has_git )); then
        printf '  ✔ Shell 体验增强已就绪（历史实时同步、dedup-history、退出码提示、Git 分支提示）\n'
    else
        printf '  ✔ Shell 体验增强已就绪（历史实时同步、dedup-history、退出码提示；未安装 git，未写入分支逻辑）\n'
    fi
}

install_simple_cli_tool() {
    local label="$1" done_name="$2" cmd="$3" pkg="$4"
    local action="安装" ver=""
    command -v "$cmd" >/dev/null 2>&1 && action="更新"
    printf '▶ [%s] %s...\n' "$action" "$label"
    sudo pacman -S --needed --noconfirm "$pkg" || return $?
    IFS= read -r ver < <("$cmd" --version) || true
    printf '  ✔ %s 已就绪: %s\n' "$done_name" "$ver"
}

validate_micro_conf() {
    local default_cfg
    default_cfg=$(normalize_dir_path "${XDG_CONFIG_HOME:-$HOME/.config}")
    validate_managed_file_and_parents "${default_cfg%/}/micro/settings.json" "Micro 配置文件" "Micro 配置目录" "配置目录" 0 0
}

setup_micro() {
    local action="安装与配置"
    command -v micro >/dev/null 2>&1 && action="覆盖更新"
    printf '▶ [%s] Micro 终端编辑器...\n' "$action"
    validate_micro_conf || return 1
    sudo pacman -S --needed --noconfirm micro || return $?
    local default_cfg micro_dir micro_conf
    default_cfg=$(normalize_dir_path "${XDG_CONFIG_HOME:-$HOME/.config}")
    micro_dir="${default_cfg%/}/micro"
    micro_conf="${micro_dir}/settings.json"
    mkdir -p "$micro_dir" || return $?
    if [[ ! -e "$micro_conf" ]]; then
        cat > "$micro_conf" <<'EOF' || return $?
{
  "tabsize": 4,
  "tabstospaces": true,
  "clipboard": "terminal",
  "wordwrap": true,
  "softwrap": true
}
EOF
    else
        printf '  ○ 已存在 %s，保留原配置\n' "$micro_conf"
    fi
    local env_content
    env_content=$(cat <<'EOF'
EDITOR=micro
VISUAL=micro
EOF
    )
    apply_env_block "archlinux:editor-micro" "$env_content" || return $?
    ensure_bashrc_env_loader || return $?
    printf '  ✔ Micro 编辑器已就绪，并设为默认系统编辑器\n'
}

paru_build_and_install() {
    local repo="$1" compile_profile="$2"
    local build_parent="${XDG_CACHE_HOME:-$HOME/.cache}"
    mkdir -p "$build_parent" || return 1
    local build_dir
    build_dir=$(mktemp -d "$build_parent/paru-build.XXXXXX") || {
        printf '✘ 无法创建临时构建目录\n' >&2
        return 1
    }
    _CLEANUP_DIRS+=("$build_dir")

    printf '  ▶ 拉取 %s 仓库...\n' "$repo"
    if ! git clone --depth=1 "https://aur.archlinux.org/$repo.git" "$build_dir"; then
        printf '✘ 拉取 %s 失败\n' "$repo" >&2
        rm -rf -- "$build_dir"
        return 1
    fi

    local build_err=0
    (
        cd "$build_dir" || exit 1
        local -a build_options=()
        local tmp_conf="" result=0
        trap '[[ -z "${tmp_conf:-}" ]] || rm -f -- "$tmp_conf"' EXIT
        if [[ "$compile_profile" == "low-memory" ]]; then
            export MAKEFLAGS="-j1"
            export CARGO_BUILD_JOBS=1
            export CARGO_PROFILE_RELEASE_LTO=off
            tmp_conf=$(mktemp) || exit 1
            cat > "$tmp_conf" <<'EOF' || exit 1
source /etc/makepkg.conf
if [[ -d /etc/makepkg.conf.d ]]; then
    for _dropin in /etc/makepkg.conf.d/*.conf; do
        if [[ -r "$_dropin" ]]; then
            source "$_dropin"
        fi
    done
    unset _dropin
fi
MAKEFLAGS="-j1"
OPTIONS+=(!lto !debug)
EOF
            build_options+=(--config "$tmp_conf")
            printf '  ○ 低内存：-j1，CARGO_BUILD_JOBS=1，!lto !debug，CARGO_PROFILE_RELEASE_LTO=off（单线程编译耗时较长，末尾安装可能需要再次确认 sudo）\n'
        else
            printf '  ▶ makepkg %s\n' "$([[ "$repo" == "paru-bin" ]] && echo "安装预编译" || echo "默认编译")"
        fi
        makepkg "${build_options[@]}" -sri --noconfirm || result=$?
        exit "$result"
    ) || build_err=1

    rm -rf -- "$build_dir"
    if [[ $build_err -ne 0 ]]; then
        printf '✘ paru 安装失败，请检查构建、依赖清理或安装日志。\n' >&2
        return 1
    fi
}

read_paru_host_metrics() {
    local meminfo_file="${1:-/proc/meminfo}"
    local swaps_file="${2:-/proc/swaps}"
    local mem_metrics swap_metrics
    local mem_total_mib=0 mem_available_mib=0
    mem_metrics=$(
        awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%.0f %.0f", (t+0)/1024, (a+0)/1024}' "$meminfo_file"
    ) || return 1
    read -r mem_total_mib mem_available_mib <<< "$mem_metrics" || return 1

    local disk_swap_free_mib=0 zram_swap_free_mib=0 has_active_swap=0
    if [[ -r "$swaps_file" ]]; then
        swap_metrics=$(
            awk '
                NR > 1 && NF >= 4 {
                    active = 1
                    free_k = ($3 + 0) - ($4 + 0)
                    if (free_k < 0) free_k = 0
                    if ($1 ~ /^\/dev\/zram[0-9]+$/) zram_k += free_k
                    else disk_k += free_k
                }
                END {
                    printf "%d %.0f %.0f", active + 0, (disk_k + 0) / 1024, (zram_k + 0) / 1024
                }
            ' "$swaps_file"
        ) || return 1
        read -r has_active_swap disk_swap_free_mib zram_swap_free_mib <<< "$swap_metrics" || return 1
    fi

    local kernel_reboot_pending=0
    if ! running_kernel_modules_available; then
        kernel_reboot_pending=1
    fi
    printf '%s %s %s %s %s %s\n' \
        "$mem_total_mib" "$mem_available_mib" "$disk_swap_free_mib" "$zram_swap_free_mib" "$has_active_swap" "$kernel_reboot_pending"
}

select_paru_build_plan() {
    local mem_total_mib="$1" mem_available_mib="$2" disk_swap_free_mib="$3"
    local zram_swap_free_mib="$4" has_active_swap="$5" kernel_reboot_pending="$6"

    # zram 已包含在 SwapFree 对应设备中；仅按压缩后折半保守估算额外有效缓冲，避免双重计数
    local effective_mib=$(( mem_available_mib + disk_swap_free_mib + zram_swap_free_mib / 2 ))
    local repo="paru" compile_profile="default" reason=""

    if (( mem_total_mib <= 1024 )); then
        repo="paru-bin"
        compile_profile="prebuilt"
        reason="物理内存 ≤1024 MiB，限制安装预编译版本 (paru-bin)"
    elif (( mem_total_mib <= 2048 && has_active_swap == 0 )); then
        repo="paru-bin"
        compile_profile="prebuilt"
        if (( kernel_reboot_pending )); then
            reason="检测到内核已升级且当前无活动 Swap，1–2 GiB 内存限制为安装预编译版本 (paru-bin)"
        else
            reason="当前无活动 Swap，1–2 GiB 内存限制为安装预编译版本 (paru-bin)"
        fi
    elif (( effective_mib < 1800 )); then
        repo="paru-bin"
        compile_profile="prebuilt"
        reason="可用有效缓冲 ${effective_mib} MiB < 1800 MiB，限制安装预编译版本 (paru-bin)"
    elif (( mem_total_mib <= 2048 || effective_mib < 3584 )); then
        repo="paru"
        compile_profile="low-memory"
        if (( mem_total_mib <= 2048 )); then
            reason="≤2048 MiB 物理内存：限制内存源码编译"
        else
            reason="可用有效缓冲 ${effective_mib} MiB < 3584 MiB：自动降级为限制内存源码编译"
        fi
    else
        repo="paru"
        compile_profile="default"
        reason=">2048 MiB 且有效缓冲充足：默认源码编译"
    fi

    printf '%s|%s|%s|%s\n' "$repo" "$compile_profile" "$effective_mib" "$reason"
}

setup_paru() {
    local action="从 AUR 构建安装"
    command -v paru >/dev/null 2>&1 && action="覆盖重新构建"
    printf '▶ [%s] paru (AUR 助手)...\n' "$action"

    local -a build_deps=(base-devel)
    command -v git >/dev/null 2>&1 || build_deps+=(git)
    printf '  ▶ 安装 AUR 构建基础依赖 (%s)...\n' "${build_deps[*]}"
    sudo pacman -S --needed --noconfirm "${build_deps[@]}" || return 1

    local mem_total_mib mem_available_mib disk_swap_free_mib zram_swap_free_mib has_active_swap kernel_reboot_pending
    read -r mem_total_mib mem_available_mib disk_swap_free_mib zram_swap_free_mib has_active_swap kernel_reboot_pending <<< "$(read_paru_host_metrics)" || return 1

    local repo compile_profile effective_mib reason
    IFS='|' read -r repo compile_profile effective_mib reason <<< "$(
        select_paru_build_plan "$mem_total_mib" "$mem_available_mib" "$disk_swap_free_mib" "$zram_swap_free_mib" "$has_active_swap" "$kernel_reboot_pending"
    )"

    printf '  ○ 物理内存 %d MiB（可用 %d MiB），磁盘 Swap 空闲 %d MiB，zram 空闲 %d MiB，有效缓冲 %d MiB\n' \
        "$mem_total_mib" "$mem_available_mib" "$disk_swap_free_mib" "$zram_swap_free_mib" "$effective_mib"
    if [[ "$repo" == "paru-bin" && "$mem_total_mib" -gt 1024 ]]; then
        printf '  ▲ %s\n' "$reason"
    else
        printf '  ○ %s\n' "$reason"
    fi

    paru_build_and_install "$repo" "$compile_profile" || return 1

    local paru_ver=""
    IFS= read -r paru_ver < <(paru --version) || true
    printf '  ✔ paru 已就绪: %s\n' "$paru_ver"
}

validate_fnm_env() {
    if [[ -n "${XDG_DATA_HOME+x}" && -z "$XDG_DATA_HOME" ]]; then
        printf '✘ XDG_DATA_HOME 已设置为空值，会导致 systemd environment.d 展开异常，请取消设置或设为有效目录\n' >&2
        return 1
    fi
    local xdg_data_home xdg_data_parent expected_fnm_dir
    xdg_data_home=$(normalize_dir_path "${XDG_DATA_HOME:-$HOME/.local/share}")
    xdg_data_parent=$(parent_dir_of "$xdg_data_home")
    expected_fnm_dir="${xdg_data_home%/}/fnm"
    if [[ -n "${FNM_DIR:-}" ]]; then
        local normalized_fnm_dir
        normalized_fnm_dir=$(normalize_dir_path "$FNM_DIR")
        [[ "$normalized_fnm_dir" == "$expected_fnm_dir" ]] || {
            printf '✘ 自定义 FNM_DIR (%s) 与统一环境路径 (%s) 不一致，请取消 FNM_DIR 后重试\n' "$FNM_DIR" "$expected_fnm_dir" >&2
            return 1
        }
    fi
    validate_dir_chain "$expected_fnm_dir" 1 \
        "$xdg_data_parent" "XDG_DATA_HOME 父" \
        "$xdg_data_home" "XDG_DATA_HOME " \
        "$expected_fnm_dir" "FNM "
}

setup_fnm() {
    local action="安装与配置"
    command -v fnm >/dev/null 2>&1 && action="覆盖更新"
    printf '▶ [%s] Node.js 环境 (fnm)...\n' "$action"
    validate_fnm_env || return 1
    local rc_content fnm_env node_version
    sudo pacman -S --needed --noconfirm fnm || return $?
    fnm_env=$(fnm env --shell bash) || return $?
    eval "$fnm_env" || return $?
    fnm install --lts || return $?
    fnm default lts-latest || return $?
    fnm use lts-latest || return $?
    node_version=$(node --version) || return $?
    apply_env_path_block "archlinux:fnm" '${XDG_DATA_HOME:-${HOME}/.local/share}/fnm/aliases/default/bin' || return $?
    ensure_bashrc_env_loader || return $?
    rc_content=$(cat <<'EOF'
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd --shell bash)"
fi
EOF
    )
    apply_bashrc_block "archlinux:fnm" "$rc_content" || return $?
    printf '  ✔ Node.js LTS 已就绪: %s (fnm + 非交互 PATH)\n' "$node_version"
}

validate_local_bin_dir() {
    local local_dir local_bin="$HOME/.local/bin"
    local_dir=$(parent_dir_of "$local_bin")
    validate_dir_chain "$local_bin" 1 "$local_dir" "~/.local " "$local_bin" "~/.local/bin "
}

go_expected_paths() {
    local xdg_data_home
    xdg_data_home=$(normalize_dir_path "${XDG_DATA_HOME:-$HOME/.local/share}")
    printf '%s\n%s\n' "${xdg_data_home%/}/go" "$HOME/.local/bin"
}

validate_go_env() {
    local default_cfg go_env_file go_path xdg_data_dir xdg_data_parent
    default_cfg=$(normalize_dir_path "${XDG_CONFIG_HOME:-$HOME/.config}")
    go_env_file="${GOENV:-${default_cfg%/}/go/env}"
    validate_managed_file_and_parents "$go_env_file" "Go 环境文件" "Go 配置目录" "Go 配置根目录" 0 1 || return 1
    IFS= read -r go_path < <(go_expected_paths)
    xdg_data_dir=$(parent_dir_of "$go_path")
    xdg_data_parent=$(parent_dir_of "$xdg_data_dir")
    validate_dir_chain "$go_path" 1 \
        "$xdg_data_parent" "XDG_DATA_HOME 父" \
        "$xdg_data_dir" "XDG_DATA_HOME " \
        "$go_path" "GOPATH "
}

setup_go() {
    local action="安装与配置"
    command -v go >/dev/null 2>&1 && action="覆盖更新"
    printf '▶ [%s] Go 工具链 (pacman)...\n' "$action"
    validate_go_env || return 1
    validate_local_bin_dir || return 1
    sudo pacman -S --needed --noconfirm go || return $?

    local go_path go_bin
    {
        IFS= read -r go_path
        IFS= read -r go_bin
    } < <(go_expected_paths)
    mkdir -p "$go_path" "$go_bin" || return $?

    env -u GOPATH -u GOBIN -u GOTOOLCHAIN go env -w \
        "GOPATH=$go_path" \
        "GOBIN=$go_bin" \
        "GOTOOLCHAIN=local" || return $?

    local go_ver
    IFS= read -r go_ver < <(go version) || return $?
    ensure_local_bin_path || return $?
    ensure_bashrc_env_loader || return $?
    printf '  ✔ Go 已就绪: %s (GOPATH=%s, GOBIN=%s, GOTOOLCHAIN=local)\n' "$go_ver" "$go_path" "$go_bin"
}

setup_uv() {
    local action="安装" ver=""
    command -v uv >/dev/null 2>&1 && action="更新"
    printf '▶ [%s] Python 工具链 (uv)...\n' "$action"
    validate_local_bin_dir || return 1
    sudo pacman -S --needed --noconfirm uv || return $?
    IFS= read -r ver < <(uv --version) || true
    ensure_local_bin_path || return $?
    ensure_bashrc_env_loader || return $?
    printf '  ✔ uv 已就绪: %s (含 ~/.local/bin 非交互 PATH)\n' "$ver"
}

setup_gh() {
    install_simple_cli_tool "GitHub CLI (gh)" "GitHub CLI" gh github-cli
}

# 格式: 编号|菜单标题|状态探测|bashrc块Tag(-无)|env块Tag(-无)|前置依赖ID(逗号分隔,-无)|precheck函数(逗号分隔,-无)|需sudo(0/1)|执行函数
readonly -a OPTIONAL_REGISTRY=(
    "1|Git 版本控制 (git)|cmd:git|-|-|-|-|1|setup_git"
    "2|Shell 体验增强 (历史实时同步/去重、退出码高亮；含 git 时附带分支提示)|shell-enhance|archlinux:shell-enhance|-|-|-|0|setup_shell_enhance"
    "3|Micro 终端编辑器及默认配置 (EDITOR/VISUAL)|envboth:micro:archlinux:editor-micro|-|archlinux:editor-micro|-|validate_micro_conf|1|setup_micro"
    "4|paru (AUR 助手，按内存与 Swap 自动选择构建模式)|cmd:paru|-|-|1|-|1|setup_paru"
    "5|Node.js LTS 环境 (fnm + 非交互 PATH)|fnm|archlinux:fnm|archlinux:fnm|-|validate_fnm_env|1|setup_fnm"
    "6|Go 工具链 (pacman go + XDG 路径 + GOTOOLCHAIN=local)|go|-|archlinux:local-bin|1|validate_go_env,validate_local_bin_dir|1|setup_go"
    "7|Python 极速工具链 (uv + ~/.local/bin)|envboth:uv:archlinux:local-bin|-|archlinux:local-bin|-|validate_local_bin_dir|1|setup_uv"
    "8|GitHub CLI 官方客户端 (gh)|cmd:gh|-|-|-|-|1|setup_gh"
)

parse_optional_selection() {
    local raw="${1//,/ }"
    local max_id=${#OPTIONAL_REGISTRY[@]}
    local -a tokens=() selected=()
    local token start end i lower
    for (( i = 0; i <= max_id; i++ )); do selected[i]=0; done

    read -ra tokens <<< "$raw" || true
    (( ${#tokens[@]} > 0 )) || return 0

    if (( ${#tokens[@]} == 1 )); then
        lower="${tokens[0],,}"
        case "$lower" in
            q|quit|exit) return 0 ;;
        esac
    fi

    for token in "${tokens[@]}"; do
        lower="${token,,}"
        if [[ "$lower" =~ ^[0-9]+$ ]] && (( 10#$lower >= 1 && 10#$lower <= max_id )); then
            selected[10#$lower]=1
        elif [[ "$lower" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=$(( 10#${BASH_REMATCH[1]} ))
            end=$(( 10#${BASH_REMATCH[2]} ))
            if (( start < 1 || end > max_id || start > end )); then
                printf '✘ 无效选项范围: %s（起止须满足 1-%d 且前小后大）\n' "$token" "$max_id" >&2
                return 1
            fi
            for (( i = start; i <= end; i++ )); do
                selected[i]=1
            done
        elif [[ "$lower" == "all" ]]; then
            for (( i = 1; i <= max_id; i++ )); do selected[i]=1; done
        else
            printf '✘ 无效选项: %s（支持 1-%d、范围如 1-4、all 或 q 退出）\n' "$token" "$max_id" >&2
            return 1
        fi
    done

    local -a out=()
    for (( i = 1; i <= max_id; i++ )); do
        if (( selected[i] )); then
            out+=("$i")
        fi
    done
    printf '%s\n' "${out[*]}"
}

resolve_optional_dependencies() {
    local initial_list="${1:-}"
    local max_id=${#OPTIONAL_REGISTRY[@]}
    local -a reg_deps=() selected=() out=()
    local entry id _ deps_spec i changed dep_id
    for (( i = 0; i <= max_id; i++ )); do
        reg_deps[i]="-"
        selected[i]=0
    done
    for entry in "${OPTIONAL_REGISTRY[@]}"; do
        IFS='|' read -r id _ _ _ _ deps_spec _ <<< "$entry"
        reg_deps[id]="$deps_spec"
    done

    for id in $initial_list; do
        selected[id]=1
    done

    changed=1
    while (( changed )); do
        changed=0
        for (( i = 1; i <= max_id; i++ )); do
            (( selected[i] )) || continue
            [[ "${reg_deps[i]}" != "-" ]] || continue
            IFS=',' read -ra _dep_arr <<< "${reg_deps[i]}"
            for dep_id in "${_dep_arr[@]}"; do
                [[ -n "$dep_id" ]] || continue
                if (( ! selected[dep_id] )); then
                    selected[dep_id]=1
                    changed=1
                fi
            done
        done
    done

    for (( i = 1; i <= max_id; i++ )); do
        if (( selected[i] )); then
            out+=("$i")
        fi
    done
    printf '%s\n' "${out[*]}"
}

go_env_is_configured() {
    local gopath="" gobin="" toolchain="" expected_gopath="" expected_gobin=""
    {
        IFS= read -r expected_gopath
        IFS= read -r expected_gobin
    } < <(go_expected_paths)
    {
        IFS= read -r gopath
        IFS= read -r gobin
        IFS= read -r toolchain
    } < <(env -u GOPATH -u GOBIN -u GOTOOLCHAIN go env GOPATH GOBIN GOTOOLCHAIN 2>/dev/null) || return 1
    [[ "$gopath" == "$expected_gopath" && "$gobin" == "$expected_gobin" && "$toolchain" == "local" ]]
}

optional_status_tag() {
    local spec="$1" cmd tag
    case "$spec" in
        shell-enhance)
            if ! has_managed_block "$BASHRC" "archlinux:shell-enhance"; then
                printf '[未配置]'
            elif command -v git >/dev/null 2>&1 && ! managed_block_contains "$BASHRC" "archlinux:shell-enhance" "__git_info"; then
                printf '[缺分支提示]'
            else
                printf '[已配置]'
            fi
            ;;
        cmd:*)
            command -v "${spec#cmd:}" >/dev/null 2>&1 && printf '[已安装]' || printf '[未安装]'
            ;;
        envboth:*)
            spec="${spec#envboth:}"
            cmd="${spec%%:*}"
            tag="${spec#*:}"
            if ! command -v "$cmd" >/dev/null 2>&1; then
                printf '[未安装]'
            elif has_managed_block "$ENV_CONF" "$tag" && has_managed_block "$BASHRC" "archlinux:env"; then
                printf '[已就绪]'
            else
                printf '[缺配置]'
            fi
            ;;
        fnm)
            local xdg_data_home fnm_default_node
            xdg_data_home=$(normalize_dir_path "${XDG_DATA_HOME:-$HOME/.local/share}")
            fnm_default_node="${FNM_DIR:-${xdg_data_home%/}/fnm}/aliases/default/bin/node"
            if ! command -v fnm >/dev/null 2>&1; then
                printf '[未安装]'
            elif has_managed_block "$BASHRC" "archlinux:fnm" &&
                 has_managed_block "$ENV_CONF" "archlinux:fnm" &&
                 has_managed_block "$BASHRC" "archlinux:env" &&
                 [[ -x "$fnm_default_node" ]]; then
                printf '[已就绪]'
            else
                printf '[缺配置]'
            fi
            ;;
        go)
            if ! command -v go >/dev/null 2>&1; then
                printf '[未安装]'
            elif has_managed_block "$ENV_CONF" "archlinux:local-bin" && has_managed_block "$BASHRC" "archlinux:env" && go_env_is_configured; then
                printf '[已就绪]'
            else
                printf '[缺配置]'
            fi
            ;;
    esac
}

print_optional_items() {
    local entry id label status_spec _
    for entry in "${OPTIONAL_REGISTRY[@]}"; do
        IFS='|' read -r id label status_spec _ <<< "$entry"
        printf '  %s) %s %s\n' "$id" "$(optional_status_tag "$status_spec")" "$label"
    done
}

print_reload_hint() {
    local mode="${1:-final}"
    (( BASHRC_CHANGED || ENV_CHANGED )) || return 0
    local extra=""
    if (( ENV_CHANGED )); then
        extra='（systemd --user 服务需重新登录后生效）'
    fi
    if [[ "$mode" == "partial" ]]; then
        printf '  → 前序步骤已更新 Shell/环境配置，可执行 exec bash -i 重载当前终端%s。\n' "$extra" >&2
    else
        printf '\n→ 执行 exec bash -i 重载当前终端即可生效%s。\n' "$extra"
    fi
}

print_reboot_reload_hint() {
    local mode="${1:-partial}"
    (( BASHRC_CHANGED || ENV_CHANGED )) || return 0
    if [[ "$mode" == "partial" ]]; then
        printf '  → 前序步骤已更新 Shell/环境配置，且内核已升级，请先执行 sudo reboot 重启后一并生效。\n' >&2
    else
        printf '\n→ Shell/环境配置已更新，且内核已升级，请先执行 sudo reboot 重启后一并生效。\n'
    fi
}

open_interactive_tty() {
    local fd_var="$1" close_var="$2" err_msg="${3:-未检测到交互终端，请在交互式终端（如 SSH）中执行}"
    local -n _fd_ref="$fd_var" _close_ref="$close_var"
    _fd_ref=""
    _close_ref=0
    if { exec {_fd_ref}</dev/tty; } 2>/dev/null; then
        _close_ref=1
    elif [[ -t 0 ]]; then
        _fd_ref=0
    else
        printf '✘ %s\n' "$err_msg" >&2
        return 1
    fi
}

close_interactive_tty() {
    local fd="$1" close_flag="$2"
    (( close_flag )) && exec {fd}<&- || true
}

require_interactive_tty() {
    local tty_fd="" close_tty=0
    open_interactive_tty tty_fd close_tty "未检测到交互终端，请在交互式终端（如 SSH）中执行" || return 1
    close_interactive_tty "$tty_fd" "$close_tty"
}

run_optional_menu() {
    local tty_fd="" close_tty=0
    open_interactive_tty tty_fd close_tty "未检测到交互终端，停止可选扩展与工具链选配" || return 1

    printf '\n======================================================\n'
    printf '       可选扩展与工具链选配 (回车默认跳过)\n'
    printf '  已存在配置将受控原位替换，未选项目保持原有状态。\n'
    printf '======================================================\n\n'
    if ! running_kernel_modules_available; then
        printf '  ▲ 提示：内核已升级，zram 与新内核模块将于 reboot 后激活；\n'
        printf '          1–2 GiB 机器若此刻选装 paru 将自动限制为预编译版本 (paru-bin)。\n\n'
    fi

    print_optional_items
    printf '\n------------------------------------------------------\n'
    printf '  提示: 输入编号 (1 3 6)、范围 (1-4)、all 全选，直接回车或 q 跳过\n'

    local raw_choice="" parsed_choice="" resolved_choice=""
    while true; do
        if ! read -r -u "$tty_fd" -p "请选择 [1-${#OPTIONAL_REGISTRY[@]} / 1-4 / all / 回车跳过]: " raw_choice; then
            close_interactive_tty "$tty_fd" "$close_tty"
            printf '\n✘ 未读取到有效的选配输入，停止执行\n' >&2
            return 1
        fi
        if parsed_choice=$(parse_optional_selection "$raw_choice"); then
            break
        fi
    done
    close_interactive_tty "$tty_fd" "$close_tty"

    if [[ -z "$parsed_choice" ]]; then
        printf '  ○ 已跳过可选扩展与工具链选配。\n'
        return 0
    fi

    resolved_choice=$(resolve_optional_dependencies "$parsed_choice")

    local -a reg_label=() reg_rc_tag=() reg_env_tag=() reg_prechecks=() reg_sudo=() reg_handler=()
    local entry id label status_spec rc_tag env_tag deps_spec prechecks_spec need_sudo handler
    for entry in "${OPTIONAL_REGISTRY[@]}"; do
        IFS='|' read -r id label status_spec rc_tag env_tag deps_spec prechecks_spec need_sudo handler <<< "$entry"
        reg_label[id]="$label"
        reg_rc_tag[id]="$rc_tag"
        reg_env_tag[id]="$env_tag"
        reg_prechecks[id]="$prechecks_spec"
        reg_sudo[id]="$need_sudo"
        reg_handler[id]="$handler"
    done

    local -a initial_items=() selected_items=() completed_items=() auto_bound_labels=()
    read -ra initial_items <<< "$parsed_choice"
    read -ra selected_items <<< "$resolved_choice"

    local -A explicit_map=()
    local item
    for item in "${initial_items[@]}"; do
        explicit_map["$item"]=1
    done
    for item in "${selected_items[@]}"; do
        if [[ -z "${explicit_map[$item]:-}" ]]; then
            auto_bound_labels+=("${item})${reg_label[item]}")
        fi
    done
    if (( ${#auto_bound_labels[@]} > 0 )); then
        printf '  → 已自动绑定前置依赖项: %s\n' "${auto_bound_labels[*]}"
    fi

    local require_sudo=0 need_env_loader=0 precheck_fn
    local -A seen_rc_tags=() seen_env_tags=() seen_prechecks=()
    for item in "${selected_items[@]}"; do
        if [[ "${reg_rc_tag[item]}" != "-" && -z "${seen_rc_tags[${reg_rc_tag[item]}]:-}" ]]; then
            validate_bashrc_block "${reg_rc_tag[item]}" || return 1
            seen_rc_tags["${reg_rc_tag[item]}"]=1
        fi
        if [[ "${reg_env_tag[item]}" != "-" ]]; then
            if [[ -z "${seen_env_tags[${reg_env_tag[item]}]:-}" ]]; then
                validate_env_block "${reg_env_tag[item]}" || return 1
                seen_env_tags["${reg_env_tag[item]}"]=1
            fi
            need_env_loader=1
        fi
        if [[ "${reg_prechecks[item]}" != "-" ]]; then
            IFS=',' read -ra _pc_arr <<< "${reg_prechecks[item]}"
            for precheck_fn in "${_pc_arr[@]}"; do
                [[ -n "$precheck_fn" && -z "${seen_prechecks[$precheck_fn]:-}" ]] || continue
                "$precheck_fn" || return 1
                seen_prechecks["$precheck_fn"]=1
            done
        fi
        if (( reg_sudo[item] )); then
            require_sudo=1
        fi
    done
    local env_rc_tag="archlinux:env"
    if (( need_env_loader )) && [[ -z "${seen_rc_tags[$env_rc_tag]:-}" ]]; then
        validate_bashrc_block "$env_rc_tag" || return 1
    fi

    if (( require_sudo )); then
        sudo -v || {
            printf '✘ sudo 提权验证失败\n' >&2
            return 1
        }
    fi

    local total=${#selected_items[@]} idx=0 step_rc=0
    printf '\n▶ 已选择 (%d 项):' "$total"
    for item in "${selected_items[@]}"; do
        printf ' %s)%s' "$item" "${reg_label[item]}"
    done
    printf '\n'

    for item in "${selected_items[@]}"; do
        idx=$(( idx + 1 ))
        printf '\n--- [%d/%d] %s ---\n' "$idx" "$total" "${reg_label[item]}"
        step_rc=0
        "${reg_handler[item]}" || step_rc=$?
        if (( step_rc != 0 )); then
            printf '✘ 第 %d/%d 项失败: %s) %s\n' "$idx" "$total" "$item" "${reg_label[item]}" >&2
            if (( ${#completed_items[@]} > 0 )); then
                printf '  ○ 此前已完成项: %s\n' "${completed_items[*]}" >&2
            fi
            if running_kernel_modules_available; then
                print_reload_hint partial
            else
                print_reboot_reload_hint partial
            fi
            OPTIONAL_FAILURE_HINT_SHOWN=1
            return "$step_rc"
        fi
        completed_items+=("${item})${reg_label[item]}")
    done

    printf '\n✔ 所选 %d 项扩展与工具链全部处理完成。\n' "$total"
}

# ========================================================
# 主入口
# ========================================================

main() {
    if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--help" ]]; }; then
        printf '✘ 不支持的参数: %s\n' "$*" >&2
        printf '用法: %s [--help]\n' "$0" >&2
        return 2
    fi
    case "${1:-}" in
        "")
            validate_arch_host || return 1
            require_interactive_tty || return 1
            local rc=0
            run_host_init || rc=$?
            if (( rc != 0 )); then
                if (( ! OPTIONAL_FAILURE_HINT_SHOWN )); then
                    if running_kernel_modules_available; then
                        print_reload_hint partial
                    else
                        print_reboot_reload_hint partial
                    fi
                fi
                return "$rc"
            fi
            if running_kernel_modules_available; then
                print_reload_hint final
            fi
            ;;
        --help)
            printf '用法: %s [--help]\n' "$0"
            printf '执行 Arch Linux 基础环境初始化与可选工具链选配。\n'
            ;;
    esac
}

main "$@"
