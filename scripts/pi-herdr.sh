#!/usr/bin/env bash
#
# scripts/pi-herdr.sh
# herdr 智能体运行时部署与检查脚本
#

set -Eeuo pipefail

MODE="deploy"

show_help() {
    cat <<'EOF'
用法:
  bash scripts/pi-herdr.sh [选项]

功能模式:
  (无参数，默认)              检查并安装 herdr
  --status                    查看 herdr 当前 Agent 状态
  -h, --help                  显示帮助信息
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)
            MODE="status"
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

if [ "$MODE" = "status" ]; then
    command -v herdr >/dev/null 2>&1 || {
        printf '❌ 未检测到 herdr，请先执行本脚本完成安装\n' >&2
        exit 1
    }
    herdr agent list
    exit 0
fi

command -v paru >/dev/null 2>&1 || {
    printf '❌ 未检测到 paru，请先完成 Arch 基础选配\n' >&2
    exit 1
}

if ! command -v herdr >/dev/null 2>&1; then
    printf '📦 通过 AUR 安装 herdr-bin...\n'
    paru -S --needed --noconfirm --skipreview herdr-bin
fi

printf '✅ herdr 运行环境就绪: %s\n' "$(herdr --version 2>/dev/null || printf '已安装')"
printf '💡 启动或连入会话: herdr\n'
