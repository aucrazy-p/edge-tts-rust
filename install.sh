#!/usr/bin/env bash
# tts-server-rust 安装 / 管理脚本（含交互菜单）
#
# 用法：
#   交互（有菜单）：
#     bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/edge-tts-rust/main/install.sh)
#   一键（环境变量）：
#     TTS_TOKEN=xxxx bash install.sh
#   子命令：
#     bash install.sh install | uninstall | start | stop | status | logs | change-port | setup-caddy | menu
#
# 说明：
#   - 自动检测架构，从 GitHub Releases 下载对应预编译二进制
#   - 默认监听端口为随机高位端口（30000-59999），避开 8080 等被全网扫描的端口
#   - 访问令牌自动随机生成，绝不允许为空（为空时服务端完全不鉴权）
#   - 反代可选项：DOMAIN 留空则直接用 IP:端口+token（个人使用足够，无需 HTTPS/域名）
#   - 交互读取统一走 /dev/tty，解决 curl|bash 场景下菜单无输入的问题

set -euo pipefail

REPO="aucrazy-p/edge-tts-rust"
BIN="tts-server-rust"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
CONFIG_FILE="/etc/$BIN.conf"
# 默认端口不再用 8080：那是全网扫描器的主要靶场，改为随机高位端口
PORT_RANGE_MIN=30000
PORT_RANGE_MAX=59999

# ---------- 通用工具 ----------
if [ -e /dev/tty ]; then
  # read 遇 Ctrl-D/EOF 会返回非 0，set -e 下会让整个脚本直接退出；这里兜住
  _ask() { local p="$1" v=""; read -r -p "$p" v < /dev/tty || true; printf '%s' "$v"; }
else
  _ask() { local p="$1" v=""; read -r v || true; printf '%s' "$v"; }
fi
info(){ echo -e "\033[32m==>\033[0m $*"; }
warn(){ echo -e "\033[33m!!\033[0m $*"; }
err(){ echo -e "\033[31m✗\033[0m $*" >&2; }

gen_token(){
  openssl rand -hex 16 2>/dev/null \
    || head -c16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' \
    || echo "$(date +%s)-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' ')"
}

gen_port(){
  local span=$((PORT_RANGE_MAX - PORT_RANGE_MIN + 1)) p
  p=$(( (RANDOM * 32768 + RANDOM) % span + PORT_RANGE_MIN ))
  echo "$p"
}

# 端口是否被监听：ss → lsof → /dev/tcp 三级回退
port_in_use(){
  local p="${1:-}"
  [ -n "$p" ] || return 1
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$p\$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  else
    (exec 3<>/dev/tcp/127.0.0.1/"$p") >/dev/null 2>&1
  fi
}

valid_port(){
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 域名白名单：挡住 $(...)、反引号、空格、协议前缀等一切注入形态
valid_domain(){
  printf '%s' "${1:-}" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
}

# 令牌字符集：只允许十六进制/字母数字/下划线/连字符，避免写进 systemd unit 时出错
valid_token(){
  printf '%s' "${1:-}" | grep -qE '^[A-Za-z0-9_-]{8,128}$'
}

pkg_install(){
  command -v apt-get >/dev/null 2>&1 || return 0
  local need="" p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"
  done
  [ -z "$need" ] && return 0
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $need
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
  # 绝不 source 配置文件：令牌和域名都是用户输入的，source 会把值里的
  # $(...)/反引号当命令执行（旧版实测可被 `$(touch PWNED)` 触发）。
  # 改为纯文本逐行解析，值永远只是字符串。
  local env_port="${PORT:-}" env_token="${TTS_TOKEN:-}" env_domain="${DOMAIN:-}"
  PORT=""; TTS_TOKEN=""; DOMAIN=""

  if [ -f "$CONFIG_FILE" ]; then
    local line k v
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in ''|'#'*) continue ;; esac
      k="${line%%=*}"; v="${line#*=}"
      # 去掉写入时包的单引号
      case "$v" in \'*\') v="${v#\'}"; v="${v%\'}";; esac
      case "$k" in
        PORT)      PORT="$v" ;;
        TTS_TOKEN) TTS_TOKEN="$v" ;;
        DOMAIN)    DOMAIN="$v" ;;
      esac
    done < "$CONFIG_FILE"
  fi

  # 优先级：环境变量 > 配置文件 > 随机高位端口
  [ -n "$env_port" ]   && PORT="$env_port"
  [ -n "$env_token" ]  && TTS_TOKEN="$env_token"
  [ -n "$env_domain" ] && DOMAIN="$env_domain"

  case "${PORT:-}" in ''|*[!0-9]*) PORT="" ;; esac
  [ -n "${PORT:-}" ] || PORT="$(gen_port)"
  TTS_TOKEN="${TTS_TOKEN:-}"
  DOMAIN="${DOMAIN:-}"
}

persist_config(){
  # 值统一单引号包裹并转义内部单引号；即便有人手动 source 也只是字面量。
  # 权限 600：文件里有明文访问令牌。
  {
    printf 'PORT=%s\n' "${PORT:-}"
    printf "TTS_TOKEN='%s'\n" "$(printf '%s' "${TTS_TOKEN:-}" | sed "s/'/'\\\\''/g")"
    printf "DOMAIN='%s'\n"    "$(printf '%s' "${DOMAIN:-}"    | sed "s/'/'\\\\''/g")"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

service_addr(){
  if [ -n "${DOMAIN:-}" ]; then
    printf 'https://%s?token=%s' "$DOMAIN" "$TTS_TOKEN"
  else
    local ip=""
    ip="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
          || hostname -I 2>/dev/null | awk '{print $1}')" || true
    [ -n "$ip" ] || ip="<服务器IP>"
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
install_caddy(){
  command -v caddy >/dev/null 2>&1 && return 0
  # 旧版用的 https://get.caddy.com 是死链（三个 DNS 均 NXDOMAIN），
  # 且 curl|bash 执行外部内容本身有供应链风险。改用官方 Cloudsmith 仓库。
  info "安装 Caddy（官方 apt 仓库）..."
  if command -v apt-get >/dev/null 2>&1; then
    pkg_install debian-keyring debian-archive-keyring apt-transport-https gpg || true
    if curl -1sLf --max-time 60 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
         | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null; then
      if curl -1sLf --max-time 60 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
           -o /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null; then
        apt-get update -qq || true
        apt-get install -y -qq caddy || true
      fi
      command -v caddy >/dev/null 2>&1 && return 0
    fi
  fi
  err "Caddy 自动安装失败，请手动安装后重试：https://caddyserver.com/docs/install"
  return 1
}

apply_caddy_conf(){
  mkdir -p /etc/caddy
  cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
  reverse_proxy 127.0.0.1:$PORT
}
EOF
  if ! caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    err "Caddyfile 校验失败（检查域名格式与端口）"
    return 1
  fi
  # apt 装的 caddy 由 systemd 托管：优先 reload/restart，
  # 绝不再用 `caddy start` 起第二个实例（会和 systemd 抢端口）
  if systemctl list-unit-files 2>/dev/null | grep -q '^caddy\.service'; then
    systemctl reload-or-restart caddy 2>/dev/null || systemctl restart caddy
  else
    caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
      || caddy start --config /etc/caddy/Caddyfile
  fi
}

install_binary(){
  detect_arch
  local asset="tts-server-rust-$SUFFIX"
  local tmp; tmp="$(mktemp -d)"
  local base="https://github.com/$REPO/releases/latest/download"
  local direct="$base/$asset" url=""

  info "获取最新 release ..."
  # 直链优先：GitHub API 未认证只有 60 次/小时，命中限流就装不上
  if curl -fL --max-time 300 --retry 2 --retry-delay 3 "$direct" -o "$tmp/bin" 2>/dev/null \
     && [ -s "$tmp/bin" ]; then
    url="$direct"
  else
    local api="https://api.github.com/repos/$REPO/releases/latest"
    url="$(curl -fsSL --max-time 25 "$api" 2>/dev/null \
           | grep -o "\"browser_download_url\": *\"[^\"]*$asset[^\"]*\"" \
           | grep -o 'https://[^"]*' | head -1)" || true
    if [ -z "$url" ]; then
      err "未找到资产 $asset，请确认 release 已发布（打 v* tag 触发自动构建）"
      rm -rf "$tmp"; exit 1
    fi
    info "下载 $url"
    curl -fL --max-time 300 --retry 2 --retry-delay 3 "$url" -o "$tmp/bin" \
      || { err "下载失败"; rm -rf "$tmp"; exit 1; }
    base="$(dirname "$url")"
  fi

  # 有 SHA256SUMS 就校验（发布流程产出该校验文件后自动生效）
  if curl -fsSL --max-time 20 "$base/SHA256SUMS" -o "$tmp/sums" 2>/dev/null; then
    local want="" got=""
    # grep 无匹配会返回 1，pipefail 下会让整个赋值语句失败并触发 set -e，必须兜住
    want="$(grep -E "(^|[[:space:]/])$asset\$" "$tmp/sums" | awk '{print $1}' | head -1)" || true
    got="$(sha256sum "$tmp/bin" 2>/dev/null | awk '{print $1}')" || true
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      err "SHA256 校验失败（期望 $want，实际 $got）"
      rm -rf "$tmp"; exit 1
    fi
    [ -n "$want" ] && info "SHA256 校验通过"
  fi

  # 先落到同目录临时名再原子替换：下载中断不会毁掉已装版本
  if command -v install >/dev/null 2>&1; then
    install -m 0755 "$tmp/bin" "$INSTALL_DIR/.$BIN.new"
  else
    cp -f "$tmp/bin" "$INSTALL_DIR/.$BIN.new"
    chmod 0755 "$INSTALL_DIR/.$BIN.new"
  fi
  mv -f "$INSTALL_DIR/.$BIN.new" "$INSTALL_DIR/$BIN"
  rm -rf "$tmp"
  info "已安装到 $INSTALL_DIR/$BIN"
}

do_install(){
  detect_arch
  local port_env="${PORT:-}"
  local token_env="${TTS_TOKEN:-}"
  # 变量名属历史遗留：fresh=0 表示"尚未安装过"（无配置文件）
  local fresh=1; [ -f "$CONFIG_FILE" ] || fresh=0
  load_config
  local force="${FORCE_PROMPT:-0}"

  # 令牌：仅首次安装（无旧配置）或强制时询问；更新时沿用已有令牌
  if { [ "$fresh" = "0" ] && [ -z "$token_env" ] && [ -z "$TTS_TOKEN" ]; } || [ "$force" = "1" ]; then
    local cur=""; [ -n "$TTS_TOKEN" ] && cur=" [当前: $TTS_TOKEN]"
    local t; t="$(_ask "访问令牌$cur（留空随机生成）: ")"
    [ -n "$t" ] && TTS_TOKEN="$t"
  fi
  # 令牌绝不允许为空：Rust 端 token 为空时会完全跳过鉴权，等于服务裸奔
  if [ -z "${TTS_TOKEN:-}" ]; then
    TTS_TOKEN="$(gen_token)"
    info "已生成随机访问令牌"
  fi
  if ! valid_token "$TTS_TOKEN"; then
    err "令牌格式非法：只允许字母、数字、下划线、连字符，长度 8-128"
    exit 1
  fi

  # 监听端口：同上，仅首次/强制询问
  if { [ "$fresh" = "0" ] && [ -z "$port_env" ]; } || [ "$force" = "1" ]; then
    local pcur=""; [ -n "${PORT:-}" ] && pcur=" [当前: $PORT]"
    local p; p="$(_ask "监听端口$pcur（留空=随机 $PORT_RANGE_MIN-$PORT_RANGE_MAX，避开 8080 等常扫端口）: ")"
    [ -n "$p" ] && PORT="$p"
  fi
  if ! valid_port "$PORT"; then
    err "端口非法：$PORT（必须是 1-65535 的数字）"; exit 1
  fi
  if port_in_use "$PORT"; then
    local alt; alt="$(gen_port)"
    while port_in_use "$alt"; do alt="$(gen_port)"; done
    warn "端口 $PORT 已被占用，改用空闲端口 $alt"
    PORT="$alt"
  fi
  info "监听端口：$PORT"

  # 反代域名：同上，仅首次/强制询问
  if { { [ "$fresh" = "0" ] && [ -z "${DOMAIN:-}" ] && [ "${NO_DOMAIN:-0}" != "1" ]; } || [ "$force" = "1" ]; }; then
    local d; d="$(_ask "反向代理域名（留空=不反代，直接用 IP:端口+token，个人使用足够）: ")"
    if [ -n "$d" ]; then
      if ! valid_domain "$d"; then
        err "域名格式非法：只允许字母、数字、点、连字符"; exit 1
      fi
      DOMAIN="$d"
    fi
  fi

  install_binary
  persist_config

  # systemd 服务
  if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
    cat > "/etc/systemd/system/$BIN.service" <<EOF
[Unit]
Description=tts-server-rust (Edge TTS for legado_NG)
After=network.target

[Service]
Environment="TTS_TOKEN=$TTS_TOKEN"
Environment="PORT=$PORT"
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
    if install_caddy && apply_caddy_conf; then
      info "已配置 Caddy 反代 https://$DOMAIN"
    else
      warn "Caddy 未配置成功，但服务本身仍在端口 $PORT 正常监听"
    fi
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

ensure_token(){
  # Rust 端 token 为空 = 完全不鉴权，所以任何启动路径都必须先保证非空
  load_config
  if [ -z "${TTS_TOKEN:-}" ]; then
    TTS_TOKEN="$(gen_token)"
    persist_config
    warn "原配置中令牌为空（服务等于裸奔），已生成新令牌"
  fi
  if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/$BIN.service" ]; then
    # 兼容带引号与旧式不带引号两种 unit 写法
    sed -i "s|^Environment=\"\?TTS_TOKEN=.*|Environment=\"TTS_TOKEN=$TTS_TOKEN\"|" \
      "/etc/systemd/system/$BIN.service" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
  fi
}

do_start(){
  ensure_token
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start "$BIN.service" && info "已启动"
  else
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
  if ! valid_domain "$d"; then
    err "域名格式非法：只允许字母、数字、点、连字符"; return 1
  fi
  DOMAIN="$d"
  persist_config
  if ! install_caddy; then
    warn "Caddy 未安装，反代未配置（服务仍在端口 $PORT 正常监听）"
    return 1
  fi
  if apply_caddy_conf; then
    info "已配置 Caddy 反代 https://$DOMAIN"
  else
    warn "Caddy 配置失败，服务仍在端口 $PORT 正常监听"
    return 1
  fi
  show_addr
}

do_change_port(){
  load_config
  local cur="${PORT:-}"
  local np; np="$(_ask "新监听端口（当前: $cur，填防火墙已开放的端口，如 80/443）: ")"
  [ -z "$np" ] && { warn "未输入，已取消"; return; }
  if ! valid_port "$np"; then
    err "端口必须是 1-65535 之间的数字"; return
  fi
  if [ "$np" != "$cur" ] && port_in_use "$np"; then
    err "端口 $np 已被占用，请换一个"; return
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
