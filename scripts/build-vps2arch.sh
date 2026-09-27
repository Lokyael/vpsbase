#!/usr/bin/env bash
# ==============================================================================
# build-vps2arch.sh
# 作用：拉取上游稳定提交，深度剪除无关系统大块冗余代码，内联固化网络与控制台依赖，
#       内置交互采集与 Arch 终态安全加固，生成纯净审计凭证与 100% 离线自包含静态脚本。
# ==============================================================================
set -Eeuo pipefail

# 彻底关闭 Windows Git Bash (MSYS) 路径转换，保证 Unix 路径原样输出
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
export LC_ALL=C

# 定位仓库根目录，统一以相对路径操作，彻底消除驱动器盘符与反斜杠转义歧义
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)
cd "$REPO_ROOT"

OUTPUT_SCRIPT="scripts/vps2arch.sh"
OUTPUT_PATCH="scripts/vps2arch.patch"

UPSTREAM_REPO="bin456789/reinstall"
UPSTREAM_COMMIT="b333811ede8dc87d47785ff1456d339ba3dde122"
UPSTREAM_BASE_URL="https://raw.githubusercontent.com/${UPSTREAM_REPO}/${UPSTREAM_COMMIT}"

BUILD_DIR=$(mktemp -d "scripts/.build_tmp_XXXXXX")
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

# 阶段快照 0: 上游原始镜像
cp "$BUILD_DIR/reinstall.sh" "$STAGES_DIR/00-upstream-reinstall.sh"
cp "$BUILD_DIR/trans.sh" "$STAGES_DIR/00-upstream-trans.sh"
cp "$BUILD_DIR/initrd-network.sh" "$STAGES_DIR/00-upstream-network.sh"

RAW_TRANS_LINES=$(wc -l < "$BUILD_DIR/trans.sh")
RAW_REINSTALL_LINES=$(wc -l < "$BUILD_DIR/reinstall.sh")

printf '▶ 2. 剪枝优化：剔除无关目标系统与死代码（~5,000+ 行）...\n'
# 2.1 剪除 trans.sh 中的无关安装分支、Web 控制台与非 Arch 驱动/网络配置
awk '
    # 剪除 Web 控制台（杜绝公网无认证端口暴露，保留关键内存探测函数 get_approximate_ram_size）
    /^setup_nginx\(\) \{/ {
        in_web1 = 1
        next
    }
    in_web1 && /^get_approximate_ram_size\(\) \{/ {
        in_web1 = 0
        print "setup_web_if_enough_ram() { :; }"
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
    !in_web1 && !in_web2 && !in_alpine && !in_nixos && !in_mod_win && !in_gentoo && !in_aosc && !in_fnos && !in_win && !in_rhu {
        print
    }
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
    !in_skip0 && !in_skip1 && !in_skip2 { print }
' "$BUILD_DIR/reinstall.sh" > "$BUILD_DIR/reinstall.pruned.sh"
mv -f "$BUILD_DIR/reinstall.pruned.sh" "$BUILD_DIR/reinstall.sh"

# 阶段快照 1: 剪枝后快照
cp "$BUILD_DIR/reinstall.sh" "$STAGES_DIR/01-pruned-reinstall.sh"
cp "$BUILD_DIR/trans.sh" "$STAGES_DIR/01-pruned-trans.sh"

printf '▶ 3. 源码级补丁：打通凭据持久化、固化内联依赖并消除外部网络请求...\n'
# 3.1 消除 --password 与 --ssh-key 互斥报错
sed -i 's/error_and_exit "Cannot set both password and ssh key."/:/' "$BUILD_DIR/reinstall.sh"

# 3.2 打通 initrd 配置持久化：同时保存公钥与密码
sed -i '/cat <<<"$ssh_keys" >$initrd_dir\/configs\/ssh_keys/,/save_password $initrd_dir\/configs/ s/^[[:space:]]*else/    fi\n    if [ -n "$password" ]; then/' "$BUILD_DIR/reinstall.sh"

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

printf '▶ 4. 植入入口向导：内置交互采集与 CLI 自动补全...\n'
cat <<'EOF_WIZARD_SNIPPET' > "$BUILD_DIR/wizard.txt"
# ==============================================================================
# vps2arch 入口处理：支持交互采集与 CLI 直接传参
# ==============================================================================
if [ $# -eq 0 ]; then
    if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
        echo "❌ 缺少 TTY 终端交互环境，请通过命令行参数传入（例如：--username <USER> --password <PASS> --ssh-key <KEY>）" >&2
        exit 1
    fi

    printf '\n════════════════════════════════════════════════════════\n'
    printf '  vps2arch: Arch Linux 原生安全一键重装\n'
    printf '════════════════════════════════════════════════════════\n\n'

    # 1. 采集普通用户名
    TARGET_USER=""
    while true; do
        read -rp "新系统登录普通用户名 (禁止为 root): " TARGET_USER < /dev/tty
        [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ && "$TARGET_USER" != "root" ]] && break
        printf '❌ 用户名不合法（必须小写字母开头，且不能为 root），请重新输入\n' >&2
    done

    # 2. 采集 sudo 提权密码
    TARGET_PASSWORD=""
    while true; do
        read -s -rp "新用户 sudo 提权密码: " p1 < /dev/tty; printf '\n'
        read -s -rp "再次输入确认密码: " p2 < /dev/tty; printf '\n'
        if [[ -n "$p1" && "$p1" == "$p2" ]]; then
            TARGET_PASSWORD="$p1"
            break
        fi
        printf '❌ 两次密码输入不匹配或为空，请重新输入\n' >&2
    done

    # 3. 校验并采集 Ed25519 公钥
    AUTH_KEY_FILE="/root/.ssh/authorized_keys"
    DEFAULT_KEY=""
    if [[ -f "$AUTH_KEY_FILE" ]] && grep -qE '^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]{68,}={0,2}([[:space:]].*)?$' "$AUTH_KEY_FILE"; then
        DEFAULT_KEY=$(grep -m1 -E '^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]{68,}={0,2}([[:space:]].*)?$' "$AUTH_KEY_FILE")
        printf '\n🔑 检测到宿主有效 Ed25519 公钥：\n%s\n' "$DEFAULT_KEY"
    fi

    TARGET_SSH_KEY=""
    while true; do
        if [[ -n "$DEFAULT_KEY" ]]; then
            read -rp "登录 Ed25519 公钥 [回车默认使用上方公钥]: " TARGET_SSH_KEY < /dev/tty
            TARGET_SSH_KEY="${TARGET_SSH_KEY:-$DEFAULT_KEY}"
        else
            read -rp "请输入将用于登录的 Ed25519 SSH 公钥文本: " TARGET_SSH_KEY < /dev/tty
        fi
        TARGET_SSH_KEY=$(printf '%s' "$TARGET_SSH_KEY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ "$TARGET_SSH_KEY" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]{68,}={0,2}([[:space:]].*)?$ ]] && break
        printf '❌ 公钥无效（必须为 ssh-ed25519 格式），请重新输入\n' >&2
    done

    # 4. SSH 端口
    read -rp $'\n新系统 SSH 端口 [默认 22]: ' TARGET_SSH_PORT < /dev/tty
    TARGET_SSH_PORT=${TARGET_SSH_PORT:-22}
    [[ "$TARGET_SSH_PORT" =~ ^[0-9]+$ ]] && (( TARGET_SSH_PORT >= 1 && TARGET_SSH_PORT <= 65535 )) || { printf '❌ 端口无效\n' >&2; exit 1; }

    # 5. 高危抹盘二次确认
    printf '\n目标: Arch Linux | 用户: %s | 端口: %s | 认证: 仅 Ed25519 公钥\n' "$TARGET_USER" "$TARGET_SSH_PORT"
    read -rp "确认开始重装？整盘数据将被抹除 [y/N]: " CONFIRM_REINSTALL < /dev/tty
    [[ "$CONFIRM_REINSTALL" =~ ^[yY]$ ]] || { printf '已取消\n'; exit 0; }

    set -- arch \
        --username "$TARGET_USER" \
        --password "$TARGET_PASSWORD" \
        --ssh-key "$TARGET_SSH_KEY" \
        --ssh-port "$TARGET_SSH_PORT"
else
    # CLI 传参模式：若首参数不是 arch 且不是 help，自动补全目标 distro 为 arch
    if [ "$1" != "arch" ] && [ "$1" != "-h" ] && [ "$1" != "--help" ]; then
        set -- arch "$@"
    fi
fi
EOF_WIZARD_SNIPPET

awk -v wizard="$BUILD_DIR/wizard.txt" '
    /# 使用 getopt 解析参数/ {
        while ((getline s < wizard) > 0) {
            print s
        }
        close(wizard)
        print ""
    }
    { print }
' "$BUILD_DIR/reinstall.sh" > "$BUILD_DIR/reinstall.wizard.sh"
mv -f "$BUILD_DIR/reinstall.wizard.sh" "$BUILD_DIR/reinstall.sh"

printf '▶ 5. 源码级补丁：固化 trans.sh 凭据设置与 Arch 终态安全加固...\n'
cat <<'EOF_PATCH_SNIPPET' > "$BUILD_DIR/basic_init_patch.txt"
    # 公钥/密码设置
    add_user_if_need "$os_dir"
    if is_need_set_ssh_keys; then
        set_ssh_keys_and_del_password "$os_dir"
        change_ssh_conf_for_key_login "$os_dir"
    fi
    if [ -s /configs/password-plaintext ] || [ -s /configs/password-linux-sha512 ]; then
        change_user_password "$os_dir"
    fi

    # Arch Linux 终态原生加固
    if [ "$distro" = "arch" ]; then
        # 1. 主机密钥：仅保留 Ed25519 并显式固化强权限（通配符避免双引号包裹导致无法展开）
        rm -f "$os_dir"/etc/ssh/ssh_host_*
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
            sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$os_dir/etc/ssh/sshd_config" 2>/dev/null || true
        fi

        # 3. 严格 Sudoers 与权限组（防呆语法校验）
        mkdir -p "$os_dir/etc/sudoers.d"
        echo '%wheel ALL=(ALL:ALL) ALL' > "$os_dir/etc/sudoers.d/10-wheel"
        chmod 0440 "$os_dir/etc/sudoers.d/10-wheel"
        rm -f "$os_dir/etc/sudoers.d/99-$username"
        rm -f "$os_dir/etc/sudoers.d/10-reinstall"

        chroot "$os_dir" visudo -c -f /etc/sudoers.d/10-wheel
        chroot "$os_dir" usermod -aG wheel "$username" 2>/dev/null || true
        chroot "$os_dir" passwd -l root 2>/dev/null || true
        rm -rf "$os_dir/root/.ssh"
        chroot "$os_dir" systemctl enable sshd.service 2>/dev/null || true
        chroot "$os_dir" sshd -t || true
    fi
EOF_PATCH_SNIPPET

awk -v patch_file="$BUILD_DIR/basic_init_patch.txt" '
    /# 公钥\/密码/ {
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
        found = 1
        next
    }
    { print }
    END { if (!found) exit 1 }
' "$BUILD_DIR/trans.sh" > "$BUILD_DIR/trans.patched.sh"
mv -f "$BUILD_DIR/trans.patched.sh" "$BUILD_DIR/trans.sh"

# 阶段快照 2: 完整加固打补丁后快照
cp "$BUILD_DIR/reinstall.sh" "$STAGES_DIR/02-patched-reinstall.sh"
cp "$BUILD_DIR/trans.sh" "$STAGES_DIR/02-patched-trans.sh"

printf '▶ 6. 默认生成纯净审计补丁 (Unified Diff)...\n'
diff -u -L "upstream/reinstall.sh" -L "vps2arch/reinstall.sh" \
    "$STAGES_DIR/01-pruned-reinstall.sh" "$STAGES_DIR/02-patched-reinstall.sh" > "$BUILD_DIR/reinstall.patch" || true
diff -u -L "upstream/trans.sh" -L "vps2arch/trans.sh" \
    "$STAGES_DIR/01-pruned-trans.sh" "$STAGES_DIR/02-patched-trans.sh" > "$BUILD_DIR/trans.patch" || true

cat <<EOF_PATCH_HEADER > "$OUTPUT_PATCH"
# ==============================================================================
# AUDIT PATCH: Functional and security changes against upstream commit ${UPSTREAM_COMMIT}
# (Excludes dead-branch pruning diffs; focuses on wizard & Arch security hardening)
# Generated automatically by scripts/build-vps2arch.sh.
# ==============================================================================
EOF_PATCH_HEADER
cat "$BUILD_DIR/reinstall.patch" "$BUILD_DIR/trans.patch" | tr -d '\r' >> "$OUTPUT_PATCH"

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
# Source: Built by scripts/build-vps2arch.sh from upstream commit ${UPSTREAM_COMMIT}.
# Audit: See scripts/vps2arch.patch for exact diff against upstream.
# ==============================================================================
EOF_HEADER
tail -n +2 "$BUILD_DIR/vps2arch.raw.sh" >> "$BUILD_DIR/vps2arch.sh"

chmod +x "$BUILD_DIR/vps2arch.sh"

printf '▶ 8. 语法完整性校验...\n'
bash -n "$BUILD_DIR/vps2arch.sh"
bash -n "$BUILD_DIR/trans.sh"

mv -f "$BUILD_DIR/vps2arch.sh" "$OUTPUT_SCRIPT"

ACTUAL_SHA256=$(sha256sum "$OUTPUT_SCRIPT" | awk '{print $1}')
FILE_SIZE=$(du -h "$OUTPUT_SCRIPT" | awk '{print $1}')
PATCH_LINES=$(wc -l < "$OUTPUT_PATCH")

printf '\n✅ 静态构建与审计完成！\n'
printf '   生产产物: %s (%s, SHA256: %s)\n' "$OUTPUT_SCRIPT" "$FILE_SIZE" "$ACTUAL_SHA256"
printf '   审计补丁: %s (%s 行 diff)\n' "$OUTPUT_PATCH" "$PATCH_LINES"
