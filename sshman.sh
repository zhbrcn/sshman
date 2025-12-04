#!/bin/bash
# ==========================================
# sshman - SSH Login Management Script
# Author: zhbrcn + ChatGPT
# Version: 0.1
# ==========================================

SSH_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
BACKUP_DIR="/etc/ssh/sshman-backups"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"

mkdir -p "$BACKUP_DIR"

# Detect ssh service name
detect_ssh_service() {
    if systemctl list-unit-files | grep -q "^ssh.service"; then
        echo "ssh"
    else
        echo "sshd"
    fi
}

SSH_SERVICE=$(detect_ssh_service)

# Backup function
backup_file() {
    local file=$1
    local name=$(basename "$file")
    cp "$file" "$BACKUP_DIR/${name}.bak.$(date +%F-%H%M%S)"
}

# Restart SSH safely
restart_ssh() {
    echo "[*] Restarting SSH service..."
    systemctl restart "$SSH_SERVICE"
    if [ $? -eq 0 ]; then
        echo "[✓] SSH restarted successfully"
    else
        echo "[!] SSH restart FAILED — please check manually!"
    fi
}

# ---------------------------------------------------------
# Show current SSH status
# ---------------------------------------------------------
show_status() {
    echo "=============================="
    echo " SSH Configuration Overview"
    echo "=============================="

    echo "- System: $(lsb_release -ds 2>/dev/null || echo Linux)"
    echo "- SSH service: $SSH_SERVICE"
    echo

    echo "[SSH Config]"
    grep -E "^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)" "$SSH_CONFIG" 2>/dev/null

    echo
    echo "[PAM YubiKey]"
    if grep -q "pam_u2f.so" "$PAM_SSHD" 2>/dev/null; then
        echo "PAM YubiKey: ENABLED"
    else
        echo "PAM YubiKey: disabled"
    fi

    echo
    echo "[Authorized Keys]"
    if [ -f "$AUTHORIZED_KEYS" ]; then
        nl -ba "$AUTHORIZED_KEYS"
    else
        echo "No authorized_keys found."
    fi
}

# ---------------------------------------------------------
# Modify SSH settings
# ---------------------------------------------------------
set_root_login() {
    echo "1) PermitRootLogin yes"
    echo "2) PermitRootLogin prohibit-password"
    echo "3) PermitRootLogin no"
    read -p "Select an option: " a

    backup_file "$SSH_CONFIG"

    case $a in
        1) sed -i "s/^PermitRootLogin.*/PermitRootLogin yes/; /PermitRootLogin/! s/$/\nPermitRootLogin yes/" "$SSH_CONFIG" ;;
        2) sed -i "s/^PermitRootLogin.*/PermitRootLogin prohibit-password/; /PermitRootLogin/! s/$/\nPermitRootLogin prohibit-password/" "$SSH_CONFIG" ;;
        3) sed -i "s/^PermitRootLogin.*/PermitRootLogin no/; /PermitRootLogin/! s/$/\nPermitRootLogin no/" "$SSH_CONFIG" ;;
        *) echo "Invalid option" ;;
    esac

    restart_ssh
}

set_password_login() {
    echo "1) Enable password login"
    echo "2) Disable password login"
    read -p "Choose: " a

    backup_file "$SSH_CONFIG"
    if [ "$a" -eq 1 ]; then
        sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/; /PasswordAuthentication/! s/$/\nPasswordAuthentication yes/" "$SSH_CONFIG"
    else
        sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/; /PasswordAuthentication/! s/$/\nPasswordAuthentication no/" "$SSH_CONFIG"
    fi

    restart_ssh
}

set_pubkey_login() {
    echo "1) Enable pubkey login"
    echo "2) Disable pubkey login"
    read -p "Choose: " a

    backup_file "$SSH_CONFIG"
    if [ "$a" -eq 1 ]; then
        sed -i "s/^PubkeyAuthentication.*/PubkeyAuthentication yes/; /PubkeyAuthentication/! s/$/\nPubkeyAuthentication yes/" "$SSH_CONFIG"
    else
        sed -i "s/^PubkeyAuthentication.*/PubkeyAuthentication no/; /PubkeyAuthentication/! s/$/\nPubkeyAuthentication no/" "$SSH_CONFIG"
    fi
    restart_ssh
}

# ---------------------------------------------------------
# Authorized keys management
# ---------------------------------------------------------
manage_keys() {
    echo "1) View keys"
    echo "2) Add key"
    echo "3) Remove key"
    read -p "Choose: " a

    case $a in
        1) nl -ba "$AUTHORIZED_KEYS" ;;
        2)
            read -p "Paste public key: " key
            mkdir -p ~/.ssh
            chmod 700 ~/.ssh
            echo "$key" >> "$AUTHORIZED_KEYS"
            chmod 600 "$AUTHORIZED_KEYS"
            echo "[✓] Key added."
            ;;
        3)
            nl -ba "$AUTHORIZED_KEYS"
            read -p "Select line number to delete: " line
            sed -i "${line}d" "$AUTHORIZED_KEYS"
            echo "[✓] Key removed."
            ;;
        *) echo "Invalid option" ;;
    esac
}

# ---------------------------------------------------------
# YubiKey PAM control
# ---------------------------------------------------------
disable_yubikey() {
    backup_file "$PAM_SSHD"
    sed -i "/pam_u2f.so/d" "$PAM_SSHD"
    echo "[✓] YubiKey PAM disabled."
    restart_ssh
}

enable_yubikey() {
    backup_file "$PAM_SSHD"
    echo "auth required pam_u2f.so cue" >> "$PAM_SSHD"
    echo "[✓] YubiKey PAM enabled (basic mode)."
    restart_ssh
}

# ---------------------------------------------------------
# Presets
# ---------------------------------------------------------
apply_preset() {
    echo "1) secure-prod"
    echo "2) personal-dev"
    echo "3) toy-box"
    read -p "Choose preset: " p

    backup_file "$SSH_CONFIG"
    backup_file "$PAM_SSHD"

    case $p in
        1)
            sed -i "s/^PermitRootLogin.*/PermitRootLogin no/" "$SSH_CONFIG"
            sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" "$SSH_CONFIG"
            sed -i "s/^PubkeyAuthentication.*/PubkeyAuthentication yes/" "$SSH_CONFIG"
            disable_yubikey
            ;;
        2)
            sed -i "s/^PermitRootLogin.*/PermitRootLogin prohibit-password/" "$SSH_CONFIG"
            sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/" "$SSH_CONFIG"
            sed -i "s/^PubkeyAuthentication.*/PubkeyAuthentication yes/" "$SSH_CONFIG"
            disable_yubikey
            ;;
        3)
            sed -i "s/^PermitRootLogin.*/PermitRootLogin yes/" "$SSH_CONFIG"
            sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/" "$SSH_CONFIG"
            sed -i "s/^PubkeyAuthentication.*/PubkeyAuthentication yes/" "$SSH_CONFIG"
            ;;
        *) echo "Invalid preset" ;;
    esac

    restart_ssh
}

# ---------------------------------------------------------
# Main menu
# ---------------------------------------------------------
while true; do
    echo
    echo "========== sshman =========="
    echo "1) Show current SSH status"
    echo "2) Set root login options"
    echo "3) Enable/disable password login"
    echo "4) Enable/disable pubkey login"
    echo "5) Manage authorized_keys"
    echo "6) Enable YubiKey login"
    echo "7) Disable YubiKey login"
    echo "8) Apply preset config"
    echo "0) Exit"
    echo "============================"
    read -p "Choose an option: " c

    case $c in
        1) show_status ;;
        2) set_root_login ;;
        3) set_password_login ;;
        4) set_pubkey_login ;;
        5) manage_keys ;;
        6) enable_yubikey ;;
        7) disable_yubikey ;;
        8) apply_preset ;;
        0) exit 0 ;;
        *) echo "Invalid choice" ;;
    esac
done
