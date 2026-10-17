#!/usr/bin/env bash
# tts-server-rust 安装 / 管理脚本（含交互菜单）
#
# 用法：
#   交互（有菜单）：
#     bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/edge-tts-rust/main/install.sh)
#   一键（环境变量）：
#     PORT=8080 TTS_TOKEN=xxxx DOMAIN=tts.example.com bash install.sh
#   子命令：
#     bash install.sh install | uninstall | start | stop | status | logs | change-port | setup-caddy | menu
#
# 说明：
#   - 自动检测架构，从 GitHub Releases 下载对应预编译二进制
#   - 反代可选项：DOMAIN 留空则直接用 IP:端口+token（个人使用足够，无需 HTTPS/域名）
#   - 交互读取统一走 /dev/tty，解决 curl|bash 场景下菜单无输入的问题

set -euo pipefail

REPO="aucrazy-p/edge-tts-rust"
BIN="tts-server-rust"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
CONFIG_FILE="/etc/$BIN.conf"

# ---------- 通用工具 ----------
if [ -e /dev/tty ]; then
  _ask() { local p="$1"; read -r -p "$p" _V < /dev/tty; printf '%s' "$_V"; }
else
  _ask() { local p="$1"; read -r _V; printf '%s' "$_V"; }
fi
info(){ echo -e "\033[32m==>\033[0m $*"; }
warn(){ echo -e "\033[33m!!\033[0m $*"; }
err(){ echo -e "\033[31m✗\033[0m $*" >&2; }

gen_token(){
  openssl rand -hex 16 2>/dev/null \
    || head -c16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' \
    || echo "$(date +%s)-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' ')"
}

detect_arch(){
  local a s
  a="$(uname -m)"; s="$(uname -s)"; SUFFIX=""
  case "$s" in
    Linux)
      case "$a" in
        x86_64) SUFFIX="linux-x86_64" ;;
        aarch64|arm64) SUFFIX="linux-aarch64" ;;
        *) err "不支持的架构: $a（仅支持 x86_64 / aarch64）"; exit 1 ;;
      esac ;;
    *) err "仅支持 Linux；Windows/macOS 请到 Releases 手动下载"; exit 1 ;;
  esac
}

load_config(){
  [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
  PORT="${PORT:-8080}"
  TTS_TOKEN="${TTS_TOKEN:-}"
  DOMAIN="${DOMAIN:-}"
}

persist_config(){
  cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
TTS_TOKEN=$TTS_TOKEN
DOMAIN=$DOMAIN
EOF
}

service_addr(){
  if [ -n "${DOMAIN:-}" ]; then
    printf 'https://%s?token=%s' "$DOMAIN" "$TTS_TOKEN"
  else
    local ip
    ip="$(curl -fsSL https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
    printf 'http://%s:%s?token=%s' "$ip" "$PORT" "$TTS_TOKEN"
  fi
}

show_addr(){
  load_config
  local addr; addr="$(service_addr)"
  echo
  echo "========================================================="
  echo " legado_NG 『自托管 Edge TTS』引擎 → 『服务地址』填写："
  echo "   $addr"
  echo "========================================================="
}

# ---------- 动作 ----------
do_install(){
  detect_arch
  local port_env="${PORT:-}"
  local token_env="${TTS_TOKEN:-}"
  local fresh=1; [ -f "$CONFIG_FILE" ] || fresh=0
  load_config
  local force="${FORCE_PROMPT:-0}"

  # 令牌：仅首次安装（无旧配置）或强制时询问；更新时沿用已有令牌
  if { [ "$fresh" = "0" ] && [ -z "$token_env" ] && [ -z "$TTS_TOKEN" ]; } || [ "$force" = "1" ]; then
    local cur=""; [ -n "$TTS_TOKEN" ] && cur=" [当前: $TTS_TOKEN]"
    local t; t="$(_ask "访问令牌$cur（留空随机生成）: ")"
    [ -n "$t" ] && TTS_TOKEN="$t"
    [ -z "$TTS_TOKEN" ] && TTS_TOKEN="$(gen_token)"
  fi

  # 监听端口：同上，仅首次/强制询问
  if { [ "$fresh" = "0" ] && [ -z "$port_env" ]; } || [ "$force" = "1" ]; then
    local cur=""; [ -n "${PORT:-}" ] && cur=" [当前: $PORT]"
    local p; p="$(_ask "监听端口$cur（默认 8080；仅填防火墙已开放的端口，如 80/443）: ")"
    [ -n "$p" ] && PORT="$p"
  fi
  PORT="${PORT:-8080}"

  # 反代域名：同上，仅首次/强制询问
  if { { [ "$fresh" = "0" ] && [ -z "${DOMAIN:-}" ] && [ "${NO_DOMAIN:-0}" != "1" ]; } || [ "$force" = "1" ]; }; then
    local d; d="$(_ask "反向代理域名（留空=不反代，直接用 IP:端口+token，个人使用足够）: ")"
    [ -n "$d" ] && DOMAIN="$d"
  fi

  # 下载二进制
  info "获取最新 release ..."
  local api="https://api.github.com/repos/$REPO/releases/latest"
  local asset="tts-server-rust-$SUFFIX"
  local url=""
  url="$(curl -fsSL "$api" 2>/dev/null | grep -o "\"browser_download_url\": *\"[^\"]*$asset[^\"]*\"" | grep -o 'https://[^"]*' | head -1)" || true
  if [ -z "$url" ]; then
    err "未找到资产 $asset，请确认 release 已发布（打 v* tag 触发自动构建）"
    exit 1
  fi
  info "下载 $url"
  curl -fL "$url" -o "$INSTALL_DIR/$BIN"
  chmod +x "$INSTALL_DIR/$BIN"
  info "已安装到 $INSTALL_DIR/$BIN"

  persist_config

  # systemd 服务
  if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
    cat > "/etc/systemd/system/$BIN.service" <<EOF
[Unit]
Description=tts-server-rust (Edge TTS for legado_NG)
After=network.target

[Service]
Environment=TTS_TOKEN=$TTS_TOKEN
Environment=PORT=$PORT
ExecStart=$INSTALL_DIR/$BIN
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$BIN.service"
    info "已启动 systemd 服务 $BIN.service"
  elif [ -z "${DOMAIN:-}" ]; then
    warn "未检测到 systemd，请手动后台运行: TTS_TOKEN=$TTS_TOKEN PORT=$PORT $INSTALL_DIR/$BIN"
  fi

  # 反向代理（可选项）
  if [ -n "${DOMAIN:-}" ]; then
    if ! command -v caddy >/dev/null 2>&1; then
      info "安装 Caddy ..."
      curl -fsSL https://get.caddy.com | bash
    fi
    mkdir -p /etc/caddy
    cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
  reverse_proxy localhost:$PORT
}
EOF
    caddy reload --config /etc/caddy/Caddyfile || caddy start --config /etc/caddy/Caddyfile
    info "已配置 Caddy 反代 https://$DOMAIN"
  fi

  show_addr
}

do_uninstall(){
  detect_arch
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$BIN.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/$BIN.service"
    systemctl daemon-reload 2>/dev/null || true
  fi
  pkill -f "$INSTALL_DIR/$BIN" 2>/dev/null || true
  rm -f "$INSTALL_DIR/$BIN" "$CONFIG_FILE"
  warn "已卸载 $BIN（如启用过 Caddy，请手动清理 /etc/caddy/Caddyfile）"
}

do_start(){
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start "$BIN.service" && info "已启动"
  else
    load_config
    nohup env TTS_TOKEN="$TTS_TOKEN" PORT="$PORT" "$INSTALL_DIR/$BIN" >"/var/log/$BIN.log" 2>&1 &
    info "已后台启动 (PID $!)"
  fi
}

do_stop(){
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$BIN.service" && info "已停止"
  else
    pkill -f "$INSTALL_DIR/$BIN" && info "已停止" || warn "未运行"
  fi
}

do_status(){
  if command -v systemctl >/dev/null 2>&1; then
    systemctl status "$BIN.service" --no-pager || true
  else
    pgrep -af "$INSTALL_DIR/$BIN" || warn "未运行"
  fi
  show_addr
}

do_logs(){
  if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/$BIN.service" ]; then
    journalctl -u "$BIN.service" -n 100 --no-pager
  elif [ -f "/var/log/$BIN.log" ]; then
    tail -n 100 "/var/log/$BIN.log"
  else
    warn "未找到日志（可能尚未运行或日志未落盘）"
  fi
}

do_setup_caddy(){
  load_config
  local d; d="$(_ask "对外访问域名（https，留空取消）: ")"
  [ -z "$d" ] && { warn "已取消"; return; }
  DOMAIN="$d"
  persist_config
  if ! command -v caddy >/dev/null 2>&1; then
    info "安装 Caddy ..."
    curl -fsSL https://get.caddy.com | bash
  fi
  mkdir -p /etc/caddy
  cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
  reverse_proxy localhost:$PORT
}
EOF
  caddy reload --config /etc/caddy/Caddyfile || caddy start --config /etc/caddy/Caddyfile
  info "已配置 Caddy 反代 https://$DOMAIN"
  show_addr
}

do_change_port(){
  load_config
  local cur="${PORT:-8080}"
  local np; np="$(_ask "新监听端口（当前: $cur，填防火墙已开放的端口，如 80/443）: ")"
  [ -z "$np" ] && { warn "未输入，已取消"; return; }
  if ! [[ "$np" =~ ^[0-9]+$ ]] || [ "$np" -lt 1 ] || [ "$np" -gt 65535 ]; then
    err "端口必须是 1-65535 之间的数字"; return
  fi
  PORT="$np"
  persist_config
  info "已写入配置 PORT=$PORT"
  # 若启用反代，同步 Caddy 反代端口
  if [ -n "${DOMAIN:-}" ] && [ -f /etc/caddy/Caddyfile ]; then
    sed -i "s/reverse_proxy localhost:[0-9]*/reverse_proxy localhost:$PORT/" /etc/caddy/Caddyfile
    caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
    info "已同步 Caddy 反代端口"
  fi
  if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/$BIN.service" ]; then
    sed -i "s/^Environment=PORT=.*/Environment=PORT=$PORT/" "/etc/systemd/system/$BIN.service"
    systemctl daemon-reload
    systemctl restart "$BIN.service" && info "已重启服务（新端口 $PORT）"
  else
    warn "非 systemd 环境，重启进程以应用新端口"
    do_stop 2>/dev/null
    do_start
  fi
  show_addr
}

show_menu(){
  while true; do
    echo
    echo "====== tts-server-rust 管理菜单 ======"
    echo " 1) 安装 install"
    echo " 2) 卸载 uninstall"
    echo " 3) 启动 start"
    echo " 4) 停止 stop"
    echo " 5) 状态 status"
    echo " 6) 查看日志 logs"
    echo " 7) 更新 update"
    echo " 8) 更改端口 change-port"
    echo " 9) 对外访问配置 setup-caddy"
    echo " 0) 退出"
    echo "========================================"
    local sel; sel="$(_ask "请选择 [0-9]: ")"
    case "$sel" in
      1) do_install ;;
      2) do_uninstall ;;
      3) do_start ;;
      4) do_stop ;;
      5) do_status ;;
      6) do_logs ;;
      7) do_install ;;
      8) do_change_port ;;
      9) do_setup_caddy ;;
      0|"") exit 0 ;;
      *) warn "无效选择: $sel，请重试" ;;
    esac
  done
}

# ---------- 入口 ----------
case "${1:-}" in
  install|update) FORCE_PROMPT=0 do_install ;;
  uninstall)      do_uninstall ;;
  start)          do_start ;;
  stop)           do_stop ;;
  status)         do_status ;;
  logs)           do_logs ;;
  change-port)    do_change_port ;;
  setup-caddy)    do_setup_caddy ;;
  addr)           show_addr ;;
  menu)           show_menu ;;
  "")
    # 交互且有 tty → 菜单；否则（纯管道/CI）一键安装，token 随机
    if [ -e /dev/tty ] && [ -z "${PORT:-}" ] && [ -z "${TTS_TOKEN:-}" ]; then
      show_menu
    else
      FORCE_PROMPT=0 NO_DOMAIN="${NO_DOMAIN:-0}" do_install
    fi
    ;;
  *) warn "未知参数: $1"; echo "用法: $0 [install|uninstall|start|stop|status|logs|change-port|setup-caddy|menu]"; exit 1 ;;
esac
