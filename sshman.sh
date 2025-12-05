#!/bin/bash
# sshman - SSH 登录管理器 (UTF-8)
# 请在 UTF-8 终端运行；提供交互式菜单管理 sshd 配置。

# 仅启用 pipefail，避免因 unset 变量或单个命令失败直接退出循环
set -o pipefail

SSH_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
BACKUP_DIR="/etc/ssh/sshman-backups"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
AUTHORIZED_YUBIKEYS="/etc/ssh/authorized_yubikeys"
HARDENED_YUBIKEYS="root:cccccbenueru:cccccbejiijg"
YUBI_CLIENT_ID="85975"
YUBI_SECRET_KEY="//EomrFfWNk8fWV/6h7IW8pgs9Y="
YUBI_LAST_MODE="pass" # 记住上次选择的模式，默认 2FA

mkdir -p "$BACKUP_DIR"
PAUSE_FLAG=1

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
    local name
    name=$(basename "$file")
    [[ -f "$file" ]] || return
    cp "$file" "$BACKUP_DIR/${name}.bak.$(date +%F-%H%M%S)"
}

_restart_ssh() {
    echo "[*] 正在重启 SSH 服务..."
    if systemctl restart "$SSH_SERVICE"; then
        echo "[OK] SSH 重启成功"
    else
        echo "[!] SSH 重启失败，请手动检查。"
    fi
}

_check_utf8_locale() {
    local charmap lang_val lc_ctype
    charmap=$(locale charmap 2>/dev/null || echo "")
    lang_val="${LANG:-}"
    lc_ctype="${LC_CTYPE:-}"
    if [[ "$charmap" != "UTF-8" && "$lang_val" != *"UTF-8"* && "$lc_ctype" != *"UTF-8"* ]]; then
        echo "[!] 检测到终端编码为 ${charmap:-未知}，菜单需要 UTF-8 才能正常显示。"
        echo "    建议先执行: export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8"
        read -rp "按 Enter 继续（可能会乱码）或 Ctrl+C 退出..." _
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
    _update_directive "KbdInteractiveAuthentication" "yes"
}

_get_directive() {
    local key=$1 default=$2
    local found
    found=$(grep -E "^${key}\\b" "$SSH_CONFIG" | tail -n1 | awk '{print $2}')
    echo "${found:-$default}"
}

_format_on_off() {
    case $1 in
        yes) echo "已开启" ;;
        no) echo "已关闭" ;;
        *) echo "$1" ;;
    esac
}

_format_root_login() {
    case $1 in
        yes) echo "root 登录：允许" ;;
        prohibit-password) echo "root 登录：仅密钥" ;;
        no) echo "root 登录：禁止" ;;
        *) echo "root 登录：未设置" ;;
    esac
}

_format_auth_methods() {
    case $1 in
        "keyboard-interactive") echo "认证方式：键盘交互（YubiKey）" ;;
        default) echo "认证方式：默认" ;;
        *) echo "认证方式：$1" ;;
    esac
}

_read_choice() {
    local prompt="$1" back_hint="$2" first rest choice

    [[ -n "$back_hint" ]] && prompt="${prompt} (${back_hint})"
    printf "%s: " "$prompt" >&2

    # 读取首个字符；用 -s 禁止终端回显，手动回显一次
    if ! IFS= read -rs -n1 first 2>/dev/null; then
        printf "\n" >&2
        echo ""
        return 0
    fi

    case "$first" in
        $'\e'|$'\n'|$'\r'|$'\177'|$'\b')
            printf "\n" >&2
            echo ""
            return 0
            ;;
    esac

    printf "%s" "$first" >&2

    # 读取本行剩余部分，允许正常编辑/退格
    if IFS= read -r rest; then
        choice="$first$rest"
    else
        choice="$first"
    fi

    choice=${choice//$'\r'/}
    choice=${choice//$'\n'/}
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"

    if [[ -n "$back_hint" && "$choice" == "0" ]]; then
        echo ""
        return 0
    fi
    echo "$choice"
}

_status_colors() {
    GREEN="\033[1;32m"; RED="\033[1;31m"; BLUE="\033[1;34m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"
}

_blue_text() {
    _status_colors
    printf "%b%s%b" "$BLUE" "$1" "$RESET"
}

_section_header() {
    _status_colors
    local title="$1" info="$2" bar
    bar=$(printf '%*s' 60 "" | tr ' ' '-')
    echo -e "${BLUE}${bar}${RESET}"
    printf " %s" "$title"
    [[ -n "$info" ]] && printf " - %b" "$(_blue_text "$info")"
    echo
    echo -e "${BLUE}${bar}${RESET}"
}

_status_root_login() {
    _format_root_login "$(_get_directive PermitRootLogin 未设置)"
}

_status_password_login() { _format_on_off "$(_get_directive PasswordAuthentication 未设置)"; }
_status_pubkey_login() { _format_on_off "$(_get_directive PubkeyAuthentication 未设置)"; }

_status_auth_methods() {
    local authm=$(_get_directive AuthenticationMethods 默认)
    if [[ "$authm" == "默认" ]]; then
        echo "默认"
    elif [[ "$authm" == "keyboard-interactive" ]]; then
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
    if [[ -f "$AUTHORIZED_KEYS" ]]; then
        local count
        count=$(wc -l < "$AUTHORIZED_KEYS")
        echo "已存在（${count} 行）"
    else
        echo "尚未创建"
    fi
}

_render_menu() {
    _status_colors
    local root_status password_status pubkey_status authm_status yubi_mode auth_file_status yubi_switch_status yubi_display sys_info
    root_status="$(_status_root_login)"
    password_status="$(_status_password_login)"
    pubkey_status="$(_status_pubkey_login)"
    auth_file_status="$(_authorized_keys_label)"
    authm_status="$(_status_auth_methods)"
    yubi_mode=$(_status_yubikey_mode)
    if [[ "$yubi_mode" == "未启用" ]]; then
        yubi_switch_status="当前：已禁用"
    else
        yubi_switch_status="当前：已启用"
    fi
    yubi_display="$yubi_mode / $yubi_switch_status"
    sys_info="系统: $(lsb_release -ds 2>/dev/null || echo Linux) | 服务: $SSH_SERVICE"

    local border=$(printf '%*s' 68 "" | tr ' ' '=')
    local divider=$(printf '%*s' 68 "" | tr ' ' '-')
    menu_line() {
        local padded_status
        padded_status=$(printf "%-26s" "$3")
        printf " %-4s %-22s %b\n" "$1" "$2" "$(_blue_text "$padded_status")"
    }

    clear
    echo -e "${BLUE}${border}${RESET}"
    printf " sshman - SSH 登录管理器 (UTF-8)\n"
    printf " %b\n" "$(_blue_text "$sys_info")"
    echo -e "${BLUE}${divider}${RESET}"
    menu_line "1)" "密码登录 (切换)" "$password_status"
    menu_line "2)" "公钥登录 (切换)" "$pubkey_status"
    menu_line "3)" "root 登录 (切换)" "$root_status"
    menu_line "4)" "YubiKey 模式" "$yubi_display"
    menu_line "5)" "密钥管理" "$auth_file_status"
    menu_line "6)" "推荐预设" "$authm_status"
    echo -e "${BLUE}${divider}${RESET}"
    echo " 0) 退出（Esc/0 返回）"
    echo -e "${BLUE}${border}${RESET}"
}

_set_root_login() {
    local current next
    current=$(_get_directive PermitRootLogin "yes")
    case $current in
        yes) next="prohibit-password" ;;
        prohibit-password) next="no" ;;
        *) next="yes" ;;
    esac
    _backup_file "$SSH_CONFIG"
    _update_directive "PermitRootLogin" "$next"
    echo "[OK] root 登录已切换为: $(_format_root_login "$next")"
    _restart_ssh
}

_set_password_login() {
    local current next
    current=$(_get_directive PasswordAuthentication "yes")
    if [[ "$current" == "yes" ]]; then
        next="no"
    else
        next="yes"
    fi
    _backup_file "$SSH_CONFIG"
    _update_directive "PasswordAuthentication" "$next"
    echo "[OK] 密码登录已切换为: $(_format_on_off "$next")"
    _restart_ssh
}

_set_pubkey_login() {
    local current next
    current=$(_get_directive PubkeyAuthentication "yes")
    if [[ "$current" == "yes" ]]; then
        next="no"
    else
        next="yes"
    fi
    _backup_file "$SSH_CONFIG"
    _update_directive "PubkeyAuthentication" "$next"
    echo "[OK] 公钥登录已切换为: $(_format_on_off "$next")"
    _restart_ssh
}

_manage_keys() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    _section_header "密钥管理 (authorized_keys)" "状态：$(_authorized_keys_label)"
    echo "当前密钥文件：$(_authorized_keys_label)"
    echo "1) 查看密钥"
    echo "2) 手动追加公钥"
    echo "3) 从文件导入（如 ~/.ssh/id_rsa.pub）"
    echo "4) 按行号删除公钥"
    local a
    a=$(_read_choice "请选择" "Esc/0 返回")
    if [[ -z "$a" ]]; then
        PAUSE_FLAG=0
        return
    fi

    case $a in
        1)
            if [[ -f "$AUTHORIZED_KEYS" ]]; then
                nl -ba "$AUTHORIZED_KEYS"
            else
                echo "authorized_keys 尚未创建"
            fi
            ;;
        2)
            read -rp "输入公钥: " key
            echo "$key" >> "$AUTHORIZED_KEYS"
            chmod 600 "$AUTHORIZED_KEYS"
            echo "[OK] 公钥已添加"
            ;;
        3)
            read -rp "公钥文件路径（默认: $HOME/.ssh/id_rsa.pub）: " path
            path=${path:-$HOME/.ssh/id_rsa.pub}
            if [[ -f "$path" ]]; then
                cat "$path" >> "$AUTHORIZED_KEYS"
                chmod 600 "$AUTHORIZED_KEYS"
                echo "[OK] 已导入 $path"
            else
                echo "未找到文件: $path"
            fi
            ;;
        4)
            if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
                echo "尚未创建 authorized_keys"; return
            fi
            local -a numbered_lines=()
            mapfile -t numbered_lines < <(nl -ba "$AUTHORIZED_KEYS")
            if [[ ${#numbered_lines[@]} -eq 0 ]]; then
                echo "authorized_keys 为空，无可删除条目"; return
            fi
            printf "%s\n" "${numbered_lines[@]}"
            local line max_line
            max_line=$(printf '%s\n' "${numbered_lines[@]}" | tail -n1 | awk '{print $1}')
            read -rp "请输入要删除的行号: " line
            if [[ ! "$line" =~ ^[0-9]+$ ]]; then
                echo "行号必须为数字"; return
            fi
            if [[ "$line" -lt 1 || "$line" -gt "$max_line" ]]; then
                echo "行号超出范围 (1-${max_line})"; return
            fi
            sed -i "${line}d" "$AUTHORIZED_KEYS"
            echo "[OK] 已删除第 $line 行"
            ;;
        *) echo "无效选项" ;;
    esac
}

_ensure_yubico_package() {
    if ! dpkg -s libpam-yubico >/dev/null 2>&1; then
        echo "[*] 正在安装 libpam-yubico..."
        apt-get update -y && apt-get upgrade -y && apt-get install -y libpam-yubico
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
    cat > "$PAM_SSHD" <<PAMCFG
# PAM config managed by sshman
auth    required                        pam_yubico.so id=${YUBI_CLIENT_ID} key=${YUBI_SECRET_KEY} authfile=${AUTHORIZED_YUBIKEYS} mode=clientless
PAMCFG

    if [[ "$mode" == "pass" ]]; then
        cat >> "$PAM_SSHD" <<PAMCFG
@include common-auth
PAMCFG
    fi

    cat >> "$PAM_SSHD" <<'PAMCFG'
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
PAMCFG
}

_disable_yubikey() {
    local skip_restart=${1:-}
    _backup_file "$PAM_SSHD"
    cat > "$PAM_SSHD" <<'PAMCFG'
# PAM config reset to defaults by sshman
@include common-auth
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
PAMCFG
    echo "[OK] 已禁用 YubiKey 登录并恢复默认 PAM"
    _remove_directive "AuthenticationMethods"
    [[ "$skip_restart" == "skip" ]] || _restart_ssh
}

_choose_yubikey_mode() {
    _section_header "YubiKey 模式" "当前：$(_status_yubikey_mode)"
    echo "1) 禁用 YubiKey"
    echo "2) 仅 YubiKey OTP（禁用密码）"
    echo "3) YubiKey + 密码 (2FA)"
    echo "0) 取消"
    local m
    m=$(_read_choice "请选择" "Esc/0 返回")
    if [[ -z "$m" ]]; then
        PAUSE_FLAG=0
        return
    fi

    case $m in
        1) _disable_yubikey ;;
        2) _enable_yubikey_mode otp ;;
        3) _enable_yubikey_mode pass ;;
        0) PAUSE_FLAG=0; return ;;
        *) echo "无效选项" ;;
    esac
}

_toggle_yubikey() {
    local state mode
    state=$(_status_yubikey_mode)
    if [[ "$state" == "未启用" ]]; then
        mode=${YUBI_LAST_MODE:-pass}
        echo "[*] 正在启用 YubiKey（模式：$mode）..."
        _enable_yubikey_mode "$mode"
    else
        echo "[*] 正在禁用 YubiKey..."
        _disable_yubikey
    fi
}

_enable_yubikey_mode() {
    local mode=$1
    echo "[*] 正在写入 YubiKey 配置（模式：$mode）..."
    _ensure_yubico_package
    _write_yubikey_authfile
    _backup_file "$PAM_SSHD"
    _write_pam_block "$mode"

    _update_directive "UsePAM" "yes"
    _update_directive "ChallengeResponseAuthentication" "yes"
    _ensure_kbdinteractive
    _update_directive "AuthenticationMethods" "keyboard-interactive"
    YUBI_LAST_MODE="$mode"
    if [[ "$mode" == "otp" ]]; then
        _update_directive "PasswordAuthentication" "no"
        _update_directive "PubkeyAuthentication" "no"
        echo "[OK] 已启用仅 YubiKey OTP"
    else
        _update_directive "PasswordAuthentication" "yes"
        _update_directive "PubkeyAuthentication" "yes"
        echo "[OK] 已启用 YubiKey + 密码 (2FA)"
    fi
    _restart_ssh
    echo "[*] YubiKey 配置完成。"
}

_apply_preset() {
    local summary="root: $(_status_root_login) | 密码: $(_status_password_login) | 公钥: $(_status_pubkey_login) | YubiKey: $(_status_yubikey_mode)"
    _section_header "推荐预设" "$summary"
    echo "1) 加固生产：禁止 root 登录，禁用密码，启用公钥"
    echo "2) 日常开发：root 仅密钥，允许密码登录"
    echo "3) 临时开放：开启 root + 密码"
    echo "4) 仅 YubiKey OTP（禁用密码/公钥）"
    echo "5) YubiKey + 密码（保留公钥）"
    local p
    p=$(_read_choice "选择预设" "Esc/0 返回")
    if [[ -z "$p" ]]; then
        PAUSE_FLAG=0
        return
    fi

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

_check_utf8_locale
while true; do
    PAUSE_FLAG=1
    _render_menu
    c=$(_read_choice "请选择操作" "")
    if [[ -z "$c" ]]; then
        PAUSE_FLAG=0
        continue
    fi
    case $c in
        1) _set_password_login ;;
        2) _set_pubkey_login ;;
        3) _set_root_login ;;
        4) _choose_yubikey_mode ;;
        5) _manage_keys ;;
        6) _apply_preset ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
