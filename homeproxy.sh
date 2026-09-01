#!/bin/sh
# ==============================================================
# homeproxy.sh - 安装 luci-app-homeproxy (sing-box 透明代理)
# 上游: https://github.com/immortalwrt/homeproxy
#
# 为什么这么装(2026-09 核实):
#   * 官方 OpenWrt 源里没有 homeproxy(23.05/24.10/25.12 三个分支都查过)
#   * 但官方源里有它的全部依赖: sing-box firewall4 kmod-nft-tproxy
#     ucode-mod-digest(24.10 起才有)
#   * 主包用 ImmortalWrt 的构建产物(Architecture: all,解包核对过没有发行版绑定)
#   * 只下单个包,不把 ImmortalWrt 源加进 customfeeds ——
#     那个源里带它自己的 luci-base 等核心包,加进去以后一次 upgrade
#     就可能把官方核心包顶替掉
# ==============================================================

OWP_BASE_URL="${OWP_BASE_URL:-https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main}"
OWP_COMMON="${OWP_COMMON:-/tmp/owp-common.sh}"
if [ ! -s "$OWP_COMMON" ]; then
    curl -fsSL "$OWP_BASE_URL/common.sh" -o "$OWP_COMMON" 2>/dev/null || \
    wget -qO "$OWP_COMMON" "$OWP_BASE_URL/common.sh" 2>/dev/null
fi
[ -s "$OWP_COMMON" ] || { echo "[ERROR] 无法获取 common.sh,请检查网络"; exit 1; }
. "$OWP_COMMON"

IMM_BASE="https://downloads.immortalwrt.org/releases"
LXIAYA_REPO="lxiaya/openwrt-homeproxy"

owp_init "homeproxy (sing-box) 安装"

[ "$OWP_FW4" = 1 ] || die "homeproxy 依赖 firewall4/nftables,当前固件是 iptables 时代的,装不了"

case "$OWP_BRANCH" in
    SNAPSHOT) IMM_BRANCH="25.12"; warn "SNAPSHOT 无对应构建,按 25.12 的包尝试" ;;
    *)        IMM_BRANCH="$OWP_BRANCH" ;;
esac

# ---------- 依赖 ----------
HP_DEPS="sing-box firewall4 kmod-nft-tproxy"
if owp_ver_ge "$OWP_BRANCH" 24.10; then
    HP_DEPS="$HP_DEPS ucode-mod-digest"
else
    warn "23.05 的官方源没有 ucode-mod-digest,只能安装 2025-10 冻结版 homeproxy(之后上游不再为 23.05 构建)"
fi

owp_pkg_update
owp_check_deps $HP_DEPS || warn "缺失的依赖会导致安装失败,继续尝试"

owp_swap_on 256
log "安装依赖(全部来自官方源)"
owp_pkg_install $HP_DEPS

# ---------- 主包 ----------
IMM_DIR="$IMM_BASE/packages-$IMM_BRANCH/$OWP_ARCH/luci"
if [ "$OWP_PM" = opkg ]; then
    APP_PAT="luci-app-homeproxy_[0-9A-Za-z._~+-]*_all\.ipk"
    I18N_PAT="luci-i18n-homeproxy-zh-cn_[0-9A-Za-z._~+-]*_all\.ipk"
    EXT="ipk"
else
    APP_PAT="luci-app-homeproxy-[0-9A-Za-z._~+-]*\.apk"
    I18N_PAT="luci-i18n-homeproxy-zh-cn-[0-9A-Za-z._~+-]*\.apk"
    EXT="apk"
fi

log "在 $IMM_DIR 里查找 homeproxy 包"
APP_URL=$(owp_dir_pick "$IMM_DIR" "$APP_PAT")
I18N_URL=$(owp_dir_pick "$IMM_DIR" "$I18N_PAT")

# ImmortalWrt 不通时的备用镜像(只有 ipk,给 opkg 分支用)
if [ -z "$APP_URL" ] && [ "$OWP_PM" = opkg ]; then
    warn "ImmortalWrt 源不可用,改用备用镜像 $LXIAYA_REPO"
    _json=$(owp_gh_releases "$LXIAYA_REPO")
    if [ -n "$_json" ]; then
        _tag=$(owp_gh_pick_tag "$_json" "$OWP_ARCH\$")
        [ -n "$_tag" ] || _tag=$(owp_gh_pick_tag "$_json" '.')
        APP_URL=$(owp_gh_asset "$_json" "$_tag" "$APP_PAT")
        I18N_URL=$(owp_gh_asset "$_json" "$_tag" "$I18N_PAT")
    fi
fi

[ -n "$APP_URL" ] || { owp_swap_off; die "找不到可用的 luci-app-homeproxy 包(架构 $OWP_ARCH / 分支 $IMM_BRANCH)"; }

FILES=""
for _u in $APP_URL $I18N_URL; do
    _f="$OWP_TMP/$(basename "$_u")"
    log "下载 $(basename "$_u")"
    if owp_download "$(owp_urlenc_plus "$_u")" "$_f"; then
        FILES="$FILES $_f"
    else
        warn "下载失败: $_u"
    fi
done
[ -n "$FILES" ] || { owp_swap_off; die "homeproxy 包下载失败"; }

log "安装 homeproxy"
owp_pkg_install_local $FILES
owp_swap_off
owp_luci_flush

if owp_pkg_installed luci-app-homeproxy; then
    ok "homeproxy 已安装。LuCI 里位于「服务 -> HomeProxy」"
    printf "  配置: /etc/config/homeproxy  |  服务: /etc/init.d/homeproxy\n"
    printf "  内核走官方源的 /usr/bin/sing-box (版本 %s)\n" \
        "$(sing-box version 2>/dev/null | head -n1 | awk '{print $3}')"
    OWP_OK_LIST="$OWP_OK_LIST luci-app-homeproxy"
else
    err "luci-app-homeproxy 未安装成功"
    OWP_FAIL_LIST="$OWP_FAIL_LIST luci-app-homeproxy"
fi

owp_summary
