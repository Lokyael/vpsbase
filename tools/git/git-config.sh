#!/usr/bin/env bash
# 跨平台 Git 全局配置脚本（GitHub 匿名邮箱推导、LF 与 UTF-8 基线）。
set -Eeuo pipefail

show_help() {
    cat <<'EOF'
用法: bash tools/git/git-config.sh [-h|--help]
交互配置全局 Git 用户名、提交邮箱（支持查询 GitHub API 自动推导匿名邮箱）、换行与编码基线。
  -h, --help  显示帮助

Linux / Git Bash:
  curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/git/git-config.sh | bash
Windows pwsh:
  sh.exe -c "curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/git/git-config.sh | bash"
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        *) printf '✘ 未知参数: %s\n' "$1" >&2; exit 1 ;;
    esac
done

command -v git >/dev/null 2>&1 || { printf '✘ 缺少依赖: git\n' >&2; exit 1; }

CURRENT_USER=$(git config --global user.name 2>/dev/null || true)
CURRENT_EMAIL=$(git config --global user.email 2>/dev/null || true)

read -rp "GitHub 用户名${CURRENT_USER:+ [默认 $CURRENT_USER]}: " GIT_USER < /dev/tty || { printf '✘ 无法读取用户名，输入已取消或终端不可用\n' >&2; exit 1; }
GIT_USER="${GIT_USER:-$CURRENT_USER}"
[[ -n "$GIT_USER" ]] || { printf '✘ 用户名不能为空\n' >&2; exit 1; }

AUTO_EMAIL=""
if [[ -z "$CURRENT_EMAIL" ]] && command -v curl >/dev/null 2>&1; then
    USER_ID=$(curl -s --connect-timeout 3 -m 3 "https://api.github.com/users/$GIT_USER" 2>/dev/null | sed -n 's/^[[:space:]]*"id":[[:space:]]*\([0-9]\+\),.*/\1/p' || true)
    [[ -n "$USER_ID" ]] && AUTO_EMAIL="${USER_ID}+${GIT_USER}@users.noreply.github.com"
fi

DEFAULT_EMAIL="${CURRENT_EMAIL:-$AUTO_EMAIL}"
if [[ -n "$DEFAULT_EMAIL" ]]; then
    read -rp "提交邮箱 [默认 $DEFAULT_EMAIL]: " GIT_EMAIL < /dev/tty || { printf '✘ 无法读取邮箱，输入已取消或终端不可用\n' >&2; exit 1; }
    GIT_EMAIL="${GIT_EMAIL:-$DEFAULT_EMAIL}"
else
    read -rp "请输入 Git 提交邮箱: " GIT_EMAIL < /dev/tty || { printf '✘ 无法读取邮箱，输入已取消或终端不可用\n' >&2; exit 1; }
fi
[[ -n "$GIT_EMAIL" ]] || { printf '✘ 邮箱不能为空\n' >&2; exit 1; }

git config --global user.name "$GIT_USER"
git config --global user.email "$GIT_EMAIL"

git config --global init.defaultBranch main
git config --global push.autoSetupRemote true
git config --global pull.rebase false
git config --global fetch.prune true

git config --global core.autocrlf false
git config --global core.eol lf
git config --global core.safecrlf warn

git config --global core.quotepath false
git config --global i18n.commitEncoding utf-8
git config --global i18n.logOutputEncoding utf-8

git config --global --list
