# nftables 原子网络防火墙

默认丢弃入站和转发流量，放行本地环回、已建立和关联连接、限速的 IPv4 ping，以及核验过的 IPv4 SSH 目的地址和端口。底座本身不开放 IPv6 SSH，也不保全 IPv6 邻居发现及依赖它的连接。

SSH 新连接匹配包共用全局令牌桶，速率 `20/minute`、突发容量 `15`，超额仅丢弃。业务放行规则经 `/etc/nftables.d/*.conf` 接入 `services` 子链。

首次安装只通过 [Arch Linux 基础环境初始化](README.md#基础环境初始化)。首次加载只创建表，不替换已存在的同名表；本页的完整重载仅用于已安装的底座。

SSH 全局桶限制的是 `ct state new` 匹配包，包含 SYN 重传，不是认证失败次数；不保证持续拥堵时新连接可用。人工封禁集合用于 IPv4 来源，命中时优先于已建立连接的放行规则。业务自动封禁由各入口管理，不写入宿主人工黑名单。封禁仅保存在运行态：默认从首次成功加入起计时 `365d`，按下列命令重复添加同一未到期元素不续期；完整加载主配置（含入口规则变更）或系统重启后清空，不自动保存或恢复。

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

修改 `/etc/nftables.conf` 或增删 `/etc/nftables.d/*.conf` 片段后，预检退出状态为 0 才加载。预检失败不会替换运行态，但开机单元仍读取磁盘配置；先修正磁盘并重新预检，不要直接重启。预检和加载期间不要并行修改主配置或片段。完整加载会原子替换受控表，并清空运行态人工封禁；不能接受清空时不要重载。

```bash
sudo nft -c -f /etc/nftables.conf &&
    sudo nft -f /etc/nftables.conf
```

### 恢复检查

保留当前 SSH 会话，确认带外控制台可用。加载或开机失败时分别检查主配置、已加载规则、SSH 实际监听和本次启动日志；开机启用、已有 SSH 会话或 `network-pre.target` 的排序都不是新连接成功的证据。先核对异常再决定是否显式重载，不用初始化接管未知规则。

```bash
systemctl is-enabled nftables.service
sudo journalctl -b -u nftables.service --no-pager
sudo nft -c -f /etc/nftables.conf
sudo nft list ruleset
sudo ss -4 -ltnp
```

从新终端验证 IPv4 SSH 登录后再关闭原会话。
