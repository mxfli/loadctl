#!/bin/bash

# stress-ng 编译安装脚本（统一版本）
# 支持在线下载和离线安装两种模式

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# stress-ng 版本配置
STRESS_NG_VERSION="0.19.05"
STRESS_NG_URL="https://github.com/ColinIanKing/stress-ng/archive/refs/tags/V${STRESS_NG_VERSION}.tar.gz"
STRESS_NG_TARBALL="stress-ng-${STRESS_NG_VERSION}.tar.gz"

log(){ echo -e "${GREEN}[INFO]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; }

# 显示帮助信息
show_help() {
    cat << EOF
stress-ng 编译安装脚本

用法: $0 [选项]

选项:
  --offline <true|false>  离线模式 (默认: true)
                          true:  使用本地源代码包，不下载
                          false: 从 GitHub 下载源代码
  --create-dist           编译后创建分发包到 ./dist/ 目录 (使用动态编译)
  --use-dist <路径>       从指定的分发包目录安装 (默认: ./dist)
  -v <版本>               指定 stress-ng 版本 (默认: $STRESS_NG_VERSION)
  -p <路径>               指定安装前缀路径 (默认: /usr/local)
  -j <数量>               指定编译并行数 (默认: 自动检测CPU核数)
  -t <路径>               指定源代码包路径 (离线模式时使用，默认: ./$STRESS_NG_TARBALL)
  -c                      仅编译，不安装
  -s                      静态编译
  -m                      最小化编译 (减少依赖)
  -f                      强制重新下载和编译 (在线模式时有效)
  -h                      显示此帮助信息

示例:
  # 创建分发包（推荐用于多服务器部署）
  $0 --create-dist                      # 编译并创建分发包到 ./dist/
  $0 --offline false --create-dist      # 在线下载 + 创建分发包
  
  # 使用分发包安装（快速部署到其他服务器）
  $0 --use-dist                         # 从 ./dist/ 安装
  $0 --use-dist /path/to/dist           # 从指定目录安装
  
  # 离线模式（默认）
  $0                                    # 使用当前目录的源代码包
  $0 --offline true -t /path/to/tarball.tar.gz  # 指定源代码包位置
  $0 --offline true -s                  # 离线模式 + 静态编译
  
  # 在线模式
  $0 --offline false                    # 从 GitHub 下载并安装
  $0 --offline false -v 0.18.06         # 下载指定版本
  $0 --offline false -s                 # 在线下载 + 静态编译
  
  # 通用选项
  $0 -p /opt/stress-ng                  # 安装到指定目录
  $0 -j 4                               # 使用4线程编译
  $0 -c                                 # 仅编译不安装
  $0 -m                                 # 最小化编译

注意:
  - 需要 sudo 权限安装到系统目录
  - 离线模式需要预先准备好源代码包
  - 在线模式需要网络连接下载源代码
  - 首次编译会自动安装编译依赖
  - 静态编译生成的二进制文件不依赖动态库，方便部署
EOF
    exit 0
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

# 将相对路径转换为绝对路径（基于指定基准目录或当前目录）
abs_path() {
    local p="$1"
    local base="${2:-$(pwd)}"
    case "$p" in
        /*) echo "$p" ;;
        *) echo "$base/$p" ;;
    esac
}

# 安装编译依赖
install_build_deps() {
    local static_build=$1
    
    if [ "$static_build" = true ]; then
        log "安装编译依赖（包含静态库支持）..."
    else
        log "安装编译依赖..."
    fi
    
    case $OS_ID in
        ubuntu|debian)
            local packages="build-essential zlib1g-dev libbsd-dev libattr1-dev libkeyutils-dev"
            packages="$packages libapparmor-dev libaio-dev libcap-dev"
            
            # 在线模式需要下载工具
            if [ "$OFFLINE_MODE" = false ]; then
                packages="$packages wget curl"
            fi
            
            # 静态编译需要的静态库
            if [ "$static_build" = true ]; then
                packages="$packages libc6-dev"
            fi
            
            # 可选依赖，增强功能
            local optional_packages="libjudy-dev libsctp-dev libgcrypt20-dev"
            
            sudo apt-get update
            sudo apt-get install -y $packages
            
            # 尝试安装可选依赖
            if sudo apt-get install -y $optional_packages 2>/dev/null; then
                log "已安装可选依赖，将获得完整功能"
            else
                warn "部分可选依赖安装失败，功能可能受限"
            fi
            ;;
        neokylin|centos|rhel|rocky|almalinux)
            if command -v dnf >/dev/null 2>&1; then
                # CentOS/RHEL 8+ - 只安装必需的编译工具和依赖
                # 核心编译工具（替代 "Development Tools" 组）
                sudo dnf install -y gcc gcc-c++ make kernel-headers binutils
                
                # 必需的开发库
                sudo dnf install -y zlib-devel libbsd-devel libattr-devel keyutils-libs-devel
                sudo dnf install -y libaio-devel libcap-devel
                
                # 在线模式需要下载工具
                if [ "$OFFLINE_MODE" = false ]; then
                    sudo dnf install -y wget curl
                fi
                
                # 静态编译需要的静态库
                if [ "$static_build" = true ]; then
                    sudo dnf install -y glibc-static
                fi
                
                # 可选依赖（安装失败不影响编译）
                sudo dnf install -y Judy-devel lksctp-tools-devel libgcrypt-devel libapparmor-devel 2>/dev/null || true
            else
                # CentOS/RHEL 7 - 只安装必需的编译工具和依赖
                # 核心编译工具（替代 "Development Tools" 组）
                sudo yum install -y gcc gcc-c++ make kernel-headers binutils
                
                # 必需的开发库
                sudo yum install -y zlib-devel libbsd-devel libattr-devel keyutils-libs-devel
                sudo yum install -y libaio-devel libcap-devel
                
                # 在线模式需要下载工具
                if [ "$OFFLINE_MODE" = false ]; then
                    sudo yum install -y wget curl
                fi
                
                # 静态编译需要的静态库
                if [ "$static_build" = true ]; then
                    sudo yum install -y glibc-static
                fi
                
                # 可选依赖（安装失败不影响编译）
                sudo yum install -y Judy-devel lksctp-tools-devel libgcrypt-devel libapparmor-devel 2>/dev/null || true
            fi
            ;;
        fedora)
            # Fedora - 只安装必需的编译工具和依赖
            # 核心编译工具（替代 "Development Tools" 组）
            sudo dnf install -y gcc gcc-c++ make kernel-headers binutils
            
            # 必需的开发库
            sudo dnf install -y zlib-devel libbsd-devel libattr-devel keyutils-libs-devel
            sudo dnf install -y libaio-devel libcap-devel
            
            # 在线模式需要下载工具
            if [ "$OFFLINE_MODE" = false ]; then
                sudo dnf install -y wget curl
            fi
            
            # 静态编译需要的静态库
            if [ "$static_build" = true ]; then
                sudo dnf install -y glibc-static
            fi
            
            # 可选依赖（安装失败不影响编译）
            sudo dnf install -y Judy-devel lksctp-tools-devel libgcrypt-devel libapparmor-devel 2>/dev/null || true
            ;;
        opensuse*|sles)
            sudo zypper install -y -t pattern devel_basis
            sudo zypper install -y zlib-devel libbsd-devel libattr-devel keyutils-devel
            sudo zypper install -y libapparmor-devel libaio-devel libcap-devel
            
            # 静态编译需要的静态库
            if [ "$static_build" = true ]; then
                sudo zypper install -y glibc-devel-static
            fi
            ;;
        arch)
            sudo pacman -S --noconfirm base-devel zlib libbsd libattr keyutils
            sudo pacman -S --noconfirm libapparmor libaio libcap
            
            # 在线模式需要下载工具
            if [ "$OFFLINE_MODE" = false ]; then
                sudo pacman -S --noconfirm wget curl
            fi
            ;;
        *)
            error "不支持的操作系统: $OS_ID"
            echo "请手动安装以下编译依赖："
            echo "  - 编译工具链 (gcc, make, etc.)"
            echo "  - zlib-dev, libbsd-dev, libattr-dev"
            echo "  - keyutils-dev, libapparmor-dev, libaio-dev, libcap-dev"
            if [ "$static_build" = true ]; then
                echo "  - 静态库支持 (glibc-static 或 libc6-dev)"
            fi
            if [ "$OFFLINE_MODE" = false ]; then
                echo "  - 下载工具 (wget 或 curl)"
            fi
            return 1
            ;;
    esac
    
    log "编译依赖安装完成"
}

# 下载源代码（仅在线模式使用）
download_source() {
    local url=$1
    local output=$2
    
    log "下载 stress-ng v${STRESS_NG_VERSION} 源代码..."
    
    if command -v wget >/dev/null 2>&1; then
        if ! wget -q -O "$output" "$url"; then
            error "wget 下载失败"
            return 1
        fi
    elif command -v curl >/dev/null 2>&1; then
        if ! curl -L -s -o "$output" "$url"; then
            error "curl 下载失败"
            return 1
        fi
    else
        error "需要 wget 或 curl 工具下载源代码"
        return 1
    fi
    
    log "源代码下载完成"
}

# 编译 stress-ng
compile_stress_ng() {
    local source_dir=$1
    local make_jobs=$2
    local static_build=$3
    local minimal_build=$4
    
    log "开始编译 stress-ng..."
    cd "$source_dir"
    
    # 清理之前的编译
    make clean >/dev/null 2>&1 || true
    
    # 构建编译选项
    local make_opts=""
    if [ "$static_build" = true ]; then
        make_opts="$make_opts STATIC=1"
        log "启用静态编译"
    fi
    
    if [ "$minimal_build" = true ]; then
        make_opts="$make_opts MINIMAL=1"
        log "启用最小化编译"
    fi
    
    # 编译
    log "使用 $make_jobs 个并行进程编译..."
    if ! make -j"$make_jobs" $make_opts; then
        warn "并行编译失败，尝试单线程编译..."
        if ! make clean && make $make_opts; then
            error "编译失败"
            return 1
        fi
    fi
    
    log "编译完成"
}

# 安装 stress-ng
install_stress_ng() {
    local source_dir=$1
    local prefix=$2
    
    log "安装 stress-ng 到 $prefix..."
    # cd "$source_dir" # compile_stress_ng 已经进入该目录，无需重复
    
    if [ "$prefix" != "/usr/local" ]; then
        if ! make install PREFIX="$prefix"; then
            error "安装失败"
            return 1
        fi
    else
        if ! sudo make install PREFIX="$prefix"; then
            error "安装失败"
            return 1
        fi
    fi
    
    log "安装完成"
}

# 创建分发包
create_dist_package() {
    local source_dir=$1
    local version=$2
    local orig_cwd=$3
    
    log "创建分发包到 ./dist/ ..."
    
    # 在原始工作目录创建 dist 目录
    local dist_dir="$orig_cwd/dist"
    rm -rf "$dist_dir"
    mkdir -p "$dist_dir/bin"
    mkdir -p "$dist_dir/man/man1"
    mkdir -p "$dist_dir/example-jobs"
    mkdir -p "$dist_dir/bash-completion"
    
    # 复制静态编译的二进制文件
    if [ ! -f "$source_dir/stress-ng" ]; then
        error "找不到编译后的 stress-ng 二进制文件"
        return 1
    fi
    
    cp "$source_dir/stress-ng" "$dist_dir/bin/"
    chmod +x "$dist_dir/bin/stress-ng"
    log "已复制二进制文件到 $dist_dir/bin/"
    
    # 复制 man 手册（如果存在）
    if [ -f "$source_dir/stress-ng.1" ]; then
        gzip -c "$source_dir/stress-ng.1" > "$dist_dir/man/man1/stress-ng.1.gz" 2>/dev/null || \
            cp "$source_dir/stress-ng.1" "$dist_dir/man/man1/"
        log "已复制 man 手册"
    elif [ -f "$source_dir/stress-ng.1.gz" ]; then
        cp "$source_dir/stress-ng.1.gz" "$dist_dir/man/man1/"
        log "已复制 man 手册"
    fi
    
    # 复制示例作业文件（如果存在）
    if [ -d "$source_dir/example-jobs" ]; then
        cp -r "$source_dir/example-jobs"/*.job "$dist_dir/example-jobs/" 2>/dev/null || true
        log "已复制示例作业文件"
    fi
    
    # 复制 bash 补全脚本（如果存在）
    if [ -f "$source_dir/bash-completion/stress-ng" ]; then
        cp "$source_dir/bash-completion/stress-ng" "$dist_dir/bash-completion/"
        log "已复制 bash 补全脚本"
    fi
    
    # 检测并记录实际的编译类型
    local build_type="UNKNOWN"
    local is_static=false
    
    if command -v ldd >/dev/null 2>&1; then
        if ldd "$dist_dir/bin/stress-ng" 2>&1 | grep -q "not a dynamic executable"; then
            build_type="STATIC"
            is_static=true
            log "检测到静态编译：二进制文件不依赖动态库"
        else
            build_type="DYNAMIC"
            is_static=false
            log "检测到动态编译：二进制文件依赖动态库"
        fi
    fi
    
    # 创建版本信息文件
    cat > "$dist_dir/VERSION" << EOF
STRESS_NG_VERSION=$version
BUILD_DATE=$(date '+%Y-%m-%d %H:%M:%S')
BUILD_TYPE=$build_type
EOF
    
    # 对于动态编译，记录需要的运行时库依赖
    if [ "$is_static" = false ] && command -v ldd >/dev/null 2>&1; then
        log "记录运行时库依赖..."
        echo "" >> "$dist_dir/VERSION"
        echo "# 运行时库依赖 (需要在目标系统安装)" >> "$dist_dir/VERSION"
        ldd "$dist_dir/bin/stress-ng" 2>/dev/null | grep "=>" | awk '{print $1}' | while read lib; do
            echo "RUNTIME_DEP=$lib" >> "$dist_dir/VERSION"
        done
        
        # 显示依赖信息
        log "动态库依赖列表："
        ldd "$dist_dir/bin/stress-ng" 2>&1 | head -10
    fi
    
    log "分发包创建完成: $dist_dir"
    log "可以将此目录复制到其他服务器进行快速安装"
    
    return 0
}

# 从分发包安装
install_from_dist() {
    local dist_dir=$1
    local prefix=$2
    
    log "从分发包安装 stress-ng ..."
    
    # 验证分发包
    if [ ! -d "$dist_dir" ]; then
        error "分发包目录不存在: $dist_dir"
        return 1
    fi
    
    if [ ! -f "$dist_dir/bin/stress-ng" ]; then
        error "分发包中找不到 stress-ng 二进制文件"
        return 1
    fi
    
    # 显示版本信息并检查编译类型
    local build_type="UNKNOWN"
    if [ -f "$dist_dir/VERSION" ]; then
        log "分发包版本信息:"
        cat "$dist_dir/VERSION" | while read line; do
            log "  $line"
        done
        
        # 读取编译类型
        build_type=$(grep "^BUILD_TYPE=" "$dist_dir/VERSION" | cut -d= -f2)
        
        # 如果是动态编译，检查并安装运行时依赖
        if [ "$build_type" = "DYNAMIC" ]; then
            log "检测到动态编译的二进制文件，检查运行时依赖..."
            
            # 安装基础运行时依赖
            case $OS_ID in
                ubuntu|debian)
                    log "安装运行时依赖库..."
                    sudo apt-get update >/dev/null 2>&1 || true
                    sudo apt-get install -y libc6 zlib1g libbsd0 libattr1 libkeyutils1 \
                        libapparmor1 libaio1 libcap2 2>/dev/null || warn "部分运行时库安装失败，可能不影响使用"
                    ;;
                neokylin|centos|rhel|rocky|almalinux)
                    log "安装运行时依赖库..."
                    if command -v dnf >/dev/null 2>&1; then
                        sudo dnf install -y glibc zlib libbsd libattr keyutils-libs \
                            libaio libcap 2>/dev/null || warn "部分运行时库安装失败，可能不影响使用"
                    else
                        sudo yum install -y glibc zlib libbsd libattr keyutils-libs \
                            libaio libcap 2>/dev/null || warn "部分运行时库安装失败，可能不影响使用"
                    fi
                    ;;
                fedora)
                    log "安装运行时依赖库..."
                    sudo dnf install -y glibc zlib libbsd libattr keyutils-libs \
                        libaio libcap 2>/dev/null || warn "部分运行时库安装失败，可能不影响使用"
                    ;;
                *)
                    warn "未识别的操作系统，跳过自动安装运行时依赖"
                    warn "如果 stress-ng 无法运行，请手动安装必要的运行时库"
                    ;;
            esac
        fi
    fi
    
    # 安装二进制文件
    local bin_dir="$prefix/bin"
    if [ "$prefix" = "/usr/local" ] || [ "$prefix" = "/usr" ]; then
        sudo mkdir -p "$bin_dir"
        sudo cp "$dist_dir/bin/stress-ng" "$bin_dir/"
        sudo chmod +x "$bin_dir/stress-ng"
    else
        mkdir -p "$bin_dir"
        cp "$dist_dir/bin/stress-ng" "$bin_dir/"
        chmod +x "$bin_dir/stress-ng"
    fi
    log "已安装二进制文件到 $bin_dir"
    
    # 安装 man 手册
    if [ -f "$dist_dir/man/man1/stress-ng.1.gz" ] || [ -f "$dist_dir/man/man1/stress-ng.1" ]; then
        local man_dir="$prefix/share/man/man1"
        if [ "$prefix" = "/usr/local" ] || [ "$prefix" = "/usr" ]; then
            sudo mkdir -p "$man_dir"
            sudo cp "$dist_dir/man/man1"/stress-ng.* "$man_dir/" 2>/dev/null || true
        else
            mkdir -p "$man_dir"
            cp "$dist_dir/man/man1"/stress-ng.* "$man_dir/" 2>/dev/null || true
        fi
        log "已安装 man 手册"
    fi
    
    # 安装示例作业文件
    if [ -d "$dist_dir/example-jobs" ] && [ -n "$(ls -A "$dist_dir/example-jobs" 2>/dev/null)" ]; then
        local example_dir="$prefix/share/stress-ng/example-jobs"
        if [ "$prefix" = "/usr/local" ] || [ "$prefix" = "/usr" ]; then
            sudo mkdir -p "$example_dir"
            sudo cp "$dist_dir/example-jobs"/*.job "$example_dir/" 2>/dev/null || true
        else
            mkdir -p "$example_dir"
            cp "$dist_dir/example-jobs"/*.job "$example_dir/" 2>/dev/null || true
        fi
        log "已安装示例作业文件"
    fi
    
    # 安装 bash 补全脚本
    if [ -f "$dist_dir/bash-completion/stress-ng" ]; then
        local completion_dir="$prefix/share/bash-completion/completions"
        if [ "$prefix" = "/usr/local" ] || [ "$prefix" = "/usr" ]; then
            sudo mkdir -p "$completion_dir"
            sudo cp "$dist_dir/bash-completion/stress-ng" "$completion_dir/" 2>/dev/null || true
        else
            mkdir -p "$completion_dir"
            cp "$dist_dir/bash-completion/stress-ng" "$completion_dir/" 2>/dev/null || true
        fi
        log "已安装 bash 补全脚本"
    fi
    
    log "从分发包安装完成"
    return 0
}

# 验证安装
verify_installation() {
    local prefix=$1
    local static_build=$2
    local binary_path=""
    
    # 首先尝试使用 command -v 查找实际安装位置
    if command -v stress-ng >/dev/null 2>&1; then
        binary_path=$(command -v stress-ng)
        log "验证安装成功"
        log "stress-ng 位置: $binary_path"
    else
        # 如果 PATH 中找不到，检查预期的安装路径
        local expected_path
        if [ "$prefix" = "/usr/local" ]; then
            expected_path="/usr/local/bin/stress-ng"
        else
            expected_path="$prefix/bin/stress-ng"
        fi
        
        if [ -x "$expected_path" ]; then
            binary_path="$expected_path"
            log "验证安装成功"
            log "stress-ng 位置: $binary_path"
        else
            # 检查其他常见安装位置
            for path in /usr/bin/stress-ng /usr/local/bin/stress-ng /opt/stress-ng/bin/stress-ng; do
                if [ -x "$path" ]; then
                    binary_path="$path"
                    log "验证安装成功"
                    log "stress-ng 位置: $binary_path"
                    warn "注意：stress-ng 安装在 $path，与预期的 $expected_path 不同"
                    break
                fi
            done
        fi
    fi
    
    # 如果找到了 stress-ng
    if [ -n "$binary_path" ] && [ -x "$binary_path" ]; then
        # 显示版本信息
        if "$binary_path" --version >/dev/null 2>&1; then
            local version=$("$binary_path" --version 2>&1 | head -1)
            log "版本信息: $version"
        fi
        
        # 验证是否为静态编译
        if [ "$static_build" = true ]; then
            if command -v ldd >/dev/null 2>&1; then
                if ldd "$binary_path" 2>&1 | grep -q "not a dynamic executable"; then
                    log "静态编译验证成功：二进制文件不依赖动态库"
                else
                    warn "注意：检测到动态库依赖"
                    ldd "$binary_path" 2>&1 | head -5
                fi
            fi
        fi
        
        # 如果不在 PATH 中，提示用户
        if ! command -v stress-ng >/dev/null 2>&1; then
            warn "stress-ng 不在 PATH 环境变量中"
            local bin_dir=$(dirname "$binary_path")
            echo "请将以下路径添加到 PATH:"
            echo "  export PATH=\"$bin_dir:\$PATH\""
            echo "或者使用完整路径运行: $binary_path"
        fi
        
        return 0
    else
        error "安装验证失败，找不到 stress-ng"
        error "已检查的路径："
        if [ "$prefix" = "/usr/local" ]; then
            error "  - /usr/local/bin/stress-ng"
        else
            error "  - $prefix/bin/stress-ng"
        fi
        error "  - /usr/bin/stress-ng"
        error "  - /opt/stress-ng/bin/stress-ng"
        return 1
    fi
}

# 主函数
main() {
    local version="$STRESS_NG_VERSION"
    local prefix="/usr/local"
    local make_jobs=$(nproc)
    local compile_only=false
    local static_build=false
    local minimal_build=false
    local force_rebuild=false
    local tarball_path=""
    local create_dist=false
    local use_dist=""
    OFFLINE_MODE=true  # 默认离线模式
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --offline)
                if [ "$2" = "false" ] || [ "$2" = "False" ] || [ "$2" = "FALSE" ]; then
                    OFFLINE_MODE=false
                else
                    OFFLINE_MODE=true
                fi
                shift 2
                ;;
            --create-dist)
                create_dist=true
                compile_only=true  # 仅编译不安装
                shift
                ;;
            --use-dist)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    use_dist="$2"
                    shift 2
                else
                    use_dist="./dist"
                    shift
                fi
                ;;
            -v)
                version="$2"
                shift 2
                ;;
            -p)
                prefix="$2"
                shift 2
                ;;
            -j)
                make_jobs="$2"
                shift 2
                ;;
            -t)
                tarball_path="$2"
                shift 2
                ;;
            -c)
                compile_only=true
                shift
                ;;
            -s)
                static_build=true
                shift
                ;;
            -m)
                minimal_build=true
                shift
                ;;
            -f)
                force_rebuild=true
                shift
                ;;
            -h)
                show_help
                ;;
            *)
                error "无效选项: $1"
                echo "使用 -h 查看帮助信息"
                exit 1
                ;;
        esac
    done
    
    # 处理 --use-dist 模式（从分发包安装）
    if [ -n "$use_dist" ]; then
        echo -e "${BLUE}stress-ng 从分发包安装${NC}"
        echo "=================================="
        log "安装路径: $prefix"
        log "分发包目录: $use_dist"
        echo
        
        # 读取分发包的编译类型
        local dist_is_static=false
        if [ -f "$use_dist/VERSION" ]; then
            local dist_build_type=$(grep "^BUILD_TYPE=" "$use_dist/VERSION" | cut -d= -f2)
            if [ "$dist_build_type" = "STATIC" ]; then
                dist_is_static=true
            fi
        fi
        
        if install_from_dist "$use_dist" "$prefix"; then
            verify_installation "$prefix" "$dist_is_static"
            log "操作完成！"
            exit 0
        else
            error "从分发包安装失败"
            exit 1
        fi
    fi
    
    # 更新版本配置
    STRESS_NG_VERSION="$version"
    STRESS_NG_URL="https://github.com/ColinIanKing/stress-ng/archive/refs/tags/V${version}.tar.gz"
    STRESS_NG_TARBALL="stress-ng-${version}.tar.gz"
    
    # 如果是离线模式且未指定 tarball 路径，使用当前目录
    if [ "$OFFLINE_MODE" = true ] && [ -z "$tarball_path" ]; then
        tarball_path="./$STRESS_NG_TARBALL"
    fi
    
    echo -e "${BLUE}stress-ng 编译安装脚本${NC}"
    echo "=================================="
    log "模式: $([ "$OFFLINE_MODE" = true ] && echo "离线安装" || echo "在线下载")"
    log "版本: $version"
    log "安装路径: $prefix"
    log "编译并行数: $make_jobs"
    [ "$OFFLINE_MODE" = true ] && log "源代码包: $tarball_path"
    [ "$OFFLINE_MODE" = false ] && log "下载地址: $STRESS_NG_URL"
    [ "$compile_only" = true ] && log "模式: 仅编译"
    [ "$static_build" = true ] && log "静态编译: 启用"
    [ "$minimal_build" = true ] && log "最小化编译: 启用"
    [ "$create_dist" = true ] && log "创建分发包: 启用 (将保存到 ./dist/)"
    echo
    
    # 离线模式：检查源代码包是否存在
    if [ "$OFFLINE_MODE" = true ]; then
        if [ ! -f "$tarball_path" ]; then
            error "找不到源代码包: $tarball_path"
            echo "请确保源代码包存在，或使用 -t 选项指定正确的路径"
            echo "或者使用 --offline false 切换到在线下载模式"
            exit 1
        fi
    fi
    
    # 检测系统
    detect_os
    
    # 记录原始工作目录，用于处理相对路径
    local orig_cwd="$(pwd)"
    
    # 创建工作目录
    local work_dir="/tmp/stress-ng-build-$$"
    mkdir -p "$work_dir"
    cd "$work_dir"
    
    # 设置清理函数
    cleanup() {
        if [ -d "$work_dir" ]; then
            log "清理临时编译目录: $work_dir"
            cd /
            rm -rf "$work_dir"
            log "临时编译目录已清理完成"
        fi
    }
    trap cleanup EXIT
    
    # 安装编译依赖
    install_build_deps "$static_build"
    
    # 获取源代码
    if [ "$OFFLINE_MODE" = true ]; then
        # 离线模式：复制本地源代码包
        log "复制源代码包到工作目录..."
        # 规范为绝对路径，避免 cd 后相对路径失效
        local abs_tarball_path="$(abs_path "$tarball_path" "$orig_cwd")"
        cp "$abs_tarball_path" "$work_dir/"
        local tarball_name=$(basename "$abs_tarball_path")
    else
        # 在线模式：下载源代码
        if [ "$force_rebuild" = true ] || [ ! -f "$STRESS_NG_TARBALL" ]; then
            download_source "$STRESS_NG_URL" "$STRESS_NG_TARBALL"
        else
            log "使用已存在的源代码包"
        fi
        local tarball_name="$STRESS_NG_TARBALL"
    fi
    
    # 解压源代码
    log "解压源代码..."
    if ! tar -xzf "$tarball_name"; then
        error "解压失败"
        exit 1
    fi
    
    # 识别解压后的源代码目录（兼容带/不带 V 的版本目录）
    local source_dir=""
    if [ -d "stress-ng-$version" ]; then
        source_dir="stress-ng-$version"
    elif [ -d "stress-ng-V$version" ]; then
        source_dir="stress-ng-V$version"
    else
        # 尝试根据压缩包的首个顶级目录判断
        local top_dir="$(tar -tzf "$tarball_name" 2>/dev/null | head -1 | cut -d/ -f1)"
        if [ -n "$top_dir" ] && [ -d "$top_dir" ]; then
            source_dir="$top_dir"
        else
            error "找不到源代码目录，已解压但目录名不匹配"
            echo "请检查压缩包内容，或使用 -t 指定正确版本包"
            exit 1
        fi
    fi
    
    # 编译
    compile_stress_ng "$source_dir" "$make_jobs" "$static_build" "$minimal_build"
    
    # 创建分发包（如果启用）
    if [ "$create_dist" = true ]; then
        create_dist_package "$work_dir/$source_dir" "$version" "$orig_cwd"
    fi
    
    # 安装
    if [ "$compile_only" = false ]; then
        install_stress_ng "$source_dir" "$prefix"
        verify_installation "$prefix" "$static_build"
    else
        log "仅编译模式完成，二进制文件位于: $work_dir/$source_dir/stress-ng"
        if [ "$static_build" = true ]; then
            log "这是静态编译的二进制文件，可以直接复制到其它机器使用"
        fi
    fi
    
    log "操作完成！"
}

# 运行主函数
main "$@"
