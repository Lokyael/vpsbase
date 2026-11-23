#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

br_fail() { printf '%s\n' "$*" >&2; exit 1; }
br_get() {
    curl -q --proto '=https' --proto-redir '=https' --location --max-redirs 5 --fail --silent --show-error --connect-timeout 10 --max-time 30 "$@"
}
br_manifest() {
    # Only the registry's short-lived anonymous read token; not an operator credential.
    printf 'header = "Authorization: Bearer %s"\n' "$token" |
        br_get --config - --header "Accept: $1" --output "$2" "https://ghcr.io/v2/garethgeorge/backrest/manifests/$3"
}
br_digest() {
    local line
    line=$(sha256sum --binary < "$1") || return 1
    [[ "$line" =~ ^([a-f0-9]{64})[[:blank:]]\*-$ ]] || return 1
    printf 'sha256:%s\n' "${BASH_REMATCH[1]}"
}
br_inventory() {
    local report=$1 tag=$2 revision=$3 arch=$4 i line sum
    local -a lines paths=(/backrest /bin/restic /usr/bin/rclone /sbin/tini) versions
    mapfile -t lines < "$report" || br_fail '无法读取镜像探针输出'
    [[ ${#lines[@]} == 8 ]] && cmp -s -- "$report" <(printf '%s\n' "${lines[@]}") || br_fail '镜像探针输出格式异常'
    [[ "${lines[0]}" == "backrest version: ${tag#v}, commit: $revision" ]] || br_fail 'Backrest 二进制版本或提交不匹配'
    [[ "${lines[1]}" =~ ^restic\ ([0-9]+\.[0-9]+\.[0-9]+)\ compiled\ with\ go[0-9.]+\ on\ linux/"$arch"$ ]] || br_fail 'restic 版本或平台异常'
    versions=("${tag#v}" "${BASH_REMATCH[1]}")
    [[ "${lines[2]}" =~ ^rclone\ v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || br_fail 'rclone 版本异常'
    versions+=("${BASH_REMATCH[1]}")
    [[ "${lines[3]}" =~ ^tini\ version\ ([0-9]+\.[0-9]+\.[0-9]+)(\ -\ git\.[a-zA-Z0-9]+)?$ ]] || br_fail 'Tini 版本异常'
    versions+=("${BASH_REMATCH[1]}")
    for i in "${!paths[@]}"; do
        line=${lines[i+4]}
        sum=${line%"  ${paths[i]}"}
        [[ "$sum" =~ ^[a-f0-9]{64}$ && "$line" == "$sum  ${paths[i]}" ]] || br_fail '镜像探针摘要或路径异常'
    done
    for i in "${!paths[@]}"; do
        printf '%s\t%s\tsha256:%s\n' "${paths[i]}" "${versions[i]}" "${lines[i+4]%% *}"
    done
}

# Keep the target in this invocation; never re-resolve the moving tag after confirmation.
br_prepare_image() (
    ctrsvc-check
    [[ $(uname -s) == Linux ]] || br_fail '镜像准备要求 Linux 业务上下文'
    case $(uname -m) in
        x86_64) arch=amd64 ;;
        aarch64) arch=arm64 ;;
        *) br_fail 'Backrest 镜像平台尚未核验' ;;
    esac
    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    [[ -d "$runtime_dir" ]] || br_fail '业务运行目录不存在'
    work=$(mktemp -d -- "$runtime_dir/backrest-image.XXXXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    repo=ghcr.io/garethgeorge/backrest
    api=https://api.github.com/repos/garethgeorge/backrest
    index_type=application/vnd.oci.image.index.v1+json
    manifest_type=application/vnd.oci.image.manifest.v1+json
    br_get --output "$work/release" "$api/releases/latest"
    tag=$(jq -ser 'select(length==1)|.[0] |
        select(.draft==false and .prerelease==false and (.published_at|type=="string" and length>0)) |
        .tag_name | select(test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\z"))' "$work/release") || br_fail '官方稳定发行信息无法核验'
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || br_fail '发行标签格式异常'
    br_get --output "$work/commit" "$api/commits/$tag"
    revision=$(jq -ser 'select(length==1)|.[0].sha|select(test("^[a-f0-9]{40}\\z"))' "$work/commit") || br_fail '官方发行提交无法核验'
    br_get --output "$work/token" 'https://ghcr.io/token?scope=repository:garethgeorge/backrest:pull'
    token=$(jq -ser 'select(length==1)|.[0].token' "$work/token") || br_fail 'GHCR 匿名读令牌无法核验'
    [[ "$token" =~ ^[a-zA-Z0-9._=-]+$ ]] || br_fail 'GHCR 令牌格式异常'

    br_manifest "$index_type" "$work/index" "$tag"
    index=$(br_digest "$work/index") || br_fail '无法读取官方镜像索引摘要'
    digest=$(jq -ser --arg arch "$arch" --arg index "$index_type" --arg manifest "$manifest_type" '
        select(length==1)|.[0] | select(.schemaVersion==2 and .mediaType==$index) |
        [.manifests[] | select(.mediaType==$manifest and .platform.os=="linux" and .platform.architecture==$arch and
          ((.platform.variant//"")=="" or ($arch=="arm64" and .platform.variant=="v8")))] |
        select(length==1)|.[0].digest | select(test("^sha256:[a-f0-9]{64}\\z"))' "$work/index") || br_fail '官方索引没有唯一已核验的 Linux 平台目标'
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || br_fail '平台 manifest 摘要格式异常'
    br_manifest "$manifest_type" "$work/manifest" "$digest"
    actual=$(br_digest "$work/manifest") || br_fail '无法读取官方平台 manifest 摘要'
    [[ "$actual" == "$digest" ]] || br_fail '平台 manifest 内容与索引摘要不匹配'
    image=$(jq -ser --arg manifest "$manifest_type" '
        select(length==1)|.[0] | select(.schemaVersion==2 and .mediaType==$manifest and
          .config.mediaType=="application/vnd.oci.image.config.v1+json") |
        .config.digest|select(test("^sha256:[a-f0-9]{64}\\z"))' "$work/manifest") || br_fail '平台镜像配置摘要无法核验'
    [[ "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || br_fail '镜像配置摘要格式异常'

    printf '拟准备 Backrest %s（%s，linux/%s）\n%s@%s\n' "$tag" "$revision" "$arch" "$repo" "$digest" >&2
    IFS= read -r -p '拉取并执行隔离镜像探针？[y/N]: ' confirm < /dev/tty || br_fail '确认输入中断'
    case "$confirm" in
        ''|[Nn]) exit 0 ;;
        [Yy]) ;;
        *) br_fail '确认输入无效' ;;
    esac
    pulled=$(podman --remote=false pull --quiet --tls-verify=true --platform "linux/$arch" "$repo@$digest") || br_fail '获取 Backrest 镜像失败'
    [[ "$pulled" == "${image#sha256:}" ]] || br_fail '拉取返回的本地镜像 ID 与官方配置摘要不符'
    podman --remote=false image inspect "$pulled" > "$work/inspect" || br_fail '无法读取已获取镜像'
    jq -se --arg id "$pulled" --arg ref "$repo@$digest" --arg arch "$arch" '
        select(length==1)|.[0] | length==1 and (.[0] |
          (.Id|sub("^sha256:";""))==$id and (.RepoDigests|index($ref))!=null and
          .Os=="linux" and .Architecture==$arch and .Config.WorkingDir=="/" and
          ((.Config.User//"")=="") and ((.Config.StopSignal//"")=="") and
          .Config.Entrypoint==["/sbin/tini","--","/docker-entrypoint"] and .Config.Cmd==["/backrest"] and
          .Labels["org.opencontainers.image.source"]=="https://github.com/garethgeorge/backrest")' "$work/inspect" >/dev/null || br_fail '本地镜像平台、入口或来源契约不匹配'

    mkdir -- "$work/hooks"
    # No default business mounts, hooks or environment; use only version commands and image bytes.
    CONTAINERS_CONF=/dev/null podman --remote=false --default-mounts-file /dev/null --hooks-dir "$work/hooks" \
        run --rm --pull never --network none --pid private --ipc private --uts private --user 0:0 \
        --read-only --read-only-tmpfs=false --image-volume ignore --no-healthcheck --env-host=false \
        --http-proxy=false --unsetenv-all --env PATH=/usr/bin:/bin:/sbin --env HOME=/root --env RCLONE_CONFIG=/dev/null \
        --workdir / --entrypoint /bin/sh \
        "$pulled" -ceu '
            /backrest --version
            /bin/restic version
            rclone=$(/usr/bin/rclone version)
            nl=$(printf "\n."); nl=${nl%.}
            printf "%s\n" "${rclone%%"$nl"*}"
            /sbin/tini --version
            sha256sum -- /backrest /bin/restic /usr/bin/rclone /sbin/tini
        ' > "$work/inventory" 2> "$work/probe-errors" || {
            cat -- "$work/probe-errors" >&2
            br_fail '隔离镜像探针失败'
        }
    if [[ -s "$work/probe-errors" ]]; then
        cat -- "$work/probe-errors" >&2
        br_fail '隔离镜像探针返回诊断'
    fi
    inventory=$(br_inventory "$work/inventory" "$tag" "$revision" "$arch") || exit 1
    printf 'release\t%s\nrevision\t%s\nplatform\tlinux/%s\nindex\t%s\nmanifest\t%s@%s\nimage\t%s\n%s\n' \
        "$tag" "$revision" "$arch" "$index" "$repo" "$digest" "$image" "$inventory"
)

case "$#:${1-}" in
    1:prepare-image) br_prepare_image; exit ;;
    1:check-sources) ;;
    0:|1:install|1:update|1:start|1:configure|1:stop|1:retire)
        br_fail 'Backrest 生产操作尚未交付：先验收受控维护窗口内的调度停用、空闲检查和正常退出。' ;;
    *) printf '用法：bash backrest.sh {prepare-image|check-sources}\n' >&2; exit 2 ;;
esac

ctrsvc-check
BACKREST_DIR="$HOME/containers/backrest"
SOURCE_FILE="$BACKREST_DIR/sources.tsv"
[[ -f "$SOURCE_FILE" && -r "$SOURCE_FILE" ]] \
  || { printf '无法读取备份源配置: %s\n' "$SOURCE_FILE" >&2; exit 1; }
# Bash 的普通 read 会忽略 NUL，先拒绝以免路径被静默改写。
if IFS= read -r -d '' invalid < "$SOURCE_FILE"; then
    printf '备份源配置不能包含 NUL 字符\n' >&2
    exit 1
fi

BACKUP_IDS=()
BACKUP_SOURCES=()
BACKUP_MOUNTS=()
protected_trees=("$HOME/.local/share/containers/storage")
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ -n "$runtime_dir" && "$runtime_dir" == /* && -d "$runtime_dir" ]]; then
    protected_trees+=("$runtime_dir")
fi
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    [[ -n "$line" ]] || continue
    [[ "$line" == *$'\t'* ]] \
      || { printf '备份源第 %s 行缺少 Tab 分隔符\n' "$line_number" >&2; exit 1; }
    source_id="${line%%$'\t'*}"
    source_path="${line#*$'\t'}"
    [[ "$source_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] \
      || { printf '备份源第 %s 行标识无效\n' "$line_number" >&2; exit 1; }
    [[ "$source_path" == /* && "$source_path" != *[[:cntrl:]]* ]] \
      || { printf '备份源第 %s 行须为不含控制字符的绝对路径\n' "$line_number" >&2; exit 1; }
    for existing_id in "${BACKUP_IDS[@]}"; do
        [[ "$source_id" != "$existing_id" ]] \
          || { printf '备份源标识重复: %s\n' "$source_id" >&2; exit 1; }
    done
    # 尾部标记避免命令替换吞掉符号链接目标中的换行。
    resolved=$(realpath -e -- "$source_path" && printf '.') \
      || { printf '无法解析备份源第 %s 行\n' "$line_number" >&2; exit 1; }
    resolved="${resolved%$'\n.'}"
    [[ "$resolved" != *[[:cntrl:]]* && -r "$resolved" ]] \
      && { [[ -f "$resolved" ]] || [[ -d "$resolved" && -x "$resolved" ]]; } \
      || { printf '备份源不是可读文件或可遍历目录: %q\n' "$resolved" >&2; exit 1; }
    if [[ "$resolved" == / || "$resolved" == "$HOME" || "$HOME" == "$resolved/"* || "$resolved" == "$HOME/containers" ]]; then
        printf '备份源第 %s 行覆盖业务 HOME 或 containers 根: %q\n' "$line_number" "$resolved" >&2
        exit 1
    fi
    for protected in "${protected_trees[@]}"; do
        [[ -n "$protected" && "$protected" == /* ]] || continue
        if [[ "$resolved" == "$protected" || "$resolved" == "$protected/"* || "$protected" == "$resolved/"* ]]; then
            printf '备份源第 %s 行与业务存储或运行目录重叠: %q\n' "$line_number" "$resolved" >&2
            exit 1
        fi
    done
    for existing_source in "${BACKUP_SOURCES[@]}"; do
        if [[ "$resolved" == "$existing_source" ]]; then
            printf '备份源第 %s 行物理路径与已有来源重复: %q\n' "$line_number" "$resolved" >&2
            exit 1
        fi
        if [[ "$resolved" == "$existing_source/"* || "$existing_source" == "$resolved/"* ]]; then
            printf '备份源第 %s 行与已有来源存在父子嵌套重叠: %q\n' "$line_number" "$resolved" >&2
            exit 1
        fi
    done
    BACKUP_IDS+=("$source_id")
    BACKUP_SOURCES+=("$resolved")
    # Podman --mount 使用 CSV 字段；双引号在字段中写成两个双引号。
    mount_source="${resolved//\"/\"\"}"
    BACKUP_MOUNTS+=("type=bind,\"source=$mount_source\",target=/backup/$source_id,readonly,bind-nonrecursive")
done < "$SOURCE_FILE"

printf '拟议的业务挂载（CSV，仅预检）：\n'
if (( ${#BACKUP_MOUNTS[@]} )); then
    printf '%s\n' "${BACKUP_MOUNTS[@]}"
else
    printf '无业务来源\n'
fi
