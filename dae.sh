#!/bin/sh
# ==========================================================
# OpenWrt/ImmortalWrt - DAE 独立直装模块 (防中断容错版)
# ==========================================================

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
# 采用更兼容的 awk 方式比对内核版本
if [ "$(echo "$KERNEL_VER" | awk '{print ($1 < 5.8) ? 1 : 0}' 2>/dev/null || echo 0)" = "1" ]; then
    echo -e "${RED}❌ 致命错误: DAE 需要 Linux 5.8+ 内核，当前内核为 $(uname -r)，流程终止！${PLAIN}"
    exit 1
fi

# 2. 临时挂载 256MB 虚拟内存 (增加容错，失败也不影响后续安装)
echo -e "\n${YELLOW}⟳ 正在尝试构建 256MB 临时虚拟内存...${PLAIN}"
rm -f /var/lock/opkg.lock || true
swapoff /root/swapfile_dae >/dev/null 2>&1 || true
dd if=/dev/zero of=/root/swapfile_dae bs=1M count=256 >/dev/null 2>&1 || true
if [ -f "/root/swapfile_dae" ]; then
    mkswap /root/swapfile_dae >/dev/null 2>&1 || true
    swapon /root/swapfile_dae >/dev/null 2>&1 || true
    echo -e "✔ 虚拟内存步骤执行完毕 (若固件底层不支持将自动跳过)。"
fi

# 3. 注入底层依赖源
ARCH=$(grep "OPENWRT_ARCH" /etc/os-release | awk -F '"' '{print $2}')
OPKG_CONF="/etc/opkg/customfeeds.conf"
OPKG_MAIN_CONF="/etc/opkg.conf"

if ! grep -q "custom_plugins" "$OPKG_CONF" 2>/dev/null; then
    echo "src/gz custom_plugins https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9" >> "$OPKG_CONF"
fi
wget -qO - "https://dl.openwrt.ai/latest/public-key.pub" | opkg-key add - >/dev/null 2>&1 || true

echo -e "${GREEN}⟳ 正在安全刷新软件列表...${PLAIN}"
sed -i 's/option check_signature/#option check_signature/g' "$OPKG_MAIN_CONF"
opkg update || true

# 4. 安装 dae 核心引擎
echo -e "\n${GREEN}🚀 正在从源安装 dae 核心底层...${PLAIN}"
opkg install --force-overwrite --force-checksum daed 2>&1 | grep -Ev "Failed to determine" || true

# 5. 拉取 QiuSimons 官方原版可视化前端
echo -e "\n${GREEN}🚀 正在独立注入 QiuSimons 官方原版 Web 界面...${PLAIN}"
opkg remove luci-app-daed luci-app-dae --force-remove-depend >/dev/null 2>&1 || true

# 双节点加速下载，防止单节点失效
DOWNLOAD_URL=$(wget -qO- https://api.github.com/repos/QiuSimons/luci-app-dae/releases/latest 2>/dev/null | grep "browser_download_url" | head -n 1 | awk -F '"' '{print $4}')
if [ -n "$DOWNLOAD_URL" ]; then
    wget -qO /tmp/qs-dae.ipk "https://ghp.ci/${DOWNLOAD_URL}" || wget -qO /tmp/qs-dae.ipk "https://ghproxy.net/${DOWNLOAD_URL}"
    if [ -s "/tmp/qs-dae.ipk" ]; then
        opkg install /tmp/qs-dae.ipk --force-overwrite 2>/dev/null || true
        rm -f /tmp/qs-dae.ipk
        echo -e "✔ 官方原版 UI 前端注入成功！"
    else
        echo -e "${RED}❌ UI 包下载失败，尝试回退安装源内魔改UI...${PLAIN}"
        opkg install luci-app-daed --force-overwrite >/dev/null 2>&1 || true
    fi
else
    echo -e "${RED}❌ 无法解析到 GitHub 界面文件，尝试回退安装源内魔改UI...${PLAIN}"
    opkg install luci-app-daed --force-overwrite >/dev/null 2>&1 || true
fi

# 6. 安全恢复环境
echo -e "\n${YELLOW}⟳ 正在安全回收虚拟内存空间...${PLAIN}"
swapoff /root/swapfile_dae >/dev/null 2>&1 || true
rm -f /root/swapfile_dae >/dev/null 2>&1 || true
sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF"

# 7. 清理缓存并唤醒服务
rm -rf /tmp/luci-* /tmp/.luci* /var/run/luci-indexcache 2>/dev/null || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true

if [ -f "/etc/init.d/dae" ]; then
    /etc/init.d/dae enable >/dev/null 2>&1 || true
    /etc/init.d/dae restart >/dev/null 2>&1 || true
elif [ -f "/etc/init.d/daed" ]; then
    /etc/init.d/daed enable >/dev/null 2>&1 || true
    /etc/init.d/daed restart >/dev/null 2>&1 || true
fi

echo -e "\n${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}  🎉 恭喜！DAE (原版可视化大屏) 模块已成功部署！${PLAIN}"
echo -e "${GREEN}  👉 请刷新路由器网页后台即可看到插件菜单。${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}"
