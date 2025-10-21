#!/bin/bash

# 系统资源监控脚本
# 配合智能资源控制脚本使用，提供实时监控界面

REFRESH_INTERVAL=2
LOG_FILE="/tmp/system_monitor.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 获取系统信息
get_system_info() {
    echo "=== 系统资源监控 ==="
    echo "更新时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

# 获取CPU信息
get_cpu_info() {
    local cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else printf "%.1f", (u-u1) * 100 / (t-t1); }' \
        <(grep 'cpu ' /proc/stat; sleep 1; grep 'cpu ' /proc/stat) 2>/dev/null)
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^[ \t]*//')
    local cpu_cores=$(nproc)
    
    echo -e "${BLUE}CPU 信息:${NC}"
    printf "  使用率: "
    if (( $(echo "$cpu_usage > 70" | bc -l) )); then
        echo -e "${RED}${cpu_usage}%${NC}"
    elif (( $(echo "$cpu_usage > 50" | bc -l) )); then
        echo -e "${YELLOW}${cpu_usage}%${NC}"
    else
        echo -e "${GREEN}${cpu_usage}%${NC}"
    fi
    echo "  核心数: $cpu_cores"
    echo "  负载平均: $load_avg"
    echo ""
}

# 获取内存信息
get_memory_info() {
    local mem_info=$(free -h | grep '^Mem:')
    local mem_total=$(echo $mem_info | awk '{print $2}')
    local mem_used=$(echo $mem_info | awk '{print $3}')
    local mem_free=$(echo $mem_info | awk '{print $4}')
    local mem_available=$(echo $mem_info | awk '{print $7}')
    
    # 计算使用率
    local mem_total_kb=$(free | grep '^Mem:' | awk '{print $2}')
    local mem_used_kb=$(free | grep '^Mem:' | awk '{print $3}')
    local mem_usage=$(echo "scale=1; $mem_used_kb * 100 / $mem_total_kb" | bc)
    
    echo -e "${BLUE}内存信息:${NC}"
    printf "  使用率: "
    if (( $(echo "$mem_usage > 80" | bc -l) )); then
        echo -e "${RED}${mem_usage}%${NC}"
    elif (( $(echo "$mem_usage > 60" | bc -l) )); then
        echo -e "${YELLOW}${mem_usage}%${NC}"
    else
        echo -e "${GREEN}${mem_usage}%${NC}"
    fi
    echo "  总内存: $mem_total"
    echo "  已使用: $mem_used"
    echo "  可用内存: $mem_available"
    echo ""
}

# 获取磁盘信息
get_disk_info() {
    echo -e "${BLUE}磁盘使用:${NC}"
    df -h | grep -E '^/dev/' | while read line; do
        local usage=$(echo $line | awk '{print $5}' | tr -d '%')
        local mount=$(echo $line | awk '{print $6}')
        local size=$(echo $line | awk '{print $2}')
        local used=$(echo $line | awk '{print $3}')
        local avail=$(echo $line | awk '{print $4}')
        
        printf "  %-15s " "$mount"
        if [ $usage -gt 90 ]; then
            echo -e "${RED}${usage}%${NC} (${used}/${size})"
        elif [ $usage -gt 70 ]; then
            echo -e "${YELLOW}${usage}%${NC} (${used}/${size})"
        else
            echo -e "${GREEN}${usage}%${NC} (${used}/${size})"
        fi
    done
    echo ""
}

# 获取网络信息
get_network_info() {
    echo -e "${BLUE}网络接口:${NC}"
    local interfaces=$(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -v lo)
    
    for iface in $interfaces; do
        local status=$(cat /sys/class/net/$iface/operstate 2>/dev/null)
        printf "  %-10s " "$iface"
        if [ "$status" = "up" ]; then
            echo -e "${GREEN}UP${NC}"
        else
            echo -e "${RED}DOWN${NC}"
        fi
    done
    echo ""
}

# 获取进程信息
get_process_info() {
    echo -e "${BLUE}TOP 进程:${NC}"
    echo "  PID    CPU%   MEM%   命令"
    ps aux --sort=-%cpu | head -6 | tail -5 | while read line; do
        local pid=$(echo $line | awk '{print $2}')
        local cpu=$(echo $line | awk '{print $3}')
        local mem=$(echo $line | awk '{print $4}')
        local cmd=$(echo $line | awk '{print $11}' | cut -c1-20)
        printf "  %-6s %-6s %-6s %s\n" "$pid" "$cpu" "$mem" "$cmd"
    done
    echo ""
}

# 检查stress-ng进程
check_stress_processes() {
    local stress_count=$(pgrep -c stress-ng 2>/dev/null || echo 0)
    local control_running=$(pgrep -f smart_resource_control 2>/dev/null | wc -l)
    
    echo -e "${BLUE}压力测试状态:${NC}"
    if [ $stress_count -gt 0 ]; then
        echo -e "  stress-ng 进程: ${GREEN}$stress_count 个运行中${NC}"
    else
        echo -e "  stress-ng 进程: ${YELLOW}未运行${NC}"
    fi
    
    if [ $control_running -gt 0 ]; then
        echo -e "  控制脚本: ${GREEN}运行中${NC}"
    else
        echo -e "  控制脚本: ${YELLOW}未运行${NC}"
    fi
    echo ""
}

# 显示帮助
show_help() {
    cat << EOF
系统资源监控脚本

用法: $0 [选项]

选项:
  -i <秒数>    刷新间隔 (默认: $REFRESH_INTERVAL 秒)
  -l <文件>    日志文件 (默认: $LOG_FILE)
  -1           只运行一次，不持续监控
  -h           显示帮助信息

示例:
  $0              # 默认每2秒刷新
  $0 -i 5         # 每5秒刷新
  $0 -1           # 只显示一次
EOF
    exit 0
}

# 主监控循环
main_monitor() {
    local once_only=false
    local interval=$REFRESH_INTERVAL
    
    # 解析参数
    while getopts "i:l:1h" opt; do
        case $opt in
            i) interval=$OPTARG ;;
            l) LOG_FILE=$OPTARG ;;
            1) once_only=true ;;
            h) show_help ;;
        esac
    done
    
    # 检查依赖
    if ! command -v bc >/dev/null 2>&1; then
        echo "错误: 需要安装 bc 计算器"
        echo "sudo apt-get install bc  # Ubuntu/Debian"
        echo "sudo yum install bc      # CentOS/RHEL"
        exit 1
    fi
    
    while true; do
        # 清屏
        clear
        
        # 显示系统信息
        get_system_info
        get_cpu_info
        get_memory_info
        get_disk_info
        get_network_info
        get_process_info
        check_stress_processes
        
        echo "按 Ctrl+C 退出监控"
        echo "日志文件: $LOG_FILE"
        
        # 记录到日志文件
        {
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 系统监控快照"
            get_cpu_info | grep -E "(使用率|负载)"
            get_memory_info | grep "使用率"
            echo "---"
        } >> "$LOG_FILE"
        
        # 如果只运行一次，退出
        if [ "$once_only" = true ]; then
            break
        fi
        
        # 等待指定间隔
        sleep $interval
    done
}

# 信号处理
cleanup() {
    echo ""
    echo "监控已停止"
    exit 0
}

trap cleanup SIGINT SIGTERM

# 运行主函数
main_monitor "$@"