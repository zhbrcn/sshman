#!/bin/bash
# sshman - SSH 登录管理脚本 (中文交互)

SSH_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
BACKUP_DIR="/etc/ssh/sshman-backups"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
AUTHORIZED_YUBIKEYS="/etc/ssh/authorized_yubikeys"
HARDENED_YUBIKEYS="root:cccccbenueru:cccccbejiijg"
YUBI_CLIENT_ID="85975"
YUBI_SECRET_KEY="//EomrFfWNk8fWV/6h7IW8pgs9Y="

mkdir -p "$BACKUP_DIR"

# 自动检测 ssh/sshd 服务名
_detect_ssh_service() {
    if systemctl list-unit-files | grep -q "^ssh.service"; then
        echo "ssh"
    else
        echo "sshd"
    fi
}

SSH_SERVICE=$(_detect_ssh_service)

_backup_file() {
    local file=$1
    local name=$(basename "$file")
    cp "$file" "$BACKUP_DIR/${name}.bak.$(date +%F-%H%M%S)"
}

_restart_ssh() {
    echo "[*] 正在重启 SSH 服务..."
    if systemctl restart "$SSH_SERVICE"; then
        echo "[✓] SSH 重启成功"
    else
        echo "[!] SSH 重启失败，请手动检查！"
    fi
}

_update_directive() {
    local key=$1 value=$2
    if grep -q "^${key}" "$SSH_CONFIG"; then
        sed -i "s/^${key}.*/${key} ${value}/" "$SSH_CONFIG"
    else
        echo "${key} ${value}" >> "$SSH_CONFIG"
    fi
}

_remove_directive() {
    local key=$1
    sed -i "/^${key}\\b/d" "$SSH_CONFIG"
}

_ensure_kbdinteractive() {
    # 确保键盘交互式认证开启，否则 YubiKey OTP 不会被 sshd 提供
    _update_directive "KbdInteractiveAuthentication" "yes"
}

_get_directive() {
    local key=$1 default=$2
    local found
    found=$(grep -E "^${key}\\b" "$SSH_CONFIG" | tail -n1 | awk '{print $2}')
    echo "${found:-$default}"
}

_format_on_off() {
    local flag=$1
    case $flag in
        yes) echo "已开启" ;;
        no) echo "已关闭" ;;
        *) echo "$flag" ;;
    esac
}

_format_root_login() {
    case $1 in
        yes) echo "root 登录: 允许" ;;
        prohibit-password) echo "root 登录: 仅密钥" ;;
        no) echo "root 登录: 禁止" ;;
        *) echo "root 登录: 未设置" ;;
    esac
}

_format_auth_methods() {
    local val=$1
    case $val in
        "keyboard-interactive") echo "认证方式: 仅键盘交互 (适用于 YubiKey)" ;;
        默认) echo "认证方式: 默认" ;;
        *) echo "认证方式: $val" ;;
    esac
}

_read_choice() {
    local prompt="$1" key char
    echo -n "$prompt (Esc/0 返回): "
    # 先读入首个按键以处理 Esc/0 快速返回
    IFS= read -rsn1 key
    # 如果是 Esc 或 0，直接返回上级
    if [[ "$key" == $'\e' || "$key" == "0" ]]; then
        echo
        return 1
    fi
    # 继续吞掉本行剩余输入直到换行或超时，便于处理多位数字
    while read -rsn1 -t 0.05 char; do
        [[ "$char" == $'\n' ]] && break
        key+="$char"
    done
    echo
    [[ -n "$key" ]] && echo "$key"
}

_status_colors() {
    GREEN="\033[1;32m"; RED="\033[1;31m"; BLUE="\033[1;34m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"
}

_status_root_login() {
    local raw=$(_get_directive PermitRootLogin 未设置)
    case $raw in
        yes) echo "允许" ;;
        prohibit-password) echo "仅密钥" ;;
        no) echo "禁止" ;;
        *) echo "未设置" ;;
    esac
}

_status_password_login() { _format_on_off "$(_get_directive PasswordAuthentication 未设置)"; }
_status_pubkey_login() { _format_on_off "$(_get_directive PubkeyAuthentication 未设置)"; }

_status_auth_methods() {
    local authm=$(_get_directive AuthenticationMethods 默认)
    if [ "$authm" = "默认" ]; then
        echo "默认"
    elif [ "$authm" = "keyboard-interactive" ]; then
        echo "键盘交互"
    else
        echo "$authm"
    fi
}

_status_yubikey_mode() {
    if ! grep -q "pam_yubico.so" "$PAM_SSHD" 2>/dev/null; then
        echo "未启用"
        return
    fi
    if grep -q "^@include common-auth" "$PAM_SSHD"; then
        echo "YubiKey + 密码"
    else
        echo "仅 YubiKey"
    fi
}

_authorized_keys_label() {
    if [ -f "$AUTHORIZED_KEYS" ]; then
        local count
        count=$(wc -l < "$AUTHORIZED_KEYS")
        echo "已存在 (${count} 条)"
    else
        echo "未创建"
    fi
}

_render_menu() {
    _status_colors
    local root_status password_status pubkey_status authm_status yubi_mode auth_file_status yubi_toggle sys_info
    root_status=$(_status_root_login)
    password_status=$(_status_password_login)
    pubkey_status=$(_status_pubkey_login)
    authm_status=$(_status_auth_methods)
    yubi_mode=$(_status_yubikey_mode)
    auth_file_status=$(_authorized_keys_label)
    yubi_toggle=$([ "$yubi_mode" = "未启用" ] && echo "已禁用" || echo "进行中")
    sys_info="系统: $(lsb_release -ds 2>/dev/null || echo Linux)  服务: $SSH_SERVICE"

    clear
    local border="┌──────────────────────── SSH 登录管理 ────────────────────────┐"
    echo -e "${BLUE}${border}${RESET}"
    printf "${BLUE}│${RESET} %-60s ${BLUE}│${RESET}\n" "$sys_info"
    echo -e "${BLUE}├────────────────────────────────────────────────────────────┤${RESET}"
    printf "${BLUE}│${RESET} 1) %-18s ${CYAN}%-32s${RESET} ${BLUE}│${RESET}\n" "root 登录" "$root_status"
    printf "${BLUE}│${RESET} 2) %-18s ${CYAN}%-32s${RESET} ${BLUE}│${RESET}\n" "密码登录" "$password_status"
    printf "${BLUE}│${RESET} 3) %-18s ${CYAN}%-32s${RESET} ${BLUE}│${RESET}\n" "公钥登录" "$pubkey_status"
    printf "${BLUE}│${RESET} 4) %-18s ${CYAN}%-32s${RESET} ${BLUE}│${RESET}\n" "authorized_keys" "$auth_file_status"
    printf "${BLUE}│${RESET} 5) %-18s ${CYAN}%-32s${RESET} ${BLUE}│${RESET}\n" "禁用 YubiKey 登录" "$yubi_toggle"
    printf "${BLUE}│${RESET} 6) %-18s ${CYAN}%-32s${RESET} ${BLUE}│${RESET}\n" "配置 YubiKey 模式" "$yubi_mode"
    printf "${BLUE}│${RESET} 7) %-18s ${CYAN}%-32s${RESET} ${BLUE}│${RESET}\n" "套用预设配置" "$authm_status"
    echo -e "${BLUE}├────────────────────────────────────────────────────────────┤${RESET}"
    echo -e "${BLUE}│${RESET} 0) 退出                                               ${BLUE}│${RESET}"
    echo -e "${BLUE}└────────────────────────────────────────────────────────────┘${RESET}"
    echo -n "请选择操作: "
}

_set_root_login() {
    echo "1) 允许 root 登录"
    echo "2) 仅允许 root 密钥"
    echo "3) 禁止 root 登录"
    local a
    a=$(_read_choice "请选择") || return

    _backup_file "$SSH_CONFIG"
    case $a in
        1) _update_directive "PermitRootLogin" "yes" ;;
        2) _update_directive "PermitRootLogin" "prohibit-password" ;;
        3) _update_directive "PermitRootLogin" "no" ;;
        *) echo "无效选择" ; return ;;
    esac
    _restart_ssh
}

_set_password_login() {
    echo "1) 启用密码登录"
    echo "2) 禁用密码登录"
    local a
    a=$(_read_choice "请选择") || return

    _backup_file "$SSH_CONFIG"
    if [ "$a" = "1" ]; then
        _update_directive "PasswordAuthentication" "yes"
    else
        _update_directive "PasswordAuthentication" "no"
    fi
    _restart_ssh
}

_set_pubkey_login() {
    echo "1) 启用公钥登录"
    echo "2) 禁用公钥登录"
    local a
    a=$(_read_choice "请选择") || return

    _backup_file "$SSH_CONFIG"
    if [ "$a" = "1" ]; then
        _update_directive "PubkeyAuthentication" "yes"
    else
        _update_directive "PubkeyAuthentication" "no"
    fi
    _restart_ssh
}

_manage_keys() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    echo "1) 查看密钥"
    echo "2) 粘贴公钥"
    echo "3) 从文件导入公钥 (例如 ~/.ssh/id_rsa.pub)"
    echo "4) 删除指定行的公钥"
    local a
    a=$(_read_choice "请选择") || return

    case $a in
        1)
            if [ -f "$AUTHORIZED_KEYS" ]; then
                nl -ba "$AUTHORIZED_KEYS"
            else
                echo "尚未创建 authorized_keys"
            fi
            ;;
        2)
            read -rp "请粘贴公钥: " key
            echo "$key" >> "$AUTHORIZED_KEYS"
            chmod 600 "$AUTHORIZED_KEYS"
            echo "[✓] 公钥已添加"
            ;;
        3)
            read -rp "请输入公钥文件路径(默认: $HOME/.ssh/id_rsa.pub): " path
            path=${path:-$HOME/.ssh/id_rsa.pub}
            if [ -f "$path" ]; then
                cat "$path" >> "$AUTHORIZED_KEYS"
                chmod 600 "$AUTHORIZED_KEYS"
                echo "[✓] 已导入 $path"
            else
                echo "未找到文件: $path"
            fi
            ;;
        4)
            if [ ! -f "$AUTHORIZED_KEYS" ]; then
                echo "尚未创建 authorized_keys"; return
            fi
            nl -ba "$AUTHORIZED_KEYS"
            read -rp "输入要删除的行号: " line
            sed -i "${line}d" "$AUTHORIZED_KEYS"
            echo "[✓] 已删除第 $line 行"
            ;;
        *) echo "无效选择" ;;
    esac
}

_ensure_yubico_package() {
    if ! dpkg -s libpam-yubico >/dev/null 2>&1; then
        echo "[*] 正在安装 libpam-yubico..."
        apt-get update -y && apt-get install -y libpam-yubico
    fi
}

_write_yubikey_authfile() {
    _backup_file "$AUTHORIZED_YUBIKEYS"
    printf "%s\n" "$HARDENED_YUBIKEYS" > "$AUTHORIZED_YUBIKEYS"
    chmod 600 "$AUTHORIZED_YUBIKEYS"
    chown root:root "$AUTHORIZED_YUBIKEYS" 2>/dev/null
}

_write_pam_block() {
    local mode=$1
    cat > "$PAM_SSHD" <<EOF
# PAM 配置由 sshman 管理
auth    required                        pam_yubico.so id=${YUBI_CLIENT_ID} key=${YUBI_SECRET_KEY} authfile=${AUTHORIZED_YUBIKEYS} mode=clientless
EOF

    if [ "$mode" = "pass" ]; then
        cat >> "$PAM_SSHD" <<'EOF'
@include common-auth
EOF
    fi

    cat >> "$PAM_SSHD" <<'EOF'
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
EOF
}

_disable_yubikey() {
    local skip_restart=$1
    _backup_file "$PAM_SSHD"
    cat > "$PAM_SSHD" <<'EOF'
# PAM 配置由 sshman 重置为默认
@include common-auth
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
EOF
    echo "[✓] 已禁用 YubiKey 登录并恢复默认 PAM"
    _remove_directive "AuthenticationMethods"
    [ "$skip_restart" = "skip" ] || _restart_ssh
}

_choose_yubikey_mode() {
    echo "1) 仅 YubiKey OTP (关闭密码)"
    echo "2) YubiKey + 密码 (双因子)"
    echo "0) 取消"
    local m
    m=$(_read_choice "请选择") || return

    case $m in
        1) _enable_yubikey_mode otp ;;
        2) _enable_yubikey_mode pass ;;
        0) return ;;
        *) echo "无效选择" ;;
    esac
}

_enable_yubikey_mode() {
    local mode=$1
    _ensure_yubico_package
    _write_yubikey_authfile
    _backup_file "$PAM_SSHD"
    _write_pam_block "$mode"

    _update_directive "UsePAM" "yes"
    _update_directive "ChallengeResponseAuthentication" "yes"
    _ensure_kbdinteractive
    _update_directive "AuthenticationMethods" "keyboard-interactive"
    if [ "$mode" = "otp" ]; then
        _update_directive "PasswordAuthentication" "no"
        _update_directive "PubkeyAuthentication" "no"
        echo "[✓] 已启用仅 YubiKey OTP 登录"
    else
        _update_directive "PasswordAuthentication" "yes"
        _update_directive "PubkeyAuthentication" "yes"
        echo "[✓] 已启用 YubiKey + 密码双因子"
    fi
    _restart_ssh
}

_apply_preset() {
    echo "1) 安全生产：禁止 root 登录，禁止密码，仅公钥"
    echo "2) 日常开发：允许 root 密钥，允许密码"
    echo "3) 玩具环境：root + 密码全部开启"
    echo "4) 仅 YubiKey OTP（禁密码/公钥）"
    echo "5) YubiKey + 密码（双因子，保留公钥）"
    local p
    p=$(_read_choice "请选择预设") || return

    case $p in
        1)
            _backup_file "$SSH_CONFIG"
            _backup_file "$PAM_SSHD"
            _update_directive "PermitRootLogin" "no"
            _update_directive "PasswordAuthentication" "no"
            _update_directive "PubkeyAuthentication" "yes"
            _disable_yubikey skip
            ;;
        2)
            _backup_file "$SSH_CONFIG"
            _backup_file "$PAM_SSHD"
            _update_directive "PermitRootLogin" "prohibit-password"
            _update_directive "PasswordAuthentication" "yes"
            _update_directive "PubkeyAuthentication" "yes"
            _disable_yubikey skip
            ;;
        3)
            _backup_file "$SSH_CONFIG"
            _backup_file "$PAM_SSHD"
            _update_directive "PermitRootLogin" "yes"
            _update_directive "PasswordAuthentication" "yes"
            _update_directive "PubkeyAuthentication" "yes"
            ;;
        4)
            _enable_yubikey_mode otp
            return
            ;;
        5)
            _enable_yubikey_mode pass
            return
            ;;
        *) echo "无效预设" ; return ;;
    esac
    _restart_ssh
}

while true; do
    _render_menu
    read -rsn1 c
    echo
    case $c in
        1) _set_root_login ;;
        2) _set_password_login ;;
        3) _set_pubkey_login ;;
        4) _manage_keys ;;
        5) _disable_yubikey ;;
        6) _choose_yubikey_mode ;;
        7) _apply_preset ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
done
