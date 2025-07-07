#!/bin/bash

# DDNS-Lan Bash版本
# 通过SSH获取路由器WAN IP并更新Cloudflare DNS记录

set -e  # 遇到错误时退出

# === 配置文件路径 ===
CONFIG_FILE="${CONFIG_FILE:-$(dirname "$0")/config.json}"

# === 全局变量 ===
ROUTER_SSH_HOST=""
ROUTER_SSH_PORT=""
ROUTER_USERNAME=""
ROUTER_PASSWORD=""
CLOUDFLARE_API_TOKEN=""
CLOUDFLARE_ZONE_ID=""
RECORD_NAME=""
CLOUDFLARE_TTL=""
CLOUDFLARE_PROXIED=""
USE_PRIVATE_IP=""
ALLOWED_PRIVATE_NETWORKS=""
FALLBACK_TO_LOCAL_IP=""
VERBOSE=""
LOG_FILE=""

# === 颜色输出 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# === 读取配置文件 ===
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        log_info "请创建配置文件或使用 --init 初始化"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "需要安装 jq 来解析JSON配置文件"
        exit 1
    fi
    
    log_info "加载配置文件: $CONFIG_FILE"
    
    # 验证JSON格式
    if ! jq . "$CONFIG_FILE" &> /dev/null; then
        log_error "配置文件JSON格式错误"
        exit 1
    fi
    
    # 读取路由器配置
    ROUTER_SSH_HOST=$(jq -r '.router.ssh_host // "192.168.110.1"' "$CONFIG_FILE")
    ROUTER_SSH_PORT=$(jq -r '.router.ssh_port // 22' "$CONFIG_FILE")
    ROUTER_USERNAME=$(jq -r '.router.username // "root"' "$CONFIG_FILE")
    ROUTER_PASSWORD=$(jq -r '.router.password // ""' "$CONFIG_FILE")
    
    # 读取Cloudflare配置
    CLOUDFLARE_API_TOKEN=$(jq -r '.cloudflare.api_token // ""' "$CONFIG_FILE")
    CLOUDFLARE_ZONE_ID=$(jq -r '.cloudflare.zone_id // ""' "$CONFIG_FILE")
    RECORD_NAME=$(jq -r '.cloudflare.record_name // "myserver.yourdomain.com"' "$CONFIG_FILE")
    CLOUDFLARE_TTL=$(jq -r '.cloudflare.ttl // 120' "$CONFIG_FILE")
    CLOUDFLARE_PROXIED=$(jq -r '.cloudflare.proxied // false' "$CONFIG_FILE")
    
    # 读取网络配置
    USE_PRIVATE_IP=$(jq -r '.network.use_private_ip // true' "$CONFIG_FILE")
    FALLBACK_TO_LOCAL_IP=$(jq -r '.network.fallback_to_local_ip // true' "$CONFIG_FILE")
    
    # 读取允许的网络段（数组）
    local networks_json
    networks_json=$(jq -r '.network.allowed_private_networks[]? // empty' "$CONFIG_FILE")
    if [ -n "$networks_json" ]; then
        ALLOWED_PRIVATE_NETWORKS="$networks_json"
    else
        ALLOWED_PRIVATE_NETWORKS="10.150.0.0/16"
    fi
    
    # 读取日志配置
    VERBOSE=$(jq -r '.logging.verbose // true' "$CONFIG_FILE")
    LOG_FILE=$(jq -r '.logging.log_file // ""' "$CONFIG_FILE")
    
    # 验证必需的配置
    if [ -z "$ROUTER_PASSWORD" ]; then
        log_warning "路由器密码未设置"
    fi
    
    log_info "配置加载完成"
}

# === 初始化配置文件 ===
init_config() {
    if [ -f "$CONFIG_FILE" ]; then
        read -p "配置文件已存在，是否覆盖? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "取消初始化"
            exit 0
        fi
    fi
    
    log_info "创建配置文件: $CONFIG_FILE"
    
    cat > "$CONFIG_FILE" << 'EOF'
{
  "router": {
    "ssh_host": "192.168.110.1",
    "ssh_port": 22,
    "username": "root",
    "password": "Im_WD_"
  },
  "cloudflare": {
    "api_token": "",
    "zone_id": "",
    "record_name": "myserver.yourdomain.com",
    "ttl": 120,
    "proxied": false
  },
  "network": {
    "use_private_ip": true,
    "allowed_private_networks": ["10.150.0.0/16"],
    "fallback_to_local_ip": true
  },
  "logging": {
    "verbose": true,
    "log_file": ""
  }
}
EOF
    
    log_success "配置文件创建成功"
    log_info "请编辑配置文件设置你的Cloudflare API凭据:"
    log_info "  vi $CONFIG_FILE"
    log_info "然后运行: $0"
}

# === 检查依赖 ===
check_dependencies() {
    local missing_deps=()
    
    if ! command -v sshpass &> /dev/null; then
        missing_deps+=("sshpass")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "缺少依赖工具: ${missing_deps[*]}"
        log_info "请安装缺少的工具："
        echo "  Ubuntu/Debian: sudo apt-get install sshpass jq curl"
        echo "  CentOS/RHEL: sudo yum install sshpass jq curl"
        echo "  Arch Linux: sudo pacman -S sshpass jq curl"
        echo "  macOS: brew install sshpass jq curl"
        exit 1
    fi
}

# === 检查IP是否在指定网络段内 ===
ip_in_network() {
    local ip="$1"
    local network="$2"
    
    # 分解网络地址和掩码
    local network_addr=$(echo "$network" | cut -d/ -f1)
    local prefix_len=$(echo "$network" | cut -d/ -f2)
    
    # 将IP地址转换为整数
    local ip_int=$(echo "$ip" | awk -F. '{print ($1 * 256^3) + ($2 * 256^2) + ($3 * 256) + $4}')
    local net_int=$(echo "$network_addr" | awk -F. '{print ($1 * 256^3) + ($2 * 256^2) + ($3 * 256) + $4}')
    
    # 计算网络掩码
    local mask=$((0xffffffff << (32 - prefix_len)))
    
    # 检查IP是否在网络段内
    if [ $((ip_int & mask)) -eq $((net_int & mask)) ]; then
        return 0
    else
        return 1
    fi
}

# === 检查IP是否为可用IP ===
is_usable_ip() {
    local ip="$1"
    
    # 检查IP格式
    if ! [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi
    
    # 排除明显无效的IP
    if [ "$ip" = "0.0.0.0" ] || [ "$ip" = "255.255.255.255" ]; then
        return 1
    fi
    
    # 排除回环地址
    local first_octet=$(echo "$ip" | cut -d. -f1)
    if [ "$first_octet" -eq 127 ]; then
        return 1
    fi
    
    # 排除链路本地地址
    local second_octet=$(echo "$ip" | cut -d. -f2)
    if [ "$first_octet" -eq 169 ] && [ "$second_octet" -eq 254 ]; then
        return 1
    fi
    
    # 如果启用了私有IP使用，检查是否在允许的网络段内
    if [ "$USE_PRIVATE_IP" = "true" ]; then
        # 检查是否在允许的私有网络段内
        if ip_in_network "$ip" "$ALLOWED_PRIVATE_NETWORKS"; then
            return 0
        fi
    fi
    
    # 检查是否为公网IP
    local second_octet=$(echo "$ip" | cut -d. -f2)
    
    # 排除私有IP地址段（如果不在允许列表中）
    # 10.0.0.0/8
    if [ "$first_octet" -eq 10 ]; then
        return 1
    fi
    
    # 172.16.0.0/12
    if [ "$first_octet" -eq 172 ] && [ "$second_octet" -ge 16 ] && [ "$second_octet" -le 31 ]; then
        return 1
    fi
    
    # 192.168.0.0/16
    if [ "$first_octet" -eq 192 ] && [ "$second_octet" -eq 168 ]; then
        return 1
    fi
    
    return 0
}

# === 通过SSH获取路由器WAN IP ===
get_router_wan_ip() {
    log_info "正在通过SSH连接路由器 ${ROUTER_SSH_HOST}:${ROUTER_SSH_PORT}..." >&2
    
    # SSH连接选项
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
    
    # 尝试多个命令获取WAN IP
    local commands=(
        "ip route | grep default | head -1"
        "ubus call network.interface.wan status 2>/dev/null || echo 'ubus failed'"
        "ifconfig | grep -A 1 wan || ifconfig | grep -A 5 eth"
        "ip addr show | grep 'inet '"
        "cat /proc/net/route | head -5"
    )
    
    for cmd in "${commands[@]}"; do
        log_info "执行命令: $cmd" >&2
        
        # 使用sshpass执行SSH命令
        local output
        output=$(sshpass -p "$ROUTER_PASSWORD" ssh $ssh_opts "${ROUTER_USERNAME}@${ROUTER_SSH_HOST}" "$cmd" 2>/dev/null || echo "")
        
        if [ -n "$output" ]; then
            log_info "命令输出: $output" >&2
            
            # 特殊处理：优先从路由表中获取 src IP（本机IP）
            if echo "$cmd" | grep -q "ip route"; then
                local src_ip
                src_ip=$(echo "$output" | grep -oE 'src [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1 | awk '{print $2}')
                if [ -n "$src_ip" ] && is_usable_ip "$src_ip"; then
                    log_success "找到路由表源IP: $src_ip" >&2
                    echo "$src_ip"
                    return 0
                fi
            fi
            
            # 特殊处理：从ubus JSON输出中提取IP地址
            if echo "$cmd" | grep -q "ubus call"; then
                if command -v jq &> /dev/null && echo "$output" | jq . &> /dev/null; then
                    # 提取IPv4地址
                    local ipv4_addr
                    ipv4_addr=$(echo "$output" | jq -r '.["ipv4-address"][]?.address // empty' 2>/dev/null | head -1)
                    if [ -n "$ipv4_addr" ] && is_usable_ip "$ipv4_addr"; then
                        log_success "找到ubus接口IP: $ipv4_addr" >&2
                        echo "$ipv4_addr"
                        return 0
                    fi
                fi
            fi
            
            # 从输出中提取所有IP地址
            local ips
            ips=$(echo "$output" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sort -u)
            
            # 检查每个IP是否可用
            while read -r ip; do
                if [ -n "$ip" ] && is_usable_ip "$ip"; then
                    log_success "找到可用 WAN IP: $ip" >&2
                    echo "$ip"
                    return 0
                elif [ -n "$ip" ]; then
                    log_info "发现其他 IP: $ip" >&2
                fi
            done <<< "$ips"
        else
            log_warning "命令无输出或执行失败" >&2
        fi
    done
    
    log_error "无法从路由器获取可用的 WAN IP" >&2
    return 1
}

# === 获取本机IP作为备用 ===
get_local_ip() {
    log_info "获取本机IP作为备用..."
    
    # 尝试多种方法获取本机IP
    local ip=""
    
    # 方法1: 通过默认路由
    ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
    
    # 方法2: 通过网络接口
    if [ -z "$ip" ]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    
    # 方法3: 通过ifconfig
    if [ -z "$ip" ]; then
        ip=$(ifconfig | grep -oE 'inet [0-9.]+' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')
    fi
    
    if [ -n "$ip" ]; then
        log_info "本机IP: $ip"
        echo "$ip"
        return 0
    else
        log_error "无法获取本机IP"
        return 1
    fi
}

# === 更新Cloudflare DNS记录 ===
update_cloudflare_dns() {
    local ip="$1"
    
    if [ -z "$CLOUDFLARE_API_TOKEN" ] || [ -z "$CLOUDFLARE_ZONE_ID" ]; then
        log_warning "缺少 Cloudflare API 凭据，跳过 DNS 更新"
        log_info "请设置环境变量: CLOUDFLARE_API_TOKEN 和 CLOUDFLARE_ZONE_ID"
        return 1
    fi
    
    log_info "正在更新 Cloudflare DNS 记录..."
    log_info "域名: $RECORD_NAME -> $ip"
    
    # 获取DNS记录ID
    log_info "获取DNS记录ID..."
    local record_response
    record_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=$RECORD_NAME&type=A" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json")
    
    if [ $? -ne 0 ]; then
        log_error "获取DNS记录失败"
        return 1
    fi
    
    # 检查响应是否成功
    local success
    success=$(echo "$record_response" | jq -r '.success')
    
    if [ "$success" != "true" ]; then
        log_error "API调用失败:"
        echo "$record_response" | jq -r '.errors[]?.message // "未知错误"'
        return 1
    fi
    
    # 提取记录ID
    local record_id
    record_id=$(echo "$record_response" | jq -r '.result[0]?.id // empty')
    
    if [ -z "$record_id" ]; then
        log_error "未找到DNS记录: $RECORD_NAME"
        return 1
    fi
    
    log_info "找到记录ID: $record_id"
    
    # 更新DNS记录
    log_info "更新DNS记录..."
    local update_data
    update_data=$(jq -n \
        --arg type "A" \
        --arg name "$RECORD_NAME" \
        --arg content "$ip" \
        --argjson ttl "$CLOUDFLARE_TTL" \
        --argjson proxied "$CLOUDFLARE_PROXIED" \
        '{type: $type, name: $name, content: $content, ttl: $ttl, proxied: $proxied}')
    
    if [ "$VERBOSE" = "true" ]; then
        log_info "请求数据: $update_data"
    fi
    
    local update_response
    update_response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$update_data")
    
    if [ $? -ne 0 ]; then
        log_error "更新DNS记录失败"
        return 1
    fi
    
    # 检查更新是否成功
    success=$(echo "$update_response" | jq -r '.success')
    
    if [ "$success" = "true" ]; then
        log_success "DNS记录更新成功: $RECORD_NAME -> $ip"
        return 0
    else
        log_error "DNS更新失败:"
        echo "$update_response" | jq -r '.errors[]?.message // "未知错误"'
        return 1
    fi
}

# === 主函数 ===
main() {
    echo "=== DDNS-Lan Bash版本 ==="
    echo
    
    # 加载配置文件
    load_config
    
    # 检查依赖
    check_dependencies
    
    # 获取IP地址
    local ip=""
    
    # 优先从路由器获取WAN IP
    if [ "$USE_PRIVATE_IP" = "true" ]; then
        log_info "尝试从路由器获取 WAN IP (允许内网IP: $ALLOWED_PRIVATE_NETWORKS)..."
    else
        log_info "尝试从路由器获取公网 WAN IP..."
    fi
    
    # 获取IP地址，确保只获取一次
    ip=$(get_router_wan_ip)
    if [ -n "$ip" ]; then
        log_success "成功获取路由器 WAN IP: $ip"
    else
        log_warning "无法从路由器获取 WAN IP，使用本机 IP 作为备用..."
        ip=$(get_local_ip)
        if [ -n "$ip" ]; then
            log_info "使用本机 IP: $ip"
        else
            log_error "无法获取任何 IP 地址，退出"
            exit 1
        fi
    fi
    
    # 更新DNS记录
    echo
    log_info "当前IP地址: $ip"
    
    if [ "$CHECK_ONLY" = "true" ]; then
        log_info "仅检查模式，跳过DNS更新"
        log_success "配置检查完成"
        return 0
    fi
    
    if update_cloudflare_dns "$ip"; then
        log_success "DDNS更新完成"
    else
        log_error "DDNS更新失败"
        exit 1
    fi
}

# === 帮助信息 ===
show_help() {
    echo "DDNS-Lan Bash版本 - 动态DNS更新工具"
    echo
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -h, --help       显示此帮助信息"
    echo "  --init           初始化配置文件"
    echo "  --config FILE    指定配置文件路径 (默认: ./ddns-lan.json)"
    echo "  --check          仅检查配置和IP，不更新DNS"
    echo
    echo "配置文件:"
    echo "  默认配置文件: $CONFIG_FILE"
    echo "  使用 --init 创建配置文件模板"
    echo
    echo "配置文件格式示例:"
    echo '  {'
    echo '    "router": {'
    echo '      "ssh_host": "192.168.110.1",'
    echo '      "username": "root",'
    echo '      "password": "your_password"'
    echo '    },'
    echo '    "cloudflare": {'
    echo '      "api_token": "your_api_token",'
    echo '      "zone_id": "your_zone_id",'
    echo '      "record_name": "myserver.yourdomain.com"'
    echo '    },'
    echo '    "network": {'
    echo '      "use_private_ip": true,'
    echo '      "allowed_private_networks": ["10.150.0.0/16"]'
    echo '    }'
    echo '  }'
    echo
    echo "示例:"
    echo "  $0 --init                    # 创建配置文件"
    echo "  $0                           # 使用默认配置文件运行"
    echo "  $0 --config my-config.json   # 使用指定配置文件"
    echo "  $0 --check                   # 仅检查配置，不更新DNS"
}

# === 参数处理 ===
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --init)
            init_config
            exit 0
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        "")
            break
            ;;
        *)
            echo "未知选项: $1"
            echo "使用 $0 --help 查看帮助"
            exit 1
            ;;
    esac
done

# 运行主函数
main
