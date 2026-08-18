#!/bin/bash
# ============================================================
# TCP 深度调优脚本 v1.0 (Ubuntu/Debian)
# ============================================================
#  1. 检测系统发行版 (Ubuntu / Debian)
#  2. 检测并启用 BBR + fq (根据内核能力自适应)
#  3. 检测 VPS 配置 (CPU / 内存，含向上取整)
#  4. 双栈延迟测试 (IPv4 / IPv6)
#  5. 用户选择 IPv4 或 IPv6 延迟基准
#  6. 结合内存、带宽、延迟自动生成 sysctl 调优参数
#  7. 写入 /etc/sysctl.d/zzz-tcp-tune.conf 并应用
# ============================================================

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- 全局变量 ----
OS_NAME=""
OS_VERSION=""
OS_ID=""
KERNEL_VER=""
CPU_CORES=0
RAM_MB=0
RAM_GB_CEIL=0      # 向上取整后的 GB 数
DISK_TOTAL_GB=0
DISK_FREE_GB=0
DISK_USED_PCT=0
BANDWIDTH_MBPS=0
LATENCY_IPV4_MS=-1
LATENCY_IPV6_MS=-1
CHOSEN_LATENCY_MS=0
CHOSEN_IP_STACK=""
BBRV3_READY=false
QDISC="fq"              # Preserve an active fq/fq_codel qdisc when supported
NOFILE_MODE="script"    # ulimit/nofile 参数来源: script=脚本内置分档值 / ai=交由 AI 提示词建议

# ---- 输出函数 ----
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}${BOLD}======================================${NC}"; echo -e "${CYAN}${BOLD}$*${NC}"; echo -e "${CYAN}${BOLD}======================================${NC}\n"; }
ask()   { echo -e "${YELLOW}[?]${NC} $*"; }

# ---- Root 检查 ----
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请使用 root 用户运行此脚本: sudo bash $0"
        exit 1
    fi
}

# ============================================================
# Step 1: 检测操作系统
# ============================================================
detect_os() {
    step "Step 1: 检测操作系统"

    if [[ ! -f /etc/os-release ]]; then
        err "无法读取 /etc/os-release，不支持此系统。"
        exit 1
    fi

    source /etc/os-release
    OS_NAME="$NAME"
    OS_VERSION="$VERSION_ID"
    OS_ID="$ID"

    info "系统: $OS_NAME $OS_VERSION"

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
            ok "支持的系统: $OS_ID (满足 Ubuntu >= 24.04)"
            ;;
        debian)
            # VERSION_ID 可能是数字(12)或代号(trixie/sid)或为空(testing)
            if [[ "$ver_major" =~ ^[0-9]+$ ]] && [[ "$ver_major" -lt 12 ]]; then
                err "Debian ${VERSION_ID} 不满足最低要求 (>= 12)。"
                err "BBRv3 内核需要 Debian 12 或更高版本。"
                exit 1
            fi
            ok "支持的系统: $OS_ID (满足 Debian >= 12)"
            ;;
        *)
            err "不支持的系统: $OS_ID。本脚本仅支持 Ubuntu 和 Debian。"
            exit 1
            ;;
    esac

    KERNEL_VER=$(uname -r)
    info "当前内核版本: $KERNEL_VER"
}

# ============================================================
# Step 2: 检测并启用 BBR + fq
# ============================================================
check_bbr() {
    step "Step 2: BBR 拥塞控制检测与启用"

    # 加载模块
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true

    # 检测可用拥塞控制算法
    local available
    available=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk '{print $3}')

    if echo "$available" | grep -q bbr; then
        ok "当前内核 $KERNEL_VER 支持 BBR, 可用算法: $available"
        BBRV3_READY=true
    else
        warn "当前内核 $KERNEL_VER 无 BBR 模块，可用算法: ${available:-无}"
        warn "调优配置仍会写入，但 BBR 无法启用。请升级内核后重新运行本脚本。"
        BBRV3_READY=false
    fi

    # 检测内核是否支持 fq qdisc
    detect_qdisc
}

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

# ============================================================
# Step 3: 检测 VPS 配置
# ============================================================
detect_vps_specs() {
    step "Step 3: 检测 VPS 配置"

    # CPU 核心数
    CPU_CORES=$(nproc)
    info "CPU 核心数: $CPU_CORES"

    # 内存 (MB)
    RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    info "物理内存: ${RAM_MB}MB"

    # 向上取整逻辑: >1G 但不满 2G 算 2G，>2G 但不满 3G 算 3G，以此类推
    RAM_GB_CEIL=$(( (RAM_MB + 1023) / 1024 ))
    # 最小 1G
    if [[ $RAM_GB_CEIL -lt 1 ]]; then
        RAM_GB_CEIL=1
    fi
    info "内存取整后 (向上取整): ${RAM_GB_CEIL}G"

    # 询问带宽
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
    echo -e "    常见参考: 100 | 300 | 500 | 1000 (1Gbps) | 2000 (2Gbps) | 10000 (10Gbps)"
    while true; do
        read -r -p "    带宽 (Mbps): " bw_input < /dev/tty
        if [[ "$bw_input" =~ ^[0-9]+$ ]] && [[ "$bw_input" -gt 0 ]]; then
            BANDWIDTH_MBPS=$bw_input
            break
        else
            warn "请输入有效的正整数。"
        fi
    done

    info "VPS 配置: ${CPU_CORES}核 / ${RAM_GB_CEIL}G内存 / ${BANDWIDTH_MBPS}Mbps带宽"
}

# ============================================================
# Step 4: 双栈延迟测试
# ============================================================
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
    step "Step 4: 双栈延迟测试"

    local ipv4_target="120.241.152.135"
    local ipv6_target="2409:8c54:871:1001::12"
    local log_v4="/tmp/tcp-tune-ping-v4.log"
    local log_v6="/tmp/tcp-tune-ping-v6.log"
    local loss_v4 loss_v6

    # ??????? RTT ??????????????????????
    info "IPv4 Ping → $ipv4_target ..."
    ping -c 5 -W 2 "$ipv4_target" > "$log_v4" 2>&1 || true
    LATENCY_IPV4_MS=$(ping_average_ms "$log_v4")
    if latency_available "$LATENCY_IPV4_MS"; then
        loss_v4=$(ping_packet_loss "$log_v4")
        ok "IPv4 延迟: ${LATENCY_IPV4_MS} ms (丢包: ${loss_v4:-丢包})"
    else
        warn "IPv4 Ping 失败，无法获取 RTT，可能封禁了 ICMP 或无 IPv4 路由。"
        LATENCY_IPV4_MS=-1
    fi

    info "IPv6 Ping → $ipv6_target ..."
    ping -c 5 -W 2 "$ipv6_target" > "$log_v6" 2>&1 || true
    LATENCY_IPV6_MS=$(ping_average_ms "$log_v6")
    if latency_available "$LATENCY_IPV6_MS"; then
        loss_v6=$(ping_packet_loss "$log_v6")
        ok "IPv6 延迟: ${LATENCY_IPV6_MS} ms (丢包: ${loss_v6:-丢包})"
    else
        warn "IPv6 Ping 失败，无法获取 RTT，可能封禁了 ICMP 或无 IPv6 路由。"
        LATENCY_IPV6_MS=-1
    fi
}

choose_latency() {
    step "Step 5: 选择延迟基准"

    echo "  测得延迟:"
    if latency_available "$LATENCY_IPV4_MS"; then
        echo -e "    ${GREEN}IPv4: ${LATENCY_IPV4_MS} ms${NC}"
    else
        echo -e "    ${RED}IPv4: 不可用${NC}"
    fi
    if latency_available "$LATENCY_IPV6_MS"; then
        echo -e "    ${GREEN}IPv6: ${LATENCY_IPV6_MS} ms${NC}"
    else
        echo -e "    ${RED}IPv6: 不可用${NC}"
    fi

    echo ""
    local v4_ok=0 v6_ok=0
    latency_available "$LATENCY_IPV4_MS" && v4_ok=1
    latency_available "$LATENCY_IPV6_MS" && v6_ok=1

    if [[ "$v4_ok" == "1" && "$v6_ok" == "1" ]]; then
        echo "  请选择延迟基准:"
        echo "    1) IPv4 (${LATENCY_IPV4_MS} ms)"
        echo "    2) IPv6 (${LATENCY_IPV6_MS} ms)"
        echo "    3) 取最大值 (取 max，更保守)"
        while true; do
            read -r -p "  请选择 [1-3]: " choice < /dev/tty
            case $choice in
                1) CHOSEN_LATENCY_MS=$LATENCY_IPV4_MS; CHOSEN_IP_STACK="IPv4"; break ;;
                2) CHOSEN_LATENCY_MS=$LATENCY_IPV6_MS; CHOSEN_IP_STACK="IPv6"; break ;;
                3) CHOSEN_LATENCY_MS=$(awk -v a="$LATENCY_IPV4_MS" -v b="$LATENCY_IPV6_MS" 'BEGIN{printf "%.1f", (a>b?a:b)}')
                   CHOSEN_IP_STACK="Max(IPv4/IPv6)"; break ;;
                *) warn "请输入 1、2 或 3" ;;
            esac
        done
    elif [[ "$v4_ok" == "1" ]]; then
        info "仅 IPv4 可用，自动选择 IPv4。"
        CHOSEN_LATENCY_MS=$LATENCY_IPV4_MS
        CHOSEN_IP_STACK="IPv4"
    elif [[ "$v6_ok" == "1" ]]; then
        info "仅 IPv6 可用，自动选择 IPv6。"
        CHOSEN_LATENCY_MS=$LATENCY_IPV6_MS
        CHOSEN_IP_STACK="IPv6"
    else
        warn "IPv4 与 IPv6 均不可达，使用默认 150ms。"
        CHOSEN_LATENCY_MS=150
        CHOSEN_IP_STACK="默认(150ms)"
    fi

    info "延迟基准: ${GREEN}${CHOSEN_IP_STACK}${NC}, 延迟: ${GREEN}${CHOSEN_LATENCY_MS} ms${NC}"
}

generate_tuning() {
    step "Step 6: 生成 TCP 调优参数 (内存: ${RAM_GB_CEIL}G / 带宽: ${BANDWIDTH_MBPS}Mbps / 延迟: ${CHOSEN_LATENCY_MS}ms)"

    # --- 计算 BDP (字节) ---
    # BDP = 带宽(bps) × RTT(s) / 8
    # 乘法先做，除法放到最后，避免 scale=0 导致分数被截断为 0
    bdp_bytes=$(awk -v bw="$BANDWIDTH_MBPS" -v lat="$CHOSEN_LATENCY_MS" 'BEGIN{printf "%d", bw*1000000/8*lat/1000}')
    # 内存分档决定缓冲策略：
    #   ≤1G：保守，缓冲 = BDP（四舍五入到整 MB）
    #   ≥2G：激进，缓冲 = BDP × 2
    local target_buf
    if [[ $RAM_GB_CEIL -le 1 ]]; then
        target_buf=$bdp_bytes
    else
        target_buf=$(( bdp_bytes * 2 ))
    fi

    # 内存侧上限：按实际内存的约 8% 计算，硬上限 512MB
    local mem_cap_buf
    mem_cap_buf=$(( RAM_MB * 1024 * 1024 / 12 ))
    local hard_cap_buf=$(( 512 * 1024 * 1024 ))
    [[ $mem_cap_buf -gt $hard_cap_buf ]] && mem_cap_buf=$hard_cap_buf

    if [[ $target_buf -lt $mem_cap_buf ]]; then
        buf_max=$target_buf
    else
        buf_max=$mem_cap_buf
        info "目标缓冲 ($(awk -v b="$target_buf" 'BEGIN{printf "%.1f", b/1024/1024}')MB) 超过内存上限，截断为 $(awk -v b="$buf_max" 'BEGIN{printf "%.1f", b/1024/1024}')MB。"
    fi

    # 最小值 4MB
    local buf_min_bytes=4194304
    if [[ $buf_max -lt $buf_min_bytes ]]; then
        buf_max=$buf_min_bytes
    fi

    # 低内存 VPS 四舍五入到整 MB，更保守
    if [[ $RAM_GB_CEIL -le 1 ]]; then
        buf_max=$(( (buf_max + 524288) / 1048576 * 1048576 ))
    fi

    info "BDP = $(awk -v b="$bdp_bytes" 'BEGIN{printf "%.2f", b/1024/1024}') MB"
    info "目标缓冲区 = $(awk -v b="$target_buf" 'BEGIN{printf "%.2f", b/1024/1024}') MB"
    info "实际缓冲区上限 = $(awk -v b="$buf_max" 'BEGIN{printf "%.2f", b/1024/1024}') MB"

    # --- 根据内存确定各类参数 ---
    # 内存分档
    # High-concurrency proxy: enlarge accept/SYN queues and bound default socket buffers.
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


    # Xray userspace write queue cap: bound unsent data per TCP socket.
    if [[ $RAM_GB_CEIL -le 2 ]]; then
        tcp_notsent_lowat=131072
    elif [[ $RAM_GB_CEIL -le 8 ]]; then
        tcp_notsent_lowat=262144
    else
        tcp_notsent_lowat=524288
    fi

    local socket_default
    socket_default=$(( bdp_bytes / 4 ))
    [[ $socket_default -lt 262144 ]] && socket_default=262144
    [[ $socket_default -gt 2097152 ]] && socket_default=2097152
    [[ $socket_default -ge $buf_max ]] && socket_default=$(( buf_max / 2 ))
    [[ $socket_default -lt 65536 ]] && socket_default=65536
    tcp_rmem_default=$socket_default
    tcp_wmem_default=$socket_default

    buf_max_mb=$(awk -v b="$buf_max" 'BEGIN{printf "%.2f", b/1024/1024}')
    info "生成参数: somaxconn=$somaxconn, nofile=$nofile_limit, buf_max=${buf_max_mb}MB"

    # 内存压榨策略 (全局变量，供 AI 提示词引用)

    # --- 根据延迟调整参数 ---

    tcp_fastopen=3
    tcp_mtu_probing=1
    tcp_slow_start_after_idle=0

    if awk -v l="$CHOSEN_LATENCY_MS" 'BEGIN{exit !(l<=50)}'; then
        # 低延迟 (<50ms)
        tcp_fin_timeout=10
        keepalive_time=300
        keepalive_intvl=10
        keepalive_probes=3
    elif awk -v l="$CHOSEN_LATENCY_MS" 'BEGIN{exit !(l<=150)}'; then
        # 中等延迟 (50-150ms)
        tcp_fin_timeout=15
        keepalive_time=600
        keepalive_intvl=15
        keepalive_probes=3
    else
        # 高延迟 (>150ms) - 跨国线路
        tcp_fin_timeout=20
        keepalive_time=900
        keepalive_intvl=30
        keepalive_probes=5
    fi

    # --- 拥塞控制算法 ---
    if $BBRV3_READY; then
        cc_algo="bbr"
        info "将使用 bbr 拥塞控制。"
    else
        cc_algo="bbr"
        warn "BBR 不可用，配置中将写入 bbr 但需内核支持才能生效。"
    fi

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
    local -a other=()
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
                zzzz-tcp-custom.conf|99-zzz-custom.conf|99-zzz-custom-limits.conf|99-custom-limits.conf) origin="AI/模板生成"; leftover+=("$f");;
                zzz-bbrv3.conf) origin="BBRv3 安装器"; leftover+=("$f");;
                10-console-messages.conf|10-ipv6-privacy.conf|10-kernel-hardening.conf|10-link-restrictions.conf|10-magic-sysrq.conf|10-map-count.conf|10-network-security.conf|10-ptrace.conf|10-zeropage.conf|20-yama.conf|50-default.conf|99-sysctl.conf) origin="系统默认";;
                *) origin="其他来源"; other+=("$f");;
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
        info "检测到 ${#leftover[@]} 个 AI/安装器生成的旧调优文件，建议清理（系统默认/其他来源文件未列入，见上表）:"
        local quoted="" f2
        for f2 in "${leftover[@]}"; do
            quoted+=" \"$f2\""
        done
        echo ""
        echo "  # 手动清理方式: 直接删除"
        echo "  rm -f${quoted}"
        echo ""
        echo -e "  ${YELLOW}${BOLD}是否现在删除以上 ${#leftover[@]} 个残留文件？${NC}${YELLOW}[y/N] (y=直接删除，直接回车=跳过)${NC}"
        local do_clean=""
        read -r do_clean </dev/tty 2>/dev/null || read -r do_clean || true
        if [[ "$do_clean" == "y" || "$do_clean" == "Y" ]]; then
            rm -f "${leftover[@]}" || warn "部分文件删除失败。"
            ok "已删除 ${#leftover[@]} 个残留文件。"
        else
            info "未清理残留文件，继续；注意字典序靠后的 zz 文件可能覆盖本次调优结果。"
        fi
        echo ""
    fi
    if [[ ${#other[@]} -gt 0 ]]; then
        warn "另有 ${#other[@]} 个【其他来源】调优文件（见上表）未加入清理命令，可能包含系统或应用自带配置，请人工确认后再决定是否删除。"
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
# Step 7: 应用配置
# ============================================================
apply_config() {
    step "Step 7: 应用配置"

    # 1. 加载内核模块
    modprobe tcp_bbr 2>/dev/null || true
    if [[ "$QDISC" == "fq" ]]; then
        modprobe sch_fq 2>/dev/null || true
    fi

    # 2. 扫除冲突配置: 禁用所有非 fq 的 qdisc + 非 bbr 的拥塞控制
    # The generated zzz sysctl file is loaded last. Preserve unrelated system configuration.
    # Do not rewrite other qdisc or congestion-control files here; rollback remains straightforward.

    # 写入调优配置（仅在用户选择应用后执行）
    write_config

    if sysctl --system 2>&1 | grep -qiE "error|unknown|invalid"; then
        warn "sysctl --system 可能存在部分错误，请查看上方输出。"
    fi

    # 4. 强制运行时生效 (使用检测到的 QDISC)，写入后立即回读验证
    sysctl -w net.core.default_qdisc="${QDISC}" 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
    sysctl -w kernel.panic=10 2>/dev/null || warn "kernel.panic write failed"
    sysctl -w vm.swappiness=1 2>/dev/null || warn "vm.swappiness write failed"
    sysctl -w vm.overcommit_memory=1 2>/dev/null || warn "vm.overcommit_memory write failed"
    local qdisc_runtime cc_runtime
    qdisc_runtime=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    cc_runtime=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$qdisc_runtime" != "${QDISC}" ]]; then
        warn "运行时 qdisc 未能切换为 ${QDISC} (当前: ${qdisc_runtime:-unknown})，重启 BBRv3 内核后生效。"
    fi
    if [[ "$cc_runtime" != "bbr" ]]; then
        warn "运行时 cc 未能切换为 bbr (当前: ${cc_runtime:-unknown})，重启后生效。"
    fi

    # 5. 写入 /etc/sysctl.conf 兜底
    local sed_fail=0
    if grep -q "^net\.core\.default_qdisc" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^net\.core\.default_qdisc.*/net.core.default_qdisc = ${QDISC}/" /etc/sysctl.conf || sed_fail=1
    else
        echo "" >> /etc/sysctl.conf || sed_fail=1
        echo "# TCP 调优: BBR + ${QDISC}" >> /etc/sysctl.conf || sed_fail=1
        echo "net.core.default_qdisc = ${QDISC}" >> /etc/sysctl.conf || sed_fail=1
    fi
    if grep -q "^net\.ipv4\.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^net\.ipv4\.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf || sed_fail=1
    else
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf || sed_fail=1
    fi
    if [[ "$sed_fail" -eq 1 ]]; then
        warn "/etc/sysctl.conf 兜底写入失败，请手动检查。"
    fi

    systemctl daemon-reload 2>/dev/null || warn "systemd daemon-reload failed; reload before restarting Xray."
    systemctl daemon-reexec 2>/dev/null || true

    # —— limits 生效验证 ——
    if [[ "$NOFILE_MODE" == "script" ]]; then
        # 当前 shell 是旧会话: soft limit 不会自动更新，hard limit 才是"能否达到"的关键；
        # xray.service 的实际限制由 systemd drop-in 决定，与 shell 的 ulimit 无关
        local ulimit_now ulimit_hard
        ulimit_now=$(ulimit -n 2>/dev/null || echo "?")
        ulimit_hard=$(ulimit -Hn 2>/dev/null || echo "?")
        info "当前会话 ulimit -n: ${ulimit_now} (hard: ${ulimit_hard})，期望 >= ${nofile_limit}"
        if [[ "$ulimit_hard" =~ ^[0-9]+$ && "$ulimit_hard" -lt "$nofile_limit" ]]; then
            warn "当前会话 hard limit 只有 ${ulimit_hard}，低于期望值：多为容器/母机限制，可重开 SSH 会话再试。"
            warn "不影响 xray.service：服务的 fd 限制由 systemd drop-in 直接设置，与 shell ulimit 无关。"
        elif [[ "$ulimit_now" =~ ^[0-9]+$ && "$ulimit_now" -lt "$nofile_limit" ]]; then
            info "当前会话 soft limit 未更新属正常（旧会话），新 SSH 会话将由 limits.d/profile.d 自动提升。"
        else
            ok "ulimit -n 已生效: ${ulimit_now}"
        fi
        if systemctl show xray.service -p LimitNOFILE >/dev/null 2>&1; then
            local svc_limit
            svc_limit=$(systemctl show xray.service -p LimitNOFILE 2>/dev/null | cut -d= -f2)
            info "xray.service LimitNOFILE: ${svc_limit:-未设置} (期望 >= ${nofile_limit})"
        fi
    else
        info "ulimit/nofile 参数交由 AI 建议，脚本未设置，跳过验证。"
    fi

    # 6. 最终验证
    local qdisc_final cc_final
    qdisc_final=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    cc_final=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")

    local all_ok=true
    if [[ "$qdisc_final" == "${QDISC}" ]]; then
        ok "队列算法: ${qdisc_final} ✓"
    else
        warn "队列算法: ${qdisc_final} (期望 ${QDISC})，重启后生效。"
        all_ok=false
    fi
    if [[ "$cc_final" == "bbr" ]]; then
        ok "拥塞控制: bbr ✓"
    else
        warn "拥塞控制: ${cc_final} (期望 bbr)，重启后生效。"
        all_ok=false
    fi

    if $all_ok; then
        ok "BBR + ${QDISC} 配对正确，已运行时生效。"
    else
        warn "部分参数需重启后生效。"
    fi

    ok "所有配置已应用！"

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
        # $1=label, $2=actual, $3=expected, $4=compare_op (default: eq)
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
    _check "rmem_max" "$actual" "${buf_max}"

    actual=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")
    _check "wmem_max" "$actual" "${buf_max}"

    # tcp_rmem = "min default max" (sysctl 输出以 TAB 分隔，统一归一化空白后比较)
    actual=$({ sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo "0 0 0"; } | tr -s ' \t' ' ')
    expected="4096 ${tcp_rmem_default} ${buf_max}"
    if [[ "$actual" == "$expected" ]]; then
        ok "  tcp_rmem: ${actual} ✓"
        ((pass++))
    else
        warn "  tcp_rmem: ${actual} (期望 ${expected})"
        ((fail++))
    fi

    actual=$({ sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo "0 0 0"; } | tr -s ' \t' ' ')
    expected="4096 ${tcp_wmem_default} ${buf_max}"
    if [[ "$actual" == "$expected" ]]; then
        ok "  tcp_wmem: ${actual} ✓"
        ((pass++))
    else
        warn "  tcp_wmem: ${actual} (期望 ${expected})"
        ((fail++))
    fi

    actual=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "?")
    _check "somaxconn" "$actual" "${somaxconn}"

    actual=$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo "?")
    _check "tcp_max_syn_backlog" "$actual" "${tcp_max_syn_backlog}"

    actual=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "?")
    _check "netdev_max_backlog" "$actual" "${netdev_max_backlog}"

    actual=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo "?")
    _check "ip_local_port_range" "$actual" "1024	65535"

    actual=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo "?")
    _check "tcp_syncookies" "$actual" "1"

    actual=$(sysctl -n net.ipv4.tcp_synack_retries 2>/dev/null || echo "?")
    _check "tcp_synack_retries" "$actual" "3"

    actual=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null || echo "?")
    _check "tcp_moderate_rcvbuf" "$actual" "1"

    actual=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "?")
    _check "tcp_notsent_lowat" "$actual" "${tcp_notsent_lowat}"

    actual=$(sysctl -n kernel.panic 2>/dev/null || echo "?")
    _check "kernel.panic" "$actual" "10"
    actual=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
    _check "vm.swappiness" "$actual" "1"
    actual=$(sysctl -n vm.overcommit_memory 2>/dev/null || echo "?")
    _check "vm.overcommit_memory" "$actual" "1"

    actual=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "?")
    _check "tcp_fastopen" "$actual" "${tcp_fastopen}"

    actual=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "?")
    _check "tcp_mtu_probing" "$actual" "${tcp_mtu_probing}"

    actual=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null || echo "?")
    _check "tcp_fin_timeout" "$actual" "${tcp_fin_timeout}"

    actual=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "?")
    _check "tcp_slow_start_after_idle" "$actual" "${tcp_slow_start_after_idle}"

    actual=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "?")
    _check "keepalive_time" "$actual" "${keepalive_time}"

    actual=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo "?")
    _check "keepalive_intvl" "$actual" "${keepalive_intvl}"

    actual=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo "?")
    _check "keepalive_probes" "$actual" "${keepalive_probes}"

    actual=$(sysctl -n fs.file-max 2>/dev/null || echo "?")
    _check "fs.file-max" "$actual" "${file_max}"

    # --- ulimit (仅 NOFILE_MODE=script 时验证; 以 hard limit 为准) ---
    if [[ "$NOFILE_MODE" == "script" ]]; then
        actual=$(ulimit -Hn 2>/dev/null || echo "?")
        _check "ulimit -Hn" "$actual" "${nofile_limit}" "ge"
        local ul_soft_now
        ul_soft_now=$(ulimit -n 2>/dev/null || echo "?")
        if [[ "$ul_soft_now" =~ ^[0-9]+$ && "$ul_soft_now" -lt "$nofile_limit" ]]; then
            info "  当前会话 ulimit -n=${ul_soft_now} 未更新属正常（旧会话），新 SSH 会话自动提升；xray.service 以 drop-in 为准。"
        fi
    else
        info "  ulimit/nofile 未由脚本设置（交由 AI 建议），跳过验证。"
    fi

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
# 步骤 7: 写入配置文件
# ============================================================
write_config() {
    step "写入调优配置文件"
    # --- 写入 sysctl 配置 (zzz- 确保字典序最后加载，覆盖其他默认值) ---
    local conf_file="/etc/sysctl.d/zzz-tcp-tune.conf"

    cat > "$conf_file" <<SYSCTLEOF
# ============================================================
# TCP 深度调优配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# VPS 配置: ${CPU_CORES}核 / ${RAM_GB_CEIL}G 内存 / ${BANDWIDTH_MBPS}Mbps 带宽
# Root filesystem: ${DISK_TOTAL_GB}G total / ${DISK_FREE_GB}G available / ${DISK_USED_PCT}% used
# 延迟基准: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms
# ============================================================

# === 核心拥塞控制 (BBR + ${QDISC}) ===
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${cc_algo}

# === 流量队列与积压 (适配 ${RAM_GB_CEIL}G 内存) ===
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

# === 缓冲区: 动态上限 (基于 BDP, 上限 ${buf_max_mb}MB) ===
# BDP = ${BANDWIDTH_MBPS}Mbps × ${CHOSEN_LATENCY_MS}ms = $(awk -v b="$bdp_bytes" 'BEGIN{printf "%.2f", b/1024/1024}')MB
net.core.rmem_max = ${buf_max}
net.core.wmem_max = ${buf_max}
net.ipv4.tcp_rmem = 4096 ${tcp_rmem_default} ${buf_max}
net.ipv4.tcp_wmem = 4096 ${tcp_wmem_default} ${buf_max}

# === 内存压榨策略 (适配 ${RAM_GB_CEIL}G) ===

# === 协议栈基础与代理进阶优化 ===
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = ${tcp_fin_timeout}
net.ipv4.tcp_slow_start_after_idle = ${tcp_slow_start_after_idle}

# TCP Fast Open (降低握手延迟)
net.ipv4.tcp_fastopen = ${tcp_fastopen}

# MTU 探测 (防止跨国路由黑洞)
net.ipv4.tcp_mtu_probing = ${tcp_mtu_probing}

# === 连接保持 (防僵尸连接) ===
net.ipv4.tcp_keepalive_time = ${keepalive_time}
net.ipv4.tcp_keepalive_intvl = ${keepalive_intvl}
net.ipv4.tcp_keepalive_probes = ${keepalive_probes}

# === IPv6 调优 (如果使用 IPv6) ===

# === 系统级设置 ===
fs.file-max = ${file_max}

# === 系统保命机制 ===
SYSCTLEOF

    ok "已写入 sysctl 配置: $conf_file"

    # --- 写入 limits 配置 (NOFILE_MODE=script 时) ---
    if [[ "$NOFILE_MODE" == "script" ]]; then
    local limits_file="/etc/security/limits.d/zzz-tcp-tune-limits.conf"
    cat > "$limits_file" <<LIMITSEOF
* soft nofile ${nofile_limit}
* hard nofile ${nofile_limit}
* soft nproc ${nofile_limit}
* hard nproc ${nofile_limit}
LIMITSEOF

    ok "已写入 limits 配置: $limits_file"
    else
    info "ulimit/nofile 参数交由 AI 建议，跳过 limits.d 写入。"
    fi

    # --- 写入 modules-load.d (开机自动加载必需模块) ---
    local modload_file="/etc/modules-load.d/tcp-tune.conf"
    {
        echo "# TCP 调优必需模块"
        echo "tcp_bbr"
        # 只有 fq 作为可加载模块存在时才写入 (内置则不需要)
        if [[ "$QDISC" == "fq" ]]; then
            find "/lib/modules/$(uname -r)" -name "sch_fq.ko*" 2>/dev/null | grep -q . && echo "sch_fq"
        fi
    } > "$modload_file"
    ok "已写入模块自动加载: $modload_file"

    # --- Systemd 补丁 (NOFILE_MODE=script 时) ---
    if [[ "$NOFILE_MODE" == "script" ]]; then
    local sed_fail=0
    sed -i "/^#*DefaultLimitNOFILE=/c DefaultLimitNOFILE=${nofile_limit}" /etc/systemd/system.conf 2>/dev/null || sed_fail=1
    sed -i "/^#*DefaultLimitNPROC=/c DefaultLimitNPROC=${nofile_limit}" /etc/systemd/system.conf 2>/dev/null || sed_fail=1
    if [[ "$sed_fail" -eq 1 ]]; then
        warn "systemd 资源限制写入失败，请手动检查 /etc/systemd/system.conf。"
    fi

    ok "已更新 systemd 资源限制。"
    fi

    # --- Xray systemd service override (NOFILE_MODE=script 时) ---
    if [[ "$NOFILE_MODE" == "script" ]]; then
    local xray_dropin_dir="/etc/systemd/system/xray.service.d"
    mkdir -p "$xray_dropin_dir"
    cat > "$xray_dropin_dir/99-tcp-tune.conf" <<XRAYEOF
[Service]
LimitNOFILE=${nofile_limit}
LimitNPROC=${nofile_limit}
TasksMax=infinity
XRAYEOF
    ok "Xray systemd override written: $xray_dropin_dir/99-tcp-tune.conf"
    fi


    # --- 确保 pam_limits.so 被加载 + profile.d 兜底 + UsePAM (NOFILE_MODE=script 时) ---
    if [[ "$NOFILE_MODE" == "script" ]]; then
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
    fi
}

# ============================================================
# ulimit/nofile 参数引导: y=脚本内置分档值 / n=交由 AI 提示词建议
# ============================================================
nofile_guide() {
    echo ""
    echo -e "${CYAN}${BOLD}  ulimit / nofile 参数处理方式${NC}"
    echo "    [y] 使用脚本内置分档值: ${nofile_limit} (按 ${RAM_GB_CEIL}G 内存档位计算)"
    echo "    [n] 不由脚本设置，交由 AI 提示词根据 VPS 情况建议"
    echo ""
    local ans=""
    while true; do
        read -r -p "  ulimit/nofile 使用脚本内置值？[y/N]: " ans < /dev/tty 2>/dev/null || read -r ans || true
        case "$ans" in
            y|Y) NOFILE_MODE="script"; return ;;
            n|N|"") NOFILE_MODE="ai"; return ;;
            *) warn "请输入 y 或 n (直接回车 = n)" ;;
        esac
    done
}

# ============================================================
# Choice Menu: 应用 / AI 提示 / 跳过
# ============================================================
choice_menu() {
    echo ""
    echo -e "${CYAN}${BOLD}======================================${NC}"
    echo -e "${CYAN}${BOLD}  选择后续操作${NC}"
    echo -e "${CYAN}${BOLD}======================================${NC}"
    echo ""
    echo "  调优参数已生成，请选择后续操作:"
    echo ""
    echo "    1) 应用设置 + 生成 AI 提示词"
    echo "       - sysctl --system 使参数生效"
    echo "       - 生成 AI 提示词到 /root/tcp-tune-ai-prompt.txt"
    echo ""
    echo "    2) 仅应用设置"
    echo "       - sysctl --system 使参数生效"
    echo "       - 跳过 AI 提示词"
    echo ""
    echo "    3) 仅生成 AI 提示词"
    echo "       - 仅生成 AI 提示词，不写入系统配置"
    echo "       - 生成 AI 提示词到 /root/tcp-tune-ai-prompt.txt"
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
# Generate AI Prompt (root 语法模板)
# ============================================================
generate_ai_prompt() {
    step "生成 AI 提示词"

    local ai_prompt_file="/root/tcp-tune-ai-prompt.txt"
    local vps_label="${CPU_CORES}核 ${RAM_GB_CEIL}G ${BANDWIDTH_MBPS}Mbps"
    local bdp_mb_val
    bdp_mb_val=$(awk -v b="${bdp_bytes:-0}" 'BEGIN{printf "%.2f", b/1024/1024}')

    # ulimit/nofile 参数来源 (nofile_guide 的 y/n 结果)
    local nofile_note nofile_rule
    if [[ "$NOFILE_MODE" == "script" ]]; then
        nofile_note=" (已由脚本应用，勿修改)"
        nofile_rule="11. nofile/nproc 已由脚本按 ${RAM_GB_CEIL}G 内存档位应用为 ${nofile_limit}（limits.d + systemd drop-in + profile.d 兜底），请勿修改该值"
    else
        nofile_note=" (脚本未应用，交由你建议)"
        nofile_rule="11. nofile/nproc 未由脚本设置：请根据 VPS 内存档位与容器限制给出建议值，写入 limits.d 与 xray systemd drop-in 并说明理由"
    fi

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

## 网络延迟
- IPv4 到 120.241.152.135: $( latency_available "$LATENCY_IPV4_MS" && echo "${LATENCY_IPV4_MS} ms" || echo "不可达" )
- IPv6 到 2409:8c54:871:1001::12: $( latency_available "$LATENCY_IPV6_MS" && echo "${LATENCY_IPV6_MS} ms" || echo "不可达" )
- 选用基准: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms

${mem_policy}

## 已计算的基准参数
- BDP: ${bdp_mb_val} MB
- 缓冲区上限: ${buf_max_mb} MB (≤1G 保守=BDP并四舍五入，≥2G 激进=BDP×2；内存约8%上限，硬上限 512MB)
- 当前已应用:
  - somaxconn = ${somaxconn}
  - tcp_max_syn_backlog = ${tcp_max_syn_backlog}
  - netdev_max_backlog = ${netdev_max_backlog}
  - rmem_max / wmem_max = ${buf_max}
  - tcp_rmem = 4096 ${tcp_rmem_default} ${buf_max}
  - tcp_wmem = 4096 ${tcp_wmem_default} ${buf_max}
  - tcp_fin_timeout = ${tcp_fin_timeout}
  - tcp_slow_start_after_idle = ${tcp_slow_start_after_idle}
  - tcp_fastopen = ${tcp_fastopen}
  - tcp_mtu_probing = ${tcp_mtu_probing}
  - tcp_keepalive_time = ${keepalive_time}
  - tcp_keepalive_intvl = ${keepalive_intvl}
  - tcp_keepalive_probes = ${keepalive_probes}
  - fs.file-max = ${file_max}
  - nofile / nproc 限制 = ${nofile_limit}${nofile_note}

## 输出要求
请生成一个 **可直接以 root 执行的 bash 脚本**，格式参考如下模板。要求:
1. 根据 ${RAM_GB_CEIL}G 内存和 ${BANDWIDTH_MBPS}Mbps 带宽重新计算最合理的参数
2. 根据 ${CHOSEN_LATENCY_MS}ms 延迟调整超时和保活参数
3. 给出每项参数的注释说明为什么选择这个值
4. 脚本开头必须备份现有配置 (tar czf /root/sysctl-backup-$(date +%Y%m%d%H%M%S).tgz /etc/sysctl.d/ /etc/sysctl.conf /etc/security/limits.d/ 2>/dev/null)
5. Do not delete or force-rewrite unrelated sysctl, qdisc, or congestion-control files; use a dedicated late-loaded file and provide rollback steps
6. 写入配置文件后，每个参数都必须用 sysctl -w 直接写入运行时，确保立竿见影
7. 每个写入操作都需要检测是否失败，失败要输出明确的错误警告
8. 脚本末尾必须包含参数验证部分：逐项使用 sysctl -n 回读，与期望值比较，不一致的输出 [WARN]
9. 验证多值参数 (tcp_rmem/tcp_wmem) 时必须先用 tr -s ' \t' ' ' 归一化空白再比较：sysctl -n 的输出以 TAB 分隔，用空格拼期望值会误报 WARN（模板已示范，请照抄）
10. 验证 ulimit 时用 ulimit -Hn (hard limit) 判断是否达标：当前 shell 的 soft limit 属于旧会话、不会自动更新，用它判断会产生假 WARN；xray.service 的实际限制以 systemctl show xray.service -p LimitNOFILE 和 systemd drop-in 为准（模板已示范，请照抄）
${nofile_rule}

输出格式模板 (将 [] 中的值替换为你的计算结果):
\`\`\`bash
#!/bin/bash
# TCP 调优参数 -- 由 AI 根据 VPS 配置生成
# VPS: ${vps_label}, 延迟: ${CHOSEN_LATENCY_MS}ms
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
# 多值参数: sysctl -n 的输出以 TAB 分隔，比较前必须用 tr 归一化空白，否则会误报 WARN
_check "tcp_rmem" "\$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | tr -s ' \t' ' ')" "4096 [你的建议default值] [你的建议max值]"
_check "tcp_wmem" "\$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | tr -s ' \t' ' ')" "4096 [你的建议default值] [你的建议max值]"
_check "somaxconn" "\$(sysctl -n net.core.somaxconn)" "[你的建议值]"
_check "tcp_max_syn_backlog" "\$(sysctl -n net.ipv4.tcp_max_syn_backlog)" "[你的建议值]"
_check "tcp_fastopen" "\$(sysctl -n net.ipv4.tcp_fastopen)" "3"
_check "tcp_mtu_probing" "\$(sysctl -n net.ipv4.tcp_mtu_probing)" "1"
_check "tcp_fin_timeout" "\$(sysctl -n net.ipv4.tcp_fin_timeout)" "[你的建议值]"
_check "tcp_slow_start_after_idle" "\$(sysctl -n net.ipv4.tcp_slow_start_after_idle)" "0"
_check "keepalive_time" "\$(sysctl -n net.ipv4.tcp_keepalive_time)" "[你的建议值]"
_check "fs.file-max" "\$(sysctl -n fs.file-max)" "[你的建议值]"
# ulimit 验证: 用 hard limit 判断能否达标；当前 shell 的 soft limit 是旧会话、不会自动更新，用它判断会产生假 WARN；xray.service 的实际限制以 systemd drop-in 为准
_ulimit_hard=\$(ulimit -Hn 2>/dev/null || echo "?")
if [[ "\$_ulimit_hard" =~ ^[0-9]+$ ]] && [[ "\$_ulimit_hard" -ge [你的建议值] ]]; then
    echo "  [OK] ulimit -Hn: \$_ulimit_hard (>= [你的建议值])"
    ((_pass++))
else
    echo "  [WARN] ulimit -Hn: \$_ulimit_hard (期望 >= [你的建议值])；可能是容器/母机限制，重开 SSH 会话再试；xray.service 以 systemd drop-in 为准"
    ((_fail++))
fi
echo "  [INFO] 当前会话 ulimit -n: \$(ulimit -n 2>/dev/null || echo "?") (旧会话未更新属正常，新登录自动生效)"
echo "  [INFO] xray.service LimitNOFILE: \$(systemctl show xray.service -p LimitNOFILE 2>/dev/null | cut -d= -f2 || echo 未设置) (期望 >= [你的建议值])"
echo "  验证: \$((_pass + _fail)) 项, \$_pass 通过, \$_fail 需关注"
\`\`\`

请直接输出完整结果。
AIEOF

    ok "AI 提示词已生成: $ai_prompt_file"
    info "将此文件内容粘贴到 DeepSeek / ChatGPT 等 AI 工具获取更精细调参建议。"
    echo ""
    echo -e "  ${BOLD}使用方法${NC}"
    echo "    1. cat ${ai_prompt_file}"
    echo "    2. 复制全文 → 粘贴到 AI 对话框"
    echo "    3. 将 AI 返回的脚本保存为 .sh，以 root 审查后运行"
}

# ============================================================
# 最终输出
# ============================================================
print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║         TCP 深度调优 — 完成！                    ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}VPS 配置${NC}"
    echo -e "    CPU 核心:  ${CYAN}${CPU_CORES}${NC}"
    echo -e "    内存:      ${CYAN}${RAM_GB_CEIL}G${NC} (实际 ${RAM_MB}MB)"
    echo -e "    Root disk:   ${CYAN}${DISK_TOTAL_GB}G${NC} (available ${DISK_FREE_GB}G / used ${DISK_USED_PCT}%)"
    echo -e "    带宽:      ${CYAN}${BANDWIDTH_MBPS}Mbps${NC}"
    echo ""
    echo -e "  ${BOLD}延迟测试${NC}"
    echo -e "    IPv4:      ${CYAN}${LATENCY_IPV4_MS} ms${NC}"
    echo -e "    IPv6:      ${CYAN}${LATENCY_IPV6_MS} ms${NC}"
    echo -e "    选用:      ${GREEN}${CHOSEN_IP_STACK} (${CHOSEN_LATENCY_MS} ms)${NC}"
    echo ""
    echo -e "  ${BOLD}应用配置${NC}"
    echo -e "    CC 算法:   ${CYAN}BBR${NC}"
    echo -e "    QDISC:     ${CYAN}${QDISC}${NC}"
    echo -e "    BDP:       ${CYAN}$(awk -v b="${bdp_bytes:-0}" 'BEGIN{printf "%.2f", b/1024/1024}') MB${NC}"
    echo -e "    缓冲区上限: ${CYAN}${buf_max_mb:-0} MB${NC}"
    if [[ "$NOFILE_MODE" == "script" ]]; then
        echo -e "    文件描述符: ${CYAN}${nofile_limit:-?}${NC} (脚本内置分档值)"
    else
        echo -e "    文件描述符: ${CYAN}未设置${NC} (交由 AI 提示词建议)"
    fi
    local ul_show
    ul_show=$(ulimit -n 2>/dev/null || echo "?")
    echo -e "    ulimit -n:  ${CYAN}${ul_show}${NC}"
    echo ""
    echo -e "  ${BOLD}配置文件${NC}"
    echo -e "    sysctl:    /etc/sysctl.d/zzz-tcp-tune.conf (字典序最后加载)"
    echo -e "    limits:    /etc/security/limits.d/zzz-tcp-tune-limits.conf"
    echo -e "    modules:   /etc/modules-load.d/tcp-tune.conf (开机自动加载 tcp_bbr)"
    echo ""

    # 验证当前状态
    local cc_now qdisc_now
    cc_now=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    qdisc_now=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    local ul_show
    ul_show=$(ulimit -n 2>/dev/null || echo "?")
    echo -e "  ${BOLD}当前状态${NC}"
    echo -e "    拥塞控制:  ${GREEN}${cc_now}${NC}"
    echo -e "    队列算法:  ${GREEN}${qdisc_now}${NC}"
    echo -e "    ulimit -n:  ${GREEN}${ul_show}${NC}"
    if [[ "$cc_now" == "bbr" && "$qdisc_now" == "${QDISC}" ]]; then
        echo -e "    ${GREEN}√ BBR + ${QDISC} 配对正确${NC}"
    else
        echo -e "    ${RED}✗ 预期 bbr + ${QDISC}，当前为 ${cc_now} + ${qdisc_now}${NC}"
    fi
    echo ""
}

# ============================================================
# 主流程
# ============================================================
main() {
    clear 2>/dev/null || true

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║     TCP 深度调优脚本 v1.0                        ║"
    echo "║     适用: Ubuntu / Debian                        ║"
    echo "║     功能: OS检测 | BBR+fq | 配置检测 | 延迟调优  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root

    # ---- 调优前: 环境检测 + 残留文件清理 (最先执行，先清理再调优) ----
    pre_apply_check

    detect_os
    check_bbr
    detect_vps_specs
    test_latency
    choose_latency
    generate_tuning

    # ---- ulimit/nofile 参数引导: y=脚本内置 / n=交由 AI ----
    nofile_guide

    # ---- Choice menu ----
    choice_menu
    local action=$?

    case $action in
        1)  # 应用设置 + AI 提示词
            apply_config
            print_summary
            generate_ai_prompt
            ;;
        2)  # 仅应用设置
            apply_config
            print_summary
            ;;
        3)  # 仅 AI 提示词
            generate_ai_prompt
            info "未写入任何系统配置文件。"
            ;;
        4)  # 跳过
            info "已跳过应用和 AI 提示词生成。"
            info "未写入任何系统配置文件。"
            ;;
    esac
}

main "$@"
