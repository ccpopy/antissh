#!/bin/bash

# =================================================================================
# Antigravity Server 安装脚本 (交互式版本获取)
# 使用方法: 从 Antigravity 客户端的 "帮助 -> 关于" 复制版本信息并粘贴
# =================================================================================

echo "================================================"
echo "    Antigravity Server 安装脚本"
echo "================================================"
echo ""
echo "请从 Antigravity 客户端复制版本信息:"
echo "  1. 打开 Antigravity 客户端"
echo "  2. 点击 Help -> About"
echo "  3. 点击 'Copy' 按钮"
echo "  4. 在下方粘贴版本信息，然后连续按两次回车:"
echo "------------------------------------------------"

# 读取多行输入，遇到空行结束
version_info=""
while IFS= read -r line; do
    [ -z "$line" ] && break
    version_info+="$line"$'\n'
done

# 解析 Version 和 Commit
# 兼容两种格式:
#   格式A (旧): Antigravity Version: 1.12.4 / Commit: da3eb231fb...
#   格式B (关于对话框): 提交: 1.16.5 / Electron: 1504c8cc4b34...
has_pcre() {
    echo "test" | grep -oP 'test' >/dev/null 2>&1
}

parse_version() {
    local input="$1"
    local result=""
    if has_pcre; then
        # 格式A: Antigravity Version: x.x.x
        result=$(echo "$input" | grep -oP 'Antigravity Version:\s*\K[\d.]+' | head -1)
        # 格式B: 提交: x.x.x ("关于"对话框中 "提交" 字段实际存放版本号)
        [ -z "$result" ] && result=$(echo "$input" | grep -oP '提交:\s*\K[\d.]+' | head -1)
    else
        result=$(echo "$input" | sed -n 's/.*Antigravity Version:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1)
        [ -z "$result" ] && result=$(echo "$input" | sed -n 's/.*提交:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1)
    fi
    echo "$result"
}

parse_commit() {
    local input="$1"
    local result=""
    if has_pcre; then
        # 格式A: Commit: xxxx
        result=$(echo "$input" | grep -oP 'Commit:\s*\K[a-f0-9]+' | head -1)
        # 格式B: Electron: xxxx (长 hex，≥32位，排除 ElectronBuildId)
        [ -z "$result" ] && result=$(echo "$input" | grep -oP '^Electron:\s*\K[a-f0-9]{32,}' | head -1)
    else
        result=$(echo "$input" | sed -n 's/.*Commit:[[:space:]]*\([a-f0-9]*\).*/\1/p' | head -1)
        [ -z "$result" ] && result=$(echo "$input" | sed -n '/^Electron:[[:space:]]*/{ s/^Electron:[[:space:]]*\([a-f0-9]\{32,\}\).*/\1/p; }' | head -1)
    fi
    echo "$result"
}

version=$(parse_version "$version_info")
commitid=$(parse_commit "$version_info")

# 验证解析结果
if [ -z "$version" ] || [ -z "$commitid" ]; then
    echo ""
    echo "[错误] 无法解析版本信息！"
    echo "请确保粘贴的内容包含版本号和 Commit ID。"
    echo ""
    echo "支持以下两种格式:"
    echo ""
    echo "  格式A (旧版):"
    echo "    Antigravity Version: 1.12.4"
    echo "    Commit: da3eb231fb10e6dc27750aa465b8582265c907d9"
    echo ""
    echo "  格式B (帮助-关于-复制):"
    echo "    版本: Antigravity"
    echo "    提交: 1.16.5"
    echo "    ..."
    echo "    Electron: 1504c8cc4b34dbfbb4a97ebe954b3da2b5634516"
    exit 1
fi

echo ""
echo "------------------------------------------------"
echo "[解析成功]"
echo "  版本号:   ${version}"
echo "  Commit:   ${commitid}"
echo "------------------------------------------------"

# 构建安装目录和下载地址
# 根据版本选择 server 根目录名（与 IDE 客户端在远程创建的目录保持一致）
#   Antigravity 1.x  → .antigravity-server
#   Antigravity 2.0+ → .antigravity-ide-server（2.0 起重命名）
version_major="${version%%.*}"
case "$version_major" in
    ''|*[!0-9]*) version_major=0 ;;
esac
if [ "$version_major" -ge 2 ]; then
    SERVER_DIR_NAME=".antigravity-ide-server"
    PRIMARY_ARCHIVE_URL_NAME="Antigravity%20IDE-reh.tar.gz"
    FALLBACK_ARCHIVE_URL_NAME="Antigravity-reh.tar.gz"
else
    SERVER_DIR_NAME=".antigravity-server"
    PRIMARY_ARCHIVE_URL_NAME="Antigravity-reh.tar.gz"
    FALLBACK_ARCHIVE_URL_NAME="Antigravity%20IDE-reh.tar.gz"
fi
SERVER_ROOT="${HOME}/${SERVER_DIR_NAME}"
TARGET_DIR="${SERVER_ROOT}/bin/${version}-${commitid}"
ARCHIVE_FILE="Antigravity-reh.tar.gz"

# 2.0+ 的安装包文件名从 Antigravity-reh.tar.gz 改为 Antigravity IDE-reh.tar.gz。
# URL 中空格必须编码为 %20；同时保留旧文件名和旧路径作为兜底，兼容 1.x/灰度版本/CDN 差异。
DOWNLOAD_URLS=(
    "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${version}-${commitid}/linux-x64/${PRIMARY_ARCHIVE_URL_NAME}"
    "https://redirector.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${version}-${commitid}/linux-x64/${PRIMARY_ARCHIVE_URL_NAME}"
    "https://edgedl.me.gvt1.com/edgedl/antigravity/stable/${version}-${commitid}/linux-x64/${PRIMARY_ARCHIVE_URL_NAME}"
    "https://redirector.gvt1.com/edgedl/antigravity/stable/${version}-${commitid}/linux-x64/${PRIMARY_ARCHIVE_URL_NAME}"
    "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${version}-${commitid}/linux-x64/${FALLBACK_ARCHIVE_URL_NAME}"
    "https://redirector.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${version}-${commitid}/linux-x64/${FALLBACK_ARCHIVE_URL_NAME}"
)

if [ ! -d "$SERVER_ROOT" ]; then
    echo "正在创建 server 根目录: $SERVER_ROOT"
    mkdir -p "$SERVER_ROOT" || { echo "无法创建 server 根目录"; exit 1; }
fi

# 验证下载链接
echo ""
echo "正在验证下载链接..."
DOWNLOAD_URL=""
for url in "${DOWNLOAD_URLS[@]}"; do
    echo "  检查: ${url}"
    if command -v curl >/dev/null 2>&1; then
        HTTP_CODE=$(curl -sIL "$url" -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 20)
        if [ "$HTTP_CODE" = "200" ]; then
            DOWNLOAD_URL="$url"
            break
        fi
        echo "    HTTP ${HTTP_CODE}"
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=10 "$url"; then
            DOWNLOAD_URL="$url"
            break
        fi
        echo "    验证失败"
    else
        echo "[错误] 未找到 wget 或 curl，请先安装其中一个。"
        echo "  Ubuntu/Debian: sudo apt-get install wget"
        echo "  CentOS/RHEL:   sudo yum install wget"
        exit 1
    fi
done

if [ -n "$DOWNLOAD_URL" ]; then
    echo "[✓] 下载链接验证通过"
    echo "命中的下载链接: ${DOWNLOAD_URL}"
else
    echo "⚠️ 未能通过 HEAD/spider 验证下载链接，将继续尝试实际下载。"
    echo "   如果全部失败，请重点检查版本号、Commit ID 或 CDN 是否可访问。"
fi
echo "开始安装"


echo ""
echo "开始安装 Antigravity Server ..."

# 1. 创建目标目录
if [ ! -d "$TARGET_DIR" ]; then
    echo "正在创建目录: $TARGET_DIR"
    mkdir -p "$TARGET_DIR"
fi

cd "$TARGET_DIR" || { echo "无法进入目录"; exit 1; }

# 2. 下载组件包（支持 wget 和 curl 降级）
echo "正在从 Google 镜像源下载组件..."
download_success=0
download_candidates=()
if [ -n "$DOWNLOAD_URL" ]; then
    download_candidates+=("$DOWNLOAD_URL")
fi
for url in "${DOWNLOAD_URLS[@]}"; do
    [ "$url" = "$DOWNLOAD_URL" ] && continue
    download_candidates+=("$url")
done

for url in "${download_candidates[@]}"; do
    echo "尝试下载: ${url}"
    rm -f "$ARCHIVE_FILE"

    if command -v wget >/dev/null 2>&1; then
        if wget -q --show-progress "$url" -O "$ARCHIVE_FILE"; then
            download_success=1
            DOWNLOAD_URL="$url"
            break
        fi
    elif command -v curl >/dev/null 2>&1; then
        echo "wget 不可用，使用 curl 下载..."
        if curl -# -L "$url" -o "$ARCHIVE_FILE"; then
            download_success=1
            DOWNLOAD_URL="$url"
            break
        fi
    else
        echo "[错误] 未找到 wget 或 curl，请先安装其中一个。"
        echo "  Ubuntu/Debian: sudo apt-get install wget"
        echo "  CentOS/RHEL:   sudo yum install wget"
        exit 1
    fi

    echo "下载失败，尝试下一个 URL..."
done

# 检查下载是否成功
if [ "$download_success" -ne 1 ]; then
    echo "错误：下载失败！请检查网络连接、版本号和 Commit ID。"
    exit 1
fi

# 3. 解压并清理
echo "正在解压组件..."
tar -xzf "$ARCHIVE_FILE" --strip-components=1

if [ $? -eq 0 ]; then
    touch 0  # 创建成功标记文件
    rm "$ARCHIVE_FILE"
    echo ""
    echo "================================================"
    echo "  恭喜！安装已完成。"
    echo "  版本: ${version}"
    echo "  Commit: ${commitid}"
    echo "  目录: ${TARGET_DIR}"
    echo "  下载源: ${DOWNLOAD_URL}"
    echo ""
    echo "  请在本地 Antigravity 客户端重新连接 SSH。"
    echo "================================================"
else
    echo "错误：解压失败，文件可能已损坏。"
    exit 1
fi
