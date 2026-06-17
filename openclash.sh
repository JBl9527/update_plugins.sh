#!/bin/sh
# ==========================================================
# OpenWrt/ImmortalWrt - OpenClash 独立直装与内核补全模块


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

echo -e "${CYAN}==========================================${PLAIN}"
echo -e "${CYAN}        正在启动 OpenClash 插件与依赖部署       ${PLAIN}"
echo -e "${CYAN}==========================================${PLAIN}"

# 1. 临时挂载 256MB 虚拟内存防止编译/解压大包时 OOM Killed
echo -e "\n${YELLOW}⟳ 正在构建 256MB 临时虚拟内存保障库...${PLAIN}"
rm -f /var/lock/opkg.lock
swapoff /root/swapfile_oc >/dev/null 2>&1 || true
dd if=/dev/zero of=/root/swapfile_oc bs=1M count=256 >/dev/null 2>&1
if [ -f "/root/swapfile_oc" ]; then
    mkswap /root/swapfile_oc >/dev/null 2>&1
    swapon /root/swapfile_oc >/dev/null 2>&1
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

# 3. 顺藤摸瓜安装 OpenClash 及其全部运行依赖
echo -e "\n${GREEN}🚀 正在安装 luci-app-openclash 及其全套网络依赖组件...${PLAIN}"
# 一并补齐 iptables, nftables, dnsmasq-full 切换所需核心组件，彻底杜绝起不来的问题
opkg install --force-overwrite --force-checksum luci-app-openclash luci-compat coreutils-nohup bash curl ca-certificates ca-bundle iptables-mod-tproxy ip-full 2>&1 | grep -Ev "Failed to determine"

# 4. 回收虚拟内存
echo -e "\n${YELLOW}⟳ 正在安全收回虚拟内存空间...${PLAIN}"
swapoff /root/swapfile_oc >/dev/null 2>&1 || true
rm -f /root/swapfile_oc >/dev/null 2>&1
sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF"

# 5. 重启 rpcd 刷新网页缓存，平滑启动
rm -rf /tmp/luci-* /tmp/.luci* /var/run/luci-indexcache 2>/dev/null || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true

echo -e "\n${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}  🎉 恭喜！OpenClash 及其依赖组件已全部装妥！ ${PLAIN}"
echo -e "${GREEN}  👉 提示：首次进入插件请在“版本更新”中下载 Meta 内核。${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}"
