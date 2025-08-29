#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# 三通道域名分流（独立版）
# - 将指定域名列表的流量走 WARP（Cloudflare WireGuard）
# - 其他流量按优先级走：上游代理(可选) -> 直连
# - 使用 sing-box 作为本地代理核心（mixed 入站 127.0.0.1:7890）
# - 不依赖 geosite/geoip 规则，仅按域名列表分流
#
# 适用场景：
#   你只想把“这份域名清单”强制走 WARP，其它一律正常代理(可选)或直连
#
# 运行示例：
#   bash tri-route-warp-proxy-direct.sh install     # 一键安装/初始化
#   bash tri-route-warp-proxy-direct.sh add example.com
#   bash tri-route-warp-proxy-direct.sh list
#   bash tri-route-warp-proxy-direct.sh remove example.com
#   bash tri-route-warp-proxy-direct.sh set-upstream socks5://user:pass@127.0.0.1:1080
#   bash tri-route-warp-proxy-direct.sh set-upstream http://127.0.0.1:8080
#   bash tri-route-warp-proxy-direct.sh unset-upstream
#   bash tri-route-warp-proxy-direct.sh restart
#   bash tri-route-warp-proxy-direct.sh status
# =============================================================

SCRIPT_NAME="三通道域名分流(独立版)"
VERSION="1.0.0"
BASE_DIR="/etc/sing-box-3route"
SB_BIN="/usr/local/bin/sing-box"
WGCF_BIN="/usr/local/bin/wgcf"
SYSTEMD_UNIT="sing-box-3route.service"
DOMAINS_FILE="$BASE_DIR/domains_warp.txt"
CONF_FILE="$BASE_DIR/config.json"
PROFILE_FILE="$BASE_DIR/wgcf-profile.conf"
UPSTREAM_FILE="$BASE_DIR/upstream.url"
LOG_DIR="$BASE_DIR/log"

# ------------------------------
# 打印工具
# ------------------------------
color() { local c=$1; shift; case "$c" in
  r) printf "\033[31m%s\033[0m\n" "$*" ;;
  g) printf "\033[32m%s\033[0m\n" "$*" ;;
  y) printf "\033[33m%s\033[0m\n" "$*" ;;
  b) printf "\033[34m%s\033[0m\n" "$*" ;;
  c) printf "\033[36m%s\033[0m\n" "$*" ;;
  *) printf "%s\n" "$*" ;;
 esac }

need_root() {
  if [[ $(id -u) -ne 0 ]]; then color r "请以 root 身份运行。"; exit 1; fi
}

# ------------------------------
# 系统与依赖
# ------------------------------
arch_map() {
  case $(uname -m) in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l) echo armv7 ;;
    *) color r "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

ensure_pkgs() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl wget jq tar grep sed awk systemd ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget jq tar grep sed awk systemd ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget jq tar grep sed awk systemd ca-certificates
  else
    color r "未检测到受支持的包管理器(apt/yum/dnf)。请手动安装 curl wget jq tar 等依赖后重试。"
    exit 1
  fi
}

# ------------------------------
# 下载 & 安装 sing-box / wgcf
# ------------------------------
install_sing_box() {
  if [[ -x "$SB_BIN" ]]; then color g "已存在 sing-box：$($SB_BIN version | head -n1 2>/dev/null || echo)"; return; fi
  local ARCH; ARCH=$(arch_map)
  color c "下载 sing-box 最新版本..."
  local api="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
  local url
  url=$(curl -fsSL "$api" | jq -r --arg arch "$ARCH" '.assets[] | select(.name|test("linux-"+$arch+".*.tar.gz$")) | .browser_download_url' | head -n1)
  if [[ -z "$url" ]]; then
    color r "获取 sing-box 下载链接失败。"
    exit 1
  fi
  mkdir -p "$BASE_DIR/tmp"
  local tgz="$BASE_DIR/tmp/singbox.tgz"
  curl -fL "$url" -o "$tgz"
  tar -xzf "$tgz" -C "$BASE_DIR/tmp"
  local bindir
  bindir=$(find "$BASE_DIR/tmp" -maxdepth 2 -type f -name sing-box -print -quit)
  install -m 0755 "$bindir" "$SB_BIN"
  color g "sing-box 安装完成：$($SB_BIN version | head -n1)"
}

install_wgcf() {
  if [[ -x "$WGCF_BIN" ]]; then color g "已存在 wgcf：$($WGCF_BIN -v 2>/dev/null || echo)"; return; fi
  local ARCH; ARCH=$(arch_map)
  color c "下载 wgcf 最新版本..."
  local api="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
  local url
  url=$(curl -fsSL "$api" | jq -r --arg arch "$ARCH" '.assets[] | select(.name|test("linux-"+$arch+"$")) | .browser_download_url' | head -n1)
  if [[ -z "$url" ]]; then
    color r "获取 wgcf 下载链接失败。"; exit 1
  fi
  mkdir -p "$BASE_DIR/tmp"
  local bin="$BASE_DIR/tmp/wgcf"
  curl -fL "$url" -o "$bin"
  install -m 0755 "$bin" "$WGCF_BIN"
  color g "wgcf 安装完成：$($WGCF_BIN -v)"
}

# ------------------------------
# 初始化目录 & WARP 账户
# ------------------------------
init_layout() {
  mkdir -p "$BASE_DIR" "$LOG_DIR"
  touch "$DOMAINS_FILE"
  chmod 600 "$DOMAINS_FILE"
}

init_warp() {
  if [[ -f "$PROFILE_FILE" ]]; then color g "已存在 WARP 配置：$PROFILE_FILE"; return; fi
  color c "注册 WARP 账户 (wgcf)..."
  yes | $WGCF_BIN register >/dev/null 2>&1 || true
  $WGCF_BIN generate -p "$PROFILE_FILE"
  if ! grep -q "\[Interface\]" "$PROFILE_FILE"; then
    color r "生成 wgcf-profile 失败。"; exit 1
  fi
  color g "WARP profile 生成完毕：$PROFILE_FILE"
}

# ------------------------------
# 解析 wgcf-profile.conf -> sing-box wireguard 出站参数
# ------------------------------
parse_warp_json() {
  # 输出 JSON 片段到 stdout
  # 包含：server, server_port, local_address[], private_key, peer_public_key, reserved(optional), mtu
  local private_key address peer_pub endpoint port mtu reserved
  private_key=$(awk -F'= ' '/^PrivateKey/ {gsub(/\r/, ""); print $2}' "$PROFILE_FILE")
  address=$(awk -F'= ' '/^Address/ {gsub(/\r/, ""); print $2}' "$PROFILE_FILE")
  peer_pub=$(awk -F'= ' '/^PublicKey/ {gsub(/\r/, ""); print $2}' "$PROFILE_FILE")
  endpoint=$(awk -F'= ' '/^Endpoint/ {gsub(/\r/, ""); print $2}' "$PROFILE_FILE")
  mtu=$(awk -F'= ' '/^MTU/ {gsub(/\r/, ""); print $2}' "$PROFILE_FILE")
  reserved=$(awk -F'= ' '/^Reserved/ {gsub(/\r/, ""); print $2}' "$PROFILE_FILE" || true)

  local server; server=${endpoint%:*}
  port=${endpoint##*:}
  [[ -z "$mtu" ]] && mtu=1280

  # Address 可能是 "172.16.0.2/32, 2606:4700:.../128"，只取 IPv4/32 一条
  local v4
  v4=$(echo "$address" | tr ',' '\n' | awk '/\./{gsub(/^\s+|\s+$/,"",$0); print $0}' | head -n1)
  [[ -z "$v4" ]] && v4="$address"

  # 处理 Reserved -> [x,y,z]
  local reserved_json="null"
  if [[ -n "${reserved:-}" ]]; then
    # 格式类似：123,45,67
    local a b c
    IFS=',' read -r a b c <<< "$reserved"
    a=${a// /}; b=${b// /}; c=${c// /}
    if [[ -n "$a" && -n "$b" && -n "$c" ]]; then
      reserved_json="[$a,$b,$c]"
    fi
  fi

  cat <<JSON
{
  "server": "$server",
  "server_port": ${port:-2408},
  "local_address": ["$v4"],
  "private_key": "$private_key",
  "peer_public_key": "$peer_pub",
  "mtu": $mtu,
  "reserved": $reserved_json
}
JSON
}

# ------------------------------
# 读取/写入上游
# ------------------------------
get_upstream() {
  [[ -f "$UPSTREAM_FILE" ]] && cat "$UPSTREAM_FILE" || true
}

set_upstream() {
  local url="$1"
  if [[ ! "$url" =~ ^(socks5|http):// ]]; then
    color r "仅支持 socks5:// 或 http:// 形式的上游地址。示例：socks5://user:pass@127.0.0.1:1080"
    exit 1
  fi
  echo "$url" > "$UPSTREAM_FILE"
  color g "已写入上游：$url"
}

unset_upstream() {
  rm -f "$UPSTREAM_FILE"
  color g "已取消上游代理(默认走直连)。"
}

# ------------------------------
# 生成 sing-box 配置
# ------------------------------
json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || sed 's/"/\\"/g'; }

build_config() {
  color c "生成 sing-box 配置..."
  local warp_json upstream url scheme host port user pass
  warp_json=$(parse_warp_json)

  # 读取域名列表 -> JSON 数组（按 domain 逐条匹配）
  local domains_json
  if [[ -s "$DOMAINS_FILE" ]]; then
    domains_json=$(awk 'NF{print}' "$DOMAINS_FILE" | sed 's/#.*$//' | awk 'NF{print}' | awk '{print "\""$0"\","}' | sed 's/,$//' | tr -d '\n')
  else
    domains_json=""
  fi

  # 解析上游
  upstream=$(get_upstream || true)
  local upstream_block=""
  local route_fallback="direct"
  if [[ -n "$upstream" ]]; then
    url="$upstream"
    scheme=${url%%://*}
    url=${url#*://}
    userpass_hostport="$url"
    user=""; pass=""; hostport="$userpass_hostport"
    if [[ "$userpass_hostport" == *"@"* ]]; then
      userpass="${userpass_hostport%@*}"; hostport="${userpass_hostport#*@}"
      user="${userpass%%:*}"; pass="${userpass#*:}"
    fi
    host="${hostport%%:*}"; port="${hostport##*:}"

    if [[ "$scheme" == "socks5" ]]; then
      upstream_block=$(cat <<J
      ,{
        "type": "socks",
        "tag": "upstream",
        "server": "$host",
        "server_port": $port,
        "version": "5"$(
          [[ -n "$user" ]] && printf ',\n        "username": "%s",\n        "password": "%s"' "$user" "$pass"
        )
      }
J
      )
      route_fallback="upstream"
    elif [[ "$scheme" == "http" ]]; then
      upstream_block=$(cat <<J
      ,{
        "type": "http",
        "tag": "upstream",
        "server": "$host",
        "server_port": $port$(
          [[ -n "$user" ]] && printf ',\n        "username": "%s",\n        "password": "%s"' "$user" "$pass"
        )
      }
J
      )
      route_fallback="upstream"
    fi
  fi

  # 组装配置
  mkdir -p "$BASE_DIR"
  cat > "$CONF_FILE" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "$LOG_DIR/sing-box.log"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "in-mixed",
      "listen": "127.0.0.1",
      "listen_port": 7890
    }
  ],
  "outbounds": [
    {
      "type": "wireguard",
      "tag": "warp",
      "server": $(echo "$warp_json" | jq -r '.server | @json'),
      "server_port": $(echo "$warp_json" | jq -r '.server_port'),
      "local_address": $(echo "$warp_json" | jq -r '.local_address'),
      "private_key": $(echo "$warp_json" | jq -r '.private_key | @json'),
      "peer_public_key": $(echo "$warp_json" | jq -r '.peer_public_key | @json'),
      "mtu": $(echo "$warp_json" | jq -r '.mtu'),
      "reserved": $(echo "$warp_json" | jq -c '.reserved // null')
    },
    {
      "type": "direct",
      "tag": "direct"
    }$upstream_block
  ],
  "route": {
    "rules": [
      {
        "outbound": "warp",
        "domain": [
$(
  if [[ -n "$domains_json" ]]; then
    echo "          $domains_json"
  fi
)
        ]
      }
    ],
    "final": "$route_fallback"
  },
  "dns": {
    "servers": [
      { "tag": "cloudflare", "address": "1.1.1.1" },
      { "tag": "local", "address": "local" }
    ],
    "final": "cloudflare"
  }
}
EOF

  color g "配置已生成：$CONF_FILE"
}

# ------------------------------
# systemd 管理
# ------------------------------
install_service() {
  cat > "/etc/systemd/system/$SYSTEMD_UNIT" <<SERVICE
[Unit]
Description=sing-box 3-route (WARP/UPSTREAM/DIRECT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SB_BIN run -c $CONF_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
  systemctl enable "$SYSTEMD_UNIT" --now
  systemctl restart "$SYSTEMD_UNIT"
}

# ------------------------------
# 域名清单维护
# ------------------------------
cmd_add() {
  need_root
  init_layout
  local d="$1"
  if [[ -z "$d" ]]; then color r "用法：$0 add example.com"; exit 1; fi
  if grep -Fxq "$d" "$DOMAINS_FILE"; then color y "已存在：$d"; return; fi
  echo "$d" >> "$DOMAINS_FILE"
  sort -u "$DOMAINS_FILE" -o "$DOMAINS_FILE"
  color g "已添加：$d"
  build_config
  systemctl restart "$SYSTEMD_UNIT" || true
}

cmd_remove() {
  need_root
  init_layout
  local d="$1"
  if [[ -z "$d" ]]; then color r "用法：$0 remove example.com"; exit 1; fi
  if ! grep -Fxq "$d" "$DOMAINS_FILE"; then color y "未找到：$d"; return; fi
  grep -Fxv "$d" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" && mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
  color g "已移除：$d"
  build_config
  systemctl restart "$SYSTEMD_UNIT" || true
}

cmd_list() {
  init_layout
  color c "WARP 域名清单 ($DOMAINS_FILE)："
  if [[ -s "$DOMAINS_FILE" ]]; then cat "$DOMAINS_FILE"; else echo "(空)"; fi
}

cmd_set_upstream() { need_root; init_layout; set_upstream "$1"; build_config; systemctl restart "$SYSTEMD_UNIT" || true; }
cmd_unset_upstream() { need_root; init_layout; unset_upstream; build_config; systemctl restart "$SYSTEMD_UNIT" || true; }

cmd_install() {
  need_root
  ensure_pkgs
  init_layout
  install_sing_box
  install_wgcf
  init_warp
  build_config
  install_service
  color g "安装完成。mixed 入站地址：127.0.0.1:7890"
  color y "提示：如需把“非清单流量”走上游代理，请执行：\n  $0 set-upstream socks5://user:pass@IP:PORT\n或\n  $0 set-upstream http://IP:PORT"
}

cmd_restart() { systemctl restart "$SYSTEMD_UNIT"; color g "已重启。"; }
cmd_status() { systemctl status "$SYSTEMD_UNIT" --no-pager; }

# ------------------------------
# 主入口
# ------------------------------
case "${1:-}" in
  install)        cmd_install ;;
  add)            shift; cmd_add "${1:-}" ;;
  remove)         shift; cmd_remove "${1:-}" ;;
  list)           cmd_list ;;
  set-upstream)   shift; cmd_set_upstream "${1:-}" ;;
  unset-upstream) cmd_unset_upstream ;;
  restart)        cmd_restart ;;
  status)         cmd_status ;;
  *)
    cat <<USAGE
$SCRIPT_NAME  v$VERSION
用法：
  $0 install                      # 安装/初始化并启动服务
  $0 add <domain>                 # 将域名加入 WARP 通道
  $0 remove <domain>              # 从 WARP 通道移除域名
  $0 list                         # 查看当前 WARP 域名清单
  $0 set-upstream <url>           # 设置上游代理(socks5:// 或 http://)
  $0 unset-upstream               # 取消上游代理(其余流量改为直连)
  $0 restart                      # 重启服务
  $0 status                       # 查看服务状态

说明：
  1) 仅按域名精确匹配，不使用 geosite/geoip；支持 example.com / sub.example.com 等逐条添加。
  2) 清单内域名 -> WARP；其余 -> 上游(若设置)；否则 -> 直连。
  3) 本脚本会自动安装 sing-box 与 wgcf，并生成 WARP WireGuard 出站配置。
  4) 本地代理监听：127.0.0.1:7890 (mixed，支持 HTTP/SOCKS5)。
USAGE
    ;;
esac
