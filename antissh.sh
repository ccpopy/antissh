#!/usr/bin/env bash
# graftcp wrapper for the Antigravity IDE Linux/WSL hub.
set -euo pipefail
umask 077

TARGET="${HOME}/.gemini/bin/agy"
# Preserve the existing backup path so installations made by antiagy.sh remain recoverable.
BACKUP="${TARGET}.antiagy-original"
MARKER="# Managed by antissh.sh (agy hub)"
LEGACY_MARKER="# Managed by antiagy.sh (experimental)"
GRAFTCP=""
PROXY_TYPE=""
PROXY_ADDRESS=""

fail() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：
  bash antissh.sh check   socks5://127.0.0.1:10808
  bash antissh.sh install socks5://127.0.0.1:10808
  bash antissh.sh status
  bash antissh.sh restore

代理支持 socks5://主机:端口 或 http://主机:端口；不支持用户名密码。
仅用于 Linux/WSL 中由 Antigravity IDE 管理的 ~/.gemini/bin/agy。
EOF
}

require_linux() {
  [[ "$(uname -s)" == Linux ]] || fail "本脚本只支持 Linux/WSL；Windows 上请使用 Proxifier。"
}

is_wrapper() {
  local marker
  [[ -f "$1" ]] || return 1
  [[ "$(od -An -tx1 -N2 "$1" | tr -d '[:space:]')" == 2321 ]] || return 1
  marker="$(sed -n '2p' "$1")"
  [[ "$marker" == "$MARKER" || "$marker" == "$LEGACY_MARKER" ]]
}

is_elf() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  [[ "$(od -An -tx1 -N4 "$1" | tr -d '[:space:]')" == 7f454c46 ]]
}

binary_version() {
  local output
  output="$(timeout 15 "$1" --version 2>&1)" || return 1
  [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[0]}"
}

validate_binary() {
  local version
  is_elf "$1" || fail "不是原生 Linux ELF 可执行文件：$1"
  [[ -x "$1" ]] || fail "文件不可执行：$1"
  version="$(binary_version "$1")" || fail "无法从 agy --version 读取版本：$1"
  printf '%s\n' "$version"
}

target_state() {
  [[ -f "$TARGET" ]] || fail "未找到 $TARGET；请先在 Linux/WSL 中打开一次 IDE Agent。"
  [[ ! -L "$TARGET" && ! -L "$BACKUP" ]] || fail "目标或备份是符号链接，请先手动检查。"
  if is_wrapper "$TARGET"; then
    [[ -f "$BACKUP" ]] || fail "发现 antissh wrapper，但原始文件备份不存在：$BACKUP"
    validate_binary "$BACKUP" >/dev/null
    printf '%s\n' wrapper
  elif is_elf "$TARGET"; then
    validate_binary "$TARGET" >/dev/null
    if [[ -e "$BACKUP" ]]; then
      validate_binary "$BACKUP" >/dev/null
      printf '%s\n' updated
    else
      printf '%s\n' native
    fi
  else
    fail "目标不是原生 agy，也不是本脚本的 wrapper：$TARGET"
  fi
}

hub_running() {
  # After installation, Linux reports the backup's name (truncated to 15 bytes)
  # as the process name, rather than "agy".
  ps -ww -u "$(id -u)" -o comm=,args= | awk \
    '($1 == "agy" || $1 ~ /^agy\.antiagy-/) && /(^|[[:space:]])--hub([[:space:]=]|$)/ { found=1 } END { exit !found }'
}

parse_proxy() {
  local raw="$1" port
  [[ "$raw" =~ ^(socks5|http)://([A-Za-z0-9._-]+):([0-9]{1,5})$ ]] ||
    fail "代理格式应为 socks5://主机:端口 或 http://主机:端口"
  PROXY_TYPE="${BASH_REMATCH[1]}"
  port="${BASH_REMATCH[3]}"
  (( 10#$port >= 1 && 10#$port <= 65535 )) || fail "代理端口超出范围：$port"
  PROXY_ADDRESS="${BASH_REMATCH[2]}:$port"
}

find_graftcp() {
  local candidate help
  if [[ -n "${GRAFTCP_BIN:-}" ]]; then
    candidate="$GRAFTCP_BIN"
  elif [[ -x "${HOME}/.graftcp-antigravity/graftcp/local/graftcp" ]]; then
    candidate="${HOME}/.graftcp-antigravity/graftcp/local/graftcp"
  elif [[ -x "${HOME}/.graftcp-antigravity/graftcp/local/mgraftcp" ]]; then
    candidate="${HOME}/.graftcp-antigravity/graftcp/local/mgraftcp"
  else
    candidate="$(command -v graftcp || true)"
  fi
  [[ -n "$candidate" && -x "$candidate" ]] || fail \
    "未找到支持单进程代理参数的 graftcp。请先按 README 编译，或设置 GRAFTCP_BIN=完整路径。"
  help="$("$candidate" --help 2>&1 || true)"
  [[ "$help" == *select_proxy_mode* && "$help" == *--socks5* ]] ||
    fail "graftcp 缺少 --socks5 或 --select_proxy_mode 参数：$candidate"
  GRAFTCP="$candidate"
}

proxy_args() {
  if [[ "$PROXY_TYPE" == socks5 ]]; then
    PROXY_ARGS=("--socks5=$PROXY_ADDRESS" --select_proxy_mode=only_socks5)
  else
    PROXY_ARGS=("--http_proxy=$PROXY_ADDRESS" --select_proxy_mode=only_http_proxy)
  fi
}

check_proxy() {
  local code
  command -v curl >/dev/null || fail "缺少 curl，无法进行代理连通性校验。"
  proxy_args
  code="$("$GRAFTCP" "${PROXY_ARGS[@]}" env \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u http_proxy -u https_proxy -u all_proxy \
    curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 8 --max-time 15 \
    https://oauth2.googleapis.com/token 2>/dev/null)" ||
    fail "无法通过 graftcp 和指定代理连接 oauth2.googleapis.com。"
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] || fail "代理探测未收到 HTTP 响应（$code）。"
  printf '代理连通性校验通过（HTTP %s）。\n' "$code"
}

status() {
  local state original
  state="$(target_state)"
  original="$TARGET"
  [[ "$state" == wrapper ]] && original="$BACKUP"
  printf '目标：%s\n状态：%s\n原始 agy 版本：%s\n' \
    "$TARGET" "$state" "$(binary_version "$original")"
  [[ "$state" != updated ]] || printf '检测到 IDE 更新覆盖了 wrapper；重新 install 前会保留旧备份。\n'
  if hub_running; then
    printf '检测到运行中的 agy --hub。\n'
  fi
}

write_wrapper() {
  local destination="$1" quoted_graftcp quoted_backup quoted_proxy quoted_type
  printf -v quoted_graftcp '%q' "$GRAFTCP"
  printf -v quoted_backup '%q' "$BACKUP"
  printf -v quoted_proxy '%q' "$PROXY_ADDRESS"
  printf -v quoted_type '%q' "$PROXY_TYPE"
  cat > "$destination" <<EOF
#!/usr/bin/env bash
$MARKER
set -e
GRAFTCP_BIN=$quoted_graftcp
ORIGINAL_BIN=$quoted_backup
PROXY_ADDRESS=$quoted_proxy
PROXY_TYPE=$quoted_type

# IDE startup checks the binary version; no network is needed for that check.
if [[ "\${1:-}" == --version ]]; then
  exec "\$ORIGINAL_BIN" "\$@"
fi

# graftcp ignores localhost by default, preserving the IDE's loopback hub.
if [[ "\$PROXY_TYPE" == socks5 ]]; then
  proxy_args=("--socks5=\$PROXY_ADDRESS" --select_proxy_mode=only_socks5)
else
  proxy_args=("--http_proxy=\$PROXY_ADDRESS" --select_proxy_mode=only_http_proxy)
fi
exec "\$GRAFTCP_BIN" "\${proxy_args[@]}" env \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  -u http_proxy -u https_proxy -u all_proxy \
  "\$ORIGINAL_BIN" "\$@"
EOF
  chmod 700 "$destination"
}

install_wrapper() {
  local state version checksum temp original previous="" rotated="" backup_moved=0
  state="$(target_state)"
  hub_running && fail "agy --hub 正在运行；请先关闭对应的 IDE 远程窗口。"
  original="$TARGET"
  [[ "$state" == wrapper ]] && original="$BACKUP"
  version="$(binary_version "$original")"
  checksum="$(sha256sum "$original" | awk '{print $1}')"

  temp="$(mktemp "${TARGET}.antiagy-tmp.XXXXXX")"
  write_wrapper "$temp"
  if [[ "$state" == wrapper ]]; then
    previous="$(mktemp "${TARGET}.antiagy-prev.XXXXXX")"
    cp -p "$TARGET" "$previous"
  else
    if [[ "$state" == updated ]]; then
      rotated="${BACKUP}.previous.$(date -u +%Y%m%dT%H%M%SZ).$$"
      mv "$BACKUP" "$rotated"
    fi
    if ! mv "$TARGET" "$BACKUP"; then
      [[ -z "$rotated" ]] || mv "$rotated" "$BACKUP"
      rm -f "$temp"
      fail "无法备份原始 agy。"
    fi
    backup_moved=1
    if [[ "$(sha256sum "$BACKUP" | awk '{print $1}')" != "$checksum" ]]; then
      mv "$BACKUP" "$TARGET"
      [[ -z "$rotated" ]] || mv "$rotated" "$BACKUP"
      rm -f "$temp"
      fail "备份校验失败，原始 agy 已恢复。"
    fi
  fi

  if ! mv -f "$temp" "$TARGET"; then
    if (( backup_moved )); then
      mv "$BACKUP" "$TARGET"
      [[ -z "$rotated" ]] || mv "$rotated" "$BACKUP"
    fi
    [[ -z "$previous" ]] || rm -f "$previous"
    fail "无法写入 wrapper。"
  fi
  if [[ "$(binary_version "$TARGET" || true)" != "$version" ]]; then
    if (( backup_moved )); then
      mv -f "$BACKUP" "$TARGET"
      [[ -z "$rotated" ]] || mv "$rotated" "$BACKUP"
    else
      mv -f "$previous" "$TARGET"
    fi
    fail "wrapper 版本校验失败，已回滚。"
  fi
  [[ -z "$previous" ]] || rm -f "$previous"
  printf '已安装代理 wrapper：%s\n原始二进制备份：%s\n' "$TARGET" "$BACKUP"
  [[ -z "$rotated" ]] || printf '上一个版本的备份：%s\n' "$rotated"
  printf '请重新连接 IDE 远程窗口；更新 agy 后可重运行本脚本。\n'
}

restore_wrapper() {
  local temp
  [[ -f "$TARGET" ]] || fail "未找到目标文件：$TARGET"
  is_wrapper "$TARGET" || fail "当前目标不是 antissh wrapper，不会覆盖它。"
  validate_binary "$BACKUP" >/dev/null
  hub_running && fail "agy --hub 正在运行；请先关闭对应的 IDE 远程窗口。"
  temp="$(mktemp "${TARGET}.antiagy-restore.XXXXXX")"
  mv "$TARGET" "$temp"
  if ! mv "$BACKUP" "$TARGET"; then
    mv "$temp" "$TARGET"
    fail "恢复失败，wrapper 已放回原位。"
  fi
  rm -f "$temp"
  printf '已恢复原始 agy：%s\n' "$TARGET"
}

main() {
  local command="${1:-}"
  require_linux
  case "$command" in
    status)
      [[ $# -eq 1 ]] || fail "status 不接受其他参数。"
      status
      ;;
    restore)
      [[ $# -eq 1 ]] || fail "restore 不接受其他参数。"
      restore_wrapper
      ;;
    check|install)
      [[ $# -eq 2 ]] || { usage; exit 2; }
      parse_proxy "$2"
      status
      find_graftcp
      check_proxy
      [[ "$command" != install ]] || install_wrapper
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
