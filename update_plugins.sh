#!/bin/sh

# ==========================================
# OpenWrt/ImmortalWrt 24.10+ 永久加源直装脚本
# 特性: 开启256M虚拟内存防Killed / 永久写入三方源 / 自动补全汉化依赖
# 增强: QiuSimons原版可视化DAED / 分离式依赖安装机制
# 支持: OPKG 架构完美适配
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

SELECTED_MANAGER=""
UPDATE_OPENCLASH=0
UPDATE_PASSWALL=0
UPDATE_DAED=0
UPDATE_BASE=0
ARCH=$(grep "OPENWRT_ARCH" /etc/os-release | awk -F '"' '{print $2}')

# === 核心源 (用于解决底层组件、内核及 eBPF 依赖) ===
OPKG_REPO="src/gz custom_plugins https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9"
PUB_KEY_URL="https://dl.openwrt.ai/latest/public-key.pub"

# ==========================================================

auto_detect_env() {
    if command -v opkg >/dev/null 2>&1; then
        SELECTED_MANAGER="opkg"
    else
        echo -e "${RED}致命错误: 本脚本专门针对 OPKG 架构系统优化，未检测到 opkg，流程终止！${PLAIN}"
        exit 1
    fi
}

execute_update() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}   正在执行 虚拟内存保卫 & 永久写入软件源 流程  ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    
    # ---------------- 第 0 步：挂载 256MB 虚拟内存 ----------------
    echo -e "\n${YELLOW}[0/5] 正在利用闲置磁盘临时构建 256MB 虚拟内存保障库...${PLAIN}"
    rm -f /var/lock/opkg.lock
    swapoff /root/swapfile >/dev/null 2>&1
    rm -f /root/swapfile >/dev/null 2>&1
    
    dd if=/dev/zero of=/root/swapfile bs=1M count=256 >/dev/null 2>&1
    if [ -f "/root/swapfile" ]; then
        mkswap /root/swapfile >/dev/null 2>&1
        swapon /root/swapfile >/dev/null 2>&1
        echo -e "✔ 256MB 虚拟内存挂载成功！"
    else
        echo -e "${RED}❌ 虚拟内存构建失败，转为常规模式。${PLAIN}"
    fi

    # ---------------- 第 1 步：注入系统软件源配置 ----------------
    echo -e "\n${GREEN}[1/5] 正在注入全功能底层软件源...${PLAIN}"
    OPKG_CONF="/etc/opkg/customfeeds.conf"
    OPKG_MAIN_CONF="/etc/opkg.conf"
    
    wget -qO - "$PUB_KEY_URL" | opkg-key add - >/dev/null 2>&1
    sed -i '/githubusercontent/d' "$OPKG_CONF" 2>/dev/null
    sed -i '/你的用户名/d' "$OPKG_CONF" 2>/dev/null
    
    if ! grep -q "custom_plugins" "$OPKG_CONF" 2>/dev/null; then
        echo "$OPKG_REPO" >> "$OPKG_CONF"
    fi
    echo -e "✔ 源配置写入完毕！"

    # ---------------- 第 2 步：刷新软件源索引 ----------------
    echo -e "\n${GREEN}[2/5] 正在安全刷新软件列表...${PLAIN}"
    sed -i 's/option check_signature/#option check_signature/g' "$OPKG_MAIN_CONF"
    opkg update
    echo -e "✔ 软件源列表全部同步完毕！"

    # ---------------- 第 3 步：安装底层依赖与常规核心 ----------------
    echo -e "\n${GREEN}[3/5] 正在从源批量安装底层核心组件与常规插件...${PLAIN}"
    
    TARGET_PACKAGES=""
    [ "$UPDATE_OPENCLASH" -eq 1 ] && TARGET_PACKAGES="$TARGET_PACKAGES luci-app-openclash"
    [ "$UPDATE_PASSWALL" -eq 1 ] && TARGET_PACKAGES="$TARGET_PACKAGES luci-app-passwall"
    
    # 注意：这里仅安装 daed 核心引擎，不安装源里的废材版 luci
    [ "$UPDATE_DAED" -eq 1 ] && TARGET_PACKAGES="$TARGET_PACKAGES daed"
    
    if [ "$UPDATE_BASE" -eq 1 ]; then
        TARGET_PACKAGES="$TARGET_PACKAGES luci-app-ddns-go luci-i18n-ddns-go-zh-cn luci-theme-argon luci-app-argon-config luci-proto-wireguard wireguard-tools qrencode luci-compat"
    fi
    
    if [ -n "$TARGET_PACKAGES" ]; then
        echo -e "🚀 批量执行: ${YELLOW}${TARGET_PACKAGES}${PLAIN}"
        opkg install --force-overwrite --force-checksum $TARGET_PACKAGES 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine|Couldn't unlink"
        opkg upgrade --force-overwrite --force-checksum $TARGET_PACKAGES 2>/dev/null | grep -Ev "remove_obsolesced_files"
    fi

    # ---------------- 第 4 步：独立安装 QiuSimons 原版可视化界面 ----------------
    if [ "$UPDATE_DAED" -eq 1 ]; then
        echo -e "\n${GREEN}[4/5] 正在通过独立通道挂载 QiuSimons 原版可视化界面...${PLAIN}"
        
        # 强制删除可能被关联带入的魔改版界面
        opkg remove luci-app-daed >/dev/null 2>&1 
        
        # 利用 GitHub API 获取最新发布版本并使用加速镜像拉取
        DOWNLOAD_URL=$(wget -qO- https://api.github.com/repos/QiuSimons/luci-app-daed/releases/latest 2>/dev/null | grep "browser_download_url" | grep "all.ipk" | head -n 1 | awk -F '"' '{print $4}')
        
        if [ -n "$DOWNLOAD_URL" ]; then
            echo -e "🔗 获取到最新官方包链接，正在加速下载..."
            wget -qO /tmp/qs-daed.ipk "https://mirror.ghproxy.com/${DOWNLOAD_URL}"
            if [ -f "/tmp/qs-daed.ipk" ]; then
                opkg install /tmp/qs-daed.ipk --force-overwrite 2>/dev/null
                rm -f /tmp/qs-daed.ipk
                echo -e "✔ QiuSimons 原版可视化界面挂载成功！"
            else
                echo -e "${RED}❌ UI 包下载失败。${PLAIN}"
            fi
        else
            echo -e "${RED}❌ 无法获取 GitHub 最新发布链接，跳过 UI 注入。${PLAIN}"
        fi
    else
        echo -e "\n${YELLOW}[4/5] 跳过单独界面的安装...${PLAIN}"
    fi

    # ---------------- 第 5 步：卸载虚拟内存，恢复纯净磁盘 ----------------
    echo -e "\n${YELLOW}[5/5] 流程结束，正在安全收回并卸载虚拟内存空间...${PLAIN}"
    swapoff /root/swapfile >/dev/null 2>&1
    rm -f /root/swapfile >/dev/null 2>&1
    sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF"
    echo -e "✔ 内存及系统配置恢复纯净状态。"
    
    restart_services
}

restart_services() {
    echo -e "\n${GREEN}正在平滑唤醒所有已安装的网络服务...${PLAIN}"
    [ -f "/etc/init.d/openclash" ] && /etc/init.d/openclash restart >/dev/null 2>&1
    [ -f "/etc/init.d/passwall" ] && /etc/init.d/passwall restart >/dev/null 2>&1
    [ -f "/etc/init.d/daed" ] && /etc/init.d/daed restart >/dev/null 2>&1
    [ -f "/etc/init.d/ddns-go" ] && /etc/init.d/ddns-go restart >/dev/null 2>&1
    /etc/init.d/network reload >/dev/null 2>&1

    echo -e "\n${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}  🎉 恭喜！所选插件均已就绪。  ${PLAIN}"
    echo -e "${GREEN}  👉 请刷新路由器网页后台，尽情享用可视化界面！   ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    
    if [ "$UPDATE_DAED" -eq 1 ]; then
        echo -e "${YELLOW}【关于 DAED 的温馨提示】${PLAIN}"
        echo -e "如果通过 LuCI 菜单打不开可视化界面，"
        echo -e "您可以直接在浏览器访问：${CYAN}http://您的路由器IP:2023${PLAIN} 进入独立大屏后台。\n"
    fi
    exit 0
}

plugin_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}  系统架构: ${SELECTED_MANAGER} 模式 | 纯净独立 UI 保卫版  ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${YELLOW}[ 科学上网系列 ]${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 仅同步更新 ${YELLOW}OpenClash${PLAIN}"
    echo -e "${GREEN}2.${PLAIN} 仅同步更新 ${YELLOW}Passwall${PLAIN}"
    echo -e "${GREEN}3.${PLAIN} 仅安装更新 ${YELLOW}DAED (原版可视化UI + eBPF核心)${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}[ 基础增强系列 ]${PLAIN}"
    echo -e "${GREEN}4.${PLAIN} 永久加源安装 ${YELLOW}DDNS-GO + Argon主题 + WG组件${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}[ 一键全家桶 ]${PLAIN}"
    echo -e "${GREEN}5.${PLAIN} ${CYAN}同时把上述所有源及插件全部写入安装 (默认推荐)${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请选择操作 [0-5]: " PLUGIN_CHOICE
    
    case "$PLUGIN_CHOICE" in
        1) UPDATE_OPENCLASH=1; UPDATE_PASSWALL=0; UPDATE_DAED=0; UPDATE_BASE=0; execute_update ;;
        2) UPDATE_OPENCLASH=0; UPDATE_PASSWALL=1; UPDATE_DAED=0; UPDATE_BASE=0; execute_update ;;
        3) UPDATE_OPENCLASH=0; UPDATE_PASSWALL=0; UPDATE_DAED=1; UPDATE_BASE=0; execute_update ;;
        4) UPDATE_OPENCLASH=0; UPDATE_PASSWALL=0; UPDATE_DAED=0; UPDATE_BASE=1; execute_update ;;
        5|"") UPDATE_OPENCLASH=1; UPDATE_PASSWALL=1; UPDATE_DAED=1; UPDATE_BASE=1; execute_update ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}"; sleep 1; plugin_menu ;;
    esac
}

auto_detect_env
plugin_menu
