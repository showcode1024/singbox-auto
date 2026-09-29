这里为你编写了一份专业、结构清晰且美观的 GitHub 规范 README.md，可直接复制到你的项目仓库中使用：

🚀 singbox-auto (ysq) - sing-box 一键安装与管理面板

一个轻量、高效、功能完备的 sing-box 一键部署管理脚本。支持 VLESS Reality 与 TUIC v5 协议，原生支持 TCP/UDP
端口复用、落地节点池中转管理、命令行无人值守静默安装、域名拦截屏蔽及 Clash 节点订阅/配置生成。

🌟 功能特性

  - ⚡ 双主流高速协议：支持 VLESS Reality (TCP) 与 TUIC v5 (UDP/QUIC) 直出与中转。
  - 🔄 TCP / UDP 端口复用：打破端口限制，VLESS 和 TUIC 可以监听同一个端口（如同时使用 20001）。
  - 🚀 参数化静默安装：支持在命令行直接传入端口与安全参数（vless=xxx tuic=xxx safe=0），全自动跑完安装，省去繁琐交互。
  - 🌐 独立落地节点池：
      - 自动根据落地 IP 获取属地并格式化为 国家：ip（如 🇯🇵|日本：1.2.3.4）。
      - 创建新端口时，可自由选择直出或绑定已有落地节点。
      - 随时修改落地节点参数（IP、端口、UUID、SNI 等），修改后自动联动更新所有关联的中转节点。
  - 🛡️ 指定网站屏蔽：内置黑名单路由过滤（REJECT），支持域名后缀快速清洗与拦截。
  - 📋 开箱即用导出：自动生成直连链接与标准 Clash Meta (Mihomo) YAML 配置文件。
  - 🌍 双栈自由切换：支持随时在 IPv4 与 IPv6 之间切换导出地址，并自动更新节点属地命名。
  - 💻 全系统广泛兼容：支持 Debian、Ubuntu、CentOS、Rocky Linux、AlmaLinux 以及 Alpine Linux（针对
    musl 环境自动适配 gcompat / glibc）。

📥 一键安装与部署

1. 极速静默安装（推荐）

指定端口并使用默认安全参数（safe=0 免去一切交互确认，端口需 \ge 10000）：

curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh vless=20001 tuic=20002 safe=0

2. TCP / UDP 端口复用安装

VLESS（TCP）与 TUIC（UDP）由于协议类型不同，可以直接复用同一个端口：

curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh vless=20001 tuic=20001 safe=0

3. 按需单协议安装（设为 0 即不安装该协议）

  - 仅安装 VLESS 直出节点：
    curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh vless=20001 tuic=0 safe=0
  - 仅安装 TUIC 直出节点：
    curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh vless=0 tuic=20002 safe=0

4. 自定义密钥交互式安装

如果需要全新随机生成 UUID、Reality 密钥对及 ShortID，请传入 safe=1：

curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh vless=20001 tuic=20002 safe=1

5. 纯交互式菜单安装

不带任何参数执行，将启动完整交互式向导：

curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh

🛠️ 管理面板快捷呼出

安装完成后，在服务器终端任意路径输入 ysq 即可调出管理控制台：

ysq

🖥️ 控制台界面预览：

==============================
 ysq sing-box 管理面板
==============================
状态文件: /etc/sing-box/ysq-state.db
配置文件: /etc/sing-box/config.json

序号 节点名                       协议   端口   类型                 落地 (国家：ip)
---- ---------------------------- ------ ------ -------------------- --------------------
1    🇯🇵日本-vless                 TCP    20001  VLESS 直出           -
2    🇯🇵日本-tuic5                 UDP    20001  TUIC v5 直出         -
3    🇯🇵日本-vless转vless          TCP    20003  VLESS -> VLESS 中转  🇺🇸美国：1.2.3.4

1) 查看节点直链
2) 查看 Clash YAML
3) 查看 sing-box 状态 / 监听端口
4) 添加节点 (直出 / 中转落地)
5) 落地节点池管理 (查看 / 添加 / 修改 / 删除)
6) 删除节点 (支持批量)
7) 修改节点 (端口 / SNI / 出口落地)
8) 屏蔽指定网站管理
9) 更新 sing-box 内核
10) 重启 sing-box
11) 刷新公网 IP (IPv4/IPv6 切换)
12) 彻底删除 sing-box 和脚本
0) 退出
==============================

📖 命令行参数详解

| 参数名称    | 示例值           | 说明                                                                                             |
| :------ | :------------ | :--------------------------------------------------------------------------------------------- |
| `vless` | `vless=20001` | 指定 VLESS 节点端口。端口需在 `10000-65535` 之间；设置为 `0` 表示不安装 VLESS 节点。低于 10000 会要求重新输入。                   |
| `tuic`  | `tuic=20002`  | 指定 TUIC v5 节点端口。端口需在 `10000-65535` 之间；设置为 `0` 表示不安装 TUIC 节点。低于 10000 会要求重新输入。                  |
| `safe`  | `safe=0`      | **安全模式开关**：<br>• `0`：静默使用预设默认 UUID、Reality 私钥、公钥及 SNI，跳过提问。<br>• `1`：弹出菜单询问是否全新生成随机 UUID 与密钥对。 |

💡 特色功能使用指南

1. 独立落地节点池与中转（Relay）

  - 在面板选择 5) 落地节点池管理，你可以统一维护自己的落地服务器（输入落地 IP、端口、UUID、PublicKey 等）。
  - 脚本自动通过 IP 接口测定归属地，展示为例如 🇯🇵|日本：1.2.3.4。
  - 在新建节点或修改已有节点时，可一键将出站方式指定为该落地。
  - 改落地零成本：当落地 VPS 更换 IP 或端口时，只需在落地管理中修改一次，所有关联中转节点自动同步最新配置并重启 sing-box。

2. 网站/域名屏蔽（黑名单）

  - 面板选择 8) 屏蔽指定网站管理。
  - 支持直接粘贴网址（如 https://www.tiktok.com/explore），脚本内置自动清洗过滤逻辑，精准提取顶级域名后缀注入
    sing-box 的 block 规则中。

3. Clash Meta / Mihomo 配置文件导出

  - 生成的文件位于 /root/singbox-nodes.yaml。
  - 直接将内容复制到本地 Clash Verge / Clash Nyanpasu / Flclash 等现代 Clash 内核客户端即可立即使用。

📂 文件与路径结构

| 路径                            | 说明                                 |
| :---------------------------- | :--------------------------------- |
| `/usr/local/bin/ysq`          | 管理面板快捷入口命令                         |
| `/etc/sing-box/config.json`   | sing-box 服务端核心运行配置                 |
| `/etc/sing-box/ysq-state.db`  | 节点、落地池及配置参数状态持久化存储库（JSON 格式）       |
| `/etc/sing-box/cert/`         | TUIC v5 自签证书存放目录（基于 EC prime256v1） |
| `/root/singbox-node-info.txt` | 节点直链及参数信息汇总                        |
| `/root/singbox-nodes.yaml`    | 预生成的 Clash YAML 代理配置文件             |

⚙️ 系统兼容性

| 操作系统 / 发行版                        | 支持状态   | 进程管理器                             |
| :-------------------------------- | :----: | :-------------------------------: |
| **Debian 10+ / Ubuntu 20.04+**    | ✅ 完全支持 | `systemd`                         |
| **CentOS 7+ / Rocky / AlmaLinux** | ✅ 完全支持 | `systemd`                         |
| **Alpine Linux (3.16+)**          | ✅ 完全支持 | `OpenRC` / `nohup` (自动配置 libc 兼容) |
| **Docker / LXC 极简容器环境**           | ✅ 完全支持 | `nohup` 自动兜底守护                    |

⚠️ 注意事项

1.  防火墙放行：如果服务器开启了防火墙（如 ufw、firewalld 或云厂商安全组），请务必在控制台放行对应的 TCP / UDP 端口。
2.  TUIC 客户端设置：由于 TUIC v5 采用高强度自签证书，客户端连接时需启用 跳过证书验证 (allowInsecure /
    skip-cert-verify: true)。
3.  Reality SNI 选择：默认伪装域名为 www.nvidia.com，如需自定义，可在面板修改节点 SNI 或在状态文件中变更。
