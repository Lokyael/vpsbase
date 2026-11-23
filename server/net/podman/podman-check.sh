(
set -euo pipefail
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
sudo loginctl enable-linger ctrsvc
business_uid=$(id -u ctrsvc)
sudo systemctl start "user@$business_uid.service"
[[ $(loginctl show-user ctrsvc -p Linger --value) == yes ]]
sudo systemctl is-active --quiet "user@$business_uid.service"
)
