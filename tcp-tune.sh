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
BANDWIDTH_MBPS=0
LATENCY_IPV4_MS=0
LATENCY_IPV6_MS=0
CHOSEN_LATENCY_MS=0
CHOSEN_IP_STACK=""
BBRV3_READY=false
QDISC="fq"              # 目标 qdisc (始终 fq，当前内核不支持则重启后生效)

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

    info "系统: $OS_NAME"
    info "版本: $OS_VERSION"

    case "$OS_ID" in
        ubuntu|debian)
            ok "支持的系统: $OS_ID"
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
    if sysctl -w net.core.default_qdisc=fq 2>/dev/null; then
        ok "qdisc: fq (当前内核支持，已运行时生效)"
        return
    fi
    warn "当前内核不支持 fq 队列 (sch_fq 不可用)。"
    warn "配置文件将写入 fq，安装 BBRv3 内核并重启后自动生效。"
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
test_latency() {
    step "Step 4: 双栈延迟测试"

    local ipv4_target="120.241.152.135"
    local ipv6_target="2409:8c54:871:1001::12"

    # ---- IPv4 Ping ----
    info "正在测试 IPv4 到 $ipv4_target ..."
    if ping -c 5 -W 2 "$ipv4_target" > /tmp/tcp-tune-ping-v4.log 2>&1; then
        LATENCY_IPV4_MS=$(awk -F'/' '/^rtt/ {printf "%.1f", $5}' /tmp/tcp-tune-ping-v4.log)
        local loss_v4
        loss_v4=$(awk '/packet loss/ {print $6}' /tmp/tcp-tune-ping-v4.log)
        ok "IPv4 延迟: ${LATENCY_IPV4_MS} ms (丢包: ${loss_v4})"
    else
        warn "IPv4 Ping 失败，可能无 IPv4 网络。"
        LATENCY_IPV4_MS=-1
    fi

    # ---- IPv6 Ping ----
    info "正在测试 IPv6 到 $ipv6_target ..."
    if ping -c 5 -W 2 "$ipv6_target" > /tmp/tcp-tune-ping-v6.log 2>&1; then
        LATENCY_IPV6_MS=$(awk -F'/' '/^rtt/ {printf "%.1f", $5}' /tmp/tcp-tune-ping-v6.log)
        local loss_v6
        loss_v6=$(awk '/packet loss/ {print $6}' /tmp/tcp-tune-ping-v6.log)
        ok "IPv6 延迟: ${LATENCY_IPV6_MS} ms (丢包: ${loss_v6})"
    else
        warn "IPv6 Ping 失败，可能无 IPv6 网络。"
        LATENCY_IPV6_MS=-1
    fi
}

# ============================================================
# Step 5: 用户选择延迟基准
# ============================================================
choose_latency() {
    step "Step 5: 选择延迟基准"

    echo "  测得延迟:"
    [[ $(echo "$LATENCY_IPV4_MS > 0" | bc -l 2>/dev/null || echo 0) -eq 1 ]] \
        && echo -e "    ${GREEN}IPv4: ${LATENCY_IPV4_MS} ms${NC}" \
        || echo -e "    ${RED}IPv4: 不可用${NC}"
    [[ $(echo "$LATENCY_IPV6_MS > 0" | bc -l 2>/dev/null || echo 0) -eq 1 ]] \
        && echo -e "    ${GREEN}IPv6: ${LATENCY_IPV6_MS} ms${NC}" \
        || echo -e "    ${RED}IPv6: 不可用${NC}"

    echo ""

    # 自动判断可用选项
    local v4_ok v6_ok
    v4_ok=$(echo "$LATENCY_IPV4_MS > 0" | bc -l 2>/dev/null || echo 0)
    v6_ok=$(echo "$LATENCY_IPV6_MS > 0" | bc -l 2>/dev/null || echo 0)

    if [[ "$v4_ok" == "1" && "$v6_ok" == "1" ]]; then
        echo "  请选择延迟调优基准:"
        echo "    1) IPv4 (${LATENCY_IPV4_MS} ms)"
        echo "    2) IPv6 (${LATENCY_IPV6_MS} ms)"
        echo "    3) 使用较高延迟 (取 max，保守策略)"
        while true; do
            read -r -p "  选择 [1-3]: " choice < /dev/tty
            case $choice in
                1) CHOSEN_LATENCY_MS=$LATENCY_IPV4_MS; CHOSEN_IP_STACK="IPv4"; break ;;
                2) CHOSEN_LATENCY_MS=$LATENCY_IPV6_MS; CHOSEN_IP_STACK="IPv6"; break ;;
                3) CHOSEN_LATENCY_MS=$(echo "if($LATENCY_IPV4_MS > $LATENCY_IPV6_MS) $LATENCY_IPV4_MS else $LATENCY_IPV6_MS" | bc -l)
                   CHOSEN_IP_STACK="Max(IPv4/IPv6)"; break ;;
                *) warn "请输入 1、2 或 3" ;;
            esac
        done
    elif [[ "$v4_ok" == "1" ]]; then
        info "仅 IPv4 可用，自动选择 IPv4 延迟基准。"
        CHOSEN_LATENCY_MS=$LATENCY_IPV4_MS
        CHOSEN_IP_STACK="IPv4"
    elif [[ "$v6_ok" == "1" ]]; then
        info "仅 IPv6 可用，自动选择 IPv6 延迟基准。"
        CHOSEN_LATENCY_MS=$LATENCY_IPV6_MS
        CHOSEN_IP_STACK="IPv6"
    else
        warn "IPv4 和 IPv6 均不可达！将使用默认延迟 150ms。"
        CHOSEN_LATENCY_MS=150
        CHOSEN_IP_STACK="默认(150ms)"
    fi

    info "选择: ${GREEN}${CHOSEN_IP_STACK}${NC}, 延迟基准: ${GREEN}${CHOSEN_LATENCY_MS} ms${NC}"
}

# ============================================================
# Step 6: 生成调优参数
# ============================================================
generate_tuning() {
    step "Step 6: 生成 TCP 调优参数 (内存: ${RAM_GB_CEIL}G / 带宽: ${BANDWIDTH_MBPS}Mbps / 延迟: ${CHOSEN_LATENCY_MS}ms)"

    # --- 计算 BDP (字节) ---
    # BDP = 带宽(bps) × RTT(s) / 8
    # 乘法先做，除法放到最后，避免 scale=0 导致分数被截断为 0
    bdp_bytes=$(echo "scale=0; $BANDWIDTH_MBPS * 1000000 / 8 * $CHOSEN_LATENCY_MS / 1000" | bc)
    # 目标缓冲区 = BDP × 2
    local target_buf
    target_buf=$(echo "scale=0; $bdp_bytes * 2" | bc)

    # 根据内存限制缓冲区最大值
    local mem_cap_buf
    mem_cap_buf=$(( RAM_GB_CEIL * 1024 * 1024 * 256 / 64 ))  # ~每G内存分配4MB上限缓冲区

    # 更合理的上限: 每G内存约 20MB 缓冲区
    mem_cap_buf=$(( RAM_GB_CEIL * 20 * 1024 * 1024 ))

    local buf_max
    if [[ $target_buf -lt $mem_cap_buf ]]; then
        buf_max=$target_buf
    else
        buf_max=$mem_cap_buf
        info "BDP×2 ($(echo "scale=1; $target_buf/1024/1024" | bc)MB) 超过内存限制，上限截断为 $(echo "scale=1; $buf_max/1024/1024" | bc)MB。"
    fi

    # 最小值 4MB
    local buf_min_bytes=4194304
    if [[ $buf_max -lt $buf_min_bytes ]]; then
        buf_max=$buf_min_bytes
    fi

    info "BDP = $(echo "scale=2; $bdp_bytes/1024/1024" | bc) MB"
    info "目标缓冲区 (BDP×2) = $(echo "scale=2; $target_buf/1024/1024" | bc) MB"
    info "实际缓冲区上限 = $(echo "scale=2; $buf_max/1024/1024" | bc) MB"

    # --- 根据内存确定各类参数 ---
    local somaxconn tcp_max_syn_backlog netdev_max_backlog
    local file_max tcp_rmem_default tcp_wmem_default tcp_rmem_max tcp_wmem_max

    # 内存分档
    if [[ $RAM_GB_CEIL -le 1 ]]; then
        # 1G 内存
        somaxconn=1024
        tcp_max_syn_backlog=1024
        netdev_max_backlog=2048
        file_max=512000
        nofile_limit=32768
        tcp_rmem_default=87380
        tcp_wmem_default=87380
    elif [[ $RAM_GB_CEIL -eq 2 ]]; then
        # 2G 内存
        somaxconn=2048
        tcp_max_syn_backlog=2048
        netdev_max_backlog=4096
        file_max=1000000
        nofile_limit=65535
        tcp_rmem_default=16777216
        tcp_wmem_default=16777216
    elif [[ $RAM_GB_CEIL -le 4 ]]; then
        # 3-4G 内存
        somaxconn=4096
        tcp_max_syn_backlog=4096
        netdev_max_backlog=8192
        file_max=1000000
        nofile_limit=65535
        tcp_rmem_default=33554432
        tcp_wmem_default=33554432
    elif [[ $RAM_GB_CEIL -le 8 ]]; then
        # 5-8G 内存
        somaxconn=8192
        tcp_max_syn_backlog=8192
        netdev_max_backlog=16384
        file_max=2000000
        nofile_limit=131072
        tcp_rmem_default=67108864
        tcp_wmem_default=67108864
    else
        # >8G 内存
        somaxconn=16384
        tcp_max_syn_backlog=16384
        netdev_max_backlog=32768
        file_max=4000000
        nofile_limit=262144
        tcp_rmem_default=134217728
        tcp_wmem_default=134217728
    fi

    local buf_max_mb
    buf_max_mb=$(echo "scale=0; $buf_max/1024/1024" | bc)
    info "生成参数: somaxconn=$somaxconn, nofile=$nofile_limit, buf_max=${buf_max_mb}MB"

    # --- 根据延迟调整参数 ---
    local tcp_fastopen tcp_fin_timeout
    local keepalive_time keepalive_intvl keepalive_probes
    local tcp_mtu_probing
    local tcp_slow_start_after_idle

    tcp_fastopen=3
    tcp_mtu_probing=1
    tcp_slow_start_after_idle=0

    if [[ $(echo "$CHOSEN_LATENCY_MS <= 50" | bc -l) -eq 1 ]]; then
        # 低延迟 (<50ms)
        tcp_fin_timeout=10
        keepalive_time=300
        keepalive_intvl=10
        keepalive_probes=3
    elif [[ $(echo "$CHOSEN_LATENCY_MS <= 150" | bc -l) -eq 1 ]]; then
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
    local cc_algo
    if $BBRV3_READY; then
        cc_algo="bbr"
        info "将使用 bbr 拥塞控制。"
    else
        cc_algo="bbr"
        warn "BBR 不可用，配置中将写入 bbr 但需内核支持才能生效。"
    fi

    # --- 写入 sysctl 配置 (zzz- 确保字典序最后加载，覆盖其他默认值) ---
    local conf_file="/etc/sysctl.d/zzz-tcp-tune.conf"

    cat > "$conf_file" <<SYSCTLEOF
# ============================================================
# TCP 深度调优配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# VPS 配置: ${CPU_CORES}核 / ${RAM_GB_CEIL}G 内存 / ${BANDWIDTH_MBPS}Mbps 带宽
# 延迟基准: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms
# ============================================================

# === 核心拥塞控制 (BBR + ${QDISC}) ===
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${cc_algo}

# === 流量队列与积压 (适配 ${RAM_GB_CEIL}G 内存) ===
net.core.somaxconn = ${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${tcp_max_syn_backlog}
net.core.netdev_max_backlog = ${netdev_max_backlog}

# === 缓冲区: 动态上限 (基于 BDP, 上限 ${buf_max_mb}MB) ===
# BDP = ${BANDWIDTH_MBPS}Mbps × ${CHOSEN_LATENCY_MS}ms = $(echo "scale=2; $bdp_bytes/1024/1024" | bc)MB
net.core.rmem_max = ${buf_max}
net.core.wmem_max = ${buf_max}
net.ipv4.tcp_rmem = 4096 ${tcp_rmem_default} ${buf_max}
net.ipv4.tcp_wmem = 4096 ${tcp_wmem_default} ${buf_max}

# === 内存压榨策略 (适配 ${RAM_GB_CEIL}G) ===
net.ipv4.tcp_adv_win_scale = $(( RAM_GB_CEIL <= 2 ? 30 : 20 ))

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
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.all.disable_ipv6 = 0

# === 系统级设置 ===
fs.file-max = ${file_max}

# === 系统保命机制 ===
kernel.panic = 10
vm.swappiness = 1
vm.overcommit_memory = 1
SYSCTLEOF

    ok "已写入 sysctl 配置: $conf_file"

    # --- 写入 limits 配置 ---
    local limits_file="/etc/security/limits.d/zzz-tcp-tune-limits.conf"
    cat > "$limits_file" <<LIMITSEOF
* soft nofile ${nofile_limit}
* hard nofile ${nofile_limit}
* soft nproc ${nofile_limit}
* hard nproc ${nofile_limit}
LIMITSEOF

    ok "已写入 limits 配置: $limits_file"

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

    # --- Systemd 补丁 ---
    sed -i "/^#*DefaultLimitNOFILE=/c DefaultLimitNOFILE=${nofile_limit}" /etc/systemd/system.conf 2>/dev/null || true
    sed -i "/^#*DefaultLimitNPROC=/c DefaultLimitNPROC=${nofile_limit}" /etc/systemd/system.conf 2>/dev/null || true

    ok "已更新 systemd 资源限制。"
}

# ============================================================
# Step 7: 应用配置
# ============================================================
apply_config() {
    step "Step 7: 应用配置"

    # 1. 加载内核模块
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true

    # 2. 扫除冲突配置: cubic 必须去掉
    #    fq_codel 仅在 QDISC=fq 时视为冲突 (QDISC=fq_codel 时不冲突)
    local f cubic_files
    cubic_files=$(grep -rl "tcp_congestion_control.*=.*cubic" /etc/sysctl.d/ /usr/lib/sysctl.d/ /etc/sysctl.conf 2>/dev/null || true)

    for f in $cubic_files; do
        [[ "$f" == *"zzz-tcp-tune"* ]] && continue
        warn "  -> 禁用 cubic: $f"
        sed -i "s/^net\.ipv4\.tcp_congestion_control\s*=\s*cubic/# [tcp-tune] 已禁用 cubic: &/" "$f"
    done

    # 注释掉所有 fq_codel 配置 (只用 fq)
    local fq_codel_files
    fq_codel_files=$(grep -rl "default_qdisc.*=.*fq_codel" /etc/sysctl.d/ /usr/lib/sysctl.d/ /etc/sysctl.conf 2>/dev/null || true)
    for f in $fq_codel_files; do
        [[ "$f" == *"zzz-tcp-tune"* ]] && continue
        warn "  -> 禁用 fq_codel: $f"
        sed -i "s/^net\.core\.default_qdisc\s*=\s*fq_codel/# [tcp-tune] 已禁用 fq_codel: &/" "$f"
    done

    # 3. 应用 sysctl
    sysctl --system

    # 4. 强制运行时生效 (使用检测到的 QDISC)
    sysctl -w net.core.default_qdisc="${QDISC}" 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true

    # 5. 写入 /etc/sysctl.conf 兜底
    if grep -q "^net\.core\.default_qdisc" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^net\.core\.default_qdisc.*/net.core.default_qdisc = ${QDISC}/" /etc/sysctl.conf
    else
        echo "" >> /etc/sysctl.conf
        echo "# TCP 调优: BBR + fq" >> /etc/sysctl.conf
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    fi
    if grep -q "^net\.ipv4\.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^net\.ipv4\.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/" /etc/sysctl.conf
    else
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    fi

    systemctl daemon-reexec 2>/dev/null || true

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
    echo -e "    BDP:       ${CYAN}$(echo "scale=2; ${bdp_bytes:-0}/1024/1024" | bc 2>/dev/null || echo '?') MB${NC}"
    echo -e "    缓冲区上限: ${CYAN}$(echo "scale=0; ${buf_max:-0}/1024/1024" | bc 2>/dev/null || echo '?') MB${NC}"
    echo -e "    文件描述符: ${CYAN}${nofile_limit:-?}${NC}"
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
    echo -e "  ${BOLD}当前状态${NC}"
    echo -e "    拥塞控制:  ${GREEN}${cc_now}${NC}"
    echo -e "    队列算法:  ${GREEN}${qdisc_now}${NC}"
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
    detect_os
    check_bbr
    detect_vps_specs
    test_latency
    choose_latency
    generate_tuning

    echo ""
    ask "确认应用以上 TCP 调优配置？[Y/n]: "
    read -r confirm < /dev/tty
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        warn "用户取消，配置未应用。"
        exit 0
    fi

    apply_config
    print_summary
}

main "$@"
