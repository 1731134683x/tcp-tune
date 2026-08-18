#!/bin/bash
# ============================================================
# TCP 全流程脚本 v4.0 — BBRv3 内核 + TCP 深度调优 + 自定义模板 + AI 提示词
# ============================================================
#  上游:
#    byjoey  — byJoey/Actions-bbr-v3 (GitHub Actions 预编译)
#    xdflight — XDflight/bbr3-debs (更频繁更新, kernel 7.0.8+)
#  适用: Ubuntu / Debian (x86_64 / arm64)
#
#  三阶段:
#   Phase 1 — 检测并安装 BBRv3 内核 (双上游可选)
#   Phase 2 — VPS 检测 + 延迟测试 + 自动 TCP 调优
#   Phase 3 — 输出报告 + 生成自定义调参模板
#
#  用法:
#   sudo bash tcp-full.sh                      # 交互选择上游 + 全流程
#   sudo bash tcp-full.sh --source xdflight    # 指定 XDflight 上游
#   sudo bash tcp-full.sh --skip-kernel        # 跳过内核安装，仅调优
#   sudo bash tcp-full.sh --tag x86_64-7.0.3   # 指定内核版本
# ============================================================

# ---- 颜色 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}${BOLD}======== $* ========${NC}\n"; }
ask()   { echo -e "${YELLOW}[?]${NC} $*"; }

# ---- 全局变量 ----
SOURCE="byjoey"         # 默认上游: byjoey | xdflight
SOURCE_EXPLICIT=false  # 用户是否通过 --source 显式指定
REPO=""
API_BASE=""
GIT_HASH=""
SOURCE_ARCH_TAG=""      # 用于 tag 过滤的架构标识 (byJoey=x86_64, XDflight=amd64)

# 命令行参数
SKIP_KERNEL=false
MANUAL_TAG=""

# 系统信息
OS_NAME=""; OS_VERSION=""; OS_ID=""; KERNEL_VER=""
ARCH_TAG=""; ARCH_DEB=""

# VPS 规格
CPU_CORES=0; RAM_MB=0; RAM_GB_CEIL=0
DISK_TOTAL_GB=0
DISK_FREE_GB=0
DISK_USED_PCT=0
BANDWIDTH_MBPS=0

# 延迟
LATENCY_IPV4_MS=-1; LATENCY_IPV6_MS=-1
CHOSEN_LATENCY_MS=0; CHOSEN_IP_STACK=""

# 调优参数
BBRV3_READY=false; QDISC="fq"  # preserve fq/fq_codel when supported
LATEST_TAG=""; DEB_URLS=""
KERNEL_INSTALLED=false  # 本次运行是否安装了新内核

# 生成的调优值 (供 Phase 3 模板使用)
declare -A TV  # Tuning Values

# ---- 解析参数 ----
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-kernel) SKIP_KERNEL=true ;;
            --source)
                shift
                if [[ -z "$1" ]]; then
                    err "--source 需要一个值 (byjoey | xdflight)"
                    exit 1
                fi
                case "$1" in
                    byjoey|xdflight) SOURCE="$1"; SOURCE_EXPLICIT=true ;;
                    *) err "--source 仅支持: byjoey, xdflight"; exit 1 ;;
                esac
                ;;
            --tag) shift; MANUAL_TAG="$1" ;;
            --help|-h)
                echo "用法: sudo bash $0 [选项]"
                echo "  --source <src>  选择上游 (byjoey | xdflight)，不指定则交互选择"
                echo "  --skip-kernel   跳过 BBRv3 内核安装，仅 TCP 调优"
                echo "  --tag <tag>     安装指定 BBRv3 版本 (如 x86_64-7.0.3)"
                echo "  --help          显示此帮助"
                exit 0
                ;;
            *) err "未知选项: $1"; exit 1 ;;
        esac
        shift
    done
}

# ============================================================
# Phase 1: BBRv3 内核安装
# ============================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请使用 root 运行: sudo bash $0"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        err "无法读取 /etc/os-release"
        exit 1
    fi
    source /etc/os-release
    OS_NAME="$NAME"; OS_VERSION="$VERSION_ID"; OS_ID="$ID"

    # 提取主版本号 (例: 24.04 → 24)
    local ver_major
    ver_major=$(echo "$VERSION_ID" | cut -d. -f1)

    case "$OS_ID" in
        ubuntu)
            if [[ "$ver_major" =~ ^[0-9]+$ ]] && [[ "$ver_major" -lt 24 ]]; then
                err "Ubuntu ${VERSION_ID} 不满足最低要求 (>= 24.04)。"
                err "BBRv3 内核需要 Ubuntu 24.04 或更高版本。"
                exit 1
            fi
            ok "系统: $OS_NAME $OS_VERSION (满足 Ubuntu >= 24.04)"
            ;;
        debian)
            # VERSION_ID 可能是数字(12)或代号(trixie/sid)或为空(testing)
            if [[ "$ver_major" =~ ^[0-9]+$ ]] && [[ "$ver_major" -lt 12 ]]; then
                err "Debian ${VERSION_ID} 不满足最低要求 (>= 12)。"
                err "BBRv3 内核需要 Debian 12 或更高版本。"
                exit 1
            fi
            ok "系统: $OS_NAME $OS_VERSION (满足 Debian >= 12)"
            ;;
        *) err "仅支持 Ubuntu / Debian。" ; exit 1 ;;
    esac
    KERNEL_VER=$(uname -r)
    info "当前内核: $KERNEL_VER"
}

detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64)  ARCH_TAG="x86_64" ; ARCH_DEB="amd64" ;;
        aarch64) ARCH_TAG="arm64"  ; ARCH_DEB="arm64"  ;;
        *) err "不支持的架构: $machine"; exit 1 ;;
    esac
    info "架构: $machine → ${ARCH_TAG} / deb ${ARCH_DEB}"
}

# 根据上游设置 REPO / 哈希 / 架构标签
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
        *) err "未知上游: $SOURCE (支持: byjoey, xdflight)"; exit 1 ;;
    esac
    API_BASE="https://api.github.com/repos/${REPO}"
    info "上游: ${REPO}"
}

# 检查当前运行的内核是否已是 BBRv3
check_current_bbr_kernel() {
    if echo "$KERNEL_VER" | grep -qE "bbr3|joeyblog"; then
        ok "当前已是 BBRv3 内核: $KERNEL_VER"
        BBRV3_READY=true
        return 0
    fi

    # 检查 BBR 模块是否可用
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
    local available
    available=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk '{print $3}')
    info "可用拥塞算法: ${available:-无}"

    if echo "$available" | grep -q bbr; then
        info "当前内核支持 BBR (主线内核，非 BBRv3)"
        BBRV3_READY=true
    else
        warn "当前内核无 BBR 支持"
        BBRV3_READY=false
    fi
}

# ---- JSON 解析辅助 (jq 优先，grep 回退) ----
parse_deb_urls() {
    local json="$1"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r '.assets[]?.browser_download_url // empty | select(endswith(".deb") and (contains("dbg") | not))' 2>/dev/null || true
    else
        echo "$json" | grep -oP '"browser_download_url":\s*"\K[^"]+\.deb' | grep -v 'dbg' || true
    fi
}

parse_latest_tag() {
    local json="$1"
    if [[ "$SOURCE" == "xdflight" ]]; then
        if command -v jq &>/dev/null; then
            echo "$json" | jq -r ".[]?.tag_name // empty | select(startswith(\"linux-\") and contains(\"-bbr3-${SOURCE_ARCH_TAG}\"))" 2>/dev/null | sort -V | tail -1 || true
        else
            echo "$json" | grep -oP '"tag_name":\s*"\Klinux-[^-]+-bbr3-'"${SOURCE_ARCH_TAG}"'[^"]*' | sort -V | tail -1 || true
        fi
    else
        if command -v jq &>/dev/null; then
            echo "$json" | jq -r ".[]?.tag_name // empty | select(startswith(\"${SOURCE_ARCH_TAG}-\"))" 2>/dev/null | sort -V | tail -1 || true
        else
            echo "$json" | grep -oP '"tag_name":\s*"\K'"${SOURCE_ARCH_TAG}"'-[^"]+' | sort -V | tail -1 || true
        fi
    fi
}

build_fallback_urls() {
    local tag="$1"
    local base="https://github.com/${REPO}/releases/download/${tag}"

    if [[ "$SOURCE" == "xdflight" ]]; then
        local ver
        ver=$(echo "$tag" | sed -E 's/^linux-([0-9.]+)-bbr3-.*/\1/')
        echo "${base}/linux-headers-${ver}-bbr3_${ver}-bbr3_${ARCH_DEB}.deb"
        echo "${base}/linux-image-${ver}-bbr3_${ver}-bbr3_${ARCH_DEB}.deb"
        echo "${base}/linux-libc-dev_${ver}-bbr3_${ARCH_DEB}.deb"
    else
        local ver="${tag#*-}"
        echo "${base}/linux-headers-${ver}-joeyblog-bbrv3_${ver}-${GIT_HASH}-1_${ARCH_DEB}.deb"
        echo "${base}/linux-image-${ver}-joeyblog-bbrv3_${ver}-${GIT_HASH}-1_${ARCH_DEB}.deb"
        echo "${base}/linux-libc-dev_${ver}-${GIT_HASH}-1_${ARCH_DEB}.deb"
    fi
}

fetch_release() {
    local tag="$1"

    if [[ -n "$tag" ]]; then
        info "获取指定 release: ${tag} ..."
        local r
        r=$(curl -4fsSL --connect-timeout 10 --max-time 30 "${API_BASE}/releases/tags/${tag}" 2>/dev/null || true)
        if [[ -z "$r" ]]; then
            err "无法获取 release: ${tag}"
            return 1
        fi
        LATEST_TAG="$tag"
        DEB_URLS=$(parse_deb_urls "$r")
        [[ -z "$DEB_URLS" ]] && { err "未找到 .deb (${tag})"; return 1; }
        return 0
    fi

    info "查询 ${REPO} 最新 ${SOURCE_ARCH_TAG} release ..."
    local list
    list=$(curl -4fsSL --connect-timeout 10 --max-time 30 "${API_BASE}/releases?per_page=50" 2>/dev/null || true)
    if [[ -z "$list" ]]; then return 1; fi

    LATEST_TAG=$(parse_latest_tag "$list")
    if [[ -z "$LATEST_TAG" ]]; then err "未找到 ${SOURCE_ARCH_TAG} release。"; return 1; fi
    info "最新 release: ${LATEST_TAG}"

    local detail
    detail=$(curl -4fsSL --connect-timeout 10 --max-time 30 "${API_BASE}/releases/tags/${LATEST_TAG}" 2>/dev/null || true)
    if [[ -z "$detail" ]]; then return 1; fi

    DEB_URLS=$(parse_deb_urls "$detail")
    [[ -z "$DEB_URLS" ]] && { err "未找到 .deb (${LATEST_TAG})"; return 1; }
}

fallback_download() {
    local tag="${1:-}"
    if [[ -z "$tag" ]]; then
        if [[ "$SOURCE" == "xdflight" ]]; then
            case "$ARCH_DEB" in
                amd64) tag="linux-7.0.8-bbr3-amd64" ;;
                arm64) tag="linux-7.0.8-bbr3-arm64" ;;
            esac
        else
            case "$ARCH_TAG" in
                x86_64) tag="x86_64-7.0.5" ;;
                arm64)  tag="arm64-7.0.3"  ;;
            esac
        fi
    fi
    LATEST_TAG="$tag"
    warn "API 不可达，按已知命名规律构造下载 URL (${LATEST_TAG}) ..."
    DEB_URLS=$(build_fallback_urls "$LATEST_TAG")
    [[ -z "$DEB_URLS" ]] && { err "URL 构造失败。"; return 1; }
    info "构造了 $(echo "$DEB_URLS" | grep -c '^') 个下载链接，交由下载阶段验证。"
}

download_debs() {
    local tmpdir="/tmp/bbrv3-debs"
    rm -rf "$tmpdir"; mkdir -p "$tmpdir"
    info "下载 .deb 到 $tmpdir ..."

    local failed=0 count=0
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        local fname; fname=$(basename "$url")
        info "  -> $fname"
        if curl -4fsSL --connect-timeout 10 --max-time 300 -o "$tmpdir/$fname" "$url"; then
            local fsize
            fsize=$(stat -c%s "$tmpdir/$fname" 2>/dev/null || stat -f%z "$tmpdir/$fname" 2>/dev/null || echo 0)
            if [[ "$fsize" -eq 0 ]]; then
                err "空文件: $fname"; failed=1
            else
                ((count++)); info "    ($(( fsize / 1024 / 1024 )) MB)"
            fi
        else
            err "下载失败: $fname"; failed=1
        fi
    done <<< "$DEB_URLS"

    [[ $failed -ne 0 ]] && { err "下载失败。"; return 1; }
    [[ $count -eq 0 ]] && { err "无文件。"; return 1; }
    ok "下载完成 (${count} 个文件)"
}

install_debs() {
    local tmpdir="/tmp/bbrv3-debs"
    local debs; debs=( "$tmpdir"/*.deb )
    [[ ${#debs[@]} -eq 0 ]] && { err "未找到 .deb"; return 1; }

    info "安装内核 (${#debs[@]} 个包) ..."
    if ! dpkg -i "${debs[@]}" 2>&1; then
        warn "dpkg 返回非零，尝试修复依赖..."
        if apt-get install -f -y 2>/dev/null; then
            dpkg -i "${debs[@]}" 2>/dev/null || { err "安装失败。"; rm -rf "$tmpdir"; return 1; }
        else
            err "依赖修复失败。"; rm -rf "$tmpdir"; return 1
        fi
    fi
    ok "内核安装完成。"
    rm -rf "$tmpdir"
}

update_bootloader() {
    info "更新 GRUB..."
    if command -v update-grub &>/dev/null; then update-grub
    elif command -v update-grub2 &>/dev/null; then update-grub2
    elif command -v grub-mkconfig &>/dev/null; then grub-mkconfig -o /boot/grub/grub.cfg
    else warn "未找到 GRUB。"; fi
    ok "GRUB 已更新。"
}

# ---- XDflight 一键安装 ----
xdflight_oneclick_install() {
    local oneclick_url="https://raw.githubusercontent.com/XDflight/bbr3-debs/refs/heads/build/install_latest.sh"
    local oneclick_script="/tmp/xdflight-install.sh"

    info "使用 XDflight 官方一键安装脚本..."
    info "下载: ${oneclick_url}"

    if ! curl -4fsSL --connect-timeout 10 --max-time 60 -o "$oneclick_script" "$oneclick_url"; then
        err "下载 XDflight 安装脚本失败，请稍后重试或切换上游。"
        return 1
    fi

    ok "下载完成，执行安装..."
    bash "$oneclick_script"
    local rc=$?
    rm -f "$oneclick_script"
    if [[ $rc -ne 0 ]]; then
        err "XDflight 一键安装脚本返回非零 (exit $rc)，请检查上方输出。"
        return 1
    fi
    ok "XDflight 一键安装完成。"
}

# Phase 1 主入口
phase1_install_kernel() {
    step "Phase 1: BBRv3 内核安装"

    if $SKIP_KERNEL; then
        info "已指定 --skip-kernel，跳过内核安装。"
        return
    fi

    if echo "$KERNEL_VER" | grep -qE "bbr3|joeyblog"; then
        ok "已运行 BBRv3 内核，无需重复安装。"
        BBRV3_READY=true
        return
    fi

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

    echo ""
    ask "是否安装 BBRv3 内核? (${REPO} 预编译) [Y/n]: "
    read -r ans < /dev/tty
    if [[ "$ans" == "n" || "$ans" == "N" ]]; then
        info "跳过内核安装。将以当前内核进行 TCP 调优。"
        return
    fi

    # XDflight 上游: 直接调用上游官方一键安装脚本
    # byJoey 上游: 自行拉取 .deb 安装
    if [[ "$SOURCE" == "xdflight" ]]; then
        xdflight_oneclick_install || return
        LATEST_TAG="xdflight-latest"
    else
        # 自动获取或 fallback
        if ! fetch_release "$MANUAL_TAG"; then
            if ! fallback_download "$MANUAL_TAG"; then
                err "无法获取 BBRv3 内核，跳过安装。"
                return
            fi
        fi

        info "将安装 $(echo "$DEB_URLS" | grep -c '^') 个 .deb 包:"
        while IFS= read -r url; do
            [[ -z "$url" ]] && continue
            info "  -> $(basename "$url")"
        done <<< "$DEB_URLS"

        download_debs || { err "下载失败，跳过内核安装。"; return; }
        install_debs || { err "安装失败。"; return; }
        update_bootloader
    fi

    KERNEL_INSTALLED=true
    BBRV3_READY=true
    ok "BBRv3 内核 (${LATEST_TAG}) 安装完成。需要重启后生效。"

    echo ""
    ask "是否立即重启以启用新内核? [y/N]: "
    read -r ans < /dev/tty
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        info "系统即将重启..."
        reboot
    fi
    info "继续在当前内核下进行 TCP 调优 (重启后对新内核生效)。"
}

# ============================================================
# Phase 2: VPS 检测 + 延迟测试 + TCP 调优
# ============================================================

# ============================================================
# qdisc compatibility detection
# ============================================================
detect_qdisc() {
    local current candidate
    current=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")

    # BBRv3 kernels may intentionally use fq_codel. Preserve either supported choice.
    case "$current" in
        fq|fq_codel)
            QDISC="$current"
            ok "qdisc: ${QDISC} (preserving the active supported qdisc)"
            return 0
            ;;
    esac

    modprobe sch_fq 2>/dev/null || true
    for candidate in fq fq_codel; do
        sysctl -w "net.core.default_qdisc=${candidate}" 2>/dev/null || continue
        current=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
        if [[ "$current" == "$candidate" ]]; then
            QDISC="$candidate"
            ok "qdisc: ${QDISC} (detected supported qdisc)"
            return 0
        fi
    done

    warn "Neither fq nor fq_codel could be activated at runtime (current: ${current:-unknown})."
    warn "Keeping fallback qdisc setting: ${QDISC}; verify after booting the target kernel."
}

detect_vps_specs() {
    step "Phase 2: VPS 检测与 TCP 调优"

    CPU_CORES=$(nproc)
    RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    RAM_GB_CEIL=$(( (RAM_MB + 1023) / 1024 ))
    [[ $RAM_GB_CEIL -lt 1 ]] && RAM_GB_CEIL=1

    info "CPU: ${CPU_CORES} 核"
    info "内存: ${RAM_MB}MB → 向上取整 ${RAM_GB_CEIL}G"

    # Root filesystem capacity for proxy data and logs.
    local disk_total_kb disk_avail_kb disk_used_pct
    read -r disk_total_kb disk_avail_kb disk_used_pct < <(
        df -Pk / 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $2, $4, $5}'
    )
    if [[ "$disk_total_kb" =~ ^[0-9]+$ && "$disk_avail_kb" =~ ^[0-9]+$ && "$disk_used_pct" =~ ^[0-9]+$ ]]; then
        DISK_TOTAL_GB=$(( (disk_total_kb + 1048575) / 1048576 ))
        DISK_FREE_GB=$(( disk_avail_kb / 1048576 ))
        DISK_USED_PCT=$disk_used_pct
        info "Root filesystem: ${DISK_TOTAL_GB}G total / ${DISK_FREE_GB}G available / ${DISK_USED_PCT}% used"
    else
        warn "Unable to read root filesystem capacity."
    fi

    echo ""
    ask "请输入 VPS 带宽 (Mbps):"
    echo "    常见: 100 | 300 | 500 | 1000 | 2000 | 10000"
    while true; do
        read -r -p "    带宽 (Mbps): " bw < /dev/tty
        if [[ "$bw" =~ ^[0-9]+$ ]] && [[ "$bw" -gt 0 ]]; then
            BANDWIDTH_MBPS=$bw; break
        fi
        warn "请输入正整数。"
    done
}

# ?? ping ???????? RTT??????? ping ?????
# ?????????????????????????????
ping_average_ms() {
    local log_file=$1
    awk '
        /(rtt|round-trip|round trip).*=/ {
            line=$0
            sub(/^.*=[[:space:]]*/, "", line)
            split(line, values, "/")
            avg=values[2]
            sub(/[[:space:]].*$/, "", avg)
            if (avg ~ /^[0-9]+([.][0-9]+)?$/) {
                printf "%.1f", avg
                exit
            }
        }
    ' "$log_file"
}

ping_packet_loss() {
    local log_file=$1
    awk '/packet loss/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+([.][0-9]+)?%$/) {
                print $i
                exit
            }
        }
    }' "$log_file"
}

latency_available() {
    awk -v v="$1" 'BEGIN{ exit !(v ~ /^[0-9]+([.][0-9]+)?$/) }' 
}

test_latency() {
    local v4="120.241.152.135"
    local v6="2409:8c54:871:1001::12"
    local log4="/tmp/tcp-full-ping-v4.log"
    local log6="/tmp/tcp-full-ping-v6.log"
    local l4 l6

    info "IPv4 Ping → $v4 ..."
    ping -c 5 -W 2 "$v4" > "$log4" 2>&1 || true
    LATENCY_IPV4_MS=$(ping_average_ms "$log4")
    if latency_available "$LATENCY_IPV4_MS"; then
        l4=$(ping_packet_loss "$log4")
        ok "IPv4: ${LATENCY_IPV4_MS} ms (丢包: ${l4:-丢包})"
    else
        warn "IPv4 Ping 失败，无法获取 RTT，可能封禁了 ICMP 或无 IPv4 路由。"
        LATENCY_IPV4_MS=-1
    fi

    info "IPv6 Ping → $v6 ..."
    ping -c 5 -W 2 "$v6" > "$log6" 2>&1 || true
    LATENCY_IPV6_MS=$(ping_average_ms "$log6")
    if latency_available "$LATENCY_IPV6_MS"; then
        l6=$(ping_packet_loss "$log6")
        ok "IPv6: ${LATENCY_IPV6_MS} ms (丢包: ${l6:-丢包})"
    else
        warn "IPv6 Ping 失败，无法获取 RTT，可能封禁了 ICMP 或无 IPv6 路由。"
        LATENCY_IPV6_MS=-1
    fi
}

choose_latency() {
    echo ""
    echo "  测得延迟:"
    if latency_available "$LATENCY_IPV4_MS"; then
        echo "    IPv4: ${LATENCY_IPV4_MS} ms"
    else
        echo "    IPv4: 不可用"
    fi
    if latency_available "$LATENCY_IPV6_MS"; then
        echo "    IPv6: ${LATENCY_IPV6_MS} ms"
    else
        echo "    IPv6: 不可用"
    fi

    local v4_ok=0 v6_ok=0
    latency_available "$LATENCY_IPV4_MS" && v4_ok=1
    latency_available "$LATENCY_IPV6_MS" && v6_ok=1

    if [[ "$v4_ok" == "1" && "$v6_ok" == "1" ]]; then
        echo "  请选择延迟基准:"
        echo "    1) IPv4 (${LATENCY_IPV4_MS} ms)"
        echo "    2) IPv6 (${LATENCY_IPV6_MS} ms)"
        echo "    3) 取最大值 (取 max，更保守)"
        while true; do
            read -r -p "  请选择 [1-3]: " c < /dev/tty
            case $c in
                1) CHOSEN_LATENCY_MS=$LATENCY_IPV4_MS; CHOSEN_IP_STACK="IPv4"; break ;;
                2) CHOSEN_LATENCY_MS=$LATENCY_IPV6_MS; CHOSEN_IP_STACK="IPv6"; break ;;
                3) CHOSEN_LATENCY_MS=$(awk -v a="$LATENCY_IPV4_MS" -v b="$LATENCY_IPV6_MS" 'BEGIN{printf "%.1f", (a>b?a:b)}')
                   CHOSEN_IP_STACK="Max(IPv4/IPv6)"; break ;;
                *) warn "请输入 1、2 或 3" ;;
            esac
        done
    elif [[ "$v4_ok" == "1" ]]; then
        info "仅 IPv4 可用，自动选择 IPv4。"; CHOSEN_LATENCY_MS=$LATENCY_IPV4_MS; CHOSEN_IP_STACK="IPv4"
    elif [[ "$v6_ok" == "1" ]]; then
        info "仅 IPv6 可用，自动选择 IPv6。"; CHOSEN_LATENCY_MS=$LATENCY_IPV6_MS; CHOSEN_IP_STACK="IPv6"
    else
        warn "IPv4 与 IPv6 均不可达，使用默认 150ms。"; CHOSEN_LATENCY_MS=150; CHOSEN_IP_STACK="默认(150ms)"
    fi

    info "延迟基准: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS} ms"
}

generate_tuning() {
    # --- BDP 计算 ---
    bdp_bytes=$(awk -v bw="$BANDWIDTH_MBPS" -v lat="$CHOSEN_LATENCY_MS" 'BEGIN{printf "%d", bw*1000000/8*lat/1000}')
    # 内存分档决定缓冲策略：
    #   ≤1G：保守，缓冲 = BDP（四舍五入到整 MB）
    #   ≥2G：激进，缓冲 = BDP × 2
    if [[ $RAM_GB_CEIL -le 1 ]]; then
        target_buf=$bdp_bytes
    else
        target_buf=$(( bdp_bytes * 2 ))
    fi

    # 内存侧上限：按实际内存的约 8% 计算，硬上限 512MB
    mem_cap_buf=$(( RAM_MB * 1024 * 1024 / 12 ))
    hard_cap_buf=$(( 512 * 1024 * 1024 ))
    [[ $mem_cap_buf -gt $hard_cap_buf ]] && mem_cap_buf=$hard_cap_buf

    if [[ $target_buf -lt $mem_cap_buf ]]; then buf_max=$target_buf; else buf_max=$mem_cap_buf; fi
    if [[ $buf_max -lt 4194304 ]]; then buf_max=4194304; fi  # 最小 4MB

    # 低内存 VPS 四舍五入到整 MB，更保守
    if [[ $RAM_GB_CEIL -le 1 ]]; then
        buf_max=$(( (buf_max + 524288) / 1048576 * 1048576 ))
    fi

    buf_max_mb=$(awk -v b="$buf_max" 'BEGIN{printf "%.2f", b/1024/1024}')
    info "BDP = $(awk -v b="$bdp_bytes" 'BEGIN{printf "%.2f", b/1024/1024}') MB, 缓冲区上限 = ${buf_max_mb} MB"

    # --- 内存分档参数 ---
    # High-concurrency proxy: enlarge accept/SYN queues and bound default socket buffers.
    # Xray userspace write queue cap: bound unsent data per TCP socket.
    if [[ $RAM_GB_CEIL -le 2 ]]; then
        tcp_notsent_lowat=131072
    elif [[ $RAM_GB_CEIL -le 8 ]]; then
        tcp_notsent_lowat=262144
    else
        tcp_notsent_lowat=524288
    fi

    if [[ $RAM_GB_CEIL -le 1 ]]; then
        somaxconn=4096; tcp_max_syn_backlog=4096; netdev_max_backlog=8192
        file_max=1000000; nofile_limit=65535
    elif [[ $RAM_GB_CEIL -eq 2 ]]; then
        somaxconn=8192; tcp_max_syn_backlog=8192; netdev_max_backlog=16384
        file_max=2000000; nofile_limit=131072
    elif [[ $RAM_GB_CEIL -le 4 ]]; then
        somaxconn=16384; tcp_max_syn_backlog=16384; netdev_max_backlog=32768
        file_max=4000000; nofile_limit=262144
    elif [[ $RAM_GB_CEIL -le 8 ]]; then
        somaxconn=32768; tcp_max_syn_backlog=32768; netdev_max_backlog=65536
        file_max=8000000; nofile_limit=524288
    else
        somaxconn=65535; tcp_max_syn_backlog=65535; netdev_max_backlog=65536
        file_max=16000000; nofile_limit=1048576
    fi

    socket_default=$(( bdp_bytes / 4 ))
    [[ $socket_default -lt 262144 ]] && socket_default=262144
    [[ $socket_default -gt 2097152 ]] && socket_default=2097152
    [[ $socket_default -ge $buf_max ]] && socket_default=$(( buf_max / 2 ))
    [[ $socket_default -lt 65536 ]] && socket_default=65536
    tcp_rmem_default=$socket_default
    tcp_wmem_default=$socket_default

    # --- 延迟分档参数 ---
    tcp_slow_start_after_idle=0

    if awk -v l="$CHOSEN_LATENCY_MS" 'BEGIN{exit !(l<=50)}'; then
        tcp_fin_timeout=10; keepalive_time=300; keepalive_intvl=10; keepalive_probes=3
    elif awk -v l="$CHOSEN_LATENCY_MS" 'BEGIN{exit !(l<=150)}'; then
        tcp_fin_timeout=15; keepalive_time=600; keepalive_intvl=15; keepalive_probes=3
    else
        tcp_fin_timeout=20; keepalive_time=900; keepalive_intvl=30; keepalive_probes=5
    fi


    # --- 保存到全局数组 (供 Phase 3 模板引用) ---
    TV[somaxconn]=$somaxconn
    TV[tcp_max_syn_backlog]=$tcp_max_syn_backlog
    TV[netdev_max_backlog]=$netdev_max_backlog
    TV[buf_max]=$buf_max
    TV[buf_max_mb]=$buf_max_mb
    TV[tcp_rmem_default]=$tcp_rmem_default
    TV[tcp_wmem_default]=$tcp_wmem_default
    TV[tcp_fin_timeout]=$tcp_fin_timeout
    TV[tcp_fastopen]=3
    TV[tcp_mtu_probing]=1
    TV[tcp_slow_start_after_idle]=$tcp_slow_start_after_idle
    TV[keepalive_time]=$keepalive_time
    TV[keepalive_intvl]=$keepalive_intvl
    TV[keepalive_probes]=$keepalive_probes
    TV[file_max]=$file_max
    TV[tcp_notsent_lowat]=$tcp_notsent_lowat
    TV[kernel_panic]=10
    TV[swappiness]=1
    TV[overcommit_memory]=1
    TV[nofile_limit]=$nofile_limit
    TV[bdp_mb]=$(awk -v b="$bdp_bytes" 'BEGIN{printf "%.2f", b/1024/1024}')

    info "参数计算完成，尚未写入任何系统配置文件。"
}

# ============================================================
# 调优前: 检测当前系统环境 + 盘点已有调优文件地址
# ============================================================
pre_apply_check() {
    step "调优前环境检测"

    # --- 1. 当前运行时环境快照 ---
    local qdisc_now cc_now mem_total mem_avail ulimit_now
    qdisc_now=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
    cc_now=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    mem_total=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    mem_avail=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    ulimit_now=$(ulimit -n 2>/dev/null || echo unknown)
    echo ""
    echo -e "  ${BOLD}当前运行时环境${NC}"
    echo "    qdisc:       ${qdisc_now}"
    echo "    拥塞控制:    ${cc_now}"
    echo "    rmem_max:    $(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
    echo "    wmem_max:    $(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
    echo "    somaxconn:   $(sysctl -n net.core.somaxconn 2>/dev/null || echo unknown)"
    echo "    ulimit -n:   ${ulimit_now}"
    echo "    内存:        ${mem_total} MB 总量 / ${mem_avail} MB 可用"

    # --- 2. 盘点已存在的调优文件 (多次调优可能残留多个) ---
    step "盘点已存在的调优文件"
    local dir f b size mtime origin found=0
    local -a late_zz=()
    local -a leftover=()
    for dir in /etc/sysctl.d /etc/security/limits.d /etc/modules-load.d; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*.conf; do
            [[ -f "$f" ]] || continue
            if ! grep -qE 'tcp_bbr|sch_fq|nofile|nproc|net\.(core|ipv4)|fs\.file-max|vm\.swappiness|vm\.overcommit_memory|kernel\.panic' "$f" 2>/dev/null; then
                continue
            fi
            b=$(basename "$f")
            size=$(stat -c%s "$f" 2>/dev/null || echo 0)
            mtime=$(stat -c%y "$f" 2>/dev/null | cut -d. -f1)
            case "$b" in
                zzz-tcp-tune.conf|zzz-tcp-tune-limits.conf|tcp-tune.conf) origin="本工具";;
                zzzz-tcp-custom.conf|99-zzz-custom-limits.conf|99-custom-limits.conf) origin="AI/模板生成"; leftover+=("$f");;
                zzz-bbrv3.conf) origin="BBRv3 安装器"; leftover+=("$f");;
                *) origin="其他来源"; leftover+=("$f");;
            esac
            echo "    [${origin}] ${f}  (${size}B, ${mtime})"
            found=$((found+1))
            if [[ "$dir" == "/etc/sysctl.d" && "$b" == zz* ]]; then
                late_zz+=("$f")
            fi
        done
    done
    if grep -qE '^net\.(core\.default_qdisc|ipv4\.tcp_congestion_control)' /etc/sysctl.conf 2>/dev/null; then
        echo "    [兜底配置] /etc/sysctl.conf (含 qdisc/cc 兜底行)"
        found=$((found+1))
    fi
    if [[ $found -eq 0 ]]; then
        info "未发现已存在的调优文件，本次为首次调优。"
    fi
    # 多个 zz 前缀 sysctl 文件同时存在 → 字典序最后者生效
    if [[ ${#late_zz[@]} -gt 1 ]]; then
        local last_zz
        last_zz=$(printf '%s\n' "${late_zz[@]}" | sort | tail -n1)
        warn "检测到 ${#late_zz[@]} 个 zz 前缀 sysctl 文件，同时存在时字典序最后的生效:"
        printf '%s\n' "${late_zz[@]}" | sort | while IFS= read -r f; do
            if [[ "$f" == "$last_zz" ]]; then
                echo "      ${f}  ← 当前生效"
            else
                echo "      ${f}"
            fi
        done
        warn "建议清理不再需要的旧文件，避免参数互相覆盖。"
    fi

    # --- 2.5 残留文件清理 (在写入新配置之前完成) ---
    if [[ ${#leftover[@]} -gt 0 ]]; then
        step "残留文件清理 (调优前)"
        info "以下 ${#leftover[@]} 个旧调优文件不在本次管理范围内；本工具管理的 zzz-tcp-tune.conf 等无需手动删除，每次运行会覆盖:"
        local quoted="" f2
        for f2 in "${leftover[@]}"; do
            quoted+=" \"$f2\""
        done
        echo ""
        echo "  # 手动清理方式 (可选): 先备份再删除"
        echo "  tar czf /root/tcp-tune-leftover-backup-\$(date +%Y%m%d%H%M%S).tgz${quoted} 2>/dev/null"
        echo "  rm -f${quoted}"
        echo ""
        # 交互确认: 现在备份并删除，保证新配置写入前残留文件已被清理
        local do_clean=""
        read -r -p "  是否现在自动备份并删除以上残留文件？[y/N]: " do_clean </dev/tty 2>/dev/null || true
        if [[ "$do_clean" == "y" || "$do_clean" == "Y" ]]; then
            local bak="/root/tcp-tune-leftover-backup-$(date +%Y%m%d%H%M%S).tgz"
            if tar czf "$bak" "${leftover[@]}" 2>/dev/null && tar tzf "$bak" >/dev/null 2>&1; then
                rm -f "${leftover[@]}" || warn "部分文件删除失败。"
                ok "已备份到 ${bak} 并删除 ${#leftover[@]} 个残留文件。"
            else
                warn "备份未成功，未执行删除，请手动处理。"
            fi
        else
            info "未清理残留文件，继续；注意字典序靠后的 zz 文件可能覆盖本次调优结果。"
        fi
        echo ""
    fi

    # --- 3. 本次将写入/更新的文件地址 ---
    step "本次将写入/更新的文件地址"
    echo "    sysctl:   /etc/sysctl.d/zzz-tcp-tune.conf"
    echo "    limits:   /etc/security/limits.d/zzz-tcp-tune-limits.conf"
    echo "    modules:  /etc/modules-load.d/tcp-tune.conf"
    echo "    systemd:  /etc/systemd/system/xray.service.d/99-tcp-tune.conf"
    echo "    systemd:  /etc/systemd/system.conf (DefaultLimitNOFILE/NPROC 两行)"
    echo "    sysctl:   /etc/sysctl.conf (仅 qdisc + cc 两行兜底)"
    echo ""
}

# ============================================================
# Apply Config (sysctl --system + 冲突扫描 + 验证)
# ============================================================
apply_config() {
    # --- 应用 ---
    info "应用配置..."

    # The dedicated zzz sysctl file is loaded last. Preserve unrelated settings.
    # fq_codel is a supported BBRv3-compatible qdisc and must not be disabled.

    # 写入调优配置（仅在用户选择应用后执行）
    write_config

    if sysctl --system 2>&1 | grep -qiE "error|unknown|invalid"; then
        warn "sysctl --system 可能存在部分错误，请查看上方输出。"
    fi
    sysctl -w net.core.default_qdisc="${QDISC}" 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
    sysctl -w kernel.panic=10 2>/dev/null || warn "kernel.panic write failed"
    sysctl -w vm.swappiness=1 2>/dev/null || warn "vm.swappiness write failed"
    sysctl -w vm.overcommit_memory=1 2>/dev/null || warn "vm.overcommit_memory write failed"
    # 写入后立即回读验证
    local qdisc_runtime cc_runtime
    qdisc_runtime=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    cc_runtime=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$qdisc_runtime" != "${QDISC}" ]]; then
        warn "运行时 qdisc 未能切换为 ${QDISC} (当前: ${qdisc_runtime:-unknown})，重启 BBRv3 内核后生效。"
    fi
    if [[ "$cc_runtime" != "bbr" ]]; then
        warn "运行时 cc 未能切换为 bbr (当前: ${cc_runtime:-unknown})，重启后生效。"
    fi

    # /etc/sysctl.conf 兜底
    local sed_fail2=0
    if grep -q "^net\.core\.default_qdisc" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^net\.core\.default_qdisc.*/net.core.default_qdisc = ${QDISC}/" /etc/sysctl.conf || sed_fail2=1
    else
        echo "net.core.default_qdisc = ${QDISC}" >> /etc/sysctl.conf || sed_fail2=1
    fi
    if grep -q "^net\.ipv4\.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^net\.ipv4\.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf || sed_fail2=1
    else
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf || sed_fail2=1
    fi
    if [[ "$sed_fail2" -eq 1 ]]; then
        warn "/etc/sysctl.conf 兜底写入失败，请手动检查。"
    fi

    systemctl daemon-reload 2>/dev/null || true
    systemctl daemon-reexec 2>/dev/null || true

    # —— limits 生效验证 (ulimit) ——
    local ulimit_now
    ulimit_now=$(ulimit -n 2>/dev/null || echo "?")
    info "当前 ulimit -n: ${ulimit_now} (期望 >= ${nofile_limit})"
    if [[ "$ulimit_now" =~ ^[0-9]+$ && "$ulimit_now" -lt "$nofile_limit" ]]; then
        warn "ulimit -n 未达到期望值 (当前 ${ulimit_now} < ${nofile_limit})，需重新登录或重启后生效。"
        warn "limits.d 配置文件已写入，新 SSH session 将自动加载。"
    elif [[ "$ulimit_now" == "$nofile_limit" || "$ulimit_now" -ge "$nofile_limit" ]]; then
        ok "ulimit -n 已生效: ${ulimit_now}"
    fi

    # 验证
    local qd cc
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    ok "当前: qdisc=${qd}, cc=${cc}"
    if [[ ( "$qd" == "fq" || "$qd" == "fq_codel" ) && "$cc" == "bbr" ]]; then
        ok "BBR + ${qd} 配对正确，已运行时生效。"
    else
        warn "部分参数需重启后对新内核生效。"
    fi

    # 本次写入/更新的文件地址 + 追加到调优日志 (多次调优可追溯)
    ok "本次写入/更新的文件:"
    echo "      /etc/sysctl.d/zzz-tcp-tune.conf"
    echo "      /etc/security/limits.d/zzz-tcp-tune-limits.conf"
    echo "      /etc/modules-load.d/tcp-tune.conf"
    echo "      /etc/systemd/system/xray.service.d/99-tcp-tune.conf"
    echo "      /etc/systemd/system.conf"
    echo "      /etc/sysctl.conf"
    {
        echo "==== $(date '+%Y-%m-%d %H:%M:%S') 本次调优写入/更新 ===="
        echo "  /etc/sysctl.d/zzz-tcp-tune.conf"
        echo "  /etc/security/limits.d/zzz-tcp-tune-limits.conf"
        echo "  /etc/modules-load.d/tcp-tune.conf"
        echo "  /etc/systemd/system/xray.service.d/99-tcp-tune.conf"
        echo "  /etc/systemd/system.conf"
        echo "  /etc/sysctl.conf"
    } >> /root/tcp-tune-file-log.txt 2>/dev/null || true
    ok "文件地址日志: /root/tcp-tune-file-log.txt"

    verify_applied
}

# ============================================================
# 验证: 逐项回读 sysctl / ulimit / PAM，确保参数正确生效
# ============================================================
verify_applied() {
    echo ""
    info "验证参数是否正确应用..."

    local pass=0 fail=0
    local actual expected

    _check() {
        local label="$1" actual="$2" expected="$3" op="${4:-eq}"
        if [[ "$op" == "ge" ]]; then
            if [[ "$actual" =~ ^[0-9]+$ ]] && [[ "$actual" -ge "$expected" ]]; then
                ok "  $label: ${actual} (>= ${expected}) ✓"
                ((pass++))
            else
                warn "  $label: ${actual} (期望 >= ${expected})"
                ((fail++))
            fi
        elif [[ "$op" == "eq" ]]; then
            if [[ "$actual" == "$expected" ]]; then
                ok "  $label: ${actual} ✓"
                ((pass++))
            else
                warn "  $label: ${actual} (期望 ${expected})"
                ((fail++))
            fi
        fi
    }

    # --- sysctl 核心参数 ---
    actual=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    _check "qdisc" "$actual" "${QDISC}"

    actual=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    _check "cc" "$actual" "bbr"

    actual=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
    _check "rmem_max" "$actual" "${TV[buf_max]}"

    actual=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")
    _check "wmem_max" "$actual" "${TV[buf_max]}"

    actual=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo "0 0 0")
    expected="4096	${TV[tcp_rmem_default]}	${TV[buf_max]}"
    if [[ "$actual" == "$expected" ]]; then
        ok "  tcp_rmem: ${actual} ✓"
        ((pass++))
    else
        warn "  tcp_rmem: ${actual} (期望 ${expected})"
        ((fail++))
    fi

    actual=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo "0 0 0")
    expected="4096	${TV[tcp_wmem_default]}	${TV[buf_max]}"
    if [[ "$actual" == "$expected" ]]; then
        ok "  tcp_wmem: ${actual} ✓"
        ((pass++))
    else
        warn "  tcp_wmem: ${actual} (期望 ${expected})"
        ((fail++))
    fi

    actual=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "?")
    _check "somaxconn" "$actual" "${TV[somaxconn]}"

    actual=$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo "?")
    _check "tcp_max_syn_backlog" "$actual" "${TV[tcp_max_syn_backlog]}"

    actual=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "?")
    _check "netdev_max_backlog" "$actual" "${TV[netdev_max_backlog]}"

    actual=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo "?")
    _check "ip_local_port_range" "$actual" "1024	65535"

    actual=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo "?")
    _check "tcp_syncookies" "$actual" "1"

    actual=$(sysctl -n net.ipv4.tcp_synack_retries 2>/dev/null || echo "?")
    _check "tcp_synack_retries" "$actual" "3"

    actual=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null || echo "?")
    _check "tcp_moderate_rcvbuf" "$actual" "1"
    actual=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "?")
    _check "tcp_notsent_lowat" "$actual" "${TV[tcp_notsent_lowat]}"

    actual=$(sysctl -n kernel.panic 2>/dev/null || echo "?")
    _check "kernel.panic" "$actual" "10"
    actual=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
    _check "vm.swappiness" "$actual" "1"
    actual=$(sysctl -n vm.overcommit_memory 2>/dev/null || echo "?")
    _check "vm.overcommit_memory" "$actual" "1"

    actual=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "?")
    _check "tcp_fastopen" "$actual" "${TV[tcp_fastopen]}"

    actual=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "?")
    _check "tcp_mtu_probing" "$actual" "${TV[tcp_mtu_probing]}"

    actual=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null || echo "?")
    _check "tcp_fin_timeout" "$actual" "${TV[tcp_fin_timeout]}"

    actual=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "?")
    _check "tcp_slow_start_after_idle" "$actual" "${TV[tcp_slow_start_after_idle]}"

    actual=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "?")
    _check "keepalive_time" "$actual" "${TV[keepalive_time]}"

    actual=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo "?")
    _check "keepalive_intvl" "$actual" "${TV[keepalive_intvl]}"

    actual=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo "?")
    _check "keepalive_probes" "$actual" "${TV[keepalive_probes]}"

    actual=$(sysctl -n fs.file-max 2>/dev/null || echo "?")
    _check "fs.file-max" "$actual" "${TV[file_max]}"

    # --- ulimit ---
    actual=$(ulimit -n 2>/dev/null || echo "?")
    _check "ulimit -n" "$actual" "${TV[nofile_limit]}" "ge"

    # --- PAM ---
    local pam_ok=0
    for f in common-session common-session-noninteractive sshd login su; do
        if grep -q "pam_limits.so" "/etc/pam.d/$f" 2>/dev/null; then
            pam_ok=1; break
        fi
    done
    if [[ "$pam_ok" -eq 1 ]]; then
        ok "  pam_limits.so: 已配置 ✓"
        ((pass++))
    else
        warn "  pam_limits.so: 未检测到"
        ((fail++))
    fi

    # --- 小结 ---
    echo ""
    local total=$((pass + fail))
    if [[ "$fail" -eq 0 ]]; then
        ok "验证完成: ${pass}/${total} 通过，全部正确。"
    else
        warn "验证完成: ${pass}/${total} 通过，${fail} 项不符（可能需重启后生效）。"
    fi
}

# ============================================================
# 写入配置文件
# ============================================================
write_config() {
    step "写入调优配置文件"
    # --- 写入 sysctl 配置 ---
    local conf="/etc/sysctl.d/zzz-tcp-tune.conf"
    cat > "$conf" <<SYSCTLEOF
# ============================================================
# TCP 深度调优 (tcp-full.sh 生成)
# 时间: $(date '+%Y-%m-%d %H:%M:%S')
# VPS: ${CPU_CORES}核 / ${RAM_GB_CEIL}G / ${BANDWIDTH_MBPS}Mbps
# Root filesystem: ${DISK_TOTAL_GB}G total / ${DISK_FREE_GB}G available / ${DISK_USED_PCT}% used
# 延迟: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms
# 内核: ${KERNEL_VER}
# ============================================================

# === 拥塞控制 ===
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = bbr

# === 队列与积压 (${RAM_GB_CEIL}G) ===
net.core.somaxconn = ${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${tcp_max_syn_backlog}
net.core.netdev_max_backlog = ${netdev_max_backlog}

    # High-concurrency proxy connection management.
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_notsent_lowat = ${tcp_notsent_lowat}

# === System protection baseline ===
# Reboot 10 seconds after a kernel panic.
kernel.panic = 10
# Minimize swap preference; this does not disable swap.
vm.swappiness = 1
# Enable heuristic memory overcommit; continue monitoring for OOM.
vm.overcommit_memory = 1

# === 缓冲区 (BDP ${TV[bdp_mb]}MB, 上限 ${buf_max_mb}MB) ===
net.core.rmem_max = ${buf_max}
net.core.wmem_max = ${buf_max}
net.ipv4.tcp_rmem = 4096 ${tcp_rmem_default} ${buf_max}
net.ipv4.tcp_wmem = 4096 ${tcp_wmem_default} ${buf_max}

# === 内存策略 ===

# === 协议栈 ===
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = ${tcp_fin_timeout}
net.ipv4.tcp_slow_start_after_idle = ${tcp_slow_start_after_idle}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# === 连接保持 ===
net.ipv4.tcp_keepalive_time = ${keepalive_time}
net.ipv4.tcp_keepalive_intvl = ${keepalive_intvl}
net.ipv4.tcp_keepalive_probes = ${keepalive_probes}

# === IPv6 ===

# === 系统级 ===
fs.file-max = ${file_max}
SYSCTLEOF
    ok "已写入: $conf"

    # --- limits ---
    local lf="/etc/security/limits.d/zzz-tcp-tune-limits.conf"
    cat > "$lf" <<LIMITSEOF
* soft nofile ${nofile_limit}
* hard nofile ${nofile_limit}
* soft nproc ${nofile_limit}
* hard nproc ${nofile_limit}
LIMITSEOF
    ok "已写入: $lf"

    # --- modules-load.d ---
    local mf="/etc/modules-load.d/tcp-tune.conf"
    {
        echo "tcp_bbr"
        find "/lib/modules/$(uname -r)" -name "sch_fq.ko*" 2>/dev/null | grep -q . && echo "sch_fq"
    } > "$mf"
    ok "已写入: $mf"

    # --- systemd ---
    local sed_fail=0
    sed -i "/^#*DefaultLimitNOFILE=/c DefaultLimitNOFILE=${nofile_limit}" /etc/systemd/system.conf 2>/dev/null || sed_fail=1
    sed -i "/^#*DefaultLimitNPROC=/c DefaultLimitNPROC=${nofile_limit}" /etc/systemd/system.conf 2>/dev/null || sed_fail=1
    if [[ "$sed_fail" -eq 1 ]]; then
        warn "systemd 资源限制写入失败，请手动检查 /etc/systemd/system.conf。"
    fi

    # --- Xray systemd service override ---
    local xray_dropin_dir="/etc/systemd/system/xray.service.d"
    mkdir -p "$xray_dropin_dir"
    cat > "$xray_dropin_dir/99-tcp-tune.conf" <<XRAYEOF
[Service]
LimitNOFILE=${nofile_limit}
LimitNPROC=${nofile_limit}
TasksMax=infinity
XRAYEOF
    ok "Xray systemd override written: $xray_dropin_dir/99-tcp-tune.conf"


    # --- 确保 pam_limits.so 被加载 (root 用户也需显式配置) ---
    local pam_files=("common-session" "common-session-noninteractive" "sshd" "su" "login")
    local pam_fixed=0
    for pf in "${pam_files[@]}"; do
        if [[ -f "/etc/pam.d/$pf" ]]; then
            if ! grep -q "pam_limits.so" "/etc/pam.d/$pf" 2>/dev/null; then
                echo "session required pam_limits.so" >> "/etc/pam.d/$pf"
                pam_fixed=1
            fi
        fi
    done
    if [[ "$pam_fixed" -eq 1 ]]; then
                ok "已在 PAM 配置中添加 pam_limits.so (确保 limits.d 对 root 生效)"
    fi

    # --- /etc/profile.d 兜底 (非交互 shell / 某些 SSH 配置可能绕过 PAM) ---
    local profile_ulimit="/etc/profile.d/zzz-tcp-tune-ulimit.sh"
    cat > "$profile_ulimit" <<PROFEOF
# TCP 调优: 确保文件描述符限制 (兜底，针对绕过 PAM 的 session)
ulimit -n ${nofile_limit} 2>/dev/null || true
ulimit -u ${nofile_limit} 2>/dev/null || true
PROFEOF
    chmod +x "$profile_ulimit"
    ok "已写入 profile.d 兜底: $profile_ulimit"

    # --- SSH UsePAM 检查 (无 PAM 则 limits.d 完全不生效) ---
    if [[ -f /etc/ssh/sshd_config ]]; then
        if ! grep -q "^UsePAM yes" /etc/ssh/sshd_config 2>/dev/null; then
            if grep -q "^#UsePAM" /etc/ssh/sshd_config 2>/dev/null; then
                sed -i 's/^#UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
            elif grep -q "^UsePAM" /etc/ssh/sshd_config 2>/dev/null; then
                sed -i 's/^UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
            else
                echo "UsePAM yes" >> /etc/ssh/sshd_config
            fi
            ok "已在 sshd_config 中启用 UsePAM yes (limits.d 依赖 PAM)"
        fi
    fi
}

# ============================================================
# Choice Menu: 应用 / AI 提示 / 跳过
# ============================================================
choice_menu() {
    echo ""
    echo -e "${CYAN}${BOLD}======== 选择后续操作 ========${NC}"
    echo ""
    echo "  调优参数已生成，请选择后续操作:"
    echo ""
    echo "    1) 应用设置 + 生成 AI 提示词"
    echo "       - sysctl --system 使参数生效"
    echo "       - 生成 AI 提示词到 /root/tcp-ai-prompt.txt"
    echo ""
    echo "    2) 仅应用设置"
    echo "       - sysctl --system 使参数生效"
    echo "       - 跳过 AI 提示词"
    echo ""
    echo "    3) 仅生成 AI 提示词"
    echo "       - 仅生成 AI 提示词，不写入系统配置"
    echo "       - 生成 AI 提示词到 /root/tcp-ai-prompt.txt"
    echo ""
    echo "    4) 跳过"
    echo "       - 不写入系统配置，可稍后重跑本脚本"
    echo ""
    while true; do
        read -r -p "  请选择 [1-4]: " action < /dev/tty
        case "$action" in
            1) return 1 ;;
            2) return 2 ;;
            3) return 3 ;;
            4) return 4 ;;
            *) warn "请输入 1、2、3 或 4" ;;
        esac
    done
}

# ============================================================
# Phase 3: 报告 + 自定义调参模板
# ============================================================

generate_custom_template() {
    step "Phase 3: 生成个性化调参模板"

    local tmpl="/root/tcp-custom-template.sh"
    local vps_label="${CPU_CORES}核 ${RAM_GB_CEIL}G ${BANDWIDTH_MBPS}Mbps"

    cat > "$tmpl" <<TMPLEOF
#!/bin/bash
# ============================================================
# 个性化 TCP 调参模板
# 由 tcp-full.sh Phase 3 生成
# ============================================================
# VPS 配置: ${vps_label}
# 延迟基准: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms
# BDP:      ${TV[bdp_mb]} MB
# 缓冲上限: ${TV[buf_max_mb]} MB
# 当前内核: ${KERNEL_VER}
# BBRv3:    $($BBRV3_READY && echo "就绪" || echo "未安装")
#
# 你可以编辑此文件中以 #@ 标记的参数值来实现个性化调优
# 编辑后运行: sudo bash $tmpl
# ============================================================

#@ 内存上限 (GB)
MEM_GB=${RAM_GB_CEIL}

#@ 带宽 (Mbps)
BW_MBPS=${BANDWIDTH_MBPS}

#@ 延迟 (ms)
LATENCY_MS=${CHOSEN_LATENCY_MS}

# 以下参数根据上面的 VPS 规格自动计算
# ============================================================

#@ somaxconn (SYN 队列长度)
SOMAXCONN=${TV[somaxconn]}

#@ tcp_max_syn_backlog
SYN_BACKLOG=${TV[tcp_max_syn_backlog]}

#@ netdev_max_backlog
NETDEV_BACKLOG=${TV[netdev_max_backlog]}

#@ 缓冲区上限 (字节), ≤1G BDP / ≥2G BDP×2, 内存约8%上限, 硬上限 512MB
BUF_MAX=${TV[buf_max]}

#@ rmem_max / wmem_max
RMEM_MAX=\$BUF_MAX
WMEM_MAX=\$BUF_MAX

#@ tcp_rmem 中间值
RMEM_DEFAULT=${TV[tcp_rmem_default]}

#@ tcp_wmem 中间值
WMEM_DEFAULT=${TV[tcp_wmem_default]}


#@ tcp_fin_timeout
FIN_TIMEOUT=${TV[tcp_fin_timeout]}

#@ tcp_fastopen (3 = client + server)
FASTOPEN=${TV[tcp_fastopen]}

#@ tcp_mtu_probing (1 = 开启)
MTU_PROBING=${TV[tcp_mtu_probing]}

#@ keepalive 保活时间
KA_TIME=${TV[keepalive_time]}

#@ keepalive 探测间隔
KA_INTVL=${TV[keepalive_intvl]}

#@ keepalive 探测次数
KA_PROBES=${TV[keepalive_probes]}

#@ fs.file-max
FILE_MAX=${TV[file_max]}

#@ nofile / nproc 限制
NOFILE_LIMIT=${TV[nofile_limit]}
TCP_NOTSENT_LOWAT=${TV[tcp_notsent_lowat]}

#@ System protection
KERNEL_PANIC=${TV[kernel_panic]}
VM_SWAPPINESS=${TV[swappiness]}
VM_OVERCOMMIT_MEMORY=${TV[overcommit_memory]}
QDISC=${QDISC}

# ============================================================
# 应用配置 (可直接运行)
# ============================================================
cat > /etc/sysctl.d/zzzz-tcp-custom.conf <<EOF
# === 核心拥塞控制 ===
net.core.default_qdisc = \$QDISC
net.ipv4.tcp_congestion_control = bbr

# === 流量队列与积压 (适配 \$MEM_GB G 内存) ===
net.core.somaxconn = \$SOMAXCONN
net.ipv4.tcp_max_syn_backlog = \$SYN_BACKLOG
net.core.netdev_max_backlog = \$NETDEV_BACKLOG
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_notsent_lowat = \$TCP_NOTSENT_LOWAT

# === System protection baseline ===
kernel.panic = \$KERNEL_PANIC
vm.swappiness = \$VM_SWAPPINESS
vm.overcommit_memory = \$VM_OVERCOMMIT_MEMORY

# === 缓冲区: 动态上限锁定 \$(( BUF_MAX / 1024 / 1024 )) MB (防 OOM) ===
# 维持 default 较小，仅提高 max，满足突发大流量及 QUIC 需求
net.core.rmem_max = \$BUF_MAX
net.core.wmem_max = \$BUF_MAX
net.ipv4.tcp_rmem = 4096 \$RMEM_DEFAULT \$BUF_MAX
net.ipv4.tcp_wmem = 4096 \$WMEM_DEFAULT \$BUF_MAX

# === 内存压榨策略 ===

# === 协议栈基础与代理进阶优化 ===
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = \$FIN_TIMEOUT
net.ipv4.tcp_slow_start_after_idle = 0

# TCP Fast Open 降低延迟
net.ipv4.tcp_fastopen = \$FASTOPEN
# MTU 探测，防止跨国路由黑洞导致卡顿
net.ipv4.tcp_mtu_probing = \$MTU_PROBING

# === 连接保持 (防 GFW 阻断导致僵尸连接) ===
# 无响应连接回收时间
net.ipv4.tcp_keepalive_time = \$KA_TIME
net.ipv4.tcp_keepalive_intvl = \$KA_INTVL
net.ipv4.tcp_keepalive_probes = \$KA_PROBES

# === 系统级设置 ===
fs.file-max = \$FILE_MAX

# === 系统保命机制 ===
EOF

# 用户级资源限制 (仅 root)
cat > /etc/security/limits.d/99-custom-limits.conf <<EOF
* soft nofile \$NOFILE_LIMIT
* hard nofile \$NOFILE_LIMIT
* soft nproc \$NOFILE_LIMIT
* hard nproc \$NOFILE_LIMIT
EOF

# Systemd 补丁 (失败时提示)
sed -i "/^#*DefaultLimitNOFILE=/c DefaultLimitNOFILE=\$NOFILE_LIMIT" /etc/systemd/system.conf 2>/dev/null || echo "  [WARN] systemd DefaultLimitNOFILE 写入失败，请手动检查"
sed -i "/^#*DefaultLimitNPROC=/c DefaultLimitNPROC=\$NOFILE_LIMIT" /etc/systemd/system.conf 2>/dev/null || echo "  [WARN] systemd DefaultLimitNPROC 写入失败，请手动检查"

# 应用 (失败时提示)
if ! sysctl --system 2>&1 | grep -qiE "error|unknown|invalid"; then :; else
    echo "  [WARN] sysctl --system 可能存在部分错误，请查看上方输出"
fi
systemctl daemon-reexec 2>/dev/null || echo "  [WARN] systemctl daemon-reexec 失败"

# 验证 limits 生效情况
ULIMIT_NOW=\$(ulimit -n 2>/dev/null || echo "?")
echo "  ulimit -n: \${ULIMIT_NOW} (期望 >= \${NOFILE_LIMIT})"

# PAM 检查 (扫描所有常见 PAM 配置)
PAM_FOUND=0
for pam_f in common-session common-session-noninteractive sshd login su; do
    if grep -q "pam_limits.so" "/etc/pam.d/\$pam_f" 2>/dev/null; then
        PAM_FOUND=1
        break
    fi
done
if [[ "\$PAM_FOUND" -eq 0 ]]; then
    echo "  [WARN] pam_limits.so 未在任何 PAM 配置中检测到，limits.d 可能不会自动生效"
    echo "  [INFO] 建议在 /etc/pam.d/common-session 中添加: session required pam_limits.so"
fi
echo "  [INFO] 当前 session 可临时执行: ulimit -n \${NOFILE_LIMIT} && ulimit -u \${NOFILE_LIMIT}"
echo ""
echo "============================================"
echo "  自定义 TCP 调优已完成！"
echo "  VPS: ${vps_label}"
echo "  延迟: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms"
echo "  缓冲: ${TV[buf_max_mb]}MB (BDP ${TV[bdp_mb]}MB)"
echo "============================================"

# === 验证: 逐项回读参数 ===
echo ""
echo "===== 参数验证 ====="
_pass=0; _fail=0
_check() {
    if [[ "\$2" == "\$3" ]]; then
        echo "  [OK] \$1: \$2"
        ((_pass++))
    else
        echo "  [WARN] \$1: \$2 (期望 \$3)"
        ((_fail++))
    fi
}
_check "qdisc" "\$(sysctl -n net.core.default_qdisc)" "\$QDISC"
_check "cc" "\$(sysctl -n net.ipv4.tcp_congestion_control)" "bbr"
_check "kernel.panic" "\$(sysctl -n kernel.panic)" "10"
_check "vm.swappiness" "\$(sysctl -n vm.swappiness)" "1"
_check "vm.overcommit_memory" "\$(sysctl -n vm.overcommit_memory)" "1"
_check "rmem_max" "\$(sysctl -n net.core.rmem_max)" "\$BUF_MAX"
_check "wmem_max" "\$(sysctl -n net.core.wmem_max)" "\$BUF_MAX"
_check "somaxconn" "\$(sysctl -n net.core.somaxconn)" "\$SOMAXCONN"
_check "tcp_max_syn_backlog" "\$(sysctl -n net.ipv4.tcp_max_syn_backlog)" "\$SYN_BACKLOG"
_check "tcp_fastopen" "\$(sysctl -n net.ipv4.tcp_fastopen)" "3"
_check "tcp_mtu_probing" "\$(sysctl -n net.ipv4.tcp_mtu_probing)" "1"
_check "tcp_fin_timeout" "\$(sysctl -n net.ipv4.tcp_fin_timeout)" "\$FIN_TIMEOUT"
_check "keepalive_time" "\$(sysctl -n net.ipv4.tcp_keepalive_time)" "\$KA_TIME"
_check "fs.file-max" "\$(sysctl -n fs.file-max)" "\$FILE_MAX"
_ulimit=\$(ulimit -n 2>/dev/null || echo "?")
if [[ "\$_ulimit" =~ ^[0-9]+$ ]] && [[ "\$_ulimit" -ge \$NOFILE_LIMIT ]]; then
    echo "  [OK] ulimit -n: \$_ulimit (>= \$NOFILE_LIMIT)"
    ((_pass++))
else
    echo "  [WARN] ulimit -n: \$_ulimit (期望 >= \$NOFILE_LIMIT)"
    ((_fail++))
fi
echo "  验证: \$((_pass + _fail)) 项, \$_pass 通过, \$_fail 需关注"
TMPLEOF

    chmod +x "$tmpl"
    ok "自定义模板已生成: $tmpl"
    info "编辑 #@ 标记的参数后运行: sudo bash $tmpl"
}

# 生成 AI 提示词 (用于粘贴到 DeepSeek / ChatGPT 等获取更精细调参)
generate_ai_prompt() {
    local ai_prompt_file="/root/tcp-ai-prompt.txt"
    local vps_label="${CPU_CORES}核 ${RAM_GB_CEIL}G ${BANDWIDTH_MBPS}Mbps"
    local buf_max_mb="${TV[buf_max_mb]}"
    local bdp_mb="${TV[bdp_mb]}"

    # 按实际内存档位注入对应的调优原则，避免 1G 小内存提示词一刀切套用到所有机器
    local mem_policy
    if [[ $RAM_GB_CEIL -le 1 ]]; then
        mem_policy="## 内存适配调优原则（小内存 ${RAM_GB_CEIL}G：喂饱带宽同时防 OOM）
- 计算窗口必须用 BDP 公式，不要靠猜：带宽(Mbps) × RTT(s) / 8
- 示例：2000Mbps × 0.15s / 8 = 37.5 MB
- 理论上每个 TCP 连接至少需要 BDP 大小的缓冲才能跑满带宽
- 缓冲过低（如 30MB）会导致速度腰斩；应锁定在略高于理论值（如 BDP=37.5MB 时取 40MB），既喂饱带宽，又给小内存留足余量、避免 OOM
- tcp_rmem/tcp_wmem 的 default 应根据 BDP 动态计算，优先保证短连接和多线程起步速度
- 只有检测到 socket memory pressure 或 OOM 风险时才降低 default，不要因为内存小就先把 default 降到 2MiB
- 目标场景是 Xray 代理，应优先低重传，避免因缓冲、队列或拥塞窗口设置不当引发不必要重传
- 不要采用 512MB 这类过大的默认缓冲，小内存会周期性 OOM"
    elif [[ $RAM_GB_CEIL -eq 2 ]]; then
        mem_policy="## 内存适配调优原则（2G 档：缓冲转激进，预算要算账）
- 2G 内存允许进入激进档：rmem_max/wmem_max 目标 = BDP×2，仍受内存约 8% 上限（约 160MB）约束
- 预算账本：估算并发连接数 × tcp_rmem default 的总占用，不要让缓冲吃掉超过内存的约 8%，否则大流量下仍会 OOM
- default 起步缓冲按 BDP/4 计算并封顶 2MB，起步快且不冒进；只有实测内存压力时才下调
- 队列与积压按 2G 档放量：somaxconn / tcp_max_syn_backlog 约 8192，netdev_max_backlog 约 16384
- 低重传优先：fq/fq_codel + BBR，避免缓冲、队列或拥塞窗口设置不当引发不必要重传
- 不要无脑把缓冲顶到 512MB 硬上限，2G 内存跑大量并发连接时同样会周期性 OOM"
    elif [[ $RAM_GB_CEIL -le 4 ]]; then
        mem_policy="## 内存适配调优原则（${RAM_GB_CEIL}G 档：内存充裕，缓冲放开但留冗余）
- 内存余量充足：rmem_max/wmem_max = BDP×2，受内存约 8% 上限（约 250~340MB）约束，通常足以覆盖高带宽 × 高延迟的 BDP
- default 起步缓冲 = BDP/4（约 256KB~2MB 区间），保证短连接和多线程起步速度
- 队列可按本档放量：somaxconn / tcp_max_syn_backlog 约 16384，netdev_max_backlog 约 32768
- 若实测出现 orphan socket 堆积或 UDP/QUIC 压力，可评估 tcp_max_orphans、udp_mem 等 CONDITIONAL 参数，必须给出测量依据
- 低重传优先，维持稳定吞吐；不要把内存余量浪费在无意义的巨型缓冲上"
    elif [[ $RAM_GB_CEIL -le 8 ]]; then
        mem_policy="## 内存适配调优原则（${RAM_GB_CEIL}G 档：内存不再是瓶颈，硬上限与高并发是主题）
- 缓冲以 BDP×2 为基准，唯一硬约束是 512MB：高带宽（如 10Gbps）× 高 RTT 时 BDP 可达数百 MB，此时 rmem_max/wmem_max 顶到 512MB 附近
- default 起步缓冲仍建议 BDP/4 封顶 2MB，防止单连接起步就吞掉大块内存
- 队列/积压按大内存档：somaxconn 约 32768、netdev_max_backlog 约 65536，file-max/nofile 相应放量
- 高并发场景优先保证连接建立成功率与低重传，而不是继续堆缓冲
- 若高 PPS：评估 netdev_budget / netdev_budget_usecs 与 softirq 分布，给出 CPU 成本说明后再调整"
    else
        mem_policy="## 内存适配调优原则（${RAM_GB_CEIL}G 档：内存充裕，512MB 是唯一缓冲上限）
- 缓冲策略：rmem_max/wmem_max = min(BDP×2, 512MB)；内存约 8% 上限在本档通常不再生效
- 队列/积压可满配：somaxconn / tcp_max_syn_backlog 65535、netdev_max_backlog 65536、nofile 1048576 级别
- default 起步缓冲按 BDP/4 计算（256KB~2MB），既快又避免单连接异常膨胀
- 大内存下可考虑提高 tcp_max_orphans、放宽孤儿 socket 回收，但仅限实测确认压力后
- 优先低重传与连接建立成功率；缓冲已不是瓶颈，别为了「看起来更大」而堆无意义的大值"
    fi

    cat > "$ai_prompt_file" <<AIEOF
## XRAY_CORE_BASELINE
The target is Xray-core. Produce one safe baseline for an Xray service; do not split the answer into Nginx/HAProxy/Docker/Kubernetes or unrelated application profiles.
- Treat Xray as a high-concurrency user-space proxy with many inbound/outbound TCP sockets, possible UDP relay, and a mixture of persistent and short-lived connections.
- Do not change forwarding, TProxy, policy routing, nftables/iptables, conntrack, or UDP memory parameters unless the collected runtime facts prove that this Xray host uses those features and is under pressure.
- Generate an Xray systemd drop-in for xray.service. Set LimitNOFILE and LimitNPROC to the calculated value, set TasksMax=infinity, but do not impose MemoryMax unless an explicit service memory budget is supplied.
- Assume the target is xray.service. Do not perform service discovery, systemctl show/cat inspection, PID lookup, or /proc process-limit probing; write the xray.service drop-in directly.
- Prefer a dedicated late-loaded sysctl file. Do not delete or rewrite unrelated sysctl files, qdisc settings, or congestion-control settings merely because they differ. Detect and retain a supported qdisc: fq and fq_codel are both valid for BBRv3; preserve an active fq/fq_codel choice, otherwise try fq first and fq_codel as fallback. Retain rollback values.
- Preserve Xray JSON configuration. This task tunes the OS and service limits only; do not rewrite inbounds, outbounds, routing, or policy JSON.

## SYSTEM_PROTECTION_BASELINE
Always apply and verify this fixed baseline in the dedicated sysctl file:
- kernel.panic = 10
- vm.swappiness = 1
- vm.overcommit_memory = 1
Do not remove or substitute these values without an explicit user request.

## TCP_BUFFER_STARTUP_POLICY
Do not be overly conservative with TCP socket buffers.
Calculate tcp_rmem/tcp_wmem from BDP, use a startup default large enough for fast ramp-up,
and keep max at least BDP rounded up (target BDP×2 when RAM ≥ 2G).
Do not artificially cap default to 2MiB/4MiB just because the VPS has 1GB RAM;
only reduce it on measured memory pressure or OOM risk.

## XRAY_PROXY_LOW_RETRANSMISSION
Tune for Xray proxy with low retransmission as a priority: avoid unnecessary TCP retransmissions,
keep loss recovery responsive, and prefer stable throughput over aggressive queue expansion.

## HIGH_CONCURRENCY_PROXY_FOCUS
This configuration targets high-concurrency TCP proxy/forwarding workloads, not ordinary web servers. Priorities:
1. Connection capacity and connection-establishment success rate
2. Long-connection stability and short-connection reclamation
3. Bounded memory usage; avoid per-connection buffers causing OOM
4. Lower queueing latency without blindly increasing CPU usage

If unknown, mark these as NEEDS_CONFIRMATION instead of guessing: proxy software/version, TCP/UDP/QUIC ratio, long/short connection ratio, expected concurrent connections, new-connection rate, NAT/iptables usage, and systemd/cgroup limits.

## CONDITIONAL_PARAMETERS
Evaluate kernel support and workload relevance, then classify each as APPLY / CONDITIONAL / DO_NOT_CHANGE:
- TCP memory/queue: net.core.rmem_default, net.core.wmem_default, net.core.optmem_max, net.ipv4.tcp_notsent_lowat
- High PPS/softirq: net.core.netdev_budget, net.core.netdev_budget_usecs, net.core.dev_weight; explain CPU cost
- Orphan cleanup: net.ipv4.tcp_max_orphans, net.ipv4.tcp_orphan_retries; change only when orphan/socket memory pressure is confirmed
- NAT/firewall: nf_conntrack_max, nf_conntrack_buckets, nf_conntrack_tcp_timeout_time_wait; only when conntrack is enabled and table usage is measured
- UDP/QUIC: net.ipv4.udp_mem, net.ipv4.udp_rmem_min, net.ipv4.udp_wmem_min, plus rmem/wmem ceilings
- Service limits: systemd LimitNOFILE, LimitNPROC, TasksMax, MemoryMax, and the proxy software fd/connection-pool/worker settings
- Port planning: inspect ip_local_reserved_ports to avoid conflicts with proxy listeners, Docker/Kubernetes, or NodePort

Never make every queue, conntrack limit, orphan limit, or UDP memory value enormous just because it looks larger. Give current value, calculation basis, risk, and rollback value.

## DIAGNOSTICS_AND_ACCEPTANCE
Before generating changes, collect and record sysctl values, ulimit -n, /proc/meminfo, ss -s, NIC drops/errors, softirq, and conntrack usage when available. Do not inspect Xray service metadata, processes, or per-process limits. After generation:
- Write only parameters that exist and are writable on this kernel; skip unknown parameters with a warning
- Make the configuration idempotent; repeated execution must not create duplicate keys
- Provide both global sysctl and a service-level systemd override, preferring service-level limits
- Include backup, rollback commands, and verification output
- Provide load-test metrics: concurrent connections, connection-establishment rate, throughput, P99 latency, ESTAB/TIME_WAIT, RSS/OOM, packet drops, and CPU softirq
- Apply the required system-protection baseline (kernel.panic=10, vm.swappiness=1, vm.overcommit_memory=1). Do not modify other unrelated global settings such as IPv6 routing

你是一位 Linux 内核网络调优专家。请根据以下 VPS 的实际配置，生成一套定制化的 sysctl TCP 调优参数。

## VPS 配置
- CPU 核心数: ${CPU_CORES}
- 内存: ${RAM_MB} MB (约 ${RAM_GB_CEIL}G)
- Root filesystem disk: ${DISK_TOTAL_GB}G total / ${DISK_FREE_GB}G available / ${DISK_USED_PCT}% used
- 带宽: ${BANDWIDTH_MBPS} Mbps
- 系统: ${OS_NAME} ${OS_VERSION}
- 内核: ${KERNEL_VER}
- 架构: ${ARCH_TAG:-$(uname -m)}
- BBRv3 内核: $($BBRV3_READY && echo "已安装" || echo "未安装")

## 网络延迟
- IPv4 到 120.241.152.135: $( latency_available "$LATENCY_IPV4_MS" && echo "${LATENCY_IPV4_MS} ms" || echo "不可达" )
- IPv6 到 2409:8c54:871:1001::12: $( latency_available "$LATENCY_IPV6_MS" && echo "${LATENCY_IPV6_MS} ms" || echo "不可达" )
- 选用延迟基准: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms

${mem_policy}

## 环境补充信息
- 内核上游: ${SOURCE} ($([[ "$SOURCE" == "xdflight" ]] && echo "XDflight 内核默认编译 qdisc 可能为 fq_codel" || echo "byJoey 内核默认编译 fq"))
- 当前运行时 qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
- 当前运行时 cc: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
- sch_fq 模块: $(lsmod 2>/dev/null | grep -q sch_fq && echo "已加载" || find "/lib/modules/$(uname -r)" -name "sch_fq.ko*" 2>/dev/null | grep -q . && echo "存在但未加载" || echo "内置或不可用")
- systemd-networkd: $(systemctl is-active systemd-networkd 2>/dev/null || echo unknown)
- 特别注意: Ubuntu 24+ 使用 netplan/systemd-networkd 管理网络，可能覆盖 sysctl qdisc 设置

## 已计算的基准参数
- BDP (带宽延迟积): ${bdp_mb} MB
- 缓冲区上限: ${buf_max_mb} MB (≤1G 保守=BDP并四舍五入，≥2G 激进=BDP×2；内存约8%上限，硬上限 512MB)
- 当前已应用:
  - somaxconn = ${TV[somaxconn]}
  - tcp_max_syn_backlog = ${TV[tcp_max_syn_backlog]}
  - netdev_max_backlog = ${TV[netdev_max_backlog]}
  - rmem_max / wmem_max = ${TV[buf_max]}
  - tcp_rmem = 4096 ${TV[tcp_rmem_default]} ${TV[buf_max]}
  - tcp_wmem = 4096 ${TV[tcp_wmem_default]} ${TV[buf_max]}
  - tcp_fin_timeout = ${TV[tcp_fin_timeout]}
  - tcp_slow_start_after_idle = 0
  - tcp_fastopen = 3
  - tcp_mtu_probing = 1
  - tcp_keepalive_time = ${TV[keepalive_time]}
  - tcp_keepalive_intvl = ${TV[keepalive_intvl]}
  - tcp_keepalive_probes = ${TV[keepalive_probes]}
  - fs.file-max = ${TV[file_max]}
  - nofile / nproc 限制 = ${TV[nofile_limit]}

## 输出要求
请生成一个可直接执行的 bash 脚本，格式参考如下模板。要求:
1. 根据 ${RAM_GB_CEIL}G 内存和 ${BANDWIDTH_MBPS}Mbps 带宽重新计算最合理的参数
2. 根据 ${CHOSEN_LATENCY_MS}ms 延迟调整超时和保活参数
3. 给出每项参数的注释说明为什么选择这个值
4. 脚本开头必须备份现有配置 (tar czf /root/sysctl-backup-$(date +%Y%m%d%H%M%S).tgz /etc/sysctl.d/ /etc/sysctl.conf /etc/security/limits.d/ 2>/dev/null)
5. Do not scan, detect, or rewrite unrelated sysctl files; write only a dedicated late-loaded file and retain the detected supported fq or fq_codel qdisc
6. 写入配置文件后，每个参数都必须用 sysctl -w 直接写入运行时，确保立竿见影
7. Choose only fq or fq_codel: preserve a supported active fq/fq_codel; otherwise try fq first, then fq_codel. Never treat fq_codel as a conflict.
8. 如果是 Ubuntu 24+ 系统，请注意 systemd-networkd/netplan 可能覆盖 sysctl 中的 qdisc 设置
9. 每个写入操作都需要检测是否失败，失败要输出明确的错误警告
10. 脚本末尾必须包含参数验证部分：逐项使用 sysctl -n 回读每个参数值，与期望值比较，不一致的输出 [WARN]

输出格式模板 (将 [] 中的值替换为你的计算结果):
\`\`\`bash
#!/bin/bash
# TCP 调优参数 -- 由 AI 根据 VPS 配置生成
# VPS: ${vps_label}, 延迟: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms
# 注意: 不使用 set -e，每个命令已自带 || echo "[WARN]" 错误处理
# set -e + ((counter++)) 在 counter=0 时 ((0)) 返回码为 1 会导致脚本意外退出

# === 1. 备份现有配置 ===
BACKUP_FILE="/root/sysctl-backup-\$(date +%Y%m%d%H%M%S).tgz"
tar czf "\$BACKUP_FILE" /etc/sysctl.d/ /etc/sysctl.conf /etc/security/limits.d/ 2>/dev/null || true
echo "[INFO] 已备份到: \$BACKUP_FILE"

# === 2. Preserve unrelated configuration ===
# Do not inspect or rewrite unrelated sysctl files. This dedicated late-loaded file wins.
# Set SELECTED_QDISC to the detected supported value: fq or fq_codel.
SELECTED_QDISC="[detected fq or fq_codel]"
# === 3. 写入 sysctl 配置 (zzzz 字典序最后，压过所有) ===
cat > /etc/sysctl.d/zzzz-tcp-custom.conf <<EOF
# === 核心拥塞控制 ===
net.core.default_qdisc = \$SELECTED_QDISC
net.ipv4.tcp_congestion_control = bbr

# === System protection baseline ===
kernel.panic = 10
vm.swappiness = 1
vm.overcommit_memory = 1

# === 流量队列与积压 (适配 ${RAM_GB_CEIL}G 内存) ===
net.core.somaxconn = [你的建议值]
net.ipv4.tcp_max_syn_backlog = [你的建议值]
net.core.netdev_max_backlog = [你的建议值]

# === 缓冲区 (上限 [你的建议值]MB) ===
net.core.rmem_max = [你的建议值]
net.core.wmem_max = [你的建议值]
net.ipv4.tcp_rmem = [min] [default] [max]
net.ipv4.tcp_wmem = [min] [default] [max]

# === 内存压榨策略 ===

# === 协议栈优化 ===
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = [你的建议值]
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# === 连接保持 ===
net.ipv4.tcp_keepalive_time = [你的建议值]
net.ipv4.tcp_keepalive_intvl = [你的建议值]
net.ipv4.tcp_keepalive_probes = [你的建议值]

# === 系统级 ===
fs.file-max = [你的建议值]
EOF

# === 4. 写入 limits 配置 ===
cat > /etc/security/limits.d/99-zzz-custom-limits.conf <<EOF
root soft nofile [你的建议值]
root hard nofile [你的建议值]
root soft nproc [你的建议值]
root hard nproc [你的建议值]
EOF

sed -i "/^#*DefaultLimitNOFILE=/c DefaultLimitNOFILE=[你的建议值]" /etc/systemd/system.conf 2>/dev/null || echo "[WARN] systemd DefaultLimitNOFILE 写入失败，请手动检查"
sed -i "/^#*DefaultLimitNPROC=/c DefaultLimitNPROC=[你的建议值]" /etc/systemd/system.conf 2>/dev/null || echo "[WARN] systemd DefaultLimitNPROC 写入失败，请手动检查"
systemctl daemon-reexec 2>/dev/null || echo "[WARN] systemctl daemon-reexec 失败"

# === 5. 加载 sysctl 配置 ===
echo "[INFO] 加载所有 sysctl 配置..."
if ! sysctl --system 2>&1 | grep -qiE "error|unknown|invalid"; then :; else
    echo "[WARN] sysctl --system 可能存在部分错误，请查看上方输出"
fi

# === 6. 逐项 sysctl -w 强制写入运行时 (立竿见影) ===
echo "[INFO] 逐项强制写入运行时..."
sysctl -w net.core.default_qdisc="\$SELECTED_QDISC" 2>/dev/null || echo "[WARN] qdisc write failed"
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || echo "[WARN] cc 写入失败"
sysctl -w kernel.panic=10 2>/dev/null || echo "[WARN] kernel.panic write failed"
sysctl -w vm.swappiness=1 2>/dev/null || echo "[WARN] vm.swappiness write failed"
sysctl -w vm.overcommit_memory=1 2>/dev/null || echo "[WARN] vm.overcommit_memory write failed"
sysctl -w net.core.rmem_max=[你的建议值] 2>/dev/null || echo "[WARN] rmem_max 写入失败"
sysctl -w net.core.wmem_max=[你的建议值] 2>/dev/null || echo "[WARN] wmem_max 写入失败"
sysctl -w net.core.somaxconn=[你的建议值] 2>/dev/null || echo "[WARN] somaxconn 写入失败"
sysctl -w net.ipv4.tcp_max_syn_backlog=[你的建议值] 2>/dev/null || echo "[WARN] tcp_max_syn_backlog 写入失败"
sysctl -w net.core.netdev_max_backlog=[你的建议值] 2>/dev/null || echo "[WARN] netdev_max_backlog 写入失败"
sysctl -w net.ipv4.tcp_fastopen=[你的建议值] 2>/dev/null || echo "[WARN] tcp_fastopen 写入失败"
sysctl -w net.ipv4.tcp_mtu_probing=[你的建议值] 2>/dev/null || echo "[WARN] tcp_mtu_probing 写入失败"
sysctl -w net.ipv4.tcp_fin_timeout=[你的建议值] 2>/dev/null || echo "[WARN] tcp_fin_timeout 写入失败"
sysctl -w net.ipv4.tcp_slow_start_after_idle=[你的建议值] 2>/dev/null || echo "[WARN] tcp_slow_start_after_idle 写入失败"
sysctl -w net.ipv4.tcp_keepalive_time=[你的建议值] 2>/dev/null || echo "[WARN] keepalive_time 写入失败"
sysctl -w net.ipv4.tcp_keepalive_intvl=[你的建议值] 2>/dev/null || echo "[WARN] keepalive_intvl 写入失败"
sysctl -w net.ipv4.tcp_keepalive_probes=[你的建议值] 2>/dev/null || echo "[WARN] keepalive_probes 写入失败"
sysctl -w net.ipv4.tcp_rmem="[min] [default] [max]" 2>/dev/null || echo "[WARN] tcp_rmem 写入失败"
sysctl -w net.ipv4.tcp_wmem="[min] [default] [max]" 2>/dev/null || echo "[WARN] tcp_wmem 写入失败"
sysctl -w fs.file-max=[你的建议值] 2>/dev/null || echo "[WARN] fs.file-max 写入失败"
echo "[OK] 所有参数已强制写入运行时。"

# === 7. 验证: 逐项回读参数，确保正确应用 ===
echo ""
echo "===== 参数验证 ====="
_pass=0; _fail=0
_check() {
    if [[ "\$2" == "\$3" ]]; then
        echo "  [OK] \$1: \$2"
        ((_pass++))
    else
        echo "  [WARN] \$1: \$2 (期望 \$3)"
        ((_fail++))
    fi
}
_check "qdisc" "\$(sysctl -n net.core.default_qdisc)" "\$SELECTED_QDISC"
_check "cc" "\$(sysctl -n net.ipv4.tcp_congestion_control)" "bbr"
_check "kernel.panic" "\$(sysctl -n kernel.panic)" "10"
_check "vm.swappiness" "\$(sysctl -n vm.swappiness)" "1"
_check "vm.overcommit_memory" "\$(sysctl -n vm.overcommit_memory)" "1"
_check "rmem_max" "\$(sysctl -n net.core.rmem_max)" "[你的建议值]"
_check "wmem_max" "\$(sysctl -n net.core.wmem_max)" "[你的建议值]"
_check "somaxconn" "\$(sysctl -n net.core.somaxconn)" "[你的建议值]"
_check "tcp_max_syn_backlog" "\$(sysctl -n net.ipv4.tcp_max_syn_backlog)" "[你的建议值]"
_check "tcp_fastopen" "\$(sysctl -n net.ipv4.tcp_fastopen)" "3"
_check "tcp_mtu_probing" "\$(sysctl -n net.ipv4.tcp_mtu_probing)" "1"
_check "tcp_fin_timeout" "\$(sysctl -n net.ipv4.tcp_fin_timeout)" "[你的建议值]"
_check "tcp_slow_start_after_idle" "\$(sysctl -n net.ipv4.tcp_slow_start_after_idle)" "0"
_check "keepalive_time" "\$(sysctl -n net.ipv4.tcp_keepalive_time)" "[你的建议值]"
_check "fs.file-max" "\$(sysctl -n fs.file-max)" "[你的建议值]"
_ulimit=\$(ulimit -n 2>/dev/null || echo "?")
if [[ "\$_ulimit" =~ ^[0-9]+$ ]] && [[ "\$_ulimit" -ge [你的建议值] ]]; then
    echo "  [OK] ulimit -n: \$_ulimit (>= [你的建议值])"
    ((_pass++))
else
    echo "  [WARN] ulimit -n: \$_ulimit (期望 >= [你的建议值])"
    ((_fail++))
fi
echo "  验证: \$((_pass + _fail)) 项, \$_pass 通过, \$_fail 需关注"
\`\`\`

请直接输出完整结果。
AIEOF

    ok "AI 提示词已生成: $ai_prompt_file"
    info "将此文件内容粘贴到 DeepSeek / ChatGPT 等 AI 工具，获取更精细的调参建议。"
    echo ""
    echo -e "  ${BOLD}使用方法${NC}"
    echo "    1. cat /root/tcp-ai-prompt.txt       # 查看"
    echo "    2. 复制全文 → 粘贴到 AI 对话框"
    echo "    3. 将 AI 返回的脚本保存为 .sh，审查后运行"
}

print_final_report() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║          TCP 全流程调优 — 完成！                     ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    # ── VPS 规格 ──
    echo -e "  ${BOLD}━━━ VPS 规格 ━━━${NC}"
    echo -e "    CPU 核心:     ${CYAN}${CPU_CORES}${NC}"
    echo -e "    物理内存:     ${CYAN}${RAM_MB} MB${NC}"
    echo -e "    内存取整:     ${CYAN}${RAM_GB_CEIL} G${NC}"
    echo -e "    带宽:         ${CYAN}${BANDWIDTH_MBPS} Mbps${NC}"
    echo -e "    系统:         ${CYAN}${OS_NAME} ${OS_VERSION}${NC}"
    echo -e "    架构:         ${CYAN}${ARCH_TAG:-$(uname -m)}${NC}"
    echo ""

    # ── 内核 ──
    echo -e "  ${BOLD}━━━ 内核状态 ━━━${NC}"
    echo -e "    当前内核:     ${CYAN}${KERNEL_VER}${NC}"
    echo -e "    Root disk:     ${CYAN}${DISK_TOTAL_GB}G${NC} (available ${DISK_FREE_GB}G / used ${DISK_USED_PCT}%)"
    if $KERNEL_INSTALLED; then
        echo -e "    BBRv3:        ${GREEN}已安装 (${SOURCE}/${LATEST_TAG}) — 重启后生效${NC}"
    elif $BBRV3_READY; then
        echo -e "    BBRv3:        ${GREEN}已就绪${NC}"
    else
        echo -e "    BBRv3:        ${YELLOW}未安装${NC}"
    fi
    echo ""

    # ── 延迟 ──
    echo -e "  ${BOLD}━━━ 延迟测试 ━━━${NC}"
    if latency_available "$LATENCY_IPV4_MS"; then
        echo -e "    IPv4:         ${CYAN}${LATENCY_IPV4_MS} ms${NC}"
    else
        echo -e "    IPv4:         ${CYAN}不可用${NC}"
    fi
    if latency_available "$LATENCY_IPV6_MS"; then
        echo -e "    IPv6:         ${CYAN}${LATENCY_IPV6_MS} ms${NC}"
    else
        echo -e "    IPv6:         ${CYAN}不可用${NC}"
    fi
    echo -e "    选用基准:     ${GREEN}${CHOSEN_IP_STACK} — ${CHOSEN_LATENCY_MS} ms${NC}"
    echo ""

    # ── 调优参数 ──
    echo -e "  ${BOLD}━━━ 已应用调优 ━━━${NC}"
    echo -e "    拥塞控制:     ${GREEN}BBR${NC}"
    echo -e "    队列算法:     ${GREEN}${QDISC}${NC}"
    echo -e "    BDP:          ${CYAN}${TV[bdp_mb]} MB${NC}"
    echo -e "    缓冲上限:     ${CYAN}${TV[buf_max_mb]} MB${NC}"
    echo -e "    somaxconn:    ${CYAN}${TV[somaxconn]}${NC}"
    echo -e "    SYN backlog:  ${CYAN}${TV[tcp_max_syn_backlog]}${NC}"
    echo -e "    文件描述符:   ${CYAN}${TV[nofile_limit]}${NC}"
    local ul_show
    ul_show=$(ulimit -n 2>/dev/null || echo "?")
    echo -e "    ulimit -n:    ${CYAN}${ul_show}${NC}"
    echo -e "    TCP FastOpen: ${CYAN}3${NC}"
    echo -e "    MTU Probing:  ${CYAN}1${NC}"
    echo -e "    Keepalive:    ${CYAN}${TV[keepalive_time]}s / ${TV[keepalive_intvl]}s / ${TV[keepalive_probes]}次${NC}"
    echo ""

    # ── 配置文件 ──
    echo -e "  ${BOLD}━━━ 配置文件 ━━━${NC}"
    echo -e "    sysctl:       /etc/sysctl.d/zzz-tcp-tune.conf"
    echo -e "    limits:       /etc/security/limits.d/zzz-tcp-tune-limits.conf"
    echo -e "    modules:      /etc/modules-load.d/tcp-tune.conf"
    echo ""

    # ── 自定义模板 ──
    echo -e "  ${BOLD}━━━ 进阶自定义 ━━━${NC}"
    echo -e "    模板文件:     ${GREEN}/root/tcp-custom-template.sh${NC}"
    echo -e "    AI 提示词:   ${GREEN}/root/tcp-ai-prompt.txt${NC}"
    echo -e "    编辑模板中 #@ 参数后运行即可；或复制 AI 提示词到 DeepSeek/ChatGPT。"
    echo ""

    # ── 当前运行时状态 ──
    local cc_now qd_now
    cc_now=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    qd_now=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    echo -e "  ${BOLD}━━━ 当前运行时状态 ━━━${NC}"
    echo -e "    qdisc:        ${GREEN}${qd_now}${NC}"
    echo -e "    cc:           ${GREEN}${cc_now}${NC}"
    echo -e "    ulimit -n:    ${GREEN}$(ulimit -n 2>/dev/null || echo "?")${NC}"
    echo ""

    if $KERNEL_INSTALLED; then
        echo -e "  ${RED}${BOLD}请重启以启用 BBRv3 内核: reboot${NC}"
        echo ""
    fi
}

# ============================================================
# 主流程
# ============================================================
main() {
    parse_args "$@"

    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   TCP 全流程调优 v4.0                                ║"
    echo "║   Phase 1: BBRv3 内核  →  Phase 2: TCP 调优        ║"
    echo "║   Phase 3: 报告 + 模板 + AI 提示词                  ║"
    echo "║   上游: byJoey / XDflight                           ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root
    check_os

    # Phase 1
    phase1_install_kernel

    # Phase 2
    detect_qdisc
    detect_vps_specs
    test_latency
    choose_latency
    generate_tuning

    # ---- 调优前: 环境检测 + 残留文件清理 (先清理再调优) ----
    pre_apply_check

    # ---- Choice menu ----
    choice_menu
    local action=$?

    case $action in
        1)  # 应用设置 + AI 提示词 + 模板
            apply_config
            generate_custom_template
            generate_ai_prompt
            print_final_report
            ;;
        2)  # 仅应用设置 + 模板
            apply_config
            generate_custom_template
            print_final_report
            ;;
        3)  # 仅 AI 提示词 + 模板
            generate_custom_template
            generate_ai_prompt
            info "未写入任何系统配置文件。"
            print_final_report
            ;;
        4)  # 跳过
            generate_custom_template
            info "已跳过应用和 AI 提示词生成。"
            info "未写入任何系统配置文件。"
            print_final_report
            ;;
    esac
}

main "$@"
