#!/usr/bin/env bash
# YSQ_CUSTOM_MULTIUSER_STATS_41453=1
# YSQ_CENTRAL_MANAGEMENT_V1=1
set -euo pipefail

# ============================================================
# ysq sing-box 一键安装 / 管理脚本
# 支持：
#   - VLESS Reality 直出 / 中转
#   - TUIC v5 直出 / 中转
#   - TCP / UDP 端口支持复用（同端口可分别运行 VLESS 和 TUIC）
#   - 独立落地节点池（支持 VLESS Reality / TUIC v5 / SOCKS5 / Shadowsocks，查看 / 添加 / 修改 / 删除，显示为“国家：ip”）
#   - 命令行安装参数（vless=端口 tuic=端口 -y）：无参数只装 sing-box 不建节点；-y 静默使用预设密钥
#   - 卸载可选「彻底删除」或「保留节点数据」；安装时发现有效的 ysq-state.db 会直接沿用，不覆盖
#   - 面板内一键「更新面板」（从 GitHub 下载新脚本，保留全部数据）
#   - 面板随时添加 / 删除 / 修改节点端口及落地出口
#   - 分流管理（域名 / Rule Set 直连与屏蔽）；中转节点支持主备落地自动切换和回切
#   - 支持 IPv4 / IPv6 入口地址选择与纯 IPv6 环境（地区检测多源 + 手动兜底）
#   - 节点入站端口要求 10000 及以上（落地节点的远端端口不受此限制）
#   - 支持 Debian / Ubuntu / CentOS / Rocky / AlmaLinux / Alpine
#
# 设计要点：
#   - 落地信息只保存在落地池 (.landings)，节点只通过 landing_id 引用
#   - 所有修改先写临时文件；配置通过 sing-box check 后才替换（低内存机器上 check 被杀时改用 jq 校验 JSON，由启动服务验证）；失败自动回滚 state
#   - 面板里每个操作都在子 shell 中运行，die 只会中止当前操作，不会退出面板
#   - 节点管理与落地管理解耦：落地的增删改只在「落地节点池管理」里做，节点只能选择已有落地
#   - 统一由 singbox-plus wrap 托管日志输出与不可变分片轮转（4 MiB × 保留 2 个历史分片），无需定时裁剪
# ============================================================

YSQ_VERSION="2026.11.27"
INSTALLER_NAME="install-singbox-ysq.sh"
DEFAULT_SCRIPT_URL="https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh"

# sing-box 内核与 singbox-plus 统一从自编译 Release 下载（支持 linux-amd64 / linux-arm64）
SINGBOX_REPO="${SINGBOX_REPO:-showcode1024/singbox-auto}"
SINGBOX_FALLBACK_VERSION="${SINGBOX_FALLBACK_VERSION:-1.14.3}"
SINGBOX_PLUS_REPO="${SINGBOX_PLUS_REPO:-$SINGBOX_REPO}"
SINGBOX_PLUS_FALLBACK_VERSION="${SINGBOX_PLUS_FALLBACK_VERSION:-0.1.1}"

# -------------------------
# 默认端口
# -------------------------
# 节点（入站）端口下限：低于该值一律拒绝（同时也避开了 1024 以下需要特权的端口）
MIN_NODE_PORT=10000
VLESS_DIRECT_PORT=20001
TUIC_DIRECT_PORT=20002
# V2Ray API 仅绑定本机回环地址，不向公网开放 gRPC。
V2RAY_API_PORT=41453
# 主备落地切换只通过本机鉴权 API 控制，不对公网开放。
FAILOVER_API_PORT=41452
# YSQ_TEST_ROOT isolates helper tests; never repurpose HOME or system environment paths.
YSQ_TEST_ROOT="${YSQ_TEST_ROOT:-}"
if [ -n "$YSQ_TEST_ROOT" ]; then
  case "$YSQ_TEST_ROOT" in
    /*) ;;
    *) printf '%s\n' 'YSQ_TEST_ROOT must be an absolute path.' >&2; exit 2 ;;
  esac
  YSQ_TEST_ROOT="${YSQ_TEST_ROOT%/}"
  case "$YSQ_TEST_ROOT" in
    ""|*'/..'*|*[[:space:]]*) printf '%s\n' 'Unsafe YSQ_TEST_ROOT.' >&2; exit 2 ;;
  esac
  export YSQ_TEST_ROOT
fi
SINGBOX_PLUS_BIN="${YSQ_TEST_ROOT}/usr/local/libexec/singbox-plus"

# -------------------------
# 预设默认参数（命令行加 -y，或交互时选择“使用默认参数”时使用）
# -------------------------
DEFAULT_UUID="a1126537-6b28-4fd3-856c-2514a7626a8b"
DEFAULT_PRIVATE_KEY="GOThQzAstrApbL92Kb-BU_7GXKOrRfNDQMK74qrEB0g"
DEFAULT_PUBLIC_KEY="pyrWuKuPUx-bt6NOFvugQEszO8XR2qYeKZhVw_dysCM"
DEFAULT_SHORT_ID="884158a048b01725"
DEFAULT_TUIC_PASS="884158a048b01725"

DEFAULT_SNI="www.python.org"
REALITY_SNI="$DEFAULT_SNI"
TUIC_SNI="$DEFAULT_SNI"

CONFIG_DIR="${YSQ_TEST_ROOT}/etc/sing-box"
CONFIG_FILE="${YSQ_TEST_ROOT}/etc/sing-box/config.json"
STATE_FILE="${YSQ_TEST_ROOT}/etc/sing-box/ysq-state.db"
CERT_DIR="${YSQ_TEST_ROOT}/etc/sing-box/cert"
CERT_FILE="${YSQ_TEST_ROOT}/etc/sing-box/cert/tuic.crt"
KEY_FILE="${YSQ_TEST_ROOT}/etc/sing-box/cert/tuic.key"
CERT_SNI_FILE="${YSQ_TEST_ROOT}/etc/sing-box/cert/tuic.sni"
LOG_FILE="${YSQ_TEST_ROOT}/var/log/sing-box/sing-box.log"
INFO_FILE="${YSQ_TEST_ROOT}/root/singbox-node-info.txt"
YAML_FILE="${YSQ_TEST_ROOT}/root/singbox-nodes.yaml"
PANEL_FILE="${YSQ_TEST_ROOT}/usr/local/bin/ysq"
INSTALLER_FILE="${YSQ_TEST_ROOT}/root/install-singbox-ysq.sh"

# Agent paths are separate from sing-box-owned directories and survive data-preserving uninstall.
AGENT_CONFIG_FILE="${YSQ_TEST_ROOT}/etc/ysq-agent/config.json"
AGENT_DATA_DIR="${YSQ_TEST_ROOT}/var/lib/ysq-agent"
AGENT_SYSTEMD_FILE="${YSQ_TEST_ROOT}/etc/systemd/system/ysq-agent.service"
AGENT_OPENRC_FILE="${YSQ_TEST_ROOT}/etc/init.d/ysq-agent"
AGENT_PID_FILE="${YSQ_TEST_ROOT}/run/ysq-agent.pid"
CONFIG_LOCK_FILE="${YSQ_TEST_ROOT}/run/ysq-config.lock"
CORE_DATA_DIR="${YSQ_TEST_ROOT}/var/lib/sing-box"
CORE_LOG_DIR="${YSQ_TEST_ROOT}/var/log/sing-box"
CORE_PID_FILE="${YSQ_TEST_ROOT}/run/sing-box.pid"
CORE_BIN_FILE="${YSQ_TEST_ROOT}/usr/local/bin/sing-box"
CORE_SYSTEMD_FILE="${YSQ_TEST_ROOT}/etc/systemd/system/sing-box.service"
CORE_OPENRC_FILE="${YSQ_TEST_ROOT}/etc/init.d/sing-box"
FAILOVER_SYSTEMD_FILE="${YSQ_TEST_ROOT}/etc/systemd/system/ysq-failover.service"
FAILOVER_OPENRC_FILE="${YSQ_TEST_ROOT}/etc/init.d/ysq-failover"
FAILOVER_PID_FILE="${YSQ_TEST_ROOT}/run/ysq-failover.pid"
FAILOVER_STATUS_FILE="${YSQ_TEST_ROOT}/var/lib/ysq-failover/status.json"

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
#   - 下载 / 证书等放在 WORK_DIR（/var/tmp 在磁盘上；/tmp 在不少系统是 tmpfs，会占内存）
#   - EXIT 时统一清理；面板每个操作结束后也会清理
# -------------------------
WORK_TAG="${BASHPID:-$$}.${RANDOM}"
WORK_DIR="${YSQ_TEST_ROOT}/var/tmp/ysq-work.${WORK_TAG}"

# 安装流程里为“覆盖状态文件前”留的备份；安装成功会删除它，退出时它还在就说明安装中途失败，
# 此时把状态恢复到安装前，并且不留下 .prev 残留
INSTALL_PREV_FILE=""

cleanup_tmp() {
  if [ -n "$INSTALL_PREV_FILE" ] && [ -f "$INSTALL_PREV_FILE" ]; then
    mv -f "$INSTALL_PREV_FILE" "$STATE_FILE" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR" 2>/dev/null || true
  rm -f "${STATE_FILE}.tmp.${WORK_TAG}."* "${CONFIG_FILE}.tmp.${WORK_TAG}."* \
    "$(dirname "$INFO_FILE")/.ysq-info.tmp.${WORK_TAG}."* \
    "$(dirname "$YAML_FILE")/.ysq-yaml.tmp.${WORK_TAG}."* \
    "${CORE_BIN_FILE}.new.${WORK_TAG}" "${SINGBOX_PLUS_BIN}.new.${WORK_TAG}" \
    "${CORE_BIN_FILE}.restore.${WORK_TAG}" "${SINGBOX_PLUS_BIN}.restore.${WORK_TAG}" 2>/dev/null || true
}
trap cleanup_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

new_work_dir() {
  mkdir -p "$WORK_DIR" || die "无法创建临时目录：$WORK_DIR"
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

AGENT_PAYLOAD=""
while [ "$#" -gt 0 ]; do
  arg="$1"
  case "$arg" in
    vless=*) CLI_VLESS="${arg#*=}" ;;
    tuic=*) CLI_TUIC="${arg#*=}" ;;
    -y|--yes) CLI_YES="1" ;;
    panel|upgrade|agent-inventory|agent-detach) set_action "$arg" ;;
    agent-apply)
      set_action "$arg"
      [ "$#" -ge 2 ] || { err "agent-apply 需要快照文件路径。"; exit 2; }
      AGENT_PAYLOAD="$2"
      shift
      ;;
    -h|--help|help) usage; exit 0 ;;
    *) err "未知参数：${arg}"; usage >&2; exit 1 ;;
  esac
  if [ "$arg" = "vless=" ] || [ "$arg" = "tuic=" ]; then
    err "参数 ${arg} 的值不能为空。"
    exit 1
  fi
  shift
done

ACTION="${ACTION:-install}"

if [ "$ACTION" != "install" ] && { [ -n "$CLI_VLESS" ] || [ -n "$CLI_TUIC" ] || [ -n "$CLI_YES" ]; }; then
  err "vless= / tuic= / -y 只能用于安装模式。"
  usage >&2
  exit 1
fi

# -------------------------
# 系统 / 包管理器 / 服务管理器
# -------------------------
OS_NAME=""
PKG_MANAGER=""
SERVICE_MANAGER=""
SING_BOX_BIN=""

load_os_release() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME="${PRETTY_NAME:-${NAME:-Linux}}"
  else
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
  if [ -n "$YSQ_TEST_ROOT" ]; then
    OS_NAME="YSQ isolated test"
    PKG_MANAGER="test"
    SERVICE_MANAGER="test"
    return 0
  fi
  load_os_release
  detect_pkg_manager
  detect_service_manager
}

pkg_update() {
  [ -z "$YSQ_TEST_ROOT" ] || { err "测试模式禁止修改系统软件包。"; return 1; }
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

# 逐个安装：一次只装一个包，降低低内存机器上包管理器的峰值内存占用；任何一个失败立即返回失败
pkg_install() {
  [ -z "$YSQ_TEST_ROOT" ] || { err "测试模式禁止修改系统软件包。"; return 1; }
  local pkg
  [ "$PKG_MANAGER" != "apt" ] || export DEBIAN_FRONTEND=noninteractive

  for pkg in "$@"; do
    case "$PKG_MANAGER" in
      apt) apt install -y "$pkg" ;;
      dnf) dnf install -y "$pkg" ;;
      yum) yum install -y "$pkg" ;;
      apk) apk add --no-cache "$pkg" ;;
    esac || return 1
  done
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

singbox_group_exists() {
  getent group sing-box >/dev/null 2>&1 || grep -q '^sing-box:' /etc/group 2>/dev/null
}

ensure_singbox_user() {
  [ -z "$YSQ_TEST_ROOT" ] || return 0
  local shell_path

  if ! singbox_group_exists; then
    if command -v groupadd >/dev/null 2>&1; then
      groupadd --system sing-box 2>/dev/null || groupadd -r sing-box 2>/dev/null || true
    elif command -v addgroup >/dev/null 2>&1; then
      addgroup -S sing-box 2>/dev/null || true
    fi
  fi
  singbox_group_exists || die "无法创建 sing-box 系统用户组。"

  if ! id sing-box >/dev/null 2>&1; then
    shell_path="$(nologin_shell)"
    if command -v useradd >/dev/null 2>&1; then
      useradd --system --no-create-home -g sing-box --shell "$shell_path" sing-box 2>/dev/null \
        || useradd -r -M -g sing-box -s "$shell_path" sing-box 2>/dev/null \
        || true
    elif command -v adduser >/dev/null 2>&1; then
      adduser -S -D -H -s "$shell_path" -G sing-box sing-box 2>/dev/null || true
    fi
  elif [ "$(id -gn sing-box 2>/dev/null || true)" != "sing-box" ]; then
    if command -v usermod >/dev/null 2>&1; then
      usermod -g sing-box sing-box 2>/dev/null || usermod -aG sing-box sing-box 2>/dev/null || true
    elif command -v addgroup >/dev/null 2>&1; then
      addgroup sing-box sing-box 2>/dev/null || true
    fi
  fi

  id sing-box >/dev/null 2>&1 || die "无法创建 sing-box 系统用户。"
  singbox_group_exists || die "无法创建 sing-box 系统用户组。"
}

normalize_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "暂不支持当前 CPU 架构：$(uname -m)（自编译包仅提供 amd64 / arm64）" ;;
  esac
}

resolve_singbox_bin() {
  if [ -x "$CORE_BIN_FILE" ]; then
    printf '%s\n' "$CORE_BIN_FILE"
  else
    command -v sing-box 2>/dev/null || true
  fi
}

singbox_bin_works() {
  local bin out
  bin="${1:-$(resolve_singbox_bin)}"
  [ -n "$bin" ] && [ -x "$bin" ] || return 1
  out="$("$bin" version 2>/dev/null)" || return 1
  printf '%s\n' "$out" | grep -q 'with_v2ray_api' \
    && printf '%s\n' "$out" | grep -q 'with_clash_api' \
    && printf '%s\n' "$out" | grep -q 'with_quic' \
    && printf '%s\n' "$out" | grep -q 'with_utls'
}

remove_broken_singbox_bins() {
  local bin
  bin="$(command -v sing-box 2>/dev/null || true)"
  if [ -n "$bin" ] && ! "$bin" version >/dev/null 2>&1; then
    warn "检测到 sing-box 可执行文件存在但无法运行：$bin"
    rm -f "$bin"
  fi

  bin="$CORE_BIN_FILE"
  if [ -e "$bin" ] && ! singbox_bin_works "$bin"; then
    warn "删除无法运行或缺少必要编译标签的 sing-box：$bin"
    rm -f "$bin"
  fi

  hash -r 2>/dev/null || true
}

valid_version() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]]
}

# 从自编译仓库获取最新版本号（优先走 /releases/latest 跳转，不受 API 限流影响）
get_latest_version() {
  local version=""

  version="$(curl -Ls --max-time 15 -o /dev/null -w '%{url_effective}' \
    "https://github.com/${SINGBOX_REPO}/releases/latest" 2>/dev/null \
    | grep -oE '[^/]+$' | sed 's/^v//')" || version=""

  if ! valid_version "$version"; then
    version="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${SINGBOX_REPO}/releases/latest" 2>/dev/null \
      | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')" || version=""
  fi

  valid_version "$version" || version=""
  echo "$version"
}

# 统一安装入口：下载自编译 tar.gz → 校验 SHA256 → 安装到 ${CORE_BIN_FILE}
# 可用 SINGBOX_VERSION=x.y.z 指定版本；否则取仓库最新 Release，取不到时用内置默认版本。
install_singbox_release() {
  local arch version base tar_name tmp_dir tar_file sums_file expect actual found_bin stage

  arch="$(normalize_arch)"
  tmp_dir="$(new_work_dir)"

  version="${SINGBOX_VERSION:-}"
  [ -n "$version" ] || version="$(get_latest_version)"
  if ! valid_version "$version"; then
    warn "无法获取最新版本号，默认安装 ${SINGBOX_FALLBACK_VERSION} 版本。"
    version="$SINGBOX_FALLBACK_VERSION"
  fi

  tar_name="sing-box-${version}-linux-${arch}.tar.gz"
  base="https://github.com/${SINGBOX_REPO}/releases/download/v${version}"
  tar_file="${tmp_dir}/${tar_name}"
  sums_file="${tmp_dir}/SHA256SUMS"

  info "正在下载自编译 sing-box ${version} / ${arch}"
  curl -fL --connect-timeout 10 --max-time 300 --speed-time 30 --speed-limit 1024 --retry 3 -o "$tar_file" "${base}/${tar_name}" \
    || die "sing-box 下载失败：${base}/${tar_name}"

  # SHA256 校验（默认 fail-closed；仅显式设置 SINGBOX_ALLOW_UNVERIFIED=1 时允许跳过缺失的 SHA256SUMS/条目）
  if curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 -o "$sums_file" "${base}/SHA256SUMS" 2>/dev/null; then
    expect="$(awk -v f="$tar_name" '{n=$2; sub(/^\.\//,"",n); sub(/^\*/,"",n); if (n==f) {print $1; exit}}' "$sums_file")"
    actual="$(sha256sum "$tar_file" | awk '{print $1}')"
    if [ -z "$expect" ]; then
      if [ "${SINGBOX_ALLOW_UNVERIFIED:-0}" = "1" ]; then
        warn "SHA256SUMS 中没有 ${tar_name}，已按 SINGBOX_ALLOW_UNVERIFIED=1 跳过校验。"
      else
        rm -rf "$tmp_dir"
        die "SHA256SUMS 中缺少 ${tar_name} 校验记录，已拒绝安装（如确需跳过，请显式设置 SINGBOX_ALLOW_UNVERIFIED=1）。"
      fi
    elif ! [[ "$expect" =~ ^[0-9a-fA-F]{64}$ ]] || ! [[ "$actual" =~ ^[0-9a-fA-F]{64}$ ]] || [ "${expect,,}" != "${actual,,}" ]; then
      rm -rf "$tmp_dir"
      die "sing-box 压缩包 SHA256 校验失败（期望 ${expect:-缺失}，实际 ${actual:-未知}）。"
    else
      ok "SHA256 校验通过。"
    fi
  elif [ "${SINGBOX_ALLOW_UNVERIFIED:-0}" = "1" ]; then
    warn "未能下载 SHA256SUMS，已按 SINGBOX_ALLOW_UNVERIFIED=1 跳过完整性校验。"
  else
    rm -rf "$tmp_dir"
    die "无法下载 sing-box SHA256SUMS 校验文件，已拒绝安装（如确需跳过，请显式设置 SINGBOX_ALLOW_UNVERIFIED=1）。"
  fi

  tar -xzf "$tar_file" -C "$tmp_dir" || die "sing-box 解压失败。"

  found_bin="$(find "$tmp_dir" -type f -name sing-box | head -n 1)"
  [ -n "$found_bin" ] || die "下载包里未找到 sing-box 可执行文件。"

  mkdir -p "$(dirname "$CORE_BIN_FILE")"
  stage="${CORE_BIN_FILE}.new.${WORK_TAG}"
  install -m 755 "$found_bin" "$stage"
  mv -f "$stage" "$CORE_BIN_FILE"
  rm -rf "$tmp_dir"
  hash -r 2>/dev/null || true
}

singbox_plus_works() {
  local bin="${1:-$SINGBOX_PLUS_BIN}"
  [ -n "$bin" ] && [ -x "$bin" ] || return 1
  "$bin" version >/dev/null 2>&1
}

singbox_plus_current_version() {
  local bin="${1:-$SINGBOX_PLUS_BIN}" ver=""
  [ -n "$bin" ] && [ -x "$bin" ] || return 0
  ver="$("$bin" version 2>/dev/null | head -n 1 | awk '{print ($2 != "" ? $2 : $1)}' || true)"
  ver="${ver#v}"
  printf '%s\n' "$ver"
}

get_latest_singbox_plus_version() {
  local version="" page resp count

  for page in 1 2 3; do
    resp="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${SINGBOX_PLUS_REPO}/releases?per_page=100&page=${page}" 2>/dev/null)" || break
    count="$(printf '%s' "$resp" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null)" || break
    [ "${count:-0}" -gt 0 ] || break
    version="$(printf '%s' "$resp" \
      | jq -r '[.[] | select(.draft != true and .prerelease != true) | .tag_name | select(test("^singbox-plus-v[0-9]+\\.[0-9]+\\.[0-9]+$")) | sub("^singbox-plus-v"; "")] | sort_by(split(".") | map(tonumber)) | last // empty' 2>/dev/null)" || version=""
    if valid_version "$version"; then
      break
    fi
    [ "$count" -eq 100 ] || break
  done

  if ! valid_version "$version"; then
    version="$(curl -fsSL --max-time 15 "https://github.com/${SINGBOX_PLUS_REPO}/tags" 2>/dev/null \
      | grep -oE 'singbox-plus-v[0-9]+\.[0-9]+\.[0-9]+' \
      | sed 's/^singbox-plus-v//' \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | tail -n 1)" || version=""
  fi

  valid_version "$version" || version=""
  echo "$version"
}

# 下载 singbox-plus Release 并强制校验 SHA256SUMS（失败返回 1，不 die，便于上层决定回滚）
install_singbox_plus_release() {
  local arch version base tar_name tmp_dir tar_file sums_file expect actual found_bin stage

  [ -z "$YSQ_TEST_ROOT" ] || { err "隔离测试模式禁止联网下载 singbox-plus。"; return 1; }
  arch="$(normalize_arch)"
  tmp_dir="$(new_work_dir)" || return 1

  version="${SINGBOX_PLUS_VERSION:-}"
  [ -n "$version" ] || version="$(get_latest_singbox_plus_version)"
  if ! valid_version "$version"; then
    warn "无法获取 singbox-plus 最新版本号，默认安装 ${SINGBOX_PLUS_FALLBACK_VERSION} 版本。"
    version="$SINGBOX_PLUS_FALLBACK_VERSION"
  fi

  tar_name="singbox-plus-${version}-linux-${arch}.tar.gz"
  base="https://github.com/${SINGBOX_PLUS_REPO}/releases/download/singbox-plus-v${version}"
  tar_file="${tmp_dir}/${tar_name}"
  sums_file="${tmp_dir}/SHA256SUMS"

  info "正在下载 singbox-plus ${version} / ${arch}"
  if ! curl -fL --connect-timeout 10 --max-time 300 --speed-time 30 --speed-limit 1024 --retry 3 -o "$tar_file" "${base}/${tar_name}"; then
    err "singbox-plus 下载失败：${base}/${tar_name}"
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 -o "$sums_file" "${base}/SHA256SUMS"; then
    err "无法下载 singbox-plus 官方 SHA256SUMS 校验文件，已拒绝安装。"
    rm -rf "$tmp_dir"
    return 1
  fi

  expect="$(awk -v f="$tar_name" '{n=$2; sub(/^\.\//,"",n); sub(/^\*/,"",n); if (n==f) {print $1; exit}}' "$sums_file")"
  actual="$(sha256sum "$tar_file" | awk '{print $1}')"
  if ! [[ "$expect" =~ ^[0-9a-fA-F]{64}$ ]] || ! [[ "$actual" =~ ^[0-9a-fA-F]{64}$ ]] || [ "${expect,,}" != "${actual,,}" ]; then
    err "singbox-plus SHA256 校验失败（期望 ${expect:-缺失}，实际 ${actual:-未知}），已拒绝安装。"
    rm -rf "$tmp_dir"
    return 1
  fi
  ok "singbox-plus SHA256 校验通过。"

  if ! tar -xzf "$tar_file" -C "$tmp_dir"; then
    err "singbox-plus 解压失败。"
    rm -rf "$tmp_dir"
    return 1
  fi

  found_bin="$(find "$tmp_dir" -type f -name singbox-plus | head -n 1)"
  if [ -z "$found_bin" ]; then
    err "下载包里未找到 singbox-plus 可执行文件。"
    rm -rf "$tmp_dir"
    return 1
  fi

  mkdir -p "$(dirname "$SINGBOX_PLUS_BIN")" || { rm -rf "$tmp_dir"; return 1; }
  stage="${SINGBOX_PLUS_BIN}.new.${WORK_TAG}"
  if ! install -m 755 "$found_bin" "$stage" || ! mv -f "$stage" "$SINGBOX_PLUS_BIN"; then
    rm -f "$stage"
    rm -rf "$tmp_dir"
    err "安装 singbox-plus 到 ${SINGBOX_PLUS_BIN} 失败。"
    return 1
  fi
  rm -rf "$tmp_dir"

  if ! singbox_plus_works "$SINGBOX_PLUS_BIN"; then
    rm -f "$SINGBOX_PLUS_BIN"
    err "singbox-plus 无法运行，请检查 CPU 架构。"
    return 1
  fi
  ok "singbox-plus 安装完成：$("$SINGBOX_PLUS_BIN" version 2>/dev/null | head -n 1)"
}

ensure_singbox_plus() {
  local force="${1:-}"
  if [ "$force" != "force" ] && singbox_plus_works "$SINGBOX_PLUS_BIN"; then
    return 0
  fi
  if [ -e "$SINGBOX_PLUS_BIN" ] && ! singbox_plus_works "$SINGBOX_PLUS_BIN"; then
    warn "检测到 singbox-plus 存在但无法运行，将重新安装。"
    rm -f "$SINGBOX_PLUS_BIN"
  fi
  install_singbox_plus_release
}

upgrade_singbox_plus_if_outdated() {
  local cur_ver="" latest_ver=""
  [ -z "$YSQ_TEST_ROOT" ] || return 0
  singbox_plus_works "$SINGBOX_PLUS_BIN" || return 0

  cur_ver="$(singbox_plus_current_version "$SINGBOX_PLUS_BIN")"
  latest_ver="${SINGBOX_PLUS_VERSION:-}"
  [ -n "$latest_ver" ] || latest_ver="$(get_latest_singbox_plus_version)"
  latest_ver="${latest_ver#v}"

  if ! valid_version "$latest_ver"; then
    return 0
  fi
  if [ "$cur_ver" = "$latest_ver" ]; then
    return 0
  fi

  info "检测到 singbox-plus 新版本：${cur_ver:-未知} -> ${latest_ver}，正在同步更新..."
  SINGBOX_PLUS_VERSION="$latest_ver" ensure_singbox_plus force \
    || warn "singbox-plus 更新失败，继续使用当前版本 (${cur_ver:-未知})。"
}

# 仅当内容变化时才覆盖目标文件；内容有变化返回 0，无变化返回 1
install_if_changed() {
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    return 1
  fi
  install -m "$mode" "$src" "$dest"
}

# 清理旧版本遗留的日志裁剪脚本、timer、cron、grpcurl 与 Python failover worker
cleanup_legacy_log_trim() {
  local legacy_crontab="${YSQ_TEST_ROOT}/etc/crontabs/root"
  local had_systemd_unit=0
  if [ -e "${YSQ_TEST_ROOT}/etc/systemd/system/ysq-log-trim.timer" ] \
      || [ -e "${YSQ_TEST_ROOT}/etc/systemd/system/ysq-log-trim.service" ]; then
    had_systemd_unit=1
  fi
  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    systemctl disable --now ysq-log-trim.timer >/dev/null 2>&1 || true
    systemctl stop ysq-log-trim.service >/dev/null 2>&1 || true
  fi
  rm -f \
    "${YSQ_TEST_ROOT}/usr/local/libexec/ysq-singbox-log-trim" \
    "${YSQ_TEST_ROOT}/etc/systemd/system/ysq-log-trim.timer" \
    "${YSQ_TEST_ROOT}/etc/systemd/system/ysq-log-trim.service" \
    "${YSQ_TEST_ROOT}/etc/periodic/hourly/ysq-singbox-log-trim" \
    "${YSQ_TEST_ROOT}/run/ysq-log-trim.lock" \
    "${YSQ_TEST_ROOT}/usr/local/libexec/ysq-grpcurl" \
    "${YSQ_TEST_ROOT}/usr/local/libexec/ysq-failover.py"
  if [ -f "$legacy_crontab" ] && grep -q '# ysq-log-trim$' "$legacy_crontab" 2>/dev/null; then
    sed -i '/# ysq-log-trim$/d' "$legacy_crontab"
  fi
  if [ "$had_systemd_unit" -eq 1 ]; then
    service_daemon_reload
  fi
}

# 只在安装 / 更新内核时调用；restart_singbox 不再重写 unit
ensure_singbox_service() {
  local wd

  SING_BOX_BIN="$(resolve_singbox_bin)"
  if [ -z "$SING_BOX_BIN" ]; then
    die "未找到 sing-box 可执行文件。"
  fi
  ensure_singbox_plus || die "未找到可用的 singbox-plus 可执行文件。"

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
ExecStart=${SINGBOX_PLUS_BIN} wrap --dir ${CORE_LOG_DIR} --name sing-box.log --max 4M --keep 2 -- ${SING_BOX_BIN} -D ${CORE_DATA_DIR} -c ${CONFIG_FILE} run
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
      if install_if_changed "$wd/unit" "$CORE_SYSTEMD_FILE" 644; then
        service_daemon_reload
      fi
      cleanup_legacy_log_trim
      ;;
    openrc)
      cat > "$wd/unit" <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="${SINGBOX_PLUS_BIN}"
command_args="wrap --dir ${CORE_LOG_DIR} --name sing-box.log --max 4M --keep 2 -- ${SING_BOX_BIN} -D ${CORE_DATA_DIR} -c ${CONFIG_FILE} run"
command_user="sing-box:sing-box"
command_background="yes"
pidfile="${CORE_PID_FILE}"
output_log="/dev/null"
error_log="/dev/null"

start_pre() {
  checkpath -d -m 0755 -o sing-box:sing-box "${CORE_DATA_DIR}"
  checkpath -d -m 0755 -o sing-box:sing-box "${CORE_LOG_DIR}"
}

depend() {
  need net
  after firewall
}
EOF
      install_if_changed "$wd/unit" "$CORE_OPENRC_FILE" 755 || true
      cleanup_legacy_log_trim
      ;;
    none)
      warn "未检测到 systemd/openrc，将使用 nohup 后台方式管理 sing-box。"
      cleanup_legacy_log_trim
      ;;
  esac

  rm -rf "$wd"
}

service_enable() {
  [ "$SERVICE_MANAGER" != "test" ] || return 0
  case "$SERVICE_MANAGER" in
    systemd) systemctl enable sing-box >/dev/null 2>&1 || true ;;
    openrc) rc-update add sing-box default >/dev/null 2>&1 || true ;;
    none) return 0 ;;
  esac
}

service_disable() {
  [ "$SERVICE_MANAGER" != "test" ] || return 0
  case "$SERVICE_MANAGER" in
    systemd) systemctl disable sing-box >/dev/null 2>&1 || true ;;
    openrc) rc-update del sing-box default >/dev/null 2>&1 || true ;;
    none) return 0 ;;
  esac
}

list_residual_singbox_pids() {
  local proc_dir proc_pid proc_cmd
  for proc_dir in /proc/[0-9]*; do
    [ -r "${proc_dir}/cmdline" ] || continue
    proc_pid="${proc_dir#/proc/}"
    [ "$proc_pid" != "$$" ] && [ "$proc_pid" != "${BASHPID:-$$}" ] || continue
    proc_cmd="$(tr '\0' ' ' < "${proc_dir}/cmdline" 2>/dev/null || true)"
    if [[ "$proc_cmd" == *sing-box* ]] && [[ "$proc_cmd" == *" ${CONFIG_FILE} "* ]] \
        && [[ "$proc_cmd" == *" -c "* || "$proc_cmd" == *" -C "* ]] && [[ "$proc_cmd" == *" run"* ]]; then
      printf '%s\n' "$proc_pid"
    fi
  done
  return 0
}

service_stop() {
  state_write_guard || return $?
  flush_agent_traffic
  if [ "$SERVICE_MANAGER" = "test" ]; then
    rm -f "${YSQ_TEST_ROOT}/run/test-singbox-running"
    return 0
  fi
  case "$SERVICE_MANAGER" in
    systemd) systemctl stop sing-box 2>/dev/null || true ;;
    openrc) rc-service sing-box stop 2>/dev/null || true ;;
    none)
      if [ -f "$CORE_PID_FILE" ]; then
        local old_pid cmdline=""
        old_pid="$(cat "$CORE_PID_FILE" 2>/dev/null || true)"
        case "$old_pid" in
          ''|*[!0-9]*) ;;
          *)
            if [ -r "/proc/${old_pid}/cmdline" ]; then
              cmdline="$(tr '\0' ' ' < "/proc/${old_pid}/cmdline" 2>/dev/null || true)"
            fi
            if [[ "$cmdline" == *singbox-plus* || "$cmdline" == *sing-box* ]]; then
              kill "$old_pid" 2>/dev/null || true
              # 等旧进程真正退出（最多 15 秒），否则重启时新进程可能和旧进程抢端口
              for _ in $(seq 1 15); do
                kill -0 "$old_pid" 2>/dev/null || break
                sleep 1
              done
              if [ -r "/proc/${old_pid}/cmdline" ]; then
                cmdline="$(tr '\0' ' ' < "/proc/${old_pid}/cmdline" 2>/dev/null || true)"
                if [[ "$cmdline" == *singbox-plus* || "$cmdline" == *sing-box* ]]; then
                  kill -9 "$old_pid" 2>/dev/null || true
                fi
              fi
            fi
            ;;
        esac
        rm -f "$CORE_PID_FILE"
      fi
      local residual_pids="" rpid i
      if command -v pkill >/dev/null 2>&1; then
        pkill -f "sing-box.*-[cC] ${CONFIG_FILE}.*run" 2>/dev/null || true
      else
        while IFS= read -r rpid; do
          [ -n "$rpid" ] || continue
          kill "$rpid" 2>/dev/null || true
        done < <(list_residual_singbox_pids)
      fi
      # 最多等待 10 秒确认残留进程已完全退出，超时则强制结束，避免重启抢端口失败
      for i in 1 2 3 4 5 6 7 8 9 10; do
        residual_pids="$(list_residual_singbox_pids)"
        [ -n "$residual_pids" ] || break
        sleep 1
      done
      residual_pids="$(list_residual_singbox_pids)"
      if [ -n "$residual_pids" ]; then
        if command -v pkill >/dev/null 2>&1; then
          pkill -9 -f "sing-box.*-[cC] ${CONFIG_FILE}.*run" 2>/dev/null || true
        fi
        while IFS= read -r rpid; do
          [ -n "$rpid" ] || continue
          kill -9 "$rpid" 2>/dev/null || true
        done <<< "$residual_pids"
        sleep 1
      fi
      ;;
  esac
}

# 失败返回 1（不 die），方便上层回滚
service_restart() {
  state_write_guard || return $?
  flush_agent_traffic
  if [ "$SERVICE_MANAGER" = "test" ]; then
    if [ -f "${YSQ_TEST_ROOT}/run/test-restart-fail-once" ]; then
      rm -f "${YSQ_TEST_ROOT}/run/test-restart-fail-once" "${YSQ_TEST_ROOT}/run/test-singbox-running"
      return 1
    fi
    [ ! -f "${YSQ_TEST_ROOT}/run/test-restart-fail" ] || return 1
    mkdir -p "${YSQ_TEST_ROOT}/run"
    : > "${YSQ_TEST_ROOT}/run/test-singbox-running"
    printf '%s\n' restart >> "${YSQ_TEST_ROOT}/run/test-restarts"
    return 0
  fi
  case "$SERVICE_MANAGER" in
    systemd)
      if ! systemctl restart sing-box 9>&-; then
        err "systemctl restart sing-box 失败。"
        [ ! -f "$LOG_FILE" ] || tail -n 20 "$LOG_FILE" >&2
        journalctl -u sing-box -n 20 --no-pager 2>/dev/null >&2 || true
        return 1
      fi
      sleep 1
      if ! systemctl is-active --quiet sing-box; then
        err "sing-box 启动后异常退出。"
        [ ! -f "$LOG_FILE" ] || tail -n 20 "$LOG_FILE" >&2
        journalctl -u sing-box -n 20 --no-pager 2>/dev/null >&2 || true
        return 1
      fi
      ;;
    openrc)
      if ! rc-service sing-box restart 9>&-; then
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
      YSQ_SKIP_AGENT_FLUSH=1 service_stop
      SING_BOX_BIN="$(resolve_singbox_bin)"
      if [ -z "$SING_BOX_BIN" ]; then
        err "未找到 sing-box 可执行文件。"
        return 1
      fi
      ensure_singbox_plus || return 1
      install -d -m 755 -o sing-box -g sing-box "$CORE_DATA_DIR" "$CORE_LOG_DIR" 2>/dev/null \
        || mkdir -p "$CORE_DATA_DIR" "$CORE_LOG_DIR"
      chown -R sing-box:sing-box "$CORE_DATA_DIR" "$CORE_LOG_DIR" 2>/dev/null || true
      mkdir -p "$(dirname "$CORE_PID_FILE")" || return 1
      if id sing-box >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 \
          && runuser -u sing-box -g sing-box -- true >/dev/null 2>&1; then
        nohup runuser -u sing-box -g sing-box -- "$SINGBOX_PLUS_BIN" wrap --dir "$CORE_LOG_DIR" --name sing-box.log --max 4M --keep 2 -- "$SING_BOX_BIN" -D "$CORE_DATA_DIR" -c "$CONFIG_FILE" run </dev/null 9>&- >/dev/null 2>&1 &
      else
        nohup "$SINGBOX_PLUS_BIN" wrap --dir "$CORE_LOG_DIR" --name sing-box.log --max 4M --keep 2 -- "$SING_BOX_BIN" -D "$CORE_DATA_DIR" -c "$CONFIG_FILE" run </dev/null 9>&- >/dev/null 2>&1 &
      fi
      echo $! > "$CORE_PID_FILE"
      sleep 1
      if ! kill -0 "$(cat "$CORE_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        [ ! -f "$LOG_FILE" ] || tail -n 20 "$LOG_FILE" >&2 || true
        err "sing-box 后台启动失败。"
        return 1
      fi
      ;;
  esac
  sync_failover_service || warn "主备切换服务启动失败，请查看 ysq-failover 状态；sing-box 仍按当前落地运行。"
  return 0
}

service_status() {
  if [ "$SERVICE_MANAGER" = "test" ]; then is_singbox_running; return $?; fi
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
      if is_singbox_running; then
        ok "sing-box 正在运行，PID: $(get_singbox_pid)"
      else
        warn "sing-box 未运行。"
      fi
      echo
      tail -n 80 "$LOG_FILE" 2>/dev/null || true
      ;;
  esac
}

service_daemon_reload() {
  [ "$SERVICE_MANAGER" != "test" ] || return 0
  case "$SERVICE_MANAGER" in
    systemd) systemctl daemon-reload 2>/dev/null || true ;;
    openrc|none) return 0 ;;
  esac
}

# -------------------------
# 状态栏辅助函数（运行状态 / 版本 / 内存）
# -------------------------
is_singbox_running() {
  if [ "$SERVICE_MANAGER" = "test" ]; then
    [ -f "${YSQ_TEST_ROOT}/run/test-singbox-running" ]
    return $?
  fi
  case "$SERVICE_MANAGER" in
    systemd) systemctl is-active --quiet sing-box 2>/dev/null ;;
    openrc)  rc-service sing-box status >/dev/null 2>&1 ;;
    none)
      local pid=""
      [ -f "$CORE_PID_FILE" ] && pid="$(cat "$CORE_PID_FILE" 2>/dev/null || true)"
      [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
        && [ -r "/proc/${pid}/cmdline" ] \
        && tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -Eq 'singbox-plus|sing-box'
      ;;
  esac
}

get_singbox_pid() {
  [ "$SERVICE_MANAGER" != "test" ] || return 0
  local main_pid="" pid="" cpid comm=""
  case "$SERVICE_MANAGER" in
    systemd)
      main_pid="$(systemctl show -p MainPID --value sing-box 2>/dev/null || true)"
      [ "$main_pid" = "0" ] && main_pid=""
      ;;
    openrc|none)
      if [ -f "$CORE_PID_FILE" ]; then
        main_pid="$(cat "$CORE_PID_FILE" 2>/dev/null || true)"
      fi
      ;;
  esac

  if [[ "$main_pid" =~ ^[0-9]+$ ]] && [ -d "/proc/${main_pid}" ]; then
    comm="$(cat "/proc/${main_pid}/comm" 2>/dev/null || true)"
    if [ "$comm" = "sing-box" ]; then
      pid="$main_pid"
    else
      # singbox-plus wrap 是多线程 Go 进程，子进程可能挂在任意 task/<tid>/children 下
      for cpid in $(cat "/proc/${main_pid}/task/"*/children 2>/dev/null || true); do
        if [[ "$cpid" =~ ^[0-9]+$ ]] && [ "$(cat "/proc/${cpid}/comm" 2>/dev/null || true)" = "sing-box" ]; then
          pid="$cpid"
          break
        fi
      done
      if [ -z "$pid" ] && command -v pgrep >/dev/null 2>&1; then
        pid="$(pgrep -P "$main_pid" -x sing-box 2>/dev/null | head -n 1 || true)"
      fi
    fi
  fi

  if [ -z "$pid" ] && command -v pidof >/dev/null 2>&1; then
    pid="$(pidof sing-box 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [ -z "$pid" ] && command -v pgrep >/dev/null 2>&1; then
    pid="$(pgrep -f "sing-box.*-[cC] ${CONFIG_FILE}.*run" 2>/dev/null | head -n 1 || true)"
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
  local status_str ver_str mem_str sb_bin=""
  sb_bin="$(resolve_singbox_bin)"
  if [ -n "$sb_bin" ]; then
    ver_str="$("$sb_bin" version 2>/dev/null | awk 'NR==1 {print $3}' || true)"
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

# 主菜单常驻监听摘要：全部正常时只显示「正常」，异常时列出具体协议和端口。
print_listen_summary() {
  local tcp_bound="" udp_bound="" p
  local tcp_missing="" udp_missing="" issues=""
  local active_users=0 node_count=0

  if ! command -v ss >/dev/null 2>&1; then
    echo -e "监听端口: ${C_RED}○ 无法检测（缺少 ss）${C_RESET}"
    return 0
  fi

  tcp_bound="$(ss -H -lnt 2>/dev/null | awk '{s=$4; sub(/^.*:/,"",s); if(s~/^[0-9]+$/) print s}' | sort -u || true)"
  udp_bound="$(ss -H -lnu 2>/dev/null | awk '{s=$4; sub(/^.*:/,"",s); if(s~/^[0-9]+$/) print s}' | sort -u || true)"

  if [ -f "$STATE_FILE" ]; then
    active_users="$(jq -r '[.users[]? | select(.enabled != false)] | length' "$STATE_FILE" 2>/dev/null || echo 0)"
    node_count="$(jq -r '(.nodes // []) | length' "$STATE_FILE" 2>/dev/null || echo 0)"
    [[ "$active_users" =~ ^[0-9]+$ ]] || active_users=0
    [[ "$node_count" =~ ^[0-9]+$ ]] || node_count=0

    if [ "$active_users" -gt 0 ]; then
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! printf '%s\n' "$tcp_bound" | grep -Fxq "$p"; then
          tcp_missing="${tcp_missing:+${tcp_missing},}${p}"
        fi
      done < <(jq -r '.nodes[]? | select((.protocol // "tcp") == "tcp") | .port' "$STATE_FILE" | sort -nu)

      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! printf '%s\n' "$udp_bound" | grep -Fxq "$p"; then
          udp_missing="${udp_missing:+${udp_missing},}${p}"
        fi
      done < <(jq -r '.nodes[]? | select((.protocol // "tcp") == "udp") | .port' "$STATE_FILE" | sort -nu)
    fi
  fi

  [ -z "$tcp_missing" ] || issues="TCP ${tcp_missing} 未监听"
  [ -z "$udp_missing" ] || issues="${issues:+${issues} | }UDP ${udp_missing} 未监听"
  if ! printf '%s\n' "$tcp_bound" | grep -Fxq "$V2RAY_API_PORT"; then
    issues="${issues:+${issues} | }API ${V2RAY_API_PORT} 未监听"
  fi

  if [ -z "$issues" ]; then
    if [ "$active_users" -eq 0 ] && [ "$node_count" -gt 0 ]; then
      echo -e "监听端口: ${C_GREEN}● 正常${C_RESET}（当前无启用用户，入站监听已暂停）"
    else
      echo -e "监听端口: ${C_GREEN}● 正常${C_RESET}"
    fi
  else
    echo -e "监听端口: ${C_RED}○ 异常${C_RESET} | ${issues}"
  fi
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

def table($headers; $mins; $rows):
  ($headers | length) as $cols |
  [range(0; $cols) as $c |
    ([$mins[$c], ($headers[$c] | dwidth), ($rows[]?[$c] | dwidth)] | max)
  ] as $widths |
  def row($cells):
    ([range(0; $cols - 1) as $c | ($cells[$c] | pad($widths[$c]))]
     + [$cells[$cols - 1]]) | join("  ");
  row($headers),
  ([range(0; $cols) as $c | dash($widths[$c])] | join("  ")),
  ($rows[] | row(.));
'

# 节点类型文案、自动命名与去重共用同一份 jq 规则。
JQ_NODE_LIB='
def landing_type_info($landing_type):
  if $landing_type == "tuic" then {suffix:"tuic5", display:"TUIC v5", table:"TUIC v5"}
  elif $landing_type == "socks" then {suffix:"socks5", display:"SOCKS5", table:"SOCKS5"}
  elif $landing_type == "shadowsocks" then {suffix:"ss", display:"SS", table:"Shadowsocks"}
  else {suffix:"vless", display:"VLESS", table:"VLESS"} end;

def node_labels($type; $out; $landing_type):
  landing_type_info($landing_type) as $lt |
  $lt.suffix as $target |
  $lt.display as $target_display |
  if ($type | startswith("vless")) then
    if $out == "landing" then {suffix:("vless转"+$target), display:("VLESS -> "+$target_display+" 中转")}
    else {suffix:"vless", display:"VLESS 直出"} end
  elif ($type | startswith("tuic")) then
    if $out == "landing" then {suffix:("tuic5转"+$target), display:("TUIC v5 -> "+$target_display+" 中转")}
    else {suffix:"tuic5", display:"TUIC v5 直出"} end
  else
    {suffix:(if $out == "landing" then "relay" else "node" end), display:$type}
  end;

def node_labels($type; $out): node_labels($type; $out; "vless");
def node_type_name($type; $out): node_labels($type; $out).display;
def landing_type_for($s; $n):
  ((first($s.landings[]? | select(.id == ($n.landing_id // ""))) | .type) // "vless");
def node_type_name_for($s; $n): node_labels($n.type; ($n.outbound_type // "direct"); landing_type_for($s; $n)).display;

def node_auto_name($s; $n; $region):
  ($n.outbound_type // "direct") as $out |
  (if $region != "" then $region
   else ((first($s.landings[]? | select(.id == ($n.landing_id // ""))) | .display) // ""
         | split("：")[0]) end) as $landing_region |
  (($s.location_flag // "🌐") + ($s.location_name // "未知地区") + "-"
   + node_labels($n.type; $out; landing_type_for($s; $n)).suffix
   + (if $out == "landing" and $landing_region != "" then "-" + $landing_region else "" end)) as $base |
  ($base + "-" + ($n.port | tostring)) as $with_port |
  ($with_port + "-" + ($n.type | split("-")[0])) as $with_type |
  [$s.nodes[]? | select(.tag != ($n.tag // "")) | .name] as $used |
  first(
    ($base, $with_port, $with_type,
     (range(2; ($used | length) + 3) | $with_type + "-" + tostring))
    | select(. as $candidate | $used | index($candidate) | not)
  );
'

# -------------------------
# 通用工具
# -------------------------
need_root() {
  [ -z "$YSQ_TEST_ROOT" ] || return 0
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

# 序号校验：$1 是 1..$2 之间的整数（最多 6 位）
valid_index() {
  [[ "${1:-}" =~ ^[0-9]{1,6}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le "$2" ]
}

# 列表输入规整：中英文逗号当空格，并去掉首尾空白
split_input() {
  local s="$1"
  s="${s//，/ }"
  s="${s//,/ }"
  trim "$s"
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

# 用法：confirm_or_cancel <提示> [默认答案=n] [取消提示=已取消。]
# 返回 0 表示确认，CANCEL_RC 表示取消；调用方显式传递返回码，不能只依赖 set -e。
# 取消提示传空字符串时保持静默。
confirm_or_cancel() {
  local prompt="$1" default_answer="${2:-n}" cancel_message="${3-已取消。}" answer=""
  read_line "$prompt" answer
  answer="${answer:-$default_answer}"
  if [ "${answer,,}" = "y" ]; then
    return 0
  fi
  if [ -n "$cancel_message" ]; then
    warn "$cancel_message"
  fi
  return "$CANCEL_RC"
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
  local lines="" foreign=""

  if [ "$proto" = "tcp" ] && [ "$port" = "$V2RAY_API_PORT" ]; then
    die "TCP 端口 ${V2RAY_API_PORT} 已预留给本机 V2Ray API，请换一个 VLESS 端口。"
  fi
  if [ "$proto" = "tcp" ] && [ "$port" = "$FAILOVER_API_PORT" ]; then
    die "TCP 端口 ${FAILOVER_API_PORT} 已预留给主备切换本机 API，请换一个 VLESS 端口。"
  fi

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
  if [ "${CLI_YES:-}" = "1" ]; then
    die "静默模式（-y）下检测到端口 ${port} (${proto^^}) 已被其他程序占用，已中止安装；请更换端口或释放该端口后重试。"
  fi
  confirm_or_cancel "仍然继续使用这个端口？输入 y 继续: " || return $?
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
    err="$(LC_ALL=C timeout "$timeout_sec" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>&1)" && return 0
    # bash 编译时没带 /dev/tcp 支持：报 No such file or directory，才换下一种；否则（超时 124 / 被拒绝）直接判失败
    case "$err" in
      *"No such file or directory"*|*"not supported"*) ;;
      *) return 1 ;;
    esac
  fi

  # 2. nc（-w 是连接超时）；只有 nc 不认 -z / -w 参数时才换 curl
  if command -v nc >/dev/null 2>&1; then
    err="$(LC_ALL=C nc -z -w "$timeout_sec" "$host" "$port" 2>&1)" && return 0
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

  info "正在预检落地节点 TCP 连通性 (${server}:${port})..."
  if test_tcp_connect "$server" "$port" 5; then
    ok "落地节点 TCP 连通性检测通过 (${server}:${port})。"
    return 0
  fi

  warn "无法连接到落地节点 ${server}:${port}（TCP 连接超时、被拒绝或防火墙未放行）。"
  confirm_or_cancel "是否仍然继续保存该落地节点？输入 y 继续: " n "已取消保存落地节点。" || return $?
  return 0
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

# 按两位国家码选择默认 SNI（Reality 与 TUIC 共用）
default_sni_for_country() {
  local code
  code="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
  case "$code" in
    JP) echo "www.sony.jp" ;;
    SG) echo "www.grab.com" ;;
    KR) echo "www.naver.com" ;;
    HK) echo "www.hku.hk" ;;
    US) echo "www.airbnb.com" ;;
    TW) echo "www.gskill.com" ;;
    *)  echo "${DEFAULT_SNI:-www.python.org}" ;;
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

node_type_name() {
  if [ -n "${3:-}" ] && [ -f "$STATE_FILE" ]; then
    jq -r --arg tag "$3" "$JQ_NODE_LIB"'. as $s | first(.nodes[]? | select(.tag==$tag)) | node_type_name_for($s; .)' "$STATE_FILE"
  else
    jq -nr --arg type "$1" --arg out "${2:-direct}" \
      "$JQ_NODE_LIB"'node_type_name($type; $out)'
  fi
}

# 生成节点名称：
#   - 中转节点自动带上落地地区标识（例如：🇭🇰香港-vless转vless-🇸🇬新加坡）
#   - 重名时依次追加端口、类型、序号；ignore_tag 排除正在修改的节点自身
make_node_name() {
  jq -r --arg type "$1" --arg port "$2" --arg out "${3:-direct}" \
    --arg lid "${4:-}" --arg tag "${5:-}" --arg region "${6:-}" \
    "$JQ_NODE_LIB"'
      node_auto_name(.; {type:$type, port:$port, outbound_type:$out, landing_id:$lid, tag:$tag}; $region)
    ' "$STATE_FILE"
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
  if ! command -v flock >/dev/null 2>&1; then
    missing+=("$(config_lock_package)")
  fi

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

  [ "$PKG_MANAGER" != "apk" ] || update-ca-certificates 2>/dev/null || true

  ok "必要依赖已就绪。"
}

# $1 = force：即使已安装可用的 sing-box 也重新下载安装（更新内核时用）
install_singbox() {
  local force="${1:-}" sb_bin=""

  step "安装 / 检查 sing-box"

  ensure_singbox_user
  # 安装、面板升级和内核更新共用运行目录准备；配置目录由安装 / 面板升级另行准备。
  mkdir -p "$CORE_DATA_DIR" "$CORE_LOG_DIR"
  chown -R sing-box:sing-box "$CORE_DATA_DIR" "$CORE_LOG_DIR" 2>/dev/null || true
  chmod 755 "$CORE_DATA_DIR" "$CORE_LOG_DIR"
  remove_broken_singbox_bins

  if [ "$force" != "force" ] && singbox_bin_works; then
    sb_bin="$(resolve_singbox_bin)"
    ok "检测到 sing-box 已安装：$("$sb_bin" version | head -n 1)"
  else
    info "正在安装 sing-box..."
    install_singbox_release
    singbox_bin_works "$CORE_BIN_FILE" || die "当前系统无法执行 sing-box 或缺少必要编译标签，请检查 CPU 架构。"
    ok "sing-box 安装完成：$("$CORE_BIN_FILE" version | head -n 1)"
  fi

  if [ "$force" = "force" ] && singbox_plus_works "$SINGBOX_PLUS_BIN"; then
    ensure_singbox_plus force || warn "singbox-plus 更新失败，继续使用当前已安装版本。"
  else
    ensure_singbox_plus "$force" || die "singbox-plus 安装失败。"
  fi
  ensure_singbox_service
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$CERT_DIR"
  chown root:sing-box "$CONFIG_DIR" "$CERT_DIR" 2>/dev/null || true
  chmod 750 "$CONFIG_DIR" "$CERT_DIR"
  [ ! -f "$STATE_FILE" ] || { chown root:root "$STATE_FILE" 2>/dev/null || true; chmod 600 "$STATE_FILE" 2>/dev/null || true; }
  [ ! -f "$CONFIG_FILE" ] || { chown root:sing-box "$CONFIG_FILE" 2>/dev/null || true; chmod 640 "$CONFIG_FILE" 2>/dev/null || true; }
  [ ! -f "$KEY_FILE" ] || { chown root:sing-box "$KEY_FILE" 2>/dev/null || true; chmod 640 "$KEY_FILE" 2>/dev/null || true; }
  [ ! -f "$CERT_FILE" ] || { chown root:sing-box "$CERT_FILE" 2>/dev/null || true; chmod 644 "$CERT_FILE" 2>/dev/null || true; }
  [ ! -f "$CERT_SNI_FILE" ] || { chown root:root "$CERT_SNI_FILE" 2>/dev/null || true; chmod 600 "$CERT_SNI_FILE" 2>/dev/null || true; }
}

# -------------------------
# state 读写（全部走“临时文件 + mv”）
# -------------------------
state_get() {
  jq -r "$1" "$STATE_FILE"
}

# 一次 jq 读取多个字段到同名变量：state_read '<逗号分隔的 jq 表达式>' 变量1 变量2 ...
# 用 \x1f 分隔（非空白分隔符，空字段不会被吞掉）；null 当作空字符串
state_read() {
  local expr="$1"
  shift
  local record
  record="$(jq -r "[ ${expr} ] | join(\"\\u001f\")" "$STATE_FILE")" || return 1
  IFS=$'\x1f' read -r "$@" <<< "$record"
}

# 用法：state_build <jq 参数...> '<filter>'
# 结果写入新的临时文件，路径保存在 NEW_STATE；jq 失败直接 die，不会碰原 state
NEW_STATE=""
YSQ_ACTION_STATE_BASELINE=""
YSQ_ACTION_WRITE_LOCKED=0

state_fingerprint() {
  local result
  if [ ! -e "$STATE_FILE" ]; then printf '%s\n' absent; return 0; fi
  if command -v sha256sum >/dev/null 2>&1; then
    result="$(sha256sum < "$STATE_FILE")" || return 1
    printf '%s\n' "${result%% *}"
  else
    result="$(openssl dgst -sha256 < "$STATE_FILE")" || return 1
    printf '%s\n' "${result##* }"
  fi
}

# Gather input without a write lock. Once a write is ready, verify the original
# snapshot before using its indexes and keep FD 9 through apply and rollback.
state_write_guard() {
  local current
  [ "$YSQ_ACTION_WRITE_LOCKED" != 1 ] || return 0
  acquire_config_lock || return $?
  if [ -n "$YSQ_ACTION_STATE_BASELINE" ]; then
    current="$(state_fingerprint)" || { err "无法读取配置状态，请重试。"; return 1; }
    if [ "$current" != "$YSQ_ACTION_STATE_BASELINE" ]; then
      warn "配置已被另一项操作更新，本次修改已取消；请重新打开该操作并选择。"
      return "$CANCEL_RC"
    fi
  fi
  YSQ_ACTION_WRITE_LOCKED=1
}

state_build() {
  # Never let a failed guard continue into a commit of an older staged state.
  state_write_guard || exit $?
  [ -f "$STATE_FILE" ] || die "未找到状态文件：$STATE_FILE"
  NEW_STATE="$(mktemp "${STATE_FILE}.tmp.${WORK_TAG}.XXXXXX")" || die "无法创建临时文件。"
  if ! jq "$@" "$STATE_FILE" > "$NEW_STATE"; then
    rm -f "$NEW_STATE"
    NEW_STATE=""
    die "更新状态失败（jq 报错），原状态未改动。"
  fi
}

# 直接落盘（不渲染 / 不重启）：用于不影响 sing-box 配置的修改，以及安装流程
commit_state_plain() {
  [ -n "$NEW_STATE" ] && [ -f "$NEW_STATE" ] || die "内部错误：没有待提交的状态。"
  chown root:root "$NEW_STATE" 2>/dev/null || true
  chmod 600 "$NEW_STATE" || return 1
  mv -f "$NEW_STATE" "$STATE_FILE" || return 1
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

  bak_state="$(mktemp "${STATE_FILE}.tmp.${WORK_TAG}.XXXXXX")" || die "无法创建备份文件。"
  if ! cp -p "$STATE_FILE" "$bak_state"; then
    rm -f "$bak_state" "$NEW_STATE"
    NEW_STATE=""
    err "备份状态文件失败（磁盘已满？），本次修改已放弃，状态未改动。"
    return 1
  fi
  if [ -f "$CONFIG_FILE" ]; then
    bak_conf="$(mktemp "${CONFIG_FILE}.tmp.${WORK_TAG}.XXXXXX")" || die "无法创建备份文件。"
    if ! cp -p "$CONFIG_FILE" "$bak_conf"; then
      rm -f "$bak_state" "$bak_conf" "$NEW_STATE"
      NEW_STATE=""
      err "备份配置文件失败（磁盘已满？），本次修改已放弃，状态未改动。"
      return 1
    fi
  fi

  if ! commit_state_plain; then
    rm -f "$bak_state" "$bak_conf"
    err "写入新状态失败，原配置保持不变。"
    return 1
  fi

  if ! render_all; then
    err "新配置生成 / 检查失败，已回滚到修改前的状态，当前运行的配置未受影响。"
    rollback_state "$bak_state" "$bak_conf" "no"
    return 1
  fi

  if ! restart_singbox || ! is_singbox_running; then
    err "sing-box 重启或运行检查失败，正在回滚到修改前的状态..."
    rollback_state "$bak_state" "$bak_conf" "restart"
    return 1
  fi

  rm -f "$bak_state"
  [ -z "$bak_conf" ] || rm -f "$bak_conf"
  return 0
}

# 规范化 state，并把旧版本“节点内冗余拷贝的落地信息”迁移到落地池
ensure_state_defaults() {
  local tmp secret

  state_write_guard || return $?
  [ -f "$STATE_FILE" ] || { err "未找到状态文件：$STATE_FILE"; return 1; }
  secret="$(jq -r '.failover_secret // empty' "$STATE_FILE")"
  [ -n "$secret" ] || secret="$(openssl rand -hex 24)"

  tmp="$(mktemp "${STATE_FILE}.tmp.${WORK_TAG}.XXXXXX")" || return 1
  if ! jq --arg secret "$secret" '
    def lid($n; $ls):
      ( first($ls[] | select(.id == ($n.landing_id // ""))) | .id ) //
      ( first($ls[] | select(.server == ($n.landing_server // "")
                              and ((.port | tostring) == (($n.landing_port // "") | tostring)))) | .id ) //
      null;

    del(.sub_port, .sub_token) |
    (if has("blocked_domains") then . else .blocked_domains = [] end) |
    (if has("direct_domains") then . else .direct_domains = [] end) |
    (if has("routing_rule_sets") then . else .routing_rule_sets = [] end) |
    .failover_secret = $secret |
    (if has("ip_version") then . else .ip_version = "ipv4" end) |
    (if has("landings") then . else .landings = [] end) |
    (if has("nodes") then . else .nodes = [] end) |
    # 无损迁移：旧版本的单账号 UUID / TUIC 密码归入第一位用户 myself。
    # VLESS 客户端只验证 UUID，TUIC 验证 UUID+密码，因此老客户端无需改配置。
    (if has("users") then
       if (.users | type) == "array" then . else error("users must be an array") end
     else .users = [{name:"myself", uuid:.uuid, tuic_pass:(.tuic_pass // .short_id)}]
     end) |
    .state_schema = 2 |
    # 根字段永久保留旧安装身份，供旧落地池兜底使用；增删改用户不覆盖根密钥。
    # 实际入站用户全部从 .users[] 读取，二者相互独立。
    .landings |= map(
      .type = (.type // "vless") |
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

  chown root:root "$tmp" 2>/dev/null || true
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

  if [ -z "$YSQ_TEST_ROOT" ]; then
    install -d -m 750 -o root -g sing-box "$CERT_DIR" || return 1
  else
    mkdir -p "$CERT_DIR" && chmod 750 "$CERT_DIR" || return 1
  fi

  if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    if [ -f "$CERT_SNI_FILE" ]; then
      old_sni="$(cat "$CERT_SNI_FILE")"
    else
      old_sni="$tuic_sni"   # 旧版本没有记录，视为一致
    fi
    if [ "$old_sni" = "$tuic_sni" ]; then
      if [ ! -f "$CERT_SNI_FILE" ]; then
        printf '%s' "$tuic_sni" > "$CERT_SNI_FILE"
        chown root:root "$CERT_SNI_FILE" 2>/dev/null || true
        chmod 600 "$CERT_SNI_FILE" 2>/dev/null || true
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

  if [ -z "$YSQ_TEST_ROOT" ]; then
    install -m 640 -o root -g sing-box "$wd/tuic.key" "$KEY_FILE" || { rm -rf "$wd"; return 1; }
    install -m 644 -o root -g sing-box "$wd/tuic.crt" "$CERT_FILE" || { rm -rf "$wd"; return 1; }
  else
    install -m 640 "$wd/tuic.key" "$KEY_FILE" || { rm -rf "$wd"; return 1; }
    install -m 644 "$wd/tuic.crt" "$CERT_FILE" || { rm -rf "$wd"; return 1; }
  fi
  printf '%s' "$tuic_sni" > "$CERT_SNI_FILE"
  chown root:root "$CERT_SNI_FILE" 2>/dev/null || true
  chmod 600 "$CERT_SNI_FILE" 2>/dev/null || true
  rm -rf "$wd"

  ok "TUIC 证书生成完成：$CERT_FILE"
  return 0
}

create_state_file() {
  local uuid private_key public_key short_id tuic_pass server_ip
  local country_code flag loc ip_version key_choice ipv_choice keypair tmp
  local default_sni reality_sni tuic_sni

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
        local sb_bin
        sb_bin="$(resolve_singbox_bin)"
        [ -n "$sb_bin" ] || die "未找到 sing-box 可执行文件。"
        uuid="$("$sb_bin" generate uuid)"
        keypair="$("$sb_bin" generate reality-keypair)"
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
  IFS='|' read -r country_code flag loc <<<"$(detect_location "$server_ip" self "本机")"
  default_sni="$(default_sni_for_country "$country_code")"
  reality_sni="$default_sni"
  tuic_sni="$default_sni"

  ok "公网 IP (${ip_version})：${server_ip}"
  ok "自动命名地区：${flag}${loc}"
  ok "默认 SNI：${default_sni}"

  state_write_guard || return $?
  mkdir -p "$CONFIG_DIR" || return 1
  tmp="$(mktemp "${STATE_FILE}.tmp.${WORK_TAG}.XXXXXX")" || die "无法创建临时文件。"
  if ! jq -n \
    --arg uuid "$uuid" \
    --arg private_key "$private_key" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" \
    --arg tuic_pass "$tuic_pass" \
    --arg reality_sni "$reality_sni" \
    --arg tuic_sni "$tuic_sni" \
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
      direct_domains: [],
      routing_rule_sets: [],
      landings: [],
      users: [{name: "myself", uuid: $uuid, tuic_pass: $tuic_pass}],
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

# 分享链接明确携带协议；域名/端口本身不携带协议信息，不能据此猜测。
parse_landing_uri() {
  "$SINGBOX_PLUS_BIN" parse-landing "$@"
}

# 密码不套用本机用户密码字符限制，保留冒号、@、+、空格等原始字符。
ask_landing_secret() {
  local prompt="$1" previous="${2:-}" answer=""
  while true; do
    IFS= read -rsp "${prompt}${previous:+ [已设置，留空保持]}: " answer || die "无法读取落地认证信息。"
    printf '\n' >&2
    answer="${answer:-$previous}"
    if [ -n "$answer" ]; then printf '%s' "$answer"; return 0; fi
    warn "这里不能为空。"
  done
}

landing_type_label() {
  case "${1:-vless}" in
    tuic) echo "TUIC v5" ;;
    socks) echo "SOCKS5" ;;
    shadowsocks) echo "Shadowsocks" ;;
    *) echo "VLESS" ;;
  esac
}

LANDING_CONFIG_JSON=""
collect_landing_config() {
  local previous="${1:-}" source old_type type choice server default_port port user password sni pbk sid fp insecure cc mode alpn auth_choice method_pick method json address_hint=""
  [ -n "$previous" ] || previous='{}'
  ensure_singbox_plus || return 1
  [ -z "$(printf '%s' "$previous" | jq -r '.server // empty')" ] || address_hint="（留空沿用原地址）"
  read_line "落地 IP/域名或 vless://、tuic://、socks5://、ss:// 分享链接${address_hint}，0 返回: " source
  source="$(trim "$source")"
  [ "$source" != "0" ] || return "$CANCEL_RC"
  if [[ "$source" == *://* ]]; then
    if ! LANDING_CONFIG_JSON="$(printf '%s' "$source" | parse_landing_uri)"; then return 1; fi
    type="$(printf '%s' "$LANDING_CONFIG_JSON" | jq -r '.type')"
    server="$(printf '%s' "$LANDING_CONFIG_JSON" | jq -r '.server')"
    port="$(printf '%s' "$LANDING_CONFIG_JSON" | jq -r '.port')"
    info "已从分享链接识别 $(landing_type_label "$type") 落地。"
  else
  server="${source:-$(printf '%s' "$previous" | jq -r '.server // ""')}"
  server="${server#[}"; server="${server%]}"
  valid_host "$server" || { err "请输入有效 IP/域名或完整分享链接。"; return 1; }
  old_type="$(printf '%s' "$previous" | jq -r '.type // "vless"')"
  case "$old_type" in
    tuic) choice=2 ;;
    socks) choice=3 ;;
    shadowsocks) choice=4 ;;
    *) choice=1 ;;
  esac
  echo "1) VLESS Reality (TCP)  2) TUIC v5 (QUIC/UDP)  3) SOCKS5  4) Shadowsocks" >&2
  read_line "落地协议 [默认 ${choice}]: " type
  type="${type:-$choice}"
  case "$type" in
    1|vless) type=vless ;;
    2|tuic) type=tuic ;;
    3|socks|socks5) type=socks ;;
    4|ss|shadowsocks) type=shadowsocks ;;
    *) err "落地协议无效。"; return 1 ;;
  esac
  # 切换协议保留通用地址；认证/TLS设置按新协议重新填写。
  if [ "$old_type" != "$type" ]; then previous="$(printf '%s' "$previous" | jq 'del(.uuid,.password,.username,.method,.sni,.public_key,.short_id,.fingerprint,.insecure,.congestion_control,.udp_relay_mode,.udp_over_stream,.alpn)')"; fi
  case "$type" in
    socks) default_port=1080 ;;
    shadowsocks) default_port=8388 ;;
    *) default_port=443 ;;
  esac
  port="$(ask_port "落地远端端口 (1-65535)" "$(printf '%s' "$previous" | jq -r --argjson dp "$default_port" '.port // $dp')")"
  if [ "$type" = "vless" ]; then
    user="$(ask_landing_secret "落地 VLESS UUID" "$(jq -r --argjson previous "$previous" '$previous.uuid // .uuid' "$STATE_FILE")")"
    [ -n "$user" ] || return 1
    pbk="$(ask_text_default "落地 Reality PublicKey" "$(jq -r --argjson previous "$previous" '$previous.public_key // .public_key' "$STATE_FILE")")"
    read_line "落地 Reality ShortID [默认 $(jq -r --argjson previous "$previous" '$previous.short_id // .short_id' "$STATE_FILE")]: " sid
    sid="${sid:-$(jq -r --argjson previous "$previous" '$previous.short_id // .short_id' "$STATE_FILE")}"
    sni="$(ask_text_default "落地 Reality SNI" "$(jq -r --argjson previous "$previous" '$previous.sni // .reality_sni' "$STATE_FILE")")"
    fp="$(ask_text_default "TLS 指纹" "$(printf '%s' "$previous" | jq -r '.fingerprint // "chrome"')")"
    json="$(jq -nc --arg type "$type" --arg server "$server" --argjson port "$port" --arg uuid "$user" --arg public_key "$pbk" --arg short_id "$sid" --arg sni "$sni" --arg fingerprint "$fp" '{type:$type,server:$server,port:$port,uuid:$uuid,public_key:$public_key,short_id:$short_id,sni:$sni,fingerprint:$fingerprint}')"
  elif [ "$type" = "tuic" ]; then
    user="$(ask_landing_secret "落地 TUIC UUID" "$(printf '%s' "$previous" | jq -r '.uuid // empty')")"
    [ -n "$user" ] || return 1
    password="$(ask_landing_secret "落地 TUIC 密码" "$(printf '%s' "$previous" | jq -r '.password // empty')")"
    [ -n "$password" ] || return 1
    sni="$(ask_text_default "落地 TUIC SNI" "$(printf '%s' "$previous" | jq -r --arg server "$server" '.sni // $server')")"
    if [ "$(printf '%s' "$previous" | jq -r '.insecure // false')" = true ]; then choice=2; else choice=1; fi
    echo "1) 校验证书  2) 跳过校验（自签证书）" >&2
    read_line "TLS 证书验证 [默认 ${choice}]: " insecure
    insecure="${insecure:-$choice}"
    case "$insecure" in 1) insecure=false ;; 2) insecure=true ;; *) err "证书验证选项无效。"; return 1 ;; esac
    cc="$(ask_text_default "拥塞控制 bbr / cubic / new_reno" "$(printf '%s' "$previous" | jq -r '.congestion_control // "bbr"')")"
    mode="$(ask_text_default "UDP 转发 native / quic / stream" "$(printf '%s' "$previous" | jq -r 'if .udp_over_stream == true then "stream" else (.udp_relay_mode // "native") end')")"
    alpn="$(ask_text_default "ALPN（多个用逗号分隔）" "$(printf '%s' "$previous" | jq -r '(.alpn // ["h3"]) | join(",")')")"
    json="$(jq -nc --arg type "$type" --arg server "$server" --argjson port "$port" --arg uuid "$user" --arg password "$password" --arg sni "$sni" --argjson insecure "$insecure" --arg congestion_control "$cc" --arg mode "$mode" --arg alpn "$alpn" '{type:$type,server:$server,port:$port,uuid:$uuid,password:$password,sni:$sni,insecure:$insecure,congestion_control:$congestion_control,alpn:($alpn|split(","))} + (if $mode=="stream" then {udp_over_stream:true} else {udp_relay_mode:$mode,udp_over_stream:false} end)')"
  elif [ "$type" = "socks" ]; then
    if [ -n "$(printf '%s' "$previous" | jq -r '.username // empty')" ]; then choice=2; else choice=1; fi
    echo "1) 无认证  2) 用户名 + 密码" >&2
    read_line "SOCKS5 认证方式 [默认 ${choice}]: " auth_choice
    auth_choice="${auth_choice:-$choice}"
    case "$auth_choice" in
      1)
        user=""
        password=""
        ;;
      2)
        user="$(ask_text_default "落地 SOCKS5 用户名" "$(printf '%s' "$previous" | jq -r '.username // empty')")"
        [ -n "$user" ] || return 1
        password="$(ask_landing_secret "落地 SOCKS5 密码" "$(printf '%s' "$previous" | jq -r '.password // empty')")"
        [ -n "$password" ] || return 1
        ;;
      *) err "SOCKS5 认证选项无效。"; return 1 ;;
    esac
    json="$(jq -nc --arg type "$type" --arg server "$server" --argjson port "$port" --arg username "$user" --arg password "$password" '{type:$type,server:$server,port:$port} + (if $username != "" then {username:$username,password:$password} else {} end)')"
  else
    echo "Shadowsocks 加密方式：" >&2
    echo "  1) 2022-blake3-aes-128-gcm      2) 2022-blake3-aes-256-gcm" >&2
    echo "  3) 2022-blake3-chacha20-poly1305" >&2
    echo "  4) aes-256-gcm                  5) aes-128-gcm" >&2
    echo "  6) chacha20-ietf-poly1305       7) xchacha20-ietf-poly1305" >&2
    echo "  8) aes-192-gcm                  9) none" >&2
    method_pick="$(ask_text_default "请选择序号或直接输入加密方式" "$(printf '%s' "$previous" | jq -r '.method // "2022-blake3-aes-128-gcm"')")"
    case "$method_pick" in
      1) method="2022-blake3-aes-128-gcm" ;;
      2) method="2022-blake3-aes-256-gcm" ;;
      3) method="2022-blake3-chacha20-poly1305" ;;
      4) method="aes-256-gcm" ;;
      5) method="aes-128-gcm" ;;
      6) method="chacha20-ietf-poly1305" ;;
      7) method="xchacha20-ietf-poly1305" ;;
      8) method="aes-192-gcm" ;;
      9) method="none" ;;
      *) method="$method_pick" ;;
    esac
    if [ "$method" = "none" ]; then
      password=""
    else
      password="$(ask_landing_secret "落地 Shadowsocks 密码/密钥" "$(printf '%s' "$previous" | jq -r '.password // empty')")"
      [ -n "$password" ] || return 1
    fi
    json="$(jq -nc --arg type "$type" --arg server "$server" --argjson port "$port" --arg method "$method" --arg password "$password" '{type:$type,server:$server,port:$port,method:$method,password:$password}')"
  fi
  if ! LANDING_CONFIG_JSON="$(printf '%s' "$json" | parse_landing_uri --json)"; then return 1; fi
  fi
  if [ "$type" = "tuic" ]; then
    info "TUIC 使用 QUIC/UDP；TCP 端口状态不能验证 TUIC。绑定到中转节点后由实际代理探测检查。"
  else
    check_landing_connectivity "$server" "$port" || return $?
  fi
}

add_landing_wizard() {
  need_state
  step "添加落地节点"
  local server port type flag loc display id
  collect_landing_config
  server="$(printf '%s' "$LANDING_CONFIG_JSON" | jq -r '.server')"
  port="$(printf '%s' "$LANDING_CONFIG_JSON" | jq -r '.port')"
  type="$(printf '%s' "$LANDING_CONFIG_JSON" | jq -r '.type')"
  info "正在检测落地节点地区..."
  IFS='|' read -r _ flag loc <<<"$(detect_location "$server" "" "落地节点")"
  display="${flag}${loc}：${server}"
  id="landing_$(date +%s)_${RANDOM}"
  state_build --argjson landing "$LANDING_CONFIG_JSON" --arg id "$id" --arg display "$display" \
    '.landings += [($landing + {id:$id,display:$display})]'
  commit_state_plain
  ok "落地节点添加成功：${display} ($(landing_type_label "$type") / ${port})"
}

list_landings_table() {
  if [ "$(landing_count)" -eq 0 ]; then warn "当前无任何落地节点。"; return 1; fi
  jq -r "$JQ_TABLE_LIB$JQ_NODE_LIB"'
    . as $s |
    ["序号", "落地节点 (国家：ip)", "协议", "端口", "被引用", "参数 / SNI"] as $headers |
    [4, 28, 11, 6, 6, 16] as $mins |
    [.landings | to_entries[] | .value as $l | ($l.type // "vless") as $t |
      [((.key+1)|tostring),($l.display // "-"),
       landing_type_info($t).table,($l.port|tostring),
       (([$s.nodes[]? | select(.landing_id==$l.id or .backup_landing_id==$l.id)]|length)|tostring),
       (if $t == "socks" then (if (($l.username // "") != "") then "账密认证" else "无认证" end)
        elif $t == "shadowsocks" then ($l.method // "-")
        else ($l.sni // "-") end)]
    ] as $rows | table($headers;$mins;$rows)' "$STATE_FILE"
}

edit_landing() {
  local idx="$1" previous previous_config id old_server old_type old_display server type display flag loc used rename=false
  previous="$(jq -c --argjson i "$idx" '.landings[$i]' "$STATE_FILE")"
  id="$(printf '%s' "$previous" | jq -r '.id')"
  old_server="$(printf '%s' "$previous" | jq -r '.server')"
  old_type="$(printf '%s' "$previous" | jq -r '.type // "vless"')"
  old_display="$(printf '%s' "$previous" | jq -r '.display // .server')"
  used="$(jq --arg id "$id" '[.nodes[]? | select(.landing_id==$id or .backup_landing_id==$id)] | length' "$STATE_FILE")"
  echo "落地：${old_display} ($(landing_type_label "$old_type"))，被 ${used} 个节点引用。"
  if [ "$used" -gt 0 ]; then warn "修改后会重启 sing-box 并同步生效。"; fi
  # 旧 VLESS 条目可能依赖根凭据；编辑时先补齐显示默认值，不覆盖原身份。
  if [ "$old_type" = "vless" ]; then
    previous="$(jq -c --argjson i "$idx" '. as $s | .landings[$i] | .type="vless" | .uuid=(.uuid // $s.uuid) | .public_key=(.public_key // $s.public_key) | .short_id=(.short_id // $s.short_id) | .sni=(.sni // $s.reality_sni)' "$STATE_FILE")"
  fi
  collect_landing_config "$previous"
  previous_config="$(printf '%s' "$previous" | parse_landing_uri --json 2>/dev/null || true)"
  if [ -n "$previous_config" ] && [ "$LANDING_CONFIG_JSON" = "$previous_config" ]; then
    info "落地信息没有变化。"
    return "$CANCEL_RC"
  fi
  server="$(printf '%s' "$LANDING_CONFIG_JSON" | jq -r '.server')"
  type="$(printf '%s' "$LANDING_CONFIG_JSON" | jq -r '.type')"
  display="$old_display"
  if [ "$server" != "$old_server" ]; then
    IFS='|' read -r _ flag loc <<<"$(detect_location "$server" "" "落地节点")"
    display="${flag}${loc}：${server}"
  fi
  if [ "$type" != "$old_type" ] || [ "${display%%：*}" != "${old_display%%：*}" ]; then rename=true; fi
  state_build --argjson i "$idx" --argjson landing "$LANDING_CONFIG_JSON" --arg id "$id" --arg display "$display" --argjson rename "$rename" "$JQ_NODE_LIB"'
    .landings[$i] = ($landing + {id:$id,display:$display}) |
    if $rename then reduce (.nodes | to_entries[] | select(.value.outbound_type=="landing" and .value.landing_id==$id) | .key) as $ni (.;
      . as $s | .nodes[$ni].name = node_auto_name($s;$s.nodes[$ni];"")) else . end'
  if [ "$used" -gt 0 ]; then apply_state; else commit_state_plain; fi
  ok "落地节点已更新：${display} ($(landing_type_label "$type"))"
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

  if ! valid_index "$pick" "$count"; then
    warn "序号无效。"
    return 1
  fi

  edit_landing "$((10#$pick - 1))"
}

delete_landing_wizard() {
  need_state
  step "删除落地节点"

  local count pick idx l_id disp used users

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

  if ! valid_index "$pick" "$count"; then
    warn "序号无效。"
    return 1
  fi

  idx=$((10#$pick - 1))
  IFS=$'\x1f' read -r l_id disp used < <(
    jq -r --argjson i "$idx" '
      . as $s | $s.landings[$i] as $l
      | [ $l.id, $l.display, ([ $s.nodes[]? | select(.landing_id == $l.id or .backup_landing_id == $l.id) ] | length | tostring) ]
      | join("\u001f")' "$STATE_FILE"
  )

  if [ "$used" -gt 0 ]; then
    users="$(jq -r --arg id "$l_id" '.nodes[]? | select(.landing_id == $id or .backup_landing_id == $id) | "  - " + .name' "$STATE_FILE")"
    warn "落地 [${disp}] 正被以下 ${used} 个节点使用，无法删除："
    echo "$users" >&2
    warn "请先到「修改节点」更换主落地、设置 / 取消备用落地，或删除引用它的节点。"
    return 1
  fi

  confirm_or_cancel "确认删除落地节点 [${disp}] 吗？输入 y 确认: " || return $?

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

    if valid_index "$pick" "$count"; then
      real_idx=$((10#$pick - 1))
      IFS=$'\x1f' read -r SEL_LANDING_ID SEL_LANDING_DISPLAY < <(
        jq -r --argjson i "$real_idx" '.landings[$i] | [.id, .display] | join("\u001f")' "$STATE_FILE"
      )
      return 0
    fi
    warn "无效选项，请重新选择。"
  done
}

SEL_BACKUP_LANDING_ID=""
select_backup_landing() {
  local primary="$1" pick count idx
  SEL_BACKUP_LANDING_ID=""
  count="$(landing_count)"
  echo
  echo "备用落地 (主落地故障后切换，恢复后自动回切)："
  list_landings_table || true
  read_line "选择备用落地序号，0 表示不启用 [默认 0]: " pick
  pick="$(trim "$pick")"
  [ -n "$pick" ] && [ "$pick" != "0" ] || return 0
  valid_index "$pick" "$count" || { err "备用落地序号无效。"; return 1; }
  idx=$((10#$pick - 1))
  SEL_BACKUP_LANDING_ID="$(jq -r --argjson i "$idx" '.landings[$i].id' "$STATE_FILE")"
  [ "$SEL_BACKUP_LANDING_ID" != "$primary" ] || { err "备用落地不能与主落地相同。"; return 1; }
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
  local backup_landing_id="${5:-}"
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
    --arg backup_landing_id "$backup_landing_id" \
    '.nodes += [
       ({
         "type": $type,
         "protocol": $protocol,
         "outbound_type": $outbound_type,
         "tag": $tag,
         "name": $name,
         "port": $port
       } + (if $landing_id != "" then {"landing_id": $landing_id} else {} end)
         + (if $backup_landing_id != "" then {"backup_landing_id": $backup_landing_id} else {} end))
     ]'

  info "新增节点：${name} / 协议: ${protocol^^} / 端口: ${port}"
}

add_node_wizard() {
  need_state
  step "添加节点"

  local choice port outbound_choice type_base landing_id="" backup_landing_id=""

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
      info "已选择主落地：${SEL_LANDING_DISPLAY}"
      select_backup_landing "$landing_id"
      backup_landing_id="$SEL_BACKUP_LANDING_ID"
      ;;
    *) warn "输入错误。"; return 1 ;;
  esac

  if [ "$type_base" = "vless" ]; then
    port="$(ask_node_port "请输入 VLESS TCP 端口" "$VLESS_DIRECT_PORT")"
  else
    port="$(ask_node_port "请输入 TUIC UDP 端口" "$TUIC_DIRECT_PORT")"
  fi

  if [ -n "$landing_id" ]; then
    prepare_add_node "${type_base}-relay" "$port" "landing" "$landing_id" "$backup_landing_id"
  else
    prepare_add_node "${type_base}-direct" "$port" "direct"
  fi

  apply_state
  ok "节点已生效。"
}

delete_node_wizard() {
  need_state

  local count indices idx real_idx n tags_json tag name
  local -a all_tags=() all_names=()
  local -a valid_tags=()
  local -a names_to_print=()
  local -a seen=()

  # 一次 jq 读出全部节点的 tag / 名称，后面按序号直接查数组
  while IFS=$'\x1f' read -r tag name; do
    all_tags+=("$tag")
    all_names+=("$name")
  done < <(jq -r '.nodes[]? | [.tag, .name] | join("\u001f")' "$STATE_FILE")
  count="${#all_tags[@]}"
  if [ "$count" -eq 0 ]; then
    warn "当前没有可删除的节点。"
    return "$CANCEL_RC"
  fi

  step "删除节点 (支持批量)"
  list_nodes_table
  echo
  read_line "请输入要删除的节点序号 (多个用空格隔开，如 1 2)，输入 0 返回: " indices
  indices="$(split_input "$indices")"

  local -a idx_items=()
  if [ -z "$indices" ] || [ "$indices" = "0" ]; then return "$CANCEL_RC"; fi

  read -r -a idx_items <<< "$indices"
  for idx in "${idx_items[@]}"; do
    if valid_index "$idx" "$count"; then
      real_idx=$((10#$idx - 1))
      # 去重
      if [[ " ${seen[*]:-} " == *" ${real_idx} "* ]]; then continue; fi
      seen+=("$real_idx")
      valid_tags+=("${all_tags[$real_idx]}")
      names_to_print+=("${all_names[$real_idx]}")
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

  confirm_or_cancel "确认删除？输入 y 确认: " n "已取消删除。" || return $?

  tags_json="$(printf '%s\n' "${valid_tags[@]}" | jq -R . | jq -s .)"
  state_build --argjson tags "$tags_json" \
    '.nodes |= map(select(.tag as $t | $tags | index($t) | not))'

  apply_state
  ok "删除完成。"
}

modify_node_wizard() {
  need_state

  local count index real_idx old_port new_port old_tag new_tag type protocol name
  local outbound_type landing_id backup_landing_id landing_display mod_choice
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

  if ! valid_index "$index" "$count"; then
    warn "序号输入错误。"
    return 1
  fi

  real_idx=$((10#$index - 1))
  # 一次 jq 取出该节点全部字段（\x1f 分隔，空字段不会被吞掉）
  IFS=$'\x1f' read -r type protocol name old_port old_tag outbound_type landing_id backup_landing_id landing_display < <(
    jq -r --argjson i "$real_idx" '
      . as $s | $s.nodes[$i] as $n
      | ($n.outbound_type // "direct") as $out
      | [ $n.type,
          ($n.protocol // (if $n.type | startswith("tuic") then "udp" else "tcp" end)),
          $n.name, ($n.port | tostring), $n.tag, $out, ($n.landing_id // ""),
          ($n.backup_landing_id // ""),
          (if $out == "landing"
           then ((first($s.landings[]? | select(.id == ($n.landing_id // ""))) | .display) // "(落地已丢失)")
           else "-" end) ]
      | join("\u001f")' "$STATE_FILE"
  )

  echo
  echo "--- 节点当前信息 ---"
  echo "名称: ${name}"
  echo "类型: $(node_type_name "$type" "$outbound_type" "$old_tag")"
  echo "协议: ${protocol^^}"
  echo "端口: ${old_port}"
  echo "出口: $([ "$outbound_type" = "landing" ] && echo "落地中转 (${landing_display})" || echo "直出")"
  echo "备用: $(jq -r --argjson i "$real_idx" '. as $s | .nodes[$i].backup_landing_id as $id | if $id==null then "未启用" else ([.landings[]|select(.id==$id)|.display][0]//"落地已丢失") end' "$STATE_FILE")"
  if [ "$outbound_type" = "landing" ] && [ -n "$backup_landing_id" ] && [ -f "$FAILOVER_STATUS_FILE" ]; then
    jq -r --arg t "failover-${old_tag}" '
      if (now - (.checked_at//0)) > 90 then "主备检测状态已超过 90 秒未更新，请检查 ysq-failover 服务。"
      elif (.error//"")!="" then "主备检测异常: \(.error)"
      else .groups[]? | select(.tag==$t) |
        "当前出口: \(.selected) (主: \(.primary_ok), 备: \(.backup_ok))" end' "$FAILOVER_STATUS_FILE" 2>/dev/null \
      || warn "主备检测状态文件不可读或格式异常，请检查 ysq-failover 服务。"
  fi
  echo "--------------------"
  echo

  echo "请选择要修改的内容："
  echo "1) 修改端口"
  echo "2) 修改入站 SNI (同协议所有节点共用)"
  echo "3) 修改出口方式 (切换直出 / 更换主落地)"
  echo "4) 设置 / 取消备用落地 (故障切换、主落地恢复后回切)"
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
        if [ "$outbound_type" = "direct" ]; then
          info "出口未改变。"
          return "$CANCEL_RC"
        fi
        if [[ "$type" == tuic* ]]; then new_type="tuic-direct"; else new_type="vless-direct"; fi
        new_tag="${new_type}-${old_port}"
        new_name="$(make_node_name "$new_type" "$old_port" "direct" "" "$old_tag")"
        state_build --argjson i "$real_idx" \
          --arg type "$new_type" \
          --arg tag "$new_tag" \
          --arg name "$new_name" \
          '.nodes[$i] |= (.type = $type | .tag = $tag | .name = $name | .outbound_type = "direct" | del(.landing_id, .backup_landing_id))'
      elif [ "$out_target" = "2" ]; then
        select_landing
        if [ "$outbound_type" = "landing" ] && [ "$landing_id" = "$SEL_LANDING_ID" ]; then
          info "落地出口未改变。"
          return "$CANCEL_RC"
        fi
        if [[ "$type" == tuic* ]]; then new_type="tuic-relay"; else new_type="vless-relay"; fi
        new_tag="${new_type}-${old_port}"
        new_name="$(make_node_name "$new_type" "$old_port" "landing" "$SEL_LANDING_ID" "$old_tag")"
        state_build --argjson i "$real_idx" \
          --arg type "$new_type" \
          --arg tag "$new_tag" \
          --arg name "$new_name" \
          --arg lid "$SEL_LANDING_ID" \
          '.nodes[$i] |= (.type = $type | .tag = $tag | .name = $name | .outbound_type = "landing" | .landing_id = $lid | if .backup_landing_id == $lid then del(.backup_landing_id) else . end)'
      else
        return "$CANCEL_RC"
      fi
      ;;
    4)
      if [ "$outbound_type" != "landing" ]; then
        warn "请先把此节点的出口改为落地中转。"
        return "$CANCEL_RC"
      fi
      select_backup_landing "$landing_id"
      state_build --argjson i "$real_idx" --arg backup "$SEL_BACKUP_LANDING_ID" \
        '.nodes[$i] |= (if $backup == "" then del(.backup_landing_id) else .backup_landing_id=$backup end)'
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
# 用户管理：同一用户可访问所有 VLESS / TUIC 入站，每人独立 UUID / TUIC Password。
# -------------------------
valid_user_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9]{1,32}$ ]]
}

valid_user_uuid() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

valid_tuic_password() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]{6,128}$ ]]
}

user_name_taken() {
  jq -e --arg n "$1" --arg ignore "${2:-}" '.users[]? | select(.name == $n and .name != $ignore)' "$STATE_FILE" >/dev/null 2>&1
}

list_users_table() {
  need_state
  jq -r "$JQ_TABLE_LIB"'
    ["序号", "用户名", "VLESS / TUIC UUID", "TUIC 密码"] as $h |
    [4, 12, 36, 11] as $w |
    ([.users | to_entries[] | [((.key+1)|tostring), .value.name, .value.uuid, .value.tuic_pass]]) as $rows |
    table($h; $w; $rows)
  ' "$STATE_FILE"
}

ask_user_name() {
  local old="${1:-}" n=""
  while true; do
    read_line "用户名（仅英文字母/数字，1-32字符）${old:+ [默认 ${old}]}: " n
    n="$(trim "$n")"
    n="${n:-$old}"
    # 保留旧名称属于未修改，不强制重命名已有用户。
    if [ -n "$old" ] && [ "$n" = "$old" ]; then
      printf '%s' "$old"
      return 0
    fi
    if ! valid_user_name "$n"; then
      warn "用户名只能包含英文字母和数字，长度为1-32字符。示例：myself、alice、user02、123。"
      continue
    fi
    if user_name_taken "$n" "$old"; then
      warn "用户名 ${n} 已存在。"
      continue
    fi
    printf '%s' "$n"
    return 0
  done
}

ask_user_uuid() {
  local n=""
  while true; do
    read_line "输入 VLESS / TUIC 共用 UUID（留空自动生成）: " n
    n="$(trim "$n")"
    if [ -z "$n" ]; then
      local sb_bin
      sb_bin="$(resolve_singbox_bin)"
      [ -n "$sb_bin" ] || return 1
      n="$("$sb_bin" generate uuid)" || return 1
    fi
    if valid_user_uuid "$n"; then
      echo "${n,,}"
      return 0
    fi
    warn "UUID 不合法，请输入 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx 格式。"
  done
}

ask_user_tuic_password() {
  local p=""
  while true; do
    read_line "输入 TUIC 密码（至少6位，仅字母/数字/_/-，留空自动生成）: " p
    p="$(trim "$p")"
    if [ -z "$p" ]; then
      openssl rand -hex 16
      return 0
    fi
    if valid_tuic_password "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
    warn "密码只能含字母、数字、_、-，长度至少6位。"
  done
}

add_user_wizard() {
  need_state
  require_local_user_management || return 1
  step "添加用户（同时开通 VLESS + TUIC）"
  local name uuid password
  name="$(ask_user_name)"
  uuid="$(ask_user_uuid)"
  password="$(ask_user_tuic_password)"
  if jq -e --arg u "$uuid" '.users[] | select(.uuid == $u)' "$STATE_FILE" >/dev/null 2>&1; then
    die "UUID 已被其他用户使用，请重新添加。"
  fi
  state_build --arg n "$name" --arg u "$uuid" --arg p "$password" \
    '.users += [{name:$n, uuid:$u, tuic_pass:$p}]'
  apply_state
  ok "用户 ${name} 添加成功，VLESS / TUIC 已生效。"
  info "节点直链和 Clash YAML 已重新生成，可在主菜单查看。"
}

modify_user_wizard() {
  need_state
  require_local_user_management || return 1
  step "修改用户"
  local count pick idx name uuid pass new choice
  count="$(jq '.users|length' "$STATE_FILE")"
  list_users_table
  read_line "请输入要修改的用户序号（0 返回）: " pick
  pick="$(trim "$pick")"
  if [ -z "$pick" ] || [ "$pick" = "0" ]; then return "$CANCEL_RC"; fi
  valid_index "$pick" "$count" || { warn "用户序号无效。"; return 1; }
  idx=$((10#$pick - 1))
  IFS=$'\x1f' read -r name uuid pass < <(jq -r --argjson i "$idx" '.users[$i] | [.name,.uuid,.tuic_pass] | join("\u001f")' "$STATE_FILE")
  echo "当前用户: ${name} / UUID: ${uuid}"
  echo "1) 修改用户名（已有固定统计 ID 的账号保留流量归属）"
  echo "2) 修改 UUID（VLESS / TUIC 客户端都需更新）"
  echo "3) 修改 TUIC 密码"
  echo "4) 同时重置 UUID + TUIC 密码"
  echo "0) 返回"
  read_line "请选择: " choice
  case "$choice" in
    1)
      new="$(ask_user_name "$name")"
      [ "$new" != "$name" ] || { info "用户名未变化。"; return "$CANCEL_RC"; }
      state_build --argjson i "$idx" --arg n "$new" '.users[$i].name=$n'
      ;;
    2)
      new="$(ask_user_uuid)"
      if jq -e --argjson i "$idx" --arg u "$new" '.users | to_entries[] | select(.key != $i and .value.uuid == $u)' "$STATE_FILE" >/dev/null 2>&1; then
        die "该 UUID 已被其他用户使用。"
      fi
      [ "$new" != "$uuid" ] || return "$CANCEL_RC"
      state_build --argjson i "$idx" --arg u "$new" '.users[$i].uuid=$u'
      ;;
    3)
      new="$(ask_user_tuic_password)"
      [ "$new" != "$pass" ] || return "$CANCEL_RC"
      state_build --argjson i "$idx" --arg p "$new" '.users[$i].tuic_pass=$p'
      ;;
    4)
      local sb_bin
      sb_bin="$(resolve_singbox_bin)"
      [ -n "$sb_bin" ] || die "未找到 sing-box 可执行文件。"
      new="$("$sb_bin" generate uuid)"
      pass="$(openssl rand -hex 16)"
      state_build --argjson i "$idx" --arg u "$new" --arg p "$pass" \
        '.users[$i] |= (.uuid=$u | .tuic_pass=$p)'
      ;;
    0) return "$CANCEL_RC" ;;
    *) warn "无效选项。"; return 1 ;;
  esac
  apply_state
  ok "用户信息已更新。修改凭据后请使用新节点链接重新配置客户端。"
}

delete_user_wizard() {
  need_state
  require_local_user_management || return 1
  step "删除用户"
  local count pick idx name
  count="$(jq '.users|length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "当前没有用户。"
    return "$CANCEL_RC"
  fi
  list_users_table
  read_line "请输入要删除的用户序号（0 返回）: " pick
  pick="$(trim "$pick")"
  if [ -z "$pick" ] || [ "$pick" = "0" ]; then return "$CANCEL_RC"; fi
  valid_index "$pick" "$count" || { warn "用户序号无效。"; return 1; }
  idx=$((10#$pick - 1))
  name="$(jq -r --argjson i "$idx" '.users[$i].name' "$STATE_FILE")"
  warn "删除后，用户 ${name} 的全部 VLESS / TUIC 连接将失效。"
  confirm_or_cancel "输入 y 确认删除 ${name}: " n "" || return $?
  state_build --argjson i "$idx" 'del(.users[$i])'
  apply_state
  ok "用户 ${name} 已删除。"
}

user_management_menu() {
  local choice
  need_state
  if agent_binding_present; then
    step "用户管理（中控托管）"
    list_users_table
    info "请在中控网页添加、修改或停用用户；本机继续保留节点与落地管理。"
    pause
    return 0
  fi
  while true; do
    step "用户管理"
    list_users_table
    echo
    echo "1) 添加用户"
    echo "2) 修改用户（名称 / UUID / TUIC 密码）"
    echo "3) 删除用户"
    echo "0) 返回主菜单"
    read_line "请选择: " choice
    case "$choice" in
      1) act add_user_wizard ;;
      2) act modify_user_wizard ;;
      3) act delete_user_wizard ;;
      0) return 0 ;;
      *) warn "输入错误。" ;;
    esac
  done
}

# -------------------------
# 流量统计：使用 singbox-plus stats 读取本机 41453 gRPC 的 V2Ray StatsService。
# 查询只读 (reset=false)，统计在 sing-box 重启后归零。
# -------------------------
show_traffic_stats() {
  need_state
  step "流量统计（V2Ray API ${V2RAY_API_PORT}）"
  if ! is_singbox_running; then
    warn "sing-box 没有运行，无法获取流量。"
    return 1
  fi
  ensure_singbox_plus || return 1
  local wd result errors
  wd="$(new_work_dir)"
  result="${wd}/response.json"
  errors="${wd}/error.txt"

  if ! "$SINGBOX_PLUS_BIN" stats --addr "127.0.0.1:${V2RAY_API_PORT}" --timeout 5s > "$result" 2> "$errors"; then
    err "无法读取 127.0.0.1:${V2RAY_API_PORT} 的 V2Ray API 统计。"
    sed -n '1,8p' "$errors" >&2
    if grep -Eqi 'connection refused|connect: connection|deadline exceeded|no route to host|timeout' "$errors"; then
      warn "API ${V2RAY_API_PORT} 无法连接。请检查 ysq 面板常驻端口指示，以及 sing-box 是否已启动。"
    elif grep -Eqi 'unknown service|unimplemented' "$errors"; then
      warn "服务名不匹配或服务器未启用统计服务。请检查 sing-box 的 with_v2ray_api 编译标签和配置。"
    else
      warn "请检查 API 端口、sing-box 编译标签（with_v2ray_api）及 sing-box 日志。"
    fi
    return 1
  fi
  if ! jq -e '.stat == null or (.stat|type) == "array"' "$result" >/dev/null 2>&1; then
    err "V2Ray API 返回了非预期数据。"
    return 1
  fi

  jq -nr --slurpfile cfg "$STATE_FILE" --slurpfile data "$result" "$JQ_TABLE_LIB"'
    ($cfg[0]) as $c |
    (($data[0].stat // []) | map({key:.name,value:((.value // 0)|tonumber)}) | from_entries) as $stats |
    def traffic($category; $name; $dir): ($stats[$category + ">>>" + $name + ">>>traffic>>>" + $dir] // 0);
    def fmt:
      if . >= 1073741824 then ((.*100/1073741824 | floor)/100|tostring)+" GiB"
      elif . >= 1048576 then ((.*100/1048576 | floor)/100|tostring)+" MiB"
      elif . >= 1024 then ((.*100/1024 | floor)/100|tostring)+" KiB"
      else tostring + " B" end;
    [$c.users[] as $u |
      traffic("user";($u.stats_key // $u.name);"uplink") as $up |
      traffic("user";($u.stats_key // $u.name);"downlink") as $down |
      [$u.name, ($up|fmt), ($down|fmt), (($up+$down)|fmt)]
    ] as $user_rows |
    table(["用户", "上传", "下载", "合计"]; [32, 12, 12, 12]; $user_rows),
    "",
    ([$c.nodes[]? as $n |
      traffic("inbound";$n.tag;"uplink") as $up |
      traffic("inbound";$n.tag;"downlink") as $down |
      [($n.name + " (" + ($n.port|tostring) + ")"), ($up|fmt), ($down|fmt), (($up+$down)|fmt)]
    ] as $node_rows |
      table(["节点 (端口)", "上传", "下载", "合计"]; [32, 12, 12, 12]; $node_rows))
  '
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

direct_add() {
  need_state

  local raw_input item domain domains_json
  local -a new_domains=()

  read_line "请输入要直连的域名 (多个用空格或逗号隔开，输入 0 返回): " raw_input
  raw_input="$(split_input "$raw_input")"
  local -a raw_items=()
  if [ -z "$raw_input" ] || [ "$raw_input" = "0" ]; then return "$CANCEL_RC"; fi

  read -r -a raw_items <<< "$raw_input"
  for item in "${raw_items[@]}"; do
    domain="$(normalize_domain "$item")"
    if [ -z "$domain" ]; then continue; fi
    if ! [[ "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
      warn "忽略无效域名格式：${item}（中文域名请填写 punycode 形式）"
      continue
    fi
    if jq -e --arg d "$domain" '.direct_domains | index($d)' "$STATE_FILE" >/dev/null 2>&1; then
      info "域名已在直连列表中，跳过：$domain"
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
  state_build --argjson ds "$domains_json" '.direct_domains += $ds | .direct_domains |= unique | .blocked_domains = ((.blocked_domains//[]) - $ds)'
  apply_state
  ok "已批量直连 ${#new_domains[@]} 个域名: ${new_domains[*]}"
}

direct_remove() {
  need_state

  local count raw_indices idx real_idx remove_json
  local -a all_domains=()
  local -a remove_domains=()
  local -a seen=()

  mapfile -t all_domains < <(jq -r '.direct_domains[]?' "$STATE_FILE")
  count="${#all_domains[@]}"
  if [ "$count" -eq 0 ]; then
    warn "直连列表为空。"
    return "$CANCEL_RC"
  fi

  read_line "请输入要解除直连的序号 (多个用空格或逗号隔开，输入 all 清空全部，输入 0 取消): " raw_indices
  raw_indices="$(split_input "$raw_indices")"
  if [ -z "$raw_indices" ] || [ "$raw_indices" = "0" ]; then return "$CANCEL_RC"; fi

  if [ "${raw_indices,,}" = "all" ]; then
    confirm_or_cancel "确认清空全部 ${count} 个已直连域名吗？输入 y 确认: " || return $?
    state_build '.direct_domains = []'
    apply_state
    ok "已清空全部直连域名。"
    return 0
  fi

  local -a idx_items=()
  read -r -a idx_items <<< "$raw_indices"
  for idx in "${idx_items[@]}"; do
    if valid_index "$idx" "$count"; then
      real_idx=$((10#$idx - 1))
      if [[ " ${seen[*]:-} " == *" ${real_idx} "* ]]; then continue; fi
      seen+=("$real_idx")
      remove_domains+=("${all_domains[$real_idx]}")
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
    '.direct_domains |= map(select(. as $d | $rm_list | index($d) | not))'
  apply_state
  ok "已解除直连 (${#remove_domains[@]} 个): ${remove_domains[*]}"
}

block_add() {
  need_state

  local raw_input item domain domains_json
  local -a new_domains=()

  read_line "请输入要屏蔽的域名 (多个用空格或逗号隔开，输入 0 返回): " raw_input
  raw_input="$(split_input "$raw_input")"
  local -a raw_items=()
  if [ -z "$raw_input" ] || [ "$raw_input" = "0" ]; then return "$CANCEL_RC"; fi

  read -r -a raw_items <<< "$raw_input"
  for item in "${raw_items[@]}"; do
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
  state_build --argjson ds "$domains_json" '.blocked_domains += $ds | .blocked_domains |= unique | .direct_domains = ((.direct_domains//[]) - $ds)'
  apply_state
  ok "已批量屏蔽 ${#new_domains[@]} 个域名: ${new_domains[*]}"
}

block_remove() {
  need_state

  local count raw_indices idx real_idx remove_json
  local -a all_domains=()
  local -a remove_domains=()
  local -a seen=()

  mapfile -t all_domains < <(jq -r '.blocked_domains[]?' "$STATE_FILE")
  count="${#all_domains[@]}"
  if [ "$count" -eq 0 ]; then
    warn "屏蔽列表为空。"
    return "$CANCEL_RC"
  fi

  read_line "请输入要解除屏蔽的序号 (多个用空格或逗号隔开，输入 all 清空全部，输入 0 取消): " raw_indices
  raw_indices="$(split_input "$raw_indices")"
  if [ -z "$raw_indices" ] || [ "$raw_indices" = "0" ]; then return "$CANCEL_RC"; fi

  if [ "${raw_indices,,}" = "all" ]; then
    confirm_or_cancel "确认清空全部 ${count} 个已屏蔽域名吗？输入 y 确认: " || return $?
    state_build '.blocked_domains = []'
    apply_state
    ok "已清空全部屏蔽域名。"
    return 0
  fi

  local -a idx_items=()
  read -r -a idx_items <<< "$raw_indices"
  for idx in "${idx_items[@]}"; do
    if valid_index "$idx" "$count"; then
      real_idx=$((10#$idx - 1))
      if [[ " ${seen[*]:-} " == *" ${real_idx} "* ]]; then continue; fi
      seen+=("$real_idx")
      remove_domains+=("${all_domains[$real_idx]}")
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

# 直连指此 VPS 本机出口；未匹配的流量仍使用各节点原本的出口。
routing_menu() {
  need_state
  local choice
  while true; do
    step "分流管理"
    echo "屏蔽域名："
    jq -r 'if (.blocked_domains|length)==0 then "  (无)" else .blocked_domains|to_entries[]|"  \(.key+1)) \(.value)" end' "$STATE_FILE"
    echo "直连域名："
    jq -r 'if ((.direct_domains//[])|length)==0 then "  (无)" else .direct_domains|to_entries[]|"  \(.key+1)) \(.value)" end' "$STATE_FILE"
    echo "Rule Set："
    jq -r 'if ((.routing_rule_sets//[])|length)==0 then "  (无)" else .routing_rule_sets|to_entries[]|"  \(.key+1)) \(.value.tag) [\(if .value.action=="block" then "屏蔽" else "直连" end), \(.value.format)] \(.value.url)" end' "$STATE_FILE"
    echo
    echo "1) 添加屏蔽域名"
    echo "2) 删除屏蔽域名"
    echo "3) 添加直连域名"
    echo "4) 删除直连域名"
    echo "5) 添加 Rule Set (sing-box JSON / SRS)"
    echo "6) 删除 Rule Set"
    echo "0) 返回"
    info "优先级：屏蔽 > 直连 > 节点原出口；直连使用此 VPS 的公网出口。"
    read_line "请选择: " choice
    case "$choice" in
      1) act block_add ;;
      2) act block_remove ;;
      3) act direct_add ;;
      4) act direct_remove ;;
      5) act rule_set_add ;;
      6) act rule_set_remove ;;
      0) return 0 ;;
      *) warn "输入错误。" ;;
    esac
  done
}

rule_set_add() {
  need_state
  local tag url choice action format interval
  read_line "规则集名称 (字母开头，字母数字 / - / _，0 返回): " tag
  tag="$(trim "$tag")"
  [ -n "$tag" ] && [ "$tag" != "0" ] || return "$CANCEL_RC"
  [[ "$tag" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,63}$ ]] || { err "规则集名称格式错误。"; return 1; }
  tag="rs-${tag}"
  if jq -e --arg t "$tag" '.routing_rule_sets[]? | select(.tag==$t)' "$STATE_FILE" >/dev/null; then
    warn "此名称已存在，请删除原规则集后重新添加。"; return "$CANCEL_RC"
  fi
  read_line "sing-box 规则集下载链接 (https://): " url
  url="$(trim "$url")"
  [[ "$url" =~ ^https://[^[:space:]]+$ ]] || { err "请输入 HTTPS 下载链接。"; return 1; }
  echo "1) 直连  2) 屏蔽"
  read_line "规则动作 [默认 1]: " choice
  case "${choice:-1}" in 1) action="direct" ;; 2) action="block" ;; *) return 1 ;; esac
  echo "1) Source JSON (.json)  2) Binary (.srs)"
  read_line "格式 [默认 2]: " choice
  case "${choice:-2}" in 1) format="source" ;; 2) format="binary" ;; *) return 1 ;; esac
  read_line "自动更新周期 [默认 1d，可填 1h / 12h / 1d]: " interval
  interval="${interval:-1d}"
  [[ "$interval" =~ ^[1-9][0-9]{0,4}[hm]$ || "$interval" =~ ^[1-9][0-9]{0,3}d$ ]] || { err "更新周期格式错误。"; return 1; }
  state_build --arg t "$tag" --arg u "$url" --arg a "$action" --arg f "$format" --arg i "$interval" \
    '.routing_rule_sets += [{tag:$t,type:"remote",url:$u,action:$a,format:$f,update_interval:$i}]'
  apply_state
  ok "规则集已添加：${tag}。首次使用需要能下载该规则集；以后使用本地缓存。"
}

rule_set_remove() {
  need_state
  local count pick idx
  count="$(jq '(.routing_rule_sets//[])|length' "$STATE_FILE")"
  [ "$count" -gt 0 ] || { warn "暂无 Rule Set。"; return "$CANCEL_RC"; }
  jq -r '.routing_rule_sets|to_entries[]|"\(.key+1)) \(.value.tag) [\(.value.action)]"' "$STATE_FILE"
  read_line "删除序号 (0 返回): " pick
  [ "$pick" != "0" ] || return "$CANCEL_RC"
  valid_index "$pick" "$count" || { err "序号无效。"; return 1; }
  idx=$((10#$pick - 1))
  state_build --argjson i "$idx" 'del(.routing_rule_sets[$i])'
  apply_state
  ok "规则集已删除。"
}

# 保留旧函数入口，已升级脚本调用时统一进入新菜单。
block_website_menu() { routing_menu; }

# -------------------------
# 更新内核 / 刷新 IP
# -------------------------
restore_bin_atomic() {
  local bak="$1" target="$2" stage
  mkdir -p "$(dirname "$target")" 2>/dev/null || return 1
  stage="${target}.restore.${WORK_TAG}"
  if install -m 755 "$bak" "$stage" && mv -f "$stage" "$target"; then
    return 0
  fi
  rm -f "$stage" 2>/dev/null || true
  return 1
}

update_core_wizard() {
  local current_ver latest_ver bin wd rc new_ver
  local agent_was_active=0 sb_changed=0 sp_changed=0

  bin="$(resolve_singbox_bin)"
  if [ -n "$bin" ]; then
    current_ver="$("$bin" version 2>/dev/null | head -n 1 | awk '{print $3}' || true)"
  else
    current_ver="未知"
  fi

  info "正在获取自编译 sing-box 最新版本..."
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
    confirm_or_cancel "是否强制重新安装？输入 y 确认: " n "" || return $?
  else
    confirm_or_cancel "确认更新到最新版本？输入 y 确认 [默认 y]: " y "" || return $?
  fi

  state_write_guard || return $?
  # 先备份旧二进制，安装或重启失败时恢复，避免把服务搞成“没有可执行文件”或停服
  local orig_bin="$bin"
  wd="$(new_work_dir)"
  if [ -n "$orig_bin" ] && [ -x "$orig_bin" ]; then
    cp -p "$orig_bin" "$wd/sing-box.bak"
  fi
  if [ -x "$SINGBOX_PLUS_BIN" ]; then
    cp -p "$SINGBOX_PLUS_BIN" "$wd/singbox-plus.bak"
  fi
  if agent_service_is_active; then
    agent_was_active=1
  fi

  # 下载并原子替换新二进制，不提前停服，避免下载超时或中断导致停服
  # 子 shell 里运行，保证里面的 die 不会直接结束整个操作
  set +e
  ( set -e; SINGBOX_VERSION="$latest_ver" install_singbox force )
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    bin="$(resolve_singbox_bin)"
    new_ver="$( [ -n "$bin" ] && "$bin" version 2>/dev/null | head -n 1 | awk '{print $3}' || true)"
    if [ "$new_ver" != "$latest_ver" ]; then
      warn "当前版本 ${new_ver:-未知} 与 Release 最新版 ${latest_ver} 不一致。"
    fi
    if service_restart && is_singbox_running; then
      if [ "$agent_was_active" -eq 1 ]; then
        agent_service_start || warn "singbox-plus 已更新，但重启 ysq-agent 失败，请在「中控连接管理」中检查状态。"
      fi
      rm -rf "$wd"
      ok "更新并重启完成。"
      return 0
    fi
    err "新版本重启或运行检查失败，正在恢复旧版本..."
  fi

  if [ -f "$wd/sing-box.bak" ] && [ -n "$orig_bin" ]; then
    if [ ! -x "$orig_bin" ] || ! cmp -s "$wd/sing-box.bak" "$orig_bin" \
        || { [ "$orig_bin" != "$CORE_BIN_FILE" ] && [ -e "$CORE_BIN_FILE" ]; }; then
      sb_changed=1
    fi
  fi
  if [ -f "$wd/singbox-plus.bak" ]; then
    if [ ! -x "$SINGBOX_PLUS_BIN" ] || ! cmp -s "$wd/singbox-plus.bak" "$SINGBOX_PLUS_BIN"; then
      sp_changed=1
    fi
  fi

  if [ "$rc" -ne 0 ] && [ "$sb_changed" -eq 0 ] && [ "$sp_changed" -eq 0 ] && is_singbox_running; then
    err "更新失败，旧版本二进制未改动，sing-box 保持当前版本运行。"
    rm -rf "$wd"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    err "更新失败，正在恢复旧版本..."
  fi

  if [ -f "$wd/sing-box.bak" ] && [ -n "$orig_bin" ] && [ "$sb_changed" -eq 1 ]; then
    if [ "$orig_bin" != "$CORE_BIN_FILE" ]; then
      rm -f "$CORE_BIN_FILE" 2>/dev/null || true
    fi
    restore_bin_atomic "$wd/sing-box.bak" "$orig_bin" \
      || warn "恢复旧版 sing-box 二进制失败：${orig_bin}"
    hash -r 2>/dev/null || true
  fi
  if [ -f "$wd/singbox-plus.bak" ] && [ "$sp_changed" -eq 1 ]; then
    restore_bin_atomic "$wd/singbox-plus.bak" "$SINGBOX_PLUS_BIN" \
      || warn "恢复旧版 singbox-plus 二进制失败：${SINGBOX_PLUS_BIN}"
  fi
  if [ -f "$wd/sing-box.bak" ] && [ -n "$orig_bin" ]; then
    ( set -e; ensure_singbox_service ) || true
    service_restart || true
  fi
  if [ "$agent_was_active" -eq 1 ] && [ "$sp_changed" -eq 1 ]; then
    agent_service_start || true
  fi
  rm -rf "$wd"
  return 1
}

refresh_ip_wizard() {
  need_state
  step "刷新公网 IP"

  local current_ver current_ip choice new_ip new_ver

  state_read '(.ip_version // "ipv4"), .server_ip' current_ver current_ip

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
    and ((.direct_domains // []) | type == "array")
    and ((.routing_rule_sets // []) | type == "array")
  ' "$STATE_FILE" >/dev/null 2>&1
}

# 沿用旧状态文件时，公网 IP 可能已变（换了服务器）：检测并按需更新
refresh_ip_if_changed() {
  local ver old new flag loc code

  state_read '(.ip_version // "ipv4"), .server_ip' ver old

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
    if ! confirm_or_cancel "是否更新为当前 IP？输入 y 更新 [默认 y]: " y ""; then
      info "保留 ${old}。"
      return 0
    fi
  fi

  IFS='|' read -r code flag loc <<<"$(detect_location "$new" self "本机")"

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
# 检查配置文件。
#   - check 正常失败（配置有错）：返回 1
#   - check 被系统杀掉（退出码 137，多半是内存不足）：先重试一次；
#     仍被杀就用 jq 确认 JSON 合法后跳过 check，交给「启动服务」来验证（启动失败会自动回滚）
check_config_file() {
  local f="$1" rc=0 sb=""

  sb="$(resolve_singbox_bin)"
  [ -n "$sb" ] || { err "未找到 sing-box 可执行文件。"; return 1; }

  "$sb" check -c "$f" && return 0 || rc=$?
  [ "$rc" -eq 137 ] || return 1

  warn "sing-box check 被系统杀掉（137，疑似内存不足），1 秒后重试一次..."
  sleep 1
  rc=0
  "$sb" check -c "$f" && return 0 || rc=$?
  [ "$rc" -eq 137 ] || return 1

  warn "重试仍被杀：内存不足。改为用 jq 确认 JSON 合法后跳过 check，直接启动服务验证（启动失败会自动回滚）。"
  if ! jq -e . "$f" >/dev/null 2>&1; then
    err "配置不是合法的 JSON。"
    return 1
  fi
  return 0
}

render_config() {
  local tmp

  state_write_guard || return $?
  [ -f "$STATE_FILE" ] || { err "未找到状态文件：$STATE_FILE"; return 1; }
  # 若旧 VLESS 节点正好使用了 API 预留的 TCP 端口，应先调整该节点，而非生成必然抢占端口的配置。
  if jq -e --argjson p "$V2RAY_API_PORT" \
      '.nodes[]? | select(.type | startswith("vless")) | select((.port|tonumber) == $p)' \
      "$STATE_FILE" >/dev/null 2>&1; then
    err "旧 VLESS 节点使用了 TCP ${V2RAY_API_PORT}，与新 V2Ray API 冲突。请先将这个节点改到其他端口。"
    return 1
  fi
  if failover_configured && jq -e --argjson p "$FAILOVER_API_PORT" \
      '.nodes[]? | select(.type | startswith("vless")) | select((.port|tonumber)==$p)' "$STATE_FILE" >/dev/null; then
    err "VLESS 节点占用主备切换 API 端口 ${FAILOVER_API_PORT}，请先修改该节点端口。"
    return 1
  fi
  info "生成 sing-box 配置..."
  mkdir -p "$CORE_LOG_DIR"
  chmod 755 "$CORE_LOG_DIR"
  if id sing-box >/dev/null 2>&1; then
    chown sing-box:sing-box "$CORE_LOG_DIR"
  fi

  tmp="$(mktemp "${CONFIG_FILE}.tmp.${WORK_TAG}.XXXXXX")" || { err "无法创建临时配置文件。"; return 1; }

  if ! jq --arg api_listen "127.0.0.1:${V2RAY_API_PORT}" --arg cert_file "$CERT_FILE" --arg key_file "$KEY_FILE" --arg cache_file "${CORE_DATA_DIR}/route-rule-cache.db" --arg failover_listen "127.0.0.1:${FAILOVER_API_PORT}" '
    (.users |= map(select(.enabled != false))) as $s |

    def landing_id($id):
      first($s.landings[]? | select(.id == $id))
      // error("引用的落地节点不存在: " + $id);
    def relay_nodes: [$s.nodes[]? | select(.outbound_type == "landing")];
    def failover_nodes: [relay_nodes[] | select((.backup_landing_id // "") != "")];
    def landing_ids: [relay_nodes[] | .landing_id, (.backup_landing_id // empty) | select(. != "")] | unique;
    def policy_rule($field; $action):
      if (($s[$field] // []) | length) == 0 then []
      else [{domain_suffix:$s[$field]} + $action] end;
    def set_rule($action; $rule):
      [$s.routing_rule_sets[]? | select(.action == $action) | .tag] as $tags |
      if ($tags|length)==0 then [] else [{rule_set:$tags} + $rule] end;

    def vless_in($n):
    {
      "type": "vless",
      "tag": $n.tag,
      "listen": "::",
      "listen_port": ($n.port | tonumber),
      "users": ($s.users | map({"name": (.stats_key // .name), "uuid": .uuid, "flow": "xtls-rprx-vision"})),
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
      "users": ($s.users | map({"name": (.stats_key // .name), "uuid": .uuid, "password": .tuic_pass})),
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
        "certificate_path": $cert_file,
        "key_path": $key_file
      }
    };

    def landing_out($l):
    if ($l.type // "vless") == "tuic" then
      if (($l.uuid // "")|length)==0 or (($l.password // "")|length)==0 then error("TUIC 落地缺少 UUID 或密码") else
      {type:"tuic",tag:("out-"+$l.id),server:$l.server,server_port:($l.port|tonumber),
       uuid:$l.uuid,password:$l.password,congestion_control:($l.congestion_control // "bbr"),
       zero_rtt_handshake:false,heartbeat:"10s",
       tls:{enabled:true,server_name:($l.sni // $l.server),insecure:($l.insecure // false),alpn:($l.alpn // ["h3"])}}
       + (if $l.udp_over_stream == true then {udp_over_stream:true}
          else {udp_relay_mode:($l.udp_relay_mode // "native")} end) end
    elif ($l.type // "vless") == "vless" then {
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
          "fingerprint": ($l.fingerprint // "chrome")
        },
        "reality": {
          "enabled": true,
          "public_key": ($l.public_key // $s.public_key),
          "short_id": ($l.short_id // $s.short_id)
        }
      },
      "packet_encoding": "xudp"
    }
    elif ($l.type // "vless") == "socks" then
      if (($l.username // "") == "") and (($l.password // "") != "") then error("SOCKS5 落地填写密码时缺少用户名") else
      {type:"socks",tag:("out-"+$l.id),server:$l.server,server_port:($l.port|tonumber),version:"5"}
      + (if (($l.username // "")|length) > 0 then {username:$l.username,password:($l.password // "")} else {} end) end
    elif ($l.type // "vless") == "shadowsocks" then
      if (($l.method // "")|length)==0 or (($l.method != "none") and (($l.password // "")|length)==0) then error("Shadowsocks 落地缺少加密方式或密码") else
      {type:"shadowsocks",tag:("out-"+$l.id),server:$l.server,server_port:($l.port|tonumber),
       method:$l.method,password:($l.password // "")} end
    else error("落地协议不支持: " + ($l.type|tostring)) end;

    {
      "log": {
        "level": "info",
        "timestamp": true
      },
      "experimental": ({
        "v2ray_api": {
          "listen": $api_listen,
          "stats": {
            "enabled": true,
            "users": [$s.users[] | (.stats_key // .name)],
            "inbounds": [$s.nodes[]? | .tag],
            "outbounds": (["direct"] + [landing_ids[] | "out-" + .] + [failover_nodes[] | "failover-" + .tag])
          }
        }
      } + (if (($s.routing_rule_sets // []) | length) > 0 then
         {cache_file:{enabled:true,path:$cache_file}} else {} end)
        + (if (failover_nodes|length)>0 then
         {clash_api:{external_controller:$failover_listen,secret:$s.failover_secret}} else {} end)),
      "inbounds": [
        $s.nodes[]? | select(($s.users | length) > 0) |
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
          [landing_ids[] | landing_id(.) | landing_out(.)]
          + [failover_nodes[] |
            if .landing_id == .backup_landing_id then error("主备落地不能相同: " + .tag) else
              {type:"selector",tag:("failover-"+.tag),
               outbounds:[("out-"+.landing_id),("out-"+.backup_landing_id)],
               default:("out-"+.landing_id),interrupt_exist_connections:false} end]
        )
      ),
      "route": {
        "rule_set": [ $s.routing_rule_sets[]? |
          if (.action != "direct" and .action != "block") then error("规则集动作无效") else
          {type:"remote",tag:.tag,format:.format,url:.url,
           update_interval:(.update_interval // "1d"),http_client:{detour:"direct"}} end ],
        "rules": (
          (if ((($s.blocked_domains//[])|length)+(($s.direct_domains//[])|length)+(($s.routing_rule_sets//[])|length))>0
           then [{action:"sniff",timeout:"300ms"}] else [] end)
          + policy_rule("blocked_domains"; {action:"reject"})
          + set_rule("block"; {action:"reject"})
          + policy_rule("direct_domains"; {action:"route",outbound:"direct"})
          + set_rule("direct"; {action:"route",outbound:"direct"})
          + [relay_nodes[] | {inbound:[.tag],action:"route",
             outbound:(if (.backup_landing_id//"")!="" then "failover-"+.tag else "out-"+.landing_id end)}]
        ),
        "final": "direct"
      }
    }
  ' "$STATE_FILE" > "$tmp"; then
    rm -f "$tmp"
    err "生成配置失败（jq 报错，见上方信息）。"
    return 1
  fi

  chown root:sing-box "$tmp" 2>/dev/null || true
  chmod 640 "$tmp"

  # 先检查临时文件，通过后再原子替换正在使用的配置
  if ! check_config_file "$tmp"; then
    rm -f "$tmp"
    err "配置检查未通过，未替换现有配置。"
    return 1
  fi

  if ! mv -f "$tmp" "$CONFIG_FILE"; then
    rm -f "$tmp"
    err "替换配置文件失败。"
    return 1
  fi

  ok "配置已生成：$CONFIG_FILE"
  return 0
}

render_info() {
  # 可选参数：用户名、输出路径。未指定时仍导出所有用户的完整节点文件。
  local selected_user="${1:-}" out_file="${2:-$INFO_FILE}" user_label="默认用户"
  if [ "$out_file" = "$INFO_FILE" ]; then state_write_guard || return $?; fi
  [ -f "$STATE_FILE" ] || return 1
  if [ -n "$selected_user" ] && ! jq -e --arg name "$selected_user" \
    '[.users[]? | select(.enabled != false and .name == $name)] | length == 1' "$STATE_FILE" >/dev/null 2>&1; then
    err "所选用户不存在或已停用：${selected_user}"
    return 1
  fi

  local server_ip reality_sni tuic_sni public_key private_key short_id ip_version server_ip_display
  local type tag name port protocol outbound_type landing_disp landing_port user uuid tuic_pass encoded_name link
  local default_name default_uuid default_tuic_pass out_dir tmp

  state_read '.server_ip, .reality_sni, .tuic_sni, .public_key, .private_key, .short_id, (.ip_version // "ipv4"), ([.users[] | select(.enabled != false)][0].name), ([.users[] | select(.enabled != false)][0].uuid), ([.users[] | select(.enabled != false)][0].tuic_pass)' \
    server_ip reality_sni tuic_sni public_key private_key short_id ip_version default_name default_uuid default_tuic_pass
  if [ -n "$selected_user" ]; then
    IFS=$'\x1f' read -r default_name default_uuid default_tuic_pass <<< "$(
      jq -r --arg name "$selected_user" \
        '.users[] | select(.enabled != false and .name == $name) | [.name, .uuid, .tuic_pass] | join("\u001f")' "$STATE_FILE"
    )"
    user_label="用户"
  fi
  if is_ipv6 "$server_ip"; then
    server_ip_display="[${server_ip}]"
  else
    server_ip_display="$server_ip"
  fi

  out_dir="$(dirname "$out_file")"
  mkdir -p "$out_dir" || return 1
  tmp="$(mktemp "${out_dir}/.ysq-info.tmp.${WORK_TAG}.XXXXXX")" || return 1

  {
    cat <<INFO
==============================
ysq sing-box 节点信息（按用户）
==============================
服务器地址: ${server_ip} (${ip_version})
${user_label}: ${default_name}
UUID: ${default_uuid}
INFO
    if [ -z "$selected_user" ]; then
      printf 'REALITY PrivateKey: %s\n' "$private_key"
    fi
    cat <<INFO
REALITY PublicKey: ${public_key}
ShortID: ${short_id}
TUIC Password: ${default_tuic_pass}
V2Ray API: 127.0.0.1:${V2RAY_API_PORT} (仅本机)
配置文件: ${CONFIG_FILE}
状态文件: ${STATE_FILE}
节点信息: ${INFO_FILE}
YAML配置: ${YAML_FILE}

INFO
  } > "$tmp" || { rm -f "$tmp"; return 1; }

  if [ "$(jq '.nodes | length' "$STATE_FILE")" -eq 0 ]; then
    printf '当前还没有节点。输入 ysq 后在面板中添加节点。\n' >> "$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$out_file" || { rm -f "$tmp"; return 1; }
    return 0
  fi

  while IFS=$'\x1f' read -r type tag name port protocol outbound_type landing_disp landing_port user uuid tuic_pass encoded_name; do
    [ -n "$type" ] || continue
    if [[ "$type" == vless* ]]; then
      link="vless://${uuid}@${server_ip_display}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${encoded_name}"
    elif [[ "$type" == tuic* ]]; then
      link="tuic://${uuid}:${tuic_pass}@${server_ip_display}:${port}?congestion_control=bbr&alpn=h3&sni=${tuic_sni}&allow_insecure=1#${encoded_name}"
    else
      continue
    fi
    {
      echo "=============================="
      echo "节点: ${name}"
      echo "用户: ${user}"
      echo "类型: $(node_type_name "$type" "$outbound_type" "$tag")"
      echo "传输协议: ${protocol^^} / 端口: ${port}"
      if [ "$outbound_type" = "landing" ]; then
        echo "落地出口: ${landing_disp} (端口: ${landing_port})"
      fi
      echo "UUID: ${uuid}"
      if [[ "$type" == tuic* ]]; then echo "TUIC Password: ${tuic_pass}"; fi
      echo "$link"
      echo
    } >> "$tmp"
  done < <(jq -r --arg selected "$selected_user" '
    . as $s |
    $s.nodes[]? as $n |
    (first($s.landings[]? | select(.id == ($n.landing_id // ""))) // {}) as $l |
    ($s.users[] | select(.enabled != false) | select($selected == "" or .name == $selected)) as $u |
    [ $n.type, $n.tag, $n.name, ($n.port | tostring), ($n.protocol // "tcp"),
      ($n.outbound_type // "direct"), ($l.display // "-"), (($l.port // "-") | tostring),
      $u.name, $u.uuid, $u.tuic_pass, (($n.name + "-" + $u.name) | @uri) ] | join("\u001f")
  ' "$STATE_FILE")

  chmod 600 "$tmp" && mv -f "$tmp" "$out_file" || { rm -f "$tmp"; return 1; }
  return 0
}

render_yaml() {
  # 可选参数：用户名、输出路径。用于按用户查看，不改变磁盘上的全量 Clash 文件。
  local selected_user="${1:-}" out_file="${2:-$YAML_FILE}"
  if [ "$out_file" = "$YAML_FILE" ]; then state_write_guard || return $?; fi
  [ -f "$STATE_FILE" ] || return 1
  if [ -n "$selected_user" ] && ! jq -e --arg name "$selected_user" \
    '[.users[]? | select(.enabled != false and .name == $name)] | length == 1' "$STATE_FILE" >/dev/null 2>&1; then
    err "所选用户不存在或已停用：${selected_user}"
    return 1
  fi

  local public_key short_id reality_sni tuic_sni server_ip
  local type name port user uuid tuic_pass proxy_name out_dir tmp
  local -a names=()
  local q_server q_uuid q_pass q_rsni q_tsni q_pbk q_sid

  state_read '.public_key, .short_id, .reality_sni, .tuic_sni, .server_ip' \
    public_key short_id reality_sni tuic_sni server_ip

  q_server="$(yaml_quote "$server_ip")"
  q_rsni="$(yaml_quote "$reality_sni")"
  q_tsni="$(yaml_quote "$tuic_sni")"
  q_pbk="$(yaml_quote "$public_key")"
  q_sid="$(yaml_quote "$short_id")"

  out_dir="$(dirname "$out_file")"
  mkdir -p "$out_dir" || return 1
  tmp="$(mktemp "${out_dir}/.ysq-yaml.tmp.${WORK_TAG}.XXXXXX")" || return 1

  cat > "$tmp" <<YAML
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

  # 每个用户都有自己的 UUID / TUIC Password。同一个入口可以给多个用户生成独立订阅条目。
  # 第一个用户的节点名保持原样，兼容已有的 Clash 代理组引用。
  while IFS=$'\x1f' read -r type name port user uuid tuic_pass proxy_name; do
    [ -n "$type" ] || continue
    names+=("$proxy_name")
    q_uuid="$(yaml_quote "$uuid")"
    q_pass="$(yaml_quote "$tuic_pass")"
    if [[ "$type" == vless* ]]; then
      {
        printf '  - name: %s\n' "$(yaml_quote "$proxy_name")"
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
      } >> "$tmp"
    elif [[ "$type" == tuic* ]]; then
      {
        printf '  - name: %s\n' "$(yaml_quote "$proxy_name")"
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
      } >> "$tmp"
    fi
  done < <(jq -r --arg selected "$selected_user" '
    . as $s |
    $s.nodes[]? as $n |
    ($s.users | map(select(.enabled != false)) | to_entries[] | select($selected == "" or .value.name == $selected)) as $u |
    [$n.type, $n.name, ($n.port | tostring), $u.value.name, $u.value.uuid, $u.value.tuic_pass,
     (if $selected != "" or $u.key == 0 then $n.name else $n.name + "-" + $u.value.name end)] | join("\u001f")
  ' "$STATE_FILE")

  if [ "${#names[@]}" -eq 0 ]; then
    sed -i 's/^proxies:$/proxies: []/' "$tmp"
  fi
  cat >> "$tmp" <<YAML

proxy-groups:
  - name: PROXY
    type: select
    proxies:
YAML

  for name in "${names[@]}"; do
    printf '      - %s\n' "$(yaml_quote "$name")" >> "$tmp"
  done

  cat >> "$tmp" <<YAML
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
YAML

  chmod 600 "$tmp" && mv -f "$tmp" "$out_file" || { rm -f "$tmp"; return 1; }
  return 0
}

# 规范化 state -> 证书 -> 配置(临时文件 + check + mv)；yaml / info 失败不阻断
render_all() {
  ensure_state_defaults || return 1
  ensure_tuic_cert || return 1
  if failover_configured; then
    # Install all fallible helper assets before replacing the active core config.
    install_failover_bundle || return 1
  fi
  render_config || return 1
  render_yaml || warn "生成 Clash YAML 失败（不影响 sing-box 运行）。"
  render_info || warn "生成节点信息文件失败（不影响 sing-box 运行）。"
  return 0
}

restart_singbox() {
  state_write_guard || return $?
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

  state_write_guard || return $?
  if [ -f "$CONFIG_FILE" ]; then
    bak_conf="$(mktemp "${CONFIG_FILE}.tmp.${WORK_TAG}.XXXXXX")" || { err "无法创建备份文件。"; return 1; }
    if ! cp -p "$CONFIG_FILE" "$bak_conf"; then
      rm -f "$bak_conf"
      err "备份现有配置失败，未修改配置。"
      return 1
    fi
  fi

  if ! render_all; then
    if [ -n "$bak_conf" ]; then
      mv -f "$bak_conf" "$CONFIG_FILE" || { err "恢复配置备份失败：${bak_conf}"; return 1; }
    else
      rm -f "$CONFIG_FILE"
    fi
    err "重新渲染失败，已恢复原配置，未重启。"
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
      rerender_and_restart || return $?
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

  jq -r "$JQ_TABLE_LIB$JQ_NODE_LIB"'
    . as $s |
    ["序号", "节点名", "协议", "端口", "类型", "主落地", "备用落地"] as $headers |
    [4, 28, 6, 6, 20, 20, 20] as $mins |
    [
      .nodes | to_entries[] | .value as $n |
      ($n.outbound_type // "direct") as $out |
      [
        ((.key + 1) | tostring),
        ($n.name // "-"),
        (($n.protocol // "tcp") | ascii_upcase),
        ($n.port | tostring),
        node_type_name_for($s; $n),
        (if $out == "landing" then
          ((first($s.landings[]? | select(.id == ($n.landing_id // ""))) | .display) // "(落地已丢失)")
        else "-" end),
        (if $out == "landing" and (($n.backup_landing_id//"")!="") then
          ((first($s.landings[]? | select(.id == $n.backup_landing_id)) | .display) // "(落地已丢失)")
        else "-" end)
      ]
    ] as $rows |
    table($headers; $mins; $rows)
  ' "$STATE_FILE"

  return 0
}


# 单用户直接显示，多用户时选定用户后仅显示其对应的节点配置。
SELECTED_EXPORT_USER=""
select_export_user() {
  need_state
  local count pick
  SELECTED_EXPORT_USER=""
  count="$(jq -r '[.users[] | select(.enabled != false)] | length' "$STATE_FILE")"
  if [ "$count" -eq 0 ]; then
    warn "当前没有可查看的用户。"
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    SELECTED_EXPORT_USER="$(jq -r '[.users[] | select(.enabled != false)][0].name' "$STATE_FILE")"
    return 0
  fi

  echo "请选择用户："
  jq -r '[.users[] | select(.enabled != false)] | to_entries[] | "  \(.key + 1)) \(.value.name)"' "$STATE_FILE"
  read_line "输入用户序号（0 返回）: " pick
  pick="$(trim "$pick")"
  if [ -z "$pick" ] || [ "$pick" = "0" ]; then return "$CANCEL_RC"; fi
  if ! valid_index "$pick" "$count"; then
    warn "用户序号无效。"
    return 1
  fi
  SELECTED_EXPORT_USER="$(jq -r --argjson i "$((10#$pick - 1))" '[.users[] | select(.enabled != false)][$i].name' "$STATE_FILE")"
}

show_info() {
  local wd out
  select_export_user || return $?
  wd="$(new_work_dir)" || return 1
  out="${wd}/selected-node-info.txt"
  render_info "$SELECTED_EXPORT_USER" "$out" || return 1
  cat "$out"
}

show_yaml() {
  local wd out
  select_export_user || return $?
  wd="$(new_work_dir)" || return 1
  out="${wd}/selected-nodes.yaml"
  render_yaml "$SELECTED_EXPORT_USER" "$out" || return 1
  cat "$out"
}


show_logs() {
  step "sing-box 运行日志"

  local lines=100 out="" f latest_rot=""
  local -a rotated=() log_files=()

  while IFS= read -r f; do
    [ -s "$f" ] && rotated+=("$f")
  done < <(find "$CORE_LOG_DIR" -maxdepth 1 -type f -name 'sing-box.*.log' 2>/dev/null | LC_ALL=C sort)

  if [ "${#rotated[@]}" -gt 0 ]; then
    latest_rot="${rotated[$(( ${#rotated[@]} - 1 ))]}"
    log_files+=("$latest_rot")
  fi
  if [ -s "$LOG_FILE" ]; then
    log_files+=("$LOG_FILE")
  fi

  if [ "${#log_files[@]}" -gt 0 ]; then
    {
      for f in "${log_files[@]}"; do
        [ -r "$f" ] && cat "$f" 2>/dev/null || true
      done
    } | tail -n "$lines"
  else
    case "$SERVICE_MANAGER" in
      systemd)
        out="$(journalctl -u sing-box -n "$lines" --no-pager 2>&1 || true)"
        if [ -z "$out" ] || [[ "$out" == *"No entries"* ]]; then
          warn "暂无 sing-box 日志。"
        else
          printf '%s\n' "$out"
        fi
        ;;
      *)
        warn "暂无 sing-box 日志。"
        ;;
    esac
  fi

  echo
  local log_level
  log_level="$(jq -r '.log.level // "未知"' "$CONFIG_FILE" 2>/dev/null || true)"
  info "提示：当前日志级别为 ${log_level:-未知}"
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
  mkdir -p "$(dirname "$PANEL_FILE")"
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

# 删除 sing-box。keep=1 时只保留状态文件（UUID / 私钥 / 节点 / 主备落地 / 分流设置）
do_uninstall() {
  local keep="${1:-0}" p

  state_write_guard || return $?
  flush_agent_traffic
  agent_service_disable
  stop_failover_service
  service_stop
  service_disable

  rm -f "$CORE_BIN_FILE"
  rm -f "$SINGBOX_PLUS_BIN"
  rm -f "$CORE_SYSTEMD_FILE"
  rm -f "$CORE_OPENRC_FILE"
  rm -f "$CORE_PID_FILE"
  cleanup_legacy_log_trim
  rm -f "$FAILOVER_SYSTEMD_FILE" "$FAILOVER_OPENRC_FILE" "$FAILOVER_PID_FILE"
  rm -rf "$(dirname "$FAILOVER_STATUS_FILE")"
  rm -rf "$CORE_DATA_DIR" "$CORE_LOG_DIR"
  rm -f "$INFO_FILE" "$YAML_FILE" "$PANEL_FILE"
  rm -f "${YSQ_TEST_ROOT}/usr/local/libexec/ysq-agent.py" "$AGENT_SYSTEMD_FILE" "$AGENT_OPENRC_FILE" "$AGENT_PID_FILE"

  if [ "$keep" = "1" ]; then
    # 配置目录里除状态文件外全部删除（config.json / 证书 / 临时文件）
    for p in "$CONFIG_DIR"/* "$CONFIG_DIR"/.[!.]*; do
      [ -e "$p" ] || [ -L "$p" ] || continue
      [ "$p" != "$STATE_FILE" ] || continue
      rm -rf "$p"
    done
    chmod 600 "$STATE_FILE" 2>/dev/null || true
  else
    rm -rf "$CONFIG_DIR" "$(dirname "$AGENT_CONFIG_FILE")" "$AGENT_DATA_DIR"
    rm -f "$INSTALLER_FILE"
  fi

  service_daemon_reload
}

uninstall_all() {
  step "删除 sing-box"

  local mode

  echo "1) 彻底删除"
  echo "2) 保留节点数据 / 中控身份 / 流量账本"
  echo "0) 取消"
  read_line "请选择: " mode

  case "$mode" in
    1)
      confirm_or_cancel "确认彻底删除 sing-box 及全部节点数据？输入 y 确认: " || return $?
      do_uninstall 0
      ok "已彻底删除。"
      ;;
    2)
      if [ ! -f "$STATE_FILE" ]; then
        warn "未找到 ${STATE_FILE}，没有可保留的节点数据。"
        return 1
      fi
      confirm_or_cancel "确认删除 sing-box 并保留节点数据？输入 y 确认: " || return $?
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
  upgrade_singbox_plus_if_outdated
  ensure_dirs
  rerender_and_restart || die "升级后重启失败，已恢复旧配置。"
  # 从解压目录直接执行 upgrade 时，也将已验证成功的完整新脚本安装到快捷命令位置。
  if [ -f "${BASH_SOURCE[0]}" ] && ! [ "${BASH_SOURCE[0]}" -ef "$INSTALLER_FILE" ]; then
    local install_new="${INSTALLER_FILE}.new.${WORK_TAG}"
    mkdir -p "$(dirname "$INSTALLER_FILE")"
    [ ! -f "$INSTALLER_FILE" ] || cp -p "$INSTALLER_FILE" "${INSTALLER_FILE}.bak"
    install -m 755 "${BASH_SOURCE[0]}" "$install_new" || return 1
    mv -f "$install_new" "$INSTALLER_FILE" || return 1
  fi
  install_panel_wrapper
  release_config_lock
  restore_agent_if_configured
  ok "升级完成。"
}

update_panel_wizard() {
  need_state
  step "更新面板"

  local url="${YSQ_SCRIPT_URL:-$DEFAULT_SCRIPT_URL}"
  local wd tmp new_ver confirm_prompt confirm_default new_file bak

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
  # 本脚本是定制版本，上游原版更新会覆盖多用户管理与流量统计，阻止误更新。
  if ! grep -q '^# YSQ_CUSTOM_MULTIUSER_STATS_41453=1$' "$tmp"; then
    warn "远端不是带有用户管理 / V2Ray 统计的定制版，已拒绝覆盖当前面板。"
    info "如需更新，请将带相同定制功能的新脚本发布到你控制的地址，并设置 YSQ_SCRIPT_URL。"
    return 1
  fi

  if ! grep -q '^# YSQ_CENTRAL_MANAGEMENT_V1=1$' "$tmp"; then
    warn "远端缺少本版中控兼容标识，已拒绝旧版本覆盖。"
    info "请将本版完整脚本发布至自己的更新地址，并设置 YSQ_SCRIPT_URL。"
    return 1
  fi

  if [ -f "$INSTALLER_FILE" ] && cmp -s "$tmp" "$INSTALLER_FILE"; then
    info "远端脚本与当前脚本完全一致。"
    confirm_prompt="仍要重新安装一遍？输入 y 确认: "
    confirm_default="n"
  else
    confirm_prompt="确认更新？节点数据（${STATE_FILE}）会保留，更新后会重新渲染并重启 sing-box。输入 y 确认 [默认 y]: "
    confirm_default="y"
  fi
  if ! confirm_or_cancel "$confirm_prompt" "$confirm_default"; then
    rm -rf "$wd"
    return "$CANCEL_RC"
  fi

  flush_legacy_agent_if_needed
  state_write_guard || return $?
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

  (
    set -e
    YSQ_ACTION_WRITE_LOCKED=0
    YSQ_ACTION_STATE_BASELINE="$(state_fingerprint)" || die "无法读取操作开始时的配置状态。"
    "$@"
  )
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
  ( acquire_config_lock && ensure_state_defaults ) || die "状态文件规范化失败，请检查 ${STATE_FILE}。"

  local choice

  while true; do
    echo
    echo -e "${C_BOLD}==============================${C_RESET}"
    echo -e "${C_BOLD} ysq sing-box 管理面板  v${YSQ_VERSION}${C_RESET}"
    echo -e "${C_BOLD}==============================${C_RESET}"
    print_status_bar
    print_listen_summary
    echo "状态文件: ${STATE_FILE}"
    echo "配置文件: ${CONFIG_FILE}"
    echo

    list_nodes_table || true
    echo

    echo "1)  查看节点直链"
    echo "2)  查看 Clash YAML"
    echo "3)  查看 sing-box 日志"
    echo "4)  添加节点"
    echo "5)  删除节点"
    echo "6)  修改节点"
    echo "7)  落地节点池管理"
    echo "8)  用户管理"
    echo "9)  流量统计"
    echo "10) 分流管理"
    echo "11) 更新 sing-box 内核"
    echo "12) 重启 sing-box"
    echo "13) 刷新公网 IP"
    echo "14) 更新面板"
    echo "15) 中控连接管理"
    echo "16) 删除 sing-box"
    echo "0)  退出"
    echo "=============================="
    read_line "请输入选项: " choice
    case "$choice" in
      1) act show_info ;;
      2) act show_yaml ;;
      3) act show_logs ;;
      4) act add_node_wizard ;;
      5) act delete_node_wizard ;;
      6) act modify_node_wizard ;;
      7) landing_pool_menu ;;
      8) user_management_menu ;;
      9) act show_traffic_stats ;;
      10) block_website_menu ;;
      11) act update_core_wizard ;;
      12) act restart_wizard ;;
      13) act refresh_ip_wizard ;;
      14) act update_panel_wizard ;;
      15) central_management_menu ;;
      16) act uninstall_all ;;
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
    if [ "$name" = "vless" ] && [ "$((10#$val))" -eq "$V2RAY_API_PORT" ]; then
      die "TCP ${V2RAY_API_PORT} 已留给 V2Ray API，请使用其他 VLESS 端口。"
    fi
    if [ "$name" = "vless" ] && [ "$((10#$val))" -eq "$FAILOVER_API_PORT" ]; then
      die "TCP ${FAILOVER_API_PORT} 已留给主备切换本机 API，请使用其他 VLESS 端口。"
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
  local prev="${STATE_FILE}.prev.${WORK_TAG}" bad
  if [ -f "$STATE_FILE" ]; then
    cp -p "$STATE_FILE" "$prev"
    INSTALL_PREV_FILE="$prev"
    if state_file_valid; then
      step "沿用已有状态文件"
      ok "检测到有效的 ${STATE_FILE}：将沿用其中的 UUID / 密钥 / 节点 / 主备落地 / 分流设置，不会覆盖。"
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
      warn "已恢复安装前的状态文件（配置文件请在 ysq 面板里选「重启 → 重新渲染后重启」重新生成）。"
    fi
    die "sing-box 启动失败，请根据上方日志排查。"
  fi

  rm -f "$prev"
  if save_self; then
    install_panel_wrapper
    PANEL_READY=1
  fi
  release_config_lock
  restore_agent_if_configured
  print_summary
}

# 主备切换独立于中控 Agent；单机使用也会安装此本地 worker。
failover_configured() {
  jq -e '.nodes[]? | select(.outbound_type=="landing" and ((.backup_landing_id//"")!=""))' "$STATE_FILE" >/dev/null
}

install_failover_bundle() {
  local wd
  ensure_singbox_plus || return 1
  wd="$(new_work_dir)" || return 1
  mkdir -p "$(dirname "$FAILOVER_STATUS_FILE")" || return 1
  chmod 700 "$(dirname "$FAILOVER_STATUS_FILE")" || return 1
  rm -f "${YSQ_TEST_ROOT}/usr/local/libexec/ysq-failover.py"
  case "$SERVICE_MANAGER" in
    systemd)
      cat > "$wd/unit" <<EOF
[Unit]
Description=YSQ preferred landing failover monitor
After=network-online.target sing-box.service
Wants=network-online.target
[Service]
Type=simple
User=root
UMask=0077
ExecStart=${SINGBOX_PLUS_BIN} failover --config ${CONFIG_FILE} --status ${FAILOVER_STATUS_FILE}
Restart=on-failure
RestartSec=5s
TimeoutStopSec=15s
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
      if install_if_changed "$wd/unit" "$FAILOVER_SYSTEMD_FILE" 644; then
        service_daemon_reload
      else
        cmp -s "$wd/unit" "$FAILOVER_SYSTEMD_FILE" || return 1
      fi
      ;;
    openrc)
      cat > "$wd/unit" <<EOF
#!/sbin/openrc-run
description="YSQ preferred landing failover monitor"
command="${SINGBOX_PLUS_BIN}"
command_args="failover --config ${CONFIG_FILE} --status ${FAILOVER_STATUS_FILE}"
command_background="yes"
pidfile="${FAILOVER_PID_FILE}"
output_log="/dev/null"
error_log="/dev/null"
umask="0077"
retry="TERM/15/KILL/5"
depend() {
  need net
  after sing-box
}
EOF
      if ! install_if_changed "$wd/unit" "$FAILOVER_OPENRC_FILE" 755; then
        cmp -s "$wd/unit" "$FAILOVER_OPENRC_FILE" || return 1
      fi
      ;;
    none|test) ;;
  esac
  rm -rf "$wd"
}

stop_failover_service() {
  case "$SERVICE_MANAGER" in
    systemd) systemctl disable --now ysq-failover >/dev/null 2>&1 || true ;;
    openrc) rc-service ysq-failover stop >/dev/null 2>&1 || true; rc-update del ysq-failover default >/dev/null 2>&1 || true ;;
    none)
      if [ -f "$FAILOVER_PID_FILE" ]; then
        local pid cmdline=""
        pid="$(cat "$FAILOVER_PID_FILE" 2>/dev/null || true)"
        case "$pid" in
          ''|*[!0-9]*) ;;
          *)
            # A stale pid file must not stop an unrelated process after PID reuse.
            if [ -r "/proc/${pid}/cmdline" ]; then
              cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
            fi
            if { [[ "$cmdline" == *"$SINGBOX_PLUS_BIN"* ]] && [[ "$cmdline" == *failover* ]]; } \
                || [[ "$cmdline" == *ysq-failover.py* ]]; then
              kill "$pid" 2>/dev/null || true
              for _ in $(seq 1 15); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 1
              done
              if [ -r "/proc/${pid}/cmdline" ]; then
                cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
                if { [[ "$cmdline" == *"$SINGBOX_PLUS_BIN"* ]] && [[ "$cmdline" == *failover* ]]; } \
                    || [[ "$cmdline" == *ysq-failover.py* ]]; then
                  kill -9 "$pid" 2>/dev/null || true
                fi
              fi
            fi
            ;;
        esac
      fi
      ;;
  esac
  rm -f "$FAILOVER_PID_FILE"
}

sync_failover_service() {
  if ! failover_configured; then
    stop_failover_service
    rm -f "$FAILOVER_STATUS_FILE"
    return 0
  fi
  case "$SERVICE_MANAGER" in
    systemd) systemctl enable ysq-failover >/dev/null 2>&1; systemctl restart ysq-failover 9>&- ;;
    openrc) rc-update add ysq-failover default >/dev/null 2>&1; rc-service ysq-failover restart 9>&- ;;
    none)
      stop_failover_service
      ensure_singbox_plus || return 1
      mkdir -p "$(dirname "$FAILOVER_STATUS_FILE")" || return 1
      chmod 700 "$(dirname "$FAILOVER_STATUS_FILE")" || return 1
      mkdir -p "$(dirname "$FAILOVER_PID_FILE")" || return 1
      nohup "$SINGBOX_PLUS_BIN" failover --config "$CONFIG_FILE" --status "$FAILOVER_STATUS_FILE" </dev/null 9>&- >/dev/null 2>&1 &
      echo $! > "$FAILOVER_PID_FILE"
      ;;
    test) ;;
  esac
}

# -------------------------
# 可选中控：全节点零 Python 依赖（单机与中控托管模式均由 singbox-plus 提供）。
# -------------------------
config_lock_package() {
  if [ "$PKG_MANAGER" = "apk" ]; then printf '%s\n' flock; else printf '%s\n' util-linux; fi
}

ensure_config_lock_tool() {
  if ! command -v flock >/dev/null 2>&1; then
    [ -z "$YSQ_TEST_ROOT" ] || { err "隔离测试需要 flock。"; return 1; }
    need_root
    local package
    package="$(config_lock_package)"
    info "安装跨进程配置锁依赖 ${package}..." >&2
    if ! pkg_install "$package" >&2; then
      pkg_update >&2 || true
      pkg_install "$package" >&2 || { err "配置锁依赖安装失败：${package}。"; return 1; }
    fi
  fi
  command -v flock >/dev/null 2>&1 || { err "未找到 flock，请安装配置锁依赖后重试。"; return 1; }
}

acquire_config_lock() {
  local inherited="${YSQ_CONFIG_LOCK_FD:-}" timeout="${YSQ_LOCK_TIMEOUT:-30}"
  local ticks=0 max_ticks message rc inherited_fd=false
  # BusyBox flock lacks -w. Use the common -n operation, preserving a bounded
  # wait instead of confusing an unsupported option with lock contention.
  case "$timeout" in ''|*[!0-9]*) err "YSQ_LOCK_TIMEOUT 必须为 0-86400 的整数秒数。"; return 1 ;; esac
  if [ "${#timeout}" -gt 5 ] || [ "$((10#$timeout))" -gt 86400 ]; then
    err "YSQ_LOCK_TIMEOUT 必须为 0-86400 的整数秒数。"
    return 1
  fi
  max_ticks=$((10#$timeout * 5))
  ensure_config_lock_tool || return 1
  if [ "$inherited" = 9 ] && [ "${YSQ_CONFIG_LOCK_PATH:-}" = "$CONFIG_LOCK_FILE" ] \
      && ( : >&9 ) 2>/dev/null; then
    inherited_fd=true
  fi
  if [ "$inherited_fd" != true ]; then
    mkdir -p "$(dirname "$CONFIG_LOCK_FILE")" || { err "无法创建配置锁目录。"; return 1; }
    if ! exec 9>>"$CONFIG_LOCK_FILE"; then err "无法打开配置锁文件。"; return 1; fi
    if ! chmod 600 "$CONFIG_LOCK_FILE"; then exec 9>&-; err "无法设置配置锁权限。"; return 1; fi
  fi
  while true; do
    if message="$(LC_ALL=C flock -n 9 2>&1)"; then
      export YSQ_CONFIG_LOCK_FD=9
      export YSQ_CONFIG_LOCK_PATH="$CONFIG_LOCK_FILE"
      return 0
    else
      rc=$?
    fi
    # Both BusyBox and util-linux return silent status 1 for contention.
    # Usage/FD/command failures are actionable tool errors, never "busy".
    if [ "$rc" -ne 1 ] || [ -n "$message" ]; then
      exec 9>&-
      err "配置锁工具执行失败（退出码 ${rc}）：${message:0:240}"
      return 1
    fi
    if [ "$ticks" -ge "$max_ticks" ]; then
      exec 9>&-
      err "另一项面板操作正在修改配置，等待 ${timeout} 秒仍未释放，请稍后重试。"
      return 1
    fi
    sleep 0.2 || { exec 9>&-; err "等待配置锁失败。"; return 1; }
    ticks=$((ticks + 1))
  done
}

release_config_lock() {
  exec 9>&- 2>/dev/null || true
  unset YSQ_CONFIG_LOCK_FD YSQ_CONFIG_LOCK_PATH
  YSQ_ACTION_WRITE_LOCKED=0
}

agent_binding_present() {
  if [ -s "$AGENT_CONFIG_FILE" ] && jq -e '
      (.detached != true) and
      (((.node_id // "") | length) > 0 or ((.registration_id // "") | length) > 0)
    ' "$AGENT_CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi
  [ -s "$STATE_FILE" ] && jq -e '.management.mode == "managed" or .management.mode == "pending"' \
    "$STATE_FILE" >/dev/null 2>&1
}

require_local_user_management() {
  if agent_binding_present; then
    err "本机用户已由中控托管，请在中控网页管理用户；解绑后恢复本机编辑。"
    return 1
  fi
}

flush_agent_traffic() {
  [ "${YSQ_SKIP_AGENT_FLUSH:-0}" != "1" ] || return 0
  [ -s "$AGENT_CONFIG_FILE" ] && [ -x "$SINGBOX_PLUS_BIN" ] || return 0
  if ! "$SINGBOX_PLUS_BIN" agent --config "$AGENT_CONFIG_FILE" --timeout 8s sample-once 9>&- >/dev/null 2>&1; then
    warn "停止前流量采样未成功，继续服务操作；最后一个采样间隔可能存在统计缺口。"
  fi
  return 0
}

install_agent_service() {
  local wd
  wd="$(new_work_dir)"
  case "$SERVICE_MANAGER" in
    systemd)
      cat > "$wd/agent-unit" <<EOF
[Unit]
Description=YSQ HTTPS center agent
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
UMask=0077
ExecStart=${SINGBOX_PLUS_BIN} agent --config ${AGENT_CONFIG_FILE} run
Restart=on-failure
RestartSec=5s
TimeoutStopSec=135s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
      mkdir -p "$(dirname "$AGENT_SYSTEMD_FILE")"
      if install_if_changed "$wd/agent-unit" "$AGENT_SYSTEMD_FILE" 644; then
        service_daemon_reload
      fi
      ;;
    openrc)
      cat > "$wd/agent-unit" <<EOF
#!/sbin/openrc-run
description="YSQ HTTPS center agent"
command="${SINGBOX_PLUS_BIN}"
command_args="agent --config ${AGENT_CONFIG_FILE} run"
command_background="yes"
pidfile="${AGENT_PID_FILE}"
output_log="${AGENT_DATA_DIR}/agent.log"
error_log="${AGENT_DATA_DIR}/agent.log"
umask="0077"
retry="TERM/135/KILL/5"
depend() {
  need net
  after sing-box
}
EOF
      mkdir -p "$(dirname "$AGENT_OPENRC_FILE")"
      install_if_changed "$wd/agent-unit" "$AGENT_OPENRC_FILE" 755 || true
      ;;
    test) ;;
    *) err "中控 Agent 常驻运行需要 systemd 或 OpenRC；本机可继续单机使用。"; rm -rf "$wd"; return 1 ;;
  esac
  rm -rf "$wd"
}

YSQ_LEGACY_AGENT_FLUSHED="${YSQ_LEGACY_AGENT_FLUSHED:-0}"
YSQ_LEGACY_AGENT_SYNC_OK="${YSQ_LEGACY_AGENT_SYNC_OK:-0}"

config_lock_currently_held() {
  [ -f "$CONFIG_LOCK_FILE" ] || return 1
  command -v flock >/dev/null 2>&1 || return 1
  if ( exec 8>>"$CONFIG_LOCK_FILE" && LC_ALL=C flock -n 8 ) 2>/dev/null; then
    return 1
  fi
  return 0
}

flush_legacy_agent_if_needed() {
  local legacy_agent="${YSQ_TEST_ROOT}/usr/local/libexec/ysq-agent.py"
  local sync_rc=0
  [ "$YSQ_LEGACY_AGENT_FLUSHED" != "1" ] || return 0
  [ -f "$legacy_agent" ] && command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
    && [ -s "$AGENT_CONFIG_FILE" ] && agent_binding_present || return 0
  if [ "${YSQ_CONFIG_LOCK_FD:-}" = "9" ] || config_lock_currently_held; then
    warn "当前已有进程持有配置锁，已跳过旧版 Python Agent 切换前同步以避免死锁。"
    warn "旧版脚本 ${legacy_agent} 与 SQLite 数据库（${AGENT_DATA_DIR}）已保留；升级结束后可执行以下命令补报并清理："
    warn "  python3 ${legacy_agent} --config ${AGENT_CONFIG_FILE} sync-once && rm -f ${legacy_agent}"
    return 0
  fi
  info "检测到旧版 Python Agent，正在执行切换前最后一次流量同步..."
  agent_service_stop
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 python3 "$legacy_agent" --config "$AGENT_CONFIG_FILE" sync-once 9>&- >/dev/null 2>&1 || sync_rc=$?
  else
    python3 "$legacy_agent" --config "$AGENT_CONFIG_FILE" sync-once 9>&- >/dev/null 2>&1 || sync_rc=$?
  fi
  YSQ_LEGACY_AGENT_FLUSHED=1
  export YSQ_LEGACY_AGENT_FLUSHED
  if [ "$sync_rc" -eq 0 ]; then
    YSQ_LEGACY_AGENT_SYNC_OK=1
    export YSQ_LEGACY_AGENT_SYNC_OK
    ok "旧版 Python Agent 切换前流量同步完成。"
  else
    YSQ_LEGACY_AGENT_SYNC_OK=0
    export YSQ_LEGACY_AGENT_SYNC_OK
    warn "旧版 Python Agent 切换前流量同步失败（退出码 ${sync_rc}）；已保留 ${legacy_agent} 与 ${AGENT_DATA_DIR} 中的旧版 SQLite 数据库。"
    warn "待中控恢复连通后，可手动执行以下命令补报并清理："
    warn "  python3 ${legacy_agent} --config ${AGENT_CONFIG_FILE} sync-once && rm -f ${legacy_agent}"
  fi
  return 0
}

install_agent_bundle() {
  local legacy_agent="${YSQ_TEST_ROOT}/usr/local/libexec/ysq-agent.py"
  local had_bound_legacy=0
  ensure_singbox_plus || return 1
  mkdir -p "$(dirname "$AGENT_CONFIG_FILE")" "$AGENT_DATA_DIR"
  chmod 700 "$(dirname "$AGENT_CONFIG_FILE")" "$AGENT_DATA_DIR"
  if [ -f "$legacy_agent" ] && [ -s "$AGENT_CONFIG_FILE" ] && agent_binding_present; then
    had_bound_legacy=1
  fi
  if [ "$had_bound_legacy" -eq 1 ]; then
    flush_legacy_agent_if_needed
    if [ "$YSQ_LEGACY_AGENT_SYNC_OK" = "1" ]; then
      rm -f "$legacy_agent"
    else
      warn "由于旧版 Python Agent 最后一次流量同步未确认成功，已保留 ${legacy_agent} 以便后续补报。"
    fi
  else
    rm -f "$legacy_agent"
  fi
  install_agent_service || return 1
}

agent_service_is_active() {
  case "$SERVICE_MANAGER" in
    systemd) systemctl is-active --quiet ysq-agent 2>/dev/null ;;
    openrc) rc-service ysq-agent status >/dev/null 2>&1 ;;
    test) [ -f "$AGENT_DATA_DIR/test-running" ] ;;
    *) return 1 ;;
  esac
}

agent_service_stop() {
  case "$SERVICE_MANAGER" in
    systemd) systemctl stop ysq-agent 2>/dev/null || true ;;
    openrc) rc-service ysq-agent stop 2>/dev/null || true ;;
    test) rm -f "$AGENT_DATA_DIR/test-running" ;;
  esac
}

agent_service_start() {
  case "$SERVICE_MANAGER" in
    systemd)
      systemctl enable ysq-agent >/dev/null 2>&1 || true
      systemctl restart ysq-agent 9>&-
      ;;
    openrc)
      rc-update add ysq-agent default >/dev/null 2>&1 || true
      rc-service ysq-agent restart 9>&-
      ;;
    test) : > "$AGENT_DATA_DIR/test-running" ;;
    *) return 1 ;;
  esac
}

agent_service_disable() {
  agent_service_stop
  case "$SERVICE_MANAGER" in
    systemd) systemctl disable ysq-agent >/dev/null 2>&1 || true ;;
    openrc) rc-update del ysq-agent default >/dev/null 2>&1 || true ;;
  esac
}

restore_agent_if_configured() {
  agent_binding_present || return 0
  [ -s "$AGENT_CONFIG_FILE" ] || { warn "中控绑定配置缺失，请恢复 Agent 配置备份；保留当前已生效用户。"; return 0; }
  install_agent_bundle || { warn "恢复 Agent 失败；代理服务保留当前用户配置。"; return 0; }
  agent_service_start || warn "Agent 启动失败，请在「中控连接管理」中检查状态。"
}

valid_agent_join_code() {
  # musl limits ERE repetitions to 255; {32,256} is an invalid expression.
  # Keep the protocol's full 256-character allowance using separate checks.
  local value="${1:-}" LC_ALL=C
  [ "${#value}" -ge 32 ] && [ "${#value}" -le 256 ] || return 1
  case "$value" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  return 0
}

agent_join_wizard() {
  need_state
  local retrying_register=0
  if agent_binding_present; then
    if [ -s "$AGENT_CONFIG_FILE" ] && jq -e '
        (.detached != true) and (.node_id == null) and (.status == "registering")
      ' "$AGENT_CONFIG_FILE" >/dev/null 2>&1; then
      retrying_register=1
      info "上一次连接尚未成功，可重新粘贴连接信息；将保留注册身份继续尝试。"
    else
      warn "本机已经绑定中控。可查看详细状态，或先解除绑定后再连接。"
      return 1
    fi
  fi
  local line url code
  step "HTTPS 连接中控"
  echo "请从中控网页复制完整连接信息，一次粘贴并回车。"
  echo "格式：https://panel.eulmo.com|一次性接入码"
  read_line "连接信息: " line
  line="$(trim "$line")"
  [ -n "$line" ] || return "$CANCEL_RC"
  case "$line" in
    *'|'*) url="${line%%|*}"; code="${line#*|}" ;;
    *) err "格式错误：请粘贴中控网页生成的整句（HTTPS 地址|接入码）。"; return 1 ;;
  esac
  url="$(trim "$url")"
  code="$(trim "$code")"
  case "$url" in https://*) ;; *) err "中控地址必须使用 HTTPS。"; return 1 ;; esac
  if ! valid_agent_join_code "$code"; then
    err "接入码格式不正确，请重新从中控网页复制完整连接信息。"
    return 1
  fi
  flush_legacy_agent_if_needed
  ( acquire_config_lock && install_agent_bundle ) || return 1
  if [ "$retrying_register" -eq 1 ]; then
    # 先停掉后台重试中的 ysq-agent，避免其持有 .sync.lock 导致 join 锁竞争失败
    agent_service_stop
  fi
  # Agent joins without holding the config lock; it reads local inventory.
  if ! "$SINGBOX_PLUS_BIN" agent --config "$AGENT_CONFIG_FILE" join \
    --url="$url" --code="$code" --script="$INSTALLER_FILE" >/dev/null; then
    if agent_binding_present; then
      agent_service_start || true
      warn "注册身份已在本机保存。如果是暂时的网络错误，Agent 会后台自动重试；请查看详细状态。"
    fi
    return 1
  fi
  agent_service_start || { err "中控已注册，但 Agent 服务未能启动；请查看详细状态。"; return 1; }
  ok "接入成功！原有用户已自动导入中控，节点将自动同步用户配置与流量。"
  info "无需在中控网页再次批准，也无需手动触发同步。"
}

agent_status_wizard() {
  step "中控详细状态"
  if [ ! -s "$AGENT_CONFIG_FILE" ] || [ ! -x "$SINGBOX_PLUS_BIN" ]; then
    if agent_binding_present; then
      warn "运行模式：中控托管（异常：缺少 Agent 配置文件或 singbox-plus 组件）"
      warn "本机状态文件仍处于中控托管模式；如无法恢复 Agent 配置，请使用选项 3「解除中控绑定」强制恢复单机模式。"
      return 0
    fi
    info "运行模式：单机模式（未连接中控）"
    info "用户配置：在本机 ysq 菜单管理"
    return 0
  fi
  local status mode center node_id revision last_sync last_sample pending rows
  local sync_error apply_error sample_error running text last_sync_display last_sample_display
  status="$("$SINGBOX_PLUS_BIN" agent --config "$AGENT_CONFIG_FILE" status)" || {
    err "无法读取 Agent 状态，请检查 ysq-agent 服务日志。"
    return 1
  }
  IFS=$'\x1f' read -r center node_id mode revision last_sync last_sample pending rows sync_error apply_error sample_error running < <(
    jq -r '
      def clean: tostring | gsub("[\\r\\n\\u001f]+"; " ");
      [
        (.center_url // "-" | clean),
        (.node_id // "-" | clean),
        (.status // "unknown" | clean),
        ((.applied_revision // 0) | tostring),
        ((.last_sync_at // 0) | tostring),
        ((.last_sample_at // 0) | tostring),
        ((.pending_batches // 0) | tostring),
        ((.unpackaged_rows // 0) | tostring),
        (.sync_error // "" | clean),
        (.apply_error // "" | clean),
        (.collector_error // "" | clean),
        ((.service_running // false) | tostring)
      ] | join("\u001f")
    ' <<<"$status"
  )
  last_sync_display="尚未成功同步"
  last_sample_display="尚未成功采样"
  if [[ "$last_sync" =~ ^[0-9]+$ ]] && [ "$last_sync" -gt 0 ]; then
    last_sync_display="$(date -d "@$last_sync" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_sync")"
  fi
  if [[ "$last_sample" =~ ^[0-9]+$ ]] && [ "$last_sample" -gt 0 ]; then
    last_sample_display="$(date -d "@$last_sample" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_sample")"
  fi
  case "$mode" in
    active) text="已连接（中控托管）" ;;
    pending|registering) text="正在接入（后台自动重试）" ;;
    detached) text="已解绑（单机模式）" ;;
    *) text="异常（${mode}）" ;;
  esac
  echo "运行模式    : ${text}"
  echo "中控地址    : ${center}"
  echo "服务器 ID   : ${node_id}"
  local agent_live=0 now_ts
  case "$SERVICE_MANAGER" in
    systemd) if systemctl is-active --quiet ysq-agent 2>/dev/null; then agent_live=1; fi ;;
    openrc) if rc-service ysq-agent status >/dev/null 2>&1; then agent_live=1; fi ;;
    test) if [ -f "$AGENT_DATA_DIR/test-running" ]; then agent_live=1; fi ;;
  esac
  if [ "$agent_live" -eq 1 ]; then
    echo "Agent 后台  : ● 正在运行（变更即时通知，流量每约 15 秒同步）"
  else
    echo "Agent 后台  : ○ 未运行（自动同步已中断）"
  fi
  now_ts="$(date +%s)"
  if [ "$mode" = active ] && [ "$agent_live" -eq 1 ] \
    && [ -z "$sync_error" ] && [[ "$last_sync" =~ ^[0-9]+$ ]] \
    && [ "$last_sync" -gt 0 ] && [ "$((now_ts - last_sync))" -ge 0 ] \
    && [ "$((now_ts - last_sync))" -lt 120 ]; then
    echo "中控通信    : ● 正常（近期同步成功）"
  else
    echo "中控通信    : ○ 未确认连接正常（见最近同步与错误状态）"
  fi
  if [ "$running" = true ]; then
    echo "sing-box    : ● 正在运行"
  else
    echo "sing-box    : ○ 未运行 / 检测异常"
  fi
  echo "已应用版本  : ${revision}"
  echo "最近同步    : ${last_sync_display}"
  echo "最近采样    : ${last_sample_display}"
  echo "待补报流量  : ${pending} 批次，${rows} 条待打包记录"
  if [ -n "$sync_error" ]; then echo "同步异常    : ${sync_error:0:220}"; fi
  if [ -n "$apply_error" ]; then echo "配置异常    : ${apply_error:0:220}"; fi
  if [ -n "$sample_error" ]; then echo "采样异常    : ${sample_error:0:220}"; fi
  if [ -z "$sync_error" ] && [ -z "$apply_error" ] && [ -z "$sample_error" ]; then
    echo "错误状态    : 无已记录异常"
  fi
}

agent_detach_wizard() {
  if [ ! -s "$AGENT_CONFIG_FILE" ] || [ ! -x "$SINGBOX_PLUS_BIN" ]; then
    if ! agent_binding_present; then
      err "尚未配置中控。"
      return 1
    fi
    warn "未找到有效的 Agent 配置或运行组件，但状态文件仍处于中控托管状态。"
    warn "强制本机解绑后将保留当前已启用用户并恢复本机用户编辑；已停用用户不会恢复。"
    confirm_or_cancel "确认强制本机解绑？输入 y（默认取消）: " n "" || return $?
    agent_service_disable
    agent_detach_action
    if [ -s "$AGENT_CONFIG_FILE" ]; then
      local cfg_tmp="${AGENT_CONFIG_FILE}.tmp.${WORK_TAG}"
      if jq '.detached = true | .status = "detached" | del(.node_token, .registration_payload, .registration_fingerprint, .registration_aliases)' "$AGENT_CONFIG_FILE" > "$cfg_tmp" 2>/dev/null; then
        chmod 600 "$cfg_tmp" 2>/dev/null || true
        mv -f "$cfg_tmp" "$AGENT_CONFIG_FILE" || rm -f "$cfg_tmp"
      else
        rm -f "$cfg_tmp"
      fi
    fi
    ok "已在本机强制解绑，恢复为单机模式。如中控仍有记录，请在中控网页撤销旧服务器。"
    return 0
  fi
  warn "解绑后保留当前已启用用户及统计账本，恢复本机用户编辑；已停用用户不会恢复。"
  confirm_or_cancel "确认主动解绑？输入 y: " n "" || return $?
  agent_service_stop
  if "$SINGBOX_PLUS_BIN" agent --config "$AGENT_CONFIG_FILE" detach >/dev/null; then
    agent_service_disable
    ok "已解绑，当前为单机模式。"
    return 0
  fi
  warn "正常解绑未完成。中控离线时可选择强制本机解绑，未确认的流量仍保留在本机账本。"
  if confirm_or_cancel "强制本机解绑？输入 y（默认取消）: " n ""; then
    if ! "$SINGBOX_PLUS_BIN" agent --config "$AGENT_CONFIG_FILE" detach --force >/dev/null; then
      agent_service_start || true
      return 1
    fi
    agent_service_disable
    ok "已在本机解绑。请在中控网页核对并撤销旧服务器记录。"
  else
    agent_service_start || true
    return "$CANCEL_RC"
  fi
}

central_management_menu() {
  local choice
  while true; do
    step "中控连接管理"
    if agent_binding_present; then
      info "当前状态：已配置中控连接（连接详情见选项 2）"
    else
      info "当前状态：单机模式"
    fi
    echo "1) HTTPS 连接中控"
    echo "2) 查看详细状态"
    echo "3) 解除中控绑定"
    echo "0) 返回"
    read_line "请选择: " choice
    case "$choice" in
      1) act agent_join_wizard ;;
      2) act agent_status_wizard ;;
      3) act agent_detach_wizard ;;
      0) return 0 ;;
      *) warn "输入错误。" ;;
    esac
  done
}

agent_inventory_action() {
  need_root
  need_state
  # One jq read sees a complete state snapshot because writers replace it atomically.
  local running=false
  is_singbox_running && running=true
  jq -c --argjson running "$running" '{
    users:[.users[]? | select(.enabled != false) | {name,uuid,tuic_pass}],
    inbounds:[. as $s | .nodes[]? | {name,tag,type,port,
      server:$s.server_ip, sni:(if (.type | startswith("tuic")) then $s.tuic_sni else $s.reality_sni end),
      public_key:(if (.type | startswith("tuic")) then "" else $s.public_key end),
      short_id:(if (.type | startswith("tuic")) then "" else $s.short_id end),
      skip_cert_verify:(.type | startswith("tuic"))}],
    management:(.management // {}), service_running:$running
  }' "$STATE_FILE"
}

validate_agent_payload() {
  local payload="$1"
  [ -f "$payload" ] && [ "$(wc -c < "$payload")" -le 8388608 ] || { err "用户快照不存在或过大。"; return 1; }
  jq -e '
    type == "object" and
    (.node_id | type == "string" and test("^n_[0-9a-f]{32}$")) and
    (.revision | type == "number" and . >= 1 and . <= 9007199254740991 and . == floor) and
    (.users | type == "array" and length <= 20000) and
    all(.users[];
      type == "object" and
      (.id | type == "string" and test("^u_[0-9a-f]{32}$")) and
      (.name | type == "string" and test("^[A-Za-z0-9]{1,32}$")) and
      (.uuid | type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")) and
      (.tuic_pass | type == "string" and test("^[A-Za-z0-9_-]{6,128}$")) and
      (.enabled | type == "boolean")) and
    (([.users[].id] | length) == ([.users[].id] | unique | length)) and
    (([.users[].name] | length) == ([.users[].name] | unique | length)) and
    (([.users[].uuid | ascii_downcase] | length) == ([.users[].uuid | ascii_downcase] | unique | length))
  ' "$payload" >/dev/null 2>&1 || { err "中控用户快照字段或唯一性校验失败。"; return 1; }
}

agent_apply_action() {
  need_root
  need_state
  acquire_config_lock || return 1
  local source="$1" payload node revision old_revision bound_node
  payload="$(new_work_dir)/desired.json"
  # 使用本进程私有副本，后续检查与应用使用完全相同的字节。
  [ -f "$source" ] || { err "未找到用户快照。"; return 1; }
  cp -- "$source" "$payload" || return 1
  chmod 600 "$payload"
  validate_agent_payload "$payload" || return 1
  node="$(jq -r '.node_id' "$payload")"
  revision="$(jq -r '.revision' "$payload")"
  [ -s "$AGENT_CONFIG_FILE" ] || { err "Agent 绑定配置缺失，拒绝应用。"; return 1; }
  bound_node="$(jq -r 'if .detached == true then "" else (.node_id // "") end' "$AGENT_CONFIG_FILE")"
  [ "$bound_node" = "$node" ] || { err "快照服务器身份与本机绑定不符。"; return 1; }
  old_revision="$(jq -r --arg n "$node" 'if .management.node_id == $n then (.management.revision // 0) else 0 end' "$STATE_FILE")"
  if [ "$revision" -lt "$old_revision" ]; then
    err "拒绝回退到较旧的中控版本。"
    return 1
  fi
  if [ "$revision" -eq "$old_revision" ] && jq -e '.management.applying_revision == null' "$STATE_FILE" >/dev/null; then
    if jq -e --slurpfile p "$payload" '
        [.users[] | {id,name,uuid:(.uuid|ascii_downcase),tuic_pass,enabled}] ==
        [$p[0].users[] | {id,name,uuid:(.uuid|ascii_downcase),tuic_pass,enabled}]
      ' "$STATE_FILE" >/dev/null; then
      if is_singbox_running; then return 0; fi
      # 磁盘版本已成功过但服务后来停止：允许相同快照恢复服务。
    else
      err "同一中控版本对应了不同用户内容，拒绝应用。"
      return 1
    fi
  fi
  state_build --slurpfile p "$payload" --argjson prev "$old_revision" '
    .users = [$p[0].users[] | {id,name,uuid:(.uuid|ascii_downcase),tuic_pass,enabled,stats_key:.id}] |
    .management = {mode:"managed",node_id:$p[0].node_id,revision:$prev,applying_revision:$p[0].revision}
  '
  apply_state || return 1
  # apply_state 已校验 restart_singbox && is_singbox_running，并在失败时原子回滚 state/config。
  # 只有真实应用成功后才记新 revision，崩溃重试不能把磁盘配置误当成已生效。
  state_build --argjson rev "$revision" '.management.revision=$rev | del(.management.applying_revision)'
  commit_state_plain
}

agent_detach_action() {
  need_root
  need_state
  acquire_config_lock || return 1
  state_build '.users = [.users[]? | select(.enabled != false)] | del(.management)'
  # 删除停用记录不会改变当前实际允许连接的用户，也无需重启内核。
  commit_state_plain
  render_yaml || true
  render_info || true
}


# -------------------------
# 入口
# -------------------------
main() {
  detect_runtime
  if [ -n "$YSQ_TEST_ROOT" ]; then
    case "$ACTION" in
      agent-inventory|agent-apply|agent-detach) ;;
      *) err "隔离测试模式只允许 agent-* helper；通过 source-only 测试其他纯函数。"; return 2 ;;
    esac
  fi

  case "$ACTION" in
    install)
      need_root
      validate_cli_ports
      flush_legacy_agent_if_needed
      acquire_config_lock || return 1
      install_wizard
      ;;
    panel)
      panel_menu
      ;;
    upgrade)
      need_root
      flush_legacy_agent_if_needed
      acquire_config_lock || return 1
      upgrade_action
      ;;
    agent-inventory)
      agent_inventory_action
      ;;
    agent-apply)
      agent_apply_action "$AGENT_PAYLOAD" >&2
      ;;
    agent-detach)
      agent_detach_action >&2
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
if [ "${YSQ_SOURCE_ONLY:-0}" = "1" ]; then
  # Explicit import for isolated tests; no main, package, service or network operations.
  :
elif [[ "$ACTION" == agent-* ]]; then
  main
elif [ ! -t 0 ] && ( : </dev/tty ) 2>/dev/null; then
  main </dev/tty
else
  main
fi
