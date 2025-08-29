#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# 三通道域名分流 独立一键安装脚本
# 安装位置和文件
INSTALL_DIR="/etc/sing-box-3route"
SB_BIN="/usr/local/bin/sing-box"
WGCF_BIN="/usr/local/bin/wgcf"
BIN_PATH="/usr/local/bin/3route"
SERVICE_NAME="sing-box-3route"
DOMAINS_FILE="$INSTALL_DIR/domains_warp.txt"
PROFILE_FILE="$INSTALL_DIR/wgcf-profile.conf"
CONF_FILE="$INSTALL_DIR/config.json"
UPSTREAM_FILE="$INSTALL_DIR/upstream.url"
LOG_DIR="$INSTALL_DIR/log"
TMPDIR="${TMPDIR:-/tmp/singbox_3route_install}"

# small color helpers
color() { case "$1" in
  r) printf "\e[31m%s\e[0m\n" "$2" ;;
  g) printf "\e[32m%s\e[0m\n" "$2" ;;
  y) printf "\e[33m%s\e[0m\n" "$2" ;;
  c) printf "\e[36m%s\e[0m\n" "$2" ;;
  *)  printf "%s\n" "$2" ;;
esac }

need_root(){ if [[ "$(id -u)" -ne 0 ]]; then color r "请以 root 用户运行本脚本"; exit 1; fi }

detect_arch(){
  local _m
  _m="$(uname -m)"
  case "$_m" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7*|armv7l) ARCH="armv7" ;;
    i386|i686) ARCH="386" ;;
    *) color y "检测到未知架构: $_m，尝试使用 amd64"; ARCH="amd64" ;;
  esac
  echo "$ARCH"
}

detect_pkgmgr(){
  if command -v apt-get >/dev/null 2>&1; then PKG="apt"
  elif command -v yum >/dev/null 2>&1; then PKG="yum"
  elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
  elif command -v apk >/dev/null 2>&1; then PKG="apk"
  else PKG="unknown"
  fi
  echo "$PKG"
}

ensure_pkgs(){
  local pkgmgr
  pkgmgr="$(detect_pkgmgr)"
  color c "检测并安装依赖 (pkgmgr=$pkgmgr) ..."
  case "$pkgmgr" in
    apt)
      apt-get update -y
      apt-get install -y curl wget tar jq sed grep iptables ca-certificates unzip
      # fix awk virtual package on new Ubuntu
      if ! command -v gawk >/dev/null 2>&1 && ! command -v mawk >/dev/null 2>&1; then
        apt-get install -y gawk || apt-get install -y mawk || true
      fi
      ;;
    yum)
      yum install -y epel-release || true
      yum install -y curl wget tar jq sed grep iptables ca-certificates unzip gawk || true
      ;;
    dnf)
      dnf install -y curl wget tar jq sed grep iptables ca-certificates unzip gawk || true
      ;;
    apk)
      apk add --no-cache curl wget tar jq sed grep iptables ca-certificates gawk || true
      ;;
    *)
      color y "未检测到受支持的包管理器(apt/yum/dnf/apk)。请手动安装：curl wget jq tar sed grep iptables gawk"
      ;;
  esac
}

install_singbox(){
  if command -v sing-box >/dev/null 2>&1; then
    color g "sing-box 已存在：$(sing-box version 2>/dev/null | head -n1 || true)"
    return
  fi
  mkdir -p "$TMPDIR"
  local api="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
  color c "从 GitHub 获取 sing-box 最新版本..."
  local url
  url=$(curl -fsSL "$api" | jq -r --arg arch "$ARCH" '.assets[] | select(.name|test("linux.*" + $arch; "i") and (.name|test("\\.tar\\.gz|\\.tgz|\\.zip"; "i") | not) | .browser_download_url)' | head -n1)
  if [[ -z "$url" ]]; then
    # fallback to matching tar.gz
    url=$(curl -fsSL "$api" | jq -r --arg arch "$ARCH" '.assets[] | select(.name|test("linux.*" + $arch; "i") and (.name|test("\\.tar\\.gz|\\.tgz"; "i"))) | .browser_download_url' | head -n1)
  fi
  if [[ -z "$url" ]]; then
    color r "无法从 GitHub 自动获取 sing-box 下载地址，请手动安装 sing-box 后再次运行。"
    return 1
  fi
  color c "下载： $url"
  local out="$TMPDIR/singbox_asset"
  curl -fL "$url" -o "$out"
  # 如果是压缩包则解压搜 sing-box 二进制
  if file "$out" | grep -qiE 'tar|gzip'; then
    tar -xzf "$out" -C "$TMPDIR"
    local bin
    bin=$(find "$TMPDIR" -type f -name sing-box -print -quit || true)
    if [[ -z "$bin" ]]; then
      color r "解压后未找到 sing-box 可执行文件，请手动安装。"
      return 1
    fi
    install -m 0755 "$bin" "$SB_BIN"
  else
    # 直接可执行文件
    install -m 0755 "$out" "$SB_BIN"
  fi
  color g "sing-box 已安装到 $SB_BIN"
}

install_wgcf(){
  if command -v wgcf >/dev/null 2>&1; then
    color g "wgcf 已存在：$(wgcf -v 2>/dev/null || true)"
    return
  fi
  mkdir -p "$TMPDIR"
  local api="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
  color c "从 GitHub 获取 wgcf 最新版本..."
  local url
  # try match linux + arch
  url=$(curl -fsSL "$api" | jq -r --arg arch "$ARCH" '.assets[] | select(.name|test("linux";"i") and (.name|test($arch;"i"))) | .browser_download_url' | head -n1)
  if [[ -z "$url" ]]; then
    url=$(curl -fsSL "$api" | jq -r '.assets[] | select(.name|test("linux";"i")) | .browser_download_url' | head -n1)
  fi
  if [[ -z "$url" ]]; then
    color r "无法获取 wgcf 下载地址，请手动安装 wgcf 后再次运行。"
    return 1
  fi
  color c "下载： $url"
  local out="$TMPDIR/wgcf_asset"
  curl -fL "$url" -o "$out"
  if file "$out" | grep -qiE 'tar|gzip|zip'; then
    mkdir -p "$TMPDIR/wgcf_extract"
    if [[ "$(file "$out")" =~ zip ]]; then
      unzip -o "$out" -d "$TMPDIR/wgcf_extract" >/dev/null 2>&1 || true
    else
      tar -xzf "$out" -C "$TMPDIR/wgcf_extract" || true
    fi
    local wbin
    wbin=$(find "$TMPDIR/wgcf_extract" -type f -name wgcf -print -quit || true)
    if [[ -z "$wbin" ]]; then
      # maybe file already binary named wgcf_*
      wbin=$(find "$TMPDIR/wgcf_extract" -type f -iname 'wgcf*' -print -quit || true)
    fi
    if [[ -n "$wbin" ]]; then
      install -m 0755 "$wbin" "$WGCF_BIN"
    else
      color r "解压后未找到 wgcf 可执行文件，请手动安装。"
      return 1
    fi
  else
    install -m 0755 "$out" "$WGCF_BIN"
  fi
  color g "wgcf 已安装到 $WGCF_BIN"
}

init_layout(){
  mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$TMPDIR"
  touch "$DOMAINS_FILE"
  chmod 600 "$DOMAINS_FILE"
}

init_warp(){
  if [[ -f "$PROFILE_FILE" ]]; then
    color g "wgcf profile 已存在：$PROFILE_FILE"
    return
  fi
  if ! command -v "$WGCF_BIN" >/dev/null 2>&1; then
    color r "wgcf 未安装，无法生成 WARP profile。"
    return 1
  fi
  color c "注册并生成 wgcf profile（WARP）..."
  # try register non-interactive
  "$WGCF_BIN" register --accept-tos || "$WGCF_BIN" register || true
  "$WGCF_BIN" generate -p "$PROFILE_FILE" || true
  if [[ ! -f "$PROFILE_FILE" ]]; then
    color r "wgcf profile 生成失败，请检查网络或手动运行 wgcf register/generate。"
    return 1
  fi
  color g "wgcf profile 已生成：$PROFILE_FILE"
}

# 从 wgcf-profile.conf 提取参数
parse_wgcf_profile(){
  if [[ ! -f "$PROFILE_FILE" ]]; then
    color r "wgcf profile 文件不存在：$PROFILE_FILE"
    return 1
  fi
  private_key=$(awk -F= '/^PrivateKey/ {gsub(/^ +| +$/,"",$2); print $2}' "$PROFILE_FILE" | tr -d '\r' | head -n1)
  address=$(awk -F= '/^Address/ {gsub(/^ +| +$/,"",$2); print $2}' "$PROFILE_FILE" | tr -d '\r' | head -n1)
  peer_pub=$(awk -F= '/^PublicKey/ {gsub(/^ +| +$/,"",$2); print $2}' "$PROFILE_FILE" | tr -d '\r' | head -n1)
  endpoint=$(awk -F= '/^Endpoint/ {gsub(/^ +| +$/,"",$2); print $2}' "$PROFILE_FILE" | tr -d '\r' | head -n1)
  mtu=$(awk -F= '/^MTU/ {gsub(/^ +| +$/,"",$2); print $2}' "$PROFILE_FILE" | tr -d '\r' | head -n1 || true)
  reserved=$(awk -F= '/^Reserved/ {gsub(/^ +| +$/,"",$2); print $2}' "$PROFILE_FILE" | tr -d '\r' | head -n1 || true)

  # fallback defaults
  [[ -z "$mtu" ]] && mtu=1280

  # endpoint -> server + port
  if [[ "$endpoint" == *:* ]]; then
    server=${endpoint%:*}
    server_port=${endpoint##*:}
  else
    server="$endpoint"
    server_port=2408
  fi

  # address -> pick first IPv4 if exists, else the first address
  v4=$(echo "$address" | tr ',' '\n' | awk '/\./{gsub(/^ +| +$/,"",$0); print $0}' | head -n1)
  [[ -z "$v4" ]] && v4=$(echo "$address" | tr ',' '\n' | awk 'NF{print $0}' | head -n1)
}

# 生成 sing-box config.json
build_config(){
  parse_wgcf_profile || return 1
  mkdir -p "$INSTALL_DIR"
  # domains entries
  local domains_entries=""
  if [[ -s "$DOMAINS_FILE" ]]; then
    # 过滤注释和空行
    domains_entries=$(awk 'NF && $0 !~ /^#/ {print $0}' "$DOMAINS_FILE" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "      \"%s\",\n", $0}' | sed '$s/,$//')
  fi

  # upstream
  local upstream_block=""
  local route_fallback="direct"
  if [[ -f "$UPSTREAM_FILE" && -s "$UPSTREAM_FILE" ]]; then
    local up
    up=$(awk 'NR==1{print; exit}' "$UPSTREAM_FILE" | tr -d '\r\n')
    if [[ -n "$up" ]]; then
      # parse
      local scheme rest userpass hostport user pass host port
      scheme="${up%%://*}"
      rest="${up#*://}"
      if [[ "$rest" == *"@"* ]]; then
        userpass="${rest%@*}"
        hostport="${rest#*@}"
        user="${userpass%%:*}"
        pass="${userpass#*:}"
      else
        hostport="$rest"
      fi
      host="${hostport%%:*}"
      port="${hostport##*:}"
      if [[ -z "$port" || "$port" == "$host" ]]; then
        color y "上游地址未指定端口，默认使用 1080（socks5）或 8080（http）"
        if [[ "$scheme" == "socks5" ]]; then port=1080; else port=8080; fi
      fi

      if [[ "$scheme" == "socks5" ]]; then
        upstream_block=", { \"type\": \"socks\", \"tag\": \"upstream\", \"server\": \"${host}\", \"server_port\": ${port}$( [[ -n \"$user\" ]] && printf ', \"username\": \"%s\", \"password\": \"%s\"' \"$user\" \"$pass\" ) }"
        route_fallback="upstream"
      elif [[ "$scheme" == "http" ]]; then
        upstream_block=", { \"type\": \"http\", \"tag\": \"upstream\", \"server\": \"${host}\", \"server_port\": ${port}$( [[ -n \"$user\" ]] && printf ', \"username\": \"%s\", \"password\": \"%s\"' \"$user\" \"$pass\" ) }"
        route_fallback="upstream"
      else
        color y "仅支持 socks5:// 或 http:// 作为上游，忽略上游： $up"
      fi
    fi
  fi

  # assemble config
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
      "server": "${server}",
      "server_port": ${server_port},
      "local_address": ["${v4}"],
      "private_key": "${private_key}",
      "peer_public_key": "${peer_pub}",
      "mtu": ${mtu}
    },
    {
      "type": "direct",
      "tag": "direct"
    }${upstream_block}
  ],
  "route": {
    "rules": [
EOF

  if [[ -n "$domains_entries" ]]; then
    cat >> "$CONF_FILE" <<EOF
      {
        "outbound": "warp",
        "domain": [
$domains_entries
        ]
      }
EOF
  fi

  cat >> "$CONF_FILE" <<EOF
    ],
    "final": "${route_fallback}"
  },
  "dns": {
    "servers": [
      { "tag": "cloudflare", "address": "1.1.1.1" }
    ],
    "final": "cloudflare"
  }
}
EOF

  color g "配置已写入：$CONF_FILE"
}

install_service(){
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=sing-box 3-route (WARP/UPSTREAM/DIRECT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SB_BIN} run -c ${CONF_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}" || true
  systemctl restart "${SERVICE_NAME}" || true
  color g "systemd 服务已安装/启动：${SERVICE_NAME}"
}

# 写入 /usr/local/bin/3route 管理脚本（包含 build_config）
write_cli(){
  cat > "$BIN_PATH" <<'EOCLI'
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="/etc/sing-box-3route"
DOMAINS_FILE="$INSTALL_DIR/domains_warp.txt"
PROFILE_FILE="$INSTALL_DIR/wgcf-profile.conf"
CONF_FILE="$INSTALL_DIR/config.json"
UPSTREAM_FILE="$INSTALL_DIR/upstream.url"
SERVICE_NAME="sing-box-3route"
SB_BIN="/usr/local/bin/sing-box"

color(){ case "$1" in r) printf "\e[31m%s\e[0m\n" "$2";; g) printf "\e[32m%s\e[0m\n" "$2";; y) printf "\e[33m%s\e[0m\n" "$2";; c) printf "\e[36m%s\e[0m\n" "$2";; *) printf "%s\n" "$2";; esac }

parse_wgcf_profile(){
  if [[ ! -f "$PROFILE_FILE" ]]; then color r "wgcf profile not found: $PROFILE_FILE"; return 1; fi
  private_key=$(awk -F= '/^PrivateKey/ {gsub(/^ +| +$/,"",$2); print $2}' "$PROFILE_FILE" | tr -d '\r' | head -n1)
  address=$(awk -F= '/^Address/ {gsub(/^ +| +$/,"",$2); print $2}' "$PROFILE_FILE" | tr -d '\r' | head -n1)
  peer_pub=$(awk -F= '/^PublicKey/ {gsub(/^ +| +$/,"",$2); print $2}' "$PROFILE_FILE" | tr -d '\r' | head -n1)
  endpoint=$(awk -F= '/^Endpoint/ {gsub(/^ +| +$/,"",$2); print $2}' "$PROFILE_FILE" | tr -d '\r' | head -n1)
  mtu=$(awk -F= '/^MTU/ {gsub(/^ +| +$/,"",$2); print $2}' "$PROFILE_FILE" | tr -d '\r' | head -n1 || true)
  [[ -z "$mtu" ]] && mtu=1280
  if [[ "$endpoint" == *:* ]]; then server=${endpoint%:*}; server_port=${endpoint##*:}; else server="$endpoint"; server_port=2408; fi
  v4=$(echo "$address" | tr ',' '\n' | awk '/\./{gsub(/^ +| +$/,"",$0); print $0}' | head -n1)
  [[ -z "$v4" ]] && v4=$(echo "$address" | tr ',' '\n' | awk 'NF{print $0}' | head -n1)
}

build_config(){
  parse_wgcf_profile || return 1
  mkdir -p "$INSTALL_DIR"
  local domains_entries=""
  if [[ -s "$DOMAINS_FILE" ]]; then
    domains_entries=$(awk 'NF && $0 !~ /^#/ {print $0}' "$DOMAINS_FILE" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "      \"%s\",\n", $0}' | sed '$s/,$//')
  fi
  local upstream_block=""
  local route_fallback="direct"
  if [[ -f "$UPSTREAM_FILE" && -s "$UPSTREAM_FILE" ]]; then
    local up
    up=$(awk 'NR==1{print; exit}' "$UPSTREAM_FILE" | tr -d '\r\n')
    if [[ -n "$up" ]]; then
      local scheme rest userpass hostport user pass host port
      scheme="${up%%://*}"
      rest="${up#*://}"
      if [[ "$rest" == *"@"* ]]; then userpass="${rest%@*}"; hostport="${rest#*@}"; user="${userpass%%:*}"; pass="${userpass#*:}"; else hostport="$rest"; fi
      host="${hostport%%:*}"; port="${hostport##*:}"
      if [[ -z "$port" || "$port" == "$host" ]]; then
        if [[ "$scheme" == "socks5" ]]; then port=1080; else port=8080; fi
      fi
      if [[ "$scheme" == "socks5" ]]; then
        upstream_block=", { \"type\": \"socks\", \"tag\": \"upstream\", \"server\": \"${host}\", \"server_port\": ${port}$( [[ -n \"$user\" ]] && printf ', \"username\": \"%s\", \"password\": \"%s\"' \"$user\" \"$pass\" ) }"
        route_fallback="upstream"
      elif [[ "$scheme" == "http" ]]; then
        upstream_block=", { \"type\": \"http\", \"tag\": \"upstream\", \"server\": \"${host}\", \"server_port\": ${port}$( [[ -n \"$user\" ]] && printf ', \"username\": \"%s\", \"password\": \"%s\"' \"$user\" \"$pass\" ) }"
        route_fallback="upstream"
      else
        color y "仅支持 socks5:// 或 http:// 上游，忽略： $up"
      fi
    fi
  fi

  cat > "$CONF_FILE" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "$INSTALL_DIR/log/sing-box.log"
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
      "server": "${server}",
      "server_port": ${server_port},
      "local_address": ["${v4}"],
      "private_key": "${private_key}",
      "peer_public_key": "${peer_pub}",
      "mtu": ${mtu}
    },
    {
      "type": "direct",
      "tag": "direct"
    }${upstream_block}
  ],
  "route": {
    "rules": [
EOF

  if [[ -n "$domains_entries" ]]; then
    cat >> "$CONF_FILE" <<EOF
      {
        "outbound": "warp",
        "domain": [
$domains_entries
        ]
      }
EOF
  fi

  cat >> "$CONF_FILE" <<EOF
    ],
    "final": "${route_fallback}"
  },
  "dns": {
    "servers": [
      { "tag": "cloudflare", "address": "1.1.1.1" }
    ],
    "final": "cloudflare"
  }
}
EOF
  color g "已生成配置：$CONF_FILE"
}

cmd_add(){ [[ -z "${2:-}" ]] && d="$1" || d="$2"; mkdir -p "$INSTALL_DIR"; echo "$d" >> "$DOMAINS_FILE"; sort -u "$DOMAINS_FILE" -o "$DOMAINS_FILE"; build_config; systemctl restart "$SERVICE_NAME" || true; color g "已添加并重启：$d"; }
cmd_remove(){ local d="$1"; if [[ -z "$d" ]]; then color y "用法: 3route remove example.com"; return; fi; grep -Fxv "$d" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" || true; mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE" || true; build_config; systemctl restart "$SERVICE_NAME" || true; color g "已移除并重启：$d"; }
cmd_list(){ if [[ -s "$DOMAINS_FILE" ]]; then cat "$DOMAINS_FILE"; else echo "(空)"; fi }
cmd_set_upstream(){ echo "$1" > "$UPSTREAM_FILE"; build_config; systemctl restart "$SERVICE_NAME" || true; color g "已设置上游： $1"; }
cmd_unset_upstream(){ rm -f "$UPSTREAM_FILE"; build_config; systemctl restart "$SERVICE_NAME" || true; color g "已取消上游"; }
cmd_restart(){ systemctl restart "$SERVICE_NAME" || true; color g "服务已重启"; }
cmd_status(){ systemctl status "$SERVICE_NAME" --no-pager || true; }

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  list) cmd_list ;;
  set-upstream) shift; cmd_set_upstream "$1" ;;
  unset-upstream) cmd_unset_upstream ;;
  restart) cmd_restart ;;
  status) cmd_status ;;
  build) build_config ;;
  *) cat <<USAGE
3route 管理脚本
用法:
  3route add <domain>
  3route remove <domain>
  3route list
  3route set-upstream socks5://user:pass@host:port
  3route unset-upstream
  3route restart
  3route status
  3route build    # 仅重建 config.json（不重启）
USAGE
;;
esac
EOCLI

  chmod +x "$BIN_PATH"
  color g "管理脚本写入：$BIN_PATH"
}

clean_tmp(){ rm -rf "$TMPDIR" || true }

# 主安装流程
do_install(){
  need_root
  detect_arch >/dev/null
  ensure_pkgs
  init_layout
  install_singbox || true
  install_wgcf || true
  init_warp || true
  # 生成初始配置（会从 wgcf-profile.conf 中读取）
  build_config || true
  write_cli
  install_service
  clean_tmp
  color g "安装完成。管理命令：3route"
  cat <<EOF
默认本地代理监听：127.0.0.1:7890 (mixed, 支持 HTTP/SOCKS)
域名清单： $DOMAINS_FILE
配置文件： $CONF_FILE
wgcf profile： $PROFILE_FILE
EOF
}

case "${1:-}" in
  install) do_install ;;
  *) cat <<USAGE
三通道域名分流(独立版) 一键脚本
用法:
  $0 install    # 安装/初始化并启动
安装后使用：
  3route add example.com
  3route list
  3route set-upstream socks5://127.0.0.1:1080
  3route restart
USAGE
  ;;
esac
