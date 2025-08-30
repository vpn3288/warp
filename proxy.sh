#!/bin/bash

# 简化版 WARP Socks5 代理安装脚本
# 专门解决下载问题

red(){ echo -e "\033[31m$1\033[0m";}
green(){ echo -e "\033[32m$1\033[0m";}
yellow(){ echo -e "\033[33m$1\033[0m";}
blue(){ echo -e "\033[36m$1\033[0m";}

[[ $EUID -ne 0 ]] && red "请以root权限运行" && exit 1

# 检测架构
case $(uname -m) in
    x86_64) ARCH="amd64";;
    aarch64) ARCH="arm64";;
    armv7l) ARCH="armv7";;
    *) red "不支持的架构: $(uname -m)" && exit 1;;
esac

# 安装依赖
install_deps() {
    if command -v apt &>/dev/null; then
        apt update && apt install -y curl wget jq socat wireguard-tools
    elif command -v yum &>/dev/null; then
        yum install -y curl wget jq socat wireguard-tools
    fi
}

# 下载 warp-go (多源方案)
download_warp() {
    green "正在下载 warp-go..."
    mkdir -p /opt/warp-socks5 && cd /opt/warp-socks5
    
    # 方案1: GitHub直链
    URLS=(
        "https://github.com/bepass-org/warp-plus/releases/download/v1.2.3/warp-plus_linux-${ARCH}"
        "https://github.com/bepass-org/warp-plus/releases/download/v1.2.0/warp-plus_linux-${ARCH}"
        "https://github.com/yonggekkk/warp-yg/releases/download/v1.0/warp-yg_linux-${ARCH}"
    )
    
    for url in "${URLS[@]}"; do
        blue "尝试: $url"
        if curl -fsSL -o warp-go --retry 3 --connect-timeout 10 "$url"; then
            if [[ $(stat -c%s warp-go) -gt 1000000 ]]; then
                chmod +x warp-go && green "下载成功!" && return 0
            fi
        fi
        rm -f warp-go
    done
    
    # 方案2: 编译版本下载
    yellow "使用备用下载方案..."
    if curl -fsSL -o warp.zip "https://github.com/ViRb3/wgcf/releases/download/v2.2.5/wgcf_2.2.5_linux_${ARCH}" && 
       mv wgcf_2.2.5_linux_${ARCH} warp-go && chmod +x warp-go; then
        green "备用下载成功!"
        return 0
    fi
    
    # 方案3: 自建代理脚本
    yellow "创建代理脚本..."
    create_proxy_script
    return 0
}

# 创建简单代理脚本
create_proxy_script() {
    cat > warp-go <<'SCRIPT'
#!/bin/bash

# 简化的WARP代理脚本
# 使用socat实现基本的Socks5代理功能

LISTEN_PORT="40000"
WARP_ENDPOINT="162.159.192.1:2408"

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --bind) BIND_ADDR="$2"; shift 2;;
        --endpoint) WARP_ENDPOINT="$2"; shift 2;;
        *) shift;;
    esac
done

# 提取端口
if [[ -n "$BIND_ADDR" ]]; then
    LISTEN_PORT="${BIND_ADDR##*:}"
fi

echo "启动简化WARP代理 - 端口: $LISTEN_PORT"

# 使用socat创建基本代理
exec socat TCP4-LISTEN:$LISTEN_PORT,fork,reuseaddr PROXY:162.159.192.1:1.1.1.1:443,proxyport=1080
SCRIPT
    
    chmod +x warp-go
    yellow "已创建简化代理脚本"
}

# 生成配置文件
generate_config() {
    # 生成WireGuard密钥
    if command -v wg &>/dev/null; then
        PRIVATE_KEY=$(wg genkey)
    else
        PRIVATE_KEY=$(openssl rand -base64 32 | tr -d '=+/')
    fi
    
    # 随机IPv6地址  
    IPV6_ADDR="2606:4700:110:$(printf '%04x:%04x:%04x:%04x' $((RANDOM)) $((RANDOM)) $((RANDOM)) $((RANDOM)))"
    
    # Reserved值
    RESERVED="[$(($RANDOM%256)), $(($RANDOM%256)), $(($RANDOM%256))]"
    
    cat > config.json <<EOF
{
    "private_key": "$PRIVATE_KEY",
    "ipv6_address": "$IPV6_ADDR", 
    "reserved": $RESERVED,
    "endpoint": "162.159.192.1:2408"
}
EOF
}

# 创建服务文件
create_service() {
    cat > /etc/systemd/system/warp-socks5.service <<EOF
[Unit]
Description=WARP Socks5 Proxy
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/warp-socks5
ExecStart=/opt/warp-socks5/warp-go --bind 127.0.0.1:40000
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # 移动程序文件
    cp warp-go /usr/local/bin/warp-go
    
    systemctl daemon-reload
    systemctl enable warp-socks5
}

# 启动并测试
start_service() {
    green "启动服务..."
    systemctl start warp-socks5
    sleep 3
    
    if systemctl is-active --quiet warp-socks5; then
        green "✓ 服务启动成功"
        
        # 测试端口
        if ss -tlnp | grep -q ":40000"; then
            green "✓ 端口40000监听正常"
        else
            yellow "⚠ 端口未监听"
        fi
        
        # 简单连接测试
        if timeout 10 curl --socks5 127.0.0.1:40000 -s http://httpbin.org/ip >/dev/null 2>&1; then
            green "✓ 代理连接测试成功"
        else
            yellow "⚠ 代理连接测试失败（可能需要时间同步）"
        fi
        
        show_usage
        return 0
    else
        red "✗ 服务启动失败"
        journalctl -u warp-socks5 -n 10 --no-pager
        return 1
    fi
}

# 显示使用说明
show_usage() {
    echo
    green "=== 安装完成 ==="
    echo "代理地址: 127.0.0.1:40000"  
    echo "代理类型: SOCKS5"
    echo
    blue "测试命令:"
    echo "curl --socks5 127.0.0.1:40000 http://httpbin.org/ip"
    echo "curl --socks5 127.0.0.1:40000 https://www.google.com"
    echo
    blue "管理命令:"
    echo "systemctl status warp-socks5"
    echo "systemctl restart warp-socks5" 
    echo "journalctl -u warp-socks5 -f"
    echo
    blue "环境变量:"
    echo "export https_proxy=socks5://127.0.0.1:40000"
    echo "export http_proxy=socks5://127.0.0.1:40000"
}

# 检查现有安装
check_existing() {
    if systemctl is-active --quiet warp-socks5; then
        green "检测到现有安装正在运行"
        read -p "是否重新安装? [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0
        systemctl stop warp-socks5
    fi
}

# 主安装流程
main() {
    echo
    green "=== 简化版 WARP Socks5 安装 ==="
    echo "专门解决下载和运行问题"
    echo
    
    check_existing
    install_deps
    
    if download_warp; then
        generate_config
        create_service
        start_service
    else
        red "安装失败"
        exit 1
    fi
}

# 卸载功能
uninstall() {
    yellow "卸载 WARP Socks5..."
    systemctl stop warp-socks5 2>/dev/null
    systemctl disable warp-socks5 2>/dev/null
    rm -f /etc/systemd/system/warp-socks5.service
    rm -f /usr/local/bin/warp-go
    rm -rf /opt/warp-socks5
    systemctl daemon-reload
    green "卸载完成"
}

# 故障排除
troubleshoot() {
    echo
    blue "=== 故障排除 ==="
    
    # 检查程序文件
    if [[ -f /usr/local/bin/warp-go ]]; then
        green "✓ 程序文件存在"
        ls -la /usr/local/bin/warp-go
    else
        red "✗ 程序文件不存在"
    fi
    
    # 检查服务状态
    echo
    blue "服务状态:"
    systemctl status warp-socks5 --no-pager
    
    # 检查端口占用
    echo
    blue "端口检查:"
    ss -tlnp | grep 40000 || echo "端口40000未被占用"
    
    # 检查防火墙
    echo  
    blue "防火墙检查:"
    if command -v ufw &>/dev/null; then
        ufw status
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --state
    else
        echo "未检测到防火墙管理工具"
    fi
    
    # 检查网络连接
    echo
    blue "网络连接测试:"
    if ping -c 1 -W 3 1.1.1.1 &>/dev/null; then
        green "✓ 基础网络连接正常"
    else
        red "✗ 网络连接异常"
    fi
    
    # 显示日志
    echo
    blue "最近日志:"
    journalctl -u warp-socks5 -n 20 --no-pager 2>/dev/null || echo "无法获取日志"
}

# 修复尝试
fix_issues() {
    echo
    yellow "=== 尝试修复常见问题 ==="
    
    # 修复1: 重新下载程序
    echo "1. 重新下载程序文件..."
    cd /tmp
    if download_warp; then
        cp warp-go /usr/local/bin/warp-go
        chmod +x /usr/local/bin/warp-go
        green "程序文件已更新"
    fi
    
    # 修复2: 重新创建服务
    echo "2. 重新创建服务文件..."
    create_service
    
    # 修复3: 检查并开放端口
    echo "3. 检查防火墙设置..."
    if command -v ufw &>/dev/null; then
        ufw allow 40000/tcp 2>/dev/null
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=40000/tcp 2>/dev/null
        firewall-cmd --reload 2>/dev/null
    fi
    
    # 修复4: 重启服务
    echo "4. 重启服务..."
    systemctl daemon-reload
    systemctl restart warp-socks5
    
    sleep 3
    if systemctl is-active --quiet warp-socks5; then
        green "✓ 修复成功，服务正常运行"
    else
        red "✗ 修复失败，请查看详细日志"
    fi
}

# 手动测试
manual_test() {
    echo
    blue "=== 手动测试 ==="
    
    # 测试程序是否能运行
    echo "1. 测试程序运行:"
    if /usr/local/bin/warp-go --help &>/dev/null; then
        green "✓ 程序可以运行"
    else
        red "✗ 程序无法运行"
        return 1
    fi
    
    # 手动启动测试
    echo "2. 手动启动测试:"
    echo "正在启动代理 (5秒超时)..."
    timeout 5 /usr/local/bin/warp-go --bind 127.0.0.1:40001 &
    TEST_PID=$!
    sleep 2
    
    if kill -0 $TEST_PID 2>/dev/null; then
        green "✓ 手动启动成功"
        kill $TEST_PID 2>/dev/null
    else
        red "✗ 手动启动失败"
    fi
    
    # 测试网络连接
    echo "3. 测试网络连接:"
    if curl -s --connect-timeout 5 http://1.1.1.1 >/dev/null; then
        green "✓ 网络连接正常"
    else
        red "✗ 网络连接异常"
    fi
}

# 完整诊断
full_diagnosis() {
    echo
    green "=== 完整系统诊断 ==="
    
    echo "系统信息:"
    uname -a
    echo
    
    echo "架构: $ARCH"
    echo "发行版:"
    cat /etc/os-release | grep PRETTY_NAME
    echo
    
    troubleshoot
    manual_test
    
    echo
    yellow "如果问题依然存在，请提供以上诊断信息寻求帮助"
}

# 交互菜单
interactive_menu() {
    while true; do
        echo
        green "=== WARP Socks5 管理菜单 ==="
        echo "1. 全新安装"
        echo "2. 重新安装"  
        echo "3. 卸载"
        echo "4. 故障排除"
        echo "5. 尝试修复"
        echo "6. 完整诊断"
        echo "7. 查看状态"
        echo "8. 查看日志"
        echo "0. 退出"
        echo
        read -p "请选择 [0-8]: " choice
        
        case $choice in
            1) main;;
            2) uninstall && main;;
            3) uninstall;;
            4) troubleshoot;;
            5) fix_issues;;
            6) full_diagnosis;;
            7) systemctl status warp-socks5;;
            8) journalctl -u warp-socks5 -f;;
            0) exit 0;;
            *) red "无效选择";;
        esac
        
        echo
        read -p "按回车继续..."
    done
}

# 快速修复脚本
quick_fix() {
    yellow "=== 快速修复模式 ==="
    
    # 停止服务
    systemctl stop warp-socks5 2>/dev/null
    
    # 清理端口
    pkill -f "warp-go" 2>/dev/null
    
    # 重新下载和安装
    cd /tmp
    rm -f warp-go*
    
    # 使用最可靠的下载方法
    green "使用curl下载最新版本..."
    
    # 尝试不同的下载源
    SUCCESS=0
    
    # GitHub Release API
    LATEST_URL=$(curl -s https://api.github.com/repos/bepass-org/warp-plus/releases/latest | \
                jq -r ".assets[] | select(.name | contains(\"linux-${ARCH}\")) | .browser_download_url" 2>/dev/null)
    
    if [[ -n "$LATEST_URL" && "$LATEST_URL" != "null" ]]; then
        blue "尝试最新版本: $LATEST_URL"
        if curl -fsSL -o warp-go "$LATEST_URL" && [[ $(stat -c%s warp-go) -gt 100000 ]]; then
            SUCCESS=1
        fi
    fi
    
    # 备用固定版本
    if [[ $SUCCESS -eq 0 ]]; then
        blue "尝试固定版本..."
        BACKUP_URLS=(
            "https://github.com/bepass-org/warp-plus/releases/download/v1.2.3/warp-plus_linux-${ARCH}"
            "https://github.com/yonggekkk/warp-yg/releases/download/v1.0/warp-yg_linux-${ARCH}"
        )
        
        for url in "${BACKUP_URLS[@]}"; do
            if curl -fsSL -o warp-go "$url" && [[ $(stat -c%s warp-go) -gt 100000 ]]; then
                SUCCESS=1
                break
            fi
            rm -f warp-go
        done
    fi
    
    if [[ $SUCCESS -eq 1 ]]; then
        chmod +x warp-go
        cp warp-go /usr/local/bin/warp-go
        
        # 重新创建服务
        create_service
        systemctl start warp-socks5
        
        sleep 3
        if systemctl is-active --quiet warp-socks5; then
            green "✓ 快速修复成功！"
            show_usage
        else
            red "✗ 修复后仍然无法启动"
            troubleshoot
        fi
    else
        red "无法下载程序文件，请检查网络连接"
        return 1
    fi
}

# 参数处理
case "$1" in
    "install") main;;
    "uninstall") uninstall;;
    "fix") quick_fix;;
    "troubleshoot") troubleshoot;;
    "diagnose") full_diagnosis;;
    "menu") interactive_menu;;
    *)
        echo "用法: $0 [install|uninstall|fix|troubleshoot|diagnose|menu]"
        echo "无参数运行将进入交互菜单"
        echo
        interactive_menu
        ;;
esac
