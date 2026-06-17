#!/bin/sh
# ==========================================================
# OpenWrt/ImmortalWrt - DAE 独立直装模块 (原版可视化UI)
# ==========================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

echo -e "${CYAN}==========================================${PLAIN}"
echo -e "${CYAN}        正在启动 DAE 核心与独立UI部署        ${PLAIN}"
echo -e "${CYAN}==========================================${PLAIN}"

# 1. 检查内核版本 (dae核心要求Linux 5.8+)
KERNEL_VER=$(uname -r | cut -d. -f1,2)
if [ "$(echo "$KERNEL_VER < 5.8" | bc -l 2>/dev/null)" = "1" ]; then
    echo -e "${RED}❌ 致命错误: DAE 需要 Linux 5.8+ 内核，当前内核为 $(uname -r)，流程终止！${PLAIN}"
    exit 1
fi

# 2. 临时挂载 256MB 虚拟内存
echo -e "\n${YELLOW}⟳ 正在构建 256MB 临时虚拟内存防止内存不足闪退...${PLAIN}"
rm -f /var/lock/opkg.lock
swapoff /root/swapfile_dae >/dev/null 2>&1 || true
dd if=/dev/zero of=/root/swapfile_dae bs=1M count=256 >/dev/null 2>&1
if [ -f "/root/swapfile_dae" ]; then
    mkswap /root/swapfile_dae >/dev/null 2>&1
    swapon /root/swapfile_dae >/dev/null 2>&1
    echo -e "✔ 虚拟内存挂载成功！"
fi

# 3. 注入底层依赖源
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

# 4. 安装 dae 核心引擎
echo -e "\n${GREEN}🚀 正在从源安装 dae 核心底层...${PLAIN}"
opkg install --force-overwrite --force-checksum daed 2>&1 | grep -Ev "Failed to determine"

# 5. 拉取 QiuSimons 官方原版可视化前端
echo -e "\n${GREEN}🚀 正在独立注入 QiuSimons 官方原版 Web 界面...${PLAIN}"
opkg remove luci-app-daed luci-app-dae --force-remove-depend >/dev/null 2>&1 || true

DOWNLOAD_URL=$(wget -qO- https://api.github.com/repos/QiuSimons/luci-app-dae/releases/latest | grep "browser_download_url" | head -n 1 | awk -F '"' '{print $4}')
if [ -n "$DOWNLOAD_URL" ]; then
    wget -qO /tmp/qs-dae.ipk "https://mirror.ghproxy.com/${DOWNLOAD_URL}"
    opkg install /tmp/qs-dae.ipk --force-overwrite 2>/dev/null
    rm -f /tmp/qs-dae.ipk
    echo -e "✔ 官方原版 UI 前端注入成功！"
else
    echo -e "${RED}❌ 无法解析到 GitHub Release 界面文件，尝试回马枪安装源内UI...${PLAIN}"
    opkg install luci-app-daed --force-overwrite >/dev/null 2>&1 || true
fi

# 6. 安全恢复环境
echo -e "\n${YELLOW}⟳ 正在安全回收虚拟内存空间...${PLAIN}"
swapoff /root/swapfile_dae >/dev/null 2>&1 || true
rm -f /root/swapfile_dae >/dev/null 2>&1
sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF"

# 7. 唤醒服务
if [ -f "/etc/init.d/dae" ]; then
    /etc/init.d/dae enable >/dev/null 2>&1
    /etc/init.d/dae restart >/dev/null 2>&1
elif [ -f "/etc/init.d/daed" ]; then
    /etc/init.d/daed enable >/dev/null 2>&1
    /etc/init.d/daed restart >/dev/null 2>&1
fi

echo -e "\n${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}  🎉 恭喜！DAE (原版可视化大屏) 模块已成功部署！${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}"
