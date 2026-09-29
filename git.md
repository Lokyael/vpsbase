# Git

Git 基础配置与 VPS 终端安全开发实践。

## 基础配置

### 1. 开启 GitHub 匿名邮箱

避免 `git log` 公开暴露真实个人邮箱。在 GitHub **Settings** → **Emails** 设置：
- 勾选 **Keep my email addresses private**（隐藏真实邮箱）；
- 勾选 **Block command line pushes that expose my email**（阻止命令行推送意外泄露真实邮箱）；
- 确认官方分配的专属匿名地址（通常为 `[ID]+[username]@users.noreply.github.com`）。

### 2. 跨平台全局配置

整段执行（兼容 Linux / Windows Git Bash）。交互式输入用户名与邮箱，支持自动推导 GitHub 匿名邮箱，统一 LF 换行与 UTF-8 编码：

```bash
(
GIT_USER=""
GIT_EMAIL=""

[[ -z "$GIT_USER" ]] && read -rp "GitHub 用户名: " GIT_USER < /dev/tty
[[ -n "$GIT_USER" ]] || { printf '❌ 用户名不能为空\n' >&2; exit 1; }

# 自动获取 GitHub ID 并推导官方匿名邮箱
AUTO_EMAIL=""
if command -v curl >/dev/null 2>&1; then
    USER_ID=$(curl -s --connect-timeout 3 "https://api.github.com/users/$GIT_USER" 2>/dev/null | sed -n 's/^[[:space:]]*"id":[[:space:]]*\([0-9]\+\),.*/\1/p' || true)
    [[ -n "$USER_ID" ]] && AUTO_EMAIL="${USER_ID}+${GIT_USER}@users.noreply.github.com"
fi

if [[ -z "$GIT_EMAIL" ]]; then
    if [[ -n "$AUTO_EMAIL" ]]; then
        printf '\n选择提交邮箱：\n'
        printf '  1) 自动使用 GitHub 匿名邮箱 (%s) [默认]\n' "$AUTO_EMAIL"
        printf '  2) 手动输入自定义邮箱\n'
        read -rp "请选择 [1-2, 默认 1]: " EMAIL_OPT < /dev/tty
        if [[ "${EMAIL_OPT:-1}" == "1" ]]; then
            GIT_EMAIL="$AUTO_EMAIL"
        else
            read -rp "请输入自定义邮箱: " GIT_EMAIL < /dev/tty
        fi
    else
        read -rp "请输入 Git 邮箱 (如 [ID]+${GIT_USER}@users.noreply.github.com): " GIT_EMAIL < /dev/tty
    fi
fi
[[ -n "$GIT_EMAIL" ]] || { printf '❌ 邮箱不能为空\n' >&2; exit 1; }

# 用户信息与默认分支
git config --global user.name "$GIT_USER"
git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch main

# 编辑器（检测 micro 编辑器，未安装则保持系统默认）
command -v micro >/dev/null 2>&1 && git config --global core.editor micro

# 跨平台全端统一换行符（LF）
git config --global core.autocrlf input
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

专仓专用 Deploy Key + GitHub 服务端规则集防破坏。多仓库重复执行各自绑定。

### 1. 仓库初始化与绑定

整段执行，支持交互确认存放目录（默认当前工作目录）、生成专属密钥、输出公钥、克隆并局部绑定：

```bash
(
set -euo pipefail

USER=""
REPO=""
DIR=""

[[ -z "$USER" ]] && read -rp "GitHub 用户名: " USER < /dev/tty
[[ -z "$REPO" ]] && read -rp "仓库名称: " REPO < /dev/tty
[[ -z "$DIR" ]] && read -rp "本地存放目录 [默认 $PWD]: " DIR < /dev/tty

[[ -n "$USER" && -n "$REPO" ]] || { printf '❌ 用户名与仓库名均不能为空\n' >&2; exit 1; }

DIR="${DIR:-$PWD}"
DIR="${DIR/#\~/$HOME}"
mkdir -p "$DIR"
BASE_DIR="$(cd "$DIR" && pwd)"
REPO_DIR="${BASE_DIR%/}/$REPO"

if [[ "$BASE_DIR" == "/" ]]; then
    printf '⚠️  目标存放路径位于根目录 (/)\n' >&2
    read -rp "确认直接在根目录下创建？[y/N]: " ROOT_CONFIRM < /dev/tty
    [[ "$ROOT_CONFIRM" =~ ^[yY]$ ]] || { printf '已取消，请重新运行并指定合理存放目录\n'; exit 1; }
fi

printf '   目标仓库路径: %s\n' "$REPO_DIR"

KEY="$HOME/.ssh/$REPO"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
[[ -f "$KEY" ]] || ssh-keygen -t ed25519 -f "$KEY" -C "deploy_$REPO" -N "" >/dev/null

printf '\n添加到 GitHub 仓库 Settings -> Deploy keys (勾选 Allow write access):\n\n'
cat "${KEY}.pub"
printf '\n'

read -rp "已在 GitHub 添加该公钥？[y/N]: " READY < /dev/tty
[[ "$READY" =~ ^[yY]$ ]] || { printf '已取消\n'; exit 0; }

SSH_CMD="ssh -i ~/.ssh/${REPO} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -F none"

if [[ ! -d "$REPO_DIR" ]]; then
    GIT_SSH_COMMAND="$SSH_CMD" git clone "git@github.com:${USER}/${REPO}.git" "$REPO_DIR"
fi

cd "$REPO_DIR"
git config core.sshCommand "$SSH_CMD"
printf '✅ 仓库 %s 初始化并绑定专属密钥成功\n' "$REPO"
)
```

### 2. GitHub 分支保护

在仓库 **Settings** → **Rules** → **Rulesets** 对 `main` 分支开启：
- **Block force pushes**：禁止强推（防 `push -f` 覆盖历史）。
- **Block deletions**：禁止删除分支。
- **Require a pull request before merging**：合并须经 PR（禁止直接 push 主分支）。

### 3. 日常开发推送

在开发分支工作，验证后在 GitHub 网页提 PR 合并至 `main`：

```bash
git checkout -b dev
git add .
git commit -m "[HERE_MSG]"
git push -u origin dev
```

### 4. 抹平重置提交历史

使用孤儿分支剥离全部历史并重建为单一干净根提交，保留现有 Remote 与 SSH 局部配置：

```bash
(
git checkout --orphan temp_branch
git add -A
git commit -m "[HERE_MSG]"
git branch -D main
git branch -m main
git branch -u origin/main main
git reflog expire --expire=now --all && git gc --prune=now
)
```

强制覆盖远端仓库主分支：

```bash
git push -f origin main
```

