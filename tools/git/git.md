# Git

跨平台 Git 基础配置、VPS 专用 Deploy Key 绑定与常用分支操作。

## 基础配置

### 1. 开启 GitHub 匿名邮箱

在 GitHub **Settings** → **Emails** 开启：
- **Keep my email addresses private**；
- **Block command line pushes that expose my email**；
- 记下匿名邮箱（`[ID]+[username]@users.noreply.github.com`）。

### 2. 跨平台全局配置

交互配置 `user.name`、`user.email`（支持按 GitHub 用户名自动推导匿名邮箱）、锁定 LF 与 UTF-8 并开启自动追踪推送：

- **Linux `[bash]`**：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/git/git-config.sh | bash
  ```
- **Windows `[pwsh]`**：
  ```powershell
  sh.exe -c "curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/git/git-config.sh | bash"
  ```

## VPS 终端开发

### 1. 仓库初始化与 Deploy Key 绑定 `[Linux]`

交互生成或复用 `~/.ssh/<REPO>` Deploy Key，设置仓库 `core.sshCommand` 并完成克隆或拉取同步：

```bash
curl -fsSL https://raw.githubusercontent.com/Lokyael/vpsbase/main/tools/git/git-deploy.sh | bash
```

### 2. GitHub 分支保护

在 **Settings** → **Rules** → **Rulesets** 对 `main` 开启：**Block force pushes**、**Block deletions**、**Require a pull request before merging**。

### 3. 日常推送与重置历史

```bash
# 分支开发并推送 PR
git checkout -b dev
git add .
git commit -m "[HERE_MSG]"
git push
```

```bash
# 孤儿分支抹平历史为单根提交
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
