#!/bin/sh
# 本地 mock 测试(不在 OpenWrt 上跑,只验证逻辑/正则/文件改写)
# 用法: sh mocktest.sh
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
MR=/tmp/owpmock
FAILED=0

t_ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; }
t_bad()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED+1)); }
chk()    { if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1 (期望[$3] 实际[$2])"; fi; }

# ---------- 生成 mock 根 ----------
mkroot() {
    rm -rf "$MR"; mkdir -p "$MR/etc/opkg" "$MR/etc/apk/repositories.d" "$MR/etc/apk/keys" \
        "$MR/proc" "$MR/sys/kernel/btf" "$MR/sbin" "$MR/usr/share" "$MR/bin"
    cat > "$MR/proc/meminfo" <<'EOF'
MemTotal:         246028 kB
MemAvailable:     120480 kB
EOF
    : > "$MR/proc/swaps"
    printf 'dest root /\noption check_signature\n' > "$MR/etc/opkg.conf"
}

# 把 common.sh 里的绝对路径改写到 mock 根下
mklib() {
    sed -e "s#/etc/openwrt_release#$MR/etc/openwrt_release#g" \
        -e "s#/etc/os-release#$MR/etc/os-release#g" \
        -e "s#\"/etc/opkg/customfeeds.conf\"#\"$MR/etc/opkg/customfeeds.conf\"#" \
        -e "s#\"/etc/opkg.conf\"#\"$MR/etc/opkg.conf\"#" \
        -e "s#\"/etc/apk/repositories.d/customfeeds.list\"#\"$MR/etc/apk/repositories.d/customfeeds.list\"#" \
        -e "s#\"/etc/apk/keys\"#\"$MR/etc/apk/keys\"#" \
        -e "s#/etc/apk/repositories;#$MR/etc/apk/repositories;#" \
        -e "s#mkdir -p /etc/opkg\$#mkdir -p $MR/etc/opkg#" \
        -e "s#mkdir -p /etc/apk/repositories.d\$#mkdir -p $MR/etc/apk/repositories.d#" \
        -e "s#/proc/meminfo#$MR/proc/meminfo#g" \
        -e "s#/proc/swaps#$MR/proc/swaps#g" \
        -e "s#/sys/kernel/btf/vmlinux#$MR/sys/kernel/btf/vmlinux#g" \
        -e "s#-x /sbin/fw4#-x $MR/sbin/fw4#g" \
        -e "s#-d /usr/share/nftables.d#-d $MR/usr/share/nftables.d#g" \
        -e "s#OWP_TMP:-/tmp/owp-work#OWP_TMP:-$MR/tmp#" \
        "$SRC/common.sh" > "$MR/common.sh"
}

# 场景: mkenv <release> <arch> <pm列表> <fw4:0|1> <btf:0|1>
mkenv() {
    printf 'DISTRIB_RELEASE="%s"\nDISTRIB_ARCH="%s"\nDISTRIB_TARGET="x86/64"\nDISTRIB_DESCRIPTION="OpenWrt %s"\n' \
        "$1" "$2" "$1" > "$MR/etc/openwrt_release"
    rm -f "$MR/bin/opkg" "$MR/bin/apk"
    for _p in $3; do printf '#!/bin/sh\nexit 0\n' > "$MR/bin/$_p"; chmod 755 "$MR/bin/$_p"; done
    [ "$4" = 1 ] && { printf '#!/bin/sh\n' > "$MR/sbin/fw4"; chmod 755 "$MR/sbin/fw4"; } || rm -f "$MR/sbin/fw4"
    [ "$5" = 1 ] && : > "$MR/sys/kernel/btf/vmlinux" || rm -f "$MR/sys/kernel/btf/vmlinux"
}

load() { PATH="$MR/bin:$PATH"; . "$MR/common.sh"; }

printf '\n=== 1. owp_ver_ge ===\n'
mkroot; mklib; mkenv 24.10.0 x86_64 opkg 1 1
( PATH="$MR/bin:$PATH"; . "$MR/common.sh"
  owp_ver_ge 25.12 25.12 && echo Y || echo N
  owp_ver_ge 24.10 25.12 && echo Y || echo N
  owp_ver_ge SNAPSHOT 25.12 && echo Y || echo N
  owp_ver_ge 23.05 24.10 && echo Y || echo N
  owp_ver_ge 26.03 25.12 && echo Y || echo N
  owp_ver_ge 25.12 SNAPSHOT && echo Y || echo N
  owp_ver_ge 6.6 5.8 && echo Y || echo N
  owp_ver_ge 5.4 5.8 && echo Y || echo N
) > "$MR/out" 2>&1
chk "版本比较矩阵" "$(tr -d '\n' < "$MR/out")" "YNYNYNYN"

printf '\n=== 2. 包管理器判定 ===\n'
for _case in "23.05.5|opkg apk|opkg" "24.10.2|opkg apk|opkg" "25.12.0|opkg apk|apk" \
             "25.12.0|apk|apk" "24.10.2|opkg|opkg" "SNAPSHOT|apk|apk" "24.10.2|apk|apk"; do
    _rel=$(echo "$_case" | cut -d'|' -f1); _pms=$(echo "$_case" | cut -d'|' -f2)
    _want=$(echo "$_case" | cut -d'|' -f3)
    mkenv "$_rel" x86_64 "$_pms" 1 1
    _got=$( PATH="$MR/bin:$PATH"; . "$MR/common.sh"; owp_detect_env; echo "$OWP_PM" )
    chk "$_rel + [$_pms]" "$_got" "$_want"
done

printf '\n=== 3. 分支归一化 ===\n'
for _case in "24.10.2|24.10" "23.05|23.05" "25.12.0-rc1|25.12" "SNAPSHOT|SNAPSHOT" "24.10-SNAPSHOT|SNAPSHOT"; do
    _rel=$(echo "$_case" | cut -d'|' -f1); _want=$(echo "$_case" | cut -d'|' -f2)
    mkenv "$_rel" x86_64 opkg 1 1
    _got=$( PATH="$MR/bin:$PATH"; . "$MR/common.sh"; owp_detect_env; echo "$OWP_BRANCH" )
    chk "$_rel -> $_want" "$_got" "$_want"
done

printf '\n=== 4. 软件源增删幂等 (opkg) ===\n'
mkenv 24.10.2 x86_64 opkg 1 1
( PATH="$MR/bin:$PATH"; . "$MR/common.sh"; owp_detect_env
  owp_feed_add nikki https://a/nikki >/dev/null
  owp_feed_add nikki https://b/nikki >/dev/null
  owp_feed_add passwall_luci https://c/pw >/dev/null
) >/dev/null 2>&1
chk "重复添加只留一行"   "$(grep -c ' nikki ' "$MR/etc/opkg/customfeeds.conf")" "1"
chk "保留后写入的 URL"   "$(grep ' nikki ' "$MR/etc/opkg/customfeeds.conf")" "src/gz nikki https://b/nikki"
chk "两个源都在"         "$(wc -l < "$MR/etc/opkg/customfeeds.conf" | tr -d ' ')" "2"
( PATH="$MR/bin:$PATH"; . "$MR/common.sh"; owp_detect_env; owp_feed_del nikki ) >/dev/null 2>&1
chk "删除 nikki 后剩 1 行" "$(wc -l < "$MR/etc/opkg/customfeeds.conf" | tr -d ' ')" "1"
chk "passwall_luci 未被误删" "$(grep -c passwall_luci "$MR/etc/opkg/customfeeds.conf")" "1"

printf '\n=== 5. 软件源增删幂等 (apk) ===\n'
mkenv 25.12.0 x86_64 apk 1 1
( PATH="$MR/bin:$PATH"; . "$MR/common.sh"; owp_detect_env
  owp_feed_add nikki https://a/x86_64/nikki >/dev/null
  owp_feed_add nikki https://b/x86_64/nikki >/dev/null
  owp_feed_add passwall2 https://c/x86_64/passwall2 >/dev/null
) >/dev/null 2>&1
F="$MR/etc/apk/repositories.d/customfeeds.list"
chk "apk 行指向 packages.adb" "$(grep nikki "$F")" "https://b/x86_64/nikki/packages.adb"
chk "apk 去重"               "$(grep -c nikki "$F")" "1"
chk "apk 两个源"             "$(wc -l < "$F" | tr -d ' ')" "2"

printf '\n=== 6. 清理旧版失效源 ===\n'
mkenv 24.10.2 x86_64 opkg 1 1
cat > "$MR/etc/opkg/customfeeds.conf" <<'EOF'
src/gz custom_plugins https://dl.openwrt.ai/latest/packages/x86_64/kiddin9
src/gz keepme https://example.org/feed
src/gz kiddin9 https://dl.openwrt.ai/releases/24.10/packages/x86_64/kiddin9
EOF
( PATH="$MR/bin:$PATH"; . "$MR/common.sh"; owp_detect_env; owp_clean_legacy_feeds ) >/dev/null 2>&1
chk "dl.openwrt.ai 全部清掉" "$(grep -c 'dl\.openwrt\.ai' "$MR/etc/opkg/customfeeds.conf")" "0"
chk "无关源保留"             "$(cat "$MR/etc/opkg/customfeeds.conf")" "src/gz keepme https://example.org/feed"

printf '\n=== 7. 签名开关 ===\n'
( PATH="$MR/bin:$PATH"; . "$MR/common.sh"; owp_detect_env; owp_sigcheck_off ) >/dev/null 2>&1
chk "关闭签名校验" "$(grep -c '^#option check_signature' "$MR/etc/opkg.conf")" "1"
( PATH="$MR/bin:$PATH"; . "$MR/common.sh"; owp_detect_env; OWP_SIGCHECK_OFF=1; owp_sigcheck_restore ) >/dev/null 2>&1
chk "恢复签名校验" "$(grep -c '^option check_signature' "$MR/etc/opkg.conf")" "1"

printf '\n=== 8. GitHub JSON 解析 ===\n'
mkdir -p "$MR/tmp"
cat > "$MR/tmp/gh.json" <<'EOF'
[{"tag_name":"dae-lang-core-1.2","assets":[]},
 {"tag_name":"v1.4.0","assets":[
   {"browser_download_url":"https://github.com/daeuniverse/daed/releases/download/v1.4.0/daed-linux-x86_64.zip"},
   {"browser_download_url":"https://github.com/daeuniverse/daed/releases/download/v1.4.0/daed-linux-arm64.zip"}]},
 {"tag_name":"daed_1.3-r2","assets":[
   {"browser_download_url":"https://github.com/x/y/releases/download/daed_1.3-r2/daed_1.3-r2_x86_64-openwrt-24.10.ipk"},
   {"browser_download_url":"https://github.com/x/y/releases/download/daed_1.3-r2/luci-app-daed_1.3-r2_all-openwrt-24.10.ipk"},
   {"browser_download_url":"https://github.com/x/y/releases/download/daed_1.3-r2/luci-i18n-daed-zh-cn_1.3-r2_all-openwrt-24.10.ipk"}]},
 {"tag_name":"v1.3.0","assets":[]}]
EOF
( PATH="$MR/bin:$PATH"; . "$MR/common.sh"; owp_detect_env
  owp_gh_pick_tag "$MR/tmp/gh.json" '^v[0-9]'
  owp_gh_pick_tag "$MR/tmp/gh.json" '^daed_'
  owp_gh_asset "$MR/tmp/gh.json" v1.4.0 '/daed-linux-x86_64\.zip$'
  owp_gh_asset "$MR/tmp/gh.json" daed_1.3-r2 '/daed_[0-9][0-9A-Za-z.~-]*_x86_64-openwrt-24\.10\.ipk$'
  owp_gh_asset "$MR/tmp/gh.json" daed_1.3-r2 '/luci-app-daed_[0-9A-Za-z.~-]*_all-openwrt-24\.10\.ipk$'
) > "$MR/out" 2>&1
chk "挑 ^v[0-9] tag(跳过 dae-lang-core)" "$(sed -n 1p "$MR/out")" "v1.4.0"
chk "挑 ^daed_ tag"                      "$(sed -n 2p "$MR/out")" "daed_1.3-r2"
chk "取 zip 资产"                        "$(sed -n 3p "$MR/out")" "https://github.com/daeuniverse/daed/releases/download/v1.4.0/daed-linux-x86_64.zip"
chk "daed 核心包不误匹配 luci-app"       "$(sed -n 4p "$MR/out")" "https://github.com/x/y/releases/download/daed_1.3-r2/daed_1.3-r2_x86_64-openwrt-24.10.ipk"
chk "luci-app-daed 独立匹配"             "$(sed -n 5p "$MR/out")" "https://github.com/x/y/releases/download/daed_1.3-r2/luci-app-daed_1.3-r2_all-openwrt-24.10.ipk"

printf '\n=== 9. 目录列表取最新包 (homeproxy 正则) ===\n'
cat > "$MR/tmp/dir.html" <<'EOF'
<a href="luci-app-homeproxy_1.0.0-r1_all.ipk">luci-app-homeproxy_1.0.0-r1_all.ipk</a>
<a href="luci-app-homeproxy_1.12.0-r20250901_all.ipk">luci-app-homeproxy_1.12.0-r20250901_all.ipk</a>
<a href="luci-i18n-homeproxy-zh-cn_1.12.0-r20250901_all.ipk">x</a>
EOF
_got=$( PATH="$MR/bin:$PATH"; . "$MR/common.sh"
        grep -oE 'luci-app-homeproxy_[0-9A-Za-z._~+-]*_all\.ipk' "$MR/tmp/dir.html" | sort -u | tail -n1 )
chk "取到最新 homeproxy 包名" "$_got" "luci-app-homeproxy_1.12.0-r20250901_all.ipk"

printf '\n=== 10. owp_in_list ===\n'
( PATH="$MR/bin:$PATH"; . "$MR/common.sh"
  owp_in_list x86_64 "$OWP_DAED_ARCHS" && echo Y || echo N
  owp_in_list mips_24kc "$OWP_DAED_ARCHS" && echo Y || echo N
  owp_in_list 23.05 "$OWP_PW_BRANCHES" && echo Y || echo N
  owp_in_list SNAPSHOT "$OWP_PW_BRANCHES" && echo Y || echo N
  owp_in_list mips_24kc "$OWP_DDNSGO_ARCHS" && echo Y || echo N
) > "$MR/out" 2>&1
chk "架构/分支白名单" "$(tr -d '\n' < "$MR/out")" "YNYYY"

printf '\n=== 11. 环境自检报告(四种环境跑通不报错) ===\n'
for _case in "23.05.5|mips_24kc|opkg|1|0" "24.10.2|x86_64|opkg|1|1" \
             "25.12.0|aarch64_generic|apk|1|1" "SNAPSHOT|riscv64_riscv64|apk|1|0"; do
    _rel=$(echo "$_case" | cut -d'|' -f1); _ar=$(echo "$_case" | cut -d'|' -f2)
    _pm=$(echo  "$_case" | cut -d'|' -f3); _fw=$(echo "$_case" | cut -d'|' -f4)
    _bt=$(echo  "$_case" | cut -d'|' -f5)
    mkenv "$_rel" "$_ar" "$_pm" "$_fw" "$_bt"
    if ( PATH="$MR/bin:$PATH"; . "$MR/common.sh"; owp_env_report ) > "$MR/rep-$_rel" 2>&1; then
        _n=$(grep -cE '可装|受限|不可' "$MR/rep-$_rel")
        chk "$_rel/$_ar 报告 8 行结论" "$_n" "8"
    else
        t_bad "$_rel/$_ar 自检报告执行失败"; cat "$MR/rep-$_rel"
    fi
done

printf '\n=== 12. 模块顶部引导可独立解析 ===\n'
for _m in nikki.sh homeproxy.sh openclash.sh passwall.sh "DDNS+argo+qr.sh" dae.sh update_plugins.sh; do
    if sh -n "$SRC/$_m" 2>/dev/null && busybox ash -n "$SRC/$_m" 2>/dev/null; then
        t_ok "$_m 语法"
    else t_bad "$_m 语法"; fi
    if grep -q 'OWP_COMMON' "$SRC/$_m"; then t_ok "$_m 引用 OWP_COMMON"; else t_bad "$_m 未引用 OWP_COMMON"; fi
done

printf '\n=== 13. 禁止把 dl.openwrt.ai 当软件源 / 禁止跳过证书校验 ===\n'
for _m in common.sh nikki.sh homeproxy.sh openclash.sh passwall.sh "DDNS+argo+qr.sh" dae.sh update_plugins.sh; do
    # 只允许出现在"清理"逻辑里,不允许作为 URL 使用
    if grep -E 'https?://dl\.openwrt\.ai' "$SRC/$_m" | grep -vqE '^[[:space:]]*#'; then
        t_bad "$_m 把 dl.openwrt.ai 当成了软件源"
    else t_ok "$_m 未把 dl.openwrt.ai 当软件源"; fi
    if grep -vE '^[[:space:]]*#' "$SRC/$_m" | grep -qE 'no-check-certificate|curl[^|]* -k[ "]|--insecure'; then
        t_bad "$_m 跳过了证书校验"
    else t_ok "$_m 未跳过证书校验"; fi
done

printf '\n===============================\n'
if [ "$FAILED" = 0 ]; then printf '全部通过\n'; else printf '失败 %s 项\n' "$FAILED"; exit 1; fi
