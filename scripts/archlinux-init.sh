#!/usr/bin/env bash
#
# scripts/archlinux-init.sh
# Arch Linux 基础环境初始化与可选扩展配置脚本
#

set -Eeuo pipefail

BASHRC="$HOME/.bashrc"

# ========================================================
# 受控分界标记块工具函数 (Managed Block Utilities)
# 基于 awk 流式原样读取，杜绝特殊字符与正则转义异常
# ========================================================

upsert_managed_block() {
    local target_file="$1"
    local tag="$2"
    local content="$3"
    local begin_mark="# >>> managed:${tag} >>>"
    local end_mark="# <<< managed:${tag} <<<"

    touch "$target_file"

    local content_file tmp_file
    content_file=$(mktemp)
    tmp_file=$(mktemp)

    printf '%s\n' "$content" > "$content_file"

    awk -v b="$begin_mark" -v e="$end_mark" -v cfile="$content_file" '
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
    ' "$target_file" > "$tmp_file"

    rm -f "$content_file"
    mv -f "$tmp_file" "$target_file"
    bash -n "$target_file" || {
        printf '❌ %s 注入后语法校验失败，请检查配置\n' "$target_file" >&2
        return 1
    }
}

has_managed_block() {
    local target_file="$1"
    local tag="$2"
    local begin_mark="# >>> managed:${tag} >>>"
    local end_mark="# <<< managed:${tag} <<<"

    [[ -f "$target_file" ]] && grep -Fq "$begin_mark" "$target_file" && grep -Fq "$end_mark" "$target_file"
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

    # 1. 验证用户环境基线
    printf '\n==> [1/5] 验证用户权限与 SSH 目录基线...\n'
    IFS=: read -r _ _ _ _ _ expected_home _ < <(getent passwd "$user_name")
    [[ "$HOME" == "$expected_home" && "$PWD" == "$expected_home" ]] || {
        printf '❌ HOME、当前工作目录与用户系统家目录不一致\n' >&2
        exit 1
    }
    id -nG "$user_name" | tr ' ' '\n' | grep -Fxq wheel || {
        printf '❌ 当前用户不在 wheel 组\n' >&2
        exit 1
    }
    [[ -d "$HOME/.ssh" && "$(stat -c '%a' "$HOME/.ssh")" == "700" ]] || {
        printf '❌ ~/.ssh 权限错误（应为 700）\n' >&2
        exit 1
    }
    [[ -f "$HOME/.ssh/authorized_keys" && "$(stat -c '%a' "$HOME/.ssh/authorized_keys")" == "600" ]] || {
        printf '❌ ~/.ssh/authorized_keys 权限错误（应为 600）\n' >&2
        exit 1
    }
    sudo -v || {
        printf '❌ sudo 提权验证失败\n' >&2
        exit 1
    }

    # 2. 设置主机名
    printf '==> [2/5] 配置系统主机名...\n'
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
    printf '==> [3/5] 更新官方密钥环与基础系统包...\n'
    sudo pacman-key --init
    sudo pacman-key --populate archlinux
    sudo pacman -Sy --needed --noconfirm archlinux-keyring
    sudo pacman -Syu --needed --noconfirm sudo which less bash-completion

    # 4. 本地化与时区
    printf '==> [4/5] 配置系统 Locale (en_US.UTF-8) 与统一时区 (UTC)...\n'
    sudo sed -i 's/^#[[:space:]]*\(en_US\.UTF-8[[:space:]]\+UTF-8\)/\1/' /etc/locale.gen
    grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' | sudo tee -a /etc/locale.gen >/dev/null
    sudo locale-gen
    sudo localectl set-locale LANG=en_US.UTF-8
    sudo timedatectl set-timezone UTC

    # 5. ~/.bashrc 通用受控配置
    printf '==> [5/5] 写入 ~/.bashrc 通用受控基础配置...\n'
    [[ ! -L "$BASHRC" ]] || { printf '❌ ~/.bashrc 是符号链接，停止\n' >&2; exit 1; }
    [[ ! -e "$BASHRC" || ( -f "$BASHRC" && -r "$BASHRC" && -w "$BASHRC" ) ]] || { printf '❌ ~/.bashrc 无法读写，停止\n' >&2; exit 1; }
    [[ ! -e "$BASHRC" ]] || bash -n "$BASHRC" || { printf '❌ 已有 ~/.bashrc 语法异常，停止\n' >&2; exit 1; }

    local default_skeleton
    default_skeleton=$'#\n# ~/.bashrc\n#\n\n# If not running interactively, don\'t do anything\n[[ $- != *i* ]] && return\n\nalias ls=\'ls --color=auto\'\nalias grep=\'grep --color=auto\'\nPS1=\'[\u@\h \W]\$ \''
    if [[ -f "$BASHRC" ]] && [[ "$(< "$BASHRC")" == "$default_skeleton" ]]; then
        > "$BASHRC"
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

    upsert_managed_block "$BASHRC" "archlinux-base" "$base_content"

    printf '\n✅ 基础环境初始化完成。\n'
    printf '   用户: %s | 主机名: %s | 时区: UTC | 语言: en_US.UTF-8\n' "$user_name" "$new_host"
}

# ========================================================
# 阶段 2: 可选组件模块 (带受控分界标记块)
# ========================================================

# 1. 多终端历史实时同步
opt_sync_history() {
    printf '==> [配置] 多终端历史实时同步...\n'
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
    printf '==> [配置] Git 分支状态提示符...\n'
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
    printf '==> [配置] 非零退出码错误高亮...\n'
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
    printf '==> [配置] 历史记录去重函数 (dedup-history)...\n'
    local content
    content=$(cat <<'EOF'
dedup-history() {
    local histfile=${HISTFILE:-$HOME/.bash_history}
    local tmpfile
    [[ -L "$histfile" ]] && { printf 'HISTFILE 是符号链接：%s；停止。\n' "$histfile"; return 1; }
    [[ -e "$histfile" ]] || { printf 'HISTFILE 不存在：%s；暂无历史记录，安全结束。\n' "$histfile"; return 0; }
    [[ -f "$histfile" && -r "$histfile" && -w "$histfile" ]] || { printf 'HISTFILE 不是当前用户可读写的普通文件：%s；停止。\n' "$histfile"; return 1; }
    [[ -s "$histfile" ]] || { printf 'HISTFILE 为空：%s；安全结束。\n' "$histfile"; return 0; }
    awk '
        function fail(message) { printf "历史文件第 %d 行异常：%s\n", NR, message > "/dev/stderr"; bad=1; exit 2 }
        {
            if ($0 ~ /^#[0-9]+$/) {
                if (!have) { if (NR != 1) fail("记录前出现无时间戳内容") }
                else if (!has_line) fail("时间戳后没有命令内容")
                have=1; has_line=0; next
            }
            if (!have) fail("文件开头不是 #数字 时间戳")
            has_line=1
        }
        END {
            if (!bad && !have) { print "历史文件为空或没有记录" > "/dev/stderr"; exit 2 }
            if (!bad && !has_line) { print "历史文件末尾时间戳后没有命令内容" > "/dev/stderr"; exit 2 }
        }' "$histfile" || { printf '%s\n' '历史文件不是完整的 Bash 时间戳格式，未执行去重。'; return 1; }
    history -a || { printf '%s\n' 'history -a 失败，未执行去重。'; return 1; }
    local histdir=${histfile%/*}
    [[ "$histdir" != "$histfile" ]] || histdir=.
    tmpfile=$(mktemp "$histdir/.bash_history.tmp.XXXXXX") || { printf '%s\n' '无法创建历史临时文件，未执行去重。'; return 1; }
    if ! awk '
        function flush() {
            if (!have) return
            if (!has_line) { bad=1; return }
            count++
            stamp[count]=timestamp
            text[count]=command
        }
        /^#[0-9]+$/ { flush(); timestamp=$0; command=""; has_line=0; have=1; next }
        !have { bad=1; next }
        !has_line { command=$0; has_line=1; next }
        { command=command "\n" $0 }
        END {
            flush()
            if (bad || count == 0) exit 2
            for (i=1; i<=count; i++) last[text[i]]=i
            for (i=1; i<=count; i++) if (last[text[i]] == i) { print stamp[i]; print text[i] }
        }' "$histfile" > "$tmpfile"; then
        rm -f -- "$tmpfile"
        printf '%s\n' '历史去重失败，原文件未修改。'
        return 1
    fi
    if ! awk '
        function fail(message) { printf "去重结果第 %d 行异常：%s\n", NR, message > "/dev/stderr"; bad=1; exit 2 }
        {
            if ($0 ~ /^#[0-9]+$/) {
                if (!have) { if (NR != 1) fail("记录前出现无时间戳内容") }
                else if (!has_line) fail("时间戳后没有命令内容")
                have=1; has_line=0; next
            }
            if (!have) fail("文件开头不是 #数字 时间戳")
            has_line=1
        }
        END {
            if (!bad && !have) { print "去重结果为空或没有记录" > "/dev/stderr"; exit 2 }
            if (!bad && !has_line) { print "去重结果末尾时间戳后没有命令内容" > "/dev/stderr"; exit 2 }
        }' "$tmpfile"; then
        rm -f -- "$tmpfile"
        printf '%s\n' '去重结果格式校验失败，原文件未修改。'
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
    printf '==> [安装与配置] Micro 终端编辑器...\n'
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
    printf '  ✅ Micro 编辑器已安装，并设为默认系统编辑器\n'
}

# 6. archlinuxcn 源与 paru
opt_archlinuxcn() {
    printf '==> [配置] archlinuxcn 软件源与 paru (AUR 助手)...\n'
    sudo sed -i '/^\[archlinuxcn\]/,/^\[/d' /etc/pacman.conf
    sudo tee -a /etc/pacman.conf > /dev/null <<'EOF'
[archlinuxcn]
Server = https://repo.archlinuxcn.org/$arch
Server = https://mirrors.aliyun.com/archlinuxcn/$arch
Server = https://mirrors.cloud.tencent.com/archlinuxcn/$arch
Server = https://repo.huaweicloud.com/archlinuxcn/$arch
EOF
    sudo pacman-conf >/dev/null && sudo pacman-conf --repo-list | grep -q '^archlinuxcn$' || {
        printf '❌ archlinuxcn 软件源配置失败\n' >&2
        return 1
    }
    sudo pacman -Sy --needed --noconfirm archlinuxcn-keyring
    sudo pacman -S --needed --noconfirm git base-devel wget paru
    printf '  ✅ archlinuxcn 源与 paru 安装成功: %s\n' "$(paru --version | head -n1)"
}

# 7. Node.js (fnm)
opt_fnm() {
    printf '==> [安装与配置] Node.js 环境 (fnm)...\n'
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
    printf '  ✅ Node.js LTS 安装完成: %s (fnm)\n' "$(node --version 2>/dev/null || true)"
}

# 8. Python 工具链 (uv)
opt_uv() {
    printf '==> [安装] Python 工具链 (uv)...\n'
    sudo pacman -S --needed --noconfirm uv
    printf '  ✅ uv 安装完成: %s\n' "$(uv --version)"
}

# 9. GitHub CLI (gh)
opt_gh() {
    printf '==> [安装] GitHub CLI (gh)...\n'
    sudo pacman -S --needed --noconfirm github-cli
    printf '  ✅ GitHub CLI 安装完成: %s\n' "$(gh --version | head -n1)"
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
    printf '  6) %s archlinuxcn 软件源与 paru (AUR 助手)\n' "$s6"
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

    for item in $choice; do
        case "$item" in
            1) opt_sync_history ;;
            2) opt_git_prompt ;;
            3) opt_exit_status ;;
            4) opt_dedup_history ;;
            5) opt_micro ;;
            6) opt_archlinuxcn ;;
            7) opt_fnm ;;
            8) opt_uv ;;
            9) opt_gh ;;
            *) printf '⚠️  忽略未知选项编号: %s\n' "$item" ;;
        esac
    done

    printf '\n✅ 所选组件配置处理完成。\n'
}

# ========================================================
# 主入口与参数路由
# ========================================================

main() {
    local mode="${1:-}"

    case "$mode" in
        --opt|-o)
            run_opt_menu
            printf '\n👉 执行 exec bash -i 重载当前终端即可生效。\n'
            ;;
        --base|-b)
            run_base_init
            printf '\n👉 执行 exec bash -i 重载当前终端即可生效。\n'
            ;;
        --help|-h)
            printf '用法: %s [选项]\n' "$0"
            printf '选项:\n'
            printf '  (无参数)   执行基础环境初始化，随后可交互进入选配向导\n'
            printf '  --base, -b 仅执行基础环境初始化，跳过选配向导\n'
            printf '  --opt,  -o 跳过基础环境初始化，直接启动选配向导\n'
            printf '  --help, -h 显示本帮助\n'
            ;;
        *)
            run_base_init
            printf '\n------------------------------------------------------\n'
            printf '基础环境已就绪。是否继续进入进阶选配向导 (Shell 增强与工具链)?\n'
            printf '  1) 退出并保持基础环境 [默认]\n'
            printf '  2) 启动交互选配向导\n'
            local next_step="1"
            if [[ -t 0 || -e /dev/tty ]]; then
                read -rp "请选择 [1-2, 默认 1]: " next_step < /dev/tty || next_step="1"
            fi
            if [[ "${next_step:-1}" == "2" ]]; then
                run_opt_menu
            fi
            printf '\n👉 请执行 exec bash -i 重载当前终端生效。\n'
            ;;
    esac
}

main "$@"
