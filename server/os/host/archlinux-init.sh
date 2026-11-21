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
# 基础包与无业务片段的宿主防火墙
# ========================================================

run_package_and_firewall_init() {
    sudo /usr/bin/bash --noprofile --norc -s <<'ROOT'
set -Eeuo pipefail
export PATH=/usr/bin LC_ALL=C
shopt -s nullglob dotglob

config=/etc/nftables.conf
fragments=/etc/nftables.d
unit=/usr/lib/systemd/system/nftables.service
enabled_link=/etc/systemd/system/multi-user.target.wants/nftables.service

fail() { printf '❌ %s\n' "$*" >&2; exit 1; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
regular() {
    local metadata
    [[ ! -L "$1" ]] && metadata=$(stat -c '%F:%u:%g:%a:%h' -- "$1") && [[ "$metadata" == 'regular file:0:0:644:1' ]]
}

ssh_snapshot() {
    local effective endpoints port pid current socket actual active
    effective=$(sshd -T) || return 1
    endpoints=$(awk '
        $1 == "Port" || $1 == "port" {
            if (NF != 2 || $2 !~ /^[1-9][0-9]{0,4}$/ || $2 > 65535 || (port != "" && $2 != port)) bad = 1
            else port = $2
        }
        $1 == "ListenAddress" || $1 == "listenaddress" {
            if (NF != 2) { bad = 1; next }
            if ($2 ~ /^\[[[:xdigit:]:.%[:alnum:]_-]+\]:[0-9]+$/) next
            if ($2 !~ /^([0-9]+\.){3}[0-9]+:[0-9]+$/) { bad = 1; next }
            split($2, a, ":")
            v4[$2] = a[2]
            if (a[1] !~ /^127\./) reachable = 1
        }
        END {
            if (bad || !port || !reachable) exit 1
            for (addr in v4) if (v4[addr] != port) exit 1
            print port
            for (addr in v4) print addr
        }' <<< "$effective") || return 1
    port=${endpoints%%$'\n'*}
    endpoints=$(sort <<< "${endpoints#*$'\n'}") || return 1
    active=$(systemctl show --value -p ActiveState sshd.service) || return 1
    [[ "$active" == active ]] || return 1
    pid=$(systemctl show --value -p MainPID sshd.service) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ && /proc/$pid/exe -ef /usr/bin/sshd ]] || return 1
    socket=$(ss -H -O -4 -ltnp 2>&1) || return 1
    actual=$(awk -v port="$port" -v pid="$pid" '
        $1 != "LISTEN" || NF < 5 { bad = 1; next }
        $4 ~ (":" port "$") || $0 ~ (",pid=" pid ",fd=") {
            if ($4 !~ ("^([0-9]+\\.){3}[0-9]+:" port "$") ||
                NF != 6 || $6 !~ ("^users:\\(\\(\"[^\"]+\",pid=" pid ",fd=[0-9]+\\)\\)$") || seen[$4]++) bad = 1
            else print $4
        }
        END { if (bad) exit 1 }' <<< "$socket" | sort) || return 1
    current=$(systemctl show --value -p MainPID sshd.service) || return 1
    [[ "$pid" == "$current" && "$actual" == "$endpoints" ]] || return 1
    printf '%s %s\n%s\n' "$port" "$pid" "$endpoints"
}

ssh_rule_scope() {
    local addresses
    addresses=$(cut -d: -f1 <<< "$1" | sort -V) || return 1
    [[ -n "$addresses" ]] || return 1
    if grep -Fxq '0.0.0.0' <<< "$addresses"; then
        printf 'meta nfproto ipv4\n'
    elif [[ "$addresses" == *$'\n'* ]]; then
        printf 'ip daddr { %s }\n' "${addresses//$'\n'/, }"
    else
        printf 'ip daddr %s\n' "$addresses"
    fi
}

render_firewall_base() {
    local SSH_PORT=$1 ssh_scope=$2 table_command=${3:-}
    cat <<EOF
${table_command}table inet filter {
    # 人工封禁集合，元素默认保留 365 天
    set ssh_dynamic_ban {
        type ipv4_addr
        size 1048576
        timeout 365d
    }

    # 业务服务挂载子链 (默认无 policy，未匹配自动返回主链)
    chain services {
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # 1. 优先放行本地环回 (保障本地应用与容器内部通信正常)
        iif "lo" accept

        # 2. 状态防火墙与动态黑名单过滤
        ct state invalid drop
        ip saddr @ssh_dynamic_ban drop
        ct state established,related accept

        # 3. 放行 IPv4 ICMP ping 限速 (便于链路审计与探活，抵御泛洪攻击)
        icmp type echo-request limit rate 5/second burst 5 packets accept

        # 4. 经核验的 IPv4 SSH：共用准入限速，超额仅丢弃
        tcp flags & (fin | syn | rst | ack) != syn ct state new drop
        $ssh_scope tcp dport $SSH_PORT ct state new limit rate over 20/minute burst 15 packets drop
        $ssh_scope tcp dport $SSH_PORT accept

        # 5. 跳转至服务子链 (由 /etc/nftables.d/*.conf 动态按需放行)
        jump services

        # 6. 记录少量未授权入站丢弃日志，其余静默丢弃 (防扫描)
        limit rate 2/second burst 5 packets log prefix "nftables_DROP: "
        drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
}

render_firewall_config() {
    printf '#!/usr/bin/nft -f\n\n# 原子替换本文件管理的 inet filter 表\ndestroy table inet filter\n\n' &&
        render_firewall_base "$@" &&
        printf '\n# 引入所有按需启用的服务放行规则片段\ninclude "/etc/nftables.d/*.conf"\n'
}

normalize_firewall_listing() {
    # nft 1.1.7 的文本输出：-t 不列集合元素；仅放宽本集合的运行态计数和已知回显形态。
    awk -v expected="$1" '
        { sub(/^[[:blank:]]+/, "") }
        /^$/ { next }
        expected && /^#/ { next }
        expected && /^type filter hook (input|forward|output) priority filter; policy / { sub(/priority filter;/, "priority 0;") }
        /^size 1048576[[:blank:]]+# count [0-9]+$/ { $0 = "size 1048576" }
        { print }'
}

read_firewall_runtime() {
    local listing
    listing=$(nft -t -y list ruleset 2>&1) || fail "无法读取 nftables 内核规则：$listing"
    printf '%s' "$listing"
}

unit_contract_matches() {
    awk '
        BEGIN { section=""; bad=0 }
        /^[[:space:]]*[#;]/ || /^[[:space:]]*$/ { next }
        /\\[[:blank:]]*$/ { bad=1; next }
        /^\[/ {
            section=$0
            if (section !~ /^\[(Unit|Service|Install)\]$/ || ++sections[section] != 1) bad=1
            next
        }
        {
            if (section == "[Unit]") {
                if ($0 == "Wants=network-pre.target") wants++
                else if ($0 == "Before=network-pre.target") before++
                else if ($0 ~ /^Description=/ || $0 ~ /^Documentation=/) next
                else bad=1
            } else if (section == "[Service]") {
                if ($0 == "Type=oneshot") type++
                else if ($0 == "ExecStart=/usr/bin/nft -f /etc/nftables.conf") exec++
                else bad=1
            } else if (section == "[Install]") {
                if ($0 == "WantedBy=multi-user.target") wanted++
                else bad=1
            } else bad=1
        }
        END {
            if (bad || sections["[Unit]"] != 1 || sections["[Service]"] != 1 || sections["[Install]"] != 1 ||
                wants != 1 || before != 1 || type != 1 || exec != 1 || wanted != 1) exit 1
        }' "$1"
}

unit_effective_matches() {
    local effective
    effective=$(systemctl show --all -p Type -p ExecStart -p Before -p Wants nftables.service) || return 1
    awk '
        $0 == "Type=oneshot" { type++ }
        /^ExecStart=/ {
            prefix="ExecStart={ path=/usr/bin/nft ; argv[]=/usr/bin/nft -f /etc/nftables.conf ; ignore_errors=no ; "
            if (index($0, prefix) == 1 && substr($0, length(prefix) + 1) ~ /^[^{}]* \}$/) exec++
        }
        /^Before=/ { if (substr($0, 8) ~ /(^| )network-pre\.target( |$)/) before++ }
        /^Wants=/ { if (substr($0, 7) ~ /(^| )network-pre\.target( |$)/) wants++ }
        END { exit (NR != 4 || type != 1 || exec != 1 || before != 1 || wants != 1) }
    ' <<< "$effective"
}

firewall_runtime_matches() {
    local actual expected
    actual=$(normalize_firewall_listing 0 <<< "$1") || return 1
    expected=$(render_firewall_base "$2" "$3" | normalize_firewall_listing 1) || return 1
    [[ "$actual" == "$expected" ]]
}

check_fragment_slot() {
    local metadata
    absent "$fragments" && return 0
    [[ ! -L "$fragments" ]] && metadata=$(stat -c '%F:%u:%g:%a' -- "$fragments") && [[ "$metadata" == 'directory:0:0:755' ]] \
        || fail "业务片段目录类型、归属或权限不符：$fragments"
    local entries=("$fragments"/*)
    ((${#entries[@]} == 0)) || fail "本次仅初始化无业务片段的底座，请先核对 $fragments"
}

firewall_state() {
    local port=$1 ssh_scope=$2 packages unit_show state listing owner stock link_target expected_disk
    check_fragment_slot
    absent "$config.pacnew" && absent "$config.pacsave" || fail '存在 nftables.pacnew 或 .pacsave 痕迹，请核对主配置。'
    packages=$(pacman -Qq) || fail '无法读取本机包清单。'
    unit_show=$(systemctl show --all -p LoadState -p ActiveState -p SubState -p Job -p FragmentPath \
        -p DropInPaths -p UnitFileState -p NeedDaemonReload nftables.service | sort) || fail '无法读取 nftables.service 状态。'
    if [[ $'\n'"$packages"$'\n' != *$'\nnftables\n'* ]]; then
        absent "$config" && absent "$unit" && absent "$enabled_link" && absent /usr/bin/nft &&
            [[ "$unit_show" == $'ActiveState=inactive\nDropInPaths=\nFragmentPath=\nJob=\nLoadState=not-found\nNeedDaemonReload=no\nSubState=dead\nUnitFileState=' ]] \
            || fail 'nftables 包未安装，但已有防火墙配置或单元，需人工核对。'
        printf 'missing\n'
        return 0
    fi

    regular "$unit" || fail 'nftables.service 不是预期的包文件。'
    owner=$(pacman -Qoq -- "$unit") || fail '无法确认 nftables.service 的包归属。'
    [[ "$owner" == nftables ]] && unit_contract_matches "$unit" \
        || fail 'nftables.service 内容、包归属或关键语义不符合已核验的 Arch 单元。'
    state=${unit_show##*$'\n'UnitFileState=}
    [[ "$state" == disabled || "$state" == enabled ]] &&
        [[ "$unit_show" == $'ActiveState=inactive\nDropInPaths=\nFragmentPath='"$unit"$'\nJob=\nLoadState=loaded\nNeedDaemonReload=no\nSubState=dead\nUnitFileState='"$state" ]] \
        || fail 'nftables.service 存在覆盖、作业或未知运行／启用状态。'
    unit_effective_matches || fail 'nftables.service 生效的命令、类型或开机排序不符合预期。'
    listing=$(read_firewall_runtime) || exit 1
    if [[ "$state" == disabled ]]; then
        absent "$enabled_link" && [[ -z "$listing" ]] || fail '首次安装要求无既有启用项且内核规则为空。'
        if ! absent "$config"; then
            regular "$config" || fail "主配置类型、归属或权限不符：$config"
            owner=$(pacman -Qoq -- "$config") || fail "无法确认主配置的包归属：$config"
            stock=$(pacman --color never -Qii nftables) || fail '无法核对 Arch 包默认配置。'
            [[ "$owner" == nftables ]] && awk -v file="$config" '
                { sub(/^Backup Files[[:blank:]]*:[[:blank:]]*/, "") }
                $1 == file { count++; if (NF == 2 && $2 == "[unmodified]") good++ }
                END { if (count != 1 || good != 1) exit 1 }' <<< "$stock" \
                || fail "主配置不是 Arch 包原样配置：$config"
        fi
        printf 'fresh\n'
        return 0
    fi

    [[ -d "$fragments" ]] || fail "缺少受控的空业务片段目录：$fragments"
    link_target=$(realpath -e -- "$enabled_link") || fail '无法确认 nftables 的开机启用链接。'
    [[ -L "$enabled_link" && "$link_target" == "$unit" ]] || fail 'nftables 的开机启用链接不匹配。'
    expected_disk=$(render_firewall_config "$port" "$ssh_scope") || fail '无法生成受控主配置。'
    regular "$config" && cmp -s -- "$config" <(printf '%s\n' "$expected_disk") && firewall_runtime_matches "$listing" "$port" "$ssh_scope" \
        || fail 'nftables 磁盘配置或内核规则不符合无业务宿主底座，请分别核对。'
    printf 'ready\n'
}

ssh_before=$(ssh_snapshot) || fail '无法确认 sshd.service 的实际 IPv4 监听与 sshd -T 一致。'
port=${ssh_before%% *}
[[ "$port" != 443 ]] || fail 'IPv4 SSH 正在使用预留给业务入口的 443/tcp，请先核对管理端口。'
ssh_scope=$(ssh_rule_scope "${ssh_before#*$'\n'}") || fail '无法确定需放行的 IPv4 SSH 目的地址。'
before=$(firewall_state "$port" "$ssh_scope")
if [[ "$before" != ready ]]; then
    printf '将首次加载 nftables 底座：仅保留核验过的 IPv4 SSH 管理入口 %s/tcp，不开放业务 443。\n' "$port"
    if ! read -rp '已确认带外控制台可用并继续？[y/N]: ' answer < /dev/tty || [[ ! "$answer" =~ ^[Yy]$ ]]; then
        fail '已取消防火墙初始化与包更新。'
    fi
fi

pacman-key --init
pacman-key --populate archlinux
pacman -Sy --needed --noconfirm archlinux-keyring
pacman -Syu --needed --noconfirm sudo which less bash-completion nftables

ssh_after=$(ssh_snapshot) || fail '包更新后无法确认实际 IPv4 SSH 监听，请检查 sshd.service。'
[[ "${ssh_before#*$'\n'}" == "${ssh_after#*$'\n'}" ]] || fail '包更新后 IPv4 SSH 地址或端口发生变化。'
after=$(firewall_state "$port" "$ssh_scope")
if [[ "$before" == ready && "$after" == ready ]]; then
    printf '✅ nftables 底座已合规；未重载，人工封禁保留。\n'
    exit 0
fi
[[ "$before" != ready && "$after" == fresh ]] || fail '包更新后的防火墙状态已变化，请核对磁盘和内核。'

umask 077
work=$(mktemp -d -- "${config%/*}/.nftables.XXXXXX")
candidate=$work/base.nft
persist=$work/nftables.conf
trap 'rm -f -- "$candidate" "$persist"; rmdir -- "$work"' EXIT
# 首装在内核事务内排他创建；既有同名表不能被首装替换。
render_firewall_base "$port" "$ssh_scope" 'create ' > "$candidate"
render_firewall_config "$port" "$ssh_scope" > "$persist"
chmod 0644 -- "$persist"
nft -c -f "$candidate" || fail 'nftables 候选预检失败，主配置未更改。'
[[ $(ssh_snapshot) == "$ssh_after" && $(firewall_state "$port" "$ssh_scope") == fresh ]] \
    || fail '预检后 SSH 监听或防火墙状态已变化，请重新核对。'
if absent "$fragments"; then
    install -d -m 0755 -- "$fragments" || fail "无法创建空的业务片段目录：$fragments"
fi
check_fragment_slot
nft -f "$candidate" || fail 'nftables 候选加载失败，主配置未更改。'
mv -fT --no-copy -- "$persist" "$config" \
    || fail "规则已加载，但主配置发布失败：$config。请分别核对运行态与磁盘。"
systemctl enable nftables.service \
    || fail '规则已加载且主配置已发布，开机启用失败。请检查 nftables.service。'
[[ $(firewall_state "$port" "$ssh_scope") == ready ]] \
    || fail '规则已加载且主配置已发布，但终态回读不符。请保持当前 SSH 并检查规则和开机启用。'
printf '✅ nftables 底座已就绪，SSH 端口 %s；请保留当前会话并从新终端验证 IPv4 SSH。\n' "$port"
ROOT
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

    # 3. 官方密钥环、基础更新与防火墙
    printf '==> [3/7] 核对并初始化宿主防火墙，更新官方密钥环与基础包...\n'
    run_package_and_firewall_init || return 1

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
    local total_ram_kb total_ram_mb buffer_size somaxconn nofile_soft nofile_hard tier_desc
    total_ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    total_ram_mb=$(( total_ram_kb / 1024 ))

    if [[ $total_ram_mb -le 1024 ]]; then
        buffer_size=4194304
        somaxconn=4096
        nofile_soft=4096
        nofile_hard=65536
        tier_desc="4MB (≤1GB RAM)"
    elif [[ $total_ram_mb -le 2048 ]]; then
        buffer_size=8388608
        somaxconn=8192
        nofile_soft=8192
        nofile_hard=262144
        tier_desc="8MB (1~2GB RAM)"
    elif [[ $total_ram_mb -le 4096 ]]; then
        buffer_size=16777216
        somaxconn=8192
        nofile_soft=65535
        nofile_hard=1048576
        tier_desc="16MB (2~4GB RAM)"
    else
        buffer_size=33554432
        somaxconn=16384
        nofile_soft=65535
        nofile_hard=1048576
        tier_desc="32MB (>4GB RAM)"
    fi

    sudo modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" | sudo tee /etc/modules-load.d/tcp_bbr.conf > /dev/null

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

# 启用宽松反向路径过滤；关闭火星包日志以避免大量扫描日志
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0
EOF

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
    manage_swap

    printf '\n✅ 基础环境初始化完成。\n'
    printf '   用户: %s | 主机名: %s | 时区: UTC (NTP 同步) | 语言: en_US.UTF-8 | 网络缓冲: %s\n' "$user_name" "$new_host" "$tier_desc"
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

    local chosen_mode=""
    if [[ -t 0 ]] || { true < /dev/tty; } 2>/dev/null; then
        read -rp "  请选择内存模式 [1-3, 默认 $suggest_mode]: " chosen_mode < /dev/tty || chosen_mode=""
    fi
    chosen_mode="${chosen_mode:-$suggest_mode}"

    case "$chosen_mode" in
        1)
            printf '  ==> 配置 1GB 经典磁盘 Swapfile...\n'
            if ! sudo dd if=/dev/null of=/swapfile count=0 conv=excl status=none; then
                printf '❌ 无法新建 /swapfile，请核对该路径及权限。\n' >&2
                return 1
            fi
            sudo chmod 0600 /swapfile
            sudo fallocate -l 1G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
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
                elif [[ ! -f /etc/default/grub ]]; then
                    printf '  ℹ️  未检测到 GRUB，请确保引导加载器内核参数包含 zswap.enabled=0 以持久化停用 zswap\n'
                fi
            fi
            printf '  ✅ zram 压缩内存盘已激活 (1/2 内存, zstd 算法)\n'
            ;;
        3)
            printf '  ⏭️  保持纯物理内存运行，未配置 Swap\n'
            ;;
        *)
            printf '  ⚠️  输入无效，保持原样未配置 Swap\n'
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
