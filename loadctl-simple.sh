#!/bin/bash
# 纯 shell 版本，使用 /dev/shm 进行大内存分配，支持动态系统资源监控和调整

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
DEFAULT_MIN_RUNTIME=600
DEFAULT_MAX_RUNTIME=900
DEFAULT_TARGET_MEMORY_PERCENT=30  # 目标系统总内存占用百分比
DEFAULT_TARGET_CPU_PERCENT=35     # 目标系统总CPU占用百分比
CPU_CYCLE_SECONDS=1

# 内存分配相关变量
MEMORY_FILES=()  # 存储内存文件路径的数组
MEMORY_DIR="/dev/shm/loadctl_$$"  # 使用进程ID确保唯一性
ALLOCATION_BATCH_SIZE=256  # 每批分配大小(MB)
MONITOR_INTERVAL=5  # 系统监控间隔(秒)
ADJUSTMENT_INTERVAL=10  # 资源调整间隔(秒)

# 动态调整相关变量
CURRENT_MEMORY_MB=0      # 当前分配的内存(MB)
CURRENT_CPU_WORKERS=0    # 当前CPU工作进程数
TARGET_MEMORY_PERCENT=30 # 目标内存占用百分比
TARGET_CPU_PERCENT=35    # 目标CPU占用百分比
ADJUSTMENT_STEP_MEMORY=128  # 内存调整步长(MB)
ADJUSTMENT_STEP_CPU=1       # CPU工作进程调整步长
CPU_PIDS=()              # CPU工作进程PID数组
MEMORY_TEST_ENABLED=false   # 内存测试是否启用标志

# 获取当前系统内存使用情况
get_current_memory_usage() {
    case "$(uname)" in
        Darwin)
            # macOS 系统
            local total_bytes=$(sysctl -n hw.memsize)
            local total_mb=$((total_bytes / 1024 / 1024))
            
            local used_mb=$(vm_stat | awk '
                /Pages active/ { active = $3 }
                /Pages inactive/ { inactive = $4 }
                /Pages speculative/ { spec = $4 }
                /Pages wired/ { wired = $4 }
                END { 
                    gsub(/[^0-9]/, "", active)
                    gsub(/[^0-9]/, "", inactive) 
                    gsub(/[^0-9]/, "", spec)
                    gsub(/[^0-9]/, "", wired)
                    print int((active + inactive + spec + wired) * 4096 / 1024 / 1024)
                }'
            )
            ;;
        Linux)
            # Linux 系统
            local mem_info=$(cat /proc/meminfo)
            local total_mb=$(echo "$mem_info" | awk '/MemTotal/ {print int($2/1024)}')
            local available_mb=$(echo "$mem_info" | awk '/MemAvailable/ {print int($2/1024)}')
            
            # 如果没有 MemAvailable，使用 MemFree + Buffers + Cached
            if [ -z "$available_mb" ] || [ "$available_mb" -eq 0 ]; then
                available_mb=$(echo "$mem_info" | awk '
                    /MemFree/ { free = $2 }
                    /Buffers/ { buffers = $2 }
                    /Cached/ { cached = $2 }
                    END { print int((free + buffers + cached) / 1024) }'
                )
            fi
            
            local used_mb=$((total_mb - available_mb))
            ;;
        *)
            printf "错误: 不支持的操作系统\n" >&2
            return 1
            ;;
    esac
    
    local usage_percent=$((used_mb * 100 / total_mb))
    printf "%d %d %d\n" "$total_mb" "$used_mb" "$usage_percent"
}

# 获取当前系统CPU使用情况
get_current_cpu_usage() {
    case "$(uname)" in
        Darwin)
            # macOS 系统 - 使用 top 命令获取CPU使用率
            local cpu_usage=$(top -l 1 -n 0 | awk '/CPU usage/ {
                gsub(/%/, "", $3)
                gsub(/%/, "", $5)
                print int($3 + $5)
            }')
            ;;
        Linux)
            # Linux 系统 - 使用 /proc/stat 计算CPU使用率
            local cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else print (u-u1) * 100 / (t-t1); }' \
                <(grep 'cpu ' /proc/stat; sleep 1; grep 'cpu ' /proc/stat) 2>/dev/null || echo "0")
            
            # 确保返回整数值
            cpu_usage=${cpu_usage%.*}
            ;;
        *)
            printf "错误: 不支持的操作系统\n" >&2
            return 1
            ;;
    esac
    
    # 确保返回值是有效的数字
    if [ -z "$cpu_usage" ] || ! [[ "$cpu_usage" =~ ^[0-9]+$ ]]; then
        cpu_usage=0
    fi
    
    printf "%d\n" "$cpu_usage"
}

# 动态内存调整函数
adjust_memory_allocation() {
    local memory_info=($(get_current_memory_usage))
    local total_mb=${memory_info[0]}
    local current_used_mb=${memory_info[1]}
    local current_usage_percent=${memory_info[2]}
    
    local target_used_mb=$((total_mb * TARGET_MEMORY_PERCENT / 100))
    local needed_adjustment_mb=$((target_used_mb - current_used_mb))
    
    printf "内存状态: 总计=%dMB, 已用=%dMB (%d%%), 目标=%d%%\n" \
        "$total_mb" "$current_used_mb" "$current_usage_percent" "$TARGET_MEMORY_PERCENT"
    
    if [ "$needed_adjustment_mb" -gt "$ADJUSTMENT_STEP_MEMORY" ]; then
        # 需要增加内存分配
        local add_mb=$ADJUSTMENT_STEP_MEMORY
        if [ "$needed_adjustment_mb" -lt "$add_mb" ]; then
            add_mb=$needed_adjustment_mb
        fi
        
        printf "增加内存分配: %dMB\n" "$add_mb"
        allocate_memory_batch "$add_mb"
        CURRENT_MEMORY_MB=$((CURRENT_MEMORY_MB + add_mb))
        
    elif [ "$needed_adjustment_mb" -lt "-$ADJUSTMENT_STEP_MEMORY" ]; then
        # 需要减少内存分配
        local reduce_mb=$((0 - needed_adjustment_mb))
        if [ "$reduce_mb" -gt "$ADJUSTMENT_STEP_MEMORY" ]; then
            reduce_mb=$ADJUSTMENT_STEP_MEMORY
        fi
        
        printf "减少内存分配: %dMB\n" "$reduce_mb"
        deallocate_memory_batch "$reduce_mb"
        CURRENT_MEMORY_MB=$((CURRENT_MEMORY_MB - reduce_mb))
        
    else
        printf "内存使用量接近目标，无需调整\n"
    fi
}

# 动态CPU调整函数
adjust_cpu_allocation() {
    local current_cpu_usage=$(get_current_cpu_usage)
    
    printf "CPU状态: 当前使用=%d%%, 目标=%d%%, 工作进程=%d\n" \
        "$current_cpu_usage" "$TARGET_CPU_PERCENT" "$CURRENT_CPU_WORKERS"
    
    if [ "$current_cpu_usage" -lt "$((TARGET_CPU_PERCENT - 5))" ] && [ "$CURRENT_CPU_WORKERS" -lt "$CPU_CORES" ]; then
        # CPU使用率低于目标，增加工作进程
        local new_workers=$((CURRENT_CPU_WORKERS + ADJUSTMENT_STEP_CPU))
        if [ "$new_workers" -gt "$CPU_CORES" ]; then
            new_workers=$CPU_CORES
        fi
        
        printf "增加CPU工作进程: %d -> %d\n" "$CURRENT_CPU_WORKERS" "$new_workers"
        start_additional_cpu_workers $((new_workers - CURRENT_CPU_WORKERS))
        CURRENT_CPU_WORKERS=$new_workers
        
    elif [ "$current_cpu_usage" -gt "$((TARGET_CPU_PERCENT + 5))" ] && [ "$CURRENT_CPU_WORKERS" -gt 1 ]; then
        # CPU使用率高于目标，减少工作进程
        local new_workers=$((CURRENT_CPU_WORKERS - ADJUSTMENT_STEP_CPU))
        if [ "$new_workers" -lt 1 ]; then
            new_workers=1
        fi
        
        printf "减少CPU工作进程: %d -> %d\n" "$CURRENT_CPU_WORKERS" "$new_workers"
        stop_cpu_workers $((CURRENT_CPU_WORKERS - new_workers))
        CURRENT_CPU_WORKERS=$new_workers
        
    else
        printf "CPU使用量接近目标，无需调整\n"
    fi
}

# 分批分配内存
allocate_memory_batch() {
    local target_mb=$1
    local allocated=0
    
    # 检查 /dev/shm 可用性和空间
    local available_mb=$(check_dev_shm)
    if [ "$target_mb" -gt "$available_mb" ]; then
        printf "警告: 目标分配 %dMB 超过 /dev/shm 可用空间 %dMB\n" "$target_mb" "$available_mb"
        target_mb=$available_mb
    fi
    
    while [ "$allocated" -lt "$target_mb" ]; do
        local batch_size=$ALLOCATION_BATCH_SIZE
        local remaining=$((target_mb - allocated))
        
        if [ "$remaining" -lt "$batch_size" ]; then
            batch_size=$remaining
        fi
        
        # 确保内存目录存在
        if [ ! -d "$MEMORY_DIR" ]; then
            if ! mkdir -p "$MEMORY_DIR" 2>/dev/null; then
                printf "错误: 无法创建内存目录 %s\n" "$MEMORY_DIR" >&2
                break
            fi
        fi
        
        local file_path="${MEMORY_DIR}/mem_${#MEMORY_FILES[@]}.dat"
        
        # 检查磁盘空间
        local available_space_mb=$(df "$MEMORY_DIR" | awk 'NR==2 {print int($4/1024)}')
        if [ "$batch_size" -gt "$available_space_mb" ]; then
            printf "警告: 批次大小 %dMB 超过可用空间 %dMB，调整为 %dMB\n" \
                "$batch_size" "$available_space_mb" "$available_space_mb"
            batch_size=$available_space_mb
            if [ "$batch_size" -le 0 ]; then
                printf "错误: /dev/shm 空间不足，无法继续分配内存\n" >&2
                break
            fi
        fi
        
        if dd if=/dev/zero of="$file_path" bs=1M count="$batch_size" 2>/dev/null; then
            MEMORY_FILES+=("$file_path")
            allocated=$((allocated + batch_size))
            printf "已分配: %dMB / %dMB\n" "$allocated" "$target_mb"
        else
            printf "警告: 无法分配更多内存，已分配 %dMB\n" "$allocated"
            break
        fi
        
        # 检查系统负载
        if monitor_system_load; then
            printf "系统负载过高，暂停分配...\n"
            sleep "$MONITOR_INTERVAL"
        fi
    done
}

# 分批释放内存
deallocate_memory_batch() {
    local target_mb=$1
    local deallocated=0
    local files_to_remove=()
    
    # 计算需要移除的文件
    for ((i=${#MEMORY_FILES[@]}-1; i>=0 && deallocated<target_mb; i--)); do
        local file_path="${MEMORY_FILES[i]}"
        if [ -f "$file_path" ]; then
            local file_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null || echo 0)
            local file_mb=$((file_size / 1024 / 1024))
            
            files_to_remove+=("$i")
            deallocated=$((deallocated + file_mb))
        fi
    done
    
    # 移除文件
    for index in "${files_to_remove[@]}"; do
        local file_path="${MEMORY_FILES[index]}"
        if [ -f "$file_path" ]; then
            rm -f "$file_path"
            printf "释放内存文件: %s\n" "$(basename "$file_path")"
        fi
        unset MEMORY_FILES[index]
    done
    
    # 重新整理数组
    local new_files=()
    for file in "${MEMORY_FILES[@]}"; do
        if [ -n "$file" ]; then
            new_files+=("$file")
        fi
    done
    MEMORY_FILES=("${new_files[@]}")
    
    printf "已释放内存: %dMB\n" "$deallocated"
}

# 启动额外的CPU工作进程
start_additional_cpu_workers() {
    local count=$1
    for ((i=0; i<count; i++)); do
        # 创建可被信号终止的CPU工作进程
        (
            # 设置信号处理，确保能被父进程终止
            trap 'exit 0' TERM INT
            
            while true; do
                for ((j=0; j<1000000; j++)); do
                    : # 空操作，消耗CPU
                done
                # 添加短暂休眠，让信号处理有机会执行
                sleep 0.001 2>/dev/null || true
            done
        ) &
        CPU_PIDS+=($!)
        printf "启动CPU工作进程: PID %d\n" $!
    done
}

# 停止CPU工作进程
stop_cpu_workers() {
    local count=$1
    for ((i=0; i<count && i<${#CPU_PIDS[@]}; i++)); do
        if [ ${#CPU_PIDS[@]} -gt 0 ]; then
            local last_index=$((${#CPU_PIDS[@]} - 1))
            local pid=${CPU_PIDS[$last_index]}
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
            fi
            unset CPU_PIDS[$last_index]
        fi
    done
}

# 系统资源监控和动态调整主循环
dynamic_resource_monitor() {
    printf "启动动态资源监控...\n"
    
    # 设置监控进程的信号处理
    trap 'printf "\n监控进程收到终止信号，正在退出...\n"; exit 0' TERM INT QUIT HUP
    
    while true; do
        printf "\n=== 资源监控周期 $(date '+%H:%M:%S') ===\n"
        
        # 调整内存分配（仅在启用内存测试时）
        if [ "$MEMORY_TEST_ENABLED" = "true" ]; then
            adjust_memory_allocation
        fi
        
        # 调整CPU分配
        adjust_cpu_allocation
        
        printf "等待 %d 秒后进行下次调整...\n" "$ADJUSTMENT_INTERVAL"
        
        # 使用可中断的睡眠
        local count=0
        while [ $count -lt "$ADJUSTMENT_INTERVAL" ]; do
            sleep 1
            count=$((count + 1))
        done
    done
}

# 检查是否应该暂停分配（基于系统负载）
should_pause_allocation() {
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    # 使用整数运算：CPU_CORES * 8 / 10 等价于 CPU_CORES * 0.8
    local load_threshold=$((CPU_CORES * 8 / 10))
    
    # 将浮点数转换为整数进行比较（乘以10）
    local load_avg_int=$(echo "$load_avg" | awk '{printf "%.0f", $1 * 10}')
    local threshold_int=$((load_threshold * 10))
    
    if [ "$load_avg_int" -gt "$threshold_int" ]; then
        return 0  # 需要暂停
    else
        return 1  # 不需要暂停
    fi
}

# 检查 /dev/shm 可用性和空间
check_dev_shm() {
    if [ ! -d "/dev/shm" ]; then
        echo "错误: /dev/shm 不存在，无法使用共享内存" >&2
        exit 1
    fi
    
    if [ ! -w "/dev/shm" ]; then
        echo "错误: /dev/shm 不可写，权限不足" >&2
        exit 1
    fi
    
    # 检查 /dev/shm 可用空间
    local available_space_kb=$(df /dev/shm | awk 'NR==2 {print $4}')
    local available_space_mb=$((available_space_kb / 1024))
    
    # 将信息输出到stderr，避免影响函数返回值
    printf "/dev/shm 可用空间: %sMB\n" "${available_space_mb}" >&2
    echo "$available_space_mb"
}
is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# 产生[min, max]之间的随机整数，优先使用内置$RANDOM，回退到awk
random_between() {
  local min=$1 max=$2
  if [[ -n "${RANDOM:-}" ]]; then
    echo $(( RANDOM % (max - min + 1) + min ))
  else
    awk -v min="${min}" -v max="${max}" 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'
  fi
}

# 参数校验：运行时长必须为正整数
validate_runtime() {
  if ! is_integer "${RUNTIME}" || (( RUNTIME < 1 )); then
    echo "运行时长参数错误: ${RUNTIME}，必须为正整数秒" >&2
    exit 1
  fi
}

# 校验CPU百分比参数
validate_cpu_percent() {
  local percent="$1"
  if ! [[ "${percent}" =~ ^[0-9]+$ ]] || [[ "${percent}" -lt 1 ]] || [[ "${percent}" -gt 100 ]]; then
    echo "错误: CPU百分比必须是1-100之间的整数" >&2
    return 1
  fi
  return 0
}

print_usage() {
  cat << 'EOF'
用法: loadctl-simple.sh [选项]

选项:
  -t, --time SECONDS      运行时长（秒），默认: 600-900随机
  -c, --cpu PERCENT       系统总CPU占用目标百分比（1-100），默认: 35
  -m, --memory PERCENT    系统总内存占用目标百分比（1-95），可选，默认不启用
  -T, --test              测试模式，仅显示配置不执行压力测试
  -h, --help              显示此帮助信息

动态资源管理特性:
  • 智能监控：实时监控系统CPU和内存使用情况
  • 动态调整：根据其他程序的资源使用情况自动调整本程序消耗
  • 渐进式调整：平滑增加或减少资源使用，避免系统冲击
  • 负载感知：监控系统负载，高负载时暂停资源分配
  • 目标导向：维持系统总资源使用量接近目标百分比
  • 自动回收：程序退出时自动清理所有分配的资源

工作原理:
  • CPU管理：动态调整工作进程数量，配合其他程序达到目标CPU使用率
  • 内存管理：使用/dev/shm动态分配/释放内存，配合系统内存使用达到目标
  • 监控周期：每10秒检查一次系统状态并进行必要调整
  • 调整策略：采用渐进式调整，避免资源使用量剧烈波动

系统要求:
  • 支持 /dev/shm 的 Linux 系统
  • 无需 sudo 权限
  • 适合生产环境长期运行

示例:
  loadctl-simple.sh -t 3600 -c 85 -m 75    # 运行1小时，目标85%CPU，75%内存
  loadctl-simple.sh -c 60 -m 50            # 目标60%CPU，50%内存，随机运行时长
  loadctl-simple.sh -c 80                  # 仅CPU测试，目标80%CPU，不进行内存测试
  loadctl-simple.sh -T -c 90 -m 80         # 测试模式，检查90%CPU，80%内存配置
  loadctl-simple.sh --help                 # 显示帮助信息

注意事项:
  • 参数指的是系统总资源占用百分比，包括本程序和其他程序
  • 程序会根据其他程序的资源使用动态调整自身消耗
  • -m 参数是可选的，不指定时仅进行CPU测试，不进行内存测试
  • 建议在生产环境中设置合理的目标值，避免系统过载
  • 使用 Ctrl+C 可安全中断并自动清理所有资源
EOF
}

random_runtime() {
  random_between "${DEFAULT_MIN_RUNTIME}" "${DEFAULT_MAX_RUNTIME}"
}

declare_runtime() {
  if [[ -z "${USER_RUNTIME:-}" ]]; then
    RUNTIME=$(random_runtime)
  else
    RUNTIME=${USER_RUNTIME}
  fi
}

# 监控系统负载
monitor_system_load() {
    case "$(uname)" in
        Darwin)
            # macOS: 获取 1 分钟负载平均值
            local load_avg=$(uptime | awk -F'load averages: ' '{print $2}' | awk '{print $1}')
            ;;
        Linux)
            # Linux: 从 /proc/loadavg 获取 1 分钟负载平均值
            local load_avg=$(awk '{print $1}' /proc/loadavg)
            ;;
        *)
            echo "1.0"  # 默认值
            return
            ;;
    esac
    
    echo "$load_avg"
}

# 渐进式内存分配函数
# 使用 /dev/shm 进行大内存分配，支持系统监控和优雅降级
allocate_memory() {
    local memory_number memory_unit memory_in_mb allocation
    
    # 验证并解析内存参数
    if [[ ! "${MEMORY_TARGET}" =~ ^[0-9]+[GgMmKk]$ ]]; then
        echo "内存参数格式错误: ${MEMORY_TARGET}，必须为整数+单位（G/M/K）" >&2
        exit 1
    fi

    memory_unit=${MEMORY_TARGET: -1}
    memory_number=${MEMORY_TARGET%[GgMmKk]}

    case "${memory_unit}" in
        G|g) memory_in_mb=$((memory_number * 1024)) ;;
        M|m) memory_in_mb=${memory_number} ;;
        K|k) memory_in_mb=$((memory_number / 1024)) ;;
        *)
            echo "不支持的内存单位: ${MEMORY_TARGET}" >&2
            exit 1
            ;;
    esac

    if (( memory_in_mb < 1 )); then
        echo "内存容量过小，无法分配: ${MEMORY_TARGET}" >&2
        exit 1
    fi

    # 检查 /dev/shm 可用性
    local shm_available=$(check_dev_shm)
    
    # 检查内存使用限制并自动调整
    allocation=$(check_memory_limits "$memory_in_mb")
    
    # 确保不超过 /dev/shm 可用空间的 90%
    local max_shm_usage=$((shm_available * 90 / 100))
    if [ "$allocation" -gt "$max_shm_usage" ]; then
        printf "警告: 分配量 (%sMB) 超过 /dev/shm 安全限制 (%sMB)\n" "$allocation" "$max_shm_usage"
        allocation=$max_shm_usage
        printf "自动调整为: %sMB\n" "$allocation"
    fi
    
    # 创建内存分配目录
    mkdir -p "$MEMORY_DIR"
    
    printf "开始渐进式内存分配: %sMB\n" "$allocation"
    printf "分配策略: 每批 %sMB，监控间隔 %s 秒\n" "$ALLOCATION_BATCH_SIZE" "$MONITOR_INTERVAL"
    
    local allocated=0
    local batch_count=0
    
    while [ "$allocated" -lt "$allocation" ]; do
        # 检查是否需要暂停
        if monitor_system_load; then
            printf "等待系统负载降低...\n"
            sleep "$MONITOR_INTERVAL"
            continue
        fi
        
        # 计算本批次分配大小
        local remaining=$((allocation - allocated))
        local batch_size=$ALLOCATION_BATCH_SIZE
        if [ "$remaining" -lt "$batch_size" ]; then
            batch_size=$remaining
        fi
        
        # 创建内存文件
        batch_count=$((batch_count + 1))
        local file_path="${MEMORY_DIR}/block_${batch_count}"
        
        printf "分配批次 %s: %sMB (%s/%sMB)\n" "$batch_count" "$batch_size" "$((allocated + batch_size))" "$allocation"
        
        # 使用 dd 创建内存文件
        if dd if=/dev/zero of="$file_path" bs=1M count="$batch_size" 2>/dev/null; then
            MEMORY_FILES+=("$file_path")
            allocated=$((allocated + batch_size))
            
            # 显示进度
            local progress=$((allocated * 100 / allocation))
            printf "进度: %s%% (%s/%sMB)\n" "$progress" "$allocated" "$allocation"
        else
            printf "错误: 无法分配内存文件 %s\n" "$file_path" >&2
            break
        fi
        
        # 短暂暂停，避免系统压力过大
        sleep 0.1
    done
    
    printf "内存分配完成: %sMB (共 %s 个文件)\n" "$allocated" "${#MEMORY_FILES[@]}"
}

# 清理内存分配
cleanup_memory() {
    if [ ${#MEMORY_FILES[@]} -gt 0 ]; then
        printf "清理内存分配...\n"
        
        local cleaned=0
        for file_path in "${MEMORY_FILES[@]}"; do
            if [ -f "$file_path" ]; then
                rm -f "$file_path" 2>/dev/null && cleaned=$((cleaned + 1))
            fi
        done
        
        # 清理内存目录
        if [ -d "$MEMORY_DIR" ]; then
            rmdir "$MEMORY_DIR" 2>/dev/null || true
        fi
        
        MEMORY_FILES=()
        printf "内存清理完成: 清理了 %s 个文件\n" "$cleaned"
    fi
}

# 清理CPU工作进程
cleanup_cpu_workers() {
    if [ ${#CPU_PIDS[@]} -eq 0 ]; then
        printf "没有CPU工作进程需要清理。\n"
        return 0
    fi
    
    printf "清理 %d 个CPU工作进程...\n" "${#CPU_PIDS[@]}"
    
    # 直接使用 kill -9 强制终止所有进程
    for pid in "${CPU_PIDS[@]}"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            printf "强制终止进程 %d\n" "$pid"
            kill -9 "$pid" 2>/dev/null
        fi
    done
    
    # 清空PID数组
    CPU_PIDS=()
    
    printf "CPU工作进程清理完成。\n"
}

# 紧急清理函数（用于信号处理）
emergency_cleanup() {
    printf "\n检测到中断信号，执行紧急清理...\n"
    
    # 清理CPU工作进程
    cleanup_cpu_workers
    
    # 清理内存文件
    cleanup_memory
    
    # 强制终止监控进程
    if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "${MONITOR_PID}" 2>/dev/null; then
        printf "强制终止监控进程 %s\n" "${MONITOR_PID}"
        kill -9 "${MONITOR_PID}" 2>/dev/null || true
    fi
    
    # 终止所有子进程（分阶段清理）
    printf "清理所有子进程...\n"
    local child_pids=$(pgrep -P $$ 2>/dev/null || true)
    if [ -n "$child_pids" ]; then
        printf "发现子进程: %s\n" "$child_pids"
        echo "$child_pids" | xargs -r kill -9 2>/dev/null || true
    fi
    
    # 清理同名进程（防止多实例运行导致的问题）
    cleanup_script_instances
    
    printf "紧急清理完成\n"
    exit 130
}

cleanup() {
  printf "\n正在清理资源...\n"
  
  # 清理CPU工作进程
  cleanup_cpu_workers
  
  # 清理内存分配
  cleanup_memory
  
  # 强制终止监控进程
  if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "${MONITOR_PID}" 2>/dev/null; then
    printf "强制终止监控进程 %s\n" "${MONITOR_PID}"
    kill -9 "${MONITOR_PID}" 2>/dev/null
  fi
  
  # 终止所有子进程（强制清理）
  printf "清理所有子进程...\n"
  local child_pids=$(pgrep -P $$ 2>/dev/null || true)
  if [ -n "$child_pids" ]; then
      printf "发现子进程: %s\n" "$child_pids"
      echo "$child_pids" | xargs -r kill -9 2>/dev/null || true
  fi
  
  # 清理同名进程（防止多实例运行导致的问题）
  cleanup_script_instances
  
  printf "清理完成\n"
}

# 清理同名脚本实例（防止多实例运行导致的问题）
cleanup_script_instances() {
    local script_name=$(basename "$0")
    local current_pid=$$
    
    # 查找其他同名脚本进程（排除当前进程）
    local other_pids=$(pgrep -f "$script_name" | grep -v "^${current_pid}$" || true)
    
    if [ -n "$other_pids" ]; then
        printf "发现其他 %s 进程: %s\n" "$script_name" "$other_pids"
        printf "清理其他脚本实例...\n"
        
        # 优雅终止
        echo "$other_pids" | xargs -r kill -TERM 2>/dev/null || true
        sleep 2
        
        # 检查并强制终止残留进程
        local remaining_others=$(pgrep -f "$script_name" | grep -v "^${current_pid}$" || true)
        if [ -n "$remaining_others" ]; then
            printf "强制终止残留的 %s 进程: %s\n" "$script_name" "$remaining_others"
            echo "$remaining_others" | xargs -r kill -KILL 2>/dev/null || true
        fi
    fi
}

# 进程清理验证函数
verify_cleanup() {
    printf "\n=== 清理验证 ===\n"
    
    local issues=0
    
    # 检查CPU工作进程
    if [ ${#CPU_PIDS[@]} -gt 0 ]; then
        local remaining_cpu=0
        for pid in "${CPU_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                printf "警告: CPU工作进程 %s 仍在运行\n" "$pid"
                remaining_cpu=$((remaining_cpu + 1))
                issues=$((issues + 1))
            fi
        done
        if [ $remaining_cpu -eq 0 ]; then
            printf "✓ CPU工作进程已全部清理\n"
        fi
    else
        printf "✓ 无CPU工作进程需要清理\n"
    fi
    
    # 检查监控进程
    if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "${MONITOR_PID}" 2>/dev/null; then
        printf "警告: 监控进程 %s 仍在运行\n" "${MONITOR_PID}"
        issues=$((issues + 1))
    else
        printf "✓ 监控进程已清理\n"
    fi
    
    # 检查子进程
    local child_pids=$(pgrep -P $$ 2>/dev/null || true)
    if [ -n "$child_pids" ]; then
        printf "警告: 发现残留子进程: %s\n" "$child_pids"
        issues=$((issues + 1))
    else
        printf "✓ 所有子进程已清理\n"
    fi
    
    # 检查内存文件
    if [ ${#MEMORY_FILES[@]} -gt 0 ]; then
        local remaining_files=0
        for file_path in "${MEMORY_FILES[@]}"; do
            if [ -f "$file_path" ]; then
                printf "警告: 内存文件 %s 仍存在\n" "$file_path"
                remaining_files=$((remaining_files + 1))
                issues=$((issues + 1))
            fi
        done
        if [ $remaining_files -eq 0 ]; then
            printf "✓ 内存文件已全部清理\n"
        fi
    else
        printf "✓ 无内存文件需要清理\n"
    fi
    
    # 检查内存目录
    if [ -d "$MEMORY_DIR" ]; then
        printf "警告: 内存目录 %s 仍存在\n" "$MEMORY_DIR"
        issues=$((issues + 1))
    else
        printf "✓ 内存目录已清理\n"
    fi
    
    printf "=== 清理验证完成 ===\n"
    if [ $issues -eq 0 ]; then
        printf "✓ 所有资源已成功清理\n"
        return 0
    else
        printf "⚠ 发现 %d 个清理问题\n" "$issues"
        return 1
    fi
}

# 信号处理将在 main() 函数中设置

# CPU工作进程，实现基于百分比的负载控制
cpu_worker() {
  local cpu_percent="$1"
  local work_time=$(( CPU_CYCLE_SECONDS * cpu_percent / 100 ))
  local sleep_time=$(( CPU_CYCLE_SECONDS - work_time ))
  
  # 确保至少有最小工作时间
  if [[ "${work_time}" -eq 0 ]] && [[ "${cpu_percent}" -gt 0 ]]; then
    work_time=1
    sleep_time=$(( CPU_CYCLE_SECONDS - 1 ))
  fi
  
  while true; do
    # 工作阶段：执行计算密集型操作
    if [[ "${work_time}" -gt 0 ]]; then
      local end_time=$(($(date +%s) + work_time))
      while [[ $(date +%s) -lt "${end_time}" ]]; do
        : $((1 + 1))  # 简单的算术运算
      done
    fi
    
    # 休息阶段
    if [[ "${sleep_time}" -gt 0 ]]; then
      sleep "${sleep_time}"
    fi
  done
}

start_compute_workers() {
    for (( i=1; i<=WORKER_COUNT; i++ )); do
      cpu_worker "${CPU_PERCENT}" &
    done
  }

# 获取CPU核心数，直接使用/proc/cpuinfo方法
get_cpu_cores() {
  if [[ -r /proc/cpuinfo ]]; then
    grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1"
  else
    echo "1"
  fi
}

choose_worker_count() {
  case "$(uname)" in
    Darwin) CPU_CORES=$(sysctl -n hw.ncpu) ;;
    Linux) CPU_CORES=$(get_cpu_cores) ;;
    *)
      echo "无法识别的系统平台: $(uname)" >&2
      exit 1
      ;;
  esac

  WORKER_COUNT=$((CPU_CORES / 2))
  if (( WORKER_COUNT < 1 )); then
    WORKER_COUNT=1
  fi
}

monitor_loop() {
  local start_ts elapsed
  start_ts=$(date +%s)
  while true; do
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= RUNTIME )); then
      printf "达到运行时长 %s 秒，准备停止...\n" "${RUNTIME}"
      return
    fi
    printf "已运行 %s/%s 秒\n" "${elapsed}" "${RUNTIME}"
    sleep 5
  done
}

# 参数解析函数
parse_arguments() {
    local opt
    while getopts "t:c:m:Th" opt; do
        case "${opt}" in
            t) 
                DURATION=${OPTARG}
                if ! is_integer "$DURATION" || [ "$DURATION" -lt 1 ]; then
                    printf "错误: 运行时长必须是正整数\n" >&2
                    exit 1
                fi
                ;;
            c) 
                TARGET_CPU_PERCENT=${OPTARG}
                if ! is_integer "$TARGET_CPU_PERCENT" || [ "$TARGET_CPU_PERCENT" -lt 1 ] || [ "$TARGET_CPU_PERCENT" -gt 100 ]; then
                    printf "错误: CPU目标百分比必须是1-100之间的整数\n" >&2
                    exit 1
                fi
                ;;
            m) 
                TARGET_MEMORY_PERCENT=${OPTARG}
                if ! is_integer "$TARGET_MEMORY_PERCENT" || [ "$TARGET_MEMORY_PERCENT" -lt 1 ] || [ "$TARGET_MEMORY_PERCENT" -gt 95 ]; then
                    printf "错误: 内存目标百分比必须是1-95之间的整数\n" >&2
                    exit 1
                fi
                MEMORY_TEST_ENABLED=true
                ;;
            T) 
                MODE="test"
                ;;
            h)
                print_usage
                exit 0
                ;;
            *)
                print_usage
                exit 1
                ;;
        esac
    done
    
    # 设置默认值
    DURATION=${DURATION:-$((RANDOM % (DEFAULT_MAX_RUNTIME - DEFAULT_MIN_RUNTIME + 1) + DEFAULT_MIN_RUNTIME))}
    TARGET_CPU_PERCENT=${TARGET_CPU_PERCENT:-$DEFAULT_TARGET_CPU_PERCENT}
    TARGET_MEMORY_PERCENT=${TARGET_MEMORY_PERCENT:-$DEFAULT_TARGET_MEMORY_PERCENT}
    MODE=${MODE:-"normal"}
}

main() {
  # 设置信号处理 - 直接退出，让EXIT trap处理清理
  trap 'exit 130' INT TERM QUIT HUP
  trap 'cleanup' EXIT
  
  parse_arguments "$@"
  
  # 初始化CPU核心数
  choose_worker_count
  
  printf "配置信息:\n"
  printf -- "- 运行时长: %s 秒\n" "${DURATION}"
  printf -- "- 系统总CPU目标: %s%%\n" "${TARGET_CPU_PERCENT}"
  if [ "$MEMORY_TEST_ENABLED" = "true" ]; then
    printf -- "- 系统总内存目标: %s%%\n" "${TARGET_MEMORY_PERCENT}"
  else
    printf -- "- 内存测试: 已禁用\n"
  fi
  printf -- "- CPU 核数: %s\n" "${CPU_CORES}"
  printf -- "- 监控间隔: %s 秒\n" "${ADJUSTMENT_INTERVAL}"
  if [[ "${MODE}" == "test" ]]; then
    printf -- "- 运行模式: 测试模式\n"
  else
    printf -- "- 运行模式: 动态调整模式\n"
  fi

  if [[ "${MODE}" == "test" ]]; then
    printf "测试模式结束，未执行压力测试。\n"
    exit 0
  fi

  # 初始化资源监控
  printf "启动动态资源监控...\n"
  
  # 获取当前系统状态
  local memory_info=($(get_current_memory_usage))
  CURRENT_MEMORY_TOTAL_MB=${memory_info[0]}
  CURRENT_MEMORY_USED_MB=${memory_info[1]}
  CURRENT_MEMORY_PERCENT=${memory_info[2]}
  
  CURRENT_CPU_PERCENT=$(get_current_cpu_usage)
  
  printf "当前系统状态:\n"
  printf -- "- 内存使用: %s%% (%s MB / %s MB)\n" "${CURRENT_MEMORY_PERCENT}" "${CURRENT_MEMORY_USED_MB}" "${CURRENT_MEMORY_TOTAL_MB}"
  printf -- "- CPU使用: %s%%\n" "${CURRENT_CPU_PERCENT}"
  
  # 启动动态监控循环
  dynamic_resource_monitor &
  MONITOR_PID=$!
  
  # 等待指定时间（使用可中断的睡眠）
  local elapsed=0
  while [ $elapsed -lt "${DURATION}" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  
  # 停止监控
  if kill -0 "${MONITOR_PID}" 2>/dev/null; then
    kill "${MONITOR_PID}" 2>/dev/null
    wait "${MONITOR_PID}" 2>/dev/null
  fi
  
  printf "运行完成。\n"
  
  # 正常退出时清理资源
  cleanup
  
  # 验证清理结果
  verify_cleanup
}

main "$@"

