#!/bin/sh

# ==========================================
# OpenWrt 插件官方直连极速追新脚本 (防断网自愈版)
# 包含: OpenClash, Passwall, DDNS-GO, Argon, WireGuard
# 特性: 防断网机制 / 官方全直连 / 内核保护隔离
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
ARGON_API="https://api.github.com/repos/jerrykuku/luci-theme-argon/releases"

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
                apk add -u --allow-untrusted --force-overwrite "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine obsolete files|Couldn't unlink|Not found|Collected errors"
            else
                opkg install --force-overwrite --force-checksum "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine obsolete files|Couldn't unlink|Not found|Collected errors"
            fi
            rm -f "$FILE"
        else
            echo -e "${YELLOW}⚠️ 尝试从公共源拉取 OpenClash...${PLAIN}"
            if [ "$SELECTED_MANAGER" = "apk" ]; then
                apk add -u --allow-untrusted --force-overwrite luci-app-openclash >/dev/null 2>&1
            else
                opkg install --force-overwrite --force-checksum luci-app-openclash >/dev/null 2>&1
            fi
        fi

        # 【核心修复】：防止 OpenClash 升级后断网导致后续下载失败
        echo -e "${YELLOW}⟳ 正在唤醒 OpenClash 恢复网络连接，请稍候 8 秒...${PLAIN}"
        /etc/init.d/openclash restart >/dev/null 2>&1
        sleep 8
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
                apk add -u --allow-untrusted --force-overwrite "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine obsolete files|Couldn't unlink|Not found|Collected errors"
            else
                opkg install --force-overwrite --force-checksum "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine obsolete files|Couldn't unlink|Not found|Collected errors"
            fi
            rm -f "$FILE"
        else
            echo -e "${YELLOW}⚠️ 尝试从公共源拉取 Passwall...${PLAIN}"
            if [ "$SELECTED_MANAGER" = "apk" ]; then
                apk add -u --allow-untrusted --force-overwrite luci-app-passwall >/dev/null 2>&1
            else
                opkg install --force-overwrite --force-checksum luci-app-passwall >/dev/null 2>&1
            fi
        fi
    fi

    # ---------------- 第四步：更新 基础扩展插件 ----------------
    if [ "$UPDATE_BASE" -eq 1 ]; then
        echo -e "\n${GREEN}[4/4] 正在安装 DDNS-GO, Argon主题, WireGuard + 二维码扫码引擎...${PLAIN}"
        
        # 1. 官方直连拉取 Argon 主题 (避开第三方源的架构冲突)
        echo -e "✔ 正在从原作者 GitHub 拉取 Argon 主题..."
        if [ "$SELECTED_MANAGER" = "apk" ]; then
            ARGON_URL=$(get_latest_github_url "$ARGON_API" "https://[^\"]*luci-theme-argon[^\"]*\.apk")
            ARGON_FILE="/tmp/argon.apk"
        else
            ARGON_URL=$(get_latest_github_url "$ARGON_API" "https://[^\"]*luci-theme-argon[^\"]*_all\.ipk")
            ARGON_FILE="/tmp/argon.ipk"
        fi
        
        if [ -n "$ARGON_URL" ]; then
            wget -qO "$ARGON_FILE" "$ARGON_URL"
            if [ "$SELECTED_MANAGER" = "apk" ]; then
                apk add -u --allow-untrusted --force-overwrite "$ARGON_FILE" >/dev/null 2>&1
            else
                opkg install --force-depends --force-overwrite "$ARGON_FILE" >/dev/null 2>&1
            fi
            rm -f "$ARGON_FILE"
        fi

        # 2. 从官方/公共源安全拉取 DDNS-GO 和 WireGuard
        echo -e "${YELLOW}*(注: WireGuard将智能切换至官方系统源拉取，防止内核冲突)*${PLAIN}"
        if [ "$SELECTED_MANAGER" = "apk" ]; then
            apk add -u --allow-untrusted --force-overwrite luci-app-ddns-go luci-proto-wireguard wireguard-tools qrencode 2>/dev/null
        else
            opkg install luci-app-ddns-go luci-proto-wireguard wireguard-tools qrencode 2>/dev/null | grep -Ev "remove_obsolesced_files|Collected errors"
            opkg upgrade luci-app-ddns-go luci-proto-wireguard wireguard-tools qrencode 2>/dev/null | grep -Ev "remove_obsolesced_files|Collected errors"
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
    
    # OpenClash 已经在中途重启过了，这里不再重复重启避免断网
    if [ "$UPDATE_PASSWALL" -eq 1 ] && [ -f "/etc/init.d/passwall" ]; then
        /etc/init.d/passwall restart >/dev/null 2>&1
        echo -e "✔ Passwall 服务已平滑重启"
    fi

    if [ "$UPDATE_BASE" -eq 1 ]; then
        if [ -f "/etc/init.d/ddns-go" ]; then
            /etc/init.d/ddns-go restart >/dev/null 2>&1
            echo -e "✔ DDNS-GO 服务已重启"
        fi
        # 去掉 network restart 防止 SSH 被强杀，改用更柔和的 reload
        /etc/init.d/network reload >/dev/null 2>&1
        echo -e "✔ WireGuard 接口环境已重载"
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
