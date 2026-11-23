#!/usr/bin/env bash
# ==============================================================================
# build-vps2arch.sh
# 作用：从固定上游提取 Arch Linux 重装组件，校验摘要，剪枝加固并内联依赖，
#      生成 vps2arch.sh 及最小行为审计补丁 vps2arch.patch。
# ==============================================================================
set -Eeuo pipefail

# 关闭 Windows Git Bash (MSYS) 路径转换，保证 Unix 路径原样输出
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
export LC_ALL=C

# 定位仓库根目录，统一以相对路径操作，消除驱动器盘符与反斜杠转义歧义
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../../.." &>/dev/null && pwd)
cd "$REPO_ROOT"

OBJECT_DIR="server/os/reinstall"
BUILD_ASSET_DIR="$OBJECT_DIR/build"
BUILDER_PATH="$BUILD_ASSET_DIR/build-vps2arch.sh"
OUTPUT_SCRIPT="$OBJECT_DIR/vps2arch.sh"
OUTPUT_PATCH="$BUILD_ASSET_DIR/vps2arch.patch"

UPSTREAM_REPO="bin456789/reinstall"
# 审计检查点：已验证至 2fcd14b (2026-11-18)
UPSTREAM_COMMIT="2fcd14b4564bc21740b85d473b4a140e283bf292"
UPSTREAM_BASE_URL="https://raw.githubusercontent.com/${UPSTREAM_REPO}/${UPSTREAM_COMMIT}"

UPSTREAM_FILES=(
    "reinstall.sh:7627cd10d50b14ebec8960e0bd28cbe4d8d42a53d705cf7282295f4c767a540f"
    "trans.sh:7bc4a823fd95ecf2104a4f4919d1534c73f003997619d8fecb2b467bdd33b848"
    "initrd-network.sh:f55fd4fb35acec6fec4b1cccc9fd75782c06941c98ec8351c094eaa4081eca9c"
    "fix-eth-name.sh:4b4505ce0ddc40e90dc12d369460136fa9add6cb2dbea6df280650b9517ebd9f"
    "fix-eth-name.service:dc667f379b23b13f51f22f8e609bed19e544fcca94b2037faa99bc7f04a90050"
    "ttys.sh:758f059c42008e89dc4df44a8da893aad8980765fa2ae06779224e96c00c3b74"
)

UPSTREAM_DIR=""
CHECK_ONLY=0

usage() {
    cat <<EOF
Usage: bash ${BUILDER_PATH} [--upstream-dir DIR] [--check]
  --upstream-dir DIR  从本地目录读取 6 份上游源文件并校验 SHA-256（离线构建）
  --check             构建到临时目录并与仓内产物逐字节比对，不改写工作区文件
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --upstream-dir)
                (( $# >= 2 )) && [[ -n "$2" ]] || { usage >&2; exit 1; }
                UPSTREAM_DIR=$2
                shift 2
                ;;
            --check)
                CHECK_ONLY=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 1
                ;;
        esac
    done
}

BUILD_DIR=$(mktemp -d "$BUILD_ASSET_DIR/.build_tmp_XXXXXX")
STAGES_DIR="$BUILD_DIR/stages"
cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT
mkdir -p "$STAGES_DIR"

main() {
    parse_args "$@"
    fetch_upstream
    prune_upstream
    cp "$BUILD_DIR/reinstall.sh" "$STAGES_DIR/01-pruned-reinstall.sh"
    cp "$BUILD_DIR/trans.sh" "$STAGES_DIR/01-pruned-trans.sh"

    write_snippets
    patch_source_hardening
    patch_rescue_inlines
    patch_source_wizard
    patch_rescue_hardening_and_gates

    generate_audit_patch
    inline_artifacts
    verify_and_publish
}

apply_awk() {
    local target=$1 stage=$2
    shift 2
    local staged="$BUILD_DIR/.stage.tmp"
    if ! awk "$@" "$target" > "$staged"; then
        printf '❌ 构建阶段失败: %s\n' "$stage" >&2
        exit 1
    fi
    mv -f "$staged" "$target"
}

assert_no_heredoc_marker() {
    local file=$1 marker=$2
    if grep -Fxq "$marker" "$file"; then
        printf '❌ 内联源文件包含冲突的 heredoc 定界符 (%s): %s\n' "$marker" "$file" >&2
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 1. 上游抓取与 SHA-256 锁定校验（阶段 1–2）
# ------------------------------------------------------------------------------
fetch_upstream() {
    local entry file expected actual
    local -a curl_fetch=(curl -fsSL --retry 3 --retry-delay 2)
    if [[ -n "$UPSTREAM_DIR" ]]; then
        [[ -d "$UPSTREAM_DIR" ]] || { printf '❌ 上游目录不存在: %s\n' "$UPSTREAM_DIR" >&2; exit 1; }
        printf '▶ 1. 读取本地上游组件 (Commit: %s, Dir: %s)...\n' "$UPSTREAM_COMMIT" "$UPSTREAM_DIR"
    else
        printf '▶ 1. 抓取上游组件 (Commit: %s)...\n' "$UPSTREAM_COMMIT"
    fi

    for entry in "${UPSTREAM_FILES[@]}"; do
        file=${entry%%:*}
        expected=${entry#*:}
        if [[ -n "$UPSTREAM_DIR" ]]; then
            cp -- "$UPSTREAM_DIR/$file" "$BUILD_DIR/$file"
        else
            "${curl_fetch[@]}" "${UPSTREAM_BASE_URL}/${file}" -o "$BUILD_DIR/$file"
        fi
        actual=$(sha256sum "$BUILD_DIR/$file" | awk '{print $1}')
        if [[ "$actual" != "$expected" ]]; then
            printf '❌ 上游文件 SHA-256 不匹配 (%s): expected=%s actual=%s\n' "$file" "$expected" "$actual" >&2
            exit 1
        fi
    done
}

prune_upstream() {
    printf '▶ 2. 剪枝优化：按函数体精确剔除无关系统、Web 控制台与 frpc...\n'

    # 2.1 剪除 trans.sh 中的无关安装分支、Web 控制台、frpc 与死代码（按函数体闭合边界）
    apply_awk "$BUILD_DIR/trans.sh" "2.1 trans.sh 剪枝" '
        BEGIN {
            drop["setup_nginx"] = 1; drop["setup_websocketd"] = 1
            drop["setup_web_if_enough_ram"] = 1; drop["setup_lighttpd"] = 1
            drop["add_user_if_need_for_alpine"] = 1; drop["refind_main_disk"] = 1
            drop["install_qcow_by_copy"] = 1
            drop["get_frpc_url"] = 1; drop["add_frpc_systemd_service_if_need"] = 1

            stub["install_alpine"] = "Alpine is not supported in this build."
            stub["install_nixos"] = "NixOS is not supported in this build."
            stub["install_fnos"] = "fnOS is not supported in this build."
            stub["install_windows"] = "Windows is not supported in this build."
            stub["install_redhat_ubuntu"] = "RedHat/Ubuntu is not supported in this build."
        }
        !skip_top && !skip_nested && /^[a-zA-Z0-9_]+\(\) \{$/ {
            name = $1; sub(/\(\)$/, "", name)
            if (name in drop) {
                skip_top = 1; dropped[name]++; next
            }
            if (name in stub) {
                printf "%s() {\n    error_and_exit \"%s\"\n}\n", name, stub[name]
                skip_top = 1; stubbed[name]++; next
            }
            if (name == "modify_windows") {
                print "modify_windows() { :; }"
                skip_top = 1; stubbed[name]++; next
            }
        }
        skip_top {
            if ($0 == "}") skip_top = 0
            next
        }
        !skip_nested && /^    install_(gentoo|aosc)\(\) \{$/ {
            name = $1; sub(/\(\)$/, "", name)
            printf "    %s() { :; }\n", name
            skip_nested = 1; nested[name]++; next
        }
        skip_nested {
            if ($0 == "    }") skip_nested = 0
            next
        }
        # 简化 add_default_efi_to_nvram 中的 true || 恒真旧查询
        $0 ~ /^        if true \|\| ! efibootmgr \| grep -i / {
            while ((getline line) == 1 && line != "        fi") {
                sub(/^    /, "", line)
                print line
            }
            if (line != "        fi") exit 1
            efi_simplify++; next
        }
        $0 == "        setup_web_if_enough_ram" { web_call++; next }
        $0 == "    web_port=${web_port:-80}" { web_default++; next }
        $0 == "    # frpc" {
            if ((getline line) != 1 || line != "    add_frpc_systemd_service_if_need $os_dir") exit 1
            frpc_basic++; next
        }
        $0 == "# 设置 frpc" {
            if ((getline line) != 1 || line != "# 并防止重复运行" ||
                (getline line) != 1 || line != "if ls /configs/frpc.* >/dev/null 2>&1 && ! pidof frpc >/dev/null; then") exit 1
            while ((getline line) == 1 && line != "fi") {}
            if (line != "fi") exit 1
            frpc_rescue++; next
        }
        $0 == "# 正式运行重装" {
            print
            if ((getline) != 1 || $0 != "# shellcheck disable=SC2046,SC2194" ||
                (getline) != 1 || $0 != "case 1 in" || (getline) != 1 || $0 != "1)" ||
                (getline) != 1 || $0 != "    # ChatGPT 说这种性能最高" ||
                (getline) != 1 || $0 != "    exec > >(exec tee $(get_ttys /dev/) /reinstall.log) 2>&1") exit 1
            print "# shellcheck disable=SC2046"
            sub(/^    /, ""); print
            if ((getline) != 1 || $0 != "    trans") exit 1
            sub(/^    /, ""); print
            if ((getline) != 1 || $0 != "    ;;" || (getline) != 1 || $0 != "2)") exit 1
            while ((getline) == 1 && $0 != "esac") {}
            if ($0 != "esac") exit 1
            log_case++; next
        }
        { print }
        END {
            for (k in drop) if (dropped[k] != 1) bad = bad " drop:" k "=" dropped[k]
            for (k in stub) if (stubbed[k] != 1) bad = bad " stub:" k "=" stubbed[k]
            if (stubbed["modify_windows"] != 1) bad = bad " modify_windows"
            if (nested["install_gentoo"] != 1 || nested["install_aosc"] != 1) bad = bad " nested"
            if (skip_top || skip_nested || web_call != 1 || web_default != 1 || log_case != 1 ||
                efi_simplify != 1 || frpc_basic != 1 || frpc_rescue != 1 || bad != "") {
                printf "trans.sh prune mismatch: bad=%s web=%d/%d log=%d efi=%d frpc=%d/%d unclosed=%d\n",
                    bad, web_call, web_default, log_case, efi_simplify, frpc_basic, frpc_rescue,
                    (skip_top || skip_nested) > "/dev/stderr"
                exit 1
            }
        }
    '

    # 2.2 剪除 reinstall.sh 中的无关 setos_* 函数（保留 setos_alpine 与 setos_arch）与死分支
    apply_awk "$BUILD_DIR/reinstall.sh" "2.2 reinstall.sh 剪枝" '
        !skip_setos && /^    setos_[a-zA-Z0-9_.-]+\(\) \{$/ {
            name = $1; sub(/\(\)$/, "", name)
            if (name != "setos_alpine" && name != "setos_arch") {
                skip_setos = 1; pruned_setos++; next
            }
            kept_setos[name]++
        }
        skip_setos {
            if ($0 == "    }") skip_setos = 0
            next
        }
        /^save_password\(\) \{/ { in_save_pw = 1 }
        in_save_pw && /^}/ { in_save_pw = 0 }
        in_save_pw && $0 == "    if false; then" { pw_dead = 1; pw_pruned++; next }
        pw_dead && $0 == "    fi" { pw_dead = 0; next }
        /^cp_boot_files_to_btrfs_root\(\) \{/ { dead_func = 1; next }
        dead_func && /^}/ { dead_func = 0; defs++; next }
        /^if false && is_need_boot_vmlinuz; then$/ { dead_branch = 1; next }
        dead_branch && /^fi$/ { dead_branch = 0; branches++; next }
        !dead_func && !dead_branch && !pw_dead { print }
        END {
            if (defs != 1 || branches != 1 || pruned_setos != 18 ||
                kept_setos["setos_alpine"] != 1 || kept_setos["setos_arch"] != 1 ||
                pw_pruned != 2 || dead_func || dead_branch || pw_dead || in_save_pw || skip_setos) {
                printf "reinstall.sh prune mismatch: defs=%d branches=%d setos=%d kept=%d/%d pw=%d unclosed=%d\n",
                    defs, branches, pruned_setos, kept_setos["setos_alpine"], kept_setos["setos_arch"], pw_pruned,
                    (dead_func || dead_branch || pw_dead || in_save_pw || skip_setos) > "/dev/stderr"
                exit 1
            }
        }
    '

    # 2.3 同步剪除源机的 Web 查看器、frpc 与无效 --commit 参数
    apply_awk "$BUILD_DIR/reinstall.sh" "2.3 移除 Web 查看器、frpc 与 --commit" '
        function expect(line) { if ((getline) != 1 || $0 != line) exit 1 }
        /^(get_http_log_url|is_need_web_viewer)\(\) \{$/ {
            if ((getline) != 1 || $0 !~ /^    /) exit 1
            expect("}"); expect("")
            helpers++; next
        }
        /^[[:blank:]]*\[--web-port[[:blank:]]+PORT\]$/ { help++; next }
        $0 == "web-port:|http-port:" { web_options++; next }
        $0 == "    --web-port | --http-port)" {
            expect("        is_port_valid $2 || error_and_exit \"Invalid $1 value: $2\"")
            expect("        web_port=$2"); expect("        shift 2"); expect("        ;;")
            web_parse++; next
        }
        $0 == "        username ssh_port rdp_port web_port web_path allow_ping; do" {
            sub(/ web_port web_path/, ""); cmdline++
        }
        $0 == "# web 路径" {
            expect("if is_need_web_viewer; then")
            if ((getline) != 1 || $0 !~ /^    web_path=/) exit 1
            expect("fi"); expect("")
            web_path++; next
        }
        $0 == "web_port=${web_port:-80}" { web_defaults++; next }
        $0 == "    echo \"WEB: $(get_http_log_url) (During installation only)\"" { web_output++; next }
        $0 == "    # 下载 websocketd" {
            expect("    # debian 11+ 才有 websocketd")
            expect("    if [ \"$distro\" = kali ] ||")
            expect("        { [ \"$distro\" = debian ] && [ \"$releasever\" -ge 11 ]; }; then")
            expect("        mkdir_clear $tmp/websocketd")
            expect("        download_and_extract_deb deb websocketd $tmp/websocketd")
            expect("        cp -f $tmp/websocketd/usr/bin/websocketd usr/bin/")
            expect("    fi"); expect("")
            packages++; next
        }
        $0 == "commit:" { commit_opt++; next }
        $0 == "    --commit)" {
            expect("        commit=$2"); expect("        shift 2"); expect("        ;;")
            commit_parse++; next
        }
        $0 == "frpc-conf:|frpc-config:" { frpc_opts++; next }
        $0 == "# 处理 --frpc-config 时会下载文件，因此在处理参数前就创建临时目录" { frpc_comment++; next }
        $0 == "    --frpc-conf | --frpc-config)" {
            while ((getline line) == 1 && line != "        ;;") {}
            if (line != "        ;;") exit 1
            frpc_parse++; next
        }
        $0 == "    if [ -n \"$frpc_config\" ]; then" {
            while ((getline line) == 1 && line != "    fi") {}
            if (line != "    fi") exit 1
            frpc_blocks++; next
        }
        { print }
        END {
            if (helpers != 2 || help != 1 || web_options != 3 || web_parse != 1 || cmdline != 1 ||
                web_path != 1 || web_defaults != 1 || web_output != 4 || packages != 1 ||
                commit_opt != 1 || commit_parse != 1 || frpc_opts != 3 || frpc_comment != 1 ||
                frpc_parse != 1 || frpc_blocks != 2) {
                printf "2.3 mismatch: web=%d/%d/%d/%d/%d/%d/%d/%d/%d commit=%d/%d frpc=%d/%d/%d/%d\n",
                    helpers, help, web_options, web_parse, cmdline, web_path, web_defaults, web_output, packages,
                    commit_opt, commit_parse, frpc_opts, frpc_comment, frpc_parse, frpc_blocks > "/dev/stderr"
                exit 1
            }
        }
    '
}

# ------------------------------------------------------------------------------
# 2. 源码补丁与门禁植入（阶段 3–5）
# ------------------------------------------------------------------------------
patch_source_hardening() {
    printf '▶ 3. 源码级补丁：恢复 TLS 校验证书、打通凭据持久化并消除外部脚本依赖...\n'

    apply_awk "$BUILD_DIR/reinstall.sh" "3.1 源机帮助、TLS、凭据、权限、confhome 与 initrd 加固" \
        -v usage_file="$BUILD_DIR/arch-usage.txt" \
        -v boot_copy_code="$BUILD_DIR/private-boot-copy.txt" \
        -v archive_file="$BUILD_DIR/initrd-archive.txt" \
        -v upstream_repo="$UPSTREAM_REPO" \
        -v upstream_commit="$UPSTREAM_COMMIT" '
        function move_boot_copy(marker, boundary,    line, before, copy) {
            while ((getline line) == 1 && line != marker) before = before line "\n"
            if (line != marker || !index(before, boundary) ||
                (getline line) != 1 || line != "        if is_boot_in_separate_partition; then") exit 1
            copy = marker "\n" line "\n"
            while ((getline line) == 1 && line != "        fi") copy = copy line "\n"
            if (line != "        fi" || !index(copy, "            cp_boot_files_to_dir ")) exit 1
            sub(/\n\n$/, "\n", before)
            printf "\n%s%s\n%s", copy, line, before
        }
        /^usage_and_exit\(\) \{$/ {
            while ((getline line < usage_file) > 0) print line
            close(usage_file)
            in_usage = 1; usage_replaced++; next
        }
        in_usage {
            if ($0 == "}") in_usage = 0
            next
        }
        $0 == "    # 32位 cygwin 已停止更新，证书可能有问题，先添加 --insecure" {
            curl_comment++; next
        }
        $0 == "        if command curl --insecure --connect-timeout 10 -f \"$@\"; then" {
            sub(/ --insecure/, "")
            curl_tls++
        }
        $0 == "        if command curl --insecure --connect-timeout 10 -Lfr 0-1048575 \"$url\" \\" {
            sub(/ --insecure/, "")
            test_url_tls++
        }
        $0 == "confhome=https://raw.githubusercontent.com/" upstream_repo "/main" {
            $0 = "confhome=https://raw.githubusercontent.com/" upstream_repo "/" upstream_commit
            pin_main++
        }
        $0 == "confhome_cn=https://cnb.cool/" upstream_repo "/-/git/raw/main" {
            $0 = "confhome_cn=https://cnb.cool/" upstream_repo "/-/git/raw/" upstream_commit
            pin_cn++
        }
        $0 == "set -eE" { print "{ set +x; } 2>/dev/null"; trace++ }
        $0 == "        set -x" {
            print "        error_and_exit \047重装入口不支持 --debug 或 -x 跟踪。\047"
            if ((getline) != 1 || $0 != "        shift") exit 1
            debug++; next
        }
        $0 == "    # 不能同时使用证书和密码" {
            if ((getline) != 1 || $0 != "    if [ -n \"$password\" ] && [ -n \"$ssh_keys\" ]; then" ||
                (getline) != 1 || $0 != "        error_and_exit \"Cannot set both password and ssh key.\"" ||
                (getline) != 1 || $0 != "    fi") exit 1
            mutex_removed++; next
        }
        $0 == "mkdir_clear \"$tmp\"" { $0 = "(umask 077; mkdir_clear \"$tmp\")"; private_tmp++ }
        $0 == "    zcat /reinstall-initrd | cpio -idm \\" {
            print "    (set -o pipefail"
            print "    " $0
            if ((getline) != 1 || $0 != "        $(is_in_windows && echo --nonmatching \047dev/console\047 --nonmatching \047dev/null\047)") exit 1
            print "    " $0
            print "    ) || error_and_exit \047无法解包救援 initrd。\047"
            unpack++; next
        }
        $0 == "    find . | cpio --quiet -o -H newc -R 0:0 | gzip -1 >/reinstall-initrd" {
            while ((getline line < archive_file) > 0) print line
            close(archive_file)
            pack++; next
        }
        $0 == "    mkdir -p $initrd_dir/configs" {
            print "    if [ \"$distro\" = arch ]; then"
            print "        (umask 077; mkdir -- \"$initrd_dir/configs\") || error_and_exit \047无法创建私有的救援配置目录。\047"
            print "    else"
            print "    " $0
            print "    fi"
            configs++
            if ((getline l0) != 1 || l0 != "    if [ -n \"$ssh_keys\" ]; then" ||
                (getline l1) != 1 || l1 != "        cat <<<\"$ssh_keys\" >$initrd_dir/configs/ssh_keys" ||
                (getline l2) != 1 || l2 != "    else" ||
                (getline l3) != 1 || l3 != "        save_password $initrd_dir/configs" ||
                (getline l4) != 1 || l4 != "    fi") exit 1
            print l0; print l1; print "    fi"; print "    if [ -n \"$password\" ]; then"; print l3; print l4
            both_creds++; next
        }
        $0 == "        crypted=$(python2 -c \"import crypt, sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))\" \"$password\")" {
            $0 = "        crypted=$(printf \047%s\047 \"$password\" | python2 -c \"import crypt, sys; print(crypt.crypt(sys.stdin.read(), crypt.mksalt(crypt.METHOD_SHA512)))\")"
            hash_stdin++
        }
        $0 == "    echo \"$crypted\" >\"$dir/password-linux-sha512\"" {
            print "    if [ \"$distro\" = arch ]; then"
            print "        valid_arch_password_hash \"$crypted\" || error_and_exit \047未生成单条有效的 SHA-512 密码摘要。\047"
            print "        (umask 077; printf \047%s\\n\047 \"$crypted\" >\"$dir/password-linux-sha512\")"
            print "    else"
            print "    " $0
            print "    fi"
            hash++; next
        }
        $0 == "    curl -Lo /reinstall-initrd $nextos_initrd" {
            print "    if [ \"$distro\" = arch ]; then install -m 0600 -- /dev/null /reinstall-initrd; fi"
            archive++
        }
        $0 == "        cp -f /reinstall-initrd \"$dir\"" {
            print "        if [ \"$distro\" = arch ]; then"
            while ((getline line < boot_copy_code) > 0) print line
            close(boot_copy_code)
            print "        else"
            print "    " $0
            print "        fi"
            boot_copy++; next
        }
        $0 == "        extlinux_dir=\"$(dirname \"$target_cfg\")\"" {
            print
            move_boot_copy("        # 复制文件到 extlinux 工作目录", "        extlinux --once=reinstall ")
            extlinux_order++; next
        }
        $0 == "        info limine" {
            print
            if ((getline) != 1 || $0 != "        echo \"$target_cfg\"") exit 1
            print
            move_boot_copy("        # 复制文件到 boot/limine 分区根目录", "        echo \"default_entry: ")
            limine_order++; next
        }
        { print }
        END {
            if (usage_replaced != 1 || in_usage || curl_comment != 1 || curl_tls != 1 || test_url_tls != 1 ||
                trace != 1 || debug != 1 || mutex_removed != 1 || private_tmp != 1 || configs != 1 ||
                both_creds != 1 || pin_main != 1 || pin_cn != 1 || unpack != 1 || pack != 1 ||
                hash != 1 || hash_stdin != 1 || archive != 1 || boot_copy != 1 || extlinux_order != 1 || limine_order != 1) {
                printf "3.1 mismatch: usage=%d tls=%d/%d/%d trace=%d debug=%d mutex=%d tmp=%d cfg=%d creds=%d pin=%d/%d arc=%d/%d/%d hash=%d/%d copy=%d ext=%d lim=%d\n",
                    usage_replaced, curl_comment, curl_tls, test_url_tls, trace, debug, mutex_removed, private_tmp, configs, both_creds,
                    pin_main, pin_cn, unpack, pack, archive, hash, hash_stdin, boot_copy, extlinux_order, limine_order > "/dev/stderr"
                exit 1
            }
        }
    '
}

patch_rescue_inlines() {
    apply_awk "$BUILD_DIR/trans.sh" "3.2 trans.sh 占位内联与 networkd 账号修正" \
        -v ttys_file="$BUILD_DIR/get-ttys-placeholder.txt" \
        -v fix_file="$BUILD_DIR/fix-eth-placeholder.txt" \
        -v account="$BUILD_DIR/networkd-account.txt" '
        /^get_ttys\(\) \{$/ {
            while ((getline line < ttys_file) > 0) print line
            close(ttys_file)
            in_ttys = 1; ttys_matched++; next
        }
        in_ttys {
            if ($0 == "}") in_ttys = 0
            next
        }
        /^add_fix_eth_name_systemd_service\(\) \{$/ {
            while ((getline line < fix_file) > 0) print line
            close(fix_file)
            in_fix = 1; fix_matched++; next
        }
        in_fix {
            if ($0 == "}") in_fix = 0
            next
        }
        $0 == "        # cloud-init 渲染 networkd 配置时，系统要有 systemd-network 用户，不然会报错" {
            if ((getline) != 1 || $0 != "        # 加 || true 防止第二次运行报错" ||
                (getline) != 1 || $0 != "        useradd --system systemd-network || true" ||
                (getline) != 1 || $0 != "        cloud-init devel net-convert -p net.cfg -k yaml -d out -D alpine -O networkd" ||
                (getline) != 1 || $0 != "        userdel -r systemd-network") exit 1
            while ((getline line < account) > 0) print line
            close(account)
            net_matched++; next
        }
        { print }
        END {
            if (ttys_matched != 1 || fix_matched != 1 || net_matched != 1 || in_ttys || in_fix) exit 1
        }
    '
}

patch_source_wizard() {
    printf '▶ 4. 植入入口向导：交互采集、CLI 收敛与共同的目标确认...\n'

    apply_awk "$BUILD_DIR/reinstall.sh" "4 植入向导、用户名校验与源机门禁" \
        -v username_file="$BUILD_DIR/username.txt" \
        -v wizard="$BUILD_DIR/wizard.txt" \
        -v disk="$BUILD_DIR/arch-disk.txt" \
        -v hash="$BUILD_DIR/arch-password.txt" \
        -v ip_recheck_file="$BUILD_DIR/arch-ip-recheck.txt" \
        -v confirm_hooks_file="$BUILD_DIR/arch-confirm-hooks.txt" '
        /^assert_username_valid\(\) \{$/ {
            while ((getline line < username_file) > 0) print line
            close(username_file)
            validators++; skipping = 1; next
        }
        /^prompt_username\(\) \{$/ { prompts++; skipping = 1; next }
        skipping && /^}$/ { skipping = 0; next }
        skipping { next }
        $0 == "get_local_bootloader_type() {" { boot_type = 1 }
        $0 == "    if [ -z \"$_bootloader_type\" ]; then" && boot_type {
            print "    local use_source_boot_disk=false"
            print "    case \"$distro\" in arch | reset) use_source_boot_disk=true ;; esac"
            $0 = "    if $use_source_boot_disk || [ -z \"$_bootloader_type\" ]; then"
            bios_cache++
        }
        boot_type && $0 == "        find_main_disk" {
            print "        local boot_disk"
            print "        if $use_source_boot_disk; then"
            print "            boot_disk=$(find_arch_bios_boot_disk) || error_and_exit \047无法从源系统 /boot 确认唯一的 BIOS 引导候选盘。\047"
            print "        else"
            print "            find_main_disk"
            print "            boot_disk=$xda"
            print "        fi"
            bios_disk++; next
        }
        boot_type && /head -c 446 \/dev\/\$xda/ { sub(/\/dev\/\$xda/, "\"/dev/$boot_disk\""); bios_reads++ }
        boot_type && $0 == "}" { boot_type = 0 }
        $0 == "init_bootloader_facts" {
            $0 = "if [ \"$distro\" != arch ]; then init_bootloader_facts; fi"
            init_early++
        }
        $0 == "    for key in confhome hold force_boot_mode force_cn cloud_image no_cloud_kernel main_disk \\" {
            print; print "        arch_ipv4_mode \\"; cmdline++; next
        }
        $0 == "collect_netconf() {" {
            print; print "    local probe_output"; in_collect = 1; next
        }
        in_collect && /via_gateway_dev_ethx=\$\(ip -\$v route show default \| / {
            print "            # Preserve each ip status for the confirmed IPv4 handoff; keep upstream selection."
            print "            probe_output=$(ip -\"$v\" route show default) || [[ \"$v:${1:-}\" != 4:require-ipv4-probes ]] || return 1"
            print "            if [[ \"$v:${2:-}\" == 4:capture-ipv4-evidence ]]; then ipv4_routes=$probe_output; fi"
            sub(/ip -\$v route show default/, "printf \047%s\\n\047 \"$probe_output\"")
            route_probe++
        }
        in_collect && /_mac "\$\(ip link show dev \$ethx \| / {
            print "                probe_output=$(ip link show dev \"$ethx\") || [[ \"$v:${1:-}\" != 4:require-ipv4-probes ]] || return 1"
            sub(/ip link show dev \$ethx/, "printf \047%s\\n\047 \"$probe_output\"")
            mac_probe++
        }
        in_collect && /all_addrs=\$\(ip -\$v -o addr show scope global dev \$ethx \| / {
            print "                probe_output=$(ip -\"$v\" -o addr show scope global dev \"$ethx\") || [[ \"$v:${1:-}\" != 4:require-ipv4-probes ]] || return 1"
            print "                if [[ \"$v:${2:-}\" == 4:capture-ipv4-evidence ]]; then ipv4_addresses=$probe_output; fi"
            sub(/ip -\$v -o addr show scope global dev \$ethx/, "printf \047%s\\n\047 \"$probe_output\"")
            address_probe++
        }
        in_collect && $0 == "}" { in_collect = 0 }
        $0 == "get_ip_conf_cmd() {" { in_ip_conf = 1 }
        in_ip_conf && $0 == "    collect_netconf >&2" {
            while ((getline line < ip_recheck_file) > 0) print line
            close(ip_recheck_file)
            ip_recheck++; next
        }
        in_ip_conf && $0 == "}" { in_ip_conf = 0 }
        $0 == "    insert_into_file init after \047configure_ip\\(\\)\047 <<EOF" {
            print "    ip_conf_cmd=$(get_ip_conf_cmd)"; prepare_conf++
        }
        $0 == "        $(get_ip_conf_cmd)" { $0 = "        $ip_conf_cmd"; embed_conf++ }
        $0 == "# 第一遍扫描" {
            while ((getline s < disk) > 0) print s; close(disk)
            while ((getline s < hash) > 0) print s; close(hash)
            while ((getline s < wizard) > 0) print s; close(wizard)
            print ""
            wizards++
        }
        $0 == "        verify_os_name \"$@\"" {
            print "        if [ $# -eq 0 ]; then set -- arch; fi"
            print
            print "        case \"$distro\" in"
            print "            arch | reset) ;;"
            print "            *) error_and_exit \"本构建仅支持 Arch Linux 重装与 reset，不支持目标：$distro\" ;;"
            print "        esac"
            os_gate++; next
        }
        $0 == "    --ssh-port)" {
            print
            if ((getline) != 1 || $0 != "        is_port_valid $2 || error_and_exit \"Invalid $1 value: $2\"") exit 1
            print "        assert_arch_ssh_port \"$2\""
            ports++; next
        }
        $0 == "# 第二遍扫描" {
            print "unset xda main_disk arch_confirmed_ipv4 arch_ipv4_mode ssh_keys username password ssh_port"
            parses++
        }
        $0 == "  --ssh-key \"ssh-rsa ...\"" || $0 == "  --ssh-key \"ecdsa-sha2-nistp256/384/521 ...\"" ||
            $0 == "  --ssh-key http://path/to/public_key" || $0 == "  --ssh-key C:\\path\\to\\public_key" {
            key_help_pruned++; next
        }
        $0 == "        gh:* | github:* | gl:* | gitlab:* | http://* | https://*)" {
            print "        http://*) ssh_key_error_and_exit \047远程公钥来源必须使用 HTTPS。\047 ;;"
            sub(/ \| http:\/\/\*/, "")
        }
        $0 == "            if ! ssh_key=$(curl -L \"$key_url\"); then" {
            sub(/curl -L/, "curl -fsSL --proto =https --proto-redir =https"); remote++
        }
        $0 == "if ! { is_netboot_xyz || [ \"$distro\" = talos ]; }; then" && previous == "# 用户名密码" {
            $0 = "if [ \"$distro\" != arch ] && ! { is_netboot_xyz || [ \"$distro\" = talos ]; }; then"
        }
        $0 == "        is_valid_ssh_key() {" {
            print "        command -v ssh-keygen >/dev/null || error_and_exit \047缺少 ssh-keygen，无法校验 Ed25519 公钥。\047"
            if ((getline) != 1 || $0 !~ /^            grep -qE / || (getline) != 1 || $0 != "        }") exit 1
            key_functions++; next
        }
        /if (! )?is_valid_ssh_key / { sub(/is_valid_ssh_key/, "validate_arch_keys"); key_calls++ }
        $0 == "        xda=${2##*/dev/}" {
            print "        xda=${2#/dev/}"
            print "        [[ \"$xda\" =~ ^[a-zA-Z0-9_.-]+$ ]] || error_and_exit \047请指定整盘的内核设备名，例如 /dev/vda。\047"
            disk_args++; next
        }
        $0 == "# 检查内存" {
            while ((getline line < confirm_hooks_file) > 0) print line
            close(confirm_hooks_file)
            print ""
            confirms++
        }
        $0 == "THIS_SCRIPT=$(readlink -f \"$0\")" {
            print
            print "printf -v reinstall_reset \047bash %q reset\047 \"$THIS_SCRIPT\""
            reset_command++; next
        }
        /^    warn false / && sub(/\$reinstall_____ reset/, "$reinstall_reset") { reset_hints++ }
        $0 ~ /^    warn false "If you want to cancel the reinstallation, run / {
            print
            if ((getline) != 1 || $0 != "    warn false \047**********************************\047") exit 1
            print
            print "    if [ \"$distro\" = arch ]; then printf \047本次已安排重装\\n\047; fi"
            scheduled++; next
        }
        { print; previous = $0 }
        END {
            if (validators != 1 || prompts != 1 || skipping ||
                wizards != 1 || os_gate != 1 || ports != 1 || parses != 1 || key_help_pruned != 4 ||
                key_functions != 1 || key_calls != 2 || disk_args != 1 || confirms != 1 ||
                remote != 1 || cmdline != 1 || route_probe != 1 || mac_probe != 1 || address_probe != 1 ||
                ip_recheck != 1 || prepare_conf != 1 || embed_conf != 1 || bios_disk != 1 || bios_reads != 2 || bios_cache != 1 ||
                init_early != 1 || reset_command != 1 || reset_hints != 10 || scheduled != 1) {
                printf "4 mismatch: val=%d prm=%d wiz=%d os=%d ports=%d parses=%d kh=%d kf=%d/%d disk=%d cfm=%d hints=%d sched=%d\n",
                    validators, prompts, wizards, os_gate, ports, parses, key_help_pruned, key_functions, key_calls, disk_args, confirms, reset_hints, scheduled > "/dev/stderr"
                exit 1
            }
        }
    '
}

patch_rescue_hardening_and_gates() {
    printf '▶ 5. 源码级补丁：固化 trans.sh 凭据设置与 Arch 终态安全加固...\n'

    # 5.1 用户创建、密码摘要读取与目标系统 SSH/Sudoers 加固
    apply_awk "$BUILD_DIR/trans.sh" "5.1 固化 Arch 目标加固" -v patch_file="$BUILD_DIR/basic_init_patch.txt" '
        $0 == "add_user_if_need() {" { add_user = 1 }
        add_user && $0 == "    if ! grep -q \"^$username:\" \"$os_dir/etc/passwd\"; then" {
            print "    if grep -q \"^$username:\" \"$os_dir/etc/passwd\"; then"
            print "        [ \"$distro\" != arch ] || error_and_exit \"The requested login user $username already exists. Choose a new username.\""
            print "    else"
            print "        if [ \"$?\" -ne 1 ] && [ \"$distro\" = arch ]; then"
            print "            error_and_exit \"Cannot read the account database under $os_dir.\""
            print "        fi"
            add_user = 0; account_gate++; next
        }
        $0 == "change_user_password() {" { password = 1 }
        password && $0 == "    if is_password_plaintext; then" {
            $0 = "    if [ \"$distro\" != arch ] && is_password_plaintext; then"
            hash_only++
        }
        password && index($0, "\"$username:$(get_password_linux_sha512)\" | chroot $os_dir chpasswd -e") {
            print "        local hash"
            print "        if [ \"$distro\" = arch ]; then"
            print "            hash=$(read_arch_password_hash) || error_and_exit \047Cannot read a valid Arch sudo password digest.\047"
            print "        else"
            print "            hash=$(get_password_linux_sha512) || error_and_exit \047Cannot read the saved password digest.\047"
            print "        fi"
            print "        printf \047%s\\n\047 \"$username:$hash\" | chroot \"$os_dir\" chpasswd -e"
            password = 0; hash_read++; next
        }
        /^basic_init\(\) \{$/ { basic = 1 }
        basic && /^    # sshd$/ { print "    if [ \"$distro\" != arch ]; then"; generic = 1 }
        basic && /# 公钥\/密码/ {
            if (!generic) exit 1
            print "    fi\n"
            generic = 0
            while ((getline line) > 0) {
                if (line ~ /change_ssh_conf_for_password_login/) {
                    getline line; break
                }
            }
            while ((getline s < patch_file) > 0) print s
            close(patch_file)
            found++; basic = 0; next
        }
        { print (generic && length($0) ? "    " $0 : $0) }
        END { if (found != 1 || generic || account_gate != 1 || hash_only != 1 || hash_read != 1) exit 1 }
    '

    # 5.2 救援入口收敛、磁盘与固定 IPv4 擦盘门禁（内容结构锚定，零相对行号硬编码）
    apply_awk "$BUILD_DIR/trans.sh" "5.2 植入救援边界" \
        -v network_gate="$BUILD_DIR/arch-fixed-ipv4.txt" \
        -v disk="$BUILD_DIR/arch-disk.txt" \
        -v rescue_disk="$BUILD_DIR/arch-rescue-disk.txt" \
        -v hash="$BUILD_DIR/arch-password.txt" \
        -v rescue_password="$BUILD_DIR/arch-rescue-password.txt" \
        -v erase_gate="$BUILD_DIR/arch-erase-gate.txt" \
        -v erase_diag="$BUILD_DIR/arch-erase-diag.txt" '
        function emit_file(path,    line) {
            while ((getline line < path) > 0) print line
            close(path)
        }
        $0 == "error_and_exit() {" { in_err = 1 }
        in_err && $0 == "    if is_have_cmd sudo; then" {
            while ((getline line) == 1 && !index(line, "install Alpine Linux instead.")) {}
            if (!index(line, "install Alpine Linux instead.")) exit 1
            emit_file(erase_diag)
            err_replaced++; in_err = 0; next
        }
        in_err && $0 == "}" { in_err = 0 }
        $0 == "install_arch_gentoo_aosc() {" {
            emit_file(disk)
            emit_file(rescue_disk)
            emit_file(network_gate)
            print ""
            print
            installers++; next
        }
        $0 == "    wipefs -a -f /dev/$xda" {
            emit_file(erase_gate)
            print
            wipes++; next
        }
        $0 == "    # 需要在重新分区之前，找到主硬盘" {
            while ((getline line) == 1 && line != "    if [ -z \"$xda\" ]; then") {}
            if (line != "    if [ -z \"$xda\" ]; then" ||
                (getline line) != 1 || line != "        find_xda" ||
                (getline line) != 1 || line != "    fi") exit 1
            print "    if [ \"$distro\" = arch ]; then"
            print "        apk add lsblk blkid"
            print "        require_confirmed_arch_disk"
            print "    elif [ -z \"$xda\" ]; then"
            print "        find_xda"
            print "    fi"
            selections++; next
        }
        $0 == "extract_env_from_cmdline" {
            emit_file(hash)
            emit_file(rescue_password)
            print "unset main_disk xda arch_rescue_disk_instance arch_ipv4_mode arch_erase_started"
            print
            print "if [ \"$distro\" = arch ]; then require_arch_rescue_credentials; fi"
            extractions++; next
        }
        $0 == "# 带参数运行部分" {
            saw_update = 0; saw_alpine = 0; saw_unknown = 0
            while ((getline line) == 1 && line != "# 无参数运行部分") {
                if (line == "if [ \"$1\" = \"update\" ]; then") saw_update++
                if (line == "elif [ \"$1\" = \"alpine\" ]; then") saw_alpine++
                if (line == "    error_and_exit \"unknown option $1\"") saw_unknown++
            }
            if (line != "# 无参数运行部分" || saw_update != 1 || saw_alpine != 1 || saw_unknown != 1) exit 1
            print "if [ -n \"$1\" ]; then"
            print "    error_and_exit \"unknown option $1\""
            print "fi"
            print ""
            print line
            rescues++; next
        }
        { print }
        END {
            if (err_replaced != 1 || installers != 1 || wipes != 1 || selections != 1 ||
                extractions != 1 || rescues != 1 || in_err) {
                printf "5.2 mismatch: err=%d inst=%d wipe=%d sel=%d ext=%d res=%d\n",
                    err_replaced, installers, wipes, selections, extractions, rescues > "/dev/stderr"
                exit 1
            }
        }
    '
}

# ------------------------------------------------------------------------------
# 3. 补丁导出、静态内联与产物发布（阶段 6–8）
# ------------------------------------------------------------------------------
generate_audit_patch() {
    printf '▶ 6. 生成审计补丁 (Unified Diff)...\n'
    local component rc
    for component in reinstall trans; do
        diff -u -L "upstream/$component.sh" -L "vps2arch/$component.sh" \
            "$STAGES_DIR/01-pruned-$component.sh" "$BUILD_DIR/$component.sh" > "$BUILD_DIR/$component.patch" || {
            rc=$?
            if (( rc != 1 )); then
                printf '❌ 无法生成 %s 的审计补丁。\n' "$component" >&2
                exit "$rc"
            fi
        }
    done

    cat <<EOF_PATCH_HEADER > "$BUILD_DIR/vps2arch.patch"
# ==============================================================================
# AUDIT PATCH: Functional and security changes against upstream commit ${UPSTREAM_COMMIT}
# (Excludes dead-branch pruning & verbatim upstream file inlining)
# Generated automatically by ${BUILDER_PATH}.
# ==============================================================================
EOF_PATCH_HEADER
    cat "$BUILD_DIR/reinstall.patch" "$BUILD_DIR/trans.patch" | tr -d '\r' >> "$BUILD_DIR/vps2arch.patch"
}

inline_artifacts() {
    printf '▶ 7. 依赖展平与静态内联嵌入...\n'
    assert_no_heredoc_marker "$BUILD_DIR/ttys.sh" "EOF_INLINED_TTYS"
    assert_no_heredoc_marker "$BUILD_DIR/fix-eth-name.sh" "EOF_FIX_ETH_SH"
    assert_no_heredoc_marker "$BUILD_DIR/fix-eth-name.service" "EOF_FIX_ETH_SVC"
    assert_no_heredoc_marker "$BUILD_DIR/initrd-network.sh" "EOF_INLINED_NETWORK"

    # 7.1 将上游 ttys.sh、fix-eth-name.sh 与 fix-eth-name.service 原文展开至 trans.sh
    apply_awk "$BUILD_DIR/trans.sh" "7.1 展开 trans.sh 内联上游文件" \
        -v ttys_src="$BUILD_DIR/ttys.sh" \
        -v fix_sh="$BUILD_DIR/fix-eth-name.sh" \
        -v fix_svc="$BUILD_DIR/fix-eth-name.service" '
        function emit(path,    line) {
            while ((getline line < path) > 0) print line
            close(path)
        }
        $0 == "# @@INLINE:ttys.sh@@" { emit(ttys_src); ttys++; next }
        $0 == "# @@INLINE:fix-eth-name.sh@@" { emit(fix_sh); sh++; next }
        $0 == "# @@INLINE:fix-eth-name.service@@" { emit(fix_svc); svc++; next }
        { print }
        END {
            if (ttys != 1 || sh != 1 || svc != 1) {
                printf "7.1 inline mismatch: ttys=%d sh=%d svc=%d\n", ttys, sh, svc > "/dev/stderr"
                exit 1
            }
        }
    '

    assert_no_heredoc_marker "$BUILD_DIR/trans.sh" "EOF_INLINED_TRANS"

    # 7.2 将 trans.sh 与 initrd-network.sh 原文展开至 reinstall.sh
    apply_awk "$BUILD_DIR/reinstall.sh" "7.2 展开 reinstall.sh 内联救援脚本" \
        -v trans_file="$BUILD_DIR/trans.sh" \
        -v net_file="$BUILD_DIR/initrd-network.sh" '
        /curl -Lo \$initrd_dir\/trans.sh/ {
            if (in_replace) exit 1
            in_replace = 1
            print "    # [Inlined Components] 静态自包含展开，无需二次网络拉取"
            print "    cat <<\047EOF_INLINED_TRANS\047 > \"$initrd_dir/trans.sh\""
            while ((getline line < trans_file) > 0) print line
            close(trans_file)
            print "EOF_INLINED_TRANS"
            print ""
            print "    cat <<\047EOF_INLINED_NETWORK\047 > \"$initrd_dir/initrd-network.sh\""
            while ((getline line < net_file) > 0) print line
            close(net_file)
            print "EOF_INLINED_NETWORK"
            next
        }
        in_replace && /chmod a\+x \$initrd_dir\/trans.sh/ {
            in_replace = 0
            replaced++
            print "    chmod a+x \"$initrd_dir/trans.sh\" \"$initrd_dir/initrd-network.sh\""
            next
        }
        !in_replace { print }
        END {
            if (in_replace || replaced != 1) {
                printf "7.2 inline mismatch: replaced=%d unclosed=%d\n", replaced, in_replace > "/dev/stderr"
                exit 1
            }
        }
    '

    tr -d '\r' < "$BUILD_DIR/reinstall.sh" > "$BUILD_DIR/vps2arch.raw.sh"

    cat <<EOF_HEADER > "$BUILD_DIR/vps2arch.sh"
#!/usr/bin/env bash
# ==============================================================================
# WARNING: THIS IS AN AUTO-GENERATED STATIC ARTIFACT. DO NOT EDIT DIRECTLY.
# Source: Built by ${BUILDER_PATH} from upstream commit ${UPSTREAM_COMMIT}.
# Audit: See ${OUTPUT_PATCH} for changes relative to the pruned upstream.
# ==============================================================================
EOF_HEADER
    tail -n +2 "$BUILD_DIR/vps2arch.raw.sh" >> "$BUILD_DIR/vps2arch.sh"
    chmod +x "$BUILD_DIR/vps2arch.sh"
}

verify_and_publish() {
    printf '▶ 8. 产物完整性、POSIX 救援片段与安全加固断言校验...\n'
    # 8.1 语法校验（Bash 全量 + 本地救援片段 POSIX sh -n）
    bash -n "$BUILD_DIR/vps2arch.sh"
    bash -n "$BUILD_DIR/trans.sh"
    bash -n "$BUILD_DIR/initrd-network.sh"
    sh -n "$BUILD_DIR/ttys.sh"
    sh -n "$BUILD_DIR/initrd-network.sh"

    local snippet
    for snippet in arch-password.txt arch-rescue-password.txt arch-disk.txt arch-rescue-disk.txt arch-fixed-ipv4.txt; do
        sh -n "$BUILD_DIR/$snippet"
    done
    for snippet in networkd-account.txt basic_init_patch.txt arch-erase-gate.txt arch-erase-diag.txt; do
        { printf 'snippet_check() {\n'; cat "$BUILD_DIR/$snippet"; printf '}\n'; } | sh -n
    done

    # 8.2 剪枝与占位展开断言
    if grep -q '@@INLINE:' "$BUILD_DIR/vps2arch.sh"; then
        echo "❌ 断言失败: 存在未展开的 @@INLINE 占位符" >&2; exit 1
    fi
    if grep -qE 'install_alpine\(\) \{[[:space:]]*echo' "$BUILD_DIR/vps2arch.sh" || ! grep -q 'Alpine is not supported in this build' "$BUILD_DIR/vps2arch.sh"; then
        echo "❌ 断言失败: Alpine 安装分支剪枝异常" >&2; exit 1
    fi
    if ! grep -q 'NixOS is not supported in this build' "$BUILD_DIR/vps2arch.sh"; then
        echo "❌ 断言失败: NixOS 安装分支剪枝异常" >&2; exit 1
    fi
    if grep -En 'setup_nginx|setup_web_if_enough_ram|setup_websocketd|setup_lighttpd|logviewer|websocketd|web[_-](port|path)|http-port|get_http_log_url|is_need_web_viewer|WEB:' "$BUILD_DIR/vps2arch.sh" >&2; then
        echo "❌ 断言失败: 未认证 Web 控制台代码泄漏" >&2; exit 1
    fi
    if grep -En 'frpc-conf|frpc-config|get_frpc_url|add_frpc_systemd_service_if_need|get-frpc-url\.sh|frpc\.service|/configs/frpc\.' "$BUILD_DIR/vps2arch.sh" >&2; then
        echo "❌ 断言失败: 已裁剪 frpc 代码泄漏" >&2; exit 1
    fi
    if grep -n -- '--insecure' "$BUILD_DIR/vps2arch.sh" >&2; then
        echo "❌ 断言失败: 源机 curl 仍残留 --insecure" >&2; exit 1
    fi
    if grep -n -- 'mv -fT' "$BUILD_DIR/vps2arch.sh" >&2; then
        echo "❌ 断言失败: 仍残留不兼容 BusyBox 的 mv -fT" >&2; exit 1
    fi

    # 8.3 依赖内联断言：确保无 live 阶段二次网络拉取
    if grep -q 'curl -Lo $initrd_dir/trans.sh' "$BUILD_DIR/vps2arch.sh"; then
        echo "❌ 断言失败: trans.sh 未能成功静态内联" >&2; exit 1
    fi
    if grep -q 'curl -Lo $initrd_dir/initrd-network.sh' "$BUILD_DIR/vps2arch.sh"; then
        echo "❌ 断言失败: initrd-network.sh 未能成功静态内联" >&2; exit 1
    fi
    if grep -q 'wget $confhome/ttys.sh' "$BUILD_DIR/vps2arch.sh"; then
        echo "❌ 断言失败: ttys.sh 未能成功静态内联" >&2; exit 1
    fi

    # 8.4 关键向导与探针函数保留断言
    local fn sec
    for fn in prompt_username assert_username_valid resolve_mount_unique_disk get_approximate_ram_size; do
        if ! grep -q "${fn}() {" "$BUILD_DIR/vps2arch.sh"; then
            echo "❌ 断言失败: 关键函数缺失: $fn" >&2; exit 1
        fi
    done

    # 8.5 Arch 终态安全加固断言
    for sec in "PermitRootLogin no" "PasswordAuthentication no" "AuthenticationMethods publickey" "PubkeyAcceptedAlgorithms ssh-ed25519" "00-hardened.conf" "%wheel ALL=(ALL:ALL) ALL" "visudo -c"; do
        if ! grep -Fq "$sec" "$BUILD_DIR/vps2arch.sh"; then
            echo "❌ 断言失败: 核心安全加固缺失: $sec" >&2; exit 1
        fi
    done

    # 8.6 审计补丁断言（且不含上游原文展开噪音）
    if [[ ! -s "$BUILD_DIR/vps2arch.patch" ]] || ! grep -q -- '--- upstream/' "$BUILD_DIR/vps2arch.patch"; then
        printf '❌ 断言失败: 审计补丁 %s 为空或无效\n' "$OUTPUT_PATCH" >&2; exit 1
    fi
    if grep -Fq 'Waiting for the NICs to be stable' "$BUILD_DIR/vps2arch.patch"; then
        echo "❌ 断言失败: 上游 fix-eth-name.sh 原文泄漏进审计补丁" >&2; exit 1
    fi

    if (( CHECK_ONLY )); then
        local drift=0
        cmp -s "$BUILD_DIR/vps2arch.sh" "$OUTPUT_SCRIPT" || {
            printf '❌ 产物漂移: %s 与构建结果不一致\n' "$OUTPUT_SCRIPT" >&2; drift=1
        }
        cmp -s "$BUILD_DIR/vps2arch.patch" "$OUTPUT_PATCH" || {
            printf '❌ 产物漂移: %s 与构建结果不一致\n' "$OUTPUT_PATCH" >&2; drift=1
        }
        (( drift == 0 )) || exit 1
        printf '\n✅ --check 校验通过：仓内产物与构建器输出完全一致。\n'
        return
    fi

    mv -f "$BUILD_DIR/vps2arch.patch" "$OUTPUT_PATCH"
    mv -f "$BUILD_DIR/vps2arch.sh" "$OUTPUT_SCRIPT"

    local actual_sha256 file_size patch_lines
    actual_sha256=$(sha256sum "$OUTPUT_SCRIPT" | awk '{print $1}')
    file_size=$(du -h "$OUTPUT_SCRIPT" | awk '{print $1}')
    patch_lines=$(wc -l < "$OUTPUT_PATCH")

    printf '\n✅ 静态构建与审计完成！\n'
    printf '   生产产物: %s (%s, SHA256: %s)\n' "$OUTPUT_SCRIPT" "$file_size" "$actual_sha256"
    printf '   审计补丁: %s (%s 行 diff)\n' "$OUTPUT_PATCH" "$patch_lines"
}

# ------------------------------------------------------------------------------
# 4. 本地载荷片段集中定义（按 共享 / 源机 / 救援 / 目标 分组写入 $BUILD_DIR）
# ------------------------------------------------------------------------------
write_snippets() {
    # === 4.1 跨端共享（同时注入源机 reinstall.sh 与救援 trans.sh）===

    # 凭据文件必须是一条完整的 SHA-512 crypt 记录。源机和救援共用同一校验。
    cat > "$BUILD_DIR/arch-password.txt" <<'EOF_ARCH_PASSWORD'
valid_arch_password_hash() {
    case "$1" in *'
'*) return 1 ;; esac
    printf '%s\n' "$1" | LC_ALL=C grep -Eq '^\$6\$(rounds=[1-9][0-9]{3,8}\$)?[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{86}$'
}

EOF_ARCH_PASSWORD

    # Linux util-linux: KNAME is the kernel device name, PTUUID is the partition-table ID.
    cat > "$BUILD_DIR/arch-disk.txt" <<'EOF_ARCH_DISK'
# Linux util-linux: KNAME is the kernel device name, PTUUID is the partition-table ID.
arch_disk_identity() {
    local listing names disk id ids= identity= selected= count=0
    listing=$(LC_ALL=C lsblk -dnro KNAME,TYPE) || return 1
    names=$(printf '%s\n' "$listing" | LC_ALL=C awk '
        $2 == "disk" { if (NF != 2 || $1 !~ /^[[:alnum:]_.-]+$/ || seen[$1]++) exit 1; print $1 }
    ') || return 1
    [ -n "$names" ] || return 1
    while IFS= read -r disk; do
        # A nonzero low-level probe is not evidence of absence (blkid can also return 2 on I/O error).
        id=$(LC_ALL=C blkid -p -s PTUUID -o value -- "/dev/$disk") || return 1
        id=$(printf '%s' "$id" | tr 'A-F' 'a-f') || return 1
        if [ -n "$id" ]; then
            case "$id" in *[!0-9a-f-]*) return 1 ;; esac
            printf '%s\n' "$id" | grep -Eq '^([0-9a-f]{8}|[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12})$' &&
                [ -n "$(printf '%s' "$id" | tr -d '0-')" ] || return 1
            ids="$ids $id"
        fi
        if { [ "$1" = name ] && [ "$disk" = "$2" ]; } || { [ "$1" = id ] && [ "$id" = "$2" ]; }; then
            [ -n "$id" ] || return 1
            selected=$id
            identity=$disk
        fi
    done <<EOF_DISKS
$names
EOF_DISKS
    [ -n "$identity" ] || return 1
    for id in $ids; do
        if [ "$id" = "$selected" ]; then count=$((count + 1)); fi
    done
    [ "$count" -eq 1 ] || return 1
    printf '%s %s\n' "$identity" "$selected"
}

EOF_ARCH_DISK

    # === 4.2 源机入口、向导与引导保护（注入 reinstall.sh）===

    cat > "$BUILD_DIR/arch-usage.txt" <<'EOF_ARCH_USAGE'
usage_and_exit() {
    cat <<EOF
Usage: bash $0                          # 交互式 Arch Linux 安装向导
       bash $0 [arch] [OPTIONS...]      # CLI 指定参数（省略 arch 自动补全）
       bash $0 reset                    # 重启前撤销已安排的重装引导项

Options (Arch Linux):
  --username, --user NAME        新系统普通运维用户名（必填，禁止 root）
  --password, --passwd PASS      新用户 sudo 提权密码（必填，<=256 字节，无 CR/LF）
  --ssh-key,  --public-key KEY   Ed25519 登录公钥文本、本地路径、github:/gitlab: 或 HTTPS URL（必填）
  --ssh-port PORT                新系统 SSH 端口（默认 22，禁止 443）
  --target-disk /dev/DISK        显式指定目标整盘（Btrfs/bcachefs 或多盘根时必填）
  --hold 0|1|2                   调试停顿点（0=打包前，1=进救援后暂停，2=安装完不自动重启）
  --force-cn                     强制使用国内镜像源
  -h, --help                     显示本帮助并退出
EOF
    exit 1
}
EOF_ARCH_USAGE

    cat > "$BUILD_DIR/private-boot-copy.txt" <<'EOF_PRIVATE_BOOT_COPY'
            (
                local staged ownership_mode
                staged=$(mktemp -- "$dir/.reinstall-initrd.XXXXXXXXXX")
                trap 'rm -f -- "$staged"' EXIT
                # FAT can ignore chmod. Check the actual mode before copying the digest-bearing image.
                ownership_mode=$(stat -c '%u:%a' -- "$staged") && [ "$ownership_mode" = 0:600 ] ||
                    error_and_exit "无法确认引导目录 $dir 中的 initrd 副本为 root 所有且权限为 0600。"
                [ ! -d "$dir/reinstall-initrd" ] ||
                    error_and_exit "引导目录 $dir 中的 reinstall-initrd 目标路径异常。"
                cat /reinstall-initrd >"$staged"
                mv -f -- "$staged" "$dir/reinstall-initrd"
            )
EOF_PRIVATE_BOOT_COPY

    cat > "$BUILD_DIR/initrd-archive.txt" <<'EOF_INITRD_ARCHIVE'
    (set -o pipefail
        find . | cpio --quiet -o -H newc -R 0:0 | gzip -1 >/reinstall-initrd
    ) || error_and_exit '无法重新打包救援 initrd。'

    (set -o pipefail
        gzip -dc /reinstall-initrd | cpio --quiet -it | awk '
            BEGIN {
                n = split("init trans.sh initrd-network.sh configs/ssh_keys configs/password-linux-sha512", names)
                for (i = 1; i <= n; i++) required[names[i]] = 0
            }
            { sub(/^[.]\//, ""); if ($0 in required) required[$0]++ }
            END { for (name in required) if (required[name] != 1) exit 1 }
        '
    ) || error_and_exit '救援 initrd 归档无法读取，或必要成员缺失或重复。'
EOF_INITRD_ARCHIVE

    cat > "$BUILD_DIR/username.txt" <<'EOF_USERNAME'
assert_username_valid() {
    if [[ "${username:-}" =~ ^[a-z_][a-z0-9_-]*$ && "$username" != root ]]; then
        return 0
    fi
    error '用户名必须以小写字母或下划线开头，仅包含小写字母、数字、下划线与连字符，且不能为 root。'
    return 1
}

prompt_username() {
    while true; do
        read -rp '新系统登录普通用户名 (禁止为 root): ' username < /dev/tty \
            || error_and_exit '无法读取普通用户名，请显式指定 --username。'
        assert_username_valid && return
    done
}
EOF_USERNAME

    cat <<'EOF_ARCH_IP_RECHECK' > "$BUILD_DIR/arch-ip-recheck.txt"
    if [ -n "$arch_ipv4_mode" ]; then unset ipv4_mac ipv4_addr ipv4_gateway; fi
    collect_netconf "${arch_ipv4_mode:+require-ipv4-probes}" >&2 || error_and_exit '无法读取源机网络参数。'
    if [ -n "$arch_ipv4_mode" ]; then
        [ "$(arch_ipv4_handoff)" = "$arch_confirmed_ipv4" ] ||
            error_and_exit '源机 IPv4 参数已变化或无法复核，请重新核对。'
    fi
EOF_ARCH_IP_RECHECK

    cat <<'EOF_ARCH_CONFIRM_HOOKS' > "$BUILD_DIR/arch-confirm-hooks.txt"
if [ "$distro" = arch ]; then
    require_arch_credentials
    if [ "$basearch" = x86_64 ]; then confirm_arch_ipv4; fi
    confirm_arch_target
    init_bootloader_facts
fi
EOF_ARCH_CONFIRM_HOOKS

    cat <<'EOF_WIZARD_SNIPPET' > "$BUILD_DIR/wizard.txt"
# ==============================================================================
# vps2arch 入口处理：支持交互采集与 CLI 直接传参
# ==============================================================================
check_arch_ssh_port() {
    if ! { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && is_port_valid "$1"; }; then
        error "SSH 端口无效：$1"
        return 1
    fi
    if [[ "$1" == 443 ]]; then
        error '443/tcp 预留给业务入口，请选择其他 SSH 端口。'
        return 1
    fi
}

assert_arch_ssh_port() {
    check_arch_ssh_port "$1" || exit 1
}

valid_ed25519_key() {
    [[ "$1" != *$'\n'* && "$1" =~ ^ssh-ed25519[[:blank:]]+[A-Za-z0-9+/]{68}([[:blank:]].*)?$ ]] &&
        ssh-keygen -lf /dev/stdin <<< "$1" >/dev/null 2>&1
}

validate_arch_keys() {
    local key found=0
    while IFS= read -r key; do
        key=${key%$'\r'}
        [[ "$key" =~ ^[[:blank:]]*(#.*)?$ ]] && continue
        valid_ed25519_key "$key" || return 1
        found=1
    done <<< "$1"
    (( found ))
}

require_arch_credentials() {
    assert_username_valid || exit 1
    [ -n "${password:-}" ] || error_and_exit '必须提供新用户的 sudo 密码（--password）。'
    [[ "$password" != *$'\n'* && "$password" != *$'\r'* ]] || error_and_exit 'sudo 密码不能包含换行或回车。'
    local LC_ALL=C
    (( ${#password} <= 256 )) || error_and_exit 'sudo 密码不能超过 256 字节。'
    [ -n "${ssh_keys:-}" ] || error_and_exit '必须提供 Ed25519 登录公钥。'
    ssh_port=${ssh_port:-22}
    assert_arch_ssh_port "$ssh_port"
}

arch_ipv4_handoff() {
    is_found_ipv4_netconf || return 1
    printf '%s|%s|%s\n' "$ipv4_mac" "$ipv4_addr" "$ipv4_gateway"
}

arch_ifupdown_static() {
    local config=$1 nic=$2 addr=$3 gateway=$4 include directory fragment
    local -a files=("$config")
    [[ -n "$nic" && -f "$config" && -r "$config" ]] || return 1
    include=$(LC_ALL=C awk '$1 ~ /^source/ { print $1, $2; if (NF != 2) exit 1 }' "$config") || return 1
    case "$include" in
        '') ;;
        'source /etc/network/interfaces.d/*' | 'source-directory /etc/network/interfaces.d')
            directory=${config%/*}/interfaces.d
            if [[ -e "$directory" || -L "$directory" ]]; then
                [[ -d "$directory" && -r "$directory" && -x "$directory" ]] || return 1
                for fragment in "$directory"/*; do
                    if [[ "$include" == source-directory* && ! "${fragment##*/}" =~ ^[a-zA-Z0-9_-]+$ ]]; then continue; fi
                    [[ -e "$fragment" || -L "$fragment" ]] || continue
                    [[ -f "$fragment" && -r "$fragment" ]] || return 1
                    files+=("$fragment")
                done
            fi ;;
        *) return 1 ;;
    esac
    # Recognize the simple ifupdown stanza; never expand arbitrary includes or run hooks.
    LC_ALL=C awk -v nic="$nic" -v addr="$addr" -v gateway="$gateway" -v include_line="$include" '
        FNR == 1 { selected = 0 }
        /\\[[:space:]]*$/ { bad = 1; exit }
        NF == 0 || $1 ~ /^#/ { next }
        /#/ || $1 == "mapping" || $1 == "rename" { bad = 1; exit }
        $1 ~ /^source/ {
            if (FILENAME != ARGV[1] || NF != 2 || $1 " " $2 != include_line || ++includes != 1) { bad = 1; exit }
            selected = 0; next
        }
        $1 == "iface" {
            if (NF != 4) { bad = 1; exit }
            selected = (":" $2 == ":" nic && $3 == "inet")
            if (selected && (++stanzas != 1 || $4 != "static")) { bad = 1; exit }
            next
        }
        $1 ~ /^(auto|allow-[^ ]+|no-auto-down|no-scripts)$/ { if (NF > 1) selected = 0; next }
        !selected { next }
        $1 == "address" && NF == 2 && $2 == addr && ++addresses == 1 { next }
        $1 == "gateway" && NF == 2 && $2 == gateway && ++gateways == 1 { next }
        $1 ~ /^(broadcast|metric|mtu|dns-nameservers|dns-search|dns-options)$/ && NF > 1 { next }
        { bad = 1; exit }
        END { exit (bad || (include_line != "" && includes != 1) || stanzas != 1 || addresses != 1 || gateways != 1) }
    ' "${files[@]}"
}

arch_networkd_static() {
    local dir=$1 nic=$2 mac=$3 addr=$4 gateway=$5 f
    local -a files=()
    [[ -n "$nic" && -n "$mac" && -d "$dir" && -r "$dir" && -x "$dir" ]] || return 1
    for f in "$dir"/*.network; do
        [[ -e "$f" || -L "$f" ]] || continue
        [[ -f "$f" && -r "$f" ]] || return 1
        files+=("$f")
    done
    (( ${#files[@]} > 0 )) || return 1
    LC_ALL=C awk -v nic="$nic" -v mac="${mac,,}" -v addr="$addr" -v gateway="$gateway" '
        function flush_route() {
            if (in_route && route_gw != "") {
                if (route_dest == "" || route_dest == "0.0.0.0/0") {
                    if (route_gw ~ /:/) {
                    } else if (route_gw == gateway) {
                        file_gw++
                    } else {
                        file_bad = 1
                    }
                }
            }
            in_route = 0; route_gw = ""; route_dest = ""
        }
        function flush_file() {
            flush_route()
            if (file_seen && file_matched) {
                matched_files++
                if (file_bad || file_dhcp_v4 || file_addr != 1 || file_gw != 1) bad = 1
            }
        }
        FNR == 1 {
            flush_file()
            file_seen = 1; section = ""
            file_matched = 0; file_bad = 0; file_dhcp_v4 = 0
            file_addr = 0; file_gw = 0
        }
        /\\[[:space:]]*$/ { file_bad = 1; next }
        /^[[:space:]]*([#;].*)?$/ { next }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            flush_route()
            section = $0
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
            if (section == "Route") in_route = 1
            next
        }
        {
            pos = index($0, "=")
            if (pos == 0) { file_bad = 1; next }
            key = substr($0, 1, pos - 1)
            val = substr($0, pos + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (val ~ /^".*"$/) val = substr(val, 2, length(val) - 2)
        }
        section == "Match" {
            if (key == "Name") {
                if (val == nic) file_matched = 1
                else if (val ~ /[*?!|[:space:]]/) file_bad = 1
            } else if (key == "MACAddress" || key == "PermanentMACAddress") {
                if (tolower(val) == mac) file_matched = 1
                else if (val ~ /[*?!|[:space:]]/) file_bad = 1
            } else if (val ~ /^!/) {
                file_bad = 1
            }
            next
        }
        section == "Network" {
            if (key == "DHCP") {
                v = tolower(val)
                if (v != "no" && v != "false" && v != "0" && v != "ipv6" && v != "") file_dhcp_v4 = 1
            } else if (key == "Address") {
                if (val ~ /:/) next
                if (val == addr) file_addr++
                else file_bad = 1
            } else if (key == "Gateway") {
                if (val ~ /:/) next
                if (val == gateway) file_gw++
                else file_bad = 1
            }
            next
        }
        section == "Address" {
            if (key == "Address") {
                if (val ~ /:/) next
                if (val == addr) file_addr++
                else file_bad = 1
            }
            next
        }
        section == "Route" {
            if (key == "Gateway") route_gw = val
            else if (key == "Destination") route_dest = val
            else if (key == "GatewayOnLink" || key == "Scope" || key == "Metric" || key == "Table") {}
            else file_bad = 1
            next
        }
        END {
            flush_file()
            exit (bad || matched_files != 1)
        }
    ' "${files[@]}"
}

arch_netplan_static() {
    local dir=$1 nic=$2 mac=$3 addr=$4 gateway=$5 f
    local -a files=()
    [[ -n "$nic" && -n "$mac" && -d "$dir" && -r "$dir" && -x "$dir" ]] || return 1
    for f in "$dir"/*.yaml "$dir"/*.yml; do
        [[ -e "$f" || -L "$f" ]] || continue
        [[ -f "$f" && -r "$f" ]] || return 1
        files+=("$f")
    done
    (( ${#files[@]} > 0 )) || return 1
    LC_ALL=C awk -v nic="$nic" -v mac="${mac,,}" -v addr="$addr" -v gateway="$gateway" '
        function unquote(s) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
            return s
        }
        function check_addr_item(item) {
            item = unquote(item)
            if (item == "" || item ~ /:/) return
            if (item == addr) stanza_addr++
            else stanza_bad = 1
        }
        function flush_route() {
            if (in_route_item && (route_to != "" || route_via != "")) {
                if (route_to == "default" || route_to == "0.0.0.0/0") {
                    if (route_via ~ /:/) {
                    } else if (route_via == gateway) {
                        stanza_gw++
                    } else {
                        stanza_bad = 1
                    }
                }
            }
            in_route_item = 0; route_to = ""; route_via = ""
        }
        function flush_stanza() {
            flush_route()
            if (!in_stanza) return
            matched = 0
            if (stanza_match_mac != "") {
                if (stanza_match_mac == mac && (stanza_set_name == "" || stanza_set_name == nic)) matched = 1
            } else if (stanza_match_name != "") {
                if (stanza_match_name == nic && (stanza_set_name == "" || stanza_set_name == nic)) matched = 1
            } else if (stanza_id == nic && !stanza_has_match) {
                matched = 1
            }
            if (matched) {
                matched_stanzas++
                if (stanza_bad || stanza_dhcp4 || stanza_addr != 1 || stanza_gw != 1) bad = 1
            }
            in_stanza = 0
        }
        FNR == 1 {
            flush_stanza()
            in_net = 0; in_eth = 0; eth_indent = -1; stanza_indent = -1; sub_indent = -1; sub_section = ""
        }
        /\t/ { bad = 1; exit }
        /^[[:space:]]*(#.*)?$/ { next }
        /[#]/ {
            if ($0 !~ /^[[:space:]]*#/) { bad = 1; exit }
        }
        {
            match($0, /^[ ]*/)
            ind = RLENGTH
            line = substr($0, ind + 1)
            gsub(/[[:space:]]+$/, "", line)
        }
        line == "---" || line == "..." { next }
        ind == 0 {
            flush_stanza()
            if (line == "network:") { in_net = 1; in_eth = 0 }
            else { in_net = 0; in_eth = 0 }
            next
        }
        !in_net { next }
        !in_eth || ind <= eth_indent {
            flush_stanza()
            in_eth = 0
            if (line == "ethernets:") { in_eth = 1; eth_indent = ind }
            next
        }
        !in_stanza || ind <= stanza_indent {
            flush_stanza()
            if (ind <= eth_indent || line !~ /^[A-Za-z0-9_.-]+:$/) { bad = 1; exit }
            stanza_id = substr(line, 1, length(line) - 1)
            stanza_indent = ind
            in_stanza = 1
            stanza_bad = 0; stanza_dhcp4 = 0; stanza_addr = 0; stanza_gw = 0
            stanza_has_match = 0; stanza_match_mac = ""; stanza_match_name = ""; stanza_set_name = ""
            sub_section = ""; sub_indent = -1
            next
        }
        sub_section != "" && ind <= sub_indent && !(ind == sub_indent && line ~ /^-[[:space:]]*/) {
            flush_route()
            sub_section = ""; sub_indent = -1
        }
        sub_section == "" {
            pos = index(line, ":")
            if (pos == 0) { stanza_bad = 1; next }
            k = substr(line, 1, pos - 1)
            v = substr(line, pos + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (k == "dhcp4") {
                vl = tolower(unquote(v))
                if (vl != "false" && vl != "no" && vl != "0") stanza_dhcp4 = 1
            } else if (k == "set-name") {
                stanza_set_name = unquote(v)
            } else if (k == "gateway4") {
                gv = unquote(v)
                if (gv == gateway) stanza_gw++
                else stanza_bad = 1
            } else if (k == "addresses") {
                if (v == "") {
                    sub_section = "addresses"; sub_indent = ind
                } else if (v ~ /^\[.*\]$/) {
                    inner = substr(v, 2, length(v) - 2)
                    n = split(inner, arr, ",")
                    for (i = 1; i <= n; i++) check_addr_item(arr[i])
                } else {
                    stanza_bad = 1
                }
            } else if (k == "routes") {
                if (v == "") { sub_section = "routes"; sub_indent = ind }
                else stanza_bad = 1
            } else if (k == "match") {
                stanza_has_match = 1
                if (v == "") { sub_section = "match"; sub_indent = ind }
                else stanza_bad = 1
            } else if (v == "") {
                sub_section = "other"; sub_indent = ind
            }
            next
        }
        sub_section == "addresses" {
            if (line !~ /^-[[:space:]]+/) { stanza_bad = 1; next }
            item = line
            sub(/^-[[:space:]]+/, "", item)
            check_addr_item(item)
            next
        }
        sub_section == "match" {
            pos = index(line, ":")
            if (pos == 0) { stanza_bad = 1; next }
            k = substr(line, 1, pos - 1)
            v = unquote(substr(line, pos + 1))
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (k == "macaddress") stanza_match_mac = tolower(v)
            else if (k == "name") stanza_match_name = v
            else stanza_bad = 1
            next
        }
        sub_section == "routes" {
            if (line ~ /^-[[:space:]]+/) {
                flush_route()
                in_route_item = 1
                sub(/^-[[:space:]]+/, "", line)
            } else if (!in_route_item) {
                stanza_bad = 1; next
            }
            pos = index(line, ":")
            if (pos == 0) { stanza_bad = 1; next }
            k = substr(line, 1, pos - 1)
            v = unquote(substr(line, pos + 1))
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (k == "to") route_to = v
            else if (k == "via") route_via = v
            next
        }
        END {
            flush_stanza()
            exit (bad || matched_stanzas != 1)
        }
    ' "${files[@]}"
}

confirm_arch_ipv4() {
    local evidence ipv4_ethx='' ipv4_mac='' ipv4_addr='' ipv4_gateway='' ipv4_routes='' ipv4_addresses='' static_source=''
    evidence=$(
        collect_netconf require-ipv4-probes capture-ipv4-evidence >&2 && arch_ipv4_handoff || exit 1
        if [[ ! "$ipv4_routes" =~ (^|[[:space:]])proto[[:blank:]]+dhcp([[:space:]]|$) &&
              ! "$ipv4_addresses" =~ (^|[[:space:]])dynamic([[:space:]]|$) ]]; then
            if arch_ifupdown_static /etc/network/interfaces "$ipv4_ethx" "$ipv4_addr" "$ipv4_gateway"; then
                printf 'static:/etc/network/interfaces\n'
            elif arch_networkd_static /etc/systemd/network "$ipv4_ethx" "$ipv4_mac" "$ipv4_addr" "$ipv4_gateway"; then
                printf 'static:/etc/systemd/network\n'
            elif arch_netplan_static /etc/netplan "$ipv4_ethx" "$ipv4_mac" "$ipv4_addr" "$ipv4_gateway"; then
                printf 'static:/etc/netplan\n'
            fi
        fi
    ) || error_and_exit '无法采集完整的源机 IPv4 地址、网关和网卡 MAC。'
    arch_confirmed_ipv4=${evidence%%$'\n'*}
    if [[ "$evidence" == *$'\n'static:* ]]; then
        arch_ipv4_mode=static
        static_source=${evidence##*$'\n'static:}
        printf '源机 %s 的静态配置与采集值一致，采用 static。\n' "$static_source" >&2
    else
        read -r -p '无法自动确认取址方式，请按服务商要求输入 dhcp（固定租约）或 static（手填，无默认）: ' arch_ipv4_mode < /dev/tty ||
            error_and_exit '无法读取 IPv4 取址方式，请从交互终端运行。'
    fi
    case "$arch_ipv4_mode" in
        dhcp | static) ;;
        *) error_and_exit '未确认固定 IPv4 取址方式，请先核对服务商说明。' ;;
    esac
}

# 解析指定挂载点对应的唯一底层整盘（忽略 systemd autofs 触发项，拒绝 btrfs/bcachefs）。
resolve_mount_unique_disk() {
    local target=$1 raw filtered source fs_type ancestors disk
    raw=$(findmnt -n -o SOURCE,FSTYPE --nofsroot --target "$target") || return 10
    filtered=$(LC_ALL=C awk '$2 != "autofs" { print }' <<< "$raw")
    [[ -n "$filtered" && "$filtered" != *$'\n'* ]] || return 11
    read -r source fs_type <<< "$filtered"
    case "$fs_type" in btrfs|bcachefs|'') return 12 ;; esac
    [[ "$source" == /dev/* && -b "$source" ]] || return 13
    ancestors=$(LC_ALL=C lsblk -snro KNAME,TYPE -- "$source") || return 14
    disk=$(awk '$2 == "disk" { disks[$1] = 1 } END { for (disk in disks) { print disk; count++ } if (count != 1) exit 1 }' <<< "$ancestors") || return 15
    [[ "$disk" =~ ^[a-zA-Z0-9_.-]+$ && -b "/dev/$disk" ]] || return 15
    printf '%s\n' "$disk"
}

find_arch_bios_boot_disk() {
    install_pkg findmnt lsblk || return 1
    resolve_mount_unique_disk /boot
}

confirm_arch_target() {
    local chosen rc=0 identity name confirm
    ! is_in_windows || error_and_exit '请从目标 VPS 的 Linux 系统执行 Arch 全盘重装。'
    install_pkg lsblk
    command -v blkid >/dev/null || error_and_exit '缺少 util-linux 的 blkid，无法核对目标磁盘。'
    if [[ -n "$xda" ]]; then
        chosen=$xda
    else
        install_pkg findmnt
        if ! chosen=$(resolve_mount_unique_disk /); then
            rc=$?
            case "$rc" in
                10) error_and_exit '无法确认根文件系统设备。' ;;
                11) error_and_exit '无法唯一确认根文件系统，请明确指定 --target-disk。' ;;
                12) error_and_exit '无法由单个根设备证明整个文件系统的底层磁盘，请明确指定 --target-disk。' ;;
                13) error_and_exit '根文件系统不是可识别的块设备，请明确指定 --target-disk。' ;;
                14) error_and_exit '无法读取根设备的底层磁盘。' ;;
                *) error_and_exit '无法唯一确定根设备所在磁盘，请明确指定 --target-disk。' ;;
            esac
        fi
    fi
    [[ "$chosen" =~ ^[a-zA-Z0-9_.-]+$ ]] || error_and_exit '目标磁盘名称无效。'
    identity=$(arch_disk_identity name "$chosen") || error_and_exit '无法直接核验所有整盘或确认目标 PTUUID 唯一。'
    read -r name main_disk <<< "$identity"
    [[ "$name" == "$chosen" && -b "/dev/$name" ]] || error_and_exit '已选目标不是可核对的整盘设备。'
    xda=$name
    printf '\n目标：/dev/%s (PTUUID: %s) | Arch Linux | 用户：%s | SSH：%s/tcp，仅 Ed25519\n' "$xda" "$main_disk" "$username" "$ssh_port"
    printf '重启进入救援环境后，确认的整块磁盘（包括所有分区）将被清空。重装期间不要替换、热插拔目标盘或接入其克隆盘。\n'
    if ! IFS= read -rp "确认请原样输入 /dev/$xda，其他输入取消: " confirm < /dev/tty || [[ "$confirm" != "/dev/$xda" ]]; then
        printf '已取消\n'
        exit 0
    fi
}

if [ $# -eq 0 ]; then
    command -v ssh-keygen >/dev/null || error_and_exit '缺少 ssh-keygen，无法校验 Ed25519 公钥。'

    printf '\n════════════════════════════════════════════════════════\n'
    printf '  vps2arch: Arch Linux 安装向导\n'
    printf '════════════════════════════════════════════════════════\n\n'

    # 1. 采集普通用户名
    prompt_username
    # 2. 采集 sudo 提权密码
    TARGET_PASSWORD=""
    while true; do
        IFS= read -s -rp "新用户 sudo 提权密码: " p1 < /dev/tty || error_and_exit '无法读取 sudo 密码。'
        printf '\n'
        IFS= read -s -rp "再次输入确认密码: " p2 < /dev/tty || error_and_exit '无法读取确认密码。'
        printf '\n'
        if [[ -z "$p1" || "$p1" != "$p2" ]]; then
            printf '❌ 两次密码输入不匹配或为空，请重新输入\n' >&2
            continue
        fi
        if [[ "$p1" == *$'\n'* || "$p1" == *$'\r'* ]]; then
            printf '❌ sudo 密码不能包含换行或回车，请重新输入\n' >&2
            continue
        fi
        if ! (LC_ALL=C; (( ${#p1} <= 256 ))); then
            printf '❌ sudo 密码不能超过 256 字节，请重新输入\n' >&2
            continue
        fi
        TARGET_PASSWORD="$p1"
        break
    done

    # 3. 校验并采集 Ed25519 公钥
    AUTH_KEY_FILE="/root/.ssh/authorized_keys"
    DEFAULT_KEY=""
    if [[ -f "$AUTH_KEY_FILE" ]]; then
        while IFS= read -r key || [[ -n "$key" ]]; do
            key=${key%$'\r'}
            if valid_ed25519_key "$key"; then DEFAULT_KEY=$key; break; fi
        done < "$AUTH_KEY_FILE"
    fi
    if [[ -n "$DEFAULT_KEY" ]]; then
        printf '\n🔑 检测到宿主有效 Ed25519 公钥：\n%s\n' "$DEFAULT_KEY"
    fi

    TARGET_SSH_KEY=""
    while true; do
        if [[ -n "$DEFAULT_KEY" ]]; then
            read -rp "登录 Ed25519 公钥 [回车默认使用上方公钥]: " TARGET_SSH_KEY < /dev/tty || error_and_exit '无法读取公钥。'
            TARGET_SSH_KEY="${TARGET_SSH_KEY:-$DEFAULT_KEY}"
        else
            read -rp "请输入将用于登录的 Ed25519 SSH 公钥文本: " TARGET_SSH_KEY < /dev/tty || error_and_exit '无法读取公钥。'
        fi
        TARGET_SSH_KEY=$(printf '%s' "$TARGET_SSH_KEY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        valid_ed25519_key "$TARGET_SSH_KEY" && break
        printf '❌ 公钥无效（必须为 ssh-ed25519 格式），请重新输入\n' >&2
    done

    # 4. SSH 端口
    while true; do
        read -rp $'\n新系统 SSH 端口 [默认 22]: ' TARGET_SSH_PORT < /dev/tty || error_and_exit '无法读取 SSH 端口。'
        TARGET_SSH_PORT=${TARGET_SSH_PORT:-22}
        if check_arch_ssh_port "$TARGET_SSH_PORT"; then break; fi
    done

    set -- arch \
        --username "$username" \
        --password "$TARGET_PASSWORD" \
        --ssh-key "$TARGET_SSH_KEY" \
        --ssh-port "$TARGET_SSH_PORT"
fi
EOF_WIZARD_SNIPPET

    # === 4.3 救援阶段内联占位与门禁（注入 trans.sh，严格 POSIX/ash 兼容）===

    cat > "$BUILD_DIR/get-ttys-placeholder.txt" <<'EOF_GET_TTYS_PLACEHOLDER'
get_ttys() {
    # [Inlined ttys.sh] 本地内嵌展开，杜绝外部网络拉取
    sh -s "$1" <<'EOF_INLINED_TTYS'
# @@INLINE:ttys.sh@@
EOF_INLINED_TTYS
}
EOF_GET_TTYS_PLACEHOLDER

    cat > "$BUILD_DIR/fix-eth-placeholder.txt" <<'EOF_FIX_ETH_PLACEHOLDER'
add_fix_eth_name_systemd_service() {
    local os_dir=$1
    # [Inlined fix-eth-name.sh] 本地内嵌展开，杜绝外部网络拉取
    cat <<'EOF_FIX_ETH_SH' > "$os_dir/fix-eth-name.sh"
# @@INLINE:fix-eth-name.sh@@
EOF_FIX_ETH_SH
    chmod +x "$os_dir/fix-eth-name.sh"

    # [Inlined fix-eth-name.service] 本地内嵌展开
    mkdir -p "$os_dir/etc/systemd/system"
    cat <<'EOF_FIX_ETH_SVC' > "$os_dir/etc/systemd/system/fix-eth-name.service"
# @@INLINE:fix-eth-name.service@@
EOF_FIX_ETH_SVC

    chroot "$os_dir" systemctl enable fix-eth-name.service 2>/dev/null || true
    if [ -d "$os_dir/usr/lib/systemd/system-preset" ]; then
        echo "enable fix-eth-name.service" > "$os_dir/usr/lib/systemd/system-preset/01-fix-eth-name.preset"
    elif [ -d "$os_dir/lib/systemd/system-preset" ]; then
        echo "enable fix-eth-name.service" > "$os_dir/lib/systemd/system-preset/01-fix-eth-name.preset"
    fi
}
EOF_FIX_ETH_PLACEHOLDER

    cat > "$BUILD_DIR/networkd-account.txt" <<'EOF_NETWORKD_ACCOUNT'
        # networkd 渲染需要 systemd-network 用户和同名组；只清理本次创建的账号。
        local network_user_created=0 render_status=0 cleanup_status=0
        if grep -q '^systemd-network:' /etc/passwd; then
            :
        else
            [ "$?" -eq 1 ] || error_and_exit 'Cannot read the rescue account database.'
            useradd --system --user-group systemd-network ||
                error_and_exit 'Cannot create the temporary systemd-network account.'
            network_user_created=1
        fi
        cloud-init devel net-convert -p net.cfg -k yaml -d out -D alpine -O networkd || render_status=$?
        if [ "$network_user_created" -eq 1 ]; then
            userdel systemd-network || cleanup_status=$?
        fi
        [ "$render_status" -eq 0 ] || return "$render_status"
        [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
EOF_NETWORKD_ACCOUNT

    cat > "$BUILD_DIR/arch-rescue-password.txt" <<'EOF_ARCH_RESCUE_PASSWORD'
read_arch_password_hash() {
    local hash
    # Preserve trailing newlines to require exactly one complete line.
    hash=$(cat /configs/password-linux-sha512 && printf .) || return 1
    case "$hash" in
        *'
.') hash=${hash%??} ;;
        *) return 1 ;;
    esac
    valid_arch_password_hash "$hash" || return 1
    printf '%s\n' "$hash"
}

require_arch_rescue_credentials() {
    [ -s /configs/ssh_keys ] && [ ! -e /configs/password-plaintext ] && [ ! -L /configs/password-plaintext ] &&
        read_arch_password_hash >/dev/null || error_and_exit 'Missing or invalid confirmed Arch login key or sudo password.'
}

EOF_ARCH_RESCUE_PASSWORD

    cat > "$BUILD_DIR/arch-rescue-disk.txt" <<'EOF_ARCH_RESCUE_DISK'
arch_disk_instance() {
    local path=/sys/class/block/$1 devnum seq node
    devnum=$(cat "$path/dev") && seq=$(cat "$path/diskseq") &&
        node=$(stat -Lc '%t:%T' -- "/dev/$1") || return 1
    printf '%s\n' "$devnum" | grep -Eq '^[0-9]+:[0-9]+$' &&
        printf '%s\n' "$seq" | grep -Eq '^[1-9][0-9]*$' || return 1
    [ "$(printf '%x:%x' "${devnum%:*}" "${devnum#*:}")" = "$node" ] || return 1
    printf '%s/%s\n' "$devnum" "$seq"
}

require_confirmed_arch_disk() {
    local identity disk instance
    [ -n "$main_disk" ] || error_and_exit 'Missing confirmed whole-disk PTUUID.'
    identity=$(arch_disk_identity id "$main_disk") || error_and_exit 'Cannot directly confirm all whole disks or the unique confirmed PTUUID.'
    disk=${identity%% *}
    [ -b "/dev/$disk" ] && instance=$(arch_disk_instance "$disk") &&
        { [ -z "$xda" ] || { [ "$xda" = "$disk" ] && [ "$arch_rescue_disk_instance" = "$instance" ]; }; } ||
        error_and_exit 'The confirmed whole-disk device identity changed or is unavailable.'
    xda=$disk
    arch_rescue_disk_instance=$instance
}

EOF_ARCH_RESCUE_DISK

    # 只读校验上游交接和实时状态，不生成或替换网络配置。
    cat > "$BUILD_DIR/arch-fixed-ipv4.txt" <<'EOF_ARCH_FIXED_IPV4'
require_arch_fixed_ipv4() {
    local machine ethx links addr nic= expected= mac live_mac dhcp disabled usable actual routes gateway
    machine=$(uname -m) || error_and_exit 'Cannot identify the rescue architecture.'
    case "$machine" in
        aarch64) return ;;
        x86_64) ;;
        *) error_and_exit 'Unsupported rescue architecture.' ;;
    esac
    case "$arch_ipv4_mode" in
        dhcp | static) ;;
        *) error_and_exit 'Missing confirmed IPv4 assignment mode.' ;;
    esac
    links=$(get_eths) || error_and_exit 'Cannot read the rescue network handoff.'
    for ethx in $links; do
        addr=$(cat "/dev/netconf/$ethx/ipv4_addr") || error_and_exit 'Cannot read the recorded IPv4 address.'
        [ -n "$addr" ] || continue
        [ -z "$nic" ] || error_and_exit 'Cannot identify one confirmed IPv4 link.'
        nic=$ethx
        expected=$addr
    done
    [ -n "$nic" ] || error_and_exit 'Missing confirmed IPv4 address in the rescue handoff.'
    dhcp=$(cat "/dev/netconf/$nic/dhcpv4") &&
        disabled=$(cat "/dev/netconf/$nic/should_disable_dhcpv4") &&
        usable=$(cat "/dev/netconf/$nic/ipv4_has_internet") ||
        error_and_exit 'Cannot read the rescue IPv4 result.'
    [ "$usable" = 1 ] || error_and_exit 'The rescue environment did not confirm usable IPv4.'
    case "$arch_ipv4_mode:$dhcp:$disabled" in
        dhcp:1:0 | static:0:0 | static:1:0) ;;
        *) error_and_exit 'Rescue IPv4 does not match the confirmed assignment mode. Check the provider settings.' ;;
    esac
    mac=$(cat "/dev/netconf/$nic/mac_addr") && [ -n "$mac" ] &&
        live_mac=$(cat "/sys/class/net/$nic/address") && [ "$live_mac" = "$mac" ] ||
        error_and_exit 'The rescue link does not match the recorded MAC address.'
    addr=$(ip -4 -o addr show scope global dev "$nic") &&
        actual=$(printf '%s\n' "$addr" | awk '
            $3 == "inet" { address = $4; count++ }
            END { if (count != 1) exit 1; print address }
        ') || error_and_exit 'Cannot verify the live rescue IPv4 address.'
    [ "${actual%/*}" = "${expected%/*}" ] || error_and_exit 'The fixed IPv4 address changed in rescue.'
    routes=$(ip -4 route show default dev "$nic") && [ -n "$routes" ] ||
        error_and_exit 'Cannot verify the live rescue IPv4 default route.'
    if [ "$arch_ipv4_mode" = static ] && [ "$dhcp" = 0 ]; then
        gateway=$(cat "/dev/netconf/$nic/ipv4_gateway") && [ -n "$gateway" ] &&
            [ "$actual" = "$expected" ] &&
            printf '%s\n' "$routes" | awk -v gateway="$gateway" '
                NR != 1 || $1 != "default" || $2 != "via" || $3 != gateway { exit 1 }
            ' || error_and_exit 'The static IPv4 prefix or gateway changed in rescue.'
    fi
}
EOF_ARCH_FIXED_IPV4

    cat <<'EOF_ARCH_ERASE_GATE' > "$BUILD_DIR/arch-erase-gate.txt"
    if [ "$distro" = arch ]; then
        require_confirmed_arch_disk
        require_arch_fixed_ipv4
        [ "$(arch_disk_instance "$xda")" = "$arch_rescue_disk_instance" ] || error_and_exit 'The confirmed device changed at the erase boundary.'
    fi
    arch_erase_started=1
EOF_ARCH_ERASE_GATE

    cat <<'EOF_ARCH_ERASE_DIAG' > "$BUILD_DIR/arch-erase-diag.txt"
    if [ "$arch_erase_started" = 1 ]; then
        echo 'Erasure was attempted in this run; data may already be lost. Check the disk and install log from the console.' >&2
    else
        echo 'Erasure has not been attempted in this run. Check the target and install log from the console.' >&2
    fi
EOF_ARCH_ERASE_DIAG

    # === 4.4 目标系统终态安全加固（注入 trans.sh::basic_init）===

    cat <<'EOF_PATCH_SNIPPET' > "$BUILD_DIR/basic_init_patch.txt"
    # 公钥/密码设置
    add_user_if_need "$os_dir"
    if is_need_set_ssh_keys; then
        set_ssh_keys_and_del_password "$os_dir"
        if [ "$distro" != arch ]; then change_ssh_conf_for_key_login "$os_dir"; fi
    fi
    if [ "$distro" = arch ] || [ -s /configs/password-plaintext ] || [ -s /configs/password-linux-sha512 ]; then
        change_user_password "$os_dir"
    fi

    # Arch Linux 终态原生加固
    if [ "$distro" = "arch" ]; then
        local ssh_enabled effective_ssh
        # 1. 主机密钥：在目标系统内仅保留 Ed25519。
        chroot "$os_dir" sh -c "rm -f /etc/ssh/ssh_host_* && ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key"
        chmod 0600 "$os_dir/etc/ssh/ssh_host_ed25519_key"
        chmod 0644 "$os_dir/etc/ssh/ssh_host_ed25519_key.pub"

        # 2. SSH Drop-in 终态加固
        mkdir -p "$os_dir/etc/ssh/sshd_config.d"
        cat > "$os_dir/etc/ssh/sshd_config.d/00-hardened.conf" <<EOF_SSHD_HARDENED
Port ${ssh_port:-22}
HostKey /etc/ssh/ssh_host_ed25519_key

PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PubkeyAcceptedAlgorithms ssh-ed25519
AuthenticationMethods publickey
AllowUsers $username

MaxAuthTries 2
LoginGraceTime 20
ClientAliveInterval 120
ClientAliveCountMax 3
Subsystem sftp internal-sftp
EOF_SSHD_HARDENED
        chmod 0600 "$os_dir/etc/ssh/sshd_config.d/00-hardened.conf"
        rm -f "$os_dir/etc/ssh/sshd_config.d/00-custom.conf"

        # 直接修改主配置：保证 /etc/ssh/sshd_config 首行必然包含 drop-in 目录（First-Match）
        if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$os_dir/etc/ssh/sshd_config" 2>/dev/null; then
            sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$os_dir/etc/ssh/sshd_config"
        fi

        # 3. 严格 Sudoers 与权限组（防呆语法校验）
        mkdir -p "$os_dir/etc/sudoers.d"
        echo '%wheel ALL=(ALL:ALL) ALL' > "$os_dir/etc/sudoers.d/10-wheel"
        chmod 0440 "$os_dir/etc/sudoers.d/10-wheel"
        rm -f "$os_dir/etc/sudoers.d/99-$username"
        rm -f "$os_dir/etc/sudoers.d/10-reinstall"

        chroot "$os_dir" visudo -c -f /etc/sudoers.d/10-wheel
        chroot "$os_dir" usermod -aG wheel "$username"
        chroot "$os_dir" passwd -l root
        rm -rf "$os_dir/root/.ssh"
        chroot "$os_dir" sshd -t
        effective_ssh=$(chroot "$os_dir" sshd -T) || error_and_exit 'Cannot read effective Arch SSH configuration.'
        printf '%s\n' "$effective_ssh" | LC_ALL=C awk -v port="$ssh_port" -v username="$username" '
            BEGIN {
                want["port"]=port; want["hostkey"]="/etc/ssh/ssh_host_ed25519_key"
                want["permitrootlogin"]="no"; want["passwordauthentication"]="no"
                want["kbdinteractiveauthentication"]="no"; want["pubkeyauthentication"]="yes"
                want["pubkeyacceptedalgorithms"]="ssh-ed25519"; want["authenticationmethods"]="publickey"
                want["allowusers"]=username
                aliases["Port"]="port"; aliases["HostKey"]="hostkey"
                aliases["PermitRootLogin"]="permitrootlogin"; aliases["PasswordAuthentication"]="passwordauthentication"
                aliases["KbdInteractiveAuthentication"]="kbdinteractiveauthentication"; aliases["PubkeyAuthentication"]="pubkeyauthentication"
                aliases["PubkeyAcceptedAlgorithms"]="pubkeyacceptedalgorithms"; aliases["AuthenticationMethods"]="authenticationmethods"
                aliases["AllowUsers"]="allowusers"
            }
            {
                field = $1 in aliases ? aliases[$1] : $1
                if (field in want && (++seen[field] != 1 || NF != 2 || $2 != want[field])) exit 1
            }
            END { for (field in want) if (seen[field] != 1) exit 1 }
        ' || error_and_exit 'Effective Arch SSH configuration does not match the requested port and Ed25519 login policy.'
        chroot "$os_dir" systemctl enable sshd.service
        ssh_enabled=$(chroot "$os_dir" systemctl is-enabled sshd.service) &&
            [ "$ssh_enabled" = enabled ] || error_and_exit 'Arch sshd.service was not enabled.'
    fi
EOF_PATCH_SNIPPET
}

main "$@"
