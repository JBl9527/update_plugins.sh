#!/bin/sh

# ==========================================
# OpenWrt 插件更新与源注入脚本 (精准选择版)
# 特性: 架构自适应探测 / 手动越权 / 插件独立更新
# 支持: OPKG (< 24.10) & APK (24.10 / 25.10+)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# === ⚙️ 配置区：请将下方链接替换为您自己的 GitHub 软件源链接 ===

# 【1】OPKG 软件源 (对应 OpenWrt 23.xx 及更早版本)
OPKG_OPENCLASH_REPO="src/gz custom_openclash https://raw.githubusercontent.com/你的用户名/你的仓库/main/opkg/openclash/x86_64"
OPKG_PASSWALL_REPO="src/gz custom_passwall https://raw.githubusercontent.com/你的用户名/你的仓库/main/opkg/passwall/x86_64"

# 【2】APK 软件源 (对应 OpenWrt 24.10 / 25.10 及未来版本)
APK_OPENCLASH_REPO="https://raw.githubusercontent.com/你的用户名/你的仓库/main/apk/openclash/x86_64"
APK_PASSWALL_REPO="https://raw.githubusercontent.com/你的用户名/你的仓库/main/apk/passwall/x86_64"

# 全局变量
SELECTED_MANAGER=""
UPDATE_OPENCLASH=0
UPDATE_PASSWALL=0

# ==========================================================

# 1. 智能探测当前系统包管理器
auto_detect_env() {
    if command -v apk >/dev/null 2>&1; then
        DETECTED_MANAGER="apk"
        DETECTED_OS_DESC="新版 OpenWrt 24.10/25.10+ (APK架构)"
    elif command -v opkg >/dev/null 2>&1; then
        DETECTED_MANAGER="opkg"
        DETECTED_OS_DESC="经典 OpenWrt 23.xx及以下 (OPKG架构)"
    else
        DETECTED_MANAGER="unknown"
        DETECTED_OS_DESC="未知架构 (未找到 apk 或 opkg 指令)"
    fi
}

# 4. 执行更新逻辑核心
execute_update() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        echo -e "${CYAN}      正在执行 OPKG 模式插件更新流程      ${PLAIN}"
    else
        echo -e "${CYAN}      正在执行 APK 模式插件更新流程       ${PLAIN}"
    fi
    echo -e "${CYAN}==========================================${PLAIN}"
    
    TARGET_PACKAGES=""

    # ---------------- OPKG 模式 ----------------
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        if ! command -v opkg >/dev/null 2>&1; then
            echo -e "${RED}致命错误: 当前系统不存在 opkg 命令！强制运行失败。${PLAIN}"
            exit 1
        fi
        
        OPKG_CONF="/etc/opkg/customfeeds.conf"
        echo -e "\n${GREEN}[1/3] 正在检查并注入 OPKG 软件源...${PLAIN}"
        
        if [ "$UPDATE_OPENCLASH" -eq 1 ]; then
            if ! grep -q "$OPKG_OPENCLASH_REPO" "$OPKG_CONF" 2>/dev/null; then
                echo "$OPKG_OPENCLASH_REPO" >> "$OPKG_CONF"
            fi
            echo -e "✔ 已装载 OpenClash 软件源"
            TARGET_PACKAGES="$TARGET_PACKAGES luci-app-openclash"
        fi
        
        if [ "$UPDATE_PASSWALL" -eq 1 ]; then
            if ! grep -q "$OPKG_PASSWALL_REPO" "$OPKG_CONF" 2>/dev/null; then
                echo "$OPKG_PASSWALL_REPO" >> "$OPKG_CONF"
            fi
            echo -e "✔ 已装载 Passwall 软件源"
            TARGET_PACKAGES="$TARGET_PACKAGES luci-app-passwall"
        fi

        echo -e "\n${GREEN}[2/3] 正在更新 OPKG 软件源列表...${PLAIN}"
        opkg update

        echo -e "\n${GREEN}[3/3] 正在升级选中插件: ${TARGET_PACKAGES}${PLAIN}"
        opkg install $TARGET_PACKAGES || opkg upgrade $TARGET_PACKAGES
    
    # ---------------- APK 模式 ----------------
    elif [ "$SELECTED_MANAGER" = "apk" ]; then
        if ! command -v apk >/dev/null 2>&1; then
            echo -e "${RED}致命错误: 当前系统不存在 apk 命令！强制运行失败。${PLAIN}"
            exit 1
        fi
        
        APK_CONF="/etc/apk/repositories"
        echo -e "\n${GREEN}[1/3] 正在检查并注入 APK 软件源...${PLAIN}"
        
        if [ "$UPDATE_OPENCLASH" -eq 1 ]; then
            if ! grep -q "$APK_OPENCLASH_REPO" "$APK_CONF" 2>/dev/null; then
                echo "$APK_OPENCLASH_REPO" >> "$APK_CONF"
            fi
            echo -e "✔ 已装载 OpenClash 软件源"
            TARGET_PACKAGES="$TARGET_PACKAGES luci-app-openclash"
        fi
        
        if [ "$UPDATE_PASSWALL" -eq 1 ]; then
            if ! grep -q "$APK_PASSWALL_REPO" "$APK_CONF" 2>/dev/null; then
                echo "$APK_PASSWALL_REPO" >> "$APK_CONF"
            fi
            echo -e "✔ 已装载 Passwall 软件源"
            TARGET_PACKAGES="$TARGET_PACKAGES luci-app-passwall"
        fi

        echo -e "\n${GREEN}[2/3] 正在更新 APK 软件源列表...${PLAIN}"
        apk update --allow-untrusted

        echo -e "\n${GREEN}[3/3] 正在升级选中插件: ${TARGET_PACKAGES}${PLAIN}"
        apk add -u --allow-untrusted $TARGET_PACKAGES
    fi
    
    restart_services
}

# 5. 重启相关服务
restart_services() {
    echo -e "\n${GREEN}正在重启相关服务以应用新版本核心...${PLAIN}"
    
    if [ "$UPDATE_OPENCLASH" -eq 1 ] && [ -f "/etc/init.d/openclash" ]; then
        /etc/init.d/openclash restart >/dev/null 2>&1
        echo -e "✔ OpenClash 服务已重启"
    fi

    if [ "$UPDATE_PASSWALL" -eq 1 ] && [ -f "/etc/init.d/passwall" ]; then
        /etc/init.d/passwall restart >/dev/null 2>&1
        echo -e "✔ Passwall 服务已重启"
    fi

    echo -e "\n${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}           🎉 所有更新任务已完成!           ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    exit 0
}

# 3. 插件选择菜单
plugin_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        echo -e "${CYAN}   目标架构: OPKG 模式 | 请选择更新目标   ${PLAIN}"
    else
        echo -e "${CYAN}   目标架构: APK 模式  | 请选择更新目标   ${PLAIN}"
    fi
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 仅更新 ${YELLOW}OpenClash${PLAIN}"
    echo -e "${GREEN}2.${PLAIN} 仅更新 ${YELLOW}Passwall${PLAIN}"
    echo -e "${GREEN}3.${PLAIN} 同时更新 ${YELLOW}OpenClash${PLAIN} 和 ${YELLOW}Passwall${PLAIN} (默认)"
    echo -e "${GREEN}0.${PLAIN} 返回上级菜单"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请选择操作 [0-3]: " PLUGIN_CHOICE
    
    case "$PLUGIN_CHOICE" in
        1)
            UPDATE_OPENCLASH=1
            UPDATE_PASSWALL=0
            execute_update
            ;;
        2)
            UPDATE_OPENCLASH=0
            UPDATE_PASSWALL=1
            execute_update
            ;;
        3|"")
            UPDATE_OPENCLASH=1
            UPDATE_PASSWALL=1
            execute_update
            ;;
        0)
            start_menu
            ;;
        *)
            echo -e "${RED}输入无效，请重新选择！${PLAIN}"
            sleep 1
            plugin_menu
            ;;
    esac
}

# 2. 初始架构交互菜单
start_menu() {
    auto_detect_env
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}   OpenWrt 插件更新与源注入工具 (双源版)  ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "智能探针已侦测到当前系统环境为:"
    echo -e "👉 ${YELLOW}${DETECTED_OS_DESC}${PLAIN}"
    echo -e "------------------------------------------"
    
    if [ "$DETECTED_MANAGER" = "apk" ]; then
        echo -e "${GREEN}1.${PLAIN} 使用默认设定 (自动进入 ${CYAN}APK 模式${PLAIN})"
    elif [ "$DETECTED_MANAGER" = "opkg" ]; then
        echo -e "${GREEN}1.${PLAIN} 使用默认设定 (自动进入 ${CYAN}OPKG 模式${PLAIN})"
    else
        echo -e "${RED}1. 使用默认设定 (系统检测失败，无法使用默认)${PLAIN}"
    fi
    
    echo -e "${GREEN}2.${PLAIN} 手动强制使用 ${YELLOW}OPKG 模式${PLAIN} (适合 23.xx 及更早版本固件)"
    echo -e "${GREEN}3.${PLAIN} 手动强制使用 ${YELLOW}APK 模式${PLAIN}  (适合 24.10 / 25.10 及未来固件)"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请选择操作 [0-3]: " MENU_CHOICE
    
    case "$MENU_CHOICE" in
        1) 
            if [ "$DETECTED_MANAGER" = "apk" ] || [ "$DETECTED_MANAGER" = "opkg" ]; then
                SELECTED_MANAGER="$DETECTED_MANAGER"
                plugin_menu
            else
                echo -e "${RED}未能检测到包管理器，请手动选择！${PLAIN}"
                sleep 2; start_menu
            fi
            ;;
        2) 
            SELECTED_MANAGER="opkg"
            plugin_menu 
            ;;
        3) 
            SELECTED_MANAGER="apk"
            plugin_menu 
            ;;
        0) 
            echo -e "${GREEN}已取消。${PLAIN}"; exit 0 
            ;;
        *) 
            echo -e "${RED}输入无效，请重新选择！${PLAIN}"; sleep 1; start_menu 
            ;;
    esac
}

# 脚本入口
start_menu
