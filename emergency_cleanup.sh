#!/bin/bash

# 紧急清理脚本 - 清理残留的 stress-ng 进程和相关资源
# 当主脚本异常退出时使用

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示帮助
show_help() {
    cat << EOF
紧急清理脚本 - 清理残留的 stress-ng 进程

用法: $0 [选项]

选项:
  -f    强制清理，不询问确认
  -v    详细输出
  -h    显示帮助信息

功能:
  - 查找并终止所有 stress-ng 进程
  - 清理相关的控制脚本进程
  - 显示清理前后的进程状态
  - 检查系统资源使用情况

示例:
  $0        # 交互式清理
  $0 -f     # 强制清理
  $0 -v     # 详细输出
EOF
    exit 0
}

# 显示当前 stress-ng 进程状态
show_stress_processes() {
    echo -e "${BLUE}当前 stress-ng 相关进程:${NC}"
    local stress_processes=$(ps aux | grep -E "(stress-ng|smart_resource_control)" | grep -v grep)
    
    if [ -n "$stress_processes" ]; then
        echo "$stress_processes"
        echo ""
        
        # 统计进程数
        local stress_count=$(pgrep -f "stress-ng" | wc -l)
        local control_count=$(pgrep -f "smart_resource_control" | wc -l)
        
        echo "统计:"
        echo "  stress-ng 进程: $stress_count 个"
        echo "  控制脚本进程: $control_count 个"
    else
        echo "  未发现 stress-ng 相关进程"
    fi
    echo ""
}

# 显示系统资源状态
show_system_status() {
    echo -e "${BLUE}当前系统状态:${NC}"
    
    # CPU 使用率
    local cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else printf "%.1f", (u-u1) * 100 / (t-t1); }' \
        <(grep 'cpu ' /proc/stat; sleep 1; grep 'cpu ' /proc/stat) 2>/dev/null || echo "N/A")
    
    # 内存使用率  
    local mem_usage=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100}')
    
    # 系统负载
    local load_avg=$(uptime | awk -F'load average:' '{print $2}')
    
    echo "  CPU 使用率: ${cpu_usage}%"
    echo "  内存使用率: ${mem_usage}%"
    echo "  系统负载:$load_avg"
    echo ""
}

# 清理 stress-ng 进程
cleanup_stress_processes() {
    local force=$1
    local verbose=$2
    
    # 查找所有相关进程
    local stress_pids=$(pgrep -f "stress-ng" 2>/dev/null)
    local control_pids=$(pgrep -f "smart_resource_control" 2>/dev/null)
    
    if [ -z "$stress_pids" ] && [ -z "$control_pids" ]; then
        log "没有发现需要清理的进程"
        return 0
    fi
    
    # 如果不是强制模式，询问确认
    if [ "$force" != true ]; then
        echo -e "${YELLOW}将要清理以下进程:${NC}"
        if [ -n "$stress_pids" ]; then
            echo "  stress-ng PIDs: $stress_pids"
        fi
        if [ -n "$control_pids" ]; then
            echo "  控制脚本 PIDs: $control_pids"
        fi
        echo ""
        read -p "确认清理? [y/N]: " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "用户取消清理"
            return 0
        fi
    fi
    
    log "开始清理进程..."
    
    # 优雅终止控制脚本
    if [ -n "$control_pids" ]; then
        log "发送 TERM 信号到控制脚本..."
        echo "$control_pids" | xargs -r kill -TERM 2>/dev/null || true
        sleep 2
    fi
    
    # 优雅终止 stress-ng 进程
    if [ -n "$stress_pids" ]; then
        log "发送 TERM 信号到 stress-ng 进程..."
        echo "$stress_pids" | xargs -r kill -TERM 2>/dev/null || true
        sleep 3
    fi
    
    # 检查是否还有残留进程
    local remaining_stress=$(pgrep -f "stress-ng" 2>/dev/null)
    local remaining_control=$(pgrep -f "smart_resource_control" 2>/dev/null)
    
    # 强制终止残留进程
    if [ -n "$remaining_stress" ]; then
        warn "强制终止残留的 stress-ng 进程: $remaining_stress"
        echo "$remaining_stress" | xargs -r kill -KILL 2>/dev/null || true
        sleep 1
    fi
    
    if [ -n "$remaining_control" ]; then
        warn "强制终止残留的控制脚本: $remaining_control"  
        echo "$remaining_control" | xargs -r kill -KILL 2>/dev/null || true
        sleep 1
    fi
    
    # 最终检查
    local final_stress=$(pgrep -f "stress-ng" 2>/dev/null)
    local final_control=$(pgrep -f "smart_resource_control" 2>/dev/null)
    
    if [ -n "$final_stress" ] || [ -n "$final_control" ]; then
        error "清理未完全成功，仍有进程残留:"
        [ -n "$final_stress" ] && echo "  stress-ng: $final_stress"
        [ -n "$final_control" ] && echo "  控制脚本: $final_control"
        echo ""
        echo "请尝试以下命令手动清理:"
        echo "  sudo pkill -9 -f stress-ng"
        echo "  sudo pkill -9 -f smart_resource_control"
        return 1
    else
        log "所有进程清理完成"
        return 0
    fi
}

# 清理日志文件
cleanup_logs() {
    local verbose=$1
    
    log "清理临时日志文件..."
    
    local log_files="/tmp/smart_resource_control.log /tmp/system_monitor.log"
    
    for log_file in $log_files; do
        if [ -f "$log_file" ]; then
            if [ "$verbose" = true ]; then
                log "清理日志文件: $log_file"
            fi
            rm -f "$log_file" 2>/dev/null || warn "无法删除 $log_file"
        fi
    done
}

# 主函数
main() {
    local force=false
    local verbose=false
    
    # 解析参数
    while getopts "fvh" opt; do
        case $opt in
            f) force=true ;;
            v) verbose=true ;;
            h) show_help ;;
            \?)
                error "无效选项: -$OPTARG"
                echo "使用 -h 查看帮助"
                exit 1
                ;;
        esac
    done
    
    echo -e "${BLUE}紧急清理脚本${NC}"
    echo "=================="
    echo ""
    
    # 显示清理前状态
    show_stress_processes
    show_system_status
    
    # 执行清理
    if cleanup_stress_processes "$force" "$verbose"; then
        log "进程清理成功"
    else
        error "进程清理失败"
        exit 1
    fi
    
    # 清理日志文件
    cleanup_logs "$verbose"
    
    echo ""
    echo "清理后状态:"
    show_stress_processes
    show_system_status
    
    log "紧急清理完成"
}

# 运行主函数
main "$@"