#!/bin/sh
# ==============================================================
# openclash.sh - 安装 luci-app-openclash
# 上游: https://github.com/vernesong/OpenClash
#
# 为什么这么装(2026-09 核实):
#   * OpenClash 官方没有任何 opkg/apk 软件源,也没有签名公钥,
#     官方文档给的就是"从 Release 下包本地安装"
#   * 依赖全部来自官方 OpenWrt 源
#   * 资产命名两种格式不一致:
#       ipk -> luci-app-openclash_0.47.156_all.ipk   (下划线 + _all)
#       apk -> luci-app-openclash-0.47.156.apk       (连字符,无 _all)
#     tag 带 v,文件名不带 v
# ==============================================================

OWP_BASE_URL="${OWP_BASE_URL:-https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main}"
OWP_COMMON="${OWP_COMMON:-/tmp/owp-common.sh}"
if [ ! -s "$OWP_COMMON" ]; then
    curl -fsSL "$OWP_BASE_URL/common.sh" -o "$OWP_COMMON" 2>/dev/null || \
    wget -qO "$OWP_COMMON" "$OWP_BASE_URL/common.sh" 2>/dev/null
fi
[ -s "$OWP_COMMON" ] || { echo "[ERROR] 无法获取 common.sh,请检查网络"; exit 1; }
. "$OWP_COMMON"

OC_REPO="vernesong/OpenClash"

# 官方 Release 正文给出的两套依赖,按防火墙世代二选一
OC_DEPS_NFT="bash curl ca-bundle ip-full ruby ruby-yaml kmod-tun kmod-inet-diag unzip kmod-nft-tproxy luci-compat luci luci-base"
OC_DEPS_IPT="bash iptables curl ca-bundle ipset ip-full iptables-mod-tproxy iptables-mod-extra ruby ruby-yaml kmod-tun kmod-inet-diag unzip luci-compat luci luci-base"

owp_init "OpenClash 安装"

if [ "$OWP_FW4" = 1 ]; then
    OC_DEPS="$OC_DEPS_NFT"
    log "检测到 firewall4,使用 nftables 依赖集"
else
    OC_DEPS="$OC_DEPS_IPT"
    log "检测到 iptables 防火墙,使用 iptables 依赖集"
fi

owp_pkg_update
owp_check_deps $OC_DEPS || warn "缺失项会导致 OpenClash 部分功能不可用"

owp_swap_on 256

# dnsmasq-full 提供 ipset/nftset 能力,是 OpenClash 域名分流的前提
owp_ensure_dnsmasq_full

log "安装依赖(ruby 体积较大,请耐心等待)"
owp_pkg_install $OC_DEPS

# ---------- 取 Release ----------
if [ "$OWP_PM" = opkg ]; then
    OC_PAT="luci-app-openclash_[0-9][0-9.]*_all\.ipk"
else
    OC_PAT="luci-app-openclash-[0-9][0-9.]*\.apk"
fi

OC_TAG="${OPENCLASH_TAG:-}"
OC_URL=""
_json=$(owp_gh_releases "$OC_REPO")
if [ -n "$_json" ]; then
    [ -n "$OC_TAG" ] || OC_TAG=$(owp_gh_pick_tag "$_json" '^v[0-9]' | head -n1)
    [ -n "$OC_TAG" ] && OC_URL=$(owp_gh_asset "$_json" "$OC_TAG" "$OC_PAT")
fi
if [ -z "$OC_URL" ] && [ -n "$OC_TAG" ]; then
    warn "GitHub API 结果不可用,改解析 Release 资产页"
    OC_URL=$(owp_gh_asset_html "$OC_REPO" "$OC_TAG" "$OC_PAT")
fi
[ -n "$OC_URL" ] || { owp_swap_off; die "无法确定 OpenClash 下载地址。可手动指定版本重试: OPENCLASH_TAG=v0.47.156 sh openclash.sh"; }

log "版本 $OC_TAG"
OC_FILE="$OWP_TMP/$(basename "$OC_URL")"
owp_download "$OC_URL" "$OC_FILE" || { owp_swap_off; die "下载失败: $OC_URL"; }

log "安装 $(basename "$OC_FILE")"
owp_pkg_install_local "$OC_FILE"
owp_swap_off
owp_luci_flush

if owp_pkg_installed luci-app-openclash; then
    ok "OpenClash 已安装。LuCI 里位于「服务 -> OpenClash」"
    printf "  内核需要在界面「版本更新」里单独下载(Meta/Mihomo 内核不随插件发布)\n"
    printf "  配置目录 /etc/openclash\n"
    OWP_OK_LIST="$OWP_OK_LIST luci-app-openclash"
else
    err "luci-app-openclash 未安装成功"
    OWP_FAIL_LIST="$OWP_FAIL_LIST luci-app-openclash"
fi

owp_summary
