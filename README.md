# 🚀 sing-box 一键安装与管理面板

### 1. 默认极速安装

指定端口并静默使用预设默认参数（默认 41454 端口）：

```bash
curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh vless=41454 tuic=41454 -y
```

### 2. 交互式安装

不带任何参数执行，将只安装 sing-box 并在交互向导中询问密钥配置，安装完成后进入 `ysq` 面板按需添加节点：

```bash
curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh
```

## 📖 命令行参数详解

| 参数名称       | 示例值        | 说明                                                         |
| :------------- | :------------ | :----------------------------------------------------------- |
| `vless`        | `vless=41454` | 指定 VLESS Reality 节点端口（TCP）。端口需在 `10000-65535` 之间（`0` 表示不创建），低于 `10000` 会直接报错退出；`41452`、`41453` 已预留给本机 API。 |
| `tuic`         | `tuic=41454`  | 指定 TUIC v5 节点端口（UDP）。端口需在 `10000-65535` 之间（`0` 表示不创建），低于 `10000` 会直接报错退出；可与 VLESS 复用同一端口号。 |
| `-y` / `--yes` | `-y`          | **静默模式**：跳过提问，直接使用脚本预设的默认 UUID、Reality 密钥对、ShortID 与 SNI。不加 `-y` 时会询问是否全新随机生成。 |

---

## 🛠️ 管理面板快捷呼出

安装完成后，在服务器终端任意路径输入 **`ysq`** 即可调出管理控制台：

```bash
ysq
```

### 主要能力一览

- **入站节点**：VLESS Reality (TCP) 与 TUIC v5 (UDP)，支持同端口 TCP/UDP 复用、多用户独立凭据管理。
- **落地节点池（中转出站）**：支持 **VLESS Reality**、**TUIC v5**、**SOCKS5**、**Shadowsocks（含 SS-2022）**，支持直接粘贴 `vless://`、`tuic://`、`socks5://`、`ss://` 分享链接一键解析，并支持主备落地自动故障切换与恢复回切。
- **分流与流量统计**：支持屏蔽域名、直连域名及 sing-box Rule Set（JSON / SRS），本机 V2Ray API（`127.0.0.1:41453`）实时只读统计各用户流量。
- **可选中控管理**：配合单文件 [center-panel.py](center-panel.py) 通过 HTTPS 统一管理多台节点、用户配额、订阅（Clash / V2Ray）与行为分析。

---

## 🖥️ 中控面板部署要点（`center-panel.py`）

```bash
# 1. 初始化管理员（密码至少 12 位）
python3 center-panel.py --data-dir /var/lib/ysq-center --init-admin admin

# 2. 启动服务（仅监听本机回环，通过 Nginx 对外提供 HTTPS）
python3 center-panel.py --data-dir /var/lib/ysq-center --host 127.0.0.1 --port 8099 --origin https://your-panel.example.com

# 3. 命令行一键更新面板（也可在网页「设置 → 面板更新」中一键检查并原地重启更新）
python3 center-panel.py --update
```

Nginx 反向代理与更新说明：

- 务必设置 `proxy_set_header X-Real-IP $remote_addr;` 以确保按真实客户端 IP 限流（若无反代直连可加 `--no-trust-proxy-header`）。
- 建议对 `location ^~ /sub/` 关闭访问日志（`access_log off;`），防止订阅 URL 中的明文 token 写入 Nginx 日志。
- 网页端「面板更新」仅从服务端 `--update-url`（或 `YSQ_CENTER_UPDATE_URL`）指定的 HTTPS 源拉取，经过标识校验、语法编译及可选 SHA256 校验（`--require-update-sha256`）后原子替换、保留 `.bak` 备份并原地平滑重启；需确保运行进程用户对 `center-panel.py` 所在目录具备写权限。

---

## 📂 文件与路径结构

| 路径                                  | 说明                                                         |
| :------------------------------------ | :----------------------------------------------------------- |
| `/usr/local/bin/ysq`                  | 管理面板快捷入口命令                                         |
| `/usr/local/bin/sing-box`             | sing-box 服务端内核（需 >= 1.14.0，含 `with_quic`/`with_utls`/`with_clash_api`/`with_v2ray_api` 标签） |
| `/etc/sing-box/config.json`           | sing-box 服务端核心运行配置                                  |
| `/etc/sing-box/ysq-state.db`          | 节点、用户、落地池及分流状态持久化库（JSON 格式，权限 `600`） |
| `/etc/sing-box/cert/`                 | TUIC v5 自签证书存放目录（基于 EC prime256v1）               |
| `/root/singbox-node-info.txt`         | 节点直链及参数信息汇总（权限 `600`）                         |
| `/root/singbox-nodes.yaml`            | 预生成的 Clash YAML 代理配置文件（权限 `600`）               |
| `/usr/local/libexec/ysq-agent.py`     | 中控 Agent（按需部署，使用 Python 3.9+ 标准库）              |
| `/usr/local/libexec/ysq-failover.py`  | 主备落地切换守护进程（按需部署，以 `sing-box` 用户运行）     |
| `127.0.0.1:41453` / `127.0.0.1:41452` | 本机回环预留端口：V2Ray Stats API / 主备切换 Clash API（均不对外网开放） |

---

## ⚙️ 系统兼容性

| 操作系统 / 发行版                 |  支持状态  |                     进程管理器                     |
| :-------------------------------- | :--------: | :------------------------------------------------: |
| **Debian 10+ / Ubuntu 20.04+**    | ✅ 完全支持 |                     `systemd`                      |
| **CentOS 7+ / Rocky / AlmaLinux** | ✅ 完全支持 |                     `systemd`                      |
| **Alpine Linux (3.16+)**          | ✅ 完全支持 |                      `OpenRC`                      |
| **Docker / LXC 极简容器环境**     | ✅ 完全支持 | `nohup` 自动兜底（优先以 `sing-box` 用户降权运行） |

---

## ⚠️ 注意事项

1. **防火墙放行**：如果服务器开启了防火墙（如 `ufw`、`firewalld` 或云厂商安全组），请务必在控制台放行对应的入站 TCP / UDP 端口。
2. **最低内存**：基础单机模式最低 128 MB；若同时启用主备切换或中控 Agent（Python 3.9+），建议 256 MB 及以上。
