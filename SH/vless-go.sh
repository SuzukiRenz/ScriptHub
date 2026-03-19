#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║          VLESS Personal Edition  v2.0                            ║
# ║  支持系统: Debian / Ubuntu / Alpine                               ║
# ║  代理核心: Xray-core  或  sing-box（安装时选择）                  ║
# ║  TLS前端:  Caddy（自动申请/续签 Let's Encrypt 证书 + 伪装网站）   ║
# ║  默认协议: VLESS + WebSocket + TLS                                ║
# ║  对外端口: 8443（Caddy TLS）                                      ║
# ║  内部端口: 随机本地端口（代理核心明文 WS 监听）                    ║
# ║  WS 路径:  由域名首段自动生成，例 proxy.xx.com → /proxy           ║
# ║  下载源:   Xray     → github.com/XTLS/Xray-core/releases         ║
# ║            sing-box → github.com/SagerNet/sing-box/releases      ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── 颜色 ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }
step()  { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
hr()    { echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"; }

# ── 常量 ─────────────────────────────────────────────────────────────
CONF_DIR="/etc/vless-personal"
CONF_FILE="${CONF_DIR}/config.env"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/etc/xray"
XRAY_CONF="${XRAY_CONF_DIR}/config.json"

SBOX_BIN="/usr/local/bin/sing-box"
SBOX_CONF_DIR="/etc/sing-box"
SBOX_CONF="${SBOX_CONF_DIR}/config.json"

CADDY_CONF_DIR="/etc/caddy"
CADDY_MAIN_CONF="${CADDY_CONF_DIR}/Caddyfile"
CADDY_VLESS_CONF="${CADDY_CONF_DIR}/vless-personal.Caddyfile"

FAKE_WEBROOT="/var/www/vless-fake"
SHORTCUT="/usr/local/bin/vless-p"
EXT_PORT=8443

# ═══════════════════════════════════════════════════════════════════
#  工具函数
# ═══════════════════════════════════════════════════════════════════

check_root() {
    [[ $EUID -ne 0 ]] && error "请以 root 运行: sudo bash $0"
}

detect_os() {
    [[ -f /etc/os-release ]] || error "无法识别操作系统"
    source /etc/os-release
    OS_ID="${ID}"
    case "$OS_ID" in
        debian|ubuntu) PKG_MGR="apt";  INIT_SYS="systemd" ;;
        alpine)        PKG_MGR="apk";  INIT_SYS="openrc"  ;;
        *) error "不支持的系统: ${OS_ID}。本脚本仅支持 Debian / Ubuntu / Alpine" ;;
    esac
}

pkg_update() {
    [[ "$PKG_MGR" == "apt" ]] && apt-get update -qq 2>/dev/null \
                               || apk update -q 2>/dev/null
}

pkg_install() {
    if [[ "$PKG_MGR" == "apt" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
    else
        apk add --quiet "$@"
    fi
}

# CPU 架构 → Xray Release 包名后缀
xray_arch() {
    case "$(uname -m)" in
        x86_64)        echo "64"        ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7*)        echo "arm32-v7a" ;;
        armv6*)        echo "arm32-v6"  ;;
        *) error "Xray 不支持该 CPU 架构: $(uname -m)" ;;
    esac
}

# CPU 架构 → sing-box Release 包名后缀
sbox_arch() {
    case "$(uname -m)" in
        x86_64)        echo "amd64"  ;;
        aarch64|arm64) echo "arm64"  ;;
        armv7*)        echo "armv7"  ;;
        armv6*)        echo "armv6"  ;;
        *) error "sing-box 不支持该 CPU 架构: $(uname -m)" ;;
    esac
}

gen_uuid() {
    if   command -v uuidgen &>/dev/null;               then uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -r /proc/sys/kernel/random/uuid ]];         then cat /proc/sys/kernel/random/uuid
    elif command -v python3 &>/dev/null;               then python3 -c "import uuid; print(uuid.uuid4())"
    else
        local N B C='89ab'
        for (( N=0; N<16; N++ )); do
            B=$(( RANDOM%256 ))
            case $N in
                6)      printf '4%x'  $(( B%16 )) ;;
                8)      printf '%c%x' "${C:$((RANDOM%${#C})):1}" $(( B%16 )) ;;
                3|5|7|9) printf '%02x-' $B ;;
                *)      printf '%02x'  $B ;;
            esac
        done; echo
    fi
}

random_local_port() {
    local port
    for _ in {1..30}; do
        port=$(shuf -i 10000-59999 -n 1 2>/dev/null || \
               awk 'BEGIN{srand();print int(rand()*49999)+10000}')
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}$" || \
            { echo "$port"; return; }
    done
    error "无法分配随机本地端口，请检查端口占用"
}

ws_path_from_domain() { echo "/${1%%.*}"; }

is_installed() { [[ -f "$CONF_FILE" ]] && grep -q "^uuid=" "$CONF_FILE"; }

load_conf() {
    [[ -f "$CONF_FILE" ]] || return 1
    source "$CONF_FILE"
}

service_cmd() {
    local action="$1" svc="$2"
    if [[ "$INIT_SYS" == "systemd" ]]; then systemctl "$action" "$svc" 2>/dev/null
    else                                    rc-service  "$svc" "$action" 2>/dev/null; fi
}

service_enable() {
    if [[ "$INIT_SYS" == "systemd" ]]; then systemctl enable "$1" 2>/dev/null
    else                                    rc-update add "$1" default 2>/dev/null; fi
}

service_is_active() {
    if [[ "$INIT_SYS" == "systemd" ]]; then systemctl is-active --quiet "$1" 2>/dev/null
    else rc-service "$1" status 2>/dev/null | grep -q started; fi
}

get_server_ip() {
    curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null ||
    curl -s4 --max-time 5 https://ifconfig.me   2>/dev/null ||
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}' ||
    hostname -I 2>/dev/null | awk '{print $1}'
}

# 根据已安装的核心类型返回服务名
proxy_svc_name() {
    load_conf 2>/dev/null
    [[ "${core_type:-xray}" == "singbox" ]] && echo "sing-box" || echo "xray"
}

# ═══════════════════════════════════════════════════════════════════
#  安装基础依赖
# ═══════════════════════════════════════════════════════════════════

install_base_deps() {
    step "安装基础依赖"
    pkg_update
    if [[ "$PKG_MGR" == "apt" ]]; then
        pkg_install curl wget unzip tar iproute2 openssl ca-certificates gnupg lsb-release
    else
        pkg_install curl wget unzip tar iproute2 openssl ca-certificates util-linux
    fi
    info "基础依赖完成"
}

# ═══════════════════════════════════════════════════════════════════
#  安装 Caddy（官方包源）
# ═══════════════════════════════════════════════════════════════════

install_caddy() {
    step "安装 Caddy"
    if command -v caddy &>/dev/null; then
        info "Caddy 已存在 ($(caddy version 2>/dev/null | head -1))，跳过"
        echo "caddy_preinstalled=true" >> "$CONF_FILE"
        return
    fi

    if [[ "$PKG_MGR" == "apt" ]]; then
        pkg_install debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
        pkg_update && pkg_install caddy
    else
        apk add --quiet --repository https://dl-cdn.alpinelinux.org/alpine/edge/community caddy \
            || apk add --quiet caddy
    fi

    echo "caddy_preinstalled=false" >> "$CONF_FILE"
    info "Caddy 安装完成: $(caddy version 2>/dev/null | head -1)"
}

# ═══════════════════════════════════════════════════════════════════
#  安装 Xray-core
#  官方仓库: https://github.com/XTLS/Xray-core/releases
#  包格式:   Xray-linux-{arch}.zip
# ═══════════════════════════════════════════════════════════════════

install_xray() {
    step "安装 Xray-core"
    local ARCH TMP_DIR VER URL

    ARCH=$(xray_arch)
    TMP_DIR=$(mktemp -d)

    info "查询最新版本..."
    VER=$(curl -s --max-time 10 \
          "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
          | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    [[ -z "$VER" ]] && VER="v25.3.6"

    # 官方 Release 直链
    URL="https://github.com/XTLS/Xray-core/releases/download/${VER}/Xray-linux-${ARCH}.zip"
    info "下载 Xray ${VER}  arch=${ARCH}"
    info "源: ${URL}"

    wget -qO "${TMP_DIR}/xray.zip" "$URL" \
        || error "Xray 下载失败，请检查网络"

    unzip -qo "${TMP_DIR}/xray.zip" -d "${TMP_DIR}/out"
    install -m 755 "${TMP_DIR}/out/xray" "$XRAY_BIN"

    mkdir -p /usr/local/share/xray
    for f in geoip.dat geosite.dat; do
        [[ -f "${TMP_DIR}/out/${f}" ]] && \
            install -m 644 "${TMP_DIR}/out/${f}" "/usr/local/share/xray/${f}" || true
    done
    rm -rf "$TMP_DIR"
    info "Xray 安装完成: $("$XRAY_BIN" version 2>&1 | head -1)"
}

# ═══════════════════════════════════════════════════════════════════
#  安装 sing-box
#  官方仓库: https://github.com/SagerNet/sing-box/releases
#  包格式:   sing-box-{ver}-linux-{arch}.tar.gz
# ═══════════════════════════════════════════════════════════════════

install_singbox() {
    step "安装 sing-box"
    local ARCH TMP_DIR VER VER_NUM PKG_NAME URL

    ARCH=$(sbox_arch)
    TMP_DIR=$(mktemp -d)

    info "查询最新稳定版本..."
    # 过滤 alpha / beta / rc，只取正式 release
    VER=$(curl -s --max-time 10 \
          "https://api.github.com/repos/SagerNet/sing-box/releases" \
          | grep '"tag_name"' \
          | grep -v 'alpha\|beta\|rc' \
          | head -1 \
          | cut -d'"' -f4)
    [[ -z "$VER" ]] && VER="v1.11.4"

    VER_NUM="${VER#v}"    # 去掉 v 前缀：1.11.4

    # 官方 Release 直链
    PKG_NAME="sing-box-${VER_NUM}-linux-${ARCH}"
    URL="https://github.com/SagerNet/sing-box/releases/download/${VER}/${PKG_NAME}.tar.gz"
    info "下载 sing-box ${VER}  arch=${ARCH}"
    info "源: ${URL}"

    wget -qO "${TMP_DIR}/sing-box.tar.gz" "$URL" \
        || error "sing-box 下载失败，请检查网络"

    tar -xzf "${TMP_DIR}/sing-box.tar.gz" -C "${TMP_DIR}/"
    install -m 755 "${TMP_DIR}/${PKG_NAME}/sing-box" "$SBOX_BIN"
    rm -rf "$TMP_DIR"
    info "sing-box 安装完成: $("$SBOX_BIN" version 2>&1 | head -1)"
}

# ═══════════════════════════════════════════════════════════════════
#  伪装网站（对非 WS 请求返回仿 nginx 静态页面）
# ═══════════════════════════════════════════════════════════════════

setup_fake_web() {
    step "生成伪装网站"
    mkdir -p "$FAKE_WEBROOT"
    cat > "${FAKE_WEBROOT}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>Welcome to nginx!</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f2f5;
         display:flex;align-items:center;justify-content:center;min-height:100vh}
    .card{background:#fff;border-radius:10px;box-shadow:0 4px 20px rgba(0,0,0,.08);
          padding:60px 80px;text-align:center;max-width:480px}
    h1{color:#1a1a2e;font-size:2rem;margin-bottom:12px}
    p{color:#666;line-height:1.7;font-size:.95rem}
    .sub{margin-top:24px;font-size:.8rem;color:#aaa}
    hr{border:none;border-top:1px solid #eee;margin:24px 0}
  </style>
</head>
<body>
  <div class="card">
    <h1>Welcome to nginx!</h1><hr>
    <p>If you see this page, the nginx web server is successfully installed and working.
       Further configuration is required.</p>
    <p class="sub">nginx/1.24.0 — Thank you for using nginx.</p>
  </div>
</body>
</html>
HTMLEOF
    info "伪装网站: ${FAKE_WEBROOT}"
}

# ═══════════════════════════════════════════════════════════════════
#  Xray 配置：VLESS + WS，只监听 127.0.0.1
# ═══════════════════════════════════════════════════════════════════

configure_xray() {
    local uuid="$1" local_port="$2" ws_path="$3"
    step "生成 Xray 配置"
    mkdir -p "$XRAY_CONF_DIR"
    cat > "$XRAY_CONF" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${local_port},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${uuid}", "flow": "", "level": 0 }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${ws_path}",
          "headers": { "Host": "" }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "UseIPv4" }
    },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF
    info "Xray 配置写入: ${XRAY_CONF}"
}

# ═══════════════════════════════════════════════════════════════════
#  sing-box 配置：VLESS + WS，只监听 127.0.0.1
# ═══════════════════════════════════════════════════════════════════

configure_singbox() {
    local uuid="$1" local_port="$2" ws_path="$3"
    step "生成 sing-box 配置"
    mkdir -p "$SBOX_CONF_DIR"
    cat > "$SBOX_CONF" << EOF
{
  "log": {
    "level": "warn",
    "output": "stderr",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": ${local_port},
      "users": [
        { "uuid": "${uuid}", "flow": "" }
      ],
      "transport": {
        "type": "ws",
        "path": "${ws_path}",
        "max_early_data": 0,
        "early_data_header_name": ""
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block",  "tag": "block"  }
  ],
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "block" }
    ],
    "final": "direct"
  }
}
EOF
    info "sing-box 配置写入: ${SBOX_CONF}"
}

# ═══════════════════════════════════════════════════════════════════
#  Caddy 配置
#  流量链路: 客户端 :8443 (TLS) → Caddy → 127.0.0.1:local_port (明文 WS)
# ═══════════════════════════════════════════════════════════════════

configure_caddy() {
    local domain="$1" local_port="$2" ws_path="$3" email="$4"
    step "生成 Caddy 配置"
    mkdir -p "$CADDY_CONF_DIR"

    # 备份已有主配置（仅首次）
    if [[ -f "$CADDY_MAIN_CONF" ]] && ! grep -q "vless-personal" "$CADDY_MAIN_CONF" 2>/dev/null; then
        cp "$CADDY_MAIN_CONF" "${CADDY_MAIN_CONF}.bak.$(date +%s)"
        info "原 Caddyfile 已备份"
    fi

    # 主配置：全局块 + import 站点文件
    cat > "$CADDY_MAIN_CONF" << EOF
# ── VLESS Personal Edition ─────────────────────────────────────────
# 由 vless-personal.sh 自动生成；如需自定义请编辑 ${CADDY_VLESS_CONF}
# 修改后执行: caddy reload --config ${CADDY_MAIN_CONF}
# ──────────────────────────────────────────────────────────────────

{
    email ${email}
    admin off
    servers {
        protocols h1 h2
    }
}

import ${CADDY_VLESS_CONF}
EOF

    # 站点块（独立文件，卸载时精准删除，不影响主配置）
    cat > "$CADDY_VLESS_CONF" << EOF
# ── VLESS+WS+TLS 站点配置 ──────────────────────────────────────────
# 域名: ${domain}   外部端口: ${EXT_PORT}   内部端口: ${local_port}
# 生成: $(date '+%Y-%m-%d %H:%M:%S')
# ──────────────────────────────────────────────────────────────────

${domain}:${EXT_PORT} {

    # Caddy 自动向 Let's Encrypt 申请证书，到期前自动续签
    tls {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    }

    # WS 升级请求 + 路径匹配 → 转发给代理核心（明文）
    @proxy_ws {
        path ${ws_path}
        header Connection *Upgrade*
        header Upgrade websocket
    }

    handle @proxy_ws {
        reverse_proxy 127.0.0.1:${local_port} {
            header_up Host            {host}
            header_up X-Real-IP       {remote_host}
            header_up X-Forwarded-For {remote_host}
            flush_interval -1
        }
    }

    # 所有其他请求 → 伪装静态页面
    handle {
        root * ${FAKE_WEBROOT}
        file_server
        header Server "nginx/1.24.0"
        header -X-Powered-By
    }

    log {
        output discard
    }
}
EOF
    info "Caddy 主配置: ${CADDY_MAIN_CONF}"
    info "站点配置:     ${CADDY_VLESS_CONF}"
}

# ═══════════════════════════════════════════════════════════════════
#  systemd 服务单元
# ═══════════════════════════════════════════════════════════════════

_write_systemd_xray() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Proxy Service (VLESS Personal)
Documentation=https://xtls.github.io
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_BIN} run -config ${XRAY_CONF}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
}

_write_systemd_singbox() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box Proxy Service (VLESS Personal)
Documentation=https://sing-box.sagernet.org
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${SBOX_BIN} run -c ${SBOX_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
}

# ═══════════════════════════════════════════════════════════════════
#  OpenRC 服务脚本（Alpine）
# ═══════════════════════════════════════════════════════════════════

_write_openrc_xray() {
    cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run
description="Xray Proxy Service (VLESS Personal)"
command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"
depend() { need net; after caddy; }
EOF
    chmod +x /etc/init.d/xray
}

_write_openrc_singbox() {
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
description="sing-box Proxy Service (VLESS Personal)"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { need net; after caddy; }
EOF
    chmod +x /etc/init.d/sing-box
}

# ═══════════════════════════════════════════════════════════════════
#  配置并启动服务
# ═══════════════════════════════════════════════════════════════════

setup_services() {
    load_conf 2>/dev/null
    local CORE_SVC
    CORE_SVC=$(proxy_svc_name)
    step "配置系统服务 (${CORE_SVC})"

    if [[ "$INIT_SYS" == "systemd" ]]; then
        [[ "$CORE_SVC" == "xray" ]] && _write_systemd_xray || _write_systemd_singbox
        systemctl daemon-reload
        service_enable caddy
        service_enable "$CORE_SVC"
        info "启动 Caddy（首次申请 TLS 证书，约 30 秒）..."
        systemctl restart caddy
        sleep 5
        info "启动 ${CORE_SVC}..."
        systemctl restart "$CORE_SVC"
    else
        [[ "$CORE_SVC" == "xray" ]] && _write_openrc_xray || _write_openrc_singbox
        service_enable caddy
        service_enable "$CORE_SVC"
        info "启动 Caddy（首次申请 TLS 证书，约 30 秒）..."
        rc-service caddy restart
        sleep 5
        info "启动 ${CORE_SVC}..."
        rc-service "$CORE_SVC" start
    fi
    info "服务配置完成"
}

# ═══════════════════════════════════════════════════════════════════
#  防火墙
# ═══════════════════════════════════════════════════════════════════

setup_firewall() {
    step "配置防火墙"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 80/tcp            comment "Caddy ACME HTTP-01" >/dev/null 2>&1 || true
        ufw allow "${EXT_PORT}/tcp" comment "VLESS WS TLS"       >/dev/null 2>&1 || true
        info "ufw: 已放行 80 和 ${EXT_PORT}"; return
    fi
    if command -v iptables &>/dev/null; then
        for port in 80 "${EXT_PORT}"; do
            iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        done
        if [[ "$OS_ID" == "alpine" ]]; then
            iptables-save > /etc/iptables/rules-save 2>/dev/null || \
                iptables-save > /etc/iptables.rules  2>/dev/null || true
        fi
        info "iptables: 已放行 80 和 ${EXT_PORT}"
    else
        warn "未检测到防火墙工具，请手动放行端口 80 和 ${EXT_PORT}"
    fi
}

# ═══════════════════════════════════════════════════════════════════
#  BBR（Debian/Ubuntu；Alpine 跳过）
# ═══════════════════════════════════════════════════════════════════

enable_bbr() {
    [[ "$OS_ID" == "alpine" ]] && { warn "Alpine 内核通常不含 BBR，跳过"; return; }
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]] && \
        { info "BBR 已启用"; return; }
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" >> /etc/modules-load.d/vless-bbr.conf
    cat > /etc/sysctl.d/99-vless-bbr.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || \
        sysctl -p /etc/sysctl.d/99-vless-bbr.conf >/dev/null 2>&1 || true
    info "BBR 已启用 ($(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null))"
}

# ═══════════════════════════════════════════════════════════════════
#  快捷命令 vless-p
# ═══════════════════════════════════════════════════════════════════

setup_shortcut() {
    local SELF
    SELF=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
    if [[ "$SELF" != "$SHORTCUT" ]]; then
        cp "$SELF" "$SHORTCUT"
        chmod +x "$SHORTCUT"
        info "快捷命令已创建: vless-p"
    fi
}

# ═══════════════════════════════════════════════════════════════════
#  显示配置信息 & VLESS 链接
# ═══════════════════════════════════════════════════════════════════

show_config() {
    is_installed || { warn "尚未安装，请先执行安装"; return; }
    load_conf

    local server_ip core_label
    server_ip=$(get_server_ip)
    [[ "${core_type:-xray}" == "singbox" ]] && core_label="sing-box" || core_label="Xray-core"

    local encoded_path
    encoded_path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${ws_path}'))" 2>/dev/null \
                   || echo "${ws_path}")

    local LINK="vless://${uuid}@${domain}:${EXT_PORT}?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${encoded_path}#VLESS-WS-TLS-${domain}"

    echo ""; hr
    echo -e "${CYAN}${BOLD}       VLESS Personal Edition — 节点信息${NC}"; hr
    printf "  %-16s %s\n" "域名:"      "${CYAN}${domain}${NC}"
    printf "  %-16s %s\n" "服务器IP:"  "${server_ip}"
    printf "  %-16s %s\n" "外部端口:"  "${CYAN}${EXT_PORT}${NC}（Caddy TLS）"
    printf "  %-16s %s\n" "协议:"      "${CYAN}VLESS + WebSocket + TLS${NC}"
    printf "  %-16s %s\n" "UUID:"      "${CYAN}${uuid}${NC}"
    printf "  %-16s %s\n" "WS 路径:"   "${CYAN}${ws_path}${NC}"
    printf "  %-16s %s\n" "内部端口:"  "127.0.0.1:${local_port}（${core_label}）"
    printf "  %-16s %s\n" "代理核心:"  "${CYAN}${core_label}${NC}"
    printf "  %-16s %s\n" "TLS:"       "Let's Encrypt（Caddy 自动续签）"
    printf "  %-16s %s\n" "安装时间:"  "${install_date}"
    hr; echo ""
    echo -e "${YELLOW}${BOLD}  ✦ VLESS 链接（复制到客户端）:${NC}"
    echo -e "  ${GREEN}${LINK}${NC}"; echo ""
    echo -e "${YELLOW}${BOLD}  ✦ 手动填写参数:${NC}"
    printf "  %-10s %s\n" "地址:"   "${domain}"
    printf "  %-10s %s\n" "端口:"   "${EXT_PORT}"
    printf "  %-10s %s\n" "UUID:"   "${uuid}"
    printf "  %-10s %s\n" "传输:"   "WebSocket"
    printf "  %-10s %s\n" "路径:"   "${ws_path}"
    printf "  %-10s %s\n" "TLS:"    "启用 | SNI: ${domain}"; echo ""
    if command -v qrencode &>/dev/null; then
        echo -e "${BOLD}  ✦ 二维码:${NC}"
        qrencode -t ansiutf8 "$LINK" 2>/dev/null; echo ""
    fi
    hr
}

# ═══════════════════════════════════════════════════════════════════
#  服务状态
# ═══════════════════════════════════════════════════════════════════

show_status() {
    load_conf 2>/dev/null
    local CORE_SVC
    CORE_SVC=$(proxy_svc_name)
    echo ""; hr; echo -e "${BOLD}  服务状态${NC}"; hr

    for svc in caddy "$CORE_SVC"; do
        if service_is_active "$svc"; then
            printf "  %-12s ${GREEN}● 运行中${NC}\n" "${svc}:"
        else
            printf "  %-12s ${RED}● 已停止${NC}\n" "${svc}:"
        fi
    done

    echo ""; echo -e "${BOLD}  端口监听${NC}"
    if ss -tlnp 2>/dev/null | grep -q ":${EXT_PORT}"; then
        echo -e "  :${EXT_PORT}   ${GREEN}✓ 已监听${NC} (外部 TLS)"
    else
        echo -e "  :${EXT_PORT}   ${RED}✗ 未监听${NC}"
    fi
    if is_installed; then
        if ss -tlnp 2>/dev/null | grep -q ":${local_port}"; then
            echo -e "  :${local_port}  ${GREEN}✓ 已监听${NC} (${CORE_SVC} 本地 WS)"
        else
            echo -e "  :${local_port}  ${RED}✗ 未监听${NC}"
        fi
    fi
    hr
}

# ═══════════════════════════════════════════════════════════════════
#  重启服务
# ═══════════════════════════════════════════════════════════════════

restart_services() {
    local CORE_SVC
    CORE_SVC=$(proxy_svc_name)
    step "重启服务"
    service_cmd restart caddy
    sleep 2
    service_cmd restart "$CORE_SVC"
    info "Caddy 和 ${CORE_SVC} 已重启"
    show_status
}

# ═══════════════════════════════════════════════════════════════════
#  查看日志
# ═══════════════════════════════════════════════════════════════════

show_logs() {
    local CORE_SVC
    CORE_SVC=$(proxy_svc_name)
    echo ""
    echo "  1) ${CORE_SVC} 日志"
    echo "  2) Caddy 日志"
    echo "  0) 返回"
    read -rp "  选择 [0-2]: " lc; echo ""
    case "$lc" in
        1)
            if [[ "$INIT_SYS" == "systemd" ]]; then
                journalctl -u "$CORE_SVC" -n 80 --no-pager 2>/dev/null || echo "无日志"
            else
                tail -80 "/var/log/${CORE_SVC}.log" 2>/dev/null || echo "暂无日志"
            fi ;;
        2)
            if [[ "$INIT_SYS" == "systemd" ]]; then
                journalctl -u caddy -n 80 --no-pager 2>/dev/null || echo "无日志"
            else
                echo "（访问日志已设为 discard）"; fi ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════
#  更换 UUID
# ═══════════════════════════════════════════════════════════════════

rotate_uuid() {
    is_installed || { warn "尚未安装"; return; }
    load_conf
    local NEW_UUID
    NEW_UUID=$(gen_uuid)
    read -rp "  新 UUID: ${NEW_UUID}，确认更换? [y/N]: " c
    [[ "${c,,}" == "y" ]] || { info "取消"; return; }

    local CORE_SVC CORE_CONF
    CORE_SVC=$(proxy_svc_name)
    [[ "${core_type:-xray}" == "singbox" ]] && CORE_CONF="$SBOX_CONF" || CORE_CONF="$XRAY_CONF"

    sed -i "s/${uuid}/${NEW_UUID}/g" "$CORE_CONF"
    sed -i "s/^uuid=.*/uuid=${NEW_UUID}/"  "$CONF_FILE"
    service_cmd restart "$CORE_SVC"
    info "UUID 已更换为: ${NEW_UUID}"
    show_config
}

# ═══════════════════════════════════════════════════════════════════
#  一键卸载
#  策略：精准移除本脚本组件，不影响其他已安装依赖
# ═══════════════════════════════════════════════════════════════════

uninstall() {
    echo ""
    echo -e "${RED}${BOLD}  ⚠  即将卸载 VLESS Personal Edition${NC}"
    echo -e "  将移除: 代理核心服务 + 配置 + Caddy 站点块 + 伪装网站"
    echo -e "  不影响: Caddy 本体（若非本脚本安装）+ 其他系统依赖"
    echo ""
    read -rp "  确认卸载? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { info "已取消"; return; }

    load_conf 2>/dev/null || true
    local CORE_SVC
    CORE_SVC=$(proxy_svc_name)

    # 1. 停止并移除代理核心服务
    step "停止代理核心 (${CORE_SVC})"
    service_cmd stop "$CORE_SVC" 2>/dev/null || true
    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl disable "$CORE_SVC" 2>/dev/null || true
        rm -f "/etc/systemd/system/${CORE_SVC}.service"
        systemctl daemon-reload 2>/dev/null || true
    else
        rc-update del "$CORE_SVC" default 2>/dev/null || true
        rm -f "/etc/init.d/${CORE_SVC}"
    fi

    # 2. 移除二进制和配置文件
    step "移除代理核心文件"
    if [[ "${core_type:-xray}" == "singbox" ]]; then
        rm -f "$SBOX_BIN" "$SBOX_CONF"
        rmdir "$SBOX_CONF_DIR" 2>/dev/null || true
    else
        rm -f "$XRAY_BIN" "$XRAY_CONF"
        rm -rf /usr/local/share/xray
        rmdir "$XRAY_CONF_DIR" 2>/dev/null || true
    fi
    rm -f /etc/modules-load.d/vless-bbr.conf
    rm -f /etc/sysctl.d/99-vless-bbr.conf

    # 3. 移除 Caddy 站点配置，恢复主配置
    step "移除 Caddy 站点配置"
    rm -f "$CADDY_VLESS_CONF"
    local BACKUP
    BACKUP=$(ls -t "${CADDY_MAIN_CONF}.bak."* 2>/dev/null | head -1)
    if [[ -n "$BACKUP" ]]; then
        cp "$BACKUP" "$CADDY_MAIN_CONF"
        info "Caddy 主配置已还原自备份: ${BACKUP}"
    elif grep -q "vless-personal" "$CADDY_MAIN_CONF" 2>/dev/null; then
        echo "# Caddy config - restored by vless-personal.sh uninstall" > "$CADDY_MAIN_CONF"
    fi
    service_cmd restart caddy 2>/dev/null || true

    # 4. 询问是否卸载 Caddy 本体（仅本脚本安装的才询问）
    if [[ "${caddy_preinstalled:-true}" == "false" ]]; then
        echo ""
        read -rp "  Caddy 由本脚本安装，是否一并卸载? [y/N]: " rm_caddy
        if [[ "${rm_caddy,,}" == "y" ]]; then
            service_cmd stop caddy 2>/dev/null || true
            if [[ "$INIT_SYS" == "systemd" ]]; then
                systemctl disable caddy 2>/dev/null || true
            else
                rc-update del caddy default 2>/dev/null || true
            fi
            if [[ "$PKG_MGR" == "apt" ]]; then
                apt-get remove -y caddy 2>/dev/null || true
                rm -f /etc/apt/sources.list.d/caddy-stable.list
                rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            else
                apk del caddy 2>/dev/null || true
            fi
            info "Caddy 已卸载"
        fi
    fi

    # 5. 清理脚本配置目录和快捷命令
    step "清理配置"
    rm -rf "$CONF_DIR" "$FAKE_WEBROOT"
    rm -f  "$SHORTCUT"

    echo ""
    echo -e "${GREEN}${BOLD}  ✓  卸载完成${NC}"
    echo -e "  如已启用 BBR，相关内核参数在重启后完全清除"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════
#  主安装流程
# ═══════════════════════════════════════════════════════════════════

do_install() {
    if is_installed; then
        echo ""; warn "检测到已有安装实例"
        load_conf
        echo -e "  域名: ${domain}  核心: ${core_type:-xray}  UUID: ${uuid}"
        read -rp "  是否覆盖重新安装? [y/N]: " ri
        [[ "${ri,,}" == "y" ]] || return
        service_cmd stop "$(proxy_svc_name)" 2>/dev/null || true
        service_cmd stop caddy 2>/dev/null || true
    fi

    echo ""
    echo -e "${CYAN}${BOLD}════════ VLESS Personal Edition — 安装向导 ════════${NC}"
    echo ""

    # ── 1. 选择代理核心 ──────────────────────────────────────────
    echo -e "${BOLD}  选择代理核心:${NC}"
    echo "  1) Xray-core   github.com/XTLS/Xray-core"
    echo "  2) sing-box    github.com/SagerNet/sing-box"
    local CORE_TYPE CORE_LABEL
    while true; do
        read -rp "  输入 [1/2]（默认 1）: " CORE_CHOICE
        CORE_CHOICE="${CORE_CHOICE:-1}"
        case "$CORE_CHOICE" in
            1) CORE_TYPE="xray";    CORE_LABEL="Xray-core"; break ;;
            2) CORE_TYPE="singbox"; CORE_LABEL="sing-box";  break ;;
            *) warn "请输入 1 或 2" ;;
        esac
    done
    echo ""

    # ── 2. 收集域名 & 邮箱 ──────────────────────────────────────
    local INPUT_DOMAIN INPUT_EMAIL
    while true; do
        read -rp "  域名（例: proxy.example.com）: " INPUT_DOMAIN
        INPUT_DOMAIN="${INPUT_DOMAIN// /}"
        [[ -n "$INPUT_DOMAIN" && "$INPUT_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] && break
        warn "域名格式不正确，请重新输入"
    done

    while true; do
        read -rp "  邮箱（TLS 证书通知）: " INPUT_EMAIL
        [[ "$INPUT_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break
        warn "邮箱格式不正确"
    done

    # ── 3. 自动生成参数 ─────────────────────────────────────────
    local AUTO_UUID AUTO_PORT AUTO_PATH
    AUTO_UUID=$(gen_uuid)
    AUTO_PORT=$(random_local_port)
    AUTO_PATH=$(ws_path_from_domain "$INPUT_DOMAIN")

    echo ""
    echo -e "${BOLD}  自动生成配置:${NC}"
    printf "  %-16s %s\n" "代理核心:" "${CYAN}${CORE_LABEL}${NC}"
    printf "  %-16s %s\n" "UUID:"     "$AUTO_UUID"
    printf "  %-16s %s\n" "WS 路径:"  "$AUTO_PATH"
    printf "  %-16s %s\n" "内部端口:" "127.0.0.1:${AUTO_PORT}"
    printf "  %-16s %s\n" "外部端口:" "${EXT_PORT} (Caddy TLS)"
    echo ""

    read -rp "  自定义 UUID? [y/N]: " cu
    if [[ "${cu,,}" == "y" ]]; then
        while true; do
            read -rp "  UUID（格式 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx）: " AUTO_UUID
            [[ "$AUTO_UUID" =~ ^[0-9a-f-]{36}$ ]] && break
            warn "格式不正确"
        done
    fi

    read -rp "  自定义 WS 路径? 默认 ${AUTO_PATH} [y/N]: " cp_
    if [[ "${cp_,,}" == "y" ]]; then
        read -rp "  路径（以 / 开头，例: /mypath）: " AUTO_PATH
        [[ "$AUTO_PATH" =~ ^/ ]] || AUTO_PATH="/${AUTO_PATH}"
    fi

    echo ""
    local DO_BBR=true
    read -rp "  启用 BBR 加速? [Y/n]: " bbr_c
    [[ "${bbr_c,,}" == "n" ]] && DO_BBR=false

    # ── 4. 确认 ──────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ── 确认安装参数 ──${NC}"
    printf "  %-16s ${CYAN}%s${NC}\n" "代理核心:" "${CORE_LABEL}"
    printf "  %-16s ${CYAN}%s${NC}\n" "域名:"     "${INPUT_DOMAIN}"
    printf "  %-16s %s\n"             "邮箱:"     "${INPUT_EMAIL}"
    printf "  %-16s ${CYAN}%s${NC}\n" "UUID:"     "${AUTO_UUID}"
    printf "  %-16s ${CYAN}%s${NC}\n" "WS 路径:"  "${AUTO_PATH}"
    printf "  %-16s ${CYAN}%s${NC}\n" "外部端口:" "${EXT_PORT}"
    printf "  %-16s %s\n"             "内部端口:" "127.0.0.1:${AUTO_PORT}"
    printf "  %-16s %s\n"             "BBR:"      "$($DO_BBR && echo '启用' || echo '不启用')"
    echo ""
    read -rp "  确认并开始安装? [Y/n]: " final_c
    [[ "${final_c,,}" == "n" ]] && { info "已取消"; return; }

    # ── 5. 写配置文件 ─────────────────────────────────────────────
    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" << EOF
# VLESS Personal Edition 配置（请勿手动修改）
core_type=${CORE_TYPE}
domain=${INPUT_DOMAIN}
email=${INPUT_EMAIL}
uuid=${AUTO_UUID}
local_port=${AUTO_PORT}
ws_path=${AUTO_PATH}
install_date=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    # ── 6. 安装各组件 ─────────────────────────────────────────────
    install_base_deps
    install_caddy

    if [[ "$CORE_TYPE" == "singbox" ]]; then
        install_singbox
        configure_singbox "$AUTO_UUID" "$AUTO_PORT" "$AUTO_PATH"
    else
        install_xray
        configure_xray   "$AUTO_UUID" "$AUTO_PORT" "$AUTO_PATH"
    fi

    setup_fake_web
    configure_caddy "$INPUT_DOMAIN" "$AUTO_PORT" "$AUTO_PATH" "$INPUT_EMAIL"
    setup_services
    setup_firewall
    $DO_BBR && enable_bbr || true
    setup_shortcut

    # ── 7. 完成提示 ──────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║              ✓  安装完成！                          ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠ 重要：${NC}请确保 ${CYAN}${INPUT_DOMAIN}${NC} 的 DNS A 记录已解析到本机 IP"
    echo -e "  Caddy 通过 HTTP-01 验证申请 Let's Encrypt 证书（约 30~60 秒）"
    echo -e "  证书申请完成后即可正常连接"
    echo ""
    show_config
}

# ═══════════════════════════════════════════════════════════════════
#  主菜单
# ═══════════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}${BOLD}║     VLESS Personal Edition  v2.0  (vless-p)           ║${NC}"
        echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

        if is_installed; then
            load_conf 2>/dev/null
            local CORE_SVC xs cs
            CORE_SVC=$(proxy_svc_name)
            service_is_active "$CORE_SVC" \
                && xs="${GREEN}运行中${NC}" || xs="${RED}已停止${NC}"
            service_is_active caddy \
                && cs="${GREEN}运行中${NC}" || cs="${RED}已停止${NC}"
            echo -e "  核心: ${CYAN}${core_type:-xray}${NC}  $(echo -e $xs)   Caddy: $(echo -e $cs)"
            echo -e "  ${domain}:${EXT_PORT}  WS: ${ws_path}"
        else
            echo -e "  状态: ${YELLOW}未安装${NC}"
        fi
        hr
        echo "  1) 安装（选择 Xray-core 或 sing-box）"
        echo "  2) 查看配置 / 链接"
        echo "  3) 服务状态"
        echo "  4) 重启服务"
        echo "  5) 查看日志"
        echo "  6) 更换 UUID"
        echo "  7) 一键卸载"
        echo "  0) 退出"
        hr
        read -rp "  请选择 [0-7]: " choice
        case "$choice" in
            1) do_install       ;;
            2) show_config      ;;
            3) show_status      ;;
            4) restart_services ;;
            5) show_logs        ;;
            6) rotate_uuid      ;;
            7) uninstall        ;;
            0) echo "  再见！"; exit 0 ;;
            *) warn "无效选项，请输入 0-7" ;;
        esac
    done
}

# ── 入口 ─────────────────────────────────────────────────────────
check_root
detect_os
main_menu
