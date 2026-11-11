#!/usr/bin/env bash
#
# server/os/archlinux-opt.sh
# Arch Linux Shell 增强与工具链选配脚本
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

has_managed_block() {
    local target_file="$1"
    local tag="$2"
    local begin_mark="# >>> managed:${tag} >>>"
    local end_mark="# <<< managed:${tag} <<<"

    [[ -f "$target_file" ]] && grep -Fq "$begin_mark" "$target_file" && grep -Fq "$end_mark" "$target_file"
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

# 1. 多终端历史实时同步
opt_sync_history() {
    local action="配置"
    has_managed_block "$BASHRC" "archlinux:sync-history" && action="覆盖更新"
    printf '==> [%s] 多终端历史实时同步...\n' "$action"
    local content
    content=$(cat <<'EOF'
__sync_history() {
    local saved_status=$?
    history -a
    history -n
    return "$saved_status"
}
if [[ ! " ${PROMPT_COMMAND[*]-} " == *" __sync_history "* ]]; then
    PROMPT_COMMAND=(__sync_history "${PROMPT_COMMAND[@]-}")
fi
EOF
    )
    upsert_managed_block "$BASHRC" "archlinux:sync-history" "$content"
    printf '  ✅ 多终端历史实时同步已生效\n'
}

# 2. Git 分支状态提示符
opt_git_prompt() {
    local action="配置"
    has_managed_block "$BASHRC" "archlinux:git-prompt" && action="覆盖更新"
    printf '==> [%s] Git 分支状态提示符...\n' "$action"
    local content
    content=$(cat <<'EOF'
__git_info() {
    command -v git >/dev/null 2>&1 || return
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return
    [[ -n "$branch" ]] || return
    if git status --porcelain --ignore-submodules 2>/dev/null | command grep -q .; then
        printf ' (%s*)' "$branch"
    else
        printf ' (%s)' "$branch"
    fi
}
PS1='\[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\[\e[01;33m\]$(__git_info)\[\e[00m\]\$ '
EOF
    )
    upsert_managed_block "$BASHRC" "archlinux:git-prompt" "$content"
    printf '  ✅ Git 分支状态提示符已生效\n'
}

# 3. 非零退出码错误高亮
opt_exit_status() {
    local action="配置"
    has_managed_block "$BASHRC" "archlinux:exit-status" && action="覆盖更新"
    printf '==> [%s] 非零退出码错误高亮...\n' "$action"
    local content
    content=$(cat <<'EOF'
__exit_status() {
    local status=$?
    [[ "$status" -ne 0 ]] && printf '\001\e[01;31m\002[%s]\001\e[00m\002 ' "$status"
}
if [[ "$PS1" != *'$(__exit_status)'* ]]; then
    PS1='$(__exit_status)'"$PS1"
fi
EOF
    )
    upsert_managed_block "$BASHRC" "archlinux:exit-status" "$content"
    printf '  ✅ 非零退出码错误高亮已生效\n'
}

# 4. 历史记录去重函数
opt_dedup_history() {
    local action="配置"
    has_managed_block "$BASHRC" "archlinux:dedup-history" && action="覆盖更新"
    printf '==> [%s] 历史记录去重函数 (dedup-history)...\n' "$action"

    # 执行首次合规化清洗（确保历史文件具备完整时间戳，防止去重校验失败）
    normalize_history
    local content
    content=$(cat <<'EOF'
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
    tmpfile=$(mktemp "$histdir/.bash_history.tmp.XXXXXX") || { printf '%s\n' '无法创建历史临时文件，未执行去重。'; return 1; }
    if ! awk '
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
        rm -f -- "$tmpfile"
        return 1
    fi
    if [[ ! -s "$tmpfile" ]]; then
        rm -f -- "$tmpfile"
        printf '%s\n' '去重后结果为空，原文件未修改。'
        return 1
    fi
    if ! cp --attributes-only --preserve=mode,ownership "$histfile" "$tmpfile"; then
        rm -f -- "$tmpfile"
        printf '%s\n' '无法保留历史文件权限或所有者，原文件未修改。'
        return 1
    fi
    mv -- "$tmpfile" "$histfile" || { rm -f -- "$tmpfile"; printf '%s\n' '历史文件替换失败，停止。'; return 1; }
    history -c
    history -r || { printf '%s\n' '历史文件已更新，但当前 Shell 重新加载失败。'; return 1; }
    printf '%s\n' '历史记录已去重；重复命令保留最后一次记录。'
}
EOF
    )
    upsert_managed_block "$BASHRC" "archlinux:dedup-history" "$content"
    printf '  ✅ 历史去重函数已注入，可通过 dedup-history 手动调用\n'
}

# 5. Micro 编辑器
opt_micro() {
    local action="安装与配置"
    command -v micro >/dev/null 2>&1 && action="覆盖更新"
    printf '==> [%s] Micro 终端编辑器...\n' "$action"
    sudo pacman -S --needed --noconfirm micro
    mkdir -p "$HOME/.config/micro"
    if [[ ! -f "$HOME/.config/micro/settings.json" ]]; then
        cat > "$HOME/.config/micro/settings.json" <<'EOF'
{
  "tabsize": 4,
  "tabstospaces": true,
  "clipboard": "terminal",
  "wordwrap": true,
  "softwrap": true
}
EOF
    fi
    local content
    content=$(cat <<'EOF'
export EDITOR=micro
export VISUAL=micro
EOF
    )
    upsert_managed_block "$BASHRC" "archlinux:editor-micro" "$content"
    printf '  ✅ Micro 编辑器已就绪，并设为默认系统编辑器\n'
}

# 6. 从 AUR 独立编译构建 paru (AUR 助手)
opt_paru() {
    local action="从 AUR 构建安装"
    command -v paru >/dev/null 2>&1 && action="覆盖重新构建"
    printf '==> [%s] paru (AUR 助手)...\n' "$action"

    printf '  📦 安装构建依赖 (git, base-devel)...\n'
    sudo pacman -S --needed --noconfirm git base-devel || return 1

    # 内存 / 交换空间检测
    local mem_total_mib mem_available_mib swap_free_mib zram_total_mib avail_mib
    read -r mem_total_mib mem_available_mib <<< "$(
        awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%.0f %.0f", t/1024, a/1024}' /proc/meminfo
    )"
    swap_free_mib=$(awk '/SwapFree/ {printf "%.0f", $2/1024}' /proc/meminfo)
    zram_total_mib=$(cat /sys/block/zram*/disksize 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s/1024/1024}') || zram_total_mib=0
    # zram 按 disksize 一半保守估算可利用量
    avail_mib=$(( mem_available_mib + swap_free_mib + zram_total_mib / 2 ))

    printf '  💾 物理内存 %d MiB（可用 %d MiB），swap 空闲 %d MiB，zram %d MiB\n' \
        "$mem_total_mib" "$mem_available_mib" "$swap_free_mib" "$zram_total_mib"
    printf '  📊 可用缓冲合计 %d MiB\n' "$avail_mib"

    local install_mode compile_profile="default"
    if (( mem_total_mib <= 1024 )); then
        install_mode="prebuilt"
        printf '  🎯 ≤1024 MiB：预编译（libalpm 升级后需要维护者发布新版本适配新 libalpm 才能使用）\n'
    elif (( mem_total_mib <= 2048 )); then
        install_mode="source"; compile_profile="low-memory"
        printf '  🎯 ≤2048 MiB：限制内存编译\n'
        (( avail_mib < 1536 )) && printf '  ⚠️  可用缓冲 %d MiB < 1536 MiB，编译可能失败\n' "$avail_mib" >&2
    else
        install_mode="source"
        printf '  🎯 >2048 MiB：默认编译\n'
        (( avail_mib < 3584 )) && printf '  ⚠️  可用缓冲 %d MiB < 3584 MiB，有 OOM 风险\n' "$avail_mib" >&2
    fi

    local build_parent="${XDG_CACHE_HOME:-$HOME/.cache}"
    mkdir -p "$build_parent"
    local build_dir
    build_dir=$(mktemp -d "$build_parent/paru-build.XXXXXX") || {
        printf '❌ 无法创建临时构建目录\n' >&2
        return 1
    }

    local repo="paru"
    [[ "$install_mode" == "prebuilt" ]] && repo="paru-bin"
    printf '  📥 拉取 %s 仓库...\n' "$repo"
    if ! git clone --depth=1 "https://aur.archlinux.org/$repo.git" "$build_dir"; then
        printf '❌ 拉取 %s 失败\n' "$repo" >&2
        rm -rf "$build_dir"
        return 1
    fi

    local build_err=0
    (
        cd "$build_dir" || exit 1
        if [[ "$compile_profile" == "low-memory" ]]; then
            export MAKEFLAGS="-j1"
            export CARGO_PROFILE_RELEASE_LTO=off
            local _tmp_conf
            _tmp_conf=$(mktemp) || exit 1
            cat > "$_tmp_conf" <<EOF
source /etc/makepkg.conf
MAKEFLAGS="-j1"
OPTIONS+=(!lto !debug)
EOF
            printf '  ⚙️  低内存：-j1，!lto !debug，CARGO_LTO=off\n'
            makepkg --config "$_tmp_conf" -si --noconfirm
            local _ret=$?
            rm -f "$_tmp_conf"
            exit $_ret
        else
            printf '  🔨 makepkg %s\n' "$([[ "$install_mode" == "prebuilt" ]] && echo "安装预编译" || echo "默认编译")"
            makepkg -si --noconfirm
        fi
    ) || build_err=1

    rm -rf "$build_dir"
    if [[ $build_err -ne 0 ]]; then
        printf '❌ paru 安装失败\n' >&2
        return 1
    fi

    local orphans
    orphans=$(pacman -Qtdq 2>/dev/null || true)
    if [[ -n "$orphans" ]]; then
        printf '  🧹 清理孤立包...\n'
        # shellcheck disable=SC2086
        sudo pacman -Rns --noconfirm $orphans >/dev/null 2>&1 || true
    fi

    printf '  ✅ paru 已就绪: %s\n' "$(paru --version | head -n1)"
}

# 7. Node.js (fnm)
opt_fnm() {
    local action="安装与配置"
    command -v fnm >/dev/null 2>&1 && action="覆盖更新"
    printf '==> [%s] Node.js 环境 (fnm)...\n' "$action"
    sudo pacman -S --needed --noconfirm fnm
    eval "$(fnm env --shell bash)"
    fnm install --lts && fnm default lts-latest && fnm use lts-latest
    local content
    content=$(cat <<'EOF'
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd --shell bash)"
fi
EOF
    )
    upsert_managed_block "$BASHRC" "archlinux:fnm" "$content"
    printf '  ✅ Node.js LTS 已就绪: %s (fnm)\n' "$(node --version 2>/dev/null || true)"
}

# 8. Python 工具链 (uv)
opt_uv() {
    local action="安装"
    command -v uv >/dev/null 2>&1 && action="更新"
    printf '==> [%s] Python 工具链 (uv)...\n' "$action"
    sudo pacman -S --needed --noconfirm uv
    printf '  ✅ uv 已就绪: %s\n' "$(uv --version)"
}

# 9. GitHub CLI (gh)
opt_gh() {
    local action="安装"
    command -v gh >/dev/null 2>&1 && action="更新"
    printf '==> [%s] GitHub CLI (gh)...\n' "$action"
    sudo pacman -S --needed --noconfirm github-cli
    printf '  ✅ GitHub CLI 已就绪: %s\n' "$(gh --version | head -n1)"
}

# ========================================================
# 交互选配向导 (Interactive Opt Menu)
# ========================================================

run_opt_menu() {
    printf '\n======================================================\n'
    printf '       Arch Linux 可选扩展与工具链配置向导\n'
    printf '  已存在的配置将受控原位替换，未选项目保持原有状态。\n'
    printf '======================================================\n\n'

    local s1 s2 s3 s4 s5 s6 s7 s8 s9
    has_managed_block "$BASHRC" "archlinux:sync-history" && s1="[已配置]" || s1="[未配置]"
    has_managed_block "$BASHRC" "archlinux:git-prompt" && s2="[已配置]" || s2="[未配置]"
    has_managed_block "$BASHRC" "archlinux:exit-status" && s3="[已配置]" || s3="[未配置]"
    has_managed_block "$BASHRC" "archlinux:dedup-history" && s4="[已配置]" || s4="[未配置]"
    command -v micro >/dev/null 2>&1 && s5="[已安装]" || s5="[未安装]"
    command -v paru >/dev/null 2>&1 && s6="[已安装]" || s6="[未安装]"
    command -v fnm >/dev/null 2>&1 && s7="[已安装]" || s7="[未安装]"
    command -v uv >/dev/null 2>&1 && s8="[已安装]" || s8="[未安装]"
    command -v gh >/dev/null 2>&1 && s9="[已安装]" || s9="[未安装]"

    printf '【Shell 体验增强】\n'
    printf '  1) %s 多终端历史实时同步 (__sync_history)\n' "$s1"
    printf '  2) %s Git 分支状态提示符 (__git_info)\n' "$s2"
    printf '  3) %s 非零退出码错误高亮 (__exit_status)\n' "$s3"
    printf '  4) %s 历史记录智能去重函数 (dedup-history)\n' "$s4"
    printf '\n【常用工具链与软件源】\n'
    printf '  5) %s Micro 终端编辑器及标准配置\n' "$s5"
    printf '  6) %s paru (AUR 助手，从 AUR 源码独立构建并自动清理构建依赖)\n' "$s6"
    printf '  7) %s Node.js LTS 环境 (fnm 管理器)\n' "$s7"
    printf '  8) %s Python 极速工具链 (uv)\n' "$s8"
    printf '  9) %s GitHub CLI 官方客户端 (gh)\n' "$s9"
    printf '\n------------------------------------------------------\n'

    local choice=""
    if [[ -t 0 || -e /dev/tty ]]; then
        read -rp "请输入要配置的编号 (多选用空格分隔，如 '1 2 5'；输入 'all' 全选；回车退出): " choice < /dev/tty || choice=""
    fi

    [[ -n "$choice" ]] || {
        printf '未选择任何可选项目，退出向导。\n'
        return 0
    }

    if [[ "$choice" == "all" ]]; then
        choice="1 2 3 4 5 6 7 8 9"
    fi

    local item
    for item in $choice; do
        case "$item" in
            1|2|3|4|5|7) validate_bashrc || return 1 ;;
        esac
    done

    for item in $choice; do
        case "$item" in
            1) opt_sync_history ;;
            2) opt_git_prompt ;;
            3) opt_exit_status ;;
            4) opt_dedup_history ;;
            5) opt_micro ;;
            6) opt_paru ;;
            7) opt_fnm ;;
            8) opt_uv ;;
            9) opt_gh ;;
            *) printf '⚠️  忽略未知选项编号: %s\n' "$item" ;;
        esac
    done

    printf '\n✅ 所选组件配置处理完成。\n'
}

# ========================================================
# 主入口
# ========================================================

validate_user_environment() {
    local user_name expected_home
    user_name=$(id -un) || return 1
    [[ "$user_name" != "root" ]] || {
        printf '❌ 请以具备 sudo 权限的普通用户执行，禁止直接以 root 执行\n' >&2
        return 1
    }
    IFS=: read -r _ _ _ _ _ expected_home _ < <(getent passwd "$user_name") || {
        printf '❌ 无法查询当前用户的系统家目录\n' >&2
        return 1
    }
    [[ -n "$expected_home" && "$HOME" == "$expected_home" ]] || {
        printf '❌ HOME 环境变量 (%s) 与系统家目录 (%s) 不一致\n' "$HOME" "$expected_home" >&2
        return 1
    }
    cd "$expected_home" || return 1
}

main() {
    if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--help" ]]; }; then
        printf '❌ 不支持的参数: %s\n' "$*" >&2
        printf '用法: %s [--help]\n' "$0" >&2
        return 2
    fi
    case "${1:-}" in
        "")
            validate_user_environment
            run_opt_menu
            printf '\n👉 执行 exec bash -i 重载当前终端即可生效。\n'
            ;;
        --help)
            printf '用法: %s [--help]\n' "$0"
            printf '启动 Arch Linux Shell 增强与工具链选配向导。\n'
            ;;
    esac
}

main "$@"
