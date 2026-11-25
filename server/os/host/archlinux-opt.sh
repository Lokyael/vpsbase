#!/usr/bin/env bash
#
# server/os/host/archlinux-opt.sh
# Arch Linux Shell 增强与工具链选配脚本
#

set -Eeuo pipefail

# ========================================================
# 1. 全局状态、临时资源生命周期与宿主环境门禁
# ========================================================

BASHRC="$HOME/.bashrc"
BASHRC_CHANGED=0
declare -a _OPT_CLEANUP_DIRS=()

cleanup_opt_temp() {
    (( ${#_OPT_CLEANUP_DIRS[@]} == 0 )) || rm -rf -- "${_OPT_CLEANUP_DIRS[@]}"
}
trap cleanup_opt_temp EXIT
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
}

# ========================================================
# 2. 受控分界标记块与历史清洗底层 (与 archlinux-init.sh 对齐)
# ========================================================

validate_bashrc() {
    [[ ! -L "$BASHRC" ]] || { printf '✘ ~/.bashrc 是符号链接，停止\n' >&2; return 1; }
    [[ ! -e "$BASHRC" || ( -f "$BASHRC" && -r "$BASHRC" && -w "$BASHRC" ) ]] || { printf '✘ ~/.bashrc 无法读写，停止\n' >&2; return 1; }
    [[ ! -e "$BASHRC" ]] || bash -n "$BASHRC" || { printf '✘ 已有 ~/.bashrc 语法异常，停止\n' >&2; return 1; }
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
        printf '✘ %s 受控块语法校验失败，请检查配置\n' "$target_file" >&2
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

has_managed_block() {
    local target_file="$1"
    local tag="$2"
    local begin_mark="# >>> managed:${tag} >>>"
    local end_mark="# <<< managed:${tag} <<<"

    [[ -f "$target_file" ]] && grep -Fxq "$begin_mark" "$target_file" && grep -Fxq "$end_mark" "$target_file"
}

apply_bashrc_block() {
    local tag="$1" content="$2"
    local before_sig="" after_sig=""
    if [[ -e "$BASHRC" ]]; then
        before_sig=$(cksum -- "$BASHRC" 2>/dev/null || true)
    fi
    upsert_managed_block "$BASHRC" "$tag" "$content" || return 1
    if [[ -e "$BASHRC" ]]; then
        after_sig=$(cksum -- "$BASHRC" 2>/dev/null || true)
    fi
    if [[ "$before_sig" != "$after_sig" ]]; then
        BASHRC_CHANGED=1
    fi
}

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
# 3. Shell 体验增强选配 (1-4)
# ========================================================

install_bashrc_opt() {
    local tag="$1" title="$2" done_msg="$3"
    local action="配置" content
    has_managed_block "$BASHRC" "$tag" && action="覆盖更新"
    printf '▶ [%s] %s...\n' "$action" "$title"
    content=$(cat) || return $?
    apply_bashrc_block "$tag" "$content" || return $?
    printf '  ✔ %s\n' "$done_msg"
}

opt_sync_history() {
    install_bashrc_opt "archlinux:sync-history" "多终端历史实时同步" "多终端历史实时同步已生效" <<'EOF'
shopt -s histappend
__sync_history() {
    local saved_status=$?
    history -a
    history -n
    return "$saved_status"
}
if [[ " ${PROMPT_COMMAND[*]-} " != *" __sync_history "* ]]; then
    PROMPT_COMMAND=(__sync_history ${PROMPT_COMMAND[@]+"${PROMPT_COMMAND[@]}"})
fi
EOF
}

opt_git_prompt() {
    install_bashrc_opt "archlinux:git-prompt" "Git 分支状态提示符" "Git 分支状态提示符已生效" <<'EOF'
__git_info() {
    command -v git >/dev/null 2>&1 || return
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return
    [[ -n "$branch" ]] || return
    if git status --porcelain -uno --ignore-submodules 2>/dev/null | command grep -q .; then
        printf ' (%s*)' "$branch"
    else
        printf ' (%s)' "$branch"
    fi
}
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    PS1='\[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\[\e[01;33m\]$(__git_info)\[\e[00m\]\$ '
else
    PS1='[\u@\h \W]$(__git_info)\$ '
fi
if declare -F __exit_status >/dev/null 2>&1 && [[ "$PS1" != *'$(__exit_status)'* ]]; then
    PS1='$(__exit_status)'"$PS1"
fi
EOF
}

opt_exit_status() {
    install_bashrc_opt "archlinux:exit-status" "非零退出码错误高亮" "非零退出码错误高亮已生效" <<'EOF'
__exit_status_color=0
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    __exit_status_color=1
fi
__exit_status() {
    local status=$?
    if (( status != 0 )); then
        if (( __exit_status_color )); then
            printf '\001\e[01;31m\002[%s]\001\e[00m\002 ' "$status"
        else
            printf '[%s] ' "$status"
        fi
    fi
}
if [[ "$PS1" != *'$(__exit_status)'* ]]; then
    PS1='$(__exit_status)'"$PS1"
fi
EOF
}

opt_dedup_history() {
    local action="配置"
    has_managed_block "$BASHRC" "archlinux:dedup-history" && action="覆盖更新"
    printf '▶ [%s] 历史记录去重函数 (dedup-history)...\n' "$action"

    # 首次注入前规范化历史时间戳格式，防止去重校验因裸行失败
    normalize_history || return $?
    local content
    content=$(cat <<'EOF'
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
EOF
    )
    apply_bashrc_block "archlinux:dedup-history" "$content" || return $?
    printf '  ✔ 历史去重函数已注入，可通过 dedup-history 手动调用\n'
}

# ========================================================
# 4. 常用工具链选配 (5-9)
# ========================================================

install_simple_cli_tool() {
    local label="$1" done_name="$2" cmd="$3" pkg="$4"
    local action="安装" ver=""
    command -v "$cmd" >/dev/null 2>&1 && action="更新"
    printf '▶ [%s] %s...\n' "$action" "$label"
    sudo pacman -S --needed --noconfirm "$pkg" || return $?
    IFS= read -r ver < <("$cmd" --version) || true
    printf '  ✔ %s 已就绪: %s\n' "$done_name" "$ver"
}

opt_micro() {
    local action="安装与配置"
    command -v micro >/dev/null 2>&1 && action="覆盖更新"
    printf '▶ [%s] Micro 终端编辑器...\n' "$action"
    sudo pacman -S --needed --noconfirm micro || return $?
    mkdir -p "$HOME/.config/micro" || return $?
    local micro_conf="$HOME/.config/micro/settings.json"
    if [[ ! -e "$micro_conf" && ! -L "$micro_conf" ]]; then
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
        printf '  ○ 已存在 ~/.config/micro/settings.json，保留原配置\n'
    fi
    local content
    content=$(cat <<'EOF'
export EDITOR=micro
export VISUAL=micro
EOF
    )
    apply_bashrc_block "archlinux:editor-micro" "$content" || return $?
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
    _OPT_CLEANUP_DIRS+=("$build_dir")

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
            printf '  ○ 低内存：-j1，CARGO_BUILD_JOBS=1，!lto !debug，CARGO_LTO=off\n'
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

opt_paru() {
    local action="从 AUR 构建安装"
    command -v paru >/dev/null 2>&1 && action="覆盖重新构建"
    printf '▶ [%s] paru (AUR 助手)...\n' "$action"

    printf '  ▶ 安装构建依赖 (git, base-devel)...\n'
    sudo pacman -S --needed --noconfirm git base-devel || return 1

    local mem_total_mib mem_available_mib swap_free_mib zram_total_mib=0 avail_mib
    read -r mem_total_mib mem_available_mib swap_free_mib <<< "$(
        awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} /SwapFree/ {s=$2} END {printf "%.0f %.0f %.0f", (t+0)/1024, (a+0)/1024, (s+0)/1024}' /proc/meminfo
    )" || return 1
    if compgen -G '/sys/block/zram*/disksize' >/dev/null; then
        zram_total_mib=$(awk '{s+=$1} END {printf "%.0f", s/1024/1024}' /sys/block/zram*/disksize 2>/dev/null) || zram_total_mib=0
    fi
    # zram 按 disksize 一半保守估算可利用量
    avail_mib=$(( mem_available_mib + swap_free_mib + zram_total_mib / 2 ))

    printf '  ○ 物理内存 %d MiB（可用 %d MiB），swap 空闲 %d MiB，zram %d MiB\n' \
        "$mem_total_mib" "$mem_available_mib" "$swap_free_mib" "$zram_total_mib"
    printf '  ○ 可用缓冲合计 %d MiB\n' "$avail_mib"

    local repo="paru" compile_profile="default"
    if (( mem_total_mib <= 1024 )); then
        repo="paru-bin"
        printf '  ○ ≤1024 MiB：预编译 (paru-bin)\n'
    elif (( mem_total_mib <= 2048 )); then
        compile_profile="low-memory"
        printf '  ○ ≤2048 MiB：限制内存编译\n'
        if (( avail_mib < 1536 )); then
            printf '  ▲ 可用缓冲 %d MiB < 1536 MiB，编译可能失败\n' "$avail_mib" >&2
        fi
    else
        printf '  ○ >2048 MiB：默认编译\n'
        if (( avail_mib < 3584 )); then
            printf '  ▲ 可用缓冲 %d MiB < 3584 MiB，有 OOM 风险\n' "$avail_mib" >&2
        fi
    fi

    paru_build_and_install "$repo" "$compile_profile" || return 1

    local paru_ver=""
    IFS= read -r paru_ver < <(paru --version) || true
    printf '  ✔ paru 已就绪: %s\n' "$paru_ver"
}

opt_fnm() {
    local action="安装与配置"
    command -v fnm >/dev/null 2>&1 && action="覆盖更新"
    printf '▶ [%s] Node.js 环境 (fnm)...\n' "$action"
    local content fnm_env node_version
    sudo pacman -S --needed --noconfirm fnm || return $?
    fnm_env=$(fnm env --shell bash) || return $?
    eval "$fnm_env" || return $?
    fnm install --lts || return $?
    fnm default lts-latest || return $?
    fnm use lts-latest || return $?
    node_version=$(node --version) || return $?
    content=$(cat <<'EOF'
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd --shell bash)"
fi
EOF
    )
    apply_bashrc_block "archlinux:fnm" "$content" || return $?
    printf '  ✔ Node.js LTS 已就绪: %s (fnm)\n' "$node_version"
}

opt_uv() {
    install_simple_cli_tool "Python 工具链 (uv)" "uv" uv uv
}

opt_gh() {
    install_simple_cli_tool "GitHub CLI (gh)" "GitHub CLI" gh github-cli
}

# ========================================================
# 5. 选配项注册表、交互向导与主入口
# ========================================================

# 格式: 编号|分组|菜单标题|状态探测(block:tag / cmd:bin / both:bin:tag)|受控块Tag(-表示无)|需sudo(0/1)|执行函数
readonly -a OPT_REGISTRY=(
    "1|shell|多终端历史实时同步|block:archlinux:sync-history|archlinux:sync-history|0|opt_sync_history"
    "2|shell|Git 分支与变更状态提示符|block:archlinux:git-prompt|archlinux:git-prompt|0|opt_git_prompt"
    "3|shell|非零退出码错误高亮|block:archlinux:exit-status|archlinux:exit-status|0|opt_exit_status"
    "4|shell|历史记录去重命令 (dedup-history)|block:archlinux:dedup-history|archlinux:dedup-history|0|opt_dedup_history"
    "5|tool|Micro 终端编辑器及标准配置|both:micro:archlinux:editor-micro|archlinux:editor-micro|1|opt_micro"
    "6|tool|paru (AUR 助手，按内存自动选择构建模式)|cmd:paru|-|1|opt_paru"
    "7|tool|Node.js LTS 环境 (fnm 管理器)|both:fnm:archlinux:fnm|archlinux:fnm|1|opt_fnm"
    "8|tool|Python 极速工具链 (uv)|cmd:uv|-|1|opt_uv"
    "9|tool|GitHub CLI 官方客户端 (gh)|cmd:gh|-|1|opt_gh"
)

parse_opt_selection() {
    local raw="${1//,/ }"
    local -a tokens=() selected=(0 0 0 0 0 0 0 0 0 0)
    local token start end i lower
    read -ra tokens <<< "$raw" || true
    (( ${#tokens[@]} > 0 )) || return 0

    if (( ${#tokens[@]} == 1 )); then
        lower="${tokens[0],,}"
        case "$lower" in
            q|quit|exit) return 0 ;;
            all)
                printf '1 2 3 4 5 6 7 8 9\n'
                return 0
                ;;
        esac
    fi

    for token in "${tokens[@]}"; do
        lower="${token,,}"
        case "$lower" in
            [1-9])
                selected[lower]=1
                ;;
            [1-9]-[1-9])
                start="${lower%-*}"
                end="${lower#*-}"
                if (( start > end )); then
                    printf '✘ 无效选项范围: %s（起止须满足 1-9 且前小后大）\n' "$token" >&2
                    return 1
                fi
                for (( i = start; i <= end; i++ )); do
                    selected[i]=1
                done
                ;;
            shell)
                for i in 1 2 3 4; do selected[i]=1; done
                ;;
            tools)
                for i in 5 6 7 8 9; do selected[i]=1; done
                ;;
            all)
                for (( i = 1; i <= 9; i++ )); do selected[i]=1; done
                ;;
            *)
                printf '✘ 无效选项: %s（支持 1-9、范围如 1-4、shell、tools、all 或 q 退出）\n' "$token" >&2
                return 1
                ;;
        esac
    done

    local -a out=()
    for (( i = 1; i <= 9; i++ )); do
        if (( selected[i] )); then
            out+=("$i")
        fi
    done
    printf '%s\n' "${out[*]}"
}

opt_status_tag() {
    local spec="$1" cmd tag
    case "$spec" in
        block:*)
            has_managed_block "$BASHRC" "${spec#block:}" && printf '[已配置]' || printf '[未配置]'
            ;;
        cmd:*)
            command -v "${spec#cmd:}" >/dev/null 2>&1 && printf '[已安装]' || printf '[未安装]'
            ;;
        both:*)
            spec="${spec#both:}"
            cmd="${spec%%:*}"
            tag="${spec#*:}"
            if ! command -v "$cmd" >/dev/null 2>&1; then
                printf '[未安装]'
            elif has_managed_block "$BASHRC" "$tag"; then
                printf '[已就绪]'
            else
                printf '[缺配置]'
            fi
            ;;
    esac
}

print_opt_group() {
    local target_group="$1" heading="$2"
    local entry id group label status_spec _
    printf '%s\n' "$heading"
    for entry in "${OPT_REGISTRY[@]}"; do
        IFS='|' read -r id group label status_spec _ <<< "$entry"
        [[ "$group" == "$target_group" ]] || continue
        printf '  %s) %s %s\n' "$id" "$(opt_status_tag "$status_spec")" "$label"
    done
}

run_opt_menu() {
    printf '\n======================================================\n'
    printf '       Arch Linux 可选扩展与工具链配置向导\n'
    printf '  已存在配置将受控原位替换，未选项目保持原有状态。\n'
    printf '======================================================\n\n'

    print_opt_group "shell" "【Shell 体验增强】"
    printf '\n'
    print_opt_group "tool" "【常用工具链与软件源】"
    printf '\n------------------------------------------------------\n'
    printf '  提示: 可输入编号 (1 2 5)、范围 (1-4)、分组 (shell / tools)、all 全选，回车或 q 退出\n'

    local raw_choice="" parsed_choice="" tty_fd="" close_tty=0
    if { exec {tty_fd}</dev/tty; } 2>/dev/null; then
        close_tty=1
    elif [[ -t 0 ]]; then
        tty_fd=0
    fi

    if [[ -z "$tty_fd" ]]; then
        printf '未检测到交互终端，退出向导。\n'
        return 0
    fi

    while true; do
        if ! read -r -u "$tty_fd" -p "请选择 [1-9 / 1-4 / shell / tools / all / q]: " raw_choice; then
            raw_choice=""
            printf '\n'
            break
        fi
        if parsed_choice=$(parse_opt_selection "$raw_choice"); then
            break
        fi
    done
    (( close_tty )) && exec {tty_fd}<&-

    if [[ -z "$parsed_choice" ]]; then
        printf '未选择任何可选项目，退出向导。\n'
        return 0
    fi

    local -a reg_label=() reg_tag=() reg_sudo=() reg_handler=()
    local entry id group label status_spec tag need_sudo handler
    for entry in "${OPT_REGISTRY[@]}"; do
        IFS='|' read -r id group label status_spec tag need_sudo handler <<< "$entry"
        reg_label[id]="$label"
        reg_tag[id]="$tag"
        reg_sudo[id]="$need_sudo"
        reg_handler[id]="$handler"
    done

    local -a selected_items=() completed_items=()
    read -ra selected_items <<< "$parsed_choice"

    local item require_sudo=0
    for item in "${selected_items[@]}"; do
        [[ "${reg_tag[item]}" == "-" ]] || validate_bashrc_block "${reg_tag[item]}" || return 1
        if (( reg_sudo[item] )); then
            require_sudo=1
        fi
    done

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
            if (( BASHRC_CHANGED )); then
                printf '  → 前序步骤已更新 ~/.bashrc，可执行 exec bash -i 重载已生效配置。\n' >&2
            fi
            return "$step_rc"
        fi
        completed_items+=("${item})${reg_label[item]}")
    done

    printf '\n✔ 所选 %d 项配置全部处理完成。\n' "$total"
}

main() {
    if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--help" ]]; }; then
        printf '✘ 不支持的参数: %s\n' "$*" >&2
        printf '用法: %s [--help]\n' "$0" >&2
        return 2
    fi
    case "${1:-}" in
        "")
            validate_arch_host || return 1
            validate_user_environment
            run_opt_menu
            if (( BASHRC_CHANGED )); then
                printf '\n→ 执行 exec bash -i 重载当前终端即可生效。\n'
            fi
            ;;
        --help)
            printf '用法: %s [--help]\n' "$0"
            printf '启动 Arch Linux Shell 增强与工具链选配向导。\n'
            ;;
    esac
}

main "$@"
