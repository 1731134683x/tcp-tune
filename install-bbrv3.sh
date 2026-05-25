#!/bin/bash
# ============================================================
# BBRv3 内核安装脚本 v3.0 (Ubuntu/Debian)
# ============================================================
#  上游:
#    byjoey  — byJoey/Actions-bbr-v3 (GitHub Actions 预编译)
#    xdflight — XDflight/bbr3-debs (更频繁更新, kernel 7.0.8+)
#
#  功能:
#   1. 检测是否已安装 BBRv3 内核
#   2. 检测系统架构 (x86_64 / arm64)
#   3. 拉取最新 (或指定) 预编译内核 .deb 并安装
#   4. 更新 GRUB
#
#  用法:
#   sudo bash install-bbrv3.sh                     # 交互选择上游 + 安装最新版
#   sudo bash install-bbrv3.sh --source xdflight   # 指定 XDflight 上游
#   sudo bash install-bbrv3.sh --tag x86_64-7.0.3  # 安装指定版本
# ============================================================

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
ask()   { echo -e "${YELLOW}[?]${NC} $*"; }

SOURCE="byjoey"      # 默认上游: byjoey | xdflight
SOURCE_EXPLICIT=false  # 用户是否通过 --source 显式指定
REPO=""
API_BASE=""
GIT_HASH=""          # byJoey 的编译 CI 在同一 commit 上构建了所有 release
SOURCE_ARCH_TAG=""   # 用于 tag 过滤的架构标识 (byJoey=x86_64, XDflight=amd64)
MANUAL_TAG=""        # --tag 指定的版本
ARCH_TAG=""
ARCH_DEB=""
LATEST_TAG=""
DEB_URLS=""

# ---- Root 检查 ----
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请使用 root 运行: sudo bash $0"
        exit 1
    fi
}

# ---- OS 检查 ----
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        err "无法读取 /etc/os-release"
        exit 1
    fi
    source /etc/os-release
    case "$ID" in
        ubuntu|debian) ok "系统: $NAME $VERSION_ID" ;;
        *) err "仅支持 Ubuntu / Debian。"  ; exit 1 ;;
    esac
}

# ---- 检测架构 ----
detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64)   ARCH_TAG="x86_64" ; ARCH_DEB="amd64" ;;
        aarch64)  ARCH_TAG="arm64"  ; ARCH_DEB="arm64"  ;;
        *)
            err "不支持的架构: $machine"
            exit 1
            ;;
    esac
    info "架构: $machine → 标签前缀 ${ARCH_TAG}, deb 后缀 ${ARCH_DEB}"
}

# ---- 根据上游设置 REPO / 哈希 / 架构标签 ----
setup_source() {
    case "$SOURCE" in
        byjoey)
            REPO="byJoey/Actions-bbr-v3"
            GIT_HASH="g90210de4b779"
            SOURCE_ARCH_TAG="$ARCH_TAG"   # x86_64 或 arm64
            ;;
        xdflight)
            REPO="XDflight/bbr3-debs"
            GIT_HASH=""
            SOURCE_ARCH_TAG="$ARCH_DEB"   # amd64 或 arm64
            ;;
        *)
            err "未知上游: $SOURCE (支持: byjoey, xdflight)"
            exit 1
            ;;
    esac
    API_BASE="https://api.github.com/repos/${REPO}"
    info "上游: ${REPO}"
}

# ---- 检查当前内核 BBR 状态 ----
check_current_bbr() {
    local kver
    kver=$(uname -r)

    if echo "$kver" | grep -qE "bbr3|joeyblog"; then
        ok "已安装 BBRv3 内核: $kver"
        ok "无需再次安装。"
        exit 0
    fi

    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
    local available
    available=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk '{print $3}')

    info "当前内核: $kver"

    if echo "$available" | grep -q bbr; then
        info "当前内核已支持 BBR (算法: $available)"
        info "注意: 主线 BBR ≠ Google BBRv3。"
        echo ""
        ask "是否仍要安装 BBRv3 内核? [y/N]: "
        read -r ans < /dev/tty
        [[ "$ans" != "y" && "$ans" != "Y" ]] && { info "已取消。"; exit 0; }
    else
        warn "当前内核无 BBR 支持 (算法: ${available:-无})"
        echo ""
        ask "是否安装 BBRv3 内核? (需要重启) [Y/n]: "
        read -r ans < /dev/tty
        [[ "$ans" == "n" || "$ans" == "N" ]] && { info "已取消。"; exit 0; }
    fi
}

# ---- JSON 解析: 从 API 返回的 JSON 中提取 .deb 下载链接 ----
#   优先使用 jq，不可用时回退到 grep
parse_deb_urls() {
    local json="$1"
    local urls

    if command -v jq &>/dev/null; then
        urls=$(echo "$json" | jq -r \
            '.assets[]?.browser_download_url // empty | select(endswith(".deb") and (contains("dbg") | not))' \
            2>/dev/null || true)
    else
        urls=$(echo "$json" \
            | grep -oP '"browser_download_url":\s*"\K[^"]+\.deb' \
            | grep -v 'dbg' || true)
    fi

    echo "$urls"
}

# ---- JSON 解析: 从 releases 列表中提取匹配架构的 tag 名 ----
parse_latest_tag() {
    local json="$1"

    if [[ "$SOURCE" == "xdflight" ]]; then
        if command -v jq &>/dev/null; then
            echo "$json" | jq -r \
                ".[]?.tag_name // empty | select(startswith(\"linux-\") and contains(\"-bbr3-${SOURCE_ARCH_TAG}\"))" \
                2>/dev/null | sort -V | tail -1 || true
        else
            echo "$json" \
                | grep -oP '"tag_name":\s*"\Klinux-[^-]+-bbr3-'"${SOURCE_ARCH_TAG}"'[^"]*' \
                | sort -V | tail -1 || true
        fi
    else
        # byjoey: tag 格式 x86_64-7.0.5
        if command -v jq &>/dev/null; then
            echo "$json" | jq -r \
                ".[]?.tag_name // empty | select(startswith(\"${SOURCE_ARCH_TAG}-\"))" \
                2>/dev/null | sort -V | tail -1 || true
        else
            echo "$json" \
                | grep -oP '"tag_name":\s*"\K'"${SOURCE_ARCH_TAG}"'-[^"]+' \
                | sort -V | tail -1 || true
        fi
    fi
}

# ---- 通过 API 获取 release ----
fetch_release_info() {
    local tag="$1"   # 可选: 指定 tag，为空则取最新

    if [[ -n "$tag" ]]; then
        info "获取指定 release: ${tag} ..."
    else
        info "获取 ${REPO} 最新 ${SOURCE_ARCH_TAG} release ..."
    fi

    local release_json

    # 如果指定了 tag，直接查该 release
    if [[ -n "$tag" ]]; then
        release_json=$(curl -4fsSL --connect-timeout 10 --max-time 30 \
            "${API_BASE}/releases/tags/${tag}" 2>/dev/null || true)

        if [[ -z "$release_json" ]]; then
            err "无法获取 release: ${tag}"
            err "请检查 tag 名称是否正确: https://github.com/${REPO}/releases"
            exit 1
        fi

        LATEST_TAG="$tag"
        DEB_URLS=$(parse_deb_urls "$release_json")

        if [[ -z "$DEB_URLS" ]]; then
            err "未找到 .deb 下载链接 (tag: ${tag})"
            exit 1
        fi
        return
    fi

    # 查最新 release: 先拉列表，找匹配架构的最新 tag
    local releases_json
    releases_json=$(curl -4fsSL --connect-timeout 10 --max-time 30 \
        "${API_BASE}/releases?per_page=50" 2>/dev/null || true)

    if [[ -z "$releases_json" ]]; then
        return 1   # API 不可达，交给 fallback
    fi

    LATEST_TAG=$(parse_latest_tag "$releases_json")

    if [[ -z "$LATEST_TAG" ]]; then
        err "未找到 ${SOURCE_ARCH_TAG} 架构的 release。"
        exit 1
    fi

    info "最新 release: ${LATEST_TAG}"

    # 获取该 release 详情
    release_json=$(curl -4fsSL --connect-timeout 10 --max-time 30 \
        "${API_BASE}/releases/tags/${LATEST_TAG}" 2>/dev/null || true)

    if [[ -z "$release_json" ]]; then
        return 1   # API 不可达，交给 fallback
    fi

    DEB_URLS=$(parse_deb_urls "$release_json")

    if [[ -z "$DEB_URLS" ]]; then
        err "未找到 .deb 下载链接 (tag: ${LATEST_TAG})"
        exit 1
    fi
}

# ---- 根据 tag 直接拼 .deb 下载 URL ----
build_fallback_urls() {
    local tag="$1"
    local base="https://github.com/${REPO}/releases/download/${tag}"
    local urls=""

    if [[ "$SOURCE" == "xdflight" ]]; then
        # tag 格式: linux-7.0.8-bbr3-amd64
        local ver
        ver=$(echo "$tag" | sed -E 's/^linux-([0-9.]+)-bbr3-.*/\1/')
        urls="${base}/linux-headers-${ver}-bbr3_${ver}-bbr3_${ARCH_DEB}.deb"$'\n'
        urls+="${base}/linux-image-${ver}-bbr3_${ver}-bbr3_${ARCH_DEB}.deb"$'\n'
        urls+="${base}/linux-libc-dev_${ver}-bbr3_${ARCH_DEB}.deb"
    else
        # byJoey: tag 格式 x86_64-7.0.5
        local ver="${tag#*-}"   # 去掉架构前缀，得到裸版本号
        urls="${base}/linux-headers-${ver}-joeyblog-bbrv3_${ver}-${GIT_HASH}-1_${ARCH_DEB}.deb"$'\n'
        urls+="${base}/linux-image-${ver}-joeyblog-bbrv3_${ver}-${GIT_HASH}-1_${ARCH_DEB}.deb"$'\n'
        urls+="${base}/linux-libc-dev_${ver}-${GIT_HASH}-1_${ARCH_DEB}.deb"
    fi

    echo "$urls"
}

# ---- fallback: API 不可达时的处理 ----
fallback_download() {
    local tag="${1:-}"

    # 如果用户指定了 tag，直接用
    if [[ -n "$tag" ]]; then
        LATEST_TAG="$tag"
    else
        if [[ "$SOURCE" == "xdflight" ]]; then
            case "$ARCH_DEB" in
                amd64) LATEST_TAG="linux-7.0.8-bbr3-amd64" ;;
                arm64) LATEST_TAG="linux-7.0.8-bbr3-arm64" ;;
            esac
        else
            case "$ARCH_TAG" in
                x86_64) LATEST_TAG="x86_64-7.0.5" ;;
                arm64)  LATEST_TAG="arm64-7.0.3"  ;;
            esac
        fi
    fi

    warn "API 不可达，按已知命名规律构造下载 URL (${LATEST_TAG}) ..."
    DEB_URLS=$(build_fallback_urls "$LATEST_TAG")

    if [[ -z "$DEB_URLS" ]]; then
        err "URL 构造失败，请手动下载:"
        err "  https://github.com/${REPO}/releases/tag/${LATEST_TAG}"
        exit 1
    fi
    info "构造了 $(echo "$DEB_URLS" | grep -c '^') 个下载链接。"
}

# ---- 下载 .deb ----
download_debs() {
    local tmpdir="/tmp/bbrv3-debs"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"

    info "下载内核 .deb 包到 $tmpdir ..."

    local failed=0
    local count=0
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        local fname
        fname=$(basename "$url")
        info "  -> $fname"
        if curl -4fsSL --connect-timeout 10 --max-time 300 \
            -o "$tmpdir/$fname" "$url"; then
            # 确保下载的文件不为空
            local fsize
            fsize=$(stat -c%s "$tmpdir/$fname" 2>/dev/null || stat -f%z "$tmpdir/$fname" 2>/dev/null || echo 0)
            if [[ "$fsize" -eq 0 ]]; then
                err "下载文件为空: $fname"
                failed=1
            else
                ((count++))
                info "    ($(( fsize / 1024 / 1024 )) MB)"
            fi
        else
            err "下载失败: $fname"
            failed=1
        fi
    done <<< "$DEB_URLS"

    if [[ $failed -ne 0 ]]; then
        err "部分或全部 .deb 下载失败。"
        exit 1
    fi

    if [[ $count -eq 0 ]]; then
        err "没有成功下载任何 .deb 文件。"
        exit 1
    fi

    ok "下载完成 (${count} 个文件)"
}

# ---- 安装 .deb ----
install_debs() {
    local tmpdir="/tmp/bbrv3-debs"

    info "安装内核..."

    # 先装 headers / libc-dev / image，用通配符让 dpkg 自动排序
    local debs
    debs=( "$tmpdir"/*.deb )
    if [[ ${#debs[@]} -eq 0 ]]; then
        err "未找到 .deb 文件。"
        exit 1
    fi

    if ! dpkg -i "${debs[@]}" 2>&1; then
        warn "dpkg 返回非零，尝试修复依赖..."
        if apt-get install -f -y 2>/dev/null; then
            # 修复后再装
            if ! dpkg -i "${debs[@]}" 2>/dev/null; then
                err "内核安装失败。"
                rm -rf "$tmpdir"
                exit 1
            fi
        else
            err "依赖修复失败。"
            rm -rf "$tmpdir"
            exit 1
        fi
    fi

    ok "内核 .deb 安装完成。"
    rm -rf "$tmpdir"
}

# ---- 更新 GRUB ----
update_bootloader() {
    info "更新 GRUB..."
    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v update-grub2 &>/dev/null; then
        update-grub2
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg
    else
        warn "未找到 GRUB，跳过。"
    fi
    ok "GRUB 已更新。"
}

# ---- 完成提示 ----
print_done() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║     BBRv3 内核安装完成！                  ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}安装版本${NC}"
    echo -e "    上游:    ${CYAN}${SOURCE}${NC}"
    echo -e "    架构:    ${CYAN}${ARCH_TAG}${NC}"
    echo -e "    Release: ${CYAN}${LATEST_TAG:-fallback}${NC}"
    echo -e "    来源:    ${CYAN}https://github.com/${REPO}${NC}"
    echo ""
    echo -e "  ${BOLD}内核特性${NC}"
    echo -e "    BBRv3:   ${GREEN}Google BBR v3${NC}"
    echo -e "    sch_fq:  ${GREEN}已编译进内核${NC}"
    echo ""
    echo -e "  ${RED}${BOLD}请立即重启以启用新内核:${NC}"
    echo -e "  ${RED}${BOLD}  reboot${NC}"
    echo ""
    echo -e "  ${BOLD}重启后验证${NC}"
    echo -e "    uname -r                              # 应带 bbrv3 后缀"
    echo -e "    sysctl net.ipv4.tcp_congestion_control # 应为 bbr"
    echo -e "    sysctl net.core.default_qdisc          # 应为 fq"
    echo ""
}

# ---- 打印用法 ----
usage() {
    echo "用法: sudo bash $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --source <src>  选择上游 (byjoey | xdflight)，不指定则交互选择"
    echo "  --tag <tag>     安装指定版本 (例: --tag x86_64-7.0.3)"
    echo "  --help          显示此帮助"
    echo ""
    echo "无选项时交互选择上游并安装最新版本。"
    exit 1
}

# ---- 解析参数 ----
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)
                shift
                if [[ -z "$1" ]]; then
                    err "--source 需要一个值 (byjoey | xdflight)"
                    usage
                fi
                case "$1" in
                    byjoey|xdflight) SOURCE="$1"; SOURCE_EXPLICIT=true ;;
                    *) err "--source 仅支持: byjoey, xdflight"; exit 1 ;;
                esac
                ;;
            --tag)
                shift
                if [[ -z "$1" ]]; then
                    err "--tag 需要一个值"
                    usage
                fi
                MANUAL_TAG="$1"
                ;;
            --help|-h)
                usage
                ;;
            *)
                err "未知选项: $1"
                usage
                ;;
        esac
        shift
    done
}

# ============================================================
# 主流程
# ============================================================
main() {
    parse_args "$@"

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════╗"
    echo "║   BBRv3 内核安装脚本 v3.0                 ║"
    echo "║   byJoey / XDflight 双上游              ║"
    echo "║   适用: Ubuntu / Debian (x86_64 / arm64) ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root
    check_os
    detect_arch

    # 未指定 --source 时交互选择
    if ! $SOURCE_EXPLICIT; then
        echo ""
        echo "  请选择 BBRv3 内核上游:"
        echo "    1) byJoey  — byJoey/Actions-bbr-v3 (稳定, kernel 7.0.5)"
        echo "    2) XDflight — XDflight/bbr3-debs (更新频繁, kernel 7.0.8+)"
        echo ""
        while true; do
            read -r -p "  选择 [1-2] (默认 1): " src_choice < /dev/tty
            [[ -z "$src_choice" ]] && src_choice=1
            case "$src_choice" in
                1) SOURCE="byjoey"; break ;;
                2) SOURCE="xdflight"; break ;;
                *) warn "请输入 1 或 2" ;;
            esac
        done
    fi

    setup_source
    check_current_bbr

    # 尝试 API; 失败时走 fallback
    if ! fetch_release_info "$MANUAL_TAG"; then
        fallback_download "$MANUAL_TAG"
    fi

    info "找到 $(echo "$DEB_URLS" | grep -c '^') 个 .deb 包:"
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        info "  -> $(basename "$url")"
    done <<< "$DEB_URLS"

    download_debs
    install_debs
    update_bootloader
    print_done
}

main "$@"
