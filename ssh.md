# SSH

客户端密钥生成、服务端加固与日常维护。通过 [vps2arch](vps2arch.md) 重装的系统已自动完成加固，装机流水线直接进入 [nftables](nftables.md)。

## 客户端生成密钥

```sh
# Bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/server_login -C ""
```

## 配置 sshd_config

采用 drop-in 配置 `/etc/ssh/sshd_config.d/00-hardened.conf`，自动提取当前生效参数，回车保持：

```bash
(
set -Eeuo pipefail

[[ $EUID -eq 0 ]] && { printf '❌ 请勿直接以 root 执行，请以具备 sudo 权限的普通用户执行\n' >&2; exit 1; }

if ! sudo grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    printf '❌ /etc/ssh/sshd_config 未启用 sshd_config.d drop-in，请先启用 Include 后重试\n' >&2
    exit 1
fi

# 1. 优先读取当前生效的 AllowUsers，回退为当前登录用户
CURRENT_SSH_USER=$(sudo sshd -T 2>/dev/null | awk '$1 == "allowusers" {print $2; exit}' || true)
DEFAULT_USER="${CURRENT_SSH_USER:-${SUDO_USER:-$(id -un)}}"

read -rp "允许登录的用户名 (AllowUsers) [当前/默认: ${DEFAULT_USER}，回车保持]: " input_user < /dev/tty
SSH_USER="${input_user:-$DEFAULT_USER}"
[[ -n "$SSH_USER" ]] || { printf '❌ 用户名不能为空\n' >&2; exit 1; }
id "$SSH_USER" &>/dev/null || { printf '❌ 系统中不存在用户: %s\n' "$SSH_USER" >&2; exit 1; }

# 2. 优先读取当前生效端口
CURRENT_SSH_PORT=$(sudo sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)
CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"

read -rp "SSH 端口 [当前生效: ${CURRENT_SSH_PORT}，回车保持]: " input_ssh < /dev/tty
SSH_PORT="${input_ssh:-$CURRENT_SSH_PORT}"
[[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]] \
    || { printf '❌ SSH 端口必须是 1-65535 的整数\n' >&2; exit 1; }

# 3. 确保 Ed25519 主机密钥存在，清理弱/旧算法密钥
[[ -s /etc/ssh/ssh_host_ed25519_key ]] || sudo ssh-keygen -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
sudo rm -f /etc/ssh/ssh_host_rsa_key* /etc/ssh/ssh_host_ecdsa_key* /etc/ssh/ssh_host_dsa_key*

# 4. 清理旧重装脚本可能遗留的过渡配置
sudo rm -f /etc/ssh/sshd_config.d/00-custom.conf /etc/ssh/sshd_config.d/10-vps2arch.conf /etc/ssh/sshd_config.d/01-*.conf

# 5. 写入终态加固配置（00 确保优先级最高）
sudo tee /etc/ssh/sshd_config.d/00-hardened.conf > /dev/null <<EOF
# 端口与主机密钥
Port $SSH_PORT                          # 自定义端口
HostKey /etc/ssh/ssh_host_ed25519_key   # 仅使用 Ed25519 密钥

# 身份认证加固
PermitRootLogin no                      # 禁止 root 登录
PasswordAuthentication no               # 禁用密码认证
KbdInteractiveAuthentication no         # 禁用挑战响应
PubkeyAuthentication yes                # 启用公钥认证
AuthenticationMethods publickey         # 强制仅允许公钥
AllowUsers $SSH_USER                    # 仅允许白名单用户

# 安全与防暴力破解
MaxAuthTries 2                          # 认证重试上限 2 次
LoginGraceTime 20                       # 认证超时 20 秒

# 连接保活
ClientAliveInterval 120                 # 保活探测间隔 120 秒
ClientAliveCountMax 3                   # 探测失败 3 次断开连接

# SFTP 子系统
Subsystem sftp internal-sftp            # 使用内置 SFTP
EOF

sudo chmod 0600 /etc/ssh/sshd_config.d/00-hardened.conf

# 6. 语法检查（确保安全，避免失联）
sudo sshd -t || { printf '❌ sshd 语法检查未通过，停止重启！\n' >&2; exit 1; }

# 7. 重启服务
sudo systemctl restart sshd

# 显示生效的关键参数
printf '\n✅ sshd 配置成功并已重启，当前生效参数：\n'
sudo sshd -T | grep -iE '^(port|permitrootlogin|passwordauthentication|allowusers|maxauthtries)'

printf '\n⚠️ 注意：请切勿关闭当前终端窗口！新开一个终端测试登录：\n'
printf '   ssh -p %s %s@[HERE_SERVER_IP]\n' "$SSH_PORT" "$SSH_USER"
)
```
