#!/usr/bin/env bash
# ==============================================================================
# build-vps2arch.sh
# 作用：从上游提取 Arch Linux 重装组件，内联依赖与安全加固配置，生成 vps2arch.sh 及审计补丁。
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
DEVELOPMENT_DIR="$OBJECT_DIR/dev"
BUILDER_PATH="$DEVELOPMENT_DIR/build-vps2arch.sh"
OUTPUT_SCRIPT="$OBJECT_DIR/vps2arch.sh"
OUTPUT_PATCH="$DEVELOPMENT_DIR/vps2arch.patch"

UPSTREAM_REPO="bin456789/reinstall"
# 审计检查点：已验证至 603ba80 (2026-11-14)
UPSTREAM_COMMIT="603ba80f939db7f9fc82ad215bcac8d6558bd588"
UPSTREAM_BASE_URL="https://raw.githubusercontent.com/${UPSTREAM_REPO}/${UPSTREAM_COMMIT}"

BUILD_DIR=$(mktemp -d "$DEVELOPMENT_DIR/.build_tmp_XXXXXX")
cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

STAGES_DIR="$BUILD_DIR/stages"
mkdir -p "$STAGES_DIR"

printf '▶ 1. 抓取上游组件 (Commit: %s)...\n' "$UPSTREAM_COMMIT"
CURL_FETCH="curl -fsSL --retry 3 --retry-delay 2"
$CURL_FETCH "${UPSTREAM_BASE_URL}/reinstall.sh" -o "$BUILD_DIR/reinstall.sh"
$CURL_FETCH "${UPSTREAM_BASE_URL}/trans.sh" -o "$BUILD_DIR/trans.sh"
$CURL_FETCH "${UPSTREAM_BASE_URL}/initrd-network.sh" -o "$BUILD_DIR/initrd-network.sh"
$CURL_FETCH "${UPSTREAM_BASE_URL}/fix-eth-name.sh" -o "$BUILD_DIR/fix-eth-name.sh"
$CURL_FETCH "${UPSTREAM_BASE_URL}/fix-eth-name.service" -o "$BUILD_DIR/fix-eth-name.service"

printf '▶ 2. 剪枝优化：剔除无关目标系统与死代码（~5,000+ 行）...\n'
# 2.1 剪除 trans.sh 中的无关安装分支、Web 控制台与非 Arch 驱动/网络配置
awk '
    # 剪除 Web 控制台（避免公网无认证端口暴露，保留关键内存探测函数 get_approximate_ram_size）
    /^setup_nginx\(\) \{/ {
        in_web1 = 1
        next
    }
    in_web1 && /^get_approximate_ram_size\(\) \{/ {
        in_web1 = 0
    }
    /^setup_web_if_enough_ram\(\) \{/ {
        in_web2 = 1
        next
    }
    in_web2 && /^get_ttys\(\) \{/ {
        in_web2 = 0
    }
    # 剪除 Alpine 安装分支
    /^install_alpine\(\) \{/ {
        print "install_alpine() {"
        print "    error_and_exit \"Alpine is not supported in this build.\""
        print "}"
        in_alpine = 1
        next
    }
    in_alpine && /^get_cpu_vendor\(\) \{/ {
        in_alpine = 0
    }
    # 剪除 NixOS 主分支
    /^install_nixos\(\) \{/ {
        print "install_nixos() {"
        print "    error_and_exit \"NixOS is not supported in this build.\""
        print "}"
        in_nixos = 1
        next
    }
    in_nixos && /^add_systemd_service\(\) \{/ {
        in_nixos = 0
    }
    # 剪除 Windows 辅助修改（严格止于 get_axx64，保护紧随其后的 cp_resolv_conf / rm_resolv_conf）
    /^modify_windows\(\) \{/ {
        print "modify_windows() { :; }"
        in_mod_win = 1
        next
    }
    in_mod_win && /^get_axx64\(\) \{/ {
        in_mod_win = 0
    }
    # 剪除 Gentoo 与 AOSC 安装分支
    /^    install_gentoo\(\) \{/ {
        print "    install_gentoo() { :; }"
        in_gentoo = 1
        next
    }
    in_gentoo && /^    install_aosc\(\) \{/ {
        in_gentoo = 0
        print "    install_aosc() { :; }"
        in_aosc = 1
        next
    }
    in_aosc && /^    local os_dir=\/os/ {
        in_aosc = 0
    }
    # 剪除 fnOS 与 qcow 镜像文件复制安装
    /^install_fnos\(\) \{/ {
        print "install_fnos() {"
        print "    error_and_exit \"fnOS is not supported in this build.\""
        print "}"
        in_fnos = 1
        next
    }
    in_fnos && /^get_partition_table_format\(\) \{/ {
        in_fnos = 0
    }
    # 剪除 Windows 目标安装分支（保留前面的基础工具函数）
    /^install_windows\(\) \{/ {
        print "install_windows() {"
        print "    error_and_exit \"Windows is not supported in this build.\""
        print "}"
        in_win = 1
        next
    }
    in_win && /^download_netboot_xyz_efi\(\) \{/ {
        in_win = 0
    }
    # 剪除 RedHat / Ubuntu 安装分支
    /^install_redhat_ubuntu\(\) \{/ {
        print "install_redhat_ubuntu() {"
        print "    error_and_exit \"RedHat/Ubuntu is not supported in this build.\""
        print "}"
        in_rhu = 1
        next
    }
    in_rhu && /^trans\(\) \{/ {
        in_rhu = 0
    }
    /^add_user_if_need_for_alpine\(\) \{/ || /^refind_main_disk\(\) \{/ { unused=1; removed++; next }
    unused && /^}/ { unused=0; next }
    /^        setup_web_if_enough_ram$/ { calls++; next }
    $0 == "    web_port=${web_port:-80}" { web_default++; next }
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
        log_case++
        next
    }
    !unused && !in_web1 && !in_web2 && !in_alpine && !in_nixos && !in_mod_win && !in_gentoo && !in_aosc && !in_fnos && !in_win && !in_rhu {
        print
    }
    END { if (removed != 2 || calls != 1 || unused || web_default != 1 || log_case != 1) exit 1 }
' "$BUILD_DIR/trans.sh" > "$BUILD_DIR/trans.pruned.sh"
mv -f "$BUILD_DIR/trans.pruned.sh" "$BUILD_DIR/trans.sh"

# 2.2 剪除 reinstall.sh 中的无关发行版配置（保留 nextos 所需的 setos_alpine 与 finalos 所需的 setos_arch）
awk '
    /^    setos_netboot\.xyz\(\) \{/ { in_skip0 = 1 }
    in_skip0 && /^    setos_alpine\(\) \{/ { in_skip0 = 0 }
    /^    setos_debian\(\) \{/ { in_skip1 = 1 }
    in_skip1 && /^    setos_arch\(\) \{/ { in_skip1 = 0 }
    /^    setos_nixos\(\) \{/ { in_skip2 = 1 }
    in_skip2 && /^[[:space:]]*set_osvar distro/ { in_skip2 = 0; print; next }
    /^cp_boot_files_to_btrfs_root\(\) \{/ { dead_func=1; next }
    dead_func && /^}/ { dead_func=0; defs++; next }
    /^if false && is_need_boot_vmlinuz; then$/ { dead_branch=1; next }
    dead_branch && /^fi$/ { dead_branch=0; branches++; next }
    !dead_func && !dead_branch && !in_skip0 && !in_skip1 && !in_skip2 { print }
    END { if (defs != 1 || branches != 1 || dead_func || dead_branch) exit 1 }
' "$BUILD_DIR/reinstall.sh" > "$BUILD_DIR/reinstall.pruned.sh"
mv -f "$BUILD_DIR/reinstall.pruned.sh" "$BUILD_DIR/reinstall.sh"

# 2.3 与救援端同步剪除源机的 Web 查看器参数、交接和提示。
awk '
    function expect(line) { if ((getline) != 1 || $0 != line) exit 1 }
    /^(get_http_log_url|is_need_web_viewer)\(\) \{$/ {
        if ((getline) != 1 || $0 !~ /^    /) exit 1
        expect("}"); expect("")
        helpers++
        next
    }
    /^[[:blank:]]*\[--web-port[[:blank:]]+PORT\]$/ { help++; next }
    $0 == "    web-port: http-port: \\" { options++; next }
    $0 == "    --web-port | --http-port)" {
        expect("        is_port_valid $2 || error_and_exit \"Invalid $1 value: $2\"")
        expect("        web_port=$2"); expect("        shift 2"); expect("        ;;")
        parse++
        next
    }
    $0 == "        username ssh_port rdp_port web_port web_path allow_ping; do" {
        sub(/ web_port web_path/, "")
        cmdline++
    }
    $0 == "# web 路径" {
        expect("if is_need_web_viewer; then")
        if ((getline) != 1 || $0 !~ /^    web_path=/) exit 1
        expect("fi"); expect("")
        path++
        next
    }
    $0 == "web_port=${web_port:-80}" { defaults++; next }
    $0 == "    echo \"WEB: $(get_http_log_url) (During installation only)\"" { output++; next }
    $0 == "    # 下载 websocketd" {
        expect("    # debian 11+ 才有 websocketd")
        expect("    if [ \"$distro\" = kali ] ||")
        expect("        { [ \"$distro\" = debian ] && [ \"$releasever\" -ge 11 ]; }; then")
        expect("        mkdir_clear $tmp/websocketd")
        expect("        download_and_extract_deb deb websocketd $tmp/websocketd")
        expect("        cp -f $tmp/websocketd/usr/bin/websocketd usr/bin/")
        expect("    fi"); expect("")
        packages++
        next
    }
    { print }
    END { if (helpers != 2 || help != 1 || options != 1 || parse != 1 || cmdline != 1 ||
        path != 1 || defaults != 1 || output != 4 || packages != 1) exit 1 }
' "$BUILD_DIR/reinstall.sh" > "$BUILD_DIR/reinstall.no-web.sh"
mv -f "$BUILD_DIR/reinstall.no-web.sh" "$BUILD_DIR/reinstall.sh"

# 阶段快照 1: 剪枝后快照
cp "$BUILD_DIR/reinstall.sh" "$STAGES_DIR/01-pruned-reinstall.sh"
cp "$BUILD_DIR/trans.sh" "$STAGES_DIR/01-pruned-trans.sh"

printf '▶ 3. 源码级补丁：打通凭据持久化、固化内联依赖并消除外部网络请求...\n'
# 3.1 允许公钥登录与 sudo 密码并存；删除上游的整段互斥检查。
awk '
    $0 == "    # 不能同时使用证书和密码" {
        if ((getline) != 1 || $0 != "    if [ -n \"$password\" ] && [ -n \"$ssh_keys\" ]; then" ||
            (getline) != 1 || $0 != "        error_and_exit \"Cannot set both password and ssh key.\"" ||
            (getline) != 1 || $0 != "    fi") exit 1
        removed++
        next
    }
    { print }
    END { if (removed != 1) exit 1 }
' "$BUILD_DIR/reinstall.sh" > "$BUILD_DIR/reinstall.credentials.sh"
mv -f "$BUILD_DIR/reinstall.credentials.sh" "$BUILD_DIR/reinstall.sh"

# 3.2 打通 initrd 配置持久化：同时保存公钥与密码
sed -i '/cat <<<"$ssh_keys" >$initrd_dir\/configs\/ssh_keys/,/save_password $initrd_dir\/configs/ s/^[[:space:]]*else/    fi\n    if [ -n "$password" ]; then/' "$BUILD_DIR/reinstall.sh"

# 凭据文件必须是一条完整的 SHA-512 crypt 记录。源机和救援共用同一校验。
cat > "$BUILD_DIR/arch-password.txt" <<'EOF_ARCH_PASSWORD'
valid_arch_password_hash() {
    case "$1" in *'
'*) return 1 ;; esac
    printf '%s\n' "$1" | LC_ALL=C grep -Eq '^\$6\$(rounds=[1-9][0-9]{3,8}\$)?[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{86}$'
}

EOF_ARCH_PASSWORD
cat > "$BUILD_DIR/private-boot-copy.txt" <<'EOF_PRIVATE_BOOT_COPY'
            (
                local staged ownership_mode
                staged=$(mktemp -- "$dir/.reinstall-initrd.XXXXXXXXXX")
                trap 'rm -f -- "$staged"' EXIT
                # FAT can ignore chmod. Check the actual mode before copying the digest-bearing image.
                ownership_mode=$(stat -c '%u:%a' -- "$staged") && [ "$ownership_mode" = 0:600 ] ||
                    error_and_exit "无法确认引导目录 $dir 中的 initrd 副本为 root 所有且权限为 0600。"
                cat /reinstall-initrd >"$staged"
                mv -fT -- "$staged" "$dir/reinstall-initrd"
            )
EOF_PRIVATE_BOOT_COPY
awk -v boot_copy_code="$BUILD_DIR/private-boot-copy.txt" '
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
    $0 == "set -eE" { print "{ set +x; } 2>/dev/null"; trace++ }
    $0 == "        set -x" {
        print "        error_and_exit \047重装入口不支持 --debug 或 -x 跟踪。\047"
        if ((getline) != 1 || $0 != "        shift") exit 1
        debug++
        next
    }
    $0 == "        # 第一遍扫描已处理" {
        if ((getline) != 1 || $0 != "        shift") exit 1
        print "        error_and_exit \047重装入口不支持 --debug 或 -x 跟踪。\047"
        debug++
        next
    }
    $0 == "mkdir_clear \"$tmp\"" { $0 = "(umask 077; mkdir_clear \"$tmp\")"; private_tmp++ }
    $0 == "    mkdir -p $initrd_dir/configs" {
        print "    if [ \"$distro\" = arch ]; then"
        print "        (umask 077; mkdir -- \"$initrd_dir/configs\") || error_and_exit \047无法创建私有的救援配置目录。\047"
        print "    else"
        print "    " $0
        print "    fi"
        configs++
        next
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
        hash++
        next
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
        boot_copy++
        next
    }
    $0 == "        extlinux_dir=\"$(dirname \"$target_cfg\")\"" {
        print
        move_boot_copy("        # 复制文件到 extlinux 工作目录", "        extlinux --once=reinstall ")
        extlinux_order++
        next
    }
    $0 == "        info limine" {
        print
        if ((getline) != 1 || $0 != "        echo \"$target_cfg\"") exit 1
        print
        move_boot_copy("        # 复制文件到 boot/limine 分区根目录", "        echo \"default_entry: ")
        limine_order++
        next
    }
    { print }
    END { if (trace != 1 || debug != 2 || private_tmp != 1 || configs != 1 || hash != 1 || hash_stdin != 1 || archive != 1 ||
        boot_copy != 1 || extlinux_order != 1 || limine_order != 1) exit 1 }
' "$BUILD_DIR/reinstall.sh" > "$BUILD_DIR/reinstall.private.sh"
mv -f "$BUILD_DIR/reinstall.private.sh" "$BUILD_DIR/reinstall.sh"

# 3.3 固化 confhome 至固定 commit，避免分支漂移
sed -i "s|confhome=https://raw.githubusercontent.com/${UPSTREAM_REPO}/main|confhome=https://raw.githubusercontent.com/${UPSTREAM_REPO}/${UPSTREAM_COMMIT}|g" "$BUILD_DIR/reinstall.sh"
sed -i "s|confhome_cn=https://cnb.cool/${UPSTREAM_REPO}/-/git/raw/main|confhome_cn=https://cnb.cool/${UPSTREAM_REPO}/-/git/raw/${UPSTREAM_COMMIT}|g" "$BUILD_DIR/reinstall.sh"

# 3.4 内嵌 trans.sh 中的 get_ttys() 为本地实现（消除 live 阶段 wget ttys.sh）
awk '
    /^get_ttys\(\) \{/ {
        print "get_ttys() {"
        print "    local prefix=$1"
        print "    local ttys is_for_cmdline is_first tty"
        print "    if [ \"$(uname -m)\" = \"aarch64\" ]; then"
        print "        ttys=\"ttyS0 ttyAMA0 tty0\""
        print "    else"
        print "        ttys=\"ttyS0 tty0\""
        print "    fi"
        print "    [ \"$prefix\" = \"console=\" ] && is_for_cmdline=true || is_for_cmdline=false"
        print "    is_first=true"
        print "    for tty in $ttys; do"
        print "        if { [ -c \"/dev/$tty\" ] && stty -g -F \"/dev/$tty\" >/dev/null 2>&1; } ||"
        print "           { $is_for_cmdline && ! [ -c \"/dev/$tty\" ]; }; then"
        print "            if $is_first; then"
        print "                is_first=false"
        print "            else"
        print "                printf \" \""
        print "            fi"
        print "            printf \"%s\" \"$prefix$tty\""
        print "            if $is_for_cmdline && { [ \"$tty\" = ttyS0 ] || [ \"$tty\" = ttyAMA0 ]; }; then"
        print "                printf \",115200n8\""
        print "            fi"
        print "        fi"
        print "    done"
        print "}"
        in_ttys = 1
        next
    }
    in_ttys && /^}/ { in_ttys = 0; next }
    !in_ttys { print }
' "$BUILD_DIR/trans.sh" > "$BUILD_DIR/trans.ttys.sh"
mv -f "$BUILD_DIR/trans.ttys.sh" "$BUILD_DIR/trans.sh"

# 3.5 内嵌 trans.sh 中的 add_fix_eth_name_systemd_service（消除 live 阶段 download fix-eth-name）
awk -v fix_sh="$BUILD_DIR/fix-eth-name.sh" -v fix_svc="$BUILD_DIR/fix-eth-name.service" '
    /^add_fix_eth_name_systemd_service\(\) \{/ {
        print "add_fix_eth_name_systemd_service() {"
        print "    local os_dir=$1"
        print "    # [Inlined fix-eth-name.sh] 本地内嵌展开，杜绝外部网络拉取"
        print "    cat <<\047EOF_FIX_ETH_SH\047 > \"$os_dir/fix-eth-name.sh\""
        while ((getline line < fix_sh) > 0) {
            print line
        }
        close(fix_sh)
        print "EOF_FIX_ETH_SH"
        print "    chmod +x \"$os_dir/fix-eth-name.sh\""
        print ""
        print "    # [Inlined fix-eth-name.service] 本地内嵌展开"
        print "    mkdir -p \"$os_dir/etc/systemd/system\""
        print "    cat <<\047EOF_FIX_ETH_SVC\047 > \"$os_dir/etc/systemd/system/fix-eth-name.service\""
        while ((getline line < fix_svc) > 0) {
            print line
        }
        close(fix_svc)
        print "EOF_FIX_ETH_SVC"
        print ""
        print "    chroot \"$os_dir\" systemctl enable fix-eth-name.service 2>/dev/null || true"
        print "    if [ -d \"$os_dir/usr/lib/systemd/system-preset\" ]; then"
        print "        echo \"enable fix-eth-name.service\" > \"$os_dir/usr/lib/systemd/system-preset/01-fix-eth-name.preset\""
        print "    elif [ -d \"$os_dir/lib/systemd/system-preset\" ]; then"
        print "        echo \"enable fix-eth-name.service\" > \"$os_dir/lib/systemd/system-preset/01-fix-eth-name.preset\""
        print "    fi"
        print "}"
        in_fix = 1
        next
    }
    in_fix && /^}/ { in_fix = 0; next }
    !in_fix { print }
' "$BUILD_DIR/trans.sh" > "$BUILD_DIR/trans.fix.sh"
mv -f "$BUILD_DIR/trans.fix.sh" "$BUILD_DIR/trans.sh"

# 3.6 在上游 networkd 渲染位置修正临时账号归属，不依赖后续 IPv4 流程。
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
awk -v account="$BUILD_DIR/networkd-account.txt" '
    $0 == "        # cloud-init 渲染 networkd 配置时，系统要有 systemd-network 用户，不然会报错" {
        if ((getline) != 1 || $0 != "        # 加 || true 防止第二次运行报错" ||
            (getline) != 1 || $0 != "        useradd --system systemd-network || true" ||
            (getline) != 1 || $0 != "        cloud-init devel net-convert -p net.cfg -k yaml -d out -D alpine -O networkd" ||
            (getline) != 1 || $0 != "        userdel -r systemd-network") exit 1
        while ((getline line < account) > 0) print line
        close(account)
        matched++
        next
    }
    { print }
    END { if (matched != 1) exit 1 }
' "$BUILD_DIR/trans.sh" > "$BUILD_DIR/trans.networkd-account.sh"
mv -f "$BUILD_DIR/trans.networkd-account.sh" "$BUILD_DIR/trans.sh"

# 3.7 在原 initrd 归档边界传播管道失败，且在后续引导步骤前验收 Arch 产物。
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
awk -v archive="$BUILD_DIR/initrd-archive.txt" '
    $0 == "    zcat /reinstall-initrd | cpio -idm \\" {
        print "    (set -o pipefail"
        print "    " $0
        if ((getline) != 1 || $0 != "        $(is_in_windows && echo --nonmatching \047dev/console\047 --nonmatching \047dev/null\047)") exit 1
        print "    " $0
        print "    ) || error_and_exit \047无法解包救援 initrd。\047"
        unpack++
        next
    }
    $0 == "    find . | cpio --quiet -o -H newc -R 0:0 | gzip -1 >/reinstall-initrd" {
        while ((getline line < archive) > 0) print line
        close(archive)
        pack++
        next
    }
    { print }
    END { if (unpack != 1 || pack != 1) exit 1 }
' "$BUILD_DIR/reinstall.sh" > "$BUILD_DIR/reinstall.initrd-archive.sh"
mv -f "$BUILD_DIR/reinstall.initrd-archive.sh" "$BUILD_DIR/reinstall.sh"

printf '▶ 4. 植入入口向导：交互采集、CLI 与共同的目标确认...\n'
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

arch_disk_instance() {
    local path=/sys/class/block/$1 devnum seq node
    devnum=$(cat "$path/dev") && seq=$(cat "$path/diskseq") &&
        node=$(stat -Lc '%t:%T' -- "/dev/$1") || return 1
    printf '%s\n' "$devnum" | grep -Eq '^[0-9]+:[0-9]+$' &&
        printf '%s\n' "$seq" | grep -Eq '^[1-9][0-9]*$' || return 1
    [ "$(printf '%x:%x' "${devnum%:*}" "${devnum#*:}")" = "$node" ] || return 1
    printf '%s/%s\n' "$devnum" "$seq"
}

EOF_ARCH_DISK
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

awk -v username_file="$BUILD_DIR/username.txt" '
    /^assert_username_valid\(\) \{/ {
        while ((getline line < username_file) > 0) print line
        close(username_file)
        validators++
        skipping = 1
        next
    }
    /^prompt_username\(\) \{/ { prompts++; skipping = 1; next }
    skipping && /^}/ { skipping = 0; next }
    !skipping { print }
    END { if (validators != 1 || prompts != 1 || skipping) exit 1 }
' "$BUILD_DIR/reinstall.sh" > "$BUILD_DIR/reinstall.username.sh"
mv -f "$BUILD_DIR/reinstall.username.sh" "$BUILD_DIR/reinstall.sh"

cat <<'EOF_WIZARD_SNIPPET' > "$BUILD_DIR/wizard.txt"
# ==============================================================================
# vps2arch 入口处理：支持交互采集与 CLI 直接传参
# ==============================================================================
assert_arch_ssh_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && is_port_valid "$1" || error_and_exit "SSH 端口无效：$1"
    [[ "$1" != 443 ]] || error_and_exit '443/tcp 预留给业务入口，请选择其他 SSH 端口。'
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
        $1 ~ /^(broadcast|metric|mtu|dns-nameservers|dns-search)$/ && NF > 1 { next }
        { bad = 1; exit }
        END { exit (bad || (include_line != "" && includes != 1) || stanzas != 1 || addresses != 1 || gateways != 1) }
    ' "${files[@]}"
}

confirm_arch_ipv4() {
    local evidence ipv4_ethx='' ipv4_mac='' ipv4_addr='' ipv4_gateway='' ipv4_routes='' ipv4_addresses=''
    evidence=$(
        collect_netconf require-ipv4-probes capture-ipv4-evidence >&2 && arch_ipv4_handoff || exit 1
        if [[ ! "$ipv4_routes" =~ (^|[[:space:]])proto[[:blank:]]+dhcp([[:space:]]|$) &&
              ! "$ipv4_addresses" =~ (^|[[:space:]])dynamic([[:space:]]|$) ]] &&
            arch_ifupdown_static /etc/network/interfaces "$ipv4_ethx" "$ipv4_addr" "$ipv4_gateway"; then
            printf 'static\n'
        fi
    ) || error_and_exit '无法采集完整的源机 IPv4 地址、网关和网卡 MAC。'
    arch_confirmed_ipv4=${evidence%%$'\n'*}
    if [[ "$evidence" == *$'\n'static ]]; then
        arch_ipv4_mode=static
        printf '%s\n' '源机 /etc/network/interfaces 的静态配置与采集值一致，采用 static。' >&2
    else
        read -r -p '无法自动确认取址方式，请按服务商要求输入 dhcp（固定租约）或 static（手填，无默认）: ' arch_ipv4_mode < /dev/tty ||
            error_and_exit '无法读取 IPv4 取址方式，请从交互终端运行。'
    fi
    case "$arch_ipv4_mode" in
        dhcp | static) ;;
        *) error_and_exit '未确认固定 IPv4 取址方式，请先核对服务商说明。' ;;
    esac
}

find_arch_bios_boot_disk() {
    local source source_info fs_type ancestors disk
    install_pkg findmnt lsblk || return 1
    source_info=$(findmnt -n -o SOURCE,FSTYPE --nofsroot --target /boot) || return 1
    [[ "$source_info" != *$'\n'* ]] || return 1
    read -r source fs_type <<< "$source_info"
    case "$fs_type" in btrfs|bcachefs|'') return 1 ;; esac
    [[ "$source" == /dev/* && -b "$source" ]] || return 1
    ancestors=$(LC_ALL=C lsblk -snro KNAME,TYPE -- "$source") || return 1
    disk=$(awk '$2 == "disk" { disks[$1] = 1 } END { for (disk in disks) { print disk; count++ } if (count != 1) exit 1 }' <<< "$ancestors") || return 1
    [[ "$disk" =~ ^[a-zA-Z0-9_.-]+$ && -b "/dev/$disk" ]] || return 1
    printf '%s\n' "$disk"
}

confirm_arch_target() {
    local root root_info root_fs ancestors chosen identity name confirm
    ! is_in_windows || error_and_exit '请从目标 VPS 的 Linux 系统执行 Arch 全盘重装。'
    install_pkg lsblk
    command -v blkid >/dev/null || error_and_exit '缺少 util-linux 的 blkid，无法核对目标磁盘。'
    if [[ -n "$xda" ]]; then
        chosen=$xda
    else
        install_pkg findmnt
        root_info=$(findmnt -n -o SOURCE,FSTYPE --nofsroot --target /) || error_and_exit '无法确认根文件系统设备。'
        [[ "$root_info" != *$'\n'* ]] || error_and_exit '无法唯一确认根文件系统，请明确指定 --target-disk。'
        read -r root root_fs <<< "$root_info"
        case "$root_fs" in
            btrfs|bcachefs|'') error_and_exit '无法由单个根设备证明整个文件系统的底层磁盘，请明确指定 --target-disk。' ;;
        esac
        [[ "$root" == /dev/* && -b "$root" ]] || error_and_exit '根文件系统不是可识别的块设备，请明确指定 --target-disk。'
        ancestors=$(LC_ALL=C lsblk -snro KNAME,TYPE -- "$root") || error_and_exit '无法读取根设备的底层磁盘。'
        chosen=$(awk '$2 == "disk" { disks[$1] = 1 } END { for (disk in disks) { print disk; count++ } if (count != 1) exit 1 }' <<< "$ancestors") \
            || error_and_exit '无法唯一确定根设备所在磁盘，请明确指定 --target-disk。'
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
        IFS= read -s -rp "新用户 sudo 提权密码: " p1 < /dev/tty; printf '\n'
        IFS= read -s -rp "再次输入确认密码: " p2 < /dev/tty; printf '\n'
        if [[ -n "$p1" && "$p1" == "$p2" ]]; then
            TARGET_PASSWORD="$p1"
            break
        fi
        printf '❌ 两次密码输入不匹配或为空，请重新输入\n' >&2
    done

    # 3. 校验并采集 Ed25519 公钥
    AUTH_KEY_FILE="/root/.ssh/authorized_keys"
    DEFAULT_KEY=""
    if [[ -f "$AUTH_KEY_FILE" ]]; then
        while IFS= read -r key || [[ -n "$key" ]]; do
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
    read -rp $'\n新系统 SSH 端口 [默认 22]: ' TARGET_SSH_PORT < /dev/tty
    TARGET_SSH_PORT=${TARGET_SSH_PORT:-22}
    assert_arch_ssh_port "$TARGET_SSH_PORT"

    set -- arch \
        --username "$username" \
        --password "$TARGET_PASSWORD" \
        --ssh-key "$TARGET_SSH_KEY" \
        --ssh-port "$TARGET_SSH_PORT"
else
    # CLI 传参模式：保留目标与控制命令，其余参数自动补全 arch
    case "$1" in
        arch|reset|-h|--help) ;;
        *) set -- arch "$@" ;;
    esac
fi
EOF_WIZARD_SNIPPET

awk -v wizard="$BUILD_DIR/wizard.txt" -v disk="$BUILD_DIR/arch-disk.txt" -v hash="$BUILD_DIR/arch-password.txt" '
    $0 == "get_local_bootloader_type() {" { boot_type=1 }
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
        bios_disk++
        next
    }
    boot_type && /head -c 446 \/dev\/\$xda/ { sub(/\/dev\/\$xda/, "\"/dev/$boot_disk\""); bios_reads++ }
    boot_type && $0 == "}" { boot_type=0 }
    $0 == "init_bootloader_facts" {
        $0 = "if [ \"$distro\" != arch ]; then init_bootloader_facts; fi"
        init_early++
    }
    $0 == "    for key in confhome hold force_boot_mode force_cn cloud_image no_cloud_kernel main_disk \\" {
        print
        print "        arch_ipv4_mode \\"
        cmdline++
        next
    }
    $0 == "collect_netconf() {" {
        print
        print "    local probe_output"
        in_collect=1
        next
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
    in_collect && $0 == "}" { in_collect=0 }
    $0 == "get_ip_conf_cmd() {" { in_ip_conf=1 }
    in_ip_conf && $0 == "    collect_netconf >&2" {
        print "    if [ -n \"$arch_ipv4_mode\" ]; then unset ipv4_mac ipv4_addr ipv4_gateway; fi"
        print "    collect_netconf \"${arch_ipv4_mode:+require-ipv4-probes}\" >&2 || error_and_exit \047无法读取源机网络参数。\047"
        print "    if [ -n \"$arch_ipv4_mode\" ]; then"
        print "        [ \"$(arch_ipv4_handoff)\" = \"$arch_confirmed_ipv4\" ] ||"
        print "            error_and_exit \047源机 IPv4 参数已变化或无法复核，请重新核对。\047"
        print "    fi"
        ip_recheck++
        next
    }
    in_ip_conf && $0 == "}" { in_ip_conf=0 }
    $0 == "    insert_into_file init after \047configure_ip\\(\\)\047 <<EOF" {
        print "    ip_conf_cmd=$(get_ip_conf_cmd)"
        prepare_conf++
    }
    $0 == "        $(get_ip_conf_cmd)" { $0 = "        $ip_conf_cmd"; embed_conf++ }
    /# 使用 getopt 解析参数/ {
        while ((getline s < disk) > 0) print s
        close(disk)
        while ((getline s < hash) > 0) print s
        close(hash)
        while ((getline s < wizard) > 0) print s
        close(wizard)
        print ""
        wizards++
    }
    $0 == "    --ssh-port)" {
        print
        if ((getline) != 1 || $0 != "        is_port_valid $2 || error_and_exit \"Invalid $1 value: $2\"") exit 1
        print "        assert_arch_ssh_port \"$2\""
        ports++
        next
    }
    $0 == "# 第二遍扫描，处理参数" {
        print "unset xda main_disk arch_confirmed_ipv4 arch_ipv4_mode ssh_keys username password ssh_port"
        parses++
    }
    $0 == "  --ssh-key \"ssh-rsa ...\"" || $0 == "  --ssh-key \"ecdsa-sha2-nistp256/384/521 ...\"" ||
        $0 == "  --ssh-key http://path/to/public_key" { next }
    $0 == "        gh:* | github:* | gl:* | gitlab:* | http://* | https://*)" {
        print "        http://*) ssh_key_error_and_exit \047远程公钥来源必须使用 HTTPS。\047 ;;"
        sub(/ \| http:\/\/\*/, "")
    }
    $0 == "            if ! ssh_key=$(curl -L \"$key_url\"); then" {
        sub(/curl -L/, "curl -fsSL --proto =https --proto-redir =https")
        remote++
    }
    $0 == "if ! is_netboot_xyz; then" && previous == "# 用户名密码" { $0 = "if [ \"$distro\" != arch ] && ! is_netboot_xyz; then" }
    $0 == "        is_valid_ssh_key() {" {
        print "        command -v ssh-keygen >/dev/null || error_and_exit \047缺少 ssh-keygen，无法校验 Ed25519 公钥。\047"
        if ((getline) != 1 || $0 !~ /^            grep -qE / || (getline) != 1 || $0 != "        }") exit 1
        key_functions++
        next
    }
    /if (! )?is_valid_ssh_key / { sub(/is_valid_ssh_key/, "validate_arch_keys"); key_calls++ }
    $0 == "        xda=${2##*/dev/}" {
        print "        xda=${2#/dev/}"
        print "        [[ \"$xda\" =~ ^[a-zA-Z0-9_.-]+$ ]] || error_and_exit \047请指定整盘的内核设备名，例如 /dev/vda。\047"
        disk_args++
        next
    }
    $0 == "# 检查内存" {
        print "if [ \"$distro\" = arch ]; then"
        print "    require_arch_credentials"
        print "    if [ \"$basearch\" = x86_64 ]; then confirm_arch_ipv4; fi"
        print "    confirm_arch_target"
        print "    init_bootloader_facts"
        print "fi"
        print ""
        confirms++
    }
    $0 == "THIS_SCRIPT=$(readlink -f \"$0\")" {
        print
        print "printf -v reinstall_reset \047bash %q reset\047 \"$THIS_SCRIPT\""
        reset_command++
        next
    }
    /^    warn false / && sub(/\$reinstall_____ reset/, "$reinstall_reset") { reset_hints++ }
    $0 ~ /^    warn false "If you want to cancel the reinstallation, run / {
        print
        if ((getline) != 1 || $0 != "    warn false \047**********************************\047") exit 1
        print
        print "    if [ \"$distro\" = arch ]; then printf \047本次已安排重装\\n\047; fi"
        scheduled++
        next
    }
    { print; previous=$0 }
    END { if (wizards != 1 || ports != 1 || parses != 1 || key_functions != 1 || key_calls != 2 || disk_args != 1 || confirms != 1 ||
        remote != 1 || cmdline != 1 || route_probe != 1 || mac_probe != 1 || address_probe != 1 ||
        ip_recheck != 1 || prepare_conf != 1 || embed_conf != 1 || bios_disk != 1 || bios_reads != 2 || bios_cache != 1 ||
        init_early != 1 || reset_command != 1 || reset_hints != 8 || scheduled != 1) exit 1 }
' "$BUILD_DIR/reinstall.sh" > "$BUILD_DIR/reinstall.wizard.sh"
mv -f "$BUILD_DIR/reinstall.wizard.sh" "$BUILD_DIR/reinstall.sh"

printf '▶ 5. 源码级补丁：固化 trans.sh 凭据设置与 Arch 终态安全加固...\n'
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
        local ssh_enabled
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

        # 保证主配置必然包含 drop-in 目录
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

awk -v patch_file="$BUILD_DIR/basic_init_patch.txt" '
    $0 == "add_user_if_need() {" { add_user=1 }
    add_user && $0 == "    if ! grep -q \"^$username:\" \"$os_dir/etc/passwd\"; then" {
        print "    if grep -q \"^$username:\" \"$os_dir/etc/passwd\"; then"
        print "        [ \"$distro\" != arch ] || error_and_exit \"The requested login user $username already exists. Choose a new username.\""
        print "    else"
        print "        if [ \"$?\" -ne 1 ] && [ \"$distro\" = arch ]; then"
        print "            error_and_exit \"Cannot read the account database under $os_dir.\""
        print "        fi"
        add_user=0
        account_gate++
        next
    }
    $0 == "change_user_password() {" { password=1 }
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
        password=0
        hash_read++
        next
    }
    /^basic_init\(\) \{/ { basic=1 }
    basic && /^    # sshd$/ { print "    if [ \"$distro\" != arch ]; then"; generic=1 }
    basic && /# 公钥\/密码/ {
        if (!generic) exit 1
        print "    fi\n"
        generic=0
        while ((getline line) > 0) {
            if (line ~ /change_ssh_conf_for_password_login/) {
                getline line
                break
            }
        }
        while ((getline s < patch_file) > 0) {
            print s
        }
        close(patch_file)
        found++
        basic=0
        next
    }
    { print (generic && length($0) ? "    " $0 : $0) }
    END { if (found != 1 || generic || account_gate != 1 || hash_only != 1 || hash_read != 1) exit 1 }
' "$BUILD_DIR/trans.sh" > "$BUILD_DIR/trans.patched.sh"
mv -f "$BUILD_DIR/trans.patched.sh" "$BUILD_DIR/trans.sh"

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
        dhcp:1:0 | static:0:0) ;;
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
    if [ "$arch_ipv4_mode" = static ]; then
        gateway=$(cat "/dev/netconf/$nic/ipv4_gateway") && [ -n "$gateway" ] &&
            [ "$actual" = "$expected" ] &&
            printf '%s\n' "$routes" | awk -v gateway="$gateway" '
                NR != 1 || $1 != "default" || $2 != "via" || $3 != gateway { exit 1 }
            ' || error_and_exit 'The static IPv4 prefix or gateway changed in rescue.'
    fi
}
EOF_ARCH_FIXED_IPV4

awk -v network_gate="$BUILD_DIR/arch-fixed-ipv4.txt" -v disk="$BUILD_DIR/arch-disk.txt" \
    -v rescue_disk="$BUILD_DIR/arch-rescue-disk.txt" -v hash="$BUILD_DIR/arch-password.txt" \
    -v rescue_password="$BUILD_DIR/arch-rescue-password.txt" '
    { lines[NR] = $0 }
    $0 == "# 带参数运行部分" { rescue = NR; rescues++ }
    $0 == "# 无参数运行部分" { main = NR; mains++ }
    $0 == "install_arch_gentoo_aosc() {" { installer = NR; installers++ }
    $0 == "    # 需要在重新分区之前，找到主硬盘" { select = NR; selections++ }
    $0 == "    wipefs -a -f /dev/$xda" { wipe = NR; wipes++ }
    $0 == "extract_env_from_cmdline" { extract = NR; extractions++ }
    $0 == "    if is_have_cmd sudo; then" && lines[NR - 2] == "    error \"$@\"" { retry_start = NR; retry_starts++ }
    index($0, "echo \"Run \047$sudo_/trans.sh\047 to retry.\" >&2") { retry = NR; retries++ }
    index($0, "/trans.sh alpine") && index($0, "install Alpine Linux instead.") { obsolete_tip = NR; tips++ }
    END {
        if (installers != 1 || rescues != 1 || mains != 1 || tips != 1 || selections != 1 || wipes != 1 || extractions != 1 || retries != 1 || retry_starts != 1 ||
            retry_start + 8 != retry ||
            !(obsolete_tip < installer && installer < wipe && wipe < select && select < extract && extract < rescue && rescue < main) ||
            lines[select + 3] != "    if [ -z \"$xda\" ]; then" || lines[select + 4] != "        find_xda" ||
            lines[select + 5] != "    fi" ||
            lines[rescue + 2] != "if [ \"$1\" = \"update\" ]; then" ||
            lines[rescue + 5] != "    wget -O /trans.sh \"$confhome/trans.sh\"" ||
            lines[rescue + 7] != "    exec /trans.sh" ||
            lines[rescue + 8] != "elif [ \"$1\" = \"alpine\" ]; then" ||
            lines[main - 4] != "elif [ -n \"$1\" ]; then" ||
            lines[main - 3] != "    error_and_exit \"unknown option $1\"" ||
            lines[main - 2] != "fi") exit 1
        for (i = 1; i <= NR; i++) {
            if (i == obsolete_tip) continue
            if (i == rescue) {
                print "if [ -n \"$1\" ]; then"
                print lines[main - 3]
                print lines[main - 2]
                print ""
                i = main - 1
                continue
            }
            if (i == installer) {
                while ((getline line < disk) > 0) print line
                close(disk)
                while ((getline line < rescue_disk) > 0) print line
                close(rescue_disk)
                while ((getline line < network_gate) > 0) print line
                close(network_gate)
                print ""
            }
            if (i == select) {
                print "    if [ \"$distro\" = arch ]; then"
                print "        apk add lsblk blkid"
                print "        require_confirmed_arch_disk"
                print "    elif [ -z \"$xda\" ]; then"
                print lines[select + 4]
                print lines[select + 5]
                i += 5
                continue
            }
            if (i == retry_start) {
                i = retry
                print "    if [ \"$arch_erase_started\" = 1 ]; then"
                print "        echo \047Erasure was attempted in this run; data may already be lost. Check the disk and install log from the console.\047 >&2"
                print "    else"
                print "        echo \047Erasure has not been attempted in this run. Check the target and install log from the console.\047 >&2"
                print "    fi"
                continue
            }
            if (i == wipe) {
                print "    if [ \"$distro\" = arch ]; then"
                print "        require_confirmed_arch_disk"
                print "        require_arch_fixed_ipv4"
                print "        [ \"$(arch_disk_instance \"$xda\")\" = \"$arch_rescue_disk_instance\" ] || error_and_exit \047The confirmed device changed at the erase boundary.\047"
                print "    fi"
                print "    arch_erase_started=1"
            }
            if (i == extract) {
                while ((getline s < hash) > 0) print s
                close(hash)
                while ((getline s < rescue_password) > 0) print s
                close(rescue_password)
                print "unset main_disk xda arch_rescue_disk_instance arch_ipv4_mode arch_erase_started"
            }
            print lines[i]
            if (i == extract) print "if [ \"$distro\" = arch ]; then require_arch_rescue_credentials; fi"
        }
    }
' "$BUILD_DIR/trans.sh" > "$BUILD_DIR/trans.arch-gates.sh" || { printf '❌ 无法确认上游 Arch 分区和救援边界。\n' >&2; exit 1; }
mv -f "$BUILD_DIR/trans.arch-gates.sh" "$BUILD_DIR/trans.sh"

printf '▶ 6. 生成审计补丁 (Unified Diff)...\n'
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
# (Excludes dead-branch pruning diffs; focuses on wizard & Arch security hardening)
# Generated automatically by ${BUILDER_PATH}.
# ==============================================================================
EOF_PATCH_HEADER
cat "$BUILD_DIR/reinstall.patch" "$BUILD_DIR/trans.patch" | tr -d '\r' >> "$BUILD_DIR/vps2arch.patch"

printf '▶ 7. 依赖展平与静态内联嵌入...\n'
cat << 'EOF_INLINE_AWK' > "$BUILD_DIR/inline.awk"
BEGIN {
    in_replace = 0
}
/curl -Lo \$initrd_dir\/trans.sh/ {
    in_replace = 1
    print "    # [Inlined Components] 静态自包含展开，无需二次网络拉取"
    print "    cat <<\047EOF_INLINED_TRANS\047 > \"$initrd_dir/trans.sh\""
    while ((getline line < trans_file) > 0) {
        print line
    }
    close(trans_file)
    print "EOF_INLINED_TRANS"
    print ""
    print "    cat <<\047EOF_INLINED_NETWORK\047 > \"$initrd_dir/initrd-network.sh\""
    while ((getline line < net_file) > 0) {
        print line
    }
    close(net_file)
    print "EOF_INLINED_NETWORK"
    next
}
in_replace && /chmod a\+x \$initrd_dir\/trans.sh/ {
    in_replace = 0
    print "    chmod a+x \"$initrd_dir/trans.sh\" \"$initrd_dir/initrd-network.sh\""
    next
}
!in_replace {
    print
}
EOF_INLINE_AWK

awk -v trans_file="$BUILD_DIR/trans.sh" -v net_file="$BUILD_DIR/initrd-network.sh" -f "$BUILD_DIR/inline.awk" "$BUILD_DIR/reinstall.sh" | tr -d '\r' > "$BUILD_DIR/vps2arch.raw.sh"

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

printf '▶ 8. 产物完整性与安全加固断言校验...\n'
# 8.1 语法校验
bash -n "$BUILD_DIR/vps2arch.sh"
bash -n "$BUILD_DIR/trans.sh"
bash -n "$BUILD_DIR/initrd-network.sh"

# 8.2 剪枝断言：确保死代码被正确替换为桩或剔除，原厂大块无关系统绝未泄漏
if grep -qE 'install_alpine\(\) \{[[:space:]]*echo' "$BUILD_DIR/vps2arch.sh" || ! grep -q 'Alpine is not supported in this build' "$BUILD_DIR/vps2arch.sh"; then
    echo "❌ 断言失败: Alpine 安装分支剪枝异常" >&2; exit 1
fi
if ! grep -q 'NixOS is not supported in this build' "$BUILD_DIR/vps2arch.sh"; then
    echo "❌ 断言失败: NixOS 安装分支剪枝异常" >&2; exit 1
fi
if grep -En 'setup_nginx|setup_web_if_enough_ram|logviewer|websocketd|web[_-](port|path)|http-port|get_http_log_url|is_need_web_viewer|WEB:' "$BUILD_DIR/vps2arch.sh" >&2; then
    echo "❌ 断言失败: 未认证 Web 控制台代码泄漏" >&2; exit 1
fi

# 8.3 依赖内联断言：确保无 live 阶段二次网络拉取
if grep -q 'curl -Lo $initrd_dir/trans.sh' "$BUILD_DIR/vps2arch.sh"; then
    echo "❌ 断言失败: trans.sh 未能成功静态内联" >&2; exit 1
fi
if grep -q 'curl -Lo $initrd_dir/initrd-network.sh' "$BUILD_DIR/vps2arch.sh"; then
    echo "❌ 断言失败: initrd-network.sh 未能成功静态内联" >&2; exit 1
fi

# 8.4 关键向导与探针函数保留断言
for fn in prompt_username assert_username_valid get_approximate_ram_size; do
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

# 8.6 审计补丁断言
if [[ ! -s "$BUILD_DIR/vps2arch.patch" ]] || ! grep -q -- '--- upstream/' "$BUILD_DIR/vps2arch.patch"; then
    printf '❌ 断言失败: 审计补丁 %s 为空或无效\n' "$OUTPUT_PATCH" >&2; exit 1
fi

mv -f "$BUILD_DIR/vps2arch.patch" "$OUTPUT_PATCH"
mv -f "$BUILD_DIR/vps2arch.sh" "$OUTPUT_SCRIPT"

ACTUAL_SHA256=$(sha256sum "$OUTPUT_SCRIPT" | awk '{print $1}')
FILE_SIZE=$(du -h "$OUTPUT_SCRIPT" | awk '{print $1}')
PATCH_LINES=$(wc -l < "$OUTPUT_PATCH")

printf '\n✅ 静态构建与审计完成！\n'
printf '   生产产物: %s (%s, SHA256: %s)\n' "$OUTPUT_SCRIPT" "$FILE_SIZE" "$ACTUAL_SHA256"
printf '   审计补丁: %s (%s 行 diff)\n' "$OUTPUT_PATCH" "$PATCH_LINES"
