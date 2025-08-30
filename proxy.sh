#!/bin/bash

# 三通道域名分流脚本
# 支持 Hiddify, Sing-box, 3X-UI, X-UI 等主流代理面板
# 作者: 基于 yonggekkk/sing-box-yg 优化改进

# 颜色定义
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

# 检查root权限
[[ $EUID -ne 0 ]] && red "请以root模式运行脚本" && exit 1

# 创建配置目录
mkdir -p /etc/three-channel-routing
CONFIG_DIR="/etc/three-channel-routing"

# 版本信息
VERSION="1.0.0"
SCRIPT_URL="https://raw.githubusercontent.com/your-repo/three-channel-routing.sh"

# 全局变量
v4=""
v6=""
endip=""
private_key=""
public_key=""
ipv6_addr=""
reserved=""

# 主菜单
main_menu() {
    clear
    green "========================================="
    green "     三通道域名分流管理脚本 v${VERSION}"
    green "========================================="
    echo
    blue "支持的代理面板："
    echo "• Hiddify Panel"
    echo "• Sing-box"
    echo "• 3X-UI / X-UI"
    echo "• Mihomo/Clash"
    echo "• 其他兼容面板"
    echo
    green "功能菜单："
    echo "1. 安装 WARP Socks5 代理"
    echo "2. 配置三通道域名分流"
    echo "3. 应用分流配置到面板"
    echo "4. 查看当前配置状态"
    echo "5. 管理自定义域名规则"
    echo "6. 测试分流效果"
    echo "7. 卸载所有配置"
    echo "0. 退出脚本"
    echo
    readp "请选择功能 [0-7]: " choice
    
    case $choice in
        1) install_warp_socks5;;
        2) configure_three_channel_routing;;
        3) apply_routing_config;;
        4) show_config_status;;
        5) manage_domain_rules;;
        6) test_routing;;
        7) uninstall_all;;
        0) exit 0;;
        *) red "无效选择，请重新输入" && sleep 2 && main_menu;;
    esac
}

# 检测网络环境
detect_network() {
    echo "检测网络环境..."
    v4=$(curl -s4m8 --max-time 8 ip.gs 2>/dev/null)
    v6=$(curl -s6m8 --max-time 8 ip.gs 2>/dev/null)
    
    if [[ -z "$v4" && -n "$v6" ]]; then
        yellow "检测到纯IPv6环境"
        # 设置IPv6 DNS
        echo -e "nameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888" > /etc/resolv.conf
    elif [[ -n "$v4" && -z "$v6" ]]; then
        green "检测到纯IPv4环境"
    elif [[ -n "$v4" && -n "$v6" ]]; then
        green "检测到双栈网络环境"
    else
        red "网络连接异常，请检查网络设置"
        exit 1
    fi
}

# 安装必要依赖
install_dependencies() {
    echo "安装必要依赖..."
    
    if command -v apt &> /dev/null; then
        apt update -q
        apt install -y curl wget jq qrencode openssl
    elif command -v yum &> /dev/null; then
        yum update -q -y
        yum install -y curl wget jq qrencode openssl
    elif command -v dnf &> /dev/null; then
        dnf update -q -y
        dnf install -y curl wget jq qrencode openssl
    else
        red "不支持的系统包管理器"
        exit 1
    fi
    
    # 检查jq是否安装成功
    if ! command -v jq &> /dev/null; then
        yellow "jq安装失败，尝试手动安装..."
        if [[ $(uname -m) == "x86_64" ]]; then
            wget -O /usr/local/bin/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
        else
            wget -O /usr/local/bin/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux32
        fi
        chmod +x /usr/local/bin/jq
    fi
}

# 安装 WARP Socks5 代理
install_warp_socks5() {
    clear
    green "=== 安装 WARP Socks5 代理 ==="
    echo
    
    # 检测现有WARP安装
    detect_existing_warp
    
    if [[ -f /usr/local/bin/warp-go ]] || [[ -f /opt/warp-go/warp-go ]]; then
        yellow "检测到已安装的WARP-GO程序"
        readp "是否使用现有安装并配置Socks5代理？[Y/n]: " use_existing
        if [[ ! $use_existing =~ [Nn] ]]; then
            configure_existing_warp
            return
        fi
    fi
    
    detect_network
    install_dependencies
    
    # 下载warp-go
    download_warp_go
    
    # 生成WARP配置
    generate_warp_config
    
    # 启动WARP服务
    start_warp_service
    
    green "WARP Socks5 代理安装完成！"
    echo "监听地址: 127.0.0.1:40000"
}

# 检测现有WARP安装
detect_existing_warp() {
    yellow "检测现有WARP安装..."
    
    # 检测fscarmen/warp-sh
    if [[ -f /opt/warp-go/warp-go ]] || [[ -d /opt/warp-go ]]; then
        green "检测到 fscarmen/warp-sh 安装"
        EXISTING_WARP_TYPE="fscarmen"
        WARP_BINARY="/opt/warp-go/warp-go"
        WARP_CONFIG="/opt/warp-go/warp.conf"
    fi
    
    # 检测yonggekkk/warp-yg
    if [[ -f /usr/local/bin/warp-go ]] && [[ -d /etc/wireguard ]]; then
        green "检测到 yonggekkk/warp-yg 安装"
        EXISTING_WARP_TYPE="yonggekkk"
        WARP_BINARY="/usr/local/bin/warp-go"
        WARP_CONFIG="/etc/wireguard/warp.conf"
    fi
    
    # 检测jinwyp/one_click_script
    if [[ -f /usr/bin/warp-go ]] || [[ -f /usr/local/bin/warp-go ]]; then
        green "检测到其他WARP-GO安装"
        EXISTING_WARP_TYPE="other"
        WARP_BINARY=$(which warp-go)
    fi
}

# 配置现有WARP
configure_existing_warp() {
    green "配置现有WARP为Socks5代理..."
    
    case $EXISTING_WARP_TYPE in
        "fscarmen")
            configure_fscarmen_warp
            ;;
        "yonggekkk")
            configure_yonggekkk_warp
            ;;
        "other")
            configure_other_warp
            ;;
    esac
    
    # 创建统一的systemd服务
    create_warp_socks5_service
    
    green "现有WARP配置完成！"
}

# 配置fscarmen的warp-sh
configure_fscarmen_warp() {
    if [[ -f /opt/warp-go/warp.conf ]]; then
        # 备份原配置
        cp /opt/warp-go/warp.conf /opt/warp-go/warp.conf.backup
        
        # 添加Socks5配置
        if ! grep -q "socks5" /opt/warp-go/warp.conf; then
            echo "" >> /opt/warp-go/warp.conf
            echo "[Socks5]" >> /opt/warp-go/warp.conf
            echo "BindAddress = 127.0.0.1:40000" >> /opt/warp-go/warp.conf
        fi
        
        # 提取配置信息用于路由
        extract_warp_config_from_file "/opt/warp-go/warp.conf"
    fi
}

# 配置yonggekkk的warp-yg
configure_yonggekkk_warp() {
    if [[ -f /etc/wireguard/warp.conf ]]; then
        cp /etc/wireguard/warp.conf /etc/wireguard/warp.conf.backup
        
        # 生成warp-go配置
        convert_wireguard_to_warp_go "/etc/wireguard/warp.conf"
    fi
}

# 配置其他WARP安装
configure_other_warp() {
    yellow "检测到其他WARP安装，尝试自动配置..."
    
    # 查找配置文件
    for config_path in "/etc/wireguard/warp.conf" "/opt/warp-go/warp.conf" "/usr/local/etc/warp.conf"; do
        if [[ -f "$config_path" ]]; then
            green "找到配置文件: $config_path"
            extract_warp_config_from_file "$config_path"
            break
        fi
    done
}

# 从配置文件提取WARP信息
extract_warp_config_from_file() {
    local config_file="$1"
    
    if [[ -f "$config_file" ]]; then
        private_key=$(grep -oP '(?<=PrivateKey = ).*' "$config_file" | head -1)
        endip=$(grep -oP '(?<=Endpoint = ).*?(?=:)' "$config_file" | head -1)
        reserved=$(grep -oP '(?<=Reserved = ).*' "$config_file" | head -1)
        ipv6_addr=$(grep -oP '(?<=Address = ).*' "$config_file" | grep -oE '([0-9a-f:]+:+)+[0-9a-f]+' | head -1)
        
        if [[ -z "$ipv6_addr" ]]; then
            ipv6_addr="2606:4700:110:8a36:df92:102a:9602:fa18"
        fi
        
        if [[ -z "$reserved" ]]; then
            reserved="[0,0,0]"
        fi
        
        green "提取到WARP配置信息"
    fi
}

# 下载warp-go
download_warp_go() {
    green "下载warp-go程序..."
    
    ARCH=$(uname -m)
    case $ARCH in
        "x86_64") ARCH_SUFFIX="amd64";;
        "aarch64") ARCH_SUFFIX="arm64";;
        "armv7l") ARCH_SUFFIX="armv7";;
        *) red "不支持的架构: $ARCH" && exit 1;;
    esac
    
    # 创建目录
    mkdir -p /usr/local/bin
    
    # 下载最新版本的warp-go
    WARP_GO_URL="https://gitlab.com/ProjectWARP/warp-go/-/releases/permalink/latest/downloads/warp-go_linux_${ARCH_SUFFIX}"
    
    if curl -sL "$WARP_GO_URL" -o /usr/local/bin/warp-go; then
        chmod +x /usr/local/bin/warp-go
        green "warp-go 下载成功"
    else
        red "warp-go 下载失败"
        exit 1
    fi
    
    WARP_BINARY="/usr/local/bin/warp-go"
}

# 生成WARP配置
generate_warp_config() {
    green "生成WARP配置..."
    
    # 创建配置目录
    mkdir -p $CONFIG_DIR
    
    # 获取WARP密钥
    if [[ -z "$private_key" ]]; then
        get_warp_keys
    fi
    
    # 生成warp-go配置文件
    cat > $CONFIG_DIR/warp.conf <<EOF
[Interface]
PrivateKey = $private_key
Address = 172.16.0.2/32
Address = $ipv6_addr/128
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
Endpoint = $endip:2408
Reserved = $reserved

[Socks5]
BindAddress = 127.0.0.1:40000
EOF

    green "WARP配置生成完成"
}

# 获取WARP密钥
get_warp_keys() {
    green "注册WARP账号并获取密钥..."
    
    # 生成密钥对
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)
    
    # 选择WARP端点
    local endpoints=(
        "162.159.193.10"
        "162.159.192.1" 
        "188.114.97.1"
        "188.114.96.1"
    )
    
    endip=${endpoints[$RANDOM % ${#endpoints[@]}]}
    
    # 生成随机IPv6地址
    ipv6_addr="2606:4700:110:$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2)"
    
    # 生成随机reserved
    reserved="[$(shuf -i 0-255 -n 1),$(shuf -i 0-255 -n 1),$(shuf -i 0-255 -n 1)]"
    
    yellow "使用自动生成的配置信息"
}

# 创建WARP Socks5服务
create_warp_socks5_service() {
    green "创建WARP Socks5系统服务..."
    
    cat > /etc/systemd/system/warp-socks5.service <<EOF
[Unit]
Description=WARP Socks5 Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=$WARP_BINARY --config $CONFIG_DIR/warp.conf --bind 127.0.0.1:40000
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-socks5
}

# 启动WARP服务
start_warp_service() {
    green "启动WARP Socks5服务..."
    
    create_warp_socks5_service
    
    systemctl stop warp-socks5 2>/dev/null
    systemctl start warp-socks5
    
    sleep 3
    
    if systemctl is-active --quiet warp-socks5; then
        green "WARP Socks5 服务启动成功"
        green "监听地址: 127.0.0.1:40000"
    else
        red "WARP Socks5 服务启动失败"
        yellow "查看日志: journalctl -u warp-socks5 -f"
        exit 1
    fi
}

# 配置三通道域名分流
configure_three_channel_routing() {
    clear
    green "=== 配置三通道域名分流 ==="
    echo
    
    # 检查WARP Socks5服务
    if ! systemctl is-active --quiet warp-socks5; then
        red "WARP Socks5 服务未运行！"
        readp "是否现在安装WARP Socks5代理？[Y/n]: " install_warp
        if [[ ! $install_warp =~ [Nn] ]]; then
            install_warp_socks5
        else
            return
        fi
    fi
    
    green "WARP Socks5 代理运行正常"
    echo
    
    blue "三通道分流说明："
    echo "• 通道1 (VPS直连): 国内网站、CDN服务、本地服务"
    echo "• 通道2 (WARP代理): 国外网站、AI服务、被墙网站" 
    echo "• 通道3 (Socks5代理): 特殊用途，当前指向WARP"
    echo
    
    # 配置域名规则
    configure_domain_rules
    
    # 生成所有面板配置
    generate_all_panel_configs
    
    green "三通道分流配置生成完成！"
    echo "配置文件位置: $CONFIG_DIR"
    echo
    readp "是否现在应用配置到面板？[Y/n]: " apply_now
    if [[ ! $apply_now =~ [Nn] ]]; then
        apply_routing_config
    fi
}

# 配置域名规则
configure_domain_rules() {
    echo
    blue "=== 配置域名分流规则 ==="
    echo
    
    # 预设的WARP代理域名
    default_warp_domains=(
        "openai.com"
        "chatgpt.com" 
        "claude.ai"
        "anthropic.com"
        "remove.bg"
        "upscale.media"
        "waifu2x.udp.jp"
        "perplexity.ai"
        "you.com"
        "ip125.com"
        "poe.com"
        "character.ai"
        "midjourney.com"
        "stability.ai"
        "huggingface.co"
        "replicate.com"
        "runpod.io"
        "colab.research.google.com"
        "bard.google.com"
        "gemini.google.com"
    )
    
    # 预设的直连域名
    default_direct_domains=(
        "cn"
        "com.cn"
        "net.cn"
        "org.cn"
        "gov.cn"
        "edu.cn"
        "baidu.com"
        "qq.com"
        "taobao.com"
        "tmall.com"
        "jd.com"
        "weibo.com"
        "douyin.com"
        "bilibili.com"
        "zhihu.com"
        "alipay.com"
        "163.com"
        "sina.com.cn"
        "sohu.com"
        "360.cn"
        "tencent.com"
        "alibaba.com"
        "aliyun.com"
    )
    
    green "通道1 - VPS直连域名配置："
    echo "默认包含: 国内网站、CDN域名"
    readp "是否添加自定义直连域名？[y/N]: " add_direct
    
    direct_domains=("${default_direct_domains[@]}")
    
    if [[ $add_direct =~ [Yy] ]]; then
        echo "请输入直连域名，每行一个，输入空行结束："
        while read -r line; do
            [[ -z "$line" ]] && break
            direct_domains+=("$line")
        done
    fi
    
    green "通道2 - WARP代理域名配置："
    echo "默认包含: AI服务、国外主流网站"
    readp "是否添加自定义WARP代理域名？[y/N]: " add_warp
    
    warp_domains=("${default_warp_domains[@]}")
    
    if [[ $add_warp =~ [Yy] ]]; then
        echo "请输入WARP代理域名，每行一个，输入空行结束："
        while read -r line; do
            [[ -z "$line" ]] && break
            warp_domains+=("$line")
        done
    fi
    
    # 保存域名规则到配置文件
    save_domain_rules
    
    green "域名规则配置完成"
    echo "• 直连域名: ${#direct_domains[@]} 个"
    echo "• WARP代理域名: ${#warp_domains[@]} 个"
}

# 保存域名规则
save_domain_rules() {
    # 转换为JSON格式
    local direct_json=$(printf '%s\n' "${direct_domains[@]}" | jq -R . | jq -s .)
    local warp_json=$(printf '%s\n' "${warp_domains[@]}" | jq -R . | jq -s .)
    
    cat > $CONFIG_DIR/domain-rules.json <<EOF
{
    "direct_domains": $direct_json,
    "warp_domains": $warp_json,
    "direct_geosite": ["cn", "apple-cn", "google-cn", "steam@cn", "category-games@cn"],
    "warp_geosite": ["openai", "anthropic", "google", "youtube", "github", "twitter", "facebook", "instagram", "telegram", "discord"],
    "updated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

# 生成所有面板配置
generate_all_panel_configs() {
    blue "=== 生成各面板配置文件 ==="
    
    # 读取域名规则
    if [[ -f $CONFIG_DIR/domain-rules.json ]]; then
        local rules=$(cat $CONFIG_DIR/domain-rules.json)
        local direct_domains_json=$(echo "$rules" | jq -r '.direct_domains')
        local warp_domains_json=$(echo "$rules" | jq -r '.warp_domains')
        local direct_geosite_json=$(echo "$rules" | jq -r '.direct_geosite')
        local warp_geosite_json=$(echo "$rules" | jq -r '.warp_geosite')
    else
        red "域名规则文件不存在"
        return
    fi
    
    # 生成Sing-box配置
    generate_singbox_config
    
    # 生成Hiddify配置
    generate_hiddify_config
    
    # 生成X-UI配置
    generate_xui_config
    
    # 生成Mihomo/Clash配置
    generate_mihomo_config
    
    green "所有面板配置文件生成完成"
}

# 生成Sing-box配置
generate_singbox_config() {
    local config_file="$CONFIG_DIR/singbox-routing.json"
    
    cat > "$config_file" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "route": {
    "auto_detect_interface": true,
    "final": "direct",
    "rules": [
      {
        "type": "logical",
        "mode": "or",
        "rules": [
          {
            "protocol": "dns"
          },
          {
            "port": 53
          }
        ],
        "outbound": "dns-out"
      },
      {
        "protocol": ["quic", "stun"],
        "outbound": "block"
      },
      {
        "domain_suffix": $warp_domains_json,
        "geosite": $warp_geosite_json,
        "outbound": "warp-out"
      },
      {
        "domain_suffix": $direct_domains_json,
        "geosite": $direct_geosite_json,
        "outbound": "direct"
      },
      {
        "geoip": ["cn", "private"],
        "outbound": "direct"
      },
      {
        "outbound": "warp-out"
      }
    ]
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "socks",
      "tag": "warp-out",
      "server": "127.0.0.1",
      "server_port": 40000,
      "version": "5"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "dns": {
    "servers": [
      {
        "tag": "cloudflare",
        "address": "1.1.1.1",
        "detour": "direct"
      },
      {
        "tag": "local",
        "address": "local",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "geosite": ["cn"],
        "server": "local"
      }
    ],
    "final": "cloudflare",
    "strategy": "prefer_ipv4"
  }
}
EOF

    green "生成 Sing-box 配置: $config_file"
}

# 生成Hiddify配置
generate_hiddify_config() {
    local config_file="$CONFIG_DIR/hiddify-routing.yaml"
    
    cat > "$config_file" <<EOF
# Hiddify Panel 三通道分流配置
# 将以下配置添加到 Hiddify Panel 的路由设置中

routing:
  domainStrategy: PreferIPv4
  rules:
    # 阻止QUIC和STUN协议
    - type: field
      protocol: [quic, stun]
      outboundTag: block
    
    # WARP代理域名
    - type: field
      domain:
$(echo "$warp_domains_json" | jq -r '.[] | "        - " + .')
      outboundTag: warp-socks5
    
    # 国外服务geosite规则
    - type: field
      domain_geosite:
$(echo "$warp_geosite_json" | jq -r '.[] | "        - " + .')
      outboundTag: warp-socks5
    
    # 直连域名
    - type: field
      domain:
$(echo "$direct_domains_json" | jq -r '.[] | "        - " + .')
      outboundTag: direct
    
    # 国内geosite规则
    - type: field
      domain_geosite:
$(echo "$direct_geosite_json" | jq -r '.[] | "        - " + .')
      outboundTag: direct
    
    # 国内IP直连
    - type: field
      ip_geoip: [cn, private]
      outboundTag: direct
    
    # 默认规则 - 国外流量走WARP
    - type: field
      network: tcp,udp
      outboundTag: warp-socks5

# 出站配置
outbounds:
  - tag: direct
    protocol: freedom
    
  - tag: warp-socks5
    protocol: socks
    settings:
      servers:
        - address: 127.0.0.1
          port: 40000
          users: []
          
  - tag: block
    protocol: blackhole

# DNS配置
dns:
  hosts:
    "localhost": "127.0.0.1"
  servers:
    - address: "1.1.1.1"
      port: 53
      domains: ["geosite:geolocation-!cn"]
    - address: "223.5.5.5" 
      port: 53
      domains: ["geosite:cn"]
      expectIPs: ["geoip:cn"]
  tag: "dns_inbound"
EOF

    green "生成 Hiddify 配置: $config_file"
}

# 生成X-UI配置
generate_xui_config() {
    local config_file="$CONFIG_DIR/xui-routing.json"
    
    cat > "$config_file" <<EOF
{
  "routing": {
    "domainStrategy": "PreferIPv4",
    "rules": [
      {
        "type": "field",
        "protocol": ["quic", "stun"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": $warp_domains_json,
        "outboundTag": "warp-socks5"
      },
      {
        "type": "field",
        "domain": $direct_domains_json,
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
        "outboundTag": "warp-socks5"
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

    green "生成 X-UI 配置: $config_file"
}

# 生成Mihomo/Clash配置
generate_mihomo_config() {
    local config_file="$CONFIG_DIR/mihomo-routing.yaml"
    
    # 转换域名数组为Clash格式
    local warp_domains_clash=$(echo "$warp_domains_json" | jq -r '.[] | "+." + .' | paste -sd "," -)
    local direct_domains_clash=$(echo "$direct_domains_json" | jq -r '.[] | "+." + .' | paste -sd "," -)
    
    cat > "$config_file" <<EOF
# Mihomo/Clash 三通道分流配置

# 代理组配置
proxy-groups:
  - name: "🚀 手动选择"
    type: select
    proxies:
      - "♻️ 自动选择"
      - "🌍 WARP"
      - "DIRECT"

  - name: "♻️ 自动选择"
    type: url-test
    proxies:
      - "🌍 WARP"
      - "DIRECT"
    url: 'http://www.gstatic.com/generate_204'
    interval: 300

  - name: "🌍 WARP"
    type: select
    proxies:
      - "warp-socks5"

  - name: "🎯 全球直连"
    type: select
    proxies:
      - "DIRECT"

  - name: "🛑 广告拦截"
    type: select
    proxies:
      - "REJECT"

# 代理配置
proxies:
  - name: "warp-socks5"
    type: socks5
    server: 127.0.0.1
    port: 40000

# 规则配置
rules:
  # 阻止QUIC
  - DST-PORT,443,🌍 WARP,no-resolve
  - NETWORK,UDP,🌍 WARP,no-resolve
  
  # WARP代理域名
$(echo "$warp_domains_json" | jq -r '.[] | "  - DOMAIN-SUFFIX," + . + ",🌍 WARP"')
  
  # 直连域名
$(echo "$direct_domains_json" | jq -r '.[] | "  - DOMAIN-SUFFIX," + . + ",🎯 全球直连"')
  
  # 国内网站直连
  - GEOSITE,CN,🎯 全球直连
  - GEOIP,CN,🎯 全球直连
  - GEOSITE,category-games@cn,🎯 全球直连
  
  # 国外网站走WARP
  - GEOSITE,geolocation-!cn,🌍 WARP
  
  # 本地网络直连
  - IP-CIDR,192.168.0.0/16,🎯 全球直连,no-resolve
  - IP-CIDR,10.0.0.0/8,🎯 全球直连,no-resolve
  - IP-CIDR,172.16.0.0/12,🎯 全球直连,no-resolve
  - IP-CIDR,127.0.0.0/8,🎯 全球直连,no-resolve
  
  # 最终规则
  - MATCH,🌍 WARP

# DNS配置
dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - localhost.ptlogin2.qq.com
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

    green "生成 Mihomo/Clash 配置: $config_file"
}

# 应用分流配置到面板
apply_routing_config() {
    clear
    green "=== 应用三通道分流配置 ==="
    echo
    
    # 检测已安装的面板
    detect_installed_panels
    
    echo "检测到的代理面板:"
    local panel_count=0
    
    if [[ $SINGBOX_DETECTED == "true" ]]; then
        echo "$((++panel_count)). Sing-box"
        PANEL_SINGBOX=$panel_count
    fi
    
    if [[ $HIDDIFY_DETECTED == "true" ]]; then
        echo "$((++panel_count)). Hiddify Panel"
        PANEL_HIDDIFY=$panel_count
    fi
    
    if [[ $XUI_DETECTED == "true" ]]; then
        echo "$((++panel_count)). X-UI/3X-UI"
        PANEL_XUI=$panel_count
    fi
    
    if [[ $MIHOMO_DETECTED == "true" ]]; then
        echo "$((++panel_count)). Mihomo/Clash"
        PANEL_MIHOMO=$panel_count
    fi
    
    if [[ $panel_count -eq 0 ]]; then
        yellow "未检测到支持的代理面板"
        echo "支持的面板配置文件已生成到: $CONFIG_DIR"
        echo "请手动应用配置到您的面板"
        return
    fi
    
    echo "$((++panel_count)). 显示所有配置"
    echo "0. 返回主菜单"
    echo
    
    readp "请选择要应用配置的面板 [0-$panel_count]: " panel_choice
    
    case $panel_choice in
        $PANEL_SINGBOX) apply_singbox_config;;
        $PANEL_HIDDIFY) apply_hiddify_config;;
        $PANEL_XUI) apply_xui_config;;
        $PANEL_MIHOMO) apply_mihomo_config;;
        $panel_count) show_all_configs;;
        0) return;;
        *) red "无效选择";;
    esac
}

# 检测已安装的面板
detect_installed_panels() {
    SINGBOX_DETECTED="false"
    HIDDIFY_DETECTED="false"
    XUI_DETECTED="false"
    MIHOMO_DETECTED="false"
    
    # 检测Sing-box
    if [[ -f /etc/sing-box/config.json ]] || [[ -f /usr/local/etc/sing-box/config.json ]] || systemctl list-units --type=service | grep -q sing-box; then
        SINGBOX_DETECTED="true"
        green "✓ 检测到 Sing-box"
    fi
    
    # 检测Hiddify
    if [[ -d /opt/hiddify-manager ]] || [[ -f /opt/hiddify-config/hiddify-panel.json ]]; then
        HIDDIFY_DETECTED="true"
        green "✓ 检测到 Hiddify Panel"
    fi
    
    # 检测X-UI系列
    if systemctl list-units --type=service | grep -E "(x-ui|3x-ui)" || [[ -f /etc/systemd/system/x-ui.service ]] || [[ -f /etc/systemd/system/3x-ui.service ]]; then
        XUI_DETECTED="true"
        green "✓ 检测到 X-UI/3X-UI"
    fi
    
    # 检测Mihomo/Clash
    if [[ -f /etc/mihomo/config.yaml ]] || [[ -f /etc/clash/config.yaml ]] || systemctl list-units --type=service | grep -E "(mihomo|clash)"; then
        MIHOMO_DETECTED="true"
        green "✓ 检测到 Mihomo/Clash"
    fi
}

# 应用Sing-box配置
apply_singbox_config() {
    green "应用Sing-box配置..."
    
    # 查找Sing-box配置文件
    local config_paths=(
        "/etc/sing-box/config.json"
        "/usr/local/etc/sing-box/config.json"
        "/opt/sing-box/config.json"
    )
    
    local singbox_config=""
    for path in "${config_paths[@]}"; do
        if [[ -f "$path" ]]; then
            singbox_config="$path"
            break
        fi
    done
    
    if [[ -z "$singbox_config" ]]; then
        red "未找到Sing-box配置文件"
        return
    fi
    
    green "找到配置文件: $singbox_config"
    
    # 备份原配置
    cp "$singbox_config" "${singbox_config}.backup"
    green "已备份原配置: ${singbox_config}.backup"
    
    # 合并配置
    if jq -s '.[0] * .[1]' "$singbox_config" "$CONFIG_DIR/singbox-routing.json" > "/tmp/singbox-merged.json"; then
        mv "/tmp/singbox-merged.json" "$singbox_config"
        
        # 重启服务
        systemctl restart sing-box
        sleep 2
        
        if systemctl is-active --quiet sing-box; then
            green "✓ Sing-box 配置应用成功！"
        else
            red "✗ 配置应用失败，已恢复备份"
            mv "${singbox_config}.backup" "$singbox_config"
            systemctl restart sing-box
        fi
    else
        red "配置合并失败"
    fi
}

# 应用Hiddify配置
apply_hiddify_config() {
    green "显示Hiddify配置..."
    echo
    yellow "请手动将以下配置添加到 Hiddify Panel 中:"
    echo "路径: Hiddify Panel -> 高级 -> 路由规则"
    echo
    cat "$CONFIG_DIR/hiddify-routing.yaml"
    echo
    readp "按回车继续..." 
}

# 应用X-UI配置
apply_xui_config() {
    green "显示X-UI配置..."
    echo
    yellow "请手动将以下配置添加到 X-UI 面板中:"
    echo "路径: X-UI 面板 -> 入站列表 -> 操作 -> 路由规则设置"
    echo
    cat "$CONFIG_DIR/xui-routing.json"
    echo
    readp "按回车继续..."
}

# 应用Mihomo配置
apply_mihomo_config() {
    green "应用Mihomo/Clash配置..."
    
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
    
    if [[ -n "$mihomo_config" ]]; then
        cp "$mihomo_config" "${mihomo_config}.backup"
        cp "$CONFIG_DIR/mihomo-routing.yaml" "$mihomo_config"
        
        # 重启服务
        if systemctl restart mihomo 2>/dev/null || systemctl restart clash 2>/dev/null; then
            green "✓ Mihomo/Clash 配置应用成功！"
        else
            yellow "请手动重启 Mihomo/Clash 服务"
        fi
    else
        yellow "请手动应用配置:"
        cat "$CONFIG_DIR/mihomo-routing.yaml"
    fi
}

# 显示所有配置
show_all_configs() {
    clear
    green "=== 所有面板配置文件 ==="
    echo
    
    echo "配置文件位置: $CONFIG_DIR"
    echo
    
    for config_file in "$CONFIG_DIR"/*.json "$CONFIG_DIR"/*.yaml; do
        if [[ -f "$config_file" ]]; then
            local filename=$(basename "$config_file")
            blue "==================== $filename ===================="
            cat "$config_file"
            echo
        fi
    done
    
    readp "按回车返回菜单..."
}

# 查看配置状态
show_config_status() {
    clear
    green "=== 当前配置状态 ==="
    echo
    
    # 检查WARP服务状态
    blue "WARP Socks5 代理状态:"
    if systemctl is-active --quiet warp-socks5; then
        green "✓ 运行中 (127.0.0.1:40000)"
        
        # 测试连接
        if curl -s --socks5 127.0.0.1:40000 --max-time 5 http://ip-api.com/json > /tmp/warp-test.json 2>/dev/null; then
            local warp_ip=$(cat /tmp/warp-test.json | jq -r '.query // "unknown"')
            local warp_country=$(cat /tmp/warp-test.json | jq -r '.country // "unknown"')
            green "  WARP IP: $warp_ip ($warp_country)"
            rm -f /tmp/warp-test.json
        else
            yellow "  连接测试失败"
        fi
    else
        red "✗ 未运行"
    fi
    echo
    
    # 检查配置文件
    blue "配置文件状态:"
    if [[ -d $CONFIG_DIR ]]; then
        local config_count=$(ls -1 "$CONFIG_DIR"/*.json "$CONFIG_DIR"/*.yaml 2>/dev/null | wc -l)
        green "✓ 配置目录存在: $CONFIG_DIR"
        green "  配置文件数量: $config_count"
        
        if [[ -f $CONFIG_DIR/domain-rules.json ]]; then
            local rules=$(cat $CONFIG_DIR/domain-rules.json)
            local direct_count=$(echo "$rules" | jq -r '.direct_domains | length')
            local warp_count=$(echo "$rules" | jq -r '.warp_domains | length')
            local updated=$(echo "$rules" | jq -r '.updated')
            
            green "  直连域名: $direct_count 个"
            green "  WARP域名: $warp_count 个"
            green "  更新时间: $updated"
        fi
    else
        red "✗ 配置目录不存在"
    fi
    echo
    
    # 检查面板状态
    blue "代理面板状态:"
    detect_installed_panels
    
    if [[ $SINGBOX_DETECTED == "false" && $HIDDIFY_DETECTED == "false" && $XUI_DETECTED == "false" && $MIHOMO_DETECTED == "false" ]]; then
        yellow "未检测到支持的代理面板"
    fi
    echo
    
    readp "按回车返回菜单..."
}

# 管理自定义域名规则
manage_domain_rules() {
    clear
    green "=== 管理自定义域名规则 ==="
    echo
    
    if [[ ! -f $CONFIG_DIR/domain-rules.json ]]; then
        red "域名规则文件不存在，请先配置三通道分流"
        return
    fi
    
    echo "1. 查看当前规则"
    echo "2. 添加直连域名"
    echo "3. 添加WARP代理域名"
    echo "4. 删除域名规则"
    echo "5. 重置为默认规则"
    echo "0. 返回主菜单"
    echo
    readp "请选择操作 [0-5]: " rule_choice
    
    case $rule_choice in
        1) show_current_rules;;
        2) add_direct_domain;;
        3) add_warp_domain;;
        4) remove_domain_rule;;
        5) reset_default_rules;;
        0) return;;
        *) red "无效选择";;
    esac
}

# 显示当前规则
show_current_rules() {
    local rules=$(cat $CONFIG_DIR/domain-rules.json)
    
    blue "=== 当前域名规则 ==="
    echo
    green "直连域名 (${$(echo "$rules" | jq -r '.direct_domains | length')} 个):"
    echo "$rules" | jq -r '.direct_domains[]' | sed 's/^/  • /'
    echo
    green "WARP代理域名 (${$(echo "$rules" | jq -r '.warp_domains | length')} 个):"
    echo "$rules" | jq -r '.warp_domains[]' | sed 's/^/  • /'
    echo
    readp "按回车继续..."
}

# 添加直连域名
add_direct_domain() {
    echo
    readp "请输入要添加的直连域名: " new_domain
    
    if [[ -z "$new_domain" ]]; then
        red "域名不能为空"
        return
    fi
    
    # 更新规则文件
    local rules=$(cat $CONFIG_DIR/domain-rules.json)
    local updated_rules=$(echo "$rules" | jq --arg domain "$new_domain" '.direct_domains += [$domain] | .updated = now | strftime("%Y-%m-%dT%H:%M:%SZ")')
    
    echo "$updated_rules" > $CONFIG_DIR/domain-rules.json
    green "✓ 已添加直连域名: $new_domain"
    
    readp "是否重新生成配置文件？[Y/n]: " regen
    if [[ ! $regen =~ [Nn] ]]; then
        # 重新读取规则并生成配置
        direct_domains=($(echo "$updated_rules" | jq -r '.direct_domains[]'))
        warp_domains=($(echo "$updated_rules" | jq -r '.warp_domains[]'))
        generate_all_panel_configs
        green "配置文件已更新"
    fi
}

# 添加WARP代理域名
add_warp_domain() {
    echo
    readp "请输入要添加的WARP代理域名: " new_domain
    
    if [[ -z "$new_domain" ]]; then
        red "域名不能为空"
        return
    fi
    
    # 更新规则文件
    local rules=$(cat $CONFIG_DIR/domain-rules.json)
    local updated_rules=$(echo "$rules" | jq --arg domain "$new_domain" '.warp_domains += [$domain] | .updated = now | strftime("%Y-%m-%dT%H:%M:%SZ")')
    
    echo "$updated_rules" > $CONFIG_DIR/domain-rules.json
    green "✓ 已添加WARP代理域名: $new_domain"
    
    readp "是否重新生成配置文件？[Y/n]: " regen
    if [[ ! $regen =~ [Nn] ]]; then
        # 重新读取规则并生成配置
        direct_domains=($(echo "$updated_rules" | jq -r '.direct_domains[]'))
        warp_domains=($(echo "$updated_rules" | jq -r '.warp_domains[]'))
        generate_all_panel_configs
        green "配置文件已更新"
    fi
}

# 测试分流效果
test_routing() {
    clear
    green "=== 测试分流效果 ==="
    echo
    
    # 检查WARP服务
    if ! systemctl is-active --quiet warp-socks5; then
        red "WARP Socks5 服务未运行"
        return
    fi
    
    blue "正在测试网络连接..."
    echo
    
    # 测试本地IP
    green "VPS本地IP测试:"
    local_ip=$(curl -s --max-time 10 ip-api.com/json 2>/dev/null)
    if [[ -n "$local_ip" ]]; then
        echo "  IP: $(echo "$local_ip" | jq -r '.query')"
        echo "  位置: $(echo "$local_ip" | jq -r '.country') - $(echo "$local_ip" | jq -r '.city')"
        echo "  ISP: $(echo "$local_ip" | jq -r '.isp')"
    else
        red "  连接失败"
    fi
    echo
    
    # 测试WARP IP
    green "WARP代理IP测试:"
    warp_ip=$(curl -s --socks5 127.0.0.1:40000 --max-time 10 ip-api.com/json 2>/dev/null)
    if [[ -n "$warp_ip" ]]; then
        echo "  IP: $(echo "$warp_ip" | jq -r '.query')"
        echo "  位置: $(echo "$warp_ip" | jq -r '.country') - $(echo "$warp_ip" | jq -r '.city')"
        echo "  ISP: $(echo "$warp_ip" | jq -r '.isp')"
    else
        red "  连接失败"
    fi
    echo
    
    # 测试特定网站
    blue "特定网站访问测试:"
    
    # 测试ChatGPT
    green "测试 chatgpt.com (应该走WARP):"
    if curl -s --socks5 127.0.0.1:40000 --max-time 10 -I https://chatgpt.com > /dev/null 2>&1; then
        echo "  ✓ 可访问"
    else
        echo "  ✗ 访问失败"
    fi
    
    # 测试百度
    green "测试 baidu.com (应该直连):"
    if curl -s --max-time 10 -I https://baidu.com > /dev/null 2>&1; then
        echo "  ✓ 可访问"
    else
        echo "  ✗ 访问失败"
    fi
    
    echo
    readp "按回车返回菜单..."
}

# 卸载所有配置
uninstall_all() {
    clear
    red "=== 卸载所有配置 ==="
    echo
    yellow "此操作将删除:"
    echo "• WARP Socks5 服务"
    echo "• 所有分流配置文件"
    echo "• 不会影响现有面板配置"
    echo
    readp "确认卸载？[y/N]: " confirm_uninstall
    
    if [[ ! $confirm_uninstall =~ [Yy] ]]; then
        yellow "取消卸载"
        return
    fi
    
    # 停止并删除WARP服务
    if systemctl is-active --quiet warp-socks5; then
        systemctl stop warp-socks5
        green "✓ 停止WARP服务"
    fi
    
    if systemctl is-enabled --quiet warp-socks5 2>/dev/null; then
        systemctl disable warp-socks5
        green "✓ 禁用WARP服务"
    fi
    
    if [[ -f /etc/systemd/system/warp-socks5.service ]]; then
        rm -f /etc/systemd/system/warp-socks5.service
        systemctl daemon-reload
        green "✓ 删除服务文件"
    fi
    
    # 删除配置目录
    if [[ -d $CONFIG_DIR ]]; then
        rm -rf $CONFIG_DIR
        green "✓ 删除配置目录"
    fi
    
    # 删除warp-go程序（如果是我们安装的）
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

# 脚本更新
update_script() {
    green "检查脚本更新..."
    
    local latest_version=$(curl -s "https://api.github.com/repos/your-repo/releases/latest" | jq -r '.tag_name // "unknown"')
    
    if [[ "$latest_version" != "unknown" && "$latest_version" != "$VERSION" ]]; then
        yellow "发现新版本: $latest_version (当前版本: $VERSION)"
        readp "是否更新？[Y/n]: " update_confirm
        
        if [[ ! $update_confirm =~ [Nn] ]]; then
            curl -sL "$SCRIPT_URL" -o /tmp/three-channel-routing-new.sh
            if [[ $? -eq 0 ]]; then
                chmod +x /tmp/three-channel-routing-new.sh
                cp /tmp/three-channel-routing-new.sh "$0"
                green "脚本更新成功，重新启动..."
                exec "$0"
            else
                red "更新失败"
            fi
        fi
    else
        green "当前已是最新版本"
    fi
}

# 显示帮助信息
show_help() {
    clear
    green "=== 三通道域名分流帮助 ==="
    echo
    blue "脚本功能:"
    echo "• 自动安装和配置WARP Socks5代理"
    echo "• 支持多种主流代理面板的分流配置"
    echo "• 智能检测现有WARP安装并复用"
    echo "• 提供域名规则管理功能"
    echo
    blue "分流逻辑:"
    echo "• 通道1 (直连): 国内网站、CDN服务"
    echo "• 通道2 (WARP): 国外网站、AI服务、被墙网站"  
    echo "• 通道3 (备用): 当前指向WARP，可自定义"
    echo
    blue "支持的面板:"
    echo "• Sing-box: 自动合并配置并重启服务"
    echo "• Hiddify Panel: 提供YAML格式配置"
    echo "• X-UI/3X-UI: 提供JSON格式路由规则"
    echo "• Mihomo/Clash: 提供完整配置文件"
    echo
    blue "兼容的WARP脚本:"
    echo "• fscarmen/warp-sh"
    echo "• yonggekkk/warp-yg"  
    echo "• jinwyp/one_click_script"
    echo "• 其他warp-go实现"
    echo
    blue "常见问题:"
    echo "• 如果WARP连接失败，请检查VPS网络环境"
    echo "• 配置应用后需要重启对应的代理服务"
    echo "• 可以随时修改域名规则并重新生成配置"
    echo
    readp "按回车返回菜单..."
}

# 转换WireGuard配置为warp-go格式
convert_wireguard_to_warp_go() {
    local wg_config="$1"
    
    if [[ -f "$wg_config" ]]; then
        # 从WireGuard配置提取信息
        extract_warp_config_from_file "$wg_config"
        
        # 生成warp-go配置
        generate_warp_config
        
        green "已转换WireGuard配置为warp-go格式"
    else
        red "WireGuard配置文件不存在: $wg_config"
    fi
}

# 检查脚本依赖
check_dependencies() {
    local missing_deps=()
    
    # 检查必需命令
    for cmd in curl wget jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        yellow "正在安装缺失的依赖: ${missing_deps[*]}"
        install_dependencies
    fi
}

# 显示欢迎信息
show_welcome() {
    clear
    echo
    green "=================================================================="
    green "           三通道域名分流管理脚本 v${VERSION}"
    green "=================================================================="
    echo
    blue "功能特点:"
    echo "• 🚀 一键安装WARP Socks5代理"
    echo "• 🎯 智能三通道域名分流"
    echo "• 🔧 支持多种主流代理面板"
    echo "• 🔄 兼容现有WARP安装"
    echo "• 📊 实时状态监控和测试"
    echo
    blue "作者: 基于 yonggekkk/sing-box-yg 优化改进"
    blue "项目地址: https://github.com/your-repo/three-channel-routing"
    echo
    green "=================================================================="
    echo
    sleep 2
}

# 清理临时文件
cleanup() {
    rm -f /tmp/warp-test.json
    rm -f /tmp/singbox-merged.json
    rm -f /tmp/three-channel-routing-new.sh
}

# 信号处理
trap cleanup EXIT
trap 'red "脚本被中断"; cleanup; exit 1' INT TERM

# 日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" >> /var/log/three-channel-routing.log
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> /var/log/three-channel-routing.log
}

# 检查系统兼容性
check_system() {
    # 检查系统类型
    if [[ ! -f /etc/os-release ]]; then
        red "不支持的系统类型"
        exit 1
    fi
    
    # 检查架构
    local arch=$(uname -m)
    case $arch in
        x86_64|aarch64|armv7l) 
            green "支持的系统架构: $arch"
            ;;
        *)
            red "不支持的系统架构: $arch"
            exit 1
            ;;
    esac
    
    # 检查systemd
    if ! command -v systemctl &> /dev/null; then
        red "系统不支持systemd"
        exit 1
    fi
}

# 网络连通性测试
test_network_connectivity() {
    local test_urls=(
        "https://www.cloudflare.com"
        "https://1.1.1.1"
        "https://www.google.com"
    )
    
    for url in "${test_urls[@]}"; do
        if curl -s --max-time 5 "$url" > /dev/null 2>&1; then
            return 0
        fi
    done
    
    red "网络连接异常，请检查网络设置"
    return 1
}

# 创建配置备份
backup_config() {
    local config_file="$1"
    local backup_dir="/root/three-channel-routing-backups"
    
    if [[ -f "$config_file" ]]; then
        mkdir -p "$backup_dir"
        local backup_name="$(basename "$config_file").$(date +%Y%m%d_%H%M%S).backup"
        cp "$config_file" "$backup_dir/$backup_name"
        green "已备份配置: $backup_dir/$backup_name"
    fi
}

# 恢复配置备份
restore_config() {
    local backup_dir="/root/three-channel-routing-backups"
    
    if [[ ! -d "$backup_dir" ]]; then
        yellow "没有找到备份目录"
        return
    fi
    
    echo "可用的配置备份:"
    local backups=($(ls -1 "$backup_dir"/*.backup 2>/dev/null))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        yellow "没有找到配置备份"
        return
    fi
    
    for i in "${!backups[@]}"; do
        echo "$((i+1)). $(basename "${backups[i]}")"
    done
    
    readp "请选择要恢复的备份 [1-${#backups[@]}]: " backup_choice
    
    if [[ $backup_choice -ge 1 && $backup_choice -le ${#backups[@]} ]]; then
        local selected_backup="${backups[$((backup_choice-1))]}"
        local config_name=$(echo "$(basename "$selected_backup")" | sed 's/\.[0-9_]*\.backup$//')
        
        # 根据配置名称确定目标路径
        case $config_name in
            "config.json") local target="/etc/sing-box/config.json";;
            "sb.json") local target="/etc/s-box/sb.json";;
            *) readp "请输入目标路径: " target;;
        esac
        
        if [[ -n "$target" ]]; then
            cp "$selected_backup" "$target"
            green "配置已恢复到: $target"
        fi
    else
        red "无效选择"
    fi
}

# 高级菜单
advanced_menu() {
    clear
    green "=== 高级功能菜单 ==="
    echo
    echo "1. 备份当前配置"
    echo "2. 恢复配置备份"
    echo "3. 查看运行日志"
    echo "4. 清理临时文件"
    echo "5. 重置网络设置"
    echo "6. 导出配置文件"
    echo "7. 导入配置文件"
    echo "8. 性能优化"
    echo "0. 返回主菜单"
    echo
    readp "请选择功能 [0-8]: " advanced_choice
    
    case $advanced_choice in
        1) backup_current_configs;;
        2) restore_config;;
        3) show_logs;;
        4) cleanup_temp_files;;
        5) reset_network_settings;;
        6) export_configs;;
        7) import_configs;;
        8) performance_optimization;;
        0) return;;
        *) red "无效选择" && sleep 2 && advanced_menu;;
    esac
}

# 备份当前配置
backup_current_configs() {
    green "备份当前配置..."
    
    local backup_dir="/root/three-channel-routing-backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # 备份脚本配置
    if [[ -d $CONFIG_DIR ]]; then
        cp -r $CONFIG_DIR "$backup_dir/"
        green "✓ 备份脚本配置"
    fi
    
    # 备份各面板配置
    local panel_configs=(
        "/etc/sing-box/config.json"
        "/etc/s-box/sb.json"
        "/opt/hiddify-config/hiddify-panel.json"
        "/etc/mihomo/config.yaml"
        "/etc/clash/config.yaml"
    )
    
    for config in "${panel_configs[@]}"; do
        if [[ -f "$config" ]]; then
            local config_dir="$backup_dir/$(dirname "$config")"
            mkdir -p "$config_dir"
            cp "$config" "$config_dir/"
            green "✓ 备份 $(basename "$config")"
        fi
    done
    
    green "配置备份完成: $backup_dir"
    readp "按回车继续..."
}

# 显示运行日志
show_logs() {
    clear
    green "=== 运行日志 ==="
    echo
    
    echo "1. WARP Socks5 服务日志"
    echo "2. 脚本运行日志"
    echo "3. 系统网络日志"
    echo "0. 返回"
    
    readp "请选择 [0-3]: " log_choice
    
    case $log_choice in
        1) 
            if systemctl is-active --quiet warp-socks5; then
                journalctl -u warp-socks5 -f --no-pager
            else
                yellow "WARP服务未运行"
            fi
            ;;
        2)
            if [[ -f /var/log/three-channel-routing.log ]]; then
                tail -f /var/log/three-channel-routing.log
            else
                yellow "脚本日志文件不存在"
            fi
            ;;
        3)
            dmesg | grep -i network | tail -20
            ;;
        0) return;;
        *) red "无效选择";;
    esac
    
    readp "按回车继续..."
}

# 清理临时文件
cleanup_temp_files() {
    green "清理临时文件..."
    
    # 清理系统临时文件
    rm -f /tmp/*warp* /tmp/*routing* /tmp/*sing-box* 2>/dev/null
    
    # 清理旧的日志文件
    if [[ -f /var/log/three-channel-routing.log ]]; then
        local log_size=$(stat -c%s /var/log/three-channel-routing.log)
        if [[ $log_size -gt 10485760 ]]; then  # 10MB
            tail -n 1000 /var/log/three-channel-routing.log > /tmp/routing.log
            mv /tmp/routing.log /var/log/three-channel-routing.log
            green "✓ 清理日志文件"
        fi
    fi
    
    # 清理旧的备份文件
    local backup_dir="/root/three-channel-routing-backups"
    if [[ -d "$backup_dir" ]]; then
        find "$backup_dir" -type f -name "*.backup" -mtime +30 -delete
        green "✓ 清理30天前的备份文件"
    fi
    
    green "临时文件清理完成"
    readp "按回车继续..."
}

# 重置网络设置
reset_network_settings() {
    yellow "此操作将重置网络DNS设置，是否继续？[y/N]"
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
        systemd-resolve --flush-caches
    fi
    
    green "网络设置已重置"
    readp "按回车继续..."
}

# 导出配置文件
export_configs() {
    local export_file="/root/three-channel-routing-export-$(date +%Y%m%d_%H%M%S).tar.gz"
    
    green "导出配置文件..."
    
    if [[ -d $CONFIG_DIR ]]; then
        tar -czf "$export_file" -C "$(dirname $CONFIG_DIR)" "$(basename $CONFIG_DIR)"
        green "配置已导出到: $export_file"
        
        # 显示导出文件信息
        local file_size=$(du -h "$export_file" | cut -f1)
        echo "文件大小: $file_size"
        echo "包含文件:"
        tar -tzf "$export_file" | sed 's/^/  /'
    else
        red "没有配置文件可导出"
    fi
    
    readp "按回车继续..."
}

# 导入配置文件
import_configs() {
    readp "请输入配置文件路径: " import_file
    
    if [[ ! -f "$import_file" ]]; then
        red "文件不存在: $import_file"
        return
    fi
    
    # 检查文件格式
    if [[ "$import_file" == *.tar.gz ]]; then
        green "导入配置文件..."
        
        # 备份现有配置
        if [[ -d $CONFIG_DIR ]]; then
            mv $CONFIG_DIR "${CONFIG_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        fi
        
        # 解压配置文件
        tar -xzf "$import_file" -C "$(dirname $CONFIG_DIR)"
        
        if [[ $? -eq 0 ]]; then
            green "配置导入成功"
        else
            red "配置导入失败"
        fi
    else
        red "不支持的文件格式，请使用.tar.gz文件"
    fi
    
    readp "按回车继续..."
}

# 性能优化
performance_optimization() {
    green "系统性能优化..."
    
    # 优化网络参数
    cat > /etc/sysctl.d/99-three-channel-routing.conf <<EOF
# 网络性能优化
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
EOF
    
    # 应用设置
    sysctl -p /etc/sysctl.d/99-three-channel-routing.conf
    
    # 优化文件描述符限制
    if ! grep -q "three-channel-routing" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf <<EOF
# three-channel-routing optimization
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
    fi
    
    green "✓ 网络参数优化完成"
    green "✓ 文件描述符限制优化完成"
    
    readp "按回车继续..."
}

# 扩展主菜单
extended_main_menu() {
    clear
    green "========================================="
    green "     三通道域名分流管理脚本 v${VERSION}"
    green "========================================="
    echo
    blue "基础功能："
    echo "1. 安装 WARP Socks5 代理"
    echo "2. 配置三通道域名分流"
    echo "3. 应用分流配置到面板"
    echo "4. 查看当前配置状态"
    echo "5. 管理自定义域名规则"
    echo "6. 测试分流效果"
    echo
    blue "高级功能："
    echo "7. 高级功能菜单"
    echo "8. 脚本更新"
    echo "9. 帮助信息"
    echo
    red "危险操作："
    echo "88. 卸载所有配置"
    echo
    echo "0. 退出脚本"
    echo
    readp "请选择功能 [0-9,88]: " choice
    
    case $choice in
        1) install_warp_socks5;;
        2) configure_three_channel_routing;;
        3) apply_routing_config;;
        4) show_config_status;;
        5) manage_domain_rules;;
        6) test_routing;;
        7) advanced_menu;;
        8) update_script;;
        9) show_help;;
        88) uninstall_all;;
        0) 
            green "感谢使用三通道域名分流脚本！"
            cleanup
            exit 0
            ;;
        *) red "无效选择，请重新输入" && sleep 2 && extended_main_menu;;
    esac
}

# 主函数入口
main() {
    # 检查root权限
    [[ $EUID -ne 0 ]] && red "请使用root权限运行此脚本" && exit 1
    
    # 初始化
    check_system
    check_dependencies
    
    # 创建日志目录
    mkdir -p /var/log
    
    # 记录脚本启动
    log_info "脚本启动 v${VERSION}"
    
    # 处理命令行参数
    case "${1:-}" in
        "install"|"-i") install_warp_socks5;;
        "config"|"-c") configure_three_channel_routing;;
        "apply"|"-a") apply_routing_config;;
        "status"|"-s") show_config_status;;
        "test"|"-t") test_routing;;
        "uninstall"|"-u") uninstall_all;;
        "update"|"--update") update_script;;
        "help"|"-h"|"--help") show_help;;
        "menu"|"-m"|"") 
            show_welcome
            while true; do
                extended_main_menu
            done
            ;;
        *)
            red "未知参数: $1"
            echo "使用 $0 help 查看帮助信息"
            exit 1
            ;;
    esac
}

# 启动脚本
main "$@"
