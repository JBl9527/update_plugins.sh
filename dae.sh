#!/bin/sh
# ==========================================
# daed (daeuniverse) OpenWrt 一键安装脚本
# 用法:
#   sh daed-install.sh
#   SKIP_LUCI=1 sh daed-install.sh            # 不装 LuCI 界面
#   START_AFTER_INSTALL=1 sh daed-install.sh  # 装完直接启用并启动
#   DAED_TAG=v0.9.0 sh daed-install.sh        # 手动指定版本(GitHub API 不通时)
# ==========================================
set -eu

LOCKDIR="/tmp/daed-install.lock"
TMP_ROOT="/tmp/daed-install"

DAED_REPO="daeuniverse/daed"                 # 官方仓库(已核对)
DAED_RELEASES_API="https://api.github.com/repos/$DAED_REPO/releases?per_page=20"
DAED_RELEASES_PAGE="https://github.com/$DAED_REPO/releases/latest"
LUCI_DAED_REPO="QiuSimons/luci-app-daed"     # 第三方社区 LuCI(非官方)
LUCI_DAED_API="https://api.github.com/repos/$LUCI_DAED_REPO/releases/latest"
LUCI_DAED_RELEASES_PAGE="https://github.com/$LUCI_DAED_REPO/releases/latest"

DAED_BIN="/usr/bin/daed"
DAED_SHARE="/usr/share/daed"
DAED_CONFIG="/etc/daed"
DAED_INIT="/etc/init.d/daed"

START_AFTER_INSTALL="${START_AFTER_INSTALL:-0}"
SKIP_LUCI="${SKIP_LUCI:-0}"
FORCE_PKG_UPDATE="1"
LOCK_ACQUIRED="0"
PKG_INDEX_REFRESHED="0"
SIG_CHECK_DISABLED="0"
UA="daed-openwrt-installer"

# ---------- 基础 ----------

restore_sig_check() {
    [ "$SIG_CHECK_DISABLED" = "1" ] || return 0
    sed -i 's/^[[:space:]]*#[[:space:]]*option check_signature/option check_signature/' /etc/opkg.conf 2>/dev/null || true
    SIG_CHECK_DISABLED="0"
}

cleanup() {
    restore_sig_check
    if [ "$LOCK_ACQUIRED" = "1" ]; then
        rm -rf "$TMP_ROOT"
        rmdir "$LOCKDIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

log()  { printf '%s\n' "==> $*"; }
warn() { printf '%s\n' "[WARN] $*" >&2; }
die()  { printf '%s\n' "[ERROR] $*" >&2; exit 1; }

detect_pkg_mgr() {
    if command -v opkg >/dev/null 2>&1; then
        printf 'opkg'
    elif command -v apk >/dev/null 2>&1; then
        printf 'apk'
    else
        printf ''
    fi
}

# 不再使用 -k / --no-check-certificate，证书由 ca-bundle 保障
download_url() {
    URL="$1"; OUT="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 15 \
            -H "Accept: application/vnd.github+json" \
            -A "$UA" "$URL" -o "$OUT" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$OUT" --user-agent="$UA" "$URL" && return 0
    fi
    return 1
}

refresh_pkg_index() {
    [ -n "$1" ] || return 0
    [ "$FORCE_PKG_UPDATE" = "1" ] || return 0
    [ "$PKG_INDEX_REFRESHED" = "1" ] && return 0
    case "$1" in
        opkg) log "刷新 opkg 软件源索引"; opkg update || warn "opkg update 失败，继续" ;;
        apk)  log "刷新 apk 软件源索引";  apk update  || warn "apk update 失败，继续" ;;
    esac
    PKG_INDEX_REFRESHED="1"
}

# ---------- 依赖安装 ----------

install_deps() {
    PKG_MGR="$1"
    case "$PKG_MGR" in
        opkg)
            log "安装 daed 运行依赖: kmod-sched-core kmod-sched-bpf kmod-veth ca-bundle"
            opkg install kmod-sched-core kmod-sched-bpf kmod-veth ca-bundle 2>/dev/null \
                || warn "部分依赖安装失败（自编译固件内核版本与源不匹配时常见），请装完后用 lsmod 确认 sch_*/cls_bpf 已加载"
            ;;
        apk)
            log "安装 daed 运行依赖: kmod-sched-core kmod-sched-bpf kmod-veth ca-certificates"
            apk add kmod-sched-core kmod-sched-bpf kmod-veth ca-certificates 2>/dev/null \
                || warn "部分依赖安装失败"
            ;;
        *)
            warn "无包管理器，跳过依赖安装（请手动确认 kmod-sched-bpf 与 CA 证书）"
            ;;
    esac
}

ensure_unzip() {
    PKG_MGR="$1"
    command -v unzip >/dev/null 2>&1 && return 0
    log "安装解压工具: unzip"
    case "$PKG_MGR" in
        opkg) opkg install unzip >/dev/null 2>&1 || true ;;
        apk)  apk add unzip     >/dev/null 2>&1 || true ;;
    esac
    command -v unzip >/dev/null 2>&1 || die "无法安装 unzip，核心组件无法解压，安装中止"
}

# ---------- 内核能力检查(仅警告,不阻止安装) ----------
# 客观说明: 以下任何一项不满足, daed 的 eBPF 程序都会加载失败,
# 服务无法启动。警告只是让你"先装上", 不是"能运行"。
check_kernel_support() {
    KVER="$(uname -r)"
    KMAJ="${KVER%%.*}"
    KREST="${KVER#*.}"
    KMIN="${KREST%%.*}"
    if [ "$KMAJ" -lt 5 ] 2>/dev/null || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -lt 8 ]; } 2>/dev/null; then
        warn "内核 $KVER 低于 5.8：daed 无法在此内核上运行！"
    fi

    if [ ! -r /sys/kernel/btf/vmlinux ] && [ ! -r /usr/lib/debug/boot/vmlinux ]; then
        warn "未检测到内核 BTF (/sys/kernel/btf/vmlinux)：daed 依赖 CO-RE，缺 BTF 将启动失败！"
    fi

    CONFIG_FILE="$TMP_ROOT/kernel.config"
    : > "$CONFIG_FILE"
    if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
        zcat /proc/config.gz > "$CONFIG_FILE" 2>/dev/null || true
    elif [ -r "/boot/config-$(uname -r)" ]; then
        cp "/boot/config-$(uname -r)" "$CONFIG_FILE" 2>/dev/null || true
    elif [ -r /boot/config ]; then
        cp /boot/config "$CONFIG_FILE" 2>/dev/null || true
    fi

    if [ -s "$CONFIG_FILE" ]; then
        MISSING=""
        for OPTION in CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_DEBUG_INFO_BTF; do
            grep -q "^${OPTION}=y$" "$CONFIG_FILE" || MISSING="$MISSING $OPTION"
        done
        [ -z "$MISSING" ] || warn "内核可能缺少:$MISSING —— 忽略继续安装，但服务大概率起不来"
    else
        warn "无法读取内核配置，跳过 BPF 项检查"
    fi
}

# ---------- 版本号获取 ----------

find_latest_tag() {
    RELEASES_JSON="$TMP_ROOT/releases.json"
    TAGS=""
    TAG=""

    if download_url "$DAED_RELEASES_API" "$RELEASES_JSON"; then
        if command -v jsonfilter >/dev/null 2>&1; then
            TAGS="$(jsonfilter -i "$RELEASES_JSON" -e '@[*].tag_name' 2>/dev/null | tr -s ' \t' '\n' || true)"
        fi
        if [ -z "$TAGS" ]; then
            TAGS="$(sed 's/"tag_name"/\n"tag_name"/g' "$RELEASES_JSON" | \
                sed -n 's/^"tag_name"[[:space:]]*:[[:space:]]*"\(v[0-9][^"]*\)".*/\1/p' || true)"
        fi
    fi

    if [ -n "$TAGS" ]; then
        TAG="$(printf '%s\n' "$TAGS" | grep -E '^v[0-9]+\.[0-9]+' | grep -viE 'rc|beta|alpha|pre' | head -n1 || true)"
        [ -n "$TAG" ] || TAG="$(printf '%s\n' "$TAGS" | grep -E '^v[0-9]' | head -n1 || true)"
    fi

    if [ -z "$TAG" ]; then
        warn "GitHub API 不可用，改从 Release 页面解析版本号"
        if download_url "$DAED_RELEASES_PAGE" "$TMP_ROOT/daed-releases.html"; then
            TAG="$(grep -o "/$DAED_REPO/releases/tag/v[0-9][^\"']*" "$TMP_ROOT/daed-releases.html" | head -n1 | sed 's|.*/tag/||' || true)"
        fi
    fi

    [ -n "$TAG" ] || die "无法获取 daed 版本号（GitHub 不可达）。请用 DAED_TAG=vX.Y.Z 手动指定后重试"
    printf '%s' "$TAG"
}

# ---------- LuCI 界面(可选组件,失败可跳过) ----------

fetch_luci_release_meta() {
    if download_url "$LUCI_DAED_API" "$TMP_ROOT/luci-release.json"; then
        return 0
    fi
    warn "GitHub API 获取 LuCI Release 失败，改用页面解析"
    download_url "$LUCI_DAED_RELEASES_PAGE" "$TMP_ROOT/luci-release.html" || return 1
    LUCI_TAG="$(grep -o "/$LUCI_DAED_REPO/releases/tag/[^\"'?#]*" "$TMP_ROOT/luci-release.html" | head -n1 | sed 's|.*/tag/||' || true)"
    [ -n "$LUCI_TAG" ] || return 1
    download_url "https://github.com/$LUCI_DAED_REPO/releases/expanded_assets/$LUCI_TAG" "$TMP_ROOT/luci-assets.html" || return 1
}

find_luci_asset_url() {
    PATTERN="$1"

    if [ -f "$TMP_ROOT/luci-release.json" ]; then
        URL="$(sed 's/"browser_download_url"/\n"browser_download_url"/g' "$TMP_ROOT/luci-release.json" | \
            sed -n 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
            grep "$PATTERN" | head -n1 || true)"
        if [ -n "$URL" ]; then
            printf '%s\n' "$URL"
            return 0
        fi
    fi

    for HTML in "$TMP_ROOT/luci-assets.html" "$TMP_ROOT/luci-release.html"; do
        [ -f "$HTML" ] || continue
        URL="$(grep -o "/$LUCI_DAED_REPO/releases/download/[^\"'<> ]*" "$HTML" | \
            grep "$PATTERN" | head -n1 || true)"
        if [ -n "$URL" ]; then
            printf 'https://github.com%s\n' "$URL"
            return 0
        fi
    done
    return 0
}

disable_sig_check() {
    [ -f /etc/opkg.conf ] || return 1
    if grep -qE '^[[:space:]]*option check_signature' /etc/opkg.conf; then
        SIG_CHECK_DISABLED="1"
        sed -i 's/^[[:space:]]*option check_signature/#option check_signature/' /etc/opkg.conf
    fi
}

# 仅在官方源装不上 luci-compat 时才注入第三方源
setup_third_party_feed() {
    [ -f /etc/os-release ] || return 1
    ARCH="$(grep '^OPENWRT_ARCH=' /etc/os-release 2>/dev/null | head -n1 | cut -d'"' -f2)"
    [ -n "$ARCH" ] || return 1

    mkdir -p /etc/opkg
    if ! grep -q 'custom_plugins' /etc/opkg/customfeeds.conf 2>/dev/null; then
        log "注入第三方源 (kiddin9) 以获取 luci-compat"
        echo "src/gz custom_plugins https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9" >> /etc/opkg/customfeeds.conf || return 1
    fi

    if ! download_url "https://dl.openwrt.ai/latest/public-key.pub" "$TMP_ROOT/kiddin9.pub"; then
        warn "第三方源公钥下载失败"
    elif ! opkg-key add "$TMP_ROOT/kiddin9.pub" >/dev/null 2>&1; then
        warn "公钥导入失败，临时关闭 opkg 签名校验（脚本退出时自动恢复原状）"
        disable_sig_check
    fi

    opkg update || warn "opkg update 失败"
    PKG_INDEX_REFRESHED="1"
}

install_luci_deps() {
    PKG_MGR="$1"
    case "$PKG_MGR" in
        opkg)
            if ! opkg install luci-compat luci-lua-runtime zoneinfo-asia 2>/dev/null; then
                warn "官方源安装 LuCI 依赖失败，尝试第三方源"
                setup_third_party_feed
                opkg install luci-compat luci-lua-runtime zoneinfo-asia 2>/dev/null \
                    || warn "luci-compat 等依赖仍安装失败，LuCI 界面可能不可用"
            fi
            ;;
        apk)
            apk add luci-compat zoneinfo-asia 2>/dev/null || warn "LuCI 依赖安装失败"
            ;;
    esac
}

install_luci_daed() {
    PKG_MGR="$1"
    I18N_PKG=""

    [ "$SKIP_LUCI" = "1" ] && { warn "按参数跳过 LuCI 界面安装"; return 0; }
    [ -n "$PKG_MGR" ] || { warn "无包管理器，跳过 LuCI 界面安装"; return 0; }

    fetch_luci_release_meta || {
        warn "无法获取 luci-app-daed Release，跳过界面安装（不影响 daed 后端）"
        return 0
    }

    # 匹配放宽: 不再写死 openwrt 版本号，避免因命名变化匹配失败
    case "$PKG_MGR" in
        opkg)
            LUCI_PATTERN='luci-app-daed_.*\.ipk$'
            I18N_PATTERN='luci-i18n-daed-zh-cn_.*\.ipk$'
            ;;
        apk)
            LUCI_PATTERN='luci-app-daed-.*\.apk$'
            I18N_PATTERN='luci-i18n-daed-zh-cn-.*\.apk$'
            ;;
    esac

    LUCI_URL="$(find_luci_asset_url "$LUCI_PATTERN")"
    I18N_URL="$(find_luci_asset_url "$I18N_PATTERN")"
    [ -n "$LUCI_URL" ] || { warn "上游 Release 未找到匹配的 LuCI 包，跳过界面安装"; return 0; }

    LUCI_PKG="$TMP_ROOT/$(basename "$LUCI_URL")"
    log "下载 LuCI: $(basename "$LUCI_URL")"
    download_url "$LUCI_URL" "$LUCI_PKG" || { warn "LuCI 包下载失败，跳过界面安装"; return 0; }

    if [ -n "$I18N_URL" ]; then
        I18N_PKG="$TMP_ROOT/$(basename "$I18N_URL")"
        log "下载中文语言包: $(basename "$I18N_URL")"
        download_url "$I18N_URL" "$I18N_PKG" || { warn "中文包下载失败（不影响界面本体）"; I18N_PKG=""; }
    fi

    install_luci_deps "$PKG_MGR"

    case "$PKG_MGR" in
        opkg)
            opkg install $LUCI_PKG ${I18N_PKG:-} 2>/dev/null || {
                warn "常规安装失败，尝试 --force-depends"
                opkg install --force-depends $LUCI_PKG ${I18N_PKG:-} || warn "LuCI 界面安装失败"
            }
            ;;
        apk)
            apk add --allow-untrusted $LUCI_PKG ${I18N_PKG:-} || warn "LuCI 界面安装失败"
            ;;
    esac
}

# ---------- daed 核心(必须成功,否则中止) ----------

detect_asset_arch() {
    SOURCE_ARCH="${DISTRIB_ARCH:-$(uname -m)}"
    case "$SOURCE_ARCH" in
        aarch64*|arm64)   printf 'arm64' ;;
        x86_64|amd64)     printf 'x86_64' ;;
        *) die "不支持的架构: $SOURCE_ARCH（daed 官方仅发布 x86_64 / arm64）" ;;
    esac
}

verify_archive() {
    unzip -t "$1" >/dev/null 2>&1
}

write_init_script() {
    cat > "$DAED_INIT" <<'EOF_INIT'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1
CONF="daed"
LOG="/var/log/daed/daed.log"

start_service() {
    config_load "$CONF"
    local enabled listen_addr log_maxbackups log_maxsize
    config_get_bool enabled "config" "enabled" "0"
    [ "$enabled" -eq 1 ] || return 1
    config_get listen_addr "config" "listen_addr" "0.0.0.0:2023"
    config_get log_maxbackups "config" "log_maxbackups" "1"
    config_get log_maxsize "config" "log_maxsize" "5"

    mkdir -p /var/log/daed
    procd_open_instance
    procd_set_param command /usr/bin/daed run
    procd_append_param command --config /etc/daed/
    procd_append_param command --listen "$listen_addr"
    procd_append_param command --logfile "$LOG"
    procd_append_param command --logfile-maxbackups "$log_maxbackups"
    procd_append_param command --logfile-maxsize "$log_maxsize"
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
    chmod 755 "$DAED_INIT"
}

ensure_luci_config() {
    mkdir -p /etc/config /var/log/daed
    if [ ! -f /etc/config/daed ]; then
        cat > /etc/config/daed <<'EOF_CONFIG'
config daed 'config'
	option enabled '0'
	option listen_addr '0.0.0.0:2023'
	option log_maxbackups '1'
	option log_maxsize '5'
EOF_CONFIG
        chmod 600 /etc/config/daed
    fi
    touch /var/log/daed/daed.log
}

install_daed() {
    ASSET_ARCH="$1"
    TAG="$2"
    ASSET_NAME="daed-linux-${ASSET_ARCH}.zip"
    RELEASE_BASE="https://github.com/$DAED_REPO/releases/download/$TAG"
    ARCHIVE="$TMP_ROOT/$ASSET_NAME"
    EXTRACT_DIR="$TMP_ROOT/extract"
    SOURCE_DIR="$EXTRACT_DIR/daed-linux-${ASSET_ARCH}"

    log "下载 daed $TAG: $ASSET_NAME"
    download_url "$RELEASE_BASE/$ASSET_NAME" "$ARCHIVE" \
        || die "daed 核心包下载失败: $RELEASE_BASE/$ASSET_NAME（可用 DAED_TAG 指定其他版本重试）"

    verify_archive "$ARCHIVE" || die "压缩包校验失败（下载不完整或被篡改），安装中止"

    mkdir -p "$EXTRACT_DIR"
    unzip -q -o "$ARCHIVE" -d "$EXTRACT_DIR" || die "解压失败"
    [ -f "$SOURCE_DIR/daed-linux-${ASSET_ARCH}" ] \
        || die "压缩包内未找到 daed 二进制，$TAG 的资产结构可能已变化"

    [ -x "$DAED_INIT" ] && "$DAED_INIT" stop >/dev/null 2>&1 || true

    mkdir -p "$DAED_SHARE" "$DAED_CONFIG"
    cp "$SOURCE_DIR/daed-linux-${ASSET_ARCH}" "$DAED_BIN" || die "写入 $DAED_BIN 失败（存储空间不足?）"
    chmod 755 "$DAED_BIN"

    if [ -f "$SOURCE_DIR/geoip.dat" ]; then
        cp "$SOURCE_DIR/geoip.dat" "$DAED_SHARE/geoip.dat" || warn "geoip.dat 复制失败"
    else
        warn "压缩包内无 geoip.dat"
    fi
    if [ -f "$SOURCE_DIR/geosite.dat" ]; then
        cp "$SOURCE_DIR/geosite.dat" "$DAED_SHARE/geosite.dat" || warn "geosite.dat 复制失败"
    else
        warn "压缩包内无 geosite.dat"
    fi

    write_init_script
    ensure_luci_config

    # 安装后自检: 能执行 --version 说明架构正确
    if "$DAED_BIN" --version >/dev/null 2>&1; then
        log "自检通过: $("$DAED_BIN" --version 2>&1 | head -n1)"
    else
        warn "daed --version 自检未通过，请手动执行 /usr/bin/daed --version 确认架构是否匹配"
    fi
}

# ---------- 主流程 ----------

main() {
    # 锁被占用时必须退出, 否则 cleanup 会误删另一个任务的临时文件
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
        die "已有另一个 daed 安装任务在运行（$LOCKDIR 存在）。若无任务运行，删除该目录后重试"
    fi
    LOCK_ACQUIRED="1"
    mkdir -p "$TMP_ROOT"

    [ -f /etc/openwrt_release ] || die "未检测到 OpenWrt 系统（/etc/openwrt_release 不存在）"
    . /etc/openwrt_release
    DISTRIB_ARCH="${DISTRIB_ARCH:-}"
    DISTRIB_RELEASE="${DISTRIB_RELEASE:-}"

    PKG_MGR="$(detect_pkg_mgr)"
    [ -n "$PKG_MGR" ] || warn "未检测到 opkg/apk，将只安装 daed 二进制"

    ASSET_ARCH="$(detect_asset_arch)"
    log "系统: ${DISTRIB_DESCRIPTION:-unknown}"
    log "架构: ${DISTRIB_ARCH:-$(uname -m)}  →  daed 资产: $ASSET_ARCH"

    check_kernel_support

    refresh_pkg_index "$PKG_MGR"
    install_deps "$PKG_MGR"
    ensure_unzip "$PKG_MGR"

    DAED_ENABLED_BEFORE="$(uci -q get daed.config.enabled 2>/dev/null || printf '0')"

    LATEST_TAG="${DAED_TAG:-$(find_latest_tag)}"
    log "安装版本: $LATEST_TAG"

    install_luci_daed "$PKG_MGR"
    install_daed "$ASSET_ARCH" "$LATEST_TAG"

    uci set daed.config.enabled="$DAED_ENABLED_BEFORE" 2>/dev/null || true
    uci commit daed 2>/dev/null || true

    if [ "$START_AFTER_INSTALL" = "1" ]; then
        uci set daed.config.enabled='1' 2>/dev/null || true
        uci commit daed 2>/dev/null || true
        "$DAED_INIT" enable >/dev/null 2>&1 || true
        "$DAED_INIT" restart >/dev/null 2>&1 || true
        log "已启用并启动 daed，面板地址: http://<路由IP>:2023"
    fi

    # 刷新 LuCI 缓存
    rm -rf /tmp/luci-* /tmp/.luci* /var/run/luci-indexcache 2>/dev/null || true
    [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true

    log "安装完成！"
    if [ "$START_AFTER_INSTALL" != "1" ]; then
        log "启用方式: uci set daed.config.enabled='1' && uci commit daed && /etc/init.d/daed start"
        log "启动后务必检查: logread -e daed   (确认 eBPF 加载成功，无 BTF/BPF 报错)"
    fi
}

main "$@"
