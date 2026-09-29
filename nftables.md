# nftables 网络防火墙

默认丢弃入站和转发流量，放行 SSH、已建立连接、必要 ICMP/ICMPv6，以及交互指定的 TCP/UDP 端口。脚本可选安装并配置 Fail2ban。

## 一键部署

以具备 `sudo` 权限的普通用户执行。确认 SSH 端口和额外端口后，脚本直接写入 nftables 主配置文件 `/etc/nftables.conf`、校验并启用服务；Fail2ban 默认跳过。

```bash
(
set -Eeuo pipefail

CURRENT_SSH_PORT=$(sudo sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)
read -rp "SSH 端口（当前首个生效端口: ${CURRENT_SSH_PORT:-未知}，回车保持）: " input_ssh < /dev/tty
SSH_PORT="${input_ssh:-$CURRENT_SSH_PORT}"
[[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -le 65535 && "$SSH_PORT" -ge 1 ]] \
    || { printf '❌ SSH 端口必须是 1-65535 的整数\n' >&2; exit 1; }

if [[ -n "$CURRENT_SSH_PORT" && "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
    printf '⚠️ 输入端口与当前 sshd 首个生效端口不同：%s\n' "$CURRENT_SSH_PORT" >&2
    read -rp '仍要继续加载防火墙规则吗？[y/N]: ' confirm_port < /dev/tty
    [[ "$confirm_port" =~ ^[Yy]$ ]] || { printf '已取消\n'; exit 1; }
fi

# 额外端口为空时不生成放行规则
read -rp '额外开放的 TCP 端口（如 80,443，回车不开放）: ' extra_tcp < /dev/tty
read -rp '额外开放的 UDP 端口（如 53,443，回车不开放）: ' extra_udp < /dev/tty
read -rp '是否同时配置 Fail2ban（SSH 增强防护 Jail）？[y/N]: ' enable_fail2ban < /dev/tty

format_ports() {
    local ports="$1"
    ports=$(printf '%s' "$ports" | tr ',' ' ' | xargs)
    [[ -z "$ports" ]] && return 0
    for port in $ports; do
        [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] \
            || { printf '❌ 端口无效：%s\n' "$port" >&2; return 1; }
    done
    printf '%s\n' "$ports" | sed 's/[[:space:]]\+/, /g'
}

# 转换为 nftables 集合格式，并校验端口范围
EXTRA_TCP_RULE='# 未开放额外 TCP 端口'
if [[ -n "$(printf '%s' "$extra_tcp" | tr -d '[:space:],')" ]]; then
    formatted_tcp=$(format_ports "$extra_tcp")
    EXTRA_TCP_RULE="tcp dport { $formatted_tcp } accept comment \"Allow Extra TCP Ports\""
fi

EXTRA_UDP_RULE='# 未开放额外 UDP 端口'
if [[ -n "$(printf '%s' "$extra_udp" | tr -d '[:space:],')" ]]; then
    formatted_udp=$(format_ports "$extra_udp")
    EXTRA_UDP_RULE="udp dport { $formatted_udp } accept comment \"Allow Extra UDP Ports\""
fi

sudo tee /etc/nftables.conf > /dev/null <<EOF
#!/usr/bin/nft -f

# 只替换本文件管理的 inet filter 表，不清除 Fail2ban 的动态表
destroy table inet filter

table inet filter {
    # SSH 动态封禁集合，超时后自动释放
    set ssh_dynamic_ban_v4 {
        type ipv4_addr
        flags dynamic, timeout
        timeout 365d
        size 1048576
    }
    set ssh_dynamic_ban_v6 {
        type ipv6_addr
        flags dynamic, timeout
        timeout 365d
        size 1048576
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # 黑名单和连接状态优先处理
        ip saddr @ssh_dynamic_ban_v4 drop
        ip6 saddr @ssh_dynamic_ban_v6 drop
        ct state established,related accept
        ct state invalid drop
        iif lo accept

        # IPv4 ping；IPv6 邻居发现是正常通信所必需
        ip protocol icmp icmp type echo-request accept
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert, nd-redirect } accept

        # SSH 新连接限速，超限地址加入动态集合
        tcp flags & (fin|syn|rst|ack) != syn ct state new drop
        tcp dport $SSH_PORT ct state new limit rate over 10/minute burst 5 packets add @ssh_dynamic_ban_v4 { ip saddr } drop
        tcp dport $SSH_PORT ct state new limit rate over 10/minute burst 5 packets add @ssh_dynamic_ban_v6 { ip6 saddr } drop
        tcp dport $SSH_PORT accept

        # 交互输入的业务端口
        $EXTRA_TCP_RULE
        $EXTRA_UDP_RULE
        # 记录少量丢弃日志，避免日志爆炸
        log prefix "nftables_DROP: " limit rate 2/second
        drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }
}
EOF

# 先校验，再以批处理方式加载
sudo nft -c -f /etc/nftables.conf || { printf '❌ nftables 语法检查未通过，未生效配置！\n' >&2; exit 1; }

# 原子级加载生效并设置开机自启
sudo nft -f /etc/nftables.conf
sudo systemctl enable --now nftables

if [[ "$enable_fail2ban" =~ ^[Yy]$ ]]; then
    # Fail2ban 独立使用 f2b-table，不会被上面的规则重载清除
    sudo pacman -S --needed --noconfirm fail2ban
    sudo install -d -m 755 /etc/fail2ban/jail.d

    sudo tee /etc/fail2ban/jail.d/sshd.local > /dev/null <<EOF
[sshd]
enabled   = true
port      = $SSH_PORT
mode      = aggressive
backend   = systemd
banaction = nftables[type=multiport]
maxretry  = 3
findtime  = 600
bantime   = 86400
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now fail2ban
    # 等待 fail2ban socket，避免服务启动竞态
    fail2ban_ready=0
    for i in {1..10}; do
        if sudo fail2ban-client ping &>/dev/null; then
            fail2ban_ready=1
            break
        fi
        sleep 0.5
    done
    [[ "$fail2ban_ready" == 1 ]] \
        || { printf '❌ Fail2ban 未就绪，请查看 journalctl -u fail2ban\n' >&2; exit 1; }
    sudo fail2ban-client status sshd
    printf '✅ Fail2ban 已启用 (sshd)\n'
else
    printf '⏭️ 跳过 Fail2ban\n'
fi

printf '\n✅ nftables 已加载并设置开机自启\n'
printf 'SSH 端口：%s\n' "$SSH_PORT"
printf 'TCP 端口：%s\n' "${extra_tcp:-无}"
printf 'UDP 端口：%s\n' "${extra_udp:-无}"
printf '请保持当前会话，并从新终端测试 SSH 登录。\n'
)
```

## 日常管理

### nftables

```bash
# 校验并重载本文件的规则；不会清除 Fail2ban 动态表
sudo nft -c -f /etc/nftables.conf
sudo nft -f /etc/nftables.conf

# 查看规则与监听
sudo nft list ruleset
sudo ss -tunap
sudo ss -tunap | grep -E 'sshd|LISTEN'

# 查看 SSH 爆破来源
sudo journalctl -u sshd --no-pager \
  | grep -E 'Failed password|Invalid user' \
  | grep -oE 'from ([0-9]{1,3}\.){3}[0-9]{1,3}' \
  | awk '{print $2}' | sort | uniq -c | sort -nr
```

### SSH 动态封禁

```bash
# 查看封禁集合
sudo nft list set inet filter ssh_dynamic_ban_v4
sudo nft list set inet filter ssh_dynamic_ban_v6

# 解封或手动封禁
sudo nft delete element inet filter ssh_dynamic_ban_v4 { 192.168.1.100 }
sudo nft delete element inet filter ssh_dynamic_ban_v6 { 2001:db8::1 }
sudo nft add element inet filter ssh_dynamic_ban_v4 { 192.168.1.100 }
sudo nft add element inet filter ssh_dynamic_ban_v6 { 2001:db8::1 }
```

### Fail2ban

主脚本选择 `y` 后会配置针对 SSH 的 `sshd` Jail（直接监控 systemd journal 认证失败日志，与 nftables 的 4 层速率限制形成纵深防御）。`f2b-table` 按需创建；没有活跃封禁时不存在是正常现象。

```bash
# 查看 Jail 与动态表
sudo fail2ban-client status sshd
sudo nft list table inet f2b-table 2>/dev/null \
  || echo '当前无 Fail2ban 封禁'

# 解封
sudo fail2ban-client set sshd unbanip [HERE_IP]

# 测试封禁联动
sudo fail2ban-client set sshd banip 192.0.2.1
sudo nft list table inet f2b-table
sudo fail2ban-client set sshd unbanip 192.0.2.1
```

## 卸载 Fail2ban

确认不再需要 Fail2ban 后执行：

```bash
(
sudo systemctl disable --now fail2ban 2>/dev/null || true
sudo pacman -Rns --noconfirm fail2ban 2>/dev/null || true
sudo rm -rf /etc/fail2ban /var/lib/fail2ban /var/log/fail2ban* /run/fail2ban /var/run/fail2ban
sudo nft destroy table inet f2b-table 2>/dev/null || true
sudo nft destroy table inet fail2ban 2>/dev/null || true
sudo nft -f /etc/nftables.conf
printf '✅ Fail2ban 已移除，nftables 已重载\n'
)
```

防火墙部署完成后进入 [git.md](git.md)。
