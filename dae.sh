#!/bin/sh
# ==============================================================
# dae.sh - 安装 daed (dae 的 Web 面板, eBPF 透明代理)
# 上游: https://github.com/daeuniverse/daed
# LuCI: https://github.com/QiuSimons/luci-app-daed
#
# 2026-09 核实要点:
#   * daeuniverse/daed 的 /releases/latest 已经被 dae-lang-core-* 这类
#     无资产的子组件 release 抢占,直接用 latest 会拿到空 release。
#     必须按 tag 正则 ^v[0-9] 自己挑。
#   * QiuSimons/luci-app-daed 现在同时发 daed 主体和 LuCI 界面,
#     并且已经区分 24.10(ipk) / 25.12(apk),但只有三种架构:
#     x86_64 / i386_pentium4 / aarch64_generic
#   * 它的 daed 包依赖 vmlinux-btf —— 这个包官方 OpenWrt 源里不存在
#     (是 ImmortalWrt 的包),所以必须 --force-depends 装
#   * daed 需要内核 >= 5.8 且带 BTF,否则 eBPF 加载失败、服务起不来
# ==============================================================

OWP_BASE_URL="${OWP_BASE_URL:-https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main}"
OWP_COMMON="${OWP_COMMON:-/tmp/owp-common.sh}"
if [ ! -s "$OWP_COMMON" ]; then
    curl -fsSL "$OWP_BASE_URL/common.sh" -o "$OWP_COMMON" 2>/dev/null || \
    wget -qO "$OWP_COMMON" "$OWP_BASE_URL/common.sh" 2>/dev/null
fi
[ -s "$OWP_COMMON" ] || { echo "[ERROR] 无法获取 common.sh,请检查网络"; exit 1; }
. "$OWP_COMMON"

DAED_REPO="daeuniverse/daed"
LUCI_REPO="QiuSimons/luci-app-daed"
DAED_BIN="/usr/bin/daed"
DAED_SHARE="/usr/share/daed"

owp_init "daed (dae eBPF) 安装"

# ---------- 内核能力检查 ----------
_kv=$(uname -r | cut -d- -f1 | cut -d. -f1,2)
owp_ver_ge "$_kv" 5.8 || warn "内核 $OWP_KERNEL 低于 5.8,daed 无法运行"
[ "$OWP_BTF" = 1 ] || warn "未检测到 /sys/kernel/btf/vmlinux —— daed 依赖 CO-RE,缺 BTF 服务会启动失败"
if [ -r /proc/config.gz ] && owp_have zcat; then
    _miss=""
    for _o in CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_DEBUG_INFO_BTF; do
        zcat /proc/config.gz 2>/dev/null | grep -q "^${_o}=y$" || _miss="$_miss $_o"
    done
    [ -z "$_miss" ] || warn "内核可能缺少:$_miss"
fi

owp_pkg_update
owp_swap_on 256

log "安装官方源里的依赖"
owp_pkg_install ca-bundle luci-compat luci-lua-runtime zoneinfo-asia \
                v2ray-geoip v2ray-geosite kmod-sched-core kmod-sched-bpf kmod-veth

# ---------- 路线 A: QiuSimons 的成品包(带 LuCI 界面) ----------
install_via_luci_repo() {
    owp_in_list "$OWP_ARCH" "$OWP_DAED_ARCHS" || return 1
    _json=$(owp_gh_releases "$LUCI_REPO") || return 1
    [ -n "$_json" ] || return 1
    _tag="${DAED_LUCI_TAG:-$(owp_gh_pick_tag "$_json" '^daed_')}"
    [ -n "$_tag" ] || return 1
    log "LuCI 包版本 $_tag"

    if [ "$OWP_PM" = opkg ]; then
        _p_core="/daed_[0-9][0-9A-Za-z.~-]*_${OWP_ARCH}-openwrt-24\.10\.ipk\$"
        _p_app="/luci-app-daed_[0-9A-Za-z.~-]*_all-openwrt-24\.10\.ipk\$"
        _p_i18n="/luci-i18n-daed-zh-cn_[0-9A-Za-z.~-]*_all-openwrt-24\.10\.ipk\$"
    else
        _p_core="/daed-[0-9][0-9A-Za-z.~-]*-${OWP_ARCH}-openwrt-25\.12\.apk\$"
        _p_app="/luci-app-daed-[0-9A-Za-z.~-]*-openwrt-25\.12\.apk\$"
        _p_i18n="/luci-i18n-daed-zh-cn-[0-9A-Za-z.~-]*-openwrt-25\.12\.apk\$"
    fi

    _files=""
    for _pat in "$_p_core" "$_p_app" "$_p_i18n"; do
        _u=$(owp_gh_asset "$_json" "$_tag" "$_pat")
        [ -n "$_u" ] || { warn "Release $_tag 里没有匹配的资产: $_pat"; continue; }
        _f="$OWP_TMP/$(basename "$_u")"
        log "下载 $(basename "$_u")"
        owp_download "$_u" "$_f" && _files="$_files $_f"
    done
    [ -n "$_files" ] || return 1

    # daed 包硬依赖 vmlinux-btf,官方源没有这个包,只能强行忽略依赖
    log "安装 daed 与 LuCI 界面 (忽略 vmlinux-btf 依赖)"
    case "$OWP_PM" in
        opkg) opkg install --force-overwrite --force-depends $_files ;;
        apk)  apk add -q --allow-untrusted --force-overwrite --force-missing-repositories $_files 2>/dev/null \
              || apk add -q --allow-untrusted --force-overwrite $_files ;;
    esac
    owp_pkg_installed luci-app-daed
}

# ---------- 路线 B: 官方二进制 + 自写 procd 服务(无 LuCI 界面) ----------
# 架构名映射在 common.sh 的 owp_daed_bin_arch 里

write_init_script() {
    cat > /etc/init.d/daed <<'EOF_INIT'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
CONF="daed"
LOG="/var/log/daed/daed.log"

start_service() {
    config_load "$CONF"
    local enabled listen_addr
    config_get_bool enabled "config" "enabled" "0"
    [ "$enabled" -eq 1 ] || return 1
    config_get listen_addr "config" "listen_addr" "0.0.0.0:2023"
    mkdir -p /var/log/daed
    procd_open_instance
    procd_set_param command /usr/bin/daed run
    procd_append_param command --config /etc/daed/
    procd_append_param command --listen "$listen_addr"
    procd_append_param command --logfile "$LOG"
    procd_set_param env DAE_LOCATION_ASSET="/usr/share/daed"
    procd_set_param respawn 3600 5 5
    procd_set_param limits nofile="1048576 1048576"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "$CONF"
}
EOF_INIT
    chmod 755 /etc/init.d/daed
    mkdir -p /etc/config /etc/daed /var/log/daed
    if [ ! -f /etc/config/daed ]; then
        printf "config daed 'config'\n\toption enabled '0'\n\toption listen_addr '0.0.0.0:2023'\n" \
            > /etc/config/daed
        chmod 600 /etc/config/daed
    fi
}

install_via_binary() {
    _da=$(owp_daed_bin_arch)
    [ -n "$_da" ] || { err "daeuniverse 没有为 $OWP_ARCH 发布二进制"; return 1; }
    owp_have unzip || owp_pkg_install unzip
    owp_have unzip || { err "缺少 unzip,无法解压 daed 发布包"; return 1; }

    _json=$(owp_gh_releases "$DAED_REPO") || return 1
    # 关键: 过滤 ^v[0-9],否则会拿到 dae-lang-core-* 这种没有资产的 release
    _tag="${DAED_TAG:-$(owp_gh_pick_tag "$_json" '^v[0-9]')}"
    [ -n "$_tag" ] || { err "无法确定 daed 版本"; return 1; }
    log "daed 版本 $_tag (资产架构 $_da)"

    _zip="$OWP_TMP/daed-linux-${_da}.zip"
    _url=$(owp_gh_asset "$_json" "$_tag" "/daed-linux-${_da}\.zip\$")
    [ -n "$_url" ] || _url="https://github.com/$DAED_REPO/releases/download/$_tag/daed-linux-${_da}.zip"
    owp_download "$_url" "$_zip" || { err "下载失败: $_url"; return 1; }
    unzip -t "$_zip" >/dev/null 2>&1 || { err "压缩包校验失败"; return 1; }

    rm -rf "$OWP_TMP/x"; mkdir -p "$OWP_TMP/x"
    unzip -q -o "$_zip" -d "$OWP_TMP/x" || { err "解压失败"; return 1; }
    _src="$OWP_TMP/x/daed-linux-${_da}"
    [ -f "$_src/daed-linux-${_da}" ] || { err "包内结构与预期不符"; return 1; }

    [ -x /etc/init.d/daed ] && /etc/init.d/daed stop >/dev/null 2>&1
    mkdir -p "$DAED_SHARE" /etc/daed
    cp "$_src/daed-linux-${_da}" "$DAED_BIN" || { err "写入 $DAED_BIN 失败(空间不足?)"; return 1; }
    chmod 755 "$DAED_BIN"
    for _d in geoip.dat geosite.dat; do
        [ -f "$_src/$_d" ] && cp "$_src/$_d" "$DAED_SHARE/$_d" || warn "包内缺少 $_d"
    done
    write_init_script
    "$DAED_BIN" --version >/dev/null 2>&1 && ok "自检通过: $("$DAED_BIN" --version 2>&1 | head -n1)" \
        || warn "daed --version 自检未通过,请确认架构是否匹配"
    return 0
}

# ---------- 主流程 ----------
if install_via_luci_repo; then
    DAED_MODE="luci"
    OWP_OK_LIST="$OWP_OK_LIST daed luci-app-daed"
else
    warn "成品包路线不可用($OWP_ARCH 可能不在 $OWP_DAED_ARCHS 里),改用官方二进制 + 自写服务"
    if install_via_binary; then
        DAED_MODE="binary"
        OWP_OK_LIST="$OWP_OK_LIST daed(二进制)"
    else
        owp_swap_off
        die "daed 安装失败"
    fi
fi

owp_swap_off
owp_luci_flush

title "后续操作"
if [ "$DAED_MODE" = luci ]; then
    printf "  LuCI 里位于「服务 -> daed」,面板默认 http://<路由IP>:2023\n"
else
    printf "  未安装 LuCI 界面(该架构没有成品包),用命令行启用:\n"
    printf "    uci set daed.config.enabled='1' && uci commit daed\n"
    printf "    /etc/init.d/daed enable && /etc/init.d/daed start\n"
    printf "  面板地址 http://<路由IP>:2023\n"
fi
printf "  启动后务必检查: logread -e daed   (确认 eBPF 加载成功,无 BTF/BPF 报错)\n"
[ "$OWP_BTF" = 1 ] || printf "  ${C_Y}当前内核没有 BTF,服务大概率起不来 —— 需要换带 CONFIG_DEBUG_INFO_BTF 的固件${C_N}\n"

owp_summary
