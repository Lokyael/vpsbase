(
set -euo pipefail
[[ $(id -u) -ne 0 ]] || { printf '请以 sudo 运维用户执行\n' >&2; exit 1; }
for database in passwd group; do
    rc=0
    getent "$database" ctrsvc >/dev/null || rc=$?
    [[ $rc -eq 2 ]] || { printf 'ctrsvc 已存在或无法查询 %s\n' "$database" >&2; exit 1; }
done
[[ ! -e /home/ctrsvc && ! -L /home/ctrsvc ]] \
    || { printf '/home/ctrsvc 已存在\n' >&2; exit 1; }
printf '将安装容器依赖并创建无登录、无 sudo 的 ctrsvc 账户及 HOME。\n'
read -rp '继续？[y/N]: ' confirm < /dev/tty
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0
sudo pacman -S --needed --noconfirm podman shadow curl jq openssl acme.sh argon2
# shadow 只在本地映射文件存在时分配范围；只创建缺失文件，不清空已有授权。
for mapping in /etc/subuid /etc/subgid; do
    if [[ ! -e "$mapping" && ! -L "$mapping" ]]; then
        sudo install -o root -g root -m 644 /dev/null "$mapping"
    else
        [[ -f "$mapping" && ! -L "$mapping" ]] \
            || { printf '映射文件类型无效: %s\n' "$mapping" >&2; exit 1; }
    fi
done
sudo useradd --system --user-group --no-create-home --add-subids-for-system \
    --home-dir /home/ctrsvc --shell /usr/bin/nologin ctrsvc
sudo passwd --lock ctrsvc
sudo install -d -o ctrsvc -g ctrsvc -m 700 /home/ctrsvc
sudo install -d -o root -g root -m 755 /etc/ssh/sshd_config.d
printf 'DenyUsers ctrsvc\n' | sudo install -o root -g root -m 644 /dev/stdin /etc/ssh/sshd_config.d/00-ctrsvc.conf
sudo sshd -t
sudo systemctl reload sshd
printf '账户已创建；请核对 sudo -l -U ctrsvc 无授权，再继续安装上下文检查。\n'
sudo passwd -S ctrsvc
id ctrsvc
)
