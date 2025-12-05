#!/bin/bash
# sshman - SSH login manager (UTF-8)
# Run in a UTF-8 terminal; provides an interactive menu to manage sshd settings.

set -euo pipefail

SSH_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
BACKUP_DIR="/etc/ssh/sshman-backups"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
AUTHORIZED_YUBIKEYS="/etc/ssh/authorized_yubikeys"
HARDENED_YUBIKEYS="root:cccccbenueru:cccccbejiijg"
YUBI_CLIENT_ID="85975"
YUBI_SECRET_KEY="//EomrFfWNk8fWV/6h7IW8pgs9Y="

mkdir -p "$BACKUP_DIR"

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
    cp "$file" "$BACKUP_DIR/${name}.bak.$(date +%F-%H%M%S)"
}

_restart_ssh() {
    echo "[*] Restarting SSH service..."
    if systemctl restart "$SSH_SERVICE"; then
        echo "[OK] SSH restarted successfully"
    else
        echo "[!] SSH restart failed; please check manually."
    fi
}

_check_utf8_locale() {
    local charmap lang_val lc_ctype
    charmap=$(locale charmap 2>/dev/null || echo "")
    lang_val="${LANG:-}"
    lc_ctype="${LC_CTYPE:-}"
    if [[ "$charmap" != "UTF-8" && "$lang_val" != *"UTF-8"* && "$lc_ctype" != *"UTF-8"* ]]; then
        echo "[!] Terminal encoding is ${charmap:-unknown}; the menu needs UTF-8 to render correctly."
        echo "    Suggested: export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8"
        read -rp "Press Enter to continue anyway (may see garbled text) or Ctrl+C to abort..." _
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
        yes) echo "Enabled" ;;
        no) echo "Disabled" ;;
        *) echo "$1" ;;
    esac
}

_format_root_login() {
    case $1 in
        yes) echo "Root login: allowed" ;;
        prohibit-password) echo "Root login: key only" ;;
        no) echo "Root login: disallowed" ;;
        *) echo "Root login: unset" ;;
    esac
}

_format_auth_methods() {
    case $1 in
        "keyboard-interactive") echo "Auth method: keyboard-interactive (YubiKey)" ;;
        default) echo "Auth method: default" ;;
        *) echo "Auth method: $1" ;;
    esac
}

_read_choice() {
    local prompt="$1" back_hint="$2" hint_suffix="" choice

    [[ -n "$back_hint" ]] && hint_suffix=" (${back_hint})"
    printf "%s%s: " "$prompt" "$hint_suffix"
    if ! IFS= read -r choice; then
        echo
        return 1
    fi
    choice=${choice//$'\r'/}
    choice=${choice//$'\n'/}
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
    [[ -n "$info" ]] && printf " - %b" "$(_blue_text "$info")"
    echo
    echo -e "${BLUE}${bar}${RESET}"
}

_status_root_login() {
    _format_root_login "$(_get_directive PermitRootLogin unset)"
}

_status_password_login() { _format_on_off "$(_get_directive PasswordAuthentication unset)"; }
_status_pubkey_login() { _format_on_off "$(_get_directive PubkeyAuthentication unset)"; }

_status_auth_methods() {
    local authm=$(_get_directive AuthenticationMethods default)
    if [[ "$authm" == "default" ]]; then
        echo "default"
    elif [[ "$authm" == "keyboard-interactive" ]]; then
        echo "keyboard-interactive"
    else
        echo "$authm"
    fi
}

_status_yubikey_mode() {
    if ! grep -q "pam_yubico.so" "$PAM_SSHD" 2>/dev/null; then
        echo "Disabled"
        return
    fi
    if grep -q "^@include common-auth" "$PAM_SSHD"; then
        echo "YubiKey + password"
    else
        echo "YubiKey only"
    fi
}

_authorized_keys_label() {
    if [[ -f "$AUTHORIZED_KEYS" ]]; then
        local count
        count=$(wc -l < "$AUTHORIZED_KEYS")
        echo "Present (${count} lines)"
    else
        echo "Not created"
    fi
}

_render_menu() {
    _status_colors
    local root_status password_status pubkey_status authm_status yubi_mode auth_file_status yubi_switch_status yubi_display sys_info
    root_status=$(_blue_text "$(_status_root_login)")
    password_status=$(_blue_text "$(_status_password_login)")
    auth_file_status=$(_authorized_keys_label)
    pubkey_status=$(_blue_text "$(_status_pubkey_login) / $auth_file_status")
    authm_status=$(_blue_text "$(_status_auth_methods)")
    yubi_mode=$(_status_yubikey_mode)
    if [[ "$yubi_mode" == "Disabled" ]]; then
        yubi_switch_status="Current: disabled"
    else
        yubi_switch_status="Current: enabled"
    fi
    yubi_display=$(_blue_text "$yubi_mode / $yubi_switch_status")
    sys_info="OS: $(lsb_release -ds 2>/dev/null || echo Linux) | Service: $SSH_SERVICE"

    local border=$(printf '%*s' 68 "" | tr ' ' '=')
    local divider=$(printf '%*s' 68 "" | tr ' ' '-')
    menu_line() {
        printf " %-4s %-20s %b\n" "$1" "$2" "$3"
    }

    clear
    echo -e "${BLUE}${border}${RESET}"
    printf " sshman - SSH login manager (UTF-8)\n"
    printf " %b\n" "$(_blue_text "$sys_info")"
    echo -e "${BLUE}${divider}${RESET}"
    menu_line "1)" "Root login" "$root_status"
    menu_line "2)" "Password login" "$password_status"
    menu_line "3)" "Public key login & keys" "$pubkey_status"
    menu_line "4)" "YubiKey" "$yubi_display"
    menu_line "5)" "Recommended presets" "$authm_status"
    echo -e "${BLUE}${divider}${RESET}"
    echo " 0) Exit (Esc/0 to go back)"
    echo -e "${BLUE}${border}${RESET}"
}

_set_root_login() {
    _section_header "Root login" "Current: $(_status_root_login)"
    echo "1) Allow root login"
    echo "2) Allow root key only"
    echo "3) Disable root login"
    local a
    a=$(_read_choice "Select" "Esc/0 to return") || return

    _backup_file "$SSH_CONFIG"
    case $a in
        1) _update_directive "PermitRootLogin" "yes" ;;
        2) _update_directive "PermitRootLogin" "prohibit-password" ;;
        3) _update_directive "PermitRootLogin" "no" ;;
        *) echo "Invalid choice" ; return ;;
    esac
    _restart_ssh
}

_set_password_login() {
    _section_header "Password login" "Current: $(_status_password_login)"
    echo "1) Enable password login"
    echo "2) Disable password login"
    local a
    a=$(_read_choice "Select" "Esc/0 to return") || return

    _backup_file "$SSH_CONFIG"
    if [[ "$a" == "1" ]]; then
        _update_directive "PasswordAuthentication" "yes"
    else
        _update_directive "PasswordAuthentication" "no"
    fi
    _restart_ssh
}

_set_pubkey_login() {
    _section_header "Public key login" "Current: $(_status_pubkey_login)"
    echo "1) Enable public key login"
    echo "2) Disable public key login"
    local a
    a=$(_read_choice "Select" "Esc/0 to return") || return

    _backup_file "$SSH_CONFIG"
    if [[ "$a" == "1" ]]; then
        _update_directive "PubkeyAuthentication" "yes"
    else
        _update_directive "PubkeyAuthentication" "no"
    fi
    _restart_ssh
}

_manage_keys() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    _section_header "authorized_keys" "Status: $(_authorized_keys_label)"
    echo "1) View keys"
    echo "2) Append a public key manually"
    echo "3) Import from file (e.g. ~/.ssh/id_rsa.pub)"
    echo "4) Delete a public key by line number"
    local a
    a=$(_read_choice "Select" "Esc/0 to return") || return

    case $a in
        1)
            if [[ -f "$AUTHORIZED_KEYS" ]]; then
                nl -ba "$AUTHORIZED_KEYS"
            else
                echo "authorized_keys not created yet"
            fi
            ;;
        2)
            read -rp "Enter public key: " key
            echo "$key" >> "$AUTHORIZED_KEYS"
            chmod 600 "$AUTHORIZED_KEYS"
            echo "[OK] Public key added"
            ;;
        3)
            read -rp "Path to public key file (default: $HOME/.ssh/id_rsa.pub): " path
            path=${path:-$HOME/.ssh/id_rsa.pub}
            if [[ -f "$path" ]]; then
                cat "$path" >> "$AUTHORIZED_KEYS"
                chmod 600 "$AUTHORIZED_KEYS"
                echo "[OK] Imported $path"
            else
                echo "File not found: $path"
            fi
            ;;
        4)
            if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
                echo "authorized_keys not created"; return
            fi
            local -a numbered_lines=()
            mapfile -t numbered_lines < <(nl -ba "$AUTHORIZED_KEYS")
            if [[ ${#numbered_lines[@]} -eq 0 ]]; then
                echo "authorized_keys is empty; nothing to delete"; return
            fi
            printf "%s\n" "${numbered_lines[@]}"
            local line max_line
            max_line=$(printf '%s\n' "${numbered_lines[@]}" | tail -n1 | awk '{print $1}')
            read -rp "Enter line number to delete: " line
            if [[ ! "$line" =~ ^[0-9]+$ ]]; then
                echo "Line number must be numeric"; return
            fi
            if [[ "$line" -lt 1 || "$line" -gt "$max_line" ]]; then
                echo "Line number out of range (1-${max_line})"; return
            fi
            sed -i "${line}d" "$AUTHORIZED_KEYS"
            echo "[OK] Deleted line $line"
            ;;
        *) echo "Invalid choice" ;;
    esac
}

_manage_pubkey_suite() {
    while true; do
        _section_header "Public key login / keys" "Login: $(_status_pubkey_login) | Keys: $(_authorized_keys_label)"
        echo "1) Toggle public key login"
        echo "2) Manage authorized_keys"
        echo "0) Back"
        local a
        a=$(_read_choice "Select" "Esc/0 to return") || return

        case $a in
            1) _set_pubkey_login ;;
            2) _manage_keys ;;
            0) return ;;
            *) echo "Invalid choice" ;;
        esac
        echo
    done
}

_ensure_yubico_package() {
    if ! dpkg -s libpam-yubico >/dev/null 2>&1; then
        echo "[*] Installing libpam-yubico..."
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
    cat > "$PAM_SSHD" <<'PAMCFG'
# PAM config managed by sshman
auth    required                        pam_yubico.so id=${YUBI_CLIENT_ID} key=${YUBI_SECRET_KEY} authfile=${AUTHORIZED_YUBIKEYS} mode=clientless
PAMCFG

    if [[ "$mode" == "pass" ]]; then
        cat >> "$PAM_SSHD" <<'PAMCFG'
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
    echo "[OK] Disabled YubiKey login and restored default PAM"
    _remove_directive "AuthenticationMethods"
    [[ "$skip_restart" == "skip" ]] || _restart_ssh
}

_choose_yubikey_mode() {
    _section_header "YubiKey mode" "Current: $(_status_yubikey_mode)"
    echo "1) YubiKey OTP only (disable passwords)"
    echo "2) YubiKey + password (2FA)"
    echo "0) Cancel"
    local m
    m=$(_read_choice "Select" "Esc/0 to return") || return

    case $m in
        1) _enable_yubikey_mode otp ;;
        2) _enable_yubikey_mode pass ;;
        0) return ;;
        *) echo "Invalid choice" ;;
    esac
}

_manage_yubikey() {
    while true; do
        _section_header "YubiKey management" "Status: $(_status_yubikey_mode)"
        echo "1) Configure / switch YubiKey mode"
        echo "2) Disable / restore YubiKey"
        echo "0) Back"
        local a
        a=$(_read_choice "Select" "Esc/0 to return") || return

        case $a in
            1) _choose_yubikey_mode ;;
            2) _disable_yubikey ;;
            0) return ;;
            *) echo "Invalid choice" ;;
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
    if [[ "$mode" == "otp" ]]; then
        _update_directive "PasswordAuthentication" "no"
        _update_directive "PubkeyAuthentication" "no"
        echo "[OK] Enabled YubiKey OTP only"
    else
        _update_directive "PasswordAuthentication" "yes"
        _update_directive "PubkeyAuthentication" "yes"
        echo "[OK] Enabled YubiKey + password (2FA)"
    fi
    _restart_ssh
}

_apply_preset() {
    local summary="root: $(_status_root_login) | password: $(_status_password_login) | pubkey: $(_status_pubkey_login) | YubiKey: $(_status_yubikey_mode)"
    _section_header "Recommended presets" "$summary"
    echo "1) Hardened production: disable root login, disable passwords, enable pubkey"
    echo "2) Daily development: allow root key, allow passwords"
    echo "3) Temporary/open: enable root + password"
    echo "4) YubiKey OTP only (disable password/pubkey)"
    echo "5) YubiKey + password (keep pubkey)"
    local p
    p=$(_read_choice "Select preset" "Esc/0 to return") || return

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
        *) echo "Invalid preset" ; return ;;
    esac
    _restart_ssh
}

_check_utf8_locale
while true; do
    _render_menu
    c=$(_read_choice "Choose an action" "") || continue
    case $c in
        1) _set_root_login ;;
        2) _set_password_login ;;
        3) _manage_pubkey_suite ;;
        4) _manage_yubikey ;;
        5) _apply_preset ;;
        0) exit 0 ;;
        *) echo "Invalid choice" ;;
    esac
    echo
    read -rp "Press Enter to return to the menu..." _
done
