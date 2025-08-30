#!/bin/bash

# 三通道域名分流脚本 - 完整修复版
# 兼容 fscarmen, yonggekkk, jinwyp 等主流WARP脚本
# 支持 Hiddify, Sing-box, 3X-UI, X-UI 等代理面板
# 修复版本: 解决分流失败问题

VERSION="2.0.1"
SCRIPT_URL="https://raw.githubusercontent.com/vpn3288/warp/refs/heads/main/proxy.sh"

# 颜色定义
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

# 检查root权限
[[ $EUID -ne 0 ]] && red "请以root模式运行脚本" && exit 1

# 配置目录
CONFIG_DIR="/etc/three-channel-routing"
LOG_FILE="/var/log/three-channel-routing.log"

# 全局变量 - 添加备用标志
WARP_BINARY=""
WARP_CONFIG=""
EXISTING_WARP_TYPE=""
PANEL_TYPE=""
USE_WIREGUARD_GO=""

# 预设域名列表 - 需要走WARP的域名
DEFAULT_WARP_DOMAINS=(
    "remove.bg"
    "upscale.media" 
    "waifu2x.udp.jp"
    "perplexity.ai"
    "you.com"
    "ip125.com"
    "openai.com"
    "chatgpt.com"
    "claude.ai"
    "anthropic.com"
    "bard.google.com"
    "github.com"
    "raw.githubusercontent.com"
    "discord.com"
    "twitter.com"
    "x.com"
    "facebook.com"
    "instagram.com"
    "youtube.com"
    "gmail.com"
    "drive.google.com"
    "dropbox.com"
    "onedrive.live.com"
    "telegram.org"
    "whatsapp.com"
    "reddit.com"
    "netflix.com"
    "spotify.com"
    "twitch.tv"
    "tiktok.com"
    "linkedin.com"
    "medium.com"
    "stackoverflow.com"
    "wikipedia.org"
    "archive.org"
)

# 日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
}

# 主菜单
main_menu() {
    clear
    green "========================================="
    green "   三通道域名分流脚本 v${VERSION} (修复版)"
    green "========================================="
    echo
    blue "核心功能："
    echo "1. 安装/配置 WARP Socks5 代理"
    echo "2. 智能检测现有面板并配置分流"
    echo "3. 添加自定义WARP域名"
    echo "4. 查看分流状态和测试"
    echo "5. 管理域名规则"
    echo
    blue "维护功能："
    echo "6. 重启WARP服务"
    echo "7. 查看日志"
    echo "8. 卸载配置"
    echo
    echo "0. 退出"
    echo
    readp "请选择功能 [0-8]: " choice
    
    case $choice in
        1) install_configure_warp;;
        2) auto_detect_and_configure;;
        3) add_custom_domains;;
        4) show_status_and_test;;
        5) manage_domain_rules;;
        6) restart_warp_service;;
        7) show_logs;;
        8) uninstall_all;;
        0) cleanup && exit 0;;
        *) red "无效选择" && sleep 1 && main_menu;;
    esac
}

# 检测系统环境
detect_system() {
    log_info "检测系统环境"
    
    # 检查系统类型
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        red "无法识别系统类型"
        exit 1
    fi
    
    # 检查架构 - 修复架构检测
    ARCH=$(uname -m)
    case $ARCH in
        "x86_64") WARP_ARCH="amd64";;
        "aarch64"|"arm64") WARP_ARCH="arm64";;
        "armv7l"|"armv7") WARP_ARCH="armv7";;
        "i386"|"i686") WARP_ARCH="386";;
        *) red "不支持的架构: $ARCH" && exit 1;;
    esac
    
    green "系统: $OS $VER ($ARCH -> $WARP_ARCH)"
    
    # 验证架构兼容性
    validate_architecture
}

# 安装依赖
install_dependencies() {
    log_info "安装必要依赖"
    
    if command -v apt &> /dev/null; then
        apt update -qq
        apt install -y curl wget jq qrencode wireguard-tools iptables &> /dev/null
    elif command -v yum &> /dev/null; then
        yum install -y curl wget jq qrencode wireguard-tools iptables &> /dev/null
    elif command -v dnf &> /dev/null; then
        dnf install -y curl wget jq qrencode wireguard-tools iptables &> /dev/null
    else
        red "不支持的包管理器"
        exit 1
    fi
    
    # 手动安装jq如果失败
    if ! command -v jq &> /dev/null; then
        yellow "手动安装jq..."
        if [[ $ARCH == "x86_64" ]]; then
            wget -O /usr/local/bin/jq "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"
        else
            wget -O /usr/local/bin/jq "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux32"
        fi
        chmod +x /usr/local/bin/jq
    fi
}

# 检测现有WARP安装
detect_existing_warp() {
    log_info "检测现有WARP安装"
    
    # fscarmen/warp-sh
    if [[ -f /opt/warp-go/warp-go ]] && [[ -f /opt/warp-go/warp.conf ]]; then
        EXISTING_WARP_TYPE="fscarmen"
        WARP_BINARY="/opt/warp-go/warp-go"
        WARP_CONFIG="/opt/warp-go/warp.conf"
        green "检测到 fscarmen/warp-sh 安装"
        return 0
    fi
    
    # yonggekkk/warp-yg
    if [[ -f /usr/local/bin/warp-go ]] && [[ -f /etc/wireguard/warp.conf ]]; then
        EXISTING_WARP_TYPE="yonggekkk"
        WARP_BINARY="/usr/local/bin/warp-go"
        WARP_CONFIG="/etc/wireguard/warp.conf"
        green "检测到 yonggekkk/warp-yg 安装"
        return 0
    fi
    
    # jinwyp/one_click_script
    if [[ -f /usr/bin/warp-go ]] || [[ -f /usr/local/bin/warp-go ]]; then
        EXISTING_WARP_TYPE="jinwyp"
        WARP_BINARY=$(which warp-go 2>/dev/null)
        green "检测到 jinwyp 或其他 WARP 安装"
        return 0
    fi
    
    # 通用检测
    if command -v warp-go &> /dev/null; then
        EXISTING_WARP_TYPE="generic"
        WARP_BINARY=$(which warp-go)
        green "检测到通用 warp-go 安装"
        return 0
    fi
    
    yellow "未检测到现有WARP安装"
    return 1
}

# 检测代理面板
detect_proxy_panels() {
    log_info "检测代理面板"
    
    # 检测fscarmen/sing-box (模块化配置)
    if [[ -d /etc/sing-box/conf ]] && [[ -f /etc/sing-box/conf/01_outbounds.json ]]; then
        PANEL_TYPE="fscarmen_singbox"
        green "检测到 fscarmen/sing-box (模块化配置)"
        return 0
    fi
    
    # 检测标准sing-box
    if [[ -f /etc/sing-box/config.json ]] || systemctl list-units --type=service | grep -q sing-box; then
        PANEL_TYPE="standard_singbox"
        green "检测到标准 Sing-box"
        return 0
    fi
    
    # 检测Hiddify
    if [[ -d /opt/hiddify-manager ]] || [[ -f /opt/hiddify-config/hiddify-panel.json ]]; then
        PANEL_TYPE="hiddify"
        green "检测到 Hiddify Panel"
        return 0
    fi
    
    # 检测X-UI系列
    if systemctl list-units --type=service | grep -E "(x-ui|3x-ui)" > /dev/null; then
        PANEL_TYPE="xui"
        green "检测到 X-UI/3X-UI"
        return 0
    fi
    
    # 检测Mihomo/Clash
    if [[ -f /etc/mihomo/config.yaml ]] || [[ -f /etc/clash/config.yaml ]]; then
        PANEL_TYPE="mihomo"
        green "检测到 Mihomo/Clash"
        return 0
    fi
    
    yellow "未检测到支持的代理面板"
    return 1
}

# 安装和配置WARP
install_configure_warp() {
    clear
    green "=== 安装/配置 WARP Socks5 代理 ==="
    echo
    
    detect_system
    install_dependencies
    
    # 检测现有WARP
    if detect_existing_warp; then
        yellow "检测到现有WARP安装: $EXISTING_WARP_TYPE"
        readp "是否使用现有安装？[Y/n]: " use_existing
        
        if [[ ! $use_existing =~ [Nn] ]]; then
            configure_existing_warp
            return
        fi
    fi
    
    # 全新安装WARP
    install_fresh_warp
}

# 配置现有WARP
configure_existing_warp() {
    log_info "配置现有WARP: $EXISTING_WARP_TYPE"
    
    case $EXISTING_WARP_TYPE in
        "fscarmen")
            configure_fscarmen_warp
            ;;
        "yonggekkk")
            configure_yonggekkk_warp
            ;;
        "jinwyp"|"generic")
            configure_generic_warp
            ;;
    esac
    
    # 创建统一的Socks5服务
    create_warp_socks5_service
    start_warp_service
    
    green "现有WARP配置完成！"
}

# 配置fscarmen的WARP
configure_fscarmen_warp() {
    log_info "配置fscarmen WARP为Socks5模式"
    
    # 停止现有服务
    systemctl stop warp-go 2>/dev/null
    
    # 备份配置
    [[ -f $WARP_CONFIG ]] && cp $WARP_CONFIG "${WARP_CONFIG}.backup"
    
    # 修改配置为Socks5模式
    if [[ -f $WARP_CONFIG ]]; then
        # 检查是否已有Socks5配置
        if ! grep -q "\[Socks5\]" $WARP_CONFIG; then
            echo "" >> $WARP_CONFIG
            echo "[Socks5]" >> $WARP_CONFIG
            echo "BindAddress = 127.0.0.1:40000" >> $WARP_CONFIG
        else
            # 更新Socks5配置
            sed -i '/\[Socks5\]/,/^\[/s/BindAddress.*/BindAddress = 127.0.0.1:40000/' $WARP_CONFIG
        fi
        green "fscarmen WARP配置已更新"
    fi
}

# 配置yonggekkk的WARP
configure_yonggekkk_warp() {
    log_info "配置yonggekkk WARP为Socks5模式"
    
    # 停止现有服务
    systemctl stop warp-go 2>/dev/null
    
    # 备份WireGuard配置
    [[ -f $WARP_CONFIG ]] && cp $WARP_CONFIG "${WARP_CONFIG}.backup"
    
    # 转换为warp-go Socks5配置
    convert_wireguard_to_socks5 $WARP_CONFIG
}

# 配置通用WARP
configure_generic_warp() {
    log_info "配置通用WARP为Socks5模式"
    
    # 查找配置文件
    local config_paths=(
        "/etc/wireguard/warp.conf"
        "/opt/warp-go/warp.conf"
        "/usr/local/etc/warp.conf"
        "/etc/warp-go/warp.conf"
    )
    
    for path in "${config_paths[@]}"; do
        if [[ -f "$path" ]]; then
            WARP_CONFIG="$path"
            log_info "找到WARP配置: $path"
            break
        fi
    done
    
    if [[ -n $WARP_CONFIG ]]; then
        configure_fscarmen_warp
    else
        yellow "未找到WARP配置，将全新安装"
        install_fresh_warp
    fi
}

# 转换WireGuard配置为Socks5
convert_wireguard_to_socks5() {
    local wg_config="$1"
    
    if [[ ! -f "$wg_config" ]]; then
        red "WireGuard配置文件不存在"
        return 1
    fi
    
    # 提取配置信息
    local private_key=$(grep -oP '(?<=PrivateKey = ).*' "$wg_config")
    local endpoint=$(grep -oP '(?<=Endpoint = ).*' "$wg_config")
    local address=$(grep -oP '(?<=Address = ).*' "$wg_config")
    local reserved=$(grep -oP '(?<=Reserved = ).*' "$wg_config")
    
    # 如果没有Reserved，生成一个
    if [[ -z "$reserved" ]]; then
        reserved="[$(shuf -i 0-255 -n 1),$(shuf -i 0-255 -n 1),$(shuf -i 0-255 -n 1)]"
    fi
    
    # 创建新的Socks5配置
    mkdir -p $CONFIG_DIR
    cat > $CONFIG_DIR/warp-socks5.conf <<EOF
[Interface]
PrivateKey = $private_key
Address = $address
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
Endpoint = $endpoint
Reserved = $reserved

[Socks5]
BindAddress = 127.0.0.1:40000
EOF

    WARP_CONFIG="$CONFIG_DIR/warp-socks5.conf"
    green "WireGuard配置已转换为Socks5格式"
}

# 全新安装WARP
install_fresh_warp() {
    log_info "全新安装WARP"
    
    green "下载 warp-go..."
    
    # 使用新的下载验证函数
    if ! download_and_verify_warp; then
        red "warp-go 下载失败，尝试备用方案"
        try_alternative_warp_install
        return
    fi
    
    # 生成WARP配置
    generate_fresh_warp_config
    
    green "WARP安装完成"
}

# 备用WARP安装方案
try_alternative_warp_install() {
    log_info "尝试备用WARP安装方案"
    
    yellow "尝试使用系统包管理器安装wireguard-go..."
    
    if command -v apt &> /dev/null; then
        apt update && apt install -y wireguard-go
    elif command -v yum &> /dev/null; then
        yum install -y wireguard-tools
    elif command -v dnf &> /dev/null; then
        dnf install -y wireguard-tools
    fi
    
    # 检查是否安装成功
    if command -v wireguard-go &> /dev/null; then
        WARP_BINARY=$(which wireguard-go)
        green "使用 wireguard-go 作为备用方案"
        USE_WIREGUARD_GO=true
        return 0
    fi
    
    red "备用方案也失败，请手动安装warp-go"
    return 1
}

# 生成全新WARP配置
generate_fresh_warp_config() {
    log_info "生成WARP配置"
    
    mkdir -p $CONFIG_DIR
    
    # 生成密钥对
    local private_key=$(wg genkey)
    local public_key=$(echo "$private_key" | wg pubkey)
    
    # WARP端点
    local endpoints=(
        "162.159.193.10:2408"
        "162.159.192.1:2408"
        "188.114.97.1:2408" 
        "188.114.96.1:2408"
    )
    local endpoint=${endpoints[$RANDOM % ${#endpoints[@]}]}
    
    # 生成配置
    cat > $CONFIG_DIR/warp-socks5.conf <<EOF
[Interface]
PrivateKey = $private_key
Address = 172.16.0.2/32, 2606:4700:110:$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2)/128
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $endpoint
Reserved = [$(shuf -i 0-255 -n 1),$(shuf -i 0-255 -n 1),$(shuf -i 0-255 -n 1)]

[Socks5]
BindAddress = 127.0.0.1:40000
EOF

    WARP_CONFIG="$CONFIG_DIR/warp-socks5.conf"
    green "WARP配置生成完成"
}

# 创建WARP Socks5服务 - 增强版本检测和兼容性
create_warp_socks5_service() {
    log_info "创建WARP Socks5服务"
    
    # 确保有WARP_BINARY
    if [[ -z $WARP_BINARY ]]; then
        WARP_BINARY=$(which warp-go 2>/dev/null)
        if [[ -z $WARP_BINARY ]]; then
            WARP_BINARY="/usr/local/bin/warp-go"
        fi
    fi
    
    # 验证二进制文件是否可执行
    if [[ ! -x "$WARP_BINARY" ]]; then
        red "WARP二进制文件不可执行: $WARP_BINARY"
        return 1
    fi
    
    # 测试二进制文件
    if ! "$WARP_BINARY" --version >/dev/null 2>&1; then
        red "WARP二进制文件测试失败，可能存在架构不匹配问题"
        
        # 显示文件信息用于调试
        yellow "文件信息:"
        file "$WARP_BINARY" || true
        yellow "系统架构: $(uname -m)"
        
        # 尝试使用备用方案
        if [[ "$USE_WIREGUARD_GO" == "true" ]]; then
            create_wireguard_service
            return
        else
            return 1
        fi
    fi
    
    # 创建服务配置
    local exec_start_cmd
    if [[ "$USE_WIREGUARD_GO" == "true" ]]; then
        exec_start_cmd="$WARP_BINARY wg0"
    else
        exec_start_cmd="$WARP_BINARY --config $WARP_CONFIG"
    fi
    
    cat > /etc/systemd/system/warp-socks5.service <<EOF
[Unit]
Description=WARP Socks5 Proxy for Three-Channel Routing
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
ExecStart=$exec_start_cmd
ExecStartPre=/bin/sleep 3
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
KillMode=mixed
TimeoutStopSec=15
TimeoutStartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-socks5
    green "WARP Socks5服务已创建"
}

# 启动WARP服务 - 增强错误处理和诊断
start_warp_service() {
    log_info "启动WARP服务"
    
    # 停止可能冲突的服务
    systemctl stop warp-go 2>/dev/null
    systemctl stop wg-quick@warp 2>/dev/null
    systemctl stop wg-quick@wg0 2>/dev/null
    
    # 检查端口占用
    if check_port_usage 40000; then
        yellow "端口40000可用"
    else
        yellow "端口40000被占用，尝试终止占用进程..."
        local pid=$(lsof -ti:40000 2>/dev/null)
        if [[ -n "$pid" ]]; then
            kill -9 $pid 2>/dev/null
            sleep 2
        fi
    fi
    
    # 启动服务
    systemctl restart warp-socks5
    sleep 8
    
    # 检查服务状态
    if systemctl is-active --quiet warp-socks5; then
        green "WARP Socks5 服务启动成功 (127.0.0.1:40000)"
        
        # 验证端口监听
        local retry_count=0
        while [[ $retry_count -lt 10 ]]; do
            if netstat -tlnp 2>/dev/null | grep -q "127.0.0.1:40000"; then
                green "Socks5端口监听确认"
                break
            fi
            sleep 1
            ((retry_count++))
        done
        
        # 测试连接
        if test_warp_connection; then
            green "WARP连接测试成功"
            return 0
        else
            yellow "WARP连接测试失败，进行故障诊断..."
            diagnose_warp_connection_failure
        fi
    else
        red "WARP服务启动失败"
        log_error "WARP服务启动失败"
        show_warp_service_logs
        return 1
    fi
}

# WARP连接故障诊断
diagnose_warp_connection_failure() {
    yellow "=== WARP连接故障诊断 ==="
    
    # 1. 检查服务状态
    echo "1. 服务状态检查:"
    systemctl status warp-socks5 --no-pager -l
    
    # 2. 检查端口监听
    echo "2. 端口监听检查:"
    netstat -tlnp | grep ":40000" || echo "端口40000未监听"
    
    # 3. 检查配置文件
    echo "3. 配置文件检查:"
    if [[ -f $WARP_CONFIG ]]; then
        echo "配置文件存在: $WARP_CONFIG"
        echo "配置文件大小: $(stat -c%s $WARP_CONFIG) 字节"
    else
        echo "配置文件不存在: $WARP_CONFIG"
    fi
    
    # 4. 检查二进制文件
    echo "4. 二进制文件检查:"
    if [[ -f $WARP_BINARY ]]; then
        echo "二进制文件: $WARP_BINARY"
        echo "文件权限: $(ls -la $WARP_BINARY)"
        file $WARP_BINARY
        
        # 测试执行
        if $WARP_BINARY --version >/dev/null 2>&1; then
            echo "二进制文件可正常执行"
        else
            echo "二进制文件执行失败 - 可能架构不匹配"
            echo "系统架构: $(uname -m)"
            echo "二进制架构: $(file $WARP_BINARY | grep -o 'ELF [^,]*')"
        fi
    else
        echo "二进制文件不存在: $WARP_BINARY"
    fi
    
    # 5. 网络连接测试
    echo "5. 网络连接测试:"
    if curl -s --max-time 5 https://1.1.1.1 > /dev/null; then
        echo "网络连接正常"
    else
        echo "网络连接异常"
    fi
    
    # 6. 防火墙检查
    echo "6. 防火墙检查:"
    if command -v iptables &> /dev/null; then
        iptables -L | grep -i drop || echo "无阻断规则"
    fi
    
    # 提供解决建议
    echo
    yellow "=== 解决建议 ==="
    echo "1. 如果二进制文件架构不匹配，请重新下载正确架构版本"
    echo "2. 如果网络连接异常，请检查VPS网络设置"
    echo "3. 如果服务持续失败，请查看详细日志: journalctl -u warp-socks5 -f"
    echo "4. 可尝试使用备用安装方案或手动配置"
}

# 显示WARP服务日志
show_warp_service_logs() {
    yellow "最近的WARP服务日志:"
    journalctl -u warp-socks5 -n 10 --no-pager
}

# 增强的WARP连接测试
test_warp_connection() {
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        local test_result=$(curl -s --socks5 127.0.0.1:40000 --max-time 15 http://ip-api.com/json 2>/dev/null)
        
        if [[ -n "$test_result" ]]; then
            local warp_ip=$(echo "$test_result" | jq -r '.query // "unknown"' 2>/dev/null)
            local warp_country=$(echo "$test_result" | jq -r '.country // "unknown"' 2>/dev/null)
            
            if [[ "$warp_ip" != "unknown" && "$warp_ip" != "null" && "$warp_ip" != "" ]]; then
                blue "WARP IP: $warp_ip ($warp_country)"
                return 0
            fi
        fi
        
        ((retry_count++))
        if [[ $retry_count -lt $max_retries ]]; then
            yellow "连接测试失败，${retry_count}/${max_retries}，重试中..."
            sleep 3
        fi
    done
    
    return 1
}

# 应用fscarmen sing-box配置 - 增强错误处理
apply_fscarmen_singbox_config() {
    log_info "应用fscarmen sing-box配置"
    
    local conf_dir="/etc/sing-box/conf"
    local outbounds_file="$conf_dir/01_outbounds.json"
    local route_file="$conf_dir/03_route.json"
    
    if [[ ! -d "$conf_dir" ]]; then
        red "fscarmen sing-box配置目录不存在"
        return 1
    fi
    
    # 备份配置文件
    [[ -f $outbounds_file ]] && cp $outbounds_file "${outbounds_file}.backup"
    [[ -f $route_file ]] && cp $route_file "${route_file}.backup"
    
    # 1. 添加WARP Socks5出站到 01_outbounds.json
    if [[ -f $outbounds_file ]]; then
        if ! jq empty "$outbounds_file" 2>/dev/null; then
            red "出站配置文件JSON格式错误"
            return 1
        fi
        
        local outbounds=$(cat $outbounds_file)
        
        # 检查是否已存在warp-socks5出站
        if ! echo "$outbounds" | jq -e '.outbounds[]? | select(.tag == "warp-socks5")' > /dev/null 2>&1; then
            # 添加warp-socks5出站
            local new_outbound='{
                "type": "socks",
                "tag": "warp-socks5", 
                "server": "127.0.0.1",
                "server_port": 40000,
                "version": "5"
            }'
            
            local updated_outbounds
            if echo "$outbounds" | jq -e '.outbounds' > /dev/null 2>&1; then
                updated_outbounds=$(echo "$outbounds" | jq --argjson newout "$new_outbound" '.outbounds += [$newout]')
            else
                updated_outbounds='{"outbounds": ['"$new_outbound"']}'
            fi
            
            echo "$updated_outbounds" > $outbounds_file
            green "已添加WARP Socks5出站配置"
        else
            green "WARP Socks5出站配置已存在"
        fi
    else
        # 创建新的出站配置文件
        cat > $outbounds_file <<EOF
{
    "outbounds": [
        {
            "type": "socks",
            "tag": "warp-socks5",
            "server": "127.0.0.1",
            "server_port": 40000,
            "version": "5"
        }
    ]
}
EOF
        green "已创建WARP Socks5出站配置"
    fi
    
    # 2. 修改路由规则 03_route.json
    if [[ -f $route_file ]]; then
        if ! jq empty "$route_file" 2>/dev/null; then
            red "路由配置文件JSON格式错误"
            return 1
        fi
        
        local routes=$(cat $route_file)
        local warp_domains=$(cat $CONFIG_DIR/warp-domains.json)
        
        # 根据sing-box版本创建规则
        local singbox_version=""
        if command -v sing-box &> /dev/null; then
            singbox_version=$(sing-box version 2>/dev/null | grep -oP 'sing-box version \K[0-9.]+' | head -1)
        fi
        
        if [[ -n "$singbox_version" ]] && version_compare "$singbox_version" "1.8.0"; then
            # 新版本配置
            local warp_rule='{
                "domain_suffix": '"$warp_domains"',
                "outbound": "warp-socks5"
            }'
            
            local warp_keyword_rule='{
                "domain_keyword": ["openai", "anthropic", "claude", "chatgpt", "bard", "perplexity"],
                "outbound": "warp-socks5"
            }'
            
            local updated_routes=$(echo "$routes" | jq --argjson warprule "$warp_rule" --argjson warpkeyword "$warp_keyword_rule" '
                if .route and .route.rules then
                    .route.rules = [$warprule, $warpkeyword] + (.route.rules | map(select(.outbound != "warp-socks5")))
                elif .rules then  
                    .rules = [$warprule, $warpkeyword] + (.rules | map(select(.outbound != "warp-socks5")))
                else
                    .route.rules = [$warprule, $warpkeyword]
                end
            ')
        else
            # 旧版本配置（如果geosite仍然支持）
            local warp_rule='{
                "domain_suffix": '"$warp_domains"',
                "outbound": "warp-socks5"
            }'
            
            local updated_routes=$(echo "$routes" | jq --argjson warprule "$warp_rule" '
                if .route and .route.rules then
                    .route.rules = [$warprule] + (.route.rules | map(select(.outbound != "warp-socks5")))
                elif .rules then  
                    .rules = [$warprule] + (.rules | map(select(.outbound != "warp-socks5")))
                else
                    .route.rules = [$warprule]
                end
            ')
        fi
        
        echo "$updated_routes" > $route_file
        green "已更新路由规则"
    else
        yellow "路由配置文件不存在，创建新文件"
        create_fscarmen_route_config
    fi
    
    # 验证配置并重启服务
    if restart_singbox_service; then
        green "fscarmen sing-box配置应用成功"
    else
        red "配置应用失败，正在恢复备份..."
        restore_singbox_backups
    fi
}

# 恢复sing-box备份
restore_singbox_backups() {
    [[ -f /etc/sing-box/conf/01_outbounds.json.backup ]] && mv /etc/sing-box/conf/01_outbounds.json.backup /etc/sing-box/conf/01_outbounds.json
    [[ -f /etc/sing-box/conf/03_route.json.backup ]] && mv /etc/sing-box/conf/03_route.json.backup /etc/sing-box/conf/03_route.json
    [[ -f /etc/sing-box/config.json.backup ]] && mv /etc/sing-box/config.json.backup /etc/sing-box/config.json
    
    systemctl restart sing-box
    yellow "已恢复sing-box配置备份"
}

# 创建WireGuard服务作为备用方案
create_wireguard_service() {
    log_info "创建WireGuard服务作为备用方案"
    
    # 转换配置为WireGuard格式
    convert_to_wireguard_config
    
    cat > /etc/systemd/system/warp-socks5.service <<EOF
[Unit]
Description=WARP WireGuard Interface
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/wg-quick up wg0
ExecStop=/usr/bin/wg-quick down wg0
ExecStartPre=/bin/sleep 3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-socks5
    green "WireGuard备用服务已创建"
}

# 转换为WireGuard配置
convert_to_wireguard_config() {
    if [[ -f $WARP_CONFIG ]]; then
        # 提取必要信息并创建标准WireGuard配置
        cp $WARP_CONFIG /etc/wireguard/wg0.conf
        
        # 移除Socks5配置段
        sed -i '/\[Socks5\]/,$d' /etc/wireguard/wg0.conf
        
        green "已转换为WireGuard配置格式"
    fi
}systemctl daemon-reload
    systemctl enable warp-socks5
    green "WARP Socks5服务已创建"
}

# 启动WARP服务
start_warp_service() {
    log_info "启动WARP服务"
    
    # 停止可能冲突的服务
    systemctl stop warp-go 2>/dev/null
    systemctl stop wg-quick@warp 2>/dev/null
    
    # 启动我们的服务
    systemctl restart warp-socks5
    sleep 5
    
    if systemctl is-active --quiet warp-socks5; then
        green "WARP Socks5 服务启动成功 (127.0.0.1:40000)"
        
        # 测试连接
        if test_warp_connection; then
            green "WARP连接测试成功"
        else
            yellow "WARP连接测试失败，但服务已启动"
            show_warp_troubleshooting
        fi
    else
        red "WARP服务启动失败"
        log_error "WARP服务启动失败"
        yellow "查看错误日志: journalctl -u warp-socks5 -n 20"
        return 1
    fi
}

# WARP故障排除
show_warp_troubleshooting() {
    yellow "WARP连接故障排除："
    echo "1. 检查服务状态: systemctl status warp-socks5"
    echo "2. 查看服务日志: journalctl -u warp-socks5 -f"
    echo "3. 测试端口监听: netstat -tlnp | grep 40000"
    echo "4. 手动测试连接: curl --socks5 127.0.0.1:40000 ipinfo.io"
}

# 测试WARP连接
test_warp_connection() {
    local test_result=$(curl -s --socks5 127.0.0.1:40000 --max-time 10 http://ip-api.com/json 2>/dev/null)
    
    if [[ -n "$test_result" ]]; then
        local warp_ip=$(echo "$test_result" | jq -r '.query // "unknown"')
        local warp_country=$(echo "$test_result" | jq -r '.country // "unknown"')
        
        if [[ "$warp_ip" != "unknown" && "$warp_ip" != "null" ]]; then
            blue "WARP IP: $warp_ip ($warp_country)"
            return 0
        fi
    fi
    
    return 1
}

# 自动检测并配置
auto_detect_and_configure() {
    clear
    green "=== 自动检测并配置分流 ==="
    echo
    
    # 检查WARP服务
    if ! systemctl is-active --quiet warp-socks5; then
        red "WARP Socks5服务未运行！"
        readp "是否现在安装配置WARP？[Y/n]: " install_warp
        if [[ ! $install_warp =~ [Nn] ]]; then
            install_configure_warp
        else
            return
        fi
    fi
    
    # 检测面板
    if detect_proxy_panels; then
        green "检测到面板类型: $PANEL_TYPE"
        echo
        
        # 配置域名规则
        configure_domain_rules
        
        # 根据面板类型应用配置
        case $PANEL_TYPE in
            "fscarmen_singbox") apply_fscarmen_singbox_config;;
            "standard_singbox") apply_standard_singbox_config;;
            "hiddify") apply_hiddify_config;;
            "xui") apply_xui_config;;
            "mihomo") apply_mihomo_config;;
        esac
        
        green "分流配置完成！"
    else
        yellow "未检测到支持的代理面板"
        echo "请先安装支持的代理面板，然后重新运行此脚本"
    fi
    
    readp "按回车返回菜单..."
}

# 配置域名规则
configure_domain_rules() {
    log_info "配置域名规则"
    
    echo "当前预设WARP域名: ${#DEFAULT_WARP_DOMAINS[@]} 个"
    readp "是否查看预设域名列表？[y/N]: " show_list
    
    if [[ $show_list =~ [Yy] ]]; then
        echo "预设WARP域名："
        for domain in "${DEFAULT_WARP_DOMAINS[@]}"; do
            echo "  • $domain"
        done
        echo
    fi
    
    readp "是否添加自定义WARP域名？[y/N]: " add_custom
    
    local warp_domains=("${DEFAULT_WARP_DOMAINS[@]}")
    
    if [[ $add_custom =~ [Yy] ]]; then
        echo "请输入自定义WARP域名 (用空格分隔，回车确认):"
        read -r custom_input
        if [[ -n "$custom_input" ]]; then
            IFS=' ' read -ra custom_array <<< "$custom_input"
            warp_domains+=("${custom_array[@]}")
            green "已添加 ${#custom_array[@]} 个自定义域名"
        fi
    fi
    
    # 保存域名规则
    save_domain_rules "${warp_domains[@]}"
    
    green "域名规则配置完成 (总计: ${#warp_domains[@]} 个WARP域名)"
}

# 保存域名规则
save_domain_rules() {
    local domains=("$@")
    
    mkdir -p $CONFIG_DIR
    
    # 生成JSON格式的规则
    printf '%s\n' "${domains[@]}" | jq -R . | jq -s . > $CONFIG_DIR/warp-domains.json
    
    # 生成完整的路由规则
    cat > $CONFIG_DIR/routing-rules.json <<EOF
{
    "warp_domains": $(cat $CONFIG_DIR/warp-domains.json),
    "direct_geosite": ["cn", "apple-cn", "google-cn", "category-games@cn"],
    "warp_geosite": ["openai", "anthropic", "google", "github", "telegram", "discord"],
    "updated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    
    log_info "域名规则已保存: ${#domains[@]} 个WARP域名"
}

# 应用fscarmen sing-box配置 (模块化)
apply_fscarmen_singbox_config() {
    log_info "应用fscarmen sing-box配置"
    
    local conf_dir="/etc/sing-box/conf"
    local outbounds_file="$conf_dir/01_outbounds.json"
    local route_file="$conf_dir/03_route.json"
    
    if [[ ! -d "$conf_dir" ]]; then
        red "fscarmen sing-box配置目录不存在"
        return 1
    fi
    
    # 备份配置文件
    [[ -f $outbounds_file ]] && cp $outbounds_file "${outbounds_file}.backup"
    [[ -f $route_file ]] && cp $route_file "${route_file}.backup"
    
    # 1. 添加WARP Socks5出站到 01_outbounds.json
    if [[ -f $outbounds_file ]]; then
        local outbounds=$(cat $outbounds_file)
        
        # 检查是否已存在warp-socks5出站
        if ! echo "$outbounds" | jq -e '.outbounds[] | select(.tag == "warp-socks5")' > /dev/null 2>&1; then
            # 添加warp-socks5出站
            local new_outbound='{
                "type": "socks",
                "tag": "warp-socks5", 
                "server": "127.0.0.1",
                "server_port": 40000,
                "version": "5"
            }'
            
            local updated_outbounds=$(echo "$outbounds" | jq --argjson newout "$new_outbound" '.outbounds += [$newout]')
            echo "$updated_outbounds" > $outbounds_file
            green "已添加WARP Socks5出站配置"
        else
            green "WARP Socks5出站配置已存在"
        fi
    fi
    
    # 2. 修改路由规则 03_route.json
    if [[ -f $route_file ]]; then
        local routes=$(cat $route_file)
        local warp_domains=$(cat $CONFIG_DIR/warp-domains.json)
        
        # 创建WARP域名规则
        local warp_rule='{
            "domain_suffix": '"$warp_domains"',
            "outbound": "warp-socks5"
        }'
        
        # 创建geosite规则
        local warp_geosite_rule='{
            "geosite": ["openai", "anthropic", "google", "github", "telegram", "discord"],
            "outbound": "warp-socks5"
        }'
        
        # 在rules数组开头插入新规则
        local updated_routes=$(echo "$routes" | jq --argjson warprule "$warp_rule" --argjson warpgeo "$warp_geosite_rule" '
            if .route and .route.rules then
                .route.rules = [$warprule, $warpgeo] + (.route.rules | map(select(.outbound != "warp-socks5")))
            elif .rules then  
                .rules = [$warprule, $warpgeo] + (.rules | map(select(.outbound != "warp-socks5")))
            else
                .rules = [$warprule, $warpgeo]
            end
        ')
        
        echo "$updated_routes" > $route_file
        green "已更新路由规则"
    else
        yellow "路由配置文件不存在，创建新文件"
        create_fscarmen_route_config
    fi
    
    # 重启sing-box服务
    restart_singbox_service
}

# 创建fscarmen路由配置 - 修复sing-box 1.8+兼容性
create_fscarmen_route_config() {
    local route_file="/etc/sing-box/conf/03_route.json"
    local warp_domains=$(cat $CONFIG_DIR/warp-domains.json)
    
    # 检测sing-box版本
    local singbox_version=""
    if command -v sing-box &> /dev/null; then
        singbox_version=$(sing-box version 2>/dev/null | grep -oP 'sing-box version \K[0-9.]+' | head -1)
    fi
    
    log_info "检测到sing-box版本: $singbox_version"
    
    # 根据版本生成不同的配置
    if [[ -n "$singbox_version" ]] && version_compare "$singbox_version" "1.8.0"; then
        # sing-box 1.8.0+ 使用新格式
        create_modern_singbox_route_config "$route_file" "$warp_domains"
    else
        # 旧版本使用传统格式
        create_legacy_singbox_route_config "$route_file" "$warp_domains"
    fi
}

# 版本比较函数
version_compare() {
    local version1="$1"
    local version2="$2"
    
    # 简单的版本比较 (适用于major.minor.patch格式)
    local v1_major=$(echo "$version1" | cut -d. -f1)
    local v1_minor=$(echo "$version1" | cut -d. -f2)
    local v2_major=$(echo "$version2" | cut -d. -f1)
    local v2_minor=$(echo "$version2" | cut -d. -f2)
    
    if [[ $v1_major -gt $v2_major ]] || 
       [[ $v1_major -eq $v2_major && $v1_minor -ge $v2_minor ]]; then
        return 0  # version1 >= version2
    else
        return 1  # version1 < version2
    fi
}

# 现代sing-box路由配置 (1.8.0+)
create_modern_singbox_route_config() {
    local route_file="$1"
    local warp_domains="$2"
    
    cat > "$route_file" <<EOF
{
    "route": {
        "auto_detect_interface": true,
        "final": "direct",
        "rules": [
            {
                "protocol": "dns",
                "outbound": "dns-out"
            },
            {
                "port": 53,
                "outbound": "dns-out"
            },
            {
                "protocol": ["quic"],
                "outbound": "block"
            },
            {
                "domain_suffix": $warp_domains,
                "outbound": "warp-socks5"
            },
            {
                "domain_keyword": ["openai", "anthropic", "claude", "chatgpt", "bard", "perplexity"],
                "outbound": "warp-socks5"
            },
            {
                "domain_suffix": [".cn", ".中国", ".中國"],
                "outbound": "direct"
            },
            {
                "domain_keyword": ["baidu", "qq", "taobao", "tmall", "alipay", "wechat", "weixin"],
                "outbound": "direct"
            },
            {
                "ip_cidr": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8"],
                "outbound": "direct"
            }
        ]
    }
}
EOF
    green "已创建现代sing-box路由配置 (兼容1.8.0+)"
}

# 传统sing-box路由配置 (1.8.0以下)
create_legacy_singbox_route_config() {
    local route_file="$1"
    local warp_domains="$2"
    
    cat > "$route_file" <<EOF
{
    "route": {
        "auto_detect_interface": true,
        "final": "direct",
        "rules": [
            {
                "protocol": "dns",
                "outbound": "dns-out"
            },
            {
                "port": 53,
                "outbound": "dns-out"
            },
            {
                "protocol": ["quic"],
                "outbound": "block"
            },
            {
                "domain_suffix": $warp_domains,
                "outbound": "warp-socks5"
            },
            {
                "geosite": ["openai", "anthropic", "google", "github", "telegram", "discord"],
                "outbound": "warp-socks5"
            },
            {
                "geosite": ["cn", "apple-cn", "google-cn", "category-games@cn"],
                "outbound": "direct"
            },
            {
                "geoip": ["cn", "private"],
                "outbound": "direct"
            }
        ]
    }
}
EOF
    green "已创建传统sing-box路由配置"
}

# 应用标准sing-box配置 - 修复新版兼容性
apply_standard_singbox_config() {
    log_info "应用标准sing-box配置"
    
    local config_file="/etc/sing-box/config.json"
    
    if [[ ! -f $config_file ]]; then
        red "sing-box配置文件不存在"
        return 1
    fi
    
    # 备份配置
    cp $config_file "${config_file}.backup"
    
    local current_config=$(cat $config_file)
    local warp_domains=$(cat $CONFIG_DIR/warp-domains.json)
    
    # 检测sing-box版本以确定规则格式
    local singbox_version=""
    if command -v sing-box &> /dev/null; then
        singbox_version=$(sing-box version 2>/dev/null | grep -oP 'sing-box version \K[0-9.]+' | head -1)
    fi
    
    # 添加WARP Socks5出站
    local warp_outbound='{
        "type": "socks",
        "tag": "warp-socks5",
        "server": "127.0.0.1", 
        "server_port": 40000,
        "version": "5"
    }'
    
    # 根据版本创建不同的路由规则
    local warp_domain_rule='{
        "domain_suffix": '"$warp_domains"',
        "outbound": "warp-socks5"
    }'
    
    local updated_config
    if [[ -n "$singbox_version" ]] && version_compare "$singbox_version" "1.8.0"; then
        # sing-box 1.8.0+ 使用关键词匹配替代geosite
        local warp_keyword_rule='{
            "domain_keyword": ["openai", "anthropic", "claude", "chatgpt", "bard", "perplexity", "github", "telegram", "discord", "twitter", "facebook", "youtube"],
            "outbound": "warp-socks5"
        }'
        
        local direct_keyword_rule='{
            "domain_keyword": ["baidu", "qq", "taobao", "tmall", "alipay", "wechat", "weixin"],
            "outbound": "direct"
        }'
        
        local direct_suffix_rule='{
            "domain_suffix": [".cn", ".中国", ".中國"],
            "outbound": "direct"
        }'
        
        local direct_ip_rule='{
            "ip_cidr": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8"],
            "outbound": "direct"
        }'
        
        updated_config=$(echo "$current_config" | jq --argjson warpout "$warp_outbound" --argjson warpdomain "$warp_domain_rule" --argjson warpkeyword "$warp_keyword_rule" --argjson directkeyword "$direct_keyword_rule" --argjson directsuffix "$direct_suffix_rule" --argjson directip "$direct_ip_rule" '
            # 添加出站
            if .outbounds then
                .outbounds = [.outbounds[] | select(.tag != "warp-socks5")] + [$warpout]
            else
                .outbounds = [$warpout]
            end |
            
            # 添加路由规则
            if .route and .route.rules then
                .route.rules = [$warpdomain, $warpkeyword, $directkeyword, $directsuffix, $directip] + (.route.rules | map(select(.outbound != "warp-socks5")))
            elif .route then
                .route.rules = [$warpdomain, $warpkeyword, $directkeyword, $directsuffix, $directip]
            else
                .route = {"rules": [$warpdomain, $warpkeyword, $directkeyword, $directsuffix, $directip], "final": "direct"}
            end
        ')
    else
        # 旧版本使用geosite
        local warp_geosite_rule='{
            "geosite": ["openai", "anthropic", "google", "github", "telegram", "discord"],
            "outbound": "warp-socks5"
        }'
        
        local direct_geosite_rule='{
            "geosite": ["cn", "apple-cn", "google-cn"],
            "outbound": "direct"
        }'
        
        local direct_geoip_rule='{
            "geoip": ["cn", "private"],
            "outbound": "direct"
        }'
        
        updated_config=$(echo "$current_config" | jq --argjson warpout "$warp_outbound" --argjson warpdomain "$warp_domain_rule" --argjson warpgeo "$warp_geosite_rule" --argjson directgeo "$direct_geosite_rule" --argjson directip "$direct_geoip_rule" '
            # 添加出站
            if .outbounds then
                .outbounds = [.outbounds[] | select(.tag != "warp-socks5")] + [$warpout]
            else
                .outbounds = [$warpout]
            end |
            
            # 添加路由规则
            if .route and .route.rules then
                .route.rules = [$warpdomain, $warpgeo, $directgeo, $directip] + (.route.rules | map(select(.outbound != "warp-socks5")))
            elif .route then
                .route.rules = [$warpdomain, $warpgeo, $directgeo, $directip]
            else
                .route = {"rules": [$warpdomain, $warpgeo, $directgeo, $directip], "final": "direct"}
            end
        ')
    fi
    
    echo "$updated_config" > $config_file
    
    # 重启服务
    restart_singbox_service
}

# 应用Hiddify配置
apply_hiddify_config() {
    log_info "生成Hiddify配置"
    
    local warp_domains=$(cat $CONFIG_DIR/warp-domains.json)
    local config_file="$CONFIG_DIR/hiddify-routing.yaml"
    
    cat > $config_file <<EOF
# Hiddify Panel 三通道分流配置
# 请手动将以下配置添加到 Hiddify Panel 中

# 在 "代理" 部分添加WARP Socks5代理:
proxies:
  - name: "WARP-Socks5"
    type: socks5
    server: 127.0.0.1
    port: 40000

# 在 "路由规则" 部分添加以下规则:
rules:
  # WARP代理域名
$(echo "$warp_domains" | jq -r '.[] | "  - DOMAIN-SUFFIX," + . + ",WARP-Socks5"')
  
  # AI服务走WARP  
  - DOMAIN-KEYWORD,openai,WARP-Socks5
  - DOMAIN-KEYWORD,anthropic,WARP-Socks5
  - DOMAIN-KEYWORD,claude,WARP-Socks5
  - DOMAIN-KEYWORD,chatgpt,WARP-Socks5
  - DOMAIN-KEYWORD,bard,WARP-Socks5
  
  # 国内网站直连
  - GEOSITE,cn,DIRECT
  - GEOIP,cn,DIRECT
  - GEOSITE,apple-cn,DIRECT
  - GEOSITE,google-cn,DIRECT
  
  # 本地网络直连
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  
  # 默认规则
  - MATCH,DIRECT
EOF
    
    green "Hiddify配置已生成: $config_file"
    echo
    yellow "请手动应用配置到Hiddify Panel:"
    echo "1. 登录Hiddify Panel管理界面"
    echo "2. 进入 '高级设置' -> '自定义配置'"
    echo "3. 将上述配置添加到相应位置"
    echo "4. 保存并重启服务"
}

# 应用XUI配置
apply_xui_config() {
    log_info "生成XUI配置" 
    
    local warp_domains=$(cat $CONFIG_DIR/warp-domains.json)
    local config_file="$CONFIG_DIR/xui-routing.json"
    
    cat > $config_file <<EOF
{
    "routing": {
        "domainStrategy": "PreferIPv4",
        "rules": [
            {
                "type": "field",
                "protocol": ["quic"],
                "outboundTag": "block"
            },
            {
                "type": "field", 
                "domain": $warp_domains,
                "outboundTag": "warp-socks5"
            },
            {
                "type": "field",
                "domain": ["geosite:openai", "geosite:anthropic", "geosite:google", "geosite:github"],
                "outboundTag": "warp-socks5"
            },
            {
                "type": "field",
                "domain": ["geosite:cn", "geosite:apple-cn", "geosite:google-cn"],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "ip": ["geoip:cn", "geoip:private"],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "network": "tcp,udp",
                "outboundTag": "direct"
            }
        ]
    },
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {},
            "tag": "direct"
        },
        {
            "protocol": "socks",
            "settings": {
                "servers": [
                    {
                        "address": "127.0.0.1",
                        "port": 40000
                    }
                ]
            },
            "tag": "warp-socks5"
        },
        {
            "protocol": "blackhole",
            "settings": {},
            "tag": "block"
        }
    ]
}
EOF
    
    green "XUI配置已生成: $config_file"
    echo
    yellow "请手动应用配置到XUI面板:"
    echo "1. 登录XUI管理界面"
    echo "2. 进入 '入站列表' -> 选择节点 -> '路由规则设置'"
    echo "3. 复制上述JSON配置到路由规则中"
    echo "4. 保存配置"
}

# 应用Mihomo配置
apply_mihomo_config() {
    log_info "应用Mihomo配置"
    
    local config_paths=(
        "/etc/mihomo/config.yaml"
        "/etc/clash/config.yaml" 
        "/opt/clash/config.yaml"
    )
    
    local mihomo_config=""
    for path in "${config_paths[@]}"; do
        if [[ -f "$path" ]]; then
            mihomo_config="$path"
            break
        fi
    done
    
    if [[ -z $mihomo_config ]]; then
        red "未找到Mihomo/Clash配置文件"
        return 1
    fi
    
    # 备份配置
    cp $mihomo_config "${mihomo_config}.backup"
    
    # 生成新配置
    generate_mihomo_config $mihomo_config
    
    # 重启服务
    if systemctl restart mihomo 2>/dev/null || systemctl restart clash 2>/dev/null; then
        green "Mihomo/Clash服务已重启"
    else
        yellow "请手动重启Mihomo/Clash服务"
    fi
}

# 生成Mihomo配置
generate_mihomo_config() {
    local config_file="$1"
    local warp_domains=$(cat $CONFIG_DIR/warp-domains.json)
    
    cat > $config_file <<EOF
# Mihomo/Clash 三通道分流配置
mixed-port: 7890
allow-lan: true
bind-address: '*'
mode: Rule
log-level: info
external-controller: '127.0.0.1:9090'

# 代理配置
proxies:
  - name: "WARP-Socks5"
    type: socks5
    server: 127.0.0.1
    port: 40000

# 代理组
proxy-groups:
  - name: "🚀 手动选择"
    type: select
    proxies:
      - "🌍 WARP代理"
      - "🎯 全球直连"

  - name: "🌍 WARP代理" 
    type: select
    proxies:
      - "WARP-Socks5"

  - name: "🎯 全球直连"
    type: select
    proxies:
      - "DIRECT"

# 路由规则
rules:
  # WARP代理域名
$(echo "$warp_domains" | jq -r '.[] | "  - DOMAIN-SUFFIX," + . + ",🌍 WARP代理"')

  # AI服务走WARP
  - DOMAIN-KEYWORD,openai,🌍 WARP代理
  - DOMAIN-KEYWORD,anthropic,🌍 WARP代理
  - DOMAIN-KEYWORD,claude,🌍 WARP代理
  - DOMAIN-KEYWORD,chatgpt,🌍 WARP代理
  - DOMAIN-KEYWORD,bard,🌍 WARP代理
  - DOMAIN-KEYWORD,perplexity,🌍 WARP代理
  
  # 国内网站直连
  - GEOSITE,CN,🎯 全球直连
  - GEOIP,CN,🎯 全球直连
  - GEOSITE,apple-cn,🎯 全球直连
  - GEOSITE,google-cn,🎯 全球直连
  
  # 本地网络直连
  - IP-CIDR,192.168.0.0/16,🎯 全球直连
  - IP-CIDR,10.0.0.0/8,🎯 全球直连
  - IP-CIDR,172.16.0.0/12,🎯 全球直连
  - IP-CIDR,127.0.0.0/8,🎯 全球直连
  
  # 最终规则 - 其他流量直连
  - MATCH,🎯 全球直连

# DNS配置
dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  fallback:
    - https://1.1.1.1/dns-query
    - https://dns.cloudflare.com/dns-query
  fallback-filter:
    geoip: true
    geoip-code: CN
EOF
}

# 重启sing-box服务
restart_singbox_service() {
    log_info "重启sing-box服务"
    
    # 验证配置文件
    if command -v sing-box &> /dev/null; then
        if ! sing-box check 2>/dev/null; then
            red "sing-box配置验证失败"
            # 恢复备份
            if [[ -f /etc/sing-box/config.json.backup ]]; then
                mv /etc/sing-box/config.json.backup /etc/sing-box/config.json
            fi
            if [[ -f /etc/sing-box/conf/03_route.json.backup ]]; then
                mv /etc/sing-box/conf/03_route.json.backup /etc/sing-box/conf/03_route.json
            fi
            if [[ -f /etc/sing-box/conf/01_outbounds.json.backup ]]; then
                mv /etc/sing-box/conf/01_outbounds.json.backup /etc/sing-box/conf/01_outbounds.json
            fi
            return 1
        fi
    fi
    
    # 重启服务
    systemctl restart sing-box
    sleep 3
    
    if systemctl is-active --quiet sing-box; then
        green "sing-box服务重启成功"
        return 0
    else
        red "sing-box服务重启失败"
        yellow "查看错误: journalctl -u sing-box -n 20"
        return 1
    fi
}

# 添加自定义域名
add_custom_domains() {
    clear
    green "=== 添加自定义WARP域名 ==="
    echo
    
    if [[ ! -f $CONFIG_DIR/warp-domains.json ]]; then
        yellow "域名规则文件不存在，使用默认配置"
        save_domain_rules "${DEFAULT_WARP_DOMAINS[@]}"
    fi
    
    local current_domains=$(cat $CONFIG_DIR/warp-domains.json | jq -r '.[]' | wc -l)
    echo "当前WARP域名数量: $current_domains"
    echo
    
    blue "请输入要添加的域名 (用空格分隔):"
    echo "示例: remove.bg upscale.media waifu2x.udp.jp perplexity.ai you.com"
    echo
    readp "域名列表: " new_domains_input
    
    if [[ -n "$new_domains_input" ]]; then
        # 解析输入的域名
        IFS=' ' read -ra new_domains <<< "$new_domains_input"
        
        # 获取现有域名
        local existing_domains=($(cat $CONFIG_DIR/warp-domains.json | jq -r '.[]'))
        
        # 合并域名（去重）
        local all_domains=("${existing_domains[@]}" "${new_domains[@]}")
        local unique_domains=($(printf '%s\n' "${all_domains[@]}" | sort -u))
        
        # 保存更新的域名列表
        save_domain_rules "${unique_domains[@]}"
        
        green "已添加域名: ${new_domains[*]}"
        green "总域名数量: ${#unique_domains[@]}"
        echo
        
        # 询问是否重新应用配置
        readp "是否重新应用分流配置？[Y/n]: " reapply
        if [[ ! $reapply =~ [Nn] ]]; then
            if detect_proxy_panels; then
                apply_panel_config
            fi
        fi
    else
        yellow "未输入域名"
    fi
    
    readp "按回车返回菜单..."
}

# 应用面板配置
apply_panel_config() {
    case $PANEL_TYPE in
        "fscarmen_singbox") apply_fscarmen_singbox_config;;
        "standard_singbox") apply_standard_singbox_config;;
        "hiddify") apply_hiddify_config;;
        "xui") apply_xui_config;;
        "mihomo") apply_mihomo_config;;
        *) yellow "未知面板类型: $PANEL_TYPE";;
    esac
}

# 显示状态和测试
show_status_and_test() {
    clear
    green "=== 分流状态和测试 ==="
    echo
    
    # WARP服务状态
    blue "WARP Socks5 服务状态:"
    if systemctl is-active --quiet warp-socks5; then
        green "✓ 运行中 (127.0.0.1:40000)"
        
        # 测试WARP连接
        if test_warp_connection; then
            green "✓ WARP连接正常"
        else
            yellow "⚠ WARP连接异常"
        fi
    else
        red "✗ 服务未运行"
        yellow "尝试启动: systemctl start warp-socks5"
    fi
    echo
    
    # 面板状态
    blue "代理面板状态:"
    if detect_proxy_panels; then
        green "✓ 检测到面板: $PANEL_TYPE"
        
        case $PANEL_TYPE in
            "fscarmen_singbox"|"standard_singbox")
                if systemctl is-active --quiet sing-box; then
                    green "✓ sing-box服务运行中"
                else
                    red "✗ sing-box服务未运行"
                fi
                ;;
            "hiddify")
                green "✓ Hiddify Panel (需手动配置)"
                ;;
            "xui")
                if systemctl is-active --quiet x-ui 2>/dev/null || systemctl is-active --quiet 3x-ui 2>/dev/null; then
                    green "✓ XUI服务运行中"
                else
                    yellow "⚠ XUI服务状态未知"
                fi
                ;;
        esac
    else
        red "✗ 未检测到支持的面板"
    fi
    echo
    
    # 域名规则状态
    blue "域名规则状态:"
    if [[ -f $CONFIG_DIR/warp-domains.json ]]; then
        local domain_count=$(cat $CONFIG_DIR/warp-domains.json | jq -r '. | length')
        green "✓ WARP域名: $domain_count 个"
        
        readp "是否查看域名列表？[y/N]: " show_domains
        if [[ $show_domains =~ [Yy] ]]; then
            echo "WARP代理域名列表:"
            cat $CONFIG_DIR/warp-domains.json | jq -r '.[]' | sed 's/^/  • /'
            echo
        fi
    else
        red "✗ 域名规则未配置"
    fi
    
    # 分流测试
    blue "分流效果测试:"
    echo
    
    # 测试VPS直连
    green "VPS直连测试 (baidu.com):"
    local direct_test=$(curl -s --max-time 8 http://ip-api.com/json 2>/dev/null)
    if [[ -n "$direct_test" ]]; then
        local direct_ip=$(echo "$direct_test" | jq -r '.query')
        local direct_country=$(echo "$direct_test" | jq -r '.country')
        echo "  IP: $direct_ip ($direct_country)"
    else
        red "  测试失败"
    fi
    
    # 测试WARP代理
    green "WARP代理测试:"
    local warp_test=$(curl -s --socks5 127.0.0.1:40000 --max-time 8 http://ip-api.com/json 2>/dev/null)
    if [[ -n "$warp_test" ]]; then
        local warp_ip=$(echo "$warp_test" | jq -r '.query')
        local warp_country=$(echo "$warp_test" | jq -r '.country')
        echo "  IP: $warp_ip ($warp_country)"
        
        # 验证IP不同
        if [[ "$direct_ip" != "$warp_ip" ]]; then
            green "✓ 分流配置正常 (IP地址不同)"
        else
            yellow "⚠ IP地址相同，请检查配置"
        fi
    else
        red "  WARP测试失败"
    fi
    
    echo
    readp "按回车返回菜单..."
}

# 管理域名规则
manage_domain_rules() {
    clear
    green "=== 管理域名规则 ==="
    echo
    
    if [[ ! -f $CONFIG_DIR/warp-domains.json ]]; then
        yellow "域名规则文件不存在，创建默认配置"
        save_domain_rules "${DEFAULT_WARP_DOMAINS[@]}"
    fi
    
    echo "1. 查看当前规则"
    echo "2. 添加WARP域名"
    echo "3. 删除域名"
    echo "4. 重置为默认规则"
    echo "5. 导出域名列表"
    echo "6. 导入域名列表"
    echo "0. 返回主菜单"
    echo
    readp "请选择操作 [0-6]: " rule_choice
    
    case $rule_choice in
        1) show_current_domains;;
        2) add_domains_interactive;;
        3) remove_domains;;
        4) reset_default_domains;;
        5) export_domains;;
        6) import_domains;;
        0) return;;
        *) red "无效选择" && sleep 1 && manage_domain_rules;;
    esac
}

# 显示当前域名
show_current_domains() {
    local domains=$(cat $CONFIG_DIR/warp-domains.json | jq -r '.[]')
    local count=$(echo "$domains" | wc -l)
    
    echo
    green "当前WARP代理域名 ($count 个):"
    echo "$domains" | sed 's/^/  • /'
    echo
    readp "按回车继续..."
    manage_domain_rules
}

# 交互式添加域名
add_domains_interactive() {
    echo
    readp "请输入要添加的域名 (用空格分隔): " new_domains_input
    
    if [[ -n "$new_domains_input" ]]; then
        IFS=' ' read -ra new_domains <<< "$new_domains_input"
        
        # 获取现有域名并合并
        local existing_domains=($(cat $CONFIG_DIR/warp-domains.json | jq -r '.[]'))
        local all_domains=("${existing_domains[@]}" "${new_domains[@]}")
        local unique_domains=($(printf '%s\n' "${all_domains[@]}" | sort -u))
        
        save_domain_rules "${unique_domains[@]}"
        green "已添加域名: ${new_domains[*]}"
        
        # 重新应用配置
        readp "是否重新应用配置？[Y/n]: " reapply
        if [[ ! $reapply =~ [Nn] ]]; then
            if detect_proxy_panels; then
                apply_panel_config
            fi
        fi
    fi
    
    readp "按回车继续..."
    manage_domain_rules
}

# 删除域名
remove_domains() {
    echo
    local current_domains=($(cat $CONFIG_DIR/warp-domains.json | jq -r '.[]'))
    
    echo "当前域名列表:"
    for i in "${!current_domains[@]}"; do
        echo "$((i+1)). ${current_domains[i]}"
    done
    echo
    
    readp "请输入要删除的域名编号 (用空格分隔): " remove_indices
    
    if [[ -n "$remove_indices" ]]; then
        local indices_array=($remove_indices)
        local remaining_domains=()
        
        # 构建剩余域名列表
        for i in "${!current_domains[@]}"; do
            local should_remove=false
            for idx in "${indices_array[@]}"; do
                if [[ $((idx-1)) -eq $i ]]; then
                    should_remove=true
                    break
                fi
            done
            
            if [[ $should_remove == false ]]; then
                remaining_domains+=("${current_domains[i]}")
            fi
        done
        
        save_domain_rules "${remaining_domains[@]}"
        green "已删除指定域名"
    fi
    
    readp "按回车继续..."
    manage_domain_rules
}

# 重置默认域名
reset_default_domains() {
    echo
    yellow "此操作将重置为默认域名规则"
    readp "确认重置？[y/N]: " confirm_reset
    
    if [[ $confirm_reset =~ [Yy] ]]; then
        save_domain_rules "${DEFAULT_WARP_DOMAINS[@]}"
        green "已重置为默认域名规则"
        
        readp "是否重新应用配置？[Y/n]: " reapply
        if [[ ! $reapply =~ [Nn] ]]; then
            if detect_proxy_panels; then
                apply_panel_config
            fi
        fi
    fi
    
    readp "按回车继续..."
    manage_domain_rules
}

# 导出域名列表
export_domains() {
    local export_file="/root/warp-domains-$(date +%Y%m%d_%H%M%S).txt"
    
    cat $CONFIG_DIR/warp-domains.json | jq -r '.[]' > $export_file
    green "域名列表已导出到: $export_file"
    
    readp "按回车继续..."
    manage_domain_rules
}

# 导入域名列表
import_domains() {
    echo
    readp "请输入域名文件路径: " import_file
    
    if [[ -f "$import_file" ]]; then
        local imported_domains=()
        while IFS= read -r line; do
            # 清理空行和注释
            line=$(echo "$line" | sed 's/#.*$//' | xargs)
            [[ -n "$line" ]] && imported_domains+=("$line")
        done < "$import_file"
        
        if [[ ${#imported_domains[@]} -gt 0 ]]; then
            save_domain_rules "${imported_domains[@]}"
            green "已导入 ${#imported_domains[@]} 个域名"
        else
            red "文件中没有有效域名"
        fi
    else
        red "文件不存在: $import_file"
    fi
    
    readp "按回车继续..."
    manage_domain_rules
}

# 重启WARP服务
restart_warp_service() {
    clear
    green "=== 重启WARP服务 ==="
    echo
    
    if systemctl is-active --quiet warp-socks5; then
        systemctl restart warp-socks5
        sleep 3
        
        if systemctl is-active --quiet warp-socks5; then
            green "WARP服务重启成功"
            if test_warp_connection; then
                green "WARP连接测试正常"
            fi
        else
            red "WARP服务重启失败"
            yellow "查看日志: journalctl -u warp-socks5 -n 20"
        fi
    else
        yellow "WARP服务未运行，尝试启动..."
        start_warp_service
    fi
    
    readp "按回车返回菜单..."
}

# 查看日志
show_logs() {
    clear
    green "=== 查看日志 ==="
    echo
    
    echo "1. WARP服务日志"
    echo "2. 脚本运行日志"
    echo "3. Sing-box日志"
    echo "4. 实时监控WARP日志"
    echo "0. 返回主菜单"
    echo
    readp "请选择 [0-4]: " log_choice
    
    case $log_choice in
        1)
            echo "WARP服务日志 (最近20条):"
            journalctl -u warp-socks5 -n 20 --no-pager
            ;;
        2)
            if [[ -f $LOG_FILE ]]; then
                echo "脚本运行日志:"
                tail -n 30 $LOG_FILE
            else
                yellow "脚本日志文件不存在"
            fi
            ;;
        3)
            echo "Sing-box服务日志 (最近20条):"
            journalctl -u sing-box -n 20 --no-pager
            ;;
        4)
            echo "实时监控WARP日志 (Ctrl+C退出):"
            journalctl -u warp-socks5 -f
            ;;
        0) return;;
        *) red "无效选择";;
    esac
    
    echo
    readp "按回车返回菜单..."
    show_logs
}

# 卸载所有配置
uninstall_all() {
    clear
    red "=== 卸载所有配置 ==="
    echo
    yellow "此操作将删除:"
    echo "• WARP Socks5 服务和配置"
    echo "• 所有分流规则文件"
    echo "• 恢复面板原始配置"
    echo
    red "警告: 此操作不可逆!"
    echo
    readp "确认卸载？输入 'YES' 继续: " confirm_uninstall
    
    if [[ "$confirm_uninstall" != "YES" ]]; then
        yellow "取消卸载"
        return
    fi
    
    log_info "开始卸载所有配置"
    
    # 停止WARP服务
    if systemctl is-active --quiet warp-socks5; then
        systemctl stop warp-socks5
        green "✓ 停止WARP服务"
    fi
    
    # 禁用并删除服务
    if systemctl is-enabled --quiet warp-socks5 2>/dev/null; then
        systemctl disable warp-socks5
        green "✓ 禁用WARP服务"
    fi
    
    if [[ -f /etc/systemd/system/warp-socks5.service ]]; then
        rm -f /etc/systemd/system/warp-socks5.service
        systemctl daemon-reload
        green "✓ 删除服务文件"
    fi
    
    # 恢复配置备份
    restore_panel_backups
    
    # 删除配置目录
    if [[ -d $CONFIG_DIR ]]; then
        rm -rf $CONFIG_DIR
        green "✓ 删除配置目录"
    fi
    
    # 清理日志
    if [[ -f $LOG_FILE ]]; then
        rm -f $LOG_FILE
        green "✓ 清理日志文件"
    fi
    
    # 询问是否删除warp-go
    if [[ -f /usr/local/bin/warp-go ]] && [[ ! -f /opt/warp-go/warp-go ]]; then
        readp "是否删除warp-go程序？[y/N]: " remove_warp_go
        if [[ $remove_warp_go =~ [Yy] ]]; then
            rm -f /usr/local/bin/warp-go
            green "✓ 删除warp-go程序"
        fi
    fi
    
    green "卸载完成！"
    echo
    readp "按回车返回菜单..."
}

# 恢复面板配置备份
restore_panel_backups() {
    log_info "恢复面板配置备份"
    
    # 恢复sing-box配置
    if [[ -f /etc/sing-box/config.json.backup ]]; then
        mv /etc/sing-box/config.json.backup /etc/sing-box/config.json
        green "✓ 恢复sing-box配置"
        systemctl restart sing-box 2>/dev/null
    fi
    
    # 恢复fscarmen sing-box模块化配置
    if [[ -f /etc/sing-box/conf/01_outbounds.json.backup ]]; then
        mv /etc/sing-box/conf/01_outbounds.json.backup /etc/sing-box/conf/01_outbounds.json
        green "✓ 恢复出站配置"
    fi
    
    if [[ -f /etc/sing-box/conf/03_route.json.backup ]]; then
        mv /etc/sing-box/conf/03_route.json.backup /etc/sing-box/conf/03_route.json
        green "✓ 恢复路由配置"
        systemctl restart sing-box 2>/dev/null
    fi
    
    # 恢复Mihomo配置
    if [[ -f /etc/mihomo/config.yaml.backup ]]; then
        mv /etc/mihomo/config.yaml.backup /etc/mihomo/config.yaml
        green "✓ 恢复Mihomo配置"
        systemctl restart mihomo 2>/dev/null
    fi
    
    if [[ -f /etc/clash/config.yaml.backup ]]; then
        mv /etc/clash/config.yaml.backup /etc/clash/config.yaml
        green "✓ 恢复Clash配置"
        systemctl restart clash 2>/dev/null
    fi
}

# 清理函数
cleanup() {
    # 清理临时文件
    rm -f /tmp/warp-test.json /tmp/singbox-merged.json
    log_info "脚本退出，清理完成"
}

# 网络连通性测试
test_network_connectivity() {
    local test_urls=(
        "https://www.cloudflare.com"
        "https://1.1.1.1"
        "http://ip-api.com"
    )
    
    for url in "${test_urls[@]}"; do
        if curl -s --max-time 5 "$url" > /dev/null 2>&1; then
            return 0
        fi
    done
    
    red "网络连接异常，请检查网络设置"
    return 1
}

# 检查端口占用
check_port_usage() {
    local port="$1"
    
    if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        local pid=$(netstat -tlnp 2>/dev/null | grep ":$port " | awk '{print $7}' | cut -d'/' -f1)
        local process=$(ps -p $pid -o comm= 2>/dev/null)
        yellow "端口 $port 已被占用 (PID: $pid, 进程: $process)"
        return 1
    fi
    return 0
}

# 优化WARP配置
optimize_warp_config() {
    log_info "优化WARP配置"
    
    if [[ ! -f $WARP_CONFIG ]]; then
        red "WARP配置文件不存在"
        return 1
    fi
    
    # 检查并优化MTU
    local current_mtu=$(grep -oP '(?<=MTU = ).*' "$WARP_CONFIG")
    if [[ -z "$current_mtu" || "$current_mtu" -gt 1280 ]]; then
        sed -i 's/MTU = .*/MTU = 1280/' "$WARP_CONFIG"
        green "✓ 优化MTU设置为1280"
    fi
    
    # 添加DNS设置
    if ! grep -q "DNS = " "$WARP_CONFIG"; then
        sed -i '/\[Interface\]/a DNS = 1.1.1.1, 1.0.0.1' "$WARP_CONFIG"
        green "✓ 添加DNS设置"
    fi
    
    green "WARP配置优化完成"
}

# 诊断分流问题
diagnose_routing_issues() {
    clear
    green "=== 分流问题诊断 ==="
    echo
    
    blue "1. 检查WARP服务状态"
    if systemctl is-active --quiet warp-socks5; then
        green "✓ WARP服务运行正常"
    else
        red "✗ WARP服务未运行"
        echo "  解决方案: systemctl start warp-socks5"
    fi
    
    blue "2. 检查端口监听"
    if netstat -tlnp 2>/dev/null | grep -q "127.0.0.1:40000"; then
        green "✓ Socks5端口监听正常"
    else
        red "✗ Socks5端口未监听"
        echo "  解决方案: 检查WARP配置和服务状态"
    fi
    
    blue "3. 检查网络连接"
    if test_network_connectivity; then
        green "✓ 网络连接正常"
    else
        red "✗ 网络连接异常"
        echo "  解决方案: 检查VPS网络设置"
    fi
    
    blue "4. 检查配置文件"
    if [[ -f $CONFIG_DIR/warp-domains.json ]]; then
        green "✓ 域名规则文件存在"
        local domain_count=$(cat $CONFIG_DIR/warp-domains.json | jq -r '. | length')
        echo "  WARP域名数量: $domain_count"
    else
        red "✗ 域名规则文件缺失"
        echo "  解决方案: 重新配置域名规则"
    fi
    
    blue "5. 检查面板状态"
    if detect_proxy_panels; then
        green "✓ 检测到代理面板: $PANEL_TYPE"
        
        case $PANEL_TYPE in
            "fscarmen_singbox"|"standard_singbox")
                if systemctl is-active --quiet sing-box; then
                    green "  sing-box服务运行正常"
                else
                    red "  sing-box服务未运行"
                fi
                ;;
        esac
    else
        red "✗ 未检测到支持的面板"
    fi
    
    echo
    readp "按回车返回菜单..."
}

# 性能监控
performance_monitor() {
    clear
    green "=== 性能监控 ==="
    echo
    
    blue "WARP服务资源占用:"
    if systemctl is-active --quiet warp-socks5; then
        local warp_pid=$(systemctl show --property MainPID --value warp-socks5)
        if [[ "$warp_pid" != "0" ]]; then
            local cpu_usage=$(ps -p $warp_pid -o %cpu --no-headers 2>/dev/null)
            local mem_usage=$(ps -p $warp_pid -o %mem --no-headers 2>/dev/null)
            echo "  CPU使用率: ${cpu_usage}%"
            echo "  内存使用率: ${mem_usage}%"
        fi
    else
        red "WARP服务未运行"
    fi
    
    blue "网络连接统计:"
    local connections=$(netstat -an 2>/dev/null | grep ":40000" | wc -l)
    echo "  Socks5连接数: $connections"
    
    blue "系统负载:"
    local load_avg=$(uptime | awk -F'load average:' '{print $2}')
    echo "  负载平均值:$load_avg"
    
    echo
    readp "按回车返回菜单..."
}

# 高级菜单
advanced_menu() {
    clear
    green "=== 高级功能菜单 ==="
    echo
    echo "1. 诊断分流问题"
    echo "2. 性能监控"
    echo "3. 优化WARP配置"
    echo "4. 备份所有配置"
    echo "5. 恢复配置备份"
    echo "6. 清理临时文件"
    echo "7. 重置网络设置"
    echo "8. 脚本更新"
    echo "0. 返回主菜单"
    echo
    readp "请选择功能 [0-8]: " advanced_choice
    
    case $advanced_choice in
        1) diagnose_routing_issues;;
        2) performance_monitor;;
        3) optimize_warp_config && restart_warp_service;;
        4) backup_all_configs;;
        5) restore_config_backup;;
        6) cleanup_temp_files;;
        7) reset_network_settings;;
        8) update_script;;
        0) return;;
        *) red "无效选择" && sleep 1 && advanced_menu;;
    esac
}

# 备份所有配置
backup_all_configs() {
    local backup_dir="/root/three-channel-routing-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    green "备份配置到: $backup_dir"
    
    # 备份脚本配置
    if [[ -d $CONFIG_DIR ]]; then
        cp -r $CONFIG_DIR "$backup_dir/"
        green "✓ 备份脚本配置"
    fi
    
    # 备份系统服务
    if [[ -f /etc/systemd/system/warp-socks5.service ]]; then
        cp /etc/systemd/system/warp-socks5.service "$backup_dir/"
        green "✓ 备份系统服务"
    fi
    
    # 备份面板配置
    local panel_configs=(
        "/etc/sing-box/config.json"
        "/etc/sing-box/conf/01_outbounds.json"
        "/etc/sing-box/conf/03_route.json"
        "/etc/mihomo/config.yaml"
        "/etc/clash/config.yaml"
    )
    
    for config in "${panel_configs[@]}"; do
        if [[ -f "$config" ]]; then
            local target_dir="$backup_dir/$(dirname "$config")"
            mkdir -p "$target_dir"
            cp "$config" "$target_dir/"
            green "✓ 备份 $(basename "$config")"
        fi
    done
    
    green "配置备份完成!"
    readp "按回车继续..."
}

# 恢复配置备份
restore_config_backup() {
    local backup_base="/root"
    local backups=($(ls -d $backup_base/three-channel-routing-backup-* 2>/dev/null))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        yellow "没有找到配置备份"
        return
    fi
    
    echo "可用的配置备份:"
    for i in "${!backups[@]}"; do
        local backup_date=$(basename "${backups[i]}" | grep -oP '\d{8}_\d{6}')
        echo "$((i+1)). $backup_date"
    done
    echo
    
    readp "请选择要恢复的备份 [1-${#backups[@]}]: " backup_choice
    
    if [[ $backup_choice -ge 1 && $backup_choice -le ${#backups[@]} ]]; then
        local selected_backup="${backups[$((backup_choice-1))]}"
        
        yellow "恢复备份: $(basename "$selected_backup")"
        
        # 恢复配置
        if [[ -d "$selected_backup/three-channel-routing" ]]; then
            rm -rf $CONFIG_DIR
            cp -r "$selected_backup/three-channel-routing" $CONFIG_DIR
            green "✓ 恢复脚本配置"
        fi
        
        # 恢复服务文件
        if [[ -f "$selected_backup/warp-socks5.service" ]]; then
            cp "$selected_backup/warp-socks5.service" /etc/systemd/system/
            systemctl daemon-reload
            green "✓ 恢复系统服务"
        fi
        
        green "配置恢复完成"
    else
        red "无效选择"
    fi
    
    readp "按回车继续..."
}

# 清理临时文件
cleanup_temp_files() {
    green "清理临时文件..."
    
    # 清理系统临时文件
    rm -f /tmp/*warp* /tmp/*routing* /tmp/*sing-box* 2>/dev/null
    
    # 清理日志文件 (保留最近1000行)
    if [[ -f $LOG_FILE ]]; then
        local log_size=$(stat -c%s $LOG_FILE 2>/dev/null)
        if [[ $log_size -gt 1048576 ]]; then  # 1MB
            tail -n 1000 $LOG_FILE > /tmp/routing.log
            mv /tmp/routing.log $LOG_FILE
            green "✓ 清理日志文件"
        fi
    fi
    
    green "临时文件清理完成"
    readp "按回车继续..."
}

# 重置网络设置
reset_network_settings() {
    yellow "此操作将重置DNS设置，是否继续？[y/N]"
    read -r reset_confirm
    
    if [[ ! $reset_confirm =~ [Yy] ]]; then
        return
    fi
    
    green "重置网络设置..."
    
    # 恢复默认DNS
    cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 223.5.5.5
EOF
    
    # 刷新DNS缓存
    if command -v systemd-resolve &> /dev/null; then
        systemd-resolve --flush-caches 2>/dev/null
    fi
    
    green "网络设置已重置"
    readp "按回车继续..."
}

# 脚本更新
update_script() {
    green "检查脚本更新..."
    
    # 下载最新版本
    local temp_script="/tmp/proxy-new.sh"
    if curl -sL "$SCRIPT_URL" -o "$temp_script"; then
        local new_version=$(grep -oP '(?<=VERSION=")[^"]*' "$temp_script")
        
        if [[ "$new_version" != "$VERSION" ]]; then
            yellow "发现新版本: $new_version (当前: $VERSION)"
            readp "是否更新？[Y/n]: " update_confirm
            
            if [[ ! $update_confirm =~ [Nn] ]]; then
                chmod +x "$temp_script"
                cp "$temp_script" "$0"
                green "脚本更新成功，重新启动..."
                exec "$0"
            fi
        else
            green "当前已是最新版本"
        fi
    else
        red "检查更新失败"
    fi
    
    rm -f "$temp_script"
    readp "按回车继续..."
}

# 扩展主菜单
extended_main_menu() {
    echo
    blue "扩展功能:"
    echo "9. 高级功能菜单"
    echo "10. 诊断分流问题"
    echo "11. 性能监控"
    echo "12. 脚本更新"
    echo
    readp "请选择功能 [0-12]: " choice
    
    case $choice in
        9) advanced_menu;;
        10) diagnose_routing_issues;;
        11) performance_monitor;;
        12) update_script;;
        *) 
            # 回到原始主菜单逻辑
            main_menu
            ;;
    esac
}

# 信号处理
trap cleanup EXIT
trap 'red "脚本被中断"; cleanup; exit 1' INT TERM

# 检查系统兼容性
check_system_compatibility() {
    # 检查系统类型
    if [[ ! -f /etc/os-release ]]; then
        red "不支持的系统类型"
        exit 1
    fi
    
    # 检查systemd
    if ! command -v systemctl &> /dev/null; then
        red "系统不支持systemd"
        exit 1
    fi
    
    # 检查网络工具
    if ! command -v curl &> /dev/null; then
        yellow "curl未安装，正在安装..."
        install_dependencies
    fi
}

# 主函数入口
main() {
    # 初始化检查
    check_system_compatibility
    
    # 创建必要目录
    mkdir -p $CONFIG_DIR
    mkdir -p "$(dirname $LOG_FILE)"
    
    # 记录脚本启动
    log_info "三通道域名分流脚本启动 v${VERSION}"
    
    # 处理命令行参数
    case "${1:-}" in
        "install"|"-i") install_configure_warp;;
        "config"|"-c") auto_detect_and_configure;;
        "test"|"-t") show_status_and_test;;
        "uninstall"|"-u") uninstall_all;;
        "update"|"--update") update_script;;
        "help"|"-h"|"--help") 
            show_help
            ;;
        "menu"|"-m"|"") 
            # 默认进入交互菜单
            while true; do
                main_menu
            done
            ;;
        *)
            red "未知参数: $1"
            echo "使用方法:"
            echo "  $0                    # 进入交互菜单"
            echo "  $0 install           # 安装WARP"
            echo "  $0 config            # 配置分流"
            echo "  $0 test              # 测试状态"
            echo "  $0 help              # 显示帮助"
            exit 1
            ;;
    esac
}

# 显示帮助信息
show_help() {
    clear
    green "=== 三通道域名分流脚本帮助 ==="
    echo
    blue "脚本功能:"
    echo "• 自动安装和配置WARP Socks5代理"
    echo "• 智能检测现有WARP安装并复用"
    echo "• 支持多种主流代理面板的分流配置"
    echo "• 提供完整的域名规则管理功能"
    echo
    blue "支持的面板:"
    echo "• Sing-box (标准版和fscarmen模块化版)"
    echo "• Hiddify Panel"
    echo "• X-UI/3X-UI"
    echo "• Mihomo/Clash"
    echo
    blue "兼容的WARP脚本:"
    echo "• fscarmen/warp-sh"
    echo "• yonggekkk/warp-yg"
    echo "• jinwyp/one_click_script"
    echo
    blue "使用说明:"
    echo "1. 首先运行 '安装/配置 WARP Socks5 代理'"
    echo "2. 然后运行 '智能检测现有面板并配置分流'"
    echo "3. 使用 '查看分流状态和测试' 验证配置"
    echo "4. 可随时添加自定义WARP域名"
    echo
    blue "故障排除:"
    echo "• 使用 '诊断分流问题' 功能自动检查"
    echo "• 查看日志了解详细错误信息"
    echo "• 确保VPS网络环境正常"
    echo
    readp "按回车返回菜单..."
}

# 启动脚本
main "$@"
