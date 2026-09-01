#!/bin/sh
# ==============================================================
# common.sh - OpenWrt 插件安装脚本公共库 (POSIX sh / busybox ash)
# 项目: https://github.com/JBl9527/update_plugins.sh
#
# 2026-09 核实过的关键前提:
#   * OpenWrt 21.02/22.03/23.05/24.10 -> opkg + .ipk
#   * OpenWrt 25.12 及更新、SNAPSHOT  -> apk  + .apk (packages.adb)
#   * 官方源里有: qrencode sing-box firewall4 luci-compat luci-lua-runtime
#                 ucode-mod-digest(24.10+) kmod-*(走 kmods feed)
#   * 官方源里没有: openclash passwall homeproxy nikki argon ddns-go daed
#   * dl.openwrt.ai(kiddin9) 已不可用于纯净 OpenWrt,禁止加为软件源
# ==============================================================

[ -n "${__OWP_COMMON_LOADED:-}" ] && return 0
__OWP_COMMON_LOADED=1

OWP_LIB_VERSION="2026.09.01"
OWP_UA="openwrt-plugin-installer/$OWP_LIB_VERSION"
OWP_TMP="${OWP_TMP:-/tmp/owp-work}"
OWP_OPKG_FEEDS="/etc/opkg/customfeeds.conf"
OWP_OPKG_CONF="/etc/opkg.conf"
OWP_APK_FEEDS="/etc/apk/repositories.d/customfeeds.list"
OWP_APK_KEYS="/etc/apk/keys"

OWP_OK_LIST=""
OWP_FAIL_LIST=""
OWP_SIGCHECK_OFF=0
OWP_SWAP_FILE=""

# ---------------- 输出 ----------------
if [ -t 1 ]; then
    C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[0;33m'
    C_C='\033[0;36m'; C_B='\033[1m';    C_N='\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_C=''; C_B=''; C_N=''
fi

log()   { printf "${C_C}==>${C_N} %s\n" "$*"; }
ok()    { printf "${C_G} +${C_N} %s\n" "$*"; }
warn()  { printf "${C_Y} !${C_N} %s\n" "$*" >&2; }
err()   { printf "${C_R} x${C_N} %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }
title() { printf "\n${C_B}%s${C_N}\n" "$*"; }

# ---------------- 基础工具 ----------------

# 版本号比较: owp_ver_ge 24.10 25.12  -> 假
# SNAPSHOT 视为最新
owp_ver_ge() {
    case "$1" in *SNAPSHOT*|snapshot*) return 0 ;; esac
    case "$2" in *SNAPSHOT*|snapshot*) return 1 ;; esac
    _a1=$(printf '%s' "$1" | cut -d. -f1); _a2=$(printf '%s' "$1" | cut -d. -f2)
    _b1=$(printf '%s' "$2" | cut -d. -f1); _b2=$(printf '%s' "$2" | cut -d. -f2)
    for _v in _a1 _a2 _b1 _b2; do
        eval "_t=\$$_v"
        case "$_t" in ''|*[!0-9]*) eval "$_v=0" ;; esac
    done
    [ "$_a1" -gt "$_b1" ] && return 0
    [ "$_a1" -lt "$_b1" ] && return 1
    [ "$_a2" -ge "$_b2" ] && return 0
    return 1
}

owp_have() { command -v "$1" >/dev/null 2>&1; }

# 下载: 不使用 -k / --no-check-certificate,证书由 ca-bundle 保障
owp_download() {
    _url="$1"; _out="$2"
    if owp_have curl; then
        curl -fsSL --retry 3 --connect-timeout 15 -A "$OWP_UA" \
             -H "Accept: application/vnd.github+json" "$_url" -o "$_out" && return 0
    fi
    if owp_have wget; then
        wget -qO "$_out" --user-agent="$OWP_UA" "$_url" && return 0
    fi
    if owp_have uclient-fetch; then
        uclient-fetch -qO "$_out" "$_url" && return 0
    fi
    rm -f "$_out" 2>/dev/null
    return 1
}

# URL 里的 + 必须编码成 %2B (PassWall 的 25.12+ 前缀资产会踩到)
owp_urlenc_plus() { printf '%s' "$1" | sed 's/+/%2B/g'; }

owp_file_drop_lines() {
    _f="$1"; _p="$2"
    [ -f "$_f" ] || return 0
    { grep -v -- "$_p" "$_f" || true; } > "${_f}.owptmp" 2>/dev/null
    mv "${_f}.owptmp" "$_f" 2>/dev/null || rm -f "${_f}.owptmp"
}

# ---------------- 环境探测 ----------------

owp_detect_env() {
    [ -f /etc/openwrt_release ] || die "未检测到 OpenWrt (缺少 /etc/openwrt_release)"
    . /etc/openwrt_release
    OWP_RELEASE="${DISTRIB_RELEASE:-unknown}"
    OWP_DESC="${DISTRIB_DESCRIPTION:-unknown}"
    OWP_TARGET="${DISTRIB_TARGET:-unknown}"
    OWP_ARCH="${DISTRIB_ARCH:-}"

    if [ -z "$OWP_ARCH" ] && [ -f /etc/os-release ]; then
        OWP_ARCH=$(sed -n 's/^OPENWRT_ARCH="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -n1)
    fi
    if [ -z "$OWP_ARCH" ] && owp_have opkg; then
        OWP_ARCH=$(opkg print-architecture 2>/dev/null | \
                   awk '$3!="all" && $3!="noarch" && $2!="" {a=$2} END{print a}')
    fi
    if [ -z "$OWP_ARCH" ] && owp_have apk; then
        OWP_ARCH=$(apk --print-arch 2>/dev/null | head -n1)
    fi
    [ -n "$OWP_ARCH" ] || die "无法确定 OpenWrt 架构名,请手动 export DISTRIB_ARCH=<架构> 后重试"

    # 主版本号: 24.10.8 -> 24.10 ; 25.12-SNAPSHOT -> SNAPSHOT
    case "$OWP_RELEASE" in
        *SNAPSHOT*|*snapshot*) OWP_BRANCH="SNAPSHOT" ;;
        *) OWP_BRANCH=$(printf '%s' "$OWP_RELEASE" | cut -d. -f1,2) ;;
    esac

    # 包管理器: 两个都在时按版本裁决 (25.12+ = apk)
    OWP_PM=""
    if owp_have apk && owp_have opkg; then
        if owp_ver_ge "$OWP_BRANCH" 25.12; then OWP_PM=apk; else OWP_PM=opkg; fi
    elif owp_have apk; then
        OWP_PM=apk
    elif owp_have opkg; then
        OWP_PM=opkg
    fi
    [ -n "$OWP_PM" ] || die "未找到 opkg 或 apk,无法继续"

    OWP_KERNEL=$(uname -r)
    OWP_FW4=0
    if [ -x /sbin/fw4 ] || owp_have fw4 || [ -d /usr/share/nftables.d ]; then OWP_FW4=1; fi
    OWP_BTF=0
    { [ -r /sys/kernel/btf/vmlinux ] || [ -r /usr/lib/debug/boot/vmlinux ]; } && OWP_BTF=1
    mkdir -p "$OWP_TMP" 2>/dev/null
}

# ---------------- 软件源 / 签名 ----------------

# 清理旧版本脚本留下的失效源(dl.openwrt.ai 已不再提供纯净 OpenWrt 可用的源,
# 留着会让 opkg update 每次报错)
owp_clean_legacy_feeds() {
    for _f in "$OWP_OPKG_FEEDS" "$OWP_APK_FEEDS" /etc/apk/repositories; do
        [ -f "$_f" ] || continue
        if grep -q "dl\.openwrt\.ai" "$_f" 2>/dev/null; then
            warn "清理失效源 dl.openwrt.ai ($_f)"
            owp_file_drop_lines "$_f" "dl\.openwrt\.ai"
        fi
        owp_file_drop_lines "$_f" "custom_plugins"
    done
}

# owp_feed_add <名称> <目录URL>
#   opkg: src/gz <名称> <目录URL>
#   apk : <目录URL>/packages.adb
# 幂等: 先按名称删除旧行再写入
owp_feed_add() {
    _name="$1"; _url="$2"
    case "$OWP_PM" in
        opkg)
            mkdir -p /etc/opkg
            touch "$OWP_OPKG_FEEDS"
            owp_file_drop_lines "$OWP_OPKG_FEEDS" "[[:space:]]${_name}[[:space:]]"
            printf 'src/gz %s %s\n' "$_name" "$_url" >> "$OWP_OPKG_FEEDS"
            ;;
        apk)
            mkdir -p /etc/apk/repositories.d
            touch "$OWP_APK_FEEDS"
            owp_file_drop_lines "$OWP_APK_FEEDS" "/${_name}/"
            printf '%s/packages.adb\n' "$_url" >> "$OWP_APK_FEEDS"
            ;;
    esac
    ok "已添加软件源 $_name"
}

owp_feed_del() {
    _name="$1"
    owp_file_drop_lines "$OWP_OPKG_FEEDS" "[[:space:]]${_name}[[:space:]]"
    owp_file_drop_lines "$OWP_APK_FEEDS" "/${_name}/"
}

# owp_key_add <名称> <公钥URL>
#   opkg 用 usign 公钥 (opkg-key add)
#   apk  用 PEM 公钥 (放进 /etc/apk/keys/<名称>.pem)
owp_key_add() {
    _name="$1"; _url="$2"
    _kf="$OWP_TMP/${_name}.key"
    if ! owp_download "$_url" "$_kf"; then
        warn "公钥下载失败: $_url"
        return 1
    fi
    case "$OWP_PM" in
        opkg)
            if owp_have opkg-key && opkg-key add "$_kf" >/dev/null 2>&1; then
                ok "已导入 $_name 公钥"
            else
                warn "$_name 公钥导入失败,将临时关闭 opkg 签名校验"
                owp_sigcheck_off
            fi
            ;;
        apk)
            mkdir -p "$OWP_APK_KEYS"
            cp "$_kf" "$OWP_APK_KEYS/${_name}.pem" && ok "已导入 $_name 公钥"
            ;;
    esac
}

owp_sigcheck_off() {
    [ "$OWP_PM" = opkg ] || return 0
    [ -f "$OWP_OPKG_CONF" ] || return 0
    grep -qE '^[[:space:]]*option[[:space:]]+check_signature' "$OWP_OPKG_CONF" || return 0
    sed -i 's/^[[:space:]]*option[[:space:]]\{1,\}check_signature/#option check_signature/' "$OWP_OPKG_CONF"
    OWP_SIGCHECK_OFF=1
}

owp_sigcheck_restore() {
    [ "$OWP_SIGCHECK_OFF" = 1 ] || return 0
    sed -i 's/^[[:space:]]*#[[:space:]]*option[[:space:]]\{1,\}check_signature/option check_signature/' \
        "$OWP_OPKG_CONF" 2>/dev/null
    OWP_SIGCHECK_OFF=0
}

# ---------------- 包管理 ----------------

owp_pkg_update() {
    log "刷新软件源索引 ($OWP_PM)"
    case "$OWP_PM" in
        opkg) rm -f /var/lock/opkg.lock 2>/dev/null; opkg update || warn "opkg update 有失败项,继续" ;;
        apk)  apk update || warn "apk update 有失败项,继续" ;;
    esac
}

owp_pkg_installed() {
    case "$OWP_PM" in
        opkg) opkg list-installed 2>/dev/null | grep -q "^$1 " ;;
        apk)  apk info -e "$1" 2>/dev/null | grep -q . || \
              apk list -I "$1" 2>/dev/null | grep -q . ;;
    esac
}

# 索引里是否存在该包(用于依赖预检)
owp_pkg_available() {
    case "$OWP_PM" in
        opkg) opkg info "$1" 2>/dev/null | grep -q "^Package: $1$" ;;
        apk)  apk list "$1" 2>/dev/null | grep -q . ;;
    esac
}

# 逐个安装,失败不中断,结果记入 OWP_OK_LIST / OWP_FAIL_LIST
owp_pkg_install() {
    for _p in "$@"; do
        [ -n "$_p" ] || continue
        if owp_pkg_installed "$_p"; then
            OWP_OK_LIST="$OWP_OK_LIST $_p"
            continue
        fi
        case "$OWP_PM" in
            opkg) opkg install --force-overwrite "$_p" >/dev/null 2>&1 ;;
            apk)  apk add --force-overwrite "$_p" >/dev/null 2>&1 ;;
        esac
        if owp_pkg_installed "$_p"; then
            ok "$_p"
            OWP_OK_LIST="$OWP_OK_LIST $_p"
        else
            warn "$_p 安装失败"
            OWP_FAIL_LIST="$OWP_FAIL_LIST $_p"
        fi
    done
}

# 关键包安装: 失败即返回非 0,由调用方决定是否中止
owp_pkg_install_strict() {
    case "$OWP_PM" in
        opkg) opkg install --force-overwrite "$@" ;;
        apk)  apk add --force-overwrite "$@" ;;
    esac
}

# 安装本地包文件(第三方 Release 下载的 ipk/apk 没有本地源签名)
owp_pkg_install_local() {
    [ $# -gt 0 ] || return 1
    case "$OWP_PM" in
        opkg)
            if ! opkg install --force-overwrite "$@"; then
                warn "常规安装失败,改用 --force-depends 重试"
                opkg install --force-overwrite --force-depends "$@"
            fi
            ;;
        apk)
            apk add -q --allow-untrusted --force-overwrite --clean-protected "$@"
            ;;
    esac
}

# dnsmasq-full 替换 dnsmasq: OpenClash / PassWall 的 ipset/nftset 分流依赖它
owp_ensure_dnsmasq_full() {
    owp_pkg_installed dnsmasq-full && { ok "dnsmasq-full 已安装"; return 0; }
    log "用 dnsmasq-full 替换 dnsmasq"
    case "$OWP_PM" in
        opkg)
            # 先把包下到本地再卸 dnsmasq,避免下载失败导致 DNS 直接瘫掉
            rm -f "$OWP_TMP"/dnsmasq-full*.ipk 2>/dev/null
            ( cd "$OWP_TMP" && opkg download dnsmasq-full >/dev/null 2>&1 )
            _dl=$(ls "$OWP_TMP"/dnsmasq-full*.ipk 2>/dev/null | head -n1)
            if [ -n "$_dl" ] && [ -f "$_dl" ]; then
                opkg remove dnsmasq --force-depends >/dev/null 2>&1
                opkg install --force-overwrite "$_dl" || warn "dnsmasq-full 安装失败"
            else
                opkg install --force-overwrite dnsmasq-full || warn "dnsmasq-full 安装失败"
            fi
            ;;
        apk)
            apk add --force-overwrite dnsmasq-full || warn "dnsmasq-full 安装失败"
            ;;
    esac
    owp_pkg_installed dnsmasq-full || warn "dnsmasq-full 仍未就绪,基于域名的分流可能不可用"
}

# ---------------- 临时 swap (小内存设备装大包用) ----------------

owp_swap_on() {
    _mb="${1:-256}"; _path="${2:-/root/.owp-swapfile}"
    grep -q "$_path" /proc/swaps 2>/dev/null && { OWP_SWAP_FILE="$_path"; return 0; }
    _free=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [ -n "$_free" ] || _free=0
    [ "$_free" -gt 192 ] && return 0     # 内存够用就不折腾 swap
    _avail=$(df -k /root 2>/dev/null | awk 'NR==2{print int($4/1024)}')
    [ -n "$_avail" ] || _avail=0
    if [ "$_avail" -lt $((_mb + 32)) ]; then
        warn "剩余空间不足,跳过临时 swap (可用 ${_avail}MB)"
        return 0
    fi
    log "内存偏小(可用 ${_free}MB),挂载 ${_mb}MB 临时 swap"
    dd if=/dev/zero of="$_path" bs=1M count="$_mb" >/dev/null 2>&1 || { rm -f "$_path"; return 0; }
    chmod 600 "$_path" 2>/dev/null
    mkswap "$_path" >/dev/null 2>&1 && swapon "$_path" >/dev/null 2>&1 \
        && { OWP_SWAP_FILE="$_path"; ok "临时 swap 已挂载"; } \
        || rm -f "$_path"
}

owp_swap_off() {
    [ -n "$OWP_SWAP_FILE" ] || return 0
    swapoff "$OWP_SWAP_FILE" >/dev/null 2>&1
    rm -f "$OWP_SWAP_FILE"
    OWP_SWAP_FILE=""
}

owp_luci_flush() {
    rm -rf /tmp/luci-modulecache /tmp/luci-indexcache* /tmp/.luci-* \
           /var/run/luci-indexcache /var/run/luci-modulecache 2>/dev/null
    [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1
    [ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd reload >/dev/null 2>&1
    return 0
}

# ---------------- GitHub Release ----------------
# 不用 /releases/latest: daeuniverse/daed 的 latest 会被 dae-lang-core-* 这类
# 无资产的子组件 release 抢占,必须自己按 tag 正则挑。

owp_gh_releases() {
    _repo="$1"; _json="$OWP_TMP/$(printf '%s' "$_repo" | tr '/' '_').json"
    if owp_download "https://api.github.com/repos/$_repo/releases?per_page=30" "$_json"; then
        printf '%s' "$_json"
        return 0
    fi
    return 1
}

# owp_gh_pick_tag <json> <tag正则>
owp_gh_pick_tag() {
    if owp_have jsonfilter; then
        jsonfilter -i "$1" -e '@[*].tag_name' 2>/dev/null | grep -E "$2" | head -n1
        return 0
    fi
    sed 's/"tag_name"/\n"tag_name"/g' "$1" 2>/dev/null | \
        sed -n 's/^"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
        grep -E "$2" | head -n1
}

# owp_gh_asset <json> <tag> <文件名正则>  -> 下载直链
owp_gh_asset() {
    sed 's/"browser_download_url"/\n"browser_download_url"/g' "$1" 2>/dev/null | \
        sed -n 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
        grep -F "/download/$2/" | grep -E "$3" | head -n1
}

# API 不可用时的兜底: 解析 Release 资产页
owp_gh_asset_html() {
    _repo="$1"; _tag="$2"; _pat="$3"
    _h="$OWP_TMP/gh-assets.html"
    owp_download "https://github.com/$_repo/releases/expanded_assets/$_tag" "$_h" || return 1
    grep -o "/$_repo/releases/download/[^\"'<> ]*" "$_h" | grep -E "$_pat" | head -n1 | \
        sed 's|^|https://github.com|'
}

# ---------------- HTML 目录列表取包名 ----------------
# 用于 downloads.immortalwrt.org 这类版本号随构建变化、无法硬编码文件名的源。
# owp_dir_pick <目录URL> <完整文件名正则>  -> 完整 URL
owp_dir_pick() {
    _dir="${1%/}"; _pat="$2"
    _h="$OWP_TMP/dirlist.html"
    owp_download "$_dir/" "$_h" || return 1
    _name=$(grep -oE "$_pat" "$_h" 2>/dev/null | sort -u | tail -n1)
    [ -n "$_name" ] || return 1
    printf '%s/%s' "$_dir" "$_name"
}

# ---------------- 依赖预检 ----------------
# 只做"索引里有没有",不安装。缺失项打印出来,返回缺失个数。
owp_check_deps() {
    _miss=""
    for _p in "$@"; do
        [ -n "$_p" ] || continue
        owp_pkg_installed "$_p" && continue
        owp_pkg_available "$_p" && continue
        _miss="$_miss $_p"
    done
    if [ -n "$_miss" ]; then
        warn "以下依赖在当前软件源里找不到:$_miss"
        printf '%s' "$_miss" > "$OWP_TMP/missing"
        return 1
    fi
    ok "依赖预检通过"
    return 0
}

owp_summary() {
    title "安装结果"
    [ -n "$OWP_OK_LIST" ] && printf "${C_G}成功:${C_N}%s\n" "$OWP_OK_LIST"
    if [ -n "$OWP_FAIL_LIST" ]; then
        printf "${C_R}失败:${C_N}%s\n" "$OWP_FAIL_LIST"
        printf "%s\n" "排查建议: 先 $OWP_PM update,再单独安装失败的包看完整报错"
        return 1
    fi
    return 0
}

# ---------------- 生命周期 ----------------

OWP_LOCKDIR="/tmp/owp-install.lock"
OWP_LOCK_HELD=0

owp_cleanup() {
    owp_sigcheck_restore
    owp_swap_off
    if [ "$OWP_LOCK_HELD" = 1 ]; then
        rm -rf "$OWP_TMP"
        rmdir "$OWP_LOCKDIR" 2>/dev/null
        OWP_LOCK_HELD=0
    fi
}

# owp_init <模块名>
owp_init() {
    if ! mkdir "$OWP_LOCKDIR" 2>/dev/null; then
        die "已有另一个安装任务在运行($OWP_LOCKDIR 存在)。确认无任务后删除该目录再试"
    fi
    OWP_LOCK_HELD=1
    trap owp_cleanup EXIT INT TERM
    mkdir -p "$OWP_TMP"
    [ "$(id -u)" = 0 ] || die "需要 root 权限"
    owp_detect_env
    owp_clean_legacy_feeds
    title "${1:-安装} - $OWP_DESC"
    printf "  架构 %s | 分支 %s | 包管理器 %s | 内核 %s | firewall4 %s\n" \
        "$OWP_ARCH" "$OWP_BRANCH" "$OWP_PM" "$OWP_KERNEL" \
        "$([ "$OWP_FW4" = 1 ] && echo 是 || echo 否)"
}

# 版本门槛: owp_require_branch 24.10 nikki
owp_require_branch() {
    if ! owp_ver_ge "$OWP_BRANCH" "$1"; then
        err "$2 要求 OpenWrt $1 或更新,当前是 $OWP_RELEASE"
        return 1
    fi
    return 0
}

# ---------------- 各插件的适用范围(2026-09 核实) ----------------
# PassWall 官方构建源发布的分支(SNAPSHOT 走 snapshots/ 目录,只有 apk)
OWP_PW_BRANCHES="21.02 22.03 23.05 24.10 25.12 SNAPSHOT"
OWP_DDNSGO_ARCHS="x86_64 aarch64_generic aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76 arm_cortex-a7 arm_cortex-a9 mips_24kc mipsel_24kc riscv64_riscv64"
OWP_DAED_ARCHS="x86_64 i386_pentium4 aarch64_generic"

# daeuniverse 官方二进制的架构名映射(与 OpenWrt 架构名不同)
# 没有对应二进制时输出空串
owp_daed_bin_arch() {
    case "${1:-$OWP_ARCH}" in
        x86_64)        printf 'x86_64' ;;
        i386_*)        printf 'x86_32' ;;
        aarch64_*)     printf 'arm64' ;;
        riscv64_*)     printf 'riscv64' ;;
        mips_24kc)     printf 'mips32' ;;
        mipsel_24kc)   printf 'mips32le' ;;
        *)             printf '' ;;
    esac
}

owp_in_list() {
    for _i in $2; do [ "$_i" = "$1" ] && return 0; done
    return 1
}

owp_env_report() {
    owp_detect_env
    _kv=$(uname -r | cut -d- -f1 | cut -d. -f1,2)
    title "系统环境"
    printf "  固件      : %s\n" "$OWP_DESC"
    printf "  版本/分支 : %s  (%s)\n" "$OWP_RELEASE" "$OWP_BRANCH"
    printf "  架构      : %s\n" "$OWP_ARCH"
    printf "  目标平台  : %s\n" "$OWP_TARGET"
    printf "  包管理器  : %s\n" "$OWP_PM"
    printf "  内核      : %s\n" "$OWP_KERNEL"
    printf "  防火墙    : %s\n" "$([ "$OWP_FW4" = 1 ] && echo 'firewall4 / nftables' || echo 'iptables (firewall3)')"
    printf "  内核 BTF  : %s\n" "$([ "$OWP_BTF" = 1 ] && echo 有 || echo 无)"
    printf "  可用内存  : %s MB\n" "$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    if [ -d /overlay ]; then
        printf "  overlay   : %s\n" "$(df -h /overlay 2>/dev/null | awk 'NR==2{print $4" 可用 / "$2}')"
    else
        printf "  根分区    : %s\n" "$(df -h / 2>/dev/null | awk 'NR==2{print $4" 可用 / "$2}')"
    fi

    title "插件可行性"
    owp_report_line "qrencode(二维码命令行)" "yes" "官方源直接安装"
    owp_report_line "OpenClash" "yes" "GitHub Release 直装 + 官方源依赖"
    if [ "$OWP_BRANCH" = SNAPSHOT ] && [ "$OWP_PM" = opkg ]; then
        owp_report_line "PassWall / PassWall2" "no" "SNAPSHOT 只发 apk 包,当前是 opkg 固件"
    elif owp_in_list "$OWP_BRANCH" "$OWP_PW_BRANCHES"; then
        if [ "$OWP_BRANCH" = SNAPSHOT ]; then
            owp_report_line "PassWall / PassWall2" "yes" "官方构建源 snapshots/packages/$OWP_ARCH"
        else
            owp_report_line "PassWall / PassWall2" "yes" "官方构建源 packages-$OWP_BRANCH/$OWP_ARCH"
        fi
    else
        owp_report_line "PassWall / PassWall2" "no" "构建源只发 $OWP_PW_BRANCHES"
    fi
    if owp_ver_ge "$OWP_BRANCH" 24.10; then
        owp_report_line "nikki (Mihomo)" "yes" "官方 nikki 源"
    else
        owp_report_line "nikki (Mihomo)" "no" "上游只支持 24.10 / 25.12 / SNAPSHOT"
    fi
    if owp_ver_ge "$OWP_BRANCH" 24.10; then
        owp_report_line "homeproxy" "yes" "ImmortalWrt 构建包 + 官方源 sing-box"
    else
        owp_report_line "homeproxy" "warn" "23.05 只能装 2025-10 冻结版"
    fi
    if [ "$OWP_BTF" != 1 ] || ! owp_ver_ge "$_kv" 5.8; then
        owp_report_line "daed (dae eBPF)" "no" "需内核 >=5.8 且带 BTF,当前不满足"
    elif owp_in_list "$OWP_ARCH" "$OWP_DAED_ARCHS"; then
        owp_report_line "daed (dae eBPF)" "yes" "LuCI 成品包 + 内核 BTF 就绪"
    elif [ -n "$(owp_daed_bin_arch)" ]; then
        owp_report_line "daed (dae eBPF)" "warn" "无 LuCI 界面,只装官方二进制 + 自建服务"
    else
        owp_report_line "daed (dae eBPF)" "no" "上游没有 $OWP_ARCH 的包或二进制"
    fi
    owp_report_line "Argon 主题" "yes" "GitHub Release 直装"
    if owp_in_list "$OWP_ARCH" "$OWP_DDNSGO_ARCHS"; then
        owp_report_line "ddns-go" "yes" "GitHub Release 直装"
    else
        owp_report_line "ddns-go" "no" "上游只编译 10 种架构,不含 $OWP_ARCH"
    fi
    printf "\n"
}

owp_report_line() {
    case "$2" in
        yes)  printf "  ${C_G}可装${C_N}  %s — %s\n" "$1" "$3" ;;
        warn) printf "  ${C_Y}受限${C_N}  %s — %s\n" "$1" "$3" ;;
        *)    printf "  ${C_R}不可${C_N}  %s — %s\n" "$1" "$3" ;;
    esac
}

