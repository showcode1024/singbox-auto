cat > install-singbox-ysq.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# =========================
# 默认端口
# =========================
VLESS_DIRECT_PORT=20001
TUIC_PORT=20002
VLESS_RELAY_PORT=20003

# =========================
# 默认参数
# 选择“不生成新密钥”时会使用这些
# =========================
DEFAULT_UUID="a1126537-6b28-4fd3-856c-2514a7626a8b"
DEFAULT_PRIVATE_KEY="GOThQzAstrApbL92Kb-BU_7GXKOrRfNDQMK74qrEB0g"
DEFAULT_PUBLIC_KEY="pyrWuKuPUx-bt6NOFvugQEszO8XR2qYeKZhVw_dysCM"
DEFAULT_SHORT_ID="884158a048b01725"
DEFAULT_TUIC_PASS="884158a048b01725"

REALITY_SNI="www.microsoft.com"
TUIC_SNI="www.bing.com"

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/sing-box/cert"
INFO_FILE="/root/singbox-node-info.txt"
YAML_FILE="/root/singbox-nodes.yaml"
PANEL_FILE="/usr/local/bin/ysq"
INSTALLER_FILE="/root/install-singbox-ysq.sh"

ask_port() {
  local name="$1"
  local default_port="$2"
  local input_port=""

  while true; do
    printf "%s [默认 %s，直接回车使用默认]: " "$name" "$default_port" >&2
    read -r input_port

    if [ -z "$input_port" ]; then
      echo "$default_port"
      return
    fi

    if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
      echo "$input_port"
      return
    fi

    echo "端口输入错误，请输入 1-65535 之间的数字。" >&2
  done
}

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行：sudo bash install-singbox-ysq.sh"
  exit 1
fi

echo "=============================="
echo " ysq sing-box 一键安装脚本"
echo " VLESS / TUIC / VLESS中转"
echo "=============================="
echo

echo "请选择是否生成新的 UUID / REALITY 密钥 / ShortID："
echo "1) 生成新的"
echo "2) 不生成，使用脚本内默认参数"
read -rp "请输入 1 或 2: " KEY_CHOICE

echo
echo "请选择要生成的节点："
echo "1) 只生成 VLESS"
echo "2) 只生成 TUIC"
echo "3) 生成 VLESS + TUIC"
read -rp "请输入 1 / 2 / 3: " NODE_CHOICE

case "$NODE_CHOICE" in
  1)
    ENABLE_VLESS=1
    ENABLE_TUIC=0
    ;;
  2)
    ENABLE_VLESS=0
    ENABLE_TUIC=1
    ;;
  3)
    ENABLE_VLESS=1
    ENABLE_TUIC=1
    ;;
  *)
    echo "输入错误，只能输入 1 / 2 / 3"
    exit 1
    ;;
esac

echo
echo "=============================="
echo "端口设置"
echo "=============================="

if [ "$ENABLE_VLESS" = "1" ]; then
  VLESS_DIRECT_PORT="$(ask_port "请输入 VLESS 直出 TCP 端口" "$VLESS_DIRECT_PORT")"
fi

if [ "$ENABLE_TUIC" = "1" ]; then
  TUIC_PORT="$(ask_port "请输入 TUIC UDP 端口" "$TUIC_PORT")"
fi

echo
echo "是否开启 VLESS 中转转发？"
echo "开启后会额外生成一个 VLESS 中转入口。"
echo "客户端连接本机中转端口，本机再转发到落地节点。"
echo "1) 开启"
echo "2) 不开启"
read -rp "请输入 1 或 2: " RELAY_CHOICE

if [ "$RELAY_CHOICE" = "1" ]; then
  ENABLE_RELAY=1

  echo
  echo "=============================="
  echo "中转设置"
  echo "=============================="

  VLESS_RELAY_PORT="$(ask_port "请输入 VLESS 中转入口 TCP 端口" "$VLESS_RELAY_PORT")"

  echo
  echo "注意：落地地址不能填 0.0.0.0，必须填真实落地 VPS IP 或域名。"
  read -rp "请输入落地节点 IP 或域名: " LANDING_SERVER

  if [ "$LANDING_SERVER" = "0.0.0.0" ]; then
    echo "落地地址不能是 0.0.0.0"
    exit 1
  fi

  LANDING_PORT="$(ask_port "请输入落地节点 VLESS 端口" "$VLESS_DIRECT_PORT")"

  if [ -z "$LANDING_SERVER" ] || [ -z "$LANDING_PORT" ]; then
    echo "落地 IP/域名 和端口不能为空"
    exit 1
  fi
else
  ENABLE_RELAY=0
  LANDING_SERVER=""
  LANDING_PORT="0"
fi

echo
echo "正在准备环境..."
apt update
apt install -y curl wget uuid-runtime openssl jq ca-certificates iproute2

echo
echo "正在安装 sing-box..."
if ! command -v sing-box >/dev/null 2>&1; then
  bash <(curl -fsSL https://sing-box.app/deb-install.sh) || curl -fsSL https://sing-box.app/install.sh | sh
else
  echo "检测到 sing-box 已安装，跳过安装。"
fi

mkdir -p "$CONFIG_DIR" "$CERT_DIR"

if [ "$KEY_CHOICE" = "1" ]; then
  echo
  echo "正在生成新的 UUID / REALITY 密钥 / ShortID..."

  UUID="$(sing-box generate uuid)"
  KEYPAIR="$(sing-box generate reality-keypair)"
  PRIVATE_KEY="$(echo "$KEYPAIR" | awk -F': ' '/PrivateKey/ {print $2}')"
  PUBLIC_KEY="$(echo "$KEYPAIR" | awk -F': ' '/PublicKey/ {print $2}')"
  SHORT_ID="$(openssl rand -hex 8)"
  TUIC_PASS="$SHORT_ID"

elif [ "$KEY_CHOICE" = "2" ]; then
  echo
  echo "使用脚本内默认参数..."

  UUID="$DEFAULT_UUID"
  PRIVATE_KEY="$DEFAULT_PRIVATE_KEY"
  PUBLIC_KEY="$DEFAULT_PUBLIC_KEY"
  SHORT_ID="$DEFAULT_SHORT_ID"
  TUIC_PASS="$DEFAULT_TUIC_PASS"

else
  echo "输入错误，只能输入 1 或 2"
  exit 1
fi

if [ "$ENABLE_TUIC" = "1" ]; then
  echo
  echo "正在生成 TUIC 自签证书..."
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CERT_DIR/tuic.key" \
    -out "$CERT_DIR/tuic.crt" \
    -days 3650 \
    -subj "/CN=${TUIC_SNI}"

  chmod 600 "$CERT_DIR/tuic.key"
fi

echo
echo "正在写入 sing-box 配置..."

jq -n \
  --arg uuid "$UUID" \
  --arg private_key "$PRIVATE_KEY" \
  --arg public_key "$PUBLIC_KEY" \
  --arg short_id "$SHORT_ID" \
  --arg tuic_pass "$TUIC_PASS" \
  --arg reality_sni "$REALITY_SNI" \
  --arg tuic_sni "$TUIC_SNI" \
  --arg cert_path "$CERT_DIR/tuic.crt" \
  --arg key_path "$CERT_DIR/tuic.key" \
  --arg landing_server "$LANDING_SERVER" \
  --arg landing_port "$LANDING_PORT" \
  --arg vless_direct_port "$VLESS_DIRECT_PORT" \
  --arg tuic_port "$TUIC_PORT" \
  --arg vless_relay_port "$VLESS_RELAY_PORT" \
  --arg enable_vless "$ENABLE_VLESS" \
  --arg enable_tuic "$ENABLE_TUIC" \
  --arg enable_relay "$ENABLE_RELAY" \
'
def vless_in($tag; $port):
{
  "type": "vless",
  "tag": $tag,
  "listen": "::",
  "listen_port": ($port | tonumber),
  "users": [
    {
      "uuid": $uuid,
      "flow": "xtls-rprx-vision"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": $reality_sni,
    "reality": {
      "enabled": true,
      "handshake": {
        "server": $reality_sni,
        "server_port": 443
      },
      "private_key": $private_key,
      "short_id": [
        $short_id
      ],
    }
  }
};

def tuic_in:
{
  "type": "tuic",
  "tag": "tuic-direct",
  "listen": "::",
  "listen_port": ($tuic_port | tonumber),
  "users": [
    {
      "name": "user1",
      "uuid": $uuid,
      "password": $tuic_pass
    }
  ],
  "congestion_control": "bbr",
  "auth_timeout": "3s",
  "zero_rtt_handshake": false,
  "heartbeat": "10s",
  "tls": {
    "enabled": true,
    "server_name": $tuic_sni,
    "alpn": [
      "h3"
    ],
    "certificate_path": $cert_path,
    "key_path": $key_path
  }
};

def landing_out:
{
  "type": "vless",
  "tag": "landing-vless",
  "server": $landing_server,
  "server_port": ($landing_port | tonumber),
  "uuid": $uuid,
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": $reality_sni,
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": $public_key,
      "short_id": $short_id
    }
  },
  "packet_encoding": "xudp"
};

{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds":
    (
      (if $enable_vless == "1" then [vless_in("vless-direct"; $vless_direct_port)] else [] end)
      +
      (if $enable_relay == "1" then [vless_in("vless-relay-to-landing"; $vless_relay_port)] else [] end)
      +
      (if $enable_tuic == "1" then [tuic_in] else [] end)
    ),
  "outbounds":
    (
      [
        {
          "type": "direct",
          "tag": "direct"
        }
      ]
      +
      (if $enable_relay == "1" then [landing_out] else [] end)
    ),
  "route": {
    "rules":
      (
        (if $enable_relay == "1" then
          [
            {
              "inbound": [
                "vless-relay-to-landing"
              ],
              "action": "route",
              "outbound": "landing-vless"
            }
          ]
        else [] end)
        +
        (if ($enable_vless == "1" or $enable_tuic == "1") then
          [
            {
              "inbound":
                (
                  (if $enable_vless == "1" then ["vless-direct"] else [] end)
                  +
                  (if $enable_tuic == "1" then ["tuic-direct"] else [] end)
                ),
              "action": "route",
              "outbound": "direct"
            }
          ]
        else [] end)
      ),
    "final": "direct"
  }
}
' > "$CONFIG_FILE"

echo
echo "正在检查配置..."
sing-box check -c "$CONFIG_FILE"

echo
echo "正在启动 sing-box..."
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box

SERVER_IP="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="$(hostname -I | awk '{print $1}')"
fi

VLESS_DIRECT_LINK="vless://${UUID}@${SERVER_IP}:${VLESS_DIRECT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#HK-VLESS-DIRECT"
VLESS_RELAY_LINK="vless://${UUID}@${SERVER_IP}:${VLESS_RELAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#HK-VLESS-RELAY"
TUIC_LINK="tuic://${UUID}:${TUIC_PASS}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&sni=${TUIC_SNI}&allow_insecure=1#HK-TUIC"

echo
echo "正在生成节点信息..."

cat > "$INFO_FILE" <<INFO
==============================
ysq sing-box 节点信息
==============================

服务器地址: ${SERVER_IP}

UUID: ${UUID}
REALITY PrivateKey: ${PRIVATE_KEY}
REALITY PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}

INFO

if [ "$ENABLE_VLESS" = "1" ]; then
cat >> "$INFO_FILE" <<INFO
==============================
VLESS 直出节点
==============================
名称: HK-VLESS-DIRECT
地址: ${SERVER_IP}
端口: ${VLESS_DIRECT_PORT}
UUID: ${UUID}
SNI: ${REALITY_SNI}
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}
Flow: xtls-rprx-vision
Fingerprint: chrome

直链:
${VLESS_DIRECT_LINK}

INFO
fi

if [ "$ENABLE_RELAY" = "1" ]; then
cat >> "$INFO_FILE" <<INFO
==============================
VLESS 中转节点
==============================
名称: HK-VLESS-RELAY
地址: ${SERVER_IP}
端口: ${VLESS_RELAY_PORT}
UUID: ${UUID}
SNI: ${REALITY_SNI}
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}
Flow: xtls-rprx-vision
Fingerprint: chrome

直链:
${VLESS_RELAY_LINK}

中转落地:
${LANDING_SERVER}:${LANDING_PORT}

注意：
落地 VPS 上必须有对应的 VLESS-REALITY 入站。
落地入站要和香港出站对应。

落地入站使用：
UUID: ${UUID}
PrivateKey: ${PRIVATE_KEY}
ShortID: ${SHORT_ID}
SNI: ${REALITY_SNI}

香港 outbound 使用：
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}

INFO
fi

if [ "$ENABLE_TUIC" = "1" ]; then
cat >> "$INFO_FILE" <<INFO
==============================
TUIC 节点
==============================
名称: HK-TUIC
地址: ${SERVER_IP}
端口: ${TUIC_PORT}
UUID: ${UUID}
Password: ${TUIC_PASS}
SNI: ${TUIC_SNI}
ALPN: h3
skip-cert-verify: true
congestion-controller: bbr

直链:
${TUIC_LINK}

INFO
fi

cat >> "$INFO_FILE" <<INFO
==============================
端口说明
==============================
VLESS 直出: TCP ${VLESS_DIRECT_PORT}
VLESS 中转: TCP ${VLESS_RELAY_PORT}
TUIC: UDP ${TUIC_PORT}

配置文件: ${CONFIG_FILE}
节点信息: ${INFO_FILE}
YAML配置: ${YAML_FILE}

以后输入 ysq 可以打开管理面板。
INFO

echo
echo "正在生成 Clash / Mihomo YAML..."

cat > "$YAML_FILE" <<YAML
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: true
  enhanced-mode: fake-ip
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - 8.8.8.8
    - 1.1.1.1

proxies:
YAML

PROXY_NAMES=()

if [ "$ENABLE_VLESS" = "1" ]; then
cat >> "$YAML_FILE" <<YAML
  - name: HK-VLESS-DIRECT
    type: vless
    server: ${SERVER_IP}
    port: ${VLESS_DIRECT_PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
YAML
PROXY_NAMES+=("HK-VLESS-DIRECT")
fi

if [ "$ENABLE_RELAY" = "1" ]; then
cat >> "$YAML_FILE" <<YAML
  - name: HK-VLESS-RELAY
    type: vless
    server: ${SERVER_IP}
    port: ${VLESS_RELAY_PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
YAML
PROXY_NAMES+=("HK-VLESS-RELAY")
fi

if [ "$ENABLE_TUIC" = "1" ]; then
cat >> "$YAML_FILE" <<YAML
  - name: HK-TUIC
    type: tuic
    server: ${SERVER_IP}
    port: ${TUIC_PORT}
    uuid: ${UUID}
    password: ${TUIC_PASS}
    alpn:
      - h3
    sni: ${TUIC_SNI}
    skip-cert-verify: true
    congestion-controller: bbr
    udp-relay-mode: native
YAML
PROXY_NAMES+=("HK-TUIC")
fi

cat >> "$YAML_FILE" <<YAML

proxy-groups:
  - name: PROXY
    type: select
    proxies:
YAML

for name in "${PROXY_NAMES[@]}"; do
  echo "      - ${name}" >> "$YAML_FILE"
done

cat >> "$YAML_FILE" <<YAML
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
YAML

echo
echo "正在安装 ysq 面板命令..."

cat > "$PANEL_FILE" <<'PANEL'
#!/usr/bin/env bash

INFO_FILE="/root/singbox-node-info.txt"
YAML_FILE="/root/singbox-nodes.yaml"
CONFIG_FILE="/etc/sing-box/config.json"

show_ports() {
  if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
    PORTS="$(jq -r '.inbounds[].listen_port' "$CONFIG_FILE" 2>/dev/null | paste -sd'|' -)"
    if [ -n "$PORTS" ]; then
      ss -lntup | grep -E ":(${PORTS})\\b" || true
      return
    fi
  fi

  ss -lntup | grep sing-box || true
}

while true; do
  clear
  echo "=============================="
  echo " ysq sing-box 管理面板"
  echo "=============================="
  echo "1) 查看节点直链"
  echo "2) 查看 Clash / Mihomo YAML"
  echo "3) 查看 sing-box 状态"
  echo "4) 重启 sing-box"
  echo "5) 彻底删除 sing-box 和脚本"
  echo "0) 退出"
  echo "=============================="
  read -rp "请输入选项: " choice

  case "$choice" in
    1)
      clear
      if [ -f "$INFO_FILE" ]; then
        cat "$INFO_FILE"
      else
        echo "未找到节点信息文件：$INFO_FILE"
      fi
      echo
      read -rp "按回车返回面板..."
      ;;
    2)
      clear
      if [ -f "$YAML_FILE" ]; then
        cat "$YAML_FILE"
      else
        echo "未找到 YAML 文件：$YAML_FILE"
      fi
      echo
      read -rp "按回车返回面板..."
      ;;
    3)
      clear
      systemctl status sing-box --no-pager || true
      echo
      echo "当前监听端口："
      show_ports
      echo
      read -rp "按回车返回面板..."
      ;;
    4)
      clear
      systemctl restart sing-box
      echo "sing-box 已重启。"
      echo
      systemctl status sing-box --no-pager || true
      echo
      read -rp "按回车返回面板..."
      ;;
    5)
      clear
      echo "危险操作：这会彻底删除 sing-box、配置、证书、节点信息、YAML、ysq 面板和安装脚本。"
      read -rp "确认删除请输入 YES: " confirm
      if [ "$confirm" = "YES" ]; then
        echo "正在停止 sing-box..."
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true

        echo "正在卸载 sing-box..."
        apt purge -y sing-box 2>/dev/null || true
        apt remove -y sing-box 2>/dev/null || true

        echo "正在删除残留文件..."
        rm -f /usr/local/bin/sing-box
        rm -f /usr/bin/sing-box
        rm -f /etc/systemd/system/sing-box.service
        rm -rf /etc/sing-box
        rm -rf /var/lib/sing-box
        rm -rf /var/log/sing-box

        rm -f /root/singbox-node-info.txt
        rm -f /root/singbox-nodes.yaml
        rm -f /root/install-singbox-ysq.sh
        rm -f /root/install-singbox.sh
        rm -f /root/singbox-install.sh
        rm -f /usr/local/bin/ysq

        systemctl daemon-reload 2>/dev/null || true

        echo
        echo "已彻底删除。"
        echo "ysq 命令也已删除。"
        exit 0
      else
        echo "已取消删除。"
        sleep 1
      fi
      ;;
    0)
      exit 0
      ;;
    *)
      echo "输入错误。"
      sleep 1
      ;;
  esac
done
PANEL

chmod +x "$PANEL_FILE"

cp "$0" "$INSTALLER_FILE" 2>/dev/null || true
chmod +x "$INSTALLER_FILE" 2>/dev/null || true

echo
echo "=============================="
echo "安装完成"
echo "=============================="
echo
cat "$INFO_FILE"

echo
echo "=============================="
echo "Clash / Mihomo YAML"
echo "=============================="
cat "$YAML_FILE"

echo
echo "=============================="
echo "当前监听端口"
echo "=============================="
PORTS="$(jq -r '.inbounds[].listen_port' "$CONFIG_FILE" 2>/dev/null | paste -sd'|' -)"
if [ -n "$PORTS" ]; then
  ss -lntup | grep -E ":(${PORTS})\\b" || true
else
  ss -lntup | grep sing-box || true
fi

echo
echo "以后输入下面命令打开面板："
echo
echo "ysq"
echo
echo "防火墙放行参考："
if [ "$ENABLE_VLESS" = "1" ]; then
  echo "TCP ${VLESS_DIRECT_PORT}"
fi
if [ "$ENABLE_RELAY" = "1" ]; then
  echo "TCP ${VLESS_RELAY_PORT}"
fi
if [ "$ENABLE_TUIC" = "1" ]; then
  echo "UDP ${TUIC_PORT}"
fi
EOF
