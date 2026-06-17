#!/bin/sh
# ==========================================================
# OpenWrt/ImmortalWrt - 终极插件管理中枢 (update_plugins.sh)
# 作者: JBl9527
# 特性: 模块化分离架构 / 云端动态拉取 / 附带国内镜像加速
# ==========================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 你的 GitHub 仓库原始地址 (自带国内镜像加速前缀)
BASE_URL="https://ghproxy.net/https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main"

# 执行远端脚本的核心函数
run_plugin() {
    local script_name="$1"
    local tmp_file="/tmp/${script_name}"
    
    # 针对 DDNS+argo+qr.sh 文件名中的 "+" 号进行 URL 编码处理 (%2B) 确保 wget 不会报错
    local download_url="${BASE_URL}/${script_name}"
    download_url=$(echo "$download_url" | sed 's/+/%2B/g')

    echo -e "\n${YELLOW}==========================================${PLAIN}"
    echo -e "${YELLOW}📥 正在从云端拉取模块: ${script_name}...${PLAIN}"
    
    # 下载脚本
    if wget -qO "$tmp_file" "$download_url"; then
        if [ -s "$tmp_file" ]; then
            chmod +x "$tmp_file"
            echo -e "${GREEN}✔ 拉取成功，开始执行！${PLAIN}"
            echo -e "${YELLOW}==========================================${PLAIN}\n"
            
            # 执行子脚本
            sh "$tmp_file"
            
            # 阅后即焚
            rm -f "$tmp_file"
        else
            echo -e "${RED}❌ 模块拉取失败：文件为空。请检查网络或仓库是否存在此文件。${PLAIN}"
            rm -f "$tmp_file"
        fi
    else
        echo -e "${RED}❌ 模块拉取失败：网络请求错误。${PLAIN}"
    fi
}

# 主菜单循环
show_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${PLAIN}"
        echo -e "${CYAN}    🔥 OpenWrt 终极插件一键部署中心 🔥    ${PLAIN}"
        echo -e "${CYAN}==========================================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 安装/更新 ${YELLOW}DAE (高性能eBPF网关 + 原版UI)${PLAIN}"
        echo -e "${GREEN}2.${PLAIN} 安装/更新 ${YELLOW}OpenClash (全网核依赖闭环版)${PLAIN}"
        echo -e "${GREEN}3.${PLAIN} 安装/更新 ${YELLOW}PassWall (全分流核心引擎版)${PLAIN}"
        echo -e "${GREEN}4.${PLAIN} 安装/更新 ${YELLOW}基础增强包 (DDNS-GO+Argon主题+二维码)${PLAIN}"
        echo -e "------------------------------------------"
        echo -e "${GREEN}5.${PLAIN} ⚡ ${CYAN}一键长驱直入安装/更新以上所有全家桶${PLAIN}"
        echo -e "------------------------------------------"
        echo -e "${GREEN}0.${PLAIN} 退出脚本"
        echo -e "${CYAN}==========================================${PLAIN}"
        read -p "请输入对应数字 [0-5]: " choice
        
        case "$choice" in
            1) run_plugin "dae.sh" ;;
            2) run_plugin "openclash.sh" ;;
            3) run_plugin "passwall.sh" ;;
            4) run_plugin "DDNS+argo+qr.sh" ;;
            5) 
                run_plugin "dae.sh"
                run_plugin "openclash.sh"
                run_plugin "passwall.sh"
                run_plugin "DDNS+argo+qr.sh"
                echo -e "\n${GREEN}🎉 恭喜，全家桶所有模块已顺利执行完毕！${PLAIN}"
                ;;
            0) echo -e "${GREEN}已退出部署中心。${PLAIN}"; exit 0 ;;
            *) echo -e "${RED}输入无效，请重新输入！${PLAIN}"; sleep 1 ;;
        esac
        
        echo -e "\n${CYAN}==========================================${PLAIN}"
        read -p "按回车键返回主菜单..." dummy
    done
}

# 启动菜单
show_menu
