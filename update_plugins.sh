#!/bin/sh

# ==========================================
# OpenWrt 插件全自动极速更新脚本 (终极除错版)
# 特性: 清理废弃死链 / 绕过无签名源 / 全自动解决依赖
# 支持: OPKG (< 24.10) & APK (24.10 / 25.10+)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

SELECTED_MANAGER=""
UPDATE_OPENCLASH=0
UPDATE_PASSWALL=0
# 获取 CPU 架构
ARCH=$(grep "OPENWRT_ARCH" /etc/os-release | awk -F '"' '{print $2}')

# === 🚀 核心公共源 (Kiddin9 / OpenWrt.ai) ===
OPKG_REPO="src/gz custom_plugins https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9"
APK_REPO="https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9"

# ==========================================================

auto_detect_env() {
    if command -v apk >/dev/null 2>&1; then
        DETECTED_MANAGER="apk"
        DETECTED_OS_DESC="新版 OpenWrt 24.10/25.10+ (APK架构: ${ARCH})"
    elif command -v opkg >/dev/null 2>&1; then
        DETECTED_MANAGER="opkg"
        DETECTED_OS_DESC="经典 OpenWrt 23.xx及以下 (OPKG架构: ${ARCH})"
    else
        DETECTED_MANAGER="unknown"
        DETECTED_OS_DESC="未知架构"
    fi
}

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
        OPKG_CONF="/etc/opkg/customfeeds.conf"
        OPKG_MAIN_CONF="/etc/opkg.conf"
        
        echo -e "\n${GREEN}[1/3] 正在清理历史死链并挂载最新源...${PLAIN}"
        # 1. 暴力清除以前脚本残留的假链接
        sed -i '/你的用户名/d' "$OPKG_CONF" 2>/dev/null
        
        # 2. 写入最新的 kiddin9 源
        if ! grep -q "$OPKG_REPO" "$OPKG_CONF" 2>/dev/null; then
            echo "$OPKG_REPO" >> "$OPKG_CONF"
        fi
        
        if [ "$UPDATE_OPENCLASH" -eq 1 ]; then TARGET_PACKAGES="$TARGET_PACKAGES luci-app-openclash"; fi
        if [ "$UPDATE_PASSWALL" -eq 1 ]; then TARGET_PACKAGES="$TARGET_PACKAGES luci-app-passwall"; fi

        echo -e "\n${GREEN}[2/3] 正在绕过签名验证并更新软件源列表...${PLAIN}"
        # 临时注释掉 opkg.conf 里的签名强制校验，防止 kiddin9 无签名报错
        sed -i 's/option check_signature/#option check_signature/g' "$OPKG_MAIN_CONF"
        
        opkg update

        echo -e "\n${GREEN}[3/3] 正在极速升级选中插件: ${TARGET_PACKAGES}${PLAIN}"
        opkg install --force-overwrite --force-checksum $TARGET_PACKAGES || opkg upgrade --force-overwrite --force-checksum $TARGET_PACKAGES
        
        # 恢复系统的安全签名校验，保证系统日后安全
        sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF"
    
    # ---------------- APK 模式 ----------------
    elif [ "$SELECTED_MANAGER" = "apk" ]; then
        APK_CONF="/etc/apk/repositories"
        
        echo -e "\n${GREEN}[1/3] 正在清理历史死链并挂载最新源...${PLAIN}"
        # 1. 暴力清除以前脚本残留的假链接
        sed -i '/你的用户名/d' "$APK_CONF" 2>/dev/null
        
        # 2. 写入最新的 kiddin9 源
        if ! grep -q "$APK_REPO" "$APK_CONF" 2>/dev/null; then
            echo "$APK_REPO" >> "$APK_CONF"
        fi
        
        if [ "$UPDATE_OPENCLASH" -eq 1 ]; then TARGET_PACKAGES="$TARGET_PACKAGES luci-app-openclash"; fi
        if [ "$UPDATE_PASSWALL" -eq 1 ]; then TARGET_PACKAGES="$TARGET_PACKAGES luci-app-passwall"; fi

        echo -e "\n${GREEN}[2/3] 正在更新 APK 软件源列表...${PLAIN}"
        apk update --allow-untrusted

        echo -e "\n${GREEN}[3/3] 正在极速升级选中插件: ${TARGET_PACKAGES}${PLAIN}"
        apk add -u --allow-untrusted --force-overwrite $TARGET_PACKAGES
    fi
    
    restart_services
}

restart_services() {
    echo -e "\n${GREEN}正在重启相关服务以应用新版本核心...${PLAIN}"
    
    if [ "$UPDATE_OPENCLASH" -eq 1 ] && [ -f "/etc/init.d/openclash" ]; then
        /etc/init.d/openclash restart >/dev/null 2>&1
        echo -e "✔ OpenClash 服务已平滑重启"
    fi

    if [ "$UPDATE_PASSWALL" -eq 1 ] && [ -f "/etc/init.d/passwall" ]; then
        /etc/init.d/passwall restart >/dev/null 2>&1
        echo -e "✔ Passwall 服务已平滑重启"
    fi

    echo -e "\n${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}         🎉 垃圾已清理，所有更新已完成!         ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    exit 0
}

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
    echo -e "${GREEN}3.${PLAIN} 同时更新 ${YELLOW}两者${PLAIN} (默认推荐)"
    echo -e "${GREEN}0.${PLAIN} 返回上级菜单"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请选择操作 [0-3]: " PLUGIN_CHOICE
    
    case "$PLUGIN_CHOICE" in
        1) UPDATE_OPENCLASH=1; UPDATE_PASSWALL=0; execute_update ;;
        2) UPDATE_OPENCLASH=0; UPDATE_PASSWALL=1; execute_update ;;
        3|"") UPDATE_OPENCLASH=1; UPDATE_PASSWALL=1; execute_update ;;
        0) start_menu ;;
        *) echo -e "${RED}输入无效！${PLAIN}"; sleep 1; plugin_menu ;;
    esac
}

start_menu() {
    auto_detect_env
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN} OpenWrt 插件极速更新工具 (防报错智能版)   ${PLAIN}"
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
    
    echo -e "${GREEN}2.${PLAIN} 手动强制使用 ${YELLOW}OPKG 模式${PLAIN} (< 23.xx)"
    echo -e "${GREEN}3.${PLAIN} 手动强制使用 ${YELLOW}APK 模式${PLAIN}  (>= 24.10)"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请选择操作 [0-3]: " MENU_CHOICE
    
    case "$MENU_CHOICE" in
        1) 
            if [ "$DETECTED_MANAGER" = "apk" ] || [ "$DETECTED_MANAGER" = "opkg" ]; then
                SELECTED_MANAGER="$DETECTED_MANAGER"
                plugin_menu
            else
                echo -e "${RED}未能检测到包管理器，请手动选择！${PLAIN}"; sleep 2; start_menu
            fi ;;
        2) SELECTED_MANAGER="opkg"; plugin_menu ;;
        3) SELECTED_MANAGER="apk"; plugin_menu ;;
        0) echo -e "${GREEN}已取消。${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}输入无效，请重新选择！${PLAIN}"; sleep 1; start_menu ;;
    esac
}

start_menu
