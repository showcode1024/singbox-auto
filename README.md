# 🚀 sing-box 一键安装与管理面板

## 📦 快速安装

### 1. 默认极速安装（推荐）
指定端口并使用预设默认参数（默认 `41454` 端口）：
```bash
curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh vless=41454 tuic=41454 -y
```

### 2. 仅安装核心与面板（按需在面板建节点）
不带节点参数执行，将安装 `sing-box` 并初始化基础密钥，随后通过 `ysq` 面板按需添加节点与落地：
```bash
curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh
```

## 📖 命令行参数详解

| 参数名称 | 示例值 | 说明 |
| :--- | :--- | :--- |
| `vless` | `vless=41454` | 指定 VLESS Reality 节点端口（`10000-65535`，`0` 或不填表示不创建）。低于 `10000` 会直接报错退出。 |
| `tuic` | `tuic=41454` | 指定 TUIC v5 节点端口（`10000-65535`，`0` 或不填表示不创建）。低于 `10000` 会直接报错退出。 |
| `-y` / `--yes` | `-y` | **静默模式**：使用预设默认 UUID、Reality 密钥与 SNI，跳过交互提问。不加 `-y` 时会询问是否全新生成随机密钥。 |

> 已存在有效的 `/etc/sing-box/ysq-state.db` 时，重新运行安装脚本会自动沿用其中的密钥、节点、落地池与分流配置，不会覆盖。

---

## ✨ 核心特性

基于自编译 `sing-box`（内置 `with_quic` / `with_utls` / `with_clash_api` / `with_v2ray_api`）与单文件 Go 辅助工具 `singbox-plus` 的轻量部署与管理脚本，支持单机独立运行，也支持按需接入 [center-panel.py](center-panel.py) 网页中控。

- **入站协议**：VLESS Reality (TCP) + TUIC v5 (UDP)，支持同端口 TCP/UDP 复用，支持多用户独立 UUID / TUIC 密码。
- **独立落地节点池**：支持 **VLESS Reality**、**TUIC v5**、**SOCKS5**（免密 / 账密认证）、**Shadowsocks**（AEAD / SS-2022），支持手动配置或直接粘贴分享链接（`vless://`、`tuic://`、`socks5://`、`socks://`、`ss://`）由 `singbox-plus parse-landing` 自动识别解析。
- **主备落地自动切换**：中转节点可配置主落地 + 备用落地，通过独立守护服务 `ysq-failover`（`singbox-plus failover`）持续探测，主落地故障自动切备，恢复后自动回切。
- **分流与流量统计**：支持域名直连 / 屏蔽及 sing-box Rule Set（JSON / SRS）；由 `singbox-plus stats` 直连本机 V2Ray API 实时按用户、按节点查看流量，无需额外安装 `grpcurl`。
- **可选网页中控**：通过单文件 [center-panel.py](center-panel.py)（纯 Python 标准库 + SQLite）提供多节点统一用户管理、配额控制、订阅导出与行为日志审计。
- **安全与轻量**：所有配置均先经 `sing-box check` 校验再原子替换，失败自动回滚；`sing-box` 日志输出统一由 `singbox-plus wrap` 托管并执行不可变分片轮转（单片 4 MiB，保留 2 个历史分片 + 1 个当前文件，上限约 12 MiB），无 `copytruncate` 竞态，也无需定时裁剪任务。
- **全节点零 Python 依赖**：无论是单机模式还是中控托管模式，节点端均不依赖 Python 与 `grpcurl`——日志轮转、落地链接解析、主备切换、流量统计与中控 Agent（内置 `bbolt` 账本）全部由单一静态 Go 二进制 `/usr/local/libexec/singbox-plus` 原生提供，原生兼容 CentOS 7+、Debian 10+、Ubuntu 20.04+、Rocky/AlmaLinux、Alpine 3.16+ 与 Docker/LXC（Python 3.9+ 仅部署在独立管理机的 `center-panel.py` 端需要）。

---

## 🛠️ 管理面板快捷呼出

安装完成后，在服务器终端任意路径输入 **`ysq`** 即可调出管理控制台：

```bash
ysq
```

### 🖥️ 控制台界面预览
```text
==============================
 ysq sing-box 管理面板
==============================
运行状态: ● 运行中  |  版本: v1.14.3  |  内存占用: 24.5 MB
监听端口: ● 正常
状态文件: /etc/sing-box/ysq-state.db
配置文件: /etc/sing-box/config.json

序号  节点名                        协议  端口   类型                    主落地                备用落地
----  ----------------------------  ----  -----  ----------------------  --------------------  --------------------
1     🇯🇵日本-vless                  TCP   20001  VLESS 直出              -                     -
2     🇯🇵日本-tuic5                  UDP   20002  TUIC v5 直出            -                     -
3     🇯🇵日本-vless转socks5-🇺🇸美国   TCP   20003  VLESS -> SOCKS5 中转    🇺🇸美国：1.2.3.4       🇸🇬新加坡：5.6.7.8
4     🇯🇵日本-vless转ss-🇸🇬新加坡     TCP   20004  VLESS -> SS 中转        🇸🇬新加坡：5.6.7.8     -

1)  查看节点直链
2)  查看 Clash YAML
3)  查看 sing-box 日志
4)  添加节点
5)  删除节点
6)  修改节点
7)  落地节点池管理
8)  用户管理
9)  流量统计
10) 分流管理
11) 更新 sing-box 内核
12) 重启 sing-box
13) 刷新公网 IP
14) 更新面板
15) 中控连接管理
16) 删除 sing-box
0)  退出
==============================
```

---

## 🌐 落地节点池支持的协议

在主菜单选择 **`7) 落地节点池管理` → `1) 添加落地节点`**，支持直接粘贴分享链接或手动输入配置：

| 落地协议 | 支持的分享链接格式 | 关键特性 |
| :--- | :--- | :--- |
| **VLESS Reality** | `vless://...` | TCP + `xtls-rprx-vision` + Reality，支持自定义指纹与 ShortID |
| **TUIC v5** | `tuic://...` | QUIC/UDP，支持 `bbr`/`cubic`/`new_reno`、ALPN、自签证书跳过校验与 `udp_over_stream` |
| **SOCKS5** | `socks5://` / `socks5h://` / `socks://` | 支持无认证与用户名+密码认证，兼容 Shadowrocket / v2rayN 的 `socks://<base64>@host:port` 格式 |
| **Shadowsocks** | `ss://...` | 支持 SIP002、SS-2022（单用户与多用户 `serverKey:userKey`）、旧版整串 Base64；支持 `2022-blake3-*` / `aes-*-gcm` / `chacha20-ietf-poly1305` / `xchacha20-ietf-poly1305` / `none` |

---

## 🎛️ 可选网页中控（`center-panel.py`）

如需集中管理多台节点的用户、流量配额、订阅与行为日志，可在独立管理机部署 [center-panel.py](center-panel.py)（仅监听本机回环地址，由 Nginx 反向代理提供 HTTPS）：

```bash
# 首次初始化管理员（密码至少 12 位）
python3 center-panel.py --init-admin admin --data-dir /var/lib/ysq-center

# 启动服务（默认 127.0.0.1:8099）
python3 center-panel.py --data-dir /var/lib/ysq-center --origin https://panel.example.com
```

在网页中控新增服务器获取一次性接入码后，于节点终端执行 `ysq` → `15) 中控连接管理` → `1) HTTPS 连接中控` 粘贴 `HTTPS地址|接入码` 即可自动完成接入。

---

## 📂 文件与路径结构

| 路径 | 说明 |
| :--- | :--- |
| `/usr/local/bin/ysq` | 管理面板快捷入口命令 |
| `/usr/local/libexec/singbox-plus` | 单文件静态 Go 辅助工具（日志轮转 `wrap`、流量统计 `stats`、落地链接解析 `parse-landing`、主备切换 `failover`、可选中控 `agent`） |
| `/etc/sing-box/config.json` | sing-box 服务端核心运行配置（日志输出至 stdout，由 `singbox-plus wrap` 托管） |
| `/etc/sing-box/ysq-state.db` | 节点、落地池、用户及分流状态持久化存储库（JSON 格式，权限 `600`） |
| `/etc/sing-box/cert/` | TUIC v5 自签证书存放目录（基于 EC `prime256v1`） |
| `/var/log/sing-box/` | sing-box 不可变分片日志目录（`sing-box.log` 及历史分片 `sing-box.<时间戳>-<序号>.log`，默认 4 MiB × 保留 2 个历史分片） |
| `/var/lib/ysq-failover/status.json` | 主备落地故障切换状态文件（仅在配置备用落地时由 `singbox-plus failover` 更新） |
| `/var/lib/ysq-agent/` | 可选中控 Agent 本地 `bbolt` 流量账本与行为缓存目录（仅在接入中控时创建） |
| `/root/singbox-node-info.txt` | 节点直链及参数信息汇总 |
| `/root/singbox-nodes.yaml` | 预生成的 Clash YAML 代理配置文件 |

---

## ⚙️ 系统兼容性

| 操作系统 / 发行版 | 支持状态 | 进程管理器 |
| :--- | :---: | :---: |
| **Debian 10+ / Ubuntu 20.04+** | ✅ 完全支持 | `systemd` |
| **CentOS 7+ / Rocky / AlmaLinux** | ✅ 完全支持 | `systemd` |
| **Alpine Linux (3.16+)** | ✅ 完全支持 | `OpenRC` / `nohup` |
| **Docker / LXC 极简容器环境** | ✅ 完全支持 | `nohup` 自动兜底守护 |

---

## ⚠️ 注意事项

1. **防火墙放行**：如果服务器开启了防火墙（如 `ufw`、`firewalld` 或云厂商安全组），请务必在控制台放行对应的 TCP / UDP 端口。
2. **端口预留**：本机回环端口 `127.0.0.1:41453`（V2Ray API）和 `127.0.0.1:41452`（主备切换 Clash API）仅监听回环地址，不对外开放。
3. **最低配置**：最低内存要求 128 MB。节点端（无论是单机模式还是中控托管模式）均无需安装 Python 与 `grpcurl`；Python 3.9+ 仅独立管理机部署 [center-panel.py](center-panel.py) 时需要。
