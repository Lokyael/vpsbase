#!/usr/bin/env bash
# GitHub 仓库初始化与 SSH Deploy Key 绑定脚本（Linux 终端开发）。
set -Eeuo pipefail

show_help() {
    cat <<'EOF'
用法: bash tools/git/git-deploy.sh [-h|--help]
交互绑定 ~/.ssh/<REPO> Deploy Key、设置仓库 core.sshCommand 并克隆或拉取同步。
  -h, --help  显示帮助

Linux:
  curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/git/git-deploy.sh | bash
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        *) printf '✘ 未知参数: %s\n' "$1" >&2; exit 1 ;;
    esac
done

for tool in git ssh ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || { printf '✘ 缺少依赖: %s\n' "$tool" >&2; exit 1; }
done

DEFAULT_USER=$(git config --global user.name 2>/dev/null || true)
read -rp "GitHub 用户名${DEFAULT_USER:+ [默认 $DEFAULT_USER]}: " USER < /dev/tty || { printf '✘ 无法读取用户名，输入已取消或终端不可用\n' >&2; exit 1; }
USER="${USER:-$DEFAULT_USER}"
read -rp "仓库名称: " REPO < /dev/tty || { printf '✘ 无法读取仓库名称，输入已取消或终端不可用\n' >&2; exit 1; }
[[ -n "$USER" && -n "$REPO" ]] || { printf '✘ 用户名与仓库名均不能为空\n' >&2; exit 1; }

[[ "$(basename "$PWD")" == "$REPO" ]] && DEFAULT_DIR="$PWD" || DEFAULT_DIR="${PWD%/}/$REPO"
read -rp "仓库最终路径 [默认 $DEFAULT_DIR]: " REPO_DIR < /dev/tty || { printf '✘ 无法读取仓库路径，输入已取消或终端不可用\n' >&2; exit 1; }
REPO_DIR="${REPO_DIR:-$DEFAULT_DIR}"
REPO_DIR="${REPO_DIR/#\~/$HOME}"
[[ -d "$REPO_DIR" && ! -d "$REPO_DIR/.git" && -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]] && REPO_DIR="${REPO_DIR%/}/$REPO"
printf '   最终路径: %s\n' "$REPO_DIR"

KEY="$HOME/.ssh/$REPO"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

USE_EXISTING=false
if [[ -f "$KEY" ]]; then
    read -rp "检测到已有密钥 $KEY，直接复用？[Y/n]: " REUSE_KEY < /dev/tty || { printf '✘ 输入已取消或终端不可用\n' >&2; exit 1; }
    [[ "${REUSE_KEY:-y}" =~ ^[yY]$ ]] && USE_EXISTING=true
fi

if [[ "$USE_EXISTING" == "false" ]]; then
    read -rp "已有私钥文件路径 [回车自动生成新密钥]: " KEY_SRC < /dev/tty || { printf '✘ 输入已取消或终端不可用\n' >&2; exit 1; }
    if [[ -n "$KEY_SRC" ]]; then
        KEY_SRC="${KEY_SRC/#\~/$HOME}"
        [[ -f "$KEY_SRC" ]] || { printf '✘ 找不到私钥文件: %s\n' "$KEY_SRC" >&2; exit 1; }
        [[ "$KEY_SRC" -ef "$KEY" ]] || (umask 077 && cp -f "$KEY_SRC" "$KEY")
        rm -f "${KEY}.pub"
    else
        rm -f "$KEY" "${KEY}.pub"
        ssh-keygen -t ed25519 -f "$KEY" -C "deploy_$REPO" -N "" >/dev/null
        printf '\nGitHub 仓库 Settings -> Deploy keys 公钥 (需写权限则勾选 Allow write access):\n\n'
        cat "${KEY}.pub"
        printf '\n'
        read -rp "已在 GitHub 添加该公钥？[y/N]: " READY < /dev/tty || { printf '✘ 输入已取消或终端不可用\n' >&2; exit 1; }
        [[ "$READY" =~ ^[yY]$ ]] || { printf '已取消\n'; exit 0; }
    fi
fi

chmod 600 "$KEY"
[[ -s "${KEY}.pub" ]] || ssh-keygen -y -f "$KEY" > "${KEY}.pub"

SSH_CMD="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -F none"

if [[ ! -d "$REPO_DIR/.git" ]]; then
    GIT_SSH_COMMAND="$SSH_CMD" git clone "git@github.com:${USER}/${REPO}.git" "$REPO_DIR"
    cd "$REPO_DIR"
    git config core.sshCommand "$SSH_CMD"
else
    cd "$REPO_DIR"
    git config core.sshCommand "$SSH_CMD"
    git pull
fi

printf '✔ 仓库 %s 绑定并同步成功（%s）\n' "$REPO" "$REPO_DIR"
