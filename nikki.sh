#!/bin/sh
# ==============================================================
# nikki.sh - 安装 nikki (Mihomo 透明代理) + LuCI 界面
# 上游: https://github.com/nikkinikki-org/OpenWrt-nikki
# 源:   https://nikkinikki.pages.dev/<分支>/<架构>/nikki
#
# 限制(上游 feed.sh 自身的判定,不是本脚本加的):
#   * 只支持 OpenWrt 24.10 / 25.12 / SNAPSHOT,23.05 及更早无源可用
#   * 固件必须带 firewall4 (/sbin/fw4)
#   * 内核需 >= 5.13
# ==============================================================

OWP_BASE_URL="${OWP_BASE_URL:-https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main}"
OWP_COMMON="${OWP_COMMON:-/tmp/owp-common.sh}"
if [ ! -s "$OWP_COMMON" ]; then
    curl -fsSL "$OWP_BASE_URL/common.sh" -o "$OWP_COMMON" 2>/dev/null || \
    wget -qO "$OWP_COMMON" "$OWP_BASE_URL/common.sh" 2>/dev/null
fi
[ -s "$OWP_COMMON" ] || { echo "[ERROR] 无法获取 common.sh,请检查网络"; exit 1; }
. "$OWP_COMMON"

NIKKI_REPO_URL="https://nikkinikki.pages.dev"
NIKKI_PKGS="nikki luci-app-nikki luci-i18n-nikki-zh-cn"
NIKKI_DEPS="ca-bundle curl yq ip-full kmod-inet-diag kmod-nft-socket kmod-nft-tproxy kmod-tun kmod-dummy"

owp_init "nikki (Mihomo) 安装"

owp_require_branch 24.10 nikki || die "无法在 $OWP_RELEASE 上安装 nikki:上游只为 24.10 / 25.12 / SNAPSHOT 构建软件源。若确实需要,只能自行编译。"

[ "$OWP_FW4" = 1 ] || die "nikki 需要 firewall4 (nftables) 固件,当前系统未检测到 /sbin/fw4"

_kv=$(uname -r | cut -d- -f1 | cut -d. -f1,2)
owp_ver_ge "$_kv" 5.13 || warn "内核 $OWP_KERNEL 低于 5.13,nikki 的 TPROXY/TUN 可能无法工作"

case "$OWP_BRANCH" in
    24.10)    NIKKI_BRANCH="openwrt-24.10" ;;
    25.12)    NIKKI_BRANCH="openwrt-25.12" ;;
    SNAPSHOT) NIKKI_BRANCH="SNAPSHOT" ;;
    *)        NIKKI_BRANCH="openwrt-25.12"
              warn "分支 $OWP_BRANCH 未在上游列表内,按 openwrt-25.12 尝试" ;;
esac
NIKKI_FEED="$NIKKI_REPO_URL/$NIKKI_BRANCH/$OWP_ARCH/nikki"
log "软件源: $NIKKI_FEED"

# 上游把 nikki 源的公钥放在仓库根目录,不在 feed 目录下
case "$OWP_PM" in
    opkg) owp_key_add nikki "$NIKKI_REPO_URL/key-build.pub" ;;
    apk)  owp_key_add nikki "$NIKKI_REPO_URL/public-key.pem" ;;
esac

owp_feed_add nikki "$NIKKI_FEED"
owp_pkg_update

if ! owp_pkg_available nikki; then
    owp_feed_del nikki
    die "在 $NIKKI_FEED 里找不到 nikki 包(架构 $OWP_ARCH 可能未被上游构建)。已回滚软件源。"
fi

owp_swap_on 256
log "安装依赖"
owp_pkg_install $NIKKI_DEPS

log "安装 nikki 主体"
owp_pkg_install $NIKKI_PKGS
owp_swap_off

owp_luci_flush

if owp_pkg_installed luci-app-nikki; then
    ok "nikki 已安装。LuCI 里位于「服务 -> nikki」"
    printf "  配置目录 /etc/nikki  |  服务: /etc/init.d/nikki\n"
    printf "  首次使用需先在界面里填订阅或导入配置文件,再启动服务\n"
else
    err "luci-app-nikki 未安装成功"
fi

owp_summary
