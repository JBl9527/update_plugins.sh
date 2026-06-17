#!/bin/sh
# ==========================================================
# OpenWrt/ImmortalWrt - 基础增强增强模块 (DDNS-GO + Argon + 二维码)
# ==========================================================


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

echo -e "${CYAN}==========================================${PLAIN}"
echo -e "${CYAN}     正在启动 基础增强包 (DDNS-GO/Argon/QR) 部署    ${PLAIN}"
echo -e "${CYAN}==========================================${PLAIN}"

# 1. 临时挂载 256MB 虚拟内存防爆存
echo -e "\n${YELLOW}⟳ 正在构建 256MB 临时虚拟内存保障库...${PLAIN}"
rm -f /var/lock/opkg.lock
swapoff /root/swapfile_base >/dev/null 2>&1 || true
dd if=/dev/zero of=/root/swapfile_base bs=1M count=256 >/dev/null 2>&1
if [ -f "/root/swapfile_base" ]; then
    mkswap /root/swapfile_base >/dev/null 2>&1
    swapon /root/swapfile_base >/dev/null 2>&1
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

# 3. 批量安装基础增强包
echo -e "\n${GREEN}🚀 正在长驱直入安装 DDNS-GO 及全套系统增强组件...${PLAIN}"
# 包含：DDNS-GO及中文包、Argon主题及配置面板、WG及二维码引擎、新版兼容层
TARGET_PKGS="luci-app-ddns-go luci-i18n-ddns-go-zh-cn luci-theme-argon luci-app-argon-config luci-proto-wireguard wireguard-tools qrencode luci-compat"

opkg install --force-overwrite --force-checksum $TARGET_PKGS 2>&1 | grep -Ev "Failed to determine|remove_obsolesced"

# 4. 回收虚拟内存
echo -e "\n${YELLOW}⟳ 正在安全收回虚拟内存空间...${PLAIN}"
swapoff /root/swapfile_base >/dev/null 2>&1 || true
rm -f /root/swapfile_base >/dev/null 2>&1
sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF"

# 5. 网页后台缓存清洗与平滑重载
rm -rf /tmp/luci-* /tmp/.luci* /var/run/luci-indexcache 2>/dev/null || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true

# 激活 DDNS-GO 服务
if [ -f "/etc/init.d/ddns-go" ]; then
    /etc/init.d/ddns-go enable >/dev/null 2>&1
    /etc/init.d/ddns-go restart >/dev/null 2>&1 || true
fi

echo -e "\n${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}  🎉 恭喜！DDNS-GO、Argon 主题与扫码引擎已部署就绪！${PLAIN}"
echo -e "${GREEN}  👉 你可以在“系统 -> Argon 主题设置”中自定义外观。${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}"
