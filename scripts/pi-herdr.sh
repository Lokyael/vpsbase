#!/usr/bin/env bash
#
# scripts/pi-herdr.sh
# herdr 智能体运行时部署与自建 ntfy 状态监控 (选配) 交互式配置脚本
#

set -Eeuo pipefail

CONFIG_DIR="${HOME}/.config/herdr-ntfy"
ENV_FILE="${CONFIG_DIR}/herdr-ntfy.env"
WATCHER_BIN="${HOME}/.local/bin/herdr-ntfy-watcher"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SYSTEMD_USER_DIR}/herdr-ntfy.service"

MODE="deploy" # deploy | config-ntfy | status | uninstall
NON_INTERACTIVE=0
SKIP_NTFY=0
FORCE_NTFY=0

CLI_SERVER=""
CLI_TOPIC=""
CLI_TOKEN=""

show_help() {
    cat <<'EOF'
用法:
  bash scripts/pi-herdr.sh [选项]

功能模式:
  (无参数，默认)              检查环境并安装 herdr，可选配置自建 ntfy 状态通知
  --config-ntfy               仅配置或更新自建 ntfy 状态监控服务
  --skip-ntfy                 仅安装与检查 herdr，跳过 ntfy 配置
  --status                    查看 herdr-ntfy 守护服务当前运行状态
  --uninstall                 停止并清理 herdr-ntfy 监控服务及配置

选配 ntfy 参数 (非交互或命令行指定):
  -s, --server <url>          自建 ntfy 服务地址 (例如 https://ntfy.example.com)
  -t, --topic <topic>         订阅 Topic 主题 (例如 pi-alerts)
  -k, --token <token>         访问凭证 Token (私有实例带鉴权时配置，无认证可留空)

通用选项:
  -y, --non-interactive       非交互模式 (自动复用已有配置或安全默认值)
  -h, --help                  显示本帮助信息
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-ntfy)
            MODE="config-ntfy"
            FORCE_NTFY=1
            shift
            ;;
        --skip-ntfy|--without-ntfy)
            SKIP_NTFY=1
            shift
            ;;
        --status)
            MODE="status"
            shift
            ;;
        --uninstall)
            MODE="uninstall"
            shift
            ;;
        -s|--server)
            CLI_SERVER="${2:-}"
            FORCE_NTFY=1
            shift 2
            ;;
        -t|--topic)
            CLI_TOPIC="${2:-}"
            FORCE_NTFY=1
            shift 2
            ;;
        -k|--token)
            CLI_TOKEN="${2:-}"
            FORCE_NTFY=1
            shift 2
            ;;
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            printf '❌ 未知参数: %s\n' "$1" >&2
            show_help
            exit 1
            ;;
    esac
done

mask_secret() {
    local s="$1"
    local len=${#s}
    if [ "$len" -eq 0 ]; then
        printf '未配置'
    elif [ "$len" -le 8 ]; then
        printf '******'
    else
        printf '%s***%s' "${s:0:3}" "${s: -4}"
    fi
}

# ========================================================
# 模式分支：状态查看与卸载
# ========================================================

if [ "$MODE" = "status" ]; then
    printf '🔍 正在检查 herdr-ntfy 守护服务状态:\n\n'
    systemctl --user status herdr-ntfy.service --no-pager || true
    exit 0
fi

if [ "$MODE" = "uninstall" ]; then
    printf '🗑️  开始清理 herdr-ntfy 监控服务...\n'
    systemctl --user disable --now herdr-ntfy.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -f "$WATCHER_BIN"
    systemctl --user daemon-reload 2>/dev/null || true
    printf '✅ 服务与监视脚本已移除。\n'

    if [ -d "$CONFIG_DIR" ]; then
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            rm -rf "$CONFIG_DIR"
            printf '🧹 已清理配置文件目录: %s\n' "$CONFIG_DIR"
        else
            read -rp "是否清理配置文件目录 ($CONFIG_DIR)? [y/N] " RM_CONF < /dev/tty || true
            if [[ "$RM_CONF" =~ ^[Yy]$ ]]; then
                rm -rf "$CONFIG_DIR"
                printf '🧹 已清理配置文件目录: %s\n' "$CONFIG_DIR"
            fi
        fi
    fi
    exit 0
fi

# ========================================================
# 阶段一：基础运行环境与依赖检查 (paru & herdr)
# ========================================================

command -v paru >/dev/null 2>&1 || { printf '❌ 未检测到 paru，请先完成 Arch 基础选配\n' >&2; exit 1; }

if ! command -v herdr >/dev/null 2>&1; then
    printf '📦 通过 AUR 安装 herdr-bin...\n'
    paru -S --needed --noconfirm --skipreview herdr-bin
fi

printf '✅ herdr 运行环境就绪: %s\n' "$(herdr --version 2>/dev/null || printf '已安装')"

# ========================================================
# 阶段二：读取已有配置与判断是否配置 ntfy (选配)
# ========================================================

OLD_SERVER=""
OLD_TOPIC=""
OLD_TOKEN=""
HAS_OLD_CONFIG=0

if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value || [ -n "$key" ]; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
        case "$key" in
            NTFY_SERVER) OLD_SERVER="$value" ;;
            NTFY_TOPIC)  OLD_TOPIC="$value" ;;
            NTFY_TOKEN)  OLD_TOKEN="$value" ;;
        esac
    done < "$ENV_FILE"
    if [ -n "$OLD_SERVER" ] && [ -n "$OLD_TOPIC" ]; then
        HAS_OLD_CONFIG=1
    fi
fi

ENABLE_NTFY=0

if [ "$SKIP_NTFY" -eq 1 ]; then
    ENABLE_NTFY=0
elif [ "$FORCE_NTFY" -eq 1 ] || [ "$MODE" = "config-ntfy" ]; then
    ENABLE_NTFY=1
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    # 非交互模式下：如有已有配置则自动启用，否则默认跳过
    if [ "$HAS_OLD_CONFIG" -eq 1 ]; then
        ENABLE_NTFY=1
    else
        ENABLE_NTFY=0
    fi
else
    # 交互模式：向用户询问是否配置选配的 ntfy 状态监控
    printf '\n'
    if [ "$HAS_OLD_CONFIG" -eq 1 ]; then
        printf '📡 检测到已有 ntfy 推送配置 (%s / %s)\n' "$OLD_SERVER" "$OLD_TOPIC"
        read -rp "是否配置/更新自建 ntfy 状态通知服务? [Y/n] " PROMPT_NTFY < /dev/tty || true
        if [[ ! "$PROMPT_NTFY" =~ ^[Nn]$ ]]; then
            ENABLE_NTFY=1
        fi
    else
        read -rp "是否配置自建 ntfy 状态通知服务 (选配: 长任务阻塞与完成推送)? [y/N] " PROMPT_NTFY < /dev/tty || true
        if [[ "$PROMPT_NTFY" =~ ^[Yy]$ ]]; then
            ENABLE_NTFY=1
        fi
    fi
fi

if [ "$ENABLE_NTFY" -eq 0 ]; then
    printf '⏩ 已跳过 ntfy 配置。herdr 已就绪 (输入 herdr 启动)。\n'
    exit 0
fi

# ========================================================
# 阶段三：配置自建 ntfy 参数与依赖 (jq)
# ========================================================

if ! command -v jq >/dev/null 2>&1; then
    printf '📦 安装监控解析依赖 jq...\n'
    paru -S --needed --noconfirm --skipreview jq
fi

FINAL_SERVER=""
FINAL_TOPIC=""
FINAL_TOKEN=""

if [ "$NON_INTERACTIVE" -eq 1 ]; then
    FINAL_SERVER="${CLI_SERVER:-$OLD_SERVER}"
    FINAL_TOPIC="${CLI_TOPIC:-$OLD_TOPIC}"
    FINAL_TOKEN="${CLI_TOKEN:-$OLD_TOKEN}"

    if [ -z "$FINAL_SERVER" ] || [ -z "$FINAL_TOPIC" ]; then
        printf '❌ 非交互配置 ntfy 必须指定或存在已有 --server 与 --topic 参数\n' >&2
        exit 1
    fi
else
    printf '\n🔧 配置自建 ntfy 推送端点 (回车保留中括号内当前值):\n'

    # 1. Server URL
    while true; do
        if [ -n "$OLD_SERVER" ]; then
            read -rp "自建 ntfy 地址 [当前: $OLD_SERVER]: " INPUT_SERVER < /dev/tty || true
            FINAL_SERVER="${INPUT_SERVER:-$OLD_SERVER}"
        else
            read -rp "自建 ntfy 地址 (例: https://ntfy.example.com): " FINAL_SERVER < /dev/tty || true
        fi
        FINAL_SERVER=$(echo "$FINAL_SERVER" | xargs | sed 's:/*$::')
        if [[ "$FINAL_SERVER" =~ ^https?:// ]]; then
            break
        fi
        printf '⚠️  地址格式无效，必须以 http:// 或 https:// 开头，请重新输入。\n'
    done

    # 2. Topic
    while true; do
        if [ -n "$OLD_TOPIC" ]; then
            read -rp "订阅 Topic 名称 [当前: $OLD_TOPIC]: " INPUT_TOPIC < /dev/tty || true
            FINAL_TOPIC="${INPUT_TOPIC:-$OLD_TOPIC}"
        else
            read -rp "订阅 Topic 名称 (例: pi-alerts): " FINAL_TOPIC < /dev/tty || true
        fi
        FINAL_TOPIC=$(echo "$FINAL_TOPIC" | xargs)
        if [ -n "$FINAL_TOPIC" ]; then
            break
        fi
        printf '⚠️  Topic 不能为空，请重新输入。\n'
    done

    # 3. Token
    if [ -n "$OLD_TOKEN" ]; then
        read -rp "访问 Token [当前: $(mask_secret "$OLD_TOKEN")，输入 none 清空]: " INPUT_TOKEN < /dev/tty || true
        INPUT_TOKEN=$(echo "$INPUT_TOKEN" | xargs)
        if [ "$INPUT_TOKEN" = "none" ] || [ "$INPUT_TOKEN" = "clear" ]; then
            FINAL_TOKEN=""
        elif [ -n "$INPUT_TOKEN" ]; then
            FINAL_TOKEN="$INPUT_TOKEN"
        else
            FINAL_TOKEN="$OLD_TOKEN"
        fi
    else
        read -rp "访问 Token (可选，无认证直接回车): " INPUT_TOKEN < /dev/tty || true
        FINAL_TOKEN=$(echo "$INPUT_TOKEN" | xargs)
    fi

    # 4. 汇总确认
    printf '\n📋 配置确认:\n'
    printf '  - 服务器: %s\n' "$FINAL_SERVER"
    printf '  - 主题:   %s\n' "$FINAL_TOPIC"
    printf '  - 凭据:   %s\n' "$(mask_secret "$FINAL_TOKEN")"

    read -rp "确认应用此配置并部署守护服务? [Y/n] " CONFIRM < /dev/tty || true
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        printf '🚫 操作已取消。\n'
        exit 0
    fi
fi

# ========================================================
# 阶段四：落地配置文件与守护脚本
# ========================================================

mkdir -p "$CONFIG_DIR"
cat << EOF > "$ENV_FILE"
# herdr-ntfy 环境变量配置
NTFY_SERVER="${FINAL_SERVER}"
NTFY_TOPIC="${FINAL_TOPIC}"
NTFY_TOKEN="${FINAL_TOKEN}"
EOF
chmod 600 "$ENV_FILE"

mkdir -p "$(dirname "$WATCHER_BIN")"
cat << 'EOF' > "$WATCHER_BIN"
#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

NTFY_SERVER="${NTFY_SERVER:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"

if [ -z "$NTFY_SERVER" ] || [ -z "$NTFY_TOPIC" ]; then
    echo "❌ 缺少必要环境变量: NTFY_SERVER 或 NTFY_TOPIC" >&2
    exit 1
fi

declare -A LAST_STATUS
INITIALIZED=0

while true; do
    raw_json=$(herdr agent list 2>/dev/null || true)
    if [ -z "$raw_json" ]; then
        sleep 3
        continue
    fi

    while IFS=$'\t' read -r id name status; do
        [ -z "$id" ] && continue

        prev="${LAST_STATUS[$id]:-}"

        if [ "$INITIALIZED" -eq 1 ] && [ -n "$prev" ] && [ "$status" != "$prev" ]; then
            headers=(-H "Markdown: yes")
            [ -n "$NTFY_TOKEN" ] && headers+=(-H "Authorization: Bearer ${NTFY_TOKEN}")

            if [ "$status" = "blocked" ]; then
                snippet=$(herdr agent read "$id" --lines 6 2>/dev/null || true)
                curl -s "${headers[@]}" \
                    -H "Title: ⚠️ Agent [${name}] 等待确认 (Blocked)" \
                    -H "Priority: high" \
                    -H "Tags: warning,stop_sign" \
                    -d "任务处于挂起等待状态：
\`\`\`text
${snippet}
\`\`\`" \
                    "${NTFY_SERVER}/${NTFY_TOPIC}" >/dev/null 2>&1 || true

            elif [ "$status" = "done" ] && [ "$prev" = "working" ]; then
                snippet=$(herdr agent read "$id" --lines 6 2>/dev/null || true)
                curl -s "${headers[@]}" \
                    -H "Title: ✅ Agent [${name}] 执行完成" \
                    -H "Priority: default" \
                    -H "Tags: white_check_mark" \
                    -d "任务已结算：
\`\`\`text
${snippet}
\`\`\`" \
                    "${NTFY_SERVER}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
            fi
        fi

        LAST_STATUS[$id]="$status"
    done < <(echo "$raw_json" | jq -r '.data.agents[]? | "\(.terminal_id)\t\(.agent // .name // "agent")\t\(.agent_status)"' 2>/dev/null || true)

    INITIALIZED=1
    sleep 2
done
EOF
chmod 755 "$WATCHER_BIN"

# ========================================================
# 阶段五：注册并启动 systemd 用户服务
# ========================================================

mkdir -p "$SYSTEMD_USER_DIR"
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Herdr Agent State Watcher for Private ntfy
After=network.target

[Service]
Type=simple
EnvironmentFile=%h/.config/herdr-ntfy/herdr-ntfy.env
ExecStart=%h/.local/bin/herdr-ntfy-watcher
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now herdr-ntfy.service

printf '\n✅ herdr-ntfy 监控服务已就绪并启动。\n'
