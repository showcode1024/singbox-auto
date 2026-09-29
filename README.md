# 🚀 singbox-auto (ysq) - sing-box 一键安装与管理面板

一个轻量、高效、功能完备的 `sing-box` 一键部署管理脚本。支持 **VLESS Reality** 与 **TUIC v5** 协议，原生支持 **TCP/UDP 端口复用**、**落地节点池中转管理**、**命令行无人值守静默安装**、**域名拦截屏蔽**及 **Clash 节点订阅/配置生成**。

---

## 🌟 功能特性

- ⚡ **双主流高速协议**：支持 `VLESS Reality` (TCP) 与 `TUIC v5` (UDP/QUIC) 直出与中转。
- 🔄 **TCP / UDP 端口复用**：打破端口限制，VLESS 和 TUIC 可以**监听同一个端口**（如同时使用 `20001`）。
- 🚀 **参数化静默安装**：支持在命令行直接传入端口与安全参数（`vless=xxx tuic=xxx safe=0`），全自动跑完安装，省去繁琐交互。
- 🌐 **独立落地节点池**：
  - 自动根据落地 IP 获取属地并格式化为 **`国家：ip`**（如 `🇯🇵|日本：1.2.3.4`）。
  - 创建新端口时，可自由选择**直出**或**绑定已有落地节点**。
  - 随时修改落地节点参数（IP、端口、UUID、SNI 等），**修改后自动联动更新**所有关联的中转节点。
- 🛡️ **指定网站屏蔽**：内置黑名单路由过滤（REJECT），支持域名后缀快速清洗与拦截。
- 📋 **开箱即用导出**：自动生成直连链接与标准 `Clash Meta (Mihomo) YAML` 配置文件。
- 🌍 **双栈自由切换**：支持随时在 IPv4 与 IPv6 之间切换导出地址，并自动更新节点属地命名。
- 💻 **全系统广泛兼容**：支持 Debian、Ubuntu、CentOS、Rocky Linux、AlmaLinux 以及 Alpine Linux（针对 musl 环境自动适配 gcompat / glibc）。

---

## 📥 一键安装与部署

### 1. 极速静默安装（推荐）
指定端口并使用默认安全参数（`safe=0` 免去一切交互确认，端口需 $\ge 10000$）：
```bash
curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh vless=20001 tuic=20002 safe=0
