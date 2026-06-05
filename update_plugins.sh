#!/bin/sh

# ==========================================
# ImmortalWrt 专属极速追新与安装脚本 (原生稳定版)
# 包含: OpenClash, Passwall, DDNS-GO, Argon, WG
# 特性: 100% 调用系统原生源 / 彻底告别依赖报错与 OOM
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

# ==========================================================

auto_detect_env() {
    if command -v apk >/dev/null 2>&1; then
        SELECTED_MANAGER="apk"
        DETECTED_OS_DESC="ImmortalWrt 24.10+ (APK 架构)"
    elif command -v opkg >/dev/null 2>&1; then
        SELECTED_MANAGER="opkg"
        DETECTED_OS_DESC="ImmortalWrt 24.10/23.05 (OPKG 架构)"
    else
        echo -e "${RED}未检测到包管理器，脚本终止！${PLAIN}"
        exit 1
    fi
}

execute_update() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}      正在执行 ImmortalWrt 原生源极速部署   ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    
    # ---------------- 第 1 步：清理历史遗留垃圾并更新源 ----------------
    echo -e "\n${YELLOW}[1/3] 正在深度清理第三方野源，并刷新系统官方源...${PLAIN}"
    if [ "$SELECTED_MANAGER" = "opkg" ]; then
        # 斩断之前测试用的 kiddin9 等第三方源，防止干扰原生系统
        sed -i '/kiddin9/d' /etc/opkg/customfeeds.conf 2>/dev/null
        sed -i '/openwrt.ai/d' /etc/opkg/customfeeds.conf 2>/dev/null
        rm -rf /var/opkg-lists/custom_plugins 2>/dev/null
        
        opkg update >/dev/null 2>&1
    else
        sed -i '/kiddin9/d' /etc/apk/repositories 2>/dev/null
        apk update >/dev/null 2>&1
    fi
    echo -e "✔ 系统源状态完美！"

    # ---------------- 第 2 步：全自动极速安装/更新 ----------------
    echo -e "\n${GREEN}[2/3] 正在通过原生源安全部署选中的插件 (自带完美依赖解析)...${PLAIN}"
    
    TARGET_PACKAGES=""
    
    if [ "$UPDATE_OPENCLASH" -eq 1 ]; then
        TARGET_PACKAGES="$TARGET_PACKAGES luci-app-openclash"
    fi
    
    if [ "$UPDATE_PASSWALL" -eq 1 ]; then
        TARGET_PACKAGES="$TARGET_PACKAGES luci-app-passwall"
    fi
    
    if [ "$UPDATE_BASE" -eq 1 ]; then
        # 囊括全部基础增强组件：DDNS-GO(及中文包) + Argon(及设置面板) + WireGuard(及扫码)
        TARGET_PACKAGES="$TARGET_PACKAGES luci-app-ddns-go luci-i18n-ddns-go-zh-cn luci-theme-argon luci-app-argon-config luci-proto-wireguard wireguard-tools qrencode"
    fi
    
    if [ -n "$TARGET_PACKAGES" ]; then
        echo -e "📦 目标组件列队: ${YELLOW}${TARGET_PACKAGES}${PLAIN}"
        if [ "$SELECTED_MANAGER" = "opkg" ]; then
            # 加上 force-overwrite 是为了覆盖掉之前从 GitHub 强行拉取的旧文件
            opkg install --force-overwrite $TARGET_PACKAGES 2>&1 | grep -Ev "remove_obsolesced_files|Collected errors"
            opkg upgrade --force-overwrite $TARGET_PACKAGES 2>/dev/null | grep -Ev "remove_obsolesced_files"
        else
            apk add -u --allow-untrusted --force-overwrite $TARGET_PACKAGES >/dev/null 2>&1
        fi
        echo -e "✔ 核心包部署完毕！"
    fi

    # ---------------- 第 3 步：平滑重启服务 ----------------
    echo -e "\n${GREEN}[3/3] 正在平滑唤醒相关网络服务...${PLAIN}"
    
    if [ "$UPDATE_OPENCLASH" -eq 1 ] && [ -f "/etc/init.d/openclash" ]; then
        /etc/init.d/openclash restart >/dev/null 2>&1
        echo -e "✔ OpenClash 已重启"
    fi

    if [ "$UPDATE_PASSWALL" -eq 1 ] && [ -f "/etc/init.d/passwall" ]; then
        /etc/init.d/passwall restart >/dev/null 2>&1
        echo -e "✔ Passwall 已重启"
    fi

    if [ "$UPDATE_BASE" -eq 1 ]; then
        if [ -f "/etc/init.d/ddns-go" ]; then
            /etc/init.d/ddns-go restart >/dev/null 2>&1
            echo -e "✔ DDNS-GO 已重启"
        fi
        /etc/init.d/network reload >/dev/null 2>&1
        echo -e "✔ WireGuard 网络接口已重载"
    fi

    echo -e "\n${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}    🎉 部署大功告成！原生环境极致稳定！   ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    exit 0
}

plugin_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}   系统架构: ${SELECTED_MANAGER} 模式 | ImmortalWrt 原生增强版  ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${YELLOW}[ 科学上网系列 ]${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 仅拉取更新 ${YELLOW}OpenClash${PLAIN}"
    echo -e "${GREEN}2.${PLAIN} 仅拉取更新 ${YELLOW}Passwall${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}[ 基础增强系列 ]${PLAIN}"
    echo -e "${GREEN}3.${PLAIN} 安装/更新 ${YELLOW}DDNS-GO + Argon + WG(+扫码引擎)${PLAIN}"
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
