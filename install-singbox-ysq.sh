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
#
# 设计要点：
#   - 落地信息只保存在落地池 (.landings)，节点只通过 landing_id 引用
#   - 所有修改先写临时文件；配置通过 sing-box check 后才替换；失败自动回滚 state
#   - 面板里每个操作都在子 shell 中运行，die 只会中止当前操作，不会退出面板
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
CERT_SNI_FILE="/etc/sing-box/cert/tuic.sni"
INFO_FILE="/root/singbox-node-info.txt"
YAML_FILE="/root/singbox-nodes.yaml"
PANEL_FILE="/usr/local/bin/ysq"
INSTALLER_FILE="/root/install-singbox-ysq.sh"

# 约定：操作函数返回 3 表示“用户主动取消”，不提示失败、不暂停
CANCEL_RC=3
# 约定：卸载完成后返回 99，让面板整体退出
EXIT_PANEL_RC=99

# -------------------------
# 颜色输出（需要在参数解析之前定义）
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
# warn / err 输出到 stderr，避免被 $(...) 捕获进返回值
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}" >&2; }
err() { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }
info() { echo -e "${C_BLUE}ℹ️  $*${C_RESET}"; }
step() {
  echo
  echo -e "${C_BOLD}==============================${C_RESET}"
  echo -e "${C_BOLD}$*${C_RESET}"
  echo -e "${C_BOLD}==============================${C_RESET}"
}
# die 只在当前（子）shell 退出；面板里每个操作都跑在子 shell 中
die() { err "$*"; exit 1; }
pause() { echo; read -rp "按回车返回..." _ || true; }

# -------------------------
# 临时文件管理
#   - state / config 的临时文件放在 /etc/sing-box 内（同分区，mv 原子替换）
#   - 下载 / 证书等放在 WORK_DIR
#   - EXIT 时统一清理；面板每个操作结束后也会清理
# -------------------------
WORK_DIR="/tmp/ysq-work.$$"

cleanup_tmp() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
  rm -f "${STATE_FILE}".tmp.* "${CONFIG_FILE}".tmp.* 2>/dev/null || true
}
trap cleanup_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

new_work_dir() {
  mkdir -p "$WORK_DIR"
  chmod 700 "$WORK_DIR"
  mktemp -d "${WORK_DIR}/d.XXXXXX"
}

# -------------------------
# CLI 参数解析（未知参数直接报错）
# -------------------------
CLI_VLESS=""
CLI_TUIC=""
CLI_SAFE=""
ACTION=""

usage() {
  cat <<EOF
用法：
  bash $0                                    # 交互式安装
  bash $0 vless=20001 tuic=20002 safe=0      # 快速指定端口安装（端口 1-65535，0 表示不创建）
  bash $0 panel                              # 打开管理面板
  bash $0 render                             # 重新生成配置并重启
EOF
}

set_action() {
  if [ -n "$ACTION" ] && [ "$ACTION" != "$1" ]; then
    err "只能指定一个动作（已指定 ${ACTION}，又指定了 $1）。"
    usage >&2
    exit 1
  fi
  ACTION="$1"
}

for arg in "$@"; do
  case "$arg" in
    vless=*) CLI_VLESS="${arg#*=}" ;;
    tuic=*)  CLI_TUIC="${arg#*=}" ;;
    safe=*)  CLI_SAFE="${arg#*=}" ;;
    panel|render|install) set_action "$arg" ;;
    -h|--help|help) usage; exit 0 ;;
    *)
      err "未知参数：${arg}"
      case "$arg" in
        vless|tuic|safe) warn "参数格式应为 ${arg}=值，例如 ${arg}=20001（等号两边不要有空格）。" ;;
      esac
      usage >&2
      exit 1
      ;;
  esac
done

ACTION="${ACTION:-install}"

# 显式写了 vless= / tuic= / safe= 但值为空
for arg in "$@"; do
  case "$arg" in
    vless=|tuic=|safe=)
      err "参数 ${arg} 的值不能为空。"
      usage >&2
      exit 1
      ;;
  esac
done

if [ -n "$CLI_SAFE" ] && [ "$CLI_SAFE" != "0" ] && [ "$CLI_SAFE" != "1" ]; then
  err "safe 参数只能是 0 或 1，当前为：${CLI_SAFE}"
  usage >&2
  exit 1
fi

if [ "$ACTION" != "install" ] && { [ -n "$CLI_VLESS" ] || [ -n "$CLI_TUIC" ] || [ -n "$CLI_SAFE" ]; }; then
  err "vless= / tuic= / safe= 只能用于安装模式。"
  usage >&2
  exit 1
fi

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

# 只在入口调用一次
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

valid_version() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]]
}

get_latest_version() {
  local version=""

  version="$(curl -fsSL --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
    | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')" || version=""

  if ! valid_version "$version"; then
    version="$(curl -Ls --max-time 15 -o /dev/null -w '%{url_effective}' \
      https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null \
      | grep -oE '[^/]+$' | sed 's/^v//')" || version=""
  fi

  valid_version "$version" || version=""
  echo "$version"
}

install_singbox_alpine_apk() {
  local arch version url tmp_dir apk_file tgz_arch tgz_file found_bin

  arch="$(normalize_apk_arch)"
  tmp_dir="$(new_work_dir)"

  info "Alpine 系统安装 sing-box..."
  version="$(get_latest_version)"
  if [ -z "$version" ]; then
    warn "无法获取最新版本号，默认安装 1.13.12 版本。"
    version="1.13.12"
  fi

  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box_${version}_linux_${arch}.apk"
  apk_file="${tmp_dir}/sing-box.apk"
  info "正在下载 Alpine .apk 包：sing-box ${version} / ${arch}"

  if curl -fL --connect-timeout 10 --retry 3 -o "$apk_file" "$url" \
     && apk add --allow-untrusted "$apk_file"; then
    hash -r 2>/dev/null || true
    if command -v sing-box >/dev/null 2>&1 && singbox_bin_works "$(command -v sing-box)"; then
      rm -rf "$tmp_dir"
      return 0
    fi
  fi

  warn ".apk 方式不可用，改用 tar.gz 安装。"
  ensure_alpine_glibc_compat
  tgz_arch="$(normalize_arch)"
  tgz_file="${tmp_dir}/sing-box.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${tgz_arch}.tar.gz"
  curl -fL --connect-timeout 10 --retry 3 -o "$tgz_file" "$url" || die "sing-box 下载失败：$url"
  tar -xzf "$tgz_file" -C "$tmp_dir" || die "sing-box 解压失败。"

  found_bin="$(find "$tmp_dir" -type f -name sing-box | head -n 1)"
  if [ -z "$found_bin" ]; then
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
  tmp_dir="$(new_work_dir)"

  info "正在使用 GitHub Release 备用方式安装 sing-box..."
  version="$(get_latest_version)"
  if [ -z "$version" ]; then
    version="1.13.12"
  fi

  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
  tar_file="${tmp_dir}/sing-box.tar.gz"

  curl -fL --connect-timeout 10 --retry 3 -o "$tar_file" "$url" || die "sing-box 下载失败：$url"
  tar -xzf "$tar_file" -C "$tmp_dir" || die "sing-box 解压失败。"

  found_bin="$(find "$tmp_dir" -type f -name sing-box -perm -111 | head -n 1)"
  if [ -z "$found_bin" ]; then
    die "下载包里未找到 sing-box 可执行文件。"
  fi

  install -m 755 "$found_bin" /usr/local/bin/sing-box
  rm -rf "$tmp_dir"
  hash -r 2>/dev/null || true
}

# 仅当内容变化时才覆盖目标文件；内容有变化返回 0，无变化返回 1
install_if_changed() {
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    return 1
  fi
  install -m "$mode" "$src" "$dest"
}

# 只在安装 / 更新内核时调用；restart_singbox 不再重写 unit
ensure_singbox_service() {
  local wd

  ensure_singbox_user
  SING_BOX_BIN="$(command -v sing-box 2>/dev/null || true)"
  if [ -z "$SING_BOX_BIN" ]; then
    die "未找到 sing-box 可执行文件。"
  fi

  mkdir -p /var/lib/sing-box /var/log/sing-box
  chown -R sing-box:sing-box /var/lib/sing-box /var/log/sing-box 2>/dev/null || true

  wd="$(new_work_dir)"

  case "$SERVICE_MANAGER" in
    systemd)
      cat > "$wd/unit" <<EOF
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
      if install_if_changed "$wd/unit" /etc/systemd/system/sing-box.service 644; then
        systemctl daemon-reload 2>/dev/null || true
      fi
      ;;
    openrc)
      cat > "$wd/unit" <<EOF
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
      install_if_changed "$wd/unit" /etc/init.d/sing-box 755 || true
      ;;
    none)
      warn "未检测到 systemd/openrc，将使用 nohup 后台方式管理 sing-box。"
      ;;
  esac

  rm -rf "$wd"
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

# 失败返回 1（不 die），方便上层回滚
service_restart() {
  case "$SERVICE_MANAGER" in
    systemd)
      if ! systemctl restart sing-box; then
        err "systemctl restart sing-box 失败。"
        journalctl -u sing-box -n 20 --no-pager 2>/dev/null >&2 || true
        return 1
      fi
      sleep 1
      if ! systemctl is-active --quiet sing-box; then
        err "sing-box 启动后异常退出。"
        journalctl -u sing-box -n 20 --no-pager 2>/dev/null >&2 || true
        return 1
      fi
      ;;
    openrc)
      if ! rc-service sing-box restart; then
        err "rc-service sing-box restart 失败。"
        tail -n 20 /var/log/sing-box/sing-box.err 2>/dev/null >&2 || true
        return 1
      fi
      sleep 1
      if ! rc-service sing-box status >/dev/null 2>&1; then
        err "sing-box 启动后异常退出。"
        tail -n 20 /var/log/sing-box/sing-box.err 2>/dev/null >&2 || true
        return 1
      fi
      ;;
    none)
      service_stop
      SING_BOX_BIN="$(command -v sing-box 2>/dev/null || true)"
      if [ -z "$SING_BOX_BIN" ]; then
        err "未找到 sing-box 可执行文件。"
        return 1
      fi
      install -d -m 755 -o sing-box -g sing-box /var/lib/sing-box /var/log/sing-box 2>/dev/null \
        || mkdir -p /var/lib/sing-box /var/log/sing-box
      nohup "$SING_BOX_BIN" -D /var/lib/sing-box -C /etc/sing-box run > /var/log/sing-box/sing-box.log 2>&1 &
      echo $! > /run/sing-box.pid
      sleep 1
      if ! kill -0 "$(cat /run/sing-box.pid)" 2>/dev/null; then
        cat /var/log/sing-box/sing-box.log >&2 || true
        err "sing-box 后台启动失败。"
        return 1
      fi
      ;;
  esac
  return 0
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
# 通用工具
# -------------------------
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

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 端口范围 1-65535
valid_port() {
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] || return 1
  [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

ask_port() {
  local name="$1"
  local default_port="$2"
  local allow_zero="${3:-false}"
  local input_port=""

  while true; do
    read -rp "$name [默认 ${default_port}]: " input_port
    input_port="$(trim "$input_port")"

    if [ -z "$input_port" ]; then
      echo "$default_port"
      return
    fi

    if [ "$allow_zero" = "true" ] && [ "$input_port" = "0" ]; then
      echo "0"
      return
    fi

    if valid_port "$input_port"; then
      echo "$((10#$input_port))"
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
    input="$(trim "$input")"
    echo "${input:-$default_value}"
  else
    while true; do
      read -rp "$prompt: " input
      input="$(trim "$input")"
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
  local confirm=""

  if port_used "$port" "$proto" "$ignore_tag"; then
    die "端口 ${port} (${proto^^}) 已经被当前脚本里的其他节点使用，请换一个端口。"
  fi

  local ss_arg="-tlpn"
  [ "$proto" = "udp" ] && ss_arg="-ulpn"

  if ss "$ss_arg" 2>/dev/null | awk '{print $4, $5}' | grep -Eq "[:.]${port}\\b"; then
    warn "检测到系统里已有程序在 ${proto^^} 监听 ${port}。如果不是当前 sing-box 节点，请换端口。"
    read -rp "仍然继续使用这个端口？输入 y 继续: " confirm
    if [ "${confirm,,}" != "y" ]; then
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

# -------------------------
# IP 校验 / 检测
# -------------------------
is_ipv4() {
  local ip="${1:-}" o
  local -a octs
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a octs <<<"$ip"
  for o in "${octs[@]}"; do
    [ "$((10#$o))" -le 255 ] || return 1
  done
  return 0
}

is_ipv6() {
  local ip="${1:-}"
  [ "${#ip}" -ge 2 ] && [ "${#ip}" -le 45 ] || return 1
  [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
  [[ "$ip" == *:*:* ]] || return 1
  return 0
}

is_private_ipv4() {
  local a b
  IFS=. read -r a b _ _ <<<"$1"
  a=$((10#$a))
  b=$((10#$b))
  [ "$a" -eq 0 ] || [ "$a" -eq 10 ] || [ "$a" -eq 127 ] \
    || { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } \
    || { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; } \
    || { [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; } \
    || { [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; }
}

# 成功时输出符合版本格式的 IP；失败返回 1（不会回退到不匹配版本的地址）
detect_public_ip() {
  local ver="${1:-4}"
  local ip="" url
  local -a urls

  if [ "$ver" = "6" ]; then
    urls=(https://api6.ipify.org https://ifconfig.co https://icanhazip.com)
  else
    urls=(https://api.ipify.org https://ifconfig.me https://icanhazip.com)
  fi

  for url in "${urls[@]}"; do
    ip="$(curl "-${ver}" -fsS --max-time 6 "$url" 2>/dev/null | tr -d ' \r\n' || true)"
    if [ "$ver" = "6" ]; then
      if is_ipv6 "$ip"; then echo "$ip"; return 0; fi
    else
      if is_ipv4 "$ip"; then echo "$ip"; return 0; fi
    fi
  done

  # 外网接口都失败时，从本机网卡兜底：只接受同版本、且是公网的地址
  if [ "$ver" = "6" ]; then
    while read -r ip; do
      case "$ip" in
        fc*|fd*|FC*|FD*|fe80*|FE80*|"") continue ;;
      esac
      if is_ipv6 "$ip"; then echo "$ip"; return 0; fi
    done < <(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  else
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    if is_ipv4 "$ip" && ! is_private_ipv4 "$ip"; then echo "$ip"; return 0; fi
  fi

  return 1
}

# 域名 -> IP（IP 原样返回）；解析失败输出空
resolve_host_ip() {
  local host="${1:-}" ip=""

  host="${host#[}"
  host="${host%]}"

  if is_ipv4 "$host" || is_ipv6 "$host"; then
    echo "$host"
    return 0
  fi

  if command -v getent >/dev/null 2>&1; then
    ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    if [ -z "$ip" ]; then
      ip="$(getent ahosts "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    fi
  fi

  echo "$ip"
}

# 输出：国家码|旗帜|名称
detect_location() {
  local host="$1"
  local ip="" code="" pair=""

  ip="$(resolve_host_ip "$host")" || ip=""

  if [ -n "$ip" ]; then
    code="$(curl -4 -s --max-time 8 "https://ipapi.co/${ip}/country/" 2>/dev/null | tr -d '\r\n ' || true)"
    if ! [[ "$code" =~ ^[A-Za-z]{2}$ ]]; then
      code="$(curl -4 -s --max-time 8 "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d '\r\n ' || true)"
    fi
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

# -------------------------
# 依赖 / sing-box 安装
# -------------------------
install_deps() {
  step "准备系统环境"
  info "系统：${OS_NAME} (${PKG_MANAGER})"

  # 只安装缺失的依赖：EL9 上已有 curl-minimal 时再装 curl 会冲突
  local -a missing=()

  command -v curl    >/dev/null 2>&1 || missing+=(curl)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  command -v jq      >/dev/null 2>&1 || missing+=(jq)
  command -v tar     >/dev/null 2>&1 || missing+=(tar)
  command -v gzip    >/dev/null 2>&1 || missing+=(gzip)

  if ! command -v ss >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1; then
    case "$PKG_MANAGER" in
      apt|apk) missing+=(iproute2) ;;
      dnf|yum) missing+=(iproute) ;;
    esac
  fi

  case "$PKG_MANAGER" in
    dnf|yum)
      command -v useradd >/dev/null 2>&1 || missing+=(shadow-utils)
      ;;
    apk)
      command -v file   >/dev/null 2>&1 || missing+=(file)
      command -v getent >/dev/null 2>&1 || missing+=(musl-utils)
      ;;
  esac

  if ! [ -s /etc/ssl/certs/ca-certificates.crt ] && ! [ -s /etc/pki/tls/certs/ca-bundle.crt ]; then
    missing+=(ca-certificates)
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    info "需要安装的依赖：${missing[*]}"
    pkg_update
    if ! pkg_install "${missing[@]}"; then
      case "$PKG_MANAGER" in
        dnf|yum)
          warn "依赖安装失败，尝试先安装 epel-release 后重试。"
          pkg_install epel-release || true
          pkg_install "${missing[@]}" || die "依赖安装失败：${missing[*]}"
          ;;
        *)
          die "依赖安装失败：${missing[*]}"
          ;;
      esac
    fi
  else
    info "依赖已齐全，跳过安装。"
  fi

  if [ "$PKG_MANAGER" = "apk" ]; then
    update-ca-certificates 2>/dev/null || true
    ensure_alpine_glibc_compat
  fi

  ok "必要依赖已就绪。"
}

install_singbox() {
  step "安装 / 检查 sing-box"

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

# -------------------------
# state 读写（全部走“临时文件 + mv”）
# -------------------------
state_get() {
  jq -r "$1" "$STATE_FILE"
}

# 用法：state_build <jq 参数...> '<filter>'
# 结果写入新的临时文件，路径保存在 NEW_STATE；jq 失败直接 die，不会碰原 state
NEW_STATE=""
state_build() {
  [ -f "$STATE_FILE" ] || die "未找到状态文件：$STATE_FILE"
  NEW_STATE="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || die "无法创建临时文件。"
  if ! jq "$@" "$STATE_FILE" > "$NEW_STATE"; then
    rm -f "$NEW_STATE"
    NEW_STATE=""
    die "更新状态失败（jq 报错），原状态未改动。"
  fi
}

# 直接落盘（不渲染 / 不重启）：用于不影响 sing-box 配置的修改，以及安装流程
commit_state_plain() {
  [ -n "$NEW_STATE" ] && [ -f "$NEW_STATE" ] || die "内部错误：没有待提交的状态。"
  chown sing-box:sing-box "$NEW_STATE" 2>/dev/null || true
  chmod 600 "$NEW_STATE"
  mv -f "$NEW_STATE" "$STATE_FILE"
  NEW_STATE=""
}

rollback_state() {
  local bak_state="$1" bak_conf="$2" do_restart="$3"

  mv -f "$bak_state" "$STATE_FILE"
  if [ -n "$bak_conf" ] && [ -f "$bak_conf" ]; then
    mv -f "$bak_conf" "$CONFIG_FILE"
  fi
  render_yaml || true
  render_info || true

  if [ "$do_restart" = "restart" ]; then
    restart_singbox || warn "旧配置重启也失败了，请在面板中查看 sing-box 状态。"
  fi
}

# 提交 NEW_STATE 并让它生效：
#   渲染配置(写临时文件 → sing-box check → mv) → 重启；任何一步失败都回滚 state（和 config）
apply_state() {
  local bak_state bak_conf=""

  [ -n "$NEW_STATE" ] && [ -f "$NEW_STATE" ] || die "内部错误：没有待提交的状态。"

  bak_state="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || die "无法创建备份文件。"
  cp -p "$STATE_FILE" "$bak_state"
  if [ -f "$CONFIG_FILE" ]; then
    bak_conf="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || die "无法创建备份文件。"
    cp -p "$CONFIG_FILE" "$bak_conf"
  fi

  commit_state_plain

  if ! render_all; then
    err "新配置生成 / 检查失败，已回滚到修改前的状态，当前运行的配置未受影响。"
    rollback_state "$bak_state" "$bak_conf" "no"
    return 1
  fi

  if ! restart_singbox; then
    err "sing-box 重启失败，正在回滚到修改前的状态..."
    rollback_state "$bak_state" "$bak_conf" "restart"
    return 1
  fi

  rm -f "$bak_state"
  [ -z "$bak_conf" ] || rm -f "$bak_conf"
  return 0
}

# 规范化 state，并把旧版本“节点内冗余拷贝的落地信息”迁移到落地池
ensure_state_defaults() {
  local tmp

  [ -f "$STATE_FILE" ] || { err "未找到状态文件：$STATE_FILE"; return 1; }

  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! jq '
    def lid($n; $ls):
      ( first($ls[] | select(.id == ($n.landing_id // ""))) | .id ) //
      ( first($ls[] | select(.server == ($n.landing_server // "")
                              and ((.port | tostring) == (($n.landing_port // "") | tostring)))) | .id ) //
      null;

    del(.sub_port, .sub_token) |
    (if has("blocked_domains") then . else .blocked_domains = [] end) |
    (if has("ip_version") then . else .ip_version = "ipv4" end) |
    (if has("landings") then . else .landings = [] end) |
    (if has("nodes") then . else .nodes = [] end) |
    .landings |= map(
      if ((.id // "") | tostring | length) > 0 then .
      else .id = ("landing_" + ((.server | tostring) | gsub("[^a-zA-Z0-9]"; "_")) + "_" + ((.port // 0) | tostring))
      end
    ) |
    .nodes |= map(
      (if has("protocol") then . else .protocol = (if .type | startswith("tuic") then "udp" else "tcp" end) end) |
      (if has("outbound_type") then . else .outbound_type = (if .type | endswith("-relay") then "landing" else "direct" end) end)
    ) |
    # 旧版本：落地信息被拷贝进每个节点 -> 补进落地池
    reduce (.nodes[] | select(.outbound_type == "landing" and has("landing_server"))) as $n (.;
      if lid($n; .landings) != null then .
      else .landings += [{
        "id": ("landing_" + (($n.landing_server | tostring) | gsub("[^a-zA-Z0-9]"; "_")) + "_" + (($n.landing_port // 0) | tostring)),
        "server": $n.landing_server,
        "port": ($n.landing_port | tonumber),
        "uuid": ($n.landing_uuid // .uuid),
        "public_key": ($n.landing_public_key // .public_key),
        "short_id": ($n.landing_short_id // .short_id),
        "sni": ($n.landing_sni // .reality_sni),
        "display": ($n.landing_display // $n.landing_server)
      }]
      end
    ) |
    .landings as $ls |
    .nodes |= map(
      if (.outbound_type == "landing") and has("landing_server")
      then .landing_id = (lid(.; $ls) // .landing_id)
      else . end
    ) |
    # 之后节点只保留 landing_id 引用
    .nodes |= map(del(.landing_server, .landing_port, .landing_uuid, .landing_public_key,
                      .landing_short_id, .landing_sni, .landing_display))
  ' "$STATE_FILE" > "$tmp"; then
    rm -f "$tmp"
    err "规范化状态文件失败。"
    return 1
  fi

  chown sing-box:sing-box "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
  return 0
}

need_tuic_cert() {
  jq -e '.nodes[]? | select(.type | startswith("tuic"))' "$STATE_FILE" >/dev/null 2>&1
}

# 证书与 tuic_sni 绑定：SNI 变了会自动重新生成，不需要手动删证书
ensure_tuic_cert() {
  local tuic_sni san wd old_sni=""

  need_tuic_cert || return 0

  tuic_sni="$(state_get '.tuic_sni')"

  install -d -m 755 -o sing-box -g sing-box "$CERT_DIR" || return 1

  if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    if [ -f "$CERT_SNI_FILE" ]; then
      old_sni="$(cat "$CERT_SNI_FILE")"
    else
      old_sni="$tuic_sni"   # 旧版本没有记录，视为一致
    fi
    if [ "$old_sni" = "$tuic_sni" ]; then
      if [ ! -f "$CERT_SNI_FILE" ]; then
        printf '%s' "$tuic_sni" > "$CERT_SNI_FILE"
        chown sing-box:sing-box "$CERT_SNI_FILE" 2>/dev/null || true
      fi
      return 0
    fi
    info "TUIC SNI 已变化（${old_sni} -> ${tuic_sni}），重新生成证书。"
  else
    info "正在生成 TUIC 自签证书..."
  fi

  if [[ "$tuic_sni" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$tuic_sni" == *:* ]]; then
    san="IP:${tuic_sni}"
  else
    san="DNS:${tuic_sni}"
  fi

  wd="$(new_work_dir)" || return 1

  cat > "$wd/openssl.cnf" <<EOF
[req]
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
    -keyout "$wd/tuic.key" \
    -out "$wd/tuic.crt" \
    -days 3650 \
    -config "$wd/openssl.cnf" >/dev/null 2>&1; then
    rm -rf "$wd"
    err "TUIC 自签证书生成失败。"
    return 1
  fi

  install -m 600 -o sing-box -g sing-box "$wd/tuic.key" "$KEY_FILE" || { rm -rf "$wd"; return 1; }
  install -m 644 -o sing-box -g sing-box "$wd/tuic.crt" "$CERT_FILE" || { rm -rf "$wd"; return 1; }
  printf '%s' "$tuic_sni" > "$CERT_SNI_FILE"
  chown sing-box:sing-box "$CERT_SNI_FILE" 2>/dev/null || true
  rm -rf "$wd"

  ok "TUIC 证书生成完成：$CERT_FILE"
  return 0
}

create_state_file() {
  local uuid private_key public_key short_id tuic_pass server_ip location_raw
  local country_code flag loc ip_version key_choice ipv_choice keypair tmp

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
        [ -n "$uuid" ] && [ -n "$private_key" ] && [ -n "$public_key" ] || die "生成密钥失败。"
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
    server_ip="$(detect_public_ip 4)" || server_ip=""
  else
    step "选择 IP 版本"
    echo "请选择用于节点分享的公网 IP 版本："
    echo "1) IPv4 (默认)"
    echo "2) IPv6"
    read -rp "请输入 1 或 2: " ipv_choice

    case "$ipv_choice" in
      1|"")
        ip_version="ipv4"
        server_ip="$(detect_public_ip 4)" || server_ip=""
        ;;
      2)
        ip_version="ipv6"
        server_ip="$(detect_public_ip 6)" || server_ip=""
        ;;
      *)
        die "输入错误，只能输入 1 或 2。"
        ;;
    esac
  fi

  if [ -z "$server_ip" ]; then
    die "未能获取到有效的公网 ${ip_version} 地址（该机器可能没有 ${ip_version} 公网出口）。"
  fi

  step "检测公网 IP 和所在地"
  location_raw="$(detect_location "$server_ip")"
  country_code="$(echo "$location_raw" | cut -d'|' -f1)"
  flag="$(echo "$location_raw" | cut -d'|' -f2)"
  loc="$(echo "$location_raw" | cut -d'|' -f3)"

  ok "公网 IP (${ip_version})：${server_ip}"
  ok "自动命名地区：${flag}${loc}"

  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || die "无法创建临时文件。"
  if ! jq -n \
    --arg uuid "$uuid" \
    --arg private_key "$private_key" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" \
    --arg tuic_pass "$tuic_pass" \
    --arg reality_sni "$REALITY_SNI" \
    --arg tuic_sni "$TUIC_SNI" \
    --arg server_ip "$server_ip" \
    --arg ip_version "$ip_version" \
    --arg country_code "$country_code" \
    --arg flag "$flag" \
    --arg loc "$loc" \
    '{
      uuid: $uuid,
      private_key: $private_key,
      public_key: $public_key,
      short_id: $short_id,
      tuic_pass: $tuic_pass,
      reality_sni: $reality_sni,
      tuic_sni: $tuic_sni,
      server_ip: $server_ip,
      ip_version: $ip_version,
      country_code: $country_code,
      location_flag: $flag,
      location_name: $loc,
      blocked_domains: [],
      landings: [],
      nodes: []
    }' > "$tmp"; then
    rm -f "$tmp"
    die "生成状态文件失败。"
  fi

  NEW_STATE="$tmp"
  commit_state_plain
}

# -------------------------
# 落地节点池管理
# -------------------------
landing_count() {
  jq '.landings | length' "$STATE_FILE"
}

add_landing_wizard() {
  need_state
  step "添加落地节点"

  local l_server l_port l_uuid l_public_key l_short_id l_sni loc_raw flag loc l_display l_id

  l_server="$(ask_text_default "请输入落地节点 IP 或域名" "")"
  l_server="${l_server#[}"
  l_server="${l_server%]}"
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

  l_id="landing_$(date +%s)_${RANDOM}"

  state_build \
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
    }]'
  # 新增的落地没有被任何节点引用，不影响 sing-box 配置，无需重启
  commit_state_plain

  ok "落地节点添加成功：${l_display} (端口: ${l_port})"
}

list_landings_table() {
  local idx disp port sni used

  if [ "$(landing_count)" -eq 0 ]; then
    warn "当前无任何落地节点。"
    return 1
  fi

  printf "%-4s %-32s %-8s %-8s %s\n" "序号" "落地节点 (国家：ip)" "端口" "被引用" "SNI"
  printf "%-4s %-32s %-8s %-8s %s\n" "----" "--------------------------------" "------" "------" "----------------"

  while IFS=$'\t' read -r idx disp port used sni; do
    printf "%-4s %-32s %-8s %-8s %s\n" "$idx" "$disp" "$port" "$used" "$sni"
  done < <(jq -r '. as $s | .landings | to_entries[] | .value as $l
    | [(.key + 1), $l.display, $l.port,
       ([$s.nodes[]? | select(.landing_id == $l.id)] | length), $l.sni] | @tsv' "$STATE_FILE")

  return 0
}

# 修改落地池中第 idx（从 0 开始）个条目；节点只引用 id，所以不需要同步任何拷贝
edit_landing() {
  local idx="$1"
  local l_id old_server old_port old_uuid old_pbk old_sid old_sni old_disp used
  local new_server new_port new_uuid new_pbk new_sid new_sni new_disp loc_raw flag loc

  l_id="$(jq -r --argjson i "$idx" '.landings[$i].id' "$STATE_FILE")"
  old_server="$(jq -r --argjson i "$idx" '.landings[$i].server' "$STATE_FILE")"
  old_port="$(jq -r --argjson i "$idx" '.landings[$i].port' "$STATE_FILE")"
  old_uuid="$(jq -r --argjson i "$idx" '.landings[$i].uuid' "$STATE_FILE")"
  old_pbk="$(jq -r --argjson i "$idx" '.landings[$i].public_key' "$STATE_FILE")"
  old_sid="$(jq -r --argjson i "$idx" '.landings[$i].short_id' "$STATE_FILE")"
  old_sni="$(jq -r --argjson i "$idx" '.landings[$i].sni' "$STATE_FILE")"
  old_disp="$(jq -r --argjson i "$idx" '.landings[$i].display' "$STATE_FILE")"
  used="$(jq --arg id "$l_id" '[.nodes[]? | select(.landing_id == $id)] | length' "$STATE_FILE")"

  echo
  echo "--- 当前落地信息 ---"
  echo "显示标识 : ${old_disp}"
  echo "IP/域名  : ${old_server}"
  echo "端口     : ${old_port}"
  echo "UUID     : ${old_uuid}"
  echo "PublicKey: ${old_pbk}"
  echo "ShortID  : ${old_sid}"
  echo "SNI      : ${old_sni}"
  echo "被引用   : ${used} 个节点"
  echo "--------------------"
  if [ "$used" -gt 0 ]; then
    warn "该落地被 ${used} 个节点使用，修改后会同步生效并重启 sing-box。"
  fi
  echo "请直接输入新值，按回车保持当前默认："

  new_server="$(ask_text_default "落地 IP 或域名" "$old_server")"
  new_server="${new_server#[}"
  new_server="${new_server%]}"
  new_port="$(ask_port "落地 VLESS 端口" "$old_port")"
  new_uuid="$(ask_text_default "落地 UUID" "$old_uuid")"
  new_pbk="$(ask_text_default "落地 Reality PublicKey" "$old_pbk")"
  new_sid="$(ask_text_default "落地 Reality ShortID" "$old_sid")"
  new_sni="$(ask_text_default "落地 Reality SNI" "$old_sni")"

  if [ "$new_server" != "$old_server" ]; then
    info "检测到 IP/域名变动，正在重新解析地区..."
    loc_raw="$(detect_location "$new_server")"
    flag="$(echo "$loc_raw" | cut -d'|' -f2)"
    loc="$(echo "$loc_raw" | cut -d'|' -f3)"
    new_disp="${flag}${loc}：${new_server}"
  else
    new_disp="$old_disp"
  fi

  state_build \
    --argjson i "$idx" \
    --arg server "$new_server" \
    --argjson port "$new_port" \
    --arg uuid "$new_uuid" \
    --arg pbk "$new_pbk" \
    --arg sid "$new_sid" \
    --arg sni "$new_sni" \
    --arg disp "$new_disp" \
    '.landings[$i] |= (
        .server = $server | .port = $port | .uuid = $uuid |
        .public_key = $pbk | .short_id = $sid | .sni = $sni | .display = $disp
     )'

  if [ "$used" -gt 0 ]; then
    apply_state
  else
    commit_state_plain
  fi

  ok "落地节点已更新：${new_disp}"
}

modify_landing_wizard() {
  need_state
  step "修改落地节点信息"

  local count pick

  count="$(landing_count)"
  if [ "$count" -eq 0 ]; then
    warn "当前暂无已保存的落地节点。"
    return "$CANCEL_RC"
  fi

  list_landings_table || true
  echo
  read -rp "请输入要修改的落地节点序号 (输入 0 返回): " pick
  pick="$(trim "$pick")"
  if [ -z "$pick" ] || [ "$pick" = "0" ]; then return "$CANCEL_RC"; fi

  if ! [[ "$pick" =~ ^[0-9]{1,6}$ ]] || [ "$((10#$pick))" -lt 1 ] || [ "$((10#$pick))" -gt "$count" ]; then
    warn "序号无效。"
    return 1
  fi

  edit_landing "$((10#$pick - 1))"
}

delete_landing_wizard() {
  need_state
  step "删除落地节点"

  local count pick idx l_id disp used confirm users

  count="$(landing_count)"
  if [ "$count" -eq 0 ]; then
    warn "当前没有可删除的落地节点。"
    return "$CANCEL_RC"
  fi

  list_landings_table || true
  echo
  read -rp "请输入要删除的落地节点序号 (输入 0 返回): " pick
  pick="$(trim "$pick")"
  if [ -z "$pick" ] || [ "$pick" = "0" ]; then return "$CANCEL_RC"; fi

  if ! [[ "$pick" =~ ^[0-9]{1,6}$ ]] || [ "$((10#$pick))" -lt 1 ] || [ "$((10#$pick))" -gt "$count" ]; then
    warn "序号无效。"
    return 1
  fi

  idx=$((10#$pick - 1))
  l_id="$(jq -r --argjson i "$idx" '.landings[$i].id' "$STATE_FILE")"
  disp="$(jq -r --argjson i "$idx" '.landings[$i].display' "$STATE_FILE")"
  used="$(jq --arg id "$l_id" '[.nodes[]? | select(.landing_id == $id)] | length' "$STATE_FILE")"

  if [ "$used" -gt 0 ]; then
    users="$(jq -r --arg id "$l_id" '.nodes[]? | select(.landing_id == $id) | "  - " + .name' "$STATE_FILE")"
    warn "落地 [${disp}] 正被以下 ${used} 个节点使用，无法删除："
    echo "$users" >&2
    warn "请先到「修改节点」把这些节点改为直出或换成其他落地，或直接删除这些节点。"
    return 1
  fi

  read -rp "确认删除落地节点 [${disp}] 吗？输入 y 确认: " confirm
  if [ "${confirm,,}" != "y" ]; then
    warn "已取消。"
    return "$CANCEL_RC"
  fi

  state_build --argjson i "$idx" 'del(.landings[$i])'
  commit_state_plain

  ok "已删除落地节点。"
}

landing_pool_menu() {
  local lchoice

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
      1) act add_landing_wizard ;;
      2) act modify_landing_wizard ;;
      3) act delete_landing_wizard ;;
      0) return 0 ;;
      *) warn "输入错误。" ;;
    esac
  done
}

# 选择已有落地，或新建；输入 0 取消（返回 1）
SEL_LANDING_ID=""
SEL_LANDING_DISPLAY=""
select_or_create_landing() {
  local count pick real_idx

  while true; do
    echo
    echo "请选择落地节点："
    list_landings_table || true
    echo "  +) 添加新的落地节点"
    echo "  0) 取消"
    read -rp "请输入序号 / + / 0: " pick
    pick="$(trim "$pick")"

    if [ "$pick" = "0" ]; then
      return 1
    fi

    if [ "$pick" = "+" ]; then
      add_landing_wizard
      continue
    fi

    count="$(landing_count)"
    if [[ "$pick" =~ ^[0-9]{1,6}$ ]] && [ "$((10#$pick))" -ge 1 ] && [ "$((10#$pick))" -le "$count" ]; then
      real_idx=$((10#$pick - 1))
      SEL_LANDING_ID="$(jq -r --argjson i "$real_idx" '.landings[$i].id' "$STATE_FILE")"
      SEL_LANDING_DISPLAY="$(jq -r --argjson i "$real_idx" '.landings[$i].display' "$STATE_FILE")"
      return 0
    fi
    warn "无效选项，请重新选择。"
  done
}

# -------------------------
# 节点增删操作
# -------------------------
# 只构建新的 state（NEW_STATE），由调用方决定 commit_state_plain 还是 apply_state
prepare_add_node() {
  local type="$1"
  local port="$2"
  local outbound_type="${3:-direct}"
  local landing_id="${4:-}"
  local protocol tag name

  if [[ "$type" == tuic* ]]; then
    protocol="udp"
  else
    protocol="tcp"
  fi

  check_port_available "$port" "$protocol"

  tag="${type}-${port}"
  name="$(make_node_name "$type" "$port" "$outbound_type")"

  state_build \
    --arg type "$type" \
    --arg protocol "$protocol" \
    --arg outbound_type "$outbound_type" \
    --arg tag "$tag" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg landing_id "$landing_id" \
    '.nodes += [
       ({
         "type": $type,
         "protocol": $protocol,
         "outbound_type": $outbound_type,
         "tag": $tag,
         "name": $name,
         "port": $port
       } + (if $landing_id != "" then {"landing_id": $landing_id} else {} end))
     ]'

  info "新增节点：${name} / 协议: ${protocol^^} / 端口: ${port}"
}

add_node_wizard() {
  need_state
  step "添加节点"

  local choice port outbound_choice

  echo "1) 添加 VLESS 节点 (TCP)"
  echo "2) 添加 TUIC v5 节点 (UDP)"
  echo "3) 添加落地节点"
  echo "0) 返回"
  read -rp "请选择: " choice

  case "$choice" in
    1|2)
      if [ "$choice" = "1" ]; then
        port="$(ask_port "请输入 VLESS TCP 端口" "$VLESS_DIRECT_PORT")"
      else
        port="$(ask_port "请输入 TUIC UDP 端口" "$TUIC_DIRECT_PORT")"
      fi
      echo
      echo "请选择出站方式："
      echo "1) 直出"
      echo "2) 落地中转 (选择已添加的落地节点)"
      read -rp "请输入 1 或 2 [默认 1]: " outbound_choice
      outbound_choice="${outbound_choice:-1}"

      if [ "$outbound_choice" = "2" ]; then
        select_or_create_landing || { warn "已取消。"; return "$CANCEL_RC"; }
        if [ "$choice" = "1" ]; then
          prepare_add_node "vless-relay" "$port" "landing" "$SEL_LANDING_ID"
        else
          prepare_add_node "tuic-relay" "$port" "landing" "$SEL_LANDING_ID"
        fi
      else
        if [ "$choice" = "1" ]; then
          prepare_add_node "vless-direct" "$port" "direct"
        else
          prepare_add_node "tuic-direct" "$port" "direct"
        fi
      fi
      ;;
    3)
      add_landing_wizard
      return 0
      ;;
    0) return "$CANCEL_RC" ;;
    *) warn "输入错误。"; return 1 ;;
  esac

  apply_state
  ok "节点已生效。"
}

delete_node_wizard() {
  need_state

  local count indices confirm idx real_idx tag name n tags_json
  local -a valid_tags=()
  local -a names_to_print=()
  local -a seen=()

  count="$(jq '.nodes | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "当前没有可删除的节点。"
    return "$CANCEL_RC"
  fi

  step "删除节点 (支持批量)"
  list_nodes_table
  echo
  read -rp "请输入要删除的节点序号 (多个用空格隔开，如 1 2)，输入 0 返回: " indices
  indices="${indices//,/ }"
  indices="$(trim "$indices")"

  if [ -z "$indices" ] || [ "$indices" = "0" ]; then return "$CANCEL_RC"; fi

  for idx in $indices; do
    if [[ "$idx" =~ ^[0-9]{1,6}$ ]] && [ "$((10#$idx))" -ge 1 ] && [ "$((10#$idx))" -le "$count" ]; then
      real_idx=$((10#$idx - 1))
      # 去重
      if [[ " ${seen[*]:-} " == *" ${real_idx} "* ]]; then continue; fi
      seen+=("$real_idx")
      tag="$(jq -r --argjson i "$real_idx" '.nodes[$i].tag' "$STATE_FILE")"
      name="$(jq -r --argjson i "$real_idx" '.nodes[$i].name' "$STATE_FILE")"
      valid_tags+=("$tag")
      names_to_print+=("$name")
    else
      warn "忽略无效的序号: $idx"
    fi
  done

  if [ "${#valid_tags[@]}" -eq 0 ]; then
    warn "未选择有效节点。"
    return 1
  fi

  echo "即将删除以下节点："
  for n in "${names_to_print[@]}"; do
    echo "  - $n"
  done

  read -rp "确认删除？输入 y 确认: " confirm
  if [ "${confirm,,}" != "y" ]; then
    warn "已取消删除。"
    return "$CANCEL_RC"
  fi

  tags_json="$(printf '%s\n' "${valid_tags[@]}" | jq -R . | jq -s .)"
  state_build --argjson tags "$tags_json" \
    '.nodes |= map(select(.tag as $t | $tags | index($t) | not))'

  apply_state
  ok "删除完成。"
}

modify_node_wizard() {
  need_state

  local count index real_idx old_port new_port old_tag type protocol name
  local outbound_type landing_id landing_display mod_choice
  local current_sni new_sni out_target new_type new_name lidx

  count="$(jq '.nodes | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "当前没有可修改的节点。"
    return "$CANCEL_RC"
  fi

  step "修改节点 (端口 / SNI / 出口落地)"
  list_nodes_table
  echo
  read -rp "请输入要修改的节点序号，输入 0 返回: " index
  index="$(trim "$index")"

  if [ -z "$index" ] || [ "$index" = "0" ]; then return "$CANCEL_RC"; fi

  if ! [[ "$index" =~ ^[0-9]{1,6}$ ]] || [ "$((10#$index))" -lt 1 ] || [ "$((10#$index))" -gt "$count" ]; then
    warn "序号输入错误。"
    return 1
  fi

  real_idx=$((10#$index - 1))
  type="$(jq -r --argjson i "$real_idx" '.nodes[$i].type' "$STATE_FILE")"
  protocol="$(jq -r --argjson i "$real_idx" '.nodes[$i].protocol // (if .type | startswith("tuic") then "udp" else "tcp" end)' "$STATE_FILE")"
  name="$(jq -r --argjson i "$real_idx" '.nodes[$i].name' "$STATE_FILE")"
  old_port="$(jq -r --argjson i "$real_idx" '.nodes[$i].port' "$STATE_FILE")"
  old_tag="$(jq -r --argjson i "$real_idx" '.nodes[$i].tag' "$STATE_FILE")"
  outbound_type="$(jq -r --argjson i "$real_idx" '.nodes[$i].outbound_type // "direct"' "$STATE_FILE")"
  landing_id="$(jq -r --argjson i "$real_idx" '.nodes[$i].landing_id // ""' "$STATE_FILE")"
  landing_display="-"
  if [ "$outbound_type" = "landing" ]; then
    landing_display="$(jq -r --arg id "$landing_id" '((first(.landings[]? | select(.id == $id)) | .display) // "(落地已丢失)")' "$STATE_FILE")"
  fi

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
  echo "2) 修改入站 SNI (同协议所有节点共用)"
  echo "3) 修改出口方式 (切换直出 / 更换已有落地)"
  if [ "$outbound_type" = "landing" ]; then
    echo "4) 编辑当前绑定的落地参数 (IP / 端口 / 密钥等，所有引用该落地的节点同步生效)"
  fi
  echo "0) 返回"
  read -rp "请输入选项: " mod_choice

  case "$mod_choice" in
    1)
      new_port="$(ask_port "请输入新端口 (${protocol^^})" "$old_port")"
      if [ "$new_port" = "$old_port" ]; then
        info "端口未改变。"
        return "$CANCEL_RC"
      fi
      check_port_available "$new_port" "$protocol" "$old_tag"
      state_build --argjson i "$real_idx" \
        --argjson port "$new_port" \
        --arg tag "${type}-${new_port}" \
        '.nodes[$i].port = $port | .nodes[$i].tag = $tag'
      ;;
    2)
      if [[ "$type" == tuic* ]]; then
        current_sni="$(state_get '.tuic_sni')"
        info "TUIC SNI 为所有 TUIC 节点共用，修改后会自动重新生成自签证书。"
      else
        current_sni="$(state_get '.reality_sni')"
        info "Reality SNI 为所有 VLESS 节点共用。落地侧 SNI 请用选项 4 或落地池管理修改。"
      fi
      new_sni="$(ask_text_default "请输入新 SNI" "$current_sni")"
      if [ "$new_sni" = "$current_sni" ]; then
        info "SNI 未改变。"
        return "$CANCEL_RC"
      fi
      if [[ "$type" == tuic* ]]; then
        state_build --arg sni "$new_sni" '.tuic_sni = $sni'
      else
        state_build --arg sni "$new_sni" '.reality_sni = $sni'
      fi
      ;;
    3)
      echo "请选择新出站方式："
      echo "1) 改为直出 (Direct)"
      echo "2) 选择已有或新建落地节点"
      echo "0) 返回"
      read -rp "请输入 1 / 2 / 0: " out_target

      if [ "$out_target" = "1" ]; then
        if [[ "$type" == tuic* ]]; then new_type="tuic-direct"; else new_type="vless-direct"; fi
        new_name="$(make_node_name "$new_type" "$old_port" "direct")"
        state_build --argjson i "$real_idx" \
          --arg type "$new_type" \
          --arg name "$new_name" \
          '.nodes[$i] |= (.type = $type | .name = $name | .outbound_type = "direct" | del(.landing_id))'
      elif [ "$out_target" = "2" ]; then
        select_or_create_landing || { warn "已取消。"; return "$CANCEL_RC"; }
        if [[ "$type" == tuic* ]]; then new_type="tuic-relay"; else new_type="vless-relay"; fi
        new_name="$(make_node_name "$new_type" "$old_port" "landing")"
        state_build --argjson i "$real_idx" \
          --arg type "$new_type" \
          --arg name "$new_name" \
          --arg lid "$SEL_LANDING_ID" \
          '.nodes[$i] |= (.type = $type | .name = $name | .outbound_type = "landing" | .landing_id = $lid)'
      else
        return "$CANCEL_RC"
      fi
      ;;
    4)
      if [ "$outbound_type" != "landing" ]; then
        warn "当前节点为直出节点，无落地参数可修改。"
        return "$CANCEL_RC"
      fi
      lidx="$(jq -r --arg id "$landing_id" '.landings | map(.id) | index($id) // empty' "$STATE_FILE")"
      if [ -z "$lidx" ]; then
        die "该节点引用的落地节点已不存在，请用选项 3 重新选择落地。"
      fi
      edit_landing "$lidx"
      return 0
      ;;
    0)
      return "$CANCEL_RC"
      ;;
    *)
      warn "无效选项。"
      return 1
      ;;
  esac

  apply_state
  ok "节点修改已生效。"
}

# -------------------------
# 屏蔽指定网站（route reject 规则；sing-box 1.11+ 已移除 block 出站）
# -------------------------
normalize_domain() {
  local d="$1"
  d="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
  d="${d#*://}"
  d="${d%%/*}"
  d="${d%%\?*}"
  d="${d%%#*}"
  d="${d##*@}"
  d="${d%%:*}"
  d="${d#\*.}"
  d="${d#.}"
  d="$(trim "$d")"
  printf '%s' "$d"
}

block_add() {
  need_state

  local domain

  read -rp "请输入要屏蔽的域名 (输入 0 返回): " domain
  domain="$(trim "$domain")"
  if [ -z "$domain" ] || [ "$domain" = "0" ]; then return "$CANCEL_RC"; fi

  domain="$(normalize_domain "$domain")"
  if ! [[ "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    warn "域名格式无效：${domain:-<空>}（中文域名请填写 punycode 形式）"
    return 1
  fi

  if jq -e --arg d "$domain" '.blocked_domains | index($d)' "$STATE_FILE" >/dev/null 2>&1; then
    info "该域名已在屏蔽列表中：$domain"
    return "$CANCEL_RC"
  fi

  state_build --arg d "$domain" '.blocked_domains += [$d] | .blocked_domains |= unique'
  apply_state
  ok "已屏蔽: $domain"
}

block_remove() {
  need_state

  local count index d_name

  count="$(jq '.blocked_domains | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "屏蔽列表为空。"
    return "$CANCEL_RC"
  fi

  read -rp "请输入要解除屏蔽的序号 (输入 0 取消): " index
  index="$(trim "$index")"
  if [ -z "$index" ] || [ "$index" = "0" ]; then return "$CANCEL_RC"; fi

  if ! [[ "$index" =~ ^[0-9]{1,6}$ ]] || [ "$((10#$index))" -lt 1 ] || [ "$((10#$index))" -gt "$count" ]; then
    warn "序号无效。"
    return 1
  fi

  d_name="$(jq -r --argjson i "$((10#$index - 1))" '.blocked_domains[$i]' "$STATE_FILE")"
  state_build --argjson i "$((10#$index - 1))" 'del(.blocked_domains[$i])'
  apply_state
  ok "已解除屏蔽: $d_name"
}

block_website_menu() {
  need_state

  local count choice

  while true; do
    step "屏蔽指定网站 (域名) 管理"
    count="$(jq '.blocked_domains | length' "$STATE_FILE")"

    if [ "$count" -eq 0 ]; then
      echo "当前没有屏蔽任何网站。"
    else
      echo "当前已屏蔽的域名后缀 (reject)："
      jq -r '.blocked_domains | to_entries[] | "\(.key + 1)) \(.value)"' "$STATE_FILE"
    fi

    echo
    echo "1) 添加屏蔽域名"
    echo "2) 解除已屏蔽的域名"
    echo "0) 返回"
    read -rp "请输入选项: " choice

    case "$choice" in
      1) act block_add ;;
      2) act block_remove ;;
      0) return 0 ;;
      *) warn "输入错误。" ;;
    esac
  done
}

# -------------------------
# 更新内核 / 刷新 IP
# -------------------------
update_core_wizard() {
  local current_ver latest_ver force confirm bin wd rc

  if command -v sing-box >/dev/null 2>&1; then
    current_ver="$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}' || true)"
  else
    current_ver="未知"
  fi

  info "正在获取 sing-box 最新版本..."
  latest_ver="$(get_latest_version)"

  if [ -z "$latest_ver" ]; then
    warn "无法获取最新版本信息，请检查网络。"
    return 1
  fi

  step "更新 sing-box 内核"
  echo -e "当前版本: ${C_GREEN}${current_ver}${C_RESET}"
  echo -e "最新版本: ${C_GREEN}${latest_ver}${C_RESET}"
  echo

  if [ "$current_ver" = "$latest_ver" ]; then
    info "当前已经是最新版本。"
    read -rp "是否强制重新安装？输入 y 确认: " force
    if [ "${force,,}" != "y" ]; then return "$CANCEL_RC"; fi
  else
    read -rp "确认更新到最新版本？输入 y 确认 [默认 y]: " confirm
    confirm="${confirm:-y}"
    if [ "${confirm,,}" != "y" ]; then return "$CANCEL_RC"; fi
  fi

  # 先备份旧二进制，安装失败时恢复，避免把服务搞成“没有可执行文件”
  bin="$(command -v sing-box 2>/dev/null || true)"
  wd="$(new_work_dir)"
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    cp -p "$bin" "$wd/sing-box.bak"
  fi

  service_stop
  rm -f /usr/local/bin/sing-box /usr/bin/sing-box
  hash -r 2>/dev/null || true

  # 子 shell 里运行，保证 install_singbox 里的 die 不会直接结束整个操作
  set +e
  ( set -e; install_singbox )
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    err "更新失败，正在恢复旧版本..."
    if [ -f "$wd/sing-box.bak" ] && [ -n "$bin" ]; then
      install -m 755 "$wd/sing-box.bak" "$bin"
      hash -r 2>/dev/null || true
      service_restart || true
    fi
    rm -rf "$wd"
    return 1
  fi

  rm -rf "$wd"
  service_restart || return 1
  ok "更新并重启完成。"
}

refresh_ip_wizard() {
  need_state
  step "刷新公网 IP"

  local current_ver current_ip choice new_ip new_ver

  current_ver="$(state_get '.ip_version // "ipv4"')"
  current_ip="$(state_get '.server_ip')"

  info "当前 IP 版本: ${current_ver}"
  info "当前 IP: ${current_ip}"
  echo
  echo "1) 切换到 IPv4 并重新检测"
  echo "2) 切换到 IPv6 并重新检测"
  echo "0) 返回"
  read -rp "请选择: " choice

  case "$choice" in
    1) new_ver="ipv4"; new_ip="$(detect_public_ip 4)" || new_ip="" ;;
    2) new_ver="ipv6"; new_ip="$(detect_public_ip 6)" || new_ip="" ;;
    0) return "$CANCEL_RC" ;;
    *) warn "输入错误"; return 1 ;;
  esac

  if [ -z "$new_ip" ]; then
    die "未能获取到有效的公网 ${new_ver} 地址（该机器可能没有 ${new_ver} 公网出口），状态未改动。"
  fi

  state_build --arg ver "$new_ver" --arg ip "$new_ip" '.ip_version = $ver | .server_ip = $ip'
  apply_state
  ok "已更新公网 IP 为 ${new_ip} (${new_ver})。"
}

# -------------------------
# 初始节点（安装流程）
# -------------------------
choose_initial_nodes() {
  step "配置初始节点"

  local vport="" tport="" vc tc

  if [ -n "$CLI_VLESS" ]; then
    vport="$CLI_VLESS"
    while true; do
      if [ "$vport" = "0" ]; then
        info "已指定 vless=0，跳过安装 VLESS 直出节点。"
        break
      fi
      if valid_port "$vport"; then
        vport=$((10#$vport))
        info "使用参数指定 VLESS 端口: ${vport}"
        prepare_add_node "vless-direct" "$vport" "direct"
        commit_state_plain
        break
      fi
      warn "VLESS 端口 ${vport} 无效（范围 1-65535，输入 0 取消）："
      read -rp "请重新输入 VLESS 端口: " vport
      vport="$(trim "$vport")"
    done
  else
    echo "是否创建 VLESS 直出节点？"
    echo "1) 创建 (默认端口 ${VLESS_DIRECT_PORT})"
    echo "2) 跳过"
    read -rp "请选择 [默认 1]: " vc
    vc="${vc:-1}"
    if [ "$vc" = "1" ]; then
      vport="$(ask_port "请输入 VLESS 直出 TCP 端口" "$VLESS_DIRECT_PORT")"
      prepare_add_node "vless-direct" "$vport" "direct"
      commit_state_plain
    fi
  fi

  if [ -n "$CLI_TUIC" ]; then
    tport="$CLI_TUIC"
    while true; do
      if [ "$tport" = "0" ]; then
        info "已指定 tuic=0，跳过安装 TUIC 直出节点。"
        break
      fi
      if valid_port "$tport"; then
        tport=$((10#$tport))
        info "使用参数指定 TUIC 端口: ${tport}"
        prepare_add_node "tuic-direct" "$tport" "direct"
        commit_state_plain
        break
      fi
      warn "TUIC 端口 ${tport} 无效（范围 1-65535，输入 0 取消）："
      read -rp "请重新输入 TUIC 端口: " tport
      tport="$(trim "$tport")"
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
      prepare_add_node "tuic-direct" "$tport" "direct"
      commit_state_plain
    fi
  fi
}

# -------------------------
# 渲染：配置 / 信息 / YAML
#   这些函数失败时 return 1（不 die），由上层决定是否回滚
# -------------------------
render_config() {
  local tmp

  [ -f "$STATE_FILE" ] || { err "未找到状态文件：$STATE_FILE"; return 1; }
  info "生成 sing-box 配置..."

  tmp="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || { err "无法创建临时配置文件。"; return 1; }

  if ! jq '
    . as $s |

    def landing($n):
      first($s.landings[]? | select(.id == ($n.landing_id // "")))
      // error("节点 [" + ($n.name // $n.tag) + "] 引用的落地节点不存在 (landing_id=" + ($n.landing_id // "") + ")");

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
      landing($n) as $l |
    {
      "type": "vless",
      "tag": ("out-" + $n.tag),
      "server": $l.server,
      "server_port": ($l.port | tonumber),
      "uuid": ($l.uuid // $s.uuid),
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": ($l.sni // $s.reality_sni),
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": ($l.public_key // $s.public_key),
          "short_id": ($l.short_id // $s.short_id)
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
          }
        ]
        +
        [
          $s.nodes[]? |
          select(.outbound_type == "landing") |
          landing_out(.)
        ]
      ),
      "route": {
        "rules": (
          (if (($s.blocked_domains // []) | length) > 0 then
            [
              {
                "domain_suffix": $s.blocked_domains,
                "action": "reject"
              }
            ]
          else [] end)
          +
          [
            $s.nodes[]? |
            {
              "inbound": [
                .tag
              ],
              "action": "route",
              "outbound": (if .outbound_type == "landing" then ("out-" + .tag) else "direct" end)
            }
          ]
        ),
        "final": "direct"
      }
    }
  ' "$STATE_FILE" > "$tmp"; then
    rm -f "$tmp"
    err "生成配置失败（jq 报错，见上方信息）。"
    return 1
  fi

  chown sing-box:sing-box "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"

  # 先检查临时文件，通过后再原子替换正在使用的配置
  if ! sing-box check -c "$tmp"; then
    rm -f "$tmp"
    err "sing-box check 未通过，未替换现有配置。"
    return 1
  fi

  if ! mv -f "$tmp" "$CONFIG_FILE"; then
    rm -f "$tmp"
    err "替换配置文件失败。"
    return 1
  fi

  ok "配置检查通过：$CONFIG_FILE"
  return 0
}

render_info() {
  [ -f "$STATE_FILE" ] || return 1

  local uuid private_key public_key short_id tuic_pass reality_sni tuic_sni server_ip flag loc
  local ip_version server_ip_display type tag name port protocol encoded_name link outbound_type
  local landing_disp landing_port

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
    chmod 600 "$INFO_FILE"
    return 0
  fi

  while IFS=$'\t' read -r type tag name port protocol outbound_type landing_disp landing_port; do
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
        echo "落地出口: ${landing_disp} (端口: ${landing_port})"
      fi
      echo "------------------------------"
      echo "$link"
      echo
    } >> "$INFO_FILE"
  done < <(jq -r '. as $s | .nodes[]? | . as $n
    | (first($s.landings[]? | select(.id == ($n.landing_id // ""))) // {}) as $l
    | [$n.type, $n.tag, $n.name, ($n.port | tostring), ($n.protocol // "tcp"),
       ($n.outbound_type // "direct"), ($l.display // "-"), (($l.port // "-") | tostring)] | @tsv' "$STATE_FILE")

  chmod 600 "$INFO_FILE"
  return 0
}

render_yaml() {
  [ -f "$STATE_FILE" ] || return 1

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

  while IFS=$'\t' read -r type name port; do
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
  done < <(jq -r '.nodes[]? | [.type, .name, (.port | tostring)] | @tsv' "$STATE_FILE")

  cat >> "$YAML_FILE" <<YAML

proxy-groups:
  - name: PROXY
    type: select
    proxies:
YAML

  while IFS= read -r name; do
    printf '      - %s\n' "$(yaml_quote "$name")" >> "$YAML_FILE"
  done < <(jq -r '.nodes[]?.name' "$STATE_FILE")

  cat >> "$YAML_FILE" <<YAML
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
YAML

  chmod 600 "$YAML_FILE"
  return 0
}

# 规范化 state -> 证书 -> 配置(临时文件 + check + mv)；yaml / info 失败不阻断
render_all() {
  ensure_state_defaults || return 1
  ensure_tuic_cert || return 1
  render_config || return 1
  render_yaml || warn "生成 Clash YAML 失败（不影响 sing-box 运行）。"
  render_info || warn "生成节点信息文件失败（不影响 sing-box 运行）。"
  return 0
}

restart_singbox() {
  step "重启 sing-box"
  service_enable
  if service_restart; then
    ok "sing-box 已重启。"
    return 0
  fi
  return 1
}

restart_and_status() {
  restart_singbox || return 1
  service_status
}

# -------------------------
# 展示
# -------------------------
list_nodes_table() {
  need_state

  local count idx name type protocol port outbound_type landing

  count="$(jq '.nodes | length' "$STATE_FILE")"

  if [ "$count" -eq 0 ]; then
    warn "当前没有节点。"
    return 0
  fi

  printf "%-4s %-28s %-6s %-8s %-20s %s\n" "序号" "节点名" "协议" "端口" "类型" "落地 (国家：ip)"
  printf "%-4s %-28s %-6s %-8s %-20s %s\n" "----" "----------------------------" "------" "------" "--------------------" "--------------------"

  while IFS=$'\t' read -r idx name type protocol port outbound_type landing; do
    printf "%-4s %-28s %-6s %-8s %-20s %s\n" \
      "$idx" "$name" "${protocol^^}" "$port" "$(node_type_name "$type" "$outbound_type")" "$landing"
  done < <(jq -r '. as $s | .nodes | to_entries[] | .value as $n
    | [(.key + 1), $n.name, $n.type, ($n.protocol // "tcp"), ($n.port | tostring),
       ($n.outbound_type // "direct"),
       (if ($n.outbound_type // "direct") == "landing"
        then ((first($s.landings[]? | select(.id == ($n.landing_id // ""))) | .display) // "(落地已丢失)")
        else "-" end)] | @tsv' "$STATE_FILE")

  return 0
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
    return 0
  fi
  ss -lntup 2>/dev/null | grep sing-box || true
}

show_info() {
  if [ -f "$INFO_FILE" ]; then
    cat "$INFO_FILE"
  else
    warn "未找到 $INFO_FILE"
  fi
}

show_yaml() {
  if [ -f "$YAML_FILE" ]; then
    cat "$YAML_FILE"
  else
    warn "未找到 $YAML_FILE"
  fi
}

show_status() {
  step "sing-box 状态"
  service_status
  echo
  echo "当前节点列表："
  list_nodes_table || true
  echo
  echo "当前端口监听："
  show_ports
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
  if [ -f "$0" ] && ! [ "$0" -ef "$INSTALLER_FILE" ]; then
    cp "$0" "$INSTALLER_FILE" 2>/dev/null || true
  fi
  chmod +x "$INSTALLER_FILE" 2>/dev/null || true
}

uninstall_all() {
  step "彻底删除"

  local confirm

  read -rp "确认彻底卸载 sing-box 及配置？输入 y 确认: " confirm
  if [ "${confirm,,}" != "y" ]; then
    warn "已取消。"
    return "$CANCEL_RC"
  fi

  service_stop
  service_disable
  pkg_remove_singbox

  rm -f /usr/local/bin/sing-box /usr/bin/sing-box
  rm -f /etc/systemd/system/sing-box.service
  rm -f /etc/init.d/sing-box
  rm -rf /etc/sing-box /var/lib/sing-box /var/log/sing-box
  rm -f "$INFO_FILE" "$YAML_FILE" "$PANEL_FILE" "$INSTALLER_FILE"

  service_daemon_reload
  ok "已彻底删除。"
  exit "$EXIT_PANEL_RC"
}

# -------------------------
# 面板：每个操作都在子 shell 里跑，die / exit 只会中止当前操作
# -------------------------
run_action() {
  local rc=0

  set +e
  ( set -e; "$@" )
  rc=$?
  set -e

  cleanup_tmp

  case "$rc" in
    0|"$CANCEL_RC") ;;
    "$EXIT_PANEL_RC") exit 0 ;;
    *) warn "操作未完成，已返回菜单。" ;;
  esac

  return "$rc"
}

# 运行一个操作，结束后暂停（用户主动取消时不暂停）。pause 统一放在这里，各向导函数内部不再 pause
act() {
  local rc=0
  run_action "$@" || rc=$?
  if [ "$rc" -ne "$CANCEL_RC" ]; then
    pause
  fi
  return 0
}

panel_menu() {
  need_root
  need_state
  ensure_state_defaults || die "状态文件规范化失败，请检查 ${STATE_FILE}。"

  local choice

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
      1) act show_info ;;
      2) act show_yaml ;;
      3) act show_status ;;
      4) act add_node_wizard ;;
      5) landing_pool_menu ;;
      6) act delete_node_wizard ;;
      7) act modify_node_wizard ;;
      8) block_website_menu ;;
      9) act update_core_wizard ;;
      10) act restart_and_status ;;
      11) act refresh_ip_wizard ;;
      12) act uninstall_all ;;
      0) exit 0 ;;
      *) warn "输入错误。" ;;
    esac
  done
}

install_wizard() {
  need_root

  local existing_choice

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
  elif [ -f "$STATE_FILE" ]; then
    warn "检测到已有安装状态，按命令行参数覆盖重装。"
  fi

  install_deps
  install_singbox
  ensure_dirs

  # 覆盖重装前备份旧 state，渲染失败时可恢复
  local prev="${STATE_FILE}.prev"
  if [ -f "$STATE_FILE" ]; then
    cp -p "$STATE_FILE" "$prev"
  fi

  create_state_file
  choose_initial_nodes

  if ! render_all; then
    if [ -f "$prev" ]; then
      mv -f "$prev" "$STATE_FILE"
      warn "已恢复安装前的状态文件。"
    fi
    die "配置生成失败，安装中止。"
  fi

  if ! restart_singbox; then
    if [ -f "$prev" ]; then
      mv -f "$prev" "$STATE_FILE"
      warn "已恢复安装前的状态文件（配置文件需用 ysq render 重新生成）。"
    fi
    die "sing-box 启动失败，请根据上方日志排查。"
  fi

  rm -f "$prev"
  save_self
  install_panel_wrapper
  print_summary
}

# -------------------------
# 入口
# -------------------------
main() {
  detect_runtime

  case "$ACTION" in
    install)
      install_wizard
      ;;
    panel)
      panel_menu
      ;;
    render)
      need_root
      need_state
      render_all || die "配置生成失败，现有配置未被修改。"
      restart_singbox || die "sing-box 重启失败。"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main
