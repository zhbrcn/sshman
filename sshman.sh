#!/bin/bash
# sshman - SSH 登录管理器 (修复显示版)
# 修复: 选项6颜色显示错误
# 优化: 菜单显示逻辑、输入体验

set -e

# --- 全局配置 ---
SSH_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
BACKUP_DIR="/etc/ssh/sshman-backups"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
AUTHORIZED_YUBIKEYS="/etc/ssh/authorized_yubikeys"
HARDENED_YUBIKEYS="root:cccccbenueru:cccccbejiijg"
YUBI_CLIENT_ID="85975"
YUBI_SECRET_KEY="//EomrFfWNk8fWV/6h7IW8pgs9Y="

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
BLUE="\033[34m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# --- 基础检查 ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[错误] 请使用 root 权限运行: sudo bash sshman.sh${RESET}"
   exit 1
fi
mkdir -p "$BACKUP_DIR"
if systemctl list-unit-files | grep -q "^ssh.service"; then
    SSH_SERVICE="ssh"
else
    SSH_SERVICE="sshd"
fi

# --- 核心工具函数 ---

_flash_msg() {
    sleep 1.5
}

# 检查返回信号 (0 或 ESC)
_is_back() {
    local input="$1"
    # 兼容 ESC 字符 (有些终端需要按回车才会发送 ESC 序列)
    if [[ "$input" == "0" || "$input" == $'\e' || "$input" == *$'\e'* ]]; then
        return 0
    else
        return 1
    fi
}

_backup_file() {
    local file=$1
    if [[ -f "$file" ]]; then
        cp "$file" "$BACKUP_DIR/$(basename "$file").bak.$(date +%F-%H%M%S)"
    fi
}

_restart_ssh() {
    echo -e "${YELLOW}[*] 正在重启 SSH 服务...${RESET}"
    if systemctl restart "$SSH_SERVICE"; then
        echo -e "${GREEN}[OK] SSH 服务已重启${RESET}"
    else
        echo -e "${RED}[!] SSH 重启失败，请检查配置!${RESET}"
    fi
}

_update_directive() {
    local key=$1; local value=$2
    if grep -q "^${key}" "$SSH_CONFIG"; then
        sed -i "s/^${key}.*/${key} ${value}/" "$SSH_CONFIG"
    else
        echo "${key} ${value}" >> "$SSH_CONFIG"
    fi
}

_remove_directive() {
    sed -i "/^${1}\\b/d" "$SSH_CONFIG"
}

_get_directive() {
    local val
    val=$(grep -E "^${1}\\b" "$SSH_CONFIG" | tail -n1 | awk '{print $2}')
    echo "${val:-$2}"
}

# --- 状态显示 ---
_fmt_yn() { if [[ "$1" == "yes" ]]; then echo -e "${GREEN}开启${RESET}"; else echo -e "${RED}关闭${RESET}"; fi; }
_fmt_root() {
    case $1 in
        yes) echo -e "${RED}允许${RESET}" ;;
        prohibit-password) echo -e "${GREEN}仅密钥${RESET}" ;;
        no) echo -e "${GREEN}禁止${RESET}" ;;
        *) echo "未知" ;;
    esac
}
_fmt_yubi() {
    if grep -q "pam_yubico.so" "$PAM_SSHD" 2>/dev/null; then
        if grep -q "^@include common-auth" "$PAM_SSHD"; then echo -e "${YELLOW}2FA模式${RESET}"; else echo -e "${GREEN}仅Key${RESET}"; fi
    else echo -e "${RED}未启用${RESET}"; fi
}

# --- 功能函数 ---

_toggle_root() {
    local curr=$(_get_directive PermitRootLogin "yes"); local next
    case $curr in yes) next="prohibit-password";; prohibit-password) next="no";; *) next="yes";; esac
    _backup_file "$SSH_CONFIG"
    _update_directive "PermitRootLogin" "$next"
    echo -e "Root登录: $(_fmt_root "$next")"
    _restart_ssh
}

_toggle_pass() {
    local curr=$(_get_directive PasswordAuthentication "yes"); local next
    if [[ "$curr" == "yes" ]]; then next="no"; else next="yes"; fi
    _backup_file "$SSH_CONFIG"
    _update_directive "PasswordAuthentication" "$next"
    echo -e "密码登录: $(_fmt_yn "$next")"
    _restart_ssh
}

_toggle_pub() {
    local curr=$(_get_directive PubkeyAuthentication "yes"); local next
    if [[ "$curr" == "yes" ]]; then next="no"; else next="yes"; fi
    _backup_file "$SSH_CONFIG"
    _update_directive "PubkeyAuthentication" "$next"
    echo -e "公钥登录: $(_fmt_yn "$next")"
    _restart_ssh
}

# --- YubiKey 逻辑 ---
_ensure_yubi() { dpkg -s libpam-yubico >/dev/null 2>&1 || (echo "安装依赖..."; apt-get update -qq && apt-get install -y libpam-yubico); }

_setup_yubikey() {
    while true; do
        clear
        echo -e "${BLUE}=== YubiKey 模式选择 ===${RESET}"
        echo " 1) 仅 YubiKey (OTP) - [禁用密码]"
        echo " 2) YubiKey + 密码 (2FA)"
        echo " 3) 禁用 YubiKey (恢复默认)"
        echo " 0) 返回"
        
        # 使用 read -e 优化输入体验
        read -e -rp "请选择: " y_choice
        
        if _is_back "$y_choice"; then return; fi

        case $y_choice in
            1)
                _ensure_yubi; _backup_file "$PAM_SSHD"; _backup_file "$AUTHORIZED_YUBIKEYS"
                echo "$HARDENED_YUBIKEYS" > "$AUTHORIZED_YUBIKEYS"; chmod 600 "$AUTHORIZED_YUBIKEYS"
                echo "auth required pam_yubico.so id=${YUBI_CLIENT_ID} key=${YUBI_SECRET_KEY} authfile=${AUTHORIZED_YUBIKEYS} mode=clientless" > "$PAM_SSHD"
                cat >> "$PAM_SSHD" <<EOF
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
EOF
                _update_directive "UsePAM" "yes"
                _update_directive "ChallengeResponseAuthentication" "yes"
                _update_directive "AuthenticationMethods" "keyboard-interactive"
                _update_directive "PasswordAuthentication" "no"
                echo -e "${GREEN}[OK] 已设为仅 YubiKey${RESET}"; _restart_ssh; _flash_msg
                ;;
            2)
                _ensure_yubi; _backup_file "$PAM_SSHD"; _backup_file "$AUTHORIZED_YUBIKEYS"
                echo "$HARDENED_YUBIKEYS" > "$AUTHORIZED_YUBIKEYS"; chmod 600 "$AUTHORIZED_YUBIKEYS"
                echo "auth required pam_yubico.so id=${YUBI_CLIENT_ID} key=${YUBI_SECRET_KEY} authfile=${AUTHORIZED_YUBIKEYS} mode=clientless" > "$PAM_SSHD"
                echo "@include common-auth" >> "$PAM_SSHD"
                cat >> "$PAM_SSHD" <<EOF
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
EOF
                _update_directive "UsePAM" "yes"
                _update_directive "ChallengeResponseAuthentication" "yes"
                _update_directive "AuthenticationMethods" "keyboard-interactive"
                _update_directive "PasswordAuthentication" "yes"
                echo -e "${GREEN}[OK] 已设为 YubiKey + 密码${RESET}"; _restart_ssh; _flash_msg
                ;;
            3)
                _backup_file "$PAM_SSHD"
                echo "@include common-auth" > "$PAM_SSHD"
                cat >> "$PAM_SSHD" <<EOF
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
EOF
                _remove_directive "AuthenticationMethods"
                _update_directive "ChallengeResponseAuthentication" "no"
                echo -e "${GREEN}[OK] YubiKey 已禁用${RESET}"; _restart_ssh; _flash_msg
                ;;
            *) echo "无效选项"; sleep 0.5 ;;
        esac
    done
}

# --- 推荐预设逻辑 ---
_presets_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== 推荐预设 (一键配置) ===${RESET}"
        # 使用 printf 确保颜色正确显示
        printf " 1) %b加固生产%b (禁止Root + 禁密码 + 仅公钥)\n" "${GREEN}" "${RESET}"
        printf " 2) %b日常开发%b (Root仅密钥 + 允许密码 + 允许公钥)\n" "${YELLOW}" "${RESET}"
        printf " 3) %b临时开放%b (允许Root + 允许密码 - 不推荐)\n" "${RED}" "${RESET}"
        echo " 0) 返回"
        
        read -e -rp "请选择: " p_choice

        if _is_back "$p_choice"; then return; fi

        case $p_choice in
            1)
                echo "[*] 应用：加固生产模式..."
                _backup_file "$SSH_CONFIG"
                _update_directive "PermitRootLogin" "no"
                _update_directive "PasswordAuthentication" "no"
                _update_directive "PubkeyAuthentication" "yes"
                _remove_directive "AuthenticationMethods"
                _restart_ssh
                echo -e "${GREEN}[OK] 配置已应用${RESET}"
                _flash_msg
                ;;
            2)
                echo "[*] 应用：日常开发模式..."
                _backup_file "$SSH_CONFIG"
                _update_directive "PermitRootLogin" "prohibit-password"
                _update_directive "PasswordAuthentication" "yes"
                _update_directive "PubkeyAuthentication" "yes"
                _remove_directive "AuthenticationMethods"
                _restart_ssh
                echo -e "${GREEN}[OK] 配置已应用${RESET}"
                _flash_msg
                ;;
            3)
                echo "[*] 应用：临时开放模式..."
                _backup_file "$SSH_CONFIG"
                _update_directive "PermitRootLogin" "yes"
                _update_directive "PasswordAuthentication" "yes"
                _update_directive "PubkeyAuthentication" "yes"
                _remove_directive "AuthenticationMethods"
                _restart_ssh
                echo -e "${RED}[警告] 系统现在允许 Root 密码登录，请注意安全!${RESET}"
                _flash_msg
                ;;
            *) echo "无效选项"; sleep 0.5 ;;
        esac
    done
}

_manage_keys() {
    while true; do
        clear
        echo -e "${BLUE}=== 密钥管理 ===${RESET}"
        if [[ -f "$AUTHORIZED_KEYS" ]]; then
            echo "当前: $(wc -l < "$AUTHORIZED_KEYS") 个公钥"
        else
            echo "当前: 无文件"
        fi
        echo " 1) 查看公钥"
        echo " 2) 添加公钥 (粘贴)"
        echo " 3) 删除公钥 (按行号)"
        echo " 0) 返回"
        
        read -e -rp "请选择: " k_choice

        if _is_back "$k_choice"; then return; fi

        case $k_choice in
            1)
                [[ -f "$AUTHORIZED_KEYS" ]] && nl -ba "$AUTHORIZED_KEYS" || echo "无文件"
                echo ""; read -rp "按回车继续..." dummy
                ;;
            2)
                mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
                read -e -rp "请粘贴公钥: " pubkey
                if [[ -n "$pubkey" ]]; then
                    echo "$pubkey" >> "$AUTHORIZED_KEYS"; chmod 600 "$AUTHORIZED_KEYS"
                    echo -e "${GREEN}[OK] 添加成功${RESET}"
                fi
                _flash_msg
                ;;
            3)
                read -e -rp "输入删除行号: " lnum
                if [[ "$lnum" =~ ^[0-9]+$ ]] && [[ -f "$AUTHORIZED_KEYS" ]]; then
                    sed -i "${lnum}d" "$AUTHORIZED_KEYS"
                    echo -e "${GREEN}[OK] 已删除${RESET}"
                fi
                _flash_msg
                ;;
            *) echo "无效"; sleep 0.5 ;;
        esac
    done
}

# --- 主循环 ---
while true; do
    clear
    echo -e "${BLUE}==========================================${RESET}"
    echo -e " sshman - 极速版 (使用 0 返回，自动刷新)"
    echo -e "${BLUE}==========================================${RESET}"
    
    r_st=$(_get_directive PermitRootLogin "yes")
    p_st=$(_get_directive PasswordAuthentication "yes")
    k_st=$(_get_directive PubkeyAuthentication "yes")

    printf " 1) 密码登录  [%s]\n" "$(_fmt_yn "$p_st")"
    printf " 2) 公钥登录  [%s]\n" "$(_fmt_yn "$k_st")"
    printf " 3) Root权限  [%s]\n" "$(_fmt_root "$r_st")"
    printf " 4) YubiKey   [%s]\n" "$(_fmt_yubi)"
    echo   " 5) 密钥管理"
    # 修复：使用 printf 替代 echo 避免颜色代码不转义
    printf " 6) %b推荐预设 (一键设置)%b\n" "${CYAN}" "${RESET}"
    echo -e "${BLUE}------------------------------------------${RESET}"
    echo " 0) 退出"
    
    # 优化：提示用户使用数字 0 返回，避免 Esc 困惑
    read -e -rp " 请输入选项: " choice
    
    case $choice in
        1) _toggle_pass; _flash_msg ;;
        2) _toggle_pub; _flash_msg ;;
        3) _toggle_root; _flash_msg ;;
        4) _setup_yubikey ;;
        5) _manage_keys ;;
        6) _presets_menu ;;
        0) echo "Bye!"; exit 0 ;;
        *) echo "无效选项"; sleep 0.5 ;;
    esac
done
