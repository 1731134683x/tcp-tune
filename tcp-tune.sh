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
    sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
    local actual
    actual=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    if [[ "$actual" == "fq" ]]; then
        ok "qdisc: fq (当前内核支持，已运行时生效)"
        return
    fi
    warn "当前内核不支持 fq 队列 (sch_fq 不可用，当前 qdisc: ${actual:-unknown})。"
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

    buf_max_mb=$(echo "scale=0; $buf_max/1024/1024" | bc)
    info "生成参数: somaxconn=$somaxconn, nofile=$nofile_limit, buf_max=${buf_max_mb}MB"

    # 内存压榨策略 (全局变量，供 AI 提示词引用)
    tcp_adv_win_scale=$(( RAM_GB_CEIL <= 2 ? 30 : 20 ))

    # --- 根据延迟调整参数 ---

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
net.ipv4.tcp_adv_win_scale = ${tcp_adv_win_scale}

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
root soft nofile ${nofile_limit}
root hard nofile ${nofile_limit}
root soft nproc ${nofile_limit}
root hard nproc ${nofile_limit}
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
    local sed_fail=0
    sed -i "/^#*DefaultLimitNOFILE=/c DefaultLimitNOFILE=${nofile_limit}" /etc/systemd/system.conf 2>/dev/null || sed_fail=1
    sed -i "/^#*DefaultLimitNPROC=/c DefaultLimitNPROC=${nofile_limit}" /etc/systemd/system.conf 2>/dev/null || sed_fail=1
    if [[ "$sed_fail" -eq 1 ]]; then
        warn "systemd 资源限制写入失败，请手动检查 /etc/systemd/system.conf。"
    fi

    ok "已更新 systemd 资源限制。"

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
# Step 7: 应用配置
# ============================================================
apply_config() {
    step "Step 7: 应用配置"

    # 1. 加载内核模块
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true

    # 2. 扫除冲突配置: 禁用所有非 fq 的 qdisc + 非 bbr 的拥塞控制
    local f
    local conflict_fail=0
    for f in $(grep -rlE "^[^#]*tcp_congestion_control\s*=\s*cubic" /etc/sysctl.d/ /usr/lib/sysctl.d/ /run/sysctl.d/ /etc/sysctl.conf 2>/dev/null || true); do
        [[ "$f" == *"zzz-tcp-tune"* ]] && continue
        warn "  -> 禁用 cubic: $f"
        sed -i "s/^net\.ipv4\.tcp_congestion_control\s*=\s*cubic/# [tcp-tune] 已禁用 cubic: &/" "$f" || { err "  修改失败: $f"; conflict_fail=1; }
    done
    for f in $(grep -rlE "^[^#]*default_qdisc\s*=\s*fq_codel" /etc/sysctl.d/ /usr/lib/sysctl.d/ /run/sysctl.d/ /etc/sysctl.conf 2>/dev/null || true); do
        [[ "$f" == *"zzz-tcp-tune"* ]] && continue
        warn "  -> 禁用 fq_codel: $f"
        sed -i "s/^net\.core\.default_qdisc\s*=\s*fq_codel/# [tcp-tune] 已禁用 fq_codel: &/" "$f" || { err "  修改失败: $f"; conflict_fail=1; }
    done
    for f in $(grep -rlE "^[^#]*default_qdisc\s*=\s*pfifo_fast" /etc/sysctl.d/ /usr/lib/sysctl.d/ /run/sysctl.d/ /etc/sysctl.conf 2>/dev/null || true); do
        [[ "$f" == *"zzz-tcp-tune"* ]] && continue
        warn "  -> 禁用 pfifo_fast: $f"
        sed -i "s/^net\.core\.default_qdisc\s*=\s*pfifo_fast/# [tcp-tune] 已禁用 pfifo_fast: &/" "$f" || { err "  修改失败: $f"; conflict_fail=1; }
    done
    if [[ "$conflict_fail" -eq 1 ]]; then
        warn "部分冲突配置未能自动禁用，请手动检查上述文件。"
    fi

    # 3. 应用 sysctl
    if sysctl --system 2>&1 | grep -qiE "error|unknown|invalid"; then
        warn "sysctl --system 可能存在部分错误，请查看上方输出。"
    fi

    # 4. 强制运行时生效 (使用检测到的 QDISC)，写入后立即回读验证
    sysctl -w net.core.default_qdisc="${QDISC}" 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
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
        echo "# TCP 调优: BBR + fq" >> /etc/sysctl.conf || sed_fail=1
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

    # tcp_rmem = "min default max"
    actual=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo "0 0 0")
    expected="4096	${tcp_rmem_default}	${buf_max}"
    if [[ "$actual" == "$expected" ]]; then
        ok "  tcp_rmem: ${actual} ✓"
        ((pass++))
    else
        warn "  tcp_rmem: ${actual} (期望 ${expected})"
        ((fail++))
    fi

    actual=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo "0 0 0")
    expected="4096	${tcp_wmem_default}	${buf_max}"
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

    # --- ulimit ---
    actual=$(ulimit -n 2>/dev/null || echo "?")
    _check "ulimit -n" "$actual" "${nofile_limit}" "ge"

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
# Choice Menu: 应用 / AI 提示 / 跳过
# ============================================================
choice_menu() {
    echo ""
    echo -e "${CYAN}${BOLD}======================================${NC}"
    echo -e "${CYAN}${BOLD}  选择后续操作${NC}"
    echo -e "${CYAN}${BOLD}======================================${NC}"
    echo ""
    echo "  调优参数已生成并写入配置文件，请选择:"
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
    echo "       - 配置文件已写入，暂不生效"
    echo "       - 生成 AI 提示词到 /root/tcp-tune-ai-prompt.txt"
    echo ""
    echo "    4) 跳过"
    echo "       - 配置文件已写入，可稍后手动运行 sysctl --system"
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
    bdp_mb_val=$(echo "scale=2; ${bdp_bytes:-0}/1024/1024" | bc 2>/dev/null || echo "?")

    cat > "$ai_prompt_file" <<AIEOF
你是一位 Linux 内核网络调优专家。请根据以下 VPS 的实际配置，生成一套定制化的 sysctl TCP 调优参数。

## VPS 配置
- CPU 核心数: ${CPU_CORES}
- 内存: ${RAM_MB} MB (约 ${RAM_GB_CEIL}G)
- 带宽: ${BANDWIDTH_MBPS} Mbps
- 系统: ${OS_NAME} ${OS_VERSION}
- 内核: ${KERNEL_VER}
- BBR: $($BBRV3_READY && echo "已安装" || echo "未安装")

## 网络延迟
- IPv4 到 120.241.152.135: $( [[ $(echo "$LATENCY_IPV4_MS > 0" | bc -l 2>/dev/null) == "1" ]] && echo "${LATENCY_IPV4_MS} ms" || echo "不可达" )
- IPv6 到 2409:8c54:871:1001::12: $( [[ $(echo "$LATENCY_IPV6_MS > 0" | bc -l 2>/dev/null) == "1" ]] && echo "${LATENCY_IPV6_MS} ms" || echo "不可达" )
- 选用基准: ${CHOSEN_IP_STACK} ${CHOSEN_LATENCY_MS}ms

## 已计算的基准参数
- BDP: ${bdp_mb_val} MB
- 缓冲区上限: ${buf_max_mb} MB (BDP×2 与内存限制取最小值)
- 当前已应用:
  - somaxconn = ${somaxconn}
  - tcp_max_syn_backlog = ${tcp_max_syn_backlog}
  - netdev_max_backlog = ${netdev_max_backlog}
  - rmem_max / wmem_max = ${buf_max}
  - tcp_rmem = 4096 ${tcp_rmem_default} ${buf_max}
  - tcp_wmem = 4096 ${tcp_wmem_default} ${buf_max}
  - tcp_adv_win_scale = ${tcp_adv_win_scale}
  - tcp_fin_timeout = ${tcp_fin_timeout}
  - tcp_slow_start_after_idle = ${tcp_slow_start_after_idle}
  - tcp_fastopen = ${tcp_fastopen}
  - tcp_mtu_probing = ${tcp_mtu_probing}
  - tcp_keepalive_time = ${keepalive_time}
  - tcp_keepalive_intvl = ${keepalive_intvl}
  - tcp_keepalive_probes = ${keepalive_probes}
  - fs.file-max = ${file_max}
  - nofile / nproc 限制 = ${nofile_limit}

## 输出要求
请生成一个 **可直接以 root 执行的 bash 脚本**，格式参考如下模板。要求:
1. 根据 ${RAM_GB_CEIL}G 内存和 ${BANDWIDTH_MBPS}Mbps 带宽重新计算最合理的参数
2. 根据 ${CHOSEN_LATENCY_MS}ms 延迟调整超时和保活参数
3. 给出每项参数的注释说明为什么选择这个值
4. 每个写入操作都需要检测是否失败，失败要输出明确的错误警告
5. 脚本末尾必须包含参数验证部分：逐项使用 sysctl -n 回读每个参数值，与期望值比较，不一致的输出 [WARN]

输出格式模板 (将 [] 中的值替换为你的计算结果):
\`\`\`bash
#!/bin/bash
# TCP 调优参数 -- 由 AI 根据 VPS 配置生成
# VPS: ${vps_label}, 延迟: ${CHOSEN_LATENCY_MS}ms

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
net.ipv4.tcp_slow_start_after_idle = 0
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
root soft nofile [你的建议值]
root hard nofile [你的建议值]
root soft nproc [你的建议值]
root hard nproc [你的建议值]
EOF

sed -i "/^#*DefaultLimitNOFILE=/c DefaultLimitNOFILE=[你的建议值]" /etc/systemd/system.conf 2>/dev/null || echo "[WARN] systemd DefaultLimitNOFILE 写入失败，请手动检查"
sed -i "/^#*DefaultLimitNPROC=/c DefaultLimitNPROC=[你的建议值]" /etc/systemd/system.conf 2>/dev/null || echo "[WARN] systemd DefaultLimitNPROC 写入失败，请手动检查"

if ! sysctl --system 2>&1 | grep -qiE "error|unknown|invalid"; then :; else
    echo "[WARN] sysctl --system 可能存在部分错误，请查看上方输出"
fi
systemctl daemon-reexec 2>/dev/null || echo "[WARN] systemctl daemon-reexec 失败"

# === 验证: 逐项回读参数，确保正确应用 ===
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
_check "qdisc" "\$(sysctl -n net.core.default_qdisc)" "fq"
_check "cc" "\$(sysctl -n net.ipv4.tcp_congestion_control)" "bbr"
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
    detect_os
    check_bbr
    detect_vps_specs
    test_latency
    choose_latency
    generate_tuning

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
            info "配置文件已写入 /etc/sysctl.d/，需要时请以 root 运行: sysctl --system"
            ;;
        4)  # 跳过
            info "已跳过应用和 AI 提示词生成。"
            info "配置文件已写入 /etc/sysctl.d/，需要时请以 root 运行: sysctl --system"
            ;;
    esac
}

main "$@"
