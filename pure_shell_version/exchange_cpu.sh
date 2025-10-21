#!/bin/bash

# 设置脚本运行时间（随机10-15分钟）
RUNTIME=$((RANDOM % 301 + 600))  # 600-900秒（10-15分钟）
echo "脚本将运行 $((RUNTIME / 60)) 分 $((RUNTIME % 60)) 秒"

# 设置初始计算强度
COMPUTE_INTENSITY=8000

# 记录开始时间
START_TIME=$(date +%s)

# 创建临时文件存储进程PID
PIDS_FILE=$(mktemp)

# 监控和调整CPU使用率的函数
monitor_cpu() {
  while true; do
    # 获取当前CPU使用率（去除百分号并取整数部分）
    CPU_USAGE=$(top -l 1 | grep "CPU usage" | awk '{print $3}' | tr -d '%')
    
    # 如果CPU使用率超过60%，减少计算强度
    if [ ${CPU_USAGE%.*} -gt 60 ]; then
      COMPUTE_INTENSITY=$((COMPUTE_INTENSITY * 90 / 100))  # 减少10%
      echo "CPU使用率: ${CPU_USAGE}% > 60%, 降低计算强度至: $COMPUTE_INTENSITY"
    elif [ ${CPU_USAGE%.*} -lt 40 ]; then
      # 如果CPU使用率低于40%，适当增加计算强度
      COMPUTE_INTENSITY=$((COMPUTE_INTENSITY * 110 / 100))  # 增加10%
      echo "CPU使用率: ${CPU_USAGE}% < 40%, 提高计算强度至: $COMPUTE_INTENSITY"
    else
      echo "CPU使用率: ${CPU_USAGE}%, 计算强度保持: $COMPUTE_INTENSITY"
    fi
    
    # 检查是否达到运行时间
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED_TIME -ge $RUNTIME ]; then
      echo "达到预设运行时间，停止所有进程..."
      # 杀掉所有子进程
      if [ -f "$PIDS_FILE" ]; then
        kill $(cat "$PIDS_FILE") 2>/dev/null
        rm "$PIDS_FILE"
      fi
      exit 0
    fi
    
    # 每5秒检查一次
    sleep 5
  done
}

# 启动监控进程
monitor_cpu &
MONITOR_PID=$!
echo $MONITOR_PID >> "$PIDS_FILE"

# 启动计算进程
for i in {1..5}
do
{
  while true
  do
    n=$(echo $(($RANDOM % 10 + 1)))  # 1-10秒的随机休眠
    
    # 动态调整计算量
    local_intensity=$COMPUTE_INTENSITY
    
    for ii in $(seq 1 $local_intensity)
    do
      for iii in $(seq 1 $local_intensity)
      do
        j=$((ii+iii))
      done
    done
    
    sleep ${n}
  done
} &
  
  # 记录进程PID
  echo $! >> "$PIDS_FILE"
done

# 等待监控进程完成（它会在时间到达后终止所有进程）
wait $MONITOR_PID