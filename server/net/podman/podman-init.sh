#!/usr/bin/env bash
# Arch Linux 宿主 Rootless Podman 业务底座初始化脚本（运维用户执行）。
(
set -euo pipefail
export LC_ALL=C

fail() { printf '✘ %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -ne 0 ]] || fail '请以 sudo 运维用户执行'

passwd_rc=0
passwd_rec=$(getent passwd ctrsvc) || passwd_rc=$?
group_rc=0
group_rec=$(getent group ctrsvc) || group_rc=$?
home_exists=0
if [[ -e /home/ctrsvc || -L /home/ctrsvc ]]; then home_exists=1; fi

need_create=0
if [[ $passwd_rc -eq 2 && $group_rc -eq 2 && $home_exists -eq 0 ]]; then
    need_create=1
elif [[ $passwd_rc -eq 0 && $group_rc -eq 0 && $home_exists -eq 1 ]]; then
    IFS=: read -r p_name _ p_uid p_gid _ p_home p_shell <<< "$passwd_rec"
    IFS=: read -r g_name _ g_gid _ <<< "$group_rec"
    [[ "$p_name" == ctrsvc && "$g_name" == ctrsvc \
        && "$p_uid" =~ ^[1-9][0-9]*$ && "$p_gid" =~ ^[1-9][0-9]*$ && "$p_gid" == "$g_gid" \
        && "$p_home" == /home/ctrsvc && "$p_shell" == /usr/bin/nologin ]] \
        || fail '检测到冲突或非受控的 ctrsvc 账户或组'
    [[ ! -L /home/ctrsvc && $(stat -c '%F:%u:%a' /home/ctrsvc) == "directory:$p_uid:700" ]] \
        || fail '/home/ctrsvc 归属、类型或权限不匹配'
else
    fail '检测到部分存在的 ctrsvc 账户、组或 /home/ctrsvc，拒绝接管'
fi

sudo -v || fail 'sudo 提权验证失败'

if (( need_create )); then
    printf '将安装容器依赖并创建无登录、无 sudo 的 ctrsvc 账户及 HOME。\n'
    read -rp '继续？[y/N]: ' confirm < /dev/tty
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    sudo pacman -S --needed --noconfirm podman shadow curl jq openssl acme.sh argon2
    # shadow 只在本地映射文件存在时分配范围；只创建缺失文件，不清空已有授权。
    for mapping in /etc/subuid /etc/subgid; do
        if [[ ! -e "$mapping" && ! -L "$mapping" ]]; then
            sudo install -o root -g root -m 644 /dev/null "$mapping"
        else
            [[ -f "$mapping" && ! -L "$mapping" ]] \
                || fail "映射文件类型无效: $mapping"
        fi
    done
    sudo useradd --system --user-group --no-create-home --add-subids-for-system \
        --home-dir /home/ctrsvc --shell /usr/bin/nologin ctrsvc
    sudo passwd --lock ctrsvc
    sudo install -d -o ctrsvc -g ctrsvc -m 700 /home/ctrsvc
    sudo install -d -o root -g root -m 755 /etc/ssh/sshd_config.d
    printf 'DenyUsers ctrsvc\n' | sudo install -o root -g root -m 644 /dev/stdin /etc/ssh/sshd_config.d/00-ctrsvc.conf
    sudo sshd -t
    sudo systemctl reload sshd
    printf '✔ ctrsvc 账户已创建\n'
    sudo passwd -S ctrsvc
    id ctrsvc
else
    printf '○ 检测到已合规的 ctrsvc 账户与 /home/ctrsvc，跳过建账。\n'
    ! sudo test -L /etc/ssh/sshd_config.d/00-ctrsvc.conf \
        || fail '/etc/ssh/sshd_config.d/00-ctrsvc.conf 不能为符号链接'
    if sudo test -e /etc/ssh/sshd_config.d/00-ctrsvc.conf; then
        sudo test -f /etc/ssh/sshd_config.d/00-ctrsvc.conf \
            && printf 'DenyUsers ctrsvc\n' | sudo cmp -s /etc/ssh/sshd_config.d/00-ctrsvc.conf - \
            || fail '/etc/ssh/sshd_config.d/00-ctrsvc.conf 内容不匹配'
    else
        sudo install -d -o root -g root -m 755 /etc/ssh/sshd_config.d
        printf 'DenyUsers ctrsvc\n' | sudo install -o root -g root -m 644 /dev/stdin /etc/ssh/sshd_config.d/00-ctrsvc.conf
        sudo sshd -t
        sudo systemctl reload sshd
    fi
fi

# 启用用户管理器前，确认 ctrsvc 没有任何 sudo 授权。
sudo_rc=0
sudo_out=$(sudo -l -U ctrsvc 2>&1) || sudo_rc=$?
[[ $sudo_rc -eq 1 && "$sudo_out" == *"not allowed to run sudo"* ]] \
    || fail "无法确认 ctrsvc 无 sudo 授权或存在授权规则: $sudo_out"

! sudo test -L /usr/local/bin/ctrsvc-check || fail '/usr/local/bin/ctrsvc-check 不能为符号链接'
sudo install -o root -g root -m 755 /dev/stdin /usr/local/bin/ctrsvc-check <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
fail() { printf '%s\n' "$1" >&2; exit 1; }
record=$(getent passwd ctrsvc) || fail '无法查询 ctrsvc 账户'
IFS=: read -r name _ expected_uid expected_gid _ expected_home login_shell <<< "$record"
[[ "$name" == ctrsvc && "$expected_uid" =~ ^[0-9]+$ && "$expected_gid" =~ ^[0-9]+$ \
    && "$expected_uid" -ne 0 && "$expected_gid" -ne 0 && "$expected_home" == /home/ctrsvc && "$login_shell" == /usr/bin/nologin ]] \
    || fail 'ctrsvc 账户属性不匹配'
[[ $(id -u) == "$expected_uid" && $(id -g) == "$expected_gid" && $(id -G) == "$expected_gid" ]] \
    || fail '请进入 ctrsvc 业务管理上下文'
[[ "${HOME:-}" == "$expected_home" && ! -L "$HOME" \
    && $(stat -c '%F:%u:%a' "$HOME") == "directory:$expected_uid:700" ]] || fail '业务 HOME 不匹配'
runtime="/run/user/$expected_uid"
[[ "${XDG_RUNTIME_DIR:-}" == "$runtime" && ! -L "$runtime" \
    && $(stat -c '%F:%u:%a' "$runtime") == "directory:$expected_uid:700" \
    && "${DBUS_SESSION_BUS_ADDRESS:-}" == "unix:path=$runtime/bus" ]] || fail '业务运行目录或用户总线不匹配'
for variable in SSH_AUTH_SOCK SSH_AGENT_PID GPG_AGENT_INFO BASH_ENV ENV \
    CONTAINER_HOST CONTAINER_CONNECTION CONTAINER_SSHKEY CONTAINERS_CONF CONTAINERS_CONF_OVERRIDE \
    CONTAINERS_STORAGE_CONF STORAGE_DRIVER STORAGE_OPTS XDG_CONFIG_HOME XDG_DATA_HOME; do
    [[ ! -v "$variable" ]] || fail "业务环境包含覆盖变量: $variable"
done
systemctl --user is-active --quiet default.target || fail '业务用户管理器未就绪'
# 本部署使用本地 subuid/subgid，各一段，拒绝与其他授权重叠；不自动补写映射。
subrange() {
    awk -F: -v user=ctrsvc -v uid="$expected_uid" '
        NF != 3 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $3 == 0 { bad=1 }
        { start[NR]=$2; count[NR]=$3;
          if ($1 == user || $1 == uid) { target=NR; found++ } }
        END {
          if (bad || found != 1 || count[target] < 65536 || start[target] <= 0) exit 1
          for (i=1; i<=NR; i++)
            if (i != target && start[i] < start[target]+count[target] && start[target] < start[i]+count[i]) exit 1
          print start[target], count[target]
        }' "$1"
}
uid_range=$(subrange /etc/subuid) || fail 'ctrsvc subuid 授权无效或重叠'
gid_range=$(subrange /etc/subgid) || fail 'ctrsvc subgid 授权无效或重叠'
read -r subuid uid_count <<< "$uid_range"
read -r subgid gid_count <<< "$gid_range"
graphroot="$HOME/.local/share/containers/storage"
[[ $(realpath -m -- "$graphroot") == "$graphroot" ]] || fail '业务存储路径含重定向'
info=$(podman info --format json) || fail '无法查询业务 Podman 存储'
jq -e --arg graph "$graphroot" --arg runtime "$runtime/containers" \
    --argjson uid "$expected_uid" --argjson gid "$expected_gid" \
    --argjson subuid "$subuid" --argjson uc "$uid_count" \
    --argjson subgid "$subgid" --argjson gc "$gid_count" '
    .host.serviceIsRemote == false and .host.security.rootless == true and .store.graphRoot == $graph and
    .store.runRoot == $runtime and .store.volumePath == ($graph + "/volumes") and
    .host.idMappings.uidmap == [{container_id:0,host_id:$uid,size:1},{container_id:1,host_id:$subuid,size:$uc}] and
    .host.idMappings.gidmap == [{container_id:0,host_id:$gid,size:1},{container_id:1,host_id:$subgid,size:$gc}]
' <<< "$info" >/dev/null || fail '业务存储或实际 UID/GID 映射不匹配'
CHECK

! sudo test -L /usr/local/bin/ctrsvc-shell || fail '/usr/local/bin/ctrsvc-shell 不能为符号链接'
sudo install -o root -g root -m 755 /dev/stdin /usr/local/bin/ctrsvc-shell <<'SHELL'
#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) -ne 0 ]] || { printf '✘ 请以 sudo 运维用户执行\n' >&2; exit 1; }
business_uid=$(id -u ctrsvc)
exec sudo systemd-run --user --machine=ctrsvc@.host --pty --wait --collect \
    --service-type=exec --expand-environment=no --working-directory=/home/ctrsvc \
    /usr/bin/env -i HOME=/home/ctrsvc USER=ctrsvc LOGNAME=ctrsvc \
    PATH=/usr/local/bin:/usr/bin TERM=xterm-256color HISTFILE=/dev/null \
    XDG_RUNTIME_DIR="/run/user/$business_uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$business_uid/bus" \
    /usr/bin/bash --noprofile --norc -c 'umask 077; ctrsvc-check && exec /usr/bin/bash --noprofile --norc -i'
SHELL

sudo loginctl enable-linger ctrsvc
business_uid=$(id -u ctrsvc)
sudo systemctl start "user@$business_uid.service"
[[ $(loginctl show-user ctrsvc -p Linger --value) == yes ]]
sudo systemctl is-active --quiet "user@$business_uid.service"
printf '✔ Podman 底座已就绪；日常请直接执行 ctrsvc-shell 进入业务管理上下文。\n'
)
