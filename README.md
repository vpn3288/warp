# warp
# 通用代理三通道分流系统

从 sing-box-yg 脚本提取的核心功能，支持多种代理面板的三通道域名分流系统。

## 功能特点

### 🚀 核心功能
- **WARP-plus-Socks5 代理模式**: 提供本地 Socks5 代理服务 (127.0.0.1:40000)
- **三通道域名分流**: 智能路由分流，优化网络访问体验
- **多面板支持**: 兼容 Hiddify、3X-UI、X-UI、Sing-box 等主流代理面板

### 📊 三通道分流策略

| 通道 | 用途 | 适用场景 | 示例域名 |
|------|------|----------|----------|
| 通道1 - 直连 | VPS直接访问 | 国内网站、未被墙服务 | baidu.com, qq.com, taobao.com |
| 通道2 - WARP | Cloudflare WARP代理 | 被墙的国外网站、AI服务 | google.com, openai.com, youtube.com |
| 通道3 - Socks5 | 本地Socks5代理 | 特定区域解锁、备用线路 | 用户自定义 |

## 安装使用

### 快速安装
```bash
# 下载并运行脚本
bash <(curl -fsSL https://raw.githubusercontent.com/your-repo/three-channel-routing/main/install.sh)

# 或者下载脚本文件
wget https://raw.githubusercontent.com/your-repo/three-channel-routing/main/install.sh
chmod +x install.sh
./install.sh
```

### 安装选项
1. **安装 WARP Socks5 代理** - 仅安装 WARP 代理功能
2. **配置三通道域名分流** - 仅配置分流规则（需先安装WARP）
3. **一键安装全部功能** - 推荐选项，自动完成全部配置
4. **服务管理** - 管理已安装的服务
5. **应用分流配置** - 将配置应用到现有代理面板

### 命令行参数
```bash
# 仅安装 WARP Socks5
./install.sh install-warp

# 仅配置三通道分流
./install.sh install-routing  

# 安装全部功能
./install.sh install-all

# 查看安装状态
./install.sh status

# 卸载全部功能
./install.sh uninstall
```

## 面板配置

### Sing-box 面板
- **自动配置**: 脚本会自动检测并合并配置文件
- **配置文件**: `/etc/s-box/sb.json`
- **应用方式**: 运行应用脚本即可

### Hiddify Panel
1. 复制生成的配置文件内容：`/etc/proxy-routing/hiddify-config.yaml`
2. 登录 Hiddify Panel 管理界面
3. 进入 `配置` → `路由设置`
4. 粘贴配置内容并保存

### 3X-UI / X-UI Panel  
1. 复制生成的配置文件内容：`/etc/proxy-routing/xui-config.json`
2. 登录面板管理界面
3. 进入 `入站列表` → `路由设置`
4. 选择 JSON 配置模式，粘贴内容并保存

### 其他面板
参考生成的配置模板，手动配置对应的路由规则。

## 配置文件说明

### 目录结构
```
/etc/warp-socks5/          # WARP代理配置目录
├── private.key            # WireGuard私钥
├── ipv6.addr             # IPv6地址
└── reserved.json         # Reserved值

/etc/proxy-routing/        # 分流配置目录
├── direct_domains.json    # 直连域名规则
├── warp_domains.json     # WARP代理域名规则  
├── socks5_domains.json   # Socks5代理域名规则
├── singbox-routing.json  # Sing-box配置模板
├── hiddify-config.yaml   # Hiddify配置模板
├── xui-config.json       # X-UI配置模板
└── apply-routing.sh      # 配置应用脚本
```

### 域名规则格式
```json
// 直连域名示例
["cn","com.cn","baidu.com","qq.com"]

// WARP代理域名示例  
["google.com","youtube.com","openai.com","github.com"]

// Socks5代理域名示例
["netflix.com","disney.com"]
```

## 服务管理

### WARP Socks5 代理
```bash
# 启动服务
systemctl start warp-socks5

# 停止服务
systemctl stop warp-socks5

# 重启服务
systemctl restart warp-socks5

# 查看状态
systemctl status warp-socks5

# 查看日志
journalctl -u warp-socks5 -f
```

### 配置应用
```bash
# 运行配置应用脚本
bash /etc/proxy-routing/apply-routing.sh

# 或使用快捷命令（如果已安装）
proxy-routing
```

## 测试验证

### 连接测试
```bash
# 测试直连
curl -I http://www.baidu.com

# 测试WARP连接
curl https://www.cloudflare.com/cdn-cgi/trace

# 测试Socks5代理
curl --socks5 127.0.0.1:40000 -I http://www.google.com
```

### 分流测试
1. 访问国内网站（如 baidu.com）应走直连
2. 访问国外网站（如 google.com）应走WARP
3. 访问自定义Socks5域名应走Socks5代理

### 查看WARP状态
```bash
# 检查WARP连接状态
curl https://www.cloudflare.com/cdn-cgi/trace | grep warp

# 返回结果说明：
# warp=off    - 未使用WARP
# warp=on     - 使用免费WARP  
# warp=plus   - 使用WARP+
```

## 故障排除

### 常见问题

**Q: WARP Socks5代理启动失败**
```bash
# 检查防火墙状态
systemctl status iptables
ufw status

# 检查端口占用
ss -tlnp | grep 40000

# 重新生成WARP密钥
cd /etc/warp-socks5
wg genkey > private.key
systemctl restart warp-socks5
```

**Q: 分流规则不生效**
```bash
# 检查域名规则格式
cat /etc/proxy-routing/direct_domains.json | jq .

# 重新应用配置
bash /etc/proxy-routing/apply-routing.sh

# 重启相关服务
systemctl restart sing-box  # 或其他面板服务
```

**Q: 网络连接异常**
```bash
# 检查DNS解析
nslookup google.com

# 检查路由表
ip route show

# 重置网络配置
systemctl restart networking
```

### 日志查看
```bash
# WARP服务日志
journalctl -u warp-socks5 -n 50

# 脚本安装日志
tail -f /var/log/proxy-routing/install.log

# 错误日志
tail -f /var/log/proxy-routing/error.log
```

## 高级配置

### 自定义域名规则
```bash
# 编辑直连域名
vim /etc/proxy-routing/direct_domains.json

# 编辑WARP代理域名
vim /etc/proxy-routing/warp_domains.json

# 编辑Socks5代理域名
vim /etc/proxy-routing/socks5_domains.json

# 重新生成配置
bash /etc/proxy-routing/apply-routing.sh
```

### 备份和还原
```bash
# 备份当前配置
mkdir /root/backup-$(date +%Y%m%d)
cp -r /etc/warp-socks5 /root/backup-$(date +%Y%m%d)/
cp -r /etc/proxy-routing /root/backup-$(date +%Y%m%d)/

# 还原配置
cp -r /root/backup-20241201/warp-socks5 /etc/
cp -r /root/backup-20241201/proxy-routing /etc/
systemctl restart warp-socks5
```

### 性能优化
```bash
# 调整WARP连接参数
vim /etc/systemd/system/warp-socks5.service

# 在ExecStart行添加参数：
# --reserved [自定义reserved值]
# --mtu 1280
# --keepalive 25

systemctl daemon-reload
systemctl restart warp-socks5
```

## 注意事项

1. **系统要求**: Ubuntu 18+, Debian 9+, CentOS 7+
2. **架构支持**: x86_64, ARM64
3. **网络要求**: 需要能够访问 Cloudflare 服务
4. **权限要求**: 需要 root 权限运行
5. **端口要求**: 确保 40000 端口未被占用

## 更新与维护

### 脚本更新
```bash
# 重新下载最新版本
wget -O install.sh https://raw.githubusercontent.com/your-repo/three-channel-routing/main/install.sh
chmod +x install.sh

# 保留现有配置更新
./install.sh
```

### 配置维护
- 定期检查WARP连接状态
- 根据需要调整域名分流规则
- 监控代理服务运行状态
- 及时备份重要配置

## 致谢

本项目基于 [yonggekkk/sing-box-yg](https://github.com/yonggekkk/sing-box-yg) 脚本提取核心功能，感谢原作者的贡献。

## 许可证

本项目采用 MIT 许可证，详见 [LICENSE](LICENSE) 文件。
