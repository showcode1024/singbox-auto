#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ysq sing-box 一键安装 / 管理脚本
# 支持：
#   - VLESS Reality 直出 / 中转
#   - TUIC v5 直出 / 中转
#   - TCP / UDP 端口支持复用（同端口可分别运行 VLESS 和 TUIC）
#   - 独立落地节点池（查看 / 添加 / 修改 IP 端口 / 删除，显示为“国家：ip”）
#   - 命令行快速安装参数（vless=xxx tuic=xxx safe=0）
#   - 面板随时添加 / 删除 / 修改节点端口及落地出口
#   - 屏蔽指定网站管理
#   - 支持 IPv4 / IPv6 入口地址选择
#   - 支持 Debian / Ubuntu / CentOS / Rocky / AlmaLinux / Alpine
# ============================================================

# -------------------------
# 默认端口
# -------------------------
VLESS_DIRECT_PORT=20001
TUIC_DIRECT_PORT=20002
VLESS_RELAY_PORT=20003
TUIC_RELAY_PORT=20004

# -------------------------
# 默认参数（safe=0 时使用）
# -------------------------
DEFAULT_UUID="a1126537-6b28-4fd3-856c-2514a7626a8b"
DEFAULT_PRIVATE_KEY="GOThQzAstrApbL92Kb-BU_7GXKOrRfNDQMK74qrEB0g"
DEFAULT_PUBLIC_KEY="pyrWuKuPUx-bt6NOFvugQEszO8XR2qYeKZhVw_dysCM"
DEFAULT_SHORT_ID="884158a048b01725"
DEFAULT_TUIC_PASS="884158a048b01725"

REALITY_SNI="www.nvidia.com"
TUIC_SNI="www.nvidia.com"

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="/etc/sing-box/config.json"
STATE_FILE="/etc/sing-box/ysq-state.db"
CERT_DIR="/etc/sing-box/cert"
CERT_FILE="/etc/sing-box/cert/tuic.crt"
KEY_FILE="/etc/sing-box/cert/tuic.key"
INFO_FILE="/root/singbox-node-info.txt"
YAML_FILE="/root/singbox-nodes.yaml"
PANEL_FILE="/usr/local/bin/ysq"
INSTALLER_FILE="/root/install-singbox-ysq.sh"

# -------------------------
# CLI 参数解析
# -------------------------
CLI_VLESS=""
CLI_TUIC=""
CLI_SAFE=""
ACTION="install"

for arg in "$@"; do
  case "$arg" in
    vless=*) CLI_VLESS="${arg#*=}" ;;
    tuic=*)  CLI_TUIC="${arg#*=}" ;;
    safe=*)  CLI_SAFE="${arg#*=}" ;;
    panel)   ACTION="panel" ;;
    render)  ACTION="render" ;;
    install) ACTION="install" ;;
  esac
done

# -------------------------
# 系统 / 包管理器 / 服务管理器
# -------------------------
OS_ID=""
OS_LIKE=""
OS_NAME=""
PKG_MANAGER=""
SERVICE_MANAGER=""
SING_BOX_BIN=""

load_os_release() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
    OS_NAME="${PRETTY_NAME:-${NAME:-Linux}}"
  else
    OS_ID="unknown"
    OS_LIKE=""
    OS_NAME="Linux"
  fi
}

detect_pkg_manager() {
  if command -v apt >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  else
    die "未识别到支持的包管理器。当前支持：apt / dnf / yum / apk。"
  fi
}

detect_service_manager() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    SERVICE_MANAGER="systemd"
  elif command -v rc-service >/dev/null 2>&1 && rc-status >/dev/null 2>&1; then
    SERVICE_MANAGER="openrc"
  else
    SERVICE_MANAGER="none"
  fi
}

detect_runtime() {
  load_os_release
  detect_pkg_manager
  detect_service_manager
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt update
      ;;
    dnf) dnf makecache -y || true ;;
    yum) yum makecache -y || true ;;
    apk) apk update ;;
  esac
}

pkg_install() {
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt install -y "$@"
      ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
  esac
}

pkg_remove_singbox() {
  case "$PKG_MANAGER" in
    apt)
      apt purge -y sing-box 2>/dev/null || true
      apt remove -y sing-box 2>/dev/null || true
      ;;
    dnf) dnf remove -y sing-box 2>/dev/null || true ;;
    yum) yum remove -y sing-box 2>/dev/null || true ;;
    apk) apk del sing-box 2>/dev/null || true ;;
  esac
}

nologin_shell() {
  if [ -x /usr/sbin/nologin ]; then
    echo "/usr/sbin/nologin"
  elif [ -x /sbin/nologin ]; then
    echo "/sbin/nologin"
  else
    echo "/bin/false"
  fi
}

ensure_singbox_user() {
  local shell_path
  id sing-box >/dev/null 2>&1 && return 0

  shell_path="$(nologin_shell)"

  if command -v useradd >/dev/null 2>&1; then
    useradd --system --no-create-home --shell "$shell_path" sing-box 2>/dev/null \
      || useradd -r -M -s "$shell_path" sing-box 2>/dev/null \
      || true
  elif command -v adduser >/dev/null 2>&1; then
    addgroup -S sing-box 2>/dev/null || true
    adduser -S -D -H -s "$shell_path" -G sing-box sing-box 2>/dev/null || true
  fi

  id sing-box >/dev/null 2>&1 || die "无法创建 sing-box 系统用户。"
}

normalize_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) die "暂不支持当前 CPU 架构：$(uname -m)" ;;
  esac
}

normalize_apk_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) die "暂不支持当前 CPU 架构：$(uname -m)" ;;
  esac
}

ensure_alpine_glibc_compat() {
  [ "${PKG_MANAGER:-}" = "apk" ] || return 0

  apk add --no-cache gcompat libc6-compat libstdc++ libgcc file 2>/dev/null || true

  case "$(uname -m)" in
    x86_64|amd64)
      mkdir -p /lib64
      if [ -e /lib/ld-linux-x86-64.so.2 ]; then
        ln -sf /lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
      elif [ -e /usr/glibc-compat/lib/ld-linux-x86-64.so.2 ]; then
        ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
      fi
      ;;
  esac
}

singbox_bin_works() {
  local bin
  bin="${1:-$(command -v sing-box 2>/dev/null || true)}"
  [ -n "$bin" ] || return 1
  [ -x "$bin" ] || return 1
  "$bin" version >/dev/null 2>&1
}

remove_broken_singbox_bins() {
  local bin
  bin="$(command -v sing-box 2>/dev/null || true)"
  if [ -n "$bin" ] && ! singbox_bin_works "$bin"; then
    warn "检测到 sing-box 可执行文件存在但无法运行：$bin"
    file "$bin" 2>/dev/null || true
    rm -f "$bin"
  fi

  for bin in /usr/local/bin/sing-box /usr/bin/sing-box; do
    if [ -e "$bin" ] && ! singbox_bin_works "$bin"; then
      warn "删除无法运行的 sing-box：$bin"
      file "$bin" 2>/dev/null || true
      rm -f "$bin"
    fi
  done

  hash -r 2>/dev/null || true
}

get_latest_version() {
  local version
  version="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/^v//' 2>/dev/null || true)"
  if [ -z "$version" ] || [ "$version" = "null" ]; then
    version="$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/SagerNet/sing-box/releases/latest | grep -oE '[^/]+$' | sed 's/^v//' || true)"
  fi
  echo "$version"
}

install_singbox_alpine_apk() {
  local arch version url tmp_dir apk_file extracted_bin tgz_arch tgz_file found_bin

  arch="$(normalize_apk_arch)"
  tmp_dir="$(mktemp -d)"

  info "Alpine 系统安装 sing-box..."
  version="$(get_latest_version)"
  if [ -z "$version" ] || [ "$version" = "null" ]; then
    warn "无法获取最新版本号，默认安装 1.13.12 版本。"
    version="1.13.12"
  fi

  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box_${version}_linux_${arch}.apk"
  apk_file="${tmp_dir}/sing-box.apk"
  info "正在下载 Alpine .apk 包：sing-box ${version} / ${arch}"
  curl -fL --connect-timeout 10 --retry 3 -o "$apk_file" "$url"

  if apk add --allow-untrusted "$apk_file"; then
    hash -r 2>/dev/null || true
    if command -v sing-box >/dev/null 2>&1 && singbox_bin_works "$(command -v sing-box)"; then
      rm -rf "$tmp_dir"
      return 0
    fi
  fi

  ensure_alpine_glibc_compat
  tgz_arch="$(normalize_arch)"
  tgz_file="${tmp_dir}/sing-box.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${tgz_arch}.tar.gz"
  curl -fL --connect-timeout 10 --retry 3 -o "$tgz_file" "$url"
  tar -xzf "$tgz_file" -C "$tmp_dir"

  found_bin="$(find "$tmp_dir" -type f -name sing-box | head -n 1)"
  if [ -z "$found_bin" ]; then
    rm -rf "$tmp_dir"
    die "tar.gz 包里未找到 sing-box 可执行文件。"
  fi

  install -m 755 "$found_bin" /usr/bin/sing-box
  ln -sf /usr/bin/sing-box /usr/local/bin/sing-box
  hash -r 2>/dev/null || true
  rm -rf "$tmp_dir"
}

install_singbox_manual() {
  local arch version url tmp_dir tar_file found_bin

  arch="$(normalize_arch)"
  tmp_dir="$(mktemp -d)"

  info "正在使用 GitHub Release 备用方式安装 sing-box..."
  version="$(get_latest_version)"
  if [ -z "$version" ] || [ "$version" = "null" ]; then
    version="1.13.12"
  fi

  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
  tar_file="${tmp_dir}/sing-box.tar.gz"

  curl -fL --connect-timeout 10 --retry 3 -o "$tar_file" "$url"
  tar -xzf "$tar_file" -C "$tmp_dir"

  found_bin="$(find "$tmp_dir" -type f -name sing-box -perm -111 | head -n 1)"
  if [ -z "$found_bin" ]; then
    die "下载包里未找到 sing-box 可执行文件。"
  fi

  install -m 755 "$found_bin" /usr/local/bin/sing-box
  rm -rf "$tmp_dir"
  hash -r 2>/dev/null || true
}

ensure_singbox_service() {
  ensure_singbox_user
  SING_BOX_BIN="$(command -v sing-box 2>/dev/null || true)"
  if [ -z "$SING_BOX_BIN" ]; then
    die "未找到 sing-box 可执行文件。"
  fi

  mkdir -p /var/lib/sing-box /var/log/sing-box
  chown -R sing-box:sing-box /var/lib/sing-box /var/log/sing-box 2>/dev/null || true

  case "$SERVICE_MANAGER" in
    systemd)
      cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=sing-box
Group=sing-box
Type=simple
ExecStart=${SING_BOX_BIN} -D /var/lib/sing-box -C /etc/sing-box run
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload 2>/dev/null || true
      ;;
    openrc)
      cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="${SING_BOX_BIN}"
command_args="-D /var/lib/sing-box -C /etc/sing-box run"
command_user="sing-box:sing-box"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box/sing-box.log"
error_log="/var/log/sing-box/sing-box.err"

start_pre() {
  checkpath -d -m 0755 -o sing-box:sing-box /var/lib/sing-box
  checkpath -d -m 0755 -o sing-box:sing-box /var/log/sing-box
}

depend() {
  need net
  after firewall
}
EOF
      chmod +x /etc/init.d/sing-box
      ;;
    none)
      warn "未检测到 systemd/openrc，将使用 nohup 后台方式管理 sing-box。"
      ;;
  esac
}

service_enable() {
  case "$SERVICE_MANAGER" in
    systemd) systemctl enable sing-box >/dev/null 2>&1 || true ;;
    openrc) rc-update add sing-box default >/dev/null 2>&1 || true ;;
    none) return 0 ;;
  esac
}

service_disable() {
  case "$SERVICE_MANAGER" in
    systemd) systemctl disable sing-box >/dev/null 2>&1 || true ;;
    openrc) rc-update del sing-box default >/dev/null 2>&1 || true ;;
    none) return 0 ;;
  esac
}

service_stop() {
  case "$SERVICE_MANAGER" in
    systemd) systemctl stop sing-box 2>/dev/null || true ;;
    openrc) rc-service sing-box stop 2>/dev/null || true ;;
    none)
      if [ -f /run/sing-box.pid ]; then
        kill "$(cat /run/sing-box.pid)" 2>/dev/null || true
        rm -f /run/sing-box.pid
      fi
      pkill -f "sing-box.*-C /etc/sing-box run" 2>/dev/null || true
      ;;
  esac
}

service_restart() {
  case "$SERVICE_MANAGER" in
    systemd)
      systemctl restart sing-box
      ;;
    openrc)
      rc-service sing-box restart
      ;;
    none)
      service_stop
      SING_BOX_BIN="$(command -v sing-box 2>/dev/null || true)"
      if [ -z "$SING_BOX_BIN" ]; then
        die "未找到 sing-box 可执行文件。"
      fi
      install -d -m 755 -o sing-box -g sing-box /var/lib/sing-box /var/log/sing-box 2>/dev/null || mkdir -p /var/lib/sing-box /var/log/sing-box
      nohup "$SING_BOX_BIN" -D /var/lib/sing-box -C /etc/sing-box run > /var/log/sing-box/sing-box.log 2>&1 &
      echo $! > /run/sing-box.pid
      sleep 1
      if ! kill -0 "$(cat /run/sing-box.pid)" 2>/dev/null; then
        cat /var/log/sing-box/sing-box.log >&2 || true
        die "sing-box 后台启动失败。"
      fi
      ;;
  esac
}

service_status() {
  case "$SERVICE_MANAGER" in
    systemd)
      systemctl status sing-box --no-pager || true
      ;;
    openrc)
      rc-service sing-box status || true
      echo
      tail -n 80 /var/log/sing-box/sing-box.log 2>/dev/null || true
      tail -n 80 /var/log/sing-box/sing-box.err 2>/dev/null || true
      ;;
    none)
      if [ -f /run/sing-box.pid ] && kill -0 "$(cat /run/sing-box.pid)" 2>/dev/null; then
        ok "sing-box 正在运行，PID: $(cat /run/sing-box.pid)"
      else
        warn "sing-box 未运行。"
      fi
      echo
      tail -n 80 /var/log/sing-box/sing-box.log 2>/dev/null || true
      ;;
  esac
}

service_daemon_reload() {
  case "$SERVICE_MANAGER" in
    systemd) systemctl daemon-reload 2>/dev/null || true ;;
    openrc|none) return 0 ;;
  esac
}

# -------------------------
# 颜色输出
# -------------------------
if [ -t 1 ]; then
  C_RESET="\033[0m"
  C_RED="\033[31m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_BLUE="\033[34m"
  C_BOLD="\033[1m"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_BOLD=""
fi

ok() { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err() { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }
info() { echo -e "${C_BLUE}ℹ️  $*${C_RESET}"; }
step() {
  echo
  echo -e "${C_BOLD}==============================${C_RESET}"
  echo -e "${C_BOLD}$*${C_RESET}"
  echo -e "${C_BOLD}==============================${C_RESET}"
}
die() { err "$*"; exit 1; }
pause() { echo; read -rp "按回车返回..."; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 运行：sudo bash $0"
  fi
}

need_state() {
  if [ ! -f "$STATE_FILE" ]; then
    die "未找到状态文件：$STATE_FILE，请先运行安装。"
  fi
}

ask_port() {
  local name="$1"
  local default_port="$2"
  local allow_zero="${3:-false}"
  local input_port=""

  while true; do
    read -rp "$name [默认 ${default_port}]: " input_port
    if [ -z "$input_port" ]; then
      echo "$default_port"
      return
    fi

    if [ "$allow_zero" = "true" ] && [ "$input_port" = "0" ]; then
      echo "0"
      return
    fi

    if [[ "$input_port" =~ ^[0-9]+$ ]]; then
      if [ "$input_port" -lt 10000 ] || [ "$input_port" -gt 65535 ]; then
        warn "端口不能小于 10000 且需在 10000-65535 之间，请重新输入。" >&2
        continue
      fi
      echo "$input_port"
      return
    fi
    warn "端口输入错误，请输入 10000-65535 之间的数字。" >&2
  done
}

ask_text_default() {
  local prompt="$1"
  local default_value="$2"
  local input=""

  if [ -n "$default_value" ]; then
    read -rp "$prompt [默认 ${default_value}]: " input
    echo "${input:-$default_value}"
  else
    while true; do
      read -rp "$prompt: " input
      if [ -n "$input" ]; then
        echo "$input"
        return
      fi
      warn "这里不能为空。"
    done
  fi
}

# 区分 TCP 与 UDP 检查脚本内端口占用
port_used() {
  local port="$1"
  local proto="${2:-tcp}"
  local ignore_tag="${3:-}"

  jq -e \
    --argjson p "$port" \
    --arg proto "$proto" \
    --arg ignore_tag "$ignore_tag" \
    '.nodes[]? | select((.port | tonumber) == ($p | tonumber) and (.protocol // (if .type | startswith("tuic") then "udp" else "tcp" end)) == $proto and .tag != $ignore_tag)' \
    "$STATE_FILE" >/dev/null 2>&1
}

# 区分 TCP/UDP 检查系统端口
check_port_available() {
  local port="$1"
  local proto="${2:-tcp}"
  local ignore_tag="${3:-}"

  if port_used "$port" "$proto" "$ignore_tag"; then
    die "端口 ${port} (${proto^^}) 已经被当前脚本里的其他节点使用，请换一个端口。"
  fi

  local ss_arg="-tlpn"
  [ "$proto" = "udp" ] && ss_arg="-ulpn"

  if ss "$ss_arg" 2>/dev/null | awk '{print $4, $5}' | grep -Eq "[:.]${port}\\b"; then
    warn "检测到系统里已有程序在 ${proto^^} 监听 ${port}。如果不是当前 sing-box 节点，请换端口。"
    read -rp "仍然继续使用这个端口？输入 y 继续: " confirm
    if [ "$confirm" != "y" ]; then
      die "已取消。"
    fi
  fi
}

country_to_name() {
  local code
  code="$(echo "${1:-}" | tr '[:lower:]' '[:upper:]')"

  case "$code" in
    SG) echo "🇸🇬|新加坡" ;;
    HK) echo "🇭🇰|香港" ;;
    TW) echo "🇹🇼|台湾" ;;
    JP) echo "🇯🇵|日本" ;;
    KR) echo "🇰🇷|韩国" ;;
    MY) echo "🇲🇾|马来西亚" ;;
    TH) echo "🇹🇭|泰国" ;;
    VN) echo "🇻🇳|越南" ;;
    PH) echo "🇵🇭|菲律宾" ;;
    ID) echo "🇮🇩|印尼" ;;
    US) echo "🇺🇸|美国" ;;
    CA) echo "🇨🇦|加拿大" ;;
    GB|UK) echo "🇬🇧|英国" ;;
    DE) echo "🇩🇪|德国" ;;
    FR) echo "🇫🇷|法国" ;;
    NL) echo "🇳🇱|荷兰" ;;
    FI) echo "🇫🇮|芬兰" ;;
    SE) echo "🇸🇪|瑞典" ;;
    PL) echo "🇵🇱|波兰" ;;
    TR) echo "🇹🇷|土耳其" ;;
    AU) echo "🇦🇺|澳大利亚" ;;
    IN) echo "🇮🇳|印度" ;;
    RU) echo "🇷🇺|俄罗斯" ;;
    CN) echo "🇨🇳|中国" ;;
    *) echo "🌐|未知地区" ;;
  esac
}

detect_public_ip() {
  local ver="${1:-4}"
  local ip=""

  if [ "$ver" = "6" ]; then
    ip="$(curl -6 -s --max-time 6 https://api6.ipify.org 2>/dev/null || true)"
    if [ -z "$ip" ]; then
      ip="$(curl -6 -s --max-time 6 https://ifconfig.co 2>/dev/null || true)"
    fi
  else
    ip="$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "$ip" ]; then
      ip="$(curl -4 -s --max-time 6 https://ifconfig.me 2>/dev/null || true)"
    fi
  fi

  if [ -z "$ip" ]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  echo "$ip"
}

detect_location() {
  local ip="$1"
  local code=""
  local pair=""

  code="$(curl -4 -s --max-time 8 "https://ipapi.co/${ip}/country/" 2>/dev/null | tr -d '\r\n ' || true)"
  if ! [[ "$code" =~ ^[A-Za-z]{2}$ ]]; then
    code="$(curl -4 -s --max-time 8 "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d '\r\n ' || true)"
  fi
  if ! [[ "$code" =~ ^[A-Za-z]{2}$ ]]; then
    code="XX"
  fi

  pair="$(country_to_name "$code")"
  echo "${code}|${pair}"
}

node_suffix() {
  local type="$1"
  local outbound_type="${2:-direct}"

  if [ "$outbound_type" = "landing" ]; then
    case "$type" in
      vless*) echo "vless转vless" ;;
      tuic*)  echo "tuic5转vless" ;;
      *) echo "relay" ;;
    esac
  else
    case "$type" in
      vless*) echo "vless" ;;
      tuic*)  echo "tuic5" ;;
      *) echo "node" ;;
    esac
  fi
}

node_type_name() {
  local type="$1"
  local outbound_type="${2:-direct}"
  case "$type" in
    vless*)
      [ "$outbound_type" = "landing" ] && echo "VLESS -> VLESS 中转" || echo "VLESS 直出"
      ;;
    tuic*)
      [ "$outbound_type" = "landing" ] && echo "TUIC v5 -> VLESS 中转" || echo "TUIC v5 直出"
      ;;
    *) echo "$1" ;;
  esac
}

make_node_name() {
  local type="$1"
  local port="$2"
  local outbound_type="${3:-direct}"
  local flag loc base
  flag="$(jq -r '.location_flag // "🌐"' "$STATE_FILE")"
  loc="$(jq -r '.location_name // "未知地区"' "$STATE_FILE")"
  base="${flag}${loc}-$(node_suffix "$type" "$outbound_type")"

  if jq -e --arg name "$base" '.nodes[]? | select(.name == $name)' "$STATE_FILE" >/dev/null 2>&1; then
    echo "${base}-${port}"
  else
    echo "$base"
  fi
}

url_encode() {
  local raw="$1"
  jq -nr --arg v "$raw" '$v | @uri' 2>/dev/null || printf '%s' "$raw"
}

yaml_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

install_deps() {
  step "准备系统环境"

  detect_runtime
  info "系统：${OS_NAME} (${PKG_MANAGER})"

  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install curl openssl jq ca-certificates iproute2 tar gzip
      ;;
    dnf|yum)
      pkg_update
      if ! pkg_install curl openssl jq ca-certificates iproute tar gzip shadow-utils; then
        warn "依赖安装失败，尝试先安装 epel-release 后重试。"
        pkg_install epel-release || true
        pkg_install curl openssl jq ca-certificates iproute tar gzip shadow-utils
      fi
      ;;
    apk)
      pkg_update
      pkg_install bash curl openssl jq ca-certificates iproute2 tar gzip file gcompat libc6-compat libstdc++ libgcc
      update-ca-certificates 2>/dev/null || true
      ensure_alpine_glibc_compat
      ;;
  esac

  ok "必要依赖安装完成。"
}

install_singbox() {
  step "安装 / 检查 sing-box"

  detect_runtime
  ensure_singbox_user
  remove_broken_singbox_bins

  if command -v sing-box >/dev/null 2>&1 && singbox_bin_works "$(command -v sing-box)"; then
    ok "检测到 sing-box 已安装：$(sing-box version | head -n 1)"
  else
    info "正在安装 sing-box..."

    if [ "$PKG_MANAGER" = "apk" ]; then
      install_singbox_alpine_apk
    elif curl -fsSL https://sing-box.app/install.sh | sh; then
      hash -r 2>/dev/null || true
    else
      warn "官方 install.sh 安装失败，尝试 GitHub Release 备用安装。"
      install_singbox_manual
    fi

    if ! command -v sing-box >/dev/null 2>&1; then
      die "sing-box 安装失败，未找到可执行文件。"
    fi

    if ! singbox_bin_works "$(command -v sing-box)"; then
      die "当前系统无法执行 sing-box，请检查 CPU 架构或 libc 兼容性。"
    fi

    ok "sing-box 安装完成：$(sing-box version | head -n 1)"
  fi

  ensure_singbox_service
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$CERT_DIR" /var/lib/sing-box /var/log/sing-box
  chown -R sing-box:sing-box "$CONFIG_DIR" /var/lib/sing-box /var/log/sing-box 2>/dev/null || true
  chmod 755 "$CONFIG_DIR" "$CERT_DIR" /var/lib/sing-box /var/log/sing-box
}

state_get() {
  jq -r "$1" "$STATE_FILE"
}

ensure_state_defaults() {
  need_state

  local tmp
  tmp="$(mktemp)"
  jq '
    del(.sub_port, .sub_token) |
    (if has("blocked_domains") then . else .blocked_domains = [] end) |
    (if has("ip_version") then . else .ip_version = "ipv4" end) |
    (if has("landings") then . else .landings = [] end) |
    (if has("nodes") then . else .nodes = [] end) |
    .landings |= map(
      if has("id") then . else .id = ("landing_" + (.server | tostring | gsub("[^a-zA-Z0-9]"; "_"))) end
    ) |
    .nodes |= map(
      (if has("protocol") then . else .protocol = (if .type | startswith("tuic") then "udp" else "tcp" end) end) |
      (if has("outbound_type") then . else .outbound_type = (if .type | endswith("-relay") then "landing" else "direct" end) end) |
      (if has("landing_display") then . else .landing_display = (.landing_server // "") end)
    )
  ' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"
}

need_tuic_cert() {
  jq -e '.nodes[]? | select(.type | startswith("tuic"))' "$STATE_FILE" >/dev/null 2>&1
}

ensure_tuic_cert() {
  local tuic_sni san tmp_dir

  need_tuic_cert || return 0

  tuic_sni="$(state_get '.tuic_sni')"

  step "检查 TUIC 证书"

  install -d -m 755 -o sing-box -g sing-box "$CERT_DIR"

  if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    ok "TUIC 证书已存在，跳过生成。"
    return 0
  fi

  info "正在生成 TUIC 自签证书..."

  if [[ "$tuic_sni" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$tuic_sni" == *:* ]]; then
    san="IP:${tuic_sni}"
  else
    san="DNS:${tuic_sni}"
  fi

  tmp_dir="$(mktemp -d)"
  umask 077

  cat > "$tmp_dir/openssl.cnf" <<EOF
[req]
default_bits = 256
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${tuic_sni}

[v3_req]
subjectAltName = ${san}
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

  if ! openssl req -x509 -newkey ec \
    -pkeyopt ec_paramgen_curve:prime256v1 \
    -nodes \
    -sha256 \
    -keyout "$tmp_dir/tuic.key" \
    -out "$tmp_dir/tuic.crt" \
    -days 3650 \
    -config "$tmp_dir/openssl.cnf" >/dev/null 2>&1; then
      rm -rf "$tmp_dir"
      die "TUIC 自签证书生成失败。"
  fi

  install -m 600 -o sing-box -g sing-box "$tmp_dir/tuic.key" "$KEY_FILE"
  install -m 644 -o sing-box -g sing-box "$tmp_dir/tuic.crt" "$CERT_FILE"
  rm -rf "$tmp_dir"

  ok "TUIC 证书生成完成：$CERT_FILE"
}

create_state_file() {
  local uuid private_key public_key short_id tuic_pass server_ip location_raw country_code flag loc ip_version

  mkdir -p "$CONFIG_DIR"

  step "基础参数设置"

  if [ "$CLI_SAFE" = "0" ]; then
    info "已指定 safe=0：直接使用默认安全参数（UUID / 密钥 / SNI）。"
    uuid="$DEFAULT_UUID"
    private_key="$DEFAULT_PRIVATE_KEY"
    public_key="$DEFAULT_PUBLIC_KEY"
    short_id="$DEFAULT_SHORT_ID"
    tuic_pass="$DEFAULT_TUIC_PASS"
  else
    echo "请选择是否生成新的 UUID / REALITY 密钥 / ShortID："
    echo "1) 生成新的"
    echo "2) 不生成，使用脚本内默认参数"
    read -rp "请输入 1 或 2 [默认 1]: " key_choice
    key_choice="${key_choice:-1}"

    case "$key_choice" in
      1)
        info "正在生成新参数..."
        uuid="$(sing-box generate uuid)"
        keypair="$(sing-box generate reality-keypair)"
        private_key="$(echo "$keypair" | awk -F': ' '/PrivateKey/ {print $2}')"
        public_key="$(echo "$keypair" | awk -F': ' '/PublicKey/ {print $2}')"
        short_id="$(openssl rand -hex 8)"
        tuic_pass="$short_id"
        ;;
      2)
        warn "将使用脚本内默认参数。"
        uuid="$DEFAULT_UUID"
        private_key="$DEFAULT_PRIVATE_KEY"
        public_key="$DEFAULT_PUBLIC_KEY"
        short_id="$DEFAULT_SHORT_ID"
        tuic_pass="$DEFAULT_TUIC_PASS"
        ;;
      *)
        die "输入错误，只能输入 1 或 2。"
        ;;
    esac
  fi

  if [ "$CLI_SAFE" = "0" ]; then
    ip_version="ipv4"
    server_ip="$(detect_public_ip 4)"
  else
    step "选择 IP 版本"
    echo "请选择用于节点分享的公网 IP 版本："
    echo "1) IPv4 (默认)"
    echo "2) IPv6"
    read -rp "请输入 1 或 2: " ipv_choice

    case "$ipv_choice" in
      1|"")
        ip_version="ipv4"
        server_ip="$(detect_public_ip 4)"
        ;;
      2)
        ip_version="ipv6"
        server_ip="$(detect_public_ip 6)"
        ;;
      *)
        die "输入错误，只能输入 1 或 2。"
        ;;
    esac
  fi

  if [ -z "$server_ip" ]; then
    die "未能获取到公网 ${ip_version} 地址。"
  fi

  step "检测公网 IP 和所在地"
  location_raw="$(detect_location "$server_ip")"
  country_code="$(echo "$location_raw" | cut -d'|' -f1)"
  flag="$(echo "$location_raw" | cut -d'|' -f2)"
  loc="$(echo "$location_raw" | cut -d'|' -f3)"

  ok "公网 IP (${ip_version})：${server_ip}"
  ok "自动命名地区：${flag}${loc}"

  cat > "$STATE_FILE" <<JSON
{
  "uuid": "${uuid}",
  "private_key": "${private_key}",
  "public_key": "${public_key}",
  "short_id": "${short_id}",
  "tuic_pass": "${tuic_pass}",
  "reality_sni": "${REALITY_SNI}",
  "tuic_sni": "${TUIC_SNI}",
  "server_ip": "${server_ip}",
  "ip_version": "${ip_version}",
  "country_code": "${country_code}",
  "location_flag": "${flag}",
  "location_name": "${loc}",
  "blocked_domains": [],
  "landings": [],
  "nodes": []
}
JSON

  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"
}

# -------------------------
# 落地节点池管理
# -------------------------
add_landing_wizard() {
  need_state
  step "添加落地节点"

  local l_server l_port l_uuid l_public_key l_short_id l_sni loc_raw flag loc l_display tmp

  l_server="$(ask_text_default "请输入落地节点 IP 或域名" "")"
  l_port="$(ask_port "请输入落地节点 VLESS 端口" "$VLESS_DIRECT_PORT")"
  l_uuid="$(ask_text_default "请输入落地 VLESS UUID" "$(state_get '.uuid')")"
  l_public_key="$(ask_text_default "请输入落地 Reality PublicKey" "$(state_get '.public_key')")"
  l_short_id="$(ask_text_default "请输入落地 Reality ShortID" "$(state_get '.short_id')")"
  l_sni="$(ask_text_default "请输入落地 Reality SNI" "$(state_get '.reality_sni')")"

  info "正在检测落地节点地区..."
  loc_raw="$(detect_location "$l_server")"
  flag="$(echo "$loc_raw" | cut -d'|' -f2)"
  loc="$(echo "$loc_raw" | cut -d'|' -f3)"
  l_display="${flag}${loc}：${l_server}"

  local l_id="landing_$(date +%s%N)"
  tmp="$(mktemp)"
  jq \
    --arg id "$l_id" \
    --arg server "$l_server" \
    --argjson port "$l_port" \
    --arg uuid "$l_uuid" \
    --arg pbk "$l_public_key" \
    --arg sid "$l_short_id" \
    --arg sni "$l_sni" \
    --arg display "$l_display" \
    '.landings += [{
      "id": $id,
      "server": $server,
      "port": $port,
      "uuid": $uuid,
      "public_key": $pbk,
      "short_id": $sid,
      "sni": $sni,
      "display": $display
    }]' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"

  ok "落地节点添加成功：${l_display} (端口: ${l_port})"
}

list_landings_table() {
  local count
  count="$(jq '.landings | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "当前无任何落地节点。"
    return 1
  fi

  printf "%-4s %-32s %-8s %s\n" "序号" "落地节点 (国家：ip)" "端口" "SNI"
  printf "%-4s %-32s %-8s %s\n" "----" "--------------------------------" "------" "----------------"
  jq -c '.landings[]' "$STATE_FILE" | nl -w1 -s' ' | while read -r idx item; do
    local disp port sni
    disp="$(echo "$item" | jq -r '.display')"
    port="$(echo "$item" | jq -r '.port')"
    sni="$(echo "$item" | jq -r '.sni')"
    printf "%-4s %-32s %-8s %s\n" "$idx" "$disp" "$port" "$sni"
  done
  return 0
}

# 修改已保存的落地节点参数（IP、端口、UUID、公钥、SNI）
modify_landing_wizard() {
  need_state
  step "修改落地节点信息"

  local count
  count="$(jq '.landings | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "当前暂无已保存的落地节点。"
    pause
    return 0
  fi

  list_landings_table
  echo
  read -rp "请输入要修改的落地节点序号 (输入 0 返回): " pick

  if [ "$pick" = "0" ] || [ -z "$pick" ]; then return 0; fi

  if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "$count" ]; then
    warn "序号无效。"
    sleep 1
    return 1
  fi

  local real_idx=$((pick-1))
  local l_id old_server old_port old_uuid old_pbk old_sid old_sni old_disp
  l_id="$(jq -r --argjson i "$real_idx" '.landings[$i].id' "$STATE_FILE")"
  old_server="$(jq -r --argjson i "$real_idx" '.landings[$i].server' "$STATE_FILE")"
  old_port="$(jq -r --argjson i "$real_idx" '.landings[$i].port' "$STATE_FILE")"
  old_uuid="$(jq -r --argjson i "$real_idx" '.landings[$i].uuid' "$STATE_FILE")"
  old_pbk="$(jq -r --argjson i "$real_idx" '.landings[$i].public_key' "$STATE_FILE")"
  old_sid="$(jq -r --argjson i "$real_idx" '.landings[$i].short_id' "$STATE_FILE")"
  old_sni="$(jq -r --argjson i "$real_idx" '.landings[$i].sni' "$STATE_FILE")"
  old_disp="$(jq -r --argjson i "$real_idx" '.landings[$i].display' "$STATE_FILE")"

  echo
  echo "--- 当前落地信息 ---"
  echo "显示标识: ${old_disp}"
  echo "IP/域名 : ${old_server}"
  echo "端口    : ${old_port}"
  echo "UUID    : ${old_uuid}"
  echo "PublicKey: ${old_pbk}"
  echo "ShortID : ${old_sid}"
  echo "SNI     : ${old_sni}"
  echo "--------------------"
  echo "请直接输入新值，按回车保持当前默认："

  local new_server new_port new_uuid new_pbk new_sid new_sni new_disp
  new_server="$(ask_text_default "落地 IP 或域名" "$old_server")"
  new_port="$(ask_port "落地 VLESS 端口" "$old_port")"
  new_uuid="$(ask_text_default "落地 UUID" "$old_uuid")"
  new_pbk="$(ask_text_default "落地 Reality PublicKey" "$old_pbk")"
  new_sid="$(ask_text_default "落地 Reality ShortID" "$old_sid")"
  new_sni="$(ask_text_default "落地 Reality SNI" "$old_sni")"

  if [ "$new_server" != "$old_server" ]; then
    info "检测到 IP/域名变动，正在重新解析地区..."
    local loc_raw flag loc
    loc_raw="$(detect_location "$new_server")"
    flag="$(echo "$loc_raw" | cut -d'|' -f2)"
    loc="$(echo "$loc_raw" | cut -d'|' -f3)"
    new_disp="${flag}${loc}：${new_server}"
  else
    new_disp="$old_disp"
  fi

  local tmp
  tmp="$(mktemp)"
  # 更新 landings 数组并联动更新所有绑定该 landing_id 的中转节点
  jq \
    --arg id "$l_id" \
    --arg server "$new_server" \
    --argjson port "$new_port" \
    --arg uuid "$new_uuid" \
    --arg pbk "$new_pbk" \
    --arg sid "$new_sid" \
    --arg sni "$new_sni" \
    --arg disp "$new_disp" \
    '
    .landings[$idx].server = $server |
    .landings[$idx].port = $port |
    .landings[$idx].uuid = $uuid |
    .landings[$idx].public_key = $pbk |
    .landings[$idx].short_id = $sid |
    .landings[$idx].sni = $sni |
    .landings[$idx].display = $disp |
    .nodes |= map(
      if .landing_id == $id or (.landing_server == "'"$old_server"'" and .landing_port == '"$old_port"') then
        .landing_id = $id |
        .landing_server = $server |
        .landing_port = $port |
        .landing_uuid = $uuid |
        .landing_public_key = $pbk |
        .landing_short_id = $sid |
        .landing_sni = $sni |
        .landing_display = $disp
      else . end
    )
    ' --argjson idx "$real_idx" "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"

  render_all
  restart_singbox
  ok "落地节点修改成功并已同步到所有关联节点！"
  pause
}

delete_landing_wizard() {
  need_state
  step "删除落地节点"

  local count
  count="$(jq '.landings | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "当前没有可删除的落地节点。"
    pause
    return 0
  fi

  list_landings_table
  echo
  read -rp "请输入要删除的落地节点序号 (输入 0 返回): " pick
  if [ "$pick" = "0" ] || [ -z "$pick" ]; then return 0; fi

  if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "$count" ]; then
    warn "序号无效。"
    sleep 1
    return 1
  fi

  local real_idx=$((pick-1))
  local disp
  disp="$(jq -r --argjson i "$real_idx" '.landings[$i].display' "$STATE_FILE")"

  read -rp "确认删除落地节点 [${disp}] 吗？输入 y 确认: " confirm
  if [ "$confirm" != "y" ]; then
    warn "已取消。"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  jq --argjson i "$real_idx" 'del(.landings[$i])' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"

  ok "已删除落地节点。"
  pause
}

landing_pool_menu() {
  while true; do
    step "落地节点池管理"
    list_landings_table || true
    echo
    echo "1) 添加落地节点"
    echo "2) 修改落地节点信息 (IP / 端口 / 密钥等)"
    echo "3) 删除落地节点"
    echo "0) 返回主菜单"
    read -rp "请输入选项: " lchoice

    case "$lchoice" in
      1) add_landing_wizard; pause ;;
      2) modify_landing_wizard ;;
      3) delete_landing_wizard ;;
      0) return 0 ;;
      *) warn "输入错误。"; sleep 1 ;;
    esac
  done
}

select_or_create_landing() {
  local count
  count="$(jq '.landings | length' "$STATE_FILE")"

  if [ "$count" -eq 0 ]; then
    info "当前暂无落地节点，请先添加一个："
    add_landing_wizard
  fi

  while true; do
    echo
    echo "请选择落地节点："
    list_landings_table
    echo "  +) 添加新的落地节点"
    read -rp "请输入序号或 + 号: " pick

    if [ "$pick" = "+" ]; then
      add_landing_wizard
      continue
    fi

    count="$(jq '.landings | length' "$STATE_FILE")"
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$count" ]; then
      local real_idx=$((pick-1))
      SEL_LANDING_ID="$(jq -r --argjson i "$real_idx" '.landings[$i].id // ""' "$STATE_FILE")"
      SEL_LANDING_SERVER="$(jq -r --argjson i "$real_idx" '.landings[$i].server' "$STATE_FILE")"
      SEL_LANDING_PORT="$(jq -r --argjson i "$real_idx" '.landings[$i].port' "$STATE_FILE")"
      SEL_LANDING_UUID="$(jq -r --argjson i "$real_idx" '.landings[$i].uuid' "$STATE_FILE")"
      SEL_LANDING_PUBLIC_KEY="$(jq -r --argjson i "$real_idx" '.landings[$i].public_key' "$STATE_FILE")"
      SEL_LANDING_SHORT_ID="$(jq -r --argjson i "$real_idx" '.landings[$i].short_id' "$STATE_FILE")"
      SEL_LANDING_SNI="$(jq -r --argjson i "$real_idx" '.landings[$i].sni' "$STATE_FILE")"
      SEL_LANDING_DISPLAY="$(jq -r --argjson i "$real_idx" '.landings[$i].display' "$STATE_FILE")"
      return 0
    fi
    warn "无效序号，请重新选择。"
  done
}

# -------------------------
# 节点增删操作
# -------------------------
add_node_to_state() {
  local type="$1"
  local port="$2"
  local outbound_type="${3:-direct}"
  local protocol=""
  local tag name tmp

  if [[ "$type" == tuic* ]]; then
    protocol="udp"
  else
    protocol="tcp"
  fi

  check_port_available "$port" "$protocol"

  tag="${type}-${port}"
  name="$(make_node_name "$type" "$port" "$outbound_type")"
  tmp="$(mktemp)"

  if [ "$outbound_type" = "landing" ]; then
    jq \
      --arg type "$type" \
      --arg protocol "$protocol" \
      --arg outbound_type "$outbound_type" \
      --arg tag "$tag" \
      --arg name "$name" \
      --argjson port "$port" \
      --arg landing_id "$SEL_LANDING_ID" \
      --arg landing_server "$SEL_LANDING_SERVER" \
      --argjson landing_port "$SEL_LANDING_PORT" \
      --arg landing_uuid "$SEL_LANDING_UUID" \
      --arg landing_public_key "$SEL_LANDING_PUBLIC_KEY" \
      --arg landing_short_id "$SEL_LANDING_SHORT_ID" \
      --arg landing_sni "$SEL_LANDING_SNI" \
      --arg landing_display "$SEL_LANDING_DISPLAY" \
      '.nodes += [{
        "type": $type,
        "protocol": $protocol,
        "outbound_type": $outbound_type,
        "tag": $tag,
        "name": $name,
        "port": $port,
        "landing_id": $landing_id,
        "landing_server": $landing_server,
        "landing_port": $landing_port,
        "landing_uuid": $landing_uuid,
        "landing_public_key": $landing_public_key,
        "landing_short_id": $landing_short_id,
        "landing_sni": $landing_sni,
        "landing_display": $landing_display
      }]' "$STATE_FILE" > "$tmp"
  else
    jq \
      --arg type "$type" \
      --arg protocol "$protocol" \
      --arg outbound_type "$outbound_type" \
      --arg tag "$tag" \
      --arg name "$name" \
      --argjson port "$port" \
      '.nodes += [{
        "type": $type,
        "protocol": $protocol,
        "outbound_type": $outbound_type,
        "tag": $tag,
        "name": $name,
        "port": $port,
        "landing_display": "-"
      }]' "$STATE_FILE" > "$tmp"
  fi

  mv "$tmp" "$STATE_FILE"
  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"

  ok "已添加节点：${name} / 协议: ${protocol^^} / 端口: ${port}"
}

add_node_wizard() {
  need_state
  step "添加节点"

  echo "1) 添加 VLESS 节点 (TCP)"
  echo "2) 添加 TUIC v5 节点 (UDP)"
  echo "3) 添加落地节点"
  echo "0) 返回"
  read -rp "请选择: " choice

  case "$choice" in
    1)
      local port outbound_choice
      port="$(ask_port "请输入 VLESS TCP 端口" "$VLESS_DIRECT_PORT")"
      echo
      echo "请选择出站方式："
      echo "1) 直出"
      echo "2) 落地中转 (选择已添加的落地节点)"
      read -rp "请输入 1 或 2 [默认 1]: " outbound_choice
      outbound_choice="${outbound_choice:-1}"

      if [ "$outbound_choice" = "2" ]; then
        select_or_create_landing
        add_node_to_state "vless-relay" "$port" "landing"
      else
        add_node_to_state "vless-direct" "$port" "direct"
      fi
      ;;
    2)
      local port outbound_choice
      port="$(ask_port "请输入 TUIC UDP 端口" "$TUIC_DIRECT_PORT")"
      echo
      echo "请选择出站方式："
      echo "1) 直出"
      echo "2) 落地中转 (选择已添加的落地节点)"
      read -rp "请输入 1 或 2 [默认 1]: " outbound_choice
      outbound_choice="${outbound_choice:-1}"

      if [ "$outbound_choice" = "2" ]; then
        select_or_create_landing
        add_node_to_state "tuic-relay" "$port" "landing"
      else
        add_node_to_state "tuic-direct" "$port" "direct"
      fi
      ;;
    3)
      add_landing_wizard
      pause
      return 0
      ;;
    0) return 0 ;;
    *) warn "输入错误。"; return 1 ;;
  esac

  render_all
  restart_singbox
  ok "节点已生效。"
}

delete_node_wizard() {
  need_state

  local count indices tmp name
  count="$(jq '.nodes | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "当前没有可删除的节点。"
    pause
    return 0
  fi

  step "删除节点 (支持批量)"
  list_nodes_table
  echo
  read -rp "请输入要删除的节点序号 (多个用空格隔开，如 1 2)，输入 0 返回: " indices

  if [ "$indices" = "0" ]; then return 0; fi

  indices="${indices//,/ }"
  declare -a valid_tags=()
  declare -a names_to_print=()

  for idx in $indices; do
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "$count" ]; then
      local real_idx=$((idx-1))
      local tag
      tag="$(jq -r --argjson i "$real_idx" '.nodes[$i].tag' "$STATE_FILE")"
      name="$(jq -r --argjson i "$real_idx" '.nodes[$i].name' "$STATE_FILE")"
      valid_tags+=("$tag")
      names_to_print+=("$name")
    else
      warn "忽略无效的序号: $idx"
    fi
  done

  if [ ${#valid_tags[@]} -eq 0 ]; then 
    warn "未选择有效节点。"
    sleep 1
    return 1
  fi

  echo "即将删除以下节点："
  for n in "${names_to_print[@]}"; do
    echo "  - $n"
  done

  read -rp "确认删除？输入 y 确认: " confirm
  if [ "$confirm" != "y" ]; then
    warn "已取消删除。"
    sleep 1
    return 0
  fi

  tmp="$(mktemp)"
  local tags_json
  tags_json="$(printf '%s\n' "${valid_tags[@]}" | jq -R . | jq -s .)"
  
  jq --argjson tags "$tags_json" '.nodes |= map(select(.tag as $t | $tags | index($t) | not))' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  
  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"

  render_all
  restart_singbox
  ok "删除完成。"
  sleep 1
}

modify_node_port_wizard() {
  need_state

  local count index old_port new_port old_tag type protocol name tmp
  count="$(jq '.nodes | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "当前没有可修改的节点。"
    pause
    return 0
  fi

  step "修改节点 (端口 / SNI / 出口落地)"
  list_nodes_table
  echo
  read -rp "请输入要修改的节点序号，输入 0 返回: " index

  if [ "$index" = "0" ]; then return 0; fi

  if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$count" ]; then
    warn "序号输入错误。"
    sleep 1
    return 1
  fi

  local real_idx=$((index-1))
  type="$(jq -r --argjson i "$real_idx" '.nodes[$i].type' "$STATE_FILE")"
  protocol="$(jq -r --argjson i "$real_idx" '.nodes[$i].protocol // (if .type | startswith("tuic") then "udp" else "tcp" end)' "$STATE_FILE")"
  name="$(jq -r --argjson i "$real_idx" '.nodes[$i].name' "$STATE_FILE")"
  old_port="$(jq -r --argjson i "$real_idx" '.nodes[$i].port' "$STATE_FILE")"
  old_tag="$(jq -r --argjson i "$real_idx" '.nodes[$i].tag' "$STATE_FILE")"
  local outbound_type="$(jq -r --argjson i "$real_idx" '.nodes[$i].outbound_type // "direct"' "$STATE_FILE")"
  local landing_display="$(jq -r --argjson i "$real_idx" '.nodes[$i].landing_display // "-"' "$STATE_FILE")"

  echo
  echo "--- 节点当前信息 ---"
  echo "名称: ${name}"
  echo "类型: $(node_type_name "$type" "$outbound_type")"
  echo "协议: ${protocol^^}"
  echo "端口: ${old_port}"
  echo "出口: $([ "$outbound_type" = "landing" ] && echo "落地中转 (${landing_display})" || echo "直出")"
  echo "--------------------"
  echo

  echo "请选择要修改的内容："
  echo "1) 修改端口"
  echo "2) 修改 SNI"
  echo "3) 修改出口方式 (切换直出 / 更换已有落地)"
  if [ "$outbound_type" = "landing" ]; then
    echo "4) 直接编辑当前绑定的落地参数 (IP / 端口 / 密钥等)"
  fi
  echo "0) 返回"
  read -rp "请输入选项: " mod_choice

  tmp="$(mktemp)"
  cp "$STATE_FILE" "$tmp"

  case "$mod_choice" in
    1)
      new_port="$(ask_port "请输入新端口 (${protocol^^})" "$old_port")"
      if [ "$new_port" != "$old_port" ]; then
        check_port_available "$new_port" "$protocol" "$old_tag"
        local new_tag="${type}-${new_port}"
        jq --argjson i "$real_idx" \
           --argjson port "$new_port" \
           --arg tag "$new_tag" \
           '.nodes[$i].port = $port | .nodes[$i].tag = $tag' \
           "$tmp" > "${tmp}.1" && mv "${tmp}.1" "$tmp"
        ok "端口已修改为: ${new_port}"
      else
        info "端口未改变。"
        rm -f "$tmp"
        return 0
      fi
      ;;
    2)
      local current_sni
      if [ "$outbound_type" = "landing" ]; then
        current_sni="$(jq -r --argjson i "$real_idx" '.nodes[$i].landing_sni' "$STATE_FILE")"
      elif [[ "$type" == tuic* ]]; then
        current_sni="$(state_get '.tuic_sni')"
      else
        current_sni="$(state_get '.reality_sni')"
      fi
      local new_sni
      new_sni="$(ask_text_default "请输入新 SNI" "$current_sni")"
      if [ "$outbound_type" = "landing" ]; then
        jq --argjson i "$real_idx" --arg sni "$new_sni" '.nodes[$i].landing_sni = $sni' "$tmp" > "${tmp}.1" && mv "${tmp}.1" "$tmp"
      elif [[ "$type" == tuic* ]]; then
        jq --arg sni "$new_sni" '.tuic_sni = $sni' "$tmp" > "${tmp}.1" && mv "${tmp}.1" "$tmp"
        rm -f "$CERT_FILE" "$KEY_FILE"
      else
        jq --arg sni "$new_sni" '.reality_sni = $sni' "$tmp" > "${tmp}.1" && mv "${tmp}.1" "$tmp"
      fi
      ok "SNI 已修改。"
      ;;
    3)
      echo "请选择新出站方式："
      echo "1) 改为直出 (Direct)"
      echo "2) 选择已有或新建落地节点"
      read -rp "请输入 1 或 2: " out_target

      local new_type new_name
      if [ "$out_target" = "1" ]; then
        if [[ "$type" == tuic* ]]; then new_type="tuic-direct"; else new_type="vless-direct"; fi
        new_name="$(make_node_name "$new_type" "$old_port" "direct")"
        jq --argjson i "$real_idx" \
           --arg type "$new_type" \
           --arg name "$new_name" \
           '.nodes[$i].type = $type | .nodes[$i].name = $name | .nodes[$i].outbound_type = "direct" | .nodes[$i].landing_display = "-"' \
           "$tmp" > "${tmp}.1" && mv "${tmp}.1" "$tmp"
        ok "出口已切换为直出。"
      elif [ "$out_target" = "2" ]; then
        select_or_create_landing
        if [[ "$type" == tuic* ]]; then new_type="tuic-relay"; else new_type="vless-relay"; fi
        new_name="$(make_node_name "$new_type" "$old_port" "landing")"
        jq --argjson i "$real_idx" \
           --arg type "$new_type" \
           --arg name "$new_name" \
           --arg lid "$SEL_LANDING_ID" \
           --arg s "$SEL_LANDING_SERVER" \
           --argjson p "$SEL_LANDING_PORT" \
           --arg u "$SEL_LANDING_UUID" \
           --arg pbk "$SEL_LANDING_PUBLIC_KEY" \
           --arg sid "$SEL_LANDING_SHORT_ID" \
           --arg sni "$SEL_LANDING_SNI" \
           --arg disp "$SEL_LANDING_DISPLAY" \
           '.nodes[$i].type = $type |
            .nodes[$i].name = $name |
            .nodes[$i].outbound_type = "landing" |
            .nodes[$i].landing_id = $lid |
            .nodes[$i].landing_server = $s |
            .nodes[$i].landing_port = $p |
            .nodes[$i].landing_uuid = $u |
            .nodes[$i].landing_public_key = $pbk |
            .nodes[$i].landing_short_id = $sid |
            .nodes[$i].landing_sni = $sni |
            .nodes[$i].landing_display = $disp' \
           "$tmp" > "${tmp}.1" && mv "${tmp}.1" "$tmp"
        ok "落地已更新为：${SEL_LANDING_DISPLAY}"
      fi
      ;;
    4)
      if [ "$outbound_type" != "landing" ]; then
        warn "当前节点为直出节点，无落地参数可修改。"
        rm -f "$tmp"
        return 0
      fi
      local cur_server cur_port cur_uuid cur_pbk cur_sid cur_sni
      cur_server="$(jq -r --argjson i "$real_idx" '.nodes[$i].landing_server' "$STATE_FILE")"
      cur_port="$(jq -r --argjson i "$real_idx" '.nodes[$i].landing_port' "$STATE_FILE")"
      cur_uuid="$(jq -r --argjson i "$real_idx" '.nodes[$i].landing_uuid' "$STATE_FILE")"
      cur_pbk="$(jq -r --argjson i "$real_idx" '.nodes[$i].landing_public_key' "$STATE_FILE")"
      cur_sid="$(jq -r --argjson i "$real_idx" '.nodes[$i].landing_short_id' "$STATE_FILE")"
      cur_sni="$(jq -r --argjson i "$real_idx" '.nodes[$i].landing_sni' "$STATE_FILE")"

      echo "正在直接编辑本节点的落地信息（按回车保留默认）："
      local n_server n_port n_uuid n_pbk n_sid n_sni n_disp
      n_server="$(ask_text_default "落地 IP 或域名" "$cur_server")"
      n_port="$(ask_port "落地 VLESS 端口" "$cur_port")"
      n_uuid="$(ask_text_default "落地 UUID" "$cur_uuid")"
      n_pbk="$(ask_text_default "落地 Reality PublicKey" "$cur_pbk")"
      n_sid="$(ask_text_default "落地 Reality ShortID" "$cur_sid")"
      n_sni="$(ask_text_default "落地 Reality SNI" "$cur_sni")"

      info "正在检测落地地区..."
      local loc_raw flag loc
      loc_raw="$(detect_location "$n_server")"
      flag="$(echo "$loc_raw" | cut -d'|' -f2)"
      loc="$(echo "$loc_raw" | cut -d'|' -f3)"
      n_disp="${flag}${loc}：${n_server}"

      jq --argjson i "$real_idx" \
         --arg s "$n_server" \
         --argjson p "$n_port" \
         --arg u "$n_uuid" \
         --arg pbk "$n_pbk" \
         --arg sid "$n_sid" \
         --arg sni "$n_sni" \
         --arg disp "$n_disp" \
         '.nodes[$i].landing_server = $s |
          .nodes[$i].landing_port = $p |
          .nodes[$i].landing_uuid = $u |
          .nodes[$i].landing_public_key = $pbk |
          .nodes[$i].landing_short_id = $sid |
          .nodes[$i].landing_sni = $sni |
          .nodes[$i].landing_display = $disp' \
         "$tmp" > "${tmp}.1" && mv "${tmp}.1" "$tmp"
      ok "当前节点的落地参数已更新为：${n_disp}"
      ;;
    0)
      rm -f "$tmp"
      return 0
      ;;
    *)
      warn "无效选项。"
      rm -f "$tmp"
      return 1
      ;;
  esac

  mv "$tmp" "$STATE_FILE"
  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"

  render_all
  restart_singbox
  ok "节点修改已生效。"
  sleep 1
}

block_website_wizard() {
  need_state

  while true; do
    step "屏蔽指定网站 (域名) 管理"
    local count
    count="$(jq '.blocked_domains | length' "$STATE_FILE")"

    if [ "$count" -eq 0 ]; then
      echo "当前没有屏蔽任何网站。"
    else
      echo "当前已屏蔽的域名后缀 (REJECT)："
      jq -r '.blocked_domains[]' "$STATE_FILE" | nl -w1 -s') '
    fi

    echo
    echo "1) 添加屏蔽域名"
    echo "2) 解除已屏蔽的域名"
    echo "0) 返回"
    read -rp "请输入选项: " choice

    case "$choice" in
      1)
        read -rp "请输入要屏蔽的域名: " domain
        if [ -n "$domain" ]; then
          domain="$(echo "$domain" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|^[ \t]*||' -e 's|[ \t]*$||')"
          if [ -n "$domain" ]; then
            local tmp
            tmp="$(mktemp)"
            jq --arg d "$domain" '.blocked_domains += [$d] | .blocked_domains |= unique' "$STATE_FILE" > "$tmp"
            mv "$tmp" "$STATE_FILE"
            chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
            chmod 600 "$STATE_FILE"
            ok "已屏蔽: $domain"
            render_all
            restart_singbox
          fi
          sleep 1
        fi
        ;;
      2)
        if [ "$count" -eq 0 ]; then
          warn "屏蔽列表为空。"
          sleep 1
          continue
        fi
        read -rp "请输入要解除屏蔽的序号 (输入 0 取消): " index
        if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$count" ]; then
          local tmp
          tmp="$(mktemp)"
          local d_name
          d_name="$(jq -r --argjson i "$((index-1))" '.blocked_domains[$i]' "$STATE_FILE")"
          jq --argjson i "$((index-1))" 'del(.blocked_domains[$i])' "$STATE_FILE" > "$tmp"
          mv "$tmp" "$STATE_FILE"
          chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
          chmod 600 "$STATE_FILE"
          ok "已解除屏蔽: $d_name"
          render_all
          restart_singbox
          sleep 1
        fi
        ;;
      0) return 0 ;;
      *) warn "输入错误。"; sleep 1 ;;
    esac
  done
}

update_core_wizard() {
  local current_ver latest_ver

  if command -v sing-box >/dev/null 2>&1; then
    current_ver="$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')"
  else
    current_ver="未知"
  fi

  info "正在获取 sing-box 最新版本..."
  latest_ver="$(get_latest_version)"

  if [ -z "$latest_ver" ]; then
    warn "无法获取最新版本信息，请检查网络。"
    pause
    return 1
  fi

  step "更新 sing-box 内核"
  echo -e "当前版本: ${C_GREEN}${current_ver}${C_RESET}"
  echo -e "最新版本: ${C_GREEN}${latest_ver}${C_RESET}"
  echo

  if [ "$current_ver" = "$latest_ver" ]; then
    info "当前已经是最新版本。"
    read -rp "是否强制重新安装？输入 y 确认: " force
    if [[ "${force,,}" != "y" ]]; then return 0; fi
  else
    read -rp "确认更新到最新版本？输入 y 确认: " confirm
    confirm=${confirm:-y}
    if [[ "${confirm,,}" != "y" ]]; then return 0; fi
  fi

  service_stop
  rm -f /usr/local/bin/sing-box /usr/bin/sing-box
  hash -r 2>/dev/null || true

  install_singbox
  service_restart

  ok "更新并重启完成。"
  pause
}

refresh_ip_wizard() {
  need_state
  step "刷新公网 IP"

  local current_ver current_ip
  current_ver="$(state_get '.ip_version // "ipv4"')"
  current_ip="$(state_get '.server_ip')"

  info "当前 IP 版本: ${current_ver}"
  info "当前 IP: ${current_ip}"
  echo
  echo "1) 切换到 IPv4 并重新检测"
  echo "2) 切换到 IPv6 并重新检测"
  echo "0) 返回"
  read -rp "请选择: " choice

  local new_ip new_ver
  case "$choice" in
    1)
      new_ip="$(detect_public_ip 4)"
      new_ver="ipv4"
      ;;
    2)
      new_ip="$(detect_public_ip 6)"
      new_ver="ipv6"
      ;;
    0) return ;;
    *) warn "输入错误"; sleep 1; return 1 ;;
  esac

  if [ -z "$new_ip" ]; then
    die "未能获取到公网 ${new_ver} 地址。"
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg ver "$new_ver" --arg ip "$new_ip" '.ip_version = $ver | .server_ip = $ip' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true

  render_all
  restart_singbox
  ok "已更新公网 IP 为 ${new_ip} (${new_ver})。"
  pause
}

choose_initial_nodes() {
  step "配置初始节点"

  local vport=""
  local tport=""

  if [ -n "$CLI_VLESS" ]; then
    vport="$CLI_VLESS"
    while true; do
      if [ "$vport" = "0" ]; then
        info "已指定 vless=0，跳过安装 VLESS 直出节点。"
        break
      fi
      if [[ "$vport" =~ ^[0-9]+$ ]] && [ "$vport" -ge 10000 ] && [ "$vport" -le 65535 ]; then
        info "使用参数指定 VLESS 端口: ${vport}"
        add_node_to_state "vless-direct" "$vport" "direct"
        break
      fi
      warn "VLESS 端口 ${vport} 无效（端口不能小于 10000 且需在 10000-65535 之间，输入 0 取消）："
      read -rp "请重新输入 VLESS 端口: " vport
    done
  else
    echo "是否创建 VLESS 直出节点？"
    echo "1) 创建 (默认端口 ${VLESS_DIRECT_PORT})"
    echo "2) 跳过"
    read -rp "请选择 [默认 1]: " vc
    vc="${vc:-1}"
    if [ "$vc" = "1" ]; then
      vport="$(ask_port "请输入 VLESS 直出 TCP 端口" "$VLESS_DIRECT_PORT")"
      add_node_to_state "vless-direct" "$vport" "direct"
    fi
  fi

  if [ -n "$CLI_TUIC" ]; then
    tport="$CLI_TUIC"
    while true; do
      if [ "$tport" = "0" ]; then
        info "已指定 tuic=0，跳过安装 TUIC 直出节点。"
        break
      fi
      if [[ "$tport" =~ ^[0-9]+$ ]] && [ "$tport" -ge 10000 ] && [ "$tport" -le 65535 ]; then
        info "使用参数指定 TUIC 端口: ${tport}"
        add_node_to_state "tuic-direct" "$tport" "direct"
        break
      fi
      warn "TUIC 端口 ${tport} 无效（端口不能小于 10000 且需在 10000-65535 之间，输入 0 取消）："
      read -rp "请重新输入 TUIC 端口: " tport
    done
  else
    echo
    echo "是否创建 TUIC v5 直出节点？"
    echo "1) 创建 (默认端口 ${TUIC_DIRECT_PORT})"
    echo "2) 跳过"
    read -rp "请选择 [默认 1]: " tc
    tc="${tc:-1}"
    if [ "$tc" = "1" ]; then
      tport="$(ask_port "请输入 TUIC 直出 UDP 端口" "$TUIC_DIRECT_PORT")"
      add_node_to_state "tuic-direct" "$tport" "direct"
    fi
  fi
}

render_config() {
  need_state
  step "生成 sing-box 配置"

  jq '
    . as $s |

    def vless_in($n):
    {
      "type": "vless",
      "tag": $n.tag,
      "listen": "::",
      "listen_port": ($n.port | tonumber),
      "users": [
        {
          "uuid": $s.uuid,
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": $s.reality_sni,
        "reality": {
          "enabled": true,
          "handshake": {
            "server": $s.reality_sni,
            "server_port": 443
          },
          "private_key": $s.private_key,
          "short_id": [
            $s.short_id
          ]
        }
      }
    };

    def tuic_in($n):
    {
      "type": "tuic",
      "tag": $n.tag,
      "listen": "::",
      "listen_port": ($n.port | tonumber),
      "users": [
        {
          "name": "user1",
          "uuid": $s.uuid,
          "password": $s.tuic_pass
        }
      ],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "server_name": $s.tuic_sni,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/cert/tuic.crt",
        "key_path": "/etc/sing-box/cert/tuic.key"
      }
    };

    def landing_out($n):
    {
      "type": "vless",
      "tag": ("out-" + $n.tag),
      "server": $n.landing_server,
      "server_port": ($n.landing_port | tonumber),
      "uuid": ($n.landing_uuid // $s.uuid),
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": ($n.landing_sni // $s.reality_sni),
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": ($n.landing_public_key // $s.public_key),
          "short_id": ($n.landing_short_id // $s.short_id)
        }
      },
      "packet_encoding": "xudp"
    };

    {
      "log": {
        "level": "error",
        "timestamp": true
      },
      "inbounds": [
        $s.nodes[]? |
        if (.type | startswith("vless")) then
          vless_in(.)
        elif (.type | startswith("tuic")) then
          tuic_in(.)
        else
          empty
        end
      ],
      "outbounds": (
        [
          {
            "type": "direct",
            "tag": "direct"
          },
          {
            "type": "block",
            "tag": "block"
          }
        ]
        +
        [
          $s.nodes[]? |
          if (.outbound_type == "landing") then
            landing_out(.)
          else
            empty
          end
        ]
      ),
      "route": {
        "rules": (
          (if ($s.blocked_domains != null and ($s.blocked_domains | length > 0)) then
            [
              {
                "domain_suffix": $s.blocked_domains,
                "outbound": "block"
              }
            ]
          else [] end)
          +
          [
            $s.nodes[]? |
            if (.outbound_type == "landing") then
              {
                "inbound": [
                  .tag
                ],
                "action": "route",
                "outbound": ("out-" + .tag)
              }
            else
              {
                "inbound": [
                  .tag
                ],
                "action": "route",
                "outbound": "direct"
              }
            end
          ]
        ),
        "final": "direct"
      }
    }
  ' "$STATE_FILE" > "$CONFIG_FILE"

  chown sing-box:sing-box "$CONFIG_FILE" 2>/dev/null || true
  chmod 600 "$CONFIG_FILE"

  sing-box check -c "$CONFIG_FILE"
  ok "配置检查通过：$CONFIG_FILE"
}

render_info() {
  need_state

  local uuid private_key public_key short_id tuic_pass reality_sni tuic_sni server_ip flag loc
  local ip_version server_ip_display type tag name port protocol encoded_name link outbound_type landing_disp

  uuid="$(state_get '.uuid')"
  private_key="$(state_get '.private_key')"
  public_key="$(state_get '.public_key')"
  short_id="$(state_get '.short_id')"
  tuic_pass="$(state_get '.tuic_pass')"
  reality_sni="$(state_get '.reality_sni')"
  tuic_sni="$(state_get '.tuic_sni')"
  server_ip="$(state_get '.server_ip')"
  ip_version="$(state_get '.ip_version // "ipv4"')"
  flag="$(state_get '.location_flag')"
  loc="$(state_get '.location_name')"

  if [ "$ip_version" = "ipv6" ]; then
    server_ip_display="[${server_ip}]"
  else
    server_ip_display="${server_ip}"
  fi

  cat > "$INFO_FILE" <<INFO
==============================
ysq sing-box 节点信息
==============================
服务器地址: ${server_ip} (${ip_version})
自动命名: ${flag}${loc}
UUID: ${uuid}
REALITY PrivateKey: ${private_key}
REALITY PublicKey: ${public_key}
ShortID: ${short_id}
TUIC Password: ${tuic_pass}

配置文件: ${CONFIG_FILE}
状态文件: ${STATE_FILE}
节点信息: ${INFO_FILE}
YAML配置: ${YAML_FILE}

INFO

  if [ "$(jq '.nodes | length' "$STATE_FILE")" -eq 0 ]; then
    cat >> "$INFO_FILE" <<INFO
当前还没有节点。
输入 ysq 打开面板后，选择“添加节点”。

INFO
    return 0
  fi

  jq -c '.nodes[]' "$STATE_FILE" | while read -r node; do
    type="$(echo "$node" | jq -r '.type')"
    tag="$(echo "$node" | jq -r '.tag')"
    name="$(echo "$node" | jq -r '.name')"
    port="$(echo "$node" | jq -r '.port')"
    protocol="$(echo "$node" | jq -r '.protocol // "tcp"')"
    outbound_type="$(echo "$node" | jq -r '.outbound_type // "direct"')"
    landing_disp="$(echo "$node" | jq -r '.landing_display // "-"' )"
    encoded_name="$(url_encode "$name")"

    if [[ "$type" == vless* ]]; then
      link="vless://${uuid}@${server_ip_display}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${encoded_name}"
    elif [[ "$type" == tuic* ]]; then
      link="tuic://${uuid}:${tuic_pass}@${server_ip_display}:${port}?congestion_control=bbr&alpn=h3&sni=${tuic_sni}&allow_insecure=1#${encoded_name}"
    else
      link=""
    fi

    {
      echo "=============================="
      echo "${name}"
      echo "类型: $(node_type_name "$type" "$outbound_type")"
      echo "传输协议: ${protocol^^}"
      echo "入口端口: ${port}"
      echo "入口 tag: ${tag}"
      if [ "$outbound_type" = "landing" ]; then
        echo "落地出口: ${landing_disp} (端口: $(echo "$node" | jq -r '.landing_port'))"
      fi
      echo "------------------------------"
      echo "$link"
      echo
    } >> "$INFO_FILE"
  done

  chmod 600 "$INFO_FILE"
}

render_yaml() {
  need_state

  local uuid public_key short_id tuic_pass reality_sni tuic_sni server_ip
  local type name port

  uuid="$(state_get '.uuid')"
  public_key="$(state_get '.public_key')"
  short_id="$(state_get '.short_id')"
  tuic_pass="$(state_get '.tuic_pass')"
  reality_sni="$(state_get '.reality_sni')"
  tuic_sni="$(state_get '.tuic_sni')"
  server_ip="$(state_get '.server_ip')"

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

  jq -c '.nodes[]' "$STATE_FILE" | while read -r node; do
    type="$(echo "$node" | jq -r '.type')"
    name="$(echo "$node" | jq -r '.name')"
    port="$(echo "$node" | jq -r '.port')"

    if [[ "$type" == vless* ]]; then
      {
        printf '  - name: %s\n' "$(yaml_quote "$name")"
        cat <<YAML
    type: vless
    server: ${server_ip}
    port: ${port}
    uuid: ${uuid}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${reality_sni}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${public_key}
      short-id: ${short_id}
YAML
      } >> "$YAML_FILE"
    elif [[ "$type" == tuic* ]]; then
      {
        printf '  - name: %s\n' "$(yaml_quote "$name")"
        cat <<YAML
    type: tuic
    server: ${server_ip}
    port: ${port}
    uuid: ${uuid}
    password: ${tuic_pass}
    alpn:
      - h3
    sni: ${tuic_sni}
    skip-cert-verify: true
    congestion-controller: bbr
    udp-relay-mode: native
YAML
      } >> "$YAML_FILE"
    fi
  done

  cat >> "$YAML_FILE" <<YAML

proxy-groups:
  - name: PROXY
    type: select
    proxies:
YAML

  if [ "$(jq '.nodes | length' "$STATE_FILE")" -gt 0 ]; then
    jq -r '.nodes[].name' "$STATE_FILE" | while read -r name; do
      printf '      - %s\n' "$(yaml_quote "$name")" >> "$YAML_FILE"
    done
  fi

  cat >> "$YAML_FILE" <<YAML
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
YAML

  chmod 600 "$YAML_FILE"
}

cleanup_old_subscription_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop ysq-subscription.socket 2>/dev/null || true
    systemctl disable ysq-subscription.socket 2>/dev/null || true
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-service ysq-subscription stop 2>/dev/null || true
    rc-update del ysq-subscription default 2>/dev/null || true
  fi

  rm -f /root/singbox-sub.txt
  rm -f /usr/local/bin/ysq-subscription
  rm -f /etc/systemd/system/ysq-subscription.socket
  rm -f /etc/systemd/system/ysq-subscription@.service
  rm -f /etc/init.d/ysq-subscription

  service_daemon_reload
}

render_all() {
  cleanup_old_subscription_service
  ensure_state_defaults
  ensure_tuic_cert
  render_config
  render_yaml
  render_info
}

restart_singbox() {
  step "重启 sing-box"
  detect_runtime
  ensure_singbox_service
  service_enable
  service_restart
  ok "sing-box 已重启。"
}

list_nodes_table() {
  need_state
  local count
  count="$(jq '.nodes | length' "$STATE_FILE")"

  if [ "$count" -eq 0 ]; then
    warn "当前没有节点。"
    return 0
  fi

  printf "%-4s %-28s %-6s %-8s %-20s %s\n" "序号" "节点名" "协议" "端口" "类型" "落地 (国家：ip)"
  printf "%-4s %-28s %-6s %-8s %-20s %s\n" "----" "----------------------------" "------" "------" "--------------------" "--------------------"

  jq -c '.nodes[]' "$STATE_FILE" | nl -w1 -s' ' | while read -r idx node; do
    local name type port protocol outbound_type landing
    name="$(echo "$node" | jq -r '.name')"
    type="$(echo "$node" | jq -r '.type')"
    protocol="$(echo "$node" | jq -r '.protocol // "tcp"')"
    port="$(echo "$node" | jq -r '.port')"
    outbound_type="$(echo "$node" | jq -r '.outbound_type // "direct"')"
    landing="$(echo "$node" | jq -r '.landing_display // "-"' )"

    printf "%-4s %-28s %-6s %-8s %-20s %s\n" "$idx" "$name" "${protocol^^}" "$port" "$(node_type_name "$type" "$outbound_type")" "$landing"
  done
}

show_ports() {
  if [ -f "$STATE_FILE" ]; then
    local tcp_ports udp_ports
    tcp_ports="$(jq -r '.nodes[]? | select((.protocol // "tcp") == "tcp") | .port' "$STATE_FILE" | paste -sd'|' -)"
    udp_ports="$(jq -r '.nodes[]? | select((.protocol // "tcp") == "udp") | .port' "$STATE_FILE" | paste -sd'|' -)"

    echo "[TCP 监听端口]"
    if [ -n "$tcp_ports" ]; then
      ss -tlpn 2>/dev/null | grep -E ":(${tcp_ports})\\b" || true
    else
      echo "无"
    fi

    echo "[UDP 监听端口]"
    if [ -n "$udp_ports" ]; then
      ss -ulpn 2>/dev/null | grep -E ":(${udp_ports})\\b" || true
    else
      echo "无"
    fi
    return
  fi
  ss -lntup 2>/dev/null | grep sing-box || true
}

print_summary() {
  step "安装完成"
  ok "节点直链文件：${INFO_FILE}"
  ok "Clash YAML 文件：${YAML_FILE}"
  echo
  cat "$INFO_FILE"
  step "Clash YAML"
  cat "$YAML_FILE"
  ok "输入 ysq 打开管理面板。"
}

install_panel_wrapper() {
  cat > "$PANEL_FILE" <<PANEL
#!/usr/bin/env bash
exec "$INSTALLER_FILE" panel "\$@"
PANEL
  chmod +x "$PANEL_FILE"
}

save_self() {
  if [ -f "$0" ]; then
    cp "$0" "$INSTALLER_FILE" 2>/dev/null || true
    chmod +x "$INSTALLER_FILE" 2>/dev/null || true
  fi
}

uninstall_all() {
  step "彻底删除"
  read -rp "确认彻底卸载 sing-box 及配置？输入 y 确认: " confirm
  if [ "$confirm" != "y" ]; then
    warn "已取消。"
    sleep 1
    return 0
  fi

  detect_runtime
  service_stop
  service_disable
  pkg_remove_singbox

  rm -f /usr/local/bin/sing-box /usr/bin/sing-box
  rm -f /etc/systemd/system/sing-box.service
  rm -f /etc/init.d/sing-box
  rm -f /root/install-singbox-ysq.sh
  cleanup_old_subscription_service
  rm -rf /etc/sing-box /var/lib/sing-box /var/log/sing-box
  rm -f "$INFO_FILE" "$YAML_FILE" "$PANEL_FILE" "$INSTALLER_FILE"

  service_daemon_reload
  ok "已彻底删除。"
  exit 0
}

show_status() {
  step "sing-box 状态"
  detect_runtime
  service_status
  echo
  echo "当前节点列表："
  list_nodes_table || true
  echo
  echo "当前端口监听："
  show_ports
  pause
}

panel_menu() {
  need_root
  need_state
  cleanup_old_subscription_service
  ensure_state_defaults

  while true; do
    echo
    echo -e "${C_BOLD}==============================${C_RESET}"
    echo -e "${C_BOLD} ysq sing-box 管理面板${C_RESET}"
    echo -e "${C_BOLD}==============================${C_RESET}"
    echo "状态文件: ${STATE_FILE}"
    echo "配置文件: ${CONFIG_FILE}"
    echo

    list_nodes_table || true
    echo

    echo "1) 查看节点直链"
    echo "2) 查看 Clash YAML"
    echo "3) 查看 sing-box 状态 / 监听端口"
    echo "4) 添加节点 (直出 / 中转落地)"
    echo "5) 落地节点池管理 (查看 / 添加 / 修改 / 删除)"
    echo "6) 删除节点 (支持批量)"
    echo "7) 修改节点 (端口 / SNI / 出口落地)"
    echo "8) 屏蔽指定网站管理"
    echo "9) 更新 sing-box 内核"
    echo "10) 重启 sing-box"
    echo "11) 刷新公网 IP (IPv4/IPv6 切换)"
    echo "12) 彻底删除 sing-box 和脚本"
    echo "0) 退出"
    echo "=============================="
    read -rp "请输入选项: " choice

    case "$choice" in
      1)
        [ -f "$INFO_FILE" ] && cat "$INFO_FILE" || warn "未找到 $INFO_FILE"
        pause
        ;;
      2)
        [ -f "$YAML_FILE" ] && cat "$YAML_FILE" || warn "未找到 $YAML_FILE"
        pause
        ;;
      3) show_status ;;
      4) add_node_wizard; pause ;;
      5) landing_pool_menu ;;
      6) delete_node_wizard ;;
      7) modify_node_port_wizard; pause ;;
      8) block_website_wizard ;;
      9) update_core_wizard ;;
      10) restart_singbox; service_status; pause ;;
      11) refresh_ip_wizard ;;
      12) uninstall_all ;;
      0) exit 0 ;;
      *) warn "输入错误。"; sleep 1 ;;
    esac
  done
}

install_wizard() {
  need_root

  echo -e "${C_BOLD}==============================${C_RESET}"
  echo -e "${C_BOLD} ysq sing-box 一键安装脚本${C_RESET}"
  echo -e "${C_BOLD}==============================${C_RESET}"
  echo

  if [ -f "$STATE_FILE" ] && [ -z "$CLI_VLESS" ] && [ -z "$CLI_TUIC" ] && [ -z "$CLI_SAFE" ]; then
    warn "检测到已有安装状态：$STATE_FILE"
    echo "1) 更新 ysq 面板并打开"
    echo "2) 覆盖重装"
    echo "0) 退出"
    read -rp "请输入选项: " existing_choice

    case "$existing_choice" in
      1)
        save_self
        install_panel_wrapper
        panel_menu
        ;;
      2)
        warn "将覆盖旧配置。"
        ;;
      0)
        exit 0
        ;;
      *)
        die "输入错误。"
        ;;
    esac
  fi

  install_deps
  install_singbox
  ensure_dirs
  create_state_file
  choose_initial_nodes
  render_all
  restart_singbox
  save_self
  install_panel_wrapper
  print_summary
}

case "$ACTION" in
  install)
    install_wizard
    ;;
  panel)
    panel_menu
    ;;
  render)
    need_root
    render_all
    restart_singbox
    ;;
  *)
    echo "用法："
    echo "  bash $0                                            # 交互式安装"
    echo "  bash $0 vless=20001 tuic=20002 safe=0              # 快速指定端口安装"
    echo "  bash $0 panel                                      # 打开管理面板"
    echo "  bash $0 render                                     # 重载配置与重启"
    exit 1
    ;;
esac
