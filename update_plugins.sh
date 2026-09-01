#!/bin/sh
# ==============================================================
# update_plugins.sh - OpenWrt 插件一键安装菜单
# https://github.com/JBl9527/update_plugins.sh
#
# 用法:
#   sh update_plugins.sh              交互菜单
#   sh update_plugins.sh check        只做环境自检
#   sh update_plugins.sh nikki        直接装某个插件
#   sh update_plugins.sh all          全家桶
# ==============================================================

OWP_BASE_URL="${OWP_BASE_URL:-https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main}"
OWP_COMMON="${OWP_COMMON:-/tmp/owp-common.sh}"
export OWP_BASE_URL OWP_COMMON

fetch() {
    _u="$1"; _o="$2"
    _u="$(printf '%s' "$_u" | sed 's/+/%2B/g')?t=$(date +%s)"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 15 "$_u" -o "$_o" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$_o" "$_u" && return 0
    fi
    rm -f "$_o" 2>/dev/null
    return 1
}

# 公共库只下一次,后面所有模块共用
load_common() {
    if [ ! -s "$OWP_COMMON" ]; then
        fetch "$OWP_BASE_URL/common.sh" "$OWP_COMMON" || {
            echo "[ERROR] 无法下载 common.sh,请检查网络 / DNS / 时间是否正确"
            exit 1
        }
    fi
    . "$OWP_COMMON"
}

run_plugin() {
    _name="$1"
    _tmp="/tmp/owp-$(printf '%s' "$_name" | tr '+' '_')"
    printf '\n>>> %s\n' "$_name"
    if ! fetch "$OWP_BASE_URL/$_name" "$_tmp"; then
        echo "[ERROR] 下载 $_name 失败"
        return 1
    fi
    [ -s "$_tmp" ] || { echo "[ERROR] $_name 内容为空"; rm -f "$_tmp"; return 1; }
    sh "$_tmp"
    _rc=$?
    rm -f "$_tmp"
    return $_rc
}

install_all() {
    for _m in "DDNS+argo+qr.sh" openclash.sh passwall.sh nikki.sh homeproxy.sh dae.sh; do
        run_plugin "$_m" || echo "[WARN] $_m 未完全成功,继续下一个"
    done
}

dispatch() {
    case "$1" in
        check|1)       load_common; owp_env_report ;;
        base|qr|2)     run_plugin "DDNS+argo+qr.sh" ;;
        openclash|3)   run_plugin "openclash.sh" ;;
        passwall|4)    run_plugin "passwall.sh" ;;
        nikki|5)       run_plugin "nikki.sh" ;;
        homeproxy|6)   run_plugin "homeproxy.sh" ;;
        daed|dae|7)    run_plugin "dae.sh" ;;
        all|8)         install_all ;;
        0|q|quit|exit) return 9 ;;
        *)             echo "无效选项: $1"; return 1 ;;
    esac
}

menu() {
    while :; do
        cat <<'EOF'

============================================
      OpenWrt 插件一键安装 (opkg / apk 自适应)
============================================
  1) 环境自检 —— 先看这个,会列出每个插件能不能装
  2) 基础套件   qrencode + Argon 主题 + ddns-go + WireGuard
  3) OpenClash
  4) PassWall / PassWall2
  5) nikki (Mihomo)          需要 24.10+
  6) homeproxy (sing-box)
  7) daed (dae eBPF)         需要内核 BTF
  8) 全家桶(按顺序全装)
  0) 退出
============================================
EOF
        printf "请选择: "
        read -r choice
        dispatch "$choice"
        [ $? = 9 ] && break
        printf "\n按回车返回菜单..."
        read -r _dummy
    done
}

[ "$(id -u)" = 0 ] || { echo "[ERROR] 需要 root 权限运行"; exit 1; }
[ -f /etc/openwrt_release ] || { echo "[ERROR] 这不是 OpenWrt 系统"; exit 1; }

if [ $# -gt 0 ]; then
    dispatch "$1"
    exit $?
fi
menu
