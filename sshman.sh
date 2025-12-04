#!/bin/bash
# sshman - SSH 登录管理脚本 (中文交互)

SSH_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
BACKUP_DIR="/etc/ssh/sshman-backups"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
AUTHORIZED_YUBIKEYS="/etc/ssh/authorized_yubikeys"
HARDENED_YUBIKEYS="root:cccccbenueru:cccccbejiijg"

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

_show_status() {
    echo "================ 当前 SSH 状态 ================"
    echo "系统: $(lsb_release -ds 2>/dev/null || echo Linux)"
    echo "服务: $SSH_SERVICE"
    echo
    echo "[sshd_config]"
    grep -E "^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|ChallengeResponseAuthentication|UsePAM)" "$SSH_CONFIG" 2>/dev/null
    echo
    echo "[PAM YubiKey]"
    if grep -q "pam_yubico.so" "$PAM_SSHD" 2>/dev/null; then
        echo "YubiKey (OTP): 已启用（支持同时使用密码/公钥）"
        if [ -f "$AUTHORIZED_YUBIKEYS" ]; then
            echo "授权文件: $AUTHORIZED_YUBIKEYS"
            nl -ba "$AUTHORIZED_YUBIKEYS"
        else
            echo "授权文件缺失"
        fi
    else
        echo "YubiKey (OTP): 未启用"
    fi
    echo
    echo "[authorized_keys]"
    if [ -f "$AUTHORIZED_KEYS" ]; then
        nl -ba "$AUTHORIZED_KEYS"
    else
        echo "尚未创建 authorized_keys"
    fi
    echo "=============================================="
}

_set_root_login() {
    echo "1) 允许 root 登录 (yes)"
    echo "2) 禁止 root 密码登录，但允许密钥 (prohibit-password)"
    echo "3) 禁止 root 登录 (no)"
    read -rp "请选择: " a

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
    read -rp "请选择: " a

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
    read -rp "请选择: " a

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
    read -rp "请选择: " a

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

_disable_yubikey() {
    local skip_restart=$1
    _backup_file "$PAM_SSHD"
    sed -i "/pam_yubico.so/d" "$PAM_SSHD"
    echo "[✓] 已禁用 YubiKey 登录"
    [ "$skip_restart" = "skip" ] || _restart_ssh
}

_enable_yubikey() {
    _backup_file "$AUTHORIZED_YUBIKEYS"
    printf "%s\n" "$HARDENED_YUBIKEYS" > "$AUTHORIZED_YUBIKEYS"
    chmod 600 "$AUTHORIZED_YUBIKEYS"
    chown root:root "$AUTHORIZED_YUBIKEYS" 2>/dev/null

    _backup_file "$PAM_SSHD"
    if grep -q "pam_yubico.so" "$PAM_SSHD"; then
        sed -i "s#pam_yubico.so.*#auth sufficient pam_yubico.so authfile=${AUTHORIZED_YUBIKEYS} mode=clientless#" "$PAM_SSHD"
    else
        sed -i "1i auth sufficient pam_yubico.so authfile=${AUTHORIZED_YUBIKEYS} mode=clientless" "$PAM_SSHD"
    fi

    _update_directive "UsePAM" "yes"
    _update_directive "ChallengeResponseAuthentication" "yes"
    echo "[✓] 已启用固定的两把 YubiKey OTP（同时保留密码/公钥登录）"
    _restart_ssh
}

_apply_preset() {
    echo "1) 安全生产：禁止 root 登录，禁止密码，仅公钥"
    echo "2) 日常开发：允许 root 密钥，允许密码"
    echo "3) 玩具环境：root + 密码全部开启"
    read -rp "请选择预设: " p

    _backup_file "$SSH_CONFIG"
    _backup_file "$PAM_SSHD"

    case $p in
        1)
            _update_directive "PermitRootLogin" "no"
            _update_directive "PasswordAuthentication" "no"
            _update_directive "PubkeyAuthentication" "yes"
            _disable_yubikey skip
            ;;
        2)
            _update_directive "PermitRootLogin" "prohibit-password"
            _update_directive "PasswordAuthentication" "yes"
            _update_directive "PubkeyAuthentication" "yes"
            _disable_yubikey skip
            ;;
        3)
            _update_directive "PermitRootLogin" "yes"
            _update_directive "PasswordAuthentication" "yes"
            _update_directive "PubkeyAuthentication" "yes"
            ;;
        *) echo "无效预设" ; return ;;
    esac
    _restart_ssh
}

while true; do
    _show_status
    echo "----------- 操作菜单 -----------"
    echo "1) 设置 root 登录方式"
    echo "2) 启用/禁用密码登录"
    echo "3) 启用/禁用公钥登录"
    echo "4) 管理 authorized_keys (自动写入我的密钥)"
    echo "5) 启用固定的两把 YubiKey 登录"
    echo "6) 禁用 YubiKey 登录"
    echo "7) 套用预设配置"
    echo "0) 退出"
    echo "--------------------------------"
    read -rp "请选择操作: " c

    case $c in
        1) _set_root_login ;;
        2) _set_password_login ;;
        3) _set_pubkey_login ;;
        4) _manage_keys ;;
        5) _enable_yubikey ;;
        6) _disable_yubikey ;;
        7) _apply_preset ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
    echo
    read -rp "按回车继续..." _
done
