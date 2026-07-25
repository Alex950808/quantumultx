#!/bin/bash
# =============================================================================
# VPS 初始化配置脚本 (交互式)
# 功能：Swap / BBR / 智能内核调优 / 时区 / Docker管理 / 服务清理 / 系统信息
#       软件源更换 (CentOS/Debian/Ubuntu/Alpine, 兼容 deb822)
# 特性：带宽分级 (低/中/高/超高) / 延迟检测 / 丢包检测 / 文件句柄优化
#       Docker源更换 / daemon.json编辑 / IPv6开关 / 镜像加速
#       IP信息(IPv4/6/运营商/归属地) / CPU/内存/磁盘/网络流量
# 适用：Debian 10+ / Ubuntu 18.04+ / CentOS 7+
# 用法：chmod +x init.sh && sudo ./init.sh
# =============================================================================

set -e

# ----------------------------- 颜色输出 --------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}>>> $1 <<<${NC}"; }

# ----------------------------- 权限检查 --------------------------------------
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 或 sudo 运行此脚本"
    exit 1
fi

# ----------------------------- 系统检测 --------------------------------------
OS=""
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
elif [[ -f /etc/redhat-release ]]; then
    OS="centos"
fi

# =============================================================================
# 交互式工具函数
# =============================================================================

# 读取 y/n，默认值可选 (default: y 或 n)
confirm() {
    local prompt="$1"
    local default="${2:-y}"
    local yn

    if [[ "$default" == "y" ]]; then
        read -rp "$(echo -e "${BOLD}${prompt}${NC} [${GREEN}Y${NC}/n]: ")" yn
        yn=${yn:-y}
    else
        read -rp "$(echo -e "${BOLD}${prompt}${NC} [y/${RED}N${NC}]: ")" yn
        yn=${yn:-n}
    fi

    [[ "$yn" =~ ^[Yy]$ ]] && return 0 || return 1
}

# 获取内核主版本号
kernel_version() {
    uname -r | cut -d. -f1,2
}

# 比较版本号: version_ge 5.4 4.9 → true
version_ge() {
    awk -v v1="$1" -v v2="$2" 'BEGIN{
        split(v1, a, "."); split(v2, b, ".")
        for (i=1; i<=length(a) || i<=length(b); i++) {
            if (a[i]+0 > b[i]+0) exit 0
            if (a[i]+0 < b[i]+0) exit 1
        }
        exit 0
    }'
}

# 安全读取 sysctl 值
sysctl_get() {
    sysctl -n "$1" 2>/dev/null || echo "N/A"
}

# ── 检测国家/地区（单次缓存，避免重复请求） ──
COUNTRY_CACHE=""
detect_country() {
    if [ -z "$COUNTRY_CACHE" ]; then
        COUNTRY_CACHE=$(curl -s --max-time 3 ipinfo.io/country 2>/dev/null || echo "")
    fi
}

# ── 通用包安装函数（适配多种包管理器） ──
install_pkg() {
    if [ $# -eq 0 ]; then
        log_error "未提供软件包参数!"
        return 1
    fi

    for package in "$@"; do
        if ! command -v "$package" &>/dev/null; then
            log_info "正在安装 $package ..."
            if command -v dnf &>/dev/null; then
                dnf -y update
                dnf install -y epel-release
                dnf install -y "$package"
            elif command -v yum &>/dev/null; then
                yum -y update
                yum install -y epel-release
                yum install -y "$package"
            elif command -v apt &>/dev/null; then
                apt update -y
                apt install -y "$package"
            elif command -v apk &>/dev/null; then
                apk update
                apk add "$package"
            elif command -v pacman &>/dev/null; then
                pacman -Syu --noconfirm
                pacman -S --noconfirm "$package"
            elif command -v zypper &>/dev/null; then
                zypper refresh
                zypper install -y "$package"
            elif command -v opkg &>/dev/null; then
                opkg update
                opkg install "$package"
            elif command -v pkg &>/dev/null; then
                pkg update
                pkg install -y "$package"
            else
                log_error "未知的包管理器!"
                return 1
            fi
        fi
    done
}

# =============================================================================
# 网络检测函数
# =============================================================================

# 检测网卡速率 (Mbps)
detect_link_speed() {
    local speed=0
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    [ -z "$iface" ] && iface=$(ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1)

    if [ -n "$iface" ]; then
        if command -v ethtool &>/dev/null; then
            speed=$(ethtool "$iface" 2>/dev/null | awk '/Speed:/{gsub(/[^0-9]/,"",$2); print $2}')
        fi
        if [ -z "$speed" ] || [ "$speed" = "0" ]; then
            speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo "0")
        fi
    fi
    # VPS 虚拟网卡可能读不到速率，默认 1000
    [ -z "$speed" ] || [ "$speed" -le 0 ] 2>/dev/null && speed=1000
    echo "$speed"
}

# 检测网络延迟 (ms)
detect_latency() {
    local total=0 count=0 avg
    local targets=("8.8.8.8" "1.1.1.1" "9.9.9.9" "208.67.222.222")
    for t in "${targets[@]}"; do
        local rtt
        rtt=$(ping -c 3 -W 2 "$t" 2>/dev/null | awk -F'/' '/avg/{print $5}')
        if [ -n "$rtt" ]; then
            total=$(awk "BEGIN{print $total + $rtt}")
            count=$((count + 1))
        fi
    done
    if [ "$count" -gt 0 ]; then
        avg=$(awk "BEGIN{printf \"%.1f\", $total / $count}")
    else
        avg="50"
    fi
    echo "$avg"
}

# 检测丢包率 (%)
detect_packet_loss() {
    local loss
    loss=$(ping -c 10 -W 2 8.8.8.8 2>/dev/null | awk -F',' '/loss/{gsub(/%/,"",$3); gsub(/ packet/,"",$3); print $3+0}')
    [ -z "$loss" ] && loss=0
    echo "$loss"
}

# 检测总物理内存 (MB)
detect_memory_mb() {
    awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo
}

# 带宽分级: low / medium / high / ultra
classify_bandwidth() {
    local speed=$1
    if [ "$speed" -lt 100 ]; then
        echo "low"
    elif [ "$speed" -lt 1000 ]; then
        echo "medium"
    elif [ "$speed" -lt 10000 ]; then
        echo "high"
    else
        echo "ultra"
    fi
}

# 查找已有 sysctl 配置行号 (用于去重写入)
# 默认写入 /etc/sysctl.d/ 下对应文件 (优先级高于 /etc/sysctl.conf)
sysctl_set() {
    local key="$1"
    local val="$2"
    local file="${3:-/etc/sysctl.d/99-custom.conf}"

    sysctl -w "$key=$val" 2>/dev/null || true
    if grep -q "^$key" "$file" 2>/dev/null; then
        sed -i "s|^$key.*|$key = $val|" "$file"
    else
        echo "$key = $val" >> "$file"
    fi
}

# =============================================================================
# 1. Swap 创建
# =============================================================================
create_swap() {
    local size_mb="$1"
    local swappiness_val="$2"

    log_step "创建 Swap"

    # ── 先检查磁盘空间 ──
    local available_mb
    available_mb=$(df -m / | awk 'NR==2 {print $4}')
    if [[ $available_mb -lt $size_mb ]]; then
        log_error "磁盘空间不足！可用: ${available_mb}MB, 需要: ${size_mb}MB"
        return 1
    fi

    # 检查是否已存在 swap
    if swapon --show 2>/dev/null | grep -q .; then
        log_warn "系统已存在 Swap:"
        swapon --show
        log_info "磁盘可用: ${available_mb}MB"
        if ! confirm "是否需要重新创建 Swap (会先删除旧的)?" "n"; then
            log_info "跳过 Swap 创建"
            return 0
        fi

        # 关闭所有旧 swap 并清理 fstab
        log_info "正在删除旧的 Swap..."

        # 从 /proc/swaps 读取实际的 swap 文件路径
        local old_swaps
        old_swaps=$(awk 'NR>1 && $1 ~ /^\// {print $1}' /proc/swaps)
        swapoff -a 2>/dev/null || true

        # 移除 fstab 中所有 swap 条目
        sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab

        # 删除实际的 swap 文件
        for old_swap in $old_swaps; do
            if [[ -f "$old_swap" ]]; then
                rm -f "$old_swap" && log_info "  已删除: $old_swap"
            fi
        done
    fi

    local swap_file="/swapfile"
    log_info "创建 ${size_mb}MB Swap 文件: ${swap_file}"

    # fallocate 更快，dd 兼容性更好
    if command -v fallocate &>/dev/null; then
        fallocate -l ${size_mb}M "$swap_file" 2>/dev/null || \
            dd if=/dev/zero of="$swap_file" bs=1M count="$size_mb" status=progress
    else
        dd if=/dev/zero of="$swap_file" bs=1M count="$size_mb" status=progress
    fi

    chmod 600 "$swap_file"
    mkswap "$swap_file"
    swapon "$swap_file"

    # 写入 fstab (防重复)
    if ! grep -q "$swap_file" /etc/fstab; then
        echo "$swap_file none swap sw 0 0" >> /etc/fstab
    fi

    # swappiness
    sysctl_set "vm.swappiness" "$swappiness_val" "/etc/sysctl.d/99-swap.conf"

    log_info "Swap 创建完成!"
    swapon --show
    free -h
}

# ── 关闭并删除 Swap ──
disable_swap() {
    log_step "关闭 Swap"

    if ! swapon --show 2>/dev/null | grep -q .; then
        log_info "Swap 未启用，无需关闭"
        return 0
    fi

    log_warn "当前 Swap:"
    swapon --show
    free -h

    if ! confirm "确认关闭并删除 Swap?" "n"; then
        log_info "已取消"
        return 0
    fi

    # 关闭所有 swap
    log_info "关闭 Swap..."
    swapoff -a 2>/dev/null || true

    # 删除 fstab 中所有 swap 条目
    sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab

    # 删除实际的 swap 文件
    local old_swaps
    old_swaps=$(awk 'NR>1 && $1 ~ /^\// {print $1}' /proc/swaps)
    for old_swap in $old_swaps; do
        if [[ -f "$old_swap" ]]; then
            rm -f "$old_swap" && log_info "  已删除: $old_swap"
        fi
    done

    # 清理 swappiness 配置
    rm -f /etc/sysctl.d/99-swap.conf
    sysctl -w vm.swappiness=60 2>/dev/null || true

    log_info "Swap 已关闭并删除"
    free -h
}

# =============================================================================
# 2. BBR 拥塞控制
# =============================================================================
enable_bbr() {
    log_step "开启 BBR 拥塞控制"

    local kernel_ver
    kernel_ver=$(kernel_version)

    # BBR 需要内核 >= 4.9
    if ! version_ge "$kernel_ver" "4.9"; then
        log_warn "内核版本 ($(uname -r)) < 4.9，不支持 BBR，请升级内核后重试"
        return 1
    fi

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

    if [[ "$current_cc" == "bbr" ]]; then
        log_info "BBR 已启用 (当前: bbr)"
        lsmod 2>/dev/null | grep -q bbr && log_info "bbr 模块已加载" || log_warn "bbr 模块未加载，请重启"
        return 0
    fi

    log_info "当前拥塞控制: ${current_cc}"
    log_info "可用算法: $(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null)"

    # 写入配置
    local bbr_conf="/etc/sysctl.d/99-bbr.conf"
    cat > "$bbr_conf" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    # 清理 /etc/sysctl.conf 中的 BBR 相关配置，避免与 sysctl.d 冲突
    sed -i '/^[[:space:]]*net\.core\.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true

    sysctl --system 2>/dev/null || true

    # 验证
    sleep 1
    local new_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$new_cc" == "bbr" ]]; then
        log_info "BBR 开启成功!"
        lsmod 2>/dev/null | grep bbr
    else
        log_warn "BBR 配置已写入，当前: ${new_cc}，重启后生效"
    fi
}

disable_bbr() {
    log_step "关闭 BBR 拥塞控制"

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

    if [[ "$current_cc" != "bbr" ]]; then
        log_info "BBR 未启用，无需关闭 (当前: ${current_cc})"
        return 0
    fi

    sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null || true
    sysctl -w net.core.default_qdisc=fq_codel 2>/dev/null || true

    rm -f /etc/sysctl.d/99-bbr.conf
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = cubic
EOF

    # 清理 /etc/sysctl.conf 中的 BBR 相关配置
    sed -i '/^[[:space:]]*net\.core\.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true

    sysctl --system 2>/dev/null || true
    sleep 1

    local new_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    log_info "当前拥塞控制: ${new_cc}"
}

# =============================================================================
# 3. 系统优化 (自动检测 + 内核网络 + 文件句柄 + VM)
# =============================================================================
auto_kernel_optimize() {
    local enable_network="$1"
    local enable_limits="$2"

    log_step "系统优化"

    # --- 自动检测网络环境 ---
    local SPEED LATENCY LOSS MEM_MB BW_CLASS
    MEM_MB=$(detect_memory_mb)

    if [[ "$enable_network" == "true" ]]; then
        log_info "自动检测网络环境..."
        SPEED=$(detect_link_speed)
        LATENCY=$(detect_latency)
        LOSS=$(detect_packet_loss)
        BW_CLASS=$(classify_bandwidth "$SPEED")

        log_info "链路速率: ${SPEED} Mbps | 延迟: ${LATENCY} ms | 丢包率: ${LOSS}%"
        case "$BW_CLASS" in
            low)    log_info "带宽等级: ${YELLOW}低带宽 (<100M)${NC} → 保守优化" ;;
            medium) log_info "带宽等级: ${CYAN}中带宽 (100M-1G)${NC} → 标准优化" ;;
            high)   log_info "带宽等级: ${GREEN}高带宽 (1G-10G)${NC} → 激进优化" ;;
            ultra)  log_info "带宽等级: ${MAGENTA}超高带宽 (>10G)${NC} → 极致优化" ;;
        esac

        # ── 根据带宽等级设定参数 ──
        local TCP_RMEM_MAX TCP_WMEM_MAX TCP_RMEM TCP_WMEM
        local NETDEV_BUDGET NETDEV_BUDGET_USECS SOMAXCONN NETDEV_BACKLOG CONNTRACK_MAX

        case "$BW_CLASS" in
            low)
                TCP_RMEM="4096 65536 2097152";      TCP_WMEM="4096 65536 2097152"
                TCP_RMEM_MAX=2097152;                TCP_WMEM_MAX=2097152
                SOMAXCONN=1024;                      NETDEV_BACKLOG=1000
                NETDEV_BUDGET=300;                   NETDEV_BUDGET_USECS=2000
                CONNTRACK_MAX=65536
                ;;
            medium)
                TCP_RMEM="4096 131072 16777216";     TCP_WMEM="4096 131072 16777216"
                TCP_RMEM_MAX=16777216;               TCP_WMEM_MAX=16777216
                SOMAXCONN=4096;                      NETDEV_BACKLOG=5000
                NETDEV_BUDGET=600;                   NETDEV_BUDGET_USECS=4000
                CONNTRACK_MAX=262144
                ;;
            high)
                TCP_RMEM="4096 262144 67108864";     TCP_WMEM="4096 262144 67108864"
                TCP_RMEM_MAX=67108864;               TCP_WMEM_MAX=67108864
                SOMAXCONN=8192;                      NETDEV_BACKLOG=10000
                NETDEV_BUDGET=1200;                  NETDEV_BUDGET_USECS=6000
                CONNTRACK_MAX=524288
                ;;
            ultra)
                TCP_RMEM="4096 524288 134217728";    TCP_WMEM="4096 524288 134217728"
                TCP_RMEM_MAX=134217728;              TCP_WMEM_MAX=134217728
                SOMAXCONN=16384;                     NETDEV_BACKLOG=20000
                NETDEV_BUDGET=2400;                  NETDEV_BUDGET_USECS=8000
                CONNTRACK_MAX=1048576
                ;;
        esac

        # 高延迟网络额外优化
        local HIGH_LATENCY=false
        if [ "$(awk "BEGIN{print ($LATENCY > 100)}")" = "1" ]; then
            HIGH_LATENCY=true
            log_warn "高延迟网络 (${LATENCY}ms > 100ms)，启用额外优化"
        fi

        # 内存不足时缩小缓冲区
        if [ "$MEM_MB" -lt 512 ]; then
            log_warn "内存不足 512MB，缩小 TCP 缓冲区"
            TCP_RMEM="4096 32768 1048576"
            TCP_WMEM="4096 32768 1048576"
            TCP_RMEM_MAX=1048576; TCP_WMEM_MAX=1048576
            CONNTRACK_MAX=32768
        fi

        # ── 备份现有配置 ──
        local CONF="/etc/sysctl.d/99-network-optimize.conf"
        if [ -f "$CONF" ]; then
            cp "$CONF" "${CONF}.bak.$(date +%s)"
            log_info "已备份旧配置"
        fi

        # ── 根据内存设定 VM 参数 ──
        local SWAPPINESS MIN_FREE_KB
        if [ "$MEM_MB" -ge 16384 ]; then
            SWAPPINESS=5;
        elif [ "$MEM_MB" -ge 4096 ]; then
            SWAPPINESS=10;
        elif [ "$MEM_MB" -ge 1024 ]; then
            SWAPPINESS=20;
        else
            SWAPPINESS=30;
        fi

        # ── 高延迟额外参数 ──
        local HIGH_LAT_EXTRA=""
        if $HIGH_LATENCY; then
            HIGH_LAT_EXTRA="
# ── 高延迟网络额外优化 ──
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384"
        fi

        log_info "写入优化配置 → ${CONF}"
        cat > "$CONF" <<SYSCTL_EOF
# =============================================================================
# 自动网络优化配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 带宽等级: ${BW_CLASS} (${SPEED}Mbps)
# 平均延迟: ${LATENCY}ms | 丢包率: ${LOSS}%
# 内核: $(uname -r) | 内存: ${MEM_MB}MB
# =============================================================================

# ── TCP 性能优化 ──
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_max_tw_buckets = 65536

# ── TCP 缓冲区 (带宽分级: ${BW_CLASS}) ──
net.core.rmem_default = $(echo "$TCP_RMEM" | awk '{print $2}')
net.core.wmem_default = $(echo "$TCP_WMEM" | awk '{print $2}')
net.core.rmem_max = ${TCP_RMEM_MAX}
net.core.wmem_max = ${TCP_WMEM_MAX}
net.ipv4.tcp_rmem = ${TCP_RMEM}
net.ipv4.tcp_wmem = ${TCP_WMEM}
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# ── 连接队列 ──
net.core.somaxconn = ${SOMAXCONN}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.netdev_budget = ${NETDEV_BUDGET}
net.ipv4.tcp_max_syn_backlog = ${SOMAXCONN}
$(sysctl -n net.core.netdev_budget_usecs &>/dev/null && echo "net.core.netdev_budget_usecs = ${NETDEV_BUDGET_USECS}" || echo "# netdev_budget_usecs 不支持，跳过")

# ── 临时端口范围 ──
net.ipv4.ip_local_port_range = 10240 65535

# ── TCP 内存与连接 ──
net.ipv4.tcp_mem = $((MEM_MB * 1024 / 8)) $((MEM_MB * 1024 / 4)) $((MEM_MB * 1024 / 2))
net.ipv4.tcp_max_orphans = 32768

# ── 网络安全和防护 ──
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# ── IPv6 优化 ──
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# ── 连接跟踪 ──
$(if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
    echo "net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}"
    echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200"
    echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
    echo "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15"
    echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15"
else
    echo "# conntrack 未启用，跳过"
fi)

# ── 文件描述符 ──
fs.file-max = 2097152
fs.nr_open = 1048576

# ── 虚拟内存优化 ──
vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.overcommit_memory = 1
vm.vfs_cache_pressure = 50

# ── CPU/内核调度优化 ──
kernel.sched_autogroup_enabled = 0
$([ -f /proc/sys/kernel/numa_balancing ] && echo "kernel.numa_balancing = 0" || echo "# numa_balancing 不支持，跳过")
${HIGH_LAT_EXTRA}
SYSCTL_EOF

        # 应用配置 (逐个应用，跳过不支持的)
        log_info "应用 sysctl 配置..."
        local apply_errors
        apply_errors=$(sysctl -p "$CONF" 2>&1 | grep -i "error\|invalid\|cannot" || true)
        if [ -n "$apply_errors" ]; then
            log_warn "部分参数不支持（已跳过）"
        fi

        # 清理 /etc/sysctl.conf 中的重复项（避免与 sysctl.d 优先级冲突）
        if [ -f /etc/sysctl.conf ]; then
            awk -F'[= ]' '{print $1}' "$CONF" | grep -v '^#' | grep -v '^$' | sort -u | while read -r key; do
                [ -n "$key" ] && sed -i "/^[[:space:]]*${key}[[:space:]=]/d" /etc/sysctl.conf 2>/dev/null || true
            done
        fi

        # 禁用透明大页面（减少延迟抖动）
        if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
            echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null && \
                log_info "透明大页面已禁用 (减少延迟抖动)" || true
        fi

        log_info "内核网络优化完成!"
    else
        log_warn "跳过内核网络优化"
    fi

    # --- 文件句柄 ---
    if [[ "$enable_limits" == "true" ]]; then
        log_info "优化文件句柄限制..."
        if ! grep -q "# network-optimize" /etc/security/limits.conf 2>/dev/null; then
            cat >> /etc/security/limits.conf <<'LIMITS_EOF'

# network-optimize - 自动网络优化添加
*    soft    nofile    1048576
*    hard    nofile    1048576
root soft    nofile    1048576
root hard    nofile    1048576
LIMITS_EOF
        fi

        if [[ -f /etc/systemd/system.conf ]]; then
            if grep -q "^DefaultLimitNOFILE" /etc/systemd/system.conf 2>/dev/null; then
                sed -i 's/^DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/' /etc/systemd/system.conf
            else
                echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf
            fi
        fi
    else
        log_warn "跳过文件句柄优化"
    fi

    log_info "系统优化完成!"
}

# =============================================================================
# 4. 时区设置
# =============================================================================
set_timezone() {
    log_step "时区设置"
    log_info "设置时区为 Asia/Shanghai..."
    if timedatectl set-timezone Asia/Shanghai 2>/dev/null; then
        log_info "时区已设置为 Asia/Shanghai"
    elif [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null || \
            cp -f /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        log_info "时区已设置 (localtime 方式)"
    else
        log_warn "未找到 /usr/share/zoneinfo/Asia/Shanghai，请先安装 tzdata"
    fi
    log_info "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# =============================================================================
# 5. 服务清理
# =============================================================================
cleanup_services() {
    log_step "服务清理"
    log_info "清理不必要的服务..."

    if command -v systemctl &>/dev/null; then
        # ── systemd (Debian/Ubuntu/CentOS) ──
        local services=("avahi-daemon" "cups" "exim4" "getty@tty1" "serial-getty@ttyS0")
        for svc in "${services[@]}"; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                log_info "  已禁用: $svc"
            fi
        done
    elif command -v rc-service &>/dev/null; then
        # ── OpenRC (Alpine) ──
        local services=("avahi-daemon" "cupsd")
        for svc in "${services[@]}"; do
            if rc-service "$svc" status 2>/dev/null | grep -q "started"; then
                rc-service "$svc" stop 2>/dev/null || true
                rc-update del "$svc" 2>/dev/null || true
                log_info "  已禁用: $svc"
            fi
        done
    else
        log_warn "未检测到 systemctl 或 rc-service，跳过服务清理"
        return 0
    fi
}

# =============================================================================
# 6. 系统更新
# =============================================================================
fix_dpkg() {
    pkill -9 -f 'apt|dpkg' 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a
}

linux_update() {
    log_step "系统更新"

    if command -v dnf &>/dev/null; then
        dnf -y update
    elif command -v yum &>/dev/null; then
        yum -y update
    elif command -v apt &>/dev/null; then
        fix_dpkg
        DEBIAN_FRONTEND=noninteractive apt update -y
        DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
    elif command -v apk &>/dev/null; then
        apk update && apk upgrade
    elif command -v pacman &>/dev/null; then
        pacman -Syu --noconfirm
    else
        log_error "不支持的包管理器"
        return 1
    fi

    log_info "系统更新完成!"
}

# =============================================================================
# 7. journald 日志限制 (立即清理 + 持久化，重启不失效)
# =============================================================================
setup_journald() {
    log_step "journald 日志限制"

    # 立即清理现有日志
    journalctl --rotate 2>/dev/null || true
    journalctl --vacuum-time=3d 2>/dev/null || true
    journalctl --vacuum-size=10M 2>/dev/null || true

    # 持久化配置到 /etc/systemd/journald.conf
    local conf="/etc/systemd/journald.conf"
    if [ -f "$conf" ]; then
        sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=10M/' "$conf"
        sed -i 's/^#\?MaxRetentionSec=.*/MaxRetentionSec=3day/' "$conf"
        grep -q '^SystemMaxUse=' "$conf" 2>/dev/null || echo 'SystemMaxUse=10M' >> "$conf"
        grep -q '^MaxRetentionSec=' "$conf" 2>/dev/null || echo 'MaxRetentionSec=3day' >> "$conf"
        systemctl restart systemd-journald 2>/dev/null || true
        log_info "journald 持久化配置完成: 最大 10M / 最长 3 天"
    else
        log_warn "未找到 journald.conf，跳过持久化配置"
    fi
}

# =============================================================================
# 8. 系统清理
# =============================================================================
linux_clean() {
    log_step "系统清理"

    if command -v dnf &>/dev/null; then
        rpm --rebuilddb
        dnf autoremove -y
        dnf clean all
        dnf makecache
    elif command -v yum &>/dev/null; then
        rpm --rebuilddb
        yum autoremove -y
        yum clean all
        yum makecache
    elif command -v apt &>/dev/null; then
        fix_dpkg
        apt autoremove --purge -y
        apt clean -y
        apt autoclean -y
    elif command -v apk &>/dev/null; then
        apk cache clean
        rm -rf /var/log/* 2>/dev/null
        rm -rf /var/cache/apk/* 2>/dev/null
        rm -rf /tmp/* 2>/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -Rns $(pacman -Qdtq 2>/dev/null) --noconfirm 2>/dev/null
        pacman -Scc --noconfirm
    else
        log_error "不支持的包管理器"
        return 1
    fi

    # 清理所有日志
    log_info "清理系统日志..."
    rm -rf /var/log/*.gz /var/log/*.1 /var/log/*.old 2>/dev/null || true
    journalctl --rotate 2>/dev/null || true
    journalctl --vacuum-time=1s 2>/dev/null || true
    journalctl --vacuum-size=10M 2>/dev/null || true

    log_info "系统清理完成!"
}

# =============================================================================
# 8. 常用工具安装
# =============================================================================
linux_tools() {
    log_step "常用工具安装"
    local tools=("curl" "wget" "sudo" "jq" "htop" "vim" "unzip" "tar" "tree" "git" "bash" "ca-certificates" "rsync")

    # apt-transport-https 仅 Debian/Ubuntu 需要
    if command -v apt &>/dev/null; then
        tools+=("apt-transport-https")
    fi
    local to_install=()

    for t in "${tools[@]}"; do
        if command -v "$t" &>/dev/null; then
            log_info "$t 已安装，跳过"
        else
            to_install+=("$t")
        fi
    done

    if [ ${#to_install[@]} -eq 0 ]; then
        log_info "全部工具已安装!"
        return 0
    fi

    log_info "待安装: ${to_install[*]}"
    install_pkg "${to_install[@]}"
    log_info "常用工具安装完成!"
}

# ── 卸载 Docker ──
uninstall_docker() {
    log_info "卸载 Docker..."

    if command -v systemctl &>/dev/null; then
        systemctl stop docker docker.socket 2>/dev/null || true
        systemctl disable docker containerd 2>/dev/null || true
    elif command -v rc-service &>/dev/null; then
        rc-service docker stop 2>/dev/null || true
        rc-update del docker 2>/dev/null || true
        rc-service containerd stop 2>/dev/null || true
        rc-update del containerd 2>/dev/null || true
    fi

    if command -v apt &>/dev/null; then
        apt remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        apt autoremove -y 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    elif command -v apk &>/dev/null; then
        apk del docker docker-cli-compose containerd 2>/dev/null || true
    fi

    rm -rf /var/lib/docker /var/lib/containerd /etc/docker 2>/dev/null
    log_info "Docker 已卸载"
}

# =============================================================================
# 9. 安装 Docker
# =============================================================================
install_docker() {
    log_step "安装 Docker"

    if command -v docker &>/dev/null; then
        log_info "Docker 已安装: $(docker --version 2>/dev/null)"
        if confirm "Docker 已存在，是否重新安装?" "n"; then
            uninstall_docker
        else
            return 0
        fi
    fi

    install_pkg curl

    echo -e "\n${MAGENTA}请选择 Docker 安装方式:${NC}"
    echo -e "  ${CYAN}[1]${NC} 官方脚本 (get.docker.com)"
    echo -e "  ${CYAN}[2]${NC} linuxmirrors 一键脚本"
    echo -e "  ${CYAN}[3]${NC} 系统存储库安装 (官方推荐)"
    local docker_choice
    while true; do
        read -rp "$(echo -e "${BOLD}请选择 (1-3)${NC} [${CYAN}1${NC}]: ")" docker_choice
        docker_choice=${docker_choice:-1}
        [[ "$docker_choice" =~ ^[1-3]$ ]] && break
        log_warn "请输入 1-3"
    done

    detect_country

    if [ "$docker_choice" = "1" ]; then
        log_info "使用 Docker 官方脚本安装..."
        if [ "$COUNTRY_CACHE" = "CN" ]; then
            curl -fsSL https://get.docker.com | sh -s -- --mirror Aliyun
        else
            curl -fsSL https://get.docker.com | sh
        fi
    elif [ "$docker_choice" = "2" ]; then
        log_info "使用 linuxmirrors 脚本安装..."
        if [ "$COUNTRY_CACHE" = "CN" ]; then
            bash <(curl -sSL https://linuxmirrors.cn/docker.sh) \
                --source mirrors.huaweicloud.com/docker-ce \
                --source-registry docker.1ms.run \
                --protocol https \
                --use-intranet-source false \
                --install-latest true \
                --close-firewall false \
                --ignore-backup-tips
        else
            bash <(curl -sSL https://linuxmirrors.cn/docker.sh) \
                --source download.docker.com \
                --source-registry registry.hub.docker.com \
                --protocol https \
                --use-intranet-source false \
                --install-latest true \
                --close-firewall false \
                --ignore-backup-tips
        fi
    else
        install_docker_repo
    fi

    # ── 配置 daemon.json（镜像加速 + 日志驱动） ──
    log_info "配置 Docker daemon..."
    configure_docker_daemon

    log_info "Docker 状态: $( (systemctl is-active docker 2>/dev/null || rc-service docker status 2>/dev/null | grep -q 'started' && echo 'started') || echo 'inactive')"
    docker --version 2>/dev/null || true
    docker compose version 2>/dev/null || true
}

# ── 系统存储库安装 Docker（官方推荐方式，支持 Debian/Ubuntu/CentOS/RHEL/Fedora） ──
install_docker_repo() {
    log_info "使用系统存储库安装 Docker..."

    # ── 卸载冲突软件包 ──
    if command -v apt &>/dev/null; then
        for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
            apt remove -y "$pkg" 2>/dev/null || true
        done
    elif command -v dnf &>/dev/null; then
        dnf remove -y docker docker-client docker-client-latest docker-common \
            docker-latest docker-latest-logrotate docker-logrotate docker-engine \
            podman runc 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum remove -y docker docker-client docker-client-latest docker-common \
            docker-latest docker-latest-logrotate docker-logrotate docker-engine \
            podman runc 2>/dev/null || true
    fi

    install_pkg ca-certificates curl
    detect_country

    local docker_host="https://download.docker.com"
    [ "$COUNTRY_CACHE" = "CN" ] && docker_host="https://mirrors.aliyun.com/docker-ce"

    if command -v apt &>/dev/null; then
        # ── Debian/Ubuntu ──
        local docker_os="$ID"
        case "$ID" in
            linuxmint|pop|elementary|kali|zorin) docker_os="ubuntu" ;;
            raspbian)                              docker_os="debian" ;;
        esac
        log_info "添加 Docker GPG 密钥..."
        install -m 0755 -d /etc/apt/keyrings
        local gpg_url="${docker_host}/linux/${docker_os}/gpg"
        curl -fsSL "$gpg_url" -o /etc/apt/keyrings/docker.asc 2>/dev/null || {
            curl -fsSL "https://download.docker.com/linux/${docker_os}/gpg" -o /etc/apt/keyrings/docker.asc
        }
        chmod a+r /etc/apt/keyrings/docker.asc

        log_info "添加 Docker APT 源..."
        local codename
        codename=$( (. /etc/os-release && echo "$VERSION_CODENAME") 2>/dev/null || echo "")
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${docker_host}/linux/${docker_os} ${codename} stable" \
            > /etc/apt/sources.list.d/docker.list
        apt update -y
        apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    elif command -v dnf &>/dev/null; then
        # ── Fedora / CentOS 8+ / RHEL 8+ ──
        dnf install -y dnf-plugins-core
        local docker_distro="fedora"
        case "$ID" in
            centos|rhel|almalinux|rocky|ol|amzn) docker_distro="centos" ;;
        esac
        dnf config-manager --add-repo "${docker_host}/linux/${docker_distro}/docker-ce.repo"
        sed -i "s|https://download.docker.com|${docker_host}|g" /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    elif command -v yum &>/dev/null; then
        # ── CentOS 7 / RHEL 7 ──
        yum install -y yum-utils
        yum-config-manager --add-repo "${docker_host}/linux/centos/docker-ce.repo"
        sed -i "s|https://download.docker.com|${docker_host}|g" /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
        yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    elif command -v apk &>/dev/null; then
        # ── Alpine ──
        log_info "启用 Alpine community 仓库..."
        sed -i 's|^#\(.*/community\)$|\1|' /etc/apk/repositories 2>/dev/null || true
        apk update
        apk add docker docker-cli-compose
        rc-update add docker boot 2>/dev/null || true
        rc-service docker start 2>/dev/null || true
    else
        log_error "不支持的包管理器，请选择其他安装方式"
        return 1
    fi
}

# ── 重启 Docker (兼容 systemd / OpenRC) ──
docker_restart() {
    if command -v systemctl &>/dev/null; then
        systemctl restart docker 2>/dev/null || true
    elif command -v rc-service &>/dev/null; then
        rc-service docker restart 2>/dev/null || true
    fi
}

# ── 配置 Docker daemon.json（镜像加速 + 日志驱动） ──
configure_docker_daemon() {
    detect_country
    mkdir -p /etc/docker
    if [ "$COUNTRY_CACHE" = "CN" ]; then
        cat > /etc/docker/daemon.json <<'DOCKEREOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.m.ixdev.cn",
    "https://hub.rat.dev",
    "https://dockerproxy.net",
    "https://docker.m.daocloud.io",
    "https://docker.kejilion.pro",
    "https://hub.1panel.dev",
    "https://dockerproxy.cool",
    "https://docker.apiba.cn",
    "https://proxy.vvvv.ee"
  ],
  "ipv6": false,
  "fixed-cidr-v6": "2001:db8:1::/64",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "2m",
    "max-file": "3"
  }
}
DOCKEREOF
        log_info "已配置国内 Docker 镜像加速 + IPv6(禁用) + 日志驱动"
    else
        cat > /etc/docker/daemon.json <<'DOCKEREOF'
{
  "ipv6": false,
  "fixed-cidr-v6": "2001:db8:1::/64",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "2m",
    "max-file": "3"
  }
}
DOCKEREOF
        log_info "已配置 Docker IPv6(禁用) + 日志驱动"
    fi
    docker_restart
}

# ── 更换 Docker 镜像源（调用 linuxmirrors 脚本） ──
docker_change_mirror() {
    log_step "更换 Docker 源"
    log_info "正在调用 linuxmirrors 一键换源脚本..."
    bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
    docker_restart
    log_info "Docker 源更换完成"
}

# ── 编辑 daemon.json ──
docker_edit_daemon() {
    log_step "编辑 daemon.json"
    mkdir -p /etc/docker
    if [ ! -f /etc/docker/daemon.json ]; then
        echo '{}' > /etc/docker/daemon.json
    fi

    # 优先 vim，不可用则 nano，都不行则 cat 查看
    local editor=""
    if command -v vim &>/dev/null; then
        editor="vim"
    elif command -v nano &>/dev/null; then
        editor="nano"
    else
        log_warn "未找到 vim/nano，当前配置内容如下："
        cat /etc/docker/daemon.json
        log_info "请手动编辑: /etc/docker/daemon.json"
        return 0
    fi

    $editor /etc/docker/daemon.json
    log_info "配置已保存，重启 Docker..."
    docker_restart
    log_info "Docker 已重启"
}

# ── 开启 Docker IPv6 ──
docker_ipv6_on() {
    log_step "开启 Docker IPv6 访问"

    # 确保 jq 已安装
    install_pkg jq || {
        log_error "无法安装 jq，请手动安装后重试"
        return 1
    }

    local CONFIG_FILE="/etc/docker/daemon.json"
    mkdir -p /etc/docker

    # 如果配置文件不存在，创建默认配置
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<'EOF'
{
  "ipv6": true,
  "fixed-cidr-v6": "2001:db8:1::/64",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "2m",
    "max-file": "3"
  }
}
EOF
        log_info "已创建 daemon.json 并开启 IPv6"
        docker_restart
        return 0
    fi

    # 检查当前是否已开启 IPv6
    local current_ipv6
    current_ipv6=$(jq -r '.ipv6 // false' "$CONFIG_FILE" 2>/dev/null)
    if [ "$current_ipv6" = "true" ]; then
        log_info "Docker IPv6 已经开启，无需重复操作"
        return 0
    fi

    # 使用 jq 更新配置
    local tmp_file=$(mktemp)
    jq '. + {"ipv6": true, "fixed-cidr-v6": "2001:db8:1::/64"}' "$CONFIG_FILE" > "$tmp_file" 2>/dev/null
    if [ -s "$tmp_file" ]; then
        mv "$tmp_file" "$CONFIG_FILE"
        log_info "已开启 Docker IPv6"
    else
        rm -f "$tmp_file"
        log_warn "jq 处理失败"
        return 1
    fi

    docker_restart
    log_info "Docker 已重启，IPv6 已开启"
}

# ── 关闭 Docker IPv6 ──
docker_ipv6_off() {
    log_step "关闭 Docker IPv6 访问"

    # 确保 jq 已安装
    install_pkg jq || {
        log_error "无法安装 jq，请手动安装后重试"
        return 1
    }

    local CONFIG_FILE="/etc/docker/daemon.json"

    if [ ! -f "$CONFIG_FILE" ]; then
        log_info "配置文件不存在，无需操作"
        return 0
    fi

    local current_ipv6
    current_ipv6=$(jq -r '.ipv6 // false' "$CONFIG_FILE" 2>/dev/null)
    if [ "$current_ipv6" != "true" ]; then
        log_info "Docker IPv6 已经关闭，无需重复操作"
        return 0
    fi

    local tmp_file=$(mktemp)
    jq '.ipv6 = false' "$CONFIG_FILE" > "$tmp_file" 2>/dev/null
    if [ -s "$tmp_file" ]; then
        mv "$tmp_file" "$CONFIG_FILE"
        log_info "已关闭 Docker IPv6"
    else
        rm -f "$tmp_file"
        log_warn "jq 处理失败"
        return 1
    fi

    docker_restart
    log_info "Docker 已重启，IPv6 已关闭"
}

# =============================================================================
# 10. 查看当前网络优化状态
# =============================================================================
show_network_status() {
    log_step "当前网络内核参数"
    local params=(
        "net.ipv4.tcp_congestion_control"
        "net.core.default_qdisc"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.core.somaxconn"
        "net.core.netdev_max_backlog"
        "net.ipv4.tcp_fastopen"
        "net.ipv4.tcp_tw_reuse"
        "net.ipv4.tcp_fin_timeout"
        "net.ipv4.ip_local_port_range"
        "net.ipv4.tcp_mtu_probing"
        "fs.file-max"
    )
    for p in "${params[@]}"; do
        printf "  %-45s = %s\n" "$p" "$(sysctl_get "$p")"
    done
    echo ""

    if [ -f /etc/sysctl.d/99-network-optimize.conf ]; then
        log_info "优化配置已安装: /etc/sysctl.d/99-network-optimize.conf"
    else
        log_warn "未检测到优化配置文件"
    fi
}

# =============================================================================
# 11. 回滚网络优化配置
# =============================================================================
restore_network_defaults() {
    log_step "回滚网络优化配置"

    local CONF="/etc/sysctl.d/99-network-optimize.conf"
    local latest_bak
    latest_bak=$(ls -t /etc/sysctl.d/99-network-optimize.conf.bak.* 2>/dev/null | head -1)

    if [ -n "$latest_bak" ]; then
        cp "$latest_bak" "$CONF"
        sysctl -p "$CONF" 2>/dev/null || true
        log_info "已从备份恢复: $latest_bak"
    elif [ -f "$CONF" ]; then
        rm -f "$CONF"
        sysctl --system 2>/dev/null || true
        log_info "已删除优化配置，恢复系统默认"
    else
        log_warn "没有优化配置需要回滚"
    fi

    # 清理 limits.conf 添加的部分
    if grep -q "# network-optimize" /etc/security/limits.conf 2>/dev/null; then
        sed -i '/# network-optimize/,+4d' /etc/security/limits.conf
        log_info "文件描述符限制已恢复"
    fi

    # 清理 BBR 持久化
    rm -f /etc/modules-load.d/bbr.conf

    # 恢复透明大页面
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    fi

    log_info "网络配置已回滚完毕"
}

# =============================================================================
# 12. 系统信息展示 (IP / 系统 / 硬件)
# =============================================================================
show_system_info() {
    clear 2>/dev/null || true

    echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
    echo -e "  ${MAGENTA}VPS 系统信息${NC}"
    echo ""

    # ── IP 信息 ──
    log_step "IP 信息"
    local ipv4 ipv6 country city isp_info

    # 一次请求获取 IPv4/国家/城市/运营商，减少 API 调用
    local ipinfo_json
    ipinfo_json=$(curl -s --max-time 3 ipinfo.io 2>/dev/null || echo "")
    ipv4=$(echo "$ipinfo_json" | grep '"ip"' | head -1 | awk -F'"' '{print $4}')
    country=$(echo "$ipinfo_json" | grep '"country"' | awk -F'"' '{print $4}')
    city=$(echo "$ipinfo_json" | grep '"city"' | awk -F'"' '{print $4}')
    isp_info=$(echo "$ipinfo_json" | grep '"org"' | awk -F'"' '{print $4}')
    [ -z "$ipv4" ] && ipv4="获取失败"

    ipv6=$(curl -s --max-time 2 v6.ipinfo.io/ip 2>/dev/null || echo "无/获取失败")

    echo -e "  IPv4 地址:     ${GREEN}${ipv4}${NC}"
    echo -e "  IPv6 地址:     ${GREEN}${ipv6}${NC}"
    echo -e "  运营商:        ${GREEN}${isp_info:-未知}${NC}"
    echo -e "  地理位置:      ${GREEN}${country:-未知} ${city:-}${NC}"

    # ── 系统信息 ──
    log_step "系统信息"
    local hostname os_info kernel_ver runtime dns_info timezone
    local congestion_alg queue_alg

    hostname=$(uname -n)
    os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '=' -f2 | tr -d '"')
    [ -z "$os_info" ] && os_info="$(cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2) $(cat /etc/os-release 2>/dev/null | grep 'VERSION_ID=' | cut -d= -f2 | tr -d '"')"
    kernel_ver=$(uname -r)
    congestion_alg=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    queue_alg=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "N/A")
    dns_info=$(awk '/^nameserver/{printf "%s ", $2} END {print ""}' /etc/resolv.conf)

    runtime=$(awk -F. '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);
        if(d>0) printf "%d天 ",d; if(h>0) printf "%d时 ",h; printf "%d分",m}' /proc/uptime)

    timezone=$( (timedatectl 2>/dev/null || true) | awk '/Time zone/{print $3}')
    [ -z "$timezone" ] && timezone=$(date +"%Z")

    local tcp_count udp_count
    tcp_count=$(ss -t 2>/dev/null | wc -l || echo "0")
    udp_count=$(ss -u 2>/dev/null | wc -l || echo "0")

    echo -e "  主机名:        ${GREEN}${hostname}${NC}"
    echo -e "  系统版本:      ${GREEN}${os_info}${NC}"
    echo -e "  内核版本:      ${GREEN}${kernel_ver}${NC}"
    echo -e "  运行时长:      ${GREEN}${runtime}${NC}"
    echo -e "  时区:          ${GREEN}${timezone}${NC}"
    echo -e "  拥塞算法:      ${GREEN}${congestion_alg} ${queue_alg}${NC}"
    echo -e "  DNS 地址:      ${GREEN}${dns_info}${NC}"
    echo -e "  TCP连接数:     ${GREEN}${tcp_count}${NC}"
    echo -e "  UDP连接数:     ${GREEN}${udp_count}${NC}"

    # ── 硬件信息 ──
    log_step "硬件信息"
    local cpu_model cpu_cores cpu_freq cpu_usage mem_info swap_info disk_info

    cpu_model=$(lscpu 2>/dev/null | awk -F': +' '/Model name:/ {print $2; exit}')
    [ -z "$cpu_model" ] && cpu_model=$(cat /proc/cpuinfo 2>/dev/null | grep "model name" | head -1 | awk -F': ' '{print $2}')

    cpu_cores=$(nproc)

    cpu_freq=$(awk '/cpu MHz/{printf "%.1f GHz", $4/1000; exit}' /proc/cpuinfo 2>/dev/null)

    # CPU 使用率 (1 秒采样，兜底处理 set -e)
    cpu_usage=$(set -- $(grep 'cpu ' /proc/stat); \
        u1=$(($2 + $4)); t1=$(($2 + $4 + $5)); \
        sleep 1; \
        set -- $(grep 'cpu ' /proc/stat); \
        u2=$(($2 + $4)); t2=$(($2 + $4 + $5)); \
        awk "BEGIN{if($t2-$t1>0) printf \"%.1f\", ($u2-$u1)*100/($t2-$t1); else print 0}" 2>/dev/null && echo "" || echo "N/A")

    mem_info=$(free -m | awk 'NR==2{printf "%s/%sMiB (%.0f%%)", $3, $2, $3*100/$2}')
    swap_info=$(free -m | awk 'NR==3{if($2+0==0) print "无"; else printf "%s/%sMiB (%.0f%%)", $3, $2, $3*100/$2}')
    disk_info=$(df -h / | awk '$NF=="/"{printf "%s/%s (%s)", $(NF-3), $(NF-2), $(NF-1)}')

    # 网络总流量
    local rx_total tx_total
    rx_total=$(awk 'BEGIN{rx=0} $1~/^(eth|ens|enp|eno)/{rx+=$2} END{
        if(rx>1073741824) printf "%.2f GB", rx/1073741824;
        else if(rx>1048576) printf "%.2f MB", rx/1048576;
        else printf "%.2f KB", rx/1024}' /proc/net/dev)
    tx_total=$(awk 'BEGIN{tx=0} $1~/^(eth|ens|enp|eno)/{tx+=$10} END{
        if(tx>1073741824) printf "%.2f GB", tx/1073741824;
        else if(tx>1048576) printf "%.2f MB", tx/1048576;
        else printf "%.2f KB", tx/1024}' /proc/net/dev)

    echo -e "  CPU 型号:      ${GREEN}${cpu_model:-未知}${NC}"
    echo -e "  CPU 核心:      ${GREEN}${cpu_cores} 核${NC}"
    echo -e "  CPU 频率:      ${GREEN}${cpu_freq:-未知}${NC}"
    echo -e "  CPU 使用:      ${GREEN}${cpu_usage}%${NC}"
    echo -e "  物理内存:      ${GREEN}${mem_info}${NC}"
    echo -e "  Swap:          ${GREEN}${swap_info}${NC}"
    echo -e "  磁盘占用:      ${GREEN}${disk_info}${NC}"
    echo -e "  总接收:        ${GREEN}${rx_total:-0}${NC}"
    echo -e "  总发送:        ${GREEN}${tx_total:-0}${NC}"

    echo ""
}

# =============================================================================
# 13. Docker 管理
# =============================================================================
docker_manage() {
    if ! command -v docker &>/dev/null; then
        log_warn "Docker 未安装"
        if confirm "是否现在安装 Docker?" "y"; then
            install_docker
        fi
        return 0
    fi

    while true; do
        clear 2>/dev/null || true
        local c_count i_count n_count v_count
        c_count=$(docker ps -a -q 2>/dev/null | wc -l)
        i_count=$(docker images -q 2>/dev/null | wc -l)
        n_count=$(docker network ls -q 2>/dev/null | wc -l)
        v_count=$(docker volume ls -q 2>/dev/null | wc -l)

        echo ""
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${MAGENTA}Docker 管理${NC}"
        echo ""
        echo -e "  容器:${c_count}  镜像:${i_count}  网络:${n_count}  卷:${v_count}"
        echo ""
        echo -e "  ${GREEN}[1]${NC} 容器列表"
        echo -e "  ${GREEN}[2]${NC} 镜像列表"
        echo -e "  ${GREEN}[3]${NC} 容器操作"
        echo -e "  ${GREEN}[4]${NC} 镜像操作"
        echo -e "  ${GREEN}[5]${NC} 全局状态"
        echo -e "  ${GREEN}[6]${NC} 清理无用资源"
        echo -e "  ${RED}[7]${NC} 卸载 Docker"
        echo -e "  ${GREEN}[8]${NC} 更换Docker源"
        echo -e "  ${GREEN}[9]${NC} 编辑daemon.json"
        echo -e "  ${GREEN}[11]${NC} 开启IPv6访问"
        echo -e "  ${GREEN}[12]${NC} 关闭IPv6访问"
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}[0]${NC} 返回主菜单"
        echo ""
        local sub
        read -rp "$(echo -e "  ${BOLD}▸ 请输入选项: ${NC}")" sub

        case $sub in
            1)
                echo ""
                docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
                echo ""
                read -rp "按回车继续..."
                ;;
            2)
                echo ""
                docker images 2>/dev/null
                echo ""
                read -rp "按回车继续..."
                ;;
            3)
                echo ""
                read -rp "输入容器名: " cname
                [ -z "$cname" ] && continue
                echo -e "  ${GREEN}s${NC}tart  ${RED}x${NC} stop  ${CYAN}r${NC}estart  ${YELLOW}l${NC}ogs  ${MAGENTA}e${NC}xec  ${RED}rm${NC} remove"
                read -rp "操作: " op
                case $op in
                    s) docker start "$cname" 2>/dev/null || true ;;
                    x) docker stop "$cname" 2>/dev/null || true ;;
                    r) docker restart "$cname" 2>/dev/null || true ;;
                    l) docker logs --tail 50 "$cname" 2>/dev/null || true ;;
                    e) docker exec -it "$cname" /bin/sh 2>/dev/null || docker exec -it "$cname" /bin/bash 2>/dev/null || true ;;
                    rm) docker rm -f "$cname" 2>/dev/null || true ;;
                esac
                echo ""
                read -rp "按回车继续..."
                ;;
            4)
                echo ""
                read -rp "输入镜像名: " iname
                [ -z "$iname" ] && continue
                echo -e "  ${RED}rm${NC} 删除  ${YELLOW}p${NC}ull 拉取"
                read -rp "操作: " op
                case $op in
                    rm) docker rmi "$iname" 2>/dev/null || true ;;
                    p) docker pull "$iname" 2>/dev/null || true ;;
                esac
                echo ""
                read -rp "按回车继续..."
                ;;
            5)
                echo ""
                docker version 2>/dev/null
                echo ""
                docker info --format "容器: {{.Containers}}  镜像: {{.Images}}  CPU: {{.NCPU}}  内存: {{.MemTotal}}" 2>/dev/null
                echo ""
                docker network ls 2>/dev/null
                echo ""
                docker volume ls 2>/dev/null
                echo ""
                read -rp "按回车继续..."
                ;;
            6)
                echo ""
                log_info "清理无用容器..."
                docker container prune -f 2>/dev/null || true
                log_info "清理无用镜像..."
                docker image prune -f 2>/dev/null || true
                log_info "清理无用网络..."
                docker network prune -f 2>/dev/null || true
                log_info "清理未使用卷..."
                docker volume prune -f 2>/dev/null || true
                log_info "清理完成!"
                echo ""
                read -rp "按回车继续..."
                ;;
            7)
                echo ""
                if confirm "确认卸载 Docker? (不可逆)" "n"; then
                    uninstall_docker
                    break
                fi
                ;;
            8)
                docker_change_mirror
                echo ""
                read -rp "按回车继续..."
                ;;
            9)
                docker_edit_daemon
                echo ""
                read -rp "按回车继续..."
                ;;
            11)
                docker_ipv6_on
                echo ""
                read -rp "按回车继续..."
                ;;
            12)
                docker_ipv6_off
                echo ""
                read -rp "按回车继续..."
                ;;
            0) break ;;
            *) read -rp "输入无效，按回车继续..." ;;
        esac
    done
}

# ── 内核调优子菜单 ──
kernel_tuning_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${MAGENTA}内核调优${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC} 自动检测并优化"
        echo -e "  ${CYAN}[2]${NC} 当前网络内核参数"
        echo -e "  ${CYAN}[3]${NC} 回滚优化设置"
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}[0]${NC} 返回主菜单"
        echo ""
        local sub
        read -rp "$(echo -e "  ${BOLD}▸ 请输入选项: ${NC}")" sub
        case $sub in
            1)
                echo ""
                auto_kernel_optimize "true" "true"
                read -rp "$(echo -e "  ${BOLD}按回车继续...${NC}")"
                ;;
            2)
                echo ""
                show_network_status
                read -rp "$(echo -e "  ${BOLD}按回车继续...${NC}")"
                ;;
            3)
                echo ""
                if confirm "确认回滚优化配置?" "n"; then
                    restore_network_defaults
                fi
                read -rp "$(echo -e "  ${BOLD}按回车继续...${NC}")"
                ;;
            0) break ;;
            *) read -rp "输入无效，按回车继续..." ;;
        esac
    done
}

# =============================================================================
# 14. SSH 密钥管理
# =============================================================================
ssh_manage() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${MAGENTA}SSH 密钥管理${NC}"
        echo ""
        echo -e "  ${GREEN}[1]${NC} 生成新的 SSH 密钥对"
        echo -e "  ${GREEN}[2]${NC} 复制公钥到远程服务器 (ssh-copy-id)"
        echo -e "  ${GREEN}[3]${NC} 查看本地公钥"
        echo -e "  ${GREEN}[4]${NC} 查看已授权公钥 (authorized_keys)"
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}[0]${NC} 返回主菜单"
        echo ""
        local sub
        read -rp "$(echo -e "  ${BOLD}▸ 请输入选项: ${NC}")" sub

        case $sub in
            1)
                echo ""
                ssh_keygen
                echo ""
                read -rp "按回车继续..."
                ;;
            2)
                echo ""
                ssh_copy_id
                echo ""
                read -rp "按回车继续..."
                ;;
            3)
                echo ""
                show_ssh_pubkey
                echo ""
                read -rp "按回车继续..."
                ;;
            4)
                echo ""
                show_authorized_keys
                echo ""
                read -rp "按回车继续..."
                ;;
            0) break ;;
            *) read -rp "输入无效，按回车继续..." ;;
        esac
    done
}

# ── 生成 SSH 密钥 ──
ssh_keygen() {
    log_step "生成 SSH 密钥对"

    # 确保 .ssh 目录存在
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    # 选择密钥类型
    echo -e "\n${MAGENTA}请选择密钥类型:${NC}"
    echo -e "  ${CYAN}[1]${NC} ed25519     ${GREEN}(推荐)${NC} — 安全、快速、短密钥"
    echo -e "  ${CYAN}[2]${NC} rsa 4096           — 兼容性最好"
    echo -e "  ${CYAN}[3]${NC} ecdsa              — 中等安全，较快"
    echo -e "  ${RED}[0]${NC} 返回上级"
    echo ""
    local key_type choice
    while true; do
        read -rp "$(echo -e "${BOLD}请选择 (0-3)${NC} [${CYAN}1${NC}]: ")" choice
        choice=${choice:-1}
        case $choice in
            0) log_info "已取消"; return 0 ;;
            1) key_type="ed25519"; break ;;
            2) key_type="rsa"; break ;;
            3) key_type="ecdsa"; break ;;
            *) log_warn "请输入 0-3 之间的数字" ;;
        esac
    done

    log_info "密钥类型: ${key_type}"

    # RSA 额外询问位数
    local bits_arg=""
    if [ "$key_type" = "rsa" ]; then
        local bits
        read -rp "$(echo -e "${BOLD}RSA 密钥位数${NC} [${CYAN}4096${NC}]: ")" bits
        bits=${bits:-4096}
        bits_arg="-b $bits"
    fi

    # 询问密钥注释
    local comment
    read -rp "$(echo -e "${BOLD}请输入密钥注释 (如邮箱或用途说明)${NC}: ")" comment
    comment=${comment:-"user@example.com"}

    # 询问密钥路径
    local key_path
    local default_path="$HOME/.ssh/id_${key_type}"
    read -rp "$(echo -e "${BOLD}密钥保存路径${NC} [${CYAN}${default_path}${NC}]: ")" key_path
    key_path=${key_path:-"$default_path"}

    # 展开路径中的 ~
    key_path="${key_path/#\~/$HOME}"

    # 检查是否已存在
    if [ -f "$key_path" ]; then
        log_warn "密钥文件已存在: ${key_path}"
        if ! confirm "是否覆盖?" "n"; then
            log_info "跳过密钥生成"
            return 0
        fi
    fi

    # 询问是否设置密码
    if confirm "是否设置密钥密码 (passphrase)?" "n"; then
        ssh-keygen -t "$key_type" $bits_arg -C "$comment" -f "$key_path"
    else
        ssh-keygen -t "$key_type" $bits_arg -C "$comment" -f "$key_path" -N ""
    fi

    chmod 600 "${key_path}"
    chmod 644 "${key_path}.pub"

    log_info "密钥生成成功!"
    echo ""
    echo -e "  ${CYAN}类型:${NC} ${key_type}"
    echo -e "  ${CYAN}私钥:${NC} ${key_path}"
    echo -e "  ${CYAN}公钥:${NC} ${key_path}.pub"
    echo ""
    echo -e "${GREEN}────── 公钥内容 ──────${NC}"
    cat "${key_path}.pub"
    echo -e "${GREEN}────────────────────────${NC}"
}

# ── 复制 SSH 公钥到远程服务器 ──
ssh_copy_id() {
    log_step "复制公钥到远程服务器"

    # 查找可用的公钥
    local pub_keys=()
    local default_key=""
    for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_ecdsa_sk.pub; do
        if [ -f "$f" ]; then
            pub_keys+=("$f")
            [ -z "$default_key" ] && default_key="$f"
        fi
    done

    if [ ${#pub_keys[@]} -eq 0 ]; then
        log_error "未找到任何 SSH 公钥，请先生成密钥"
        return 1
    fi

    # 选择要使用的公钥
    local use_key="$default_key"
    if [ ${#pub_keys[@]} -gt 1 ]; then
        echo -e "\n${MAGENTA}找到以下公钥:${NC}"
        for i in "${!pub_keys[@]}"; do
            printf "  %b[%s]%b %s\n" "${CYAN}" "$((i + 1))" "${NC}" "${pub_keys[$i]}"
        done
        local choice
        read -rp "请选择 (1-${#pub_keys[@]}) [1]: " choice
        choice=${choice:-1}
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#pub_keys[@]} )); then
            use_key="${pub_keys[$((choice - 1))]}"
        fi
    fi

    log_info "使用公钥: ${use_key}"

    # 询问远程服务器信息
    local remote
    read -rp "$(echo -e "${BOLD}远程服务器地址 (user@host 或 user@ip)${NC}: ")" remote

    if [ -z "$remote" ]; then
        log_warn "未输入远程地址，已取消"
        return 0
    fi

    # 询问 SSH 端口
    local port
    read -rp "$(echo -e "${BOLD}SSH 端口${NC} [${CYAN}22${NC}]: ")" port
    port=${port:-22}

    # 安装 ssh-copy-id 如果不存在
    if ! command -v ssh-copy-id &>/dev/null; then
        log_info "安装 ssh-copy-id..."
        install_pkg openssh-client || true
    fi

    # 尝试使用 ssh-copy-id
    if command -v ssh-copy-id &>/dev/null; then
        if [ "$port" = "22" ]; then
            ssh-copy-id -i "$use_key" "$remote"
        else
            ssh-copy-id -i "$use_key" -p "$port" "$remote"
        fi
    else
        # 手动方式复制
        log_info "手动复制公钥..."
        local pub_content
        pub_content=$(cat "$use_key")
        if [ "$port" = "22" ]; then
            ssh "$remote" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub_content' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        else
            ssh -p "$port" "$remote" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub_content' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        fi
    fi

    log_info "公钥复制完成! 测试连接..."
    if [ "$port" = "22" ]; then
        ssh -o ConnectTimeout=5 "$remote" "echo 'SSH 密钥认证成功!'"
    else
        ssh -p "$port" -o ConnectTimeout=5 "$remote" "echo 'SSH 密钥认证成功!'"
    fi
}

# ── 查看本地公钥 ──
show_ssh_pubkey() {
    log_step "本地 SSH 公钥"
    local found=false
    for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_ecdsa_sk.pub; do
        if [ -f "$f" ]; then
            echo ""
            echo -e "  ${CYAN}${f}${NC}"
            echo -e "  ${GREEN}$(cat "$f")${NC}"
            found=true
        fi
    done
    if ! $found; then
        log_warn "未找到任何 SSH 公钥"
        if confirm "是否现在生成?" "y"; then
            ssh_keygen
        fi
    fi
}

# ── 查看 authorized_keys ──
show_authorized_keys() {
    log_step "已授权公钥 (authorized_keys)"
    local auth_file="$HOME/.ssh/authorized_keys"
    if [ -f "$auth_file" ]; then
        local count
        count=$(grep -c . "$auth_file" 2>/dev/null || echo "0")
        echo -e "  文件: ${CYAN}${auth_file}${NC}"
        echo -e "  密钥数: ${GREEN}${count}${NC}"
        echo ""
        local i=1
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local key_type comment
            key_type=$(echo "$line" | awk '{print $1}')
            comment=$(echo "$line" | awk '{print $NF}')
            echo -e "  ${CYAN}[${i}]${NC} ${key_type}  ${GREEN}${comment}${NC}"
            echo ""
            i=$((i + 1))
        done < "$auth_file"
    else
        log_warn "未找到 authorized_keys 文件"
    fi
}

# =============================================================================
# 15. sing-box 管理
# =============================================================================

# ── 安装 sing-box ──
install_singbox() {
    log_step "安装 sing-box"

    if command -v sing-box &>/dev/null; then
        log_info "sing-box 已安装: $(sing-box version 2>/dev/null | head -1)"
        if ! confirm "sing-box 已存在，是否重新安装?" "n"; then
            return 0
        fi
        # 先卸载旧的
        uninstall_singbox_silent
    fi

    echo -e "\n${MAGENTA}请选择安装方式:${NC}"
    echo -e "  ${CYAN}[1]${NC} 包管理器 / 官方脚本自动安装"
    echo -e "  ${CYAN}[2]${NC} 返回"
    local choice
    read -rp "$(echo -e "${BOLD}请选择${NC} [${CYAN}1${NC}]: ")" choice
    choice=${choice:-1}
    [[ "$choice" != "1" ]] && return 0

    if command -v apk &>/dev/null; then
        log_info "Alpine: apk add sing-box ..."
        apk add sing-box
        if [ ! -f /etc/init.d/sing-box ]; then
            cat > /etc/init.d/sing-box <<'SBOXINIT'
#!/sbin/openrc-run

name="sing-box"
description="sing-box proxy server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
SBOXINIT
            chmod +x /etc/init.d/sing-box
        fi
    elif command -v apt &>/dev/null; then
        install_pkg curl
        bash <(curl -fsSL https://sing-box.app/deb-install.sh)
    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
        install_pkg curl
        bash <(curl -fsSL https://sing-box.app/rpm-install.sh)
    else
        install_pkg curl
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi

    # 创建默认配置
    mkdir -p /etc/sing-box /var/log/sing-box
    if [ ! -f /etc/sing-box/config.json ]; then
        cat > /etc/sing-box/config.json <<'SBOXCFG'
{
    "log": {
        "disabled": false,
        "level": "info",
        "output": "/var/log/sing-box/box.log",
        "timestamp": true
    },
    "dns": {
        "servers": [
            {
                "type": "tls",
                "tag": "google",
                "server": "8.8.8.8"
            }
        ]
    },
    "inbounds": [],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct-out"
        }
    ],
    "route": {
        "rules": [],
        "final": "direct-out",
        "auto_detect_interface": true
    }
}
SBOXCFG
        log_info "已创建默认配置文件 → /etc/sing-box/config.json"
    fi

    log_info "sing-box 安装完成!"
    sing-box version 2>/dev/null | head -1 || true
}

# ── 静默卸载 (给重装用) ──
uninstall_singbox_silent() {
    singbox_service stop 2>/dev/null || true
    singbox_service disable 2>/dev/null || true
    if command -v apk &>/dev/null; then
        apk del sing-box 2>/dev/null || true
        rm -f /etc/init.d/sing-box
    elif command -v apt &>/dev/null; then
        apt remove -y sing-box 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf remove -y sing-box 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum remove -y sing-box 2>/dev/null || true
    else
        rm -f /usr/bin/sing-box /usr/local/bin/sing-box
    fi
    rm -rf /etc/sing-box /var/log/sing-box 2>/dev/null
}

# ── 卸载 sing-box ──
uninstall_singbox() {
    log_step "卸载 sing-box"
    uninstall_singbox_silent
    log_info "sing-box 已卸载"
}

# ── sing-box 服务控制 ──
singbox_service() {
    local action="${1:-status}"
    case "$action" in
        start)
            if command -v systemctl &>/dev/null; then
                systemctl start sing-box 2>/dev/null || true
            elif command -v rc-service &>/dev/null; then
                rc-service sing-box start 2>/dev/null || true
            fi
            log_info "sing-box 已启动"
            ;;
        stop)
            if command -v systemctl &>/dev/null; then
                systemctl stop sing-box 2>/dev/null || true
            elif command -v rc-service &>/dev/null; then
                rc-service sing-box stop 2>/dev/null || true
            fi
            log_info "sing-box 已停止"
            ;;
        restart)
            if command -v systemctl &>/dev/null; then
                systemctl restart sing-box 2>/dev/null || true
            elif command -v rc-service &>/dev/null; then
                rc-service sing-box restart 2>/dev/null || true
            fi
            log_info "sing-box 已重启"
            ;;
        status)
            echo ""
            if command -v systemctl &>/dev/null; then
                systemctl status sing-box 2>/dev/null || true
            elif command -v rc-service &>/dev/null; then
                rc-service sing-box status 2>/dev/null || true
            fi
            ;;
        enable)
            if command -v systemctl &>/dev/null; then
                systemctl enable sing-box 2>/dev/null || true
            elif command -v rc-service &>/dev/null; then
                rc-update add sing-box default 2>/dev/null || true
            fi
            log_info "已开启 sing-box 自启"
            ;;
        disable)
            if command -v systemctl &>/dev/null; then
                systemctl disable sing-box 2>/dev/null || true
            elif command -v rc-service &>/dev/null; then
                rc-update del sing-box 2>/dev/null || true
            fi
            log_info "已关闭 sing-box 自启"
            ;;
    esac
}

# ── sing-box 管理菜单 ──
singbox_manage() {
    if ! command -v sing-box &>/dev/null; then
        log_warn "sing-box 未安装"
        if confirm "是否现在安装 sing-box?" "y"; then
            install_singbox
        fi
        return 0
    fi

    while true; do
        clear 2>/dev/null || true
        local sb_status
        sb_status=$((systemctl is-active sing-box 2>/dev/null || rc-service sing-box status 2>/dev/null | grep -q 'started' && echo "${GREEN}运行中${NC}") || echo "${RED}未运行${NC}")

        echo ""
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${MAGENTA}sing-box 管理${NC}"
        echo ""
        echo -e "  状态: ${sb_status}"
        echo -e "  版本: $(sing-box version 2>/dev/null | head -1)"
        echo -e "  配置: /etc/sing-box/config.json"
        echo ""
        echo -e "  ${GREEN}[1]${NC} 启动服务"
        echo -e "  ${RED}[2]${NC} 停止服务"
        echo -e "  ${CYAN}[3]${NC} 重启服务"
        echo -e "  ${YELLOW}[4]${NC} 查看状态"
        echo -e "  ${GREEN}[5]${NC} 开启自启"
        echo -e "  ${RED}[6]${NC} 关闭自启"
        echo -e "  ${CYAN}[7]${NC} 编辑配置文件"
        echo -e "  ${YELLOW}[8]${NC} 查看日志"
        echo -e "  ${RED}[9]${NC} 卸载 sing-box"
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}[0]${NC} 返回主菜单"
        echo ""
        local sub
        read -rp "$(echo -e "  ${BOLD}▸ 请输入选项: ${NC}")" sub

        case $sub in
            1) singbox_service start ;;
            2) singbox_service stop ;;
            3) singbox_service restart ;;
            4) singbox_service status ;;
            5) singbox_service enable ;;
            6) singbox_service disable ;;
            7)
                local editor=""
                if command -v vim &>/dev/null; then
                    editor="vim"
                elif command -v nano &>/dev/null; then
                    editor="nano"
                else
                    log_warn "未找到 vim/nano，当前配置如下："
                    cat /etc/sing-box/config.json 2>/dev/null
                    read -rp "按回车继续..."
                    continue
                fi
                mkdir -p /etc/sing-box
                [ ! -f /etc/sing-box/config.json ] && echo '{}' > /etc/sing-box/config.json
                $editor /etc/sing-box/config.json
                log_info "配置文件已保存"
                ;;
            8)
                echo ""
                if [ -f /var/log/sing-box/box.log ]; then
                    tail -50 /var/log/sing-box/box.log
                else
                    log_warn "日志文件不存在"
                fi
                ;;
            9)
                if confirm "确认卸载 sing-box?" "n"; then
                    uninstall_singbox
                    break
                fi
                ;;
            0) break ;;
            *) read -rp "输入无效，按回车继续..." ;;
        esac
        echo ""
        read -rp "按回车继续..."
    done
}

# =============================================================================
# 16. komari-agent 管理
# =============================================================================

# ── 安装 komari-agent ──
install_komari() {
    log_step "安装 komari-agent"

    if command -v komari-agent &>/dev/null || [ -f /opt/komari/agent ] || [ -f /etc/systemd/system/komari-agent.service ] || [ -f /etc/init.d/komari-agent ]; then
        log_info "komari-agent 已安装"
        if ! confirm "是否重新安装?" "n"; then
            return 0
        fi
        uninstall_komari_silent
    fi

    echo -e "\n${MAGENTA}请选择 komari-agent 版本:${NC}"
    echo -e "  ${CYAN}[1]${NC} komari-agent (Go 版)"
    echo -e "  ${CYAN}[2]${NC} komari-zig-agent (Zig 版)${NC}"
    echo -e "  ${RED}[0]${NC} 返回"
    local ver_choice
    read -rp "$(echo -e "${BOLD}请选择${NC} [${CYAN}1${NC}]: ")" ver_choice
    ver_choice=${ver_choice:-1}

    local install_url
    case $ver_choice in
        1) install_url="https://raw.githubusercontent.com/komari-monitor/komari-agent/refs/heads/main/install.sh" ;;
        2) install_url="https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/install.sh" ;;
        0) return 0 ;;
        *) log_warn "无效选项，已取消"; return 1 ;;
    esac

    echo ""
    log_info "安装脚本: ${install_url}"
    echo ""
    echo -e "${MAGENTA}请配置以下参数:${NC}"

    local endpoint auto_discovery
    read -rp "$(echo -e "${BOLD}--endpoint (上报地址)${NC}: ")" endpoint
    read -rp "$(echo -e "${BOLD}--auto-discovery (发现密钥)${NC}: ")" auto_discovery

    if [ -z "$endpoint" ] || [ -z "$auto_discovery" ]; then
        log_error "endpoint 和 auto-discovery 不能为空"
        return 1
    fi

    install_pkg curl

    log_info "正在安装 komari-agent ..."
    bash <(curl -sL "$install_url") \
        --endpoint "$endpoint" \
        --auto-discovery "$auto_discovery" \
        --disable-web-ssh \
        --interval 5.0 \
        --info-report-interval 15 \
        --max-retries 5 \
        --reconnect-interval 10 \
        --month-rotate 1

    log_info "komari-agent 安装完成!"
}

# ── 静默卸载 ──
uninstall_komari_silent() {
    # systemd
    if command -v systemctl &>/dev/null; then
        systemctl stop komari-agent 2>/dev/null || true
        systemctl disable komari-agent 2>/dev/null || true
        rm -f /etc/systemd/system/komari-agent.service
        systemctl daemon-reload 2>/dev/null || true
    fi

    # OpenRC
    if command -v rc-service &>/dev/null; then
        rc-service komari-agent stop 2>/dev/null || true
        rc-update del komari-agent default 2>/dev/null || true
    fi

    # 通用清理
    rm -f /etc/init.d/komari-agent
    rm -rf /opt/komari/agent
    rm -rf /var/log/komari
}

# ── 卸载 komari-agent ──
uninstall_komari() {
    log_step "卸载 komari-agent"
    uninstall_komari_silent
    log_info "komari-agent 已卸载"
}

# ── komari-agent 管理菜单 ──
komari_manage() {
    local installed=false
    command -v komari-agent &>/dev/null && installed=true
    [ -f /opt/komari/agent ] && installed=true
    [ -f /etc/systemd/system/komari-agent.service ] && installed=true
    [ -f /etc/init.d/komari-agent ] && installed=true

    if ! $installed; then
        log_warn "komari-agent 未安装"
        if confirm "是否现在安装 komari-agent?" "y"; then
            install_komari
        fi
        return 0
    fi

    while true; do
        clear 2>/dev/null || true
        local km_status
        km_status=$((systemctl is-active komari-agent 2>/dev/null || rc-service komari-agent status 2>/dev/null | grep -q 'started' && echo "${GREEN}运行中${NC}") || echo "${RED}未运行${NC}")

        echo ""
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${MAGENTA}komari-agent 管理${NC}"
        echo ""
        echo -e "  状态: ${km_status}"
        echo -e "  目录: /opt/komari/agent"
        echo ""
        echo -e "  ${GREEN}[1]${NC} 启动服务"
        echo -e "  ${RED}[2]${NC} 停止服务"
        echo -e "  ${CYAN}[3]${NC} 重启服务"
        echo -e "  ${YELLOW}[4]${NC} 查看状态"
        echo -e "  ${GREEN}[5]${NC} 开启自启"
        echo -e "  ${RED}[6]${NC} 关闭自启"
        echo -e "  ${CYAN}[7]${NC} 查看日志"
        echo -e "  ${RED}[8]${NC} 卸载 komari-agent"
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}[0]${NC} 返回主菜单"
        echo ""
        local sub
        read -rp "$(echo -e "  ${BOLD}▸ 请输入选项: ${NC}")" sub

        case $sub in
            1)
                if command -v systemctl &>/dev/null; then
                    systemctl start komari-agent 2>/dev/null || true
                elif command -v rc-service &>/dev/null; then
                    rc-service komari-agent start 2>/dev/null || true
                fi
                log_info "komari-agent 已启动"
                ;;
            2)
                if command -v systemctl &>/dev/null; then
                    systemctl stop komari-agent 2>/dev/null || true
                elif command -v rc-service &>/dev/null; then
                    rc-service komari-agent stop 2>/dev/null || true
                fi
                log_info "komari-agent 已停止"
                ;;
            3)
                if command -v systemctl &>/dev/null; then
                    systemctl restart komari-agent 2>/dev/null || true
                elif command -v rc-service &>/dev/null; then
                    rc-service komari-agent restart 2>/dev/null || true
                fi
                log_info "komari-agent 已重启"
                ;;
            4)
                echo ""
                if command -v systemctl &>/dev/null; then
                    systemctl status komari-agent 2>/dev/null || true
                elif command -v rc-service &>/dev/null; then
                    rc-service komari-agent status 2>/dev/null || true
                fi
                ;;
            5)
                if command -v systemctl &>/dev/null; then
                    systemctl enable komari-agent 2>/dev/null || true
                elif command -v rc-service &>/dev/null; then
                    rc-update add komari-agent default 2>/dev/null || true
                fi
                log_info "已开启 komari-agent 自启"
                ;;
            6)
                if command -v systemctl &>/dev/null; then
                    systemctl disable komari-agent 2>/dev/null || true
                elif command -v rc-service &>/dev/null; then
                    rc-update del komari-agent default 2>/dev/null || true
                fi
                log_info "已关闭 komari-agent 自启"
                ;;
            7)
                echo ""
                if command -v journalctl &>/dev/null && journalctl -u komari-agent --no-pager -n 50 2>/dev/null; then
                    true
                elif ls /var/log/komari/*.log &>/dev/null 2>&1; then
                    tail -50 /var/log/komari/*.log 2>/dev/null
                elif ls /opt/komari/agent/*.log &>/dev/null 2>&1; then
                    tail -50 /opt/komari/agent/*.log 2>/dev/null
                else
                    log_warn "日志文件不存在，请手动查看"
                fi
                ;;
            8)
                if confirm "确认卸载 komari-agent?" "n"; then
                    uninstall_komari
                    break
                fi
                ;;
            0) break ;;
            *) read -rp "输入无效，按回车继续..." ;;
        esac
        echo ""
        read -rp "按回车继续..."
    done
}

# =============================================================================
# 17. 软件源更换 (CentOS / Debian / Ubuntu / Alpine)
# 兼容传统 sources.list 和 deb822 (.sources) 格式
# =============================================================================

# 镜像源列表（域名 + 中文标签）
MIRROR_HOSTS=(
    "mirrors.aliyun.com"
    "mirrors.tuna.tsinghua.edu.cn"
    "mirrors.ustc.edu.cn"
    "mirrors.tencent.com"
    "mirrors.huaweicloud.com"
    "mirrors.163.com"
    "mirrors.volces.com"
    "mirror.sjtu.edu.cn"
    "mirrors.nju.edu.cn"
)

MIRROR_LABELS=(
    "阿里云"
    "清华"
    "中科大"
    "腾讯云"
    "华为云"
    "网易"
    "火山引擎"
    "上海交大"
    "南京大学"
)

backup_sources() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="/etc/repo-backup-${timestamp}"
    mkdir -p "$backup_dir"
    case "$1" in
        centos)
            if ls /etc/yum.repos.d/*.repo &>/dev/null 2>&1; then
                cp -a /etc/yum.repos.d/*.repo "$backup_dir/" 2>/dev/null || true
            fi ;;
        debian|ubuntu)
            [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$backup_dir/"
            if ls /etc/apt/sources.list.d/*.sources &>/dev/null 2>&1; then
                cp -a /etc/apt/sources.list.d/*.sources "$backup_dir/" 2>/dev/null || true
            fi
            if ls /etc/apt/sources.list.d/*.list &>/dev/null 2>&1; then
                cp -a /etc/apt/sources.list.d/*.list "$backup_dir/" 2>/dev/null || true
            fi
            if [ -d /etc/apt/mirrors ]; then
                cp -a /etc/apt/mirrors "$backup_dir/mirrors" 2>/dev/null || true
            fi ;;
        alpine)
            [ -f /etc/apk/repositories ] && cp -a /etc/apk/repositories "$backup_dir/" ;;
    esac
    log_info "原始源文件已备份到 $backup_dir"
}

is_deb822() {
    local os=$1
    # 检查当前 OS 对应的 .sources 文件是否有实质内容（排除 docker.sources 等第三方仓库）
    local src_file="/etc/apt/sources.list.d/${os}.sources"
    [ -f "$src_file" ] && grep -qE '^Types:' "$src_file" 2>/dev/null && return 0
    return 1
}

change_centos_mirror_func() {
    local mirror=$1
    log_info "正在更换 CentOS 软件源为: $mirror"
    backup_sources "centos"
    for repo_file in /etc/yum.repos.d/CentOS-*.repo /etc/yum.repos.d/centos*.repo; do
        [ -f "$repo_file" ] || continue
        sed -i "s|^mirrorlist=|#mirrorlist=|g" "$repo_file"
        sed -i "s|^metalink=|#metalink=|g" "$repo_file"
        sed -i "s|^#baseurl=https\?://mirror.centos.org|baseurl=https://${mirror}|g" "$repo_file"
        sed -i "s|^#baseurl=https\?://mirror.stream.centos.org|baseurl=https://${mirror}|g" "$repo_file"
        sed -i "s|https\?://mirror.centos.org|https://${mirror}|g" "$repo_file"
        sed -i "s|https\?://mirror.stream.centos.org|https://${mirror}|g" "$repo_file"
        sed -i "s|https\?://vault.centos.org|https://${mirror}|g" "$repo_file"
    done
    if command -v dnf &>/dev/null; then
        dnf clean all && dnf makecache
    else
        yum clean all && yum makecache
    fi
    log_info "CentOS 软件源更换完成"
}

change_debian_traditional() {
    local mirror=$1
    log_info "正在更换 Debian 软件源（传统格式）为: $mirror"
    sed -i "s@https\?://deb.debian.org@https://${mirror}@g" /etc/apt/sources.list
    sed -i "s@https\?://security.debian.org@https://${mirror}@g" /etc/apt/sources.list
}

change_deb822() {
    local os=$1 mirror=$2
    log_info "检测到 deb822 格式（.sources），正在更换 ${os} 软件源为: $mirror"
    local src_file="/etc/apt/sources.list.d/${os}.sources"
    # 直接内嵌 URI 的情况
    sed -i "s@https\?://deb.debian.org@https://${mirror}@g" "$src_file" 2>/dev/null || true
    sed -i "s@https\?://security.debian.org@https://${mirror}@g" "$src_file" 2>/dev/null || true
    # mirror+file:// 间接引用的情况（实际地址在 /etc/apt/mirrors/ 下）
    for mirror_file in /etc/apt/mirrors/debian.list /etc/apt/mirrors/debian-security.list; do
        [ -f "$mirror_file" ] || continue
        sed -i "s@https\?://deb.debian.org@https://${mirror}@g" "$mirror_file"
        sed -i "s@https\?://security.debian.org@https://${mirror}@g" "$mirror_file"
    done
    log_info "deb822 格式源文件已更新"
}

change_debian_mirror_func() {
    local mirror=$1
    backup_sources "debian"
    if is_deb822 "debian"; then
        change_deb822 "debian" "$mirror"
    else
        change_debian_traditional "$mirror"
    fi
    apt update
    log_info "Debian 软件源更换完成"
}

change_ubuntu_mirror_func() {
    local mirror=$1
    backup_sources "ubuntu"
    if is_deb822 "ubuntu"; then
        log_info "检测到 deb822 格式（.sources），正在更换 Ubuntu 软件源为: $mirror"
        local src_file="/etc/apt/sources.list.d/ubuntu.sources"
        # 直接内嵌 URI 的情况
        sed -i "s@https\?://archive.ubuntu.com@https://${mirror}@g" "$src_file" 2>/dev/null || true
        sed -i "s@https\?://ports.ubuntu.com@https://${mirror}@g" "$src_file" 2>/dev/null || true
        sed -i "s@https\?://security.ubuntu.com@https://${mirror}@g" "$src_file" 2>/dev/null || true
        # mirror+file:// 间接引用的情况
        for mirror_file in /etc/apt/mirrors/ubuntu.list /etc/apt/mirrors/debian.list; do
            [ -f "$mirror_file" ] || continue
            sed -i "s@https\?://archive.ubuntu.com@https://${mirror}@g" "$mirror_file"
            sed -i "s@https\?://ports.ubuntu.com@https://${mirror}@g" "$mirror_file"
            sed -i "s@https\?://security.ubuntu.com@https://${mirror}@g" "$mirror_file"
        done
    else
        log_info "正在更换 Ubuntu 软件源（传统格式）为: $mirror"
        sed -i "s@https\?://archive.ubuntu.com@https://${mirror}@g" /etc/apt/sources.list
        sed -i "s@https\?://ports.ubuntu.com@https://${mirror}@g" /etc/apt/sources.list
        sed -i "s@https\?://security.ubuntu.com@https://${mirror}@g" /etc/apt/sources.list
    fi
    apt update
    log_info "Ubuntu 软件源更换完成"
}

change_alpine_mirror_func() {
    local mirror=$1
    log_info "正在更换 Alpine 软件源为: $mirror"
    sed -i "s@dl-cdn.alpinelinux.org@${mirror}@g" /etc/apk/repositories
    apk update
    log_info "Alpine 软件源更换完成"
}

detect_os_mirror() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            centos)     echo "centos" ;;
            debian)                                echo "debian" ;;
            ubuntu)                                echo "ubuntu" ;;
            alpine)                                echo "alpine" ;;
            *)                                     echo "" ;;
        esac
    elif [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif [ -f /etc/redhat-release ]; then
        echo "centos"
    else
        echo ""
    fi
}

change_os_mirror() {
    clear 2>/dev/null || true
    echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
    echo -e "  ${MAGENTA}软件源更换${NC}"
    echo ""

    local os_type
    os_type=$(detect_os_mirror)
    if [ -z "$os_type" ]; then
        log_error "不支持的操作系统，无法更换软件源"
        return 1
    fi

    for i in "${!MIRROR_HOSTS[@]}"; do
        echo -e "  ${GREEN}[$((i + 1))]${NC} ${MIRROR_LABELS[$i]}"
    done
    echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
    echo -e "  ${RED}[0]${NC} 返回主菜单"
    echo ""

    local choice
    while true; do
        read -rp "$(echo -e "  ${BOLD}▸ 请输入选项: ${NC}")" choice
        if [[ -z "$choice" ]]; then
            read -rp "输入无效，按回车继续..."
            continue
        fi
        if [[ "$choice" == "0" ]]; then
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#MIRROR_HOSTS[@]} )); then
            break
        fi
        read -rp "输入无效，按回车继续..."
    done

    local mirror="${MIRROR_HOSTS[$((choice - 1))]}"

    case "$os_type" in
        centos) change_centos_mirror_func "$mirror" ;;
        debian) change_debian_mirror_func "$mirror" ;;
        ubuntu) change_ubuntu_mirror_func "$mirror" ;;
        alpine) change_alpine_mirror_func "$mirror" ;;
    esac

    log_info "软件源更换完成"
    return 0
}

# =============================================================================
# 交互式主菜单
# =============================================================================
main() {

    while true; do
        clear 2>/dev/null || true

        # ── 顶部信息栏 ──
        local mem_usage cpu_count swap_status bbr_status tz
        mem_usage=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
        cpu_count=$(nproc)
        swap_status=$(free -h | awk 'NR==3{if($2+0==0) print "未配置"; else print $2}')
        tz=$( (timedatectl 2>/dev/null || true) | awk '/Time zone/{print $3}')
        [ -z "$tz" ] && tz=$(date +"%Z")
        if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            bbr_status="${GREEN}已启用${NC}"
        else
            bbr_status="${RED}未启用${NC}"
        fi

        echo ""
        echo -e "${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC}"
        echo -e "       ${BOLD}${GREEN}🚀  VPS 初始化工具${NC}  ${YELLOW}v1.0${NC}"
        echo ""
        echo -e "  ${CYAN}系统${NC}  $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '=' -f2 | tr -d '"')"
        echo -e "  ${CYAN}架构${NC}  $(uname -m)"
        echo -e "  ${CYAN}内核${NC}  $(uname -r | cut -d- -f1)"
        echo -e "  ${CYAN}内存${NC}  ${mem_usage}"
        echo -e "  ${CYAN}Swap${NC}  ${swap_status}"
        echo -e "  ${CYAN}磁盘${NC}  $(df -h / | awk '$NF=="/"{print $(NF-2)}') 可用"
        echo -e "  ${CYAN}时区${NC}  ${tz}"
        echo -e "  ${CYAN}BBR${NC}  ${bbr_status}"
        echo -e "${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC} ── ${GREEN}──${NC}"
        echo ""

        # ── 功能菜单 ──
        echo -e "  ${CYAN}[1]${NC}  查看系统详情"
        echo -e "  ${CYAN}[2]${NC}  时区设置"
        echo -e "  ${CYAN}[3]${NC}  系统更新"
        echo -e "  ${CYAN}[4]${NC}  安装常用工具"
        echo -e "  ${CYAN}[5]${NC}  BBR 管理"
        echo -e "  ${CYAN}[6]${NC}  Swap 配置"
        echo -e "  ${CYAN}[7]${NC}  Docker 管理"
        # echo -e "  ${CYAN}[8]${NC}  智能内核调优"
        echo -e "  ${CYAN}[9]${NC}  服务精简"
        echo -e "  ${CYAN}[10]${NC} 系统垃圾清理"
        echo -e "  ${CYAN}[11]${NC} NodeQuality测试"
        echo -e "  ${CYAN}[12]${NC} SSH 密钥管理"
        echo -e "  ${CYAN}[13]${NC} 更换软件源"
        echo -e "  ${CYAN}[14]${NC} sing-box 管理"
        echo -e "  ${CYAN}[15]${NC} komari-agent 管理"

        echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
        echo -e "   ${YELLOW}[A]${NC} 一键自动优化      ${RED}[0]${NC} 退出脚本"
        echo ""

        local choice
        read -rp "$(echo -e "  ${BOLD}▸ 请输入选项: ${NC}")" choice

        case $choice in
            1)
                show_system_info
                ;;     
            2)
                set_timezone
                ;;
            3)
                linux_update
                ;;
            4)
                linux_tools
                ;;
            5)
                echo ""
                while true; do
                    clear 2>/dev/null || true
                    echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
                    echo -e "  ${MAGENTA}BBR 管理${NC}"
                    echo ""
                    echo -e "  ${GREEN}[1]${NC} 开启 BBR"
                    echo -e "  ${GREEN}[2]${NC} 关闭 BBR"
                    echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
                    echo -e "  ${RED}[0]${NC} 返回主菜单"
                    echo ""
                    local bb_choice
                    read -rp "$(echo -e "  ${BOLD}▸ 请输入选项: ${NC}")" bb_choice
                    case $bb_choice in
                        1) enable_bbr; break ;;
                        2) disable_bbr; break ;;
                        0) break ;;
                        *) read -rp "输入无效，按回车继续..." ;;
                    esac
                done
                continue
                ;;
            6)
                echo ""
                while true; do
                    clear 2>/dev/null || true
                    echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
                    echo -e "  ${MAGENTA}Swap 配置${NC}"
                    echo ""
                    echo -e "  ${GREEN}[1]${NC} 创建/重建 Swap"
                    echo -e "  ${GREEN}[2]${NC} 关闭并删除 Swap"
                    echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
                    echo -e "  ${RED}[0]${NC} 返回主菜单"
                    echo ""
                    local sw_choice
                    read -rp "$(echo -e "  ${BOLD}▸ 请输入选项: ${NC}")" sw_choice
                    case $sw_choice in
                        1)
                            local size=2048 swp=60
                            read -rp "$(echo -e "${BOLD}Swap 大小 (MB)${NC} [${CYAN}2048${NC}]: ")" size
                            size=${size:-2048}
                            read -rp "$(echo -e "${BOLD}Swappiness 值 (1-100)${NC} [${CYAN}60${NC}]: ")" swp
                            swp=${swp:-60}
                            [[ $swp -gt 100 ]] && swp=100
                            [[ $swp -lt 1 ]] && swp=1
                            create_swap "$size" "$swp"
                            break
                            ;;
                        2) disable_swap; break ;;
                        0) break ;;
                        *) read -rp "输入无效，按回车继续..." ;;
                    esac
                done
                continue
                ;;
            7)
                docker_manage
                continue
                ;;
            # 8)
            #     kernel_tuning_menu
            #     continue
            #     ;;
            9)
                cleanup_services
                ;;
            10)
                linux_clean
                ;;
            11)
                bash <(curl -sL https://run.NodeQuality.com) || true
                ;;
            12)
                ssh_manage
                continue
                ;;
            13)
                change_os_mirror
                continue
                ;;
            14)
                singbox_manage
                continue
                ;;
            15)
                komari_manage
                continue
                ;;
            [Aa])
                echo ""
                echo -e "${YELLOW}自动模式：按菜单顺序执行...${NC}"
                set_timezone
                linux_update
                linux_tools
                enable_bbr
                # create_swap 2048 60
                install_docker
                # auto_kernel_optimize "true" "true"
                cleanup_services
                setup_journald
                linux_clean
                echo ""
                log_info "全部完成!"
                ;;     
            0)
                echo ""
                log_info "退出。"
                exit 0
                ;;
            *)
                log_warn "无效选项，请输入 0-15 或 A"
                continue
                ;;     
        esac

        # 非退出选项等待回车返回
        if [[ "$choice" != "0" ]]; then
            echo ""
            read -rp "$(echo -e "  ${BOLD}按回车返回菜单...${NC}")"
        fi
    done
}

main "$@"
