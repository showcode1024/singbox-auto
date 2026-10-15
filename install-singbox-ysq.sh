#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ysq sing-box 一键安装 / 管理脚本
# 支持：
#   - VLESS Reality 直出 / 中转
#   - TUIC v5 直出 / 中转
#   - TCP / UDP 端口支持复用（同端口可分别运行 VLESS 和 TUIC）
#   - 独立落地节点池（查看 / 添加 / 修改 IP 端口 / 删除，显示为“国家：ip”）
#   - 命令行安装参数（vless=端口 tuic=端口 -y）：无参数只装 sing-box 不建节点；-y 静默使用预设密钥
#   - 卸载可选「彻底删除」或「保留节点数据」；安装时发现有效的 ysq-state.db 会直接沿用，不覆盖
#   - 面板内一键「更新面板」（从 GitHub 下载新脚本，保留全部数据）
#   - 面板随时添加 / 删除 / 修改节点端口及落地出口
#   - 屏蔽指定网站管理（支持批量添加与批量删除，自动启用 sniff 保证规则生效）
#   - 支持 IPv4 / IPv6 入口地址选择与纯 IPv6 环境（地区检测多源 + 手动兜底）
#   - 节点入站端口要求 10000 及以上（落地节点的远端端口不受此限制）
#   - 支持 Debian / Ubuntu / CentOS / Rocky / AlmaLinux / Alpine
#
# 设计要点：
#   - 落地信息只保存在落地池 (.landings)，节点只通过 landing_id 引用
#   - 所有修改先写临时文件；配置通过 sing-box check 后才替换；失败自动回滚 state
#   - 面板里每个操作都在子 shell 中运行，die 只会中止当前操作，不会退出面板
#   - 节点管理与落地管理解耦：落地的增删改只在「落地节点池管理」里做，节点只能选择已有落地
#   - Alpine(OpenRC)：日志写入单个文件，busybox cron 每小时检查，达 9MB 裁剪、保留最后 2MB
# ============================================================

YSQ_VERSION="2026.10.15"
INSTALLER_NAME="install-singbox-ysq.sh"
DEFAULT_SCRIPT_URL="https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh"

# -------------------------
# 默认端口
# -------------------------
# 节点（入站）端口下限：低于该值一律拒绝（同时也避开了 1024 以下需要特权的端口）
MIN_NODE_PORT=10000
VLESS_DIRECT_PORT=20001
TUIC_DIRECT_PORT=20002
VLESS_RELAY_PORT=20003
TUIC_RELAY_PORT=20004

# -------------------------
# 预设默认参数（命令行加 -y，或交互时选择“使用默认参数”时使用）
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
LOG_DIR="/var/log/sing-box"
LOG_FILE="/var/log/sing-box/sing-box.log"
# 日志裁剪（仅 OpenRC / Alpine 使用 busybox cron；systemd 的日志由 journald 管理）
LOG_TRIM_MAX_MB=9      # 日志文件达到 9MB 时触发裁剪
LOG_TRIM_KEEP_MB=2     # 裁剪后保留最后 2MB
LOG_TRIM_SCRIPT="/etc/periodic/hourly/ysq-singbox-log-trim"
INFO_FILE="/root/singbox-node-info.txt"
YAML_FILE="/root/singbox-nodes.yaml"
PANEL_FILE="/usr/local/bin/ysq"
INSTALLER_FILE="/root/install-singbox-ysq.sh"

# 约定：操作函数返回 3 表示“用户主动取消”，不提示失败、不暂停
CANCEL_RC=3
# 约定：卸载完成后返回 99，让面板整体退出
EXIT_PANEL_RC=99
# 约定：更新面板完成后返回 98，由主 shell 用 exec 原地换成新面板（不留下嵌套的旧面板进程）
RESTART_PANEL_RC=98
# ysq 快捷命令是否安装成功（save_self 成功才会置 1）
PANEL_READY=0

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

# 安装流程里为“覆盖状态文件前”留的备份；安装成功会删除它，退出时它还在就说明安装中途失败，
# 此时把状态恢复到安装前，并且不留下 .prev 残留
INSTALL_PREV_FILE=""

cleanup_tmp() {
  if [ -n "$INSTALL_PREV_FILE" ] && [ -f "$INSTALL_PREV_FILE" ]; then
    mv -f "$INSTALL_PREV_FILE" "$STATE_FILE" 2>/dev/null || true
  fi
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
CLI_YES=""
ACTION=""

usage() {
  cat <<EOF
用法：
  bash ${INSTALLER_NAME}                                   # 只安装 sing-box，不创建任何节点（会询问是否全新生成 UUID / 密钥）
  bash ${INSTALLER_NAME} vless=41454 tuic=41454            # 安装并创建节点（端口 ${MIN_NODE_PORT}-65535，0 表示不创建），仍会询问密钥
  bash ${INSTALLER_NAME} vless=41454 tuic=41454 -y         # 静默：使用预设 UUID / Reality 密钥 / SNI，不提任何问题
  bash ${INSTALLER_NAME} panel                             # 打开管理面板
  bash ${INSTALLER_NAME} render                            # 重新生成配置并重启
  bash ${INSTALLER_NAME} upgrade                           # 应用新版脚本（刷新服务 / 重新渲染 / 重启，保留数据）

说明：
  - 已存在有效的 ${STATE_FILE} 时直接沿用其中的 UUID / 密钥 / 节点，不会覆盖。
  - 节点端口必须 >= ${MIN_NODE_PORT}，低于该值会直接报错退出。
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
    -y|--yes) CLI_YES="1" ;;
    panel|render|install|upgrade) set_action "$arg" ;;
    -h|--help|help) usage; exit 0 ;;
    *)
      err "未知参数：${arg}"
      case "$arg" in
        vless|tuic) warn "参数格式应为 ${arg}=值，例如 ${arg}=41454（等号两边不要有空格）。" ;;
      esac
      usage >&2
      exit 1
      ;;
  esac
done

ACTION="${ACTION:-install}"

# 显式写了 vless= / tuic= 但值为空
for arg in "$@"; do
  case "$arg" in
    vless=|tuic=)
      err "参数 ${arg} 的值不能为空。"
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$ACTION" != "install" ] && { [ -n "$CLI_VLESS" ] || [ -n "$CLI_TUIC" ] || [ -n "$CLI_YES" ]; }; then
  err "vless= / tuic= / -y 只能用于安装模式。"
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

# sing-box 是否由系统包管理器（apt / dnf / yum）安装。
# Alpine 的 .apk 是从 GitHub 下载后安装的，apk upgrade 取不到新版，仍走原来的下载安装流程。
pkg_managed_singbox() {
  case "$PKG_MANAGER" in
    apt)     dpkg-query -W -f='${Status}' sing-box 2>/dev/null | grep -q 'install ok installed' ;;
    dnf|yum) rpm -q sing-box >/dev/null 2>&1 ;;
    *)       return 1 ;;
  esac
}

# 用包管理器升级 / 重装 sing-box。$1: upgrade | reinstall
# 不能先删二进制再跑官方 install.sh：包管理器认为包仍是已安装状态，install 什么都不会做。
pkg_upgrade_singbox() {
  local mode="${1:-upgrade}"

  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update || warn "apt-get update 失败，继续尝试。"
      if [ "$mode" = "reinstall" ]; then
        apt-get install -y --reinstall sing-box
      else
        apt-get install -y --only-upgrade sing-box
      fi
      ;;
    dnf|yum)
      "$PKG_MANAGER" makecache -y || true
      if [ "$mode" = "reinstall" ]; then
        "$PKG_MANAGER" reinstall -y sing-box
      else
        "$PKG_MANAGER" upgrade -y sing-box
      fi
      ;;
    *)
      die "当前系统的 sing-box 不是由包管理器安装的。"
      ;;
  esac

  hash -r 2>/dev/null || true
  singbox_bin_works "$(command -v sing-box 2>/dev/null || true)" || die "升级后的 sing-box 无法运行。"
  ensure_singbox_service
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

# 生成日志裁剪脚本：文件 >= MAX 字节时只保留最后 KEEP 字节
write_log_trim_script() {
  local dest="$1"
  local max_bytes=$((LOG_TRIM_MAX_MB * 1024 * 1024))
  local keep_bytes=$((LOG_TRIM_KEEP_MB * 1024 * 1024))

  cat > "$dest" <<'TRIM'
#!/bin/sh
# ysq: sing-box 日志裁剪。由 install-singbox-ysq.sh 生成，重新安装 / 升级时会被覆盖。
# 日志文件达到 MAX 字节时，只保留最后 KEEP 字节。
LOG="@LOG@"
MAX=@MAX@
KEEP=@KEEP@

[ -f "$LOG" ] || exit 0
size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
[ "${size:-0}" -ge "$MAX" ] || exit 0

tmp="${LOG}.trim.$$"
# 取最后 KEEP 字节；开头那一行大概率被截断，丢掉它
if tail -c "$KEEP" "$LOG" | sed '1d' > "$tmp"; then
  # 原地覆盖，不能 mv：sing-box 以追加模式持有这个文件，inode 不能换
  cat "$tmp" > "$LOG"
fi
rm -f "$tmp"
TRIM
  sed -i -e "s|@LOG@|${LOG_FILE}|" -e "s|@MAX@|${max_bytes}|" -e "s|@KEEP@|${keep_bytes}|" "$dest"
  chmod 755 "$dest"
}

# OpenRC(Alpine)：安装 busybox cron 的每小时裁剪任务，并确保 crond 已启用
install_log_trim() {
  [ "$SERVICE_MANAGER" = "openrc" ] || return 0

  local wd

  mkdir -p /etc/periodic/hourly
  wd="$(new_work_dir)"
  write_log_trim_script "$wd/trim"
  install_if_changed "$wd/trim" "$LOG_TRIM_SCRIPT" 755 || true
  rm -rf "$wd"

  # 旧版本留下的 .err 日志不再使用
  rm -f "${LOG_DIR}/sing-box.err"

  # busybox crond 靠 root 的 crontab 调用 run-parts；缺了就补上
  mkdir -p /etc/crontabs
  if [ ! -f /etc/crontabs/root ]; then
    : > /etc/crontabs/root
    chmod 600 /etc/crontabs/root
  fi
  if ! grep -q 'periodic/hourly' /etc/crontabs/root 2>/dev/null; then
    echo '0 * * * * run-parts /etc/periodic/hourly' >> /etc/crontabs/root
  fi

  if [ -x /etc/init.d/crond ]; then
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond status >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
  else
    warn "未找到 crond 服务，sing-box 日志不会自动裁剪（可手动 apk add busybox-openrc 后重试）。"
  fi
}

remove_log_trim() {
  rm -f "$LOG_TRIM_SCRIPT"
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
ExecStart=${SING_BOX_BIN} -D /var/lib/sing-box -c /etc/sing-box/config.json run
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
command_args="-D /var/lib/sing-box -c /etc/sing-box/config.json run"
command_user="sing-box:sing-box"
command_background="yes"
pidfile="/run/sing-box.pid"
# stdout 与 stderr 都追加（O_APPEND）写入同一个文件，方便 cron 原地裁剪
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

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
      install_log_trim
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
        local old_pid i
        old_pid="$(cat /run/sing-box.pid 2>/dev/null || true)"
        if [ -n "$old_pid" ]; then
          kill "$old_pid" 2>/dev/null || true
          # 等旧进程真正退出（最多 15 秒），否则重启时新进程可能和旧进程抢端口
          for i in $(seq 1 15); do
            kill -0 "$old_pid" 2>/dev/null || break
            sleep 1
          done
          kill -0 "$old_pid" 2>/dev/null && kill -9 "$old_pid" 2>/dev/null || true
        fi
        rm -f /run/sing-box.pid
      fi
      pkill -f "sing-box.*-[cC] /etc/sing-box.*run" 2>/dev/null || true
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
        tail -n 20 "$LOG_FILE" 2>/dev/null >&2 || true
        return 1
      fi
      sleep 1
      if ! rc-service sing-box status >/dev/null 2>&1; then
        err "sing-box 启动后异常退出。"
        tail -n 20 "$LOG_FILE" 2>/dev/null >&2 || true
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
      # 没有 cron 可用：每次启动前（进程已停）顺手裁剪一次，并用追加模式写日志
      local trim_wd
      trim_wd="$(new_work_dir)"
      write_log_trim_script "$trim_wd/trim"
      sh "$trim_wd/trim" || true
      rm -rf "$trim_wd"
      nohup "$SING_BOX_BIN" -D /var/lib/sing-box -c /etc/sing-box/config.json run >> "$LOG_FILE" 2>&1 &
      echo $! > /run/sing-box.pid
      sleep 1
      if ! kill -0 "$(cat /run/sing-box.pid)" 2>/dev/null; then
        tail -n 20 "$LOG_FILE" >&2 || true
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
      tail -n 80 "$LOG_FILE" 2>/dev/null || true
      ;;
    none)
      if [ -f /run/sing-box.pid ] && kill -0 "$(cat /run/sing-box.pid)" 2>/dev/null; then
        ok "sing-box 正在运行，PID: $(cat /run/sing-box.pid)"
      else
        warn "sing-box 未运行。"
      fi
      echo
      tail -n 80 "$LOG_FILE" 2>/dev/null || true
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
# 状态栏辅助函数（运行状态 / 版本 / 内存）
# -------------------------
is_singbox_running() {
  case "$SERVICE_MANAGER" in
    systemd) systemctl is-active --quiet sing-box 2>/dev/null ;;
    openrc)  rc-service sing-box status >/dev/null 2>&1 ;;
    none)    [ -f /run/sing-box.pid ] && kill -0 "$(cat /run/sing-box.pid 2>/dev/null)" 2>/dev/null ;;
  esac
}

get_singbox_pid() {
  local pid=""
  case "$SERVICE_MANAGER" in
    systemd)
      pid="$(systemctl show -p MainPID --value sing-box 2>/dev/null || true)"
      [ "$pid" = "0" ] && pid=""
      ;;
    openrc|none)
      if [ -f /run/sing-box.pid ]; then
        pid="$(cat /run/sing-box.pid 2>/dev/null || true)"
      fi
      ;;
  esac

  if [ -z "$pid" ] && command -v pidof >/dev/null 2>&1; then
    pid="$(pidof sing-box 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [ -z "$pid" ] && command -v pgrep >/dev/null 2>&1; then
    pid="$(pgrep -f "sing-box.*-[cC] /etc/sing-box.*run" 2>/dev/null | head -n 1 || true)"
  fi
  echo "$pid"
}

get_singbox_memory() {
  local pid rss_kb=""
  pid="$(get_singbox_pid)"
  if [ -z "$pid" ]; then
    echo "-"
    return 0
  fi

  if [ -r "/proc/${pid}/status" ]; then
    rss_kb="$(awk '/^VmRSS:/ {print $2}' "/proc/${pid}/status" 2>/dev/null || true)"
  fi
  if [ -z "$rss_kb" ] && command -v ps >/dev/null 2>&1; then
    rss_kb="$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
  fi

  if [[ "$rss_kb" =~ ^[0-9]+$ ]] && [ "$rss_kb" -gt 0 ]; then
    awk -v kb="$rss_kb" 'BEGIN { printf "%.1f MB", kb / 1024 }'
  else
    echo "-"
  fi
}

print_status_bar() {
  local status_str ver_str mem_str
  if command -v sing-box >/dev/null 2>&1; then
    ver_str="$(sing-box version 2>/dev/null | awk 'NR==1 {print $3}' || true)"
    ver_str="${ver_str:+v${ver_str#v}}"
    ver_str="${ver_str:-未知}"
  else
    ver_str="未安装"
  fi

  if is_singbox_running; then
    status_str="${C_GREEN}● 运行中${C_RESET}"
    mem_str="$(get_singbox_memory)"
  else
    status_str="${C_RED}○ 未运行${C_RESET}"
    mem_str="-"
  fi

  echo -e "运行状态: ${status_str}  |  版本: ${C_BLUE}${ver_str}${C_RESET}  |  内存占用: ${C_YELLOW}${mem_str}${C_RESET}"
}

# -------------------------
# 终端表格：按「显示宽度」补空格（中文 / 全角符号 / emoji 占 2 列，国旗按一对区域指示符合计 2 列，
# 零宽连接符与变体选择符占 0 列）。区间采用 Unicode East Asian Wide / Fullwidth 的主要范围。
# 注意：这是 jq 程序片段，会被拼接到各个表格的 jq 程序前面。
# -------------------------
JQ_TABLE_LIB='
def dwidth:
  [ explode[] | . as $c |
    if $c == 8205 or $c == 65039 or ($c >= 768 and $c <= 879) then 0
    elif $c >= 127462 and $c <= 127487 then 1
    elif ($c >= 4352 and $c <= 4447)
      or ($c >= 11904 and $c <= 42191)
      or ($c >= 44032 and $c <= 55203)
      or ($c >= 63744 and $c <= 64255)
      or ($c >= 65040 and $c <= 65049)
      or ($c >= 65072 and $c <= 65135)
      or ($c >= 65281 and $c <= 65376)
      or ($c >= 65504 and $c <= 65510)
      or ($c >= 126976 and $c <= 129791)
      or ($c >= 131072 and $c <= 262141) then 2
    else 1 end
  ] | add // 0;

def pad($w):
  tostring as $s |
  ($w - ($s | dwidth)) as $p |
  $s + ([range(0; if $p > 0 then $p else 0 end) | " "] | join(""));

def dash($w):
  [range(0; $w) | "-"] | join("");
'

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

# 通用端口范围 1-65535（用于落地节点的远端端口）
valid_port() {
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] || return 1
  [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

# 节点（入站）端口：MIN_NODE_PORT-65535
valid_node_port() {
  valid_port "${1:-}" && [ "$((10#$1))" -ge "$MIN_NODE_PORT" ]
}

# 读一行输入；stdin 已关闭（EOF）时直接中止当前操作，避免 set -e 下静默退出
read_line() {
  local __prompt="$1" __var="$2"
  # shellcheck disable=SC2229
  IFS= read -rp "$__prompt" "$__var" || die "无法读取输入（标准输入已关闭），请在交互终端中运行。"
}

# 用法：ask_port <提示> <默认值> [allow_zero=false] [最小端口=1]
#   节点入站端口传 "$MIN_NODE_PORT"；落地节点远端端口用默认下限 1
ask_port() {
  local name="$1"
  local default_port="$2"
  local allow_zero="${3:-false}"
  local min_port="${4:-1}"
  local input_port=""

  while true; do
    read_line "$name [默认 ${default_port}]: " input_port
    input_port="$(trim "$input_port")"

    if [ -z "$input_port" ]; then
      echo "$default_port"
      return
    fi

    if [ "$allow_zero" = "true" ] && [ "$input_port" = "0" ]; then
      echo "0"
      return
    fi

    if valid_port "$input_port" && [ "$((10#$input_port))" -ge "$min_port" ]; then
      echo "$((10#$input_port))"
      return
    fi
    warn "端口输入错误，请输入 ${min_port}-65535 之间的数字。"
  done
}

# 节点入站端口输入（>= MIN_NODE_PORT）
ask_node_port() {
  ask_port "$1" "$2" "${3:-false}" "$MIN_NODE_PORT"
}

ask_text_default() {
  local prompt="$1"
  local default_value="$2"
  local input=""

  if [ -n "$default_value" ]; then
    read_line "$prompt [默认 ${default_value}]: " input
    input="$(trim "$input")"
    echo "${input:-$default_value}"
  else
    while true; do
      read_line "$prompt: " input
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

# 列出占用指定端口的监听行（TCP / UDP 分别查）。
# 只比较「本地地址:端口」整段最后一个冒号之后的端口号，且必须整数相等：
#   - 2000 不会误匹配 20001 / 12000
#   - 不会被 IPv6 地址里的片段（如 [::1]:80 里的 :1）或远端端口、PID 数字误伤
#   - 兼容 *:443 / 0.0.0.0:443 / [::]:443 / 127.0.0.53%lo:53
port_listen_lines() {
  local port="$1"
  local proto="${2:-tcp}"
  local ss_arg="-tlnp"

  [ "$proto" = "udp" ] && ss_arg="-ulnp"
  command -v ss >/dev/null 2>&1 || return 0

  ss "$ss_arg" 2>/dev/null | awk -v p="$port" '
    NR > 1 && NF >= 4 {
      loc = $4
      sub(/^.*:/, "", loc)
      if (loc ~ /^[0-9]+$/ && (loc + 0) == (p + 0)) print $0
    }'
}

# 检查端口是否可用。返回：0 可用 / CANCEL_RC 用户选择放弃 / 脚本内冲突时 die
#   - 脚本内其他节点已用同协议同端口：直接拒绝
#   - 系统里被「非 sing-box」进程监听：提示并让用户确认
#   - 仅被 sing-box 自己监听（覆盖重装 / 旧配置残留）：视为可用，重启后由新配置接管
check_port_available() {
  local port="$1"
  local proto="${2:-tcp}"
  local ignore_tag="${3:-}"
  local confirm="" lines="" foreign=""

  if port_used "$port" "$proto" "$ignore_tag"; then
    die "端口 ${port} (${proto^^}) 已经被当前脚本里的其他节点使用，请换一个端口。"
  fi

  lines="$(port_listen_lines "$port" "$proto")"
  [ -n "$lines" ] || return 0

  foreign="$(printf '%s\n' "$lines" | grep -v 'users:(("sing-box"' || true)"
  if [ -z "$foreign" ]; then
    info "端口 ${port} (${proto^^}) 当前由 sing-box 自身监听（旧配置），将在重启后由新配置接管。"
    return 0
  fi

  warn "检测到系统里已有其他程序在 ${proto^^} 监听 ${port}："
  printf '%s\n' "$foreign" >&2
  read_line "仍然继续使用这个端口？输入 y 继续: " confirm
  if [ "${confirm,,}" != "y" ]; then
    warn "已取消。"
    return "$CANCEL_RC"
  fi
  return 0
}

# 主机名 / IP 合法性（只允许字母数字与 . : - _，且不能以 - 开头）
valid_host() {
  local h="${1:-}"
  [ -n "$h" ] && [ "${#h}" -le 253 ] || return 1
  [[ "$h" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
  [[ "$h" != -* ]] || return 1
  return 0
}

# TCP 连通性测试（支持 IPv4 / IPv6 / 域名）；host / port 全部以参数传递，绝不拼进命令字符串
test_tcp_connect() {
  local host="$1"
  local port="$2"
  local timeout_sec="${3:-5}"
  local url_host="" conn_time=""

  host="${host#[}"
  host="${host%]}"

  valid_host "$host" || return 1
  valid_port "$port" || return 1

  if is_ipv6 "$host"; then
    url_host="[${host}]"
  else
    url_host="$host"
  fi

  # 三种方式做的是同一件事（TCP 握手），所以只用一种，并把它的结果当作最终结果：
  # 连接失败 / 超时就是失败，绝不再换下一种重试（否则丢包目标会串联等 3 × 超时）。
  # 只有「这个工具本身不可用」才换下一种。最坏耗时 ≈ timeout_sec。
  local err="" rc=0

  # 1. bash 内建 /dev/tcp（host/port 作为位置参数传入）
  if command -v timeout >/dev/null 2>&1; then
    err="$(timeout "$timeout_sec" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>&1)" && return 0
    # bash 编译时没带 /dev/tcp 支持：报 No such file or directory，才换下一种；否则（超时 124 / 被拒绝）直接判失败
    case "$err" in
      *"No such file or directory"*|*"not supported"*) ;;
      *) return 1 ;;
    esac
  fi

  # 2. nc（-w 是连接超时）；只有 nc 不认 -z / -w 参数时才换 curl
  if command -v nc >/dev/null 2>&1; then
    err="$(nc -z -w "$timeout_sec" "$host" "$port" 2>&1)" && return 0
    case "$err" in
      *[Uu]sage*|*"invalid option"*|*"unrecognized option"*|*"illegal option"*) ;;
      *) return 1 ;;
    esac
  fi

  # 3. curl：time_connect > 0 代表 TCP 三次握手成功
  conn_time="$(curl -s -o /dev/null -w '%{time_connect}' --connect-timeout "$timeout_sec" --max-time "$timeout_sec" "http://${url_host}:${port}" 2>/dev/null || true)"
  if [ -n "$conn_time" ] && awk -v t="$conn_time" 'BEGIN { exit((t + 0 > 0) ? 0 : 1) }' 2>/dev/null; then
    return 0
  fi

  return 1
}

# 落地节点 TCP 预检。通过返回 0；失败时让用户决定是否仍保存，放弃则返回 CANCEL_RC
check_landing_connectivity() {
  local server="$1"
  local port="$2"
  local confirm=""

  info "正在预检落地节点 TCP 连通性 (${server}:${port})..."
  if test_tcp_connect "$server" "$port" 5; then
    ok "落地节点 TCP 连通性检测通过 (${server}:${port})。"
    return 0
  fi

  warn "无法连接到落地节点 ${server}:${port}（TCP 连接超时、被拒绝或防火墙未放行）。"
  read_line "是否仍然继续保存该落地节点？输入 y 继续: " confirm
  if [ "${confirm,,}" != "y" ]; then
    warn "已取消保存落地节点。"
    return "$CANCEL_RC"
  fi
  return 0
}

# 输入落地 IP / 域名（带格式校验，去掉 IPv6 方括号）
ask_landing_host() {
  local prompt="$1" default_value="${2:-}" h=""
  while true; do
    h="$(ask_text_default "$prompt" "$default_value")"
    h="${h#[}"
    h="${h%]}"
    if valid_host "$h"; then
      echo "$h"
      return 0
    fi
    warn "地址格式无效：只允许 IP 或域名（字母、数字、点、冒号、连字符）。"
  done
}

# SNI（TLS server_name）合法性：只允许域名 / IPv4 形式（字母、数字、点、连字符），
# 首尾必须是字母或数字，总长 <= 253，不能有连续的点。
# TUIC 的 SNI 会写进 openssl 配置文件（CN / subjectAltName），所以必须严格校验。
valid_sni() {
  local v="${1:-}"
  [ -n "$v" ] && [ "${#v}" -le 253 ] || return 1
  [[ "$v" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$v" != *..* ]] || return 1
  return 0
}

# 输入 SNI（带校验，无效则重新输入）。调用方必须写成 x="$(ask_sni ...)" 并且不要接 ||，
# 这样标准输入 EOF 时这里 return 1 能让外层的 set -e 生效，而不是死循环。
ask_sni() {
  local prompt="$1" default_value="${2:-}" v=""
  while true; do
    v="$(ask_text_default "$prompt" "$default_value")" || return 1
    if valid_sni "$v"; then
      echo "$v"
      return 0
    fi
    warn "SNI 格式无效：只允许域名（字母、数字、点、连字符，首尾须为字母或数字，不含空格和特殊符号）。"
  done
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
    IT) echo "🇮🇹|意大利" ;;
    ES) echo "🇪🇸|西班牙" ;;
    PT) echo "🇵🇹|葡萄牙" ;;
    CH) echo "🇨🇭|瑞士" ;;
    AT) echo "🇦🇹|奥地利" ;;
    IE) echo "🇮🇪|爱尔兰" ;;
    BE) echo "🇧🇪|比利时" ;;
    LU) echo "🇱🇺|卢森堡" ;;
    NO) echo "🇳🇴|挪威" ;;
    DK) echo "🇩🇰|丹麦" ;;
    IS) echo "🇮🇸|冰岛" ;;
    CZ) echo "🇨🇿|捷克" ;;
    RO) echo "🇷🇴|罗马尼亚" ;;
    BG) echo "🇧🇬|保加利亚" ;;
    HU) echo "🇭🇺|匈牙利" ;;
    GR) echo "🇬🇷|希腊" ;;
    LT) echo "🇱🇹|立陶宛" ;;
    LV) echo "🇱🇻|拉脱维亚" ;;
    EE) echo "🇪🇪|爱沙尼亚" ;;
    UA) echo "🇺🇦|乌克兰" ;;
    KZ) echo "🇰🇿|哈萨克斯坦" ;;
    IL) echo "🇮🇱|以色列" ;;
    AE) echo "🇦🇪|阿联酋" ;;
    MO) echo "🇲🇴|澳门" ;;
    NZ) echo "🇳🇿|新西兰" ;;
    BR) echo "🇧🇷|巴西" ;;
    MX) echo "🇲🇽|墨西哥" ;;
    AR) echo "🇦🇷|阿根廷" ;;
    CL) echo "🇨🇱|智利" ;;
    ZA) echo "🇿🇦|南非" ;;
    XX|"") echo "🌐|未知地区" ;;
    *)
      # 表里没有的合法两位国家码：自动由字母生成国旗，名称直接用国家码
      if [[ "$code" =~ ^[A-Z]{2}$ ]]; then
        echo "$(flag_from_code "$code")|${code}"
      else
        echo "🌐|未知地区"
      fi
      ;;
  esac
}

# 两位国家码 -> 国旗 emoji（用 jq implode 生成，不依赖终端 locale）
flag_from_code() {
  local code="${1:-}"
  jq -nr --arg c "$code" '[ $c | ascii_upcase | explode[] | . - 65 + 127462 ] | implode' 2>/dev/null || printf '🌐'
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

# 域名 -> IP（IP 原样返回）；支持 IPv4 与纯 IPv6 环境
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
      ip="$(getent ahostsv6 "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    fi
    if [ -z "$ip" ]; then
      ip="$(getent ahosts "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    fi
  fi

  echo "$ip"
}

# 是否为两位国家码
valid_cc() {
  [[ "${1:-}" =~ ^[A-Za-z]{2}$ ]]
}

# 请求一个地区查询接口并取出国家码。
#   $1 URL   $2 jq 过滤器（空 = 响应体本身就是国家码）
# curl 依次用「默认 / -6 / -4」三种方式尝试：
#   纯 IPv6 机器上只有 -6 能连上仅有 AAAA 的接口；纯 IPv4 机器则反之。
# 命中返回 0 并输出大写国家码，全部失败返回 1。
geo_query() {
  local url="$1" filter="${2:-}" fam body code
  local -a fams=("" "-6" "-4")

  for fam in "${fams[@]}"; do
    body="$(curl ${fam:+"$fam"} -fsS --max-time 6 "$url" 2>/dev/null || true)"
    [ -n "$body" ] || continue

    if [ -n "$filter" ]; then
      code="$(printf '%s' "$body" | jq -r "$filter // empty" 2>/dev/null || true)"
    else
      code="$body"
    fi
    code="$(printf '%s' "$code" | tr -d '\r\n "')"

    if valid_cc "$code"; then
      printf '%s' "${code^^}"
      return 0
    fi
  done
  return 1
}

# 手动输入国家码（仅在交互终端下询问；回车跳过）
ask_country_code() {
  local label="${1:-}" cc=""
  [ "${CLI_YES:-}" = "1" ] && return 1
  [ -t 0 ] || return 1
  read -rp "未能自动识别${label}所在地区，请输入两位国家代码（如 US / JP / HK，直接回车跳过）: " cc || return 1
  cc="$(trim "$cc")"
  valid_cc "$cc" || return 1
  printf '%s' "${cc^^}"
}

# 输出：国家码|旗帜|名称
#   $1 主机（IP 或域名）
#   $2 "self" 表示查询的是本机公网 IP：此时额外使用「查询调用者自身」的接口，
#      这类接口只要本机能出网就能返回，对纯 IPv6 服务器最可靠
#   $3 展示用标签（手动兜底提问时使用，如「落地节点」）
detect_location() {
  local host="$1" mode="${2:-}" label="${3:-}"
  local ip="" code="" fam_flag="" pair=""

  ip="$(resolve_host_ip "$host")" || ip=""

  if [ -n "$ip" ]; then
    code="$(geo_query "https://ipapi.co/${ip}/country/" "")" \
      || code="$(geo_query "https://ipinfo.io/${ip}/country" "")" \
      || code="$(geo_query "https://api.country.is/${ip}" '.country')" \
      || code="$(geo_query "https://ipwho.is/${ip}" '.country_code')" \
      || code="$(geo_query "https://api.ip.sb/geoip/${ip}" '.country_code')" \
      || code=""
  fi

  # 本机公网 IP：用「查询调用者自身」的接口兜底，并按 IP 版本强制走对应协议栈
  if [ -z "$code" ] && [ "$mode" = "self" ]; then
    if is_ipv6 "$ip"; then fam_flag="-6"; else fam_flag="-4"; fi
    local url
    for url in https://ifconfig.co/country-iso https://ipapi.co/country/ https://ipinfo.io/country; do
      code="$(curl "$fam_flag" -fsS --max-time 6 "$url" 2>/dev/null | tr -d '\r\n "' || true)"
      if valid_cc "$code"; then code="${code^^}"; break; fi
      code=""
    done
  fi

  # 仍然失败：交互式手动输入，否则标记为未知
  if [ -z "$code" ]; then
    code="$(ask_country_code "$label" || true)"
  fi
  [ -n "$code" ] || code="XX"

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

# 获取指定 landing_id 的落地地区标识（如 "🇸🇬新加坡"）
get_landing_region() {
  local lid="${1:-}" disp=""
  [ -n "$lid" ] || return 0
  disp="$(jq -r --arg id "$lid" '(first(.landings[]? | select(.id == $id)) | .display) // empty' "$STATE_FILE")"
  if [ -n "$disp" ]; then
    printf '%s' "${disp%%：*}"
  fi
}

# 生成节点名称：
#   - 中转节点自动带上落地地区标识（例如：🇭🇰香港-vless转vless-🇸🇬新加坡）
#   - 支持传入 ignore_tag 排除正在修改的节点自身，避免重名误判
make_node_name() {
  local type="$1"
  local port="$2"
  local outbound_type="${3:-direct}"
  local landing_id="${4:-}"
  local ignore_tag="${5:-}"
  local landing_region="${6:-}"
  local flag loc base candidate

  flag="$(jq -r '.location_flag // "🌐"' "$STATE_FILE")"
  loc="$(jq -r '.location_name // "未知地区"' "$STATE_FILE")"

  if [ "$outbound_type" = "landing" ]; then
    if [ -z "$landing_region" ] && [ -n "$landing_id" ]; then
      landing_region="$(get_landing_region "$landing_id")"
    fi
    if [ -n "$landing_region" ]; then
      base="${flag}${loc}-$(node_suffix "$type" "$outbound_type")-${landing_region}"
    else
      base="${flag}${loc}-$(node_suffix "$type" "$outbound_type")"
    fi
  else
    base="${flag}${loc}-$(node_suffix "$type" "$outbound_type")"
  fi

  if ! jq -e --arg name "$base" --arg ignore "$ignore_tag" \
    '.nodes[]? | select(.tag != $ignore and .name == $name)' "$STATE_FILE" >/dev/null 2>&1; then
    echo "$base"
    return 0
  fi

  candidate="${base}-${port}"
  if ! jq -e --arg name "$candidate" --arg ignore "$ignore_tag" \
    '.nodes[]? | select(.tag != $ignore and .name == $name)' "$STATE_FILE" >/dev/null 2>&1; then
    echo "$candidate"
    return 0
  fi

  echo "${base}-${port}-${type%%-*}"
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
  if ! cp -p "$STATE_FILE" "$bak_state"; then
    rm -f "$bak_state" "$NEW_STATE"
    NEW_STATE=""
    err "备份状态文件失败（磁盘已满？），本次修改已放弃，状态未改动。"
    return 1
  fi
  if [ -f "$CONFIG_FILE" ]; then
    bak_conf="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || die "无法创建备份文件。"
    if ! cp -p "$CONFIG_FILE" "$bak_conf"; then
      rm -f "$bak_state" "$bak_conf" "$NEW_STATE"
      NEW_STATE=""
      err "备份配置文件失败（磁盘已满？），本次修改已放弃，状态未改动。"
      return 1
    fi
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

  if [ "$CLI_YES" = "1" ]; then
    info "已指定 -y：静默使用预设的 UUID / Reality 密钥 / SNI。"
    uuid="$DEFAULT_UUID"
    private_key="$DEFAULT_PRIVATE_KEY"
    public_key="$DEFAULT_PUBLIC_KEY"
    short_id="$DEFAULT_SHORT_ID"
    tuic_pass="$DEFAULT_TUIC_PASS"
  else
    echo "请选择是否生成新的 UUID / REALITY 密钥 / ShortID："
    echo "1) 生成新的"
    echo "2) 不生成，使用脚本内默认参数"
    read_line "请输入 1 或 2 [默认 1]: " key_choice
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
        warn "将使用脚本内预设参数（密钥公开，仅建议测试使用）。"
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

  if [ "$CLI_YES" = "1" ]; then
    if server_ip="$(detect_public_ip 4)"; then
      ip_version="ipv4"
    elif server_ip="$(detect_public_ip 6)"; then
      ip_version="ipv6"
    else
      ip_version="ipv4"
      server_ip=""
    fi
  else
    step "选择 IP 版本"
    echo "请选择用于节点分享的公网 IP 版本："
    echo "1) IPv4 (默认)"
    echo "2) IPv6"
    read_line "请输入 1 或 2: " ipv_choice
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
  location_raw="$(detect_location "$server_ip" self "本机")"
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

  l_server="$(ask_landing_host "请输入落地节点 IP 或域名" "")"
  l_port="$(ask_port "请输入落地节点 VLESS 端口 (远端端口，1-65535)" "$VLESS_DIRECT_PORT")"

  check_landing_connectivity "$l_server" "$l_port"

  l_uuid="$(ask_text_default "请输入落地 VLESS UUID" "$(state_get '.uuid')")"
  l_public_key="$(ask_text_default "请输入落地 Reality PublicKey" "$(state_get '.public_key')")"
  l_short_id="$(ask_text_default "请输入落地 Reality ShortID" "$(state_get '.short_id')")"
  l_sni="$(ask_sni "请输入落地 Reality SNI" "$(state_get '.reality_sni')")"

  info "正在检测落地节点地区..."
  loc_raw="$(detect_location "$l_server" "" "落地节点")"
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

# 使用 jq 码点宽度计算，解决中文与国旗 Emoji 在终端表格中的错位问题
list_landings_table() {
  if [ "$(landing_count)" -eq 0 ]; then
    warn "当前无任何落地节点。"
    return 1
  fi

  jq -r "$JQ_TABLE_LIB"'
    . as $s |
    ["序号", "落地节点 (国家：ip)", "端口", "被引用", "SNI"] as $headers |
    [4, 28, 6, 6, 16] as $mins |
    [
      .landings | to_entries[] | .value as $l |
      [
        ((.key + 1) | tostring),
        ($l.display // "-"),
        ($l.port | tostring),
        (([ $s.nodes[]? | select(.landing_id == $l.id) ] | length) | tostring),
        ($l.sni // "-")
      ]
    ] as $rows |
    [
      range(0; 5) as $c |
      ([ $mins[$c], ($headers[$c] | dwidth), ($rows[]?[$c] | dwidth) ] | max)
    ] as $widths |
    (
      [ range(0; 4) as $c | ($headers[$c] | pad($widths[$c])) ] + [$headers[4]] | join("  ")
    ),
    (
      [ range(0; 5) as $c | dash($widths[$c]) ] | join("  ")
    ),
    (
      $rows[] | . as $r |
      [ range(0; 4) as $c | ($r[$c] | pad($widths[$c])) ] + [$r[4]] | join("  ")
    )
  ' "$STATE_FILE"

  return 0
}

# 修改落地池中第 idx（从 0 开始）个条目；若落地地区变化则同步更新引用该落地的节点名称
edit_landing() {
  local idx="$1"
  local l_id old_server old_port old_uuid old_pbk old_sid old_sni old_disp used
  local new_server new_port new_uuid new_pbk new_sid new_sni new_disp new_region loc_raw flag loc

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

  new_server="$(ask_landing_host "落地 IP 或域名" "$old_server")"
  new_port="$(ask_port "落地 VLESS 端口 (远端端口，1-65535)" "$old_port")"

  # 只有地址或端口发生变化时才重新预检
  if [ "$new_server" != "$old_server" ] || [ "$new_port" != "$old_port" ]; then
    check_landing_connectivity "$new_server" "$new_port"
  fi

  new_uuid="$(ask_text_default "落地 UUID" "$old_uuid")"
  new_pbk="$(ask_text_default "落地 Reality PublicKey" "$old_pbk")"
  new_sid="$(ask_text_default "落地 Reality ShortID" "$old_sid")"
  new_sni="$(ask_sni "落地 Reality SNI" "$old_sni")"

  if [ "$new_server" != "$old_server" ]; then
    info "检测到 IP/域名变动，正在重新解析地区..."
    loc_raw="$(detect_location "$new_server" "" "落地节点")"
    flag="$(echo "$loc_raw" | cut -d'|' -f2)"
    loc="$(echo "$loc_raw" | cut -d'|' -f3)"
    new_disp="${flag}${loc}：${new_server}"
  else
    new_disp="$old_disp"
  fi
  new_region="${new_disp%%：*}"

  state_build \
    --argjson i "$idx" \
    --arg id "$l_id" \
    --arg server "$new_server" \
    --argjson port "$new_port" \
    --arg uuid "$new_uuid" \
    --arg pbk "$new_pbk" \
    --arg sid "$new_sid" \
    --arg sni "$new_sni" \
    --arg disp "$new_disp" \
    --arg region "$new_region" \
    '
    (.location_flag // "🌐") as $eflag |
    (.location_name // "未知地区") as $eloc |
    .landings[$i] |= (
      .server = $server | .port = $port | .uuid = $uuid |
      .public_key = $pbk | .short_id = $sid | .sni = $sni | .display = $disp
    ) |
    reduce (
      .nodes | to_entries[] | select(.value.landing_id == $id) | .key
    ) as $ni (.;
      .nodes[$ni] as $n |
      (if ($n.type | startswith("tuic")) then "tuic5转vless" else "vless转vless" end) as $suf |
      ($eflag + $eloc + "-" + $suf + "-" + $region) as $base |
      ([.nodes[] | select(.tag != $n.tag and .name == $base)] | length) as $dup |
      .nodes[$ni].name = (if $dup == 0 then $base else ($base + "-" + ($n.port | tostring)) end)
    )
    '

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
  read_line "请输入要修改的落地节点序号 (输入 0 返回): " pick
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
  read_line "请输入要删除的落地节点序号 (输入 0 返回): " pick
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

  read_line "确认删除落地节点 [${disp}] 吗？输入 y 确认: " confirm
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
    info "落地的增删改只在这里进行；节点只通过 ID 引用落地（添加 / 修改节点时选择即可）。"
    list_landings_table || true
    echo
    echo "1) 添加落地节点"
    echo "2) 修改落地节点信息 (IP / 端口 / 密钥等)"
    echo "3) 删除落地节点"
    echo "0) 返回主菜单"
    read_line "请输入选项: " lchoice
    case "$lchoice" in
      1) act add_landing_wizard ;;
      2) act modify_landing_wizard ;;
      3) act delete_landing_wizard ;;
      0) return 0 ;;
      *) warn "输入错误。" ;;
    esac
  done
}

# 从落地池里选择一个已有的落地（只选择，不在这里新建 / 修改，那些都在「落地节点池管理」里做）。
# 选中返回 0（结果在 SEL_LANDING_ID / SEL_LANDING_DISPLAY）；取消或池为空返回 CANCEL_RC
# 调用方直接裸调用，不要写成 select_landing || ...（否则函数内部的 set -e 会失效）
SEL_LANDING_ID=""
SEL_LANDING_DISPLAY=""
select_landing() {
  local count pick real_idx

  count="$(landing_count)"
  if [ "$count" -eq 0 ]; then
    warn "落地节点池是空的。请先回到主菜单「落地节点池管理」添加落地节点，再来创建 / 切换中转节点。"
    return "$CANCEL_RC"
  fi

  while true; do
    echo
    echo "请选择落地节点（落地的增删改请到「落地节点池管理」）："
    list_landings_table || true
    echo "  0) 取消"
    read_line "请输入序号: " pick
    pick="$(trim "$pick")"

    if [ -z "$pick" ] || [ "$pick" = "0" ]; then
      warn "已取消。"
      return "$CANCEL_RC"
    fi

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

  check_port_available "$port" "$protocol" || return $?

  tag="${type}-${port}"
  name="$(make_node_name "$type" "$port" "$outbound_type" "$landing_id")"

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

  local choice port outbound_choice type_base landing_id=""

  echo "1) 添加 VLESS 节点 (TCP)"
  echo "2) 添加 TUIC v5 节点 (UDP)"
  echo "0) 返回"
  read_line "请选择: " choice
  case "$choice" in
    1) type_base="vless" ;;
    2) type_base="tuic" ;;
    0) return "$CANCEL_RC" ;;
    *) warn "输入错误。"; return 1 ;;
  esac

  # 先确定出口，再填端口：选了中转却没有落地时，不会白填一遍端口
  echo
  echo "请选择出站方式："
  echo "1) 直出"
  echo "2) 落地中转 (从「落地节点池」里选择已有落地)"
  read_line "请输入 1 或 2 [默认 1]: " outbound_choice
  outbound_choice="${outbound_choice:-1}"

  case "$outbound_choice" in
    1) ;;
    2)
      select_landing
      landing_id="$SEL_LANDING_ID"
      info "已选择落地：${SEL_LANDING_DISPLAY}"
      ;;
    *) warn "输入错误。"; return 1 ;;
  esac

  if [ "$type_base" = "vless" ]; then
    port="$(ask_node_port "请输入 VLESS TCP 端口" "$VLESS_DIRECT_PORT")"
  else
    port="$(ask_node_port "请输入 TUIC UDP 端口" "$TUIC_DIRECT_PORT")"
  fi

  if [ -n "$landing_id" ]; then
    prepare_add_node "${type_base}-relay" "$port" "landing" "$landing_id"
  else
    prepare_add_node "${type_base}-direct" "$port" "direct"
  fi

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
  read_line "请输入要删除的节点序号 (多个用空格隔开，如 1 2)，输入 0 返回: " indices
  indices="${indices//，/ }"
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

  read_line "确认删除？输入 y 确认: " confirm
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

  local count index real_idx old_port new_port old_tag new_tag type protocol name
  local outbound_type landing_id landing_display mod_choice
  local current_sni new_sni out_target new_type new_name

  count="$(jq '.nodes | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "当前没有可修改的节点。"
    return "$CANCEL_RC"
  fi

  step "修改节点 (端口 / SNI / 出口落地)"
  list_nodes_table
  echo
  read_line "请输入要修改的节点序号，输入 0 返回: " index
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
  echo "3) 修改出口方式 (切换直出 / 更换为落地池里的其他落地)"
  echo "0) 返回"
  read_line "请输入选项: " mod_choice
  case "$mod_choice" in
    1)
      new_port="$(ask_node_port "请输入新端口 (${protocol^^}，>= ${MIN_NODE_PORT})" "$old_port")"
      if [ "$new_port" = "$old_port" ]; then
        info "端口未改变。"
        return "$CANCEL_RC"
      fi
      check_port_available "$new_port" "$protocol" "$old_tag"
      new_tag="${type}-${new_port}"
      new_name="$(make_node_name "$type" "$new_port" "$outbound_type" "$landing_id" "$old_tag")"
      state_build --argjson i "$real_idx" \
        --argjson port "$new_port" \
        --arg tag "$new_tag" \
        --arg name "$new_name" \
        '.nodes[$i] |= (.port = $port | .tag = $tag | .name = $name)'
      ;;
    2)
      if [[ "$type" == tuic* ]]; then
        current_sni="$(state_get '.tuic_sni')"
        info "TUIC SNI 为所有 TUIC 节点共用，修改后会自动重新生成自签证书。"
      else
        current_sni="$(state_get '.reality_sni')"
        info "Reality SNI 为所有 VLESS 节点共用。落地侧的 IP / 端口 / SNI 请到「落地节点池管理」修改。"
      fi
      new_sni="$(ask_sni "请输入新 SNI" "$current_sni")"
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
      echo "2) 改为落地中转 (从「落地节点池」里选择)"
      echo "0) 返回"
      read_line "请输入 1 / 2 / 0: " out_target
      if [ "$out_target" = "1" ]; then
        if [[ "$type" == tuic* ]]; then new_type="tuic-direct"; else new_type="vless-direct"; fi
        new_tag="${new_type}-${old_port}"
        new_name="$(make_node_name "$new_type" "$old_port" "direct" "" "$old_tag")"
        state_build --argjson i "$real_idx" \
          --arg type "$new_type" \
          --arg tag "$new_tag" \
          --arg name "$new_name" \
          '.nodes[$i] |= (.type = $type | .tag = $tag | .name = $name | .outbound_type = "direct" | del(.landing_id))'
      elif [ "$out_target" = "2" ]; then
        select_landing
        if [[ "$type" == tuic* ]]; then new_type="tuic-relay"; else new_type="vless-relay"; fi
        new_tag="${new_type}-${old_port}"
        new_name="$(make_node_name "$new_type" "$old_port" "landing" "$SEL_LANDING_ID" "$old_tag")"
        state_build --argjson i "$real_idx" \
          --arg type "$new_type" \
          --arg tag "$new_tag" \
          --arg name "$new_name" \
          --arg lid "$SEL_LANDING_ID" \
          '.nodes[$i] |= (.type = $type | .tag = $tag | .name = $name | .outbound_type = "landing" | .landing_id = $lid)'
      else
        return "$CANCEL_RC"
      fi
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
# 屏蔽指定网站（支持批量输入与批量删除）
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

  local raw_input item domain domains_json
  local -a new_domains=()

  read_line "请输入要屏蔽的域名 (多个用空格或逗号隔开，输入 0 返回): " raw_input
  raw_input="${raw_input//，/ }"
  raw_input="${raw_input//,/ }"
  raw_input="$(trim "$raw_input")"
  if [ -z "$raw_input" ] || [ "$raw_input" = "0" ]; then return "$CANCEL_RC"; fi

  for item in $raw_input; do
    domain="$(normalize_domain "$item")"
    if [ -z "$domain" ]; then continue; fi
    if ! [[ "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
      warn "忽略无效域名格式：${item}（中文域名请填写 punycode 形式）"
      continue
    fi
    if jq -e --arg d "$domain" '.blocked_domains | index($d)' "$STATE_FILE" >/dev/null 2>&1; then
      info "域名已在屏蔽列表中，跳过：$domain"
      continue
    fi
    if [[ " ${new_domains[*]:-} " == *" ${domain} "* ]]; then
      continue
    fi
    new_domains+=("$domain")
  done

  if [ "${#new_domains[@]}" -eq 0 ]; then
    warn "没有新增任何有效域名。"
    return "$CANCEL_RC"
  fi

  domains_json="$(printf '%s\n' "${new_domains[@]}" | jq -R . | jq -s .)"
  state_build --argjson ds "$domains_json" '.blocked_domains += $ds | .blocked_domains |= unique'
  apply_state
  ok "已批量屏蔽 ${#new_domains[@]} 个域名: ${new_domains[*]}"
}

block_remove() {
  need_state

  local count raw_indices idx real_idx d_name confirm remove_json
  local -a remove_domains=()
  local -a seen=()

  count="$(jq '.blocked_domains | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "屏蔽列表为空。"
    return "$CANCEL_RC"
  fi

  read_line "请输入要解除屏蔽的序号 (多个用空格或逗号隔开，输入 all 清空全部，输入 0 取消): " raw_indices
  raw_indices="${raw_indices//，/ }"
  raw_indices="${raw_indices//,/ }"
  raw_indices="$(trim "$raw_indices")"
  if [ -z "$raw_indices" ] || [ "$raw_indices" = "0" ]; then return "$CANCEL_RC"; fi

  if [ "${raw_indices,,}" = "all" ]; then
    read_line "确认清空全部 ${count} 个已屏蔽域名吗？输入 y 确认: " confirm
    if [ "${confirm,,}" != "y" ]; then
      warn "已取消。"
      return "$CANCEL_RC"
    fi
    state_build '.blocked_domains = []'
    apply_state
    ok "已清空全部屏蔽域名。"
    return 0
  fi

  for idx in $raw_indices; do
    if [[ "$idx" =~ ^[0-9]{1,6}$ ]] && [ "$((10#$idx))" -ge 1 ] && [ "$((10#$idx))" -le "$count" ]; then
      real_idx=$((10#$idx - 1))
      if [[ " ${seen[*]:-} " == *" ${real_idx} "* ]]; then continue; fi
      seen+=("$real_idx")
      d_name="$(jq -r --argjson i "$real_idx" '.blocked_domains[$i]' "$STATE_FILE")"
      remove_domains+=("$d_name")
    else
      warn "忽略无效序号: $idx"
    fi
  done

  if [ "${#remove_domains[@]}" -eq 0 ]; then
    warn "未选择有效序号。"
    return 1
  fi

  remove_json="$(printf '%s\n' "${remove_domains[@]}" | jq -R . | jq -s .)"
  state_build --argjson rm_list "$remove_json" \
    '.blocked_domains |= map(select(. as $d | $rm_list | index($d) | not))'
  apply_state
  ok "已解除屏蔽 (${#remove_domains[@]} 个): ${remove_domains[*]}"
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
    echo "1) 添加屏蔽域名 (支持批量)"
    echo "2) 解除已屏蔽的域名 (支持批量 / all)"
    echo "0) 返回"
    read_line "请输入选项: " choice
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
  local current_ver latest_ver force confirm bin wd rc mode new_ver

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

  mode="upgrade"
  if [ "$current_ver" = "$latest_ver" ]; then
    mode="reinstall"
    info "当前已经是最新版本。"
    read_line "是否强制重新安装？输入 y 确认: " force
    if [ "${force,,}" != "y" ]; then return "$CANCEL_RC"; fi
  else
    read_line "确认更新到最新版本？输入 y 确认 [默认 y]: " confirm
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

  # 子 shell 里运行，保证里面的 die 不会直接结束整个操作
  set +e
  if pkg_managed_singbox; then
    info "sing-box 由系统包管理器 (${PKG_MANAGER}) 管理，改用包管理器处理（模式：${mode}）。"
    ( set -e; pkg_upgrade_singbox "$mode" )
  else
    rm -f /usr/local/bin/sing-box /usr/bin/sing-box
    hash -r 2>/dev/null || true
    ( set -e; install_singbox )
  fi
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

  new_ver="$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}' || true)"
  if [ "$new_ver" != "$latest_ver" ]; then
    warn "当前版本 ${new_ver:-未知} 与 GitHub 最新版 ${latest_ver} 不一致（软件源可能尚未同步该版本）。"
  fi

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
  read_line "请选择: " choice
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
  # server_ip / ip_version 只影响分享链接与 Clash YAML，不影响 config.json（入站固定监听 ::），
  # 所以只落盘并重新生成链接 / YAML，不重启 sing-box，不会断开现有连接。
  commit_state_plain
  render_yaml || warn "生成 Clash YAML 失败。"
  render_info || warn "生成节点信息文件失败。"
  ok "已更新公网 IP 为 ${new_ip} (${new_ver})，节点链接与 Clash YAML 已重新生成（sing-box 未重启）。"
}

# -------------------------
# 初始节点（安装流程）
# -------------------------
# 状态文件是否「有效」：是 JSON 对象，且必需字段齐全、列表字段类型正确
state_file_valid() {
  [ -s "$STATE_FILE" ] || return 1
  jq -e '
    . as $s
    | type == "object"
    and (["uuid","private_key","public_key","short_id","tuic_pass","reality_sni","tuic_sni","server_ip"]
         | all(.[]; (($s[.] | type) == "string") and (($s[.] | length) > 0)))
    and ((.nodes // []) | type == "array")
    and ((.landings // []) | type == "array")
    and ((.blocked_domains // []) | type == "array")
  ' "$STATE_FILE" >/dev/null 2>&1
}

# 沿用旧状态文件时，公网 IP 可能已变（换了服务器）：检测并按需更新
refresh_ip_if_changed() {
  local ver old new loc_raw flag loc code ans

  ver="$(state_get '.ip_version // "ipv4"')"
  old="$(state_get '.server_ip')"

  if [ "$ver" = "ipv6" ]; then
    new="$(detect_public_ip 6)" || new=""
  else
    new="$(detect_public_ip 4)" || new=""
  fi

  if [ -z "$new" ]; then
    warn "未能检测到当前公网 ${ver} 地址，保留状态文件里的 ${old}。"
    return 0
  fi
  [ "$new" != "$old" ] || return 0

  warn "当前公网 IP 与状态文件不一致：${old} -> ${new}（可能换了服务器）。"
  if [ "$CLI_YES" != "1" ]; then
    read_line "是否更新为当前 IP？输入 y 更新 [默认 y]: " ans
    ans="${ans:-y}"
    if [ "${ans,,}" != "y" ]; then
      info "保留 ${old}。"
      return 0
    fi
  fi

  loc_raw="$(detect_location "$new" self "本机")"
  code="$(echo "$loc_raw" | cut -d'|' -f1)"
  flag="$(echo "$loc_raw" | cut -d'|' -f2)"
  loc="$(echo "$loc_raw" | cut -d'|' -f3)"

  state_build --arg ip "$new" --arg cc "$code" --arg flag "$flag" --arg loc "$loc" \
    '.server_ip = $ip | .country_code = $cc | .location_flag = $flag | .location_name = $loc'
  commit_state_plain
  ok "已更新公网 IP：${new}（${flag}${loc}）。已有节点名称里的地区不会自动改变。"
}

# 命令行指定的一个直出节点：值为 0 跳过；沿用旧状态时同类型同端口已存在则跳过（幂等）
add_cli_node() {
  local type="$1" val="$2" port

  [ -n "$val" ] || return 0

  if [ "$val" = "0" ]; then
    info "已指定 ${type%%-*}=0，跳过。"
    return 0
  fi

  port=$((10#$val))
  if jq -e --arg t "$type" --argjson p "$port" \
       '.nodes[]? | select(.type == $t and ((.port | tonumber) == $p))' "$STATE_FILE" >/dev/null 2>&1; then
    info "节点 ${type} / 端口 ${port} 已存在，跳过。"
    return 0
  fi

  info "命令行指定 ${type%%-*} 端口: ${port}"
  prepare_add_node "$type" "$port" "direct" || die "已取消。"
  commit_state_plain
}

# 安装时创建的节点只来自命令行 vless= / tuic=；没有指定就不创建任何节点，也不提问
choose_initial_nodes() {
  if [ -z "$CLI_VLESS" ] && [ -z "$CLI_TUIC" ]; then
    info "未指定 vless= / tuic=，本次不创建任何节点。安装完成后输入 ysq 打开面板添加。"
    return 0
  fi

  step "创建初始节点"
  add_cli_node "vless-direct" "$CLI_VLESS"
  add_cli_node "tuic-direct" "$CLI_TUIC"
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

    def landing_out($l):
    {
      "type": "vless",
      "tag": ("out-" + $l.id),
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
        (
          [
            $s.nodes[]? |
            select(.outbound_type == "landing") |
            landing(.)
          ]
          | unique_by(.id)
          | map(landing_out(.))
        )
      ),
      "route": {
        "rules": (
          (if (($s.blocked_domains // []) | length) > 0 then
            [
              {
                "action": "sniff"
              },
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
              "outbound": (if .outbound_type == "landing" then ("out-" + .landing_id) else "direct" end)
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
输入 ysq 打开面板后，选择「添加节点」。

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
  local q_server q_uuid q_pass q_rsni q_tsni q_pbk q_sid

  uuid="$(state_get '.uuid')"
  public_key="$(state_get '.public_key')"
  short_id="$(state_get '.short_id')"
  tuic_pass="$(state_get '.tuic_pass')"
  reality_sni="$(state_get '.reality_sni')"
  tuic_sni="$(state_get '.tuic_sni')"
  server_ip="$(state_get '.server_ip')"

  # 这些值写进 YAML 时统一加引号：纯数字 / 形如 12e45 的 short-id、IPv6 地址等不加引号会被解析成数字或报错
  q_server="$(yaml_quote "$server_ip")"
  q_uuid="$(yaml_quote "$uuid")"
  q_pass="$(yaml_quote "$tuic_pass")"
  q_rsni="$(yaml_quote "$reality_sni")"
  q_tsni="$(yaml_quote "$tuic_sni")"
  q_pbk="$(yaml_quote "$public_key")"
  q_sid="$(yaml_quote "$short_id")"

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
    server: ${q_server}
    port: ${port}
    uuid: ${q_uuid}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${q_rsni}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${q_pbk}
      short-id: ${q_sid}
YAML
      } >> "$YAML_FILE"
    elif [[ "$type" == tuic* ]]; then
      {
        printf '  - name: %s\n' "$(yaml_quote "$name")"
        cat <<YAML
    type: tuic
    server: ${q_server}
    port: ${port}
    uuid: ${q_uuid}
    password: ${q_pass}
    alpn:
      - h3
    sni: ${q_tsni}
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

# 重新渲染 config.json（按 ysq-state.db）并重启；渲染失败不重启，重启失败恢复旧配置
rerender_and_restart() {
  local bak_conf=""

  if [ -f "$CONFIG_FILE" ]; then
    bak_conf="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || { err "无法创建备份文件。"; return 1; }
    cp -p "$CONFIG_FILE" "$bak_conf"
  fi

  if ! render_all; then
    [ -z "$bak_conf" ] || rm -f "$bak_conf"
    err "重新渲染失败，现有配置未被修改，未重启。"
    return 1
  fi

  if ! restart_singbox; then
    err "用新配置重启失败，正在恢复旧配置..."
    if [ -n "$bak_conf" ]; then
      mv -f "$bak_conf" "$CONFIG_FILE"
      restart_singbox || warn "旧配置也启动失败，请在面板里查看状态与日志。"
    fi
    return 1
  fi

  [ -z "$bak_conf" ] || rm -f "$bak_conf"
  return 0
}

restart_wizard() {
  need_state
  step "重启 sing-box"

  local choice

  echo "1) 直接重启"
  echo "2) 重新渲染后重启"
  echo "0) 返回"
  read_line "请选择 [默认 1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    1) restart_and_status ;;
    2)
      rerender_and_restart
      service_status
      ;;
    0) return "$CANCEL_RC" ;;
    *) warn "输入错误。"; return 1 ;;
  esac
}

# -------------------------
# 展示与日志
# -------------------------
# 使用 jq 码点宽度计算，解决中文与国旗 Emoji 导致的表格错位
list_nodes_table() {
  need_state

  local count
  count="$(jq '.nodes | length' "$STATE_FILE")"

  if [ "$count" -eq 0 ]; then
    warn "当前没有节点。"
    return 0
  fi

  jq -r "$JQ_TABLE_LIB"'
    def tname($type; $out):
      if ($type | startswith("vless")) then
        if $out == "landing" then "VLESS -> VLESS 中转" else "VLESS 直出" end
      elif ($type | startswith("tuic")) then
        if $out == "landing" then "TUIC v5 -> VLESS 中转" else "TUIC v5 直出" end
      else $type end;

    . as $s |
    ["序号", "节点名", "协议", "端口", "类型", "落地 (国家：ip)"] as $headers |
    [4, 28, 6, 6, 20, 20] as $mins |
    [
      .nodes | to_entries[] | .value as $n |
      ($n.outbound_type // "direct") as $out |
      [
        ((.key + 1) | tostring),
        ($n.name // "-"),
        (($n.protocol // "tcp") | ascii_upcase),
        ($n.port | tostring),
        tname($n.type; $out),
        (if $out == "landing" then
          ((first($s.landings[]? | select(.id == ($n.landing_id // ""))) | .display) // "(落地已丢失)")
        else "-" end)
      ]
    ] as $rows |
    [
      range(0; 6) as $c |
      ([ $mins[$c], ($headers[$c] | dwidth), ($rows[]?[$c] | dwidth) ] | max)
    ] as $widths |
    (
      [ range(0; 5) as $c | ($headers[$c] | pad($widths[$c])) ] + [$headers[5]] | join("  ")
    ),
    (
      [ range(0; 6) as $c | dash($widths[$c]) ] | join("  ")
    ),
    (
      $rows[] | . as $r |
      [ range(0; 5) as $c | ($r[$c] | pad($widths[$c])) ] + [$r[5]] | join("  ")
    )
  ' "$STATE_FILE"

  return 0
}

show_ports() {
  if [ -f "$STATE_FILE" ]; then
    local tcp_ports udp_ports
    tcp_ports="$(jq -r '.nodes[]? | select((.protocol // "tcp") == "tcp") | .port' "$STATE_FILE" | paste -sd',' -)"
    udp_ports="$(jq -r '.nodes[]? | select((.protocol // "tcp") == "udp") | .port' "$STATE_FILE" | paste -sd',' -)"

    echo "[TCP 监听端口]"
    if [ -n "$tcp_ports" ]; then
      ss -tlpn 2>/dev/null | awk -v plist="$tcp_ports" 'BEGIN {
        n = split(plist, arr, ",")
        for (i = 1; i <= n; i++) ports[arr[i]] = 1
      } NR > 1 {
        loc = $4; sub(/^.*:/, "", loc)
        if (loc in ports) print $0
      }' || true
    else
      echo "无"
    fi

    echo "[UDP 监听端口]"
    if [ -n "$udp_ports" ]; then
      ss -ulpn 2>/dev/null | awk -v plist="$udp_ports" 'BEGIN {
        n = split(plist, arr, ",")
        for (i = 1; i <= n; i++) ports[arr[i]] = 1
      } NR > 1 {
        loc = $4; sub(/^.*:/, "", loc)
        if (loc in ports) print $0
      }' || true
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

show_logs() {
  step "sing-box 运行日志"

  local lines="" out="" file

  read_line "显示最近多少行？[默认 100]: " lines
  lines="$(trim "$lines")"
  if ! [[ "$lines" =~ ^[0-9]{1,4}$ ]] || [ "$((10#$lines))" -lt 1 ]; then
    lines=100
  else
    lines=$((10#$lines))
  fi

  case "$SERVICE_MANAGER" in
    systemd)
      out="$(journalctl -u sing-box -n "$lines" --no-pager 2>&1 || true)"
      if [ -z "$out" ] || [[ "$out" == *"No entries"* ]]; then
        warn "journal 里暂无 sing-box 日志。"
      else
        printf '%s\n' "$out"
      fi
      ;;
    openrc|none)
      if [ -s "$LOG_FILE" ]; then
        echo "--- ${LOG_FILE} ---"
        tail -n "$lines" "$LOG_FILE"
      else
        warn "日志文件为空或不存在：${LOG_FILE}"
      fi
      ;;
  esac

  echo
  info "提示：当前日志级别为 error，只会记录错误；日志为空通常表示运行正常。"
}

print_summary() {
  step "安装完成"
  ok "节点直链文件：${INFO_FILE}"
  ok "Clash YAML 文件：${YAML_FILE}"
  echo
  cat "$INFO_FILE"
  step "Clash YAML"
  cat "$YAML_FILE"
  if [ "$PANEL_READY" = "1" ]; then
    ok "输入 ysq 打开管理面板。"
  else
    warn "未创建 ysq 快捷命令（脚本没有保存为本地文件，见上方提示）。"
  fi
}

install_panel_wrapper() {
  cat > "$PANEL_FILE" <<PANEL
#!/usr/bin/env bash
if [ ! -f "$INSTALLER_FILE" ]; then
  echo "未找到主脚本文件: $INSTALLER_FILE，请重新运行安装脚本。" >&2
  exit 1
fi
exec bash "$INSTALLER_FILE" panel "\$@"
PANEL
  chmod +x "$PANEL_FILE"
}

# 判断一个文件是不是「我们自己的脚本」：
#   必须是普通文件、以 #! 开头（排除 ELF 二进制，如 /bin/bash）、并含脚本标识
is_ysq_script() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
  [ "$(head -c 2 "$f" 2>/dev/null)" = "#!" ] || return 1
  grep -q "ysq sing-box" "$f" 2>/dev/null
}

# 是否指向 bash 解释器本身
is_shell_binary() {
  local f="${1:-}" b
  [ -n "$f" ] || return 1
  b="$(command -v bash 2>/dev/null || true)"
  [ -n "$b" ] && [ "$f" -ef "$b" ] && return 0
  [ "$f" -ef /bin/bash ] || [ "$f" -ef /usr/bin/bash ] || [ "$f" -ef /bin/sh ] || [ "$f" -ef /usr/bin/sh ]
}

# 把脚本自身保存到 INSTALLER_FILE，成功（得到一个可用的脚本文件）返回 0。
# 来源按优先级：
#   1) 本地脚本文件（bash script.sh）
#   2) 已存在的 INSTALLER_FILE
#   3) 环境变量 YSQ_SCRIPT_URL 指定的下载地址（适用于 curl | bash / bash <(curl ...)）
# 管道运行时 BASH_SOURCE[0] 为空或为 /dev/fd/N，$0 可能是 "bash"：
# 这里既不使用 $0，也要求来源是以 #! 开头且含标识的普通文件，因此绝不会把 bash 二进制复制成脚本。
save_self() {
  local src="${BASH_SOURCE[0]:-}" wd tmp

  if [ -n "$src" ] && ! is_shell_binary "$src" && is_ysq_script "$src"; then
    if ! [ "$src" -ef "$INSTALLER_FILE" ]; then
      install -m 755 "$src" "$INSTALLER_FILE" 2>/dev/null || { warn "保存脚本到 ${INSTALLER_FILE} 失败。"; return 1; }
    fi
    chmod +x "$INSTALLER_FILE" 2>/dev/null || true
    return 0
  fi

  if is_ysq_script "$INSTALLER_FILE"; then
    chmod +x "$INSTALLER_FILE" 2>/dev/null || true
    return 0
  fi

  # 管道 / 进程替换运行时没有本地文件：从发布地址（默认 GitHub，可用环境变量 YSQ_SCRIPT_URL 覆盖）下载一份
  wd="$(new_work_dir)"
  tmp="${wd}/${INSTALLER_NAME}"
  if curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp" "${YSQ_SCRIPT_URL:-$DEFAULT_SCRIPT_URL}" 2>/dev/null && is_ysq_script "$tmp"; then
    install -m 755 "$tmp" "$INSTALLER_FILE"
    rm -rf "$wd"
    return 0
  fi
  rm -rf "$wd"

  warn "当前通过管道 / 进程替换运行，没有本地脚本文件，且从 ${YSQ_SCRIPT_URL:-$DEFAULT_SCRIPT_URL} 下载失败，未能保存到 ${INSTALLER_FILE}，因此不会创建 ysq 快捷命令。"
  warn "如需 ysq 命令：先把脚本保存为文件再执行（curl -fsSLo ${INSTALLER_NAME} <脚本地址> && bash ${INSTALLER_NAME}）。"
  return 1
}

# 删除 sing-box。keep=1 时只保留状态文件（UUID / 私钥 / 节点 / 落地 / 屏蔽列表）
do_uninstall() {
  local keep="${1:-0}" keep_copy="" p

  if [ "$keep" = "1" ]; then
    # 包管理器卸载可能清理 /etc/sing-box，先在目录外留一份，最后确认还在
    keep_copy="$(mktemp /root/.ysq-state.keep.XXXXXX)" || die "无法创建临时备份。"
    cp -p "$STATE_FILE" "$keep_copy"
  fi

  service_stop
  service_disable
  pkg_remove_singbox

  rm -f /usr/local/bin/sing-box /usr/bin/sing-box
  rm -f /etc/systemd/system/sing-box.service
  rm -f /etc/init.d/sing-box
  rm -f /run/sing-box.pid
  remove_log_trim
  rm -rf /var/lib/sing-box /var/log/sing-box
  rm -f "$INFO_FILE" "$YAML_FILE" "$PANEL_FILE"

  if [ "$keep" = "1" ]; then
    # 配置目录里除状态文件外全部删除（config.json / 证书 / 临时文件）
    for p in "$CONFIG_DIR"/* "$CONFIG_DIR"/.[!.]*; do
      [ -e "$p" ] || continue
      [ "$p" = "$STATE_FILE" ] && continue
      rm -rf "$p"
    done
    if [ ! -s "$STATE_FILE" ]; then
      mkdir -p "$CONFIG_DIR"
      install -m 600 "$keep_copy" "$STATE_FILE"
    fi
    rm -f "$keep_copy"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
  else
    rm -rf "$CONFIG_DIR"
    rm -f "$INSTALLER_FILE"
  fi

  service_daemon_reload
}

uninstall_all() {
  step "删除 sing-box"

  local mode confirm

  echo "1) 彻底删除"
  echo "2) 保留节点数据"
  echo "0) 取消"
  read_line "请选择: " mode

  case "$mode" in
    1)
      read_line "确认彻底删除 sing-box 及全部节点数据？输入 y 确认: " confirm
      if [ "${confirm,,}" != "y" ]; then
        warn "已取消。"
        return "$CANCEL_RC"
      fi
      do_uninstall 0
      ok "已彻底删除。"
      ;;
    2)
      if [ ! -f "$STATE_FILE" ]; then
        warn "未找到 ${STATE_FILE}，没有可保留的节点数据。"
        return 1
      fi
      read_line "确认删除 sing-box 并保留节点数据？输入 y 确认: " confirm
      if [ "${confirm,,}" != "y" ]; then
        warn "已取消。"
        return "$CANCEL_RC"
      fi
      do_uninstall 1
      ok "已删除 sing-box，节点数据已保留：${STATE_FILE}"
      info "该文件含 UUID / Reality 私钥，请妥善保管（权限 600）。"
      info "重新安装：bash ${INSTALLER_FILE} [vless=端口 tuic=端口 -y]，会自动沿用该文件，不会覆盖。"
      ;;
    0) return "$CANCEL_RC" ;;
    *) warn "输入错误。"; return 1 ;;
  esac

  exit "$EXIT_PANEL_RC"
}

# -------------------------
# 更新面板：下载新脚本 -> 校验 -> 原子替换 -> 用新脚本执行 upgrade（保留数据）
# -------------------------
script_version_of() {
  sed -n 's/^YSQ_VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -n 1
}

# 新版脚本执行：沿用状态文件，刷新服务单元 / 日志裁剪，重新渲染并重启
upgrade_action() {
  need_root
  need_state
  step "升级：应用新版脚本（保留全部节点数据）"

  ensure_state_defaults || die "状态文件规范化失败，请检查 ${STATE_FILE}。"
  install_deps
  install_singbox
  ensure_dirs
  rerender_and_restart || die "升级后重启失败，已恢复旧配置。"
  ok "升级完成。"
}

update_panel_wizard() {
  need_state
  step "更新面板"

  local url="${YSQ_SCRIPT_URL:-$DEFAULT_SCRIPT_URL}"
  local wd tmp new_ver confirm new_file bak

  wd="$(new_work_dir)"
  tmp="${wd}/${INSTALLER_NAME}"

  info "当前面板版本：${YSQ_VERSION}"
  info "下载地址：${url}"

  if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp" "$url"; then
    rm -rf "$wd"
    die "下载失败，现有面板未改动。请检查网络或 GitHub 访问。"
  fi
  if ! is_ysq_script "$tmp"; then
    rm -rf "$wd"
    die "下载的内容不是有效的 ysq 脚本（可能是 404 页面或被拦截），现有面板未改动。"
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -rf "$wd"
    die "新脚本语法检查未通过，现有面板未改动。"
  fi

  new_ver="$(script_version_of "$tmp")"
  info "远端面板版本：${new_ver:-未标注版本号}"

  if [ -f "$INSTALLER_FILE" ] && cmp -s "$tmp" "$INSTALLER_FILE"; then
    info "远端脚本与当前脚本完全一致。"
    read_line "仍要重新安装一遍？输入 y 确认: " confirm
    confirm="${confirm:-n}"
  else
    read_line "确认更新？节点数据（${STATE_FILE}）会保留，更新后会重新渲染并重启 sing-box。输入 y 确认 [默认 y]: " confirm
    confirm="${confirm:-y}"
  fi
  if [ "${confirm,,}" != "y" ]; then
    rm -rf "$wd"
    warn "已取消。"
    return "$CANCEL_RC"
  fi

  # 先写同目录临时文件再 mv：原子替换；当前正在运行的旧脚本仍持有旧 inode，不会被改乱
  new_file="${INSTALLER_FILE}.new.$$"
  bak="${INSTALLER_FILE}.bak"
  install -m 755 "$tmp" "$new_file"
  if [ -f "$INSTALLER_FILE" ]; then
    cp -p "$INSTALLER_FILE" "$bak"
  fi
  mv -f "$new_file" "$INSTALLER_FILE"
  rm -rf "$wd"
  install_panel_wrapper

  info "正在用新脚本应用升级..."
  if ! bash "$INSTALLER_FILE" upgrade; then
    err "新脚本的升级步骤失败，正在恢复旧脚本..."
    if [ -f "$bak" ]; then
      mv -f "$bak" "$INSTALLER_FILE"
    fi
    return 1
  fi

  ok "面板已更新（${YSQ_VERSION} -> ${new_ver:-新版}），节点数据已保留。旧脚本备份在 ${bak}。"
  return "$RESTART_PANEL_RC"
}

# -------------------------
# 面板：每个操作都在子 shell 里跑，die / exit 只会中止当前操作
# -------------------------
# 注意：这里绝不能写成  run_action ... || xxx 。
# bash 在 || / && / if 条件里会整体忽略 set -e，子 shell 里再写 set -e 也无效，
# 结果是 apply_state 失败（已回滚）后向导函数继续往下执行，还会打印“已生效”。
# 所以 act 用「关 -e → 直接调用 → 取返回码 → 开 -e」的写法，让子 shell 里的 set -e 真正生效。
run_action() {
  local rc=0

  ( set -e; "$@" )
  rc=$?

  cleanup_tmp

  case "$rc" in
    0|"$CANCEL_RC") ;;
    "$EXIT_PANEL_RC") exit 0 ;;
    # 此时子 shell 已结束、临时文件已清理；exec 让新面板直接取代当前进程
    "$RESTART_PANEL_RC") pause; exec bash "$INSTALLER_FILE" panel ;;
    *) warn "操作未完成，已返回菜单。" ;;
  esac

  return "$rc"
}

# 运行一个操作，结束后暂停（用户主动取消时不暂停）。pause 统一放在这里，各向导函数内部不再 pause
act() {
  local rc=0

  set +e
  run_action "$@"
  rc=$?
  set -e

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
    echo -e "${C_BOLD} ysq sing-box 管理面板  v${YSQ_VERSION}${C_RESET}"
    echo -e "${C_BOLD}==============================${C_RESET}"
    print_status_bar
    echo "状态文件: ${STATE_FILE}"
    echo "配置文件: ${CONFIG_FILE}"
    echo

    list_nodes_table || true
    echo

    echo "1)  查看节点直链"
    echo "2)  查看 Clash YAML"
    echo "3)  查看 sing-box 状态 / 监听端口"
    echo "4)  查看 sing-box 日志"
    echo "5)  添加节点 (直出 / 中转落地)"
    echo "6)  落地节点池管理 (查看 / 添加 / 修改 / 删除)"
    echo "7)  删除节点 (支持批量)"
    echo "8)  修改节点 (端口 / SNI / 出口落地)"
    echo "9)  屏蔽指定网站管理 (支持批量)"
    echo "10) 更新 sing-box 内核"
    echo "11) 重启 sing-box (可选是否重新渲染配置)"
    echo "12) 刷新公网 IP (IPv4/IPv6 切换)"
    echo "13) 更新面板 (保留数据)"
    echo "14) 删除 sing-box (彻底删除 / 保留节点数据)"
    echo "0)  退出"
    echo "=============================="
    read_line "请输入选项: " choice
    case "$choice" in
      1) act show_info ;;
      2) act show_yaml ;;
      3) act show_status ;;
      4) act show_logs ;;
      5) act add_node_wizard ;;
      6) landing_pool_menu ;;
      7) act delete_node_wizard ;;
      8) act modify_node_wizard ;;
      9) block_website_menu ;;
      10) act update_core_wizard ;;
      11) act restart_wizard ;;
      12) act refresh_ip_wizard ;;
      13) act update_panel_wizard ;;
      14) act uninstall_all ;;
      0) exit 0 ;;
      *) warn "输入错误。" ;;
    esac
  done
}

# 命令行端口参数在安装任何东西之前就校验，避免装到一半才发现端口非法
validate_cli_ports() {
  local name val
  for name in vless tuic; do
    case "$name" in
      vless) val="$CLI_VLESS" ;;
      tuic)  val="$CLI_TUIC" ;;
    esac
    [ -n "$val" ] || continue
    [ "$val" = "0" ] && continue
    if ! valid_node_port "$val"; then
      die "参数 ${name}=${val} 无效：节点端口必须在 ${MIN_NODE_PORT}-65535 之间（0 表示不创建）。"
    fi
  done
}

install_wizard() {
  need_root

  echo -e "${C_BOLD}==============================${C_RESET}"
  echo -e "${C_BOLD} ysq sing-box 一键安装脚本  v${YSQ_VERSION}${C_RESET}"
  echo -e "${C_BOLD}==============================${C_RESET}"
  echo

  validate_cli_ports

  install_deps
  install_singbox
  ensure_dirs

  # 已有状态文件：有效就沿用（不覆盖），无效则改名备份后当作全新安装
  # 修改前先留一份 .prev，渲染 / 启动失败时恢复
  local prev="${STATE_FILE}.prev" bad
  if [ -f "$STATE_FILE" ]; then
    cp -p "$STATE_FILE" "$prev"
    INSTALL_PREV_FILE="$prev"
    if state_file_valid; then
      step "沿用已有状态文件"
      ok "检测到有效的 ${STATE_FILE}：将沿用其中的 UUID / 密钥 / 节点 / 落地 / 屏蔽设置，不会覆盖。"
      ensure_state_defaults || die "状态文件规范化失败，请检查 ${STATE_FILE}。"
      refresh_ip_if_changed
    else
      bad="${STATE_FILE}.invalid.$(date +%Y%m%d%H%M%S)"
      mv -f "$STATE_FILE" "$bad"
      rm -f "$prev"
      warn "已有的状态文件无效（不是合法 JSON 或缺少必需字段），已改名备份为 ${bad}，将按全新安装处理。"
      create_state_file
    fi
  else
    create_state_file
  fi

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
  if save_self; then
    install_panel_wrapper
    PANEL_READY=1
  fi
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
    upgrade)
      upgrade_action
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}
# ENTRY_POINT
# curl ... | bash 时 stdin 是脚本内容本身，read 会把脚本剩余部分当输入吞掉。
# 只对 main 这一条命令把标准输入重定向到终端（脚本源码仍从原管道读取，已经读完，不受影响）。
if [ ! -t 0 ] && ( : </dev/tty ) 2>/dev/null; then
  main </dev/tty
else
  main
fi
