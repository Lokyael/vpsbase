#!/usr/bin/env bash
#
# server/os/host/nftables-init.sh
# Arch Linux 宿主 nftables 防火墙底座首次安装脚本
#

set -Eeuo pipefail

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

validate_user_environment() {
    local user_name
    user_name=$(id -un) || return 1
    [[ "$user_name" != "root" ]] || {
        printf '❌ 请以具备 sudo 权限的普通用户执行，禁止直接以 root 执行\n' >&2
        return 1
    }
    id -nG "$user_name" | tr ' ' '\n' | grep -Fxq wheel || {
        printf '❌ 当前用户不在 wheel 组\n' >&2
        return 1
    }
    sudo -v || {
        printf '❌ sudo 提权验证失败\n' >&2
        return 1
    }
}

run_firewall_init() {
    sudo /usr/bin/bash --noprofile --norc -s <<'ROOT'
set -Eeuo pipefail
export PATH=/usr/bin LC_ALL=C
shopt -s nullglob dotglob

config=/etc/nftables.conf
fragments=/etc/nftables.d
unit=/usr/lib/systemd/system/nftables.service
enabled_link=/etc/systemd/system/multi-user.target.wants/nftables.service
modules=/usr/lib/modules

fail() { printf '❌ %s\n' "$*" >&2; exit 1; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
running_kernel_modules_available() {
    local kver
    kver=$(uname -r) || return 1
    [[ -d "$modules/$kver" ]]
}
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

    # 按源 IP 限速动态集合，无匹配流量 5 分钟后自动回收
    set ssh_ratelimit {
        type ipv4_addr
        size 65536
        flags dynamic,timeout
        timeout 5m
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

        # 4. 经核验的 IPv4 SSH：非纯 SYN 丢弃 + 单源 IP 严格限速 + 全局兜底限速，超额仅丢弃
        tcp flags & (fin | syn | rst | ack) != syn ct state new drop
        $ssh_scope tcp dport $SSH_PORT ct state new update @ssh_ratelimit { ip saddr limit rate over 6/minute burst 5 packets } drop
        $ssh_scope tcp dport $SSH_PORT ct state new limit rate over 30/minute burst 15 packets drop
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
    # nft 1.1.7 的文本输出：-t 不列集合元素；仅放宽受控集合的运行态计数和已知回显形态。
    awk -v expected="$1" '
        { sub(/^[[:blank:]]+/, "") }
        /^$/ { next }
        expected && /^#/ { next }
        expected && /^type filter hook (input|forward|output) priority filter; policy / { sub(/priority filter;/, "priority 0;") }
        # nft 1.1.7 回显省略 `update @ssh_ratelimit { ip saddr ... }` 规则里与 ip saddr 重复的 meta nfproto ipv4 前缀
        /^meta nfproto ipv4 tcp dport [0-9]+ ct state new update @ssh_ratelimit / { sub(/^meta nfproto ipv4 /, "") }
        /^size (1048576|65536)[[:blank:]]+# count [0-9]+$/ { sub(/[[:blank:]]+# count [0-9]+$/, "") }
        /^flags (dynamic,[[:blank:]]*timeout|timeout,[[:blank:]]*dynamic)$/ { $0 = "flags dynamic,timeout" }
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
    if [[ "$state" == disabled ]]; then
        running_kernel_modules_available || fail "当前运行内核 ($(uname -r)) 的模块目录缺失（通常因内核已升级），请先执行 sudo reboot 重启后再初始化防火墙。"
    fi
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
    running_kernel_modules_available || fail "当前运行内核 ($(uname -r)) 的模块目录缺失（通常因内核已升级），请先执行 sudo reboot 重启后再初始化防火墙。"
    printf '将首次加载 nftables 底座：仅保留核验过的 IPv4 SSH 管理入口 %s/tcp，不开放业务 443。\n' "$port"
    if ! read -rp '已确认带外控制台可用并继续？[y/N]: ' answer < /dev/tty || [[ ! "$answer" =~ ^[Yy]$ ]]; then
        fail '已取消防火墙初始化。'
    fi
fi

pacman-key --init
pacman-key --populate archlinux
pacman -Sy --needed --noconfirm archlinux-keyring
pacman -Syu --needed --noconfirm nftables

ssh_after=$(ssh_snapshot) || fail '包更新后无法确认实际 IPv4 SSH 监听，请检查 sshd.service。'
[[ "${ssh_before#*$'\n'}" == "${ssh_after#*$'\n'}" ]] || fail '包更新后 IPv4 SSH 地址或端口发生变化。'
if [[ "$before" != ready ]] && ! running_kernel_modules_available; then
    fail "包更新升级了内核（当前运行内核 $(uname -r) 的模块目录已移除），请先执行 sudo reboot 重启后再执行 nftables-init.sh。"
fi
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

main() {
    if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--help" ]]; }; then
        printf '❌ 不支持的参数: %s\n' "$*" >&2
        printf '用法: %s [--help]\n' "$0" >&2
        return 2
    fi
    case "${1:-}" in
        "")
            validate_arch_host || return 1
            validate_user_environment || return 1
            run_firewall_init
            ;;
        --help)
            printf '用法: %s [--help]\n' "$0"
            printf '执行 Arch Linux 宿主 nftables 防火墙底座首次安装。\n'
            ;;
    esac
}

main "$@"
