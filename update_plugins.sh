#!/bin/sh
set -eu

LOCKDIR="/tmp/dae-install.lock"
TMP_ROOT="/tmp/dae-install"
DAE_REPO="daeuniverse/dae"
DAE_RELEASES_API="https://api.github.com/repos/$DAE_REPO/releases?per_page=20"
DAE_RELEASES_PAGE="https://github.com/$DAE_REPO/releases"
LUCI_DAE_REPO="QiuSimons/luci-app-dae"
LUCI_DAE_API="https://api.github.com/repos/$LUCI_DAE_REPO/releases/latest"
LUCI_DAE_RELEASES_PAGE="https://github.com/$LUCI_DAE_REPO/releases/latest"
BTF_REPO_BASE="https://opkg.cooluc.com"
DAE_BIN="/usr/bin/dae"
DAE_SHARE="/usr/share/dae"
DAE_CONFIG="/etc/dae"
DAE_INIT="/etc/init.d/dae"
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
        opkg install unzip || die "安装 unzip 失败"
    elif command -v apk >/dev/null 2>&1; then
        log "安装解压依赖: unzip"
        apk update || warn "apk update 失败，将继续尝试安装 unzip"
        apk add unzip || die "安装 unzip 失败"
    else
        die "缺少 unzip，且未检测到 opkg 或 apk"
    fi
}

usage() {
    cat <<'EOF_USAGE'
用法:
  sh dae.sh [选项]

选项:
  --start             安装后启用并启动 dae 服务（默认保持停用）
  --skip-start        兼容旧参数；安装后保持停用
  --skip-luci         跳过安装 LuCI DAE 界面
  --skip-btf-install  缺少 BTF 时不尝试安装外置 vmlinux-btf
  --allow-btf-series-mismatch
                      允许自动安装同一主次版本的 vmlinux-btf
  --skip-pkg-update   跳过 opkg update / apk update
  -h, --help          显示帮助
EOF_USAGE
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --start)
                START_AFTER_INSTALL="1"
                ;;
            --skip-start)
                START_AFTER_INSTALL="0"
                ;;
            --skip-luci)
                SKIP_LUCI="1"
                ;;
            --skip-btf-install)
                SKIP_BTF_INSTALL="1"
                ;;
            --allow-btf-series-mismatch)
                ALLOW_BTF_SERIES_MISMATCH="1"
                ;;
            --skip-pkg-update)
                FORCE_PKG_UPDATE="0"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数: $1"
                ;;
        esac
        shift
    done
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
        curl -fsSL --retry 3 --connect-timeout 15 \
            -H "Accept: application/vnd.github+json" \
            -A "openclash-auto-installer" \
            "$URL" -o "$OUT" && return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "$OUT" --user-agent="openclash-auto-installer" "$URL" && return 0
    fi

    return 1
}

fetch_luci_release_meta() {
    if download_url "$LUCI_DAE_API" "$TMP_ROOT/luci-release.json"; then
        return 0
    fi

    warn "GitHub API 获取 LuCI DAE Release 失败，改用 Release 页面兜底"
    download_url "$LUCI_DAE_RELEASES_PAGE" "$TMP_ROOT/luci-release.html" || return 1
    LUCI_TAG="$(sed -n 's|.*href="/'"$LUCI_DAE_REPO"'/releases/tag/\([^"/?#]*\)".*|\1|p' "$TMP_ROOT/luci-release.html" | head -n1 || true)"
    [ -n "$LUCI_TAG" ] || return 1
    download_url "https://github.com/$LUCI_DAE_REPO/releases/expanded_assets/$LUCI_TAG" "$TMP_ROOT/luci-assets.html" || return 1
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
        URL="$(grep -o "/$LUCI_DAE_REPO/releases/download/[^\"'<> ]*" "$HTML" |
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
    [ "$FORCE_PKG_UPDATE" = "1" ] || {
        log "按参数跳过软件源更新"
        return 0
    }

    case "$PKG_MGR" in
        opkg)
            log "刷新 opkg 软件源索引"
            opkg update || warn "opkg update 失败，将继续安装 LuCI DAE Release 包"
            ;;
        apk)
            log "刷新 apk 软件源索引"
            apk update || warn "apk update 失败，将继续安装 LuCI DAE Release 包"
            ;;
    esac
}

install_luci_dae() {
    PKG_MGR="$1"
    CORE_URL=""
    CORE_PKG=""

    if [ "$SKIP_LUCI" = "1" ]; then
        warn "已按参数跳过安装 LuCI DAE 界面"
        return 0
    fi

    if [ -z "$PKG_MGR" ]; then
        warn "未检测到 opkg 或 apk，无法安装 LuCI DAE 界面；dae 后端已安装"
        return 0
    fi

    fetch_luci_release_meta || {
        warn "无法获取 luci-app-dae 最新 Release；dae 后端已安装"
        return 0
    }

    case "$PKG_MGR" in
        opkg)
            LUCI_PATTERN='luci-app-dae_.*_all-openwrt-24\.10\.ipk$'
            I18N_PATTERN='luci-i18n-dae-zh-cn_.*_all-openwrt-24\.10\.ipk$'
            ;;
        apk)
            CORE_PATTERN="dae-.*-${DISTRIB_ARCH}-openwrt-25\\.12\\.apk$"
            LUCI_PATTERN='luci-app-dae-.*-openwrt-25\.12\.apk$'
            I18N_PATTERN='luci-i18n-dae-zh-cn-.*-openwrt-25\.12\.apk$'
            ;;
    esac

    if [ "$PKG_MGR" = "apk" ]; then
        CORE_URL="$(find_luci_asset_url "$CORE_PATTERN")"
        if [ -z "$CORE_URL" ]; then
            warn "上游未发布适用于 ${DISTRIB_ARCH:-unknown} 的 OpenWrt 25.12 dae APK；无法安装 LuCI DAE 界面"
            return 0
        fi
    fi

    LUCI_URL="$(find_luci_asset_url "$LUCI_PATTERN")"
    I18N_URL="$(find_luci_asset_url "$I18N_PATTERN")"
    if [ -z "$LUCI_URL" ] || [ -z "$I18N_URL" ]; then
        warn "上游未发布匹配当前包管理器的 LuCI DAE 包；dae 后端已安装"
        return 0
    fi

    LUCI_PKG="$TMP_ROOT/$(basename "$LUCI_URL")"
    I18N_PKG="$TMP_ROOT/$(basename "$I18N_URL")"
    if [ -n "$CORE_URL" ]; then
        CORE_PKG="$TMP_ROOT/$(basename "$CORE_URL")"
        log "下载 OpenWrt dae: $(basename "$CORE_PKG")"
        download_url "$CORE_URL" "$CORE_PKG" || {
            warn "下载 OpenWrt dae 包失败；无法安装 LuCI DAE 界面"
            return 0
        }
    fi
    log "下载 LuCI DAE: $(basename "$LUCI_PKG")"
    download_url "$LUCI_URL" "$LUCI_PKG" || {
        warn "下载 LuCI DAE 包失败；dae 后端已安装"
        return 0
    }
    log "下载 LuCI DAE 中文包: $(basename "$I18N_PKG")"
    download_url "$I18N_URL" "$I18N_PKG" || {
        warn "下载 LuCI DAE 中文包失败；dae 后端已安装"
        return 0
    }

    maybe_update_pkg_index "$PKG_MGR"
    case "$PKG_MGR" in
        opkg)
            opkg install luci-compat luci-lua-runtime zoneinfo-asia ||
                warn "部分 LuCI DAE 依赖安装失败，将继续尝试安装界面包"
            opkg install --force-depends "$LUCI_PKG" "$I18N_PKG" ||
                warn "LuCI DAE 界面安装失败；启用并启动 dae 后仍可通过命令行使用"
            ;;
        apk)
            apk add luci-compat zoneinfo-asia ||
                warn "部分 LuCI DAE 依赖安装失败，将继续尝试安装 Release 包"
            if apk info -e dae >/dev/null 2>&1; then
                [ ! -x "$DAE_INIT" ] || "$DAE_INIT" stop >/dev/null 2>&1 || true
                log "移除旧版 OpenWrt dae 与 LuCI APK"
                set -- dae
                for PACKAGE in luci-app-dae luci-i18n-dae-zh-cn; do
                    if apk info -e "$PACKAGE" >/dev/null 2>&1; then
                        set -- "$@" "$PACKAGE"
                    fi
                done
                apk del --force-broken-world "$@" ||
                    die "移除现有 dae APK 失败，无法恢复 OpenWrt 专用核心"
                if apk info -e dae >/dev/null 2>&1; then
                    die "旧版 dae APK 仍被依赖保留，无法安全替换核心"
                fi
                [ ! -e "$DAE_BIN" ] ||
                    die "移除旧版 dae APK 后核心文件仍存在，无法确认新核心会覆盖"
            fi
            apk add --allow-untrusted "$CORE_PKG" "$LUCI_PKG" "$I18N_PKG" ||
                die "安装 OpenWrt dae 与 LuCI Release 包失败"
            apk info -e dae >/dev/null 2>&1 ||
                die "OpenWrt dae APK 安装后未登记到包管理器"
            ;;
    esac
}

dae_is_running() {
    pidof dae >/dev/null 2>&1
}

diagnose_dae_failure() {
    LOG_FILE="/var/log/dae/dae.log"
    [ -s "$LOG_FILE" ] || return 0

    if tail -n 50 "$LOG_FILE" |
        grep -q 'program local_tcp_sockops:.*program of this type cannot use helper bpf_get_current_task'; then
        warn "检测到旧版 dae eBPF 对象不兼容当前内核：local_tcp_sockops 无法使用 bpf_get_current_task"
        warn "该问题无法通过 vmlinux-btf 修复；请重新运行最新安装脚本以强制更新 OpenWrt dae APK 核心"
    fi
}

disable_failed_dae() {
    uci -q set dae.config.enabled='0' || true
    uci -q commit dae || true
    [ ! -x "$DAE_INIT" ] || "$DAE_INIT" stop >/dev/null 2>&1 || true
    [ ! -x "$DAE_INIT" ] || "$DAE_INIT" disable >/dev/null 2>&1 || true
    warn "已取消启用 dae，避免不兼容核心持续崩溃重启"
}

verify_dae_started() {
    sleep 3
    if dae_is_running; then
        return 0
    fi

    warn "dae 启动后立即退出"
    diagnose_dae_failure
    if [ -s /var/log/dae/dae.log ]; then
        warn "最近的 dae 日志:"
        tail -n 20 /var/log/dae/dae.log >&2 || true
    fi
    warn "可在 LuCI '服务 -> DAE -> 日志' 查看完整日志，或执行: logread -e dae"
    return 1
}

detect_asset_arch() {
    OPENWRT_ARCH="${DISTRIB_ARCH:-}"
    MACHINE_ARCH="$(uname -m)"
    SOURCE_ARCH="${OPENWRT_ARCH:-$MACHINE_ARCH}"

    case "$SOURCE_ARCH" in
        aarch64_*|aarch64|arm64)
            printf 'arm64'
            ;;
        x86_64|amd64)
            printf 'x86_64'
            ;;
        i386*|i486*|i586*|i686*)
            printf 'x86_32'
            ;;
        mips64el_*|mips64el)
            printf 'mips64le'
            ;;
        mips64_*|mips64)
            printf 'mips64'
            ;;
        mipsel_*|mipsel)
            printf 'mips32le'
            ;;
        mips_*|mips)
            printf 'mips32'
            ;;
        riscv64_*|riscv64)
            printf 'riscv64'
            ;;
        *)
            die "dae 官方暂未提供当前架构的预编译包: OpenWrt=${OPENWRT_ARCH:-unknown}, uname=${MACHINE_ARCH:-unknown}"
            ;;
    esac
}

version_ge_5_8() {
    VERSION="$(uname -r | sed 's/[^0-9.].*$//')"
    MAJOR="${VERSION%%.*}"
    REST="${VERSION#*.}"
    MINOR="${REST%%.*}"

    case "$MAJOR:$MINOR" in
        *[!0-9:]*|:) return 1 ;;
    esac

    [ "$MAJOR" -gt 5 ] || { [ "$MAJOR" -eq 5 ] && [ "$MINOR" -ge 8 ]; }
}

has_btf() {
    if [ -r /sys/kernel/btf/vmlinux ]; then
        BTF_SOURCE="integrated"
        return 0
    fi

    if [ -r /usr/lib/debug/boot/vmlinux ] ||
        [ -r "/usr/lib/debug/boot/vmlinux-$(uname -r)" ]; then
        BTF_SOURCE="external"
        return 0
    fi

    return 1
}

confirm_btf_series_mismatch() {
    CURRENT_KERNEL="$1"
    BTF_VERSION="$2"

    if [ "$ALLOW_BTF_SERIES_MISMATCH" = "1" ]; then
        return 0
    fi

    [ -r /dev/tty ] || return 1
    warn "未找到与内核 $CURRENT_KERNEL 完全一致的 vmlinux-btf"
    warn "找到同一主次版本的 vmlinux-btf $BTF_VERSION；上游允许尝试，但仍可能因类型或补丁差异无法运行"
    printf '是否继续安装该 BTF 包？[y/N]: ' >/dev/tty
    read -r ANSWER </dev/tty || return 1
    case "$ANSWER" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

install_external_btf() {
    PKG_MGR="$1"
    CURRENT_KERNEL="$(uname -r)"
    KERNEL_SERIES="$(printf '%s' "$CURRENT_KERNEL" | awk -F. '{print $1 "." $2}')"
    OPENWRT_SERIES="$(printf '%s' "${DISTRIB_RELEASE:-}" | awk -F. '{print $1 "." $2}')"
    OPENWRT_ARCH="${DISTRIB_ARCH:-}"

    [ "$SKIP_BTF_INSTALL" = "0" ] || return 1
    [ "$PKG_MGR" = "apk" ] || {
        warn "自动安装外置 vmlinux-btf 当前仅支持 OpenWrt 25.12+ 的 apk 环境"
        return 1
    }
    [ -n "$OPENWRT_SERIES" ] && [ -n "$OPENWRT_ARCH" ] || return 1
    case "$OPENWRT_SERIES:$OPENWRT_ARCH" in
        *[!0-9.a-zA-Z_:-]*) return 1 ;;
    esac

    BTF_DIR_URL="$BTF_REPO_BASE/openwrt-$OPENWRT_SERIES/$OPENWRT_ARCH"
    BTF_INDEX="$TMP_ROOT/vmlinux-btf-index.html"
    log "当前固件未内置 BTF，查找外置 vmlinux-btf"
    download_url "$BTF_DIR_URL/" "$BTF_INDEX" || {
        warn "无法访问 vmlinux-btf 软件源: $BTF_DIR_URL"
        return 1
    }

    BTF_NAME="$(grep -o "vmlinux-btf-${CURRENT_KERNEL}\\.apk" "$BTF_INDEX" | head -n1 || true)"
    if [ -z "$BTF_NAME" ]; then
        BTF_NAME="$(grep -o "vmlinux-btf-${KERNEL_SERIES}\\.[0-9][0-9.]*\\.apk" "$BTF_INDEX" | head -n1 || true)"
        [ -n "$BTF_NAME" ] || {
            warn "软件源没有适用于 $OPENWRT_ARCH、内核 $CURRENT_KERNEL 的 vmlinux-btf"
            return 1
        }
        BTF_VERSION="${BTF_NAME#vmlinux-btf-}"
        BTF_VERSION="${BTF_VERSION%.apk}"
        confirm_btf_series_mismatch "$CURRENT_KERNEL" "$BTF_VERSION" || {
            warn "已取消安装版本不完全一致的 vmlinux-btf"
            return 1
        }
    fi

    BTF_PKG="$TMP_ROOT/$BTF_NAME"
    warn "外置 BTF 将从第三方软件源 opkg.cooluc.com 下载"
    log "下载外置 BTF: $BTF_NAME"
    download_url "$BTF_DIR_URL/$BTF_NAME" "$BTF_PKG" || {
        warn "下载外置 vmlinux-btf 失败"
        return 1
    }
    log "安装外置 BTF: $BTF_NAME"
    apk add --allow-untrusted "$BTF_PKG" || {
        warn "安装外置 vmlinux-btf 失败"
        return 1
    }
    has_btf || {
        warn "vmlinux-btf 安装后仍未找到 /usr/lib/debug/boot/vmlinux"
        return 1
    }
    log "外置 BTF 安装完成"
}

check_kernel_support() {
    PKG_MGR="$1"
    version_ge_5_8 || die "dae 需要 Linux 5.8+ 内核，当前内核为 $(uname -r)"

    has_btf || install_external_btf "$PKG_MGR" || die "当前固件（OpenWrt ${DISTRIB_RELEASE:-unknown}，架构 ${DISTRIB_ARCH:-unknown}，内核 $(uname -r)）未提供可用 BTF，无法运行 dae。请使用已开启 eBPF/BTF 的固件，或安装匹配的 vmlinux-btf"

    CONFIG_FILE="$TMP_ROOT/kernel.config"
    if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
        zcat /proc/config.gz > "$CONFIG_FILE" 2>/dev/null || true
    elif [ -r "/boot/config-$(uname -r)" ]; then
        cp "/boot/config-$(uname -r)" "$CONFIG_FILE"
    elif [ -r /boot/config ]; then
        cp /boot/config "$CONFIG_FILE"
    fi

    if [ ! -s "$CONFIG_FILE" ]; then
        warn "已检测到 BTF，但无法读取完整内核配置；不能确认其余 eBPF 能力"
        return 0
    fi

    MISSING=""
    for OPTION in \
        CONFIG_BPF \
        CONFIG_BPF_SYSCALL \
        CONFIG_BPF_JIT \
        CONFIG_CGROUPS \
        CONFIG_KPROBES \
        CONFIG_NET_INGRESS \
        CONFIG_NET_EGRESS \
        CONFIG_NET_CLS_ACT \
        CONFIG_BPF_STREAM_PARSER \
        CONFIG_KPROBE_EVENTS \
        CONFIG_BPF_EVENTS
    do
        grep -q "^${OPTION}=y$" "$CONFIG_FILE" || MISSING="$MISSING ${OPTION}"
    done

    if [ "$BTF_SOURCE" = "integrated" ]; then
        for OPTION in CONFIG_DEBUG_INFO CONFIG_DEBUG_INFO_BTF; do
            grep -q "^${OPTION}=y$" "$CONFIG_FILE" || MISSING="$MISSING ${OPTION}"
        done
        if grep -q '^CONFIG_DEBUG_INFO_REDUCED=y$' "$CONFIG_FILE"; then
            MISSING="$MISSING # CONFIG_DEBUG_INFO_REDUCED is not set"
        fi
    fi

    for OPTION in CONFIG_NET_SCH_INGRESS CONFIG_NET_CLS_BPF; do
        grep -Eq "^${OPTION}=(y|m)$" "$CONFIG_FILE" || MISSING="$MISSING ${OPTION}"
    done

    [ -z "$MISSING" ] || die "当前内核缺少 dae 所需能力:$MISSING"
}

find_latest_tag() {
    RELEASES_JSON="$TMP_ROOT/releases.json"
    RELEASES_HTML="$TMP_ROOT/releases.html"
    TAG=""

    if download_url "$DAE_RELEASES_API" "$RELEASES_JSON"; then
        TAG="$(sed 's/"tag_name"/\
"tag_name"/g' "$RELEASES_JSON" |
            sed -n 's/^"tag_name"[[:space:]]*:[[:space:]]*"\(v[0-9][^"]*\)".*/\1/p' |
            head -n1 || true)"
    fi

    if [ -z "$TAG" ] && download_url "$DAE_RELEASES_PAGE" "$RELEASES_HTML"; then
        TAG="$(sed -n 's|.*href="/'"$DAE_REPO"'/releases/tag/\(v[0-9][^"/?#]*\)".*|\1|p' "$RELEASES_HTML" |
            head -n1 || true)"
    fi

    [ -n "$TAG" ] || die "无法获取 dae 最新正式版本"
    printf '%s' "$TAG"
}

check_disk_space() {
    AVAILABLE_KB="$(df -k /usr 2>/dev/null | awk 'END {print $4}' || printf 0)"
    case "$AVAILABLE_KB" in
        ''|*[!0-9]*) AVAILABLE_KB=0 ;;
    esac

    if [ "$AVAILABLE_KB" -lt 100000 ]; then
        die "系统 /usr 可用空间不足 100MB，无法安装 dae（程序与规则数据约 85MB）"
    fi

    TMP_AVAILABLE_KB="$(df -k /tmp 2>/dev/null | awk 'END {print $4}' || printf 0)"
    case "$TMP_AVAILABLE_KB" in
        ''|*[!0-9]*) TMP_AVAILABLE_KB=0 ;;
    esac

    if [ "$TMP_AVAILABLE_KB" -lt 130000 ]; then
        die "系统 /tmp 可用空间不足 130MB，无法下载并解压 dae 官方包"
    fi
}

verify_archive() {
    ARCHIVE="$1"
    DIGEST_FILE="$2"

    if ! command -v sha256sum >/dev/null 2>&1; then
        warn "缺少 sha256sum，跳过压缩包校验"
        return 0
    fi

    EXPECTED="$(awk '$3 == "sha256" {print $1; exit}' "$DIGEST_FILE")"
    [ -n "$EXPECTED" ] || die "dae 校验文件中未找到 SHA-256"
    ACTUAL="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
    [ "$EXPECTED" = "$ACTUAL" ] || die "dae 压缩包 SHA-256 校验失败"
}

write_init_script() {
    cat > "$DAE_INIT" <<'EOF_INIT'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1
CONF="dae"
LOG="/var/log/dae/dae.log"

start_service() {
    config_load "$CONF"

    local enabled log_maxbackups log_maxsize
    config_get_bool enabled "config" "enabled" "0"
    [ "$enabled" -eq 1 ] || return 1
    config_get log_maxbackups "config" "log_maxbackups" "1"
    config_get log_maxsize "config" "log_maxsize" "5"

    mkdir -p /var/log/dae
    procd_open_instance
    procd_set_param command /usr/bin/dae run
    procd_append_param command -c /etc/dae/config.dae
    procd_append_param command --logfile "$LOG"
    procd_append_param command --logfile-maxbackups "$log_maxbackups"
    procd_append_param command --logfile-maxsize "$log_maxsize"
    procd_set_param env DAE_LOCATION_ASSET="/usr/share/dae"
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
    chmod 755 "$DAE_INIT"
}

ensure_luci_config() {
    mkdir -p /etc/config /var/log/dae /etc/dae
    if [ ! -f /etc/config/dae ]; then
        cat > /etc/config/dae <<'EOF_CONFIG'
config dae 'config'
	option enabled '0'
	option log_maxbackups '1'
	option log_maxsize '5'
EOF_CONFIG
        chmod 600 /etc/config/dae
    fi
    
    if [ ! -f /etc/dae/config.dae ]; then
        cat > /etc/dae/config.dae <<'EOF_DAE'
global {
    tproxy_port: 12345
    tproxy_port_protect: true
    so_mark_from_dae: 0
    log_level: info
}
routing {
    pname(dnsmasq) -> must_direct
    dip(geoip:private) -> direct
    fallback: proxy
}
EOF_DAE
    fi
    touch /var/log/dae/dae.log
}

limit_dae_respawn() {
    [ -f "$DAE_INIT" ] || return 0

    if grep -q '^[[:space:]]*procd_set_param respawn[[:space:]]*$' "$DAE_INIT"; then
        sed -i 's/^[[:space:]]*procd_set_param respawn[[:space:]]*$/    procd_set_param respawn 3600 5 5/' "$DAE_INIT"
    fi
}

refresh_luci() {
    rm -rf /tmp/luci-* /tmp/.luci* /tmp/etc/config/ucitrack /var/run/luci-indexcache 2>/dev/null || true
    if [ -x /etc/init.d/rpcd ]; then
        /etc/init.d/rpcd restart >/dev/null 2>&1 || warn "rpcd 重启失败"
    fi
}

install_dae() {
    ASSET_ARCH="$1"
    TAG="$2"
    ASSET_NAME="dae-linux-${ASSET_ARCH}.zip"
    RELEASE_BASE="https://github.com/$DAE_REPO/releases/download/$TAG"
    ARCHIVE="$TMP_ROOT/$ASSET_NAME"
    DIGEST="$TMP_ROOT/$ASSET_NAME.dgst"
    EXTRACT_DIR="$TMP_ROOT/extract"

    log "下载 dae $TAG: $ASSET_NAME"
    download_url "$RELEASE_BASE/$ASSET_NAME" "$ARCHIVE" || die "下载 dae 压缩包失败"
    download_url "$RELEASE_BASE/$ASSET_NAME.dgst" "$DIGEST" || die "下载 dae 校验文件失败"
    verify_archive "$ARCHIVE" "$DIGEST"

    mkdir -p "$EXTRACT_DIR"
    unzip -q "$ARCHIVE" -d "$EXTRACT_DIR" || die "解压 dae 压缩包失败"
    
    if [ -f "$EXTRACT_DIR/dae-linux-${ASSET_ARCH}" ]; then
        BIN_FILE="$EXTRACT_DIR/dae-linux-${ASSET_ARCH}"
        GEOIP_FILE="$EXTRACT_DIR/geoip.dat"
        GEOSITE_FILE="$EXTRACT_DIR/geosite.dat"
    elif [ -f "$EXTRACT_DIR/dae-linux-${ASSET_ARCH}/dae-linux-${ASSET_ARCH}" ]; then
        BIN_FILE="$EXTRACT_DIR/dae-linux-${ASSET_ARCH}/dae-linux-${ASSET_ARCH}"
        GEOIP_FILE="$EXTRACT_DIR/dae-linux-${ASSET_ARCH}/geoip.dat"
        GEOSITE_FILE="$EXTRACT_DIR/dae-linux-${ASSET_ARCH}/geosite.dat"
    else
        die "压缩包内未找到 dae 程序"
    fi

    [ -f "$GEOIP_FILE" ] || warn "压缩包内未找到 geoip.dat"
    [ -f "$GEOSITE_FILE" ] || warn "压缩包内未找到 geosite.dat"

    if [ -x "$DAE_INIT" ]; then
        "$DAE_INIT" stop >/dev/null 2>&1 || true
    fi

    mkdir -p "$DAE_SHARE" "$DAE_CONFIG"
    cp "$BIN_FILE" "$DAE_BIN"
    [ ! -f "$GEOIP_FILE" ] || cp "$GEOIP_FILE" "$DAE_SHARE/geoip.dat"
    [ ! -f "$GEOSITE_FILE" ] || cp "$GEOSITE_FILE" "$DAE_SHARE/geosite.dat"
    chmod 755 "$DAE_BIN"
    [ ! -f "$DAE_SHARE/geoip.dat" ] || chmod 644 "$DAE_SHARE/geoip.dat"
    [ ! -f "$DAE_SHARE/geosite.dat" ] || chmod 644 "$DAE_SHARE/geosite.dat"
    write_init_script
    ensure_luci_config
}

main() {
    parse_args "$@"
    need_cmd id
    [ "$(id -u)" -eq 0 ] || die "安装和运行 dae 需要 root 权限"

    if ! mkdir "$LOCKDIR" 2>/dev/null; then
        die "已有另一个 dae 任务正在运行"
    fi
    LOCK_ACQUIRED="1"
    mkdir -p "$TMP_ROOT"

    [ -f /etc/openwrt_release ] || die "未检测到 /etc/openwrt_release，当前环境不像 OpenWrt"
    # shellcheck disable=SC1091
    . /etc/openwrt_release

    need_cmd uname
    need_cmd sed
    need_cmd awk
    need_cmd grep
    need_cmd head
    need_cmd df
    need_cmd cp
    need_cmd chmod
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        die "缺少 curl 或 wget，无法下载 dae"
    fi

    ASSET_ARCH="$(detect_asset_arch)"
    PKG_MGR="$(detect_pkg_mgr)"
    log "检查 dae 运行环境"
    check_kernel_support "$PKG_MGR"
    check_disk_space

    LATEST_TAG="$(find_latest_tag)"
    OLD_VER="$("$DAE_BIN" --version 2>/dev/null | awk '{print $NF}' | head -n1 || true)"

    log "系统架构: ${DISTRIB_ARCH:-$(uname -m)}"
    log "匹配 dae 架构: $ASSET_ARCH"
    log "当前已安装版本: ${OLD_VER:-not installed}"
    log "最新正式版本: $LATEST_TAG"

    ensure_unzip
    DAE_ENABLED_BEFORE="$(uci -q get dae.config.enabled 2>/dev/null || printf '0')"
    case "$DAE_ENABLED_BEFORE" in
        0|1) ;;
        *) DAE_ENABLED_BEFORE="0" ;;
    esac
    install_luci_dae "$PKG_MGR"
    if [ "$PKG_MGR" = "apk" ] && apk info -e dae >/dev/null 2>&1; then
        log "OpenWrt 25.12 使用上游 dae APK 核心与服务脚本"
    else
        install_dae "$ASSET_ARCH" "$LATEST_TAG"
    fi
    limit_dae_respawn
    uci set dae.config.enabled="$DAE_ENABLED_BEFORE"
    uci commit dae
    refresh_luci
    NEW_VER="$("$DAE_BIN" --version 2>/dev/null | awk '{print $NF}' | head -n1 || true)"
    log "安装后版本: ${NEW_VER:-unknown}"

    if [ "$START_AFTER_INSTALL" = "1" ] || [ "$DAE_ENABLED_BEFORE" = "1" ]; then
        uci set dae.config.enabled='1'
        uci commit dae
        "$DAE_INIT" enable
        : > /var/log/dae/dae.log
        "$DAE_INIT" restart || {
            disable_failed_dae
            die "dae 服务启动失败，可执行 logread -e dae 查看日志"
        }
        verify_dae_started || {
            disable_failed_dae
            die "dae 无法保持运行，请根据上方日志检查核心版本和 eBPF 兼容性"
        }
        log "dae 服务已启用并启动"
    else
        log "dae 安装完成，LuCI '启用' 选项默认未勾选；请在 '服务 -> DAE' 中手动启用"
    fi

    warn "dae 依赖 eBPF/BTF；部分 OpenWrt 固件即使内核版本满足，也可能因内核裁剪而无法运行"
    if [ -f /usr/lib/lua/luci/controller/dae.lua ] || [ -f /usr/share/luci/menu.d/luci-app-dae.json ]; then
        log "LuCI 入口: 服务 -> DAE"
    else
        warn "未检测到 LuCI DAE 界面，可通过 --skip-luci 跳过界面安装或检查软件源依赖"
    fi
    log "启用并启动 dae 后，可在 LuCI 的 '服务 -> DAE' 中进行配置。"
    log "dae 处理完成"
}

main "$@"
