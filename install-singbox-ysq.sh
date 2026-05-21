#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ysq sing-box 一键安装 / 管理脚本
# 支持：
#   - VLESS Reality 直出
#   - TUIC v5 直出
#   - VLESS -> VLESS Reality 中转
#   - TUIC v5 -> VLESS Reality 中转
#   - 面板随时添加 / 删除 / 修改节点端口
#   - 根据服务器公网 IP 所在地自动命名节点
#   - 生成节点直链和 Clash YAML 文件
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
# 默认参数
# 选择“不生成新密钥”时使用
# -------------------------
DEFAULT_UUID="a1126537-6b28-4fd3-856c-2514a7626a8b"
DEFAULT_PRIVATE_KEY="GOThQzAstrApbL92Kb-BU_7GXKOrRfNDQMK74qrEB0g"
DEFAULT_PUBLIC_KEY="pyrWuKuPUx-bt6NOFvugQEszO8XR2qYeKZhVw_dysCM"
DEFAULT_SHORT_ID="884158a048b01725"
DEFAULT_TUIC_PASS="884158a048b01725"

REALITY_SNI="www.microsoft.com"
TUIC_SNI="www.bing.com"

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
    # Docker / LXC / 精简 Alpine 里可能有 rc-service 命令，但 OpenRC 没真正运行。
    # 这种情况下不要强行用 rc-service，改用 nohup 后台兜底。
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
    dnf)
      dnf makecache -y || true
      ;;
    yum)
      yum makecache -y || true
      ;;
    apk)
      apk update
      ;;
  esac
}

pkg_install() {
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
  esac
}

pkg_remove_singbox() {
  case "$PKG_MANAGER" in
    apt)
      apt purge -y sing-box 2>/dev/null || true
      apt remove -y sing-box 2>/dev/null || true
      ;;
    dnf)
      dnf remove -y sing-box 2>/dev/null || true
      ;;
    yum)
      yum remove -y sing-box 2>/dev/null || true
      ;;
    apk)
      apk del sing-box 2>/dev/null || true
      ;;
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

  # 官方 tar.gz 里的 sing-box 在部分版本/架构上会依赖 glibc loader：
  # /lib64/ld-linux-x86-64.so.2。Alpine 默认是 musl，所以需要兼容层。
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

install_singbox_alpine_apk() {
  local arch version url tmp_dir apk_file extracted_bin tgz_arch tgz_file found_bin

  arch="$(normalize_apk_arch)"
  tmp_dir="$(mktemp -d)"

  info "Alpine 系统安装 sing-box..."
  version="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/^v//' 2>/dev/null || true)"
  [ -n "$version" ] && [ "$version" != "null" ] || die "无法获取 sing-box 最新版本号。"

  # 1) 优先尝试官方 Alpine .apk 包。
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
    warn ".apk 安装完成，但 sing-box 无法运行，继续使用备用安装。"
  else
    warn "apk add 本地包失败，尝试直接解包 .apk。"
  fi

  # 2) 有些 Alpine 环境不能 apk add 本地包，尝试把 apk 当 tar 包解开。
  if tar -xzf "$apk_file" -C "$tmp_dir" 2>/dev/null || tar -xf "$apk_file" -C "$tmp_dir" 2>/dev/null; then
    extracted_bin="$(find "$tmp_dir" \( -type f -path '*/bin/sing-box' -o -type f -name sing-box \) | head -n 1)"
    if [ -n "$extracted_bin" ]; then
      install -m 755 "$extracted_bin" /usr/bin/sing-box
      ln -sf /usr/bin/sing-box /usr/local/bin/sing-box
      hash -r 2>/dev/null || true
      if singbox_bin_works /usr/bin/sing-box; then
        rm -rf "$tmp_dir"
        return 0
      fi
      warn "从 .apk 解出的 sing-box 仍无法运行，继续使用 tar.gz 备用安装。"
    else
      warn ".apk 解包后没有找到 sing-box 二进制，继续使用 tar.gz 备用安装。"
    fi
  else
    warn ".apk 无法解包，继续使用 tar.gz 备用安装。"
  fi

  # 3) 最后兜底：使用 GitHub tar.gz。该包在 Alpine 上可能需要 gcompat/glibc loader 兼容层。
  ensure_alpine_glibc_compat
  tgz_arch="$(normalize_arch)"
  tgz_file="${tmp_dir}/sing-box.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${tgz_arch}.tar.gz"
  info "正在下载 tar.gz 备用包：sing-box ${version} / linux-${tgz_arch}"
  curl -fL --connect-timeout 10 --retry 3 -o "$tgz_file" "$url"
  tar -xzf "$tgz_file" -C "$tmp_dir"

  found_bin="$(find "$tmp_dir" -type f -name sing-box | head -n 1)"
  [ -n "$found_bin" ] || { rm -rf "$tmp_dir"; die "tar.gz 包里未找到 sing-box 可执行文件。"; }

  install -m 755 "$found_bin" /usr/bin/sing-box
  ln -sf /usr/bin/sing-box /usr/local/bin/sing-box

  # tar.gz 包可能附带 libcronet.so，复制到系统库目录，避免运行时缺库。
  find "$tmp_dir" -type f -name libcronet.so -exec cp -f {} /usr/lib/libcronet.so \; 2>/dev/null || true
  chmod 755 /usr/lib/libcronet.so 2>/dev/null || true

  hash -r 2>/dev/null || true

  if ! singbox_bin_works /usr/bin/sing-box; then
    err "tar.gz 备用安装后 sing-box 仍无法运行。"
    file /usr/bin/sing-box 2>/dev/null || true
    ldd /usr/bin/sing-box 2>/dev/null || true
    rm -rf "$tmp_dir"
    die "Alpine 上 sing-box 安装失败。"
  fi

  rm -rf "$tmp_dir"
}

install_singbox_manual() {
  local arch version url tmp_dir tar_file found_bin

  arch="$(normalize_arch)"
  tmp_dir="$(mktemp -d)"

  info "正在使用 GitHub Release 备用方式安装 sing-box..."
  version="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/^v//' 2>/dev/null || true)"
  [ -n "$version" ] && [ "$version" != "null" ] || die "无法获取 sing-box 最新版本号。"

  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
  tar_file="${tmp_dir}/sing-box.tar.gz"

  curl -fL --connect-timeout 10 --retry 3 -o "$tar_file" "$url"
  tar -xzf "$tar_file" -C "$tmp_dir"

  found_bin="$(find "$tmp_dir" -type f -name sing-box -perm -111 | head -n 1)"
  [ -n "$found_bin" ] || die "下载包里未找到 sing-box 可执行文件。"

  install -m 755 "$found_bin" /usr/local/bin/sing-box
  rm -rf "$tmp_dir"
  hash -r 2>/dev/null || true
}

ensure_singbox_service() {
  ensure_singbox_user
  SING_BOX_BIN="$(command -v sing-box 2>/dev/null || true)"
  [ -n "$SING_BOX_BIN" ] || die "未找到 sing-box 可执行文件。"

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
      [ -n "$SING_BOX_BIN" ] || die "未找到 sing-box 可执行文件。"
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

ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }
info() { echo -e "${C_BLUE}ℹ️  $*${C_RESET}"; }
step() {
  echo
  echo -e "${C_BOLD}==============================${C_RESET}"
  echo -e "${C_BOLD}$*${C_RESET}"
  echo -e "${C_BOLD}==============================${C_RESET}"
}
die() {
  err "$*"
  exit 1
}
pause() {
  echo
  read -rp "按回车返回..."
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行：sudo bash $0"
}

need_state() {
  [ -f "$STATE_FILE" ] || die "未找到状态文件：$STATE_FILE，请先运行安装。"
}

ask_choice() {
  local prompt="$1"
  local input=""
  read -rp "$prompt" input
  echo "$input"
}

ask_port() {
  local name="$1"
  local default_port="$2"
  local input_port=""

  while true; do
    read -rp "$name [默认 ${default_port}]: " input_port

    if [ -z "$input_port" ]; then
      echo "$default_port"
      return
    fi

    if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
      echo "$input_port"
      return
    fi

    warn "端口输入错误，请输入 1-65535 之间的数字。"
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

port_used() {
  local port="$1"
  local ignore_tag="${2:-}"

  jq -e \
    --argjson p "$port" \
    --arg ignore_tag "$ignore_tag" \
    '.nodes[]? | select(.port == $p and .tag != $ignore_tag)' \
    "$STATE_FILE" >/dev/null 2>&1
}

check_port_available() {
  local port="$1"
  local ignore_tag="${2:-}"

  if port_used "$port" "$ignore_tag"; then
    die "端口 ${port} 已经被当前脚本里的其他节点使用，请换一个端口。"
  fi

  if ss -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"; then
    warn "检测到系统里已有程序监听 ${port}。如果不是当前 sing-box 节点，请换端口。"
    read -rp "仍然继续使用这个端口？输入 y 继续: " confirm
    [ "$confirm" = "y" ] || die "已取消。"
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
  local ip=""

  ip="$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -4 -s --max-time 6 https://ifconfig.me 2>/dev/null || true)"
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
  case "$1" in
    vless-direct) echo "vless" ;;
    tuic-direct) echo "tuic5" ;;
    vless-relay) echo "vless转vless" ;;
    tuic-relay) echo "tuic5转vless" ;;
    *) echo "node" ;;
  esac
}

node_type_name() {
  case "$1" in
    vless-direct) echo "VLESS 直出" ;;
    tuic-direct) echo "TUIC v5 直出" ;;
    vless-relay) echo "VLESS -> VLESS 中转" ;;
    tuic-relay) echo "TUIC v5 -> VLESS 中转" ;;
    *) echo "$1" ;;
  esac
}

make_node_name() {
  local type="$1"
  local port="$2"
  local flag loc base
  flag="$(jq -r '.location_flag // "🌐"' "$STATE_FILE")"
  loc="$(jq -r '.location_name // "未知地区"' "$STATE_FILE")"
  base="${flag}${loc}-$(node_suffix "$type")"

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

  info "系统：${OS_NAME}"
  info "包管理器：${PKG_MANAGER}"
  info "服务管理：${SERVICE_MANAGER}"

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

  ok "必要依赖安装完成：bash / curl / openssl / jq / ca-certificates / iproute / tar / gzip。"
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
      # Alpine 是 musl libc，不能随便使用通用 tar.gz 里的二进制。
      # 这里优先使用官方 Alpine .apk 包，并用绝对路径安装，避免本地包 IO ERROR。
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
      err "sing-box 已安装但无法运行：$(command -v sing-box)"
      file "$(command -v sing-box)" 2>/dev/null || true
      die "当前系统无法执行该 sing-box 二进制文件，请检查 CPU 架构或 libc 兼容性。"
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

  # 兼容旧 v3：删除已经废弃的订阅字段。
  if jq -e 'has("sub_port") or has("sub_token")' "$STATE_FILE" >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    jq 'del(.sub_port, .sub_token)' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
  fi

  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"
}

need_tuic_cert() {
  jq -e '.nodes[]? | select(.type == "tuic-direct" or .type == "tuic-relay")' "$STATE_FILE" >/dev/null 2>&1
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

  info "正在生成 TUIC 自签证书，已隐藏 OpenSSL 进度输出。"

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
    -config "$tmp_dir/openssl.cnf" \
    2>"$tmp_dir/openssl.log"; then
      cat "$tmp_dir/openssl.log" >&2 || true
      rm -rf "$tmp_dir"
      die "TUIC 自签证书生成失败。"
  fi

  install -m 600 -o sing-box -g sing-box "$tmp_dir/tuic.key" "$KEY_FILE"
  install -m 644 -o sing-box -g sing-box "$tmp_dir/tuic.crt" "$CERT_FILE"
  rm -rf "$tmp_dir"

  ok "TUIC 证书生成完成：$CERT_FILE"
}

create_state_file() {
  local uuid private_key public_key short_id tuic_pass server_ip location_raw country_code flag loc

  mkdir -p "$CONFIG_DIR"

  step "基础参数设置"

  echo "请选择是否生成新的 UUID / REALITY 密钥 / ShortID："
  echo "1) 生成新的"
  echo "2) 不生成，使用脚本内默认参数"
  read -rp "请输入 1 或 2: " key_choice

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
      warn "将使用脚本内默认参数。多个服务器复用同一套参数时请注意安全。"
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

  step "检测公网 IP 和所在地"
  server_ip="$(detect_public_ip)"
  [ -n "$server_ip" ] || die "无法获取公网 IP。"

  location_raw="$(detect_location "$server_ip")"
  country_code="$(echo "$location_raw" | cut -d'|' -f1)"
  flag="$(echo "$location_raw" | cut -d'|' -f2)"
  loc="$(echo "$location_raw" | cut -d'|' -f3)"

  ok "公网 IP：${server_ip}"
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
  "country_code": "${country_code}",
  "location_flag": "${flag}",
  "location_name": "${loc}",
  "nodes": []
}
JSON

  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"
}

ask_landing_params() {
  LANDING_SERVER="$(ask_text_default "请输入落地节点 IP 或域名，不能填 0.0.0.0" "")"
  [ "$LANDING_SERVER" != "0.0.0.0" ] || die "落地地址不能是 0.0.0.0。"

  LANDING_PORT="$(ask_port "请输入落地节点 VLESS 端口" "$VLESS_DIRECT_PORT")"
  LANDING_UUID="$(ask_text_default "请输入落地 VLESS UUID" "$(state_get '.uuid')")"
  LANDING_PUBLIC_KEY="$(ask_text_default "请输入落地 Reality PublicKey" "$(state_get '.public_key')")"
  LANDING_SHORT_ID="$(ask_text_default "请输入落地 Reality ShortID" "$(state_get '.short_id')")"
  LANDING_SNI="$(ask_text_default "请输入落地 Reality SNI" "$(state_get '.reality_sni')")"
}

add_node_to_state() {
  local type="$1"
  local port="$2"
  local tag name tmp

  check_port_available "$port"

  tag="${type}-${port}"
  name="$(make_node_name "$type" "$port")"
  tmp="$(mktemp)"

  if [[ "$type" == *"-relay" ]]; then
    jq \
      --arg type "$type" \
      --arg tag "$tag" \
      --arg name "$name" \
      --argjson port "$port" \
      --arg landing_server "$LANDING_SERVER" \
      --argjson landing_port "$LANDING_PORT" \
      --arg landing_uuid "$LANDING_UUID" \
      --arg landing_public_key "$LANDING_PUBLIC_KEY" \
      --arg landing_short_id "$LANDING_SHORT_ID" \
      --arg landing_sni "$LANDING_SNI" \
      '.nodes += [{
        "type": $type,
        "tag": $tag,
        "name": $name,
        "port": $port,
        "landing_server": $landing_server,
        "landing_port": $landing_port,
        "landing_uuid": $landing_uuid,
        "landing_public_key": $landing_public_key,
        "landing_short_id": $landing_short_id,
        "landing_sni": $landing_sni
      }]' "$STATE_FILE" > "$tmp"
  else
    jq \
      --arg type "$type" \
      --arg tag "$tag" \
      --arg name "$name" \
      --argjson port "$port" \
      '.nodes += [{
        "type": $type,
        "tag": $tag,
        "name": $name,
        "port": $port
      }]' "$STATE_FILE" > "$tmp"
  fi

  mv "$tmp" "$STATE_FILE"
  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"

  ok "已添加节点：${name} / 端口 ${port}"
}

add_node_wizard() {
  need_state

  step "添加节点"

  echo "1) VLESS 直出                  默认端口 ${VLESS_DIRECT_PORT}"
  echo "2) TUIC v5 直出                默认端口 ${TUIC_DIRECT_PORT}"
  echo "3) VLESS -> VLESS 中转          默认端口 ${VLESS_RELAY_PORT}"
  echo "4) TUIC v5 -> VLESS 中转        默认端口 ${TUIC_RELAY_PORT}"
  echo "0) 返回"
  read -rp "请选择要添加的节点类型: " choice

  case "$choice" in
    1)
      port="$(ask_port "请输入 VLESS 直出 TCP 端口" "$VLESS_DIRECT_PORT")"
      add_node_to_state "vless-direct" "$port"
      ;;
    2)
      port="$(ask_port "请输入 TUIC 直出 UDP 端口" "$TUIC_DIRECT_PORT")"
      add_node_to_state "tuic-direct" "$port"
      ;;
    3)
      port="$(ask_port "请输入 VLESS 中转入口 TCP 端口" "$VLESS_RELAY_PORT")"
      step "落地 VLESS 参数"
      ask_landing_params
      add_node_to_state "vless-relay" "$port"
      ;;
    4)
      port="$(ask_port "请输入 TUIC 中转入口 UDP 端口" "$TUIC_RELAY_PORT")"
      step "落地 VLESS 参数"
      ask_landing_params
      add_node_to_state "tuic-relay" "$port"
      ;;
    0)
      return 0
      ;;
    *)
      warn "输入错误。"
      return 1
      ;;
  esac

  render_all
  restart_singbox
  ok "节点已生效。"
}

delete_node_wizard() {
  need_state

  local count index tmp name

  count="$(jq '.nodes | length' "$STATE_FILE")"
  [ "$count" -gt 0 ] || { warn "当前没有可删除的节点。"; pause; return 0; }

  step "删除节点"

  list_nodes_table
  echo
  read -rp "请输入要删除的节点序号，输入 0 返回: " index

  if [ "$index" = "0" ]; then
    return 0
  fi

  if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$count" ]; then
    warn "序号输入错误。"
    sleep 1
    return 1
  fi

  name="$(jq -r --argjson i "$((index-1))" '.nodes[$i].name' "$STATE_FILE")"
  read -rp "确认删除「${name}」？输入 y 确认: " confirm
  [ "$confirm" = "y" ] || { warn "已取消删除。"; sleep 1; return 0; }

  tmp="$(mktemp)"
  jq --argjson i "$((index-1))" 'del(.nodes[$i])' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"

  render_all
  restart_singbox

  ok "已删除节点：${name}"
  sleep 1
}

modify_node_port_wizard() {
  need_state

  local count index old_port new_port old_tag new_tag type name tmp

  count="$(jq '.nodes | length' "$STATE_FILE")"
  [ "$count" -gt 0 ] || { warn "当前没有可修改端口的节点。"; pause; return 0; }

  step "修改节点端口"

  list_nodes_table
  echo
  read -rp "请输入要修改端口的节点序号，输入 0 返回: " index

  if [ "$index" = "0" ]; then
    return 0
  fi

  if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$count" ]; then
    warn "序号输入错误。"
    sleep 1
    return 1
  fi

  old_port="$(jq -r --argjson i "$((index-1))" '.nodes[$i].port' "$STATE_FILE")"
  old_tag="$(jq -r --argjson i "$((index-1))" '.nodes[$i].tag' "$STATE_FILE")"
  type="$(jq -r --argjson i "$((index-1))" '.nodes[$i].type' "$STATE_FILE")"
  name="$(jq -r --argjson i "$((index-1))" '.nodes[$i].name' "$STATE_FILE")"

  new_port="$(ask_port "请输入「${name}」的新端口" "$old_port")"

  if [ "$new_port" = "$old_port" ]; then
    warn "端口没有变化。"
    sleep 1
    return 0
  fi

  check_port_available "$new_port" "$old_tag"
  new_tag="${type}-${new_port}"

  read -rp "确认把「${name}」端口从 ${old_port} 改为 ${new_port}？输入 y 确认: " confirm
  [ "$confirm" = "y" ] || { warn "已取消修改。"; sleep 1; return 0; }

  tmp="$(mktemp)"
  jq \
    --argjson i "$((index-1))" \
    --argjson port "$new_port" \
    --arg tag "$new_tag" \
    '.nodes[$i].port = $port | .nodes[$i].tag = $tag' \
    "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"

  render_all
  restart_singbox

  ok "已修改端口：${name} ${old_port} -> ${new_port}"
  sleep 1
}

choose_initial_nodes() {
  step "选择初始节点"

  echo "先选一个初始组合，安装完成后可随时输入 ysq 添加、删除节点或修改端口。"
  echo
  echo "1) 只创建 VLESS 直出"
  echo "2) 只创建 TUIC v5 直出"
  echo "3) 创建 VLESS 直出 + TUIC v5 直出"
  echo "4) 暂不创建直出节点，稍后在面板添加"
  read -rp "请输入 1 / 2 / 3 / 4: " node_choice

  case "$node_choice" in
    1)
      port="$(ask_port "请输入 VLESS 直出 TCP 端口" "$VLESS_DIRECT_PORT")"
      add_node_to_state "vless-direct" "$port"
      ;;
    2)
      port="$(ask_port "请输入 TUIC 直出 UDP 端口" "$TUIC_DIRECT_PORT")"
      add_node_to_state "tuic-direct" "$port"
      ;;
    3)
      port="$(ask_port "请输入 VLESS 直出 TCP 端口" "$VLESS_DIRECT_PORT")"
      add_node_to_state "vless-direct" "$port"
      port="$(ask_port "请输入 TUIC 直出 UDP 端口" "$TUIC_DIRECT_PORT")"
      add_node_to_state "tuic-direct" "$port"
      ;;
    4)
      warn "已选择暂不创建直出节点。"
      ;;
    *)
      die "输入错误，只能输入 1 / 2 / 3 / 4。"
      ;;
  esac

  echo
  echo "是否同时创建中转入口？"
  echo "1) 创建 VLESS -> VLESS 中转，默认入口端口 ${VLESS_RELAY_PORT}"
  echo "2) 创建 TUIC v5 -> VLESS 中转，默认入口端口 ${TUIC_RELAY_PORT}"
  echo "3) 两个中转都创建"
  echo "4) 不创建中转"
  read -rp "请输入 1 / 2 / 3 / 4: " relay_choice

  case "$relay_choice" in
    1)
      step "落地 VLESS 参数"
      ask_landing_params
      port="$(ask_port "请输入 VLESS 中转入口 TCP 端口" "$VLESS_RELAY_PORT")"
      add_node_to_state "vless-relay" "$port"
      ;;
    2)
      step "落地 VLESS 参数"
      ask_landing_params
      port="$(ask_port "请输入 TUIC 中转入口 UDP 端口" "$TUIC_RELAY_PORT")"
      add_node_to_state "tuic-relay" "$port"
      ;;
    3)
      step "落地 VLESS 参数，两个中转会共用这一组落地参数"
      ask_landing_params
      port="$(ask_port "请输入 VLESS 中转入口 TCP 端口" "$VLESS_RELAY_PORT")"
      add_node_to_state "vless-relay" "$port"
      port="$(ask_port "请输入 TUIC 中转入口 UDP 端口" "$TUIC_RELAY_PORT")"
      add_node_to_state "tuic-relay" "$port"
      ;;
    4)
      warn "已选择不创建中转。"
      ;;
    *)
      die "输入错误，只能输入 1 / 2 / 3 / 4。"
      ;;
  esac
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
        "level": "info",
        "timestamp": true
      },
      "inbounds": [
        $s.nodes[]? |
        if (.type == "vless-direct" or .type == "vless-relay") then
          vless_in(.)
        elif (.type == "tuic-direct" or .type == "tuic-relay") then
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
          }
        ]
        +
        [
          $s.nodes[]? |
          if (.type == "vless-relay" or .type == "tuic-relay") then
            landing_out(.)
          else
            empty
          end
        ]
      ),
      "route": {
        "rules": [
          $s.nodes[]? |
          if (.type == "vless-relay" or .type == "tuic-relay") then
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
        ],
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
  local type tag name port encoded_name link

  uuid="$(state_get '.uuid')"
  private_key="$(state_get '.private_key')"
  public_key="$(state_get '.public_key')"
  short_id="$(state_get '.short_id')"
  tuic_pass="$(state_get '.tuic_pass')"
  reality_sni="$(state_get '.reality_sni')"
  tuic_sni="$(state_get '.tuic_sni')"
  server_ip="$(state_get '.server_ip')"
  flag="$(state_get '.location_flag')"
  loc="$(state_get '.location_name')"
  cat > "$INFO_FILE" <<INFO
==============================
ysq sing-box 节点信息
==============================
服务器地址: ${server_ip}
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
    encoded_name="$(url_encode "$name")"

    case "$type" in
      vless-direct|vless-relay)
        link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${encoded_name}"
        ;;
      tuic-direct|tuic-relay)
        link="tuic://${uuid}:${tuic_pass}@${server_ip}:${port}?congestion_control=bbr&alpn=h3&sni=${tuic_sni}&allow_insecure=1#${encoded_name}"
        ;;
      *)
        link=""
        ;;
    esac

    {
      echo "=============================="
      echo "${name}"
      echo "类型: $(node_type_name "$type")"
      echo "入口端口: ${port}"
      echo "入口 tag: ${tag}"

      if [[ "$type" == *"-relay" ]]; then
        echo "落地: $(echo "$node" | jq -r '.landing_server') : $(echo "$node" | jq -r '.landing_port')"
        echo "落地 SNI: $(echo "$node" | jq -r '.landing_sni')"
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

    case "$type" in
      vless-direct|vless-relay)
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
        ;;
      tuic-direct|tuic-relay)
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
        ;;
    esac
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
  # 兼容从 v3 订阅版升级：关闭并删除旧的订阅服务残留。
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

  printf "%-4s %-30s %-20s %-8s %s\n" "序号" "节点名" "类型" "端口" "落地"
  printf "%-4s %-30s %-20s %-8s %s\n" "----" "------------------------------" "--------------------" "------" "----------------"

  jq -c '.nodes[]' "$STATE_FILE" | nl -w1 -s' ' | while read -r idx node; do
    local name type port landing
    name="$(echo "$node" | jq -r '.name')"
    type="$(node_type_name "$(echo "$node" | jq -r '.type')")"
    port="$(echo "$node" | jq -r '.port')"

    if echo "$node" | jq -e 'has("landing_server")' >/dev/null 2>&1; then
      landing="$(echo "$node" | jq -r '.landing_server + ":" + (.landing_port|tostring)')"
    else
      landing="-"
    fi

    printf "%-4s %-30s %-20s %-8s %s\n" "$idx" "$name" "$type" "$port" "$landing"
  done
}

show_ports() {
  if [ -f "$STATE_FILE" ]; then
    local ports
    ports="$(jq -r '.nodes[]?.port' "$STATE_FILE" | paste -sd'|' -)"
    if [ -n "$ports" ]; then
      ss -lntup 2>/dev/null | grep -E ":(${ports})\\b" || true
      return
    fi
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
  ok "以后输入 ysq 打开管理面板。"
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

  if [ ! -x "$INSTALLER_FILE" ]; then
    warn "未能自动保存安装脚本到 ${INSTALLER_FILE}。"
    warn "ysq 面板需要这个文件，请手动把本脚本复制到 ${INSTALLER_FILE}。"
  fi
}

uninstall_all() {
  step "彻底删除"

  echo "这个操作会删除：sing-box、配置、证书、节点信息、YAML、ysq 面板。"
  read -rp "确认删除请输入 y: " confirm
  [ "$confirm" = "y" ] || { warn "已取消删除。"; sleep 1; return 0; }

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
  echo "当前节点："
  list_nodes_table || true
  echo
  echo "当前监听端口："
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
    echo "4) 添加节点"
    echo "5) 删除节点"
    echo "6) 修改节点端口"
    echo "7) 重启 sing-box"
    echo "8) 彻底删除 sing-box 和脚本"
    echo "0) 退出"
    echo "=============================="
    read -rp "请输入选项: " choice

    case "$choice" in
      1)
        [ -f "$INFO_FILE" ] && cat "$INFO_FILE" || warn "未找到节点信息文件：$INFO_FILE"
        pause
        ;;
      2)
        [ -f "$YAML_FILE" ] && cat "$YAML_FILE" || warn "未找到 YAML 文件：$YAML_FILE"
        pause
        ;;
      3)
        show_status
        ;;
      4)
        add_node_wizard
        pause
        ;;
      5)
        delete_node_wizard
        ;;
      6)
        modify_node_port_wizard
        pause
        ;;
      7)
        restart_singbox
        service_status
        pause
        ;;
      8)
        uninstall_all
        ;;
      0)
        exit 0
        ;;
      *)
        warn "输入错误。"
        sleep 1
        ;;
    esac
  done
}

install_wizard() {
  need_root
  echo -e "${C_BOLD}==============================${C_RESET}"
  echo -e "${C_BOLD} ysq sing-box 一键安装脚本${C_RESET}"
  echo -e "${C_BOLD} VLESS / TUIC / VLESS中转 / TUIC中转${C_RESET}"
  echo -e "${C_BOLD}==============================${C_RESET}"
  echo

  if [ -f "$STATE_FILE" ]; then
    warn "检测到已有安装状态：$STATE_FILE"
    echo "1) 更新 ysq 面板并打开"
    echo "2) 覆盖重装"
    echo "0) 退出"
    read -rp "请输入选项: " existing_choice
    case "$existing_choice" in
      1) save_self; install_panel_wrapper; panel_menu ;;
      2) warn "将覆盖旧配置。"; sleep 1 ;;
      0) exit 0 ;;
      *) die "输入错误。" ;;
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

case "${1:-install}" in
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
    echo "  bash $0          # 安装向导"
    echo "  bash $0 panel    # 打开管理面板"
    echo "  bash $0 render   # 重新生成配置、节点信息并重启"
    exit 1
    ;;
esac
