#!/bin/bash
# ==============================================================================
# sshman - SSH 登录配置管理工具 (个人专用版)
# 版本: v1.0.1
# 作者: 代码助手
# 说明: 本脚本仅供个人服务器管理使用，请勿在未授权的生产环境中分发。
# ==============================================================================

set -e

# --- [ 全局配置变量 ] ---
VERSION="v1.0.1"
SSH_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
BACKUP_DIR="/etc/ssh/sshman-backups"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
AUTHORIZED_YUBIKEYS="/etc/ssh/authorized_yubikeys"

# YubiKey 默认凭证 (硬编码)
HARDENED_YUBIKEYS="root:cccccbenueru:cccccbejiijg"
YUBI_CLIENT_ID="85975"
YUBI_SECRET_KEY="//EomrFfWNk8fWV/6h7IW8pgs9Y="

# 颜色代码
GREEN="\033[32m"
RED="\033[31m"
BLUE="\033[34m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# --- [ 环境自检 ] ---
[[ $EUID -ne 0 ]] && { echo -e "${RED}[错误] 请使用 sudo 运行此脚本。${RESET}"; exit 1; }
mkdir -p "$BACKUP_DIR"
systemctl list-unit-files | grep -q "^ssh.service" && SSH_SERVICE="ssh" || SSH_SERVICE="sshd"

# --- [ 核心工具函数 ] ---

_flash_msg() { sleep 1.2; } # 操作后短暂亦留

_backup_file() {
    local file=$1
    [[ -f "$file" ]] && cp "$file" "$BACKUP_DIR/$(basename "$file").bak.$(date +%F-%H%M%S)"
}

_restart_ssh() {
    echo -e "${YELLOW}[*] 正在应用更改 (重启 SSH)...${RESET}"
    if systemctl restart "$SSH_SERVICE"; then
        echo -e "${GREEN}[OK] 服务重启成功${RESET}"
    else
        echo -e "${RED}[!] 重启失败，请检查配置文件: sshd -t${RESET}"
    fi
}

_update_conf() {
    local key=$1 val=$2 file=${3:-$SSH_CONFIG}
    if grep -q "^${key}" "$file"; then
        sed -i "s|^${key}.*|${key} ${val}|" "$file"
    else
        echo "${key} ${val}" >> "$file"
    fi
}

_remove_conf() { sed -i "/^${1}\\b/d" "${2:-$SSH_CONFIG}"; }

_get_conf() {
    local val
    val=$(grep -E "^${1}\\b" "$SSH_CONFIG" | tail -n1 | awk '{print $2}')
    echo "${val:-$2}"
}

# --- [ 状态格式化 ] ---
_fmt_yn()   { [[ "$1" == "yes" ]] && echo -e "${GREEN}开启${RESET}" || echo -e "${RED}关闭${RESET}"; }
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
        grep -q "^@include common-auth" "$PAM_SSHD" && echo -e "${YELLOW}2FA模式${RESET}" || echo -e "${GREEN}仅Key${RESET}"
    else
        echo -e "${RED}未启用${RESET}"
    fi
}

# 检查当前配置是否符合任一预设，并返回指示字符串
_check_preset_status() {
    local root_st pass_st pub_st
    # 确保公钥认证相关指令存在，否则可能导致空值判断错误
    root_st=$(_get_conf "PermitRootLogin" "yes")
    pass_st=$(_get_conf "PasswordAuthentication" "yes")
    pub_st=$(_get_conf "PubkeyAuthentication" "yes")
    
    # 1) 加固生产 (禁止Root + 禁密码 + 仅公钥)
    if [[ "$root_st" == "no" ]] && [[ "$pass_st" == "no" ]] && [[ "$pub_st" == "yes" ]]; then
        echo -e " (${GREEN}已匹配: 加固生产${RESET})"
        return
    fi

    # 2) 日常开发 (Root仅密钥 + 允许密码 + 允许公钥)
    if [[ "$root_st" == "prohibit-password" ]] && [[ "$pass_st" == "yes" ]] && [[ "$pub_st" == "yes" ]]; then
        echo -e " (${YELLOW}已匹配: 日常开发${RESET})"
        return
    fi

    # 3) 临时开放 (允许Root + 允许密码 + 允许公钥)
    if [[ "$root_st" == "yes" ]] && [[ "$pass_st" == "yes" ]] && [[ "$pub_st" == "yes" ]]; then
        echo -e " (${RED}已匹配: 临时开放${RESET})"
        return
    fi

    # 如果不匹配任何预设，则返回空字符串
    echo ""
}

# --- [ 业务逻辑模块 ] ---

_toggle_bool() {
    local key=$1 desc=$2 current next
    current=$(_get_conf "$key" "yes")
    [[ "$current" == "yes" ]] && next="no" || next="yes"
    _backup_file "$SSH_CONFIG"
    _update_conf "$key" "$next"
    echo -e "${desc}: $(_fmt_yn "$next")"
    _restart_ssh
}

_toggle_root() {
    local current next
    current=$(_get_conf "PermitRootLogin" "yes")
    case $current in
        yes) next="prohibit-password" ;;
        prohibit-password) next="no" ;;
        *) next="yes" ;;
    esac
    _backup_file "$SSH_CONFIG"
    _update_conf "PermitRootLogin" "$next"
    echo -e "Root登录: $(_fmt_root "$next")"
    _restart_ssh
}

# --- [ YubiKey 模块 ] ---
_ensure_yubi_pkg() { dpkg -s libpam-yubico &>/dev/null || (echo "安装 YubiKey 依赖..."; apt-get update -qq && apt-get install -y libpam-yubico); }

_setup_yubikey() {
    while true; do
        clear
        echo -e "${BLUE}=== YubiKey 安全配置 ===${RESET}"
        echo " 1) 仅 YubiKey (OTP) - [禁用密码]"
        echo " 2) YubiKey + 密码 (2FA)"
        echo " 3) 禁用 YubiKey (恢复默认)"
        echo " 0) 返回"
        read -rp "请选择: " sel
        case $sel in
            1|2)
                _ensure_yubi_pkg; _backup_file "$PAM_SSHD"; _backup_file "$AUTHORIZED_YUBIKEYS"
                echo "$HARDENED_YUBIKEYS" > "$AUTHORIZED_YUBIKEYS"; chmod 600 "$AUTHORIZED_YUBIKEYS"
                
                echo "auth required pam_yubico.so id=${YUBI_CLIENT_ID} key=${YUBI_SECRET_KEY} authfile=${AUTHORIZED_YUBIKEYS} mode=clientless" > "$PAM_SSHD"
                [[ "$sel" == "2" ]] && echo "@include common-auth" >> "$PAM_SSHD"
                
                cat >> "$PAM_SSHD" <<EOF
account include common-account
password include common-password
session include common-session
session include common-session-noninteractive
EOF
                _update_conf "UsePAM" "yes"
                _update_conf "ChallengeResponseAuthentication" "yes"
                _update_conf "AuthenticationMethods" "keyboard-interactive"
                [[ "$sel" == "1" ]] && _update_conf "PasswordAuthentication" "no" || _update_conf "PasswordAuthentication" "yes"
                
                echo -e "${GREEN}[OK] YubiKey 配置已应用${RESET}"; _restart_ssh; _flash_msg
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
                _remove_conf "AuthenticationMethods"
                _update_conf "ChallengeResponseAuthentication" "no"
                echo -e "${GREEN}[OK] YubiKey 已禁用${RESET}"; _restart_ssh; _flash_msg
                ;;
            0) return ;;
            *) echo "无效选项"; sleep 0.5 ;;
        esac
    done
}

# --- [ 预设与密钥管理 ] ---
_presets_menu() {
    while true; do
        clear
        # 预设菜单标题也使用非蓝色
        echo -e "${YELLOW}=== 场景一键预设 ===${RESET}"
        echo -e " 1) ${GREEN}加固生产${RESET} (禁止Root + 禁密码 + 仅公钥)"
        echo -e " 2) ${YELLOW}日常开发${RESET} (Root仅密钥 + 允许密码 + 允许公钥)"
        echo -e " 3) ${RED}临时开放${RESET} (允许Root + 允许密码 - 不推荐)"
        echo " 0) 返回"
        read -rp "请选择: " p
        
        if [[ "$p" =~ ^[1-3]$ ]]; then
            _backup_file "$SSH_CONFIG"
            _remove_conf "AuthenticationMethods" 
            case $p in
                1) _update_conf "PermitRootLogin" "no"; _update_conf "PasswordAuthentication" "no"; _update_conf "PubkeyAuthentication" "yes" ;;
                2) _update_conf "PermitRootLogin" "prohibit-password"; _update_conf "PasswordAuthentication" "yes"; _update_conf "PubkeyAuthentication" "yes" ;;
                3) _update_conf "PermitRootLogin" "yes"; _update_conf "PasswordAuthentication" "yes"; _update_conf "PubkeyAuthentication" "yes" ;;
            esac
            echo -e "${GREEN}[OK] 预设已应用${RESET}"; _restart_ssh; _flash_msg
        elif [[ "$p" == "0" ]]; then return
        else echo "无效选项"; sleep 0.5
        fi
    done
}

_manage_keys() {
    while true; do
        clear
        echo -e "${BLUE}=== 密钥管理 ===${RESET}"
        KEY_COUNT=0
        [[ -f "$AUTHORIZED_KEYS" ]] && KEY_COUNT=$(wc -l < "$AUTHORIZED_KEYS")
        echo "当前公钥数: ${KEY_COUNT}"
        echo " 1) 查看 | 2) 添加(粘贴) | 3) 删除(行号) | 0) 返回"
        read -rp "选择: " k
        case $k in
            1) [[ -f "$AUTHORIZED_KEYS" ]] && nl -ba "$AUTHORIZED_KEYS" || echo "无文件"; read -rp "按回车继续..." ;;
            2) 
                mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
                read -rp "粘贴公钥: " pub
                [[ -n "$pub" ]] && { echo "$pub" >> "$AUTHORIZED_KEYS"; chmod 600 "$AUTHORIZED_KEYS"; echo -e "${GREEN}[OK] 添加成功${RESET}"; }
                _flash_msg ;;
            3)
                read -rp "删除行号: " num
                [[ "$num" =~ ^[0-9]+$ ]] && [[ -f "$AUTHORIZED_KEYS" ]] && { sed -i "${num}d" "$AUTHORIZED_KEYS"; echo -e "${GREEN}[OK] 删除成功${RESET}"; }
                _flash_msg ;;
            0) return ;;
            *) echo "无效"; sleep 0.5 ;;
        esac
    done
}

# --- [ 主程序 ] ---
while true; do
    clear
    echo -e "${BLUE}==========================================${RESET}"
    echo -e " sshman - SSH 管理器 ${VERSION}"
    echo -e "${BLUE}==========================================${RESET}"
    
    # 实时获取状态
    r=$(_get_conf "PermitRootLogin" "yes")
    p=$(_get_conf "PasswordAuthentication" "yes")
    k=$(_get_conf "PubkeyAuthentication" "yes")
    
    # 获取预设匹配状态和密钥数量
    PRESET_STATUS=$(_check_preset_status)
    KEY_COUNT=0
    [[ -f "$AUTHORIZED_KEYS" ]] && KEY_COUNT=$(wc -l < "$AUTHORIZED_KEYS")

    printf " 1) 密码登录  [%s]\n" "$(_fmt_yn "$p")"
    printf " 2) 公钥登录  [%s]\n" "$(_fmt_yn "$k")"
    printf " 3) Root权限  [%s]\n" "$(_fmt_root "$r")"
    printf " 4) YubiKey   [%s]\n" "$(_fmt_yubi)"
    # 优化点 1: 显示公钥数量
    echo   " 5) 密钥管理 (${KEY_COUNT}个公钥)"
    # 优化点 2: 改变颜色并显示预设匹配状态
    echo -e " 6) ${YELLOW}推荐预设${RESET}${PRESET_STATUS}"
    echo -e "${BLUE}------------------------------------------${RESET}"
    echo " 0) 退出"
    
    read -rp " 请输入: " choice
    case $choice in
        1) _toggle_bool "PasswordAuthentication" "密码登录"; _flash_msg ;;
        2) _toggle_bool "PubkeyAuthentication" "公钥登录"; _flash_msg ;;
        3) _toggle_root; _flash_msg ;;
        4) _setup_yubikey ;;
        5) _manage_keys ;;
        6) _presets_menu ;;
        0) echo "再见!"; exit 0 ;;
        *) echo "无效选项"; sleep 0.5 ;;
    esac
done
