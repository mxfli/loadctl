#!/bin/bash

# 智能资源控制脚本 - 使用 stress-ng 实现安全的系统压力测试
# 特点：渐进式资源消耗、智能监控、自动调节、保护现有程序

set -euo pipefail

# 默认配置
DEFAULT_RUNTIME=900  # 15分钟
DEFAULT_CPU_TARGET=50  # 目标CPU使用率50%
DEFAULT_MEM_TARGET=50  # 目标内存使用率50%
MIN_USAGE=35  # 最小使用率
MAX_USAGE=65  # 最大使用率
ADJUSTMENT_INTERVAL=10  # 调整间隔（秒）
RAMP_UP_STEPS=5  # 渐进式启动步骤数

# 全局变量
SCRIPT_PID=$$
STRESS_PID=""
MONITOR_PID=""
CLEANUP_DONE=false
LOG_FILE="/tmp/smart_resource_control.log"

# 日志函数
# 日志输出函数：带时间戳，写入文件并回显
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 显示帮助信息
# 显示命令行帮助
show_help() {
    cat << EOF
智能资源控制脚本 v2.0

用法: $0 [选项]

描述:
  使用 stress-ng 实现安全的系统压力测试，具有以下特点：
  - 渐进式资源消耗，避免突然冲击
  - 智能监控和自动调节
  - 保护现有运行程序
  - 安全的资源限制和清理机制

选项:
  -t <秒数>     运行时间 (默认: $DEFAULT_RUNTIME 秒)
  -c <百分比>   目标CPU使用率 (默认: $DEFAULT_CPU_TARGET%, 范围: $MIN_USAGE-$MAX_USAGE%)
  -m <百分比>   目标内存使用率 (默认: $DEFAULT_MEM_TARGET%, 范围: $MIN_USAGE-$MAX_USAGE%)
  -i <秒数>     监控调整间隔 (默认: $ADJUSTMENT_INTERVAL 秒)
  -s <步骤数>   渐进启动步骤 (默认: $RAMP_UP_STEPS 步)
  -l <文件>     日志文件路径 (默认: $LOG_FILE)
  -T            测试模式，只显示配置不实际运行
  -h            显示此帮助信息

示例:
  $0 -t 600 -c 40 -m 45     # 运行10分钟，CPU目标40%，内存目标45%
  $0 -c 35 -m 40 -i 5       # CPU目标35%，内存40%，每5秒调整一次
  $0 -T -c 60 -m 55         # 测试模式，检查参数

注意:
  - 需要安装 stress-ng 工具
  - 建议以普通用户运行，避免 root 风险
  - 脚本会自动检测系统能力并调整参数
  - 使用 Ctrl+C 可随时安全停止
EOF
    exit 0
}

# 检查依赖
# 检查外部依赖命令是否可用
check_dependencies() {
    local missing_deps=()
    
    for cmd in stress-ng bc awk free top; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log "错误: 缺少必需的命令: ${missing_deps[*]}"
        log "请安装缺少的工具："
        log "  Ubuntu/Debian: sudo apt-get install stress-ng bc"
        log "  CentOS/RHEL: sudo yum install stress-ng bc"
        exit 1
    fi
}

# 获取系统信息
# 采集CPU核数与总内存信息
get_system_info() {
    CPU_CORES=$(nproc)
    TOTAL_MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
    
    log "系统信息："
    log "  CPU核数: $CPU_CORES"
    log "  总内存: ${TOTAL_MEM_GB}GB"
}

# 获取当前系统资源使用情况
# 采集当前CPU/内存使用率与系统负载（1秒平均）
get_current_usage() {
    # 获取CPU使用率（1秒平均值）
    local cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else print (u-u1) * 100 / (t-t1); }' \
        <(grep 'cpu ' /proc/stat; sleep 1; grep 'cpu ' /proc/stat) 2>/dev/null || echo "0")
    
    # 获取内存使用率（使用 available 字段来准确反映实际内存使用）
    local mem_info=$(free | grep '^Mem:')
    local mem_total=$(echo $mem_info | awk '{print $2}')
    local mem_available=$(echo $mem_info | awk '{print $7}')
    local mem_usage=$(echo "scale=1; ($mem_total - $mem_available) * 100 / $mem_total" | bc)
    
    # 获取系统负载
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    
    echo "${cpu_usage%.*} ${mem_usage%.*} $load_avg"
}

# 检查系统是否适合运行压力测试
# 在运行前评估系统是否过载，避免风险
check_system_readiness() {
    local usage_info=($(get_current_usage))
    local current_cpu=${usage_info[0]}
    local current_mem=${usage_info[1]}
    local load_avg=${usage_info[2]}
    
    log "当前系统状态："
    log "  CPU使用率: ${current_cpu}%"
    log "  内存使用率: ${current_mem}%"
    log "  系统负载: $load_avg"
    
    # 检查是否已经过载
    if [ "$current_cpu" -gt 80 ]; then
        log "错误: 当前CPU使用率过高 (${current_cpu}%)，不适合运行压力测试"
        return 1
    fi
    
    if [ "$current_mem" -gt 80 ]; then
        log "错误: 当前内存使用率过高 (${current_mem}%)，不适合运行压力测试"
        return 1
    fi
    
    if (( $(echo "$load_avg > $CPU_CORES * 2" | bc -l) )); then
        log "错误: 系统负载过高 ($load_avg)，不适合运行压力测试"
        return 1
    fi
    
    return 0
}

# 计算stress-ng参数
# 基于目标使用率的绝对值计算 CPU workers 与内存分配
calculate_stress_params() {
    local target_cpu=$1
    local target_mem=$2
    local baseline_mem=$3  # 当前系统基线内存使用率
    
    # 直接基于目标值计算CPU worker数量
    # 每个CPU worker大约消耗100/CPU_CORES的CPU使用率
    local cpu_workers=$((target_cpu * CPU_CORES / 100))
    if [ $cpu_workers -lt 1 ]; then
        cpu_workers=1
    elif [ $cpu_workers -gt $CPU_CORES ]; then
        cpu_workers=$CPU_CORES
    fi
    
    # 基于目标值减去基线使用率来计算stress-ng应分配的内存
    # 这样可以确保总体系统内存使用率达到目标值，而不是超过
    local mem_to_allocate=$((target_mem - baseline_mem))
    
    # 如果基线已经超过或接近目标，只分配最小内存
    if [ $mem_to_allocate -lt 5 ]; then
        mem_to_allocate=5  # 至少分配5%以保持stress-ng运行
    fi
    
    local mem_size_mb=$((TOTAL_MEM_KB * mem_to_allocate / 100 / 1024))
    if [ $mem_size_mb -lt 100 ]; then
        mem_size_mb=100  # 最小100MB
    fi
    
    echo "$cpu_workers $mem_size_mb"
}

# 渐进式启动stress-ng
# 分步提升负载，减少系统冲击并记录状态
start_stress_gradually() {
    local target_cpu=$1
    local target_mem=$2
    local steps=$3
    local baseline_mem=$4  # 基线内存使用率
    
    log "开始渐进式资源消耗 (${steps}步到达目标)"
    log "基线内存使用率: ${baseline_mem}%"
    
    for step in $(seq 1 $steps); do
        local step_cpu=$((target_cpu * step / steps))
        local step_mem=$((target_mem * step / steps))
        
        log "第${step}/${steps}步: 目标CPU ${step_cpu}%, 内存 ${step_mem}%"
        
        # 停止当前的stress-ng进程
        stop_stress
        
        # 计算当前步骤的参数（传入基线内存使用率）
        local params=($(calculate_stress_params $step_cpu $step_mem $baseline_mem))
        local cpu_workers=${params[0]}
        local mem_size=${params[1]}
        
        # 启动新的stress-ng进程
        stress-ng --cpu $cpu_workers --vm 1 --vm-bytes ${mem_size}M \
                  --timeout 0 --quiet &
        STRESS_PID=$!
        
        log "启动 stress-ng: CPU workers=$cpu_workers, 内存=${mem_size}MB, PID=$STRESS_PID"
        
        # 等待系统稳定（增加等待时间）
        sleep $((ADJUSTMENT_INTERVAL * 3))
        
        # 检查当前使用率
        local current_usage=($(get_current_usage))
        log "当前状态: CPU ${current_usage[0]}%, 内存 ${current_usage[1]}%"
    done
    
    log "渐进式启动完成"
}

# 停止stress-ng进程
# 停止主PID并清理残留的 stress-ng 进程
stop_stress() {
    # 停止记录的主进程
    if [ -n "$STRESS_PID" ] && kill -0 "$STRESS_PID" 2>/dev/null; then
        log "停止 stress-ng 主进程 PID $STRESS_PID"
        kill -TERM "$STRESS_PID" 2>/dev/null
        
        # 等待进程结束
        local count=0
        while [ $count -lt 5 ] && kill -0 "$STRESS_PID" 2>/dev/null; do
            sleep 1
            count=$((count + 1))
        done
        
        # 如果进程仍然存在，强制终止
        if kill -0 "$STRESS_PID" 2>/dev/null; then
            kill -KILL "$STRESS_PID" 2>/dev/null
            log "强制终止 stress-ng 主进程"
        fi
        
        STRESS_PID=""
    fi
    
    # 额外清理：查找并停止所有相关的 stress-ng 进程
    local stress_pids=$(pgrep -f "stress-ng" 2>/dev/null)
    if [ -n "$stress_pids" ]; then
        log "发现额外的 stress-ng 进程: $stress_pids"
        echo "$stress_pids" | xargs -r kill -TERM 2>/dev/null || true
        sleep 2
        
        # 检查是否还有残留进程
        local remaining_pids=$(pgrep -f "stress-ng" 2>/dev/null)
        if [ -n "$remaining_pids" ]; then
            log "强制终止残留的 stress-ng 进程: $remaining_pids"
            echo "$remaining_pids" | xargs -r kill -KILL 2>/dev/null || true
        fi
    fi
}

# 智能调节资源使用
# 基于监控数据适度调整目标，避免频繁重启和过度敏感
intelligent_adjustment() {
    local original_cpu_target=$1
    local original_mem_target=$2
    local baseline_mem=$3  # 基线内存使用率（启动前的系统内存使用）
    local target_cpu=$original_cpu_target
    local target_mem=$original_mem_target
    # 初始化stress-ng分配的内存百分比（目标内存 - 基线内存）
    local stress_ng_mem_allocation=$((target_mem - baseline_mem))
    if [ $stress_ng_mem_allocation -lt 0 ]; then
        stress_ng_mem_allocation=0
    fi
    
    while true; do
        local current_usage=($(get_current_usage))
        local current_cpu=${current_usage[0]}
        local current_mem=${current_usage[1]}
        local load_avg=${current_usage[2]}
        
        # 动态更新基线内存：当前总内存使用 - stress-ng分配的内存
        # 这样可以反映除stress-ng外其他应用的内存变化
        local new_baseline_mem=$((current_mem - stress_ng_mem_allocation))
        if [ $new_baseline_mem -lt 5 ]; then
            new_baseline_mem=5  # 最小基线为5%
        fi
        
        # 如果基线变化超过3%，记录日志并更新
        local baseline_diff=$((new_baseline_mem - baseline_mem))
        if [ $baseline_diff -lt 0 ]; then
            baseline_diff=$((-baseline_diff))
        fi
        if [ $baseline_diff -gt 3 ]; then
            log "基线内存变化: ${baseline_mem}% -> ${new_baseline_mem}% (差距${baseline_diff}%)"
            baseline_mem=$new_baseline_mem
        fi
        
        log "监控: CPU ${current_cpu}%, 内存 ${current_mem}%, 负载 $load_avg, 基线 ${baseline_mem}%"
        
        # 检查是否需要调整（只有差距超过10%时才调整）
        local need_adjustment=false
        local new_target_cpu=$target_cpu
        local new_target_mem=$target_mem
        local cpu_diff=$((current_cpu - target_cpu))
        local mem_diff=$((${current_mem%.*} - target_mem))
        
        # 取绝对值
        if [ $cpu_diff -lt 0 ]; then
            cpu_diff=$((-cpu_diff))
        fi
        if [ $mem_diff -lt 0 ]; then
            mem_diff=$((-mem_diff))
        fi
        
        # CPU使用率过高，降低目标
        if [ $current_cpu -gt $MAX_USAGE ]; then
            new_target_cpu=$((target_cpu - 5))
            need_adjustment=true
            log "CPU使用率过高，降低目标到 ${new_target_cpu}%"
        # CPU使用率与目标差距超过10%且过低，提高目标（但不超过用户指定的原始目标）
        elif [ $cpu_diff -gt 10 ] && [ $current_cpu -lt $target_cpu ]; then
            new_target_cpu=$((target_cpu + 5))
            # 不能超过用户指定的原始目标
            if [ $new_target_cpu -gt $original_cpu_target ]; then
                new_target_cpu=$original_cpu_target
            fi
            if [ $new_target_cpu -gt $MAX_USAGE ]; then
                new_target_cpu=$MAX_USAGE
            fi
            need_adjustment=true
            log "CPU使用率过低（差距${cpu_diff}%），提高目标到 ${new_target_cpu}%"
        fi
        
        # 内存使用率过高，降低目标
        if [ ${current_mem%.*} -gt $MAX_USAGE ]; then
            new_target_mem=$((target_mem - 5))
            need_adjustment=true
            log "内存使用率过高，降低目标到 ${new_target_mem}%"
        # 内存使用率与目标差距超过10%且过低，提高目标（但不超过用户指定的原始目标）
        elif [ $mem_diff -gt 10 ] && [ ${current_mem%.*} -lt $target_mem ]; then
            new_target_mem=$((target_mem + 5))
            # 不能超过用户指定的原始目标
            if [ $new_target_mem -gt $original_mem_target ]; then
                new_target_mem=$original_mem_target
            fi
            if [ $new_target_mem -gt $MAX_USAGE ]; then
                new_target_mem=$MAX_USAGE
            fi
            need_adjustment=true
            log "内存使用率过低（差距${mem_diff}%），提高目标到 ${new_target_mem}%"
        fi
        
        # 检查系统负载是否过高
        if (( $(echo "$load_avg > $CPU_CORES * 1.5" | bc -l) )); then
            new_target_cpu=$((new_target_cpu - 10))
            need_adjustment=true
            log "系统负载过高 ($load_avg)，大幅降低CPU目标到 ${new_target_cpu}%"
        fi
        
        # 执行调整
        if [ "$need_adjustment" = true ]; then
            # 确保目标值在合理范围内
            if [ $new_target_cpu -lt 10 ]; then
                new_target_cpu=10
            elif [ $new_target_cpu -gt $MAX_USAGE ]; then
                new_target_cpu=$MAX_USAGE
            fi
            
            if [ $new_target_mem -lt 10 ]; then
                new_target_mem=10
            elif [ $new_target_mem -gt $MAX_USAGE ]; then
                new_target_mem=$MAX_USAGE
            fi
            
            # 重新计算并调整stress-ng参数
            local params=($(calculate_stress_params $new_target_cpu $new_target_mem $baseline_mem))
            local cpu_workers=${params[0]}
            local mem_size=${params[1]}
            
            # 检查参数是否有显著变化，只有变化较大时才重启进程
            local current_params=($(calculate_stress_params $target_cpu $target_mem $baseline_mem))
            local current_cpu_workers=${current_params[0]}
            local current_mem_size=${current_params[1]}
            
            local worker_diff=$((cpu_workers - current_cpu_workers))
            local mem_diff=$((mem_size - current_mem_size))
            
            # 取绝对值
            if [ $worker_diff -lt 0 ]; then
                worker_diff=$((-worker_diff))
            fi
            if [ $mem_diff -lt 0 ]; then
                mem_diff=$((-mem_diff))
            fi
            
            # 只有当参数变化较大时才重启进程
            if [ $worker_diff -gt 2 ] || [ $mem_diff -gt 5000 ]; then
                stop_stress
                stress-ng --cpu $cpu_workers --vm 1 --vm-bytes ${mem_size}M \
                          --timeout 0 --quiet &
                STRESS_PID=$!
                
                log "调整 stress-ng: CPU workers=$cpu_workers, 内存=${mem_size}MB"
            else
                log "参数变化较小，跳过进程重启"
            fi
            
            # 更新目标值
            target_cpu=$new_target_cpu
            target_mem=$new_target_mem
            
            # 更新stress-ng内存分配百分比
            stress_ng_mem_allocation=$((new_target_mem - baseline_mem))
            if [ $stress_ng_mem_allocation -lt 0 ]; then
                stress_ng_mem_allocation=0
            fi
        fi
        
        sleep $ADJUSTMENT_INTERVAL
    done
}

# 清理函数
# 清理监控与压力进程，确保系统恢复到安全状态
cleanup() {
    if [ "$CLEANUP_DONE" = true ]; then
        return
    fi
    CLEANUP_DONE=true
    
    log "开始清理资源..."
    
    # 停止监控进程
    if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill -TERM "$MONITOR_PID" 2>/dev/null
        sleep 1
    fi
    
    # 停止stress-ng进程
    stop_stress
    
    # 强制清理所有 stress-ng 进程（防止遗漏）
    log "强制清理所有 stress-ng 进程..."
    pkill -f "stress-ng" 2>/dev/null || true
    sleep 2
    
    # 如果还有 stress-ng 进程，强制杀掉
    local remaining_pids=$(pgrep -f "stress-ng" 2>/dev/null)
    if [ -n "$remaining_pids" ]; then
        log "发现残留的 stress-ng 进程: $remaining_pids"
        echo "$remaining_pids" | xargs -r kill -KILL 2>/dev/null || true
        sleep 1
    fi
    
    # 清理所有子进程
    pkill -P $$ 2>/dev/null || true
    
    # 最终检查
    local final_check=$(pgrep -f "stress-ng" 2>/dev/null)
    if [ -n "$final_check" ]; then
        warn "警告: 仍有 stress-ng 进程运行 (PID: $final_check)"
        warn "请手动执行: sudo pkill -f stress-ng"
    else
        log "所有 stress-ng 进程已清理完成"
    fi
    
    log "清理完成"
    exit 0
}

# 主函数
# 参数解析、依赖检查、准备、启动与收尾的主流程
main() {
    local runtime=$DEFAULT_RUNTIME
    local cpu_target=$DEFAULT_CPU_TARGET
    local mem_target=$DEFAULT_MEM_TARGET
    local interval=$ADJUSTMENT_INTERVAL
    local steps=$RAMP_UP_STEPS
    local test_mode=false
    
    # 解析命令行参数
    while getopts "t:c:m:i:s:l:Th" opt; do
        case $opt in
            t) runtime=$OPTARG ;;
            c) cpu_target=$OPTARG ;;
            m) mem_target=$OPTARG ;;
            i) interval=$OPTARG ;;
            s) steps=$OPTARG ;;
            l) LOG_FILE=$OPTARG ;;
            T) test_mode=true ;;
            h) show_help ;;
            \?)
                echo "无效选项: -$OPTARG" >&2
                echo "使用 -h 查看帮助信息"
                exit 1
                ;;
        esac
    done
    
    # 验证参数
    if [ $cpu_target -lt $MIN_USAGE ] || [ $cpu_target -gt $MAX_USAGE ]; then
        log "错误: CPU目标使用率必须在 $MIN_USAGE-$MAX_USAGE% 之间"
        exit 1
    fi
    
    if [ $mem_target -lt $MIN_USAGE ] || [ $mem_target -gt $MAX_USAGE ]; then
        log "错误: 内存目标使用率必须在 $MIN_USAGE-$MAX_USAGE% 之间"
        exit 1
    fi
    
    # 设置信号处理
    trap cleanup SIGINT SIGTERM EXIT
    
    log "智能资源控制脚本启动"
    log "配置: 运行时间=${runtime}s, CPU目标=${cpu_target}%, 内存目标=${mem_target}%"
    log "调整间隔=${interval}s, 渐进步骤=${steps}"
    
    # 检查依赖和系统状态
    check_dependencies
    get_system_info
    
    if ! check_system_readiness; then
        exit 1
    fi
    
    if [ "$test_mode" = true ]; then
        log "测试模式完成，参数检查通过"
        exit 0
    fi
    
    # 开始压力测试
    log "开始智能资源控制..."
    
    # 获取基线内存使用率（在启动任何stress-ng之前）
    local baseline_usage=($(get_current_usage))
    local baseline_mem=${baseline_usage[1]}
    
    # 渐进式启动
    start_stress_gradually $cpu_target $mem_target $steps $baseline_mem
    
    # 启动监控和调节进程
    {
        intelligent_adjustment $cpu_target $mem_target $baseline_mem
    } &
    MONITOR_PID=$!
    
    log "监控进程启动: PID $MONITOR_PID"
    log "将运行 ${runtime} 秒，按 Ctrl+C 可随时停止"
    
    # 等待指定时间
    sleep $runtime
    
    log "达到预设运行时间，停止测试"
    cleanup
}

# 运行主函数
main "$@"