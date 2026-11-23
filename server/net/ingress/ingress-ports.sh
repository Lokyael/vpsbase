(
set -euo pipefail

file=/etc/sysctl.d/99-unprivileged-ports.conf
key=net.ipv4.ip_unprivileged_port_start
threshold=443
printf '%s=%s\n' "$key" "$threshold" | sudo tee "$file" > /dev/null
if ! sudo sysctl -w "$key=$threshold" > /dev/null; then
    printf '已写入 %s，但未能确认运行设置 %s=%s。\n' "$file" "$key" "$threshold" >&2
    exit 1
fi
if ! actual=$(sysctl -n "$key"); then
    printf '已写入 %s，但无法回读 %s 的运行值。\n' "$file" "$key" >&2
    exit 1
fi
[[ "$actual" == "$threshold" ]] || {
    printf '已写入 %s，但 %s 回读为 %q，预期 %s。\n' "$file" "$key" "$actual" "$threshold" >&2
    exit 1
}
printf '✅ 非特权端口参数已生效 (ip_unprivileged_port_start: %s)\n' "$actual"
)
