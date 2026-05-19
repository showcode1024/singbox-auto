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
DEFAULT_NODE_PREFIX="🌐UN"

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/sing-box/cert"
INFO_FILE="/root/singbox-node-info.txt"
YAML_FILE="/root/singbox-nodes.yaml"
ENV_FILE="/etc/sing-box/ysq.env"
STATE_FILE="/etc/sing-box/ysq-state.env"
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

detect_country_code() {
  local code=""

  code="$(curl -4 -fsSL --max-time 6 https://ipinfo.io/country 2>/dev/null || true)"
  code="$(printf '%s' "$code" | tr -d '\r\n ' | tr '[:lower:]' '[:upper:]')"

  if ! [[ "$code" =~ ^[A-Z]{2}$ ]]; then
    code="$(curl -4 -fsSL --max-time 6 https://ifconfig.co/country-iso 2>/dev/null || true)"
    code="$(printf '%s' "$code" | tr -d '\r\n ' | tr '[:lower:]' '[:upper:]')"
  fi

  if ! [[ "$code" =~ ^[A-Z]{2}$ ]]; then
    code="$(curl -4 -fsSL --max-time 6 https://ipapi.co/country_code 2>/dev/null || true)"
    code="$(printf '%s' "$code" | tr -d '\r\n ' | tr '[:lower:]' '[:upper:]')"
  fi

  if [[ "$code" =~ ^[A-Z]{2}$ ]]; then
    echo "$code"
  else
    echo "UN"
  fi
}

country_flag() {
  local code="$1"

  case "$code" in
    SG) echo "🇸🇬" ;;
    HK) echo "🇭🇰" ;;
    TW) echo "🇹🇼" ;;
    JP) echo "🇯🇵" ;;
    KR) echo "🇰🇷" ;;
    US) echo "🇺🇸" ;;
    GB|UK) echo "🇬🇧" ;;
    DE) echo "🇩🇪" ;;
    FR) echo "🇫🇷" ;;
    NL) echo "🇳🇱" ;;
    CA) echo "🇨🇦" ;;
    AU) echo "🇦🇺" ;;
    MY) echo "🇲🇾" ;;
    TH) echo "🇹🇭" ;;
    VN) echo "🇻🇳" ;;
    PH) echo "🇵🇭" ;;
    ID) echo "🇮🇩" ;;
    IN) echo "🇮🇳" ;;
    RU) echo "🇷🇺" ;;
    TR) echo "🇹🇷" ;;
    BR) echo "🇧🇷" ;;
    MX) echo "🇲🇽" ;;
    AE) echo "🇦🇪" ;;
    SA) echo "🇸🇦" ;;
    ZA) echo "🇿🇦" ;;
    *) echo "🌐" ;;
  esac
}

auto_node_prefix() {
  local code=""
  local flag=""

  code="$(detect_country_code)"
  flag="$(country_flag "$code")"

  echo "${flag}${code}"
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

echo "=============================="
echo "节点命名设置"
echo "=============================="
echo "正在通过公网 IP 自动识别节点地区..."
NODE_PREFIX="$(auto_node_prefix)"
echo "自动识别节点名前缀：${NODE_PREFIX}"
echo "生成示例：${NODE_PREFIX}-vless / ${NODE_PREFIX}-tuic5 / ${NODE_PREFIX}-vless-relay"
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
    ENABLE_VLESS_DIRECT=1
    ENABLE_TUIC=0
    ;;
  2)
    ENABLE_VLESS_DIRECT=0
    ENABLE_TUIC=1
    ;;
  3)
    ENABLE_VLESS_DIRECT=1
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

if [ "$ENABLE_VLESS_DIRECT" = "1" ]; then
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

if [ "$ENABLE_VLESS_DIRECT" = "1" ] && [ "$ENABLE_RELAY" = "1" ] && [ "$VLESS_DIRECT_PORT" = "$VLESS_RELAY_PORT" ]; then
  echo "VLESS 直出端口和中转端口不能相同，因为它们都是 TCP。"
  exit 1
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

cat > "$ENV_FILE" <<ENV
UUID="$UUID"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
TUIC_PASS="$TUIC_PASS"
REALITY_SNI="$REALITY_SNI"
TUIC_SNI="$TUIC_SNI"
NODE_PREFIX="$NODE_PREFIX"
CONFIG_DIR="$CONFIG_DIR"
CONFIG_FILE="$CONFIG_FILE"
CERT_DIR="$CERT_DIR"
INFO_FILE="$INFO_FILE"
YAML_FILE="$YAML_FILE"
STATE_FILE="$STATE_FILE"
ENV

chmod 600 "$ENV_FILE"

cat > "$STATE_FILE" <<STATE
ENABLE_VLESS_DIRECT="$ENABLE_VLESS_DIRECT"
VLESS_DIRECT_PORT="$VLESS_DIRECT_PORT"
ENABLE_TUIC="$ENABLE_TUIC"
TUIC_PORT="$TUIC_PORT"
ENABLE_RELAY="$ENABLE_RELAY"
VLESS_RELAY_PORT="$VLESS_RELAY_PORT"
LANDING_SERVER="$LANDING_SERVER"
LANDING_PORT="$LANDING_PORT"
STATE

chmod 600 "$STATE_FILE"

echo
echo "正在安装 ysq 面板命令..."

cat > "$PANEL_FILE" <<'PANEL'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/sing-box/ysq.env"
STATE_FILE="/etc/sing-box/ysq-state.env"
PANEL_FILE="/usr/local/bin/ysq"

DEFAULT_VLESS_DIRECT_PORT=20001
DEFAULT_TUIC_PORT=20002
DEFAULT_VLESS_RELAY_PORT=20003
DEFAULT_NODE_PREFIX="🌐UN"

load_all() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "缺少环境文件：$ENV_FILE"
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$ENV_FILE"

  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi

  ENABLE_VLESS_DIRECT="${ENABLE_VLESS_DIRECT:-0}"
  VLESS_DIRECT_PORT="${VLESS_DIRECT_PORT:-$DEFAULT_VLESS_DIRECT_PORT}"
  ENABLE_TUIC="${ENABLE_TUIC:-0}"
  TUIC_PORT="${TUIC_PORT:-$DEFAULT_TUIC_PORT}"
  ENABLE_RELAY="${ENABLE_RELAY:-0}"
  VLESS_RELAY_PORT="${VLESS_RELAY_PORT:-$DEFAULT_VLESS_RELAY_PORT}"
  LANDING_SERVER="${LANDING_SERVER:-}"
  LANDING_PORT="${LANDING_PORT:-0}"
  NODE_PREFIX="${NODE_PREFIX:-$DEFAULT_NODE_PREFIX}"

  VLESS_DIRECT_NAME="${NODE_PREFIX}-vless"
  TUIC_NAME="${NODE_PREFIX}-tuic5"
  VLESS_RELAY_NAME="${NODE_PREFIX}-vless-relay"
}

save_state() {
  cat > "$STATE_FILE" <<STATE
ENABLE_VLESS_DIRECT="$ENABLE_VLESS_DIRECT"
VLESS_DIRECT_PORT="$VLESS_DIRECT_PORT"
ENABLE_TUIC="$ENABLE_TUIC"
TUIC_PORT="$TUIC_PORT"
ENABLE_RELAY="$ENABLE_RELAY"
VLESS_RELAY_PORT="$VLESS_RELAY_PORT"
LANDING_SERVER="$LANDING_SERVER"
LANDING_PORT="$LANDING_PORT"
STATE
  chmod 600 "$STATE_FILE"
}

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

enabled_count() {
  local count=0
  [ "${ENABLE_VLESS_DIRECT:-0}" = "1" ] && count=$((count + 1))
  [ "${ENABLE_TUIC:-0}" = "1" ] && count=$((count + 1))
  [ "${ENABLE_RELAY:-0}" = "1" ] && count=$((count + 1))
  echo "$count"
}

get_server_ip() {
  local ip=""
  ip="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
  if [ -z "$ip" ]; then
    ip="$(hostname -I | awk '{print $1}')"
  fi
  echo "$ip"
}

fix_permissions() {
  mkdir -p "$CONFIG_DIR" "$CERT_DIR"

  local sb_user=""
  local sb_group=""

  sb_user="$(systemctl show sing-box -p User --value 2>/dev/null || true)"

  if [ -z "$sb_user" ]; then
    sb_user="root"
  fi

  sb_group="$(id -gn "$sb_user" 2>/dev/null || echo "$sb_user")"

  chown -R "$sb_user:$sb_group" "$CONFIG_DIR" 2>/dev/null || true

  chmod 755 "$CONFIG_DIR" 2>/dev/null || true
  chmod 755 "$CERT_DIR" 2>/dev/null || true

  if [ -f "$CERT_DIR/tuic.key" ]; then
    chmod 600 "$CERT_DIR/tuic.key" 2>/dev/null || chmod 644 "$CERT_DIR/tuic.key" 2>/dev/null || true
  fi

  if [ -f "$CERT_DIR/tuic.crt" ]; then
    chmod 644 "$CERT_DIR/tuic.crt" 2>/dev/null || true
  fi
}

ensure_tuic_cert() {
  load_all

  mkdir -p "$CERT_DIR"

  if [ ! -f "$CERT_DIR/tuic.key" ] || [ ! -f "$CERT_DIR/tuic.crt" ]; then
    echo "正在生成 TUIC 自签证书..."
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$CERT_DIR/tuic.key" \
      -out "$CERT_DIR/tuic.crt" \
      -days 3650 \
      -subj "/CN=${TUIC_SNI}"
  fi

  fix_permissions
}

check_tcp_port_conflict() {
  local new_port="$1"
  local skip_name="$2"

  if [ "$skip_name" != "vless-direct" ] && [ "${ENABLE_VLESS_DIRECT:-0}" = "1" ] && [ "$new_port" = "$VLESS_DIRECT_PORT" ]; then
    echo "端口冲突：TCP $new_port 已被 VLESS 直出使用。"
    return 1
  fi

  if [ "$skip_name" != "vless-relay" ] && [ "${ENABLE_RELAY:-0}" = "1" ] && [ "$new_port" = "$VLESS_RELAY_PORT" ]; then
    echo "端口冲突：TCP $new_port 已被 VLESS 中转使用。"
    return 1
  fi

  return 0
}

write_config() {
  load_all
  mkdir -p "$CONFIG_DIR"

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
    --arg enable_vless_direct "$ENABLE_VLESS_DIRECT" \
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
      ]
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
      (if $enable_vless_direct == "1" then [vless_in("vless-direct"; $vless_direct_port)] else [] end)
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
        (if ($enable_vless_direct == "1" or $enable_tuic == "1") then
          [
            {
              "inbound":
                (
                  (if $enable_vless_direct == "1" then ["vless-direct"] else [] end)
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
}

uri_encode() {
  jq -nr --arg v "$1" '$v|@uri'
}

generate_outputs() {
  load_all

  local server_ip
  server_ip="$(get_server_ip)"

  local vless_direct_link=""
  local vless_relay_link=""
  local tuic_link=""

  local vless_direct_name="$VLESS_DIRECT_NAME"
  local vless_relay_name="$VLESS_RELAY_NAME"
  local tuic_name="$TUIC_NAME"

  local vless_direct_name_enc=""
  local vless_relay_name_enc=""
  local tuic_name_enc=""

  vless_direct_name_enc="$(uri_encode "$vless_direct_name")"
  vless_relay_name_enc="$(uri_encode "$vless_relay_name")"
  tuic_name_enc="$(uri_encode "$tuic_name")"

  vless_direct_link="vless://${UUID}@${server_ip}:${VLESS_DIRECT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${vless_direct_name_enc}"
  vless_relay_link="vless://${UUID}@${server_ip}:${VLESS_RELAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${vless_relay_name_enc}"
  tuic_link="tuic://${UUID}:${TUIC_PASS}@${server_ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&sni=${TUIC_SNI}&allow_insecure=1#${tuic_name_enc}"

  cat > "$INFO_FILE" <<INFO
==============================
ysq sing-box 节点信息
==============================

服务器地址: ${server_ip}
节点名前缀: ${NODE_PREFIX}

UUID: ${UUID}
REALITY PrivateKey: ${PRIVATE_KEY}
REALITY PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}

INFO

  if [ "$ENABLE_VLESS_DIRECT" = "1" ]; then
    cat >> "$INFO_FILE" <<INFO
==============================
VLESS 直出节点
==============================
名称: ${vless_direct_name}
地址: ${server_ip}
端口: ${VLESS_DIRECT_PORT}
UUID: ${UUID}
SNI: ${REALITY_SNI}
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}
Flow: xtls-rprx-vision
Fingerprint: chrome

直链:
${vless_direct_link}

INFO
  fi

  if [ "$ENABLE_RELAY" = "1" ]; then
    cat >> "$INFO_FILE" <<INFO
==============================
VLESS 中转节点
==============================
名称: ${vless_relay_name}
地址: ${server_ip}
端口: ${VLESS_RELAY_PORT}
UUID: ${UUID}
SNI: ${REALITY_SNI}
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}
Flow: xtls-rprx-vision
Fingerprint: chrome

直链:
${vless_relay_link}

中转落地:
${LANDING_SERVER}:${LANDING_PORT}

注意：
落地 VPS 上必须有对应的 VLESS-REALITY 入站。
如果你使用同一套参数，落地入站应使用：
UUID: ${UUID}
PrivateKey: ${PRIVATE_KEY}
ShortID: ${SHORT_ID}
SNI: ${REALITY_SNI}

中转 outbound 使用：
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}

INFO
  fi

  if [ "$ENABLE_TUIC" = "1" ]; then
    cat >> "$INFO_FILE" <<INFO
==============================
TUIC 节点
==============================
名称: ${tuic_name}
地址: ${server_ip}
端口: ${TUIC_PORT}
UUID: ${UUID}
Password: ${TUIC_PASS}
SNI: ${TUIC_SNI}
ALPN: h3
skip-cert-verify: true
congestion-controller: bbr

直链:
${tuic_link}

INFO
  fi

  cat >> "$INFO_FILE" <<INFO
==============================
端口说明
==============================
VLESS 直出: TCP ${VLESS_DIRECT_PORT}，状态：${ENABLE_VLESS_DIRECT}
VLESS 中转: TCP ${VLESS_RELAY_PORT}，状态：${ENABLE_RELAY}
TUIC: UDP ${TUIC_PORT}，状态：${ENABLE_TUIC}

配置文件: ${CONFIG_FILE}
节点信息: ${INFO_FILE}
YAML配置: ${YAML_FILE}

输入 ysq 可以打开管理面板。
INFO

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

  local proxy_names=()

  if [ "$ENABLE_VLESS_DIRECT" = "1" ]; then
    cat >> "$YAML_FILE" <<YAML
  - name: "${vless_direct_name}"
    type: vless
    server: ${server_ip}
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
    proxy_names+=("$vless_direct_name")
  fi

  if [ "$ENABLE_RELAY" = "1" ]; then
    cat >> "$YAML_FILE" <<YAML
  - name: "${vless_relay_name}"
    type: vless
    server: ${server_ip}
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
    proxy_names+=("$vless_relay_name")
  fi

  if [ "$ENABLE_TUIC" = "1" ]; then
    cat >> "$YAML_FILE" <<YAML
  - name: "${tuic_name}"
    type: tuic
    server: ${server_ip}
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
    proxy_names+=("$tuic_name")
  fi

  cat >> "$YAML_FILE" <<YAML

proxy-groups:
  - name: PROXY
    type: select
    proxies:
YAML

  for name in "${proxy_names[@]}"; do
    echo "      - \"${name}\"" >> "$YAML_FILE"
  done

  cat >> "$YAML_FILE" <<YAML
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
YAML
}

check_config() {
  if sing-box check -D /var/lib/sing-box -C /etc/sing-box; then
    return 0
  fi

  echo
  echo "配置检查失败。"
  return 1
}

apply_changes() {
  load_all

  if [ "$(enabled_count)" -lt 1 ]; then
    echo "至少要保留一个节点，不能全部删除。"
    return 1
  fi

  if [ "$ENABLE_TUIC" = "1" ]; then
    ensure_tuic_cert
  else
    fix_permissions
  fi

  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)" 2>/dev/null || true

  write_config

  if ! check_config; then
    echo "新配置有问题，未重启 sing-box。"
    return 1
  fi

  systemctl restart sing-box
  generate_outputs

  echo
  echo "操作完成，sing-box 已重启。"
}

show_ports() {
  if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
    local ports
    ports="$(jq -r '.inbounds[].listen_port' "$CONFIG_FILE" 2>/dev/null | paste -sd'|' -)"
    if [ -n "$ports" ]; then
      ss -lntup | grep -E ":(${ports})\\b" || true
      return
    fi
  fi

  ss -lntup | grep sing-box || true
}

show_current_summary() {
  load_all
  echo "当前节点状态："
  echo "节点名前缀: ${NODE_PREFIX}"
  echo "VLESS 直出: ${ENABLE_VLESS_DIRECT}，端口: ${VLESS_DIRECT_PORT}，名称: ${VLESS_DIRECT_NAME}"
  echo "TUIC: ${ENABLE_TUIC}，端口: ${TUIC_PORT}，名称: ${TUIC_NAME}"
  echo "VLESS 中转: ${ENABLE_RELAY}，端口: ${VLESS_RELAY_PORT}，名称: ${VLESS_RELAY_NAME}"
  if [ "$ENABLE_RELAY" = "1" ]; then
    echo "落地: ${LANDING_SERVER}:${LANDING_PORT}"
  fi
}

add_vless_direct() {
  load_all

  if [ "$ENABLE_VLESS_DIRECT" = "1" ]; then
    echo "VLESS 直出已经存在。"
    read -rp "是否修改 VLESS 直出端口？输入 y 修改，其他键取消: " yn
    if [ "$yn" != "y" ] && [ "$yn" != "Y" ]; then
      return
    fi
  fi

  local port
  port="$(ask_port "请输入 VLESS 直出 TCP 端口" "$VLESS_DIRECT_PORT")"

  if ! check_tcp_port_conflict "$port" "vless-direct"; then
    return
  fi

  ENABLE_VLESS_DIRECT=1
  VLESS_DIRECT_PORT="$port"
  save_state
  apply_changes
}

add_tuic() {
  load_all

  if [ "$ENABLE_TUIC" = "1" ]; then
    echo "TUIC 已经存在。"
    read -rp "是否修改 TUIC 端口？输入 y 修改，其他键取消: " yn
    if [ "$yn" != "y" ] && [ "$yn" != "Y" ]; then
      return
    fi
  fi

  local port
  port="$(ask_port "请输入 TUIC UDP 端口" "$TUIC_PORT")"

  ENABLE_TUIC=1
  TUIC_PORT="$port"
  save_state
  ensure_tuic_cert
  apply_changes
}

add_relay() {
  load_all

  if [ "$ENABLE_RELAY" = "1" ]; then
    echo "VLESS 中转已经存在。"
    read -rp "是否修改中转端口或落地信息？输入 y 修改，其他键取消: " yn
    if [ "$yn" != "y" ] && [ "$yn" != "Y" ]; then
      return
    fi
  fi

  local relay_port
  relay_port="$(ask_port "请输入 VLESS 中转入口 TCP 端口" "$VLESS_RELAY_PORT")"

  if ! check_tcp_port_conflict "$relay_port" "vless-relay"; then
    return
  fi

  local landing_server
  local landing_port

  read -rp "请输入落地节点 IP 或域名: " landing_server

  if [ -z "$landing_server" ] || [ "$landing_server" = "0.0.0.0" ]; then
    echo "落地地址不能为空，也不能是 0.0.0.0"
    return
  fi

  landing_port="$(ask_port "请输入落地节点 VLESS 端口" "$VLESS_DIRECT_PORT")"

  ENABLE_RELAY=1
  VLESS_RELAY_PORT="$relay_port"
  LANDING_SERVER="$landing_server"
  LANDING_PORT="$landing_port"

  save_state
  apply_changes
}

delete_vless_direct() {
  load_all

  if [ "$ENABLE_VLESS_DIRECT" != "1" ]; then
    echo "VLESS 直出不存在。"
    return
  fi

  if [ "$(enabled_count)" -le 1 ]; then
    echo "不能删除最后一个节点。"
    return
  fi

  read -rp "确认删除 VLESS 直出？输入 y 确认: " confirm
  if [ "$confirm" = "y" ]; then
    ENABLE_VLESS_DIRECT=0
    save_state
    apply_changes
  else
    echo "已取消。"
  fi
}

delete_tuic() {
  load_all

  if [ "$ENABLE_TUIC" != "1" ]; then
    echo "TUIC 不存在。"
    return
  fi

  if [ "$(enabled_count)" -le 1 ]; then
    echo "不能删除最后一个节点。"
    return
  fi

  read -rp "确认删除 TUIC？输入 y 确认: " confirm
  if [ "$confirm" = "y" ]; then
    ENABLE_TUIC=0
    save_state
    apply_changes
  else
    echo "已取消。"
  fi
}

delete_relay() {
  load_all

  if [ "$ENABLE_RELAY" != "1" ]; then
    echo "VLESS 中转不存在。"
    return
  fi

  if [ "$(enabled_count)" -le 1 ]; then
    echo "不能删除最后一个节点。"
    return
  fi

  read -rp "确认删除 VLESS 中转？输入 y 确认: " confirm
  if [ "$confirm" = "y" ]; then
    ENABLE_RELAY=0
    LANDING_SERVER=""
    LANDING_PORT="0"
    save_state
    apply_changes
  else
    echo "已取消。"
  fi
}

add_menu() {
  while true; do
    clear
    echo "=============================="
    echo " 添加 / 修改 节点"
    echo "=============================="
    show_current_summary
    echo "=============================="
    echo "1) 添加/修改 VLESS 直出"
    echo "2) 添加/修改 TUIC"
    echo "3) 添加/修改 VLESS 中转"
    echo "0) 返回"
    echo "=============================="
    read -rp "请输入选项: " choice

    case "$choice" in
      1)
        clear
        add_vless_direct
        read -rp "按回车继续..."
        ;;
      2)
        clear
        add_tuic
        read -rp "按回车继续..."
        ;;
      3)
        clear
        add_relay
        read -rp "按回车继续..."
        ;;
      0)
        return
        ;;
      *)
        echo "输入错误。"
        sleep 1
        ;;
    esac
  done
}

delete_menu() {
  while true; do
    clear
    echo "=============================="
    echo " 删除节点"
    echo "=============================="
    show_current_summary
    echo "=============================="
    echo "1) 删除 VLESS 直出"
    echo "2) 删除 TUIC"
    echo "3) 删除 VLESS 中转"
    echo "0) 返回"
    echo "=============================="
    read -rp "请输入选项: " choice

    case "$choice" in
      1)
        clear
        delete_vless_direct
        read -rp "按回车继续..."
        ;;
      2)
        clear
        delete_tuic
        read -rp "按回车继续..."
        ;;
      3)
        clear
        delete_relay
        read -rp "按回车继续..."
        ;;
      0)
        return
        ;;
      *)
        echo "输入错误。"
        sleep 1
        ;;
    esac
  done
}

uninstall_all() {
  clear
  echo "危险操作：这会彻底删除 sing-box、配置、证书、节点信息、YAML、ysq 面板和安装脚本。"
  read -rp "确认删除请输入 y: " confirm

  if [ "$confirm" = "y" ]; then
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
    rm -f "$PANEL_FILE"

    systemctl daemon-reload 2>/dev/null || true

    echo
    echo "已彻底删除。"
    echo "ysq 命令也已删除。"
    exit 0
  else
    echo "已取消删除。"
    sleep 1
  fi
}

main_menu() {
  load_all

  while true; do
    clear
    echo "=============================="
    echo " ysq sing-box 管理面板"
    echo "=============================="
    show_current_summary
    echo "=============================="
    echo "1) 查看节点直链"
    echo "2) 查看 Clash YAML"
    echo "3) 查看 sing-box 状态"
    echo "4) 重启 sing-box"
    echo "5) 添加/修改节点"
    echo "6) 删除节点"
    echo "7) 查看 sing-box 配置文件"
    echo "8) 彻底删除 sing-box 和脚本"
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
        generate_outputs
        echo "sing-box 已重启。"
        echo
        systemctl status sing-box --no-pager || true
        echo
        read -rp "按回车返回面板..."
        ;;
      5)
        add_menu
        ;;
      6)
        delete_menu
        ;;
      7)
        clear
        if [ -f "$CONFIG_FILE" ]; then
          jq . "$CONFIG_FILE" 2>/dev/null || cat "$CONFIG_FILE"
        else
          echo "未找到配置文件：$CONFIG_FILE"
        fi
        echo
        read -rp "按回车返回面板..."
        ;;
      8)
        uninstall_all
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
}

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行 ysq。"
  exit 1
fi

case "${1:-}" in
  rebuild)
    load_all
    if [ "$ENABLE_TUIC" = "1" ]; then
      ensure_tuic_cert
    fi
    save_state
    write_config
    check_config
    systemctl restart sing-box
    generate_outputs
    ;;
  *)
    main_menu
    ;;
esac
PANEL

chmod +x "$PANEL_FILE"

echo
echo "正在生成初始配置..."
"$PANEL_FILE" rebuild

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
echo "Clash YAML"
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
