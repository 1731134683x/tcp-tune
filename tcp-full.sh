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
CPU_CORES=0; RAM_MB=0; RAM_GB_CEIL=0; BANDWIDTH_MBPS=0

# 延迟
LATENCY_IPV4_MS=0; LATENCY_IPV6_MS=0
CHOSEN_LATENCY_MS=0; CHOSEN_IP_STACK=""

# 调优参数
BBRV3_READY=false; QDISC="fq"
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
    case "$OS_ID" in
        ubuntu|debian) ok "系统: $OS_NAME $OS_VERSION" ;;
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

detect_vps_specs() {
    step "Phase 2: VPS 检测与 TCP 调优"

    CPU_CORES=$(nproc)
    RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    RAM_GB_CEIL=$(( (RAM_MB + 1023) / 1024 ))
    [[ $RAM_GB_CEIL -lt 1 ]] && RAM_GB_CEIL=1

    info "CPU: ${CPU_CORES} 核"
    info "内存: ${RAM_MB}MB → 向上取整 ${RAM_GB_CEIL}G"

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

test_latency() {
    local v4="120.241.152.135"
    local v6="2409:8c54:871:1001::12"
    local log4="/tmp/tcp-full-ping-v4.log"
    local log6="/tmp/tcp-full-ping-v6.log"

    info "IPv4 Ping → $v4 ..."
    if ping -c 5 -W 2 "$v4" > "$log4" 2>&1; then
        LATENCY_IPV4_MS=$(awk -F'/' '/^rtt/ {printf "%.1f", $5}' "$log4")
        local l4; l4=$(awk '/packet loss/ {print $6}' "$log4")
        ok "IPv4: ${LATENCY_IPV4_MS} ms (丢包: ${l4})"
    else
        warn "IPv4 Ping 失败。"; LATENCY_IPV4_MS=-1
    fi

    info "IPv6 Ping → $v6 ..."
    if ping -c 5 -W 2 "$v6" > "$log6" 2>&1; then
        LATENCY_IPV6_MS=$(awk -F'/' '/^rtt/ {printf "%.1f", $5}' "$log6")
        local l6; l6=$(awk '/packet loss/ {print $6}' "$log6")
        ok "IPv6: ${LATENCY_IPV6_MS} ms (丢包: ${l6})"
    else
        warn "IPv6 Ping 失败。"; LATENCY_IPV6_MS=-1
    fi
}

choose_latency() {
    echo ""
    echo "  测得延迟:"
    if [[ $(echo "$LATENCY_IPV4_MS > 0" | bc -l 2>/dev/null) == "1" ]]; then
        echo "    IPv4: ${LATENCY_IPV4_MS} ms"
    else
        echo "    IPv4: 不可用"
    fi
    if [[ $(echo "$LATENCY_IPV6_MS > 0" | bc -l 2>/dev/null) == "1" ]]; then
        echo "    IPv6: ${LATENCY_IPV6_MS} ms"
    else
        echo "    IPv6: 不可用"
    fi

    local v4_ok v6_ok
    v4_ok=$(echo "$LATENCY_IPV4_MS > 0" | bc -l 2>/dev/null || echo 0)
    v6_ok=$(echo "$LATENCY_IPV6_MS > 0" | bc -l 2>/dev/null || echo 0)

    if [[ "$v4_ok" == "1" && "$v6_ok" == "1" ]]; then
        echo "  请选择延迟基准:"
        echo "    1) IPv4 (${LATENCY_IPV4_MS} ms)"
        echo "    2) IPv6 (${LATENCY_IPV6_MS} ms)"
        echo "    3) 较高延迟 (保守策略)"
        while true; do
            read -r -p "  选择 [1-3]: " c < /dev/tty
            case $c in
                1) CHOSEN_LATENCY_MS=$LATENCY_IPV4_MS; CHOSEN_IP_STACK="IPv4"; break ;;
                2) CHOSEN_LATENCY_MS=$LATENCY_IPV6_MS; CHOSEN_IP_STACK="IPv6"; break ;;
                3) CHOSEN_LATENCY_MS=$(echo "if($LATENCY_IPV4_MS > $LATENCY_IPV6_MS) $LATENCY_IPV4_MS else $LATENCY_IPV6_MS" | bc -l)
                   CHOSEN_IP_STACK="Max(IPv4/IPv6)"; break ;;
                *) warn "请输入 1、2 或 3" ;;
            esac
        done
    elif [[ "$v4_ok" == "1" ]]; then
        info "仅 IPv4 可用。"; CHOSEN_LATENCY_MS=$LATENCY_IPV4_MS; CHOSEN_IP_STACK="IPv4"
    elif [[ "$v6_ok" == "1" ]]; then
        info "仅 IPv6 可用。"; CHOSEN_LATENCY_MS=$LATENCY_IPV6_MS; CHOSEN_IP_STACK="IPv6"
    else
        warn "双栈均不可达，使用默认 150ms。"; CHOSEN_LATENCY_MS=150; CHOSEN_IP_STACK="默认(150ms)"
    fi

    info "延迟基准: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS} ms"
}

generate_and_apply_tuning() {
    # --- BDP 计算 ---
    local bdp_bytes
    bdp_bytes=$(echo "scale=0; $BANDWIDTH_MBPS * 1000000 / 8 * $CHOSEN_LATENCY_MS / 1000" | bc)
    local target_buf; target_buf=$(echo "scale=0; $bdp_bytes * 2" | bc)

    # 内存上限: 每G约 20MB 缓冲
    local mem_cap_buf; mem_cap_buf=$(( RAM_GB_CEIL * 20 * 1024 * 1024 ))
    local buf_max
    if [[ $target_buf -lt $mem_cap_buf ]]; then buf_max=$target_buf; else buf_max=$mem_cap_buf; fi
    if [[ $buf_max -lt 4194304 ]]; then buf_max=4194304; fi  # 最小 4MB

    local buf_max_mb; buf_max_mb=$(echo "scale=0; $buf_max/1024/1024" | bc)
    info "BDP = $(echo "scale=2; $bdp_bytes/1024/1024" | bc) MB, 缓冲区上限 = ${buf_max_mb} MB"

    # --- 内存分档参数 ---
    local somaxconn tcp_max_syn_backlog netdev_max_backlog file_max nofile_limit
    local tcp_rmem_default tcp_wmem_default

    if [[ $RAM_GB_CEIL -le 1 ]]; then
        somaxconn=1024; tcp_max_syn_backlog=1024; netdev_max_backlog=2048
        file_max=512000; nofile_limit=32768
        tcp_rmem_default=87380; tcp_wmem_default=87380
    elif [[ $RAM_GB_CEIL -eq 2 ]]; then
        somaxconn=2048; tcp_max_syn_backlog=2048; netdev_max_backlog=4096
        file_max=1000000; nofile_limit=65535
        tcp_rmem_default=16777216; tcp_wmem_default=16777216
    elif [[ $RAM_GB_CEIL -le 4 ]]; then
        somaxconn=4096; tcp_max_syn_backlog=4096; netdev_max_backlog=8192
        file_max=1000000; nofile_limit=65535
        tcp_rmem_default=33554432; tcp_wmem_default=33554432
    elif [[ $RAM_GB_CEIL -le 8 ]]; then
        somaxconn=8192; tcp_max_syn_backlog=8192; netdev_max_backlog=16384
        file_max=2000000; nofile_limit=131072
        tcp_rmem_default=67108864; tcp_wmem_default=67108864
    else
        somaxconn=16384; tcp_max_syn_backlog=16384; netdev_max_backlog=32768
        file_max=4000000; nofile_limit=262144
        tcp_rmem_default=134217728; tcp_wmem_default=134217728
    fi

    # --- 延迟分档参数 ---
    local tcp_fin_timeout keepalive_time keepalive_intvl keepalive_probes tcp_slow_start_after_idle
    tcp_slow_start_after_idle=0

    if [[ $(echo "$CHOSEN_LATENCY_MS <= 50" | bc -l) -eq 1 ]]; then
        tcp_fin_timeout=10; keepalive_time=300; keepalive_intvl=10; keepalive_probes=3
    elif [[ $(echo "$CHOSEN_LATENCY_MS <= 150" | bc -l) -eq 1 ]]; then
        tcp_fin_timeout=15; keepalive_time=600; keepalive_intvl=15; keepalive_probes=3
    else
        tcp_fin_timeout=20; keepalive_time=900; keepalive_intvl=30; keepalive_probes=5
    fi

    local tcp_adv_win_scale
    tcp_adv_win_scale=$(( RAM_GB_CEIL <= 2 ? 30 : 20 ))

    # --- 保存到全局数组 (供 Phase 3 模板引用) ---
    TV[somaxconn]=$somaxconn
    TV[tcp_max_syn_backlog]=$tcp_max_syn_backlog
    TV[netdev_max_backlog]=$netdev_max_backlog
    TV[buf_max]=$buf_max
    TV[buf_max_mb]=$buf_max_mb
    TV[tcp_rmem_default]=$tcp_rmem_default
    TV[tcp_wmem_default]=$tcp_wmem_default
    TV[tcp_adv_win_scale]=$tcp_adv_win_scale
    TV[tcp_fin_timeout]=$tcp_fin_timeout
    TV[tcp_fastopen]=3
    TV[tcp_mtu_probing]=1
    TV[tcp_slow_start_after_idle]=$tcp_slow_start_after_idle
    TV[keepalive_time]=$keepalive_time
    TV[keepalive_intvl]=$keepalive_intvl
    TV[keepalive_probes]=$keepalive_probes
    TV[file_max]=$file_max
    TV[nofile_limit]=$nofile_limit
    TV[bdp_mb]=$(echo "scale=2; $bdp_bytes/1024/1024" | bc)

    # --- 写入 sysctl 配置 ---
    local conf="/etc/sysctl.d/zzz-tcp-tune.conf"
    cat > "$conf" <<SYSCTLEOF
# ============================================================
# TCP 深度调优 (tcp-full.sh 生成)
# 时间: $(date '+%Y-%m-%d %H:%M:%S')
# VPS: ${CPU_CORES}核 / ${RAM_GB_CEIL}G / ${BANDWIDTH_MBPS}Mbps
# 延迟: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms
# 内核: ${KERNEL_VER}
# ============================================================

# === 拥塞控制 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === 队列与积压 (${RAM_GB_CEIL}G) ===
net.core.somaxconn = ${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${tcp_max_syn_backlog}
net.core.netdev_max_backlog = ${netdev_max_backlog}

# === 缓冲区 (BDP $(echo "scale=2; ${bdp_bytes}/1024/1024" | bc)MB, 上限 ${buf_max_mb}MB) ===
net.core.rmem_max = ${buf_max}
net.core.wmem_max = ${buf_max}
net.ipv4.tcp_rmem = 4096 ${tcp_rmem_default} ${buf_max}
net.ipv4.tcp_wmem = 4096 ${tcp_wmem_default} ${buf_max}

# === 内存策略 ===
net.ipv4.tcp_adv_win_scale = ${tcp_adv_win_scale}

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
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.all.disable_ipv6 = 0

# === 系统级 ===
fs.file-max = ${file_max}
kernel.panic = 10
vm.swappiness = 1
vm.overcommit_memory = 1
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
    sed -i "/^#*DefaultLimitNOFILE=/c DefaultLimitNOFILE=${nofile_limit}" /etc/systemd/system.conf 2>/dev/null || true
    sed -i "/^#*DefaultLimitNPROC=/c DefaultLimitNPROC=${nofile_limit}" /etc/systemd/system.conf 2>/dev/null || true

    # --- 应用 ---
    info "应用配置..."

    # 禁用冲突配置: cubic / fq_codel / pfifo_fast 全部干掉
    local f
    for f in $(grep -rl "tcp_congestion_control.*=.*cubic" /etc/sysctl.d/ /usr/lib/sysctl.d/ /run/sysctl.d/ /etc/sysctl.conf 2>/dev/null || true); do
        [[ "$f" == *"zzz-tcp-tune"* ]] && continue
        warn "禁用 cubic: $f"
        sed -i "s/^net\.ipv4\.tcp_congestion_control\s*=\s*cubic/# [tcp-tune] 已禁用: &/" "$f"
    done
    for f in $(grep -rl "default_qdisc.*=.*fq_codel" /etc/sysctl.d/ /usr/lib/sysctl.d/ /run/sysctl.d/ /etc/sysctl.conf 2>/dev/null || true); do
        [[ "$f" == *"zzz-tcp-tune"* ]] && continue
        warn "禁用 fq_codel: $f"
        sed -i "s/^net\.core\.default_qdisc\s*=\s*fq_codel/# [tcp-tune] 已禁用: &/" "$f"
    done
    for f in $(grep -rl "default_qdisc.*=.*pfifo_fast" /etc/sysctl.d/ /usr/lib/sysctl.d/ /run/sysctl.d/ /etc/sysctl.conf 2>/dev/null || true); do
        [[ "$f" == *"zzz-tcp-tune"* ]] && continue
        warn "禁用 pfifo_fast: $f"
        sed -i "s/^net\.core\.default_qdisc\s*=\s*pfifo_fast/# [tcp-tune] 已禁用: &/" "$f"
    done

    sysctl --system
    sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true

    # /etc/sysctl.conf 兜底
    if grep -q "^net\.core\.default_qdisc" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^net\.core\.default_qdisc.*/net.core.default_qdisc = fq/" /etc/sysctl.conf
    else
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    fi
    if grep -q "^net\.ipv4\.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^net\.ipv4\.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf
    else
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    fi

    systemctl daemon-reexec 2>/dev/null || true

    # 验证
    local qd cc
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    ok "当前: qdisc=${qd}, cc=${cc}"
    if [[ "$qd" == "fq" && "$cc" == "bbr" ]]; then
        ok "BBR + fq 配对正确，已运行时生效。"
    else
        warn "部分参数需重启后对新内核生效。"
    fi
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

set -e

#@ 内存上限 (GB)
MEM_GB=${RAM_GB_CEIL}

#@ 带宽 (Mbps)
BW_MBPS=${BANDWIDTH_MBPS}

#@ 延迟 (ms)
LATENCY_MS=${CHOSEN_LATENCY_MS}

# ============================================================
# 以下参数根据上面的 VPS 规格自动计算
# ============================================================

#@ somaxconn (SYN 队列长度)
SOMAXCONN=${TV[somaxconn]}

#@ tcp_max_syn_backlog
SYN_BACKLOG=${TV[tcp_max_syn_backlog]}

#@ netdev_max_backlog
NETDEV_BACKLOG=${TV[netdev_max_backlog]}

#@ 缓冲区上限 (字节), BDP×2 与内存上限取 min
BUF_MAX=${TV[buf_max]}

#@ rmem_max / wmem_max
RMMEM_MAX=\$BUF_MAX
WMEM_MAX=\$BUF_MAX

#@ tcp_rmem 中间值
RMEM_DEFAULT=${TV[tcp_rmem_default]}

#@ tcp_wmem 中间值
WMEM_DEFAULT=${TV[tcp_wmem_default]}

#@ tcp_adv_win_scale
ADV_WIN_SCALE=${TV[tcp_adv_win_scale]}

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

# ============================================================
# 应用配置 (可直接运行)
# ============================================================
sudo bash -c '
cat > /etc/sysctl.d/99-zz-custom.conf <<EOF
# === 核心拥塞控制 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === 流量队列与积压 (适配 '\$MEM_GB'G 内存) ===
net.core.somaxconn = '\$SOMAXCONN'
net.ipv4.tcp_max_syn_backlog = '\$SYN_BACKLOG'
net.core.netdev_max_backlog = '\$NETDEV_BACKLOG'

# === 缓冲区: 动态上限锁定 '\$(( BUF_MAX / 1024 / 1024 ))'MB (防 OOM) ===
# 维持 default 较小，仅提高 max，满足突发大流量及 QUIC 需求
net.core.rmem_max = '\$BUF_MAX'
net.core.wmem_max = '\$BUF_MAX'
net.ipv4.tcp_rmem = 16384 '\$RMEM_DEFAULT' '\$BUF_MAX'
net.ipv4.tcp_wmem = 16384 '\$WMEM_DEFAULT' '\$BUF_MAX'

# === 内存压榨策略 ===
net.ipv4.tcp_adv_win_scale = '\$ADV_WIN_SCALE'

# === 协议栈基础与代理进阶优化 ===
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = '\$FIN_TIMEOUT'

# TCP Fast Open 降低延迟
net.ipv4.tcp_fastopen = '\$FASTOPEN'
# MTU 探测，防止跨国路由黑洞导致卡顿
net.ipv4.tcp_mtu_probing = '\$MTU_PROBING'

# === 连接保持 (防 GFW 阻断导致僵尸连接) ===
# 无响应连接回收时间
net.ipv4.tcp_keepalive_time = '\$KA_TIME'
net.ipv4.tcp_keepalive_intvl = '\$KA_INTVL'
net.ipv4.tcp_keepalive_probes = '\$KA_PROBES'

# === 系统级设置 ===
fs.file-max = '\$FILE_MAX'

# === 系统保命机制 ===
kernel.panic = 10
vm.swappiness = 1
vm.overcommit_memory = 1
EOF

# 用户级资源限制
cat > /etc/security/limits.d/99-custom-limits.conf <<EOF
* soft nofile '\$NOFILE_LIMIT'
* hard nofile '\$NOFILE_LIMIT'
* soft nproc '\$NOFILE_LIMIT'
* hard nproc '\$NOFILE_LIMIT'
EOF

# Systemd 补丁
sed -i "/^#*DefaultLimitNOFILE=/c DefaultLimitNOFILE='\$NOFILE_LIMIT'" /etc/systemd/system.conf
sed -i "/^#*DefaultLimitNPROC=/c DefaultLimitNPROC='\$NOFILE_LIMIT'" /etc/systemd/system.conf

# 应用
sysctl --system
systemctl daemon-reexec

echo ""
echo "============================================"
echo "  自定义 TCP 调优已完成！"
echo "  VPS: ${vps_label}"
echo "  延迟: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms"
echo "  缓冲: ${TV[buf_max_mb]}MB (BDP ${TV[bdp_mb]}MB)"
echo "============================================"
'
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

    cat > "$ai_prompt_file" <<AIEOF
你是一位 Linux 内核网络调优专家。请根据以下 VPS 的实际配置，生成一套定制化的 sysctl TCP 调优参数。

## VPS 配置
- CPU 核心数: ${CPU_CORES}
- 内存: ${RAM_MB} MB (约 ${RAM_GB_CEIL}G)
- 带宽: ${BANDWIDTH_MBPS} Mbps
- 系统: ${OS_NAME} ${OS_VERSION}
- 内核: ${KERNEL_VER}
- 架构: ${ARCH_TAG:-$(uname -m)}
- BBRv3 内核: $($BBRV3_READY && echo "已安装" || echo "未安装")

## 网络延迟
- IPv4 到 120.241.152.135: $([[ $(echo "$LATENCY_IPV4_MS > 0" | bc -l 2>/dev/null) == "1" ]] && echo "${LATENCY_IPV4_MS} ms" || echo "不可达")$
- IPv6 到 2409:8c54:871:1001::12: $([[ $(echo "$LATENCY_IPV6_MS > 0" | bc -l 2>/dev/null) == "1" ]] && echo "${LATENCY_IPV6_MS} ms" || echo "不可达")$
- 选用延迟基准: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms

## 已计算的基准参数
- BDP (带宽延迟积): ${bdp_mb} MB
- 缓冲区上限: ${buf_max_mb} MB (BDP×2 与内存限制取最小值)
- 当前已应用:
  - somaxconn = ${TV[somaxconn]}
  - tcp_max_syn_backlog = ${TV[tcp_max_syn_backlog]}
  - netdev_max_backlog = ${TV[netdev_max_backlog]}
  - rmem_max / wmem_max = ${TV[buf_max]}
  - tcp_rmem = 4096 ${TV[tcp_rmem_default]} ${TV[buf_max]}
  - tcp_wmem = 4096 ${TV[tcp_wmem_default]} ${TV[buf_max]}
  - tcp_adv_win_scale = ${TV[tcp_adv_win_scale]}
  - tcp_fin_timeout = ${TV[tcp_fin_timeout]}
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
4. 如果有更激进或更保守的调优建议，也请一并列出

输出格式模板 (将 [] 中的值替换为你的计算结果):
\`\`\`bash
sudo bash -c '
cat > /etc/sysctl.d/99-zz-custom.conf <<EOF
# === 核心拥塞控制 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

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
net.ipv4.tcp_adv_win_scale = [你的建议值]

# === 协议栈优化 ===
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = [你的建议值]
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# === 连接保持 ===
net.ipv4.tcp_keepalive_time = [你的建议值]
net.ipv4.tcp_keepalive_intvl = [你的建议值]
net.ipv4.tcp_keepalive_probes = [你的建议值]

# === 系统级 ===
fs.file-max = [你的建议值]
kernel.panic = 10
vm.swappiness = 1
vm.overcommit_memory = 1
EOF

cat > /etc/security/limits.d/99-custom-limits.conf <<EOF
* soft nofile [你的建议值]
* hard nofile [你的建议值]
* soft nproc [你的建议值]
* hard nproc [你的建议值]
EOF

sed -i "/^#*DefaultLimitNOFILE=/c DefaultLimitNOFILE=[你的建议值]" /etc/systemd/system.conf
sed -i "/^#*DefaultLimitNPROC=/c DefaultLimitNPROC=[你的建议值]" /etc/systemd/system.conf

sysctl --system
systemctl daemon-reexec
'
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
    echo -e "    IPv4:         ${CYAN}$([[ $(echo "$LATENCY_IPV4_MS > 0" | bc -l 2>/dev/null) == "1" ]] && echo "${LATENCY_IPV4_MS} ms" || echo "不可用")${NC}"
    echo -e "    IPv6:         ${CYAN}$([[ $(echo "$LATENCY_IPV6_MS > 0" | bc -l 2>/dev/null) == "1" ]] && echo "${LATENCY_IPV6_MS} ms" || echo "不可用")${NC}"
    echo -e "    选用基准:     ${GREEN}${CHOSEN_IP_STACK} — ${CHOSEN_LATENCY_MS} ms${NC}"
    echo ""

    # ── 调优参数 ──
    echo -e "  ${BOLD}━━━ 已应用调优 ━━━${NC}"
    echo -e "    拥塞控制:     ${GREEN}BBR${NC}"
    echo -e "    队列算法:     ${GREEN}fq${NC}"
    echo -e "    BDP:          ${CYAN}${TV[bdp_mb]} MB${NC}"
    echo -e "    缓冲上限:     ${CYAN}${TV[buf_max_mb]} MB${NC}"
    echo -e "    somaxconn:    ${CYAN}${TV[somaxconn]}${NC}"
    echo -e "    SYN backlog:  ${CYAN}${TV[tcp_max_syn_backlog]}${NC}"
    echo -e "    文件描述符:   ${CYAN}${TV[nofile_limit]}${NC}"
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
    detect_vps_specs
    test_latency
    choose_latency

    echo ""
    ask "确认应用以上 TCP 调优配置? [Y/n]: "
    read -r confirm < /dev/tty
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        warn "用户取消。"
        # 仍然生成模板
        generate_custom_template
        exit 0
    fi

    generate_and_apply_tuning

    # Phase 3
    generate_custom_template

    echo ""
    ask "是否生成 AI 提示词模板? (用于粘贴到 DeepSeek/ChatGPT 等获取更精细的调参建议) [Y/n]: "
    read -r ai_ans < /dev/tty
    if [[ "$ai_ans" != "n" && "$ai_ans" != "N" ]]; then
        generate_ai_prompt
    fi

    print_final_report
}

main "$@"
