#!/bin/sh
# ==============================================================
# DDNS+argo+qr.sh - 基础套件: qrencode + Argon 主题 + ddns-go + WireGuard
#
# 2026-09 核实要点:
#   * qrencode / libqrencode 在官方 packages 源里,23.05/24.10/25.12 都有,
#     直接用包名安装,不需要第三方源(用户只要命令行,不装 LuCI 界面)
#   * luci-theme-argon 官方源没有,走 jerrykuku 的 Release。
#     注意它 README 里写的 luci-theme-argon_2.4.7-1_all.ipk 是错的(404),
#     真实文件名不带 release 号
#   * luci-app-argon-config 的二进制现在跟主题同一个 Release 一起发
#   * ddns-go 官方源没有。sirpdboy 从 v6.16.0 起改成按架构打 tar.gz:
#       openwrt-24.10-<arch>.tar.gz -> 里面是 ipk
#       SNAPSHOT-<arch>.tar.gz      -> 里面是 apk (25.12 只能用这个)
#     且只编译 10 种架构
# ==============================================================

OWP_BASE_URL="${OWP_BASE_URL:-https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main}"
OWP_COMMON="${OWP_COMMON:-/tmp/owp-common.sh}"
if [ ! -s "$OWP_COMMON" ]; then
    curl -fsSL "$OWP_BASE_URL/common.sh" -o "$OWP_COMMON" 2>/dev/null || \
    wget -qO "$OWP_COMMON" "$OWP_BASE_URL/common.sh" 2>/dev/null
fi
[ -s "$OWP_COMMON" ] || { echo "[ERROR] 无法获取 common.sh,请检查网络"; exit 1; }
. "$OWP_COMMON"

ARGON_REPO="jerrykuku/luci-theme-argon"
DDNSGO_REPO="sirpdboy/luci-app-ddns-go"

owp_init "基础套件安装 (二维码 / Argon / ddns-go / WireGuard)"

owp_pkg_update
owp_swap_on 256

# ---------- 1. 官方源里的部分 ----------
title "官方源组件"
owp_pkg_install qrencode luci-compat jsonfilter ca-bundle \
                luci-proto-wireguard wireguard-tools
# argon 依赖真 wget(官方固件只带 uclient-fetch),wget 是虚拟包由 wget-ssl 提供
owp_pkg_installed wget-ssl || owp_pkg_install wget-ssl

if owp_have qrencode; then
    ok "qrencode 可用: $(qrencode --version 2>&1 | head -n1)"
    printf "  用法示例: qrencode -t ANSIUTF8 \"要编码的内容\"\n"
    printf "            qrencode -o /tmp/qr.png -s 8 \"https://example.com\"\n"
fi

# ---------- 2. Argon 主题 ----------
title "Argon 主题"
if [ "$OWP_PM" = opkg ]; then
    A_THEME="luci-theme-argon_[0-9][0-9.]*_all\.ipk"
    A_CONF="luci-app-argon-config_[0-9][0-9.]*_all\.ipk"
    A_I18N=""
else
    A_THEME="luci-theme-argon-[0-9][0-9.]*-r[0-9]*\.apk"
    A_CONF="luci-app-argon-config-[0-9][0-9.]*-r[0-9]*\.apk"
    A_I18N="luci-i18n-argon-config-zh-cn-[0-9A-Za-z._~+-]*\.apk"
fi

ARGON_FILES=""
_json=$(owp_gh_releases "$ARGON_REPO")
if [ -n "$_json" ]; then
    A_TAG="${ARGON_TAG:-$(owp_gh_pick_tag "$_json" '^v[0-9]')}"
    for _pat in "$A_THEME" "$A_CONF" $A_I18N; do
        _u=$(owp_gh_asset "$_json" "$A_TAG" "$_pat")
        [ -n "$_u" ] || { warn "Release $A_TAG 里没有匹配 $_pat 的资产"; continue; }
        _f="$OWP_TMP/$(basename "$_u")"
        log "下载 $(basename "$_u")"
        owp_download "$_u" "$_f" && ARGON_FILES="$ARGON_FILES $_f" || warn "下载失败: $_u"
    done
else
    warn "无法访问 GitHub API,跳过 Argon 主题"
fi

if [ -n "$ARGON_FILES" ]; then
    owp_pkg_install_local $ARGON_FILES
    if owp_pkg_installed luci-theme-argon; then
        ok "Argon 主题已安装 ($A_TAG)"
        uci set luci.main.mediaurlbase='/luci-static/argon' 2>/dev/null && uci commit luci 2>/dev/null
        OWP_OK_LIST="$OWP_OK_LIST luci-theme-argon"
    else
        OWP_FAIL_LIST="$OWP_FAIL_LIST luci-theme-argon"
    fi
fi

# ---------- 3. ddns-go ----------
title "ddns-go"
if ! owp_in_list "$OWP_ARCH" "$OWP_DDNSGO_ARCHS"; then
    warn "上游只为 10 种架构编译 ddns-go,不含 $OWP_ARCH,跳过"
    OWP_FAIL_LIST="$OWP_FAIL_LIST ddns-go(架构不支持)"
else
    if [ "$OWP_PM" = opkg ]; then
        D_PAT="openwrt-24\.10-${OWP_ARCH}\.tar\.gz"
        D_EXT="ipk"
    else
        D_PAT="SNAPSHOT-${OWP_ARCH}\.tar\.gz"
        D_EXT="apk"
    fi
    _json=$(owp_gh_releases "$DDNSGO_REPO")
    D_URL=""
    if [ -n "$_json" ]; then
        D_TAG="${DDNSGO_TAG:-$(owp_gh_pick_tag "$_json" '^v[0-9]')}"
        D_URL=$(owp_gh_asset "$_json" "$D_TAG" "$D_PAT")
    fi
    if [ -z "$D_URL" ]; then
        warn "找不到 ddns-go 资产($D_PAT),跳过"
        OWP_FAIL_LIST="$OWP_FAIL_LIST ddns-go"
    else
        D_TGZ="$OWP_TMP/ddns-go.tar.gz"
        log "下载 $(basename "$D_URL")"
        if owp_download "$D_URL" "$D_TGZ"; then
            rm -rf "$OWP_TMP/ddnsgo"; mkdir -p "$OWP_TMP/ddnsgo"
            if tar -xzf "$D_TGZ" -C "$OWP_TMP/ddnsgo" 2>/dev/null; then
                # 顺序重要: 先装 ddns-go 二进制包,再装 LuCI 界面
                D_CORE=$(find "$OWP_TMP/ddnsgo" -name "ddns-go[-_]*.$D_EXT" | head -n1)
                D_APP=$(find "$OWP_TMP/ddnsgo" -name "luci-app-ddns-go[-_]*.$D_EXT" | head -n1)
                D_I18N=$(find "$OWP_TMP/ddnsgo" -name "luci-i18n-ddns-go-zh-cn[-_]*.$D_EXT" | head -n1)
                [ -n "$D_CORE" ] && owp_pkg_install_local "$D_CORE"
                [ -n "$D_APP" ] && owp_pkg_install_local "$D_APP" ${D_I18N:+"$D_I18N"}
                if owp_pkg_installed luci-app-ddns-go; then
                    ok "ddns-go 已安装 ($D_TAG)"
                    [ -x /etc/init.d/ddns-go ] && {
                        /etc/init.d/ddns-go enable  >/dev/null 2>&1
                        /etc/init.d/ddns-go restart >/dev/null 2>&1
                    }
                    OWP_OK_LIST="$OWP_OK_LIST ddns-go luci-app-ddns-go"
                else
                    OWP_FAIL_LIST="$OWP_FAIL_LIST luci-app-ddns-go"
                fi
            else
                warn "tar 解包失败"
                OWP_FAIL_LIST="$OWP_FAIL_LIST ddns-go"
            fi
        else
            OWP_FAIL_LIST="$OWP_FAIL_LIST ddns-go"
        fi
    fi
fi

owp_swap_off
owp_luci_flush
owp_summary
