#!/bin/bash
# =============================================================================
# VPS 初始化配置脚本 (交互式)
# 功能：Swap / BBR / 系统优化
# 适用：Debian 10+ / Ubuntu 18.04+ / CentOS 7+
# 用法：chmod +x vps_init.sh && sudo ./vps_init.sh
#       (也支持非交互: AUTO=1 ./vps_init.sh)
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

# 查找已有 sysctl 配置行号 (用于去重写入)
# 默认写入 /etc/sysctl.d/ 下对应文件 (优先级高于 /etc/sysctl.conf)
sysctl_set() {
    local key="$1"
    local val="$2"
    local file="${3:-/etc/sysctl.d/99-custom.conf}"

    sysctl -w "$key=$val" 2>/dev/null
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

    log_step "1. 创建 Swap"

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
        swapoff -a

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
        fallocate -l ${size_mb}M "$swap_file"
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
    log_step "2. 开启 BBR 拥塞控制"

    local kernel_ver
    kernel_ver=$(uname -r | cut -d. -f1,2)

    # BBR 需要内核 >= 4.9
    if [[ $(echo "$kernel_ver < 4.9" | bc -l 2>/dev/null || echo "0") -eq 1 ]]; then
        log_warn "内核版本 ($(uname -r)) < 4.9，不支持 BBR。"
        echo ""
        echo "  Ubuntu/Debian 升级内核:"
        echo "    apt update && apt install -y linux-image-generic-hwe-22.04"
        echo ""
        echo "  CentOS 7 升级内核:"
        echo "    rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org"
        echo "    rpm -Uvh https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm"
        echo "    yum --enablerepo=elrepo-kernel install -y kernel-ml && reboot"
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

    # 加载模块 & 配置
    modprobe tcp_bbr 2>/dev/null || true

    # 写入 /etc/sysctl.d/99-bbr.conf
    local bbr_conf="/etc/sysctl.d/99-bbr.conf"
    cat > "$bbr_conf" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system 2>/dev/null

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
    log_step "2. 关闭 BBR 拥塞控制"

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

    if [[ "$current_cc" != "bbr" ]]; then
        log_info "BBR 未启用，无需关闭 (当前: ${current_cc})"
        return 0
    fi

    log_info "当前拥塞控制: ${current_cc} → 恢复为 cubic"
    modprobe tcp_cubic 2>/dev/null || true

    sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null
    sysctl -w net.core.default_qdisc=fq_codel 2>/dev/null

    rm -f /etc/sysctl.d/99-bbr.conf
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = cubic
EOF

    sysctl --system 2>/dev/null
    sleep 1

    local new_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    log_info "当前拥塞控制: ${new_cc}"
}

# =============================================================================
# 3. 系统优化 (内核网络 + 文件句柄)
# =============================================================================
system_optimize() {
    local enable_network="$1"
    local enable_limits="$2"

    log_step "3. 系统优化"

    # --- 内核网络参数 ---
    if [[ "$enable_network" == "true" ]]; then
        log_info "应用内核网络优化..."

        # 根据内存动态调整缓冲区大小
        local mem_mb
        mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
        local rmem_max wmem_max tcp_rmem tcp_wmem backlog somaxconn
        if [[ $mem_mb -le 256 ]]; then
            rmem_max=131072; wmem_max=131072
            tcp_rmem="4096 87380 131072"; tcp_wmem="4096 65536 131072"
            backlog=256; somaxconn=128
        elif [[ $mem_mb -le 512 ]]; then
            rmem_max=1048576; wmem_max=1048576
            tcp_rmem="4096 87380 1048576"; tcp_wmem="4096 65536 1048576"
            backlog=1000; somaxconn=256
        elif [[ $mem_mb -le 1024 ]]; then
            rmem_max=4194304; wmem_max=4194304
            tcp_rmem="4096 87380 4194304"; tcp_wmem="4096 65536 4194304"
            backlog=4000; somaxconn=512
        else
            rmem_max=16777216; wmem_max=16777216
            tcp_rmem="4096 87380 16777216"; tcp_wmem="4096 65536 16777216"
            backlog=10000; somaxconn=1024
        fi
        log_info "内存: ${mem_mb}MB, rmem_max=${rmem_max}, netdev_max_backlog=${backlog}, somaxconn=${somaxconn}"

        cat > /etc/sysctl.d/99-network.conf <<SYSCTL_EOF
# ========== TCP 性能优化 ==========
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0

# ========== TCP/UDP 缓冲区优化 ==========
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}
net.ipv4.udp_mem = 256000 512000 1024000
net.ipv6.udp_mem = 256000 512000 1024000

# ========== 临时端口范围 ==========
net.ipv4.ip_local_port_range = 10240 65535

# ========== 突发流量处理 ==========
net.core.netdev_budget = 600
net.core.netdev_max_backlog = ${backlog}
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = ${somaxconn}

# ========== 网络安全和防护 ==========
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ========== 内存和连接数优化 ==========
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_buckets = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 300
fs.file-max = 2097152
fs.nr_open = 1048576

SYSCTL_EOF
        sysctl --system 2>/dev/null
    else
        log_warn "跳过内核网络优化"
    fi

    # --- 文件句柄 ---
    if [[ "$enable_limits" == "true" ]]; then
        log_info "优化文件句柄限制..."
        cat >> /etc/security/limits.conf <<EOF
*    soft    nofile    655350
*    hard    nofile    655350
*    soft    nproc     655350
*    hard    nproc     655350
root soft    nofile    655350
root hard    nofile    655350
EOF

        if [[ -f /etc/systemd/system.conf ]]; then
            if grep -q "^DefaultLimitNOFILE" /etc/systemd/system.conf 2>/dev/null; then
                sed -i 's/^DefaultLimitNOFILE=.*/DefaultLimitNOFILE=655350/' /etc/systemd/system.conf
            else
                echo "DefaultLimitNOFILE=655350" >> /etc/systemd/system.conf
            fi
            if grep -q "^DefaultLimitNPROC" /etc/systemd/system.conf 2>/dev/null; then
                sed -i 's/^DefaultLimitNPROC=.*/DefaultLimitNPROC=655350/' /etc/systemd/system.conf
            else
                echo "DefaultLimitNPROC=655350" >> /etc/systemd/system.conf
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
    log_step "4. 时区设置"
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
    log_step "5. 服务清理"
    log_info "清理不必要的服务..."
    local services=("avahi-daemon" "cups")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            log_info "  已禁用: $svc"
        fi
    done
}

# =============================================================================
# 交互式主菜单
# =============================================================================
main() {
    clear 2>/dev/null || true

    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║                                                  ║"
    echo "║       🖥️   VPS 一键初始化脚本                     ║"
    echo "║                                                  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    log_info "系统: ${OS} | 架构: $(uname -m) | 内核: $(uname -r)"
    log_info "内存: $(free -h | awk '/^Mem:/ {print $2}') | 磁盘: $(df -h / | awk 'NR==2 {print $2}')"

    while true; do
        echo ""
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}  主菜单${NC}"
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        printf "  ${CYAN}1${NC}  swap配置\n"
        printf "  ${CYAN}2${NC}  开启/关闭BBR           %s\n" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && echo "${GREEN}[已开启]${NC}" || echo "${RED}[已关闭]${NC}")"
        printf "  ${CYAN}3${NC}  系统优化\n"
        printf "  ${CYAN}4${NC}  时区设置               ${CYAN}[%s]${NC}\n" "$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')"
        printf "  ${CYAN}5${NC}  服务清理\n"
        printf "  ${CYAN}6${NC}  一键执行全部\n"
        printf "  ${RED}0${NC}  退出\n"
        echo ""

        local choice
        read -rp "$(echo -e "${BOLD}请输入选项 [0-6]${NC}: ")" choice

        case $choice in
            1)
                echo ""
                echo -e "${MAGENTA}━━ 1. swap配置 ━━${NC}"
                local size=2048 swp=60
                if confirm "是否创建/配置 Swap?" "y"; then
                    size=$(input_number "  Swap 大小 (MB)" "2048")
                    swp=$(input_number "  Swappiness 值 (1-100)" "60")
                    [[ $swp -gt 100 ]] && swp=100
                    [[ $swp -lt 1 ]] && swp=1
                    create_swap "$size" "$swp"
                fi
                ;;
            2)
                echo ""
                echo -e "${MAGENTA}━━ 2. 开启/关闭BBR ━━${NC}"
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
            3)
                echo ""
                echo -e "${MAGENTA}━━ 3. 系统优化 ━━${NC}"
                local net="false" limits="false"
                confirm "是否优化内核网络参数?" "y" && net="true"
                confirm "是否提升文件句柄上限?" "y" && limits="true"
                if [[ "$net" == "true" || "$limits" == "true" ]]; then
                    system_optimize "$net" "$limits"
                fi
                ;;
            4)
                echo ""
                echo -e "${MAGENTA}━━ 4. 时区设置 ━━${NC}"
                if confirm "是否设置时区为 Asia/Shanghai?" "y"; then
                    set_timezone
                fi
                ;;
            5)
                echo ""
                echo -e "${MAGENTA}━━ 5. 服务清理 ━━${NC}"
                if confirm "是否禁用多余服务 (avahi/cups)?" "n"; then
                    cleanup_services
                fi
                ;;
            6)
                echo ""
                echo -e "${YELLOW}一键执行全部配置...${NC}"
                create_swap 2048 60
                enable_bbr
                system_optimize "true" "true"
                set_timezone
                cleanup_services
                echo ""
                print_summary
                log_info "全部完成! 按回车返回菜单..."
                read -r
                ;;
            0)
                echo ""
                log_info "退出。"
                exit 0
                ;;
            *)
                log_warn "无效选项，请输入 0-6"
                ;;
        esac

        # 按回车继续
        if [[ "$choice" -ge 1 && "$choice" -le 6 ]]; then
            echo ""
            read -rp "$(echo -e "${BOLD}按回车返回菜单...${NC}")"
        fi
    done
}

# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        ✅  VPS 初始化全部完成!                    ║${NC}"
    echo -e "${GREEN}║                                                    ║${NC}"
    echo -e "${GREEN}║  建议执行 reboot 重启使所有配置生效                ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

main "$@"
