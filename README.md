🚀 OpenWrt 核心插件智能更新脚本说明书
这份脚本专门为解决 OpenWrt 跨版本（23.xx 的 opkg 与 24.10+ 的 apk）软件源不兼容、更新繁琐的问题而生。


💻 第一步：在软路由上一键执行
以后无论您面对的是哪台 OpenWrt，或者是哪个版本的固件，只需要通过 SSH 登录到软路由后台，直接复制并执行下面这行命令即可（请替换为您自己的脚本链接）：

```bash

sh -c "$(curl -kLs https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main/update_plugins.sh)"
```

(注：加入了 -k 参数是为了防止某些老旧软路由的 SSL 证书过期导致 curl 下载脚本失败。)

🎛️ 第二步：交互菜单详解
执行命令后，脚本会弹出两级交互菜单，完全傻瓜式操作：

🟢 第一级：系统架构探测菜单
脚本会首先启动“智能探针”，侦测当前软路由的底层包管理器。

选项 1：使用默认设定

推荐选择！ 脚本会根据探针的结果，自动帮您决定是走经典 OPKG 路线还是全新 APK 路线。

选项 2 / 选项 3：手动强制模式

如果您确认当前固件经过魔改（探针失效），或者您想跨版本强制刷入，可以选择这两项进行“越权强杀”。

🟡 第二级：插件精准更新菜单
在确定了架构后，脚本会询问您具体要动哪块蛋糕：

1. 仅更新 OpenClash：只向系统注入 OpenClash 的源，并仅对 luci-app-openclash 发起更新指令，Passwall 完全不受影响。

2. 仅更新 Passwall：同上，只针对 Passwall。

3. 同时更新两者：一键双雕。

选择完毕后，脚本将自动完成：写源 -> 更新软件列表 -> 下载升级插件 -> 重启对应服务 的全自动流水线。

🚑 第三步：极客避坑指南 (FAQ)
Q1：新版 24.10 的 apk 模式下，为什么会有个 --allow-untrusted 参数？
新版的 Alpine 包管理器对安全性要求极高，默认必须有公钥签名的源才能安装。因为我们使用的是 GitHub 个人仓库作为软件源（通常没有配置复杂的签名校验），加上这个参数可以强行绕过验证直接安装，防止报错阻断。

Q2：如果我只选了更新 OpenClash，Passwall 会重启断网吗？
绝对不会。这套脚本采用了“精准变量管控”，如果您在第二级菜单只选了 OpenClash，脚本在最后一步只会执行 /etc/init.d/openclash restart，其他任何服务都会保持稳定运行。

Q3：源添加过一次，第二次跑脚本会重复添加导致配置文件爆炸吗？
不会的。脚本内置了 grep -q 去重判定逻辑。在向 customfeeds.conf 或 repositories 写入源地址前，它会先扫描里面是不是已经有这行代码了，如果有，它会直接跳过写入步骤，绝对保持系统的纯净。

🟢 情况一：软路由已经能科学上网（直连 GitHub）
直接复制这行执行：

```bash
sh -c "$(curl -kLs https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main/update_plugins.sh)"
```

🔴 情况二：软路由在国内纯净网络（无法直连 GitHub）
利用国内的 Ghproxy 镜像加速代理，直接复制这行执行：

```bash
sh -c "$(curl -kLs https://mirror.ghproxy.com/https://raw.githubusercontent.com/JBl9527/update_plugins.sh/main/update_plugins.sh)"
```
