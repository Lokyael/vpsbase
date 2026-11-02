# nftables 原子网络防火墙

默认丢弃入站和转发流量，放行本地环回、已建立连接、必要 ICMP 限速，以及带外管理高位 SSH 端口。SSH 新连接匹配包共用全局令牌桶，速率 `20/minute`、突发容量 `15`，超额仅丢弃；明确的人工封禁使用 `365d` 集合。作为单机宿主安全底座，开辟 `chain services` 服务子链并通过 drop-in 目录 `/etc/nftables.d/*.conf` 动态承接各网络入口（WireGuard、Ingress）的按需放行规则。

## 一键部署

以具备 `sudo` 权限的普通用户执行。脚本自省提取当前 SSH 端口，初始化 drop-in 目录，直接覆盖主配置文件 `/etc/nftables.conf`，预检通过后加载一次并启用开机自启：

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

# 确保 drop-in 目录存在
sudo mkdir -p /etc/nftables.d

# 生成主防火墙底座配置
sudo tee /etc/nftables.conf > /dev/null <<EOF
#!/usr/bin/nft -f

# 原子替换本文件管理的 inet filter 表
destroy table inet filter

table inet filter {
    # 人工封禁集合，元素默认保留 365 天
    set ssh_dynamic_ban {
        type ipv4_addr
        flags timeout
        timeout 365d
        size 1048576
    }

    # 业务服务挂载子链 (默认无 policy，未匹配自动返回主链)
    chain services {
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # 1. 优先放行本地环回 (保障本地应用与容器内部通信正常)
        iif lo accept

        # 2. 状态防火墙与动态黑名单过滤
        ct state invalid drop
        ip saddr @ssh_dynamic_ban drop
        ct state established,related accept

        # 3. 放行 IPv4 ICMP ping 限速 (便于链路审计与探活，抵御泛洪攻击)
        ip protocol icmp icmp type echo-request limit rate 5/second accept

        # 4. SSH 全局准入限速，超额仅丢弃，不归因封禁当前来源
        tcp flags & (fin|syn|rst|ack) != syn ct state new drop
        tcp dport $SSH_PORT ct state new limit rate over 20/minute burst 15 packets drop
        tcp dport $SSH_PORT accept

        # 5. 跳转至服务子链 (由 /etc/nftables.d/*.conf 动态按需放行)
        jump services

        # 6. 记录少量未授权入站丢弃日志，其余静默丢弃 (防扫描)
        log prefix "nftables_DROP: " limit rate 2/second
        drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

# 引入所有按需启用的服务放行规则片段
include "/etc/nftables.d/*.conf"
EOF

# 预检、加载规则并启用开机自启
sudo nft -c -f /etc/nftables.conf || { printf '❌ nftables 语法检查未通过，未生效配置！\n' >&2; exit 1; }
sudo nft -f /etc/nftables.conf
sudo systemctl enable nftables

printf '\n✅ nftables 主底座已就绪 (已启用开机自启)\n'
printf 'SSH 端口：%s\n' "$SSH_PORT"
printf '请保持当前会话，并从新终端测试 SSH 登录。\n'
)
```

SSH 全局桶限制的是 `ct state new` 匹配包，包含 SYN 重传，不是认证失败次数；不保证持续拥堵时新连接可用。人工黑名单优先于已建立连接，对命中来源的全部入站流量生效。业务自动封禁由各入口管理，不写入宿主人工黑名单。封禁仅保存在运行态：默认从首次成功加入起计时 `365d`，按下列命令重复添加同一未到期元素不续期；完整加载主配置（含入口规则变更）或系统重启后清空，不自动保存或恢复。

集合寿命与重建语义见 [nft 手册](https://netfilter.org/projects/nftables/manpage.html)，重复添加行为按 [Linux 6.12 元素更新逻辑](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/net/netfilter/nf_tables_api.c?h=v6.12)核验。

## 常用运维操作

### 查看运行态全量规则与封禁集合

```bash
# 查看当前加载的完整规则集
sudo nft list ruleset

# 查看系统监听端口
sudo ss -tulanp

# 查看人工封禁集合中的 IP
sudo nft list set inet filter ssh_dynamic_ban

# 手动解封误封的 IP
sudo nft delete element inet filter ssh_dynamic_ban { [HERE_IP] }

# 手动封禁指定恶意 IP
sudo nft add element inet filter ssh_dynamic_ban { [HERE_IP] }
```

### 规则重载与语法审计

修改 `/etc/nftables.conf` 或增删 `/etc/nftables.d/*.conf` 片段后，执行原子重载：

```bash
# 语法预检 (无输出即为语法正确)
sudo nft -c -f /etc/nftables.conf

# 原子替换受控表，同时清空已有封禁元素
sudo nft -f /etc/nftables.conf
```
