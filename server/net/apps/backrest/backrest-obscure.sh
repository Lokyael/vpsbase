(
set -euo pipefail
IFS= read -r -s -p '应用密码: ' PASSWORD < /dev/tty || exit 1
printf '\n'
[[ -n "$PASSWORD" ]] || { printf '应用密码不能为空\n' >&2; exit 1; }
printf '%s\n' "$PASSWORD" | rclone obscure -
)
