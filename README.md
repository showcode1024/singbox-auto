# 🚀 sing-box 一键安装与管理面板

### 1. 默认极速安装（推荐）
指定端口并使用默认安全参数(默认41454端口)：
```bash
curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh vless=41454 tuic=41454 safe=0
```
### 2. 纯交互式菜单安装
不带任何参数执行，将启动完整交互式向导：
```bash
curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh
```
## 📖 命令行参数详解

| 参数名称 | 示例值 | 说明 |
| :--- | :--- | :--- |
| `vless` | `vless=41454` | 指定 VLESS 节点端口。端口需在 `10000-65535` 之间；设置为 `0` 表示不安装 VLESS 节点。低于 10000 会要求重新输入。 |
| `tuic` | `tuic=41454` | 指定 TUIC v5 节点端口。端口需在 `10000-65535` 之间；设置为 `0` 表示不安装 TUIC 节点。低于 10000 会要求重新输入。 |
| `safe` | `safe=0` | **安全模式开关**：<br>• `0`：静默使用预设默认 UUID、Reality 私钥、公钥及 SNI，跳过提问。<br>• `1`：弹出菜单询问是否全新生成随机 UUID 与密钥对。 |

---

## 🛠️ 管理面板快捷呼出

安装完成后，在服务器终端任意路径输入 **`ysq`** 即可调出管理控制台：

```bash
ysq
```

### 🖥️ 控制台界面预览：
```text
==============================
 ysq sing-box 管理面板
==============================
状态文件: /etc/sing-box/ysq-state.db
配置文件: /etc/sing-box/config.json

序号 节点名                       协议   端口   类型                 落地 (国家：ip)
---- ---------------------------- ------ ------ -------------------- --------------------
1    🇯🇵日本-vless                 TCP    20001  VLESS 直出           -
2    🇯🇵日本-tuic5                 UDP    20002  TUIC v5 直出         -
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
```

---



## 📂 文件与路径结构

| 路径 | 说明 |
| :--- | :--- |
| `/usr/local/bin/ysq` | 管理面板快捷入口命令 |
| `/etc/sing-box/config.json` | sing-box 服务端核心运行配置 |
| `/etc/sing-box/ysq-state.db` | 节点、落地池及配置参数状态持久化存储库（JSON 格式） |
| `/etc/sing-box/cert/` | TUIC v5 自签证书存放目录（基于 EC prime256v1） |
| `/root/singbox-node-info.txt` | 节点直链及参数信息汇总 |
| `/root/singbox-nodes.yaml` | 预生成的 Clash YAML 代理配置文件 |

---

## ⚙️ 系统兼容性

| 操作系统 / 发行版 | 支持状态 | 进程管理器 |
| :--- | :---: | :---: |
| **Debian 10+ / Ubuntu 20.04+** | ✅ 完全支持 | `systemd` |
| **CentOS 7+ / Rocky / AlmaLinux** | ✅ 完全支持 | `systemd` |
| **Alpine Linux (3.16+)** | ✅ 完全支持 | `OpenRC` / `nohup` (自动配置 libc 兼容) |
| **Docker / LXC 极简容器环境** | ✅ 完全支持 | `nohup` 自动兜底守护 |

---

## ⚠️ 注意事项

1. **防火墙放行**：如果服务器开启了防火墙（如 `ufw`、`firewalld` 或云厂商安全组），请务必在控制台放行对应的 TCP / UDP 端口。

