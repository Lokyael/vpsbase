# Rootless Podman 业务底座

适用 Arch Linux x86-64 / systemd。由运维用户准备非 sudo 业务账户 `ctrsvc` 并安装持久化入口；业务 Shell 不接收运维凭据或管理 socket。

## 首次准备

### 1. 初始化底座与入口 `[运维用户]`

保留当前 SSH 会话；同名用户、组或 HOME 存在冲突时阻断。脚本安装依赖包、创建 `ctrsvc`（首次交互确认）、自动核验无 sudo 授权、启用 linger 与用户管理器，并落盘 `/usr/local/bin/ctrsvc-check` 与 `/usr/local/bin/ctrsvc-shell`：

```bash
script=$(mktemp "${TMPDIR:-/tmp}/podman-init.XXXXXX")
trap 'rm -f -- "$script"' EXIT
curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/net/podman/podman-init.sh -o "$script"
bash "$script"
```

### 2. 启用开机恢复 `[ctrsvc Shell]`

进入下方业务 Shell 后执行，启用作用于整个 `ctrsvc` 账户的 `podman-restart.service`（停用单个应用勿停止此单元）：

```bash
script=$(mktemp "${TMPDIR:-/tmp}/podman-autostart.XXXXXX")
trap 'rm -f -- "$script"' EXIT
curl -fL --progress-bar https://raw.githubusercontent.com/Lokyael/vpsbase/main/server/net/podman/podman-autostart.sh -o "$script"
bash "$script"
```

## 进入业务管理 Shell

`[运维用户]` 容器操作统一在此执行，不使用 `sudo podman` 或 `sudo -iu ctrsvc`；执行 `exit` 返回运维 Shell：

```bash
ctrsvc-shell
```

## 查看容器日志（通用）

Rootless 容器使用默认 `journald` 日志驱动时，在业务 Shell 的 `podman logs` 可能为空；按两步查询：

```bash
# 1. [ctrsvc Shell] 获取目标容器完整 ID（如 nginx / vaultwarden）
podman container inspect [HERE_CONTAINER] | jq -er '.[0].Id'

# 2. [运维用户] 查看该容器标准输出与错误日志
sudo journalctl --system --no-pager -o cat 'CONTAINER_ID_FULL=[HERE_CONTAINER_ID]'
```

> 引用本地交付脚本来源：[`podman-init.sh`](podman-init.sh)、[`podman-autostart.sh`](podman-autostart.sh)。
