(
set -euo pipefail
umask 077
ctrsvc-check
export LC_ALL=C
ENV_FILE="$HOME/containers/gateway.env"
gateway_scope() {
    local path kind
    for path in "$HOME/containers" "$ENV_FILE"; do
        [[ $(realpath -m -- "$path") == "$path" ]] || { printf '网关路径含重定向: %s\n' "$path" >&2; exit 1; }
        if [[ -e "$path" || -L "$path" ]]; then
            kind=directory
            [[ "$path" != "$ENV_FILE" ]] || kind='regular file'
            [[ ! -L "$path" && $(stat -c '%F:%u' "$path") == "$kind:$(id -u)" ]] \
                || { printf '网关路径归属或类型不匹配: %s\n' "$path" >&2; exit 1; }
            [[ "$kind" != 'regular file' || $(stat -c %h "$path") == 1 ]] || exit 1
        fi
    done
}
gateway_scope
had_env=0
old_hash=''
DOMAIN=""
EMAIL=""

OLD_DOMAIN=""
OLD_EMAIL=""
SERVICES=()

# 1. 若已有配置，先读取展示旧值并询问是否修改
if [[ -f "$ENV_FILE" ]]; then
    had_env=1
    old_hash=$(sha256sum -- "$ENV_FILE")
    if ! source "$ENV_FILE"; then
        printf '❌ 无法读取配置文件: %s\n' "$ENV_FILE" >&2
        exit 1
    fi
    OLD_DOMAIN="$DOMAIN"
    OLD_EMAIL="$EMAIL"

    printf '\n📄 检测到已有配置 (%s)：\n' "$ENV_FILE"
    printf '   主域名 (DOMAIN)             : %s\n' "${OLD_DOMAIN:-未设置}"
    printf '   联系邮箱 (EMAIL)            : %s\n' "${OLD_EMAIL:-未设置}"

    read -rp "是否需要修改上述变量？[y/N]: " MODIFY < /dev/tty
    if [[ ! "$MODIFY" =~ ^[Yy]$ ]]; then
        printf '✅ 保持现有配置不变\n'
        exit 0
    fi
fi

# 计算输入提示与回退默认值
curr_d="${OLD_DOMAIN:-}"
[[ -n "$DOMAIN" ]] && curr_d="$DOMAIN"

curr_e="${OLD_EMAIL:-}"
[[ -n "$EMAIL" ]] && curr_e="$EMAIL"

# 2. 交互输入（直接回车即保留原值不变）
read -rp "主域名 (DOMAIN)${curr_d:+ [当前: $curr_d, 回车保持]}: " input_domain < /dev/tty
DOMAIN="${input_domain:-$curr_d}"

read -rp "联系邮箱 (EMAIL)${curr_e:+ [当前: $curr_e, 回车保持]}: " input_email < /dev/tty
EMAIL="${input_email:-$curr_e}"

# 3. 基础校验
[[ -z "$DOMAIN" ]] && { printf '❌ 主域名不能为空\n' >&2; exit 1; }
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
    || { printf '❌ 主域名格式不正确: %s\n' "$DOMAIN" >&2; exit 1; }
[[ -z "$EMAIL" ]] && { printf '❌ 联系邮箱不能为空\n' >&2; exit 1; }

# 若已有 SERVICES 配置则保留，否则使用默认服务清单
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  SERVICES=(
    "bak 9898 any"
    "vw 8088 any"
  )
fi

# 4. 确认及输入校验后才写入；重查同一已读取内容，原子发布完整配置。
gateway_scope
if (( had_env )); then
    [[ $(sha256sum -- "$ENV_FILE") == "$old_hash" ]] || { printf '交互期间网关配置已变化，请重试\n' >&2; exit 1; }
else
    [[ ! -e "$ENV_FILE" && ! -L "$ENV_FILE" ]] || { printf '交互期间出现新的网关配置\n' >&2; exit 1; }
fi
if [[ ! -d "$HOME/containers" ]]; then mkdir -m 700 "$HOME/containers"; fi
work=$(mktemp "$HOME/containers/.gateway.env.XXXXXX")
trap 'rm -f -- "$work"' EXIT
printf -v DOMAIN_Q '%q' "$DOMAIN"
printf -v EMAIL_Q '%q' "$EMAIL"
{
    printf 'DOMAIN=%s\n' "$DOMAIN_Q"
    printf 'EMAIL=%s\n' "$EMAIL_Q"
    printf '\n# 服务列表格式："子域名 内部监听端口 白名单(多IP逗号分隔，不限制填 any)"\nSERVICES=(\n'
    printf '  %q\n' "${SERVICES[@]}"
    printf ')\n'
} > "$work"
chmod 600 "$work"
mv -T -- "$work" "$ENV_FILE"
printf '✅ %s 配置已就绪\n' "$ENV_FILE"
)
