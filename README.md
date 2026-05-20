# singbox-auto v1

一个基于 **sing-box** 的自用节点一键安装与管理脚本，支持快速生成 **VLESS Reality**、**TUIC v5** 节点，并支持通过面板随时添加、删除、修改节点端口。

脚本适合用于个人 VPS 节点部署、双机中转、落地机转发等场景。

## 一键安装

使用 root 用户执行：

```bash
curl -Ls -o install-singbox-ysq.sh https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh && bash install-singbox-ysq.sh
```

如果当前系统没有 `curl`，可以先安装：

```bash
apt update
apt install -y curl
```

> 仅供学习、研究和合法网络加速用途，请遵守所在地区法律法规。

---

## 功能特点

- 一键安装 sing-box
- 支持 VLESS Reality 直出节点
- 支持 TUIC v5 直出节点
- 支持 VLESS 转 VLESS 中转
- 支持 TUIC v5 转 VLESS 中转
- 支持自动根据服务器 IP 所在地和协议生成节点名称
- 支持生成节点直链
- 支持生成 Clash / Mihomo YAML 配置
- 支持面板管理
  - 查看节点
  - 查看 YAML
  - 查看 sing-box 状态
  - 添加节点
  - 删除节点
  - 修改节点端口
  - 重启 sing-box
  - 卸载脚本和 sing-box
- 面板不会清屏，不会覆盖之前命令行输出
- 依赖较少，不安装不必要组件

---

## 支持的节点类型

### 1. VLESS Reality 直出

客户端直接连接当前 VPS，由当前 VPS 访问外网。

```text
客户端 -> 当前 VPS -> 外网
```

---

### 2. TUIC v5 直出

客户端使用 TUIC v5 连接当前 VPS，适合 UDP 体验较好的线路。

```text
客户端 -> 当前 VPS -> 外网
```

---

### 3. VLESS 转 VLESS 中转

当前 VPS 作为中转机，最终由落地机访问外网。

```text
客户端 -> 当前 VPS(VLESS入口) -> 落地 VPS(VLESS Reality) -> 外网
```

---

### 4. TUIC v5 转 VLESS 中转

客户端使用 TUIC v5 连接中转机，中转机再连接落地机的 VLESS Reality。

默认 TUIC 中转入口端口为：

```text
20004
```

链路示例：

```text
客户端 -> 当前 VPS(TUIC v5入口) -> 落地 VPS(VLESS Reality) -> 外网
```

---

## 打开管理面板

安装完成后，输入：

```bash
ysq
```

即可打开管理面板。

面板示例：

```text
==============================
 ysq sing-box 管理面板
==============================
1) 查看节点直链
2) 查看 Clash YAML
3) 查看 sing-box 状态 / 监听端口
4) 添加节点
5) 删除节点
6) 修改节点端口
7) 重启 sing-box
8) 彻底删除 sing-box 和脚本
0) 退出
==============================
```

---

## 生成的文件位置

| 文件                           | 说明                     |
| ------------------------------ | ------------------------ |
| `/etc/sing-box/config.json`    | sing-box 主配置文件      |
| `/etc/sing-box/ysq-state.json` | 脚本状态文件             |
| `/etc/sing-box/cert/`          | TUIC 自签证书目录        |
| `/root/singbox-node-info.txt`  | 节点直链信息             |
| `/root/singbox-nodes.yaml`     | Clash / Mihomo YAML 配置 |
| `/usr/local/bin/ysq`           | 管理面板命令             |
| `/root/install-singbox-ysq.sh` | 安装脚本备份             |

---

## 查看节点信息

```bash
cat /root/singbox-node-info.txt
```

---

## 查看 Clash / Mihomo 配置

```bash
cat /root/singbox-nodes.yaml
```

你也可以在面板中选择：

```text
2) 查看 Clash YAML
```

---

## 修改节点端口

执行：

```bash
ysq
```

然后选择：

```text
6) 修改节点端口
```

选择要修改的节点，输入新的端口后，脚本会自动：

1. 修改状态文件
2. 重新生成 sing-box 配置
3. 重新生成节点直链
4. 重新生成 YAML
5. 重启 sing-box

---

## 添加节点

执行：

```bash
ysq
```

然后选择：

```text
4) 添加节点
```

可添加：

```text
1) VLESS Reality 直出
2) TUIC v5 直出
3) VLESS 转 VLESS
4) TUIC v5 转 VLESS
```

---

## 删除节点

执行：

```bash
ysq
```

然后选择：

```text
5) 删除节点
```

删除后会自动重新生成配置并重启 sing-box。

---

## 查看 sing-box 状态

```bash
systemctl status sing-box --no-pager
```

或者打开面板：

```bash
ysq
```

选择：

```text
3) 查看 sing-box 状态 / 监听端口
```

---

## 重启 sing-box

```bash
systemctl restart sing-box
```

或者通过面板选择：

```text
7) 重启 sing-box
```

---

## 卸载

执行：

```bash
ysq
```

选择：

```text
8) 彻底删除 sing-box 和脚本
```

会删除：

- sing-box 程序
- sing-box 配置
- TUIC 证书
- 节点信息
- YAML 文件
- ysq 管理面板命令

---

## 端口说明

默认端口如下：

| 类型               | 默认端口 |
| ------------------ | -------- |
| VLESS Reality 直出 | `20001`  |
| TUIC v5 直出       | `20002`  |
| VLESS 转 VLESS     | `20003`  |
| TUIC v5 转 VLESS   | `20004`  |

如果 VPS 有防火墙、安全组或 NAT 端口限制，请确保对应 TCP / UDP 端口已放行。

常见端口类型：

| 协议                 | 端口类型 |
| -------------------- | -------- |
| VLESS Reality        | TCP      |
| TUIC v5              | UDP      |
| VLESS 转 VLESS入口   | TCP      |
| TUIC v5 转 VLESS入口 | UDP      |

---

## 常见问题

### 1. TUIC 节点连不上怎么办？

请检查 UDP 端口是否放行。

例如 TUIC 使用 `20002`，需要确认服务器安全组、防火墙、NAT 映射都允许 UDP `20002`。

---

### 2. VLESS Reality 连不上怎么办？

请检查：

- TCP 端口是否放行
- 客户端 Reality 公钥是否正确
- Short ID 是否正确
- SNI 是否与节点信息一致
- 客户端是否开启 Reality / Vision

---

### 3. 中转节点怎么填落地信息？

添加中转节点时，落地地址需要填写真实落地 VPS 的 IP 或域名。

例如：

```text
落地地址: 1.2.3.4
落地端口: 20001
```

落地机必须已经部署好 VLESS Reality 节点。

---

### 4. NAT VPS 可以用吗？

可以，但必须使用服务商分配给你的可用端口。

如果服务商只给了部分端口，例如：

```text
42046-42047
```

那你添加节点或修改节点端口时，就要使用这些端口。

---

### 5. 为什么没有订阅链接？

当前版本不提供订阅链接功能，只生成：

- 节点直链
- Clash / Mihomo YAML 文件

你可以直接复制 `/root/singbox-nodes.yaml` 的内容导入客户端。

---

## 免责声明

本项目仅用于 sing-box 学习、个人服务器管理和合法网络访问优化。  
请勿用于任何违反当地法律法规、服务条款或网络安全规范的用途。  
使用本脚本产生的一切风险由使用者自行承担。
