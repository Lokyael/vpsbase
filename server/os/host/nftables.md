# nftables 原子网络防火墙

**前置条件**：首次安装仅通过 [2. 防火墙底座初始化](archlinux.md#2-防火墙底座初始化) 执行。底座默认丢弃入站与转发，仅放行环回、已建立/关联连接、限速 IPv4 ping、核验的 IPv4 SSH 及 `/etc/nftables.d/*.conf` 业务片段（不开放 IPv6 SSH）。

## 常用运维

- **注意**：人工封禁集合 `ssh_dynamic_ban` 仅存于运行态（365 天不续期）；完整重载或系统重启会清空该集合及限速状态。

```bash
# 查看当前规则集、监听端口与人工封禁列表
sudo nft list ruleset
sudo ss -tulanp
sudo nft list set inet filter ssh_dynamic_ban

# 手动封禁 / 解封 IPv4
sudo nft add element inet filter ssh_dynamic_ban { [HERE_IP] }
sudo nft delete element inet filter ssh_dynamic_ban { [HERE_IP] }
```

修改 `/etc/nftables.conf` 或 `/etc/nftables.d/*.conf` 后，先预检通过再完整加载：

```bash
sudo nft -c -f /etc/nftables.conf && sudo nft -f /etc/nftables.conf
```

## 恢复检查

保留当前 SSH 会话并确认带外控制台可用后排查：

```bash
systemctl is-enabled nftables.service
sudo journalctl -b -u nftables.service --no-pager
sudo nft -c -f /etc/nftables.conf
sudo nft list ruleset
sudo ss -4 -ltnp
```

修正后从**新终端**验证 IPv4 SSH 登录成功，再关闭原会话。
