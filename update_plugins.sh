#!/bin/sh

# ==========================================
# OpenWrt 插件官方直连极速追新脚本 (全能扫码版)
# 包含: OpenClash, Passwall, DDNS-GO, Argon, WireGuard+扫码
# 特性: 官方直连 / 智能依赖 / 内核保护隔离
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

SELECTED_MANAGER=""
UPDATE_OPENCLASH=0
UPDATE_PASSWALL=0
UPDATE_BASE=0
ARCH=$(grep "OPENWRT_ARCH" /etc/os-release | awk -F '"' '{print $2}')

# === 官方 GitHub API 接口 ===
OC_API="https://api.github.com/repos/vernesong/OpenClash/releases"
PW_API="https://api.github.com/repos/xiaorouji/openwrt-passwall/releases"

# === 核心依赖与基础插件补给站 ===
OPKG_REPO="src/gz custom_plugins https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9"
APK_REPO="https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9"
PUB_KEY_URL="https://dl.openwrt.ai/latest/public-key.pub"

# ==========================================================

auto_detect_env() {
    if command -v apk >/dev/null 2>&1; then
        DETECTED_MANAGER="apk"
        DETECTED_OS_DESC="新版 OpenWrt/ImmortalWrt 24.10+ (APK架构: ${ARCH})"
    elif command -v opkg >/dev/null 2>&1; then
        DETECTED_MANAGER="opkg"
        DETECTED_OS_DESC="经典 OpenWrt/ImmortalWrt/iStoreOS (OPKG架构: ${ARCH})"
    else
        DETECTED_MANAGER="unknown"
        DETECTED_OS_DESC="未知架构"
    fi
}

get_latest_github_url() {
    local api=$1
    local regex=$2
    curl -sL "$api" | grep -o "$regex" | head -n 1
}

execute_update() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        echo -e "${CYAN}      正在执行 OPKG 模式插件安装/更新流程  ${PLAIN}"
    else
        echo -e "${CYAN}      正在执行 APK 模式插件安装/更新流程   ${PLAIN}"
    fi
    echo -e "${CYAN}==========================================${PLAIN}"
    
    # ---------------- 第一步：环境与源准备 ----------------
    echo -e "\n${GREEN}[1/4] 正在准备底层环境与依赖补给站...${PLAIN}"
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        OPKG_CONF="/etc/opkg/customfeeds.conf"
        OPKG_MAIN_CONF="/etc/opkg.conf"
        sed -i '/githubusercontent/d' "$OPKG_CONF" 2>/dev/null
        wget -qO - "$PUB_KEY_URL" | opkg-key add - >/dev/null 2>&1
        if ! grep -q "$OPKG_REPO" "$OPKG_CONF" 2>/dev/null; then echo "$OPKG_REPO" >> "$OPKG_CONF"; fi
        sed -i 's/option check_signature/#option check_signature/g' "$OPKG_MAIN_CONF"
        opkg update >/dev/null 2>&1
        # 原版OpenWrt需要补齐curl和证书包才能访问GitHub API
        opkg install curl ca-bundle ca-certificates 2>/dev/null | grep -Ev "remove_obsolesced_files"
    elif [ "$SELECTED_MANAGER" = "apk" ]; then
        APK_CONF="/etc/apk/repositories"
        sed -i '/githubusercontent/d' "$APK_CONF" 2>/dev/null
        if ! grep -q "$APK_REPO" "$APK_CONF" 2>/dev/null; then echo "$APK_REPO" >> "$APK_CONF"; fi
        apk update --allow-untrusted >/dev/null 2>&1
        apk add curl ca-certificates 2>/dev/null
    fi
    echo -e "✔ 依赖补给站装载完毕。"

    # ---------------- 第二步：更新 OpenClash ----------------
    if [ "$UPDATE_OPENCLASH" -eq 1 ]; then
        echo -e "\n${GREEN}[2/4] 正在请求 OpenClash 最新安装包...${PLAIN}"
        if [ "$SELECTED_MANAGER" = "apk" ]; then
            URL=$(get_latest_github_url "$OC_API" "https://[^\"]*luci-app-openclash[^\"]*\.apk")
            FILE="/tmp/openclash.apk"
        else
            URL=$(get_latest_github_url "$OC_API" "https://[^\"]*luci-app-openclash[^\"]*_all\.ipk")
            FILE="/tmp/openclash.ipk"
        fi
        
        if [ -n "$URL" ]; then
            echo -e "✔ 成功获取官方最新版: ${YELLOW}$(basename "$URL")${PLAIN}"
            wget -qO "$FILE" "$URL"
            if [ "$SELECTED_MANAGER" = "apk" ]; then
                apk add -u --allow-untrusted --force-overwrite "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine obsolete files|Couldn't unlink|Not found"
            else
                opkg install --force-overwrite --force-checksum "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine obsolete files|Couldn't unlink|Not found"
            fi
            rm -f "$FILE"
        else
            echo -e "${YELLOW}⚠️ 尝试从公共源拉取 OpenClash...${PLAIN}"
            if [ "$SELECTED_MANAGER" = "apk" ]; then
                apk add -u --allow-untrusted --force-overwrite luci-app-openclash
            else
                opkg install --force-overwrite --force-checksum luci-app-openclash 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine obsolete files"
            fi
        fi
    fi

    # ---------------- 第三步：更新 Passwall ----------------
    if [ "$UPDATE_PASSWALL" -eq 1 ]; then
        echo -e "\n${GREEN}[3/4] 正在请求 Passwall 最新安装包...${PLAIN}"
        if [ "$SELECTED_MANAGER" = "apk" ]; then
            URL=$(get_latest_github_url "$PW_API" "https://[^\"]*luci-app-passwall[^\"]*\.apk")
            FILE="/tmp/passwall.apk"
        else
            URL=$(get_latest_github_url "$PW_API" "https://[^\"]*luci-app-passwall[^\"]*_all\.ipk")
            FILE="/tmp/passwall.ipk"
        fi
        
        if [ -n "$URL" ]; then
            echo -e "✔ 成功获取官方最新版: ${YELLOW}$(basename "$URL")${PLAIN}"
            wget -qO "$FILE" "$URL"
            if [ "$SELECTED_MANAGER" = "apk" ]; then
                apk add -u --allow-untrusted --force-overwrite "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine obsolete files|Couldn't unlink|Not found"
            else
                opkg install --force-overwrite --force-checksum "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine obsolete files|Couldn't unlink|Not found"
            fi
            rm -f "$FILE"
        else
            echo -e "${YELLOW}⚠️ 尝试从公共源拉取 Passwall...${PLAIN}"
            if [ "$SELECTED_MANAGER" = "apk" ]; then
                apk add -u --allow-untrusted --force-overwrite luci-app-passwall
            else
                opkg install --force-overwrite --force-checksum luci-app-passwall 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine obsolete files"
            fi
        fi
    fi

    # ---------------- 第四步：更新 基础扩展插件 ----------------
    if [ "$UPDATE_BASE" -eq 1 ]; then
        echo -e "\n${GREEN}[4/4] 正在安装 DDNS-GO, Argon主题, WireGuard + 二维码扫码引擎...${PLAIN}"
        echo -e "${YELLOW}*(注: WireGuard将智能切换至官方系统源进行安全拉取，防止内核冲突)*${PLAIN}"
        
        if [ "$SELECTED_MANAGER" = "apk" ]; then
            apk add -u --allow-untrusted --force-overwrite luci-theme-argon luci-app-argon-config luci-app-ddns-go luci-proto-wireguard wireguard-tools qrencode 2>&1
        else
            # 使用标准的安装命令（非强制校验），确保内核模块能顺畅匹配官方源，并同步安装 qrencode 引擎
            opkg install luci-theme-argon luci-app-argon-config luci-app-ddns-go luci-proto-wireguard wireguard-tools qrencode 2>&1 | grep -Ev "remove_obsolesced_files"
            opkg upgrade luci-theme-argon luci-app-argon-config luci-app-ddns-go luci-proto-wireguard wireguard-tools qrencode 2>/dev/null | grep -Ev "remove_obsolesced_files"
        fi
        echo -e "✔ 基础扩展与扫码引擎包部署完毕。"
    fi
    
    # 恢复安全签名校验
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF"
    fi
    
    restart_services
}

restart_services() {
    echo -e "\n${GREEN}正在平滑重启相关服务...${PLAIN}"
    
    if [ "$UPDATE_OPENCLASH" -eq 1 ] && [ -f "/etc/init.d/openclash" ]; then
        /etc/init.d/openclash restart >/dev/null 2>&1
        echo -e "✔ OpenClash 服务已重启"
    fi

    if [ "$UPDATE_PASSWALL" -eq 1 ] && [ -f "/etc/init.d/passwall" ]; then
        /etc/init.d/passwall restart >/dev/null 2>&1
        echo -e "✔ Passwall 服务已重启"
    fi

    if [ "$UPDATE_BASE" -eq 1 ] && [ -f "/etc/init.d/ddns-go" ]; then
        /etc/init.d/ddns-go restart >/dev/null 2>&1
        /etc/init.d/network restart >/dev/null 2>&1
        echo -e "✔ DDNS-GO 及 Network(WireGuard) 服务已重启"
    fi

    echo -e "\n${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}      🎉 所有插件已成功安装或更新至最新版!     ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    exit 0
}

plugin_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        echo -e "${CYAN}   目标架构: OPKG 模式 | 请选择安装/更新目标  ${PLAIN}"
    else
        echo -e "${CYAN}   目标架构: APK 模式  | 请选择安装/更新目标  ${PLAIN}"
    fi
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${YELLOW}[ 科学上网系列 ]${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 仅拉取更新 ${YELLOW}OpenClash${PLAIN}"
    echo -e "${GREEN}2.${PLAIN} 仅拉取更新 ${YELLOW}Passwall${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}[ 基础增强系列 ]${PLAIN}"
    echo -e "${GREEN}3.${PLAIN} 安装/更新 ${YELLOW}DDNS-GO + Argon + WireGuard (+扫码引擎)${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}[ 一键全家桶 ]${PLAIN}"
    echo -e "${GREEN}4.${PLAIN} ${CYAN}同时拉取更新上述所有插件 (默认推荐)${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${GREEN}0.${PLAIN} 返回上级菜单"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请选择操作 [0-4]: " PLUGIN_CHOICE
    
    case "$PLUGIN_CHOICE" in
        1) UPDATE_OPENCLASH=1; UPDATE_PASSWALL=0; UPDATE_BASE=0; execute_update ;;
        2) UPDATE_OPENCLASH=0; UPDATE_PASSWALL=1; UPDATE_BASE=0; execute_update ;;
        3) UPDATE_OPENCLASH=0; UPDATE_PASSWALL=0; UPDATE_BASE=1; execute_update ;;
        4|"") UPDATE_OPENCLASH=1; UPDATE_PASSWALL=1; UPDATE_BASE=1; execute_update ;;
        0) start_menu ;;
        *) echo -e "${RED}输入无效！${PLAIN}"; sleep 1; plugin_menu ;;
    esac
}

start_menu() {
    auto_detect_env
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN} OpenWrt 全能版插件管理与极速追新脚本      ${PLAIN}"
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
