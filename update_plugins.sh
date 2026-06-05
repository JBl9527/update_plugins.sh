#!/bin/sh

# ==========================================
# OpenWrt 插件官方直连极速追新脚本 (终极双轨版)
# 特性: 官方 GitHub 直连拉取 / 智能回退 / 全自动依赖补全
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
# 自动抓取当前路由器的 CPU 架构 (例如 x86_64, aarch64_generic)
ARCH=$(grep "OPENWRT_ARCH" /etc/os-release | awk -F '"' '{print $2}')

# === 🚀 官方 GitHub API 接口 ===
OC_API="https://api.github.com/repos/vernesong/OpenClash/releases"
PW_API="https://api.github.com/repos/xiaorouji/openwrt-passwall/releases"

# === 🚀 核心依赖补给站 (仅用于补齐官方包所需的底层依赖) ===
OPKG_REPO="src/gz custom_plugins https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9"
APK_REPO="https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9"
PUB_KEY_URL="https://dl.openwrt.ai/latest/public-key.pub"

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

# 抓取官方 GitHub 最新直链的核心函数
get_latest_github_url() {
    local api=$1
    local regex=$2
    # 通过 curl 抓取 API，利用纯英文正则精准匹配下载直链
    curl -sL "$api" | grep -o "$regex" | head -n 1
}

execute_update() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        echo -e "${CYAN}      正在执行 OPKG 模式官方直连更新流程  ${PLAIN}"
    else
        echo -e "${CYAN}      正在执行 APK 模式官方直连更新流程   ${PLAIN}"
    fi
    echo -e "${CYAN}==========================================${PLAIN}"
    
    # ---------------- 第一步：挂载依赖补给站 ----------------
    echo -e "\n${GREEN}[1/3] 正在挂载底层依赖补给站 (用于自动解决依赖缺失)...${PLAIN}"
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        OPKG_CONF="/etc/opkg/customfeeds.conf"
        OPKG_MAIN_CONF="/etc/opkg.conf"
        sed -i '/githubusercontent/d' "$OPKG_CONF" 2>/dev/null
        wget -qO - "$PUB_KEY_URL" | opkg-key add - >/dev/null 2>&1
        if ! grep -q "$OPKG_REPO" "$OPKG_CONF" 2>/dev/null; then echo "$OPKG_REPO" >> "$OPKG_CONF"; fi
        # 临时关闭强制安全签名，防止第三方源报错
        sed -i 's/option check_signature/#option check_signature/g' "$OPKG_MAIN_CONF"
        opkg update >/dev/null 2>&1
    elif [ "$SELECTED_MANAGER" = "apk" ]; then
        APK_CONF="/etc/apk/repositories"
        sed -i '/githubusercontent/d' "$APK_CONF" 2>/dev/null
        if ! grep -q "$APK_REPO" "$APK_CONF" 2>/dev/null; then echo "$APK_REPO" >> "$APK_CONF"; fi
        apk update --allow-untrusted >/dev/null 2>&1
    fi
    echo -e "✔ 依赖补给站装载完毕。"

    # ---------------- 第二步：更新 OpenClash ----------------
    if [ "$UPDATE_OPENCLASH" -eq 1 ]; then
        echo -e "\n${GREEN}[2/3] 正在向原作者 GitHub 请求 OpenClash 最新安装包...${PLAIN}"
        if [ "$SELECTED_MANAGER" = "apk" ]; then
            URL=$(get_latest_github_url "$OC_API" "https://[^\"]*luci-app-openclash[^\"]*\.apk")
            FILE="/tmp/openclash.apk"
        else
            URL=$(get_latest_github_url "$OC_API" "https://[^\"]*luci-app-openclash[^\"]*_all\.ipk")
            FILE="/tmp/openclash.ipk"
        fi
        
        if [ -n "$URL" ]; then
            echo -e "✔ 成功获取官方第一手最新版: ${YELLOW}$(basename "$URL")${PLAIN}"
            wget -qO "$FILE" "$URL"
            if [ "$SELECTED_MANAGER" = "apk" ]; then
                apk add -u --allow-untrusted --force-overwrite "$FILE"
            else
                opkg install --force-overwrite --force-checksum "$FILE"
            fi
            rm -f "$FILE"
        else
            echo -e "${YELLOW}⚠️ 原作者尚未发布适用于此架构的最新包，转为使用公共源拉取次新版...${PLAIN}"
            if [ "$SELECTED_MANAGER" = "apk" ]; then
                apk add -u --allow-untrusted --force-overwrite luci-app-openclash
            else
                opkg install --force-overwrite --force-checksum luci-app-openclash || opkg upgrade --force-overwrite --force-checksum luci-app-openclash
            fi
        fi
    fi

    # ---------------- 第三步：更新 Passwall ----------------
    if [ "$UPDATE_PASSWALL" -eq 1 ]; then
        echo -e "\n${GREEN}[3/3] 正在向原作者 GitHub 请求 Passwall 最新安装包...${PLAIN}"
        if [ "$SELECTED_MANAGER" = "apk" ]; then
            URL=$(get_latest_github_url "$PW_API" "https://[^\"]*luci-app-passwall[^\"]*\.apk")
            FILE="/tmp/passwall.apk"
        else
            URL=$(get_latest_github_url "$PW_API" "https://[^\"]*luci-app-passwall[^\"]*_all\.ipk")
            FILE="/tmp/passwall.ipk"
        fi
        
        if [ -n "$URL" ]; then
            echo -e "✔ 成功获取官方第一手最新版: ${YELLOW}$(basename "$URL")${PLAIN}"
            wget -qO "$FILE" "$URL"
            if [ "$SELECTED_MANAGER" = "apk" ]; then
                apk add -u --allow-untrusted --force-overwrite "$FILE"
            else
                opkg install --force-overwrite --force-checksum "$FILE"
            fi
            rm -f "$FILE"
        else
            echo -e "${YELLOW}⚠️ 原作者尚未发布适用于此架构的最新包 (可能未提供APK)，转为使用公共源拉取编译版...${PLAIN}"
            if [ "$SELECTED_MANAGER" = "apk" ]; then
                apk add -u --allow-untrusted --force-overwrite luci-app-passwall
            else
                opkg install --force-overwrite --force-checksum luci-app-passwall || opkg upgrade --force-overwrite --force-checksum luci-app-passwall
            fi
        fi
    fi
    
    # OPKG 模式恢复安全签名校验
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF"
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
    echo -e "${GREEN}      🎉 官方第一手版本已部署完毕!        ${PLAIN}"
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
    echo -e "${GREEN}1.${PLAIN} 仅拉取更新 ${YELLOW}OpenClash${PLAIN}"
    echo -e "${GREEN}2.${PLAIN} 仅拉取更新 ${YELLOW}Passwall${PLAIN}"
    echo -e "${GREEN}3.${PLAIN} 同时拉取更新 ${YELLOW}两者${PLAIN} (默认推荐)"
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
    echo -e "${CYAN} OpenWrt 官方直连极速追新脚本 (带智能依赖) ${PLAIN}"
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
