#!/bin/bash
# sshman - SSH 鐧诲綍绠＄悊鑴氭湰 (涓枃浜や簰)
# 闇€瑕佸湪 UTF-8 缁堢杩愯锛屽惁鍒欒彍鍗曚細涔辩爜銆?
SSH_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
BACKUP_DIR="/etc/ssh/sshman-backups"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
AUTHORIZED_YUBIKEYS="/etc/ssh/authorized_yubikeys"
HARDENED_YUBIKEYS="root:cccccbenueru:cccccbejiijg"
YUBI_CLIENT_ID="85975"
YUBI_SECRET_KEY="//EomrFfWNk8fWV/6h7IW8pgs9Y="

mkdir -p "$BACKUP_DIR"

# 鑷姩妫€娴?ssh/sshd 鏈嶅姟鍚?_detect_ssh_service() {
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
    echo "[*] 姝ｅ湪閲嶅惎 SSH 鏈嶅姟..."
    if systemctl restart "$SSH_SERVICE"; then
        echo "[鉁揮 SSH 閲嶅惎鎴愬姛"
    else
        echo "[!] SSH 閲嶅惎澶辫触锛岃鎵嬪姩妫€鏌ワ紒"
    fi
}

_check_utf8_locale() {
    local charmap
    charmap=$(locale charmap 2>/dev/null || echo "")
    if [[ "$charmap" != "UTF-8" && "$LANG" != *"UTF-8"* && "$LC_CTYPE" != *"UTF-8"* ]]; then
        echo "[!] 妫€娴嬪埌褰撳墠缁堢缂栫爜涓?${charmap:-鏈煡}锛岃彍鍗曢渶瑕?UTF-8 鎵嶈兘姝ｅ父鏄剧ず銆?
        echo "    寤鸿鍏堟墽琛? export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8"
        read -rp "缁х画鍙兘鍑虹幇涔辩爜锛屾寜 Enter 缁х画锛屾垨 Ctrl+C 缁堟..." _
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
    # 纭繚閿洏浜や簰寮忚璇佸紑鍚紝鍚﹀垯 YubiKey OTP 涓嶄細琚?sshd 鎻愪緵
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
        yes) echo "宸插紑鍚? ;;
        no) echo "宸插叧闂? ;;
        *) echo "$flag" ;;
    esac
}

_format_root_login() {
    case $1 in
        yes) echo "root 鐧诲綍: 鍏佽" ;;
        prohibit-password) echo "root 鐧诲綍: 浠呭瘑閽? ;;
        no) echo "root 鐧诲綍: 绂佹" ;;
        *) echo "root 鐧诲綍: 鏈缃? ;;
    esac
}

_format_auth_methods() {
    local val=$1
    case $val in
        "keyboard-interactive") echo "璁よ瘉鏂瑰紡: 浠呴敭鐩樹氦浜?(閫傜敤浜?YubiKey)" ;;
        榛樿) echo "璁よ瘉鏂瑰紡: 榛樿" ;;
        *) echo "璁よ瘉鏂瑰紡: $val" ;;
    esac
}

_read_choice() {
    local prompt="$1" back_hint="$2" hint_suffix="" choice

    [ -n "$back_hint" ] && hint_suffix=" (${back_hint})"
    printf "%s%s: " "$prompt" "$hint_suffix"
    if ! IFS= read -r choice; then
        echo
        return 1
    fi
    # strip CR/LF that may come from different terminals
    choice=${choice//$'\r'/}
    choice=${choice//$'\n'/}
    # trim surrounding whitespace
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"
    if [[ -z "$choice" || "$choice" == $'\e' ]]; then
        echo
        return 1
    fi
    if [[ -n "$back_hint" && "$choice" == "0" ]]; then
        echo
        return 1
    fi
    echo
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
    [ -n "$info" ] && printf " - %b" "$(_blue_text "$info")"
    echo
    echo -e "${BLUE}${bar}${RESET}"
}

_status_root_login() {
    local raw=$(_get_directive PermitRootLogin 鏈缃?
    case $raw in
        yes) echo "鍏佽" ;;
        prohibit-password) echo "浠呭瘑閽? ;;
        no) echo "绂佹" ;;
        *) echo "鏈缃? ;;
    esac
}

_status_password_login() { _format_on_off "$(_get_directive PasswordAuthentication 鏈缃?"; }
_status_pubkey_login() { _format_on_off "$(_get_directive PubkeyAuthentication 鏈缃?"; }

_status_auth_methods() {
    local authm=$(_get_directive AuthenticationMethods 榛樿)
    if [ "$authm" = "榛樿" ]; then
        echo "榛樿"
    elif [ "$authm" = "keyboard-interactive" ]; then
        echo "閿洏浜や簰"
    else
        echo "$authm"
    fi
}

_status_yubikey_mode() {
    if ! grep -q "pam_yubico.so" "$PAM_SSHD" 2>/dev/null; then
        echo "鏈惎鐢?
        return
    fi
    if grep -q "^@include common-auth" "$PAM_SSHD"; then
        echo "YubiKey + 瀵嗙爜"
    else
        echo "浠?YubiKey"
    fi
}

_authorized_keys_label() {
    if [ -f "$AUTHORIZED_KEYS" ]; then
        local count
        count=$(wc -l < "$AUTHORIZED_KEYS")
        echo "宸插瓨鍦?(${count} 鏉?"
    else
        echo "鏈垱寤?
    fi
}

_render_menu() {
    _status_colors
    local root_status password_status pubkey_status authm_status yubi_mode auth_file_status yubi_switch_status yubi_display sys_info
    root_status=$(_blue_text "$(_status_root_login)")
    password_status=$(_blue_text "$(_status_password_login)")
    pubkey_status=$(_status_pubkey_login)
    auth_file_status=$(_authorized_keys_label)
    pubkey_status=$(_blue_text "$pubkey_status / $auth_file_status")
    authm_status=$(_blue_text "$(_status_auth_methods)")
    yubi_mode=$(_status_yubikey_mode)
    if [ "$yubi_mode" = "鏈惎鐢? ]; then
        yubi_switch_status="褰撳墠: 宸茬鐢?
    else
        yubi_switch_status="褰撳墠: 宸插惎鐢?
    fi
    yubi_display=$(_blue_text "$yubi_mode / $yubi_switch_status")
    sys_info="绯荤粺: $(lsb_release -ds 2>/dev/null || echo Linux) | 鏈嶅姟: $SSH_SERVICE"

    local border=$(printf '%*s' 68 "" | tr ' ' '=')
    local divider=$(printf '%*s' 68 "" | tr ' ' '-')
    menu_line() {
        printf " %-4s %-20s %b\n" "$1" "$2" "$3"
    }

    clear
    echo -e "${BLUE}${border}${RESET}"
    printf " sshman - SSH 鐧诲綍绠＄悊 (UTF-8)\n"
    printf " %b\n" "$(_blue_text "$sys_info")"
    echo -e "${BLUE}${divider}${RESET}"
    menu_line "1)" "root 鐧诲綍" "$root_status"
    menu_line "2)" "瀵嗙爜鐧诲綍" "$password_status"
    menu_line "3)" "鍏挜鐧诲綍涓庡瘑閽? "$pubkey_status"
    menu_line "4)" "YubiKey" "$yubi_display"
    menu_line "5)" "濂楃敤棰勮" "$authm_status"
    echo -e "${BLUE}${divider}${RESET}"
    echo " 0) 閫€鍑?(Esc/0 杩斿洖)"
    echo -e "${BLUE}${border}${RESET}"
}

_set_root_login() {
    _section_header "root 鐧诲綍" "褰撳墠: $(_status_root_login)"
    echo "1) 鍏佽 root 鐧诲綍"
    echo "2) 浠呭厑璁?root 瀵嗛挜"
    echo "3) 绂佹 root 鐧诲綍"
    local a
    a=$(_read_choice "璇烽€夋嫨" "Esc/0 杩斿洖") || return

    _backup_file "$SSH_CONFIG"
    case $a in
        1) _update_directive "PermitRootLogin" "yes" ;;
        2) _update_directive "PermitRootLogin" "prohibit-password" ;;
        3) _update_directive "PermitRootLogin" "no" ;;
        *) echo "鏃犳晥閫夋嫨" ; return ;;
    esac
    _restart_ssh
}

_set_password_login() {
    _section_header "瀵嗙爜鐧诲綍" "褰撳墠: $(_status_password_login)"
    echo "1) 鍚敤瀵嗙爜鐧诲綍"
    echo "2) 绂佺敤瀵嗙爜鐧诲綍"
    local a
    a=$(_read_choice "璇烽€夋嫨" "Esc/0 杩斿洖") || return

    _backup_file "$SSH_CONFIG"
    if [ "$a" = "1" ]; then
        _update_directive "PasswordAuthentication" "yes"
    else
        _update_directive "PasswordAuthentication" "no"
    fi
    _restart_ssh
}

_set_pubkey_login() {
    _section_header "鍏挜鐧诲綍" "褰撳墠: $(_status_pubkey_login)"
    echo "1) 鍚敤鍏挜鐧诲綍"
    echo "2) 绂佺敤鍏挜鐧诲綍"
    local a
    a=$(_read_choice "璇烽€夋嫨" "Esc/0 杩斿洖") || return

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

    _section_header "authorized_keys" "鐘舵€? $(_authorized_keys_label)"
    echo "1) 鏌ョ湅瀵嗛挜"
    echo "2) 绮樿创鍏挜"
    echo "3) 浠庢枃浠跺鍏ュ叕閽?(渚嬪 ~/.ssh/id_rsa.pub)"
    echo "4) 鍒犻櫎鎸囧畾琛岀殑鍏挜"
    local a
    a=$(_read_choice "璇烽€夋嫨" "Esc/0 杩斿洖") || return

    case $a in
        1)
            if [ -f "$AUTHORIZED_KEYS" ]; then
                nl -ba "$AUTHORIZED_KEYS"
            else
                echo "灏氭湭鍒涘缓 authorized_keys"
            fi
            ;;
        2)
            read -rp "璇风矘璐村叕閽? " key
            echo "$key" >> "$AUTHORIZED_KEYS"
            chmod 600 "$AUTHORIZED_KEYS"
            echo "[鉁揮 鍏挜宸叉坊鍔?
            ;;
        3)
            read -rp "璇疯緭鍏ュ叕閽ユ枃浠惰矾寰?榛樿: $HOME/.ssh/id_rsa.pub): " path
            path=${path:-$HOME/.ssh/id_rsa.pub}
            if [ -f "$path" ]; then
                cat "$path" >> "$AUTHORIZED_KEYS"
                chmod 600 "$AUTHORIZED_KEYS"
                echo "[鉁揮 宸插鍏?$path"
            else
                echo "鏈壘鍒版枃浠? $path"
            fi
            ;;
        4)
            if [ ! -f "$AUTHORIZED_KEYS" ]; then
                echo "灏氭湭鍒涘缓 authorized_keys"; return
            fi
            local -a numbered_lines=()
            mapfile -t numbered_lines < <(nl -ba "$AUTHORIZED_KEYS")
            if [ ${#numbered_lines[@]} -eq 0 ]; then
                echo "authorized_keys 涓虹┖锛屾棤闇€鍒犻櫎"; return
            fi
            printf "%s\n" "${numbered_lines[@]}"
            local line max_line
            max_line=$(printf '%s\n' "${numbered_lines[@]}" | tail -n1 | awk '{print $1}')
            read -rp "杈撳叆瑕佸垹闄ょ殑琛屽彿: " line
            if [[ ! "$line" =~ ^[0-9]+$ ]]; then
                echo "琛屽彿蹇呴』涓烘暟瀛?; return
            fi
            if [ "$line" -lt 1 ] || [ "$line" -gt "$max_line" ]; then
                echo "琛屽彿瓒呭嚭鑼冨洿 (1-${max_line})"; return
            fi
            sed -i "${line}d" "$AUTHORIZED_KEYS"
            echo "[鉁揮 宸插垹闄ょ $line 琛?
            ;;
        *) echo "鏃犳晥閫夋嫨" ;;
    esac
}

_manage_pubkey_suite() {
    while true; do
        _section_header "鍏挜鐧诲綍/瀵嗛挜" "鐧诲綍: $(_status_pubkey_login) | 瀵嗛挜: $(_authorized_keys_label)"
        echo "1) 璁剧疆鍏挜鐧诲綍寮€鍏?
        echo "2) 绠＄悊 authorized_keys"
        echo "0) 杩斿洖"
        local a
        a=$(_read_choice "璇烽€夋嫨" "Esc/0 杩斿洖") || return

        case $a in
            1) _set_pubkey_login ;;
            2) _manage_keys ;;
            0) return ;;
            *) echo "鏃犳晥閫夋嫨" ;;
        esac
        echo
    done
}

_ensure_yubico_package() {
    if ! dpkg -s libpam-yubico >/dev/null 2>&1; then
        echo "[*] 姝ｅ湪瀹夎 libpam-yubico..."
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
# PAM 閰嶇疆鐢?sshman 绠＄悊
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
# PAM 閰嶇疆鐢?sshman 閲嶇疆涓洪粯璁?@include common-auth
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
EOF
    echo "[鉁揮 宸茬鐢?YubiKey 鐧诲綍骞舵仮澶嶉粯璁?PAM"
    _remove_directive "AuthenticationMethods"
    [ "$skip_restart" = "skip" ] || _restart_ssh
}

_choose_yubikey_mode() {
    _section_header "YubiKey 妯″紡" "褰撳墠: $(_status_yubikey_mode)"
    echo "1) 浠?YubiKey OTP (鍏抽棴瀵嗙爜)"
    echo "2) YubiKey + 瀵嗙爜 (鍙屽洜瀛?"
    echo "0) 鍙栨秷"
    local m
    m=$(_read_choice "璇烽€夋嫨" "Esc/0 杩斿洖") || return

    case $m in
        1) _enable_yubikey_mode otp ;;
        2) _enable_yubikey_mode pass ;;
        0) return ;;
        *) echo "鏃犳晥閫夋嫨" ;;
    esac
}

_manage_yubikey() {
    while true; do
        _section_header "YubiKey 绠＄悊" "鐘舵€? $(_status_yubikey_mode)"
        echo "1) 閰嶇疆/鍒囨崲 YubiKey 妯″紡"
        echo "2) 绂佺敤/鎭㈠ YubiKey"
        echo "0) 杩斿洖"
        local a
        a=$(_read_choice "璇烽€夋嫨" "Esc/0 杩斿洖") || return

        case $a in
            1) _choose_yubikey_mode ;;
            2) _disable_yubikey ;;
            0) return ;;
            *) echo "鏃犳晥閫夋嫨" ;;
        esac
        echo
    done
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
        echo "[鉁揮 宸插惎鐢ㄤ粎 YubiKey OTP 鐧诲綍"
    else
        _update_directive "PasswordAuthentication" "yes"
        _update_directive "PubkeyAuthentication" "yes"
        echo "[鉁揮 宸插惎鐢?YubiKey + 瀵嗙爜鍙屽洜瀛?
    fi
    _restart_ssh
}

_apply_preset() {
    local summary="root: $(_status_root_login) | 瀵嗙爜: $(_status_password_login) | 鍏挜: $(_status_pubkey_login) | YubiKey: $(_status_yubikey_mode)"
    _section_header "濂楃敤棰勮" "$summary"
    echo "1) 瀹夊叏鐢熶骇锛氱姝?root 鐧诲綍锛岀姝㈠瘑鐮侊紝浠呭叕閽?
    echo "2) 鏃ュ父寮€鍙戯細鍏佽 root 瀵嗛挜锛屽厑璁稿瘑鐮?
    echo "3) 鐜╁叿鐜锛歳oot + 瀵嗙爜鍏ㄩ儴寮€鍚?
    echo "4) 浠?YubiKey OTP锛堢瀵嗙爜/鍏挜锛?
    echo "5) YubiKey + 瀵嗙爜锛堝弻鍥犲瓙锛屼繚鐣欏叕閽ワ級"
    local p
    p=$(_read_choice "璇烽€夋嫨棰勮" "Esc/0 杩斿洖") || return

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
        *) echo "鏃犳晥棰勮" ; return ;;
    esac
    _restart_ssh
}

_check_utf8_locale
while true; do
    _render_menu
    c=$(_read_choice "璇烽€夋嫨鎿嶄綔" "") || continue
    case $c in
        1) _set_root_login ;;
        2) _set_password_login ;;
        3) _manage_pubkey_suite ;;
        4) _manage_yubikey ;;
        5) _apply_preset ;;
        0) exit 0 ;;
        *) echo "鏃犳晥閫夋嫨" ;;
    esac
    echo
    read -rp "鎸夊洖杞︾户缁?.." _
done
