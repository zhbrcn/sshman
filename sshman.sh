#!/bin/bash
# sshman - SSH 登录管理器 (修复优化版)
# 适用系统: Debian/Ubuntu (依赖 apt-get)
# 请在 UTF-8 终端运行

# 如果发生严重错误则停止运行，但允许 grep 等命令返回非零值
set -e

# --- 全局变量配置 ---
SSH_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
BACKUP_DIR="/etc/ssh/sshman-backups"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
# 注意：这里是硬编码的 YubiKey 密钥，生产环境建议不要直接写在脚本里
AUTHORIZED_YUBIKEYS="/etc/ssh/authorized_yubikeys"
HARDENED_YUBIKEYS="root:cccccbenueru:cccccbejiijg"
YUBI_CLIENT_ID="85975"
YUBI_SECRET_KEY="//EomrFfWNk8fWV/6h7IW8pgs9Y="

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

# --- 基础检查函数 ---

# 1. 检查是否为 Root 用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[错误] 请使用 root 权限运行此脚本 (例如: sudo bash sshman.sh)${RESET}"
   exit 1
fi

# 2. 创建备份目录
mkdir -p "$BACKUP_DIR"

# 3. 检测 SSH 服务名称 (ssh 或 sshd)
if systemctl list-unit-files | grep -q "^ssh.service"; then
    SSH_SERVICE="ssh"
else
    SSH_SERVICE="sshd"
fi

# --- 核心工具函数 ---

# 暂停并等待用户确认
_pause() {
    echo ""
    read -rp "按 [回车键] 返回主菜单..." dummy
}

# 备份文件
_backup_file() {
    local file=$1
    local name
    name=$(basename "$file")
    if [[ -f "$file" ]]; then
        local backup_path="$BACKUP_DIR/${name}.bak.$(date +%F-%H%M%S)"
        cp "$file" "$backup_path"
        # echo "已备份 $file 到 $backup_path" # 调试时可开启
    fi
}

# 重启 SSH 服务
_restart_ssh() {
    echo -e "${YELLOW}[*] 正在重启 SSH 服务...${RESET}"
    if systemctl restart "$SSH_SERVICE"; then
        echo -e "${GREEN}[OK] SSH 服务重启成功${RESET}"
    else
        echo -e "${RED}[!] SSH 重启失败，请手动检查配置文件: sshd -t${RESET}"
    fi
}

# 修改 SSH 配置文件 (如果存在则替换，不存在则添加)
_update_directive() {
    local key=$1
    local value=$2
    if grep -q "^${key}" "$SSH_CONFIG"; then
        sed -i "s/^${key}.*/${key} ${value}/" "$SSH_CONFIG"
    else
        echo "${key} ${value}" >> "$SSH_CONFIG"
    fi
}

# 删除配置项
_remove_directive() {
    local key=$1
    sed -i "/^${key}\\b/d" "$SSH_CONFIG"
}

# 获取当前配置值
_get_directive() {
    local key=$1
    local default=$2
    # 获取最后一行有效的配置
    local found
    found=$(grep -E "^${key}\\b" "$SSH_CONFIG" | tail -n1 | awk '{print $2}')
    echo "${found:-$default}"
}

# --- 状态显示格式化 ---

_format_status() {
    if [[ "$1" == "yes" ]]; then
        echo -e "${GREEN}已开启${RESET}"
    else
        echo -e "${RED}已关闭${RESET}"
    fi
}

_format_root() {
    case $1 in
        yes) echo -e "${RED}允许 (不安全)${RESET}" ;;
        prohibit-password) echo -e "${GREEN}仅密钥 (推荐)${RESET}" ;;
        no) echo -e "${GREEN}禁止 (最安全)${RESET}" ;;
        *) echo "未设置" ;;
    esac
}

_status_yubikey() {
    if grep -q "pam_yubico.so" "$PAM_SSHD" 2>/dev/null; then
        if grep -q "^@include common-auth" "$PAM_SSHD"; then
             echo -e "${YELLOW}YubiKey + 密码 (2FA)${RESET}"
        else
             echo -e "${GREEN}仅 YubiKey (OTP)${RESET}"
        fi
    else
        echo -e "${RED}未启用${RESET}"
    fi
}

# --- 核心功能函数 ---

# 切换 Root 登录权限
_toggle_root_login() {
    local current next
    current=$(_get_directive PermitRootLogin "yes")
    
    # 循环切换逻辑: yes -> prohibit-password -> no -> yes
    case $current in
        yes) next="prohibit-password" ;;
        prohibit-password) next="no" ;;
        *) next="yes" ;;
    esac

    _backup_file "$SSH_CONFIG"
    _update_directive "PermitRootLogin" "$next"
    echo -e "Root 登录权限已修改为: $(_format_root "$next")"
    _restart_ssh
}

# 切换密码登录
_toggle_password() {
    local current next
    current=$(_get_directive PasswordAuthentication "yes")
    if [[ "$current" == "yes" ]]; then next="no"; else next="yes"; fi
    
    _backup_file "$SSH_CONFIG"
    _update_directive "PasswordAuthentication" "$next"
    echo -e "密码登录已修改为: $(_format_status "$next")"
    _restart_ssh
}

# 切换公钥登录
_toggle_pubkey() {
    local current next
    current=$(_get_directive PubkeyAuthentication "yes")
    if [[ "$current" == "yes" ]]; then next="no"; else next="yes"; fi
    
    _backup_file "$SSH_CONFIG"
    _update_directive "PubkeyAuthentication" "$next"
    echo -e "公钥登录已修改为: $(_format_status "$next")"
    _restart_ssh
}

# 密钥管理菜单
_manage_keys() {
    while true; do
        clear
        echo -e "${BLUE}=== 密钥管理 (Authorized Keys) ===${RESET}"
        if [[ -f "$AUTHORIZED_KEYS" ]]; then
            local count=$(wc -l < "$AUTHORIZED_KEYS")
            echo "当前状态: 文件存在，共 $count 行"
        else
            echo "当前状态: 文件不存在"
        fi
        echo "--------------------------------"
        echo "1) 查看当前所有公钥"
        echo "2) 手动粘贴添加公钥"
        echo "3) 删除指定行的公钥"
        echo "0) 返回主菜单"
        echo "--------------------------------"
        read -rp "请选择: " k_choice

        case $k_choice in
            1)
                if [[ -f "$AUTHORIZED_KEYS" ]]; then
                    echo -e "\n--- 公钥列表 ---"
                    nl -ba "$AUTHORIZED_KEYS"
                else
                    echo -e "\n[!] 文件不存在。"
                fi
                _pause
                ;;
            2)
                mkdir -p "$HOME/.ssh"
                chmod 700 "$HOME/.ssh"
                read -rp "请粘贴公钥内容 (然后按回车): " pubkey
                if [[ -n "$pubkey" ]]; then
                    echo "$pubkey" >> "$AUTHORIZED_KEYS"
                    chmod 600 "$AUTHORIZED_KEYS"
                    echo -e "${GREEN}[OK] 公钥已添加。${RESET}"
                else
                    echo "未输入内容。"
                fi
                _pause
                ;;
            3)
                read -rp "请输入要删除的行号: " line_num
                if [[ "$line_num" =~ ^[0-9]+$ ]]; then
                     if [[ -f "$AUTHORIZED_KEYS" ]]; then
                        sed -i "${line_num}d" "$AUTHORIZED_KEYS"
                        echo -e "${GREEN}[OK] 第 $line_num 行已删除。${RESET}"
                     fi
                else
                    echo "无效的行号。"
                fi
                _pause
                ;;
            0) return ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

# --- YubiKey 相关函数 ---

_ensure_yubico() {
    if ! dpkg -s libpam-yubico >/dev/null 2>&1; then
        echo -e "${YELLOW}[*] 检测到未安装 libpam-yubico，正在安装...${RESET}"
        apt-get update -qq && apt-get install -y libpam-yubico
    fi
}

_write_yubi_pam() {
    local mode=$1 # 'otp' or 'pass'
    _ensure_yubico
    
    # 写入 authorized_yubikeys
    _backup_file "$AUTHORIZED_YUBIKEYS"
    echo "$HARDENED_YUBIKEYS" > "$AUTHORIZED_YUBIKEYS"
    chmod 600 "$AUTHORIZED_YUBIKEYS"
    
    # 写入 PAM
    _backup_file "$PAM_SSHD"
    echo "# Managed by sshman" > "$PAM_SSHD"
    echo "auth required pam_yubico.so id=${YUBI_CLIENT_ID} key=${YUBI_SECRET_KEY} authfile=${AUTHORIZED_YUBIKEYS} mode=clientless" >> "$PAM_SSHD"
    
    if [[ "$mode" == "pass" ]]; then
        echo "@include common-auth" >> "$PAM_SSHD"
    fi
    
    # 添加标准 PAM 配置
    cat >> "$PAM_SSHD" <<EOF
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
EOF
}

_disable_yubikey() {
    _backup_file "$PAM_SSHD"
    cat > "$PAM_SSHD" <<EOF
@include common-auth
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
EOF
    _remove_directive "AuthenticationMethods"
    _update_directive "ChallengeResponseAuthentication" "no"
    echo -e "${GREEN}[OK] YubiKey 已禁用，恢复默认设置。${RESET}"
    _restart_ssh
}

_setup_yubikey() {
    clear
    echo -e "${BLUE}=== YubiKey 配置模式 ===${RESET}"
    echo "1) 仅 YubiKey (OTP) - 禁用密码登录"
    echo "2) YubiKey + 密码 (两步验证)"
    echo "3) 禁用 YubiKey (恢复默认)"
    echo "0) 返回"
    read -rp "请选择: " y_choice
    
    case $y_choice in
        1)
            _write_yubi_pam "otp"
            _update_directive "UsePAM" "yes"
            _update_directive "ChallengeResponseAuthentication" "yes"
            _update_directive "AuthenticationMethods" "keyboard-interactive"
            _update_directive "PasswordAuthentication" "no"
            echo -e "${GREEN}[OK] 已配置为仅 YubiKey 模式。${RESET}"
            _restart_ssh
            ;;
        2)
            _write_yubi_pam "pass"
            _update_directive "UsePAM" "yes"
            _update_directive "ChallengeResponseAuthentication" "yes"
            _update_directive "AuthenticationMethods" "keyboard-interactive"
            _update_directive "PasswordAuthentication" "yes"
            echo -e "${GREEN}[OK] 已配置为 YubiKey + 密码模式。${RESET}"
            _restart_ssh
            ;;
        3) _disable_yubikey ;;
        0) return ;;
        *) echo "无效选项" ;;
    esac
    _pause
}

# --- 主菜单逻辑 ---

_show_menu() {
    clear
    local border="================================================================"
    echo -e "${BLUE}$border${RESET}"
    echo -e "   sshman - SSH 登录配置管理器 (新手友好版)"
    echo -e "   系统: $(lsb_release -ds 2>/dev/null || echo Linux) | 服务: $SSH_SERVICE"
    echo -e "${BLUE}$border${RESET}"
    
    # 获取当前状态
    local root_st=$(_get_directive PermitRootLogin "yes")
    local pass_st=$(_get_directive PasswordAuthentication "yes")
    local pub_st=$(_get_directive PubkeyAuthentication "yes")
    
    printf " 1) 密码登录开关       [%s]\n" "$(_format_status "$pass_st")"
    printf " 2) 公钥登录开关       [%s]\n" "$(_format_status "$pub_st")"
    printf " 3) Root 登录权限      [%s]\n" "$(_format_root "$root_st")"
    printf " 4) YubiKey 设置       [%s]\n" "$(_status_yubikey)"
    echo " 5) 密钥管理 (查看/添加/删除)"
    echo " ----------------------------------------------------------------"
    echo " 0) 退出程序"
    echo -e "${BLUE}$border${RESET}"
}

# --- 主程序循环 ---

while true; do
    _show_menu
    read -rp " 请输入数字选项 [0-5]: " choice
    
    case $choice in
        1) _toggle_password; _pause ;;
        2) _toggle_pubkey; _pause ;;
        3) _toggle_root_login; _pause ;;
        4) _setup_yubikey ;; # 子菜单内部有 pause
        5) _manage_keys ;;   # 子菜单内部有 pause
        0) echo "已退出。"; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新输入。${RESET}"; sleep 1 ;;
    esac
done
