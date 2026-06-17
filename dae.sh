#!/bin/sh
# ==========================================================
# OpenWrt/ImmortalWrt - DAE/DAED 独立直装模块 (curl直连无视拦截版)
# ==========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

echo -e "${CYAN}==========================================${PLAIN}"
echo -e "${CYAN}        正在启动 DAE 核心与独立UI部署        ${PLAIN}"
echo -e "${CYAN}==========================================${PLAIN}"

# 1. 检查内核版本
KERNEL_VER=$(uname -r | cut -d. -f1,2)
if [ "$(echo "$KERNEL_VER" | awk '{print ($1 < 5.8) ? 1 : 0}' 2>/dev/null || echo 0)" = "1" ]; then
    echo -e "${RED}❌ 致命错误: DAE 需要 Linux 5.8+ 内核，当前内核为 $(uname -r)，流程终止！${PLAIN}"
    exit 1
fi

# 2. 挂载虚拟内存
echo -e "\n${YELLOW}⟳ 正在尝试构建临时虚拟内存...${PLAIN}"
rm -f /var/lock/opkg.lock || true
swapoff /root/swapfile_dae >/dev/null 2>&1 || true
dd if=/dev/zero of=/root/swapfile_dae bs=1M count=256 >/dev/null 2>&1 || true
if [ -f "/root/swapfile_dae" ]; then
    mkswap /root/swapfile_dae >/dev/null 2>&1 || true
    swapon /root/swapfile_dae >/dev/null 2>&1 || true
    echo -e "✔ 虚拟内存步骤执行完毕。"
fi

# 3. 注入底层依赖源
ARCH=$(grep "OPENWRT_ARCH" /etc/os-release | awk -F '"' '{print $2}')
OPKG_CONF="/etc/opkg/customfeeds.conf"
OPKG_MAIN_CONF="/etc/opkg.conf"

if ! grep -q "custom_plugins" "$OPKG_CONF" 2>/dev/null; then
    echo "src/gz custom_plugins https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9" >> "$OPKG_CONF"
fi
# 使用 curl 替换 wget
curl -kLs "https://dl.openwrt.ai/latest/public-key.pub" | opkg-key add - >/dev/null 2>&1 || true

echo -e "${GREEN}⟳ 正在安全刷新软件列表...${PLAIN}"
sed -i 's/option check_signature/#option check_signature/g' "$OPKG_MAIN_CONF"
opkg update || true

# 4. 安装 dae 核心引擎 (加入 --force-depends 无视假性 btf 依赖报错)
echo -e "\n${GREEN}🚀 正在从源安装 daed 核心底层...${PLAIN}"
opkg install --force-overwrite --force-checksum --force-depends daed 2>&1 | grep -Ev "Failed to determine" || true

# 5. 拉取 QiuSimons 官方原版可视化前端 (全盘改用 curl)
echo -e "\n${GREEN}🚀 正在独立注入 QiuSimons 官方原版 Web 界面...${PLAIN}"
opkg remove luci-app-daed luci-app-dae --force-remove-depend >/dev/null 2>&1 || true

# 利用 curl 调用 GitHub API 获取最新直链
DOWNLOAD_URL=$(curl -kLs https://api.github.com/repos/QiuSimons/luci-app-daed/releases/latest | grep "browser_download_url" | grep "all.ipk" | head -n 1 | awk -F '"' '{print $4}')

if [ -n "$DOWNLOAD_URL" ]; then
    echo -e "📥 成功获取官方直链，正在使用 curl 强力下载..."
    curl -kLo /tmp/qs-daed.ipk "$DOWNLOAD_URL"
    if [ -s "/tmp/qs-daed.ipk" ]; then
        echo -e "🛠 正在覆盖安装独立大屏 UI..."
        # 同样无视界面的假性依赖
        opkg install /tmp/qs-daed.ipk --force-overwrite --force-depends 2>/dev/null || true
        rm -f /tmp/qs-daed.ipk
        echo -e "${GREEN}✔ 官方原版 UI 前端注入成功！${PLAIN}"
    else
        echo -e "${RED}❌ UI 包下载失败(文件为空)，回退安装源内魔改UI...${PLAIN}"
        opkg install luci-app-daed --force-overwrite --force-depends >/dev/null 2>&1 || true
    fi
else
    echo -e "${RED}❌ 无法解析到 GitHub 界面文件，回退安装源内魔改UI...${PLAIN}"
    opkg install luci-app-daed --force-overwrite --force-depends >/dev/null 2>&1 || true
fi

# 6. 安全恢复环境
echo -e "\n${YELLOW}⟳ 正在安全回收空间并重启服务...${PLAIN}"
swapoff /root/swapfile_dae >/dev/null 2>&1 || true
rm -f /root/swapfile_dae >/dev/null 2>&1 || true
sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF"

rm -rf /tmp/luci-* /tmp/.luci* /var/run/luci-indexcache 2>/dev/null || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true

if [ -f "/etc/init.d/daed" ]; then
    /etc/init.d/daed enable >/dev/null 2>&1 || true
    /etc/init.d/daed restart >/dev/null 2>&1 || true
fi

echo -e "\n${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}  🎉 恭喜！DAE (原版可视化大屏) 模块已成功部署！${PLAIN}"
echo -e "${GREEN}  👉 请强制刷新路由器网页（Ctrl+F5）查看最新 UI！${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}"
