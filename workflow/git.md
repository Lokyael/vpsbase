# Git

跨平台 Git 规范、凭据安全隔离与 VPS 终端安全开发实践。

## 基础配置

### 1. 开启 GitHub 匿名邮箱

在 GitHub **Settings** → **Emails** 开启：
- **Keep my email addresses private**：隐藏真实邮箱；
- **Block command line pushes that expose my email**：阻断真实邮箱命令行推送；
- 记下专属匿名邮箱地址（通常为 `[ID]+[username]@users.noreply.github.com`）。

### 2. 跨平台全局配置

终端执行（兼容 Linux / Windows Git Bash）。读取已有配置，推导 GitHub 匿名邮箱，统一 LF 与 UTF-8 编码，开启自动追踪推送：

```bash
(
set -euo pipefail

CURRENT_USER=$(git config --global user.name 2>/dev/null || true)
CURRENT_EMAIL=$(git config --global user.email 2>/dev/null || true)

read -rp "GitHub 用户名${CURRENT_USER:+ [默认 $CURRENT_USER]}: " GIT_USER < /dev/tty
GIT_USER="${GIT_USER:-$CURRENT_USER}"
[[ -n "$GIT_USER" ]] || { printf '❌ 用户名不能为空\n' >&2; exit 1; }

# 自动获取 GitHub ID 并推导官方匿名邮箱
AUTO_EMAIL=""
if command -v curl >/dev/null 2>&1; then
    USER_ID=$(curl -s --connect-timeout 3 "https://api.github.com/users/$GIT_USER" 2>/dev/null | sed -n 's/^[[:space:]]*"id":[[:space:]]*\([0-9]\+\),.*/\1/p' || true)
    [[ -n "$USER_ID" ]] && AUTO_EMAIL="${USER_ID}+${GIT_USER}@users.noreply.github.com"
fi

DEFAULT_EMAIL="${CURRENT_EMAIL:-$AUTO_EMAIL}"
if [[ -n "$DEFAULT_EMAIL" ]]; then
    read -rp "提交邮箱 [默认 $DEFAULT_EMAIL]: " GIT_EMAIL < /dev/tty
    GIT_EMAIL="${GIT_EMAIL:-$DEFAULT_EMAIL}"
else
    read -rp "请输入 Git 提交邮箱: " GIT_EMAIL < /dev/tty
fi
[[ -n "$GIT_EMAIL" ]] || { printf '❌ 邮箱不能为空\n' >&2; exit 1; }

# 用户信息、默认主分支与自动追踪推送
git config --global user.name "$GIT_USER"
git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch main
git config --global push.autoSetupRemote true
git config --global pull.rebase false
git config --global fetch.prune true

# 编辑器（检测 micro 编辑器，未安装则保持系统默认）
command -v micro >/dev/null 2>&1 && git config --global core.editor micro

# 跨平台全端统一换行符（LF Everywhere：不转换、零警告、全域纯 LF）
git config --global core.autocrlf false
git config --global core.eol lf
git config --global core.safecrlf warn

# 中文路径与 UTF-8 编码防乱码
git config --global core.quotepath false
git config --global i18n.commitencoding utf-8
git config --global i18n.logoutputencoding utf-8

git config --global --list
)
```

## VPS 终端开发

专仓专用 Deploy Key 隔离与服务端规则集防护。

### 1. 仓库初始化与绑定

终端执行。自适应路径防嵌套，生成或复用 Deploy Key 并绑定仓库：

```bash
(
set -euo pipefail

DEFAULT_USER=$(git config --global user.name 2>/dev/null || true)
read -rp "GitHub 用户名${DEFAULT_USER:+ [默认 $DEFAULT_USER]}: " USER < /dev/tty
USER="${USER:-$DEFAULT_USER}"
read -rp "仓库名称: " REPO < /dev/tty
[[ -n "$USER" && -n "$REPO" ]] || { printf '❌ 用户名与仓库名均不能为空\n' >&2; exit 1; }

# 智能推导默认路径：若当前已在同名目录内则直接使用 $PWD，避免套娃嵌套
[[ "$(basename "$PWD")" == "$REPO" ]] && DEFAULT_DIR="$PWD" || DEFAULT_DIR="${PWD%/}/$REPO"
read -rp "仓库最终路径 [默认 $DEFAULT_DIR]: " REPO_DIR < /dev/tty
REPO_DIR="${REPO_DIR:-$DEFAULT_DIR}"
REPO_DIR="${REPO_DIR/#\~/$HOME}"
# 若填入的是已存在的非空父目录（如 /opt），自动补齐子目录名
[[ -d "$REPO_DIR" && ! -d "$REPO_DIR/.git" && -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]] && REPO_DIR="${REPO_DIR%/}/$REPO"
printf '   最终路径: %s\n' "$REPO_DIR"

KEY="$HOME/.ssh/$REPO"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

USE_EXISTING=false
if [[ -f "$KEY" ]]; then
    read -rp "检测到已有密钥 $KEY，直接复用？[Y/n]: " REUSE_KEY < /dev/tty
    [[ "${REUSE_KEY:-y}" =~ ^[yY]$ ]] && USE_EXISTING=true
fi

if [[ "$USE_EXISTING" == "false" ]]; then
    read -rp "已有私钥文件路径 [回车自动生成新密钥]: " KEY_SRC < /dev/tty
    if [[ -n "$KEY_SRC" ]]; then
        KEY_SRC="${KEY_SRC/#\~/$HOME}"
        [[ -f "$KEY_SRC" ]] || { printf '❌ 找不到私钥文件: %s\n' "$KEY_SRC" >&2; exit 1; }
        [[ "$KEY_SRC" -ef "$KEY" ]] || (umask 077 && cp -f "$KEY_SRC" "$KEY")
        rm -f "${KEY}.pub"
    else
        rm -f "$KEY" "${KEY}.pub"
        ssh-keygen -t ed25519 -f "$KEY" -C "deploy_$REPO" -N "" >/dev/null
        printf '\nGitHub 仓库 Settings -> Deploy keys 公钥 (需写权限则勾选 Allow write access):\n\n'
        cat "${KEY}.pub"
        printf '\n'
        read -rp "已在 GitHub 添加该公钥？[y/N]: " READY < /dev/tty
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

printf '✅ 仓库 %s 绑定并同步成功（%s）\n' "$REPO" "$REPO_DIR"
)
```

### 2. GitHub 分支保护

在仓库 **Settings** → **Rules** → **Rulesets** 对 `main` 分支开启：
- **Block force pushes**：禁止强推（防 `push -f` 覆盖历史）。
- **Block deletions**：禁止删除分支。
- **Require a pull request before merging**：合并须经 PR（禁止直接 push 主分支）。

### 3. 日常开发推送

在开发分支工作并推送（已开启 `autoSetupRemote`），经 PR 合并至 `main`：

```bash
git checkout -b dev
git add .
git commit -m "[HERE_MSG]"
git push
```

### 4. 抹平重置提交历史

使用孤儿分支压平全部历史为单一干净根提交：

```bash
(
git branch -D temp_branch 2>/dev/null || true
git checkout --orphan temp_branch
git add -A
git commit -m "[HERE_MSG]"
git branch -D main
git branch -m main
git branch -u origin/main main
git reflog expire --expire=now --all && git gc --prune=now
)
git push -f origin main
```
