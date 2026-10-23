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
#   - 所有修改先写临时文件；配置通过 sing-box check 后才替换（低内存机器上 check 被杀时改用 jq 校验 JSON，由启动服务验证）；失败自动回滚 state
#   - 面板里每个操作都在子 shell 中运行，die 只会中止当前操作，不会退出面板
#   - 节点管理与落地管理解耦：落地的增删改只在「落地节点池管理」里做，节点只能选择已有落地
#   - Alpine(OpenRC)：日志写入单个文件，busybox cron 每小时检查，达 9MB 裁剪、保留最后 2MB
# ============================================================

YSQ_VERSION="2026.10.23.3"
INSTALLER_NAME="install-singbox-ysq.sh"
DEFAULT_SCRIPT_URL="https://raw.githubusercontent.com/showcode1024/singbox-auto/main/install-singbox-ysq.sh"

# sing-box 内核统一从自编译 Release 下载（支持 linux-amd64 / linux-arm64）
SINGBOX_REPO="${SINGBOX_REPO:-showcode1024/singbox-auto}"
SINGBOX_FALLBACK_VERSION="${SINGBOX_FALLBACK_VERSION:-1.14.3}"

# -------------------------
# 默认端口
# -------------------------
# 节点（入站）端口下限：低于该值一律拒绝（同时也避开了 1024 以下需要特权的端口）
MIN_NODE_PORT=10000
VLESS_DIRECT_PORT=20001
TUIC_DIRECT_PORT=20002
# V2Ray API 仅绑定本机回环地址，不向公网开放 gRPC。
V2RAY_API_PORT=41453
GRPCURL_VERSION="1.9.4"
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
GRPCURL_YSQ_BIN="${YSQ_TEST_ROOT}/usr/local/libexec/ysq-grpcurl"

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

CONFIG_DIR="${YSQ_TEST_ROOT}/etc/sing-box"
CONFIG_FILE="${YSQ_TEST_ROOT}/etc/sing-box/config.json"
STATE_FILE="${YSQ_TEST_ROOT}/etc/sing-box/ysq-state.db"
CERT_DIR="${YSQ_TEST_ROOT}/etc/sing-box/cert"
CERT_FILE="${YSQ_TEST_ROOT}/etc/sing-box/cert/tuic.crt"
KEY_FILE="${YSQ_TEST_ROOT}/etc/sing-box/cert/tuic.key"
CERT_SNI_FILE="${YSQ_TEST_ROOT}/etc/sing-box/cert/tuic.sni"
LOG_FILE="${YSQ_TEST_ROOT}/var/log/sing-box/sing-box.log"
# 统一 info 文件日志：Agent 连续读取；systemd timer / OpenRC cron 提供容量检查兜底
LOG_TRIM_MAX_MB=9      # 日志文件达到 9MB 时触发裁剪
LOG_TRIM_KEEP_MB=2     # 裁剪后保留最后 2MB
LOG_TRIM_SCRIPT="${YSQ_TEST_ROOT}/usr/local/libexec/ysq-singbox-log-trim"
INFO_FILE="${YSQ_TEST_ROOT}/root/singbox-node-info.txt"
YAML_FILE="${YSQ_TEST_ROOT}/root/singbox-nodes.yaml"
PANEL_FILE="${YSQ_TEST_ROOT}/usr/local/bin/ysq"
INSTALLER_FILE="${YSQ_TEST_ROOT}/root/install-singbox-ysq.sh"

# Agent paths are separate from sing-box-owned directories and survive data-preserving uninstall.
AGENT_FILE="${YSQ_TEST_ROOT}/usr/local/libexec/ysq-agent.py"
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
PERIODIC_DIR="${YSQ_TEST_ROOT}/etc/periodic/hourly"
CRONTAB_DIR="${YSQ_TEST_ROOT}/etc/crontabs"
CRONTAB_FILE="${YSQ_TEST_ROOT}/etc/crontabs/root"
CROND_FILE="${YSQ_TEST_ROOT}/etc/init.d/crond"

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
  rm -f "${STATE_FILE}.tmp.${WORK_TAG}."* "${CONFIG_FILE}.tmp.${WORK_TAG}."* 2>/dev/null || true
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

ensure_singbox_user() {
  [ -z "$YSQ_TEST_ROOT" ] || return 0
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
    *) die "暂不支持当前 CPU 架构：$(uname -m)（自编译包仅提供 amd64 / arm64）" ;;
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
    rm -f "$bin"
  fi

  bin=${CORE_BIN_FILE}
  if [ -e "$bin" ] && ! singbox_bin_works "$bin"; then
    warn "删除无法运行的 sing-box：$bin"
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
  local arch version base tar_name tmp_dir tar_file sums_file expect actual found_bin

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
  curl -fL --connect-timeout 10 --retry 3 -o "$tar_file" "${base}/${tar_name}" \
    || die "sing-box 下载失败：${base}/${tar_name}"

  # SHA256 校验（Release 里有 SHA256SUMS 才校验；下载不到只警告）
  if curl -fsSL --connect-timeout 10 --retry 2 -o "$sums_file" "${base}/SHA256SUMS" 2>/dev/null; then
    expect="$(awk -v f="$tar_name" '{n=$2; sub(/^\.\//,"",n); sub(/^\*/,"",n); if (n==f) print $1}' "$sums_file" | head -n 1)"
    actual="$(sha256sum "$tar_file" | awk '{print $1}')"
    if [ -z "$expect" ]; then
      warn "SHA256SUMS 中没有 ${tar_name}，跳过校验。"
    elif [ "$expect" != "$actual" ]; then
      die "sing-box 压缩包 SHA256 校验失败（期望 ${expect}，实际 ${actual}）。"
    else
      ok "SHA256 校验通过。"
    fi
  else
    warn "未能下载 SHA256SUMS，跳过完整性校验。"
  fi

  tar -xzf "$tar_file" -C "$tmp_dir" || die "sing-box 解压失败。"

  found_bin="$(find "$tmp_dir" -type f -name sing-box | head -n 1)"
  [ -n "$found_bin" ] || die "下载包里未找到 sing-box 可执行文件。"

  install -m 755 "$found_bin" ${CORE_BIN_FILE}
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

# Agent 每秒读取后检查容量；定时裁剪在 Agent 停止时仍提供兜底。
install_log_trim() {
  local wd
  wd="$(new_work_dir)"
  mkdir -p "$(dirname "$LOG_TRIM_SCRIPT")"
  write_log_trim_script "$wd/trim"
  install_if_changed "$wd/trim" "$LOG_TRIM_SCRIPT" 755 || true
  rm -f "${YSQ_TEST_ROOT}/etc/periodic/hourly/ysq-singbox-log-trim"
  case "$SERVICE_MANAGER" in
    systemd)
      cat > "$wd/trim-service" <<EOF
[Unit]
Description=YSQ sing-box log size guard
[Service]
Type=oneshot
ExecStart=${LOG_TRIM_SCRIPT}
EOF
      cat > "$wd/trim-timer" <<'EOF'
[Unit]
Description=YSQ sing-box log size guard timer
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
      install_if_changed "$wd/trim-service" "${YSQ_TEST_ROOT}/etc/systemd/system/ysq-log-trim.service" 644 || true
      install_if_changed "$wd/trim-timer" "${YSQ_TEST_ROOT}/etc/systemd/system/ysq-log-trim.timer" 644 || true
      service_daemon_reload
      systemctl enable --now ysq-log-trim.timer >/dev/null 2>&1 || warn "日志容量检查 timer 启动失败，请检查 ysq-log-trim.timer。"
      ;;
    openrc)
      mkdir -p "${CRONTAB_DIR}"
      touch "${CRONTAB_FILE}"
      chmod 600 "${CRONTAB_FILE}"
      sed -i '/# ysq-log-trim$/d' "${CRONTAB_FILE}"
      echo "* * * * * ${LOG_TRIM_SCRIPT} # ysq-log-trim" >> "${CRONTAB_FILE}"
      if [ -x "${CROND_FILE}" ]; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond status >/dev/null 2>&1 || rc-service crond start 9>&- >/dev/null 2>&1 || true
      else
        warn "未找到 crond，Agent 停止时日志没有定时裁剪兜底。"
      fi
      ;;
  esac
  rm -rf "$wd"
}

remove_log_trim() {
  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    systemctl disable --now ysq-log-trim.timer >/dev/null 2>&1 || true
  fi
  rm -f "$LOG_TRIM_SCRIPT" "${YSQ_TEST_ROOT}/etc/periodic/hourly/ysq-singbox-log-trim" \
    "${YSQ_TEST_ROOT}/etc/systemd/system/ysq-log-trim.timer" "${YSQ_TEST_ROOT}/etc/systemd/system/ysq-log-trim.service"
  [ ! -f "${CRONTAB_FILE}" ] || sed -i '/# ysq-log-trim$/d' "${CRONTAB_FILE}"
}

# 只在安装 / 更新内核时调用；restart_singbox 不再重写 unit
ensure_singbox_service() {
  local wd

  SING_BOX_BIN="$(command -v sing-box 2>/dev/null || true)"
  if [ -z "$SING_BOX_BIN" ]; then
    die "未找到 sing-box 可执行文件。"
  fi

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
ExecStart=${SING_BOX_BIN} -D ${CORE_DATA_DIR} -c ${CONFIG_FILE} run
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
      if install_if_changed "$wd/unit" ${CORE_SYSTEMD_FILE} 644; then
        service_daemon_reload
      fi
      install_log_trim
      ;;
    openrc)
      cat > "$wd/unit" <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="${SING_BOX_BIN}"
command_args="-D ${CORE_DATA_DIR} -c ${CONFIG_FILE} run"
command_user="sing-box:sing-box"
command_background="yes"
pidfile="${CORE_PID_FILE}"
# stdout 与 stderr 都追加（O_APPEND）写入同一个文件，方便 cron 原地裁剪
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

start_pre() {
  checkpath -d -m 0755 -o sing-box:sing-box ${CORE_DATA_DIR}
  checkpath -d -m 0755 -o sing-box:sing-box ${CORE_LOG_DIR}
}

depend() {
  need net
  after firewall
}
EOF
      install_if_changed "$wd/unit" ${CORE_OPENRC_FILE} 755 || true
      install_log_trim
      ;;
    none)
      warn "未检测到 systemd/openrc，将使用 nohup 后台方式管理 sing-box。"
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

service_stop() {
  flush_agent_traffic
  if [ "$SERVICE_MANAGER" = "test" ]; then
    rm -f "${YSQ_TEST_ROOT}/run/test-singbox-running"
    return 0
  fi
  case "$SERVICE_MANAGER" in
    systemd) systemctl stop sing-box 2>/dev/null || true ;;
    openrc) rc-service sing-box stop 2>/dev/null || true ;;
    none)
      if [ -f ${CORE_PID_FILE} ]; then
        local old_pid
        old_pid="$(cat ${CORE_PID_FILE} 2>/dev/null || true)"
        if [ -n "$old_pid" ]; then
          kill "$old_pid" 2>/dev/null || true
          # 等旧进程真正退出（最多 15 秒），否则重启时新进程可能和旧进程抢端口
          for _ in $(seq 1 15); do
            kill -0 "$old_pid" 2>/dev/null || break
            sleep 1
          done
          kill -0 "$old_pid" 2>/dev/null && kill -9 "$old_pid" 2>/dev/null || true
        fi
        rm -f ${CORE_PID_FILE}
      fi
      pkill -f "sing-box.*-[cC] /etc/sing-box.*run" 2>/dev/null || true
      ;;
  esac
}

# 失败返回 1（不 die），方便上层回滚
service_restart() {
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
      sleep 0.5
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
      sleep 0.5
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
      install -d -m 755 -o sing-box -g sing-box ${CORE_DATA_DIR} ${CORE_LOG_DIR} 2>/dev/null \
        || mkdir -p ${CORE_DATA_DIR} ${CORE_LOG_DIR}
      # 没有 cron 可用：每次启动前（进程已停）顺手裁剪一次，并用追加模式写日志
      local trim_wd
      trim_wd="$(new_work_dir)"
      write_log_trim_script "$trim_wd/trim"
      sh "$trim_wd/trim" || true
      rm -rf "$trim_wd"
      nohup "$SING_BOX_BIN" -D ${CORE_DATA_DIR} -c ${CONFIG_FILE} run 9>&- >> "$LOG_FILE" 2>&1 &
      echo $! > ${CORE_PID_FILE}
      sleep 0.5
      if ! kill -0 "$(cat ${CORE_PID_FILE})" 2>/dev/null; then
        tail -n 20 "$LOG_FILE" >&2 || true
        err "sing-box 后台启动失败。"
        return 1
      fi
      ;;
  esac
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
      if [ -f ${CORE_PID_FILE} ] && kill -0 "$(cat ${CORE_PID_FILE})" 2>/dev/null; then
        ok "sing-box 正在运行，PID: $(cat ${CORE_PID_FILE})"
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
    none)    [ -f ${CORE_PID_FILE} ] && kill -0 "$(cat ${CORE_PID_FILE} 2>/dev/null)" 2>/dev/null ;;
  esac
}

get_singbox_pid() {
  [ "$SERVICE_MANAGER" != "test" ] || return 0
  local pid=""
  case "$SERVICE_MANAGER" in
    systemd)
      pid="$(systemctl show -p MainPID --value sing-box 2>/dev/null || true)"
      [ "$pid" = "0" ] && pid=""
      ;;
    openrc|none)
      if [ -f ${CORE_PID_FILE} ]; then
        pid="$(cat ${CORE_PID_FILE} 2>/dev/null || true)"
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

# 主菜单常驻监听摘要：全部正常时只显示「正常」，异常时列出具体协议和端口。
print_listen_summary() {
  local tcp_bound="" udp_bound="" p
  local tcp_missing="" udp_missing="" issues=""

  if ! command -v ss >/dev/null 2>&1; then
    echo -e "监听端口: ${C_RED}○ 无法检测（缺少 ss）${C_RESET}"
    return 0
  fi

  tcp_bound="$(ss -H -lnt 2>/dev/null | awk '{s=$4; sub(/^.*:/,"",s); if(s~/^[0-9]+$/) print s}' | sort -u || true)"
  udp_bound="$(ss -H -lnu 2>/dev/null | awk '{s=$4; sub(/^.*:/,"",s); if(s~/^[0-9]+$/) print s}' | sort -u || true)"

  if [ -f "$STATE_FILE" ]; then
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

  [ -z "$tcp_missing" ] || issues="TCP ${tcp_missing} 未监听"
  [ -z "$udp_missing" ] || issues="${issues:+${issues} | }UDP ${udp_missing} 未监听"
  if ! printf '%s\n' "$tcp_bound" | grep -Fxq "$V2RAY_API_PORT"; then
    issues="${issues:+${issues} | }API ${V2RAY_API_PORT} 未监听"
  fi

  if [ -z "$issues" ]; then
    echo -e "监听端口: ${C_GREEN}● 正常${C_RESET}"
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
def node_labels($type; $out):
  if ($type | startswith("vless")) then
    if $out == "landing" then {suffix:"vless转vless", display:"VLESS -> VLESS 中转"}
    else {suffix:"vless", display:"VLESS 直出"} end
  elif ($type | startswith("tuic")) then
    if $out == "landing" then {suffix:"tuic5转vless", display:"TUIC v5 -> VLESS 中转"}
    else {suffix:"tuic5", display:"TUIC v5 直出"} end
  else
    {suffix:(if $out == "landing" then "relay" else "node" end), display:$type}
  end;

def node_type_name($type; $out): node_labels($type; $out).display;

def node_auto_name($s; $n; $region):
  ($n.outbound_type // "direct") as $out |
  (if $region != "" then $region
   else ((first($s.landings[]? | select(.id == ($n.landing_id // ""))) | .display) // ""
         | split("：")[0]) end) as $landing_region |
  (($s.location_flag // "🌐") + ($s.location_name // "未知地区") + "-"
   + node_labels($n.type; $out).suffix
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

  info "正在预检落地节点 TCP 连通性 (${server}:${port})..."
  if test_tcp_connect "$server" "$port" 5; then
    ok "落地节点 TCP 连通性检测通过 (${server}:${port})。"
    return 0
  fi

  warn "无法连接到落地节点 ${server}:${port}（TCP 连接超时、被拒绝或防火墙未放行）。"
  confirm_or_cancel "是否仍然继续保存该落地节点？输入 y 继续: " n "已取消保存落地节点。" || return $?
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

node_type_name() {
  jq -nr --arg type "$1" --arg out "${2:-direct}" \
    "$JQ_NODE_LIB"'node_type_name($type; $out)'
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
  command -v flock   >/dev/null 2>&1 || missing+=(util-linux)

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
  local force="${1:-}"

  step "安装 / 检查 sing-box"

  ensure_singbox_user
  # 安装、面板升级和内核更新共用运行目录准备；配置目录由安装 / 面板升级另行准备。
  mkdir -p ${CORE_DATA_DIR} ${CORE_LOG_DIR}
  chown -R sing-box:sing-box ${CORE_DATA_DIR} ${CORE_LOG_DIR} 2>/dev/null || true
  chmod 755 ${CORE_DATA_DIR} ${CORE_LOG_DIR}
  remove_broken_singbox_bins

  if [ "$force" != "force" ] && singbox_bin_works; then
    ok "检测到 sing-box 已安装：$(sing-box version | head -n 1)"
  else
    info "正在安装 sing-box..."
    install_singbox_release
    singbox_bin_works || die "当前系统无法执行 sing-box，请检查 CPU 架构。"
    ok "sing-box 安装完成：$(sing-box version | head -n 1)"
  fi

  ensure_singbox_service
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$CERT_DIR"
  chown -R sing-box:sing-box "$CONFIG_DIR" 2>/dev/null || true
  chmod 755 "$CONFIG_DIR" "$CERT_DIR"
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
state_build() {
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
  chown sing-box:sing-box "$NEW_STATE" 2>/dev/null || true
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
  local tmp

  [ -f "$STATE_FILE" ] || { err "未找到状态文件：$STATE_FILE"; return 1; }

  tmp="$(mktemp "${STATE_FILE}.tmp.${WORK_TAG}.XXXXXX")" || return 1
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
  local uuid private_key public_key short_id tuic_pass server_ip
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
  IFS='|' read -r country_code flag loc <<<"$(detect_location "$server_ip" self "本机")"

  ok "公网 IP (${ip_version})：${server_ip}"
  ok "自动命名地区：${flag}${loc}"

  tmp="$(mktemp "${STATE_FILE}.tmp.${WORK_TAG}.XXXXXX")" || die "无法创建临时文件。"
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

add_landing_wizard() {
  need_state
  step "添加落地节点"

  local l_server l_port l_uuid l_public_key l_short_id l_sni flag loc l_display l_id
  local d_uuid d_pbk d_sid d_sni

  l_server="$(ask_landing_host "请输入落地节点 IP 或域名" "")"
  l_port="$(ask_port "请输入落地节点 VLESS 端口 (远端端口，1-65535)" "$VLESS_DIRECT_PORT")"

  check_landing_connectivity "$l_server" "$l_port"

  state_read '.uuid, .public_key, .short_id, .reality_sni' d_uuid d_pbk d_sid d_sni
  l_uuid="$(ask_text_default "请输入落地 VLESS UUID" "$d_uuid")"
  l_public_key="$(ask_text_default "请输入落地 Reality PublicKey" "$d_pbk")"
  l_short_id="$(ask_text_default "请输入落地 Reality ShortID" "$d_sid")"
  l_sni="$(ask_sni "请输入落地 Reality SNI" "$d_sni")"

  info "正在检测落地节点地区..."
  IFS='|' read -r _ flag loc <<<"$(detect_location "$l_server" "" "落地节点")"
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
    table($headers; $mins; $rows)
  ' "$STATE_FILE"

  return 0
}

# 修改落地池中第 idx（从 0 开始）个条目；若落地地区变化则同步更新引用该落地的节点名称
edit_landing() {
  local idx="$1"
  local l_id old_server old_port old_uuid old_pbk old_sid old_sni old_disp used
  local new_server new_port new_uuid new_pbk new_sid new_sni new_disp old_region new_region flag loc
  local rename_nodes=false

  # 一次 jq 取出全部字段；用 \x1f 分隔（非空白分隔符，空字段不会被吞掉）
  IFS=$'\x1f' read -r l_id old_server old_port old_uuid old_pbk old_sid old_sni old_disp used < <(
    jq -r --argjson i "$idx" '
      . as $s | $s.landings[$i] as $l
      | [ $l.id, $l.server, ($l.port | tostring), ($l.uuid // ""), ($l.public_key // ""),
          ($l.short_id // ""), ($l.sni // ""), ($l.display // ""),
          ([ $s.nodes[]? | select(.landing_id == $l.id) ] | length | tostring) ]
      | join("\u001f")' "$STATE_FILE"
  )

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
    IFS='|' read -r _ flag loc <<<"$(detect_location "$new_server" "" "落地节点")"
    new_disp="${flag}${loc}：${new_server}"
  else
    new_disp="$old_disp"
  fi
  if [ "$new_server" = "$old_server" ] && [ "$new_port" = "$old_port" ] \
      && [ "$new_uuid" = "$old_uuid" ] && [ "$new_pbk" = "$old_pbk" ] \
      && [ "$new_sid" = "$old_sid" ] && [ "$new_sni" = "$old_sni" ] \
      && [ "$new_disp" = "$old_disp" ]; then
    info "落地信息没有变化。"
    return "$CANCEL_RC"
  fi
  old_region="${old_disp%%：*}"
  new_region="${new_disp%%：*}"
  if [ "$new_region" != "$old_region" ]; then rename_nodes=true; fi

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
    --argjson rename_nodes "$rename_nodes" \
    "$JQ_NODE_LIB"'
    .landings[$i] |= (
      .server = $server | .port = $port | .uuid = $uuid |
      .public_key = $pbk | .short_id = $sid | .sni = $sni | .display = $disp
    ) |
    if $rename_nodes then
      reduce (
        .nodes | to_entries[] |
        select(.value.outbound_type == "landing" and .value.landing_id == $id) | .key
      ) as $ni (.;
        . as $s | .nodes[$ni].name = node_auto_name($s; $s.nodes[$ni]; "")
      )
    else . end
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
      | [ $l.id, $l.display, ([ $s.nodes[]? | select(.landing_id == $l.id) ] | length | tostring) ]
      | join("\u001f")' "$STATE_FILE"
  )

  if [ "$used" -gt 0 ]; then
    users="$(jq -r --arg id "$l_id" '.nodes[]? | select(.landing_id == $id) | "  - " + .name' "$STATE_FILE")"
    warn "落地 [${disp}] 正被以下 ${used} 个节点使用，无法删除："
    echo "$users" >&2
    warn "请先到「修改节点」把这些节点改为直出或换成其他落地，或直接删除这些节点。"
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

  if [ -z "$indices" ] || [ "$indices" = "0" ]; then return "$CANCEL_RC"; fi

  for idx in $indices; do
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

  if ! valid_index "$index" "$count"; then
    warn "序号输入错误。"
    return 1
  fi

  real_idx=$((10#$index - 1))
  # 一次 jq 取出该节点全部字段（\x1f 分隔，空字段不会被吞掉）
  IFS=$'\x1f' read -r type protocol name old_port old_tag outbound_type landing_id landing_display < <(
    jq -r --argjson i "$real_idx" '
      . as $s | $s.nodes[$i] as $n
      | ($n.outbound_type // "direct") as $out
      | [ $n.type,
          ($n.protocol // (if $n.type | startswith("tuic") then "udp" else "tcp" end)),
          $n.name, ($n.port | tostring), $n.tag, $out, ($n.landing_id // ""),
          (if $out == "landing"
           then ((first($s.landings[]? | select(.id == ($n.landing_id // ""))) | .display) // "(落地已丢失)")
           else "-" end) ]
      | join("\u001f")' "$STATE_FILE"
  )

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
          '.nodes[$i] |= (.type = $type | .tag = $tag | .name = $name | .outbound_type = "direct" | del(.landing_id))'
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
      n="$(sing-box generate uuid)" || return 1
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
      new="$(sing-box generate uuid)"
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
# 流量统计：使用本机 41453 gRPC 的 V2Ray StatsService。
# 查询只读 (reset=false)，统计在 sing-box 重启后归零。
# -------------------------
GRPCURL_COMMAND=""
ensure_grpcurl() {
  local arch asset base wd file sums expected actual
  if command -v grpcurl >/dev/null 2>&1; then
    GRPCURL_COMMAND="$(command -v grpcurl)"
    return 0
  fi
  if [ -x "$GRPCURL_YSQ_BIN" ]; then
    GRPCURL_COMMAND="$GRPCURL_YSQ_BIN"
    return 0
  fi
  arch="$(normalize_arch)"
  case "$arch" in
    amd64) arch="x86_64" ;;
    arm64) arch="arm64" ;;
  esac
  asset="grpcurl_${GRPCURL_VERSION}_linux_${arch}.tar.gz"
  base="https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}"
  wd="$(new_work_dir)"
  file="${wd}/${asset}"
  sums="${wd}/checksums.txt"
  info "首次查看流量：下载 grpcurl ${GRPCURL_VERSION}（仅用于读取本机 gRPC 统计）..."
  if ! curl -fL --connect-timeout 10 --retry 2 -o "$file" "${base}/${asset}"; then
    err "grpcurl 下载失败。可自行安装 grpcurl 后重新打开流量统计。"
    return 1
  fi
  if ! curl -fL --connect-timeout 10 --retry 2 -o "$sums" "${base}/grpcurl_${GRPCURL_VERSION}_checksums.txt"; then
    err "无法下载 grpcurl 官方 SHA256 校验文件，已拒绝安装。"
    return 1
  fi
  expected="$(awk -v f="$asset" '{n=$2; sub(/^\*/,"",n); sub(/^\.\//,"",n); if(n==f) {print $1; exit}}' "$sums")"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if ! [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || [ "${expected,,}" != "${actual,,}" ]; then
    err "grpcurl SHA256 校验失败，已拒绝安装。"
    return 1
  fi
  if ! tar -xzf "$file" -C "$wd" grpcurl || [ ! -f "$wd/grpcurl" ]; then
    err "grpcurl 解压失败。"
    return 1
  fi
  mkdir -p "$(dirname "$GRPCURL_YSQ_BIN")"
  install -m 755 "$wd/grpcurl" "$GRPCURL_YSQ_BIN" || return 1
  GRPCURL_COMMAND="$GRPCURL_YSQ_BIN"
  ok "grpcurl 安装完成，SHA256 已校验。"
}

# sing-box 的注册服务名与原 proto package 名不同；此处使用兼容的线格式和真正的服务名。
write_v2ray_stats_proto() {
  cat > "$1" <<'PROTO'
syntax = "proto3";
package v2ray.core.app.stats.command;
message Stat { string name = 1; int64 value = 2; }
message QueryStatsRequest { string pattern = 1; bool reset = 2; repeated string patterns = 3; bool regexp = 4; }
message QueryStatsResponse { repeated Stat stat = 1; }
service StatsService { rpc QueryStats(QueryStatsRequest) returns (QueryStatsResponse); }
PROTO
}

show_traffic_stats() {
  need_state
  step "流量统计（V2Ray API ${V2RAY_API_PORT}）"
  if ! is_singbox_running; then
    warn "sing-box 没有运行，无法获取流量。"
    return 1
  fi
  ensure_grpcurl || return 1
  local wd proto result errors
  wd="$(new_work_dir)"
  proto="${wd}/stats.proto"
  result="${wd}/response.json"
  errors="${wd}/error.txt"
  write_v2ray_stats_proto "$proto"

  # 先用实际安装的 grpcurl 在本地解析 proto；此动作不连接 API，也不触碰计数器。
  # 之前的 -proto 绝对路径错误在此阶段即可直接发现，而不是被误报为编译问题。
  if ! "$GRPCURL_COMMAND" -import-path "$wd" -proto stats.proto list > "$wd/services.txt" 2> "$errors"; then
    err "grpcurl 无法解析流量统计 proto；尚未向 sing-box 发起请求。"
    sed -n '1,8p' "$errors" >&2
    return 1
  fi
  if ! grep -Fxq 'v2ray.core.app.stats.command.StatsService' "$wd/services.txt"; then
    err "本地 proto 中没有预期的 V2Ray StatsService。"
    sed -n '1,8p' "$wd/services.txt" >&2
    return 1
  fi

  # grpcurl 的 -proto 必须相对于 -import-path，不能直接使用无导入根目录的绝对路径。
  # 此处使用每次执行生成的临时目录作为导入根目录，保证从任何 cwd 启动 ysq 都能解析。
  if ! "$GRPCURL_COMMAND" -plaintext -max-time 5 -import-path "$wd" -proto stats.proto -d '{"reset":false}' \
    "127.0.0.1:${V2RAY_API_PORT}" \
    'v2ray.core.app.stats.command.StatsService/QueryStats' > "$result" 2> "$errors"; then
    err "无法读取 127.0.0.1:${V2RAY_API_PORT} 的 V2Ray API 统计。"
    sed -n '1,8p' "$errors" >&2
    if grep -Eqi 'connection refused|connect: connection|deadline exceeded|no route to host' "$errors"; then
      warn "API 41453 无法连接。请检查 ysq 面板常驻端口指示，以及 sing-box 是否已启动。"
    elif grep -Eqi 'unknown service|unimplemented' "$errors"; then
      warn "服务名不匹配或服务器未启用统计服务。请检查 sing-box 的 with_v2ray_api 编译标签和配置。"
    elif grep -Eqi 'proto source|import.path|proto:' "$errors"; then
      warn "grpcurl 解析本地 proto 文件失败；请确认正在运行 v${YSQ_VERSION} 或更新的修复版脚本。"
    else
      warn "请检查 API 端口、sing-box 编译标签（with_v2ray_api）及 sing-box 日志。"
    fi
    return 1
  fi
  if ! jq -e '.stat == null or (.stat|type) == "array"' "$result" >/dev/null 2>&1; then
    err "gRPC 返回了非预期数据。"
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

block_add() {
  need_state

  local raw_input item domain domains_json
  local -a new_domains=()

  read_line "请输入要屏蔽的域名 (多个用空格或逗号隔开，输入 0 返回): " raw_input
  raw_input="$(split_input "$raw_input")"
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

  for idx in $raw_indices; do
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
  local current_ver latest_ver bin wd rc new_ver

  if command -v sing-box >/dev/null 2>&1; then
    current_ver="$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}' || true)"
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

  # 先备份旧二进制，安装失败时恢复，避免把服务搞成“没有可执行文件”
  bin="$(command -v sing-box 2>/dev/null || true)"
  wd="$(new_work_dir)"
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    cp -p "$bin" "$wd/sing-box.bak"
  fi

  service_stop

  # 子 shell 里运行，保证里面的 die 不会直接结束整个操作
  set +e
  ( set -e; SINGBOX_VERSION="$latest_ver" install_singbox force )
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
    warn "当前版本 ${new_ver:-未知} 与 Release 最新版 ${latest_ver} 不一致。"
  fi

  service_restart || return 1
  ok "更新并重启完成。"
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
  local f="$1" rc=0

  sing-box check -c "$f" && return 0 || rc=$?
  [ "$rc" -eq 137 ] || return 1

  warn "sing-box check 被系统杀掉（137，疑似内存不足），1 秒后重试一次..."
  sleep 1
  rc=0
  sing-box check -c "$f" && return 0 || rc=$?
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

  [ -f "$STATE_FILE" ] || { err "未找到状态文件：$STATE_FILE"; return 1; }
  # 若旧 VLESS 节点正好使用了 API 预留的 TCP 端口，应先调整该节点，而非生成必然抢占端口的配置。
  if jq -e --argjson p "$V2RAY_API_PORT" \
      '.nodes[]? | select(.type | startswith("vless")) | select((.port|tonumber) == $p)' \
      "$STATE_FILE" >/dev/null 2>&1; then
    err "旧 VLESS 节点使用了 TCP ${V2RAY_API_PORT}，与新 V2Ray API 冲突。请先将这个节点改到其他端口。"
    return 1
  fi
  info "生成 sing-box 配置..."
  mkdir -p "$CORE_LOG_DIR"
  touch "$LOG_FILE"
  chmod 640 "$LOG_FILE"
  # Legacy OpenRC stdout logs may have been created by root. The new core file
  # output must be writable by the service account, including on first adoption.
  if id sing-box >/dev/null 2>&1; then
    chown sing-box:sing-box "$CORE_LOG_DIR" "$LOG_FILE"
  fi

  tmp="$(mktemp "${CONFIG_FILE}.tmp.${WORK_TAG}.XXXXXX")" || { err "无法创建临时配置文件。"; return 1; }

  if ! jq --arg api_listen "127.0.0.1:${V2RAY_API_PORT}" --arg cert_file "$CERT_FILE" --arg key_file "$KEY_FILE" --arg log_file "$LOG_FILE" '
    (.users |= map(select(.enabled != false))) as $s |

    def landing($n):
      first($s.landings[]? | select(.id == ($n.landing_id // "")))
      // error("节点 [" + ($n.name // $n.tag) + "] 引用的落地节点不存在 (landing_id=" + ($n.landing_id // "") + ")");

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
        "level": "info",
        "output": $log_file,
        "timestamp": true
      },
      "experimental": {
        "v2ray_api": {
          "listen": $api_listen,
          "stats": {
            "enabled": true,
            "users": [$s.users[] | (.stats_key // .name)],
            "inbounds": [$s.nodes[]? | .tag],
            "outbounds": (["direct"] + ([$s.nodes[]? | select(.outbound_type == "landing") | "out-" + .landing_id] | unique))
          }
        }
      },
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
          (
            [$s.nodes[]? | select(.outbound_type == "landing")]
            | group_by(.landing_id)
            | map({
              "inbound": map(.tag),
              "action": "route",
              "outbound": ("out-" + .[0].landing_id)
            })
          )
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
  [ -f "$STATE_FILE" ] || return 1
  if [ -n "$selected_user" ] && ! jq -e --arg name "$selected_user" \
    '[.users[]? | select(.enabled != false and .name == $name)] | length == 1' "$STATE_FILE" >/dev/null 2>&1; then
    err "所选用户不存在或已停用：${selected_user}"
    return 1
  fi

  local server_ip reality_sni tuic_sni public_key private_key short_id ip_version server_ip_display
  local type tag name port protocol outbound_type landing_disp landing_port user uuid tuic_pass encoded_name link
  local default_name default_uuid default_tuic_pass

  state_read '.server_ip, .reality_sni, .tuic_sni, .public_key, .private_key, .short_id, (.ip_version // "ipv4"), ([.users[] | select(.enabled != false)][0].name), ([.users[] | select(.enabled != false)][0].uuid), ([.users[] | select(.enabled != false)][0].tuic_pass)' \
    server_ip reality_sni tuic_sni public_key private_key short_id ip_version default_name default_uuid default_tuic_pass
  if [ -n "$selected_user" ]; then
    IFS=$'\x1f' read -r default_name default_uuid default_tuic_pass <<< "$(
      jq -r --arg name "$selected_user" \
        '.users[] | select(.enabled != false and .name == $name) | [.name, .uuid, .tuic_pass] | join("\u001f")' "$STATE_FILE"
    )"
    user_label="用户"
  fi
  if [ "$ip_version" = "ipv6" ]; then
    server_ip_display="[${server_ip}]"
  else
    server_ip_display="$server_ip"
  fi

  cat > "$out_file" <<INFO
==============================
ysq sing-box 节点信息（按用户）
==============================
服务器地址: ${server_ip} (${ip_version})
${user_label}: ${default_name}
UUID: ${default_uuid}
REALITY PrivateKey: ${private_key}
REALITY PublicKey: ${public_key}
ShortID: ${short_id}
TUIC Password: ${default_tuic_pass}
V2Ray API: 127.0.0.1:${V2RAY_API_PORT} (仅本机)
配置文件: ${CONFIG_FILE}
状态文件: ${STATE_FILE}
节点信息: ${INFO_FILE}
YAML配置: ${YAML_FILE}

INFO

  if [ "$(jq '.nodes | length' "$STATE_FILE")" -eq 0 ]; then
    printf '当前还没有节点。输入 ysq 后在面板中添加节点。\n' >> "$out_file"
    chmod 600 "$out_file"
    return 0
  fi

  while IFS=$'\t' read -r type tag name port protocol outbound_type landing_disp landing_port user uuid tuic_pass encoded_name; do
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
      echo "类型: $(node_type_name "$type" "$outbound_type")"
      echo "传输协议: ${protocol^^} / 端口: ${port}"
      if [ "$outbound_type" = "landing" ]; then
        echo "落地出口: ${landing_disp} (端口: ${landing_port})"
      fi
      echo "UUID: ${uuid}"
      if [[ "$type" == tuic* ]]; then echo "TUIC Password: ${tuic_pass}"; fi
      echo "$link"
      echo
    } >> "$out_file"
  done <<< "$(jq -r --arg selected "$selected_user" '
    . as $s |
    $s.nodes[]? as $n |
    (first($s.landings[]? | select(.id == ($n.landing_id // ""))) // {}) as $l |
    ($s.users[] | select(.enabled != false) | select($selected == "" or .name == $selected)) as $u |
    [ $n.type, $n.tag, $n.name, ($n.port | tostring), ($n.protocol // "tcp"),
      ($n.outbound_type // "direct"), ($l.display // "-"), (($l.port // "-") | tostring),
      $u.name, $u.uuid, $u.tuic_pass, (($n.name + "-" + $u.name) | @uri) ] | @tsv
  ' "$STATE_FILE")"

  chmod 600 "$out_file"
  return 0
}

render_yaml() {
  # 可选参数：用户名、输出路径。用于按用户查看，不改变磁盘上的全量 Clash 文件。
  local selected_user="${1:-}" out_file="${2:-$YAML_FILE}"
  [ -f "$STATE_FILE" ] || return 1
  if [ -n "$selected_user" ] && ! jq -e --arg name "$selected_user" \
    '[.users[]? | select(.enabled != false and .name == $name)] | length == 1' "$STATE_FILE" >/dev/null 2>&1; then
    err "所选用户不存在或已停用：${selected_user}"
    return 1
  fi

  local public_key short_id reality_sni tuic_sni server_ip
  local type name port user uuid tuic_pass proxy_name
  local -a names=()
  local q_server q_uuid q_pass q_rsni q_tsni q_pbk q_sid

  state_read '.public_key, .short_id, .reality_sni, .tuic_sni, .server_ip' \
    public_key short_id reality_sni tuic_sni server_ip

  q_server="$(yaml_quote "$server_ip")"
  q_rsni="$(yaml_quote "$reality_sni")"
  q_tsni="$(yaml_quote "$tuic_sni")"
  q_pbk="$(yaml_quote "$public_key")"
  q_sid="$(yaml_quote "$short_id")"

  cat > "$out_file" <<YAML
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
  while IFS=$'\t' read -r type name port user uuid tuic_pass proxy_name; do
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
      } >> "$out_file"
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
      } >> "$out_file"
    fi
  done <<< "$(jq -r --arg selected "$selected_user" '
    . as $s |
    $s.nodes[]? as $n |
    ($s.users | map(select(.enabled != false)) | to_entries[] | select($selected == "" or .value.name == $selected)) as $u |
    [$n.type, $n.name, ($n.port | tostring), $u.value.name, $u.value.uuid, $u.value.tuic_pass,
     (if $selected != "" or $u.key == 0 then $n.name else $n.name + "-" + $u.value.name end)] | @tsv
  ' "$STATE_FILE")"

  if [ "${#names[@]}" -eq 0 ]; then
    sed -i 's/^proxies:$/proxies: []/' "$out_file"
  fi
  cat >> "$out_file" <<YAML

proxy-groups:
  - name: PROXY
    type: select
    proxies:
YAML

  for name in "${names[@]}"; do
    printf '      - %s\n' "$(yaml_quote "$name")" >> "$out_file"
  done

  cat >> "$out_file" <<YAML
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
YAML

  chmod 600 "$out_file"
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
    bak_conf="$(mktemp "${CONFIG_FILE}.tmp.${WORK_TAG}.XXXXXX")" || { err "无法创建备份文件。"; return 1; }
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

  jq -r "$JQ_TABLE_LIB$JQ_NODE_LIB"'
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
        node_type_name($n.type; $out),
        (if $out == "landing" then
          ((first($s.landings[]? | select(.id == ($n.landing_id // ""))) | .display) // "(落地已丢失)")
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

  local lines=100 out=""

  if [ -s "$LOG_FILE" ]; then
    tail -n "$lines" "$LOG_FILE"
  else
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
      fi
      ;;
  esac

  echo
  fi
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

# 删除 sing-box。keep=1 时只保留状态文件（UUID / 私钥 / 节点 / 落地 / 屏蔽列表）
do_uninstall() {
  local keep="${1:-0}" p

  flush_agent_traffic
  agent_service_disable
  service_stop
  service_disable

  rm -f ${CORE_BIN_FILE}
  rm -f "$GRPCURL_YSQ_BIN"
  rm -f ${CORE_SYSTEMD_FILE}
  rm -f ${CORE_OPENRC_FILE}
  rm -f ${CORE_PID_FILE}
  remove_log_trim
  rm -rf ${CORE_DATA_DIR} ${CORE_LOG_DIR}
  rm -f "$INFO_FILE" "$YAML_FILE" "$PANEL_FILE"
  rm -f "$AGENT_FILE" "$AGENT_SYSTEMD_FILE" "$AGENT_OPENRC_FILE" "$AGENT_PID_FILE"

  if [ "$keep" = "1" ]; then
    # 配置目录里除状态文件外全部删除（config.json / 证书 / 临时文件）
    for p in "$CONFIG_DIR"/* "$CONFIG_DIR"/.[!.]*; do
      [ -e "$p" ] || continue
      [ "$p" = "$STATE_FILE" ] && continue
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
    case "$1" in
      agent_join_wizard|agent_status_wizard|agent_sync_wizard|agent_detach_wizard) ;;
      *) acquire_config_lock ;;
    esac
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
  ( acquire_config_lock; ensure_state_defaults ) || die "状态文件规范化失败，请检查 ${STATE_FILE}。"

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
    echo "10) 屏蔽指定网站管理"
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
      warn "已恢复安装前的状态文件（配置文件请在 ysq 面板里选「重启 → 重新渲染后重启」重新生成）。"
    fi
    die "sing-box 启动失败，请根据上方日志排查。"
  fi

  rm -f "$prev"
  if save_self; then
    install_panel_wrapper
    PANEL_READY=1
  fi
  restore_agent_if_configured
  print_summary
}

# -------------------------
# 可选中控：单机模式不依赖 Python；只有连接中控时安装 Agent。
# -------------------------
acquire_config_lock() {
  local inherited="${YSQ_CONFIG_LOCK_FD:-}"
  if [ "$inherited" = "9" ] && [ "${YSQ_CONFIG_LOCK_PATH:-}" = "$CONFIG_LOCK_FILE" ]; then
    if flock -n 9 2>/dev/null; then
      return 0
    fi
  fi
  if ! command -v flock >/dev/null 2>&1; then
    [ -z "$YSQ_TEST_ROOT" ] || { err "隔离测试需要 flock。"; return 1; }
    need_root
    info "安装跨进程配置锁依赖 util-linux..." >&2
    pkg_install util-linux >&2 || return 1
  fi
  mkdir -p "$(dirname "$CONFIG_LOCK_FILE")"
  exec 9>>"$CONFIG_LOCK_FILE"
  chmod 600 "$CONFIG_LOCK_FILE"
  if ! flock -x -w "${YSQ_LOCK_TIMEOUT:-30}" 9; then
    err "另一项面板操作正在修改配置，请稍后重试。"
    return 1
  fi
  export YSQ_CONFIG_LOCK_FD=9
  export YSQ_CONFIG_LOCK_PATH="$CONFIG_LOCK_FILE"
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
  [ -s "$AGENT_CONFIG_FILE" ] && [ -f "$AGENT_FILE" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  if ! python3 -c '
import subprocess, sys
try:
    result = subprocess.run([sys.executable, sys.argv[1], "--config", sys.argv[2], "sample-once"],
                            timeout=8, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            close_fds=True)
    raise SystemExit(result.returncode)
except (OSError, subprocess.TimeoutExpired):
    raise SystemExit(1)
' "$AGENT_FILE" "$AGENT_CONFIG_FILE"; then
    warn "停止前流量采样未成功，继续服务操作；最后一个采样间隔可能存在统计缺口。"
  fi
  return 0
}

write_embedded_agent() {
  cat <<'YSQ_AGENT_PY'
# BEGIN_EMBEDDED_AGENT
#!/usr/bin/env python3
"""YSQ node agent. Python 3.9+, standard library only.

Configuration and the SQLite ledger are private local files.  The collector never
resets sing-box counters.  HTTPS delivery is at-least-once; the center commits a
batch before acknowledging its persistent (node, ledger epoch, sequence) key.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import datetime
import hashlib
import http.client
import ipaddress
import json
import os
import pathlib
import re
import secrets
import signal
import shutil
import socket
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

VERSION = "2026.10.23.3"
PROTOCOL = 1
SAMPLE_SECONDS = 10
SYNC_SECONDS = 15
WAIT_SECONDS = 20
BATCH_SECONDS = SYNC_SECONDS
MAX_BODY = 2 * 1024 * 1024
MAX_SQLITE_INT = (1 << 63) - 1
USER_ID_RE = re.compile(r"u_[0-9a-f]{32}\Z")
NODE_ID_RE = re.compile(r"n_[0-9a-f]{32}\Z")
NAME_RE = re.compile(r"[A-Za-z0-9]{1,32}\Z")
PASSWORD_RE = re.compile(r"[A-Za-z0-9_-]{6,128}\Z")
STAT_RE = re.compile(r"user>>>([^>]+)>>>traffic>>>(uplink|downlink)\Z")
PROTO = '''syntax = "proto3";
package v2ray.core.app.stats.command;
message Stat { string name = 1; int64 value = 2; }
message QueryStatsRequest { string pattern = 1; bool reset = 2; repeated string patterns = 3; bool regexp = 4; }
message QueryStatsResponse { repeated Stat stat = 1; }
service StatsService { rpc QueryStats(QueryStatsRequest) returns (QueryStatsResponse); }
'''


def system_path(path):
    root = os.environ.get("YSQ_TEST_ROOT", "")
    return str(pathlib.Path(root) / path.lstrip("/")) if root else path


DEFAULT_CONFIG = system_path("/etc/ysq-agent/config.json")
DEFAULT_DB = system_path("/var/lib/ysq-agent/agent.db")
DEFAULT_SCRIPT = system_path("/root/install-singbox-ysq.sh")
DEFAULT_STATE = system_path("/etc/sing-box/ysq-state.db")
DEFAULT_GRPCURL = system_path("/usr/local/libexec/ysq-grpcurl")


class AgentError(Exception):
    pass


class CollectorError(AgentError):
    pass


class LockBusy(AgentError):
    pass


class TransportError(AgentError):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def integer(value, label, minimum=0, maximum=MAX_SQLITE_INT):
    if type(value) is not int or value < minimum or value > maximum:
        raise AgentError("Invalid integer: " + label)
    return value


def private_parent(path):
    parent = pathlib.Path(path).parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if parent.is_symlink():
        raise AgentError("Private data directory must not be a symlink")
    return parent


def atomic_json(path, value):
    parent = private_parent(path)
    fd, temp = tempfile.mkstemp(prefix=".ysq-", suffix=".tmp", dir=str(parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(canonical(value) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        directory = os.open(str(parent), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def read_json(path, limit=MAX_BODY * 4):
    with open(path, "rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise AgentError("Local JSON file is too large")
    result = json.loads(data)
    if not isinstance(result, dict):
        raise AgentError("Expected a JSON object")
    return result


@contextlib.contextmanager
def file_lock(path, timeout=1.0):
    private_parent(path)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    os.fchmod(fd, 0o600)
    deadline = time.monotonic() + timeout
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise LockBusy("Another agent operation holds the local lock")
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)


def redact(message, config=None):
    text = str(message)
    cfg = config or {}
    secret_values = [cfg.get("node_token", "")]
    pending = cfg.get("registration_payload", {})
    secret_values.append(pending.get("join_code", ""))
    users = pending.get("users", []) + cfg.get("_redact_users", [])
    if cfg.get("state_path"):
        try:
            state = read_json(cfg["state_path"])
            users = users + state.get("users", [])
            secret_values.extend(state.get(key, "") for key in ("uuid", "private_key", "short_id", "tuic_pass"))
            for landing in state.get("landings", []):
                if isinstance(landing, dict):
                    secret_values.extend(landing.get(key, "") for key in
                                         ("uuid", "password", "private_key", "short_id"))
        except (OSError, ValueError, AgentError):
            pass
    for user in users:
        if isinstance(user, dict):
            secret_values.extend([user.get("uuid", ""), user.get("tuic_pass", "")])
    for value in sorted(set(str(v) for v in secret_values if v), key=len, reverse=True):
        text = text.replace(value, "[redacted]")
    text = re.sub(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", "[uuid]", text)
    text = re.sub(r"(?i)bearer\s+\S+", "Bearer [redacted]", text)
    text = " ".join(text.split())
    return text[-900:]


def log(message, config=None):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + " " + redact(message, config),
          file=sys.stderr, flush=True)


def validate_origin(value, allow_loopback_http=False):
    if not isinstance(value, str) or any(c.isspace() for c in value):
        raise AgentError("Center URL must be an HTTPS origin")
    parsed = urllib.parse.urlsplit(value)
    try:
        parsed.port
    except ValueError as exc:
        raise AgentError("Invalid center port") from exc
    if (not parsed.hostname or parsed.username is not None or parsed.password is not None
            or parsed.query or parsed.fragment or parsed.path not in ("", "/")):
        raise AgentError("Use only the center origin, for example https://panel.eulmo.com")
    if parsed.scheme != "https":
        loopback = parsed.hostname.lower() == "localhost"
        try:
            loopback = loopback or ipaddress.ip_address(parsed.hostname).is_loopback
        except ValueError:
            pass
        if not (allow_loopback_http and parsed.scheme == "http" and loopback):
            raise AgentError("Production connections require HTTPS with certificate verification")
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "Agent refuses HTTP redirects", headers, fp)


class Transport:
    def __init__(self, origin, token=None, allow_loopback_http=False, timeout=12):
        self.origin = validate_origin(origin, allow_loopback_http)
        self.token = token
        self.timeout = timeout
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=ssl.create_default_context()), NoRedirect())

    def post(self, path, body, authenticated=True):
        if path not in ("/api/agent/register", "/api/agent/sync", "/api/agent/detach", "/api/agent/wait", "/api/agent/activity"):
            raise AgentError("Unsupported agent endpoint")
        data = canonical(body).encode("utf-8")
        if len(data) > MAX_BODY:
            raise AgentError("Agent request exceeds 2 MiB")
        headers = {"Content-Type": "application/json", "Accept": "application/json",
                   "User-Agent": "ysq-agent/" + VERSION}
        if authenticated:
            if not self.token:
                raise AgentError("No node credential is configured")
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(self.origin + path, data=data, headers=headers, method="POST")
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                data = response.read(MAX_BODY + 1)
        except urllib.error.HTTPError as exc:
            if 300 <= exc.code < 400:
                raise TransportError("Center redirected the request; redirects are refused", exc.code) from exc
            try:
                detail = json.loads(exc.read(4096)).get("error", "Request rejected")
            except (ValueError, AttributeError):
                detail = "Request rejected"
            raise TransportError("Center HTTP %d: %s" % (exc.code, detail), exc.code) from exc
        except (urllib.error.URLError, http.client.HTTPException, TimeoutError, OSError) as exc:
            raise TransportError("HTTPS request failed: " + str(exc)) from exc
        if len(data) > MAX_BODY:
            raise TransportError("Center response exceeds 2 MiB")
        try:
            result = json.loads(data)
        except ValueError as exc:
            raise TransportError("Center did not return valid JSON") from exc
        if not isinstance(result, dict) or result.get("protocol") != PROTOCOL:
            raise TransportError("Unsupported center response protocol")
        return result


def run_process(args, timeout, config=None, termination_grace=5):
    """Run a fixed local command; timeout also terminates all of its children."""
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                   start_new_session=True, close_fds=True)
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=termination_grace)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=1)
            # A shell can exit before a descendant; finish cleaning its group.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            raise AgentError("Local helper timed out; its process group was terminated; "
                             "configuration must be checked on the next sync") from exc
        out.seek(0)
        output = out.read(MAX_BODY + 1)
        err.seek(0, os.SEEK_END)
        size = err.tell()
        err.seek(max(0, size - 8192))
        errors = err.read().decode("utf-8", "replace")
    if process.returncode != 0:
        raise AgentError("Local command failed (%d): %s" % (process.returncode, redact(errors, config)))
    if len(output) > MAX_BODY:
        raise AgentError("Local helper output exceeds 2 MiB")
    return output


def helper(config, action, extra=(), timeout=120):
    if action not in ("agent-inventory", "agent-apply", "agent-detach"):
        raise AgentError("Unsupported local helper action")
    script = config.get("script_path", DEFAULT_SCRIPT)
    if not os.path.isabs(script) or not os.path.isfile(script):
        raise AgentError("Installer helper path is missing or is not absolute")
    return run_process(["bash", script, action] + list(extra), timeout, config)


def validated_users(users, snapshots=False):
    if not isinstance(users, list) or len(users) > 20000:
        raise AgentError("Invalid user list")
    names, ids, credentials, result = set(), set(), set(), []
    for user in users:
        if not isinstance(user, dict):
            raise AgentError("Invalid user record")
        name, credential, password = user.get("name"), user.get("uuid"), user.get("tuic_pass")
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            raise AgentError("Invalid user name")
        if not isinstance(credential, str):
            raise AgentError("Invalid user UUID")
        try:
            normalized = str(uuid.UUID(credential))
        except (ValueError, AttributeError) as exc:
            raise AgentError("Invalid user UUID") from exc
        if credential.lower() != normalized:
            raise AgentError("User UUID must use the canonical UUID format")
        if not isinstance(password, str) or not PASSWORD_RE.fullmatch(password):
            raise AgentError("Invalid TUIC credential")
        if name in names or normalized in credentials:
            raise AgentError("Duplicate name or UUID in node users")
        names.add(name)
        credentials.add(normalized)
        item = {"name": name, "uuid": normalized, "tuic_pass": password}
        if snapshots:
            identity = user.get("id")
            if not isinstance(identity, str) or not USER_ID_RE.fullmatch(identity) or identity in ids:
                raise AgentError("Invalid or duplicate global user ID")
            if type(user.get("enabled")) is not bool:
                raise AgentError("User enabled flag must be a boolean")
            ids.add(identity)
            item.update(id=identity, enabled=user["enabled"])
        result.append(item)
    return result


def fingerprint(users):
    normalized = validated_users(users)
    normalized.sort(key=lambda item: (item["name"], item["uuid"]))
    return hashlib.sha256(canonical(normalized).encode("utf-8")).hexdigest()


class Ledger:
    def __init__(self, path):
        self.path = str(path)
        private_parent(self.path)
        if os.path.islink(self.path):
            raise AgentError("Ledger must not be a symlink")
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            os.fchmod(fd, 0o600)
        finally:
            os.close(fd)
        with self.connect() as db:
            db.executescript('''
              CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS aliases (
                stats_key TEXT PRIMARY KEY, user_id TEXT NOT NULL, baseline_required INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS baselines (
                stats_key TEXT PRIMARY KEY, core_epoch TEXT NOT NULL,
                up INTEGER NOT NULL, down INTEGER NOT NULL, ts INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS usage (
                user_id TEXT PRIMARY KEY, up INTEGER NOT NULL CHECK(typeof(up)='integer' AND up>=0),
                down INTEGER NOT NULL CHECK(typeof(down)='integer' AND down>=0), last_at INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS pending_usage (
                user_id TEXT NOT NULL, ts INTEGER NOT NULL,
                up INTEGER NOT NULL CHECK(typeof(up)='integer' AND up>=0),
                down INTEGER NOT NULL CHECK(typeof(down)='integer' AND down>=0),
                PRIMARY KEY(user_id, ts));
              CREATE TABLE IF NOT EXISTS outbox (
                epoch TEXT NOT NULL, seq INTEGER NOT NULL, payload TEXT NOT NULL, created_at INTEGER NOT NULL,
                PRIMARY KEY(epoch, seq));
            ''')
            db.execute("INSERT OR IGNORE INTO meta VALUES ('epoch', ?)", (canonical(str(uuid.uuid4())),))
            db.execute("INSERT OR IGNORE INTO meta VALUES ('next_seq', '1')")
            db.execute("INSERT OR IGNORE INTO meta VALUES ('applied_revision', '0')")
            db.execute("INSERT OR IGNORE INTO meta VALUES ('last_packaged_at', '0')")
        os.chmod(self.path, 0o600)

    def connect(self):
        return database_connection(self.path)

    @staticmethod
    def get(db, key, default=None):
        row = db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else default

    @staticmethod
    def put(db, key, value):
        db.execute("INSERT INTO meta(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   (key, canonical(value)))

    def meta(self, key, default=None):
        with self.connect() as db:
            return self.get(db, key, default)

    def set_meta(self, **values):
        with self.connect() as db:
            for key, value in values.items():
                self.put(db, key, value)

    def remember(self, entries):
        with self.connect() as db:
            for stats_key, user_id, baseline_required in entries:
                old = db.execute("SELECT user_id FROM aliases WHERE stats_key=?", (stats_key,)).fetchone()
                if old and old[0] != user_id:
                    raise AgentError("A statistics alias belongs to another user; manual reconciliation is required")
                db.execute("INSERT OR IGNORE INTO aliases VALUES (?,?,?)",
                           (stats_key, user_id, int(baseline_required)))

    def aliases(self):
        with self.connect() as db:
            return [dict(row) for row in db.execute("SELECT * FROM aliases")]

    def record(self, core_epoch, counters, sampled_at):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            rows = db.execute("SELECT * FROM aliases").fetchall()
            added_up = added_down = 0
            for alias in rows:
                key = alias["stats_key"]
                counter = counters.get(key, {})
                old = db.execute("SELECT * FROM baselines WHERE stats_key=?", (key,)).fetchone()
                up, down = counter.get("uplink", 0), counter.get("downlink", 0)
                integer(up, "upload counter")
                integer(down, "download counter")
                if old and old["core_epoch"] == core_epoch:
                    if up < old["up"] or down < old["down"]:
                        raise CollectorError("Counter disappeared or moved backwards without a core restart; "
                                             "baseline preserved; check other reset=true collectors")
                    delta_up, delta_down = up - old["up"], down - old["down"]
                elif old:
                    delta_up, delta_down = up, down
                elif alias["baseline_required"]:
                    delta_up, delta_down = 0, 0
                else:
                    delta_up, delta_down = up, down
                db.execute("INSERT INTO baselines VALUES (?,?,?,?,?) ON CONFLICT(stats_key) DO UPDATE SET "
                           "core_epoch=excluded.core_epoch,up=excluded.up,down=excluded.down,ts=excluded.ts",
                           (key, core_epoch, up, down, sampled_at))
                if delta_up or delta_down:
                    db.execute("INSERT INTO usage VALUES (?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET "
                               "up=usage.up+excluded.up,down=usage.down+excluded.down,last_at=excluded.last_at",
                               (alias["user_id"], delta_up, delta_down, sampled_at))
                    bucket = sampled_at // BATCH_SECONDS * BATCH_SECONDS
                    db.execute("INSERT INTO pending_usage VALUES (?,?,?,?) ON CONFLICT(user_id,ts) DO UPDATE SET "
                               "up=pending_usage.up+excluded.up,down=pending_usage.down+excluded.down",
                               (alias["user_id"], bucket, delta_up, delta_down))
                    added_up += delta_up
                    added_down += delta_down
            self.put(db, "last_sample_at", sampled_at)
            self.put(db, "collector_error", "")
            self.put(db, "core_epoch", core_epoch)
            self.put(db, "service_running", True)
        return {"sampled_at": sampled_at, "up": added_up, "down": added_down}

    def package(self, now=None, force=False):
        now = int(time.time()) if now is None else int(now)
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if not force and now - self.get(db, "last_packaged_at", 0) < BATCH_SECONDS:
                return 0
            count = 0
            # Bound each batch and each packaging transaction; older rows remain durable.
            for unused in range(16):
                rows = [dict(row) for row in db.execute(
                    "SELECT user_id,ts,up,down FROM pending_usage ORDER BY ts,user_id LIMIT 1000")]
                if not rows:
                    break
                epoch = self.get(db, "epoch")
                seq = integer(self.get(db, "next_seq"), "batch sequence", 1)
                batch = {"epoch": epoch, "seq": seq, "rows": rows}
                db.execute("INSERT INTO outbox VALUES (?,?,?,?)", (epoch, seq, canonical(batch), now))
                db.executemany("DELETE FROM pending_usage WHERE user_id=? AND ts=?",
                               [(row["user_id"], row["ts"]) for row in rows])
                self.put(db, "next_seq", seq + 1)
                count += 1
            self.put(db, "last_packaged_at", now)
            return count

    def batches(self):
        with self.connect() as db:
            result, size = [], 0
            for row in db.execute("SELECT payload FROM outbox ORDER BY created_at,seq LIMIT 16"):
                payload = row[0]
                size += len(payload.encode("utf-8")) + 1
                if size > MAX_BODY - 16384:
                    break
                result.append(json.loads(payload))
            return result

    def acknowledge(self, acknowledgements, sent):
        if not isinstance(acknowledgements, list):
            raise TransportError("Center acknowledgement is not a list")
        allowed = {(batch["epoch"], batch["seq"]) for batch in sent}
        accepted = set()
        for ack in acknowledgements:
            if not isinstance(ack, dict) or not isinstance(ack.get("epoch"), str):
                raise TransportError("Invalid center acknowledgement")
            key = (ack["epoch"], integer(ack.get("seq"), "ack sequence", 1))
            if key not in allowed:
                raise TransportError("Center acknowledged a batch that was not sent")
            accepted.add(key)
        with self.connect() as db:
            db.executemany("DELETE FROM outbox WHERE epoch=? AND seq=?", list(accepted))
        return len(accepted)

    def summary(self):
        with self.connect() as db:
            usage = [dict(row) for row in db.execute("SELECT user_id,up,down,last_at FROM usage ORDER BY user_id")]
            return {"ledger_epoch": self.get(db, "epoch"), "applied_revision": self.get(db, "applied_revision", 0),
                    "last_sample_at": self.get(db, "last_sample_at"),
                    "last_sync_at": self.get(db, "last_sync_at"),
                    "collector_error": self.get(db, "collector_error", ""),
                    "apply_error": self.get(db, "apply_error", ""),
                    "sync_error": self.get(db, "sync_error", ""),
                    "pending_batches": db.execute("SELECT COUNT(*) FROM outbox").fetchone()[0],
                    "unpackaged_rows": db.execute("SELECT COUNT(*) FROM pending_usage").fetchone()[0],
                    "usage": usage}


@contextlib.contextmanager
def database_connection(path):
    db = sqlite3.connect(path, timeout=4.0)
    db.row_factory = sqlite3.Row
    try:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=FULL")
        db.execute("PRAGMA busy_timeout=4000")
        yield db
        db.commit()
    except BaseException:
        db.rollback()
        raise
    finally:
        db.close()


def probe_core(config):
    """Identify the configured Linux sing-box process without shell helper locks."""
    proc = pathlib.Path("/proc")
    try:
        boot = (proc / "sys/kernel/random/boot_id").read_text().strip()
    except OSError as exc:
        raise CollectorError("Cannot read Linux boot identity") from exc
    core_config = str(pathlib.Path(config.get("state_path", DEFAULT_STATE)).parent / "config.json")
    candidates = []
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            command = (entry / "cmdline").read_bytes().split(b"\0")
            args = [part.decode("utf-8", "replace") for part in command if part]
            if not args or pathlib.Path(args[0]).name != "sing-box" or "run" not in args:
                continue
            configured = any(args[index] in ("-c", "--config") and index + 1 < len(args)
                             and args[index + 1] == core_config for index in range(len(args)))
            if not configured:
                continue
            raw = (entry / "stat").read_text()
            fields = raw[raw.rfind(")") + 2:].split()
            if fields[0] == "Z":
                continue
            starttime = fields[19]  # field 22; fields starts at Linux stat field 3.
            candidates.append(boot + ":" + entry.name + ":" + starttime)
        except (OSError, IndexError):
            continue
    if not candidates:
        raise CollectorError("sing-box is not running with the expected configuration")
    if len(candidates) != 1:
        raise CollectorError("Multiple sing-box processes use the expected configuration")
    return candidates[0]


def collect_counters(config):
    command = config.get("grpcurl_path", DEFAULT_GRPCURL)
    if not os.path.isabs(command) or not os.access(command, os.X_OK):
        raise CollectorError("grpcurl is not installed; repair the node agent installation")
    directory = private_parent(config["db_path"])
    with tempfile.TemporaryDirectory(prefix=".stats-", dir=str(directory)) as temp:
        proto_path = pathlib.Path(temp) / "stats.proto"
        proto_path.write_text(PROTO, encoding="utf-8")
        os.chmod(proto_path, 0o600)
        output = run_process([command, "-plaintext", "-max-time", "3", "-import-path", temp,
                              "-proto", "stats.proto", "-d", '{"reset":false}',
                              "127.0.0.1:41453",
                              "v2ray.core.app.stats.command.StatsService/QueryStats"], 4, config,
                             termination_grace=0.5)
    try:
        response = json.loads(output)
    except ValueError as exc:
        raise CollectorError("Stats API returned invalid JSON") from exc
    if not isinstance(response, dict) or not isinstance(response.get("stat", []), list):
        raise CollectorError("Stats API returned an invalid counter list")
    result, seen = {}, set()
    for stat in response.get("stat", []):
        if not isinstance(stat, dict) or not isinstance(stat.get("name"), str):
            raise CollectorError("Stats API returned an invalid counter")
        match = STAT_RE.fullmatch(stat["name"])
        if not match:
            continue
        key, direction = match.groups()
        if stat["name"] in seen:
            raise CollectorError("Stats API returned a duplicate counter")
        seen.add(stat["name"])
        value = stat.get("value", 0)
        if isinstance(value, str) and re.fullmatch(r"[0-9]+", value):
            value = int(value)
        integer(value, "statistics byte counter")
        result.setdefault(key, {})[direction] = value
    return result


class ActivityCollector:
    """Bounded durable log queue, independent of the byte-accounting ledger.

    Cursor, connection context and parsed events commit in one transaction. File
    truncation is detected by inode AND a cursor anchor (copytruncate keeps inode).
    Raw copytruncate can still race a core write; every trim is reported as a gap.
    """
    MAX_PENDING = 20000
    MAX_QUEUE_BYTES = 16 * 1024 * 1024
    MAX_RAW_BYTES = 9 * 1024 * 1024
    KEEP_RAW_BYTES = 2 * 1024 * 1024
    READ_BYTES = 256 * 1024
    LINE = re.compile(r"\b(INFO|WARN|ERROR|FATAL)\s+(?:\[(\d+)\s+[^\]]*\]\s+)?(.*)")
    INBOUND = re.compile(r"inbound/([^\s:]+)\[([^\]]+)\]:\s*(.*)")
    SOURCE = re.compile(r"inbound (?:packet )?connection from (\S+)")
    TARGET = re.compile(r"\[([^\]]+)\]\s+inbound (packet )?connection to (\S+)")
    ANSI = re.compile(r"\x1b\[[0-9;]*m")

    def __init__(self, config_path):
        self.config_path = str(config_path)
        config = read_json(config_path)
        # A new enrollment/center receives a fresh activity queue. The byte
        # ledger intentionally survives detach, whereas activity must not cross it.
        scope = str(config.get("node_id") or "pending") + "@" + config["center_url"]
        suffix = hashlib.sha256(scope.encode()).hexdigest()[:12]
        self.path = config["db_path"] + ".activity-" + suffix + ".db"
        private_parent(self.path)
        with self.connect() as db:
            db.execute("PRAGMA auto_vacuum=INCREMENTAL")
            db.executescript('''
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS pending(id TEXT PRIMARY KEY,ts INTEGER NOT NULL,payload TEXT NOT NULL,bytes INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS pending_time ON pending(ts);
                CREATE INDEX IF NOT EXISTS pending_size ON pending(bytes);
                CREATE TABLE IF NOT EXISTS seen(id TEXT PRIMARY KEY,ts INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS contexts(id TEXT PRIMARY KEY,ts INTEGER NOT NULL,value TEXT NOT NULL);
            ''')
        os.chmod(self.path, 0o600)

    @contextlib.contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=3, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA synchronous=FULL")
        db.execute("PRAGMA busy_timeout=3000")
        # The queue has a 16 MiB payload budget; this also bounds ancillary pages.
        db.execute("PRAGMA max_page_count=12288")
        try:
            yield db
        finally:
            db.close()

    @contextlib.contextmanager
    def transaction(self):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                yield db
                db.execute("COMMIT")
            except BaseException:
                db.execute("ROLLBACK")
                raise

    @staticmethod
    def endpoint(value):
        host, port = value, 0
        try:
            host, raw_port = value.rsplit(":", 1)
            port = int(raw_port)
            if not 0 <= port <= 65535:
                raise ValueError()
        except ValueError:
            return value[:512], 0
        return host.strip("[]")[:512], port

    @staticmethod
    def timestamp(line, fallback):
        match = re.search(r"([+-]\d{4})\s+(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", line)
        if match:
            try:
                return int(datetime.datetime.strptime(match[2] + match[1], "%Y-%m-%d %H:%M:%S%z").timestamp())
            except ValueError:
                pass
        return fallback

    def aliases(self, config):
        aliases = {}
        # Legacy names remain resolvable across a managed credential adoption.
        with database_connection(config["db_path"]) as db:
            aliases.update((row["stats_key"], row["user_id"]) for row in db.execute("SELECT stats_key,user_id FROM aliases"))
        state = read_json(config.get("state_path", DEFAULT_STATE))
        imported = config.get("registration_aliases", {})
        for name, uid in imported.items():
            if isinstance(uid, str) and USER_ID_RE.fullmatch(uid):
                aliases[name] = uid
        managed_here = state.get("management", {}).get("node_id") == config.get("node_id")
        for user in state.get("users", []):
            uid = str(user.get("id", "") if managed_here else imported.get(user.get("name"), ""))
            if USER_ID_RE.fullmatch(uid):
                aliases[uid] = uid
                aliases[user.get("stats_key") or user.get("name")] = uid
        return aliases

    def enqueue(self, db, event):
        # One malformed log field must not poison an otherwise valid upload batch.
        for key, limit in (("source_ip", 64), ("target", 512), ("inbound", 100), ("message", 500)):
            if key in event:
                event[key] = re.sub(r"[\x00-\x1f\x7f]", " ", str(event[key])).strip()[:limit]
        payload = canonical(event)
        if db.execute("INSERT OR IGNORE INTO seen VALUES(?,?)", (event["id"], event["ts"])).rowcount:
            db.execute("INSERT OR IGNORE INTO pending VALUES(?,?,?,?)", (event["id"], event["ts"], payload, len(payload.encode("utf-8"))))

    def gap(self, db, reason, ts):
        Ledger.put(db, "gaps", Ledger.get(db, "gaps", 0) + 1)
        event = {"id": uuid.uuid4().hex + uuid.uuid4().hex, "ts": ts, "user_id": None,
                 "kind": "gap", "message": reason}
        self.enqueue(db, event)

    def parse(self, db, raw, session, aliases, fallback):
        line = self.ANSI.sub("", raw.decode("utf-8", "replace")).strip()
        match = self.LINE.search(line)
        if not match:
            return
        level, cid, message = match.groups()
        ts = self.timestamp(line, fallback)
        if ts < 1577836800 or ts > int(time.time()) + 300:
            return
        context_id = session + ":" + str(cid) if cid else None
        row = db.execute("SELECT value FROM contexts WHERE id=?", (context_id,)).fetchone() if context_id else None
        context = json.loads(row[0]) if row else {}
        inbound = self.INBOUND.search(message)
        if inbound:
            context["inbound"] = inbound[2][:100]
        source = self.SOURCE.search(message)
        if source:
            # A reused connection ID starts a NEW authentication context. Never
            # attach an early handshake failure to that ID's previous user.
            context = {"source_ip": self.endpoint(source[1])[0][:64]}
            if inbound:
                context["inbound"] = inbound[2][:100]
        target = self.TARGET.search(message)
        event = None
        if target and inbound:
            context.update(user_id=aliases.get(target[1]), target=self.endpoint(target[3])[0],
                           port=self.endpoint(target[3])[1], network="udp" if target[2] else "tcp")
            event = dict(context, kind="connection")
        elif level in ("ERROR", "FATAL"):
            # Only a previously authenticated context can attribute an error.
            # Never guess a user from source IP or an unauthenticated scan.
            event = dict(context, kind="error", message=" ".join(message.split())[:500])
        if context_id and context:
            db.execute("INSERT INTO contexts VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET ts=excluded.ts,value=excluded.value",
                       (context_id, ts, canonical(context)))
        if event:
            event.update(id=hashlib.sha256((session + line).encode()).hexdigest(), ts=ts)
            self.enqueue(db, event)

    def bound_queue(self, db, ts):
        # Expired/offline data cannot fill the disk indefinitely. Make the loss
        # explicit in status as well as a gap event; byte accounting is separate.
        dropped = db.execute("DELETE FROM pending WHERE ts<?", (ts - 7 * 86400,)).rowcount
        count, size = db.execute("SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM pending").fetchone()
        if count > self.MAX_PENDING or size > self.MAX_QUEUE_BYTES:
            for row in db.execute("SELECT id,bytes FROM pending ORDER BY ts,rowid").fetchall():
                if count <= self.MAX_PENDING - 1 and size <= self.MAX_QUEUE_BYTES - 2048:
                    break
                db.execute("DELETE FROM pending WHERE id=?", (row["id"],))
                dropped += 1
                count -= 1
                size -= row["bytes"]
        if dropped:
            Ledger.put(db, "dropped", Ledger.get(db, "dropped", 0) + dropped)
            self.gap(db, "本地行为缓存达到容量或 7 天期限，丢弃 %d 条记录" % dropped, ts)
        db.execute("DELETE FROM seen WHERE rowid IN (SELECT rowid FROM seen ORDER BY rowid DESC LIMIT -1 OFFSET 40000)")
        db.execute("DELETE FROM contexts WHERE ts<?", (ts - 900,))
        db.execute("DELETE FROM contexts WHERE rowid IN (SELECT rowid FROM contexts ORDER BY ts DESC LIMIT -1 OFFSET 4000)")

    def collect_once(self):
        config = read_json(self.config_path)
        if config.get("detached") or config.get("detaching") or config.get("status") != "active":
            return False
        aliases = self.aliases(config)
        path = config.get("activity_log_path", system_path("/var/log/sing-box/sing-box.log"))
        ts = int(time.time())
        core_path = config.get("activity_core_config_path", system_path("/etc/sing-box/config.json"))
        if os.path.isfile(core_path):
            log_config = read_json(core_path).get("log", {})
            if (log_config.get("disabled") or log_config.get("level", "info") not in ("info", "debug", "trace")
                    or log_config.get("output") != path or log_config.get("timestamp") is not True):
                raise AgentError("行为日志未启用：请升级 VPS 脚本，使用 info 文件日志并开启 timestamp")
        with file_lock(self.path + ".read.lock", timeout=0.2):
            with open(path, "rb") as stream, self.transaction() as db:
                stat = os.fstat(stream.fileno())
                identity = [stat.st_dev, stat.st_ino, path]
                cursor = Ledger.get(db, "cursor", {})
                offset = cursor.get("offset", 0)
                same_file = cursor.get("identity") == identity
                session = cursor.get("session") if same_file else uuid.uuid4().hex
                changed = bool(cursor) and (not same_file or stat.st_size < offset)
                if same_file and not changed and offset:
                    stream.seek(max(0, offset - 128))
                    changed = hashlib.sha256(stream.read(min(offset, 128))).hexdigest() != cursor.get("anchor")
                if not cursor or not same_file or changed:
                    offset = 0
                    if cursor:
                        self.gap(db, "原始日志被裁剪、替换或轮转，已重新续读", ts)
                stream.seek(offset)
                block = stream.read(self.READ_BYTES)
                # Offset only crosses complete lines, except a malformed >64 KiB
                # line which is explicitly skipped and cannot stall the reader.
                complete = block.rfind(b"\n") + 1
                if not complete and len(block) >= 65536:
                    complete = len(block)
                    self.gap(db, "跳过超长或损坏的日志行", ts)
                for raw in block[:complete].splitlines():
                    if len(raw) <= 65536:
                        self.parse(db, raw, session, aliases, ts)
                    else:
                        self.gap(db, "跳过超长或损坏的日志行", ts)
                offset += complete
                stream.seek(max(0, offset - 128))
                anchor = hashlib.sha256(stream.read(min(offset, 128))).hexdigest()
                Ledger.put(db, "cursor", {"identity": identity, "session": session, "offset": offset, "anchor": anchor})
                Ledger.put(db, "collected_at", ts)
                Ledger.put(db, "error", "")
                self.bound_queue(db, ts)
                caught_up = offset >= stat.st_size
            # Parsed records are durable before raw bytes are discarded. The
            # writer can race copytruncate; disclose this conservative gap.
            if caught_up and stat.st_size >= self.MAX_RAW_BYTES:
                self.trim(path, identity)
        return not caught_up

    def trim(self, path, identity):
        with open(path, "r+b") as stream:
            stat = os.fstat(stream.fileno())
            if [stat.st_dev, stat.st_ino, path] != identity or stat.st_size < self.MAX_RAW_BYTES:
                return
            stream.seek(max(0, stat.st_size - self.KEEP_RAW_BYTES))
            tail = stream.read(self.KEEP_RAW_BYTES)
            tail = tail.partition(b"\n")[2]
            # Persist a gap BEFORE copytruncate, including across a process crash.
            with self.transaction() as db:
                self.gap(db, "原始日志达到 9 MiB，已保留最近 2 MiB；裁剪瞬间可能存在缺口", int(time.time()))
            stream.seek(0)
            stream.write(tail)
            stream.truncate(len(tail))
            stream.flush()
            os.fsync(stream.fileno())

    def set_error(self, error):
        with self.transaction() as db:
            Ledger.put(db, "error", " ".join(str(error).split())[:1000])

    def status(self):
        with self.connect() as db:
            return {"pending": db.execute("SELECT COUNT(*) FROM pending").fetchone()[0],
                    **{key: Ledger.get(db, key, "" if key == "error" else 0)
                       for key in ("collected_at", "dropped", "gaps", "error")}}

    def upload_once(self, transport=None, allow_loopback_http=False):
        config = read_json(self.config_path)
        if config.get("detached") or config.get("detaching") or config.get("status") != "active":
            return 0
        with self.connect() as db:
            events = [json.loads(row[0]) for row in db.execute("SELECT payload FROM pending ORDER BY ts,rowid LIMIT 400")]
        transport = transport or Transport(config["center_url"], config.get("node_token"), allow_loopback_http)
        response = transport.post("/api/agent/activity", {"protocol": PROTOCOL, "node_id": config["node_id"],
                                                        "events": events, "status": self.status()})
        ack = response.get("ack")
        sent = {event["id"] for event in events}
        if not isinstance(ack, list) or any(not isinstance(eid, str) or eid not in sent for eid in ack):
            raise TransportError("Invalid activity acknowledgement")
        with self.transaction() as db:
            db.executemany("DELETE FROM pending WHERE id=?", ((eid,) for eid in ack))
        with self.connect() as db:
            db.execute("PRAGMA incremental_vacuum(128)")
        return len(ack)


class Agent:
    def __init__(self, config_path, allow_loopback_http=False, transport=None,
                 collector=None, core_probe=None, helper_runner=None):
        self.config_path = str(config_path)
        self.config = read_json(self.config_path)
        if self.config.get("protocol", PROTOCOL) != PROTOCOL:
            raise AgentError("Unsupported local agent protocol")
        self.allow_loopback_http = allow_loopback_http
        validate_origin(self.config["center_url"], allow_loopback_http)
        self.ledger = Ledger(self.config["db_path"])
        self.transport_override = transport
        self.collector = collector or collect_counters
        self.core_probe = core_probe or probe_core
        self.helper_runner = helper_runner or helper

    def reload(self):
        fresh = read_json(self.config_path)
        if fresh.get("db_path") != self.config.get("db_path"):
            raise AgentError("Agent configuration changed to another ledger; restart the service")
        self.config = fresh
        return fresh

    def save(self):
        atomic_json(self.config_path, self.config)

    def transport(self, timeout=12):
        return self.transport_override or Transport(self.config["center_url"], self.config.get("node_token"),
                                                     self.allow_loopback_http, timeout=timeout)

    def state(self):
        return read_json(self.config.get("state_path", DEFAULT_STATE))

    def subscription_inbounds(self):
        state = self.state()
        result = []
        for node in state.get("nodes", []):
            kind = str(node.get("type", ""))
            item = {key: node.get(key, "") for key in ("name", "tag", "type", "port")}
            item.update(server=state.get("server_ip", ""),
                        sni=state.get("tuic_sni" if kind.startswith("tuic") else "reality_sni", ""),
                        public_key=state.get("public_key", ""), short_id=state.get("short_id", ""),
                        skip_cert_verify=kind.startswith("tuic"))
            result.append(item)
        return result

    def is_running(self):
        try:
            self.core_probe(self.config)
            return True
        except (AgentError, OSError):
            return False

    def remember_state(self, state):
        aliases = []
        known = {item["stats_key"] for item in self.ledger.aliases()}
        for user in state.get("users", []):
            if not isinstance(user, dict) or not USER_ID_RE.fullmatch(str(user.get("id", ""))):
                continue
            key = user.get("stats_key") or user.get("name")
            if isinstance(key, str) and key and ">" not in key and key not in known:
                aliases.append((key, user["id"], True))
        self.ledger.remember(aliases)

    def sample_once(self, allow_detaching=False):
        with file_lock(self.ledger.path + ".sample.lock", timeout=0.5):
            self.reload()
            if self.config.get("detached") or (self.config.get("detaching") and not allow_detaching):
                return {"skipped": "detached_or_detaching"}
            if not self.config.get("node_id") or self.config.get("status") in ("registering", "pending"):
                return {"skipped": "waiting_for_first_sync"}
            if (not self.ledger.meta("applied_revision", 0)
                    and not self.ledger.meta("adoption_prepared", False)):
                return {"skipped": "waiting_for_first_sync"}
            try:
                self.remember_state(self.state())
                if not self.ledger.aliases():
                    return {"skipped": "waiting_for_first_sync"}
                before = self.core_probe(self.config)
                counters = self.collector(self.config)
                after = self.core_probe(self.config)
                if before != after:
                    raise CollectorError("sing-box restarted during collection; sample was not committed")
                return self.ledger.record(before, counters, int(time.time()))
            except (AgentError, OSError, ValueError, sqlite3.Error) as exc:
                message = redact(exc, self.config)
                try:
                    self.ledger.set_meta(collector_error=message, service_running=self.is_running())
                except sqlite3.Error as disk_error:
                    raise AgentError("Ledger write failed; counters were not acknowledged or discarded: "
                                     + str(disk_error)) from exc
                raise CollectorError(message) from exc

    def register(self):
        self.reload()
        if self.config.get("node_id"):
            return {"node_id": self.config["node_id"], "status": self.config.get("status", "pending")}
        payload = self.config.get("registration_payload")
        if not payload:
            raise AgentError("No pending registration exists")
        response = self.transport().post("/api/agent/register", payload, authenticated=False)
        if (not NODE_ID_RE.fullmatch(str(response.get("node_id", "")))
                or response.get("status") not in ("pending", "active")):
            raise TransportError("Invalid registration response")
        imported = response.get("imported", [])
        if not isinstance(imported, list):
            raise TransportError("Invalid imported user mappings")
        registration_users = {user["name"] for user in payload.get("users", [])}
        aliases = {}
        for item in imported:
            if (not isinstance(item, dict) or item.get("old_name") not in registration_users
                    or not USER_ID_RE.fullmatch(str(item.get("id", "")))):
                raise TransportError("Invalid imported user mapping")
            if item["old_name"] in aliases and aliases[item["old_name"]] != item["id"]:
                raise TransportError("Ambiguous imported user mapping")
            aliases[item["old_name"]] = item["id"]
        self.config.update(node_id=response["node_id"], status=response["status"], registered_at=int(time.time()))
        self.config["registration_aliases"] = aliases
        self.config.pop("registration_payload", None)
        self.save()
        return {"node_id": self.config["node_id"], "status": self.config["status"]}

    def prepare_desired(self, desired):
        if not isinstance(desired, dict) or desired.get("node_id") != self.config.get("node_id"):
            raise AgentError("Desired configuration belongs to another node")
        revision = integer(desired.get("revision"), "desired revision", 1)
        users = validated_users(desired.get("users"), snapshots=True)
        current_revision = self.ledger.meta("applied_revision", 0)
        if revision < current_revision:
            raise AgentError("Center offered an older configuration revision")
        state = self.state()
        management = state.get("management", {})
        applied_on_disk = management.get("revision")
        applying_on_disk = management.get("applying_revision")
        known_revisions = [value for value in (applied_on_disk, applying_on_disk)
                           if type(value) is int and value >= 1]
        managed_on_this_node = (management.get("mode") == "managed"
                                and management.get("node_id") == self.config.get("node_id")
                                and bool(known_revisions))
        if managed_on_this_node:
            # A crash can happen after the helper replaced the local state but
            # before the ledger recorded its acknowledgement. The center may
            # already offer a newer revision; the first-registration fingerprint
            # no longer describes this local state. Trust its stable IDs after
            # checking the locally managed snapshot and monotonic revision.
            validated_users(state.get("users", []), snapshots=True)
            if revision < max(known_revisions):
                raise AgentError("Center offered a revision older than the locally managed state")
        if (current_revision == 0 and not managed_on_this_node
                and self.config.get("registration_fingerprint")):
            if fingerprint(state.get("users", [])) != self.config["registration_fingerprint"]:
                raise AgentError("Local users changed after registration, before initial center sync. "
                                 "Review local users and reconnect")
        by_uuid = {user["uuid"]: user["id"] for user in users}
        desired_ids = {user["id"] for user in users}
        imported_aliases = self.config.get("registration_aliases", {})
        aliases = []
        for local in state.get("users", []):
            old_key = local.get("stats_key") or local.get("name")
            identity = local.get("id") if (current_revision or managed_on_this_node) else None
            if not USER_ID_RE.fullmatch(str(identity or "")):
                # An existing central account may have different credentials.
                # The registration response links the original local name to
                # its central identity before the first desired snapshot.
                identity = imported_aliases.get(local.get("name"))
                if identity not in desired_ids:
                    identity = by_uuid.get(str(local.get("uuid", "")).lower())
            if identity and isinstance(old_key, str) and old_key:
                aliases.append((old_key, identity, True))
        current_keys = {user.get("stats_key") or user.get("name") for user in state.get("users", [])}
        aliases.extend((user["id"], user["id"], user["id"] in current_keys) for user in users)
        with file_lock(self.ledger.path + ".sample.lock", timeout=8):
            self.ledger.remember(aliases)
            self.ledger.set_meta(adoption_prepared=True)
        return {"node_id": desired["node_id"], "revision": revision, "users": users}

    def apply_desired(self, desired):
        payload = self.prepare_desired(desired)
        if payload["revision"] == self.ledger.meta("applied_revision", 0):
            return False
        directory = private_parent(self.ledger.path)
        fd, path = tempfile.mkstemp(prefix=".desired-", suffix=".json", dir=str(directory))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(canonical(payload))
                stream.flush()
                os.fsync(stream.fileno())
            helper_config = dict(self.config, _redact_users=payload["users"])
            self.helper_runner(helper_config, "agent-apply", (path,), 120)
            management = self.state().get("management", {})
            if (management.get("mode") != "managed" or management.get("node_id") != payload["node_id"]
                    or management.get("revision") != payload["revision"] or not self.is_running()):
                raise AgentError("Helper did not confirm the requested revision and a healthy core")
            self.ledger.set_meta(applied_revision=payload["revision"], apply_error="", last_apply_at=int(time.time()))
            return True
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(path)

    def sync_once(self, force_package=False, apply=True):
        with file_lock(self.config_path + ".sync.lock", timeout=1):
            self.reload()
            if self.config.get("detached") or self.config.get("detaching"):
                raise AgentError("Node is detached or detaching")
            if self.config.get("remote_detached"):
                return self._detach_local()
            return self._sync(force_package=force_package, apply=apply)

    def wait_changes(self, detach=True):
        """Wait without holding the sync lock, so metrics and application continue."""
        self.reload()
        if self.config.get("detached"):
            return {"status": "detached", "changed": False}
        if self.config.get("remote_detached"):
            return self.detach_from_center() if detach else {"changed": False, "detach_requested": True}
        if self.config.get("detaching") or not self.config.get("node_id"):
            return {"changed": False, "skipped": True}
        try:
            # /wait compares a notification cursor; only /sync acknowledges a
            # genuinely applied revision. Remember an offered revision here so
            # the listener can hear later edits/deletion during a slow apply.
            cursor = max(self.ledger.meta("applied_revision", 0), getattr(self, "_notified_revision", 0))
            result = self.transport(timeout=WAIT_SECONDS + 5).post("/api/agent/wait", {
                "protocol": PROTOCOL, "node_id": self.config["node_id"],
                "applied_revision": cursor, "timeout": WAIT_SECONDS})
            if type(result.get("changed")) is not bool:
                raise TransportError("Invalid center change notification")
            integer(result.get("revision"), "notified revision")
            if result["changed"]:
                self._notified_revision = result["revision"]
            return result
        except TransportError as exc:
            if exc.status == 410:
                return self.detach_from_center() if detach else {"changed": False, "detach_requested": True}
            raise

    def detach_from_center(self):
        """The center already removed this binding; no remote request is needed."""
        with file_lock(self.config_path + ".sync.lock", timeout=20):
            self.reload()
            return self._detach_local()

    def _detach_local(self):
        if self.config.get("detached"):
            return {"status": "detached", "changed": False, "ledger_preserved": self.ledger.path}
        self.config.update(remote_detached=True, detaching=True)
        self.save()
        try:
            self.helper_runner(self.config, "agent-detach", (), 120)
            self.config.update(detached=True, detaching=False, status="detached", detached_at=int(time.time()))
            for key in ("node_token", "registration_payload", "registration_fingerprint", "registration_aliases"):
                self.config.pop(key, None)
            self.save()
            self.ledger.set_meta(sync_error="", apply_error="")
            return {"node_id": self.config.get("node_id"), "status": "detached", "changed": False,
                    "acknowledged_batches": 0, "applied": False, "ledger_preserved": self.ledger.path,
                    "pending_batches": self.ledger.summary()["pending_batches"]}
        except BaseException:
            # Keep the remote decision, but allow the next sync to retry the
            # local helper rather than leaving local management locked forever.
            self.config["detaching"] = False
            self.save()
            raise

    def _sync(self, force_package=False, apply=True):
        if not self.config.get("node_id"):
            try:
                self.register()
            except TransportError as exc:
                if exc.status in (403, 410):
                    # A rejected/expired registration cannot recover by
                    # retrying the same join code. This also covers a lost
                    # registration reply followed by deletion at the center.
                    return self._detach_local()
                raise
        self.ledger.package(force=force_package)
        status = self.ledger.summary()
        batches = self.ledger.batches()
        payload = {"protocol": PROTOCOL, "node_id": self.config["node_id"], "agent_version": VERSION,
                   "applied_revision": status["applied_revision"], "apply_error": status["apply_error"],
                   "service_running": self.is_running(), "collector_error": status["collector_error"],
                   "last_sample_at": status["last_sample_at"] or 0, "pending_batches": status["pending_batches"],
                   "batches": batches, "inbounds": self.subscription_inbounds()}
        try:
            response = self.transport().post("/api/agent/sync", payload)
            if response.get("node_id") != self.config["node_id"] or response.get("status") not in ("active", "pending"):
                raise TransportError("Center returned an invalid node status")
            acknowledged = self.ledger.acknowledge(response.get("ack", []), batches)
            self.ledger.set_meta(last_sync_at=int(time.time()), sync_error="")
            if self.config.get("status") != response["status"]:
                self.config["status"] = response["status"]
                self.save()
            applied = False
            if apply and response.get("desired") is not None:
                try:
                    if response["status"] != "active":
                        raise AgentError("Node is not yet active")
                    applied = self.apply_desired(response["desired"])
                except (AgentError, OSError, ValueError, sqlite3.Error) as exc:
                    self.ledger.set_meta(apply_error=redact(exc, self.config))
                    raise AgentError("Configuration was not acknowledged: " + redact(exc, self.config)) from exc
            return {"node_id": self.config["node_id"], "status": response["status"],
                    "acknowledged_batches": acknowledged, "applied": applied,
                    "applied_revision": self.ledger.meta("applied_revision", 0)}
        except TransportError as exc:
            if exc.status == 410:
                return self._detach_local()
            self.ledger.set_meta(sync_error=redact(exc, self.config))
            raise
        except (AgentError, OSError, ValueError, sqlite3.Error) as exc:
            self.ledger.set_meta(sync_error=redact(exc, self.config))
            raise

    def detach(self, force=False):
        with file_lock(self.config_path + ".sync.lock", timeout=20):
            self.reload()
            if self.config.get("detached"):
                return {"status": "detached", "ledger_preserved": self.ledger.path}
            self.config["detaching"] = True
            self.save()
            try:
                try:
                    self.sample_once(allow_detaching=True)
                except (AgentError, OSError, sqlite3.Error) as exc:
                    log("Final sample failed: " + str(exc), self.config)
                if not self.config.get("remote_detached"):
                    try:
                        if self.config.get("node_id"):
                            # Drain bounded batches without applying a new desired configuration.
                            for unused in range(64):
                                result = self._sync(force_package=True, apply=False)
                                if result.get("status") == "detached":
                                    return result
                                summary = self.ledger.summary()
                                if not summary["pending_batches"] and not summary["unpackaged_rows"]:
                                    break
                                if not result["acknowledged_batches"]:
                                    raise AgentError("Center did not acknowledge pending traffic")
                            else:
                                raise AgentError("Traffic backlog is too large; finish syncing before detaching")
                            response = self.transport().post("/api/agent/detach", {
                                "protocol": PROTOCOL, "node_id": self.config["node_id"]})
                            if response.get("node_id", self.config["node_id"]) != self.config["node_id"]:
                                raise TransportError("Invalid detach acknowledgement")
                        elif not force:
                            raise AgentError("Registration is incomplete; use --force for local detachment")
                        self.config["remote_detached"] = True
                        self.save()
                    except (AgentError, OSError, ValueError) as exc:
                        if isinstance(exc, TransportError) and exc.status == 410:
                            return self._detach_local()
                        if not force:
                            raise AgentError("Center detachment could not be confirmed. Local configuration "
                                             "was retained; use detach --force for an explicit local detachment. "
                                             + redact(exc, self.config)) from exc
                        log("Forced local detachment; unacknowledged traffic stays in the ledger: " + str(exc), self.config)
                return self._detach_local()
            except BaseException:
                if not self.config.get("remote_detached"):
                    self.config["detaching"] = False
                    self.save()
                raise

    def status(self):
        result = {"version": VERSION, "node_id": self.config.get("node_id"),
                  "status": self.config.get("status", "registering"),
                  "center_url": self.config["center_url"], "detached": bool(self.config.get("detached")),
                  "service_running": self.is_running()}
        result.update(self.ledger.summary())
        return result

    def run(self):
        with file_lock(self.ledger.path + ".run.lock", timeout=0.1):
            stop = threading.Event()
            change = threading.Event()
            center_detached = threading.Event()
            old_handlers = {}
            for sig in (signal.SIGTERM, signal.SIGINT):
                old_handlers[sig] = signal.signal(sig, lambda signum, frame: (stop.set(), change.set()))

            # Each worker owns its config snapshot. Atomic config replacement is
            # shared; mutable Python dictionaries are not shared across threads.
            sampling_agent = Agent(self.config_path, self.allow_loopback_http,
                                   collector=self.collector, core_probe=self.core_probe,
                                   helper_runner=self.helper_runner)
            waiting_agent = Agent(self.config_path, self.allow_loopback_http, transport=self.transport_override,
                                  collector=self.collector, core_probe=self.core_probe,
                                  helper_runner=self.helper_runner)

            def sampler():
                while not stop.is_set():
                    start = time.monotonic()
                    try:
                        current = read_json(self.config_path)
                        if current.get("detached"):
                            stop.set()
                            change.set()
                            break
                        if current.get("detaching"):
                            stop.wait(0.25)
                            continue
                        sampling_agent.sample_once()
                    except LockBusy:
                        pass
                    except (AgentError, OSError, ValueError, sqlite3.Error) as exc:
                        log("Collector: " + str(exc), self.config)
                    stop.wait(max(0.1, SAMPLE_SECONDS - (time.monotonic() - start)))

            def watch_changes():
                while not stop.is_set():
                    try:
                        # Only the main worker changes local bindings/config.
                        # This listener can block on HTTPS independently of the
                        # sampler and the regular metrics/reporting cycle.
                        result = waiting_agent.wait_changes(detach=False)
                        if result.get("detach_requested"):
                            center_detached.set()
                            change.set()
                            break
                        if result.get("status") == "detached":
                            stop.set()
                            change.set()
                            break
                        if result.get("changed"):
                            change.set()
                        elif result.get("skipped"):
                            stop.wait(0.5)
                    except TransportError as exc:
                        if exc.status in (404, 405):
                            log("Center has no change listener; keeping 15-second sync", self.config)
                            break
                        log("Change listener: " + str(exc), self.config)
                        stop.wait(3)
                    except (AgentError, OSError, ValueError, sqlite3.Error) as exc:
                        log("Change listener: " + str(exc), self.config)
                        stop.wait(3)

            def activity_worker(upload=False):
                activity = None
                while not stop.is_set():
                    delay = SYNC_SECONDS if upload else 1
                    try:
                        current = read_json(self.config_path)
                        if current.get("detached") or current.get("detaching"):
                            break
                        if current.get("status") != "active" or not current.get("node_id"):
                            stop.wait(1)
                            continue
                        if activity is None:
                            activity = ActivityCollector(self.config_path)
                        if upload:
                            sent = activity.upload_once(self.transport_override, self.allow_loopback_http)
                            if sent == 400:
                                delay = 0.25
                        elif activity.collect_once():
                            delay = 0.05
                    except TransportError as exc:
                        if exc.status == 410:
                            center_detached.set()
                            change.set()
                            break
                        if exc.status in (404, 405):
                            delay = 60
                        # A network failure cannot stop the continuous reader.
                    except (AgentError, OSError, ValueError, sqlite3.Error) as exc:
                        if activity is not None and not upload:
                            with contextlib.suppress(sqlite3.Error):
                                activity.set_error(redact(exc, current))
                        delay = 3
                    stop.wait(delay)

            activity_reader = threading.Thread(target=activity_worker, name="ysq-activity-reader", daemon=True)
            activity_uploader = threading.Thread(target=lambda: activity_worker(True), name="ysq-activity-uploader", daemon=True)
            activity_reader.start()
            activity_uploader.start()
            thread = threading.Thread(target=sampler, name="ysq-sampler", daemon=True)
            listener = threading.Thread(target=watch_changes, name="ysq-change-listener", daemon=True)
            thread.start()
            listener.start()
            failures = 0
            try:
                while not stop.is_set():
                    start = time.monotonic()
                    change.clear()
                    try:
                        self.reload()
                        if self.config.get("detached") or self.config.get("detaching"):
                            break
                        result = self.detach_from_center() if center_detached.is_set() else self.sync_once()
                        if result.get("status") == "detached":
                            stop.set()
                            break
                        if result.get("applied"):
                            # Confirm the applied revision immediately so the
                            # panel does not keep showing pending for 15 seconds.
                            change.set()
                        failures = 0
                    except LockBusy:
                        pass
                    except (AgentError, OSError, ValueError, sqlite3.Error) as exc:
                        failures = min(failures + 1, 5)
                        log("Sync: " + str(exc), self.config)
                    delay = min(120, SYNC_SECONDS * (2 ** max(0, failures - 1)))
                    change.wait(max(0.1, delay - (time.monotonic() - start)))
            finally:
                stop.set()
                change.set()
                thread.join(timeout=8)
                listener.join(timeout=1)
                activity_reader.join(timeout=4)
                activity_uploader.join(timeout=1)
                for sig, handler in old_handlers.items():
                    signal.signal(sig, handler)


def join(config_path, url, code, name=None, script=None, allow_loopback_http=False):
    origin = validate_origin(url, allow_loopback_http)
    with file_lock(str(config_path) + ".sync.lock", timeout=5):
        previous = read_json(config_path) if os.path.isfile(config_path) else None
        if previous and not previous.get("detached"):
            if previous.get("center_url") != origin:
                raise AgentError("Already enrolled with another center; detach before joining another")
            agent = Agent(config_path, allow_loopback_http)
            if agent.config.get("node_id"):
                return {"node_id": agent.config["node_id"], "status": agent.config.get("status", "pending")}
            pending = agent.config.get("registration_payload")
            if not isinstance(pending, dict):
                raise AgentError("An unfinished registration has no saved request; inspect agent state")
            if pending.get("join_code") != code:
                # The user may have regenerated an expired one-time code. Reuse
                # the durable registration id and node token: if the earlier
                # request was committed but its response lost, the center can
                # still reply idempotently without creating duplicate nodes.
                pending["join_code"] = code
                agent.save()
            return agent.register()
        registration_id = uuid.uuid4().hex
        db_path = DEFAULT_DB
        history = []
        if previous:
            history = list(previous.get("previous_ledgers", []))
            history.append({"db_path": previous["db_path"], "node_id": previous.get("node_id"),
                            "center_url": previous.get("center_url")})
            db_path = str(pathlib.Path(previous["db_path"]).parent / ("agent-" + registration_id + ".db"))
        config = {"protocol": PROTOCOL, "agent_version": VERSION, "node_id": None,
                  "node_token": secrets.token_urlsafe(32), "center_url": origin,
                  "script_path": os.path.abspath(script or DEFAULT_SCRIPT), "db_path": db_path,
                  "state_path": DEFAULT_STATE, "grpcurl_path": shutil.which("grpcurl") or DEFAULT_GRPCURL,
                  "registration_id": registration_id, "status": "registering", "detached": False,
                  "created_at": int(time.time()), "previous_ledgers": history}
        raw = helper(config, "agent-inventory", (), 20)
        try:
            inventory = json.loads(raw)
        except ValueError as exc:
            raise AgentError("Inventory helper did not return JSON") from exc
        if not isinstance(inventory, dict):
            raise AgentError("Invalid inventory helper response")
        users = validated_users(inventory.get("users"))
        inbounds = []
        for inbound in inventory.get("inbounds", []):
            if not isinstance(inbound, dict):
                raise AgentError("Invalid inbound inventory")
            port = integer(inbound.get("port"), "inbound port", 1, 65535)
            clean = {key: str(inbound.get(key, ""))[:253] for key in ("name", "tag", "type", "server", "sni", "public_key", "short_id")}
            clean["skip_cert_verify"] = bool(inbound.get("skip_cert_verify", False))
            clean["port"] = port
            inbounds.append(clean)
        config["registration_fingerprint"] = fingerprint(users)
        config["registration_payload"] = {"protocol": PROTOCOL, "join_code": code,
            "registration_id": registration_id, "node_token": config["node_token"],
            "agent_version": VERSION, "hostname": str(name or socket.gethostname())[:253],
            "users": users, "inbounds": inbounds}
        # Persist identity before the first byte is sent. Never regenerate it on a network retry.
        Ledger(db_path)
        atomic_json(config_path, config)
        return Agent(config_path, allow_loopback_http).register()


def main(argv=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="YSQ optional HTTPS center agent")
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--allow-loopback-http", action="store_true", help="Test-only: allow HTTP on loopback")
    parser.add_argument("--version", action="version", version=VERSION)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("run", "status", "sync-once", "sample-once"):
        commands.add_parser(command)
    joining = commands.add_parser("join")
    joining.add_argument("--url", required=True)
    joining.add_argument("--code", required=True)
    joining.add_argument("--name")
    joining.add_argument("--script")
    detaching = commands.add_parser("detach")
    detaching.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "join":
            result = join(args.config, args.url, args.code, args.name, args.script, args.allow_loopback_http)
        elif args.command == "status" and not os.path.isfile(args.config):
            result = {"version": VERSION, "status": "standalone", "configured": False}
        else:
            agent = Agent(args.config, args.allow_loopback_http)
            if args.command == "run":
                agent.run()
                return 0
            if args.command == "sample-once":
                result = agent.sample_once()
            elif args.command == "sync-once":
                result = agent.sync_once(force_package=True)
            elif args.command == "detach":
                result = agent.detach(force=args.force)
            else:
                result = agent.status()
        print(canonical(result))
        return 0
    except (AgentError, OSError, ValueError, sqlite3.Error) as exc:
        config = {}
        with contextlib.suppress(Exception):
            config = read_json(args.config)
        log(exc, config)
        return 1


if __name__ == "__main__":
    sys.exit(main())
# END_EMBEDDED_AGENT
YSQ_AGENT_PY
}

ensure_agent_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    [ -z "$YSQ_TEST_ROOT" ] || { err "隔离测试需要 Python 3.9+。"; return 1; }
    pkg_update
    pkg_install python3 || return 1
  fi
  if ! python3 -c 'import sys, sqlite3, ssl; raise SystemExit(0 if sys.version_info >= (3,9) else 1)' >/dev/null 2>&1; then
    err "中控 Agent 需要 Python 3.9 或更新版本，以及 sqlite3/ssl 标准库；当前单机功能不受影响。"
    return 1
  fi
}

install_agent_service() {
  local wd py
  wd="$(new_work_dir)"
  py="$(command -v python3)"
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
ExecStart=${py} ${AGENT_FILE} --config ${AGENT_CONFIG_FILE} run
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
command="${py}"
command_args="${AGENT_FILE} --config ${AGENT_CONFIG_FILE} run"
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
    *) err "中控 Agent 常驻运行需要 systemd 或 OpenRC；本机可继续单机使用。"; return 1 ;;
  esac
}

install_agent_bundle() {
  ensure_agent_python || return 1
  ensure_grpcurl || return 1
  local wd
  wd="$(new_work_dir)"
  mkdir -p "$(dirname "$AGENT_FILE")" "$(dirname "$AGENT_CONFIG_FILE")" "$AGENT_DATA_DIR"
  chmod 700 "$(dirname "$AGENT_CONFIG_FILE")" "$AGENT_DATA_DIR"
  write_embedded_agent > "$wd/ysq-agent.py"
  python3 -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' \
    "$wd/ysq-agent.py" || return 1
  install -m 700 "$wd/ysq-agent.py" "${AGENT_FILE}.new.${WORK_TAG}"
  mv -f "${AGENT_FILE}.new.${WORK_TAG}" "$AGENT_FILE"
  install_agent_service || return 1
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

agent_service_ensure_running() {
  case "$SERVICE_MANAGER" in
    systemd) systemctl is-active --quiet ysq-agent 2>/dev/null && return 0 ;;
    openrc) rc-service ysq-agent status >/dev/null 2>&1 && return 0 ;;
    test) [ -f "$AGENT_DATA_DIR/test-running" ] && return 0 ;;
  esac
  agent_service_start
}

restore_agent_if_configured() {
  agent_binding_present || return 0
  [ -s "$AGENT_CONFIG_FILE" ] || { warn "中控绑定配置缺失，请恢复 Agent 配置备份；保留当前已生效用户。"; return 0; }
  install_agent_bundle || { warn "恢复 Agent 失败；代理服务保留当前用户配置。"; return 0; }
  agent_service_start || warn "Agent 启动失败，请在「中控连接管理」中检查状态。"
}

agent_join_wizard() {
  need_state
  if agent_binding_present; then
    if [ -s "$AGENT_CONFIG_FILE" ] && jq -e '
        (.detached != true) and (.node_id == null) and (.status == "registering")
      ' "$AGENT_CONFIG_FILE" >/dev/null 2>&1; then
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
  if [[ ! "$code" =~ ^[A-Za-z0-9_-]{32,256}$ ]]; then
    err "接入码格式不正确，请重新从中控网页复制完整连接信息。"
    return 1
  fi
  ( acquire_config_lock; install_agent_bundle ) || return 1
  # Agent joins without holding the config lock; it reads local inventory.
  if ! python3 "$AGENT_FILE" --config "$AGENT_CONFIG_FILE" join \
    --url "$url" --code "$code" --script "$INSTALLER_FILE" >/dev/null; then
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
  if [ ! -s "$AGENT_CONFIG_FILE" ] || [ ! -f "$AGENT_FILE" ]; then
    info "运行模式：单机模式（未连接中控）"
    info "用户配置：在本机 ysq 菜单管理"
    return 0
  fi
  local status mode center node_id revision last_sync last_sample pending rows
  local sync_error apply_error sample_error running text last_sync_display last_sample_display
  status="$(python3 "$AGENT_FILE" --config "$AGENT_CONFIG_FILE" status)" || {
    err "无法读取 Agent 状态，请检查 ysq-agent 服务日志。"
    return 1
  }
  center="$(jq -r '.center_url // "-"' <<<"$status")"
  node_id="$(jq -r '.node_id // "-"' <<<"$status")"
  mode="$(jq -r '.status // "unknown"' <<<"$status")"
  revision="$(jq -r '.applied_revision // 0' <<<"$status")"
  last_sync="$(jq -r '.last_sync_at // 0' <<<"$status")"
  last_sample="$(jq -r '.last_sample_at // 0' <<<"$status")"
  pending="$(jq -r '.pending_batches // 0' <<<"$status")"
  rows="$(jq -r '.unpackaged_rows // 0' <<<"$status")"
  sync_error="$(jq -r '.sync_error // ""' <<<"$status")"
  apply_error="$(jq -r '.apply_error // ""' <<<"$status")"
  sample_error="$(jq -r '.collector_error // ""' <<<"$status")"
  running="$(jq -r '.service_running // false' <<<"$status")"
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
  [ -s "$AGENT_CONFIG_FILE" ] && [ -f "$AGENT_FILE" ] || { err "尚未配置中控。"; return 1; }
  warn "解绑后保留当前已启用用户及统计账本，恢复本机用户编辑；已停用用户不会恢复。"
  confirm_or_cancel "确认主动解绑？输入 y: " n "" || return $?
  agent_service_stop
  if python3 "$AGENT_FILE" --config "$AGENT_CONFIG_FILE" detach >/dev/null; then
    agent_service_disable
    ok "已解绑，当前为单机模式。"
    return 0
  fi
  warn "正常解绑未完成。中控离线时可选择强制本机解绑，未确认的流量仍保留在本机账本。"
  if confirm_or_cancel "强制本机解绑？输入 y（默认取消）: " n ""; then
    python3 "$AGENT_FILE" --config "$AGENT_CONFIG_FILE" detach --force >/dev/null || return 1
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
  acquire_config_lock || return 1
  local running=false
  is_singbox_running && running=true
  jq -c --argjson running "$running" '{
    users:[.users[]? | select(.enabled != false) | {name,uuid,tuic_pass}],
    inbounds:[. as $s | .nodes[]? | {name,tag,type,port,
      server:$s.server_ip, sni:(if (.type | startswith("tuic")) then $s.tuic_sni else $s.reality_sni end),
      public_key:$s.public_key, short_id:$s.short_id, skip_cert_verify:(.type | startswith("tuic"))}],
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
  is_singbox_running || { err "新配置运行健康检查失败，未确认中控版本。"; return 1; }
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
      acquire_config_lock || return 1
      install_wizard
      ;;
    panel)
      panel_menu
      ;;
    upgrade)
      need_root
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
