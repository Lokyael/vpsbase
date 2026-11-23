(
set -euo pipefail
ctrsvc-check
# Pod 创建标识是本部署的重试依据，不凭同名接管现有 Pod。
[[ $(realpath -m "$HOME/containers") == "$HOME/containers" ]] || exit 1
if [[ -e "$HOME/containers" || -L "$HOME/containers" ]]; then
    [[ ! -L "$HOME/containers" && $(stat -c '%F:%u' "$HOME/containers") == "directory:$(id -u)" ]] || exit 1
else mkdir -m 700 "$HOME/containers"; fi
record="$HOME/containers/gw.json"
rc=0
podman pod exists gw || rc=$?
case "$rc" in
    0|1) ;;
    *) printf '无法查询 gw Pod\n' >&2; exit "$rc" ;;
esac
if [[ ! -e "$record" && ! -L "$record" ]]; then
    [[ $rc == 1 ]] || { printf 'gw Pod 归属未知\n' >&2; exit 1; }
    token=$(openssl rand -hex 32)
    (set -o noclobber; jq -n --arg token "$token" '{token:$token}' > "$record")
fi
[[ -f "$record" && ! -L "$record" && $(stat -c %u "$record") == $(id -u) ]] || exit 1
token=$(jq -er '.token|select(test("^[0-9a-f]{64}$"))' "$record")
if [[ $rc == 1 ]]; then
    podman pod create --name gw --network pasta --exit-policy continue --label "io.ingress.pod=$token" -p 443:443
fi
podman pod inspect gw | jq -e --arg token "$token" '
  type == "array" and length == 1 and (.[0] |
    (.Id | test("^[0-9a-f]{64}$")) and
    .Name == "gw" and .Labels["io.ingress.pod"] == $token and .ExitPolicy == "continue" and
    (.SharedNamespaces | sort) == ["ipc","net","uts"] and .InfraConfig.HostNetwork == false and
    (.InfraConfig.PortBindings | keys) == ["443/tcp"] and
    (.InfraConfig.PortBindings["443/tcp"] | length) == 1 and
    .InfraConfig.PortBindings["443/tcp"][0].HostPort == "443" and
    (.InfraConfig.PortBindings["443/tcp"][0].HostIp | . == "" or . == "0.0.0.0"))' >/dev/null \
    || { printf '无法确认 gw Pod 的归属、网络、发布映射或退出策略\n' >&2; exit 1; }
)
