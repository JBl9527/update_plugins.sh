#!/bin/sh
# ==============================================================
# passwall.sh - 安装 PassWall / PassWall2 及其核心
# 上游: https://github.com/Openwrt-Passwall (原 xiaorouji,已迁移,旧地址 404)
# 构建源: https://github.com/moetayuko/openwrt-passwall-build
#
# 2026-09 核实要点:
#   * 官方构建源在 SourceForge,opkg 与 apk 都有,且仍在每日更新
#   * 只发布这几个分支: 21.02 22.03 23.05 24.10 25.12
#   * 核心包名是上游真名 xray-core / sing-box,
#     旧脚本里的 passwall-xray / passwall-sing-box / passwall-trojan-go
#     已经不存在了(trojan-go 彻底下架)
#
# 可选: PW_EDITION=1|2|both  (默认 1)
# ==============================================================

OWP_BASE_URL="${OWP_BASE_URL:-https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main}"
OWP_COMMON="${OWP_COMMON:-/tmp/owp-common.sh}"
if [ ! -s "$OWP_COMMON" ]; then
    curl -fsSL "$OWP_BASE_URL/common.sh" -o "$OWP_COMMON" 2>/dev/null || \
    wget -qO "$OWP_COMMON" "$OWP_BASE_URL/common.sh" 2>/dev/null
fi
[ -s "$OWP_COMMON" ] || { echo "[ERROR] 无法获取 common.sh,请检查网络"; exit 1; }
. "$OWP_COMMON"

PW_SF="https://master.dl.sourceforge.net/project/openwrt-passwall-build"
PW_FEEDS="passwall_luci passwall_packages passwall2"
PW_EDITION="${PW_EDITION:-1}"

PW_CORES="xray-core sing-box geoview v2ray-geoip v2ray-geosite tcping chinadns-ng dns2socks microsocks"
PW_COMMON_DEPS="coreutils coreutils-base64 coreutils-nohup coreutils-timeout curl ip-full libuci-lua lua luci-compat luci-lib-jsonc lyaml resolveip unzip"

owp_init "PassWall 安装"

owp_in_list "$OWP_BRANCH" "$OWP_PW_BRANCHES" || \
    die "PassWall 官方构建源只发布 $OWP_PW_BRANCHES 分支,当前是 $OWP_RELEASE,无法通过软件源安装"
[ "$OWP_BRANCH" = SNAPSHOT ] && [ "$OWP_PM" = opkg ] && \
    die "SNAPSHOT 分支上游只发 apk 包,而当前固件用的是 opkg。请换正式版固件(如 24.10)"

# ---------- 公钥 ----------
case "$OWP_PM" in
    opkg) owp_key_add passwall-build "$PW_SF/ipk.pub" ;;
    apk)  owp_key_add passwall-build "$PW_SF/apk.pub" ;;
esac

# ---------- 软件源 ----------
for _f in $PW_FEEDS; do
    if [ "$OWP_PM" = apk ] && [ "$OWP_BRANCH" = SNAPSHOT ]; then
        owp_feed_add "$_f" "$PW_SF/snapshots/packages/$OWP_ARCH/$_f"
    else
        owp_feed_add "$_f" "$PW_SF/releases/packages-$OWP_BRANCH/$OWP_ARCH/$_f"
    fi
done
owp_pkg_update

if ! owp_pkg_available luci-app-passwall && ! owp_pkg_available luci-app-passwall2; then
    for _f in $PW_FEEDS; do owp_feed_del "$_f"; done
    die "软件源里找不到 passwall 包,架构 $OWP_ARCH 可能未被构建。已回滚软件源。"
fi

# ---------- 透明代理相关内核模块 ----------
if [ "$OWP_FW4" = 1 ]; then
    PW_FW_DEPS="nftables kmod-nft-socket kmod-nft-tproxy kmod-nft-nat kmod-nf-reject kmod-nf-reject6"
else
    PW_FW_DEPS="iptables iptables-zz-legacy iptables-mod-conntrack-extra iptables-mod-iprange iptables-mod-socket iptables-mod-tproxy kmod-ipt-nat ipset ipt2socks"
fi

owp_swap_on 256
owp_ensure_dnsmasq_full

log "安装公共依赖"
owp_pkg_install $PW_COMMON_DEPS $PW_FW_DEPS

log "安装代理核心"
owp_pkg_install $PW_CORES

# ---------- 主体 ----------
case "$PW_EDITION" in
    2)    PW_APPS="luci-app-passwall2 luci-i18n-passwall2-zh-cn" ;;
    both) PW_APPS="luci-app-passwall luci-i18n-passwall-zh-cn luci-app-passwall2 luci-i18n-passwall2-zh-cn" ;;
    *)    PW_APPS="luci-app-passwall luci-i18n-passwall-zh-cn" ;;
esac
log "安装 PassWall 主体 (PW_EDITION=$PW_EDITION)"
owp_pkg_install $PW_APPS

owp_swap_off
owp_luci_flush
[ -x /etc/init.d/passwall ]  && /etc/init.d/passwall restart  >/dev/null 2>&1
[ -x /etc/init.d/passwall2 ] && /etc/init.d/passwall2 restart >/dev/null 2>&1

if owp_pkg_installed luci-app-passwall || owp_pkg_installed luci-app-passwall2; then
    ok "PassWall 已安装。LuCI 里位于「服务 -> PassWall」"
    printf "  软件源已常驻(%s),以后可直接用 %s 升级\n" "$PW_FEEDS" "$OWP_PM"
    printf "  只想装 PassWall2 时用: PW_EDITION=2 sh passwall.sh\n"
else
    err "PassWall 主体未安装成功"
fi

owp_summary
