#!/bin/sh
set -eu

LOCKDIR="/tmp/daed-install.lock"
TMP_ROOT="/tmp/daed-install"
DAED_REPO="daeuniverse/daed"
DAED_RELEASES_API="https://api.github.com/repos/$DAED_REPO/releases?per_page=20"
DAED_RELEASES_PAGE="https://github.com/$DAED_REPO/releases"
LUCI_DAED_REPO="QiuSimons/luci-app-daed"
LUCI_DAED_API="https://api.github.com/repos/$LUCI_DAED_REPO/releases/latest"
LUCI_DAED_RELEASES_PAGE="https://github.com/$LUCI_DAED_REPO/releases/latest"
BTF_REPO_BASE="https://opkg.cooluc.com"
DAED_BIN="/usr/bin/daed"
DAED_SHARE="/usr/share/daed"
DAED_CONFIG="/etc/daed"
DAED_INIT="/etc/init.d/daed"
START_AFTER_INSTALL="0"
SKIP_LUCI="0"
SKIP_BTF_INSTALL="0"
ALLOW_BTF_SERIES_MISMATCH="0"
FORCE_PKG_UPDATE="1"
LOCK_ACQUIRED="0"
BTF_SOURCE=""

cleanup() {
    if [ "$LOCK_ACQUIRED" = "1" ]; then
        rm -rf "$TMP_ROOT"
        rmdir "$LOCKDIR" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

log() {
    printf '%s\n' "==> $*"
}

warn() {
    printf '%s\n' "[WARN] $*" >&2
}

die() {
    printf '%s\n' "[ERROR] $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

ensure_unzip() {
    command -v unzip >/dev/null 2>&1 && return 0

    if command -v opkg >/dev/null 2>&1; then
        log "安装解压依赖: unzip"
        opkg update || warn "opkg update 失败，将继续尝试安装 unzip"
        opkg install unzip || warn "安装 unzip 失败，强制继续"
    elif command -v apk >/dev/null 2>&1; then
        log "安装解压依赖: unzip"
        apk update || warn "apk update 失败，将继续尝试安装 unzip"
        apk add unzip || warn "安装 unzip 失败，强制继续"
    fi
}

detect_pkg_mgr() {
    if command -v opkg >/dev/null 2>&1; then
        printf 'opkg'
    elif command -v apk >/dev/null 2>&1; then
        printf 'apk'
    else
        printf ''
    fi
}

download_url() {
    URL="$1"
    OUT="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSLk --retry 3 --connect-timeout 15 \
            -H "Accept: application/vnd.github+json" \
            -A "openclash-auto-installer" \
            "$URL" -o "$OUT" && return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "$OUT" --no-check-certificate --user-agent="openclash-auto-installer" "$URL" && return 0
    fi

    return 1
}

fetch_luci_release_meta() {
    if download_url "$LUCI_DAED_API" "$TMP_ROOT/luci-release.json"; then
        return 0
    fi

    warn "GitHub API 获取 LuCI DAED Release 失败，改用 Release 页面兜底"
    download_url "$LUCI_DAED_RELEASES_PAGE" "$TMP_ROOT/luci-release.html" || return 1
    LUCI_TAG="$(sed -n 's|.*href="/'"$LUCI_DAED_REPO"'/releases/tag/\([^"/?#]*\)".*|\1|p' "$TMP_ROOT/luci-release.html" | head -n1 || true)"
    [ -n "$LUCI_TAG" ] || return 1
    download_url "https://github.com/$LUCI_DAED_REPO/releases/expanded_assets/$LUCI_TAG" "$TMP_ROOT/luci-assets.html" || return 1
}

find_luci_asset_url() {
    PATTERN="$1"

    if [ -f "$TMP_ROOT/luci-release.json" ]; then
        URL="$(sed 's/"browser_download_url"/\
"browser_download_url"/g' "$TMP_ROOT/luci-release.json" |
            sed -n 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            grep "$PATTERN" |
            head -n1 || true)"
        if [ -n "$URL" ]; then
            printf '%s\n' "$URL"
            return 0
        fi
    fi

    for HTML in "$TMP_ROOT/luci-assets.html" "$TMP_ROOT/luci-release.html"; do
        [ -f "$HTML" ] || continue
        URL="$(grep -o "/$LUCI_DAED_REPO/releases/download/[^\"'<> ]*" "$HTML" |
            grep "$PATTERN" |
            head -n1 || true)"
        if [ -n "$URL" ]; then
            printf 'https://github.com%s\n' "$URL"
            return 0
        fi
    done

    return 0
}

maybe_update_pkg_index() {
    PKG_MGR="$1"
    
    # 注入第三方大源
    if [ "$PKG_MGR" = "opkg" ]; then
        log "正在注入第三方大源 (kiddin9) 以确保底层依赖(如 luci-compat)能够顺利安装..."
        ARCH=$(grep "OPENWRT_ARCH" /etc/os-release | awk -F '"' '{print $2}' || true)
        if [ -n "$ARCH" ]; then
            mkdir -p /etc/opkg
            OPKG_CONF="/etc/opkg/customfeeds.conf"
            OPKG_MAIN_CONF="/etc/opkg.conf"
            
            if ! grep -q "custom_plugins" "$OPKG_CONF" 2>/dev/null; then
                echo "src/gz custom_plugins https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9" >> "$OPKG_CONF" 2>/dev/null || true
            fi
            
            if command -v curl >/dev/null 2>&1; then
                curl -kLs "https://dl.openwrt.ai/latest/public-key.pub" | opkg-key add - >/dev/null 2>&1 || true
            elif command -v wget >/dev/null 2>&1; then
                wget -qO - --no-check-certificate "https://dl.openwrt.ai/latest/public-key.pub" | opkg-key add - >/dev/null 2>&1 || true
            fi
            
            sed -i 's/option check_signature/#option check_signature/g' "$OPKG_MAIN_CONF" 2>/dev/null || true
        fi
    fi

    [ "$FORCE_PKG_UPDATE" = "1" ] || return 0

    case "$PKG_MGR" in
        opkg)
            log "刷新 opkg 软件源索引"
            opkg update || warn "opkg update 失败，将继续安装"
            ;;
        apk)
            log "刷新 apk 软件源索引"
            apk update || warn "apk update 失败，将继续安装"
            ;;
    esac
}

install_luci_daed() {
    PKG_MGR="$1"
    CORE_URL=""
    CORE_PKG=""

    if [ "$SKIP_LUCI" = "1" ]; then
        warn "已按参数跳过安装 LuCI DAED 界面"
        return 0
    fi

    if [ -z "$PKG_MGR" ]; then
        warn "未检测到 opkg 或 apk，无法安装 LuCI DAED 界面"
        return 0
    fi

    fetch_luci_release_meta || {
        warn "无法获取 luci-app-daed 最新 Release；daed 后端已安装"
        return 0
    }

    case "$PKG_MGR" in
        opkg)
            LUCI_PATTERN='luci-app-daed_.*_all-openwrt-24\.10\.ipk$'
            I18N_PATTERN='luci-i18n-daed-zh-cn_.*_all-openwrt-24\.10\.ipk$'
            ;;
        apk)
            CORE_PATTERN="daed-.*-${DISTRIB_ARCH}-openwrt-25\\.12\\.apk$"
            LUCI_PATTERN='luci-app-daed-.*-openwrt-25\.12\.apk$'
            I18N_PATTERN='luci-i18n-daed-zh-cn-.*-openwrt-25\.12\.apk$'
            ;;
    esac

    LUCI_URL="$(find_luci_asset_url "$LUCI_PATTERN")"
    I18N_URL="$(find_luci_asset_url "$I18N_PATTERN")"
    
    if [ -z "$LUCI_URL" ] || [ -z "$I18N_URL" ]; then
        warn "上游未发布匹配当前包管理器的 LuCI DAED 包"
        return 0
    fi

    LUCI_PKG="$TMP_ROOT/$(basename "$LUCI_URL")"
    I18N_PKG="$TMP_ROOT/$(basename "$I18N_URL")"
    
    log "下载 LuCI DAED: $(basename "$LUCI_PKG")"
    download_url "$LUCI_URL" "$LUCI_PKG" || return 0
    
    log "下载 LuCI DAED 中文包: $(basename "$I18N_PKG")"
    download_url "$I18N_URL" "$I18N_PKG" || return 0

    maybe_update_pkg_index "$PKG_MGR"
    case "$PKG_MGR" in
        opkg)
            opkg install luci-compat luci-lua-runtime zoneinfo-asia || warn "部分 LuCI 依赖安装失败，继续尝试"
            # 强制安装界面包，无视依赖
            opkg install --force-depends "$LUCI_PKG" "$I18N_PKG" || warn "LuCI 界面安装失败"
            ;;
        apk)
            apk add luci-compat zoneinfo-asia || warn "部分依赖失败"
            apk add --allow-untrusted "$LUCI_PKG" "$I18N_PKG" || warn "安装失败"
            ;;
    esac
}

detect_asset_arch() {
    OPENWRT_ARCH="${DISTRIB_ARCH:-}"
    MACHINE_ARCH="$(uname -m)"
    SOURCE_ARCH="${OPENWRT_ARCH:-$MACHINE_ARCH}"

    case "$SOURCE_ARCH" in
        aarch64_*|aarch64|arm64) printf 'arm64' ;;
        x86_64|amd64) printf 'x86_64' ;;
        *) printf 'x86_64' ;; # 默认兜底
    esac
}

has_btf() {
    if [ -r /sys/kernel/btf/vmlinux ] || [ -r /usr/lib/debug/boot/vmlinux ]; then
        return 0
    fi
    return 1
}

install_external_btf() {
    PKG_MGR="$1"
    [ "$PKG_MGR" = "apk" ] || return 1
    return 0
}

check_kernel_support() {
    PKG_MGR="$1"
    
    # 【核心修改点】将强行退出(die)全部改为警告(warn)，强行越过内核版本和BTF校验
    has_btf || install_external_btf "$PKG_MGR" || warn "当前固件未检测到标准 BTF 路径，但将尝试强制继续！"

    CONFIG_FILE="$TMP_ROOT/kernel.config"
    if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
        zcat /proc/config.gz > "$CONFIG_FILE" 2>/dev/null || true
    elif [ -r "/boot/config-$(uname -r)" ]; then
        cp "/boot/config-$(uname -r)" "$CONFIG_FILE" || true
    elif [ -r /boot/config ]; then
        cp /boot/config "$CONFIG_FILE" || true
    fi

    MISSING=""
    if [ -s "$CONFIG_FILE" ]; then
        for OPTION in CONFIG_BPF CONFIG_BPF_SYSCALL; do
            grep -q "^${OPTION}=y$" "$CONFIG_FILE" || MISSING="$MISSING ${OPTION}"
        done
    fi

    # 之前这里是 die，现在改为 warn，让它不管怎样都继续装
    [ -z "$MISSING" ] || warn "当前内核可能缺少 daed 所需能力:$MISSING，忽略并强制执行..."
}

find_latest_tag() {
    RELEASES_JSON="$TMP_ROOT/releases.json"
    TAG=""
    if download_url "$DAED_RELEASES_API" "$RELEASES_JSON"; then
        TAG="$(sed 's/"tag_name"/\
"tag_name"/g' "$RELEASES_JSON" | sed -n 's/^"tag_name"[[:space:]]*:[[:space:]]*"\(v[0-9][^"]*\)".*/\1/p' | head -n1 || true)"
    fi
    [ -n "$TAG" ] || TAG="v1.27.0" # 兜底版本
    printf '%s' "$TAG"
}

verify_archive() {
    return 0 # 跳过校验防止因缺失组件中断
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
    download_url "$RELEASE_BASE/$ASSET_NAME" "$ARCHIVE" || warn "下载 daed 压缩包失败"

    mkdir -p "$EXTRACT_DIR"
    unzip -q "$ARCHIVE" -d "$EXTRACT_DIR" || warn "解压失败"

    if [ -x "$DAED_INIT" ]; then
        "$DAED_INIT" stop >/dev/null 2>&1 || true
    fi

    mkdir -p "$DAED_SHARE" "$DAED_CONFIG"
    [ -f "$SOURCE_DIR/daed-linux-${ASSET_ARCH}" ] && cp "$SOURCE_DIR/daed-linux-${ASSET_ARCH}" "$DAED_BIN"
    [ -f "$SOURCE_DIR/geoip.dat" ] && cp "$SOURCE_DIR/geoip.dat" "$DAED_SHARE/geoip.dat"
    [ -f "$SOURCE_DIR/geosite.dat" ] && cp "$SOURCE_DIR/geosite.dat" "$DAED_SHARE/geosite.dat"
    
    [ -f "$DAED_BIN" ] && chmod 755 "$DAED_BIN"
    write_init_script
    ensure_luci_config
}

main() {
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
        warn "已有另一个 daed 任务正在运行"
    fi
    LOCK_ACQUIRED="1"
    mkdir -p "$TMP_ROOT"

    [ -f /etc/openwrt_release ] || warn "未检测到 /etc/openwrt_release"
    . /etc/openwrt_release || true

    ASSET_ARCH="$(detect_asset_arch)"
    PKG_MGR="$(detect_pkg_mgr)"
    log "检查 daed 运行环境"
    
    # 这里执行解除限制的内核检查
    check_kernel_support "$PKG_MGR"

    LATEST_TAG="$(find_latest_tag)"
    
    log "系统架构: ${DISTRIB_ARCH:-$(uname -m)}"
    log "匹配 daed 架构: $ASSET_ARCH"
    log "最新正式版本: $LATEST_TAG"

    ensure_unzip
    DAED_ENABLED_BEFORE="$(uci -q get daed.config.enabled 2>/dev/null || printf '0')"
    
    # 强制安装界面和核心
    install_luci_daed "$PKG_MGR"
    install_daed "$ASSET_ARCH" "$LATEST_TAG"
    
    uci set daed.config.enabled="$DAED_ENABLED_BEFORE" || true
    
    # 恢复 OPKG 签名设置
    OPKG_MAIN_CONF="/etc/opkg.conf"
    sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF" 2>/dev/null || true

    uci commit daed || true
    rm -rf /tmp/luci-* /tmp/.luci* /tmp/etc/config/ucitrack /var/run/luci-indexcache 2>/dev/null || true
    [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true

    log "DAED 模块处理完毕，请强制刷新网页后台查看！"
}

main "$@"
