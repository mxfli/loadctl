#!/bin/bash

# 智能资源控制工具安装和设置脚本

set -e



# 全局变量
AUTO_MODE=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log(){ echo -e "${GREEN}[INFO]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; }
# 显示帮助信息
show_help() {
    echo "智能资源控制工具安装和设置脚本"
    echo
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -a, --auto      一键自动安装模式（无交互）"
    echo "  -h, --help      显示此帮助信息"
    echo
    echo "一键安装模式特性:"
    echo "  - 不提示 root 权限警告"
    echo "  - 使用默认安装目录: /opt/app/loadctl"
    echo "  - 自动安装缺少的依赖包"
    echo "  - 自动创建或替换 crontab 定时任务"
    echo "  - 跳过验证测试"
    echo "  - 减少用户交互提示"
    echo
    echo "示例:"
    echo "  $0              # 交互式安装"
    echo "  $0 --auto       # 一键自动安装"
    echo "  $0 -h           # 显示帮助"
    echo
}

# 操作系统检测（设置 OS_ID/OS_VERSION，并兼容 OS/VER）
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=${ID}
        OS_VERSION=${VERSION_ID}
        OS=${NAME}
        VER=${VERSION_ID}
    elif command -v lsb_release >/dev/null 2>&1; then
        OS_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
        OS=$(lsb_release -si)
        VER=${OS_VERSION}
    else
        OS_ID=$(uname -s | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(uname -r)
        OS=$(uname -s)
        VER=${OS_VERSION}
    fi
    log "检测到操作系统: $OS $VER"
}

# 检查 dist 分发包是否存在且有效
check_dist_package() {
    local dist_dir="${1:-./dist}"
    
    # 检查 dist 目录是否存在
    if [ ! -d "$dist_dir" ]; then
        return 1
    fi
    
    # 检查是否包含 stress-ng 二进制文件
    if [ ! -f "$dist_dir/bin/stress-ng" ]; then
        return 1
    fi
    
    # 检查 VERSION 文件是否存在
    if [ ! -f "$dist_dir/VERSION" ]; then
        return 1
    fi
    
    return 0
}

# 使用 install_stress_ng.sh 脚本安装 stress-ng
install_stress_ng_offline() {
    log "使用 install_stress_ng.sh 脚本进行离线安装..."

    # 检查 install_stress_ng.sh 脚本是否存在
    if [ ! -f "./install_stress_ng.sh" ]; then
        error "找不到 install_stress_ng.sh 脚本"
        return 1
    fi

    # 确保脚本有执行权限
    chmod +x ./install_stress_ng.sh

    # 调用离线安装模式
    log "调用 install_stress_ng.sh 进行离线安装..."
    if ./install_stress_ng.sh --offline true; then
        log "stress-ng 离线安装成功"
        return 0
    else
        warn "离线安装失败，尝试在线安装..."
        if ./install_stress_ng.sh --offline false; then
            log "stress-ng 在线安装成功"
            return 0
        else
            error "stress-ng 安装失败"
            return 1
        fi
    fi
}



# 检查 loadctl.sh 的依赖包
check_loadctl_dependencies() {
    log "检查 loadctl.sh 的依赖包..."
    
    local missing_deps=()
    local required_tools=("awk" "free" "top" "nproc")
    
    # 检查必需的工具
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_deps+=("$tool")
        fi
    done
    
    # 检查 stress-ng
    if ! command -v stress-ng >/dev/null 2>&1; then
        missing_deps+=("stress-ng")
    fi
    
    if [ ${#missing_deps[@]} -eq 0 ]; then
        log "所有 loadctl.sh 依赖包已安装"
        return 0
    else
        warn "缺少以下依赖包: ${missing_deps[*]}"
        return 1
    fi
}

# 安装依赖包
install_dependencies() {
    log "正在安装依赖包..."
    
    # 首先尝试使用 install_stress_ng.sh 安装 stress-ng
    if ! command -v stress-ng >/dev/null 2>&1; then
        log "stress-ng 未安装，使用 install_stress_ng.sh 进行安装..."
        if ! install_stress_ng_offline; then
            warn "使用 install_stress_ng.sh 安装失败"
            return 1
        fi
    fi
    
    # 安装其他基础依赖（不包括 stress-ng）
    if command -v apt-get >/dev/null 2>&1; then
        log "使用 apt-get 安装基础依赖..."
        sudo apt-get update
        sudo apt-get install -y curl wget
    elif command -v yum >/dev/null 2>&1; then
        log "使用 yum 安装基础依赖..."
        sudo yum install -y curl wget
    elif command -v dnf >/dev/null 2>&1; then
        log "使用 dnf 安装基础依赖..."
        sudo dnf install -y curl wget
    elif command -v zypper >/dev/null 2>&1; then
        log "使用 zypper 安装基础依赖..."
        sudo zypper install -y curl wget
    elif command -v pacman >/dev/null 2>&1; then
        log "使用 pacman 安装基础依赖..."
        sudo pacman -S --noconfirm curl wget
    else
        warn "不支持的包管理器，跳过基础依赖安装"
    fi
}

# 验证安装
verify_installation() {
    log "验证安装..."
    
    local missing_tools=()
    
    for tool in stress-ng curl wget; do
        if ! command -v $tool >/dev/null 2>&1; then
            missing_tools+=($tool)
        fi
    done
    
    if [ ${#missing_tools[@]} -eq 0 ]; then
        log "所有依赖工具安装成功！"
        return 0
    else
        error "以下工具安装失败: ${missing_tools[*]}"
        return 1
    fi
}

# 安装 loadctl.sh 到指定目录
install_loadctl() {
    local install_dir="${1:-/opt/app/loadctl}"
    
    log "安装 loadctl.sh 到 $install_dir..."
    
    # 检查 loadctl.sh 是否存在
    if [ ! -f "./loadctl.sh" ]; then
        error "找不到 loadctl.sh 脚本"
        return 1
    fi
    
    # 创建安装目录
    if ! sudo mkdir -p "$install_dir"; then
        error "无法创建安装目录: $install_dir"
        return 1
    fi
    
    # 复制脚本文件
    if ! sudo cp ./loadctl.sh "$install_dir/"; then
        error "复制 loadctl.sh 失败"
        return 1
    fi
    
    # 复制相关脚本
    for script in system_monitor.sh emergency_cleanup.sh; do
        if [ -f "./$script" ]; then
            sudo cp "./$script" "$install_dir/" || warn "复制 $script 失败"
        fi
    done
    
    # 设置权限
    sudo chmod +x "$install_dir"/*.sh
    
    # 创建符号链接到 /usr/local/bin (可选)
    if [ -d "/usr/local/bin" ]; then
        sudo ln -sf "$install_dir/loadctl.sh" /usr/local/bin/loadctl 2>/dev/null || true
        log "创建符号链接: /usr/local/bin/loadctl -> $install_dir/loadctl.sh"
    fi
    
    log "loadctl.sh 安装完成: $install_dir"
    return 0
}

# 设置脚本权限
setup_scripts() {
    log "设置脚本权限..."
    

    chmod +x loadctl.sh 2>/dev/null || warn "loadctl.sh 不存在"
    chmod +x system_monitor.sh 2>/dev/null || warn "system_monitor.sh 不存在"
    chmod +x install_and_setup.sh 2>/dev/null || warn "install_and_setup.sh 不存在"
    chmod +x emergency_cleanup.sh 2>/dev/null || warn "emergency_cleanup.sh 不存在"
    
    log "脚本权限设置完成"
}

# 创建示例配置
create_examples() {
    log "创建使用示例..."
    
    cat > quick_start_examples.sh << 'EOF'
#!/bin/bash

# 智能资源控制脚本快速开始示例

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== 智能资源控制脚本使用示例 ===${NC}"
echo

echo "1. 测试模式 - 检查参数但不实际运行"
echo "   ./loadctl.sh -T"
echo

echo "2. 轻度测试 - CPU 35%, 内存 40%, 运行 5 分钟"
echo "   ./loadctl.sh -t 300 -c 35 -m 40"
echo

echo "3. 标准测试 - CPU 50%, 内存 50%, 运行 15 分钟"
echo "   ./loadctl.sh -t 900 -c 50 -m 50"
echo

echo "4. 监控系统状态 (在另一个终端运行)"
echo "   ./system_monitor.sh"
echo

echo "5. 一次性系统状态检查"
echo "   ./system_monitor.sh -1"
echo

echo "6. 紧急清理 - 清理残留的 stress-ng 进程"
echo "   ./emergency_cleanup.sh"
echo

echo "选择要运行的示例 (1-6) 或按 Enter 退出:"
read -r choice

case $choice in
    1)
        echo -e "${GREEN}运行测试模式...${NC}"
        ./loadctl.sh -T
        ;;
    2)
        echo -e "${GREEN}运行轻度测试...${NC}"
        echo -e "${YELLOW}注意: 测试将运行 5 分钟，按 Ctrl+C 可随时停止${NC}"
        ./loadctl.sh -t 300 -c 35 -m 40
        ;;
    3)
        echo -e "${GREEN}运行标准测试...${NC}"
        echo -e "${YELLOW}注意: 测试将运行 15 分钟，按 Ctrl+C 可随时停止${NC}"
        ./loadctl.sh -t 900 -c 50 -m 50
        ;;
    4)
        echo -e "${GREEN}启动系统监控...${NC}"
        echo -e "${YELLOW}提示: 按 Ctrl+C 退出监控${NC}"
        ./system_monitor.sh
        ;;
    5)
        echo -e "${GREEN}显示系统状态...${NC}"
        ./system_monitor.sh -1
        ;;
    6)
        echo -e "${GREEN}运行紧急清理...${NC}"
        ./emergency_cleanup.sh
        ;;
    *)
        echo "退出"
        ;;
esac

# 运行后检查是否有残留进程
echo ""
echo -e "${BLUE}检查是否有残留进程...${NC}"
stress_pids=$(pgrep -f "stress-ng" 2>/dev/null)
if [ -n "$stress_pids" ]; then
    echo -e "${RED}警告: 发现残留的 stress-ng 进程 (PID: $stress_pids)${NC}"
    echo -e "${YELLOW}建议运行清理脚本: ./emergency_cleanup.sh${NC}"
else
    echo -e "${GREEN}没有发现残留进程${NC}"
fi
EOF

    chmod +x quick_start_examples.sh
    log "创建了快速开始示例脚本: quick_start_examples.sh"
}

# 运行系统检查
system_check() {
    log "执行系统检查..."
    
    # 检查内存
    local total_mem_gb=$(free -g | grep '^Mem:' | awk '{print $2}')
    if [ $total_mem_gb -lt 2 ]; then
        warn "系统内存较少 (${total_mem_gb}GB)，建议至少 2GB"
    else
        log "内存检查通过: ${total_mem_gb}GB"
    fi
    
    # 检查CPU核数
    local cpu_cores=$(nproc)
    log "CPU核数: $cpu_cores"
    
    # 检查当前负载
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    log "当前系统负载: $load_avg"
    
    # 检查磁盘空间
    local disk_usage=$(df /tmp | tail -1 | awk '{print $5}' | tr -d '%')
    if [ $disk_usage -gt 80 ]; then
        warn "/tmp 磁盘空间使用率较高: ${disk_usage}%"
    else
        log "磁盘空间检查通过"
    fi
}

# 生成 crontab 定时任务字符串
generate_crontab_task() {
    local install_dir="${1:-/opt/app/loadctl}"
    
    log "生成 crontab 定时任务字符串..."
    
    # 生成 crontab 任务：每天凌晨2点执行，运行15分钟，CPU 45% 内存 40%
    local crontab_task="0 2 * * * $install_dir/loadctl.sh -t 900 -c 45 -m 40 >/dev/null 2>&1"
    
    echo
    log "生成的 crontab 定时任务字符串："
    echo "=================================="
    echo "$crontab_task"
    echo "=================================="
    echo
    echo "任务说明："
    echo "  - 执行时间: 每天凌晨 2:00"
    echo "  - 运行时长: 15 分钟 (900 秒)"
    echo "  - CPU 目标: 45%"
    echo "  - 内存目标: 40%"
    echo "  - 日志输出: 重定向到 /dev/null"
    echo
    
    return 0
}

# 自动配置 crontab 任务
setup_crontab_task() {
    local install_dir="${1:-/opt/app/loadctl}"
    
    if [ "$AUTO_MODE" = true ]; then
        log "自动模式：配置 crontab 定时任务..."
        local setup_crontab=true
    else
        echo
        echo "是否要自动配置 crontab 定时任务？"
        echo "任务将在每天凌晨2点执行，运行15分钟，CPU负载45%，内存负载40%"
        echo
        read -p "请选择 [y/N]: " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            local setup_crontab=true
        else
            local setup_crontab=false
        fi
    fi
    
    if [ "$setup_crontab" = true ]; then
        log "配置 crontab 定时任务..."
        
        local crontab_task="0 2 * * * $install_dir/loadctl.sh -t 900 -c 45 -m 40 >/dev/null 2>&1"
        
        # 检查是否已存在相同的任务
        if crontab -l 2>/dev/null | grep -q "$install_dir/loadctl.sh"; then
            if [ "$AUTO_MODE" = true ]; then
                log "自动模式：替换现有的 loadctl 定时任务"
                # 删除现有任务
                crontab -l 2>/dev/null | grep -v "$install_dir/loadctl.sh" | crontab -
                log "删除现有的 loadctl 定时任务"
            else
                warn "检测到已存在的 loadctl 定时任务"
                echo "是否要替换现有任务？[y/N]: "
                read -p "" -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log "跳过 crontab 配置"
                    return 0
                fi
                
                # 删除现有任务
                crontab -l 2>/dev/null | grep -v "$install_dir/loadctl.sh" | crontab -
                log "删除现有的 loadctl 定时任务"
            fi
        fi
        
        # 添加新任务
        (crontab -l 2>/dev/null; echo "$crontab_task") | crontab -
        
        if [ $? -eq 0 ]; then
            log "crontab 定时任务配置成功"
            log "任务详情: $crontab_task"
            
            # 显示当前的 crontab 任务
            echo
            log "当前用户的 crontab 任务："
            crontab -l 2>/dev/null | grep -E "(loadctl|stress)" || echo "  (无相关任务)"
        else
            error "crontab 定时任务配置失败"
            return 1
        fi
    else
        log "跳过 crontab 自动配置"
        echo "您可以手动添加以下任务到 crontab："
        echo "  crontab -e"
        echo "  然后添加: 0 2 * * * $install_dir/loadctl.sh -t 900 -c 45 -m 40 >/dev/null 2>&1"
    fi
    
    return 0
}

# 执行验证测试
run_verification_test() {
    local install_dir="${1:-/opt/app/loadctl}"
    
    echo
    echo "是否要执行一次验证测试？"
    echo "测试将运行 30 秒，CPU 目标 35%，内存目标 35%"
    echo
    read -p "请选择 [y/N]: " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "开始验证测试..."
        
        # 检查 loadctl.sh 是否可执行
        if [ ! -x "$install_dir/loadctl.sh" ]; then
            error "loadctl.sh 不可执行: $install_dir/loadctl.sh"
            return 1
        fi
        
        # 运行测试模式检查
        log "运行测试模式检查..."
        if ! "$install_dir/loadctl.sh" -T -c 35 -m 35; then
            error "测试模式检查失败"
            return 1
        fi
        
        log "测试模式检查通过，开始实际测试..."
        echo "注意: 测试将运行 30 秒，您可以按 Ctrl+C 提前停止"
        sleep 2
        
        # 运行实际测试
        if "$install_dir/loadctl.sh" -t 30 -c 35 -m 35; then
            log "验证测试完成！"
            log "loadctl.sh 工作正常"
        else
            warn "验证测试过程中出现问题，但这可能是正常的"
            log "请检查系统日志或手动运行测试"
        fi
    else
        log "跳过验证测试"
        echo "您可以手动运行测试："
        echo "  $install_dir/loadctl.sh -T        # 测试模式"
        echo "  $install_dir/loadctl.sh -t 30 -c 35 -m 35  # 30秒测试"
    fi
    
    return 0
}

# 显示安装完成信息
show_completion() {
    local install_dir="${1:-/opt/app/loadctl}"
    
    echo
    log "安装和设置完成！"
    echo
    echo "安装位置: $install_dir"
    echo
    echo "可用的脚本："
    echo "  1. loadctl.sh                 - 智能资源控制主脚本"
    echo "  2. system_monitor.sh          - 系统监控脚本"  
    echo "  3. emergency_cleanup.sh       - 紧急清理脚本"
    [ -f "./quick_start_examples.sh" ] && echo "  4. quick_start_examples.sh    - 快速开始示例"
    echo
    echo "快速开始："
    if [ -L "/usr/local/bin/loadctl" ]; then
        echo "  loadctl -T                    - 测试模式"
        echo "  loadctl -t 300 -c 35 -m 35   - 运行5分钟轻度测试"
    else
        echo "  $install_dir/loadctl.sh -T    - 测试模式"
        echo "  $install_dir/loadctl.sh -t 300 -c 35 -m 35  - 运行5分钟轻度测试"
    fi
    [ -f "./quick_start_examples.sh" ] && echo "  ./quick_start_examples.sh     - 运行示例选择器"
    echo "  ./system_monitor.sh -1        - 查看系统状态"
    echo
}

# 主函数
main() {
    local install_dir="/opt/app/loadctl"
    
    echo -e "${BLUE}智能资源控制工具安装程序${NC}"
    echo "================================"
    echo
    
    # 检查是否以root用户运行安装
    if [ "$EUID" -eq 0 ] && [ "$AUTO_MODE" != true ]; then
        warn "建议不要以root用户运行此脚本"
        echo "按 Enter 继续或 Ctrl+C 取消..."
        read
    fi
    
    detect_os
    
    # 询问安装目录
    if [ "$AUTO_MODE" = true ]; then
        log "自动模式：使用默认安装路径: $install_dir"
    else
        echo
        echo "请选择 loadctl.sh 的安装目录："
        echo "默认: $install_dir"
        echo
        read -p "输入自定义路径或按 Enter 使用默认路径: " custom_dir
        if [ -n "$custom_dir" ]; then
            install_dir="$custom_dir"
            log "使用自定义安装路径: $install_dir"
        else
            log "使用默认安装路径: $install_dir"
        fi
    fi
    
    # 检查 loadctl.sh 依赖
    echo
    log "检查 loadctl.sh 依赖包..."
    if check_loadctl_dependencies; then
        log "所有依赖包已安装"
    else
        if [ "$AUTO_MODE" = true ]; then
            log "自动模式：安装缺少的依赖包..."
            log "使用 install_stress_ng.sh 离线安装..."
            install_dependencies
            if ! verify_installation; then
                error "依赖安装失败"
                exit 1
            fi
        else
            echo
            echo "是否要安装缺少的依赖包？"
            read -p "请选择 [Y/n]: " -n 1 -r
            echo
            
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            # 询问是否安装依赖
            echo
            echo "选择安装方式:"
            echo "1) 使用 install_stress_ng.sh 离线安装 (推荐)"
            echo "2) 使用包管理器安装"
            echo "3) 使用 install_stress_ng.sh 在线安装"
            echo "4) 跳过安装 (已手动安装依赖)"
            echo
            read -p "请选择 [1-4]: " -n 1 -r
            echo
            echo
            
            case $REPLY in
                1|"")
                    log "使用 install_stress_ng.sh 离线安装..."
                    install_dependencies
                    if ! verify_installation; then
                        error "依赖安装失败"
                        exit 1
                    fi
                    ;;
                2)
                    log "使用包管理器安装依赖..."
                    # 先使用包管理器安装基础依赖（不包括 stress-ng）
                    if command -v apt-get >/dev/null 2>&1; then
                        sudo apt-get update && sudo apt-get install -y curl wget
                    elif command -v yum >/dev/null 2>&1; then
                        sudo yum install -y curl wget
                    elif command -v dnf >/dev/null 2>&1; then
                        sudo dnf install -y curl wget
                    elif command -v zypper >/dev/null 2>&1; then
                        sudo zypper install -y curl wget
                    elif command -v pacman >/dev/null 2>&1; then
                        sudo pacman -S --noconfirm curl wget
                    fi
                    
                    # 使用 install_stress_ng.sh 安装 stress-ng
                    if ! command -v stress-ng >/dev/null 2>&1; then
                        log "使用 install_stress_ng.sh 安装 stress-ng..."
                        if ! install_stress_ng_offline; then
                            error "stress-ng 安装失败"
                            exit 1
                        fi
                    fi
                    
                    if ! verify_installation; then
                        error "依赖安装失败"
                        exit 1
                    fi
                    ;;
                3)
                    log "使用 install_stress_ng.sh 在线安装..."
                    # 先安装基础工具
                    if command -v apt-get >/dev/null 2>&1; then
                        sudo apt-get install -y curl wget
                    elif command -v yum >/dev/null 2>&1; then
                        sudo yum install -y curl wget
                    elif command -v dnf >/dev/null 2>&1; then
                        sudo dnf install -y curl wget
                    fi
                    
                    # 使用 install_stress_ng.sh 在线安装
                    if ./install_stress_ng.sh --offline false; then
                        log "在线安装成功"
                    else
                        error "在线安装失败"
                        exit 1
                    fi
                    
                    if ! verify_installation; then
                        error "安装验证失败"
                        exit 1
                    fi
                    ;;
                4)
                    log "跳过依赖安装，请确保已手动安装必需工具"
                    warn "请确保已安装: stress-ng, curl, wget"
                    ;;
                *)
                    error "无效选择，退出"
                    exit 1
                    ;;
                esac
            else
                warn "跳过依赖安装，请确保手动安装所需依赖"
            fi
        fi
    fi
    
    # 安装 loadctl.sh
    echo
    if install_loadctl "$install_dir"; then
        log "loadctl.sh 安装成功"
    else
        error "loadctl.sh 安装失败"
        exit 1
    fi
    
    setup_scripts
    create_examples
    system_check
    
    # 生成 crontab 任务字符串
    generate_crontab_task "$install_dir"
    
    # 配置 crontab 任务
    setup_crontab_task "$install_dir"
    
    # 执行验证测试
    if [ "$AUTO_MODE" = true ]; then
        log "自动模式：跳过验证测试"
    else
        run_verification_test "$install_dir"
    fi
    
    show_completion "$install_dir"
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--auto)
                AUTO_MODE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 解析参数并运行主函数
parse_args "$@"
main