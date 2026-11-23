(
set -euo pipefail
business_uid=$(id -u ctrsvc)
sudo systemd-run --user --machine=ctrsvc@.host --wait --pipe --collect \
    --service-type=exec --expand-environment=no \
    /usr/bin/env -i HOME=/home/ctrsvc USER=ctrsvc LOGNAME=ctrsvc PATH=/usr/local/bin:/usr/bin \
    XDG_RUNTIME_DIR="/run/user/$business_uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$business_uid/bus" \
    /usr/bin/bash --noprofile --norc /home/ctrsvc/containers/nginx/manage.sh release-check
sudo /usr/bin/bash --noprofile --norc <<'ROOT'
set -euo pipefail
export LC_ALL=C
file=/etc/nftables.d/60-ingress.conf
if [[ -e "$file" || -L "$file" ]]; then
    [[ $(stat -c '%F:%u:%a:%h' "$file") == 'regular file:0:644:1' ]] || exit 1
    cmp -s "$file" <(cat <<'RULE'
# 单端口统一接入网关；自动封禁仅在 Web 请求路径处理
add rule inet filter services tcp dport 443 accept comment "Unified Ingress Gateway"
RULE
    ) || { printf 'Ingress 防火墙片段归属不匹配\n' >&2; exit 1; }
    rm -- "$file"
fi
nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
printf '所属入口已撤销；受控表运行态封禁已清空。\n'
ROOT
)
