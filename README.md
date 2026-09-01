# update_plugins.sh

给**纯净官方 OpenWrt** 用的插件一键安装脚本。自动识别固件版本、架构、包管理器（opkg / apk）和防火墙世代，检测依赖、按需添加官方上游软件源，然后装插件。

不依赖任何"某某大佬全家桶源"。旧版本脚本里硬编码的 `dl.openwrt.ai`（kiddin9）源已经不能用于纯净 OpenWrt，新版本不但不再使用，还会在每次运行时把它从你的 `customfeeds.conf` 里清掉。

## 快速开始

```sh
# 交互菜单
sh -c "$(curl -fsSL https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main/update_plugins.sh)"

# 或者先下载再跑
curl -fsSLO https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main/update_plugins.sh
sh update_plugins.sh
```

**第一次用请先选 `1) 环境自检`**，它会打印固件信息，并逐个列出每个插件在你这台设备上到底能不能装、不能装的原因是什么。不看这个直接装，遇到"上游没为你的架构编译"这类问题会一头雾水。

非交互用法：

```sh
sh update_plugins.sh check       # 只做环境自检
sh update_plugins.sh nikki       # 直接装 nikki
sh update_plugins.sh all         # 全家桶
```

可用参数：`check` `base` `openclash` `passwall` `nikki` `homeproxy` `daed` `all`。

## 包含哪些插件

| 插件 | 来源 | 安装方式 |
|---|---|---|
| qrencode（二维码，命令行） | 官方源 | 直接安装 |
| Argon 主题 + argon-config | jerrykuku/luci-theme-argon | GitHub Release |
| ddns-go | sirpdboy/luci-app-ddns-go | GitHub Release（只有 10 种架构） |
| WireGuard | 官方源 | 直接安装 |
| OpenClash | vernesong/OpenClash | GitHub Release（官方无软件源） |
| PassWall / PassWall2 | 官方 SourceForge 构建源 | 添加软件源 |
| nikki (Mihomo) | nikkinikki.pages.dev | 添加软件源（**要 24.10+**） |
| homeproxy (sing-box) | ImmortalWrt 构建产物 | 只下单包，不加源 |
| daed (dae eBPF) | QiuSimons 成品包 / 官方二进制 | 二选一，见下 |

## 已知限制（这些不是脚本的 bug，是上游的边界）

**nikki 装不到 23.05 及更早**。上游 `feed.sh` 自己就只为 `openwrt-24.10` / `openwrt-25.12` / `SNAPSHOT` 三个分支构建软件源，23.05 直接被判定为 unsupported。脚本会明确告诉你原因并退出，不会去乱试。

**daed 对内核要求很硬**。需要内核 ≥ 5.8 且有 `/sys/kernel/btf/vmlinux`（CO-RE）。官方 OpenWrt 的部分设备固件没开 `CONFIG_DEBUG_INFO_BTF`，这种情况下包能装上但服务起不来，只能换固件。另外成品 LuCI 包只有 `x86_64` / `i386_pentium4` / `aarch64_generic` 三种架构，其余架构脚本会退回"官方二进制 + 自建 procd 服务"，功能可用但**没有 LuCI 界面**，要用命令行启用：

```sh
uci set daed.config.enabled='1' && uci commit daed
/etc/init.d/daed enable && /etc/init.d/daed start
```

成品包里的 `daed` 声明依赖 `vmlinux-btf`，这个包只存在于 ImmortalWrt，官方源没有，所以脚本用 `--force-depends` 跳过它。

**ddns-go 只编译 10 种架构**，不在其中的设备会被跳过（自检会写明）。

**PassWall 只发 21.02 / 22.03 / 23.05 / 24.10 / 25.12 和 SNAPSHOT**，且 SNAPSHOT 只有 apk 包。架构没被构建时脚本会**回滚它刚加的三个软件源**再退出，不会留下一堆 update 报错的死源。

**homeproxy 在 23.05 上只能装 2025-10 的冻结版**，因为官方 23.05 源里没有 `ucode-mod-digest`，且上游之后不再为 23.05 构建。

## 版本与包管理器

OpenWrt 21.02 / 22.03 / 23.05 / 24.10 用 opkg + `.ipk`；**25.12 起和 SNAPSHOT 用 apk + `.apk`**（索引是 `packages.adb`）。分界线是 25.12，不是 24.10 —— 网上不少教程写错了这一点。

脚本对两套包管理器做了完整抽象：软件源写法（`src/gz` 行 vs 指向 `packages.adb` 的整行）、公钥格式（usign `.pub` vs PEM）、本地包安装参数、`apk --allow-untrusted` 等都在 `common.sh` 里分开处理，模块本身不关心用的是哪个。

## 文件结构

```
update_plugins.sh    菜单入口，只负责下载 common.sh 和各模块
common.sh            公共库：环境探测、双包管理器抽象、软件源/公钥管理、
                     GitHub Release 解析、依赖预检、临时 swap、自检报告
DDNS+argo+qr.sh      qrencode + Argon 主题 + ddns-go + WireGuard
openclash.sh         OpenClash
passwall.sh          PassWall / PassWall2（PW_EDITION=1|2|both）
nikki.sh             nikki (Mihomo)
homeproxy.sh         homeproxy (sing-box)
dae.sh               daed (dae eBPF)
mocktest.sh          本地 mock 测试，不需要 OpenWrt 设备就能跑
```

各模块可以单独执行，会自己拉 `common.sh`：

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main/nikki.sh)"
```

## 环境变量

| 变量 | 作用 |
|---|---|
| `PW_EDITION` | `1`（默认）/ `2` / `both`，选 PassWall 版本 |
| `OPENCLASH_TAG` | 指定 OpenClash 版本，如 `v0.47.156` |
| `ARGON_TAG` / `DDNSGO_TAG` / `DAED_TAG` / `DAED_LUCI_TAG` | 锁定对应上游版本 |
| `OWP_BASE_URL` | 换成你自己的仓库/镜像地址 |
| `DISTRIB_ARCH` | 架构探测失败时手动指定 |

## 脚本做了哪些防护

依赖只从官方源装，第三方源只在必须时才加、且都带公钥；加源是幂等的（重复跑不会写重复行）；失败会回滚自己加的源。

`dnsmasq-full` 替换 `dnsmasq` 时**先把包下到本地再卸旧包**，下载失败不会让路由器中途没有 DNS。

小内存设备（可用内存 < 192MB）装 ruby、sing-box 这类大包前会临时挂 256MB swap，装完自动卸掉删除文件。

同一时间只允许一个安装任务（`/tmp/owp-install.lock`），退出时通过 trap 清理临时目录、恢复被临时关掉的签名校验、卸掉临时 swap。

下载全程不使用 `-k` / `--no-check-certificate`，证书校验靠 `ca-bundle`。如果你的设备报证书错误，先校准时间（`ntpd -q -p pool.ntp.org`）。

## 本地测试

```sh
sh mocktest.sh
```

在普通 Linux 上用 mock 的 `/etc/openwrt_release`、假 opkg/apk 和预置的 GitHub JSON，覆盖版本比较、包管理器判定、分支归一化、软件源增删幂等、失效源清理、签名开关、Release 资产正则、目录列表取包、四种固件环境的自检报告等 60+ 项断言。所有脚本同时通过 `sh -n` 和 `busybox ash -n`。

## 卸载脚本加的软件源

```sh
# opkg
sed -i '/nikki/d;/passwall/d' /etc/opkg/customfeeds.conf && opkg update
# apk
sed -i '/nikki/d;/passwall/d' /etc/apk/repositories.d/customfeeds.list && apk update
```
