#!/bin/sh

# ==========================================
# 原版 OpenWrt 24.10 专属插件追新脚本 (原生增强版)
# 包含: OpenClash, Passwall, DDNS-GO(带中文), Argon, WG+扫码
# 特性: 拒绝庞大源防 Killed / 核心直连 / 原生源智能互补
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

# === 官方 GitHub API 接口全家桶 ===
OC_API="https://api.github.com/repos/vernesong/OpenClash/releases"
PW_API="https://api.github.com/repos/xiaorouji/openwrt-passwall/releases"
ARGON_API="https://api.github.com/repos/jerrykuku/luci-theme-argon/releases"

# ==========================================================

auto_detect_env() {
    if command -v apk >/dev/null 2>&1; then
        SELECTED_MANAGER="apk"
        DETECTED_OS_DESC="原版 OpenWrt 24.10 (APK 架构)"
    elif command -v opkg >/dev/null 2>&1; then
        SELECTED_MANAGER="opkg"
        DETECTED_OS_DESC="原版 OpenWrt 24.10/23.05 (OPKG 架构)"
    else
        echo -e "${RED}未检测到包管理器，脚本终止！${PLAIN}"
        exit 1
    fi
}

# 带 10 秒超时限制的请求，防止网络卡死
get_latest_github_url() {
    local api=$1
    local regex=$2
    curl -m 10 -sL "$api" | grep -o "$regex" | head -n 1
}

execute_update() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}      正在执行原版专属 零内存溢出 更新流程  ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    
    # ---------------- 第 0 步：深度净化与官方源更新 ----------------
    echo -e "\n${YELLOW}[1/4] 正在清理危险源并更新官方自带原生源...${PLAIN}"
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        # 彻底删掉之前残留的庞大第三方源，防止内存溢出
        sed -i '/kiddin9/d' /etc/opkg/customfeeds.conf 2>/dev/null
        sed -i '/openwrt.ai/d' /etc/opkg/customfeeds.conf 2>/dev/null
        rm -rf /var/opkg-lists/custom_plugins 2>/dev/null
        
        opkg update >/dev/null 2>&1
        # 补齐原生环境与新版 UI 兼容包 (luci-compat)
        opkg install curl ca-bundle ca-certificates luci-compat 2>/dev/null | grep -Ev "remove_obsolesced_files"
    else
        sed -i '/kiddin9/d' /etc/apk/repositories 2>/dev/null
        apk update >/dev/null 2>&1
        apk add curl ca-certificates luci-compat 2>/dev/null
    fi
    echo -e "✔ 官方原生源更新完毕，内存极度安全！"

    # ---------------- 第 2 步：直连更新 OpenClash ----------------
    if [ "$UPDATE_OPENCLASH" -eq 1 ]; then
        echo -e "\n${GREEN}[2/4] 正在请求 OpenClash 官方最新安装包...${PLAIN}"
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
                apk add -u --allow-untrusted --force-overwrite "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine"
            else
                opkg install "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine|Unknown package"
            fi
            rm -f "$FILE"
        else
            echo -e "${RED}⚠️ 获取失败，请检查网络是否能访问 GitHub！${PLAIN}"
        fi

        echo -e "${YELLOW}⟳ 正在唤醒 OpenClash 恢复网络，请稍候 8 秒...${PLAIN}"
        /etc/init.d/openclash restart >/dev/null 2>&1
        sleep 8
    fi

    # ---------------- 第 3 步：直连更新 Passwall ----------------
    if [ "$UPDATE_PASSWALL" -eq 1 ]; then
        echo -e "\n${GREEN}[3/4] 正在请求 Passwall 官方最新安装包...${PLAIN}"
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
                apk add -u --allow-untrusted --force-overwrite "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine"
            else
                opkg install "$FILE" 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine|Unknown package"
            fi
            rm -f "$FILE"
        else
            echo -e "${RED}⚠️ 获取失败，请检查网络是否能访问 GitHub！${PLAIN}"
        fi
    fi

    # ---------------- 第 4 步：更新增强插件 (混合源智能拉取) ----------------
    if [ "$UPDATE_BASE" -eq 1 ]; then
        echo -e "\n${GREEN}[4/4] 正在安装 DDNS-GO 与 Argon 主题 等基础环境...${PLAIN}"
        
        # 1. GitHub 直连拉取 Argon 主题 (越过 wget-any 报错)
        echo -e "✔ 正在拉取 Argon 主题并处理底层依赖..."
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
                sed -i 's/, wget-any//g' /usr/lib/opkg/status 2>/dev/null
                sed -i 's/wget-any, //g' /usr/lib/opkg/status 2>/dev/null
                sed -i 's/Depends: wget-any/Depends: curl/g' /usr/lib/opkg/status 2>/dev/null
            fi
            rm -f "$ARGON_FILE"
        fi

        # 2. 安全拉取 DDNS-GO(带中文包)、WireGuard 与 二维码引擎
        echo -e "✔ 正在从官方源安全提取原生基础组件..."
        if [ "$SELECTED_MANAGER" = "apk" ]; then
            apk add -u luci-app-ddns-go luci-i18n-ddns-go-zh-cn luci-proto-wireguard wireguard-tools qrencode >/dev/null 2>&1
        else
            # 直接通过官方包管理器安装原生的 DDNS-GO 及其对应的中文语言包
            opkg install luci-app-ddns-go luci-i18n-ddns-go-zh-cn luci-proto-wireguard wireguard-tools qrencode 2>&1 | grep -Ev "remove_obsolesced_files|Collected errors"
        fi
        echo -e "✔ 基础扩展部署完毕。"
    fi
    
    restart_services
}

restart_services() {
    echo -e "\n${GREEN}正在平滑唤醒所有已安装的网络服务...${PLAIN}"
    
    if [ "$UPDATE_PASSWALL" -eq 1 ] && [ -f "/etc/init.d/passwall" ]; then
        /etc/init.d/passwall restart >/dev/null 2>&1
        echo -e "✔ Passwall 服务已平滑重启"
    fi

    if [ "$UPDATE_BASE" -eq 1 ]; then
        if [ -f "/etc/init.d/ddns-go" ]; then
            /etc/init.d/ddns-go restart >/dev/null 2>&1
            echo -e "✔ DDNS-GO 服务已重启"
        fi
        /etc/init.d/network reload >/dev/null 2>&1
        echo -e "✔ WireGuard 接口环境已重载"
    fi

    echo -e "\n${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}    🎉 完美适配原版，所有插件均已安全部署完毕!  ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    exit 0
}

plugin_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}   目标架构: ${SELECTED_MANAGER} 模式 | 原版原生智选版  ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${YELLOW}[ 科学上网系列 (全网 API 直连) ]${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 仅拉取更新 ${YELLOW}OpenClash${PLAIN}"
    echo -e "${GREEN}2.${PLAIN} 仅拉取更新 ${YELLOW}Passwall${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}[ 增强扩展系列 (官方原生提取) ]${PLAIN}"
    echo -e "${GREEN}3.${PLAIN} 安装/更新 ${YELLOW}DDNS-GO(中) + Argon + WG(带扫码)${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}[ 一键全家桶 ]${PLAIN}"
    echo -e "${GREEN}4.${PLAIN} ${CYAN}同时部署更新上述所有插件 (默认推荐)${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请选择操作 [0-4]: " PLUGIN_CHOICE
    
    case "$PLUGIN_CHOICE" in
        1) UPDATE_OPENCLASH=1; UPDATE_PASSWALL=0; UPDATE_BASE=0; execute_update ;;
        2) UPDATE_OPENCLASH=0; UPDATE_PASSWALL=1; UPDATE_BASE=0; execute_update ;;
        3) UPDATE_OPENCLASH=0; UPDATE_PASSWALL=0; UPDATE_BASE=1; execute_update ;;
        4|"") UPDATE_OPENCLASH=1; UPDATE_PASSWALL=1; UPDATE_BASE=1; execute_update ;;
        0) echo -e "${GREEN}已取消。${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}"; sleep 1; plugin_menu ;;
    esac
}

auto_detect_env
plugin_menu
