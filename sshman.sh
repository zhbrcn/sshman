#!/bin/bash
# ==========================================
# sshman - SSH 登录管理脚本
# Author: zhbrcn + ChatGPT
# Version: 0.2
# ==========================================

SSH_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
BACKUP_DIR="/etc/ssh/sshman-backups"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
U2F_KEYS="/etc/ssh/u2f_keys"

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
    local key=$1
    local value=$2
    if grep -q "^${key}" "$SSH_CONFIG"; then
        sed -i "s/^${key}.*/${key} ${value}/" "$SSH_CONFIG"
    else
        echo "${key} ${value}" >> "$SSH_CONFIG"
    fi
}

_show_status() {
    echo "================ 当前 SSH 状态 ================"
    echo "- 系统: $(lsb_release -ds 2>/dev/null || echo Linux)"
    echo "- SSH 服务名: $SSH_SERVICE"
    echo
    echo "[sshd_config]"
    grep -E "^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)" "$SSH_CONFIG" 2>/dev/null
    echo
    echo "[PAM YubiKey]"
    if grep -q "pam_u2f.so" "$PAM_SSHD" 2>/dev/null; then
        echo "YubiKey 认证: 已启用"
        if [ -f "$U2F_KEYS" ]; then
            echo "映射文件: $U2F_KEYS"
            nl -ba "$U2F_KEYS"
        else
            echo "未找到 U2F 映射文件"
        fi
    else
        echo "YubiKey 认证: 未启用"
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
    _backup_file "$PAM_SSHD"
    sed -i "/pam_u2f.so/d" "$PAM_SSHD"
    echo "[✓] 已禁用 YubiKey 登录"
    _restart_ssh
}

_enable_yubikey() {
    _backup_file "$PAM_SSHD"
    if grep -q "pam_u2f.so" "$PAM_SSHD"; then
        sed -i "s#pam_u2f.so.*#auth required pam_u2f.so authfile=${U2F_KEYS} cue#" "$PAM_SSHD"
    else
        echo "auth required pam_u2f.so authfile=${U2F_KEYS} cue" >> "$PAM_SSHD"
    fi
    echo "[✓] 已启用 YubiKey 登录"
    _restart_ssh
}

_register_yubikeys() {
    echo "将为 pam_u2f 配置最多两个 YubiKey 映射。"
    read -rp "输入要绑定的系统用户名(默认: root): " u
    local user=${u:-root}

    mkdir -p "$(dirname "$U2F_KEYS")"
    touch "$U2F_KEYS"
    _backup_file "$U2F_KEYS"

    local entries=()
    for i in 1 2; do
        read -rp "粘贴第 ${i} 个 YubiKey 的 pamu2fcfg 输出行(留空跳过): " line
        [ -z "$line" ] && continue
        if [[ $line != ${user}:* ]]; then
            line="${user}:${line}"
        fi
        entries+=("$line")
    done

    if [ ${#entries[@]} -eq 0 ]; then
        echo "未添加任何 YubiKey 映射"
        return
    fi

    tmp=$(mktemp)
    grep -v "^${user}:" "$U2F_KEYS" > "$tmp" || true
    for e in "${entries[@]}"; do
        echo "$e" >> "$tmp"
    done
    mv "$tmp" "$U2F_KEYS"
    chmod 600 "$U2F_KEYS"
    echo "[✓] 已为用户 ${user} 写入 ${#entries[@]} 个 YubiKey 映射"
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
            _disable_yubikey
            ;;
        2)
            _update_directive "PermitRootLogin" "prohibit-password"
            _update_directive "PasswordAuthentication" "yes"
            _update_directive "PubkeyAuthentication" "yes"
            _disable_yubikey
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
    echo "5) 为用户注册最多 2 个 YubiKey"
    echo "6) 启用 YubiKey 登录"
    echo "7) 禁用 YubiKey 登录"
    echo "8) 套用预设配置"
    echo "0) 退出"
    echo "--------------------------------"
    read -rp "请选择操作: " c

    case $c in
        1) _set_root_login ;;
        2) _set_password_login ;;
        3) _set_pubkey_login ;;
        4) _manage_keys ;;
        5) _register_yubikeys ;;
        6) _enable_yubikey ;;
        7) _disable_yubikey ;;
        8) _apply_preset ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
    echo
    read -rp "按回车继续..." _
done
