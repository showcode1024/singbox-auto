#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ysq sing-box 生产级一键安装 / 管理脚本
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

get_latest_version() {
  local version
  # 优先使用 API 抓取
  version="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/^v//' 2>/dev/null || true)"
  # 如果遭遇 API 限流，改用抓取跳转链接防封锁兜底
  if [ -z "$version" ] || [ "$version" = "null" ]; then
    version="$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/SagerNet/sing-box/releases/latest | grep -oE '[^/]+$' | sed 's/^v//' || true)"
  fi
  echo "$version"
}

install_singbox_alpine_apk() {
  local arch version url tmp_dir apk_file extracted_bin tgz_arch tgz_file found_bin

  arch="$(normalize_apk_arch)"
  tmp_dir="$(mktemp -d)"

  info "Alpine 系统安装/更新 sing-box..."
  version="$(get_latest_version)"
  if [ -z "$version" ]; then
    warn "无法获取最新版本号（可能触发API限制），将默认安装 1.13.12 版本。"
    version="1.13.12"
  fi

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
  if [ -z "$found_bin" ]; then
    rm -rf "$tmp_dir"
    die "tar.gz 包里未找到 sing-box 可执行文件。"
  fi

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

  info "正在使用 GitHub Release 安装/更新 sing-box..."
  version="$(get_latest_version)"
  if [ -z "$version" ]; then
    warn "无法获取最新版本号，将默认安装 1.13.12 版本。"
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

ok() {
  echo -e "${C_GREEN}✅ $*${C_RESET}"
}
warn() {
  echo -e "${C_YELLOW}⚠️  $*${C_RESET}"
}
err() {
  echo -e "${C_RED}❌ $*${C_RESET}" >&2
}
info() {
  echo -e "${C_BLUE}ℹ️  $*${C_RESET}"
}
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
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 运行：sudo bash $0"
  fi
}

need_state() {
  if [ ! -f "$STATE_FILE" ]; then
    die "未找到状态文件：$STATE_FILE，请先运行安装。"
  fi
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

ask_ports() {
  local prompt="$1"
  local default_port="$2"
  local input_ports=""

  while true; do
    read -rp "$prompt [默认 ${default_port}]: " input_ports
    if [ -z "$input_ports" ]; then
      echo "$default_port"
      return
    fi
    
    local valid=true
    for p in $input_ports; do
      if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
        valid=false
        break
      fi
    done

    if [ "$valid" = true ]; then
      echo "$input_ports"
      return
    fi

    warn "包含无效端口，请输入 1-65535 的数字，多个端口请用空格隔开。"
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
  step "系统依赖安装"

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

  ok "基础依赖安装完成：bash / curl / openssl / jq / ca-certificates / iproute / tar / gzip。"
}

install_singbox() {
  step "安装 / 检查服务端内核"

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
      die "核心组件安装失败，未找到可执行文件。"
    fi

    if ! singbox_bin_works "$(command -v sing-box)"; then
      err "sing-box 已安装但无法运行：$(command -v sing-box)"
      file "$(command -v sing-box)" 2>/dev/null || true
      die "二进制文件与当前 CPU 架构或 libc 不兼容，请检查系统环境。"
    fi

    ok "服务端安装成功：$(sing-box version | head -n 1)"
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
  
  # 确保状态文件中存在被屏蔽的域名列表
  if ! jq -e '. | has("blocked_domains")' "$STATE_FILE" >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    jq '.blocked_domains = []' "$STATE_FILE" > "$tmp"
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

  step "生成 TUIC 加密证书"

  install -d -m 755 -o sing-box -g sing-box "$CERT_DIR"

  if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    ok "TUIC 证书已存在，自动跳过。"
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

  ok "证书生成完成：$CERT_FILE"
}

create_state_file() {
  local uuid private_key public_key short_id tuic_pass server_ip location_raw country_code flag loc

  mkdir -p "$CONFIG_DIR"

  step "基础安全凭据生成"

  echo "1) 生成全新安全凭证 (推荐)"
  echo "2) 维持代码默认参数 (仅供集群复用时选择)"
  read -rp "请输入选项 [默认 1]: " key_choice

  case "${key_choice:-1}" in
    1)
      info "分配全新的 UUID / REALITY 私钥 / 密码凭据..."
      uuid="$(sing-box generate uuid)"
      keypair="$(sing-box generate reality-keypair)"
      private_key="$(echo "$keypair" | awk -F': ' '/PrivateKey/ {print $2}')"
      public_key="$(echo "$keypair" | awk -F': ' '/PublicKey/ {print $2}')"
      short_id="$(openssl rand -hex 8)"
      tuic_pass="$short_id"
      ;;
    2)
      warn "将使用代码内默认参数。多个服务器复用同一套参数时请注意安全。"
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

  step "节点定位与识别"
  server_ip="$(detect_public_ip)"
  if [ -z "$server_ip" ]; then
    die "公网 IP 识别失败。"
  fi

  location_raw="$(detect_location "$server_ip")"
  country_code="$(echo "$location_raw" | cut -d'|' -f1)"
  flag="$(echo "$location_raw" | cut -d'|' -f2)"
  loc="$(echo "$location_raw" | cut -d'|' -f3)"

  ok "识别成功: [IP ${server_ip}] [属地 ${flag}${loc}]"

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
  "blocked_domains": [],
  "nodes": []
}
JSON

  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"
}

ask_landing_params() {
  LANDING_SERVER="$(ask_text_default "请输入落地节点域名或IP (不能填 0.0.0.0)" "")"
  if [ "$LANDING_SERVER" = "0.0.0.0" ]; then
    die "落地地址输入错误，不能是 0.0.0.0。"
  fi

  LANDING_PORT="$(ask_port "请输入落地 VLESS 端口" "$VLESS_DIRECT_PORT")"
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

  ok "节点建立成功：${name} [端口 ${port}]"
}

add_node_wizard() {
  need_state

  step "批量新增代理节点"

  echo "1) VLESS 直出                  (默认端口 ${VLESS_DIRECT_PORT})"
  echo "2) TUIC v5 直出                (默认端口 ${TUIC_DIRECT_PORT})"
  echo "3) VLESS -> VLESS 中转          (默认端口 ${VLESS_RELAY_PORT})"
  echo "4) TUIC v5 -> VLESS 中转        (默认端口 ${TUIC_RELAY_PORT})"
  echo "0) 返回主菜单"
  read -rp "请选择类型: " choice

  case "$choice" in
    1)
      ports="$(ask_ports "指定 VLESS 直出监听端口 (多个端口用空格隔开)" "$VLESS_DIRECT_PORT")"
      for p in $ports; do
        add_node_to_state "vless-direct" "$p"
      done
      ;;
    2)
      ports="$(ask_ports "指定 TUIC 直出监听端口 (多个端口用空格隔开)" "$TUIC_DIRECT_PORT")"
      for p in $ports; do
        add_node_to_state "tuic-direct" "$p"
      done
      ;;
    3)
      step "前置需求：验证中转目标落地参数"
      ask_landing_params
      ports="$(ask_ports "指定 VLESS 中转入口监听端口 (多个端口用空格隔开)" "$VLESS_RELAY_PORT")"
      for p in $ports; do
        add_node_to_state "vless-relay" "$p"
      done
      ;;
    4)
      step "前置需求：验证中转目标落地参数"
      ask_landing_params
      ports="$(ask_ports "指定 TUIC 中转入口监听端口 (多个端口用空格隔开)" "$TUIC_RELAY_PORT")"
      for p in $ports; do
        add_node_to_state "tuic-relay" "$p"
      done
      ;;
    0)
      return 0
      ;;
    *)
      warn "指令错误。"
      return 1
      ;;
  esac

  render_all
  restart_singbox
  ok "新增配置变更已生效。"
}

delete_node_wizard() {
  need_state

  local count indices tmp

  count="$(jq '.nodes | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "库内无可用节点，无法执行删除。"
    pause
    return 0
  fi

  step "批量删除节点"

  list_nodes_table
  echo
  read -rp "请输入要删除的节点序号 (批量删除请用空格隔开，如 1 2 3)，输入 0 返回: " indices

  if [ "$indices" = "0" ]; then
    return 0
  fi

  # 规范化输入：将逗号替换为空格
  indices="${indices//,/ }"

  declare -a valid_tags=()
  declare -a names_to_print=()

  for idx in $indices; do
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "$count" ]; then
      local real_idx=$((idx-1))
      local tag
      local name
      tag="$(jq -r --argjson i "$real_idx" '.nodes[$i].tag' "$STATE_FILE")"
      name="$(jq -r --argjson i "$real_idx" '.nodes[$i].name' "$STATE_FILE")"
      valid_tags+=("$tag")
      names_to_print+=("$name")
    else
      warn "忽略无效的目标序号: $idx"
    fi
  done

  if [ ${#valid_tags[@]} -eq 0 ]; then 
    warn "没有解析到任何有效节点进行删除。"
    sleep 1
    return 1
  fi

  echo "即将清理以下配置信息："
  for n in "${names_to_print[@]}"; do
    echo "  - $n"
  done

  read -rp "危险操作，确认执行？[y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    warn "已撤销指令。"
    sleep 1
    return 0
  fi

  # 使用 jq 的 IN 语法，通过匹配 tag，一次性过滤并删除所有目标节点
  tmp="$(mktemp)"
  local tags_json
  tags_json="$(printf '%s\n' "${valid_tags[@]}" | jq -R . | jq -s .)"
  
  jq --argjson tags "$tags_json" '.nodes |= map(select(.tag as $t | $tags | index($t) | not))' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  
  chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE"

  render_all
  restart_singbox

  ok "指定数据已被安全清理。"
  sleep 1
}

block_website_wizard() {
  need_state

  while true; do
    step "配置域名拦截规则 (服务端生效)"
    
    local count
    count="$(jq '.blocked_domains | length' "$STATE_FILE")"
    
    if [ "$count" -eq 0 ]; then
      echo "当前拦截策略库为空。"
    else
      echo "已激活的域名后缀拦截 (REJECT) 列表："
      jq -r '.blocked_domains[]' "$STATE_FILE" | nl -w1 -s') '
    fi
    
    echo
    echo "1) 录入拦截域名 (自动清洗格式，如 https://baidu.com/abc 会转为 baidu.com)"
    echo "2) 释放拦截域名"
    echo "0) 返回主菜单"
    read -rp "请选择操作指令: " choice

    case "$choice" in
      1)
        read -rp "请输入目标域名: " domain
        if [ -n "$domain" ]; then
          # 域名清洗规则：去除协议、去除末尾路径、去除头尾空格
          domain="$(echo "$domain" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|^[ \t]*||' -e 's|[ \t]*$||')"
          
          if [ -n "$domain" ]; then
            local tmp
            tmp="$(mktemp)"
            # 追加域名并去重
            jq --arg d "$domain" '.blocked_domains += [$d] | .blocked_domains |= unique' "$STATE_FILE" > "$tmp"
            mv "$tmp" "$STATE_FILE"
            
            chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
            chmod 600 "$STATE_FILE"
            
            ok "安全管控: 拦截链路上已注册 $domain"
            render_all
            restart_singbox
          fi
          sleep 1
        fi
        ;;
      2)
        if [ "$count" -eq 0 ]; then 
          warn "当前无可操作的数据。"
          sleep 1
          continue
        fi
        
        read -rp "请输入需要解封的序号 (输入 0 取消): " index
        if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$count" ]; then
          local tmp
          tmp="$(mktemp)"
          local d_name
          d_name="$(jq -r --argjson i "$((index-1))" '.blocked_domains[$i]' "$STATE_FILE")"
          
          jq --argjson i "$((index-1))" 'del(.blocked_domains[$i])' "$STATE_FILE" > "$tmp"
          mv "$tmp" "$STATE_FILE"
          
          chown sing-box:sing-box "$STATE_FILE" 2>/dev/null || true
          chmod 600 "$STATE_FILE"
          
          ok "已解除拦截封印: $d_name"
          render_all
          restart_singbox
          sleep 1
        else
          if [ "$index" != "0" ]; then
            warn "非法的序号。"
            sleep 1
          fi
        fi
        ;;
      0)
        return 0
        ;;
      *)
        warn "输入指令错误。"
        sleep 1
        ;;
    esac
  done
}

modify_node_port_wizard() {
  need_state

  local count index old_port new_port old_tag new_tag type name tmp

  count="$(jq '.nodes | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "库内无可用节点，无法修改监听端口。"
    pause
    return 0
  fi

  step "修改节点监听端口"

  list_nodes_table
  echo
  read -rp "请锁定修改目标的序号，输入 0 返回: " index

  if [ "$index" = "0" ]; then
    return 0
  fi

  if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$count" ]; then
    warn "序号索引越界。"
    sleep 1
    return 1
  fi

  old_port="$(jq -r --argjson i "$((index-1))" '.nodes[$i].port' "$STATE_FILE")"
  old_tag="$(jq -r --argjson i "$((index-1))" '.nodes[$i].tag' "$STATE_FILE")"
  type="$(jq -r --argjson i "$((index-1))" '.nodes[$i].type' "$STATE_FILE")"
  name="$(jq -r --argjson i "$((index-1))" '.nodes[$i].name' "$STATE_FILE")"

  new_port="$(ask_port "设定「${name}」的新监听端口" "$old_port")"

  if [ "$new_port" = "$old_port" ]; then
    info "端口无变动，终止操作。"
    sleep 1
    return 0
  fi

  check_port_available "$new_port" "$old_tag"
  new_tag="${type}-${new_port}"

  read -rp "应用修改：${old_port} -> ${new_port}？[y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    warn "已取消操作。"
    sleep 1
    return 0
  fi

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

  ok "参数覆写成功：${name} [${new_port}]"
  sleep 1
}

update_core_wizard() {
  local current_ver
  local latest_ver
  
  if command -v sing-box >/dev/null 2>&1; then
    current_ver="$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')"
  else
    current_ver="未知版本"
  fi
  
  info "正在联机检索 GitHub Release 仓库..."
  latest_ver="$(get_latest_version)"
  
  if [ -z "$latest_ver" ]; then
    warn "无法获取最新版本信息，请检查服务器网络。"
    pause
    return 1
  fi
  
  step "内核版本核对校验"
  
  echo -e "当前系统运行版本: ${C_GREEN}${current_ver}${C_RESET}"
  echo -e "云端仓库最新版本: ${C_GREEN}${latest_ver}${C_RESET}"
  echo
  
  if [ "$current_ver" = "$latest_ver" ]; then
    info "当前已是最新内核版本。"
    read -rp "是否强制重新拉取并安装覆盖？[y/N]: " force
    if [[ "${force,,}" != "y" ]]; then
      return 0
    fi
  else
    read -rp "确认将内核升级至最新版本？[Y/n]: " confirm
    confirm=${confirm:-Y}
    if [[ "${confirm,,}" != "y" ]]; then
      return 0
    fi
  fi
  
  step "执行一键平滑升级"
  
  service_stop
  rm -f /usr/local/bin/sing-box /usr/bin/sing-box
  hash -r 2>/dev/null || true
  
  install_singbox
  service_restart
  
  ok "内核升级与守护进程重启已全部完成。"
  pause
}

choose_initial_nodes() {
  step "装载初始节点矩阵"

  echo "您可以在此指派首批部署任务 (稍后仍可通过管理面板继续添加)"
  echo
  echo "1) 仅部署 VLESS 直出链路"
  echo "2) 仅部署 TUIC v5 直出链路"
  echo "3) 双擎部署 (VLESS + TUIC v5)"
  echo "4) 暂缓部署，稍后进入面板手动操作"
  read -rp "录入部署方案 [1-4]: " node_choice

  case "$node_choice" in
    1)
      ports="$(ask_ports "指定 VLESS 直出监听端口 (多个用空格隔开)" "$VLESS_DIRECT_PORT")"
      for p in $ports; do
        add_node_to_state "vless-direct" "$p"
      done
      ;;
    2)
      ports="$(ask_ports "指定 TUIC 直出监听端口 (多个用空格隔开)" "$TUIC_DIRECT_PORT")"
      for p in $ports; do
        add_node_to_state "tuic-direct" "$p"
      done
      ;;
    3)
      ports="$(ask_ports "指定 VLESS 直出监听端口 (多个用空格隔开)" "$VLESS_DIRECT_PORT")"
      for p in $ports; do
        add_node_to_state "vless-direct" "$p"
      done
      ports="$(ask_ports "指定 TUIC 直出监听端口 (多个用空格隔开)" "$TUIC_DIRECT_PORT")"
      for p in $ports; do
        add_node_to_state "tuic-direct" "$p"
      done
      ;;
    4)
      info "已跳过直出链路的自动指派。"
      ;;
    *)
      die "无效的选项规范，请输入 1 / 2 / 3 / 4。"
      ;;
  esac

  echo
  echo "是否同步装载中转入口？"
  echo "1) 部署 VLESS -> VLESS 中转枢纽 (默认端口 ${VLESS_RELAY_PORT})"
  echo "2) 部署 TUIC v5 -> VLESS 中转枢纽 (默认端口 ${TUIC_RELAY_PORT})"
  echo "3) 全量部署上述两种枢纽"
  echo "4) 暂不构建中转体系"
  read -rp "录入拓展方案 [1-4]: " relay_choice

  case "$relay_choice" in
    1)
      step "中转目标落地参数"
      ask_landing_params
      ports="$(ask_ports "指定 VLESS 中转入口监听端口 (多个用空格隔开)" "$VLESS_RELAY_PORT")"
      for p in $ports; do
        add_node_to_state "vless-relay" "$p"
      done
      ;;
    2)
      step "中转目标落地参数"
      ask_landing_params
      ports="$(ask_ports "指定 TUIC 中转入口监听端口 (多个用空格隔开)" "$TUIC_RELAY_PORT")"
      for p in $ports; do
        add_node_to_state "tuic-relay" "$p"
      done
      ;;
    3)
      step "中转目标统一落地参数"
      ask_landing_params
      ports="$(ask_ports "指定 VLESS 中转入口监听端口 (多个用空格隔开)" "$VLESS_RELAY_PORT")"
      for p in $ports; do
        add_node_to_state "vless-relay" "$p"
      done
      ports="$(ask_ports "指定 TUIC 中转入口监听端口 (多个用空格隔开)" "$TUIC_RELAY_PORT")"
      for p in $ports; do
        add_node_to_state "tuic-relay" "$p"
      done
      ;;
    4)
      info "已跳过中转枢纽的构建。"
      ;;
    *)
      die "无效的选项规范，请输入 1 / 2 / 3 / 4。"
      ;;
  esac
}

render_config() {
  need_state

  step "重载服务端 JSON 路由体系"

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
          },
          {
            "type": "block",
            "tag": "block"
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
            if (.type == "vless-relay" or .type == "tuic-relay") then
              {
                "inbound": [
                  .tag
                ],
                "outbound": ("out-" + .tag)
              }
            else
              {
                "inbound": [
                  .tag
                ],
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
  ok "核心配置合法性检验通过：$CONFIG_FILE"
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
 服务端身份凭证卡
==============================
接入路由: ${server_ip}
节点定位: ${flag}${loc}
VLESS UUID: ${uuid}
REALITY 公钥 (PublicKey): ${public_key}
REALITY 私钥 (PrivateKey): ${private_key}
ShortID 标识: ${short_id}
TUIC 高速密钥: ${tuic_pass}

配置文件位置: ${CONFIG_FILE}
系统状态总控: ${STATE_FILE}
分享直链文件: ${INFO_FILE}
Clash YAML文件: ${YAML_FILE}

INFO

  if [ "$(jq '.nodes | length' "$STATE_FILE")" -eq 0 ]; then
    cat >> "$INFO_FILE" <<INFO
当前节点列表为空。
请唤起 'ysq' 面板进入高级控制台，执行部署配置。

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
      echo "节点标识: ${name}"
      echo "驱动协议: $(node_type_name "$type")"
      echo "对外暴露端口: ${port}"
      echo "内部路由标 (tag): ${tag}"

      if [[ "$type" == *"-relay" ]]; then
        echo "桥接落地指向: $(echo "$node" | jq -r '.landing_server') : $(echo "$node" | jq -r '.landing_port')"
        echo "桥接握手SNI: $(echo "$node" | jq -r '.landing_sni')"
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
  # 兼容从旧版本订阅体系升级：关闭并删除旧的订阅服务残留。
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
  step "重启主程序"

  detect_runtime
  ensure_singbox_service
  service_enable
  service_restart

  ok "守护进程重启成功并处于运行态。"
}

list_nodes_table() {
  need_state

  local count
  count="$(jq '.nodes | length' "$STATE_FILE")"

  if [ "$count" -eq 0 ]; then
    warn "库内无可用节点配置。"
    return 0
  fi

  printf "%-4s %-30s %-20s %-8s %s\n" "索引" "标识" "驱动层" "端口" "中转落地层"
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
  step "流程完结"
  
  ok "参数导出成功：${INFO_FILE}"
  ok "Clash订阅文件：${YAML_FILE}"
  echo
  cat "$INFO_FILE"
  step "订阅代码节选 (Clash YAML)"
  cat "$YAML_FILE"
  
  ok "指令映射已生效，可在任意终端唤起 'ysq' 面板进入高级控制台。"
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
  step "环境抹除"

  echo "警告：本操作将引发不可逆的数据丢失，包含全部加密凭证与配置！"
  read -rp "执行最终确认？[y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    warn "抹除指令已撤销。"
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

  ok "系统环境已彻底清理，代码后会有期。"
  exit 0
}

show_status() {
  step "运行状态监控"

  detect_runtime
  service_status
  echo
  
  echo "【在线节点大盘】"
  list_nodes_table || true
  echo
  
  echo "【侦听端口追踪】"
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
    echo -e "${C_BOLD} 核心数据与节点管控终端${C_RESET}"
    echo -e "${C_BOLD}==============================${C_RESET}"
    echo "状态文件集: ${STATE_FILE}"
    echo "路由配置集: ${CONFIG_FILE}"
    echo
    
    list_nodes_table || true
    echo
    
    echo "1) 显示节点分享直链"
    echo "2) 显示 Clash 订阅配置"
    echo "3) 监控服务运行状态"
    echo "4) 批量新增代理节点"
    echo "5) 批量删除已有节点"
    echo "6) 修改节点监听端口"
    echo "7) 配置域名拦截规则"
    echo "8) 一键升级服务端内核"
    echo "9) 重启主路由进程"
    echo "10) 卸载脚本及服务端"
    echo "0) 退出控制终端"
    echo "=============================="
    read -rp "下发操作指令: " choice

    case "$choice" in
      1)
        if [ -f "$INFO_FILE" ]; then
          cat "$INFO_FILE"
        else
          warn "未发现分享集文件：$INFO_FILE"
        fi
        pause
        ;;
      2)
        if [ -f "$YAML_FILE" ]; then
          cat "$YAML_FILE"
        else
          warn "未发现订阅集文件：$YAML_FILE"
        fi
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
        block_website_wizard
        ;;
      8)
        update_core_wizard
        ;;
      9)
        restart_singbox
        service_status
        pause
        ;;
      10)
        uninstall_all
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无法解析该指令。"
        sleep 1
        ;;
    esac
  done
}

install_wizard() {
  need_root
  
  echo -e "${C_BOLD}==============================${C_RESET}"
  echo -e "${C_BOLD} 融合网关集群架构快速部署${C_RESET}"
  echo -e "${C_BOLD}==============================${C_RESET}"
  echo

  if [ -f "$STATE_FILE" ]; then
    warn "侦测到历史遗留数据："
    echo "1) 重载面板组件并拉起控制台"
    echo "2) 彻底覆盖重装"
    echo "0) 放弃并退出"
    read -rp "请下发干预指令: " existing_choice
    
    case "$existing_choice" in
      1)
        save_self
        install_panel_wrapper
        panel_menu
        ;;
      2)
        warn "即将进入强行覆盖执行流。"
        sleep 1
        ;;
      0)
        exit 0
        ;;
      *)
        die "无法解析干预指令。"
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
    echo "用法指引："
    echo "  bash $0          # 向导式构建集群"
    echo "  bash $0 panel    # 呼出管控面板"
    echo "  bash $0 render   # 触发无感配置重载"
    exit 1
    ;;
esac
