#!/usr/bin/env bash
# ctrsvc / Rootless Podman / gw；source 只定义函数，不执行部署。
VW="$HOME/containers/vaultwarden"
vw_fail() { printf '%s\n' "$*" >&2; exit 1; }
vw_pm() { podman "$@" 8>&-; }
vw_confirm() { local a; IFS= read -r -p "$1 [y/N]: " a < /dev/tty || return 1; [[ "$a" =~ ^[Yy]$ ]]; }
vw_hash() {
    local result
    result=$(sha256sum --binary -- "$1") || vw_fail "无法读取文件摘要: $1"
    [[ "$result" =~ ^([0-9a-f]{64})\ [*] ]] || vw_fail "文件摘要格式异常: $1"
    printf '%s\n' "${BASH_REMATCH[1]}"
}
vw_owned() {
    local p=$1 type=$2 mode=${3:-600} meta
    [[ ! -L "$p" && $(realpath -m -- "$p") == "$p" ]] && meta=$(stat -c '%F:%u:%a' -- "$p") &&
        [[ ${meta/#regular empty file:/regular file:} == "$type:$(id -u):$mode" ]] || vw_fail "路径归属、类型或权限不匹配: $p"
    [[ "$type" != 'regular file' || $(stat -c %h -- "$p") == 1 ]] || vw_fail "文件存在其他硬链接: $p"
}
vw_exists() { [[ -e "$1" || -L "$1" ]]; }
vw_save() {
    local p=$1 tmp
    if vw_exists "$p"; then vw_owned "$p" 'regular file'; fi
    tmp=$(mktemp "$VW/.write.XXXXXXXX")
    cat > "$tmp"
    mv -T -- "$tmp" "$p"
}
vw_json() { vw_owned "$1" 'regular file'; jq -e "$2" "$1"; }
vw_file_hash() {
    if vw_exists "$1"; then vw_owned "$1" 'regular file'; vw_hash "$1"; else printf 'absent\n'; fi
}
vw_same() {
    local rc=0
    cmp -s -- "$1" "$2" || rc=$?
    case $rc in 0|1) return "$rc" ;; *) vw_fail "文件比较失败: $1" ;; esac
}
vw_pod() {
    local token meta
    token=$(vw_json "$HOME/containers/gw.json" '.token|select(test("^[0-9a-f]{64}$"))' | jq -er .)
    meta=$(vw_pm pod inspect gw)
    POD=$(jq -er --arg token "$token" '
      select(length==1)|.[0]|select(.Name=="gw" and .Labels["io.ingress.pod"]==$token and
        .ExitPolicy=="continue" and (.SharedNamespaces|sort)==["ipc","net","uts"] and
        .InfraConfig.HostNetwork==false and (.InfraConfig.PortBindings|keys)==["443/tcp"] and
        (.InfraConfig.PortBindings["443/tcp"]|length)==1 and
        .InfraConfig.PortBindings["443/tcp"][0].HostPort=="443" and
        (.InfraConfig.PortBindings["443/tcp"][0].HostIp|.=="" or .=="0.0.0.0"))|
      .Id|select(test("^[0-9a-f]{64}$"))' <<< "$meta") || vw_fail 'gw Pod 归属、映射或退出策略不匹配'
}
vw_lock() {
    ctrsvc-check
    vw_owned "$HOME/containers" directory 700
    vw_owned "$VW" directory 700
    vw_owned "$VW/managed" 'regular file'
    cmp -s "$VW/managed" <(printf 'vaultwarden-rootless-v1\n') || vw_fail 'Vaultwarden 目录标识不匹配'
    vw_owned "$VW/lock" 'regular file'
    exec 8<>"$VW/lock"
    flock -n -x 8 || vw_fail '已有另一个 Vaultwarden 维护操作正在运行'
}
vw_settings() {
    jq -e 'type=="object" and (keys|sort)==["domain","invitations_allowed","org_creation_users","sends_allowed","show_password_hint","signups_allowed"] and
      (.domain|type=="string" and test("^https://vw\\.[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$")) and
      (.org_creation_users|type=="string" and (.=="all" or .=="none" or test("^[A-Za-z0-9@._+,-]+$"))) and
      ([.signups_allowed,.invitations_allowed,.sends_allowed,.show_password_hint]|all(type=="boolean"))' "$1" >/dev/null \
      || vw_fail '配置须为完整的 Vaultwarden settings.json，字段或类型不匹配'
}
vw_env() {
    jq -r 'to_entries|sort_by(.key)[]|"\(.key|ascii_upcase)=\(.value)"' "$1" || return
    printf '%s\n' 'IP_HEADER=X-Real-IP' 'IP_HEADER_TRUSTED_PROXIES=127.0.0.1'
}
vw_phc() {
    local part padded canonical size
    local -a parts
    # 本入口使用上游 OWASP 参数；允许上游另一预设，不接受残缺 PHC。
    [[ "$1" =~ ^\$argon2id\$v=19\$m=(19456,t=2,p=1|65540,t=3,p=4)\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]{43}$ ]] \
      || vw_fail '管理员 Argon2id PHC 格式或预设不匹配'
    IFS='$' read -ra parts <<< "$1"
    for part in "${parts[4]}" "${parts[5]}"; do
        padded=$part
        while (( ${#padded}%4 )); do padded+='='; done
        size=$(printf '%s' "$padded" | base64 --decode | wc -c)
        canonical=$(printf '%s' "$padded" | base64 --decode | base64 --wrap=0 | tr -d '=')
        [[ "$canonical" == "$part" && "$size" -ge 8 && "$size" -le 64 ]] || vw_fail '管理员 PHC 的 Base64 内容无效'
    done
}
vw_config() {
    local app="$VW/data/config.json" token
    vw_owned "$VW/config" directory 700
    vw_owned "$VW/config/settings.json" 'regular file'; vw_settings "$VW/config/settings.json"
    vw_owned "$VW/config/vaultwarden.env" 'regular file'
    cmp -s "$VW/config/vaultwarden.env" <(vw_env "$VW/config/settings.json") || vw_fail '应用环境文件与业务／来源配置基线不一致'
    vw_owned "$VW/config/admin-token" 'regular file'
    token=$(cat "$VW/config/admin-token"); vw_phc "$token"
    cmp -s "$VW/config/admin-token" <(printf '%s\n' "$token") || vw_fail '管理员散列文件不完整'
    if vw_exists "$app"; then
        vw_owned "$app" 'regular file'
        jq -e --slurpfile settings "$VW/config/settings.json" 'type=="object" and
          (.domain==null or .domain==$settings[0].domain) and
          (.ip_header==null or .ip_header=="X-Real-IP") and
          (.ip_header_trusted_proxies==null or .ip_header_trusted_proxies=="127.0.0.1") and
          ((.data_folder//"/data")|.=="/data" or .=="data") and
          ((.database_url//"sqlite:///data/db.sqlite3")|.=="sqlite:///data/db.sqlite3" or .=="sqlite://data/db.sqlite3") and
          ((.attachments_folder//"/data/attachments")|.=="/data/attachments" or .=="data/attachments") and
          ((.sends_folder//"/data/sends")|.=="/data/sends" or .=="data/sends") and
          ((.rsa_key_filename//"/data/rsa_key")|.=="/data/rsa_key" or .=="data/rsa_key") and
          ((.tmp_folder//"/data/tmp")|.=="/data/tmp" or .=="data/tmp") and
          ((.templates_folder//"/data/templates")|.=="/data/templates" or .=="data/templates") and
          (.disable_admin_token==null or .disable_admin_token==false) and
          (.extended_logging==null or .extended_logging==true) and
          (.log_level==null or .log_level=="info") and .log_file==null and
          (.admin_token==null or (.admin_token|type=="string"))' "$app" >/dev/null \
          || vw_fail '面板配置无效，或域名／来源头／数据／认证／诊断超出部署契约'
        if jq -e '.admin_token!=null' "$app" >/dev/null; then token=$(jq -er .admin_token "$app"); vw_phc "$token"; fi
    fi
}
vw_config_hash() {
    local p part text=''
    for p in config/settings.json config/vaultwarden.env config/admin-token data/config.json; do
        part=$(vw_file_hash "$VW/$p") || return 1
        [[ "$part" != absent || "$p" == data/config.json ]] || vw_fail "正式配置缺失: $p"
        text+="$part"$'\n'
    done
    printf '%s' "$text" | sha256sum | cut -d ' ' -f 1
}
vw_password() {
    local first second random phc
    IFS= read -r -s -p '新 /admin 密码（回车生成 24 位随机密码）: ' first < /dev/tty || vw_fail '密码读取中断'
    printf '\n' > /dev/tty
    if [[ -z "$first" ]]; then
        random=''
        while (( ${#random}<24 )); do random+=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9'); done
        first=${random:0:24}
    else
        [[ "$first" != [[:space:]]* && "$first" != *[[:space:]] && ${#first} -ge 8 ]] || vw_fail '密码须至少 8 位且两端不能有空白'
        IFS= read -r -s -p '再次输入: ' second < /dev/tty || vw_fail '密码确认中断'
        printf '\n' > /dev/tty
        [[ "$first" == "$second" ]] || vw_fail '两次密码不同'
    fi
    phc=$(printf '%s' "$first" | argon2 "$(openssl rand -base64 32)" -e -id -k 19456 -t 2 -p 1)
    vw_phc "$phc"
    printf '\n/admin 新密码: %s\n请保存到独立可用的安全位置。\n' "$first" > /dev/tty
    vw_confirm '已保存新密码，继续准备散列？' || vw_fail '凭据交付已取消'
    NEW_TOKEN=$phc
    unset first second random
}
vw_launcher_text() {
    cat <<'VWLAUNCH'
#!/bin/sh
set -eu
umask 077
[ "$$" = 1 ]
token=${VAULTWARDEN_TOKEN:?}
case "$token" in *[!0-9a-f]*|'') exit 1 ;; esac
[ "${#token}" = 64 ]
instance=$(cat /proc/sys/kernel/random/uuid)
core=$(sha256sum /vaultwarden | cut -d ' ' -f 1)
root=/var/log/vaultwarden
set -C
exec 1>"$root/$instance.stdout" 2>"$root/$instance.stderr"
printf 'instance=%s token=%s\n' "$instance" "$token"
printf '%s\t%s\n' "$instance" "$core" > "$root/current-$token.$instance"
mv "$root/current-$token.$instance" "$root/current-$token"
exec /start.sh
VWLAUNCH
}
vw_probe() {
    local image=$1 entry=$2 err rc=0
    shift 2
    err=$(mktemp "$WORK/probe.XXXXXXXX")
    vw_pm run --rm --pull never --network none --user 0:0 --read-only --read-only-tmpfs=false \
      --http-proxy=false --env-host=false --entrypoint "$entry" "$image" "$@" 2>"$err" || rc=$?
    if ((rc!=0)) || ! cmp -s "$err" /dev/null; then cat "$err" >&2; vw_fail "镜像查询失败（退出码 $rc）"; fi
}
vw_target() {
    local target=$1 arch
    jq -e '(.image|test("^sha256:[0-9a-f]{64}$")) and
      (.digest|test("^docker.io/vaultwarden/server@sha256:[0-9a-f]{64}$")) and
      (.version|test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and (.revision|test("^[0-9a-f]{40}$")) and
      (.core|test("^[0-9a-f]{64}$")) and (.arch=="amd64" or .arch=="arm64")' <<< "$target" >/dev/null
    IMAGE=$(jq -er .image <<< "$target")
    arch=$(vw_pm info --format '{{.Host.Arch}}')
    vw_pm image inspect "$IMAGE" | jq -e --argjson t "$target" --arg arch "$arch" '
      length==1 and (.[0].Id|ltrimstr("sha256:"))==($t.image|ltrimstr("sha256:")) and
      .[0].Os=="linux" and .[0].Architecture==$t.arch and $t.arch==$arch and
      (.[0].RepoDigests|index($t.digest))!=null and (.[0].Config.Entrypoint//[])==[] and
      .[0].Config.Cmd==["/start.sh"] and ((.[0].Config.User//"")|.=="" or .=="0" or .=="0:0") and
      ((.[0].Config.StopSignal//"")|.=="" or .=="SIGTERM") and
      .[0].Config.Labels["org.opencontainers.image.version"]==$t.version and
      .[0].Config.Labels["org.opencontainers.image.revision"]==$t.revision and
      .[0].Config.Labels["org.opencontainers.image.source"]=="https://github.com/dani-garcia/vaultwarden"' >/dev/null \
      || vw_fail '官方镜像、平台、版本或启动契约不匹配'
}
vw_fetch() {
    local release version ref kind revision image meta digest arch actual core
    release=$(curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout 10 --max-time 60 \
      https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest)
    version=$(jq -er 'select(.draft==false and .prerelease==false)|.tag_name|select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<< "$release")
    ref=$(curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout 10 --max-time 60 \
      "https://api.github.com/repos/dani-garcia/vaultwarden/git/ref/tags/$version")
    kind=$(jq -er .object.type <<< "$ref"); revision=$(jq -er '.object.sha|select(test("^[0-9a-f]{40}$"))' <<< "$ref")
    if [[ "$kind" == tag ]]; then
        ref=$(curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout 10 --max-time 60 \
          "https://api.github.com/repos/dani-garcia/vaultwarden/git/tags/$revision")
        kind=$(jq -er .object.type <<< "$ref"); revision=$(jq -er '.object.sha|select(test("^[0-9a-f]{40}$"))' <<< "$ref")
    fi
    [[ "$kind" == commit ]] || vw_fail '发行标签不能关联到唯一源码提交'
    image=$(vw_pm pull --quiet --tls-verify=true "docker.io/vaultwarden/server:$version")
    [[ "$image" =~ ^(sha256:)?[0-9a-f]{64}$ ]] || vw_fail '镜像获取结果无效'
    image="sha256:${image#sha256:}"
    meta=$(vw_pm image inspect "$image")
    digest=$(jq -er '.[0].RepoDigests|map(select(test("^docker.io/vaultwarden/server@sha256:[0-9a-f]{64}$")))|unique|
      if length==1 then .[0] else error("镜像摘要不唯一") end' <<< "$meta")
    arch=$(jq -er '.[0].Architecture' <<< "$meta")
    actual=$(vw_probe "$image" /vaultwarden --version)
    [[ "${actual%%$'\n'*}" == "Vaultwarden $version" ]] || vw_fail '镜像实际版本与发行版不符'
    core=$(vw_probe "$image" /bin/sh -ec '
      for x in cat cut mv sha256sum stat readlink awk curl; do command -v "$x" >/dev/null; done
      for x in /etc/vaultwarden.sh /etc/bitwarden_rs.sh /etc/vaultwarden.d /etc/bitwarden_rs.d; do [ ! -e "$x" ]; done
      sha256sum /vaultwarden')
    [[ "$core" =~ ^([0-9a-f]{64})\ \ /vaultwarden$ ]] || vw_fail '镜像核心或启动辅助命令不匹配'
    TARGET=$(jq -n --arg image "$image" --arg digest "$digest" --arg version "$version" --arg arch "$arch" \
      --arg revision "$revision" --arg core "${BASH_REMATCH[1]}" '{image:$image,digest:$digest,version:$version,arch:$arch,revision:$revision,core:$core}')
    vw_target "$TARGET"
    printf '固定目标: %s\n版本: %s\n发行说明: https://github.com/dani-garcia/vaultwarden/releases/tag/%s\n' "$digest" "$version" "$version"
}
vw_state() {
    local rc=0 fields token
    STATE=absent ID='' STARTED=''
    vw_pm container exists vaultwarden || rc=$?
    case $rc in 1) return ;; 0) ;; *) vw_fail '无法查询 Vaultwarden 容器' ;; esac
    SLOT=$(vw_json "$VW/container.json" 'select((.token|test("^[0-9a-f]{64}$")) and (.pod|test("^[0-9a-f]{64}$")) and
      (.id==null or (.id|test("^[0-9a-f]{64}$"))))')
    # Podman inspect 省略 ConmonPid=0 和 StoppedByUser=false；只补缺失字段。
    META=$(vw_pm container inspect vaultwarden | jq -ce '
      select(type=="array" and length==1 and (.[0].State|type=="object")) |
      .[0].State |= (
        if has("ConmonPid") then . else .ConmonPid=0 end |
        if has("StoppedByUser") then . else .StoppedByUser=false end
      ) | select(.[0].State | (.ConmonPid|type=="number" and .>=0 and floor==.) and (.StoppedByUser|type=="boolean"))') \
      || vw_fail 'Vaultwarden 容器查询失败或 inspect 字段格式异常'
    fields=$(jq -er --argjson s "$SLOT" '
      .[0]|select(.Name=="vaultwarden" and .Pod==$s.pod and (.Id|test("^[0-9a-f]{64}$")) and
        (.Id==$s.id or ($s.id==null and .State.Status=="created" and .State.Pid==0 and (.State.StartedAt|startswith("0001-")))) and
        (.Image|ltrimstr("sha256:"))==($s.image|ltrimstr("sha256:")) and
        .Config.Labels["io.vaultwarden.lifecycle"]==$s.token and .Config.User=="0:0" and
        .Config.StopSignal=="SIGTERM" and .Config.Entrypoint==["/bin/sh"] and
        .Config.Cmd==["/usr/local/libexec/vaultwarden-launch"] and .Config.Tty==false and
        .Config.Healthcheck.Test==["NONE"]) |
      [.Id,.State.Status,.State.StartedAt]|@tsv' <<< "$META") || vw_fail 'Vaultwarden 容器身份或入口不匹配'
    read -r ID STATE STARTED <<< "$fields"
    # 完整环境白名单不允许额外 ADMIN_TOKEN、路径或 Rocket 参数覆盖。
    token=$(jq -er .token <<< "$SLOT")
    jq -e --arg base "$VW" --arg token "$token" '
      .[0]|(.Config.Env|map(select(startswith("HOSTNAME=")))|length)<=1 and
      (.Config.Env|map(select(startswith("HOSTNAME=")|not))|sort)==([
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "container=podman", "ROCKET_PROFILE=release", "DEBIAN_FRONTEND=noninteractive",
        "ROCKET_ADDRESS=0.0.0.0", "ROCKET_PORT=8088", "DATA_FOLDER=/data", "DATABASE_URL=sqlite:///data/db.sqlite3",
        "CONFIG_FILE=/data/config.json", "ENV_FILE=/etc/vaultwarden-config/vaultwarden.env",
        "ADMIN_TOKEN_FILE=/etc/vaultwarden-config/admin-token", "UMASK=077", "EXTENDED_LOGGING=true", "LOG_LEVEL=info",
        ("VAULTWARDEN_TOKEN="+$token)]|sort) and
      .HostConfig.CgroupManager=="systemd" and .HostConfig.PidMode=="private" and (.HostConfig.Init//false)==false and
      .HostConfig.Privileged==false and .HostConfig.ReadonlyRootfs==false and
      (.HostConfig.RestartPolicy.Name|.=="no" or .=="unless-stopped") and
      (.Mounts|map({Type,Source,Destination,RW})|sort_by(.Destination))==([
        {Type:"bind",Source:($base+"/data"),Destination:"/data",RW:true},
        {Type:"bind",Source:($base+"/config"),Destination:"/etc/vaultwarden-config",RW:false},
        {Type:"bind",Source:($base+"/launch.sh"),Destination:"/usr/local/libexec/vaultwarden-launch",RW:false},
        {Type:"bind",Source:($base+"/diagnostics"),Destination:"/var/log/vaultwarden",RW:true}]|sort_by(.Destination))' <<< "$META" >/dev/null \
      || vw_fail 'Vaultwarden 环境、隔离或挂载不匹配'
    vw_pod
    [[ "$POD" == $(jq -er .pod <<< "$SLOT") ]] || vw_fail 'gw Pod 已变化'
}
vw_bind() {
    if [[ $(jq -r '.id//""' <<< "$SLOT") == '' ]]; then
        [[ "$STATE" == created ]] || vw_fail '创建结果未绑定且对象状态并非 created'
        vw_closed
        jq --arg id "$ID" '.id=$id' <<< "$SLOT" | vw_save "$VW/container.json"
    fi
}
vw_ticks() {
    local pid=$1 kind text rest
    local -a parts
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r /proc && -x /proc ]] || return 2
    kind=$(find -P /proc -mindepth 1 -maxdepth 1 -name "$pid" -printf '%y') || return 2
    case "$kind" in '') return 1 ;; d) ;; *) return 2 ;; esac
    text=$(<"/proc/$pid/stat") || return 2
    [[ "$text" == "$pid ("* && "$text" == *') '* ]] || return 2
    rest=${text##*) }; read -ra parts <<< "$rest"
    [[ ${#parts[@]} -ge 20 && "${parts[19]}" =~ ^[1-9][0-9]*$ ]] || return 2
    printf '%s\n' "${parts[19]}"
}
vw_empty() {
    local path=$1 node=/sys/fs/cgroup part kind events
    local -a parts
    [[ "$path" == /user.slice/* && "$path" != *..* && "$path" =~ ^/[A-Za-z0-9_./@:-]+$ &&
      -r "$node/cgroup.controllers" && -x "$node" ]] || vw_fail 'cgroup 路径或挂载未知'
    IFS=/ read -ra parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -n "$part" && -r "$node" && -x "$node" ]] || vw_fail 'cgroup 父目录不可读取'
        kind=$(find -P "$node" -mindepth 1 -maxdepth 1 -name "$part" -printf '%y')
        case "$kind" in '') return ;; d) node+="/$part" ;; *) vw_fail 'cgroup 类型异常' ;; esac
    done
    events=$(<"$node/cgroup.events")
    awk '$1=="populated" {n++; if(NF!=2 || $2!="0") bad=1} END {exit(n!=1 || bad)}' <<< "$events" || vw_fail 'cgroup 尚有进程或结果未知'
}
vw_boot() {
    local b
    b=$(</proc/sys/kernel/random/boot_id)
    [[ "$b" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || vw_fail '无法读取宿主启动标识'
    printf '%s\n' "$b"
}
vw_jobs() {
    local jobs
    jobs=$(systemctl --user list-jobs --full --no-legend --plain --no-pager)
    awk -v id="$ID" -v payload="${PAYLOAD##*/}" -v monitor="${MONITOR##*/}" '
      NF && (NF!=4 || $1!~/^[1-9][0-9]*$/) {bad=1}
      NF==4 && (index($2,id) || $2=="podman-restart.service" || $2==payload || $2==monitor) {bad=1}
      END {exit(bad)}' <<< "$jobs" || vw_fail 'Vaultwarden 存在未完成管理作业或查询格式异常'
}
vw_record() {
    local token marker core extra old='{}' pid ticks boot monitor cg again outid errid
    token=$(jq -er .token <<< "$SLOT")
    vw_owned "$VW/diagnostics/current-$token" 'regular file'
    marker=$(cat "$VW/diagnostics/current-$token")
    cmp -s "$VW/diagnostics/current-$token" <(printf '%s\n' "$marker") || vw_fail '实例标记读取不完整'
    IFS=$'\t' read -r INSTANCE core extra <<< "$marker"
    [[ "$INSTANCE" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ && "$core" =~ ^[0-9a-f]{64}$ &&
      -z "$extra" && "$marker" == "$INSTANCE"$'\t'"$core" ]] || vw_fail '实例标记格式错误'
    if vw_exists "$VW/run.json"; then old=$(vw_json "$VW/run.json" '.'); fi
    if [[ $(jq -r '.instance//""' <<< "$old") == "$INSTANCE" ]]; then
        jq -e --arg id "$ID" --arg started "$STARTED" --arg core "$core" '
          .id==$id and .started==$started and .core==$core' <<< "$old" >/dev/null || vw_fail '实例关联已变化'
        RUN=$old
    else
        [[ "$STATE" == running ]] || vw_fail '实例退出前未取得宿主运行信息'
        pid=$(jq -er '.[0].State.ConmonPid|select(.>0)' <<< "$META")
        ticks=$(vw_ticks "$pid") || vw_fail '无法读取 conmon 身份'
        boot=$(vw_boot)
        monitor=$(awk -F: '$1==0 {print $3}' "/proc/$pid/cgroup")
        cg=$(jq -er '.[0].State.CgroupPath|select(startswith("/user.slice/"))' <<< "$META")
        vw_owned "$VW/diagnostics/$INSTANCE.stdout" 'regular file'; vw_owned "$VW/diagnostics/$INSTANCE.stderr" 'regular file'
        outid=$(stat -c '%d:%i' "$VW/diagnostics/$INSTANCE.stdout"); errid=$(stat -c '%d:%i' "$VW/diagnostics/$INSTANCE.stderr")
        RUN=$(jq -n --arg id "$ID" --arg started "$STARTED" --arg instance "$INSTANCE" --arg core "$core" \
          --arg boot "$boot" --arg monitor "$monitor" --arg cgroup "$cg" --argjson pid "$pid" --arg ticks "$ticks" \
          --arg stdout "$outid" --arg stderr "$errid" \
          '{id:$id,started:$started,instance:$instance,core:$core,boot:$boot,monitor:$monitor,cgroup:$cgroup,pid:$pid,ticks:$ticks,stdout:$stdout,stderr:$stderr}')
        again=$(vw_ticks "$pid") || vw_fail '无法复查 conmon 身份'
        vw_pm container inspect "$ID" | jq -e --arg started "$STARTED" --argjson pid "$pid" \
          '.[0].State|.Status=="running" and .StartedAt==$started and .ConmonPid==$pid' >/dev/null
        [[ "$again" == "$ticks" && $(vw_boot) == "$boot" && $(cat "$VW/diagnostics/current-$token") == "$marker" ]] || vw_fail '运行记录期间实例变化'
        printf '%s\n' "$RUN" | vw_save "$VW/run.json"
    fi
    jq -e '(.pid|type=="number" and .>0 and floor==.) and (.ticks|test("^[1-9][0-9]*$")) and
      (.boot|test("^[0-9a-f-]{36}$")) and (.cgroup|startswith("/user.slice/")) and (.monitor|startswith("/user.slice/"))' <<< "$RUN" >/dev/null
    PAYLOAD=$(jq -er .cgroup <<< "$RUN"); MONITOR=$(jq -er .monitor <<< "$RUN")
    OUTID=$(jq -er '.stdout|select(test("^[0-9]+:[0-9]+$"))' <<< "$RUN")
    ERRID=$(jq -er '.stderr|select(test("^[0-9]+:[0-9]+$"))' <<< "$RUN")
}
vw_gone() {
    local pid ticks actual rc paths p
    vw_empty "$PAYLOAD"
    if [[ $(vw_boot) == $(jq -er .boot <<< "$RUN") ]]; then
        pid=$(jq -er .pid <<< "$RUN"); ticks=$(jq -er .ticks <<< "$RUN")
        while :; do
            rc=0; actual=$(vw_ticks "$pid") || rc=$?
            case $rc in 0) [[ "$actual" == "$ticks" ]] || break; sleep 1 ;; 1) break ;; *) vw_fail '无法确认原 conmon 是否结束' ;; esac
        done
        if [[ "$MONITOR" == */libpod-conmon-"$ID".scope ]]; then vw_empty "$MONITOR"; fi
    fi
    paths=$(find "/sys/fs/cgroup/user.slice/user-$(id -u).slice" -type d \( -name "libpod-$ID.scope" -o -name "libpod-conmon-$ID.scope" \))
    while IFS= read -r p; do [[ -z "$p" ]] || vw_empty "${p#/sys/fs/cgroup}"; done <<< "$paths"
    vw_jobs
}
vw_diag_files() {
    local out="$VW/diagnostics/$INSTANCE.stdout" err="$VW/diagnostics/$INSTANCE.stderr" token
    token=$(jq -er .token <<< "$SLOT")
    vw_owned "$out" 'regular file'; vw_owned "$err" 'regular file'
    [[ $(stat -c '%d:%i' "$out") == "$OUTID" && $(stat -c '%d:%i' "$err") == "$ERRID" ]] || vw_fail '实例诊断文件已替换'
    [[ $(head -n 1 "$out") == "instance=$INSTANCE token=$token" ]] || vw_fail '实例日志头不匹配'
}
vw_diag() {
    local out="$VW/diagnostics/$INSTANCE.stdout" err="$VW/diagnostics/$INSTANCE.stderr"
    vw_diag_files
    cmp -s "$err" /dev/null || vw_fail "实例有 stderr 诊断: $err"
    # 配置反序列化失败可能回退到环境；panic 也由应用写 stdout。
    awk '/^\[ERROR\]/ || /\[panic\]\[ERROR\]/ {bad=1} END {exit(bad)}' "$out" || vw_fail "实例有配置或 panic 诊断: $out"
}
vw_close_audit() {
    awk '
      /\[WARN\]/ || /\[ERROR\]/ {bad=1}
      /\[vaultwarden\]\[INFO\] Received SIGTERM, initiating graceful shutdown$/ {signal++; next}
      /\[vaultwarden\]\[INFO\] Vaultwarden process exited!$/ {if(signal!=1) bad=1; done++}
      END {exit(bad || signal!=1 || done!=1)}'
}
vw_no_process() {
    jq -e '.[0]|.State.Pid==0 and .State.ConmonPid==0 and has("ExecIDs") and (.ExecIDs|length)==0' <<< "$META" >/dev/null \
      || vw_fail '容器仍有进程、exec 或查询未知'
}
vw_closed() {
    local mode=${1:-strict} wait_result=${2:-0} id=$ID started=$STARTED term offset out size
    case "$STATE" in
      created)
        vw_no_process
        [[ "$STARTED" == 0001-* ]] || vw_fail '无法证明容器从未运行'
        PAYLOAD='' MONITOR=''; vw_jobs
        if [[ "$mode" == explicit ]]; then printf 'Vaultwarden 尚未启动，无需停止。\n'; fi
        return ;;
      exited|stopped) ;;
      *) vw_fail 'Vaultwarden 尚未退出' ;;
    esac
    vw_record; vw_no_process; vw_gone
    if [[ "$mode" == explicit ]]; then
        vw_state
        [[ "$ID:$STARTED:$STATE" == "$id:$started:exited" ]] || vw_fail '实例变化或 runtime cleanup 未完成'
        vw_no_process
        PHASE=核验正常关闭
        printf '已确认 Vaultwarden 本实例退出；正在核验正常关闭。\n'
        [[ "$wait_result" == 0 ]] || vw_fail "Vaultwarden 退出结果异常: $wait_result"
    fi
    term=$(vw_json "$VW/term.json" '.')
    jq -e --arg id "$ID" --arg started "$STARTED" --arg instance "$INSTANCE" '
      .id==$id and .started==$started and .instance==$instance and .phase=="sent" and
      (.offset|type=="number" and .>=0 and floor==.) and (.prefix|test("^[0-9a-f]{64}$"))' <<< "$term" >/dev/null || vw_fail '本实例 TERM 结果未确认'
    jq -e '.[0].State|.ExitCode==0 and .OOMKilled==false and .Error=="" and .StoppedByUser==true' <<< "$META" >/dev/null || vw_fail 'Vaultwarden 关闭结果异常'
    vw_diag
    offset=$(jq -er .offset <<< "$term"); out="$VW/diagnostics/$INSTANCE.stdout"
    size=$(stat -c %s "$out"); ((size>=offset)) || vw_fail '实例日志已截断'
    [[ $(head -c "$offset" "$out" | sha256sum | cut -d ' ' -f 1) == $(jq -er .prefix <<< "$term") ]] || vw_fail '停止前日志内容已改变'
    tail -c "+$((offset+1))" "$out" | vw_close_audit || vw_fail "关闭诊断不完整或存在异常: $out"
    vw_state
    [[ "$ID:$STARTED:$STATE" == "$id:$started:exited" ]] || vw_fail '实例变化或 runtime cleanup 未完成'
    vw_no_process; vw_gone
    if [[ "$mode" == explicit ]]; then printf 'Vaultwarden 正常关闭核验通过。\n'; fi
}
vw_stop() {
    local expected=${1:-} mode=${2:-strict} id started term='{}' match offset result
    vw_state
    [[ "$STATE" != absent ]] || vw_fail 'Vaultwarden 容器不存在'
    [[ -z "$expected" || "$ID:$STARTED" == "$expected" ]] || vw_fail '待停止实例已变化'
    case "$STATE" in created|exited|stopped) vw_closed "$mode"; return ;; running) ;; *) vw_fail 'Vaultwarden 状态不允许停止' ;; esac
    vw_record
    if [[ "$mode" == explicit ]]; then vw_diag_files; else vw_diag; fi
    vw_jobs
    jq -e '.[0]|has("ExecIDs") and (.ExecIDs|length)==0' <<< "$META" >/dev/null || vw_fail '存在活动 exec'
    vw_pm top "$ID" pid comm | awk 'NR>1 {n++;if(NF!=2 || $1!=1 || $2!="vaultwarden") bad=1} END {exit(n!=1 || bad)}' || vw_fail 'Vaultwarden 进程身份不匹配'
    id=$ID started=$STARTED
    if vw_exists "$VW/term.json"; then term=$(vw_json "$VW/term.json" '.'); fi
    match=0
    jq -e --arg id "$id" --arg started "$started" --arg instance "$INSTANCE" \
      '.id==$id and .started==$started and .instance==$instance' <<< "$term" >/dev/null || match=$?
    case $match in
      0) [[ $(jq -er .phase <<< "$term") == sent ]] || vw_fail 'TERM 调用结果未知，请保留当前对象排查' ;;
      1)
        [[ $(jq -er '.[0].State.StoppedByUser|tostring' <<< "$META") == false ]] || vw_fail '用户停止标记来源未知'
        offset=$(stat -c %s "$VW/diagnostics/$INSTANCE.stdout")
        term=$(jq -n --arg id "$id" --arg started "$started" --arg instance "$INSTANCE" --argjson offset "$offset" \
          --arg prefix "$(head -c "$offset" "$VW/diagnostics/$INSTANCE.stdout" | sha256sum | cut -d ' ' -f 1)" \
          '{id:$id,started:$started,instance:$instance,offset:$offset,prefix:$prefix,phase:"sending"}')
        printf '%s\n' "$term" | vw_save "$VW/term.json"
        vw_pm kill --signal TERM "$id"
        jq '.phase="sent"' <<< "$term" | vw_save "$VW/term.json" ;;
      *) vw_fail '无法比较停止记录' ;;
    esac
    PHASE=等待正常退出
    result=$(vw_pm wait "$id")
    [[ "$result" == 0 || "$mode" == explicit ]] || vw_fail "Vaultwarden 退出结果异常: $result"
    vw_state
    [[ "$ID:$STARTED" == "$id:$started" ]] || vw_fail '等待期间实例变化'
    vw_closed "$mode" "$result"
}
vw_data() {
    local invalid
    vw_owned "$VW/data" directory 700
    invalid=$(find -P "$VW/data" -xdev \( ! -uid "$(id -u)" -o \( ! -type d ! -type f \) -o \( -type f ! -links 1 \) \) -print)
    [[ -z "$invalid" ]] || vw_fail '数据目录含未知属主、链接或特殊文件'
    if vw_exists "$VW/initialized"; then
        vw_owned "$VW/initialized" 'regular file'
        vw_owned "$VW/data/db.sqlite3" 'regular file'
        vw_owned "$VW/data/rsa_key.pem" 'regular file'
    fi
}
vw_tree_hash() {
    (cd "$VW" || exit 1
      find data config -xdev -printf '%y %m %U %G %p\0' | sort -z || exit 1
      find data config -xdev -type f -print0 | sort -z | xargs -0 -r sha256sum --zero || exit 1) | sha256sum | cut -d ' ' -f 1
}
vw_backup_parent() {
    [[ "$1" == /* && "$1" != "$VW" && "$1" != "$VW/"* ]] || vw_fail '冷备目录须在 Vaultwarden 数据树之外'
    vw_owned "$1" directory 700
}
vw_backup() {
    local parent=$1 before after archive digest selfdir selfname result
    local -a members=(data config launch.sh image.json container.json managed)
    vw_closed; vw_config; vw_data
    if vw_exists "$VW/initialized"; then vw_owned "$VW/initialized" 'regular file'; members+=(initialized); fi
    vw_backup_parent "$parent"
    [[ $(tar --version) == 'tar (GNU tar)'* ]] || vw_fail '冷备需要已安装的 GNU tar'
    vw_owned "$SELF" 'regular file'
    selfdir=${SELF%/*}; selfname=${SELF##*/}
    [[ "$selfname" == vaultwarden.sh ]] || vw_fail '维护脚本文件名须为 vaultwarden.sh'
    before=$(vw_tree_hash)
    archive=$(mktemp "$parent/vaultwarden-XXXXXXXX.tar")
    printf '本次完整冷备（含凭据，0600）: %s\n' "$archive"
    tar --create --file "$archive" --directory "$VW" "${members[@]}" --directory "$selfdir" "$selfname"
    tar --compare --file "$archive" --directory "$VW" "${members[@]}"
    # 部署脚本来自独立目录，单独回读原始成员；不建立运行副本。
    tar --extract --to-stdout --file "$archive" "$selfname" | cmp - "$SELF"
    mkdir -m 700 "$WORK/recovery"
    tar --extract --file "$archive" --directory "$WORK/recovery" --no-same-owner --exclude=data/db.sqlite3-shm
    if [[ -f "$WORK/recovery/data/db.sqlite3" ]]; then
        # 检查一次性恢复副本，不提前打开／迁移生产数据库；WAL 原样配套恢复。
        result=$(sqlite3 -readonly "$WORK/recovery/data/db.sqlite3" 'PRAGMA quick_check; PRAGMA foreign_key_check;')
        [[ "$result" == ok ]] || vw_fail '冷备数据库恢复检查未通过'
    fi
    after=$(vw_tree_hash)
    [[ "$after" == "$before" ]] || vw_fail '冷备期间源内容变化'
    vw_state; vw_closed
    digest=$(vw_hash "$archive")
    BACKUP=$archive BACKUP_HASH=$digest FROZEN=$after
}
vw_backup_verify() {
    local job=$1 archive digest frozen actual_archive actual_tree
    archive=$(jq -er .archive <<< "$job"); digest=$(jq -er .archive_hash <<< "$job"); frozen=$(jq -er .frozen <<< "$job")
    vw_owned "$archive" 'regular file'
    actual_archive=$(vw_hash "$archive") || vw_fail '无法读取本次冷备'
    actual_tree=$(vw_tree_hash) || vw_fail '无法读取冻结源'
    [[ "$actual_archive" == "$digest" && "$actual_tree" == "$frozen" ]] || vw_fail '本次冷备或冻结数据已变化'
}
vw_create() {
    local token slot
    vw_state; [[ "$STATE" == absent ]] || vw_fail 'Vaultwarden 容器已存在'
    vw_pod; vw_target "$TARGET"; vw_config; vw_data
    token=$(openssl rand -hex 32)
    slot=$(jq --arg token "$token" --arg pod "$POD" '.+{token:$token,pod:$pod,id:null}' <<< "$TARGET")
    printf '%s\n' "$slot" | vw_save "$VW/container.json"
    PHASE=创建容器
    vw_pm --cgroup-manager systemd create --pull never --pod "$POD" --name vaultwarden \
      --label "io.vaultwarden.lifecycle=$token" --restart no --stop-signal SIGTERM --user 0:0 \
      --pid private --init=false --cgroups enabled --read-only=false --entrypoint /bin/sh --health-cmd none \
      --unsetenv-all --env-host=false --http-proxy=false \
      -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin -e container=podman \
      -e ROCKET_PROFILE=release -e DEBIAN_FRONTEND=noninteractive \
      -e "VAULTWARDEN_TOKEN=$token" -e ROCKET_ADDRESS=0.0.0.0 -e ROCKET_PORT=8088 \
      -e DATA_FOLDER=/data -e DATABASE_URL=sqlite:///data/db.sqlite3 -e CONFIG_FILE=/data/config.json \
      -e ENV_FILE=/etc/vaultwarden-config/vaultwarden.env -e ADMIN_TOKEN_FILE=/etc/vaultwarden-config/admin-token \
      -e UMASK=077 -e EXTENDED_LOGGING=true -e LOG_LEVEL=info \
      -v "$VW/data":/data -v "$VW/config":/etc/vaultwarden-config:ro \
      -v "$VW/launch.sh":/usr/local/libexec/vaultwarden-launch:ro -v "$VW/diagnostics":/var/log/vaultwarden \
      "$IMAGE" /usr/local/libexec/vaultwarden-launch
    vw_state; vw_closed
    jq --arg id "$ID" '.id=$id' <<< "$slot" | vw_save "$VW/container.json"
}
vw_ready() {
    local before="$ID:$STARTED" result version expected core
    vw_config; vw_record; vw_diag; vw_jobs
    core=$(jq -er .core <<< "$SLOT"); expected=$(jq -er .version <<< "$SLOT")
    [[ $(jq -er .core <<< "$RUN") == "$core" && $(jq -er '.[0].State.StoppedByUser|tostring' <<< "$META") == false ]] || vw_fail '核心不匹配或本实例已请求停止'
    result=$(vw_pm exec "$ID" /bin/sh -ec '
      [ "$(readlink /proc/1/exe)" = /vaultwarden ]
      sha256sum /proc/1/exe
      fds=$(for f in /proc/1/fd/*; do readlink "$f" || exit 2; done)
      printf "%s\n" "$fds" | awk '\''FNR==NR {if($2=="00000000:1F98" && $4=="0A") sockets["socket:["$10"]"]=1;next}
        $0 in sockets {found=1} END {exit(!found)}'\'' /proc/net/tcp -
      curl --fail --silent --show-error --max-time 10 http://127.0.0.1:8088/alive >/dev/null')
    [[ "$result" == "$core  /proc/1/exe" ]] || vw_fail '实际核心、监听归属或数据库健康不匹配'
    version=$(vw_pm exec "$ID" /vaultwarden --version)
    [[ "${version%%$'\n'*}" == "Vaultwarden $expected" ]] || vw_fail '实际版本不匹配'
    vw_state; [[ "$STATE" == running && "$ID:$STARTED" == "$before" ]] || vw_fail '检查期间实例变化'
    vw_record; vw_diag; vw_no_exec
}
vw_no_exec() {
    jq -e '.[0]|has("ExecIDs") and (.ExecIDs|length)==0' <<< "$META" >/dev/null || vw_fail '存在活动 exec 或查询未知'
}
vw_activation_done() {
    local id=$ID
    vw_owned "$VW/data/db.sqlite3" 'regular file'; vw_owned "$VW/data/rsa_key.pem" 'regular file'
    if ! vw_exists "$VW/initialized"; then printf 'initialized\n' | vw_save "$VW/initialized"; fi
    vw_pm update --restart unless-stopped "$id"
    vw_state
    [[ "$ID" == "$id" && "$STATE" == running && $(jq -er '.[0].HostConfig.RestartPolicy.Name' <<< "$META") == unless-stopped ]] || vw_fail '运行检查后恢复策略未确认'
    if vw_exists "$VW/activation.json"; then rm -- "$VW/activation.json"; fi
}
vw_start() {
    local prior id output rc prior_core expected_core activation='' marker=''
    vw_state; prior="$ID:$STARTED:$STATE"
    [[ "$STATE" != absent ]] || vw_fail 'Vaultwarden 不存在，请显式 install 或继续 update'
    if vw_exists "$VW/activation.json"; then
        activation=$(vw_json "$VW/activation.json" '.')
        [[ "$ID" == $(jq -er .replacement <<< "$activation") ]] || vw_fail '待迁移对象已变化'
    fi
    if [[ "$STATE" == running ]]; then
        vw_ready
        if [[ -n "$activation" || $(jq -er '.[0].HostConfig.RestartPolicy.Name' <<< "$META") == no ]]; then vw_activation_done; fi
        return
    fi
    case "$STATE" in
      created) vw_closed ;;
      exited|stopped)
        vw_no_process; vw_record; vw_gone
        [[ "$STATE" == exited ]] || vw_fail 'runtime cleanup 未完成'
        if [[ -n "$activation" ]]; then
            prior_core=$(jq -er .core <<< "$RUN")
            expected_core=$(jq -er .core <<< "$SLOT")
            [[ -n "$STARTED" && "$STARTED" != 0001-* && "$prior_core" == "$expected_core" ]] \
              || vw_fail '无法确认替代镜像的既有运行实例'
        fi
        printf '上次退出结果: %s\n' "$(jq -c '.[0].State|{ExitCode,OOMKilled,Error}' <<< "$META")" ;;
      *) vw_fail '容器处于过渡或未知状态' ;;
    esac
    vw_config; vw_data; vw_target "$SLOT"
    vw_owned "$VW/launch.sh" 'regular file'
    cmp -s "$VW/launch.sh" <(vw_launcher_text) || vw_fail '启动器内容不匹配'
    vw_state; [[ "$ID:$STARTED:$STATE" == "$prior" ]] || vw_fail '启动准备期间实例变化'
    vw_bind
    id=$ID
    if [[ -n "$activation" && "$STATE" == created ]]; then
        # 启动器在 exec 前写标记；与从未运行的 Podman 状态冲突时不猜测。
        vw_owned "$VW/diagnostics" directory 700
        marker="$VW/diagnostics/current-$(jq -er .token <<< "$SLOT")"
        ! vw_exists "$marker" || vw_fail '替代容器状态与启动标记冲突'
        PHASE=核验本次冷备
        vw_backup_verify "$activation"
    fi
    # 首次激活／迁移失败不自动反复重试；成功后才恢复运行期 restart 策略。
    vw_pm update --restart no "$id"
    vw_state; [[ "$ID:$STARTED:$STATE" == "$prior" && $(jq -er '.[0].HostConfig.RestartPolicy.Name' <<< "$META") == no ]] \
      || vw_fail '激活前实例变化或恢复策略未关闭'
    [[ -z "$marker" ]] || ! vw_exists "$marker" || vw_fail '替代容器状态与启动标记冲突'
    PHASE=启动及可能的数据迁移
    systemd-run --user --scope --collect --quiet --expand-environment=no \
      /usr/bin/env -u INVOCATION_ID /usr/bin/podman --remote=false start "$id" 8>&-
    for _ in {1..30}; do
        vw_state
        [[ "$ID" == "$id" && "$STATE" == running && $(jq -er '.[0].RestartCount' <<< "$META") == 0 ]] || vw_fail 'Vaultwarden 启动失败或已自动重试'
        # 应用没有 check CLI；HTTP 200 仅作就绪候选，最终仍核验版本、socket 及实例。
        if vw_exists "$VW/diagnostics/current-$(jq -er .token <<< "$SLOT")"; then vw_record; vw_diag; fi
        rc=0
        output=$(vw_pm exec "$id" /bin/sh -c 'curl --silent --output /dev/null --write-out "%{http_code}" --max-time 2 http://127.0.0.1:8088/alive') || rc=$?
        case "$rc:$output" in 0:200) break ;; 0:503|7:000|28:000) ;; *) vw_fail "健康接口查询异常: $rc / $output" ;; esac
        sleep 1
    done
    vw_ready
    vw_activation_done
    printf 'Vaultwarden 启动检查通过；公网业务及密码库功能仍须验收。\n'
}
vw_install() {
    local domain settings initial
    vw_state
    if [[ "$STATE" != absent ]]; then
        [[ "$STATE" == created ]] || vw_fail '已有实例，请使用 start；软件变更使用 update'
        vw_closed
        vw_bind
        printf '安装对象已创建，保持停止；显式 start 初始化。\n'; return
    fi
    if ! vw_exists "$VW/image.json"; then vw_fetch; printf '%s\n' "$TARGET" | vw_save "$VW/image.json"; fi
    TARGET=$(vw_json "$VW/image.json" '.'); vw_target "$TARGET"
    if ! vw_exists "$VW/config/settings.json" || vw_exists "$VW/install.json"; then
        if ! vw_exists "$VW/install.json"; then
            IFS= read -r -p 'Vaultwarden 完整地址（https://vw.域名）: ' domain < /dev/tty || vw_fail '域名输入中断'
            settings=$(jq -n --arg domain "$domain" '{domain:$domain,signups_allowed:false,org_creation_users:"all",invitations_allowed:true,sends_allowed:true,show_password_hint:true}')
            printf '%s\n' "$settings" > "$WORK/settings.json"; vw_settings "$WORK/settings.json"
            vw_confirm '使用上述地址及原有业务策略安装？' || return
            vw_password
            printf '%s' "$NEW_TOKEN" > "$WORK/token"
            jq -n --argjson settings "$settings" --rawfile token "$WORK/token" '{settings:$settings,token:$token}' | vw_save "$VW/install.json"
        fi
        initial=$(vw_json "$VW/install.json" '.')
        jq .settings <<< "$initial" | vw_save "$VW/config/settings.json"
        vw_env "$VW/config/settings.json" | vw_save "$VW/config/vaultwarden.env"
        jq -r .token <<< "$initial" | vw_save "$VW/config/admin-token"
        vw_config
        rm -- "$VW/install.json"
    fi
    vw_config
    # 仅首次空目录安装，已有业务数据不按同名路径接管。
    [[ -z $(find "$VW/data" -mindepth 1 -maxdepth 1 -print) ]] || vw_fail '首次安装数据目录不为空'
    vw_create
    printf '安装对象已创建并保持停止；显式 start 执行首次初始化。\n'
}
vw_require_removed() {
    local id=$1 rc=0
    vw_pm container exists "$id" || rc=$?
    case $rc in
        0) vw_fail "仍可按完整 ID 查到 Vaultwarden 容器: $id" ;;
        1) return 0 ;;
        *) vw_fail "无法按完整 ID 查询 Vaultwarden 容器: $id（退出码 $rc）" ;;
    esac
}
vw_update() {
    local parent=${1:-} job old started before version oldversion config
    if vw_exists "$VW/update.json"; then
        job=$(vw_json "$VW/update.json" '.')
    else
        vw_state; [[ "$STATE" != absent ]] || vw_fail '请先安装 Vaultwarden'
        before="$ID:$STARTED"; old=$ID
        if [[ "$STATE" == running ]]; then vw_record; vw_diag; else vw_closed; fi
        vw_config; vw_data
        oldversion=$(jq -er .version <<< "$SLOT")
        vw_confirm '显式获取官方最新稳定镜像？' || return
        vw_fetch
        if [[ "$IMAGE" == $(jq -er .image <<< "$SLOT") ]]; then printf '镜像无变化，不停止。\n'; return; fi
        version=$(jq -er .version <<< "$TARGET")
        [[ $(printf '%s\n%s\n' "$oldversion" "$version" | sort -V | tail -n 1) == "$version" ]] || vw_fail '目标版本早于当前版本，不能数据库降级'
        [[ -n "$parent" ]] || vw_fail '首次 update 须指定已准备的冷备父目录'
        vw_backup_parent "$parent"
        command -v sqlite3 >/dev/null || vw_fail '请在维护前准备 SQLite CLI'
        [[ $(tar --version) == 'tar (GNU tar)'* ]] || vw_fail '请在维护前准备 GNU tar'
        vw_confirm '已核对发行说明并安排停止使用？继续后将停止、完整冷备并替换，更新后保持停止。' || return
        vw_state; [[ "$ID:$STARTED" == "$before" ]] || vw_fail '镜像准备期间实例变化'
        config=$(vw_config_hash) || vw_fail '无法读取本次配置摘要'
        job=$(jq -n --arg old "$old" --arg started "$STARTED" --arg parent "$parent" --arg config "$config" \
          --argjson target "$TARGET" \
          '{old:$old,started:$started,parent:$parent,config:$config,target:$target,phase:"prepared"}')
        printf '%s\n' "$job" | vw_save "$VW/update.json"
    fi
    jq -e '(.old|test("^[0-9a-f]{64}$")) and (.started|type=="string" and length>0) and
      (.phase|.=="prepared" or .=="backed-up" or .=="removal-confirmed" or .=="replacement-created")' <<< "$job" >/dev/null \
      || vw_fail 'Vaultwarden 更新记录无效'
    TARGET=$(jq -e .target <<< "$job"); vw_target "$TARGET"
    old=$(jq -er .old <<< "$job"); started=$(jq -er .started <<< "$job"); vw_state
    case $(jq -er .phase <<< "$job") in
      prepared)
        [[ "$ID:$STARTED" == "$old:$started" && $(vw_config_hash) == $(jq -er .config <<< "$job") ]] || vw_fail '待更新实例或配置已变化'
        vw_stop "$ID:$STARTED"
        [[ $(vw_config_hash) == $(jq -er .config <<< "$job") ]] || vw_fail '停止期间配置变化，请核对后取消本次更新'
        vw_backup "$(jq -er .parent <<< "$job")"
        job=$(jq --arg archive "$BACKUP" --arg archive_hash "$BACKUP_HASH" --arg frozen "$FROZEN" \
          '.+{archive:$archive,archive_hash:$archive_hash,frozen:$frozen,phase:"backed-up"}' <<< "$job")
        printf '%s\n' "$job" | vw_save "$VW/update.json" ;;
    esac
    if [[ $(jq -er .phase <<< "$job") == backed-up ]]; then
        [[ "$ID:$STARTED" == "$old:$started" ]] \
          || vw_fail "旧对象缺失或实例已变化，且无本次移除完成记录；请核对容器 $old 和 Podman 诊断"
        vw_backup_verify "$job"
        vw_state; [[ "$ID:$STARTED" == "$old:$started" ]] || vw_fail '旧 Vaultwarden 实例已变化'
        vw_closed
        PHASE=移除旧容器
        vw_pm rm "$old" || return "$?"
        PHASE=回读旧容器移除
        vw_require_removed "$old"
        PHASE=保存移除完成记录
        job=$(jq -e '.phase="removal-confirmed"' <<< "$job"); printf '%s\n' "$job" | vw_save "$VW/update.json"
        vw_state; [[ "$STATE" == absent ]] || vw_fail '移除后出现同名 Vaultwarden 容器；请核对归属'
    else
        PHASE=复查旧容器移除
        vw_require_removed "$old"
    fi
    if [[ $(jq -er .phase <<< "$job") == removal-confirmed ]]; then
        PHASE=核验本次冷备
        vw_backup_verify "$job"; vw_state
        if [[ "$STATE" == absent ]]; then
            printf '%s\n' "$TARGET" | vw_save "$VW/image.json"; vw_create
        else
            [[ "$ID" != "$old" && $(jq -er .image <<< "$SLOT") == "$IMAGE" ]] || vw_fail '替代对象与固定目标不同'
            vw_closed; vw_bind
        fi
        job=$(jq --arg replacement "$ID" '.+{phase:"replacement-created",replacement:$replacement}' <<< "$job")
        printf '%s\n' "$job" | vw_save "$VW/update.json"
    fi
    vw_state; vw_closed
    [[ "$ID" == $(jq -er .replacement <<< "$job") && $(jq -er .image <<< "$SLOT") == "$IMAGE" ]] || vw_fail '替代对象身份变化'
    vw_backup_verify "$job"
    jq '{replacement,archive,archive_hash,frozen}' <<< "$job" | vw_save "$VW/activation.json"
    rm -- "$VW/update.json"
    printf '软件替换完成，容器保持停止；本次冷备: %s\n显式 start 将打开生产数据库并可能执行迁移。\n' "$(jq -er .archive <<< "$job")"
}
vw_change() {
    local kind=$1 input=${2:-} job settings token app='absent' before original_config content oldhash newhash p value
    if vw_exists "$VW/change.json"; then
        job=$(vw_json "$VW/change.json" '.')
        [[ $(jq -er .kind <<< "$job") == "$kind" ]] || vw_fail '请继续原配置操作'
    else
        vw_state; [[ "$STATE" != absent ]] || vw_fail '请先安装 Vaultwarden'
        before="$ID:$STARTED"; vw_config; original_config=$(vw_config_hash)
        if [[ "$STATE" == running ]]; then vw_record; vw_diag; else vw_closed; fi
        settings=$(cat "$VW/config/settings.json"); token=$(cat "$VW/config/admin-token")
        if vw_exists "$VW/data/config.json"; then app=$(cat "$VW/data/config.json"); fi
        if [[ "$kind" == configure ]]; then
            [[ -n "$input" ]] || vw_fail 'configure 须指定候选 settings.json'
            vw_owned "$input" 'regular file'; vw_settings "$input"
            settings=$(cat "$input")
            if [[ "$app" != absent ]]; then
                app=$(jq --argjson settings "$settings" 'reduce ($settings|keys[]) as $k (.; if has($k) then .[$k]=$settings[$k] else . end)' <<< "$app")
            fi
            if [[ $(jq -Sc . <<< "$settings") == $(jq -Sc . "$VW/config/settings.json") ]] &&
              { [[ "$app" == absent ]] || [[ $(jq -Sc . <<< "$app") == $(jq -Sc . "$VW/data/config.json") ]]; }; then
                printf '配置无变化。\n'; return
            fi
        else
            vw_password; token=$NEW_TOKEN
            printf '%s' "$token" > "$WORK/token"
            if [[ "$app" != absent ]]; then app=$(jq --rawfile token "$WORK/token" 'if has("admin_token") then .admin_token=$token else . end' <<< "$app"); fi
        fi
        # 先构造所有候选；无变化不发停止信号。
        printf '%s\n' "$settings" > "$WORK/settings.json"
        printf '%s' "$token" > "$WORK/token"
        printf '%s' "$app" > "$WORK/app"
        vw_env "$WORK/settings.json" > "$WORK/env"
        jq -n --slurpfile settings "$WORK/settings.json" --rawfile env "$WORK/env" --rawfile token "$WORK/token" --rawfile app "$WORK/app" \
          '{"config/settings.json":($settings[0]|tojson),"config/vaultwarden.env":($env|rtrimstr("\n")),"config/admin-token":$token,"data/config.json":$app}' > "$WORK/files.json"
        local old='{}' changed=false
        while IFS= read -r p; do
            value=$(jq -er --arg p "$p" '.[$p]' "$WORK/files.json")
            if [[ "$p" == config/settings.json ]]; then value=$(jq . <<< "$value"); fi
            if [[ "$value" == absent && "$p" == data/config.json ]]; then oldhash=absent
            else
                printf '%s\n' "$value" > "$WORK/candidate"
                oldhash=$(vw_hash "$VW/$p")
                if ! vw_same "$WORK/candidate" "$VW/$p"; then changed=true; fi
            fi
            old=$(jq --arg p "$p" --arg hash "$oldhash" '.[$p]=$hash' <<< "$old")
        done < <(jq -r 'keys[]' "$WORK/files.json")
        if [[ "$changed" == false ]]; then printf '配置无变化。\n'; return; fi
        printf '目标业务配置:\n%s\n' "$settings"
        vw_confirm '正常关闭后发布本次配置／管理散列？不更换镜像或容器，发布后保持停止。' || return
        vw_state
        [[ "$ID:$STARTED" == "$before" && $(vw_config_hash) == "$original_config" ]] || vw_fail '准备配置期间实例或配置变化'
        job=$(jq -n --arg kind "$kind" --arg id "$ID" --arg started "$STARTED" --slurpfile files "$WORK/files.json" \
          --argjson old "$old" '{kind:$kind,id:$id,started:$started,files:$files[0],old:$old,phase:"prepared"}')
        printf '%s\n' "$job" | vw_save "$VW/change.json"
    fi
    vw_state
    [[ "$ID:$STARTED" == "$(jq -er .id <<< "$job"):$(jq -er .started <<< "$job")" ]] || vw_fail '配置操作的容器实例已变化'
    jq -e '(.files|keys)==["config/admin-token","config/settings.json","config/vaultwarden.env","data/config.json"] and
      (.old|keys)==(.files|keys) and (.phase=="prepared" or .phase=="publishing")' <<< "$job" >/dev/null
    if [[ $(jq -er .phase <<< "$job") == prepared ]]; then
        while IFS= read -r p; do
            [[ $(vw_file_hash "$VW/$p") == $(jq -er --arg p "$p" '.old[$p]' <<< "$job") ]] || vw_fail '配置已被其他操作修改'
        done < <(jq -r '.old|keys[]' <<< "$job")
        vw_stop "$ID:$STARTED"
        while IFS= read -r p; do
            [[ $(vw_file_hash "$VW/$p") == $(jq -er --arg p "$p" '.old[$p]' <<< "$job") ]] || vw_fail '停止期间配置已变化'
        done < <(jq -r '.old|keys[]' <<< "$job")
        job=$(jq '.phase="publishing"' <<< "$job"); printf '%s\n' "$job" | vw_save "$VW/change.json"
    fi
    vw_closed
    while IFS= read -r p; do
        case "$p" in config/settings.json|config/vaultwarden.env|config/admin-token|data/config.json) ;; *) vw_fail '配置候选含未知路径' ;; esac
        value=$(jq -er --arg p "$p" '.files[$p]' <<< "$job")
        [[ "$p:$value" != data/config.json:absent ]] || continue
        if [[ "$p" == config/settings.json ]]; then value=$(jq . <<< "$value"); fi
        printf '%s\n' "$value" > "$WORK/candidate"
        newhash=$(vw_hash "$WORK/candidate"); oldhash=$(jq -er --arg p "$p" '.old[$p]' <<< "$job")
        content=$(vw_file_hash "$VW/$p")
        [[ "$content" == "$newhash" || "$content" == "$oldhash" ]] || vw_fail "发布期间文件被其他操作修改: $p"
        if [[ "$content" != "$newhash" ]]; then vw_save "$VW/$p" < "$WORK/candidate"; fi
    done < <(jq -r '.files|keys[]' <<< "$job")
    vw_config
    rm -- "$VW/change.json"
    printf '配置发布完成，容器保持停止；显式 start 应用。管理密码轮换不会撤销已签发 JWT，也不轮换 RSA 密钥。\n'
}
vw_retire() {
    local job target started removed
    vw_state
    if ! vw_exists "$VW/retire.json"; then
        [[ "$STATE" != absent ]] || vw_fail '容器缺失且没有退役记录'
        vw_confirm '永久退役本容器？保留密码库、附件、Send、配置、凭据、诊断及镜像。' || return
        jq -n --arg id "$ID" --arg started "$STARTED" '{id:$id,started:$started,removed:false}' | vw_save "$VW/retire.json"
    fi
    job=$(vw_json "$VW/retire.json" 'select((.id|test("^[0-9a-f]{64}$")) and
      (.started|type=="string" and length>0) and (.removed|type=="boolean"))') || vw_fail 'Vaultwarden 退役记录无效'
    target=$(jq -er .id <<< "$job"); started=$(jq -er .started <<< "$job")
    removed=$(jq -er '.removed|tostring' <<< "$job")
    if [[ "$removed" == false ]]; then
        [[ "$ID:$STARTED" == "$target:$started" ]] \
          || vw_fail "退役对象缺失或实例已变化，且无本次移除完成记录；请核对容器 $target 和 Podman 诊断"
        PHASE=禁用本容器恢复
        vw_pm update --restart no "$target"
        vw_state
        [[ "$ID:$STARTED" == "$target:$started" && $(jq -er '.[0].HostConfig.RestartPolicy.Name' <<< "$META") == no ]] \
          || vw_fail '退役实例变化或本容器恢复策略未关闭'
        vw_stop "$target:$started"
        PHASE=移除退役容器
        vw_pm rm "$target" || return "$?"
    fi
    PHASE=回读退役容器移除
    vw_require_removed "$target"
    if [[ "$removed" == false ]]; then
        PHASE=保存退役移除完成记录
        jq -e '.removed=true' <<< "$job" | vw_save "$VW/retire.json"
    fi
    vw_state
    [[ "$STATE" == absent ]] || vw_fail '仍有同名 Vaultwarden 容器；请核对归属'
    printf 'Vaultwarden 已退役；数据、凭据、日志、冷备和部署材料全部保留。\n'
}
vw_main() {
    set -euo pipefail
    shopt -s inherit_errexit
    [[ $- != *x* ]] || vw_fail '请关闭 Shell 跟踪后运行'
    umask 077
    export LC_ALL=C
    local action=${1:-} arg=${2:-}
    [[ $# -ge 1 && $# -le 2 ]] || vw_fail '用法: vaultwarden.sh install|update [冷备父目录]|configure [settings.json]|rotate-admin|start|stop|status|retire|cancel-update'
    ctrsvc-check
    [[ "$action" =~ ^(install|update|configure|rotate-admin|start|stop|status|retire|cancel-update)$ ]] || vw_fail '未知 Vaultwarden 操作'
    [[ -z "$arg" || "$action" == update || "$action" == configure ]] || vw_fail '本操作不接受额外参数'
    SELF=${BASH_SOURCE[0]}
    [[ "$SELF" == /* ]] || SELF="$PWD/$SELF"
    vw_owned "$SELF" 'regular file'
    vw_owned "$HOME/containers" directory 700
    if ! vw_exists "$VW"; then
        [[ "$action" == install ]] || vw_fail 'Vaultwarden 尚未安装'
        vw_pod
        local rc=0
        vw_pm container exists vaultwarden || rc=$?
        [[ "$rc" == 1 ]] || vw_fail '同名容器已存在或无法查询'
        vw_confirm '建立全新 Vaultwarden 专属目录并准备安装？' || return
        mkdir -m 700 "$VW"
        printf 'vaultwarden-rootless-v1\n' > "$VW/managed"
        : > "$VW/lock"
        mkdir -m 700 "$VW/data" "$VW/config" "$VW/diagnostics"
        vw_launcher_text > "$VW/launch.sh"
    fi
    vw_lock
    WORK=$(mktemp -d "$VW/.work.XXXXXXXX")
    PHASE=探测 PAYLOAD='' MONITOR=''
    trap 'rc=$?; if ((rc!=0)); then printf "Vaultwarden 操作失败，阶段：%s；请核对当前对象和已完成步骤。\n" "$PHASE" >&2; fi; rm -rf -- "$WORK"' EXIT
    if vw_exists "$VW/retire.json"; then case "$action" in retire|stop|status) ;; *) vw_fail '已进入退役，请继续 retire' ;; esac; fi
    if vw_exists "$VW/update.json"; then case "$action" in update|cancel-update|stop|status) ;; *) vw_fail '请先处理未完成的软件更新' ;; esac; fi
    if vw_exists "$VW/change.json"; then case "$action" in configure|rotate-admin|stop|status) ;; *) vw_fail '请先完成配置发布' ;; esac; fi
    if vw_exists "$VW/activation.json"; then
        case "$action" in start|stop|status|retire) ;; update) vw_exists "$VW/update.json" || vw_fail '请先完成本次版本激活' ;; *) vw_fail '请先完成本次版本激活' ;; esac
    fi
    case "$action" in
      install) vw_install ;;
      update) vw_update "$arg" ;;
      configure) vw_change configure "$arg" ;;
      rotate-admin) vw_change rotate-admin ;;
      start) vw_confirm '以已安装内容启动？可能初始化／迁移数据库并恢复客户端写入。' || return; vw_start ;;
      stop) vw_confirm '正常停止 Vaultwarden 并保留对象？' || return; vw_stop '' explicit ;;
      status) vw_state; printf 'Vaultwarden: %s；ID: %s\n' "$STATE" "$ID" ;;
      retire) vw_retire ;;
      cancel-update)
        local job
        job=$(vw_json "$VW/update.json" '.')
        [[ $(jq -er .phase <<< "$job") == prepared || $(jq -er .phase <<< "$job") == backed-up ]] || vw_fail '旧对象已进入替换，请继续 update'
        vw_state; [[ "$ID" == $(jq -er .old <<< "$job") ]] || vw_fail '旧对象缺失或变化'
        vw_confirm '仅取消替换前更新意图？已发信号、冷备及停止状态保留。' || return
        rm -- "$VW/update.json" ;;
    esac
}
if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then vw_main "$@"; fi
