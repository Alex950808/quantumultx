#!/bin/bash
# =============================================================================
# VPS 初始化配置脚本 (交互式)
# 功能：Swap / BBR / 智能内核调优 / 时区 / Docker管理 / 服务清理 / 系统信息
# 特性：带宽分级 (低/中/高/超高) / 延迟检测 / 丢包检测 / 文件句柄优化
#       Docker源更换 / daemon.json编辑 / IPv6开关 / 镜像加速
#       IP信息(IPv4/6/运营商/归属地) / CPU/内存/磁盘/网络流量
# 适用：Debian 10+ / Ubuntu 18.04+ / CentOS 7+
# 用法：chmod +x vps_init.sh && sudo ./vps_init.sh
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

# 读取数字输入，带默认值
input_number() {
    local prompt="$1"
    local default="$2"
    local user_input

    read -rp "$(echo -e "${BOLD}${prompt}${NC} [${CYAN}${default}${NC}]: ")" user_input
    user_input=${user_input:-$default}

    # 验证是否为数字
    if [[ "$user_input" =~ ^[0-9]+$ ]]; then
        echo "$user_input"
    else
        log_warn "输入无效，使用默认值: $default"
        echo "$default"
    fi
}

# 单选菜单 (返回选择的序号)
select_option() {
    local prompt="$1"; shift
    local options=("$@")
    local choice

    echo -e "\n${MAGENTA}${prompt}${NC}"
    for i in "${!options[@]}"; do
        printf "  %s[%s]%s %s\n" "${CYAN}" "$((i + 1))" "${NC}" "${options[$i]}"
    done

    while true; do
        read -rp "$(echo -e "${BOLD}请选择 (1-${#options[@]})${NC}: ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo ""
            return $((choice - 1))
        fi
        log_warn "请输入 1-${#options[@]} 之间的数字"
    done
}

# 获取内核主版本号
kernel_version() {
    uname -r | grep -oP '^\d+\.\d+'
}

# 比较版本号: version_ge 5.4 4.9 → true
version_ge() {
    printf '%s\n%s' "$2" "$1" | sort -V -C
}

# 安全读取 sysctl 值
sysctl_get() {
    sysctl -n "$1" 2>/dev/null || echo "N/A"
}

# 获取发行版 (更细粒度)
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu|linuxmint|pop|kali) echo "debian" ;;
            centos|rhel|almalinux|rocky|ol|amzn|fedora) echo "rhel" ;;
            alpine) echo "alpine" ;;
            arch|manjaro|endeavouros) echo "arch" ;;
            opensuse*|sles) echo "suse" ;;
            *) echo "unknown" ;;
        esac
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "unknown"
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
        sed -i '/\bswap\b/d' /etc/fstab

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

    # 加载模块
    modprobe tcp_bbr 2>/dev/null || true

    # 持久化 BBR 模块
    if [ ! -f /etc/modules-load.d/bbr.conf ]; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        log_info "BBR 模块已持久化"
    fi

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

    log_info "当前拥塞控制: ${current_cc} → 恢复为 cubic"
    modprobe tcp_cubic 2>/dev/null || true

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

    # 清理 BBR 模块持久化
    rm -f /etc/modules-load.d/bbr.conf

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
            SWAPPINESS=5;   MIN_FREE_KB=131072
        elif [ "$MEM_MB" -ge 4096 ]; then
            SWAPPINESS=10;  MIN_FREE_KB=65536
        elif [ "$MEM_MB" -ge 1024 ]; then
            SWAPPINESS=20;  MIN_FREE_KB=32768
        else
            SWAPPINESS=30;  MIN_FREE_KB=16384
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
vm.min_free_kbytes = ${MIN_FREE_KB}
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
    else
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        log_info "时区已设置 (localtime 方式)"
    fi
    log_info "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# =============================================================================
# 5. 服务清理
# =============================================================================
cleanup_services() {
    log_step "服务清理"
    log_info "清理不必要的服务..."
    local services=("avahi-daemon" "cups" "exim4" "getty@tty1" "serial-getty@ttyS0")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            log_info "  已禁用: $svc"
        fi
    done
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
# 7. 系统清理
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

    # 清理 systemd 日志 (保留 500M)
    journalctl --rotate 2>/dev/null || true
    journalctl --vacuum-time=1s 2>/dev/null || true
    journalctl --vacuum-size=500M 2>/dev/null || true

    log_info "系统清理完成!"
}

# =============================================================================
# 8. 常用工具安装
# =============================================================================
linux_tools() {
    log_step "常用工具安装"
    local tools=("curl" "wget" "sudo" "jq" "htop" "vim" "unzip" "tar" "tree" "git")
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
    systemctl stop docker docker.socket 2>/dev/null || true
    systemctl disable docker containerd 2>/dev/null || true

    if command -v apt &>/dev/null; then
        apt remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        apt autoremove -y 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
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

    # 使用 linuxmirrors 脚本一键安装（自动适配所有发行版 + 国内镜像源）
    install_pkg curl
    local country
    country=$(curl -s --max-time 3 ipinfo.io/country 2>/dev/null || echo "")

    if [ "$country" = "CN" ]; then
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

    # ── 配置 daemon.json（镜像加速） ──
    log_info "配置 Docker daemon..."
    install_add_docker_cn

    log_info "Docker 状态: $(systemctl is-active docker 2>/dev/null || echo 'inactive')"
    docker --version 2>/dev/null || true
    docker compose version 2>/dev/null || true
}

# ── 配置国内 Docker 镜像加速 ──
install_add_docker_cn() {
    local country
    country=$(curl -s --max-time 3 ipinfo.io/country 2>/dev/null || echo "")
    if [ "$country" = "CN" ]; then
        mkdir -p /etc/docker
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
  ]
}
DOCKEREOF
        log_info "已配置国内 Docker 镜像加速"
        systemctl restart docker 2>/dev/null || true
    else
        log_info "非国内环境，无需配置镜像加速"
    fi
}

# ── 更换 Docker 镜像源（调用 linuxmirrors 脚本） ──
docker_change_mirror() {
    log_step "更换 Docker 源"
    log_info "正在调用 linuxmirrors 一键换源脚本..."
    bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
    systemctl restart docker 2>/dev/null || true
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
    systemctl restart docker 2>/dev/null || true
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
  "experimental": true,
  "ip6tables": true
}
EOF
        log_info "已创建 daemon.json 并开启 IPv6"
        systemctl restart docker 2>/dev/null || true
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
    jq '. + {"ipv6": true, "fixed-cidr-v6": "2001:db8:1::/64", "experimental": true, "ip6tables": true}' "$CONFIG_FILE" > "$tmp_file" 2>/dev/null
    if [ -s "$tmp_file" ]; then
        mv "$tmp_file" "$CONFIG_FILE"
        log_info "已开启 Docker IPv6"
    else
        rm -f "$tmp_file"
        log_warn "jq 处理失败"
        return 1
    fi

    systemctl restart docker 2>/dev/null || true
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
    jq 'del(.["fixed-cidr-v6"]) | .ipv6 = false' "$CONFIG_FILE" > "$tmp_file" 2>/dev/null
    if [ -s "$tmp_file" ]; then
        mv "$tmp_file" "$CONFIG_FILE"
        log_info "已关闭 Docker IPv6"
    else
        rm -f "$tmp_file"
        log_warn "jq 处理失败"
        return 1
    fi

    systemctl restart docker 2>/dev/null || true
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

    echo -e "${CYAN}✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦${NC}"
    echo -e "       ${BOLD}${GREEN}📊  VPS 系统信息${NC}"
    echo -e "${CYAN}✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦${NC}"

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
    queue_alg=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    dns_info=$(awk '/^nameserver/{printf "%s ", $2} END {print ""}' /etc/resolv.conf)

    runtime=$(awk -F. '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);
        if(d>0) printf "%d天 ",d; if(h>0) printf "%d时 ",h; printf "%d分",m}' /proc/uptime)

    timezone=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}' || date +"%Z")

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
    cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5;
        if(NR==1){u1=u;t1=t} else printf "%.1f", (u-u1)*100/(t-t1)}' \
        <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat) 2>/dev/null && echo "" || echo "N/A")

    mem_info=$(free -h | awk 'NR==2{printf "%s/%s (%.0f%%)", $3, $2, $3*100/$2}')
    swap_info=$(free -h | awk 'NR==3{if($2+0==0) print "无"; else printf "%s/%s (%.0f%%)", $3, $2, $3*100/$2}')
    disk_info=$(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')

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
        echo -e "${CYAN}✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦${NC}"
        echo -e "       ${BOLD}${GREEN}🐳  Docker 管理${NC}"
        echo ""
        echo -e "  容器:${c_count}  镜像:${i_count}  网络:${n_count}  卷:${v_count}"
        echo ""
        echo -e "${CYAN}✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦${NC}"
        echo ""
        echo -e "  ${GREEN} 1${NC}  容器列表"
        echo -e "  ${GREEN} 2${NC}  镜像列表"
        echo -e "  ${GREEN} 3${NC}  容器操作"
        echo -e "  ${GREEN} 4${NC}  镜像操作"
        echo -e "  ${GREEN} 5${NC}  全局状态"
        echo -e "  ${GREEN} 6${NC}  清理无用资源"
        echo -e "  ${RED} 7${NC}  卸载 Docker"
        echo -e "  ${GREEN} 8${NC}  更换Docker源"
        echo -e "  ${GREEN} 9${NC}  编辑daemon.json"
        echo -e "  ${GREEN}11${NC}  开启IPv6访问"
        echo -e "  ${GREEN}12${NC}  关闭IPv6访问"
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${RED} 0${NC}  返回主菜单"
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
            *) log_warn "无效选项" ;;
        esac
    done
}

# ── 智能内核调优子菜单 ──
kernel_tuning_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "${CYAN}✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦${NC}"
        echo -e "       ${BOLD}${GREEN}🔧  智能内核调优${NC}"
        echo -e "${CYAN}✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦${NC}"
        echo ""
        echo -e "  ${CYAN}1${NC}  自动检测并优化"
        echo -e "  ${CYAN}2${NC}  当前网络内核参数"
        echo -e "  ${CYAN}3${NC}  回滚优化设置"
        echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0${NC}  返回主菜单"
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
            *) log_warn "无效选项" ;;
        esac
    done
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
        tz=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}' || echo "N/A")
        if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            bbr_status="${GREEN}已启用${NC}"
        else
            bbr_status="${RED}未启用${NC}"
        fi

        echo ""
        echo -e "${CYAN}✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦${NC}"
        echo -e "       ${BOLD}${GREEN}🚀  VPS 初始化工具${NC}  ${YELLOW}v1.0${NC}"
        echo ""
        echo -e "  ${CYAN}系统${NC}  $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '=' -f2 | tr -d '"')"
        echo -e "  ${CYAN}架构${NC}  $(uname -m)"
        echo -e "  ${CYAN}内核${NC}  $(uname -r | cut -d- -f1)"
        echo -e "  ${CYAN}内存${NC}  ${mem_usage}"
        echo -e "  ${CYAN}Swap${NC}  ${swap_status}"
        echo -e "  ${CYAN}磁盘${NC}  $(df -h / | awk 'NR==2{print $4}') 可用"
        echo -e "  ${CYAN}时区${NC}  ${tz}"
        echo -e "  ${CYAN}BBR${NC}  ${bbr_status}"
        echo -e "${CYAN}✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦ ─── ✦${NC}"
        echo ""

        # ── 功能菜单 ──
        echo -e "  ${CYAN} 1${NC}  查看系统详情"
        echo -e "  ${CYAN} 2${NC}  时区设置"
        echo -e "  ${CYAN} 3${NC}  系统更新"
        echo -e "  ${CYAN} 4${NC}  安装常用工具"
        echo -e "  ${CYAN} 5${NC}  BBR 管理"
        echo -e "  ${CYAN} 6${NC}  Swap 配置"
        echo -e "  ${CYAN} 7${NC}  Docker 管理"
        echo -e "  ${CYAN} 8${NC}  智能内核调优"
        echo -e "  ${CYAN} 9${NC}  服务精简"
        echo -e "  ${CYAN}10${NC}  系统垃圾清理"
        echo -e "  ${CYAN}11${NC}  NodeQuality测试"

        echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
        echo -e "   ${YELLOW}A${NC}  一键自动优化      ${RED}0${NC}  退出脚本"
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
                local cc
                cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
                if [[ "$cc" == "bbr" ]]; then
                    log_info "BBR 当前: ${GREEN}已开启${NC}"
                    if confirm "是否关闭 BBR?" "n"; then
                        disable_bbr
                    fi
                else
                    log_info "BBR 当前: ${RED}已关闭${NC} (${cc})"
                    if confirm "是否开启 BBR?" "y"; then
                        enable_bbr
                    fi
                fi
                ;;
            6)
                local size=2048 swp=60
                size=$(input_number "Swap 大小 (MB)" "2048")
                swp=$(input_number "Swappiness 值 (1-100)" "60")
                [[ $swp -gt 100 ]] && swp=100
                [[ $swp -lt 1 ]] && swp=1
                create_swap "$size" "$swp"
                ;;
            7)
                docker_manage
                continue
                ;;
            8)
                kernel_tuning_menu
                continue
                ;;
            9)
                cleanup_services
                ;;
            10)
                linux_clean
                ;;
            11)
                bash <(curl -sL https://run.NodeQuality.com) || true
                ;;
            [Aa])
                echo ""
                echo -e "${YELLOW}自动模式：按菜单顺序执行...${NC}"
                set_timezone
                linux_update
                linux_tools
                enable_bbr
                create_swap 2048 60
                install_docker
                auto_kernel_optimize "true" "true"
                cleanup_services
                linux_clean
                echo ""
                log_info "全部完成! 按回车返回菜单..."
                read -r
                ;;     
            0)
                echo ""
                log_info "退出。"
                exit 0
                ;;
            *)
                log_warn "无效选项，请输入 0-11 或 A"
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
