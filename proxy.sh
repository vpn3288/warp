#!/bin/bash

# 通用代理三通道分流集成脚本
# 支持 Hiddify, 3X-UI, X-UI, Sing-box 等多种代理面板
# 提取自 sing-box-yg 脚本的核心功能

export LANG=en_US.UTF-8

# 颜色定义
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

# 检查权限
[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit

# 系统检测
detect_system() {
    if [[ -f /etc/redhat-release ]]; then
        release="Centos"
    elif cat /etc/issue | grep -q -E -i "debian"; then
        release="Debian"
    elif cat /etc/issue | grep -q -E -i "ubuntu"; then
        release="Ubuntu"
    else 
        red "脚本不支持当前的系统，请选择使用Ubuntu,Debian,Centos系统。" && exit
    fi
    
    case $(uname -m) in
        aarch64) cpu=arm64;;
        x86_64) cpu=amd64;;
        *) red "目前脚本不支持$(uname -m)架构" && exit;;
    esac
}

# 网络环境检测
detect_network() {
    v4=$(curl -s4m5 icanhazip.com -k)
    v6=$(curl -s6m5 icanhazip.com -k)
    
    if [ -z "$v4" ]; then
        echo -e "nameserver 2a00:1098:2b::1\nnameserver 2a00:1098:2c::1\nnameserver 2a01:4f8:c2c:123f::1" > /etc/resolv.conf
        endip="2606:4700:d0::a29f:c101"
        ipv="prefer_ipv6"
    else
        endip="162.159.192.1"
        ipv="prefer_ipv4"
    fi
}

# 安装必要依赖
install_dependencies() {
    green "安装必要依赖包..."
    
    if [ -x "$(command -v apt-get)" ]; then
        apt update -y
        apt install -y curl wget jq socat iptables-persistent coreutils util-linux wireguard-tools
    elif [ -x "$(command -v yum)" ]; then
        yum update -y && yum install epel-release -y
        yum install -y curl wget jq socat coreutils util-linux wireguard-tools
    elif [ -x "$(command -v dnf)" ]; then
        dnf update -y
        dnf install -y curl wget jq socat coreutils util-linux wireguard-tools
    fi
}

# 安装WARP Socks5代理
install_warp_socks5() {
    green "=== 安装 WARP Socks5 代理 ==="
    
    mkdir -p /etc/warp-socks5
    cd /etc/warp-socks5
    
    # 下载warp-go
    blue "下载 warp-go..."
    if [[ $cpu == "amd64" ]]; then
        curl -L -o warp-go https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus_linux-amd64
    else
        curl -L -o warp-go https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus_linux-arm64
    fi
    
    chmod +x warp-go
    mv warp-go /usr/local/bin/
    
    # 生成WireGuard密钥
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)
    
    # 生成IPv6地址
    ipv6_addr=$(printf "2606:4700:110:%04x:%04x:%04x:%04x:%04x\n" $((RANDOM % 65536)) $((RANDOM % 65536)) $((RANDOM % 65536)) $((RANDOM % 65536)))
    
    # 生成reserved值
    reserved="[$(($RANDOM % 256)), $(($RANDOM % 256)), $(($RANDOM % 256))]"
    
    # 保存配置到文件
    echo "$private_key" > /etc/warp-socks5/private.key
    echo "$ipv6_addr" > /etc/warp-socks5/ipv6.addr
    echo "$reserved" > /etc/warp-socks5/reserved.json
    
    # 创建systemd服务
    cat > /etc/systemd/system/warp-socks5.service <<EOF
[Unit]
Description=WARP Socks5 Proxy
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/warp-socks5
ExecStart=/usr/local/bin/warp-go --bind 127.0.0.1:40000 --endpoint $endip:2408
Restart=always
RestartSec=5
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-socks5
    systemctl start warp-socks5
    
    sleep 3
    if systemctl is-active --quiet warp-socks5; then
        green "WARP Socks5 代理安装成功！监听端口: 127.0.0.1:40000"
    else
        red "WARP Socks5 代理启动失败！"
        return 1
    fi
}

# 配置三通道分流
setup_three_channel_routing() {
    green "=== 配置三通道域名分流 ==="
    
    mkdir -p /etc/proxy-routing
    
    # 加载WARP配置
    private_key=$(cat /etc/warp-socks5/private.key 2>/dev/null)
    ipv6_addr=$(cat /etc/warp-socks5/ipv6.addr 2>/dev/null)
    reserved=$(cat /etc/warp-socks5/reserved.json 2>/dev/null)
    
    if [[ -z "$private_key" ]]; then
        red "未找到WARP配置，请先安装WARP Socks5代理"
        return 1
    fi
    
    # 配置域名规则
    configure_domain_rules
    
    # 生成通用路由配置模板
    generate_routing_templates
    
    # 创建自动应用脚本
    create_auto_apply_script
}

# 域名规则配置
configure_domain_rules() {
    blue "配置域名分流规则..."
    
    # 默认直连域名 (通道1)
    default_direct='["cn","com.cn","net.cn","org.cn","gov.cn","edu.cn","mil.cn","ac.cn","baidu.com","qq.com","taobao.com","tmall.com","alipay.com","weixin.com","163.com","sina.com","sohu.com","youku.com","iqiyi.com","bilibili.com"]'
    
    # 默认WARP代理域名 (通道2)  
    default_warp='["openai.com","chatgpt.com","claude.ai","google.com","youtube.com","twitter.com","facebook.com","instagram.com","github.com","stackoverflow.com","reddit.com","discord.com","telegram.org","netflix.com","spotify.com"]'
    
    # 默认Socks5代理域名 (通道3) - 留空，用户自定义
    default_socks5='[]'
    
    readp "是否使用默认域名规则？[Y/n]: " use_default
    
    if [[ $use_default =~ [Nn] ]]; then
        echo "请自定义域名规则 (JSON格式数组):"
        readp "直连域名: " direct_domains
        readp "WARP代理域名: " warp_domains  
        readp "Socks5代理域名: " socks5_domains
        
        [[ -z "$direct_domains" ]] && direct_domains="$default_direct"
        [[ -z "$warp_domains" ]] && warp_domains="$default_warp"
        [[ -z "$socks5_domains" ]] && socks5_domains="$default_socks5"
    else
        direct_domains="$default_direct"
        warp_domains="$default_warp"
        socks5_domains="$default_socks5"
    fi
    
    # 保存域名规则
    echo "$direct_domains" > /etc/proxy-routing/direct_domains.json
    echo "$warp_domains" > /etc/proxy-routing/warp_domains.json  
    echo "$socks5_domains" > /etc/proxy-routing/socks5_domains.json
}

# 生成路由配置模板
generate_routing_templates() {
    blue "生成各面板配置模板..."
    
    # Sing-box 配置模板
    cat > /etc/proxy-routing/singbox-routing.json <<EOF
{
  "route": {
    "rules": [
      {
        "protocol": ["quic", "stun"],
        "outbound": "block"
      },
      {
        "outbound": "warp-IPv4-out",
        "domain_suffix": $warp_domains
      },
      {
        "outbound": "warp-IPv6-out", 
        "domain_suffix": $warp_domains
      },
      {
        "outbound": "socks-IPv4-out",
        "domain_suffix": $socks5_domains
      },
      {
        "outbound": "socks-IPv6-out",
        "domain_suffix": $socks5_domains
      },
      {
        "outbound": "vps-outbound-v4",
        "domain_suffix": $direct_domains
      },
      {
        "outbound": "vps-outbound-v6",
        "domain_suffix": $direct_domains
      },
      {
        "outbound": "direct",
        "network": "udp,tcp"
      }
    ]
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "domain_strategy": "$ipv"
    },
    {
      "type": "direct", 
      "tag": "vps-outbound-v4",
      "domain_strategy": "prefer_ipv4"
    },
    {
      "type": "direct",
      "tag": "vps-outbound-v6", 
      "domain_strategy": "prefer_ipv6"
    },
    {
      "type": "socks",
      "tag": "socks-out",
      "server": "127.0.0.1",
      "server_port": 40000,
      "version": "5"
    },
    {
      "type": "direct",
      "tag": "socks-IPv4-out",
      "detour": "socks-out",
      "domain_strategy": "prefer_ipv4"
    },
    {
      "type": "direct",
      "tag": "socks-IPv6-out",
      "detour": "socks-out",
      "domain_strategy": "prefer_ipv6"
    },
    {
      "type": "direct", 
      "tag": "warp-IPv4-out",
      "detour": "wireguard-out",
      "domain_strategy": "prefer_ipv4"
    },
    {
      "type": "direct",
      "tag": "warp-IPv6-out",
      "detour": "wireguard-out", 
      "domain_strategy": "prefer_ipv6"
    },
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "server": "$endip",
      "server_port": 2408,
      "local_address": [
        "172.16.0.2/32",
        "$ipv6_addr/128"
      ],
      "private_key": "$private_key",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "reserved": $reserved
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF

    # Hiddify Panel 配置模板
    cat > /etc/proxy-routing/hiddify-config.yaml <<EOF
# Hiddify Panel 三通道分流配置
# 复制此配置到 Hiddify Panel 的路由设置中

outbounds:
  - tag: direct
    type: direct
    
  - tag: warp-out
    type: wireguard
    server: $endip
    server_port: 2408
    local_address: ["172.16.0.2/32", "$ipv6_addr/128"]
    private_key: "$private_key"
    peer_public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    reserved: $reserved
    
  - tag: socks5-out
    type: socks
    server: 127.0.0.1
    server_port: 40000
    version: 5
    
  - tag: block
    type: blackhole

route:
  rules:
    # 阻止QUIC和STUN
    - protocol: [quic, stun]
      outbound: block
      
    # WARP代理域名 (通道2)
    - domain_suffix: $warp_domains
      outbound: warp-out
      
    # Socks5代理域名 (通道3)
    - domain_suffix: $socks5_domains
      outbound: socks5-out
      
    # 直连域名 (通道1)  
    - domain_suffix: $direct_domains
      outbound: direct
      
    # 默认直连
    - outbound: direct
EOF

    # X-UI/3X-UI 配置模板
    cat > /etc/proxy-routing/xui-config.json <<EOF
{
  "comment": "X-UI/3X-UI 三通道分流配置",
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "protocol": ["quic", "stun"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": $warp_domains,
        "outboundTag": "warp-out"
      },
      {
        "type": "field",
        "domain": $socks5_domains, 
        "outboundTag": "socks5-out"
      },
      {
        "type": "field",
        "domain": $direct_domains,
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
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "socks5-out",
      "protocol": "socks", 
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40000
          }
        ]
      }
    },
    {
      "tag": "warp-out",
      "protocol": "wireguard",
      "settings": {
        "address": ["172.16.0.2", "$ipv6_addr"],
        "private_key": "$private_key",
        "peers": [
          {
            "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
            "endpoint": "$endip:2408",
            "allowed_ips": ["0.0.0.0/0", "::/0"],
            "reserved": $reserved
          }
        ]
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {}
    }
  ]
}
EOF

    green "配置模板已生成完成！"
}

# 创建自动应用脚本
create_auto_apply_script() {
    cat > /etc/proxy-routing/apply-routing.sh <<'EOF'
#!/bin/bash

# 自动应用三通道分流配置脚本

red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}

# 检测并应用到Sing-box
apply_to_singbox() {
    if [[ -f /etc/s-box/sb.json ]]; then
        green "检测到 Sing-box，应用三通道分流配置..."
        
        # 备份原配置
        cp /etc/s-box/sb.json /etc/s-box/sb.json.backup.$(date +%Y%m%d_%H%M%S)
        
        # 读取当前配置
        current_config=$(cat /etc/s-box/sb.json)
        routing_config=$(cat /etc/proxy-routing/singbox-routing.json)
        
        # 合并配置
        echo "$current_config" | jq --argjson routing "$routing_config" '.route = $routing.route | .outbounds += $routing.outbounds' > /tmp/sb-new.json
        
        # 验证JSON格式
        if jq empty /tmp/sb-new.json 2>/dev/null; then
            mv /tmp/sb-new.json /etc/s-box/sb.json
            systemctl restart sing-box
            
            if systemctl is-active --quiet sing-box; then
                green "Sing-box 三通道分流配置应用成功！"
                return 0
            else
                red "服务启动失败，恢复备份配置"
                mv /etc/s-box/sb.json.backup.$(date +%Y%m%d_%H%M%S) /etc/s-box/sb.json
                systemctl restart sing-box
                return 1
            fi
        else
            red "配置格式错误，未应用更改"
            return 1
        fi
    else
        yellow "未检测到 Sing-box 配置"
        return 1
    fi
}

# 显示面板配置说明
show_panel_configs() {
    echo
    blue "=== 各面板配置说明 ==="
    echo
    
    if [[ -d /opt/hiddify-manager ]] || [[ -f /opt/hiddify-config/hiddify-panel.service ]]; then
        green "检测到 Hiddify Panel"
        echo "配置文件: /etc/proxy-routing/hiddify-config.yaml"
        echo "应用方法: 复制配置到 Hiddify Panel -> 配置 -> 路由设置"
        echo
    fi
    
    if [[ -f /etc/systemd/system/x-ui.service ]] || [[ -f /etc/systemd/system/3x-ui.service ]]; then
        green "检测到 X-UI 面板"
        echo "配置文件: /etc/proxy-routing/xui-config.json"  
        echo "应用方法: 复制配置到 X-UI Panel -> 路由设置 -> JSON配置"
        echo
    fi
    
    green "配置文件位置:"
    echo "• Sing-box: /etc/proxy-routing/singbox-routing.json"
    echo "• Hiddify: /etc/proxy-routing/hiddify-config.yaml"
    echo "• X-UI: /etc/proxy-routing/xui-config.json"
}

# 主菜单
main_menu() {
    echo
    green "=== 三通道分流配置应用 ==="
    echo "1. 自动应用到 Sing-box"
    echo "2. 显示 Hiddify 配置"
    echo "3. 显示 X-UI 配置"  
    echo "4. 显示所有面板配置"
    echo "5. 测试代理连接"
    echo "0. 退出"
    echo
    read -p "请选择 [0-5]: " choice
    
    case $choice in
        1) apply_to_singbox;;
        2) echo; cat /etc/proxy-routing/hiddify-config.yaml;;
        3) echo; cat /etc/proxy-routing/xui-config.json;;
        4) show_panel_configs;;
        5) test_proxy_connections;;
        0) exit 0;;
        *) red "无效选择，请重新输入"; main_menu;;
    esac
    
    echo
    read -p "按回车键继续..." 
    main_menu
}

# 测试代理连接
test_proxy_connections() {
    blue "=== 测试代理连接 ==="
    echo
    
    # 测试直连
    echo -n "测试直连: "
    if curl -s --connect-timeout 5 http://www.baidu.com > /dev/null; then
        green "✓ 直连正常"
    else
        red "✗ 直连失败"
    fi
    
    # 测试WARP
    echo -n "测试WARP: "
    warp_status=$(curl -s --connect-timeout 5 https://www.cloudflare.com/cdn-cgi/trace | grep warp | cut -d= -f2)
    if [[ "$warp_status" =~ on|plus ]]; then
        green "✓ WARP正常 ($warp_status)"
    else
        red "✗ WARP未启用"
    fi
    
    # 测试Socks5代理
    echo -n "测试Socks5代理: "
    if curl -s --connect-timeout 5 --socks5-hostname 127.0.0.1:40000 http://www.google.com > /dev/null; then
        green "✓ Socks5代理正常"
    else
        red "✗ Socks5代理失败"
    fi
}

# 检查WARP服务状态
if ! systemctl is-active --quiet warp-socks5; then
    red "WARP Socks5代理未运行，请先安装！"
    exit 1
fi

main_menu
EOF

    chmod +x /etc/proxy-routing/apply-routing.sh
}

# 管理菜单
management_menu() {
    echo
    green "=== 服务管理 ==="
    echo "1. 启动 WARP Socks5"
    echo "2. 停止 WARP Socks5" 
    echo "3. 重启 WARP Socks5"
    echo "4. 查看 WARP 状态"
    echo "5. 应用分流配置"
    echo "6. 编辑域名规则"
    echo "0. 返回主菜单"
    echo
    readp "请选择 [0-6]: " mgmt_choice
    
    case $mgmt_choice in
        1) systemctl start warp-socks5; green "WARP Socks5 已启动";;
        2) systemctl stop warp-socks5; yellow "WARP Socks5 已停止";;
        3) systemctl restart warp-socks5; green "WARP Socks5 已重启";;
        4) systemctl status warp-socks5;;
        5) bash /etc/proxy-routing/apply-routing.sh;;
        6) edit_domain_rules;;
        0) return;;
        *) red "无效选择"; management_menu;;
    esac
    
    echo
    read -p "按回车键继续..."
    management_menu
}

# 编辑域名规则
edit_domain_rules() {
    echo
    blue "=== 编辑域名分流规则 ==="
    echo "1. 编辑直连域名"
    echo "2. 编辑WARP代理域名"
    echo "3. 编辑Socks5代理域名"
    echo "0. 返回"
    readp "请选择 [0-3]: " edit_choice
    
    case $edit_choice in
        1) 
            echo "当前直连域名:"
            cat /etc/proxy-routing/direct_domains.json
            echo
            readp "输入新的直连域名规则 (JSON格式): " new_direct
            [[ -n "$new_direct" ]] && echo "$new_direct" > /etc/proxy-routing/direct_domains.json
            ;;
        2)
            echo "当前WARP代理域名:"
            cat /etc/proxy-routing/warp_domains.json  
            echo
            readp "输入新的WARP代理域名规则 (JSON格式): " new_warp
            [[ -n "$new_warp" ]] && echo "$new_warp" > /etc/proxy-routing/warp_domains.json
            ;;
        3)
            echo "当前Socks5代理域名:"
            cat /etc/proxy-routing/socks5_domains.json
            echo
            readp "输入新的Socks5代理域名规则 (JSON格式): " new_socks5
            [[ -n "$new_socks5" ]] && echo "$new_socks5" > /etc/proxy-routing/socks5_domains.json
            ;;
        0) return;;
        *) red "无效选择";;
    esac
    
    if [[ $edit_choice =~ [1-3] ]]; then
        green "域名规则已更新，请重新生成配置模板"
        # 重新生成配置
        setup_three_channel_routing
    fi
}

# 主菜单
main_menu() {
    clear
    green "================================================"
    green "    通用代理三通道分流集成脚本"  
    green "    提取自 sing-box-yg 核心功能"
    green "================================================"
    echo
    green "当前系统: $release ($cpu)"
    echo
    
    # 检查WARP状态
    if systemctl is-active --quiet warp-socks5; then
        green "✓ WARP Socks5: 运行中 (127.0.0.1:40000)"
    else
        red "✗ WARP Socks5: 未运行"
    fi
    echo
    
    echo "功能选项:"
    echo "1. 安装 WARP Socks5 代理"
    echo "2. 配置三通道域名分流" 
    echo "3. 一键安装全部功能"
    echo "4. 服务管理"
    echo "5. 应用分流配置"
    echo "6. 卸载全部功能"
    echo "0. 退出脚本"
    echo
    readp "请选择 [0-6]: " choice
    
    case $choice in
        1) 
            detect_system
            detect_network
            install_dependencies
            install_warp_socks5
            ;;
        2)
            if ! systemctl is-active --quiet warp-socks5; then
                red "请先安装 WARP Socks5 代理！"
            else
                setup_three_channel_routing
            fi
            ;;
        3)
            detect_system
            detect_network  
            install_dependencies
            install_warp_socks5 && setup_three_channel_routing
            ;;
        4) management_menu;;
        5) 
            if [[ -f /etc/proxy-routing/apply-routing.sh ]]; then
                bash /etc/proxy-routing/apply-routing.sh
            else
                red "请先配置三通道分流！"
            fi
            ;;
        6) uninstall_all;;
        0) green "感谢使用！"; exit 0;;
        *) red "无效选择，请重新输入";;
    esac
    
    echo
    read -p "按回车键继续..."
    main_menu
}

# 卸载功能
uninstall_all() {
    echo
    yellow "=== 卸载所有功能 ==="
    readp "确认卸载所有功能？[y/N]: " confirm_uninstall
    
    if [[ $confirm_uninstall =~ [Yy] ]]; then
        # 停止服务
        systemctl stop warp-socks5 2>/dev/null
        systemctl disable warp-socks5 2>/dev/null
        
        # 删除服务文件
        rm -f /etc/systemd/system/warp-socks5.service
        systemctl daemon-reload
        
        # 删除程序文件
        rm -f /usr/local/bin/warp-go
        
        # 删除配置目录
        rm -rf /etc/warp-socks5
        rm -rf /etc/proxy-routing
        
        green "卸载完成！"
    else
        yellow "已取消卸载"
    fi
}

# 显示使用说明
show_usage_info() {
    echo
    green "=== 使用说明 ==="
    echo
    blue "三通道分流原理："
    echo "• 通道1 (直连): VPS直接访问，适用于国内网站和未被墙的服务"
    echo "• 通道2 (WARP): 通过Cloudflare WARP访问，适用于被墙的国外网站"
    echo "• 通道3 (Socks5): 通过本地Socks5代理访问，适用于特定区域解锁"
    echo
    blue "支持的面板："
    echo "• Hiddify Panel - 复制YAML配置到路由设置"
    echo "• 3X-UI / X-UI - 复制JSON配置到路由设置"
    echo "• Sing-box - 自动合并配置文件"
    echo "• 其他支持标准路由配置的面板"
    echo
    blue "配置文件位置："
    echo "• WARP配置: /etc/warp-socks5/"
    echo "• 分流配置: /etc/proxy-routing/"
    echo "• 应用脚本: /etc/proxy-routing/apply-routing.sh"
    echo
    blue "管理命令："
    echo "• 查看WARP状态: systemctl status warp-socks5"
    echo "• 重启WARP: systemctl restart warp-socks5"
    echo "• 应用分流: bash /etc/proxy-routing/apply-routing.sh"
    echo "• 编辑域名规则: 编辑 /etc/proxy-routing/*_domains.json"
    echo
    blue "测试命令："
    echo "• 测试直连: curl -I http://www.baidu.com"
    echo "• 测试WARP: curl https://www.cloudflare.com/cdn-cgi/trace"
    echo "• 测试Socks5: curl --socks5 127.0.0.1:40000 -I http://www.google.com"
    echo
    green "更多帮助请查看配置文件中的注释说明"
}

# 检查安装状态
check_installation_status() {
    echo
    blue "=== 安装状态检查 ==="
    echo
    
    # 检查WARP Socks5
    if systemctl is-active --quiet warp-socks5; then
        green "✓ WARP Socks5 代理: 运行正常"
        echo "  监听地址: 127.0.0.1:40000"
        
        # 检查WARP连接状态
        warp_trace=$(curl -s --connect-timeout 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep warp)
        if [[ -n "$warp_trace" ]]; then
            echo "  WARP状态: $(echo $warp_trace | cut -d= -f2)"
        fi
    else
        red "✗ WARP Socks5 代理: 未安装或未运行"
    fi
    
    # 检查分流配置
    if [[ -d /etc/proxy-routing ]]; then
        green "✓ 三通道分流配置: 已生成"
        echo "  配置文件数量: $(ls /etc/proxy-routing/*.json /etc/proxy-routing/*.yaml 2>/dev/null | wc -l)"
    else
        red "✗ 三通道分流配置: 未生成"
    fi
    
    # 检查各面板
    echo
    blue "面板检测结果:"
    
    if [[ -f /etc/s-box/sb.json ]]; then
        if systemctl is-active --quiet sing-box; then
            green "✓ Sing-box: 运行中"
        else
            yellow "⚠ Sing-box: 已安装但未运行"
        fi
    fi
    
    if [[ -d /opt/hiddify-manager ]] || [[ -f /opt/hiddify-config/hiddify-panel.service ]]; then
        green "✓ Hiddify Panel: 已检测到"
    fi
    
    if [[ -f /etc/systemd/system/x-ui.service ]] || [[ -f /etc/systemd/system/3x-ui.service ]]; then
        green "✓ X-UI Panel: 已检测到"
    fi
}

# 添加快捷命令
create_shortcuts() {
    # 创建快捷命令脚本
    cat > /usr/local/bin/proxy-routing <<'EOF'
#!/bin/bash
bash /etc/proxy-routing/apply-routing.sh "$@"
EOF
    chmod +x /usr/local/bin/proxy-routing
    
    # 创建主脚本快捷命令
    cat > /usr/local/bin/three-channel <<'EOF'  
#!/bin/bash
bash <(curl -fsSL https://raw.githubusercontent.com/your-repo/three-channel-routing/main/install.sh) "$@"
EOF
    chmod +x /usr/local/bin/three-channel
    
    green "快捷命令已创建:"
    echo "• proxy-routing - 应用分流配置"
    echo "• three-channel - 运行主脚本"
}

# 备份和还原功能
backup_config() {
    backup_dir="/root/proxy-routing-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # 备份配置文件
    [[ -d /etc/warp-socks5 ]] && cp -r /etc/warp-socks5 "$backup_dir/"
    [[ -d /etc/proxy-routing ]] && cp -r /etc/proxy-routing "$backup_dir/"
    [[ -f /etc/s-box/sb.json ]] && cp /etc/s-box/sb.json "$backup_dir/singbox-original.json"
    
    # 备份服务文件
    [[ -f /etc/systemd/system/warp-socks5.service ]] && cp /etc/systemd/system/warp-socks5.service "$backup_dir/"
    
    green "配置已备份到: $backup_dir"
    echo "$backup_dir" > /tmp/latest-backup-path
}

restore_config() {
    echo "可用的备份:"
    ls -la /root/proxy-routing-backup-* 2>/dev/null || { red "未找到备份文件"; return 1; }
    echo
    readp "请输入备份目录名称: " backup_path
    
    if [[ -d "$backup_path" ]]; then
        readp "确认从 $backup_path 还原配置？[y/N]: " confirm_restore
        if [[ $confirm_restore =~ [Yy] ]]; then
            # 停止服务
            systemctl stop warp-socks5 2>/dev/null
            
            # 还原配置
            [[ -d "$backup_path/warp-socks5" ]] && cp -r "$backup_path/warp-socks5" /etc/
            [[ -d "$backup_path/proxy-routing" ]] && cp -r "$backup_path/proxy-routing" /etc/
            [[ -f "$backup_path/singbox-original.json" ]] && cp "$backup_path/singbox-original.json" /etc/s-box/sb.json
            [[ -f "$backup_path/warp-socks5.service" ]] && cp "$backup_path/warp-socks5.service" /etc/systemd/system/
            
            systemctl daemon-reload
            systemctl start warp-socks5
            
            green "配置已还原完成"
        fi
    else
        red "备份目录不存在"
    fi
}

# 高级选项菜单
advanced_menu() {
    echo
    green "=== 高级选项 ==="
    echo "1. 备份当前配置"
    echo "2. 还原配置"
    echo "3. 查看安装状态"
    echo "4. 创建快捷命令"
    echo "5. 使用说明"
    echo "6. 更新脚本"
    echo "0. 返回主菜单"
    echo
    readp "请选择 [0-6]: " adv_choice
    
    case $adv_choice in
        1) backup_config;;
        2) restore_config;;
        3) check_installation_status;;
        4) create_shortcuts;;
        5) show_usage_info;;
        6) update_script;;
        0) return;;
        *) red "无效选择"; advanced_menu;;
    esac
    
    echo
    read -p "按回车键继续..."
    advanced_menu
}

# 更新脚本
update_script() {
    green "检查脚本更新..."
    # 这里可以添加从GitHub或其他源更新脚本的逻辑
    yellow "更新功能开发中..."
}

# 初始化和主程序入口
init() {
    # 检查网络连接
    if ! ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
        red "网络连接异常，请检查网络设置"
        exit 1
    fi
    
    # 创建必要目录
    mkdir -p /etc/warp-socks5 /etc/proxy-routing /var/log/proxy-routing
    
    # 设置日志
    exec 1> >(tee -a /var/log/proxy-routing/install.log)
    exec 2> >(tee -a /var/log/proxy-routing/error.log)
    
    green "脚本初始化完成"
}

# 脚本入口
main() {
    init
    
    # 如果有参数，直接执行对应功能
    case "$1" in
        "install-warp") 
            detect_system && detect_network && install_dependencies && install_warp_socks5
            ;;
        "install-routing")
            setup_three_channel_routing
            ;;
        "install-all")
            detect_system && detect_network && install_dependencies && install_warp_socks5 && setup_three_channel_routing
            ;;
        "uninstall")
            uninstall_all
            ;;
        "status")
            check_installation_status
            ;;
        *)
            main_menu
            ;;
    esac
}

# 捕获退出信号，清理临时文件
trap 'rm -f /tmp/sb-new.json /tmp/latest-backup-path' EXIT

# 运行主程序
main "$@"
