#!/usr/bin/env bash
#
# Antigravity Agent + graftcp 一键配置脚本
# 支持：Linux（macOS 需使用 Proxifier 等替代方案）
# 作用：
#   1. 询问是否需要代理，以及代理地址（格式：socks5://ip:port 或 http://ip:port）
#   2. 自动安装 / 编译 graftcp（Go 项目，使用 Go modules，要求 Go >= 1.13）
#   3. 自动查找 antigravity 的 language_server_* 可执行文件
#   4. 备份原二进制为 .bak，并写入 wrapper
#
# 安装位置：
#   graftcp 安装在：$HOME/.graftcp-antigravity/graftcp
#   安装日志：      $HOME/.graftcp-antigravity/install.log

################################ 基本变量 ################################

INSTALL_ROOT="${HOME}/.graftcp-antigravity"
REPO_DIR="${INSTALL_ROOT}/graftcp"
INSTALL_LOG="${INSTALL_ROOT}/install.log"

mkdir -p "${INSTALL_ROOT}"
touch "${INSTALL_LOG}"

PLATFORM=""
PM=""          # 包管理器
SUDO=""        # sudo 命令
PROXY_URL=""   # 代理地址（不含协议前缀，如 127.0.0.1:10808）
PROXY_TYPE=""  # socks5 或 http
GRAFTCP_DIR="${GRAFTCP_DIR:-}" # 保留用户通过环境变量传入的值，空则后续设为 ${REPO_DIR}
TARGET_BIN=""  # language_server_* 路径
BACKUP_BIN=""  # 备份路径 = ${TARGET_BIN}.bak
GRAFTCP_LOCAL_PORT=""  # graftcp-local 监听端口（默认 2233）
GRAFTCP_PIPE_PATH=""   # graftcp-local FIFO 路径（多实例支持）

################################ 安全设置 ################################

# 设置 umask 确保新建文件权限安全 (600 for files, 700 for dirs)
umask 077

################################ Bash 版本检查 ################################

check_bash_version() {
  local major="${BASH_VERSINFO[0]:-0}"

  if [ "${major}" -lt 4 ]; then
    echo ""
    echo "============================================="
    echo " ❌ Bash 版本过低"
    echo "============================================="
    echo ""
    echo " 当前 Bash 版本：${BASH_VERSION:-unknown}"
    echo " 本脚本要求：Bash >= 4.0"
    echo ""
    echo " 本脚本使用了以下 Bash 4+ 特性："
    echo "   - declare -A（关联数组）"
    echo "   - mapfile（数组读取）"
    echo "   - 进程替换 <(...)"
    echo ""
    echo " 升级建议："
    echo "   Ubuntu/Debian: sudo apt-get install bash"
    echo "   CentOS/RHEL:   sudo yum install bash"
    echo "   从源码编译:    https://www.gnu.org/software/bash/"
    echo ""
    exit 1
  fi
}

# 立即执行 Bash 版本检查
check_bash_version

################################ 兼容性 Helper 函数 ################################

# 获取文件修改时间（epoch 秒）
# 成功返回 epoch，失败返回空字符串
get_file_mtime() {
  local file="$1"
  # GNU stat
  stat -c '%Y' -- "${file}" 2>/dev/null && return 0
  # 降级：返回空
  echo ""
  return 1
}

# 将 epoch 时间戳格式化为人类可读日期
# 失败返回 "unknown"
format_date_from_epoch() {
  local epoch="$1"
  # GNU date
  date -d "@${epoch}" '+%F %T %z' 2>/dev/null && return 0
  # 降级
  echo "unknown"
  return 1
}

# 原地编辑文件（兼容处理）
sed_inplace() {
  local pattern="$1"
  local file="$2"
  if sed -i "${pattern}" "${file}" 2>/dev/null; then
    return 0
  fi
  warn "sed -i 失败，请检查 sed 版本"
  return 1
}

# 安全删除：检查路径非空且在 INSTALL_ROOT 下
safe_rm_rf() {
  local target="$1"
  if [ -z "${target}" ]; then
    warn "safe_rm_rf: 目标路径为空，跳过删除"
    return 1
  fi
  if [ -z "${INSTALL_ROOT}" ]; then
    warn "safe_rm_rf: INSTALL_ROOT 未设置，跳过删除"
    return 1
  fi
  case "${target}" in
    "${INSTALL_ROOT}"|"${INSTALL_ROOT}/"*)
      rm -rf "${target}"
      return $?
      ;;
    *)
      warn "safe_rm_rf: 路径 ${target} 不在 ${INSTALL_ROOT} 下，拒绝删除"
      return 1
      ;;
  esac
}

# 创建安全临时文件
# 用法：wrapper_tmp=$(safe_mktemp "${prefix}")
safe_mktemp() {
  local prefix="$1"
  if command -v mktemp >/dev/null 2>&1; then
    mktemp "${prefix}.XXXXXX" && return 0
  fi
  # fallback
  local tmp="${prefix}.$$.$RANDOM"
  : > "${tmp}" && echo "${tmp}" && return 0
  return 1
}

# 检查端口是否被占用（不依赖 root 获取 PID）
# 返回：0 = 被占用，1 = 未被占用
# 设置变量：PORT_OCCUPIED_BY_GRAFTCP
PORT_OCCUPIED_BY_GRAFTCP="false"
check_port_occupied() {
  local port="$1"
  PORT_OCCUPIED_BY_GRAFTCP="false"
  local occupied="false"

  # ss 不需要 root 就能判断是否占用
  if command -v ss >/dev/null 2>&1; then
    if ss -tln 2>/dev/null | grep -q ":${port} "; then
      occupied="true"
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tln 2>/dev/null | grep -q ":${port} "; then
      occupied="true"
    fi
  fi

  if [ "${occupied}" = "false" ]; then
    return 1
  fi

  # 检查是否是 graftcp-local 占用了该端口
  # 策略：
  #   1. 对于默认端口 2233：如果有任何 graftcp-local 进程在运行，就认定是它占用的
  #      （因为旧版 graftcp-local 不带 -listen 参数，使用默认端口 2233）
  #   2. 对于其他端口：检查是否有带 -listen :PORT 参数的 graftcp-local 进程
  
  local graftcp_running="false"
  local graftcp_with_port="false"
  
  # 检测是否有任何 graftcp-local 进程在运行
  if command -v pgrep >/dev/null 2>&1; then
    if pgrep -f "graftcp-local" >/dev/null 2>&1; then
      graftcp_running="true"
      # 检查是否有指定该端口的进程
      if pgrep -f "graftcp-local.*-listen.*:${port}" >/dev/null 2>&1; then
        graftcp_with_port="true"
      fi
    fi
  else
    # 使用 ps + grep 作为备用
    if ps aux 2>/dev/null | grep -v grep | grep -q "graftcp-local"; then
      graftcp_running="true"
      if ps aux 2>/dev/null | grep -v grep | grep -q "graftcp-local.*-listen.*:${port}"; then
        graftcp_with_port="true"
      fi
    fi
  fi
  
  # 判断端口是否被 graftcp-local 占用
  if [ "${port}" = "2233" ] && [ "${graftcp_running}" = "true" ]; then
    # 默认端口 2233：只要有 graftcp-local 运行就认定是它
    PORT_OCCUPIED_BY_GRAFTCP="true"
  elif [ "${graftcp_with_port}" = "true" ]; then
    # 非默认端口：需要明确匹配 -listen :PORT 参数
    PORT_OCCUPIED_BY_GRAFTCP="true"
  fi
  return 0
}

################################ 日志输出 ################################

log() {
  echo "[INFO] $*" | tee -a "${INSTALL_LOG}"
}

warn() {
  echo "[WARN] $*" | tee -a "${INSTALL_LOG}" >&2
}

error() {
  echo "[ERROR] $*" | tee -a "${INSTALL_LOG}" >&2
  echo "安装失败，可查看日志：${INSTALL_LOG}"
  exit 1
}

################################ 系统检查 ################################

check_linux_version() {
  if [ ! -f /etc/os-release ]; then
    error "无法检测到 Linux 发行版（缺少 /etc/os-release），可能系统版本低，脚本暂不支持。"
  fi

  # shellcheck source=/dev/null
  . /etc/os-release

  case "${ID}" in
    ubuntu)
      major="${VERSION_ID%%.*}"
      if [ "${major}" -lt 16 ]; then
        error "检测到 ${ID} ${VERSION_ID}，版本过低（<16），不在脚本支持范围。"
      fi
      ;;
    debian)
      major="${VERSION_ID%%.*}"
      if [ "${major}" -lt 11 ]; then
        error "检测到 ${ID} ${VERSION_ID}，版本过低（<11），不在脚本支持范围。"
      fi
      ;;
    centos|rhel|rocky|almalinux)
      major="${VERSION_ID%%.*}"
      if [ "${major}" -lt 7 ]; then
        error "检测到 ${ID} ${VERSION_ID}，版本过低（<7），不在脚本支持范围。"
      fi
      ;;
    *)
      warn "检测到发行版 ${ID} ${VERSION_ID}，将尝试执行脚本（如失败请考虑手动配置）。"
      ;;
  esac
}

check_macos_version() {
  # graftcp 官方不支持 macOS，给出替代方案提示
  echo ""
  echo "============================================="
  echo " ⚠️  检测到 macOS 系统"
  echo "============================================="
  echo ""
  echo " graftcp 不支持 macOS，原因：macOS 的 ptrace(2) 功能受限"
  echo ""
  echo " 请使用以下替代方案："
  echo ""
  echo " 1. Proxifier（推荐）"
  echo "    - 官网: https://www.proxifier.com/"
  echo "    - 关于license key，请自行搜索，有特别版序列号，如有能力请支持正版"
  echo "    - 支持按应用配置代理规则"
  echo "    - 设置方法: Proxifier -> Profile -> Proxy Servers -> Add 添加代理服务器"
  echo "      然后在 Rules 中应用程序中添加 com.google.antigravity.helper; com.google.antigravity; Antigravity; language_server_macos_arm; language_server_macos_x64"
  echo ""
  echo " 2. Clash / Surge 等 TUN 模式"
  echo "    - 开启 TUN 模式后可全局透明代理"
  echo ""
  echo " 3. 环境变量，不推荐，Agent 服务无法走代理"
  echo "    export ALL_PROXY=socks5://127.0.0.1:10808"
  echo "    export HTTPS_PROXY=http://127.0.0.1:10809"
  echo ""
  echo "============================================="
  echo ""
  exit 0
}

check_system() {
  os="$(uname -s)"
  case "${os}" in
    Linux)
      PLATFORM="linux"
      check_linux_version
      ;;
    Darwin)
      PLATFORM="macos"
      check_macos_version
      ;;
    *)
      error "当前系统 ${os} 不在支持列表，仅支持 Linux。macOS/Windows 用户请使用 Proxifier 应用或 TUN 模式。"
      ;;
  esac
}

################################ 代理解析与校验 ################################

# 校验 IP 地址格式（每段 0-255）
# 返回 0 表示有效，1 表示无效
validate_ip() {
  local ip="$1"
  local IFS='.'
  local -a octets
  read -ra octets <<< "${ip}"
  
  # 必须是 4 段
  if [ "${#octets[@]}" -ne 4 ]; then
    return 1
  fi
  
  for octet in "${octets[@]}"; do
    # 必须是纯数字
    if ! echo "${octet}" | grep -Eq '^[0-9]+$'; then
      return 1
    fi
    # 范围 0-255
    if [ "${octet}" -lt 0 ] || [ "${octet}" -gt 255 ]; then
      return 1
    fi
  done
  
  return 0
}

# 校验主机名格式
# 返回 0 表示有效，1 表示无效
validate_hostname() {
  local hostname="$1"
  
  # 空字符串无效
  if [ -z "${hostname}" ]; then
    return 1
  fi
  
  # 主机名长度限制（RFC 1035: 最多 255 字符）
  if [ "${#hostname}" -gt 255 ]; then
    return 1
  fi
  
  # 主机名格式校验：
  # - 允许字母、数字、连字符和点
  # - 不能以连字符或点开头/结尾
  # - 每个标签（点分隔的部分）最多 63 字符
  if ! echo "${hostname}" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$'; then
    # 单字符主机名也有效
    if ! echo "${hostname}" | grep -Eq '^[a-zA-Z0-9]$'; then
      return 1
    fi
  fi
  
  # 检查是否包含连续的点
  if echo "${hostname}" | grep -q '\.\.'; then
    return 1
  fi
  
  return 0
}

# 校验端口号（1-65535）
# 返回 0 表示有效，1 表示无效
validate_port() {
  local port="$1"
  
  # 必须是纯数字
  if ! echo "${port}" | grep -Eq '^[0-9]+$'; then
    return 1
  fi
  
  # 范围 1-65535
  if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    return 1
  fi
  
  return 0
}

# 解析代理 URL 并设置全局变量 PROXY_TYPE 和 PROXY_URL
# 输入格式：socks5://127.0.0.1:10808 或 http://127.0.0.1:10809
# 返回 0 表示解析成功，1 表示格式错误
# 错误信息存储在 PARSE_ERROR 变量中
PARSE_ERROR=""

parse_proxy_url() {
  local input="$1"
  local scheme host port host_port
  
  PARSE_ERROR=""
  
  # 检查是否包含协议前缀
  if ! echo "${input}" | grep -Eq '^(socks5h?|https?|http)://'; then
    PARSE_ERROR="代理地址必须以 socks5:// 或 http:// 开头"
    return 1
  fi
  
  # 提取协议
  scheme="${input%%://*}"
  host_port="${input#*://}"
  
  # 校验协议类型
  case "${scheme}" in
    socks5)
      PROXY_TYPE="socks5"
      ;;
    socks5h)
      # socks5h = socks5 with remote DNS resolution
      # graftcp 不支持 socks5h，自动转换为 socks5
      echo "⚠️  检测到 socks5h:// 协议，将自动转换为 socks5://"
      PROXY_TYPE="socks5"
      ;;
    http)
      PROXY_TYPE="http"
      ;;
    https)
      # 警告：graftcp-local 仅支持明文 HTTP 代理（CONNECT 方法），不支持 TLS 加密的代理隧道
      echo ""
      echo "⚠️  检测到 https:// 代理协议"
      echo "   graftcp-local 当前仅支持明文 HTTP 代理（使用 CONNECT 方法）"
      echo "   不支持以 TLS 加密方式连接代理服务器（https:// 代理）"
      echo "   将自动转换为 http:// 处理，如果连接失败，请确认代理服务器支持明文 HTTP 连接"
      echo ""
      PROXY_TYPE="http"
      ;;
    *)
      PARSE_ERROR="仅支持 socks5 或 http 协议，当前输入：${scheme}"
      return 1
      ;;
  esac
  
  # 检查是否包含端口
  if ! echo "${host_port}" | grep -q ':'; then
    PARSE_ERROR="代理地址缺少端口号，正确格式：${scheme}://IP:PORT"
    return 1
  fi
  
  # 提取 IP 和端口
  host="${host_port%%:*}"
  port="${host_port##*:}"
  
  # 移除端口后可能的路径（如 /）
  port="${port%%/*}"
  
  # 校验 IP 地址或主机名
  if ! validate_ip "${host}"; then
    # 也允许 localhost 和合法的主机名
    if [ "${host}" != "localhost" ]; then
      if ! validate_hostname "${host}"; then
        PARSE_ERROR="地址格式无效：${host}（必须是有效的 IP 地址或主机名）"
        return 1
      fi
    fi
  fi
  
  # 校验端口
  if ! validate_port "${port}"; then
    PARSE_ERROR="端口号无效：${port}（必须在 1-65535 之间）"
    return 1
  fi
  
  # 设置代理地址（不含协议前缀）
  PROXY_URL="${host}:${port}"
  
  return 0
}

################################ 从环境变量中检测代理 ################################

ENV_PROXY_RAW=""
ENV_PROXY_SOURCE=""

detect_env_proxy() {
  local var val
  for var in ALL_PROXY all_proxy HTTPS_PROXY https_proxy HTTP_PROXY http_proxy; do
    val="${!var}"
    if [ -n "${val}" ]; then
      ENV_PROXY_RAW="${val}"
      ENV_PROXY_SOURCE="${var}"
      return 0
    fi
  done
  return 1
}

################################ 代理交互 ################################

ask_proxy() {
  echo "============================================="
  echo " 是否需要为 Antigravity Agent 配置代理？"
  echo "   - 输入 Y 或直接回车：配置代理（默认）"
  echo "   - 输入 N：不配置代理，退出脚本"
  echo "============================================="
  read -r -p "请选择 [Y/n] （默认 Y）: " yn

  yn="${yn:-Y}"
  case "${yn}" in
    [Nn]*)
      echo "恭喜，你目前的环境不需要代理，可以愉快的编码了 🎉"
      exit 0
      ;;
    *)
      ;;
  esac

  # 选择了"需要代理"，先检查环境变量里有没有
  if detect_env_proxy; then
    echo
    echo "检测到环境变量 ${ENV_PROXY_SOURCE} 中已配置代理：${ENV_PROXY_RAW}"
    
    # 尝试解析环境变量中的代理
    if parse_proxy_url "${ENV_PROXY_RAW}"; then
      echo "解析结果：类型=${PROXY_TYPE}，地址=${PROXY_URL}"
      read -r -p "是否直接使用该代理？ [Y/n] （默认 Y）: " use_env
      use_env="${use_env:-Y}"
      case "${use_env}" in
        [Nn]*)
          # 用户不需要使用环境变量里的代理，将进入自定义代理设置
          ;;
        *)
          log "将使用环境代理：${PROXY_TYPE}://${PROXY_URL}（来源：${ENV_PROXY_SOURCE}）"
          return
          ;;
      esac
    else
      warn "环境变量中的代理格式无效：${PARSE_ERROR}"
      echo "将进入手动输入..."
    fi
  fi

  # 没有检测到环境代理，或者用户拒绝使用环境代理 → 自定义输入
  echo
  echo "请输入代理地址，格式示例："
  echo "  SOCKS5: socks5://127.0.0.1:10808"
  echo "  HTTP:   http://127.0.0.1:10809"
  echo ""
  echo "直接回车 = 不设置代理，退出脚本"
  
  while true; do
    read -r -p "代理地址: " proxy_input

    if [ -z "${proxy_input}" ]; then
      echo "未设置代理，脚本退出"
      exit 0
    fi

    # 解析并校验代理地址
    if parse_proxy_url "${proxy_input}"; then
      log "代理设置成功：${PROXY_TYPE}://${PROXY_URL}"
      break
    else
      echo "❌ ${PARSE_ERROR}"
      echo "请重新输入正确格式的代理地址"
      echo ""
    fi
  done
}

################################ graftcp-local 端口配置 ################################

# 询问用户配置 graftcp-local 监听端口
# 设置全局变量 GRAFTCP_LOCAL_PORT 和 GRAFTCP_PIPE_PATH
ask_graftcp_port() {
  local DEFAULT_PORT="2233"
  
  echo ""
  echo "============================================="
  echo " graftcp-local 端口配置"
  echo "============================================="
  echo ""
  echo "graftcp-local 是代理转发服务，需要监听一个本地端口。"
  echo "多用户环境下，建议每个用户使用不同的端口避免冲突。"
  echo ""
  
  while true; do
    read -r -p "请输入端口号（默认 ${DEFAULT_PORT}，直接回车使用默认）: " port_input
    
    # 直接回车使用默认端口
    if [ -z "${port_input}" ]; then
      port_input="${DEFAULT_PORT}"
    fi
    
    # 校验是否为数字
    if ! echo "${port_input}" | grep -Eq '^[0-9]+$'; then
      echo "❌ 错误：端口号必须是数字"
      echo ""
      continue
    fi
    
    # 校验端口范围
    if [ "${port_input}" -lt 1 ] || [ "${port_input}" -gt 65535 ]; then
      echo "❌ 错误：端口号必须在 1-65535 之间"
      echo ""
      continue
    fi
    
    # 使用改进的端口检测（不依赖 root 权限获取 PID）
    if check_port_occupied "${port_input}"; then
      # 端口被占用
      if [ "${PORT_OCCUPIED_BY_GRAFTCP}" = "true" ]; then
        log "端口 ${port_input} 已被 graftcp-local 服务占用，将复用现有服务"
        GRAFTCP_LOCAL_PORT="${port_input}"
        break
      else
        echo ""
        echo "❌ 端口 ${port_input} 已被其他服务占用"
        echo "   （提示：非 root 用户可能无法获取占用进程详情）"
        echo ""
        echo "请输入其他端口号"
        continue
      fi
    else
      # 端口未被占用，可以使用
      log "端口 ${port_input} 可用"
      GRAFTCP_LOCAL_PORT="${port_input}"
      break
    fi
  done
  
  # 设置 FIFO 路径（多实例支持）
  GRAFTCP_PIPE_PATH="${INSTALL_ROOT}/graftcp-local-${GRAFTCP_LOCAL_PORT}.fifo"
  
  log "graftcp-local 将使用端口 ${GRAFTCP_LOCAL_PORT}，FIFO 路径：${GRAFTCP_PIPE_PATH}"
}

################################ 轻量级代理可用性探测 ################################

# 快速探测代理是否可用
# 返回 0 表示代理可用，1 表示不可用
# 探测成功时临时导出 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 供 git/curl 使用
PROXY_ENV_EXPORTED="false"

probe_and_export_proxy() {
  local proxy_full_url=""
  
  # 构造完整代理 URL
  if [ "${PROXY_TYPE}" = "socks5" ]; then
    proxy_full_url="socks5://${PROXY_URL}"
  else
    proxy_full_url="http://${PROXY_URL}"
  fi
  
  log "正在快速探测代理可用性...（超时 3 秒）"
  
  # 使用 curl 进行轻量级探测
  # 尝试访问一个快速响应的地址
  local probe_result=1
  
  if [ "${PROXY_TYPE}" = "socks5" ]; then
    # 对于 socks5 代理，使用 --socks5 选项
    if curl -s --socks5 "${PROXY_URL}" --connect-timeout 3 --max-time 5 -o /dev/null -w "%{http_code}" "https://www.google.com" 2>/dev/null | grep -qE '^(200|301|302)$'; then
      probe_result=0
    fi
  else
    # 对于 http 代理，使用 -x 选项
    if curl -s -x "${proxy_full_url}" --connect-timeout 3 --max-time 5 -o /dev/null -w "%{http_code}" "https://www.google.com" 2>/dev/null | grep -qE '^(200|301|302)$'; then
      probe_result=0
    fi
  fi
  
  if [ "${probe_result}" -eq 0 ]; then
    log "代理探测成功，临时导出 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 供后续 git/curl 使用"
    export HTTP_PROXY="${proxy_full_url}"
    export HTTPS_PROXY="${proxy_full_url}"
    export ALL_PROXY="${proxy_full_url}"
    # 同时设置小写版本（某些工具只认小写）
    export http_proxy="${proxy_full_url}"
    export https_proxy="${proxy_full_url}"
    export all_proxy="${proxy_full_url}"
    PROXY_ENV_EXPORTED="true"
    return 0
  else
    log "代理探测失败或超时，将继续使用镜像下载策略，不设置代理环境变量"
    PROXY_ENV_EXPORTED="false"
    return 1
  fi
}

################################ 依赖检查/安装 ################################

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PM="pacman"
  elif command -v zypper >/dev/null 2>&1; then
    PM="zypper"
  else
    PM=""
  fi
}

# 全局变量：是否需要兼容旧版本 Go，兼容模式将移除 toolchain 指令
NEED_GO_COMPAT="false"

check_go_version() {
  if ! command -v go >/dev/null 2>&1; then
    # 缺 go 的情况交给依赖安装逻辑
    return
  fi

  # go version 输出类似：go version go1.22.5 linux/amd64
  gv_raw="$(go version 2>/dev/null | awk '{print $3}')"
  gv="${gv_raw#go}"
  major="${gv%%.*}"
  rest="${gv#*.}"
  minor="${rest%%.*}"

  # graftcp 使用 Go Modules，要求 Go >= 1.13
  if [ "${major}" -lt 1 ] || { [ "${major}" -eq 1 ] && [ "${minor}" -lt 13 ]; }; then
    error "检测到 Go 版本 ${gv_raw}，过低（要求 >= 1.13），请先升级 Go 后重试。"
  fi
  
  log "Go 版本检查通过：${gv_raw}"
  
  # 检查是否需要升级 Go（< 1.21 时 go.mod 的 toolchain 指令不被支持）
  if [ "${major}" -eq 1 ] && [ "${minor}" -lt 21 ]; then
    echo ""
    echo "============================================="
    echo " 检测到 Go 版本：${gv_raw}"
    echo "============================================="
    echo ""
    echo " graftcp 项目使用了 Go 1.21+ 的 toolchain 指令。"
    echo " 当前版本可以通过兼容模式编译，如果兼容模式编译后 graftcp 运行失败，请升级到 Go 1.21+。"
    echo ""
    echo " 升级 Go 的影响："
    echo "   ✓ 更好的性能和安全性"
    echo "   ✓ 原生支持新版 go.mod 语法"
    echo "   ✗ 注意：可能影响系统上依赖旧版 Go 的其他项目！！！"
    echo ""
    echo " 不升级（兼容模式）："
    echo "   ✓ 不影响现有环境"
    echo "   ✓ 自动移除 go.mod 中的 toolchain 指令后编译"
    echo ""
    read -r -p "是否升级 Go 到最新版本？ [y/N]（默认 N，使用兼容模式）: " upgrade_go
    
    case "${upgrade_go}" in
      [Yy]*)
        upgrade_go_version
        ;;
      *)
        log "使用兼容模式，将在编译前移除 toolchain 指令。"
        NEED_GO_COMPAT="true"
        ;;
    esac
  fi
}

# 升级 Go 到最新稳定版
upgrade_go_version() {
  # 设置 SUDO 变量，用于后续需要权限的操作
  local UPGRADE_SUDO=""
  
  # 权限预检查：安装到 /usr/local 始终需要 root/sudo 权限
  if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo ""
      echo "❌ 升级 Go 需要 root 权限，但系统未安装 sudo"
      echo ""
      echo "解决方法："
      echo "  1. 使用 root 用户运行此脚本"
      echo "  2. 或安装 sudo 后重试"
      echo "  3. 或手动升级 Go：https://go.dev/doc/install"
      echo ""
      echo "将使用兼容模式继续（不升级 Go）..."
      NEED_GO_COMPAT="true"
      return
    fi
    # 测试 sudo 是否可用
    if ! sudo -n true 2>/dev/null; then
      echo ""
      echo "⚠️ 升级 Go 需要 sudo 权限"
      echo "   请在接下来的提示中输入密码，或按 Ctrl+C 取消"
      echo ""
      if ! sudo true; then
        echo ""
        echo "❌ 无法获取 sudo 权限，将使用兼容模式继续..."
        NEED_GO_COMPAT="true"
        return
      fi
    fi
    # sudo 验证通过，设置 UPGRADE_SUDO
    UPGRADE_SUDO="sudo"
  fi
  
  log "开始升级 Go..."
  
  # 检测系统架构
  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    armv7l)  arch="armv6l" ;;
    *)       error "不支持的系统架构：$(uname -m)" ;;
  esac
  
  # 获取最新 Go 版本号
  log "获取最新 Go 版本..."
  local latest_version
  latest_version=$(curl -sL "https://go.dev/VERSION?m=text" 2>/dev/null | head -1)
  
  if [ -z "${latest_version}" ]; then
    # 备用方案：使用固定的稳定版本
    latest_version="go1.22.5"
    warn "无法获取最新版本，使用备用版本：${latest_version}"
  fi
  
  log "将安装 Go 版本：${latest_version}"
  
  local go_tar="${latest_version}.linux-${arch}.tar.gz"
  local tmp_dir="${INSTALL_ROOT}/tmp"
  
  mkdir -p "${tmp_dir}"
  
  # 下载 Go，优先使用国内镜像加速
  local download_urls=(
    "https://mirrors.aliyun.com/golang/${go_tar}" # 阿里云镜像
    "https://golang.google.cn/dl/${go_tar}"       # Google 中国镜像
    "https://go.dev/dl/${go_tar}"                 # 官方源
  )
  
  local download_success="false"
  for url in "${download_urls[@]}"; do
    log "尝试下载：${url}"
    if curl -L --connect-timeout 10 --max-time 300 -o "${tmp_dir}/${go_tar}" "${url}" 2>/dev/null; then
      # 验证下载的文件是否有效，检查文件大小是否大于 50MB
      local file_size
      file_size=$(stat -c%s "${tmp_dir}/${go_tar}" 2>/dev/null || wc -c < "${tmp_dir}/${go_tar}" 2>/dev/null || echo "0")
      if [ "${file_size}" -gt 50000000 ]; then
        log "下载成功：${url}"
        download_success="true"
        break
      else
        warn "下载的文件无效，尝试下一个镜像..."
        rm -f "${tmp_dir}/${go_tar}"
      fi
    else
      warn "下载失败，尝试下一个镜像..."
    fi
  done
  
  if [ "${download_success}" != "true" ]; then
    error "所有镜像均下载失败，请检查网络连接。"
  fi
  
  # 备份旧版本
  if [ -d "/usr/local/go" ]; then
    log "备份旧版 Go 到 /usr/local/go.bak..."
    ${UPGRADE_SUDO} rm -rf /usr/local/go.bak 2>/dev/null || true
    ${UPGRADE_SUDO} mv /usr/local/go /usr/local/go.bak
  fi
  
  # 解压新版本
  log "安装 Go 到 /usr/local/go..."
  ${UPGRADE_SUDO} tar -C /usr/local -xzf "${tmp_dir}/${go_tar}"
  
  # 更新 PATH
  if ! echo "${PATH}" | grep -q "/usr/local/go/bin"; then
    export PATH="/usr/local/go/bin:${PATH}"
    log "已临时添加 /usr/local/go/bin 到 PATH"
    echo ""
    echo "⚠️ 提示：请将以下行添加到 ~/.bashrc 或 ~/.profile 以永久生效："
    echo "  export PATH=/usr/local/go/bin:\$PATH"
    echo "  然后执行 source ~/.bashrc 或 source ~/.profile 使配置生效"
    echo ""
  fi
  
  # 清理临时文件
  rm -f "${tmp_dir}/${go_tar}"
  
  # 验证安装
  local new_version
  new_version="$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')"
  log "Go 升级完成：${new_version}"
  
  NEED_GO_COMPAT="false"
}

ensure_dependencies() {
  detect_pkg_manager

  missing=()
  # 核心编译依赖
  for cmd in git make gcc go; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done
  
  # 网络工具依赖
  if ! command -v curl >/dev/null 2>&1; then
    missing+=("curl")
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    log "依赖已满足：git / make / gcc / go / curl"
    check_go_version
    return
  fi

  if [ -z "${PM}" ]; then
    error "缺少依赖 ${missing[*]}，且无法识别包管理器，请手动安装后重试。"
  fi

  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      error "当前用户不是 root，且系统未安装 sudo，无法自动安装依赖：${missing[*]}，请手动安装后重试。"
    fi
  else
    SUDO=""
  fi

  log "缺少依赖：${missing[*]}，使用 ${PM} 自动安装..."

  case "${PM}" in
    apt)
      ${SUDO} apt-get update | tee -a "${INSTALL_LOG}"
      # 安装核心编译依赖 + curl + procps（pgrep/pkill）+ 可选的 net-tools（netstat）
      ${SUDO} apt-get install -y git make gcc golang-go curl procps net-tools 2>&1 | tee -a "${INSTALL_LOG}"
      local install_result="${PIPESTATUS[0]}"
      if [ "${install_result}" -ne 0 ]; then
        # 回退到不包含 net-tools 的版本
        ${SUDO} apt-get install -y git make gcc golang-go curl procps 2>&1 | tee -a "${INSTALL_LOG}"
        install_result="${PIPESTATUS[0]}"
      fi
      ;;
    dnf)
      ${SUDO} dnf install -y git make gcc golang curl procps-ng net-tools 2>&1 | tee -a "${INSTALL_LOG}"
      local install_result="${PIPESTATUS[0]}"
      if [ "${install_result}" -ne 0 ]; then
        ${SUDO} dnf install -y git make gcc golang curl procps-ng 2>&1 | tee -a "${INSTALL_LOG}"
        install_result="${PIPESTATUS[0]}"
      fi
      ;;
    yum)
      ${SUDO} yum install -y git make gcc golang curl procps-ng net-tools 2>&1 | tee -a "${INSTALL_LOG}"
      local install_result="${PIPESTATUS[0]}"
      if [ "${install_result}" -ne 0 ]; then
        ${SUDO} yum install -y git make gcc golang curl procps-ng 2>&1 | tee -a "${INSTALL_LOG}"
        install_result="${PIPESTATUS[0]}"
      fi
      ;;
    pacman)
      ${SUDO} pacman -Sy --noconfirm git base-devel go curl procps-ng net-tools 2>&1 | tee -a "${INSTALL_LOG}"
      local install_result="${PIPESTATUS[0]}"
      if [ "${install_result}" -ne 0 ]; then
        ${SUDO} pacman -Sy --noconfirm git base-devel go curl procps-ng 2>&1 | tee -a "${INSTALL_LOG}"
        install_result="${PIPESTATUS[0]}"
      fi
      ;;
    zypper)
      ${SUDO} zypper refresh | tee -a "${INSTALL_LOG}"
      ${SUDO} zypper install -y git make gcc go curl procps net-tools 2>&1 | tee -a "${INSTALL_LOG}"
      local install_result="${PIPESTATUS[0]}"
      if [ "${install_result}" -ne 0 ]; then
        ${SUDO} zypper install -y git make gcc go curl procps 2>&1 | tee -a "${INSTALL_LOG}"
        install_result="${PIPESTATUS[0]}"
      fi
      ;;
    *)
      error "暂不支持使用 ${PM} 自动安装依赖，请手动安装：${missing[*]}"
      ;;
  esac
  
  # 验证安装是否成功
  if [ "${install_result:-1}" -ne 0 ]; then
    echo ""
    echo "❌ 依赖安装失败"
    echo ""
    echo "请检查以上输出中的错误信息，或手动安装以下依赖后重试："
    echo "  ${missing[*]}"
    echo ""
    echo "详细日志：${INSTALL_LOG}"
    error "依赖安装失败"
  fi

  check_go_version
  log "依赖安装完成。"
}

################################ 安装 / 编译 graftcp ################################

install_graftcp() {
  # 检查用户是否通过环境变量指定了 graftcp 目录
  if [ -n "${GRAFTCP_DIR:-}" ]; then
    log "检测到环境变量 GRAFTCP_DIR=${GRAFTCP_DIR}"
    if [ -x "${GRAFTCP_DIR}/graftcp" ] && [ -x "${GRAFTCP_DIR}/local/graftcp-local" ]; then
      log "验证通过，将使用用户指定的 graftcp 目录，跳过编译"
      return
    else
      echo ""
      echo "❌ 环境变量 GRAFTCP_DIR 指定的目录无效"
      echo "   GRAFTCP_DIR=${GRAFTCP_DIR}"
      echo ""
      echo "   请确保以下文件存在且可执行："
      echo "     - ${GRAFTCP_DIR}/graftcp"
      echo "     - ${GRAFTCP_DIR}/local/graftcp-local"
      echo ""
      error "GRAFTCP_DIR 验证失败，请检查路径是否正确。"
    fi
  fi

  GRAFTCP_DIR="${REPO_DIR}"

  if [ -x "${GRAFTCP_DIR}/graftcp" ] && [ -x "${GRAFTCP_DIR}/local/graftcp-local" ]; then
    log "检测到已安装的 graftcp：${GRAFTCP_DIR}"
    return
  fi

  log "开始安装 graftcp 到：${GRAFTCP_DIR}"
  mkdir -p "${GRAFTCP_DIR}"

  # 检测是否存在不完整的安装（目录存在但没有 .git 或关键文件缺失）
  if [ -d "${GRAFTCP_DIR}" ] && [ ! -d "${GRAFTCP_DIR}/.git" ] && [ "$(ls -A "${GRAFTCP_DIR}" 2>/dev/null)" ]; then
    warn "检测到不完整的安装状态，正在清理..."
    safe_rm_rf "${GRAFTCP_DIR}"
    mkdir -p "${GRAFTCP_DIR}"
  fi

  if [ ! -d "${GRAFTCP_DIR}/.git" ]; then
    log "克隆 graftcp 仓库..."
    
    # 重试逻辑：最多尝试 3 次
    local max_retries=3
    local retry_count=0
    local clone_success="false"
    
    while [ "${retry_count}" -lt "${max_retries}" ]; do
      retry_count=$((retry_count + 1))
      
      if [ "${retry_count}" -gt 1 ]; then
        log "第 ${retry_count} 次尝试克隆...（共 ${max_retries} 次）"
        # 清理可能的残留
        safe_rm_rf "${GRAFTCP_DIR}"
        mkdir -p "${GRAFTCP_DIR}"
        # 等待一段时间后重试
        sleep 2
      fi
      
      # 尝试使用国内镜像加速
      local clone_urls=(
        "https://ghproxy.net/https://github.com/hmgle/graftcp.git"  # 代理镜像
        "https://github.com/hmgle/graftcp.git"          # 官方源
      )
      
      for url in "${clone_urls[@]}"; do
        log "尝试从 ${url} 克隆..."
        # 使用 PIPESTATUS 获取 git clone 的实际返回码，而不是 tee 的返回码
        git clone --depth 1 "${url}" "${GRAFTCP_DIR}" 2>&1 | tee -a "${INSTALL_LOG}"
        local git_exit_code="${PIPESTATUS[0]}"
        if [ "${git_exit_code}" -eq 0 ]; then
          # 验证克隆是否完整
          if [ -d "${GRAFTCP_DIR}/.git" ] && [ -f "${GRAFTCP_DIR}/Makefile" ]; then
            clone_success="true"
            log "仓库克隆成功"
            break 2
          else
            warn "克隆不完整，清理后重试..."
            safe_rm_rf "${GRAFTCP_DIR}"
            mkdir -p "${GRAFTCP_DIR}"
          fi
        else
          warn "从 ${url} 克隆失败 (退出码: ${git_exit_code})"
        fi
      done
    done
    
    if [ "${clone_success}" != "true" ]; then
      error "graftcp 仓库克隆失败（已尝试 ${max_retries} 次），请检查网络连接后重试。"
    fi
  else
    log "检测到已有 graftcp 仓库，尝试更新..."
    # 使用 PIPESTATUS 获取 git pull 的实际返回码
    (cd "${GRAFTCP_DIR}" && git pull --ff-only 2>&1 | tee -a "${INSTALL_LOG}"; exit "${PIPESTATUS[0]}") || warn "graftcp 仓库更新失败，继续使用当前版本。"
  fi

  cd "${GRAFTCP_DIR}" || error "无法进入目录：${GRAFTCP_DIR}"

  # 临时加速 Go 依赖（GOPROXY），仅针对本次 make 生效，不影响全局环境
  if [ -z "${GOPROXY:-}" ]; then
    log "为编译临时设置 GOPROXY=https://goproxy.cn,direct 加速 go 依赖下载（仅本次运行生效）。"
    GOPROXY_ENV="GOPROXY=https://goproxy.cn,direct"
  else
    GOPROXY_ENV=""
  fi

  # 兼容旧版本 Go：删除 go.mod 中的 toolchain 指令
  # 注意：这里修改的是克隆到 ${GRAFTCP_DIR} 的 graftcp 仓库，不是用户的项目
  if [ "${NEED_GO_COMPAT}" = "true" ]; then
    log "兼容模式：移除 ${GRAFTCP_DIR} 中 go.mod 的 toolchain 指令..."
    log "  注：此修改仅影响 graftcp 仓库，不影响您的其他项目"
    for gomod in go.mod local/go.mod; do
      if [ -f "${gomod}" ] && grep -q '^toolchain' "${gomod}"; then
        log "  移除 ${gomod} 中的 toolchain 行"
        sed_inplace '/^toolchain/d' "${gomod}"
      fi
    done
  fi

  # 检查并转换不兼容的代理协议
  # 不清除环境变量，而是转换为兼容格式，保持用户代理配置的意图
  local proxy_vars=("ALL_PROXY" "all_proxy" "HTTPS_PROXY" "https_proxy" "HTTP_PROXY" "http_proxy")
  local proxy_fixed="false"
  for var in "${proxy_vars[@]}"; do
    local val="${!var:-}"
    if [ -n "${val}" ]; then
      # 检查是否包含不兼容协议
      if echo "${val}" | grep -Eq '^socks5h://'; then
        # 转换 socks5h -> socks5
        local new_val="${val/socks5h:\/\//socks5:\/\/}"
        export "${var}=${new_val}"
        if [ "${proxy_fixed}" = "false" ]; then
          log "检测到环境变量使用 socks5h:// 协议（Go 不支持），已临时转换为 socks5://"
          proxy_fixed="true"
        fi
      fi
    fi
  done

  log "开始编译 graftcp（日志写入：${INSTALL_LOG}）..."
  
  # 编译重试逻辑
  local make_retries=2
  local make_count=0
  local make_success="false"
  
  while [ "${make_count}" -lt "${make_retries}" ]; do
    make_count=$((make_count + 1))
    
    if [ "${make_count}" -gt 1 ]; then
      log "第 ${make_count} 次尝试编译...（共 ${make_retries} 次）"
      # 清理之前的编译产物
      make clean >> "${INSTALL_LOG}" 2>&1 || true
      sleep 1
    fi
    
    if env ${GOPROXY_ENV} make >> "${INSTALL_LOG}" 2>&1; then
      make_success="true"
      break
    else
      warn "编译失败，正在分析原因..."
      
      # 检查常见错误
      if tail -20 "${INSTALL_LOG}" | grep -q "go: module download"; then
        warn "Go 模块下载失败，可能是网络问题"
      elif tail -20 "${INSTALL_LOG}" | grep -q "toolchain"; then
        warn "检测到 toolchain 相关错误，尝试移除..."
        for gomod in go.mod local/go.mod; do
          if [ -f "${gomod}" ]; then
            sed_inplace '/^toolchain/d' "${gomod}" || true
          fi
        done
      elif tail -20 "${INSTALL_LOG}" | grep -q "permission denied"; then
        warn "权限不足"
      fi
    fi
  done
  
  if [ "${make_success}" != "true" ]; then
    echo ""
    echo "❌ graftcp 编译失败（已尝试 ${make_retries} 次）"
    echo ""
    echo "可能原因："
    echo "  1. Go 依赖下载失败（网络问题）"
    echo "  2. Go 版本过低或不兼容"
    echo "  3. 缺少编译工具（gcc/make）"
    echo ""
    echo "===================== 手动安装指引 ====================="
    echo ""
    echo "方法 1：在本机手动编译"
    echo "  1. 根据上述原因排查并解决问题（如升级 Go、配置网络代理等）"
    echo "  2. 手动执行编译："
    echo "     cd ${REPO_DIR} && make"
    echo "  3. 编译成功后设置环境变量并重新运行脚本："
    echo "     export GRAFTCP_DIR=${REPO_DIR}"
    echo "     bash $0"
    echo ""
    echo "方法 2：在其他机器编译后拷贝"
    echo "  1. 在可正常编译的机器上执行："
    echo "     git clone https://github.com/hmgle/graftcp.git 或加速地址：git clone https://ghproxy.net/https://github.com/hmgle/graftcp.git"
    echo "     cd graftcp && make"
    echo "  2. 将整个 graftcp 目录拷贝到本机"
    echo "  3. 设置环境变量后重新运行脚本："
    echo "     export GRAFTCP_DIR=/path/to/graftcp"
    echo "     bash $0"
    echo ""
    echo "=========================================================="
    echo ""
    echo "排查建议："
    echo "  - 检查网络，确保能访问 github.com 或 goproxy.cn"
    echo "  - 升级 Go 到 1.21+：https://go.dev/doc/install"
    echo "  - 查看详细日志：${INSTALL_LOG}"
    echo ""
    # 显示日志最后几行帮助诊断
    echo "日志最后 10 行："
    tail -10 "${INSTALL_LOG}" 2>/dev/null || true
    echo ""
    error "编译失败，请根据上述提示排查问题。"
  fi

  if [ ! -x "${GRAFTCP_DIR}/graftcp" ] || [ ! -x "${GRAFTCP_DIR}/local/graftcp-local" ]; then
    error "编译完成但未找到 graftcp 或 graftcp-local，可执行文件缺失。"
  fi

  log "graftcp 安装/编译完成。"
}

################################ 查找 language_server_* ################################

find_language_server() {
  local pattern base current_user
  pattern="language_server_linux_"
  
  # 获取当前用户名
  current_user="$(whoami)"
  
  log "当前用户：${current_user}"
  log "用户目录：${HOME}"
  log "开始查找 *${pattern}* ..."

  candidates=()
  
  # 构建搜索路径列表（按优先级排序）
  local search_paths=()
  
  # 1. 优先当前用户的 .antigravity-server 目录
  search_paths+=("${HOME}/.antigravity-server")
  
  # 2. 如果 HOME 不是 /root，也搜索 /root（可能以 sudo 运行）
  if [ "${HOME}" != "/root" ] && [ -d "/root/.antigravity-server" ]; then
    search_paths+=("/root/.antigravity-server")
  fi
  
  # 3. 扫描 /home 下的其他用户目录（WSL 或多用户环境）
  if [ -d "/home" ]; then
    for user_dir in /home/*; do
      if [ -d "${user_dir}/.antigravity-server" ]; then
        # 跳过已添加的路径
        if [ "${user_dir}" != "${HOME}" ]; then
          search_paths+=("${user_dir}/.antigravity-server")
        fi
      fi
    done
  fi
  
  # 4. 用户主目录的其他位置，兜底
  if [ ! -d "${HOME}/.antigravity-server" ]; then
    search_paths+=("${HOME}")
  fi
  
  # 用于去重的关联数组
  declare -A seen_paths
  
  # 遍历搜索路径
  for base in "${search_paths[@]}"; do
    if [ -d "${base}" ]; then
      log "搜索目录：${base}"
      while IFS= read -r path; do
        # 跳过 .bak 备份文件（之前脚本运行时创建的备份）
        if [[ "${path}" == *.bak ]]; then
          continue
        fi
        # 去重：检查是否已经添加过
        if [ -z "${seen_paths[${path}]:-}" ]; then
          seen_paths["${path}"]=1
          candidates+=("${path}")
          log "  找到：${path}"
        fi
      done < <(find "${base}" -maxdepth 10 -type f -path "*extensions/antigravity/bin/${pattern}*" 2>/dev/null)
    fi
  done

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo ""
    echo "未在以下位置找到 language_server_* 文件："
    for base in "${search_paths[@]}"; do
      echo "  - ${base}"
    done
    echo ""
    echo "请手动输入 antigravity 安装目录"
    echo "（通常是 ~/.antigravity-server 或 /home/用户名/.antigravity-server）"
    read -r -p "目录路径，不输入直接回车则放弃: " base
    if [ -z "${base}" ] || [ ! -d "${base}" ]; then
      error "未找到 Agent 文件，请确认 antigravity 安装路径后重试。"
    fi

    log "搜索用户指定目录：${base}"
    while IFS= read -r path; do
      candidates+=("${path}")
    done < <(find "${base}" -maxdepth 10 -type f -path "*extensions/antigravity/bin/${pattern}*" 2>/dev/null)
  fi

  if [ "${#candidates[@]}" -eq 0 ]; then
    error "仍然没有找到 language_server_* 可执行文件，请检查 antigravity 安装。"
  fi

  if [ "${#candidates[@]}" -eq 1 ]; then
    TARGET_BIN="${candidates[0]}"
    log "找到 Agent 服务：${TARGET_BIN}"
  else
    local -a sorted_lines=()
    local -a sorted_candidates=()
    local -a sorted_mtimes=()

    # 按文件修改时间排序（从新到旧）
    mapfile -t sorted_lines < <(
      for p in "${candidates[@]}"; do
        local epoch
        epoch="$(get_file_mtime "${p}")"
        printf '%s\t%s\n' "${epoch}" "${p}"
      done | sort -rn -k1,1 -k2,2
    )

    for line in "${sorted_lines[@]}"; do
      local epoch p mtime
      IFS=$'\t' read -r epoch p <<< "${line}"

      if [ -n "${epoch}" ] && echo "${epoch}" | grep -Eq '^[0-9]+$'; then
        mtime="$(format_date_from_epoch "${epoch}")"
      else
        mtime="unknown"  # 无法获取 mtime，降级显示
      fi

      sorted_candidates+=("${p}")
      sorted_mtimes+=("${mtime}")
    done

    candidates=("${sorted_candidates[@]}")

    echo "检测到多个 language_server 可执行文件，请选择要代理的一个："
    local i=1
    for p in "${candidates[@]}"; do
      echo "  [$i] ${sorted_mtimes[$((i-1))]}  ${p}"
      i=$((i+1))
    done
    read -r -p "请输入序号（默认 1）: " idx
    idx="${idx:-1}"
    if ! echo "${idx}" | grep -Eq '^[0-9]+$'; then
      error "输入无效：${idx}"
    fi
    if [ "${idx}" -lt 1 ] || [ "${idx}" -gt "${#candidates[@]}" ]; then
      error "输入序号超出范围。"
    fi
    TARGET_BIN="${candidates[$((idx-1))]}"
    log "已选择 Agent 服务：${TARGET_BIN}"
  fi
}

################################ 写入 wrapper ################################

setup_wrapper() {
  BACKUP_BIN="${TARGET_BIN}.bak"
  
  # Wrapper 脚本的签名标识
  local WRAPPER_SIGNATURE="# 该文件由 antissh.sh 自动生成"

  if [ -f "${BACKUP_BIN}" ]; then
    # .bak 文件存在，说明之前执行过脚本
    # 需要验证当前的 TARGET_BIN 是否为 wrapper 脚本
    if grep -q "${WRAPPER_SIGNATURE}" "${TARGET_BIN}" 2>/dev/null; then
      # 当前文件是 wrapper 脚本，直接更新即可
      log "检测到已有备份文件：${BACKUP_BIN}"
      log "当前文件已是 wrapper 脚本，将更新代理配置"
    else
      # 当前文件不是 wrapper 脚本，但 .bak 已存在
      # 这是异常情况，可能是手动恢复过或其他问题
      warn "检测到异常情况：${BACKUP_BIN} 存在，但 ${TARGET_BIN} 不是 wrapper 脚本"
      echo ""
      echo "可能的原因："
      echo "  1. 之前手动恢复过原始文件"
      echo "  2. Antigravity 更新后覆盖了 wrapper"
      echo ""
      echo "当前文件信息："
      file "${TARGET_BIN}" 2>/dev/null || echo "  无法识别文件类型"
      echo ""
      echo "备份文件信息："
      file "${BACKUP_BIN}" 2>/dev/null || echo "  无法识别文件类型"
      echo ""
      read -r -p "是否将当前文件作为新的原始文件备份？ [y/N]: " confirm
      case "${confirm}" in
        [Yy]*)
          log "将当前文件备份为新的 .bak 文件"
          mv "${BACKUP_BIN}" "${BACKUP_BIN}.old" || true
          mv "${TARGET_BIN}" "${BACKUP_BIN}" || error "备份失败"
          ;;
        *)
          echo "操作取消。如需继续，请先手动处理这两个文件："
          echo "  ${TARGET_BIN}"
          echo "  ${BACKUP_BIN}"
          exit 1
          ;;
      esac
    fi
  else
    # .bak 文件不存在
    # 检查当前文件是否为 wrapper（防止意外情况）
    if grep -q "${WRAPPER_SIGNATURE}" "${TARGET_BIN}" 2>/dev/null; then
      error "异常：${TARGET_BIN} 是 wrapper 脚本，但备份文件 ${BACKUP_BIN} 不存在！请手动检查。"
    fi
    
    # 正常情况：首次运行，备份原始文件
    log "备份原始 Agent 服务到：${BACKUP_BIN}"
    mv "${TARGET_BIN}" "${BACKUP_BIN}" || error "备份失败：无法移动 ${TARGET_BIN} -> ${BACKUP_BIN}"
  fi

  # 生成 wrapper 脚本（使用原子写入：先写临时文件，再移动到目标位置）
  local wrapper_tmp
  wrapper_tmp=$(safe_mktemp "${TARGET_BIN}.tmp") || error "无法创建临时文件"
  
  cat > "${wrapper_tmp}" <<EOF
#!/usr/bin/env bash
# 该文件由 antissh.sh 自动生成
# 用 graftcp 代理启动原始 Antigravity Agent

GRAFTCP_DIR="${GRAFTCP_DIR}"
PROXY_URL="${PROXY_URL}"
PROXY_TYPE="${PROXY_TYPE}"
GRAFTCP_LOCAL_PORT="${GRAFTCP_LOCAL_PORT}"
GRAFTCP_PIPE_PATH="${GRAFTCP_PIPE_PATH}"
LOG_FILE="\$HOME/.graftcp-antigravity/wrapper.log"

mkdir -p "\$(dirname "\$LOG_FILE")"
echo "[\$(date)] Starting wrapper: \$0 \$@" >> "\$LOG_FILE"

# 检查指定 FIFO 路径的 graftcp-local 是否已在运行
graftcp_running="false"
if command -v pgrep >/dev/null 2>&1; then
  if pgrep -f "\$GRAFTCP_PIPE_PATH" >/dev/null 2>&1; then
    graftcp_running="true"
  fi
else
  if ps aux | grep -v grep | grep -q "\$GRAFTCP_PIPE_PATH"; then
    graftcp_running="true"
  fi
fi

if [ "\$graftcp_running" = "false" ]; then
  echo "[\$(date)] Starting graftcp-local on port \$GRAFTCP_LOCAL_PORT with \$PROXY_TYPE proxy \$PROXY_URL" >> "\$LOG_FILE"
  if [ "\$PROXY_TYPE" = "http" ]; then
    nohup "\$GRAFTCP_DIR/local/graftcp-local" -listen ":\$GRAFTCP_LOCAL_PORT" -pipepath "\$GRAFTCP_PIPE_PATH" -http_proxy="\$PROXY_URL" -select_proxy_mode=only_http_proxy >/dev/null 2>&1 &
  else
    nohup "\$GRAFTCP_DIR/local/graftcp-local" -listen ":\$GRAFTCP_LOCAL_PORT" -pipepath "\$GRAFTCP_PIPE_PATH" -socks5="\$PROXY_URL" -select_proxy_mode=only_socks5 >/dev/null 2>&1 &
  fi
  sleep 0.5
fi

# 设置 GODEBUG，保留用户原有值并追加所需配置
# 1. 强制使用系统 DNS (解决解析问题)
# 2. 关闭 HTTP/2 客户端 (解决 EOF 等问题)
if [ -n "\${GODEBUG:-}" ]; then
  export GODEBUG="\$GODEBUG,netdns=cgo,http2client=0,tls13=0"
else
  export GODEBUG="netdns=cgo,http2client=0,tls13=0"
fi

# 使用 graftcp 启动备份的原始 Agent 服务（指定端口和 FIFO 路径）
exec "\$GRAFTCP_DIR/graftcp" -p "\$GRAFTCP_LOCAL_PORT" -f "\$GRAFTCP_PIPE_PATH" "\$0.bak" "\$@"
EOF

  # 设置执行权限
  if ! chmod +x "${wrapper_tmp}"; then
    rm -f "${wrapper_tmp}"
    error "无法为 wrapper 添加执行权限"
  fi
  
  # 原子移动到目标位置
  if ! mv "${wrapper_tmp}" "${TARGET_BIN}"; then
    rm -f "${wrapper_tmp}"
    # 尝试恢复备份
    if [ -f "${BACKUP_BIN}" ]; then
      warn "wrapper 写入失败，尝试恢复备份..."
      mv "${BACKUP_BIN}" "${TARGET_BIN}" 2>/dev/null || true
    fi
    error "wrapper 写入失败：无法移动临时文件到 ${TARGET_BIN}"
  fi
  
  log "已生成代理 wrapper：${TARGET_BIN}"
}

################################ 测试代理连通性 ################################

test_proxy() {
  echo ""
  echo "============================================="
  echo " 正在测试代理连通性..."
  echo "============================================="

  # 使用全局变量 GRAFTCP_LOCAL_PORT（在 ask_graftcp_port 中设置）
  # 确保变量已设置
  if [ -z "${GRAFTCP_LOCAL_PORT}" ]; then
    GRAFTCP_LOCAL_PORT="2233"
    GRAFTCP_PIPE_PATH="${INSTALL_ROOT}/graftcp-local-2233.fifo"
  fi
  
  # 初始化变量：是否需要在测试结束后关闭 graftcp-local
  local need_kill_graftcp_local="false"
  local graftcp_local_pid=""

  # 检查端口是否被占用
  local port_in_use="false"
  local port_pid=""
  local port_process=""

  if command -v ss >/dev/null 2>&1; then
    port_pid=$(ss -tlnp 2>/dev/null | grep ":${GRAFTCP_LOCAL_PORT} " | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)
  elif command -v netstat >/dev/null 2>&1; then
    port_pid=$(netstat -tlnp 2>/dev/null | grep ":${GRAFTCP_LOCAL_PORT} " | awk '{print $7}' | cut -d'/' -f1 | head -1)
  fi

  if [ -n "${port_pid}" ]; then
    port_in_use="true"
    port_process=$(ps -p "${port_pid}" -o comm= 2>/dev/null || echo "unknown")
  fi

  # 如果端口被占用，检查是否是 graftcp-local 服务
  if [ "${port_in_use}" = "true" ]; then
    log "检测到端口 ${GRAFTCP_LOCAL_PORT} 已被占用 (PID: ${port_pid}, 进程: ${port_process})"

    # 检查是否是 graftcp-local 进程
    local is_graftcp_local="false"
    if [ "${port_process}" = "graftcp-local" ]; then
      is_graftcp_local="true"
    elif ps -p "${port_pid}" -o args= 2>/dev/null | grep -q "graftcp-local"; then
      is_graftcp_local="true"
    fi

    if [ "${is_graftcp_local}" = "true" ]; then
      # 已有 graftcp-local 在运行，但可能使用的是旧的代理配置
      # 需要停止旧服务，用新的代理配置重启
      log "端口 ${GRAFTCP_LOCAL_PORT} 已被 graftcp-local 服务占用"
      log "将停止现有服务并使用新的代理配置重启..."
      
      # 停止现有的 graftcp-local
      kill "${port_pid}" 2>/dev/null || true
      sleep 0.5
      
      # 用新的代理配置启动 graftcp-local
      if [ "${PROXY_TYPE}" = "http" ]; then
        "${GRAFTCP_DIR}/local/graftcp-local" -listen ":${GRAFTCP_LOCAL_PORT}" -pipepath "${GRAFTCP_PIPE_PATH}" -http_proxy="${PROXY_URL}" -select_proxy_mode=only_http_proxy &
      else
        "${GRAFTCP_DIR}/local/graftcp-local" -listen ":${GRAFTCP_LOCAL_PORT}" -pipepath "${GRAFTCP_PIPE_PATH}" -socks5="${PROXY_URL}" -select_proxy_mode=only_socks5 &
      fi
      graftcp_local_pid=$!
      need_kill_graftcp_local="true"
      sleep 1
      
      # 检查 graftcp-local 是否成功启动
      if ! kill -0 "${graftcp_local_pid}" 2>/dev/null; then
        warn "graftcp-local 重启失败"
        echo ""
        echo "❌ 代理测试失败：graftcp-local 无法重启"
        echo ""
        exit 1
      fi
    else
      echo ""
      echo "❌ 代理测试失败：端口 ${GRAFTCP_LOCAL_PORT} 被其他进程占用"
      echo ""
      echo "占用信息："
      echo "  端口：${GRAFTCP_LOCAL_PORT}"
      echo "  PID：${port_pid}"
      echo "  进程：${port_process}"
      echo ""
      echo "解决方法："
      echo "  1. 停止占用该端口的进程：kill ${port_pid}"
      echo "  2. 或修改 graftcp-local 的监听端口（需手动配置）"
      echo ""
      exit 1
    fi
  else
    # 端口未被占用，启动 graftcp-local
    log "启动 graftcp-local 进行测试..."

    # 停止可能存在的旧进程
    pkill -f "${GRAFTCP_DIR}/local/graftcp-local" 2>/dev/null || true
    sleep 0.5

    # 启动 graftcp-local
    if [ "${PROXY_TYPE}" = "http" ]; then
      "${GRAFTCP_DIR}/local/graftcp-local" -listen ":${GRAFTCP_LOCAL_PORT}" -pipepath "${GRAFTCP_PIPE_PATH}" -http_proxy="${PROXY_URL}" -select_proxy_mode=only_http_proxy &
    else
      "${GRAFTCP_DIR}/local/graftcp-local" -listen ":${GRAFTCP_LOCAL_PORT}" -pipepath "${GRAFTCP_PIPE_PATH}" -socks5="${PROXY_URL}" -select_proxy_mode=only_socks5 &
    fi
    graftcp_local_pid=$!
    need_kill_graftcp_local="true"
    sleep 1

    # 检查 graftcp-local 是否成功启动
    if ! kill -0 "${graftcp_local_pid}" 2>/dev/null; then
      warn "graftcp-local 启动失败"
      echo ""
      echo "❌ 代理测试失败：graftcp-local 无法启动"
      echo ""
      echo "可能原因："
      echo "  1. graftcp 编译有问题"
      echo "  2. 系统权限不足"
      echo ""
      echo "如需调整，请重新执行脚本。"
      exit 1
    fi
  fi
  
  # 使用 graftcp 测试访问 google.com
  log "测试通过代理访问 google.com..."
  
  # 等待 graftcp-local 完全初始化并与代理建立连接
  sleep 2
  
  # 获取 HTTP 状态码（带重试逻辑）
  local http_code="000"
  local retry_count=0
  local max_retries=3
  
  while [ "${retry_count}" -lt "${max_retries}" ]; do
    retry_count=$((retry_count + 1))
    
    if [ "${retry_count}" -gt 1 ]; then
      log "第 ${retry_count} 次尝试测试代理..."
      sleep 1
    fi
    
    http_code=$("${GRAFTCP_DIR}/graftcp" -p "${GRAFTCP_LOCAL_PORT}" -f "${GRAFTCP_PIPE_PATH}" curl -s --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" "https://www.google.com" 2>/dev/null || echo "000")
    
    # 如果成功，跳出循环
    if [ "${http_code}" = "200" ] || [ "${http_code}" = "301" ] || [ "${http_code}" = "302" ]; then
      break
    fi
  done
  
  # 只有当我们启动了 graftcp-local 时才停止它
  if [ "${need_kill_graftcp_local:-}" = "true" ]; then
    kill "${graftcp_local_pid}" 2>/dev/null || true
  fi
  
  # 判断测试结果
  if [ "${http_code}" = "200" ] || [ "${http_code}" = "301" ] || [ "${http_code}" = "302" ]; then
    echo ""
    echo "✅ 代理测试成功！"
    echo "   已成功通过代理访问 google.com (HTTP ${http_code})"
    echo ""
    return 0
  else
    echo ""
    echo "⚠️ 代理测试失败"
    echo "   无法通过代理访问 google.com (HTTP ${http_code})"
    echo ""
    echo "可能原因："
    echo "  1. 代理服务器未启动或不可用"
    echo "  2. 代理地址配置错误：${PROXY_TYPE}://${PROXY_URL}"
    echo "  3. 代理服务器无法访问外网"
    echo "  4. 测试时网络波动或超时"
    echo "  5. 代理服务器限制访问 google.com"
    echo ""
    echo "============================================="
    echo " 是否仍然继续完成配置？"
    echo "   - 如果确定代理是可用的，只是测试存在问题，可以选择继续"
    echo "   - 如果代理确实不可用，或者代理配置错误，建议选择退出并检查代理设置"
    echo "============================================="
    read -r -p "继续配置？ [y/N]（默认 N，退出）: " continue_choice
    
    case "${continue_choice}" in
      [Yy]*)
        echo ""
        echo "⚠️ 用户选择忽略测试结果，继续配置..."
        echo "   如果实际使用中代理不生效，请重新检查代理设置。"
        echo ""
        return 0
        ;;
      *)
        echo ""
        echo "配置已取消。如需调整代理配置，请重新执行脚本。"
        exit 1
        ;;
    esac
  fi
}

################################ 主流程 ################################

main() {
  echo "==== Antigravity + graftcp 一键配置脚本 ===="
  echo "支持系统：Linux"
  echo "安装日志：${INSTALL_LOG}"
  echo

  check_system
  ask_proxy
  ask_graftcp_port
  
  # 轻量级探测代理可用性，成功则导出代理环境变量供后续 git/curl 使用（可选增益）
  # 探测失败不影响后续流程，继续走镜像下载策略
  probe_and_export_proxy || true
  
  ensure_dependencies
  install_graftcp
  find_language_server
  setup_wrapper
  test_proxy

  echo
  echo "=================== 配置完成 🎉 ==================="
  echo "graftcp 安装目录： ${GRAFTCP_DIR}"
  echo "Agent 备份文件：   ${BACKUP_BIN}"
  echo "当前代理：         ${PROXY_TYPE}://${PROXY_URL}"
  echo "graftcp-local 端口: ${GRAFTCP_LOCAL_PORT}"
  echo
  echo "如需修改代理："
  echo "  1. 直接重新运行本脚本，按提示输入新的代理地址即可。"
  echo "  2. 或手动编辑 wrapper 文件："
  echo "       ${TARGET_BIN}"
  echo "     修改其中的 PROXY_URL 和 PROXY_TYPE 后重启 antigravity。"
  echo
  echo "如需完全恢复原始行为："
  echo "  mv \"${BACKUP_BIN}\" \"${TARGET_BIN}\""
  echo
  echo "安装/编译日志位于：${INSTALL_LOG}"
  echo
  echo "⚠️ 如果是远程连接，请断开并重新连接，即可生效，编码愉快！"
  echo "==================================================="
}

main
