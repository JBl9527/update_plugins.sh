#!/bin/sh
# ==========================================================
# OpenWrt/ImmortalWrt - PassWall 独立直装与全分流核心模块
# ==========================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

echo -e "${CYAN}==========================================${PLAIN}"
echo -e "${CYAN}        正在启动 PassWall 及其全套核心组件部署     ${PLAIN}"
echo -e "${CYAN}==========================================${PLAIN}"

# 1. 临时挂载 256MB 虚拟内存
echo -e "\n${YELLOW}⟳ 正在构建 256MB 临时虚拟内存保障库...${PLAIN}"
rm -f /var/lock/opkg.lock
swapoff /root/swapfile_pw >/dev/null 2>&1 || true
dd if=/dev/zero of=/root/swapfile_pw bs=1M count=256 >/dev/null 2>&1
if [ -f "/root/swapfile_pw" ]; then
    mkswap /root/swapfile_pw >/dev/null 2>&1
    swapon /root/swapfile_pw >/dev/null 2>&1
    echo -e "✔ 虚拟内存挂载成功！"
fi

# 2. 注入软件源
ARCH=$(grep "OPENWRT_ARCH" /etc/os-release | awk -F '"' '{print $2}')
OPKG_CONF="/etc/opkg/customfeeds.conf"
OPKG_MAIN_CONF="/etc/opkg.conf"

if ! grep -q "custom_plugins" "$OPKG_CONF" 2>/dev/null; then
    echo "src/gz custom_plugins https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9" >> "$OPKG_CONF"
fi
wget -qO - "https://dl.openwrt.ai/latest/public-key.pub" | opkg-key add - >/dev/null 2>&1

echo -e "${GREEN}⟳ 正在安全刷新软件列表...${PLAIN}"
sed -i 's/option check_signature/#option check_signature/g' "$OPKG_MAIN_CONF"
opkg update

# 3. 安装 PassWall 及其全套核心分流引擎（Xray, Trojan, Sing-box 等）
echo -e "\n${GREEN}🚀 正在安装 luci-app-passwall 及其全套编译核心分流引擎...${PLAIN}"
# 一并强制拉入常用的 Xray 和分流依赖，防止节点类型缺失
opkg install --force-overwrite --force-checksum luci-app-passwall luci-i18n-passwall-zh-cn passwall-xray passwall-sing-box passwall-trojan-go 2>&1 | grep -Ev "Failed to determine"

# 4. 回收虚拟内存
echo -e "\n${YELLOW}⟳ 正在安全收回虚拟内存空间...${PLAIN}"
swapoff /root/swapfile_pw >/dev/null 2>&1 || true
rm -f /root/swapfile_pw >/dev/null 2>&1
sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF"

# 5. 网页后台缓存清洗与平滑重载
rm -rf /tmp/luci-* /tmp/.luci* /var/run/luci-indexcache 2>/dev/null || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true
[ -f "/etc/init.d/passwall" ] && /etc/init.d/passwall restart >/dev/null 2>&1 || true

echo -e "\n${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}  🎉 恭喜！PassWall 及其全套后端分流引擎已部署就绪！${PLAIN}"
echo -e "${GREEN}  👉 现在刷新路由器后台页面，即可直接享用。       ${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}"
