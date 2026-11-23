(
set -euo pipefail
umask 077
ctrsvc-check

source "$HOME/containers/nginx/manage.sh"
nginx_lock
[[ ! -e "$NGINX_DIR/retire.json" ]] || nginx_fail 'Nginx 已进入退役，不能重新登记证书'
# 1. 注册 ZeroSSL 账户；DNS 凭据只交给首次签发子进程。
GATEWAY_ENV="$HOME/containers/gateway.env"
[[ -f "$GATEWAY_ENV" ]] || { printf '❌ 配置文件不存在: %s\n' "$GATEWAY_ENV" >&2; exit 1; }
nginx_owned "$GATEWAY_ENV" 'regular file'
source "$GATEWAY_ENV"
[[ -n "$EMAIL" ]] || { printf '❌ EMAIL 不能为空\n' >&2; exit 1; }
if [[ -e "$HOME/.acme.sh" || -L "$HOME/.acme.sh" ]]; then
    nginx_owned "$HOME/.acme.sh" directory
else mkdir -m 700 "$HOME/.acme.sh"; fi
had_acme_account=0
if [[ -e "$HOME/.acme.sh/account.conf" || -L "$HOME/.acme.sh/account.conf" ]]; then
    nginx_owned "$HOME/.acme.sh/account.conf" 'regular file'
    had_acme_account=1
fi
acme.sh --home "$HOME/.acme.sh" --register-account -m "$EMAIL" --server zerossl

# 2. 生成配置与证书；已有 account.conf 时直接使用 acme.sh 保存的凭据。
if (( had_acme_account )); then
    read -rp '本次签发需输入 DNS API 凭据？[y/N，回车使用已保存值；首次签发选 y]: ' replace_dns < /dev/tty
else
    replace_dns=y
fi
(
    if [[ "$replace_dns" =~ ^[Yy]$ ]]; then
        read -rsp 'Spaceship API Key: ' SPACESHIP_API_KEY < /dev/tty; printf '\n'
        read -rsp 'Spaceship API Secret: ' SPACESHIP_API_SECRET < /dev/tty; printf '\n'
        [[ -n "$SPACESHIP_API_KEY" && -n "$SPACESHIP_API_SECRET" ]] \
            || { printf 'DNS API 凭据不能为空\n' >&2; exit 1; }
        export SPACESHIP_API_KEY SPACESHIP_API_SECRET
    fi
    bash ~/containers/nginx/gen-conf.sh
)

# 3. 配置用户级自动续签 Timer（每周触发）
mkdir -p ~/.config/systemd/user/

nginx_install "$HOME/.config/systemd/user/acme-renew.service" 600 <<'EOF'
# Nginx ingress task v1
[Unit]
Description=Renew certificates via acme.sh

[Service]
Type=oneshot
UMask=0077
ExecStart=/usr/bin/env -i HOME=%h USER=ctrsvc LOGNAME=ctrsvc PATH=/usr/local/bin:/usr/bin XDG_RUNTIME_DIR=%t DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus /usr/bin/bash --noprofile --norc -c 'set -euo pipefail; source "$HOME/containers/nginx/manage.sh"; nginx_lock; exec /usr/bin/acme.sh --cron --home "$HOME/.acme.sh"'
EOF

nginx_install "$HOME/.config/systemd/user/acme-renew.timer" 600 <<'EOF'
# Nginx ingress task v1
[Unit]
Description=Weekly renewal timer for acme.sh

[Timer]
OnCalendar=weekly
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now acme-renew.timer
systemctl --user is-active --quiet acme-renew.timer
printf '✅ acme-renew.timer 用户级续签定时器已启动\n'
)
