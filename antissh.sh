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

PLATFORM=""
PM=""          # 包管理器
SUDO=""        # sudo 命令
PROXY_URL=""   # 代理地址（不含协议前缀，如 127.0.0.1:10808）
PROXY_TYPE=""  # socks5 或 http
GRAFTCP_DIR="${GRAFTCP_DIR:-}" # 保留用户通过环境变量传入的值，空则后续设为 ${REPO_DIR}
GRAFTCP_RUNTIME_MODE="" # merged=v0.8+ 单二进制；legacy=v0.7 graftcp + graftcp-local
GRAFTCP_BIN=""          # 实际用于执行命令的 graftcp 可执行文件
GRAFTCP_LOCAL_BIN=""    # legacy 模式下的 graftcp-local 可执行文件
TARGET_BINS=()  # 需配置代理的 language_server_* 路径列表（兼容多版本共存）
GRAFTCP_LOCAL_PORT=""  # graftcp-local 监听端口（默认 2233）
GRAFTCP_PIPE_PATH=""   # graftcp-local FIFO 路径（多实例支持）
FORCE_SYSTEM_DNS="1"   # 默认强制使用系统 DNS（可选开关）
LAST_PORT_FILE="${INSTALL_ROOT}/last_graftcp_local_port"

# Antigravity 远程 server 根目录名（兼容多版本，按优先级排列）
#   .antigravity-server     ：Antigravity 1.x
#   .antigravity-ide-server ：Antigravity 2.0+（2.0 起重命名）
# 同时存在两者时，后续按 language_server 版本号自动选择最新版本
ANTIGRAVITY_SERVER_DIRS=(".antigravity-server" ".antigravity-ide-server")

################################ 安全设置 ################################

# 设置 umask 确保新建文件权限安全
umask 077

mkdir -p "${INSTALL_ROOT}"
chmod 700 "${INSTALL_ROOT}" 2>/dev/null || true
touch "${INSTALL_LOG}"
chmod 600 "${INSTALL_LOG}" 2>/dev/null || true

# 临时文件清理函数（在脚本退出时调用）
# 用于清理可能残留的临时文件
TEMP_FILES_TO_CLEANUP=()
cleanup_temp_files() {
for tmp_file in "${TEMP_FILES_TO_CLEANUP[@]}"; do
if [ -n "${tmp_file}" ] && [ -f "${tmp_file}" ]; then
rm -f "${tmp_file}" 2>/dev/null || true
fi
done
}
trap cleanup_temp_files EXIT

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

# 预检阶段确认过需要重新备份的目标，setup_wrapper 会据此避免重复询问
declare -A WRAPPER_REBACKUP_ALLOWED=()

################################ 兼容性 Helper 函数 ################################

# 函数名：get_file_mtime
# 功能：获取文件修改时间（epoch 秒）
# 参数：$1 - 文件路径
# 返回：0 成功（输出 epoch 时间戳）/ 1 失败（输出空字符串）
get_file_mtime() {
local file="$1"
# GNU stat
stat -c '%Y' -- "${file}" 2>/dev/null && return 0
# BusyBox stat (输出格式不同，第 12 个字段是 mtime)
local busybox_stat
busybox_stat=$(stat -t -- "${file}" 2>/dev/null) && {
echo "${busybox_stat}" | awk '{print $12}'
return 0
}
# 降级处理：无法获取 mtime 时返回空
echo ""
return 1
}

# 函数名：extract_version_from_language_server_path
# 功能：从 language_server 路径中提取版本号
# 参数：$1 - language_server 文件路径
# 返回：0 成功（输出版本号）/ 1 失败（输出空）
extract_version_from_language_server_path() {
local path="$1"
local version_dir version
version_dir=$(echo "${path}" | sed -n 's|.*/bin/\([^/]*\)/extensions/antigravity/bin/.*|\1|p')
[ -z "${version_dir}" ] && return 1

version="${version_dir%-*}"
[ -z "${version}" ] && version="${version_dir}"

if [[ "${version}" =~ ^[0-9]+([.][0-9]+)*([-.][0-9A-Za-z]+)*$ ]]; then
echo "${version}"
return 0
fi
return 1
}

# 函数名：choose_best_language_server_candidate
# 功能：按版本号优先、mtime 次优先选择 language_server 路径
# 参数：$@ - 候选路径列表
# 返回：0 成功（输出选中的路径）/ 1 失败（输出空）
choose_best_language_server_candidate() {
if [ "$#" -eq 0 ]; then
return 1
fi

local path version mtime has_version
for path in "$@"; do
version=""
has_version=0
if version="$(extract_version_from_language_server_path "${path}" 2>/dev/null)"; then
has_version=1
else
version="0.0.0"
fi
mtime="$(get_file_mtime "${path}" 2>/dev/null || echo 0)"
printf '%s\t%s\t%s\t%s\n' "${has_version}" "${version}" "${mtime}" "${path}"
done | sort -t $'\t' -k1,1n -k2,2V -k3,3n | tail -n 1 | cut -f4-
}

# 函数名：select_best_per_server_dir
# 功能：将候选路径按 server 根目录（ANTIGRAVITY_SERVER_DIRS）分组，每组各选版本
#       最新的一个；无法归类的候选（如自定义目录）合并为一组单独选最新。
#       用于多版本共存（1.x 与 2.0+）时为每个版本各配置一个 wrapper。
# 参数：$@ - 候选路径列表
# 输出：每行一个选中的路径（去重后）
select_best_per_server_dir() {
local -a remaining=("$@")
[ "${#remaining[@]}" -eq 0 ] && return 0

local srv_dir p best
local -a group rest
for srv_dir in "${ANTIGRAVITY_SERVER_DIRS[@]}"; do
group=()
rest=()
for p in "${remaining[@]}"; do
if [[ "${p}" == *"/${srv_dir}/"* ]]; then
group+=("${p}")
else
rest+=("${p}")
fi
done
remaining=("${rest[@]}")
if [ "${#group[@]}" -gt 0 ]; then
best="$(choose_best_language_server_candidate "${group[@]}")"
[ -n "${best}" ] && echo "${best}"
fi
done

# 未归类（自定义目录等）：合并后选最新单个，保持旧的“选最新”行为
if [ "${#remaining[@]}" -gt 0 ]; then
best="$(choose_best_language_server_candidate "${remaining[@]}")"
[ -n "${best}" ] && echo "${best}"
fi
}

# 函数名：language_server_owner_group
# 功能：提取 language_server 所属安装根（通常是用户 HOME），用于跨用户场景避免混选
# 参数：$1 - language_server 文件路径
# 输出：安装根标识；未知路径输出 __custom__
language_server_owner_group() {
local path="$1"
local srv_dir

for srv_dir in "${ANTIGRAVITY_SERVER_DIRS[@]}"; do
if [[ "${path}" == *"/${srv_dir}/"* ]]; then
echo "${path%%/${srv_dir}/*}"
return 0
fi
done

echo "__custom__"
}

# 函数名：select_best_same_owner_group
# 功能：在跨用户候选中先选一个最合适的安装根，再在该安装根内按 server 目录各选最新
#       避免 root/sudo 场景把不同用户的 1.x/2.x 文件混在一起配置。
# 参数：$@ - 候选路径列表
# 输出：每行一个选中的路径
select_best_same_owner_group() {
local -a candidates=("$@")
[ "${#candidates[@]}" -eq 0 ] && return 0

declare -A grouped_paths
declare -A selected_paths
declare -A representative_by_group
local -a group_keys representatives
local p group_key representative best_representative

for p in "${candidates[@]}"; do
group_key="$(language_server_owner_group "${p}")"
if [ -z "${grouped_paths[${group_key}]+x}" ]; then
group_keys+=("${group_key}")
grouped_paths["${group_key}"]="${p}"
else
grouped_paths["${group_key}"]+=$'\n'"${p}"
fi
done

for group_key in "${group_keys[@]}"; do
local -a group_candidates group_selected
mapfile -t group_candidates <<< "${grouped_paths[${group_key}]}"
group_selected=()
while IFS= read -r p; do
[ -n "${p}" ] && group_selected+=("${p}")
done < <(select_best_per_server_dir "${group_candidates[@]}")

[ "${#group_selected[@]}" -eq 0 ] && continue

representative="$(choose_best_language_server_candidate "${group_selected[@]}")"
[ -z "${representative}" ] && continue
representatives+=("${representative}")
representative_by_group["${group_key}"]="${representative}"
selected_paths["${group_key}"]="$(printf '%s\n' "${group_selected[@]}")"
done

[ "${#representatives[@]}" -eq 0 ] && return 0

best_representative="$(choose_best_language_server_candidate "${representatives[@]}")"
for group_key in "${group_keys[@]}"; do
if [ "${representative_by_group[${group_key}]:-}" = "${best_representative}" ]; then
printf '%s\n' "${selected_paths[${group_key}]}"
return 0
fi
done
}

# 函数名：format_date_from_epoch
# 功能：将 epoch 时间戳格式化为人类可读日期
# 参数：$1 - epoch 时间戳
# 返回：0 成功 / 1 失败（输出 "unknown"）
format_date_from_epoch() {
local epoch="$1"
# GNU date
date -d "@${epoch}" '+%F %T %z' 2>/dev/null && return 0
# 降级处理：无法格式化时返回 unknown
echo "unknown"
return 1
}

# 原地编辑文件（兼容不同 sed 实现）
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

# 函数名：safe_mktemp
# 功能：创建安全临时文件
# 参数：$1 - 文件名前缀
# 返回：0 成功（输出临时文件路径）/ 1 失败
# 用法：wrapper_tmp=$(safe_mktemp "${prefix}")
safe_mktemp() {
local prefix="$1"
if command -v mktemp >/dev/null 2>&1; then
mktemp "${prefix}.XXXXXX" && return 0
fi
# 降级处理：mktemp 不可用时的备用方案
local tmp="${prefix}.$$.$RANDOM"
: > "${tmp}" && echo "${tmp}" && return 0
return 1
}

# 函数名：check_port_occupied
# 功能：检查端口是否被占用（不依赖 root 获取 PID）
# 参数：$1 - 端口号
# 返回：0 = 被占用，1 = 未被占用
# 设置变量：PORT_OCCUPIED_BY_GRAFTCP ("true" 或 "false")
PORT_OCCUPIED_BY_GRAFTCP="false"
check_port_occupied() {
local port="$1"
PORT_OCCUPIED_BY_GRAFTCP="false"
local occupied="false"

# ss 不需要 root 就能判断是否占用
# 使用 awk 进行精确端口匹配，避免正则误匹配（如 22 匹配到 2233）
# 支持 IPv4 格式 (如 0.0.0.0:2233) 和 IPv6 格式 (如 [::]:2233)
if command -v ss >/dev/null 2>&1; then
if ss -tln 2>/dev/null | awk -v p="${port}" 'index($4, ":"p) && substr($4, length($4)-length(p)+1) == p {found=1; exit} END {exit !found}'; then
occupied="true"
fi
elif command -v netstat >/dev/null 2>&1; then
if netstat -tln 2>/dev/null | awk -v p="${port}" 'index($4, ":"p) && substr($4, length($4)-length(p)+1) == p {found=1; exit} END {exit !found}'; then
occupied="true"
fi
fi

if [ "${occupied}" = "false" ]; then
return 1
fi

# 检查是否是 graftcp-local 占用了该端口
# 策略：
#   1. 优先匹配带 -listen :PORT 的 graftcp-local
#   2. 仅对默认端口 2233：当存在“无 -listen 参数”的旧版 graftcp-local 时，才认为可复用

local has_any_graftcp="false"
local has_any_listen="false"
local has_listen_port="false"

# 检测 graftcp-local 进程（尽量不依赖 root）
if command -v pgrep >/dev/null 2>&1; then
if pgrep -x "graftcp-local" >/dev/null 2>&1; then
has_any_graftcp="true"
fi
if pgrep -f "graftcp-local.*-listen" >/dev/null 2>&1; then
has_any_listen="true"
has_any_graftcp="true"
fi
if pgrep -f "graftcp-local.*-listen[[:space:]]+:${port}([[:space:]]|$)" >/dev/null 2>&1; then
has_listen_port="true"
fi
else
if ps -ef 2>/dev/null | grep -v grep | grep -Eq '(^|[[:space:]])([^[:space:]]*/)?graftcp-local([[:space:]]|$)'; then
has_any_graftcp="true"
fi
if ps -ef 2>/dev/null | grep -v grep | grep -Eq '(^|[[:space:]])([^[:space:]]*/)?graftcp-local([[:space:]]|$).* -listen'; then
has_any_listen="true"
has_any_graftcp="true"
fi
if ps -ef 2>/dev/null | grep -v grep | grep -Eq "([^[:space:]]*/)?graftcp-local([[:space:]]|$).* -listen[[:space:]]+:${port}([[:space:]]|$)"; then
has_listen_port="true"
fi
fi

# 判断端口是否被 graftcp-local 占用
if [ "${has_listen_port}" = "true" ]; then
PORT_OCCUPIED_BY_GRAFTCP="true"
elif [ "${port}" = "2233" ] && [ "${has_any_graftcp}" = "true" ] && [ "${has_any_listen}" = "false" ]; then
# 默认端口 2233：仅当检测到旧版（无 -listen 参数）graftcp-local 进程时，才认为可复用
PORT_OCCUPIED_BY_GRAFTCP="true"
fi
return 0
}

################################ 日志输出 ################################

# 函数名：log
# 功能：输出信息日志到标准输出和日志文件
# 参数：$* - 日志内容
log() {
echo "[INFO] $*" | tee -a "${INSTALL_LOG}"
}

# 函数名：warn
# 功能：输出警告日志到标准错误和日志文件
# 参数：$* - 警告内容
warn() {
echo "[WARN] $*" | tee -a "${INSTALL_LOG}" >&2
}

# 函数名：error
# 功能：输出错误日志并退出脚本
# 参数：$* - 错误内容
# 返回：不返回，直接 exit 1
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

# 读取上次使用的 graftcp-local 端口
# 返回 0 成功（输出端口号）/ 1 失败
load_last_graftcp_port() {
local port=""

[ -f "${LAST_PORT_FILE}" ] || return 1

port="$(head -n 1 "${LAST_PORT_FILE}" 2>/dev/null | tr -d '[:space:]')"
if ! validate_port "${port}"; then
return 1
fi

echo "${port}"
return 0
}

# 保存本次使用的 graftcp-local 端口
# 参数：$1 - 端口号
save_last_graftcp_port() {
local port="$1"

if ! validate_port "${port}"; then
return 1
fi

printf '%s\n' "${port}" > "${LAST_PORT_FILE}" || return 1
chmod 600 "${LAST_PORT_FILE}" 2>/dev/null || true
return 0
}

# 校验端口是否可用于 graftcp-local
# 参数：$1 - 端口号
# 返回：0 可用或可复用，1 不可用
check_graftcp_port_ready() {
local port="$1"

if ! validate_port "${port}"; then
echo "❌ 错误：端口号必须是 1-65535 的数字"
echo ""
return 1
fi

if check_port_occupied "${port}"; then
if [ "${PORT_OCCUPIED_BY_GRAFTCP}" = "true" ]; then
log "端口 ${port} 已被 graftcp-local 服务占用，将复用现有服务"
return 0
fi
echo ""
echo "❌ 端口 ${port} 已被其他服务占用"
echo "   （提示：非 root 用户可能无法获取占用进程详情）"
echo ""
return 1
fi

log "端口 ${port} 可用"
return 0
}

# 解析代理 URL 并设置全局变量 PROXY_TYPE 和 PROXY_URL
# 输入格式：socks5://HOST:PORT 或 http://HOST:PORT
# 兼容：socks5h:// 会按 socks5:// 处理；https:// 会按 http:// 处理
# 返回 0 表示解析成功，1 表示格式错误
# 错误信息存储在 PARSE_ERROR 变量中
PARSE_ERROR=""

parse_proxy_url() {
local input="$1"
local scheme host port host_port

PARSE_ERROR=""

# 检查是否包含协议前缀
if ! echo "${input}" | grep -Eq '^(socks5h?|https?|http)://'; then
PARSE_ERROR="代理地址必须包含协议前缀（socks5:// 或 http://；兼容 socks5h://、https://）"
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
local last_port=""
local reuse_last=""
local port_input=""

echo ""
echo "============================================="
echo " graftcp-local 端口配置"
echo "============================================="
echo ""
echo "graftcp-local 是代理转发服务，需要监听一个本地端口。"
echo "多用户环境下，建议每个用户使用不同的端口避免冲突。"
echo ""

if last_port="$(load_last_graftcp_port 2>/dev/null)"; then
echo "检测到上次使用端口：${last_port}"
read -r -p "是否复用该端口？ [Y/n]（默认 Y）: " reuse_last
reuse_last="${reuse_last:-Y}"
case "${reuse_last}" in
[Nn]*)
echo "已选择不复用上次端口，将手动输入新端口。"
echo ""
;;
*)
if check_graftcp_port_ready "${last_port}"; then
GRAFTCP_LOCAL_PORT="${last_port}"
else
echo "将改为手动输入端口。"
echo ""
fi
;;
esac
fi

while [ -z "${GRAFTCP_LOCAL_PORT}" ]; do
read -r -p "请输入端口号（默认 ${DEFAULT_PORT}，直接回车使用默认）: " port_input
port_input="${port_input:-${DEFAULT_PORT}}"

if check_graftcp_port_ready "${port_input}"; then
GRAFTCP_LOCAL_PORT="${port_input}"
else
echo "请输入其他端口号"
fi
done

# 设置 FIFO 路径（多实例支持）
GRAFTCP_PIPE_PATH="${INSTALL_ROOT}/graftcp-local-${GRAFTCP_LOCAL_PORT}.fifo"

if ! save_last_graftcp_port "${GRAFTCP_LOCAL_PORT}"; then
warn "写入上次端口记录失败：${LAST_PORT_FILE}"
fi

log "graftcp-local 将使用端口 ${GRAFTCP_LOCAL_PORT}，FIFO 路径：${GRAFTCP_PIPE_PATH}"
}

################################ DNS 解析策略 ################################

# 询问用户是否强制使用系统 DNS
# 设置全局变量 FORCE_SYSTEM_DNS（1=强制，0=不强制）
ask_dns_mode() {
local choice=""

echo ""
echo "============================================="
echo " DNS 解析策略"
echo "============================================="
echo "默认：强制使用系统 DNS（GODEBUG=netdns=cgo）"
echo "说明："
echo "  - 可减少 Go 内置解析在部分网络的异常"
echo "  - 但在特殊网络场景，系统 DNS 可能被限制，导致 google 等域名解析失败"
echo ""
echo "如果你已配置 smartdns/dnscrypt-proxy 等本地 DNS（如将 /etc/resolv.conf 指向 127.0.0.1）"
echo "可选择“不强制”，由你自己的 DNS 方案决定解析结果"
echo "注意：该选项不会自动让 DNS 走代理"
echo ""
echo "请选择："
echo "  - 输入 Y 或直接回车：强制使用系统 DNS（默认）"
echo "  - 输入 N：不强制系统 DNS（交给用户自定义 DNS 方案）"
read -r -p "请选择 [Y/n]（默认 Y）: " choice

choice="${choice:-Y}"
case "${choice}" in
[Nn]*)
FORCE_SYSTEM_DNS="0"
;;
*)
FORCE_SYSTEM_DNS="1"
;;
esac

log "DNS 策略：强制系统 DNS=${FORCE_SYSTEM_DNS}"
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

log "正在快速探测代理可用性...（连接超时 3 秒，总超时 5 秒）"

# 使用 curl 进行轻量级探测
# 尝试访问一个快速响应的地址（目标可能被网络策略阻断；失败不影响后续流程）
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

# 函数名：detect_pkg_manager
# 功能：检测系统使用的包管理器
# 设置变量：PM (“apt”, “dnf”, “yum”, “pacman”, “zypper” 或 空字符串)
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

# 函数名：check_go_version
# 功能：检查 Go 版本是否满足要求（>= 1.13），并处理 toolchain 兼容性
# 设置变量：NEED_GO_COMPAT (“true” 如果需要兼容模式)
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

# 函数名：ensure_dependencies
# 功能：检查并安装编译 graftcp 所需的依赖（git, make, gcc, go, curl）
# 错误处理：依赖安装失败时调用 error() 退出
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

# 声明 install_result 变量（在 case 之前声明，避免 local 重置 PIPESTATUS）
local install_result=0
local pipestatus_arr

case "${PM}" in
apt)
${SUDO} apt-get update | tee -a "${INSTALL_LOG}"
# 安装核心编译依赖 + curl + procps（pgrep/pkill）+ 可选的 net-tools（netstat）
${SUDO} apt-get install -y git make gcc golang-go curl procps net-tools 2>&1 | tee -a "${INSTALL_LOG}"
pipestatus_arr=("${PIPESTATUS[@]}")
install_result="${pipestatus_arr[0]}"
if [ "${install_result}" -ne 0 ]; then
# 回退到不包含 net-tools 的版本
${SUDO} apt-get install -y git make gcc golang-go curl procps 2>&1 | tee -a "${INSTALL_LOG}"
pipestatus_arr=("${PIPESTATUS[@]}")
install_result="${pipestatus_arr[0]}"
fi
;;
dnf)
${SUDO} dnf install -y git make gcc golang curl procps-ng net-tools 2>&1 | tee -a "${INSTALL_LOG}"
pipestatus_arr=("${PIPESTATUS[@]}")
install_result="${pipestatus_arr[0]}"
if [ "${install_result}" -ne 0 ]; then
${SUDO} dnf install -y git make gcc golang curl procps-ng 2>&1 | tee -a "${INSTALL_LOG}"
pipestatus_arr=("${PIPESTATUS[@]}")
install_result="${pipestatus_arr[0]}"
fi
;;
yum)
${SUDO} yum install -y git make gcc golang curl procps-ng net-tools 2>&1 | tee -a "${INSTALL_LOG}"
pipestatus_arr=("${PIPESTATUS[@]}")
install_result="${pipestatus_arr[0]}"
if [ "${install_result}" -ne 0 ]; then
${SUDO} yum install -y git make gcc golang curl procps-ng 2>&1 | tee -a "${INSTALL_LOG}"
pipestatus_arr=("${PIPESTATUS[@]}")
install_result="${pipestatus_arr[0]}"
fi
;;
pacman)
${SUDO} pacman -Sy --noconfirm git base-devel go curl procps-ng net-tools 2>&1 | tee -a "${INSTALL_LOG}"
pipestatus_arr=("${PIPESTATUS[@]}")
install_result="${pipestatus_arr[0]}"
if [ "${install_result}" -ne 0 ]; then
${SUDO} pacman -Sy --noconfirm git base-devel go curl procps-ng 2>&1 | tee -a "${INSTALL_LOG}"
pipestatus_arr=("${PIPESTATUS[@]}")
install_result="${pipestatus_arr[0]}"
fi
;;
zypper)
${SUDO} zypper refresh | tee -a "${INSTALL_LOG}"
${SUDO} zypper install -y git make gcc go curl procps net-tools 2>&1 | tee -a "${INSTALL_LOG}"
pipestatus_arr=("${PIPESTATUS[@]}")
install_result="${pipestatus_arr[0]}"
if [ "${install_result}" -ne 0 ]; then
${SUDO} zypper install -y git make gcc go curl procps 2>&1 | tee -a "${INSTALL_LOG}"
pipestatus_arr=("${PIPESTATUS[@]}")
install_result="${pipestatus_arr[0]}"
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

# 函数名：detect_graftcp_runtime
# 功能：检测 graftcp 目录的官方运行模式
#   - v0.8+：local/graftcp 单二进制，直接带代理参数启动目标命令
#   - v0.7 ：graftcp + local/graftcp-local，需先启动本地转发服务
# 参数：$1 - graftcp 仓库目录
# 设置变量：GRAFTCP_RUNTIME_MODE / GRAFTCP_BIN / GRAFTCP_LOCAL_BIN
detect_graftcp_runtime() {
local dir="$1"

GRAFTCP_RUNTIME_MODE=""
GRAFTCP_BIN=""
GRAFTCP_LOCAL_BIN=""

if [ -x "${dir}/local/graftcp" ]; then
GRAFTCP_RUNTIME_MODE="merged"
GRAFTCP_BIN="${dir}/local/graftcp"
return 0
fi

if [ -x "${dir}/graftcp" ] && [ -x "${dir}/local/graftcp-local" ]; then
GRAFTCP_RUNTIME_MODE="legacy"
GRAFTCP_BIN="${dir}/graftcp"
GRAFTCP_LOCAL_BIN="${dir}/local/graftcp-local"
return 0
fi

return 1
}

# 函数名：describe_graftcp_runtime
# 功能：输出当前 graftcp 运行模式的人类可读描述
describe_graftcp_runtime() {
case "${GRAFTCP_RUNTIME_MODE}" in
merged)
echo "v0.8+ 单二进制模式（local/graftcp）"
;;
legacy)
echo "v0.7 legacy 模式（graftcp + graftcp-local）"
;;
*)
echo "未知模式"
;;
esac
}

# 函数名：install_graftcp
# 功能：安装或编译 graftcp 工具
# 设置变量：GRAFTCP_DIR
# 错误处理：克隆或编译失败时调用 error() 退出
install_graftcp() {
# 检查用户是否通过环境变量指定了 graftcp 目录
if [ -n "${GRAFTCP_DIR:-}" ]; then
log "检测到环境变量 GRAFTCP_DIR=${GRAFTCP_DIR}"
if detect_graftcp_runtime "${GRAFTCP_DIR}"; then
log "验证通过，将使用用户指定的 graftcp 目录，跳过编译"
log "graftcp 运行模式：$(describe_graftcp_runtime)"
return
else
echo ""
echo "❌ 环境变量 GRAFTCP_DIR 指定的目录无效"
echo "   GRAFTCP_DIR=${GRAFTCP_DIR}"
echo ""
echo "   请确保该目录符合以下任一官方版本结构："
echo "     - v0.8+：${GRAFTCP_DIR}/local/graftcp"
echo "     - v0.7 ：${GRAFTCP_DIR}/graftcp 和 ${GRAFTCP_DIR}/local/graftcp-local"
echo ""
error "GRAFTCP_DIR 验证失败，请检查路径是否正确。"
fi
fi

GRAFTCP_DIR="${REPO_DIR}"

if detect_graftcp_runtime "${GRAFTCP_DIR}"; then
log "检测到已安装的 graftcp：${GRAFTCP_DIR}"
log "graftcp 运行模式：$(describe_graftcp_runtime)"
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
# 2. 修正版本号：将 go 1.23.0 这种格式改为 go 1.23
sed_inplace 's/^go \([0-9]\+\.[0-9]\+\)\.[0-9]\+/go \1/' "${gomod}"
log "  已处理 ${gomod}"
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

if ! detect_graftcp_runtime "${GRAFTCP_DIR}"; then
echo ""
echo "❌ 编译完成但未找到可用的 graftcp 可执行文件"
echo ""
echo "已支持的官方产物结构："
echo "  - v0.8+：${GRAFTCP_DIR}/local/graftcp"
echo "  - v0.7 ：${GRAFTCP_DIR}/graftcp 和 ${GRAFTCP_DIR}/local/graftcp-local"
echo ""
error "graftcp 可执行文件缺失。"
fi

log "graftcp 安装/编译完成。"
log "graftcp 运行模式：$(describe_graftcp_runtime)"
}

################################ 查找 language_server_* ################################

# 函数名：find_language_server
# 功能：查找 Antigravity 的 language_server_* 可执行文件
# 设置变量：TARGET_BINS（数组，多版本共存时含多个待配置文件）
# 错误处理：未找到时调用 error() 退出
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
# 兼容多版本 server 目录名：.antigravity-server（1.x）/ .antigravity-ide-server（2.0+）
local search_paths=()
local srv_dir

# 1. 优先当前用户的 server 目录
for srv_dir in "${ANTIGRAVITY_SERVER_DIRS[@]}"; do
search_paths+=("${HOME}/${srv_dir}")
done

# 2. 如果 HOME 不是 /root，也搜索 /root（可能以 sudo 运行）
if [ "${HOME}" != "/root" ]; then
for srv_dir in "${ANTIGRAVITY_SERVER_DIRS[@]}"; do
if [ -d "/root/${srv_dir}" ]; then
search_paths+=("/root/${srv_dir}")
fi
done
fi

# 3. 扫描 /home 下的其他用户目录（WSL 或多用户环境）
if [ -d "/home" ]; then
for user_dir in /home/*; do
# 跳过当前用户（已在步骤 1 处理）
if [ "${user_dir}" = "${HOME}" ]; then
continue
fi
for srv_dir in "${ANTIGRAVITY_SERVER_DIRS[@]}"; do
if [ -d "${user_dir}/${srv_dir}" ]; then
search_paths+=("${user_dir}/${srv_dir}")
fi
done
done
fi

# 4. 用户主目录的其他位置，兜底
local has_known_server_dir="false"
for srv_dir in "${ANTIGRAVITY_SERVER_DIRS[@]}"; do
if [ -d "${HOME}/${srv_dir}" ]; then
has_known_server_dir="true"
break
fi
done
if [ "${has_known_server_dir}" = "false" ]; then
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
echo "（1.x 通常是 ~/.antigravity-server，2.0+ 通常是 ~/.antigravity-ide-server）"
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
    TARGET_BINS=("${candidates[0]}")
    log "找到 Agent 服务：${candidates[0]}"
  else
    log "检测到多个 language_server 文件（${#candidates[@]} 个）"

    # 多用户场景：优先选择当前用户主目录下的文件
    local user_candidates=()
    local other_candidates=()

    for p in "${candidates[@]}"; do
      if [[ "${p}" == "${HOME}/"* ]]; then
        user_candidates+=("${p}")
      else
        other_candidates+=("${p}")
      fi
    done

    # 优先使用当前用户的文件
    if [ "${#user_candidates[@]}" -gt 0 ]; then
      # 兼容多版本共存（1.x / 2.0+）：按 server 目录分组，每组各选最新版本并全部配置
      log "按 server 目录分组选择各自最新版本（兼容多版本共存）..."
      TARGET_BINS=()
      while IFS= read -r p; do
        [ -n "${p}" ] && TARGET_BINS+=("${p}")
      done < <(select_best_per_server_dir "${user_candidates[@]}")
      if [ "${#TARGET_BINS[@]}" -gt 1 ]; then
        log "检测到多个版本共存，将分别为以下 ${#TARGET_BINS[@]} 个文件配置代理："
      fi
      for p in "${TARGET_BINS[@]}"; do
        log "  将配置：${p}"
      done
    else
      # 没有当前用户的文件，检查其他用户的文件是否有权限
      warn "未找到当前用户（${current_user}）的 language_server"
      log "检测到其他用户的文件，正在检查权限..."

      local accessible_candidates=()
      for p in "${other_candidates[@]}"; do
        # 检查是否有读写权限
        if [ -r "${p}" ] && [ -w "$(dirname "${p}")" ]; then
          accessible_candidates+=("${p}")
        fi
      done

      if [ "${#accessible_candidates[@]}" -eq 0 ]; then
        echo ""
        echo "❌ 检测到 ${#other_candidates[@]} 个其他用户的 language_server，但当前用户无权限修改："
        for p in "${other_candidates[@]}"; do
          echo "  - ${p}"
        done
        echo ""
        error "请确保 Antigravity 已安装在当前用户目录（${HOME}/.antigravity-server 或 ${HOME}/.antigravity-ide-server）"
      fi

      # 借用其他用户的文件：先选定同一个安装根，再按 server 目录各选最新。
      # 这样 root/sudo 场景可同时兼容 1.x/2.0+，又避免混配多个用户的文件。
      local chosen_group
      TARGET_BINS=()
      while IFS= read -r p; do
        [ -n "${p}" ] && TARGET_BINS+=("${p}")
      done < <(select_best_same_owner_group "${accessible_candidates[@]}")

      if [ "${#TARGET_BINS[@]}" -gt 0 ]; then
        chosen_group="$(language_server_owner_group "${TARGET_BINS[0]}")"
        warn "将使用其他安装根的文件（请确认这是您期望的行为）：${chosen_group}"
        for p in "${TARGET_BINS[@]}"; do
          warn "  将配置：${p}"
        done
      fi
    fi

    if [ "${#TARGET_BINS[@]}" -eq 0 ]; then
      error "自动选择 Agent 服务失败，请检查文件权限。"
    fi
  fi
}

################################ 写入 wrapper ################################

# Wrapper 脚本的签名标识（可能包含旧的签名）
WRAPPER_SIGNATURE="# 该文件由 antissh.sh 自动生成"
WRAPPER_SIGNATURE_OLD="# 该文件由 antigravity-set.sh 自动生成"

# 检测函数：判断文件是否为 antissh 生成的 wrapper 脚本
is_antissh_wrapper_script() {
local file="$1"
grep -q "${WRAPPER_SIGNATURE}" "${file}" 2>/dev/null || \
grep -q "${WRAPPER_SIGNATURE_OLD}" "${file}" 2>/dev/null
}

# 函数名：preflight_wrapper_targets
# 功能：在写入多个 wrapper 前统一检查权限和备份状态，避免部分写入后失败
# 参数：$@ - 目标 language_server_* 文件路径列表
# 错误处理：发现不可安全写入的目标时调用 error() 退出
preflight_wrapper_targets() {
local target backup dir tmp confirm

[ "$#" -eq 0 ] && error "未找到需要配置的 Agent 服务。"

log "预检 $# 个 wrapper 目标..."
for target in "$@"; do
backup="${target}.bak"
dir="$(dirname "${target}")"

if [ -z "${target}" ] || [ ! -f "${target}" ]; then
error "wrapper 目标不存在或不是普通文件：${target}"
fi

if [ ! -r "${target}" ]; then
error "wrapper 目标不可读：${target}"
fi

if [ ! -d "${dir}" ] || [ ! -w "${dir}" ]; then
error "wrapper 目标目录不可写：${dir}"
fi

tmp="$(safe_mktemp "${target}.preflight")" || error "无法在目标目录创建临时文件：${dir}"
rm -f "${tmp}" 2>/dev/null || error "无法清理预检临时文件：${tmp}"

if [ -f "${backup}" ]; then
if is_antissh_wrapper_script "${target}"; then
log "预检通过：${target} 已是 wrapper，将更新配置"
else
warn "检测到备份与当前文件不一致：${backup} 存在，但 ${target} 不是 wrapper 脚本"
echo ""
echo "可能的原因："
echo "  1. 之前手动恢复过原始文件"
echo "  2. Antigravity 更新后覆盖了 wrapper"
echo ""
echo "当前文件信息："
file "${target}" 2>/dev/null || echo "  无法识别文件类型"
echo ""
echo "备份文件信息："
file "${backup}" 2>/dev/null || echo "  无法识别文件类型"
echo ""
read -r -p "是否将当前文件作为新的原始文件备份？ [y/N]: " confirm
case "${confirm}" in
[Yy]*)
WRAPPER_REBACKUP_ALLOWED["${target}"]=1
;;
*)
echo "操作取消。如需继续，请先手动处理这两个文件："
echo "  ${target}"
echo "  ${backup}"
exit 1
;;
esac
fi
else
if is_antissh_wrapper_script "${target}"; then
error "异常：${target} 是 wrapper 脚本，但备份文件 ${backup} 不存在！请手动检查。"
fi
log "预检通过：${target} 将首次生成 wrapper"
fi
done
}

# 函数名：setup_wrapper
# 功能：备份指定的原始 Agent 并生成代理 wrapper 脚本
# 参数：$1 - 目标 language_server_* 文件路径
# 错误处理：备份或写入失败时调用 error() 退出
setup_wrapper() {
local TARGET_BIN="$1"
local BACKUP_BIN="${TARGET_BIN}.bak"

if [ -f "${BACKUP_BIN}" ]; then
# .bak 文件存在，说明之前执行过脚本
# 需要验证当前的 TARGET_BIN 是否为 wrapper 脚本
if is_antissh_wrapper_script "${TARGET_BIN}"; then
# 当前文件是 wrapper 脚本，直接更新即可
log "检测到已有备份文件：${BACKUP_BIN}"
log "当前文件已是 wrapper 脚本，将更新代理配置"
else
# .bak 已存在但当前文件不是 wrapper：备份与当前可执行文件已不再对应
# 常见原因：手动恢复原始文件 / 升级覆盖 wrapper / 文件被替换
if [ "${WRAPPER_REBACKUP_ALLOWED[${TARGET_BIN}]:-}" != "1" ]; then
warn "检测到备份与当前文件不一致：${BACKUP_BIN} 存在，但 ${TARGET_BIN} 不是 wrapper 脚本"
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
WRAPPER_REBACKUP_ALLOWED["${TARGET_BIN}"]=1
;;
*)
echo "操作取消。如需继续，请先手动处理这两个文件："
echo "  ${TARGET_BIN}"
echo "  ${BACKUP_BIN}"
exit 1
;;
esac
else
log "预检已确认重新备份当前文件：${TARGET_BIN}"
fi
log "将当前文件备份为新的 .bak 文件"
local backup_old
backup_old="${BACKUP_BIN}.old.$(date +%Y%m%d%H%M%S)"
if [ -e "${backup_old}" ]; then
backup_old="${BACKUP_BIN}.old.$$"
fi
mv "${BACKUP_BIN}" "${backup_old}" || error "备份轮转失败：无法移动 ${BACKUP_BIN} -> ${backup_old}"
if ! mv "${TARGET_BIN}" "${BACKUP_BIN}"; then
mv "${backup_old}" "${BACKUP_BIN}" 2>/dev/null || true
error "备份失败：无法移动 ${TARGET_BIN} -> ${BACKUP_BIN}"
fi
fi
else
# .bak 文件不存在
# .bak 不存在但当前文件是 wrapper：说明备份文件丢失或被清理
if is_antissh_wrapper_script "${TARGET_BIN}"; then
error "异常：${TARGET_BIN} 是 wrapper 脚本，但备份文件 ${BACKUP_BIN} 不存在！请手动检查。"
fi

# 正常情况：首次运行，备份原始文件
log "备份原始 Agent 服务到：${BACKUP_BIN}"
mv "${TARGET_BIN}" "${BACKUP_BIN}" || error "备份失败：无法移动 ${TARGET_BIN} -> ${BACKUP_BIN}"
fi

# 生成 wrapper 脚本（先写临时文件，再 mv 覆盖，尽量保证写入原子性）
local wrapper_tmp
wrapper_tmp=$(safe_mktemp "${TARGET_BIN}.tmp") || error "无法创建临时文件"
# 注册临时文件到清理列表，确保脚本异常退出时也能清理
TEMP_FILES_TO_CLEANUP+=("${wrapper_tmp}")

cat > "${wrapper_tmp}" <<EOF
#!/usr/bin/env bash
# 该文件由 antissh.sh 自动生成
# 用 graftcp 代理启动原始 Antigravity Agent

umask 077

GRAFTCP_DIR="${GRAFTCP_DIR}"
GRAFTCP_RUNTIME_MODE="${GRAFTCP_RUNTIME_MODE}"
GRAFTCP_BIN="${GRAFTCP_BIN}"
GRAFTCP_LOCAL_BIN="${GRAFTCP_LOCAL_BIN}"
PROXY_URL="${PROXY_URL}"
PROXY_TYPE="${PROXY_TYPE}"
GRAFTCP_LOCAL_PORT="${GRAFTCP_LOCAL_PORT}"
GRAFTCP_PIPE_PATH="${GRAFTCP_PIPE_PATH}"
ANTISSH_FORCE_SYSTEM_DNS="\${ANTISSH_FORCE_SYSTEM_DNS:-${FORCE_SYSTEM_DNS}}"
LOG_FILE="\$HOME/.graftcp-antigravity/wrapper.log"

mkdir -p "\$(dirname "\$LOG_FILE")"
echo "[\$(date)] Starting wrapper: \$0 \$@" >> "\$LOG_FILE"

if [ "\$GRAFTCP_RUNTIME_MODE" = "legacy" ]; then
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
    nohup "\$GRAFTCP_LOCAL_BIN" -listen ":\$GRAFTCP_LOCAL_PORT" -pipepath "\$GRAFTCP_PIPE_PATH" -http_proxy="\$PROXY_URL" -select_proxy_mode=only_http_proxy >/dev/null 2>&1 &
  else
    nohup "\$GRAFTCP_LOCAL_BIN" -listen ":\$GRAFTCP_LOCAL_PORT" -pipepath "\$GRAFTCP_PIPE_PATH" -socks5="\$PROXY_URL" -select_proxy_mode=only_socks5 >/dev/null 2>&1 &
  fi
  sleep 0.5 2>/dev/null || sleep 1
 fi
fi

# 设置 GODEBUG，保留用户原有值并追加所需配置
# 1. 可选：强制使用系统 DNS（默认开启，可用 ANTISSH_FORCE_SYSTEM_DNS=0 关闭）
# 2. 关闭 HTTP/2 客户端 (解决 EOF 等问题)
# 3. 关闭 TLS 1.3 (避免部分环境握手问题)
DNS_FORCE="\${ANTISSH_FORCE_SYSTEM_DNS:-1}"
DNS_GODEBUG=""
case "\${DNS_FORCE}" in
  0|false|FALSE|no|NO|off|OFF)
    DNS_GODEBUG=""
    ;;
  *)
    DNS_GODEBUG="netdns=cgo"
    ;;
esac

EXTRA_GODEBUG="http2client=0,tls13=0"
if [ -n "\${DNS_GODEBUG}" ]; then
  EXTRA_GODEBUG="\${DNS_GODEBUG},\${EXTRA_GODEBUG}"
fi

if [ -n "\${GODEBUG:-}" ]; then
  export GODEBUG="\${GODEBUG},\${EXTRA_GODEBUG}"
else
  export GODEBUG="\${EXTRA_GODEBUG}"
fi

# 通过 graftcp 启动原始二进制，并清除代理相关环境变量，避免递归代理/死循环
if [ "\$GRAFTCP_RUNTIME_MODE" = "merged" ]; then
  if [ "\$PROXY_TYPE" = "http" ]; then
    exec "\$GRAFTCP_BIN" -http_proxy="\$PROXY_URL" -select_proxy_mode=only_http_proxy env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy "\$0.bak" "\$@"
  else
    exec "\$GRAFTCP_BIN" -socks5="\$PROXY_URL" -select_proxy_mode=only_socks5 env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy "\$0.bak" "\$@"
  fi
else
  exec "\$GRAFTCP_BIN" -p "\$GRAFTCP_LOCAL_PORT" -f "\$GRAFTCP_PIPE_PATH" env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy "\$0.bak" "\$@"
fi
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

################################ 清理残留 language_server 进程 ################################

# 函数名：cleanup_stale_language_servers
# 功能：清理当前用户残留的 language_server 进程，避免复用旧进程
cleanup_stale_language_servers() {
local PROCESS_PATTERN="extensions/antigravity/bin/language_server_"
local current_user pid user cmd
local stale_pids=()

if ! command -v ps >/dev/null 2>&1; then
warn "未找到 ps 命令，跳过残留 language_server 进程清理。"
return 0
fi

current_user="$(whoami)"
log "检查残留 language_server 进程..."

while IFS= read -r pid user cmd; do
[ -z "${pid}" ] && continue
case "${cmd}" in
*"${PROCESS_PATTERN}"*)
[ "${user}" = "${current_user}" ] || continue
stale_pids+=("${pid}")
log "发现残留进程：PID=${pid} 用户=${user} 命令=${cmd}"
;;
esac
done < <(ps -eo pid=,user=,args= 2>/dev/null)

if [ "${#stale_pids[@]}" -eq 0 ]; then
log "未发现当前用户的残留 language_server 进程。"
return 0
fi

for pid in "${stale_pids[@]}"; do
kill "${pid}" 2>/dev/null || warn "发送 SIGTERM 失败：PID=${pid}"
done

wait_for_processes_exit "${stale_pids[@]}"

log "已清理 ${#stale_pids[@]} 个残留 language_server 进程。"
}

# 等待进程退出，超时后发送 SIGKILL
# 参数：$@ - PID 列表
wait_for_processes_exit() {
local MAX_WAIT_ROUNDS=6
local WAIT_INTERVAL_SECONDS="0.5"
local WAIT_FALLBACK_SECONDS=1
local pid wait_count has_alive
local pids=("$@")

[ "${#pids[@]}" -eq 0 ] && return 0

wait_count=0
while [ "${wait_count}" -lt "${MAX_WAIT_ROUNDS}" ]; do
has_alive="false"
for pid in "${pids[@]}"; do
if kill -0 "${pid}" 2>/dev/null; then
has_alive="true"
break
fi
done
[ "${has_alive}" = "false" ] && return 0
sleep "${WAIT_INTERVAL_SECONDS}" 2>/dev/null || sleep "${WAIT_FALLBACK_SECONDS}"
wait_count=$((wait_count + 1))
done

for pid in "${pids[@]}"; do
if kill -0 "${pid}" 2>/dev/null; then
warn "进程未退出，发送 SIGKILL：PID=${pid}"
kill -9 "${pid}" 2>/dev/null || warn "发送 SIGKILL 失败：PID=${pid}"
fi
done
}

# 函数名：cleanup_stale_graftcp_locals
# 功能：清理当前用户旧的 graftcp-local 进程，仅保留当前端口对应实例
# 参数：$1 - 需要保留的 FIFO 路径
cleanup_stale_graftcp_locals() {
local keep_pipe_path="$1"
local PROCESS_PATTERN="graftcp-local"
local PIPE_PREFIX="${INSTALL_ROOT}/graftcp-local-"
local current_user pid user cmd
local stale_pids=()

if ! command -v ps >/dev/null 2>&1; then
warn "未找到 ps 命令，跳过旧 graftcp-local 进程清理。"
return 0
fi

current_user="$(whoami)"
log "检查旧 graftcp-local 进程..."

while IFS= read -r pid user cmd; do
[ -z "${pid}" ] && continue
[ "${user}" = "${current_user}" ] || continue
case "${cmd}" in
*"${PROCESS_PATTERN}"*"-pipepath "*"${PIPE_PREFIX}"*.fifo*)
if [ -n "${keep_pipe_path}" ] && [[ "${cmd}" == *"-pipepath ${keep_pipe_path}"* ]]; then
continue
fi
stale_pids+=("${pid}")
log "发现旧 graftcp-local 进程：PID=${pid} 命令=${cmd}"
;;
esac
done < <(ps -eo pid=,user=,args= 2>/dev/null)

if [ "${#stale_pids[@]}" -eq 0 ]; then
log "未发现需要清理的旧 graftcp-local 进程。"
return 0
fi

for pid in "${stale_pids[@]}"; do
kill "${pid}" 2>/dev/null || warn "发送 SIGTERM 失败：PID=${pid}"
done

wait_for_processes_exit "${stale_pids[@]}"
log "已清理 ${#stale_pids[@]} 个旧 graftcp-local 进程。"
}

################################ 测试代理连通性 ################################

# 函数名：test_proxy
# 功能：测试代理连通性，通过 graftcp 访问 google.com
# 返回：0 成功 / 用户确认继续，非 0 失败及退出
test_proxy() {
echo ""
echo "============================================="
echo " 正在测试代理连通性..."
echo "============================================="

if [ "${GRAFTCP_RUNTIME_MODE}" = "merged" ]; then
log "使用 graftcp v0.8+ 单二进制模式进行测试..."

local http_code="000"
local retry_count=0
local max_retries=3

while [ "${retry_count}" -lt "${max_retries}" ]; do
retry_count=$((retry_count + 1))

if [ "${retry_count}" -gt 1 ]; then
log "第 ${retry_count} 次尝试测试代理..."
sleep 1
fi

if [ "${PROXY_TYPE}" = "http" ]; then
http_code=$("${GRAFTCP_BIN}" -http_proxy="${PROXY_URL}" -select_proxy_mode=only_http_proxy env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy curl -s --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" "https://www.google.com" 2>/dev/null || echo "000")
else
http_code=$("${GRAFTCP_BIN}" -socks5="${PROXY_URL}" -select_proxy_mode=only_socks5 env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy curl -s --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" "https://www.google.com" 2>/dev/null || echo "000")
fi

if [ "${http_code}" = "200" ] || [ "${http_code}" = "301" ] || [ "${http_code}" = "302" ]; then
break
fi
done

if [ "${http_code}" = "200" ] || [ "${http_code}" = "301" ] || [ "${http_code}" = "302" ]; then
echo ""
echo "✅ 代理测试成功！"
echo "   已成功通过代理访问 google.com (HTTP ${http_code})"
echo ""
return 0
fi

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

# 停止现有 graftcp-local：先 SIGTERM，超时后 SIGKILL
log "正在停止旧进程 (PID: ${port_pid})..."

# 先发送 SIGTERM 优雅终止
kill "${port_pid}" 2>/dev/null || true

# 等待进程退出（最多 3 秒）
local wait_count=0
while [ "${wait_count}" -lt 6 ]; do
if ! kill -0 "${port_pid}" 2>/dev/null; then
log "进程已成功终止"
break
fi
# 兼容处理：sleep 0.5 在某些 BusyBox 环境不支持小数秒
sleep 0.5 2>/dev/null || sleep 1
wait_count=$((wait_count + 1))
done

# 如果进程仍在运行，强制终止
if kill -0 "${port_pid}" 2>/dev/null; then
warn "进程未响应 SIGTERM，发送 SIGKILL 强制终止..."
kill -9 "${port_pid}" 2>/dev/null || true
sleep 0.5 2>/dev/null || sleep 1
fi

# 再次确认端口已释放
local port_check_count=0
while [ "${port_check_count}" -lt 4 ]; do
if ! ss -tln 2>/dev/null | grep -q ":${GRAFTCP_LOCAL_PORT} " && \
! netstat -tln 2>/dev/null | grep -q ":${GRAFTCP_LOCAL_PORT} "; then
break
fi
sleep 0.5 2>/dev/null || sleep 1
port_check_count=$((port_check_count + 1))
done

# 用新的代理配置启动 graftcp-local
if [ "${PROXY_TYPE}" = "http" ]; then
"${GRAFTCP_LOCAL_BIN}" -listen ":${GRAFTCP_LOCAL_PORT}" -pipepath "${GRAFTCP_PIPE_PATH}" -http_proxy="${PROXY_URL}" -select_proxy_mode=only_http_proxy &
else
"${GRAFTCP_LOCAL_BIN}" -listen ":${GRAFTCP_LOCAL_PORT}" -pipepath "${GRAFTCP_PIPE_PATH}" -socks5="${PROXY_URL}" -select_proxy_mode=only_socks5 &
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

# 仅按 FIFO 路径匹配停止进程，避免误杀其他实例
if [ -n "${GRAFTCP_PIPE_PATH}" ]; then
pkill -f "${GRAFTCP_PIPE_PATH}" 2>/dev/null || true
fi
# 兼容处理：sleep 0.5 在某些 BusyBox 环境不支持小数秒
sleep 0.5 2>/dev/null || sleep 1

# 启动 graftcp-local
if [ "${PROXY_TYPE}" = "http" ]; then
"${GRAFTCP_LOCAL_BIN}" -listen ":${GRAFTCP_LOCAL_PORT}" -pipepath "${GRAFTCP_PIPE_PATH}" -http_proxy="${PROXY_URL}" -select_proxy_mode=only_http_proxy &
else
"${GRAFTCP_LOCAL_BIN}" -listen ":${GRAFTCP_LOCAL_PORT}" -pipepath "${GRAFTCP_PIPE_PATH}" -socks5="${PROXY_URL}" -select_proxy_mode=only_socks5 &
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

# 通过 graftcp 发起外网请求作为连通性验证（目标为 google.com，可能被网络策略阻断）
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

# 清除代理相关环境变量，避免 curl 走系统代理导致递归代理/死循环
http_code=$("${GRAFTCP_BIN}" -p "${GRAFTCP_LOCAL_PORT}" -f "${GRAFTCP_PIPE_PATH}" env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy curl -s --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" "https://www.google.com" 2>/dev/null || echo "000")

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

# 函数名：main
# 功能：脚本主入口，协调所有配置步骤
main() {
  local target
  echo "==== Antigravity + graftcp 一键配置脚本 ===="
  echo "支持系统：Linux"
  echo "安装日志：${INSTALL_LOG}"
  echo

  check_system
  ask_proxy
  ask_dns_mode

  # 轻量级探测代理可用性，成功则导出代理环境变量供后续 git/curl 使用（可选增益）
  # 探测失败不影响后续流程，继续走镜像下载策略
  probe_and_export_proxy || true

  ensure_dependencies
  install_graftcp
  if [ "${GRAFTCP_RUNTIME_MODE}" = "legacy" ]; then
    ask_graftcp_port
  else
    log "当前 graftcp 为 v0.8+ 单二进制模式，无需配置 graftcp-local 端口。"
  fi
  find_language_server
  preflight_wrapper_targets "${TARGET_BINS[@]}"
  for target in "${TARGET_BINS[@]}"; do
    setup_wrapper "${target}"
  done
  cleanup_stale_language_servers
  if [ "${GRAFTCP_RUNTIME_MODE}" = "legacy" ]; then
    cleanup_stale_graftcp_locals "${GRAFTCP_PIPE_PATH}"
  else
    cleanup_stale_graftcp_locals ""
  fi
  test_proxy

  echo
  echo "=================== 配置完成 🎉 ==================="
  echo "graftcp 安装目录： ${GRAFTCP_DIR}"
  echo "graftcp 运行模式： $(describe_graftcp_runtime)"
  echo "当前代理：         ${PROXY_TYPE}://${PROXY_URL}"
  if [ "${GRAFTCP_RUNTIME_MODE}" = "legacy" ]; then
    echo "graftcp-local 端口: ${GRAFTCP_LOCAL_PORT}"
  fi
  echo
  if [ "${#TARGET_BINS[@]}" -gt 1 ]; then
    echo "已为以下 ${#TARGET_BINS[@]} 个版本分别配置代理 wrapper（多版本共存）："
  else
    echo "已配置代理 wrapper："
  fi
  for target in "${TARGET_BINS[@]}"; do
    echo "  wrapper： ${target}"
    echo "  备份：    ${target}.bak"
  done
  echo
  echo "如需修改代理："
  echo "  1. 直接重新运行本脚本，按提示输入新的代理地址即可。"
  echo "  2. 或手动编辑上面列出的 wrapper 文件，"
  echo "     修改其中的 PROXY_URL 和 PROXY_TYPE 后重启 antigravity。"
  echo
  echo "如需切换 DNS 策略："
  echo "  1. 重新运行本脚本，在“DNS 解析策略”中选择。"
  echo "  2. 或手动编辑上面列出的 wrapper 文件，"
  echo "     将 ANTISSH_FORCE_SYSTEM_DNS 设置为 1（强制）或 0（不强制）。"
  echo
  echo "如需完全恢复原始行为（对每个文件分别执行）："
  for target in "${TARGET_BINS[@]}"; do
    echo "  mv \"${target}.bak\" \"${target}\""
  done
  echo
  echo "安装/编译日志位于：${INSTALL_LOG}"
  echo
  echo "⚠️ 如果是远程连接，请断开并重新连接，即可生效，编码愉快！"
  echo "==================================================="
}

main
