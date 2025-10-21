#!/bin/bash

# 设置脚本运行时间（随机10-15分钟）
RUNTIME=$((RANDOM % 301 + 600))  # 600-900秒（10-15分钟）
echo "脚本将运行 $((RUNTIME / 60)) 分 $((RUNTIME % 60)) 秒"

# 设置初始计算强度
COMPUTE_INTENSITY=8000

# 获取系统总内存（以KB为单位）
if [ "$(uname)" == "Darwin" ]; then
  # macOS
  TOTAL_MEM_KB=$(sysctl hw.memsize | awk '{print $2/1024}')
  # 获取当前内存使用情况
  CURRENT_MEM_USED_KB=$(top -l 1 | grep PhysMem | awk '{print $2}' | tr -d 'M' | awk '{print $1*1024}')
else
  # Linux
  TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  # 获取当前内存使用情况
  CURRENT_MEM_USED_KB=$(free | grep Mem | awk '{print $3}')
fi

# 计算当前内存使用率（使用整数运算）
CURRENT_MEM_PERCENT=$((CURRENT_MEM_USED_KB * 100 / TOTAL_MEM_KB))

# 计算50%的系统内存（以KB为单位）
MAX_MEM_KB=$((TOTAL_MEM_KB / 2))
# 转换为GB（整数运算）
MAX_MEM_GB=$((MAX_MEM_KB / 1024 / 1024))

# 计算可用于分配的内存（50%限制减去当前已使用的内存）
AVAILABLE_MEM_KB=$((MAX_MEM_KB - CURRENT_MEM_USED_KB))
if [ $AVAILABLE_MEM_KB -lt 0 ]; then
  AVAILABLE_MEM_KB=0
fi
AVAILABLE_MEM_GB=$((AVAILABLE_MEM_KB / 1024 / 1024))

# 设置内存占用大小（默认为可用内存的80%，确保不超过限制）
if [ $AVAILABLE_MEM_KB -gt 0 ]; then
  DEFAULT_MEM_KB=$((AVAILABLE_MEM_KB * 80 / 100))
else
  DEFAULT_MEM_KB=0
fi
DEFAULT_MEM_GB=$((DEFAULT_MEM_KB / 1024 / 1024))
MEMORY_SIZE="${DEFAULT_MEM_GB}G"

# 显示帮助信息函数
show_help() {
  cat << EOF
使用方法: $(basename $0) [选项]

描述:
  此脚本用于控制系统CPU和内存资源占用，可用于系统压力测试。
  默认情况下，脚本会在10-15分钟内随机时间自动停止。
  CPU占用会动态调整，确保系统总CPU使用率保持在34%-48%范围内。
  内存占用会考虑当前系统使用情况，确保总使用率不超过系统内存的50%。

选项:
  -t <秒数>    设置脚本运行时间，单位为秒 (默认: 随机600-900秒)
  -c <数值>    设置初始CPU计算强度 (默认: 8000)
  -m <大小>    设置内存占用大小，支持K、M、G单位 (默认: 可用内存的80%)
               例如: 4G, 512M, 1024K
               注意: 会自动检查当前内存使用情况，确保总使用率不超过50%
  -T           测试模式，只检查参数不实际运行
  -h           显示此帮助信息并退出

示例:
  $(basename $0) -t 300 -c 5000 -m 2G    # 运行5分钟，初始计算强度5000，内存占用2GB
  $(basename $0) -m 4G                   # 使用默认运行时间和计算强度，内存占用4GB
  $(basename $0) -T -m 8G                # 测试模式，检查8GB内存占用是否超过系统限制
  $(basename $0) -h                      # 显示帮助信息

注意:
  - 此脚本需要root权限才能分配内存
  - 会检查当前系统资源使用情况，确保总占用不超过限制
  - 内存总使用率不会超过系统内存的50%
  - CPU总使用率会动态调整，保持在34%-48%范围内
  - 如果当前系统资源使用已接近限制，脚本会自动调整分配量
EOF
  exit 0
}

# 测试模式标志
TEST_MODE=false

# 解析命令行参数
while getopts "t:c:m:Th" opt; do
  case $opt in
    t) RUNTIME=$OPTARG ;;      # 运行时间（秒）
    c) COMPUTE_INTENSITY=$OPTARG ;; # 初始计算强度
    m) 
      # 检查用户指定的内存大小是否超过系统内存的50%
      USER_MEM_SIZE=$OPTARG
      # 提取数字部分和单位
      USER_MEM_NUM=$(echo $USER_MEM_SIZE | sed 's/[^0-9.]//g')
      USER_MEM_UNIT=$(echo $USER_MEM_SIZE | sed 's/[0-9.]//g')
      
      # 转换为KB进行比较（使用整数运算）
      case $USER_MEM_UNIT in
        [Gg]) USER_MEM_KB=$((${USER_MEM_NUM%.*} * 1024 * 1024)) ;;
        [Mm]) USER_MEM_KB=$((${USER_MEM_NUM%.*} * 1024)) ;;
        [Kk]) USER_MEM_KB=${USER_MEM_NUM%.*} ;;
        *) USER_MEM_KB=${USER_MEM_NUM%.*} ;; # 默认假设为KB
      esac
      
      # 检查是否超过可用内存限制
      if [ $USER_MEM_KB -gt $AVAILABLE_MEM_KB ]; then
        echo "警告: 请求的内存大小 $USER_MEM_SIZE 超过可用内存 (${AVAILABLE_MEM_GB}G)"
        echo "当前系统内存使用率: ${CURRENT_MEM_PERCENT}%"
        echo "已自动调整为可用内存: ${AVAILABLE_MEM_GB}G"
        MEMORY_SIZE="${AVAILABLE_MEM_GB}G"
      else
        MEMORY_SIZE=$USER_MEM_SIZE
      fi
      ;;
    T) TEST_MODE=true ;; # 测试模式，只检查参数不实际运行
    h) show_help ;; # 显示帮助信息
  esac
done

# 获取CPU核数用于显示配置信息
if [ "$(uname)" == "Darwin" ]; then
  # macOS
  CPU_CORES=$(sysctl -n hw.ncpu)
else
  # Linux
  CPU_CORES=$(nproc)
fi

# 计算CPU计算进程数量（CPU核数/2，最少1个）
CPU_PROCESSES=$((CPU_CORES / 2))
if [ $CPU_PROCESSES -lt 1 ]; then
  CPU_PROCESSES=1
fi

echo "配置信息："
echo "- 运行时间: $RUNTIME 秒"
echo "- 初始计算强度: $COMPUTE_INTENSITY"
echo "- CPU核数: $CPU_CORES，计算进程数: $CPU_PROCESSES"
echo "- 系统总内存: $((TOTAL_MEM_KB / 1024 / 1024))G"
echo "- 当前内存使用率: ${CURRENT_MEM_PERCENT}%"
echo "- 可用于分配的内存: ${AVAILABLE_MEM_GB}G"
echo "- 本次内存占用: $MEMORY_SIZE"
if [ "$TEST_MODE" = true ]; then
  echo "- 运行模式: 测试模式 (仅检查参数，不实际运行)"
else
  echo "- 运行模式: 正常模式"
fi

# 记录开始时间
START_TIME=$(date +%s)

# 创建临时文件存储进程PID
PIDS_FILE=$(mktemp)

# 内存占用函数
allocate_memory() {
  echo "开始分配内存..."
  
  # 创建临时目录
  if [ -d /opt/tmp/memory ]; then
    echo "临时内存目录已存在"
  else
    mkdir -p /opt/tmp/memory
    echo "创建临时内存目录: /opt/tmp/memory"
  fi
  
  # 先卸载已存在的tmpfs（如果有的话）
  if mount | grep -q "/opt/tmp/memory"; then
    echo "卸载已存在的tmpfs..."
    umount /opt/tmp/memory 2>/dev/null
  fi
  
  # 挂载tmpfs并分配内存
  mount -t tmpfs -o size=$MEMORY_SIZE tmpfs /opt/tmp/memory/
  echo "挂载了大小为 $MEMORY_SIZE 的tmpfs到 /opt/tmp/memory/"
  
  # 计算要分配的内存大小（转换为MB）
  MEM_NUM=$(echo $MEMORY_SIZE | sed 's/[^0-9.]//g')
  MEM_UNIT=$(echo $MEMORY_SIZE | sed 's/[0-9.]//g')
  
  case $MEM_UNIT in
    [Gg]) MEM_MB=$((${MEM_NUM%.*} * 1024)) ;;
    [Mm]) MEM_MB=${MEM_NUM%.*} ;;
    [Kk]) MEM_MB=$((${MEM_NUM%.*} / 1024)) ;;
    *) MEM_MB=$((${MEM_NUM%.*} / 1024 / 1024)) ;; # 假设为字节
  esac
  
  # 预留一些空间给文件系统元数据，分配90%的空间
  ACTUAL_MEM_MB=$((MEM_MB * 90 / 100))
  
  # 创建内存占用文件 - 指定确切的大小
  echo "正在分配内存 ${ACTUAL_MEM_MB}MB，这可能需要一些时间..."
  dd if=/dev/zero of=/opt/tmp/memory/block bs=1M count=$ACTUAL_MEM_MB status=progress
  
  if [ $? -eq 0 ]; then
    echo "内存分配完成: ${ACTUAL_MEM_MB}MB"
  else
    echo "内存分配出现问题，但继续运行..."
  fi
}

# 清理标志，防止重复清理
CLEANUP_DONE=false

# 清理函数
cleanup() {
  # 防止重复清理
  if [ "$CLEANUP_DONE" = true ]; then
    return
  fi
  CLEANUP_DONE=true
  
  echo ""
  echo "正在清理资源..."
  
  # 停止所有计算进程
  if [ -f "$ACTIVE_PIDS_FILE" ]; then
    echo "停止所有计算进程..."
    while read pid; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        # 等待进程结束，如果超时则强制杀掉
        for i in {1..3}; do
          if ! kill -0 "$pid" 2>/dev/null; then
            break
          fi
          sleep 1
        done
        # 如果进程仍然存在，强制杀掉
        if kill -0 "$pid" 2>/dev/null; then
          kill -KILL "$pid" 2>/dev/null
        fi
      fi
    done < "$ACTIVE_PIDS_FILE"
    rm "$ACTIVE_PIDS_FILE" 2>/dev/null
  fi
  
  # 清理监控进程
  if [ -f "$PIDS_FILE" ]; then
    while read pid; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
      fi
    done < "$PIDS_FILE"
    rm "$PIDS_FILE" 2>/dev/null
  fi
  
  # 杀掉当前进程组的所有子进程
  echo "清理进程组..."
  pkill -P $$ 2>/dev/null
  
  # 卸载内存
  if mount | grep -q "/opt/tmp/memory"; then
    echo "清理内存文件..."
    rm -f /opt/tmp/memory/block 2>/dev/null
    echo "卸载tmpfs..."
    umount /opt/tmp/memory 2>/dev/null
    if [ $? -eq 0 ]; then
      echo "已成功卸载 /opt/tmp/memory"
    else
      echo "卸载 /opt/tmp/memory 时出现问题，可能需要手动清理"
    fi
  fi
  
  echo "清理完成"
  exit 0
}

# 捕获中断信号
trap cleanup SIGINT SIGTERM

# 存储活跃计算进程PID的数组文件
ACTIVE_PIDS_FILE=$(mktemp)

# 启动单个计算进程的函数
start_compute_process() {
  {
    trap 'exit 0' SIGTERM SIGINT
    while true; do
      n=$(($RANDOM % 10 + 1))  # 1-10秒的随机休眠
      
      # 固定的计算量，不再动态调整
      for ii in $(seq 1 5000); do
        for iii in $(seq 1 5000); do
          j=$((ii+iii))
        done
      done
      
      sleep ${n}
    done
  } &
  
  local pid=$!
  echo $pid >> "$ACTIVE_PIDS_FILE"
  echo "启动计算进程: PID $pid"
  return $pid
}

# 停止一个计算进程的函数
stop_compute_process() {
  if [ -s "$ACTIVE_PIDS_FILE" ]; then
    # 获取最后一个进程PID
    local pid=$(tail -n 1 "$ACTIVE_PIDS_FILE")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      # 等待进程结束
      for i in {1..3}; do
        if ! kill -0 "$pid" 2>/dev/null; then
          break
        fi
        sleep 1
      done
      # 如果进程仍然存在，强制杀掉
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null
      fi
      echo "停止计算进程: PID $pid"
      
      # 从活跃进程列表中移除
      grep -v "^$pid$" "$ACTIVE_PIDS_FILE" > "${ACTIVE_PIDS_FILE}.tmp" 2>/dev/null
      mv "${ACTIVE_PIDS_FILE}.tmp" "$ACTIVE_PIDS_FILE" 2>/dev/null
      return 0
    fi
  fi
  return 1
}

# 获取当前活跃计算进程数量
get_active_process_count() {
  if [ -f "$ACTIVE_PIDS_FILE" ]; then
    # 清理已经不存在的进程
    local temp_file=$(mktemp)
    while read pid; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo $pid >> "$temp_file"
      fi
    done < "$ACTIVE_PIDS_FILE"
    mv "$temp_file" "$ACTIVE_PIDS_FILE"
    
    # 返回活跃进程数量
    wc -l < "$ACTIVE_PIDS_FILE" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# 监控和调整CPU使用率的函数
monitor_resources() {
  while true; do
    # 计算已运行时间和剩余时间
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    REMAINING_TIME=$((RUNTIME - ELAPSED_TIME))
    
    # 格式化剩余时间显示
    REMAINING_MINUTES=$((REMAINING_TIME / 60))
    REMAINING_SECONDS=$((REMAINING_TIME % 60))
    
    # 获取当前CPU使用率（去除百分号并取整数部分）
    if [ "$(uname)" == "Darwin" ]; then
      # macOS
      CPU_USAGE=$(top -l 1 | grep "CPU usage" | awk '{print $3}' | tr -d '%')
    else
      # Linux
      CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    fi
    
    # 获取内存使用情况
    if [ "$(uname)" == "Darwin" ]; then
      # macOS
      MEM_INFO=$(top -l 1 | grep PhysMem)
      MEM_USED_PERCENT=$(echo $MEM_INFO | awk '{print $2}' | tr -d 'M' | awk '{print $1/'"$TOTAL_MEM_KB"'*100*1024}')
      MEM_USED_PERCENT=$(printf "%.1f" $MEM_USED_PERCENT)
    else
      # Linux
      MEM_INFO=$(free -h | grep Mem)
      MEM_USED_PERCENT=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
      MEM_USED_PERCENT=$(printf "%.1f" $MEM_USED_PERCENT)
    fi
    
    # 获取当前活跃计算进程数量
    ACTIVE_COUNT=$(get_active_process_count)
    
    # 显示运行状态和剩余时间
    echo "=========================================="
    echo "运行状态监控 - 剩余时间: ${REMAINING_MINUTES}分${REMAINING_SECONDS}秒"
    echo "已运行: $((ELAPSED_TIME / 60))分$((ELAPSED_TIME % 60))秒 / 总时长: $((RUNTIME / 60))分$((RUNTIME % 60))秒"
    echo "内存状态: $MEM_INFO (使用率: ${MEM_USED_PERCENT}%)"
    echo "当前活跃计算进程数: $ACTIVE_COUNT"
    
    # 动态调整计算进程数量，确保总CPU使用率保持在34%-48%范围内
    if [ ${CPU_USAGE%.*} -gt 48 ] && [ $ACTIVE_COUNT -gt 1 ]; then
      # 如果总CPU使用率超过48%且还有进程可以停止，停止一个计算进程
      if stop_compute_process; then
        ACTIVE_COUNT=$((ACTIVE_COUNT - 1))
        echo "总CPU使用率: ${CPU_USAGE}% > 48%, 停止1个计算进程，当前进程数: $ACTIVE_COUNT"
      else
        echo "总CPU使用率: ${CPU_USAGE}% > 48%, 但无法停止更多进程"
      fi
    elif [ ${CPU_USAGE%.*} -lt 34 ] && [ $ACTIVE_COUNT -lt $CPU_CORES ]; then
      # 如果总CPU使用率低于34%且进程数未达到CPU核数，启动一个新的计算进程
      start_compute_process
      ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
      echo "总CPU使用率: ${CPU_USAGE}% < 34%, 启动1个计算进程，当前进程数: $ACTIVE_COUNT"
    else
      echo "总CPU使用率: ${CPU_USAGE}%, 进程数: $ACTIVE_COUNT (在合理范围内)"
    fi
    
    # 检查是否达到运行时间
    if [ $ELAPSED_TIME -ge $RUNTIME ]; then
      echo "达到预设运行时间 $RUNTIME 秒，停止所有进程..."
      cleanup
      break
    fi
    
    echo "=========================================="
    echo ""
    
    # 每5秒检查一次
    sleep 5
  done
}

# 如果不是测试模式，则实际运行资源占用
if [ "$TEST_MODE" = false ]; then
  echo "检测到CPU核数: $CPU_CORES，将启动 $CPU_PROCESSES 个计算进程"
  
  # 分配内存
  allocate_memory

  # 启动监控进程
  {
    trap 'exit 0' SIGTERM SIGINT
    monitor_resources
  } &
  MONITOR_PID=$!
  echo $MONITOR_PID >> "$PIDS_FILE"
  echo "启动监控进程: PID $MONITOR_PID"

  # 启动初始计算进程（启动2个进程作为基础负载）
  echo "启动初始 CPU 计算进程..."
  INITIAL_PROCESSES=2
  if [ $INITIAL_PROCESSES -gt $CPU_PROCESSES ]; then
    INITIAL_PROCESSES=$CPU_PROCESSES
  fi
  
  for i in $(seq 1 $INITIAL_PROCESSES); do
    start_compute_process
  done
  
  echo "初始启动了 $INITIAL_PROCESSES 个计算进程"

  echo "所有资源占用进程已启动，将在 $RUNTIME 秒后自动停止"
  echo "按 Ctrl+C 可以随时停止脚本"
  echo ""

  # 等待监控进程完成（它会在时间到达后终止所有进程）
  wait $MONITOR_PID 2>/dev/null
  
  # 如果监控进程意外退出且未清理，执行清理
  if [ "$CLEANUP_DONE" != true ]; then
    cleanup
  fi
else
  echo ""
  echo "测试模式完成，参数检查通过。"
  echo "如需实际运行资源占用，请移除 -T 参数重新执行脚本。"
  echo ""
  echo "执行示例:"
  echo "  正常模式: sudo $0 -t $RUNTIME -c $COMPUTE_INTENSITY -m $MEMORY_SIZE"
  echo "  测试模式: sudo $0 -t $RUNTIME -c $COMPUTE_INTENSITY -m $MEMORY_SIZE -T"
fi