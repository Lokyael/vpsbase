# Arch Linux 系统配置

x86_64 Arch Linux 服务器 / VPS 初始配置。

## 首次登录与基础环境初始化

以重装时配置的普通用户 SSH 登录：

```bash
ssh -p [HERE_SSH_PORT] [HERE_USERNAME]@[HERE_SERVER_IP]
```

登录后整段复制执行：

```bash
(
set -Eeuo pipefail

USER_NAME="$(id -un)"
[[ "$USER_NAME" != "root" ]] || { printf '❌ 请以普通用户执行，禁止以 root 执行\n' >&2; exit 1; }

# 1. 验证用户环境
IFS=: read -r _ _ _ _ _ EXPECTED_HOME _ < <(getent passwd "$USER_NAME")
[[ "$HOME" == "$EXPECTED_HOME" && "$PWD" == "$EXPECTED_HOME" ]] || { printf '❌ HOME、工作目录与用户家目录不一致\n' >&2; exit 1; }
id -nG "$USER_NAME" | tr ' ' '\n' | grep -Fxq wheel || { printf '❌ 用户不在 wheel 组\n' >&2; exit 1; }
[[ -d "$HOME/.ssh" && "$(stat -c '%a' "$HOME/.ssh")" == "700" ]] || { printf '❌ ~/.ssh 权限错误\n' >&2; exit 1; }
[[ -f "$HOME/.ssh/authorized_keys" && "$(stat -c '%a' "$HOME/.ssh/authorized_keys")" == "600" ]] || { printf '❌ authorized_keys 权限错误\n' >&2; exit 1; }
sudo -v || { printf '❌ sudo 提权验证失败\n' >&2; exit 1; }

# 2. 设置主机名
CURRENT_HOST=$(hostnamectl hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || true)
read -rp "主机名 (Hostname) [当前: ${CURRENT_HOST:-archlinux}，回车保持]: " input_host < /dev/tty
NEW_HOST="${input_host:-${CURRENT_HOST:-archlinux}}"
[[ -n "$NEW_HOST" ]] || { printf '❌ 主机名不能为空\n' >&2; exit 1; }
sudo hostnamectl set-hostname "$NEW_HOST"

# 3. 基础包与密钥环更新
sudo pacman-key --init
sudo pacman-key --populate archlinux
sudo pacman -Sy --needed --noconfirm archlinux-keyring
sudo pacman -Syu --needed --noconfirm sudo micro less which

printf '\n✅ 基础环境初始化完成。用户: %s | 主机名: %s\n' "$USER_NAME" "$NEW_HOST"
)
```

### 后续管理

需要 root shell 时：

```bash
sudo -i
```

确认要删除用户及其家目录时执行：

```bash
sudo userdel -r [HERE_USERNAME]
```

## 软件与仓库

后续操作均在普通用户 Shell 中执行。

### archlinuxcn 与 paru

配置第三方 `archlinuxcn` 源并安装 `paru`：

```bash
(
sudo sed -i '/^\[archlinuxcn\]/,/^\[/d' /etc/pacman.conf
sudo tee -a /etc/pacman.conf > /dev/null <<'EOF'
[archlinuxcn]
Server = https://repo.archlinuxcn.org/$arch
Server = https://mirrors.aliyun.com/archlinuxcn/$arch
Server = https://mirrors.cloud.tencent.com/archlinuxcn/$arch
Server = https://repo.huaweicloud.com/archlinuxcn/$arch
EOF

sudo pacman-conf >/dev/null && sudo pacman-conf --repo-list | grep -q '^archlinuxcn$' || { printf '❌ archlinuxcn 配置失败\n' >&2; exit 1; }

# 必须先单独安装并生效密钥环，再安装 paru（若密钥环报错先执行: sudo pacman-key --lsign-key "farseerfc@archlinux.org"）
sudo pacman -Sy --needed --noconfirm archlinuxcn-keyring
sudo pacman -S --needed --noconfirm git base-devel wget paru
paru --version
)
```

## 用户环境配置

### ~/.bashrc 受控区块

注入别名、彩色提示符、历史同步及去重函数 `dedup-history`：

```bash
(
set -e
BASHRC="$HOME/.bashrc"
BEGIN_MARK='# >>> managed:archlinux-system-config >>>'
END_MARK='# <<< managed:archlinux-system-config <<<'

# 合法性校验
[[ ! -L "$BASHRC" ]] || { printf '❌ ~/.bashrc 是符号链接，停止\n' >&2; exit 1; }
[[ ! -e "$BASHRC" || ( -f "$BASHRC" && -r "$BASHRC" && -w "$BASHRC" ) ]] || { printf '❌ ~/.bashrc 无法读写，停止\n' >&2; exit 1; }
[[ ! -e "$BASHRC" ]] || bash -n "$BASHRC" || { printf '❌ 已有 ~/.bashrc 语法异常，停止\n' >&2; exit 1; }

# 清理默认模板
DEFAULT_SKELETON=$'#\n# ~/.bashrc\n#\n\n# If not running interactively, don\'t do anything\n[[ $- != *i* ]] && return\n\nalias ls=\'ls --color=auto\'\nalias grep=\'grep --color=auto\'\nPS1=\'[\u@\h \W]\$ \''
if [[ -f "$BASHRC" ]] && [[ "$(< "$BASHRC")" == "$DEFAULT_SKELETON" ]]; then
    > "$BASHRC"
fi

BLOCK=$(cat <<'EOF'
# >>> managed:archlinux-system-config >>>

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

# 历史记录同步
__sync_history() {
    local saved_status=$?
    history -a
    history -n
    return "$saved_status"
}
if [[ ! " ${PROMPT_COMMAND[*]-} " == *" __sync_history "* ]]; then PROMPT_COMMAND=(__sync_history "${PROMPT_COMMAND[@]-}"); fi

# 常用别名
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
if command -v ss >/dev/null 2>&1; then alias ports='ss -tulanp'; elif command -v netstat >/dev/null 2>&1; then alias ports='netstat -tulanp'; else alias ports='printf "No netstat or ss found\n"'; fi
command -v df >/dev/null 2>&1 && alias df='df -h'
command -v free >/dev/null 2>&1 && alias free='free -h'

# 彩色输出
test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'

# 补全
if ! shopt -oq posix; then
    if [[ -f /usr/share/bash-completion/bash_completion ]]; then . /usr/share/bash-completion/bash_completion; elif [[ -f /etc/bash_completion ]]; then . /etc/bash_completion; fi
fi

# 终端标题与提示符
if [[ ${TERM:-} =~ (xterm|rxvt|screen|tmux) ]]; then TITLE="\[\e]0;\u@\h: \w\a\]"; else TITLE=''; fi

color_prompt=
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    colors=$(tput colors 2>/dev/null) || colors=0
    [[ "$colors" =~ ^[0-9]+$ && "$colors" -ge 8 ]] && color_prompt=yes
fi
if [[ "$color_prompt" == yes ]]; then
    WHITE="\[$(tput setaf 7; tput bold)\]"; GREEN="\[$(tput setaf 2; tput bold)\]"; YELLOW="\[$(tput setaf 3; tput bold)\]"; BLUE="\[$(tput setaf 4; tput bold)\]"; RESET="\[$(tput sgr0)\]"
else
    WHITE=; GREEN=; YELLOW=; BLUE=; RESET=
fi
__git_info() {
    command -v git >/dev/null 2>&1 || return
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return
    [[ -n "$branch" ]] || return
    if git status --porcelain --ignore-submodules 2>/dev/null | command grep -q .; then printf ' (%s*)' "$branch"; else printf ' (%s)' "$branch"; fi
}
__exit_status() { local status=$?; [[ "$status" -ne 0 ]] && printf '[%s] ' "$status"; }
PS1="${TITLE}${WHITE}\$(__exit_status)${GREEN}\u@\h${RESET}:${BLUE}\w${RESET}${YELLOW}\$(__git_info)${RESET}\$ "

export LESS='-R -F'
export PAGER=less
export MANPAGER='less -R'
export EDITOR=micro
export VISUAL=micro
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]]; then export BROWSER=echo; fi

# fnm 初始化
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd --shell bash)"
fi

# 历史记录去重函数
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

# <<< managed:archlinux-system-config <<<
EOF
)

printf '%s\n' "$BLOCK" | bash -n || { printf '❌ 受控区块语法校验失败\n' >&2; exit 1; }

touch "$BASHRC"
if grep -Fq "$BEGIN_MARK" "$BASHRC" && grep -Fq "$END_MARK" "$BASHRC"; then
    sed -i "/^${BEGIN_MARK}$/,/^${END_MARK}$/d" "$BASHRC"
fi

{ printf '%s\n\n' "$BLOCK"; cat "$BASHRC"; } > "$BASHRC.tmp"
mv "$BASHRC.tmp" "$BASHRC"
bash -n "$BASHRC" || { printf '❌ ~/.bashrc 语法校验失败\n' >&2; exit 1; }
printf '✅ ~/.bashrc 受控配置写入成功\n'
)
```

重载配置：

```bash
exec bash -i
```

### 历史记录去重

受控配置已内置 `dedup-history` 函数。需要清理重复命令时执行：

```bash
dedup-history
```

### Micro 配置

```bash
mkdir -p ~/.config/micro
if [[ ! -f ~/.config/micro/settings.json ]]; then
    cat > ~/.config/micro/settings.json <<'EOF'
{
  "tabsize": 4,
  "tabstospaces": true,
  "clipboard": "terminal",
  "wordwrap": true,
  "softwrap": true
}
EOF
fi
```

### 开发工具链（可选）

安装 `fnm`、`uv`、`github-cli`、`bash-completion` 并初始化 Node.js LTS：

```bash
sudo pacman -S --needed --noconfirm fnm uv github-cli bash-completion

if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --shell bash)"
    fnm install --lts && fnm default lts-latest && fnm use lts-latest
    node --version
fi
```

## Locale、时区与字体

### 本地化配置

安装 Maple Mono 字体，启用 en_US / zh_CN 并设置默认语言：

```bash
sudo pacman -S --needed --noconfirm ttf-maplemono-nf-cn-unhinted

sudo sed -i 's/^#[[:space:]]*\(en_US\.UTF-8[[:space:]]\+UTF-8\)/\1/' /etc/locale.gen
sudo sed -i 's/^#[[:space:]]*\(zh_CN\.UTF-8[[:space:]]\+UTF-8\)/\1/' /etc/locale.gen
grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' | sudo tee -a /etc/locale.gen >/dev/null
grep -q '^zh_CN.UTF-8 UTF-8' /etc/locale.gen || echo 'zh_CN.UTF-8 UTF-8' | sudo tee -a /etc/locale.gen >/dev/null
sudo locale-gen

if [[ ! -s /etc/locale.conf ]]; then
    sudo localectl set-locale LANG=en_US.UTF-8
fi
```

### 时区配置

```bash
# 默认 UTC，东八区可改为 Asia/Singapore
sudo timedatectl set-timezone UTC
timedatectl status
```

## zswap 与 zram

### 状态体检

检查 Swap、zswap、zram 及引导环境：

```bash
printf '=== zswap 状态 ===\n'
cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "不支持"

printf '\n=== 活动 Swap ===\n'
swapon --show
zramctl

printf '\n=== /etc/fstab Swap ===\n'
grep -nE '^[[:space:]]*[^#[:space:]]+[[:space:]]+[^#[:space:]]+[[:space:]]+swap([[:space:]]|$)' /etc/fstab 2>/dev/null || echo "无未注释磁盘 Swap"

printf '\n=== 引导器 ===\n'
grep -q "BOOT_IMAGE=" /proc/cmdline && echo "GRUB" || echo "非 GRUB 或未知"
```

### 禁用 zswap（GRUB）

zswap 为 `Y` 时需在 GRUB 中禁用并重启：

```bash
if ! grep -q 'zswap\.enabled=0' /etc/default/grub; then
    sudo sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)/\1 zswap.enabled=0/' /etc/default/grub
fi
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo reboot
```

### 配置 zram-generator

确认 zswap 为 `N` 且无活动磁盘 Swap 后执行：

```bash
sudo pacman -S --needed --noconfirm zram-generator

sudo mkdir -p /etc/systemd/zram-generator.conf.d
sudo tee /etc/systemd/zram-generator.conf.d/zram0.conf > /dev/null <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

sudo systemctl daemon-reload
sudo systemctl start dev-zram0.swap

# 验证状态与算法
systemctl is-active --quiet dev-zram0.swap && echo "dev-zram0.swap: active" || echo "dev-zram0.swap: failed"
swapon --show
cat /sys/block/zram0/comp_algorithm
```

基础配置完成后进入 [nftables.md](nftables.md)。变更 SSH 端口或用户参见 [ssh.md](ssh.md)。
