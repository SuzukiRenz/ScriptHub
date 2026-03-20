#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════╗
# ║          VLESS Personal Edition  v3.0                             ║
# ║  支持系统: Debian / Ubuntu / Alpine                                ║
# ║  代理核心: Xray-core 或 sing-box（安装时选择）                     ║
# ║  协议模式: VLESS+WS+TLS（需域名）| VLESS+Reality（无需域名）       ║
# ║  TLS前端:  Caddy（WS+TLS 模式，自动续签 Let's Encrypt）            ║
# ║  外部端口: 自定义（默认 8443）                                     ║
# ║  WS路径:   伪装成 404，实际流量正常穿透                            ║
# ║  流量限制: 可选，月初自动重置并重启服务                            ║
# ║  中转转发: 可转发流量到远程 VLESS+WS+TLS 服务器                   ║
# ║  下载源:   Xray     → github.com/XTLS/Xray-core/releases          ║
# ║            sing-box → github.com/SagerNet/sing-box/releases       ║
# ╚═══════════════════════════════════════════════════════════════════╝
# wget -O vless-go.sh https://raw.githubusercontent.com/SuzukiRenz/ScriptHub/refs/heads/main/SH/vless-go.sh && chmod +x vless-go.sh && ./vless-go.sh
# ── 颜色（$'\033[...]' 语法，赋值时即完成转义，避免 printf 乱码）─────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }
step()  { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
hr()    { echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"; }

# ── 路径常量 ──────────────────────────────────────────────────────────
CONF_DIR="/etc/vless-personal"
CONF_FILE="${CONF_DIR}/config.env"
TRAFFIC_FILE="${CONF_DIR}/traffic.env"
LOG_FILE="/var/log/vless-personal.log"

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

# Reality 可借用的公共域名（x-ui 项目同款，TLS 稳定可靠）
REALITY_DEST_LIST=(
    "yahoo.com"
    "icloud.com"
    "addons.mozilla.org"
    "www.microsoft.com"
    "skype.com"
    "store.steampowered.com"
    "www.apple.com"
    "www.swift.org"
)

# ═══════════════════════════════════════════════════════════════════
#  工具函数
# ═══════════════════════════════════════════════════════════════════

check_root() { [[ $EUID -ne 0 ]] && error "请以 root 运行: sudo bash $0"; }

detect_os() {
    [[ -f /etc/os-release ]] || error "无法识别操作系统"
    source /etc/os-release
    OS_ID="${ID}"
    case "$OS_ID" in
        debian|ubuntu) PKG_MGR="apt";  INIT_SYS="systemd" ;;
        alpine)        PKG_MGR="apk";  INIT_SYS="openrc"  ;;
        *) error "不支持的系统: ${OS_ID}（仅支持 Debian / Ubuntu / Alpine）" ;;
    esac
}

pkg_update()   { [[ "$PKG_MGR" == "apt" ]] && apt-get update -qq 2>/dev/null || apk update -q 2>/dev/null; }
pkg_install()  { [[ "$PKG_MGR" == "apt" ]] && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" || apk add --quiet "$@"; }

xray_arch() {
    case "$(uname -m)" in
        x86_64)        echo "64"        ;;  aarch64|arm64) echo "arm64-v8a" ;;
        armv7*)        echo "arm32-v7a" ;;  armv6*)        echo "arm32-v6"  ;;
        *) error "Xray 不支持该架构: $(uname -m)" ;;
    esac
}

sbox_arch() {
    case "$(uname -m)" in
        x86_64)        echo "amd64" ;;  aarch64|arm64) echo "arm64" ;;
        armv7*)        echo "armv7" ;;  armv6*)        echo "armv6" ;;
        *) error "sing-box 不支持该架构: $(uname -m)" ;;
    esac
}

gen_uuid() {
    if   command -v uuidgen  &>/dev/null; then uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
    elif command -v python3  &>/dev/null; then python3 -c "import uuid; print(uuid.uuid4())"
    else
        local N B C='89ab'
        for (( N=0; N<16; N++ )); do
            B=$(( RANDOM%256 ))
            case $N in
                6)       printf '4%x'  $(( B%16 )) ;;
                8)       printf '%c%x' "${C:$((RANDOM%${#C})):1}" $(( B%16 )) ;;
                3|5|7|9) printf '%02x-' $B ;;
                *)       printf '%02x'  $B ;;
            esac
        done; echo
    fi
}

random_local_port() {
    local port
    for _ in {1..30}; do
        port=$(shuf -i 10000-59999 -n 1 2>/dev/null || awk 'BEGIN{srand();print int(rand()*49999)+10000}')
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}$" || { echo "$port"; return; }
    done
    error "无法分配随机本地端口"
}

ws_path_from_domain() { echo "/${1%%.*}"; }

is_installed() { [[ -f "$CONF_FILE" ]] && grep -q "^uuid=" "$CONF_FILE"; }

load_conf() { [[ -f "$CONF_FILE" ]] || return 1; source "$CONF_FILE"; }
load_traffic() { [[ -f "$TRAFFIC_FILE" ]] || return 1; source "$TRAFFIC_FILE"; }

service_cmd() {
    local action="$1" svc="$2"
    [[ "$INIT_SYS" == "systemd" ]] && systemctl "$action" "$svc" 2>/dev/null \
                                   || rc-service  "$svc" "$action" 2>/dev/null
}

service_enable() {
    [[ "$INIT_SYS" == "systemd" ]] && systemctl enable "$1" 2>/dev/null \
                                   || rc-update add "$1" default 2>/dev/null
}

service_is_active() {
    [[ "$INIT_SYS" == "systemd" ]] && systemctl is-active --quiet "$1" 2>/dev/null \
                                   || rc-service "$1" status 2>/dev/null | grep -q started
}

get_server_ip() {
    curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null ||
    curl -s4 --max-time 5 https://ifconfig.me   2>/dev/null ||
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}' ||
    hostname -I 2>/dev/null | awk '{print $1}'
}

proxy_svc_name() { load_conf 2>/dev/null; [[ "${core_type:-xray}" == "singbox" ]] && echo "sing-box" || echo "xray"; }
core_conf_file()  { [[ "${core_type:-xray}" == "singbox" ]] && echo "$SBOX_CONF" || echo "$XRAY_CONF"; }
core_bin()        { [[ "${core_type:-xray}" == "singbox" ]] && echo "$SBOX_BIN"  || echo "$XRAY_BIN"; }

human_bytes() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN{
        if(b<1048576) printf "%.1f KB", b/1024
        else if(b<1073741824) printf "%.2f MB", b/1048576
        else printf "%.3f GB", b/1073741824
    }'
}

# iptables 专用链 → 统计出入流量
setup_traffic_chain() {
    local port="$1"
    iptables -N VLESS_IN  2>/dev/null || true
    iptables -N VLESS_OUT 2>/dev/null || true
    # 幂等：移除旧的跳转规则
    while iptables -D INPUT  -p tcp --dport "$port" -j VLESS_IN  2>/dev/null; do true; done
    while iptables -D OUTPUT -p tcp --sport "$port" -j VLESS_OUT 2>/dev/null; do true; done
    iptables -I INPUT  -p tcp --dport "$port" -j VLESS_IN
    iptables -I OUTPUT -p tcp --sport "$port" -j VLESS_OUT
    iptables -F VLESS_IN;  iptables -A VLESS_IN  -j RETURN
    iptables -F VLESS_OUT; iptables -A VLESS_OUT -j RETURN
}

get_iptables_bytes() {
    local in_b out_b
    in_b=$(iptables  -L VLESS_IN  -n -v -x 2>/dev/null | awk 'NR==3{print $2+0}')
    out_b=$(iptables -L VLESS_OUT -n -v -x 2>/dev/null | awk 'NR==3{print $2+0}')
    echo $(( ${in_b:-0} + ${out_b:-0} ))
}

# ═══════════════════════════════════════════════════════════════════
#  安装基础依赖
# ═══════════════════════════════════════════════════════════════════

install_base_deps() {
    step "安装基础依赖"
    pkg_update
    [[ "$PKG_MGR" == "apt" ]] \
        && pkg_install curl wget unzip tar iproute2 openssl ca-certificates gnupg lsb-release iptables cron \
        || pkg_install curl wget unzip tar iproute2 openssl ca-certificates util-linux iptables dcron
    info "基础依赖完成"
}

# ═══════════════════════════════════════════════════════════════════
#  Caddy（官方包源）
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
#  Xray-core  github.com/XTLS/Xray-core/releases
#  包格式:    Xray-linux-{arch}.zip
# ═══════════════════════════════════════════════════════════════════

install_xray() {
    step "安装 Xray-core"
    local ARCH TMP VER URL
    ARCH=$(xray_arch); TMP=$(mktemp -d)
    VER=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
          | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    [[ -z "$VER" ]] && VER="v25.3.6"
    URL="https://github.com/XTLS/Xray-core/releases/download/${VER}/Xray-linux-${ARCH}.zip"
    info "版本: ${VER}  arch: ${ARCH}"
    info "下载: ${URL}"
    wget -qO "${TMP}/xray.zip" "$URL" || error "Xray 下载失败"
    unzip -qo "${TMP}/xray.zip" -d "${TMP}/out"
    install -m 755 "${TMP}/out/xray" "$XRAY_BIN"
    mkdir -p /usr/local/share/xray
    for f in geoip.dat geosite.dat; do
        [[ -f "${TMP}/out/${f}" ]] && install -m 644 "${TMP}/out/${f}" "/usr/local/share/xray/${f}" || true
    done
    rm -rf "$TMP"
    info "Xray 安装完成: $("$XRAY_BIN" version 2>&1 | head -1)"
}

# ═══════════════════════════════════════════════════════════════════
#  sing-box  github.com/SagerNet/sing-box/releases
#  包格式:   sing-box-{ver}-linux-{arch}.tar.gz
# ═══════════════════════════════════════════════════════════════════

install_singbox() {
    step "安装 sing-box"
    local ARCH TMP VER VER_NUM PKG URL
    ARCH=$(sbox_arch); TMP=$(mktemp -d)
    VER=$(curl -s --max-time 10 "https://api.github.com/repos/SagerNet/sing-box/releases" \
          | grep '"tag_name"' | grep -v 'alpha\|beta\|rc' | head -1 | cut -d'"' -f4)
    [[ -z "$VER" ]] && VER="v1.11.4"
    VER_NUM="${VER#v}"
    PKG="sing-box-${VER_NUM}-linux-${ARCH}"
    URL="https://github.com/SagerNet/sing-box/releases/download/${VER}/${PKG}.tar.gz"
    info "版本: ${VER}  arch: ${ARCH}"
    info "下载: ${URL}"
    wget -qO "${TMP}/sing-box.tar.gz" "$URL" || error "sing-box 下载失败"
    tar -xzf "${TMP}/sing-box.tar.gz" -C "${TMP}/"
    install -m 755 "${TMP}/${PKG}/sing-box" "$SBOX_BIN"
    rm -rf "$TMP"
    info "sing-box 安装完成: $("$SBOX_BIN" version 2>&1 | head -1)"
}

# ═══════════════════════════════════════════════════════════════════
#  Reality 密钥生成（需要二进制已安装）
# ═══════════════════════════════════════════════════════════════════

gen_reality_keys() {
    local output private_key public_key short_id
    # short_id: 8 字节随机 hex（16 位）
    short_id=$(openssl rand -hex 8 2>/dev/null \
               || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)

    if [[ "${core_type:-xray}" == "singbox" ]]; then
        output=$("$SBOX_BIN" generate reality-keypair 2>/dev/null)
        private_key=$(echo "$output" | grep -i "PrivateKey" | awk -F'[: ]+' '{print $NF}' | tr -d '\r')
        public_key=$(echo  "$output" | grep -i "PublicKey"  | awk -F'[: ]+' '{print $NF}' | tr -d '\r')
    else
        output=$("$XRAY_BIN" x25519 2>/dev/null)
        private_key=$(echo "$output" | grep "Private key:" | awk '{print $NF}' | tr -d '\r')
        public_key=$(echo  "$output" | grep "Public key:"  | awk '{print $NF}' | tr -d '\r')
    fi

    [[ -z "$private_key" || -z "$public_key" ]] && error "Reality 密钥生成失败，请检查核心二进制"

    REALITY_PRIVATE_KEY="$private_key"
    REALITY_PUBLIC_KEY="$public_key"
    REALITY_SHORT_ID="$short_id"
}

# ═══════════════════════════════════════════════════════════════════
#  伪装网站（nginx 风格静态页）
# ═══════════════════════════════════════════════════════════════════

setup_fake_web() {
    step "生成伪装网站"
    mkdir -p "$FAKE_WEBROOT"
    cat > "${FAKE_WEBROOT}/index.html" << 'HTMLEOF'
<!DOCTYPE html><html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome to nginx!</title>
<style>*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f2f5;
     display:flex;align-items:center;justify-content:center;min-height:100vh}
.c{background:#fff;border-radius:10px;box-shadow:0 4px 20px rgba(0,0,0,.08);
   padding:60px 80px;text-align:center;max-width:480px}
h1{color:#1a1a2e;font-size:2rem;margin-bottom:12px}
p{color:#666;line-height:1.7;font-size:.95rem}
.s{margin-top:24px;font-size:.8rem;color:#aaa}
hr{border:none;border-top:1px solid #eee;margin:24px 0}</style>
</head><body><div class="c">
<h1>Welcome to nginx!</h1><hr>
<p>If you see this page, the nginx web server is successfully installed and working.
Further configuration is required.</p>
<p class="s">nginx/1.24.0 — Thank you for using nginx.</p>
</div></body></html>
HTMLEOF
    info "伪装网站: ${FAKE_WEBROOT}"
}

# ═══════════════════════════════════════════════════════════════════
#  构建 Xray 出站配置（direct 或 relay）
#  relay_enabled / relay_* 从全局变量（load_conf 后）读取
# ═══════════════════════════════════════════════════════════════════

_xray_outbound_json() {
    if [[ "${relay_enabled:-false}" == "true" ]]; then
        cat << RELAY
    {
      "protocol": "vless",
      "tag": "relay",
      "settings": {
        "vnext": [{
          "address": "${relay_host}",
          "port": ${relay_port},
          "users": [{"id": "${relay_uuid}", "encryption": "none"}]
        }]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {"serverName": "${relay_sni}", "allowInsecure": false},
        "wsSettings": {"path": "${relay_ws_path}", "headers": {"Host": "${relay_sni}"}}
      }
    }
RELAY
    else
        echo '    {"protocol":"freedom","tag":"direct","settings":{"domainStrategy":"UseIPv4"}}'
    fi
}

_xray_out_tag() { [[ "${relay_enabled:-false}" == "true" ]] && echo "relay" || echo "direct"; }

# ═══════════════════════════════════════════════════════════════════
#  配置 Xray — WS+TLS 模式（监听 127.0.0.1）
# ═══════════════════════════════════════════════════════════════════

configure_xray_ws() {
    load_conf
    step "生成 Xray 配置 (WS+TLS)"
    mkdir -p "$XRAY_CONF_DIR"
    local OUT_JSON OUT_TAG
    OUT_JSON=$(_xray_outbound_json)
    OUT_TAG=$(_xray_out_tag)
    cat > "$XRAY_CONF" << EOF
{
  "log": {"loglevel": "warning", "access": "none"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": ${local_port},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${uuid}", "level": 0}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "none",
      "wsSettings": {"path": "${ws_path}"}
    },
    "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
  }],
  "outbounds": [
${OUT_JSON},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type":"field","ip":["geoip:private"],"outboundTag":"block"},
      {"type":"field","network":"tcp,udp","outboundTag":"${OUT_TAG}"}
    ]
  }
}
EOF
    info "Xray WS 配置: ${XRAY_CONF}"
}

# ═══════════════════════════════════════════════════════════════════
#  配置 Xray — Reality 模式（监听 0.0.0.0:ext_port）
# ═══════════════════════════════════════════════════════════════════

configure_xray_reality() {
    load_conf
    step "生成 Xray 配置 (Reality)"
    mkdir -p "$XRAY_CONF_DIR"
    local OUT_JSON OUT_TAG
    OUT_JSON=$(_xray_outbound_json)
    OUT_TAG=$(_xray_out_tag)
    cat > "$XRAY_CONF" << EOF
{
  "log": {"loglevel": "warning", "access": "none"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${ext_port},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision", "level": 0}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${reality_dest}:443",
        "xver": 0,
        "serverNames": ["${reality_dest}"],
        "privateKey": "${reality_private_key}",
        "shortIds": ["${reality_short_id}"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
  }],
  "outbounds": [
${OUT_JSON},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type":"field","ip":["geoip:private"],"outboundTag":"block"},
      {"type":"field","network":"tcp,udp","outboundTag":"${OUT_TAG}"}
    ]
  }
}
EOF
    info "Xray Reality 配置: ${XRAY_CONF}"
}

# ═══════════════════════════════════════════════════════════════════
#  构建 sing-box 出站配置
# ═══════════════════════════════════════════════════════════════════

_sbox_outbound_json() {
    if [[ "${relay_enabled:-false}" == "true" ]]; then
        cat << RELAY
    {
      "type": "vless",
      "tag": "relay",
      "server": "${relay_host}",
      "server_port": ${relay_port},
      "uuid": "${relay_uuid}",
      "tls": {"enabled": true, "server_name": "${relay_sni}"},
      "transport": {"type": "ws", "path": "${relay_ws_path}", "headers": {"Host": "${relay_sni}"}}
    }
RELAY
    else
        echo '    {"type": "direct", "tag": "direct"}'
    fi
}

_sbox_out_tag() { [[ "${relay_enabled:-false}" == "true" ]] && echo "relay" || echo "direct"; }

# ═══════════════════════════════════════════════════════════════════
#  配置 sing-box — WS+TLS 模式
# ═══════════════════════════════════════════════════════════════════

configure_singbox_ws() {
    load_conf
    step "生成 sing-box 配置 (WS+TLS)"
    mkdir -p "$SBOX_CONF_DIR"
    local OUT_JSON OUT_TAG
    OUT_JSON=$(_sbox_outbound_json)
    OUT_TAG=$(_sbox_out_tag)
    cat > "$SBOX_CONF" << EOF
{
  "log": {"level": "warn", "output": "stderr", "timestamp": true},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "127.0.0.1",
    "listen_port": ${local_port},
    "users": [{"uuid": "${uuid}"}],
    "transport": {"type": "ws", "path": "${ws_path}"}
  }],
  "outbounds": [
${OUT_JSON},
    {"type": "block", "tag": "block"}
  ],
  "route": {
    "rules": [
      {"ip_is_private": true, "outbound": "block"},
      {"network": ["tcp","udp"], "outbound": "${OUT_TAG}"}
    ],
    "final": "${OUT_TAG}"
  }
}
EOF
    info "sing-box WS 配置: ${SBOX_CONF}"
}

# ═══════════════════════════════════════════════════════════════════
#  配置 sing-box — Reality 模式
# ═══════════════════════════════════════════════════════════════════

configure_singbox_reality() {
    load_conf
    step "生成 sing-box 配置 (Reality)"
    mkdir -p "$SBOX_CONF_DIR"
    local OUT_JSON OUT_TAG
    OUT_JSON=$(_sbox_outbound_json)
    OUT_TAG=$(_sbox_out_tag)
    cat > "$SBOX_CONF" << EOF
{
  "log": {"level": "warn", "output": "stderr", "timestamp": true},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "0.0.0.0",
    "listen_port": ${ext_port},
    "users": [{"uuid": "${uuid}", "flow": "xtls-rprx-vision"}],
    "tls": {
      "enabled": true,
      "server_name": "${reality_dest}",
      "reality": {
        "enabled": true,
        "handshake": {"server": "${reality_dest}", "server_port": 443},
        "private_key": "${reality_private_key}",
        "short_id": ["${reality_short_id}"]
      }
    }
  }],
  "outbounds": [
${OUT_JSON},
    {"type": "block", "tag": "block"}
  ],
  "route": {
    "rules": [
      {"ip_is_private": true, "outbound": "block"},
      {"network": ["tcp","udp"], "outbound": "${OUT_TAG}"}
    ],
    "final": "${OUT_TAG}"
  }
}
EOF
    info "sing-box Reality 配置: ${SBOX_CONF}"
}

# ═══════════════════════════════════════════════════════════════════
#  配置代理核心（调度器）
# ═══════════════════════════════════════════════════════════════════

configure_core() {
    load_conf
    if [[ "${core_type:-xray}" == "singbox" ]]; then
        [[ "${mode}" == "reality" ]] && configure_singbox_reality || configure_singbox_ws
    else
        [[ "${mode}" == "reality" ]] && configure_xray_reality    || configure_xray_ws
    fi
}

# ═══════════════════════════════════════════════════════════════════
#  配置 Caddy（仅 WS+TLS 模式使用）
#
#  WS 路径策略（双层匹配）：
#  ① WebSocket 升级请求 (@ws_upgrade) → 转发给代理核心（实际流量）
#  ② 普通 HTTP 请求访问同路径      → 返回 404（伪装探测无效）
#  ③ 其余路径                      → 返回伪装静态页面
# ═══════════════════════════════════════════════════════════════════

configure_caddy() {
    load_conf
    step "生成 Caddy 配置"
    mkdir -p "$CADDY_CONF_DIR"

    if [[ -f "$CADDY_MAIN_CONF" ]] && ! grep -q "vless-personal" "$CADDY_MAIN_CONF" 2>/dev/null; then
        cp "$CADDY_MAIN_CONF" "${CADDY_MAIN_CONF}.bak.$(date +%s)"
        info "原 Caddyfile 已备份"
    fi

    cat > "$CADDY_MAIN_CONF" << EOF
# ── VLESS Personal Edition ─────────────────────────────────────────
# 修改站点配置请编辑: ${CADDY_VLESS_CONF}
# 生效: caddy reload --config ${CADDY_MAIN_CONF}
# ──────────────────────────────────────────────────────────────────
{
    email ${email}
    admin off
    servers { protocols h1 h2 }
}
import ${CADDY_VLESS_CONF}
EOF

    cat > "$CADDY_VLESS_CONF" << EOF
# ── VLESS+WS+TLS 站点 ────────────────────────────────────────────
# 域名: ${domain}  外部: ${ext_port}  内部: ${local_port}
# 生成: $(date '+%Y-%m-%d_%H:%M:%S')
# ─────────────────────────────────────────────────────────────────

${domain}:${ext_port} {

    # Caddy 自动申请 Let's Encrypt 证书并续签
    tls {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    }

    # ① WS 升级请求 → 代理核心（实际流量，正常转发）
    @ws_upgrade {
        path ${ws_path}
        header Upgrade websocket
    }
    handle @ws_upgrade {
        reverse_proxy 127.0.0.1:${local_port} {
            header_up Host            {host}
            header_up X-Real-IP       {remote_host}
            header_up X-Forwarded-For {remote_host}
            flush_interval -1
            # 强制 HTTP/1.1：WebSocket 不兼容 HTTP/2
            transport http { versions 1.1 }
        }
    }

    # ② 普通 HTTP 请求访问 WS 路径 → 404（伪装扫描探测无效）
    handle ${ws_path} {
        respond 404
    }

    # ③ 其余所有路径 → 伪装 nginx 静态页面
    handle {
        root * ${FAKE_WEBROOT}
        file_server
        header Server "nginx/1.24.0"
        header -X-Powered-By
    }

    log { output discard }
}
EOF
    info "Caddy 主配置: ${CADDY_MAIN_CONF}"
    info "站点配置:     ${CADDY_VLESS_CONF}"
}

# ═══════════════════════════════════════════════════════════════════
#  服务单元 — systemd
# ═══════════════════════════════════════════════════════════════════

_write_systemd_unit() {
    load_conf
    local CORE_SVC BIN CONF AFTER
    CORE_SVC=$(proxy_svc_name); BIN=$(core_bin); CONF=$(core_conf_file)
    [[ "${mode:-ws_tls}" == "ws_tls" ]] && AFTER="caddy.service" || AFTER="network-online.target"

    local EXEC_ARGS
    [[ "${core_type:-xray}" == "singbox" ]] && EXEC_ARGS="run -c ${CONF}" || EXEC_ARGS="run -config ${CONF}"

    cat > "/etc/systemd/system/${CORE_SVC}.service" << EOF
[Unit]
Description=VLESS Personal - ${CORE_SVC}
After=network-online.target ${AFTER}
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStartPre=/etc/vless-personal/restore-iptables.sh
ExecStart=${BIN} ${EXEC_ARGS}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
}

# ═══════════════════════════════════════════════════════════════════
#  服务单元 — OpenRC（Alpine）
# ═══════════════════════════════════════════════════════════════════

_write_openrc_unit() {
    load_conf
    local CORE_SVC BIN CONF EXEC_ARGS
    CORE_SVC=$(proxy_svc_name); BIN=$(core_bin); CONF=$(core_conf_file)
    [[ "${core_type:-xray}" == "singbox" ]] && EXEC_ARGS="run -c ${CONF}" || EXEC_ARGS="run -config ${CONF}"

    cat > "/etc/init.d/${CORE_SVC}" << RCEOF
#!/sbin/openrc-run
description="VLESS Personal - ${CORE_SVC}"
command="${BIN}"
command_args="${EXEC_ARGS}"
command_background=true
pidfile="/run/${CORE_SVC}.pid"
output_log="/var/log/${CORE_SVC}.log"
error_log="/var/log/${CORE_SVC}.log"
start_pre() { /etc/vless-personal/restore-iptables.sh; }
depend() { need net; $([ "${mode:-ws_tls}" = "ws_tls" ] && echo "after caddy"); }
RCEOF
    chmod +x "/etc/init.d/${CORE_SVC}"
}

# ═══════════════════════════════════════════════════════════════════
#  配置并启动服务
# ═══════════════════════════════════════════════════════════════════

setup_services() {
    load_conf
    local CORE_SVC
    CORE_SVC=$(proxy_svc_name)
    step "配置系统服务"

    if [[ "$INIT_SYS" == "systemd" ]]; then
        _write_systemd_unit
        systemctl daemon-reload
        if [[ "${mode:-ws_tls}" == "ws_tls" ]]; then
            service_enable caddy
            info "启动 Caddy（首次申请 TLS 证书，约 30~60 秒）..."
            systemctl restart caddy && sleep 5
        fi
        service_enable "$CORE_SVC"
        systemctl restart "$CORE_SVC"
    else
        _write_openrc_unit
        if [[ "${mode:-ws_tls}" == "ws_tls" ]]; then
            service_enable caddy
            rc-service caddy restart && sleep 5
        fi
        service_enable "$CORE_SVC"
        rc-service "$CORE_SVC" start
    fi
    info "服务配置完成"
}

# ═══════════════════════════════════════════════════════════════════
#  流量监控 — iptables 链 + cron 脚本
# ═══════════════════════════════════════════════════════════════════

setup_traffic_monitoring() {
    load_conf
    step "配置流量监控"
    mkdir -p "$CONF_DIR"

    # 初始化流量记录文件
    if [[ ! -f "$TRAFFIC_FILE" ]]; then
        cat > "$TRAFFIC_FILE" << EOF
traffic_month=$(date +%Y-%m)
traffic_bytes_saved=0
traffic_bytes_total=0
traffic_exceeded=false
EOF
    fi

    # 建立 iptables 计数链
    if command -v iptables &>/dev/null; then
        setup_traffic_chain "${ext_port}"
        info "iptables 流量计数链已建立（端口 ${ext_port}）"
    else
        warn "iptables 不可用，流量统计将不工作"
    fi

    # restore-iptables.sh：服务启动时自动恢复计数链（重启后规则消失）
    cat > "${CONF_DIR}/restore-iptables.sh" << 'EOFI'
#!/bin/bash
source /etc/vless-personal/config.env 2>/dev/null || exit 0
command -v iptables &>/dev/null || exit 0
iptables -L VLESS_IN -n &>/dev/null && exit 0  # 链已存在则跳过
# 重建链（重启后 iptables 规则消失）
iptables -N VLESS_IN  2>/dev/null || true
iptables -N VLESS_OUT 2>/dev/null || true
while iptables -D INPUT  -p tcp --dport "${ext_port}" -j VLESS_IN  2>/dev/null; do true; done
while iptables -D OUTPUT -p tcp --sport "${ext_port}" -j VLESS_OUT 2>/dev/null; do true; done
iptables -I INPUT  -p tcp --dport "${ext_port}" -j VLESS_IN
iptables -I OUTPUT -p tcp --sport "${ext_port}" -j VLESS_OUT
iptables -F VLESS_IN;  iptables -A VLESS_IN  -j RETURN
iptables -F VLESS_OUT; iptables -A VLESS_OUT -j RETURN
# 重建后 iptables 字节从 0 起算，旧的累计值已保存在 traffic_bytes_saved
source /etc/vless-personal/traffic.env 2>/dev/null || true
EOFI
    chmod +x "${CONF_DIR}/restore-iptables.sh"

    # 每小时流量检查脚本
    cat > "${CONF_DIR}/traffic-check.sh" << 'EOFC'
#!/bin/bash
CONF_FILE="/etc/vless-personal/config.env"
TRAFFIC_FILE="/etc/vless-personal/traffic.env"
LOG_FILE="/var/log/vless-personal.log"
[[ -f "$CONF_FILE" ]] || exit 0
source "$CONF_FILE"
source "$TRAFFIC_FILE" 2>/dev/null || true

# 检查 iptables 链，不存在则重建
if ! iptables -L VLESS_IN -n &>/dev/null 2>&1; then
    /etc/vless-personal/restore-iptables.sh
fi

# 获取本次运行 iptables 字节（自上次归零后的累计）
IN_B=$(iptables  -L VLESS_IN  -n -v -x 2>/dev/null | awk 'NR==3{print $2+0}')
OUT_B=$(iptables -L VLESS_OUT -n -v -x 2>/dev/null | awk 'NR==3{print $2+0}')
CURRENT=$(( IN_B + OUT_B ))

# 总流量 = 历史保存值 + 本次会话iptables值
TOTAL=$(( ${traffic_bytes_saved:-0} + CURRENT ))

# 持久化写入（下次读取时参考）
sed -i "s/^traffic_bytes_total=.*/traffic_bytes_total=${TOTAL}/" "$TRAFFIC_FILE" 2>/dev/null \
    || echo "traffic_bytes_total=${TOTAL}" >> "$TRAFFIC_FILE"

# 检查限额（0 = 不限）
LIMIT_GB="${traffic_limit_gb:-0}"
[[ "$LIMIT_GB" -le 0 ]] && exit 0

LIMIT=$(( LIMIT_GB * 1024 * 1024 * 1024 ))
if [[ "$TOTAL" -ge "$LIMIT" ]] && [[ "${traffic_exceeded:-false}" != "true" ]]; then
    CORE_SVC="xray"
    [[ "${core_type}" == "singbox" ]] && CORE_SVC="sing-box"
    systemctl stop  "$CORE_SVC" 2>/dev/null || rc-service "$CORE_SVC" stop 2>/dev/null || true
    sed -i 's/^traffic_exceeded=.*/traffic_exceeded=true/' "$TRAFFIC_FILE" \
        || echo "traffic_exceeded=true" >> "$TRAFFIC_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 流量限制 ${LIMIT_GB}GB 已达上限，服务已停止。" >> "$LOG_FILE"
fi
EOFC
    chmod +x "${CONF_DIR}/traffic-check.sh"

    # 月初重置脚本（每月 1 日 00:00 运行）
    cat > "${CONF_DIR}/traffic-reset.sh" << 'EOFR'
#!/bin/bash
CONF_FILE="/etc/vless-personal/config.env"
TRAFFIC_FILE="/etc/vless-personal/traffic.env"
LOG_FILE="/var/log/vless-personal.log"
[[ -f "$CONF_FILE" ]] || exit 0
source "$CONF_FILE"

# 归零 iptables 计数
iptables -Z VLESS_IN  2>/dev/null || true
iptables -Z VLESS_OUT 2>/dev/null || true

# 重置流量记录
cat > "$TRAFFIC_FILE" << ENVEOF
traffic_month=$(date +%Y-%m)
traffic_bytes_saved=0
traffic_bytes_total=0
traffic_exceeded=false
ENVEOF

# 如果服务因超限被停止则重新启动
CORE_SVC="xray"
[[ "${core_type}" == "singbox" ]] && CORE_SVC="sing-box"
systemctl start "$CORE_SVC" 2>/dev/null || rc-service "$CORE_SVC" start 2>/dev/null || true

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 月度流量已重置。" >> "$LOG_FILE"
EOFR
    chmod +x "${CONF_DIR}/traffic-reset.sh"

    # 注册 cron 任务
    _setup_cron
    info "流量监控脚本已部署"
}

_setup_cron() {
    if [[ "$OS_ID" == "alpine" ]]; then
        local CRON_FILE="/etc/crontabs/root"
        touch "$CRON_FILE"
        # 删除旧条目后重新写入
        sed -i '/vless-personal/d' "$CRON_FILE"
        cat >> "$CRON_FILE" << 'EOF'
# vless-personal
0 * * * * /etc/vless-personal/traffic-check.sh >/dev/null 2>&1
0 0 1 * * /etc/vless-personal/traffic-reset.sh >/dev/null 2>&1
EOF
        rc-service crond restart 2>/dev/null || rc-service dcron restart 2>/dev/null || true
    else
        cat > /etc/cron.d/vless-personal << 'EOF'
# vless-personal traffic monitoring
0 * * * * root /etc/vless-personal/traffic-check.sh >/dev/null 2>&1
0 0 1 * * root /etc/vless-personal/traffic-reset.sh >/dev/null 2>&1
EOF
        service_cmd restart cron 2>/dev/null || true
    fi
    info "Cron 任务已注册（每小时检查，月初自动重置）"
}

# ═══════════════════════════════════════════════════════════════════
#  防火墙
# ═══════════════════════════════════════════════════════════════════

setup_firewall() {
    load_conf
    step "配置防火墙"
    local PORTS=("${ext_port}")
    [[ "${mode:-ws_tls}" == "ws_tls" ]] && PORTS+=(80)  # Caddy ACME HTTP-01

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        for p in "${PORTS[@]}"; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
        info "ufw: 已放行端口 ${PORTS[*]}"
        return
    fi
    if command -v iptables &>/dev/null; then
        for p in "${PORTS[@]}"; do
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
        done
        [[ "$OS_ID" == "alpine" ]] && \
            iptables-save > /etc/iptables/rules-save 2>/dev/null || \
            iptables-save > /etc/iptables.rules 2>/dev/null || true
        info "iptables: 已放行端口 ${PORTS[*]}"
    else
        warn "请手动放行端口: ${PORTS[*]}"
    fi
}

# ═══════════════════════════════════════════════════════════════════
#  BBR
# ═══════════════════════════════════════════════════════════════════

enable_bbr() {
    [[ "$OS_ID" == "alpine" ]] && { warn "Alpine 内核通常不含 BBR，跳过"; return; }
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]] && { info "BBR 已启用"; return; }
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" >> /etc/modules-load.d/vless-bbr.conf
    cat > /etc/sysctl.d/99-vless-bbr.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-vless-bbr.conf >/dev/null 2>&1 || true
    info "BBR 已启用 ($(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null))"
}

# ═══════════════════════════════════════════════════════════════════
#  快捷命令
# ═══════════════════════════════════════════════════════════════════

setup_shortcut() {
    local SELF
    SELF=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
    [[ "$SELF" != "$SHORTCUT" ]] && { cp "$SELF" "$SHORTCUT"; chmod +x "$SHORTCUT"; info "快捷命令: vless-p"; }
}

# ═══════════════════════════════════════════════════════════════════
#  显示配置信息 & VLESS 链接
# ═══════════════════════════════════════════════════════════════════

show_config() {
    is_installed || { warn "尚未安装"; return; }
    load_conf

    local server_ip core_label LINK
    server_ip=$(get_server_ip)
    [[ "${core_type:-xray}" == "singbox" ]] && core_label="sing-box" || core_label="Xray-core"

    echo ""; hr
    echo -e "${CYAN}${BOLD}       VLESS Personal Edition — 节点信息${NC}"; hr

    printf "  %-16s ${CYAN}%s${NC}\n" "代理核心:" "${core_label}"
    printf "  %-16s ${CYAN}%s${NC}\n" "协议模式:" "$([[ "${mode}" == "reality" ]] && echo 'VLESS+Reality (无需域名)' || echo 'VLESS+WS+TLS')"
    printf "  %-16s %s\n"             "服务器IP:"  "${server_ip}"
    printf "  %-16s ${CYAN}%s${NC}\n" "外部端口:" "${ext_port}"

    if [[ "${mode:-ws_tls}" == "ws_tls" ]]; then
        printf "  %-16s ${CYAN}%s${NC}\n" "域名:"    "${domain}"
        printf "  %-16s ${CYAN}%s${NC}\n" "WS 路径:" "${ws_path}"
        printf "  %-16s %s\n"             "内部端口:" "127.0.0.1:${local_port}（${core_label}）"
        printf "  %-16s %s\n"             "TLS:"     "Let's Encrypt（Caddy 自动续签）"
    else
        printf "  %-16s ${CYAN}%s${NC}\n" "伪装域名:" "${reality_dest}"
        printf "  %-16s %s\n"             "公钥 pbk:"  "${reality_public_key}"
        printf "  %-16s %s\n"             "Short ID:"  "${reality_short_id}"
        printf "  %-16s %s\n"             "流量控制:"  "xtls-rprx-vision"
    fi

    printf "  %-16s ${CYAN}%s${NC}\n" "UUID:"     "${uuid}"

    if [[ "${relay_enabled:-false}" == "true" ]]; then
        printf "  %-16s ${YELLOW}%s${NC}\n" "中转模式:" "已启用 → ${relay_host}:${relay_port}"
        printf "  %-16s %s\n"               "中转路径:" "${relay_sni}${relay_ws_path}"
    fi

    printf "  %-16s %s\n" "安装时间:" "${install_date}"

    hr; echo ""
    echo -e "${YELLOW}${BOLD}  ✦ VLESS 链接（复制到客户端）:${NC}"

    if [[ "${mode:-ws_tls}" == "ws_tls" ]]; then
        local encoded_path
        encoded_path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${ws_path}'))" 2>/dev/null \
                       || printf '%s' "${ws_path}" | sed 's|/|%2F|g')
        LINK="vless://${uuid}@${domain}:${ext_port}?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${encoded_path}#VLESS-${domain}"
    else
        LINK="vless://${uuid}@${server_ip}:${ext_port}?encryption=none&security=reality&sni=${reality_dest}&pbk=${reality_public_key}&sid=${reality_short_id}&fp=chrome&flow=xtls-rprx-vision&type=tcp#VLESS-Reality"
    fi

    echo -e "  ${GREEN}${LINK}${NC}"; echo ""

    echo -e "${YELLOW}${BOLD}  ✦ 手动填写参数:${NC}"
    if [[ "${mode:-ws_tls}" == "ws_tls" ]]; then
        printf "  %-12s %s\n" "地址:" "${domain}"
        printf "  %-12s %s\n" "端口:" "${ext_port}"
        printf "  %-12s %s\n" "UUID:" "${uuid}"
        printf "  %-12s %s\n" "传输:" "WebSocket | 路径: ${ws_path}"
        printf "  %-12s %s\n" "TLS:"  "启用 | SNI: ${domain}"
    else
        printf "  %-12s %s\n" "地址:"    "${server_ip}"
        printf "  %-12s %s\n" "端口:"    "${ext_port}"
        printf "  %-12s %s\n" "UUID:"    "${uuid}"
        printf "  %-12s %s\n" "传输:"    "TCP"
        printf "  %-12s %s\n" "流量控制:" "xtls-rprx-vision"
        printf "  %-12s %s\n" "TLS:"     "Reality | SNI: ${reality_dest}"
        printf "  %-12s %s\n" "公钥:"    "${reality_public_key}"
        printf "  %-12s %s\n" "短 ID:"   "${reality_short_id}"
        printf "  %-12s %s\n" "指纹:"    "chrome"
    fi
    echo ""
    if command -v qrencode &>/dev/null; then
        echo -e "${BOLD}  ✦ 二维码:${NC}"; qrencode -t ansiutf8 "$LINK" 2>/dev/null; echo ""
    fi
    hr
}

# ═══════════════════════════════════════════════════════════════════
#  流量统计
# ═══════════════════════════════════════════════════════════════════

show_traffic() {
    is_installed || { warn "尚未安装"; return; }
    load_conf
    load_traffic 2>/dev/null || true

    # 运行一次 traffic-check 以更新最新字节数
    [[ -x "${CONF_DIR}/traffic-check.sh" ]] && "${CONF_DIR}/traffic-check.sh" 2>/dev/null
    load_traffic 2>/dev/null || true

    local used_bytes="${traffic_bytes_total:-0}"
    local month="${traffic_month:-$(date +%Y-%m)}"
    local limit_gb="${traffic_limit_gb:-0}"

    echo ""; hr
    echo -e "${BOLD}  流量统计 — ${month}${NC}"; hr
    printf "  %-16s %s\n" "本月已用:" "$(human_bytes "$used_bytes")"

    if [[ "$limit_gb" -gt 0 ]]; then
        local limit_bytes=$(( limit_gb * 1024 * 1024 * 1024 ))
        local remain_bytes=$(( limit_bytes - used_bytes ))
        [[ $remain_bytes -lt 0 ]] && remain_bytes=0
        printf "  %-16s %s\n" "月度上限:" "${limit_gb} GB"
        printf "  %-16s %s\n" "剩余流量:" "$(human_bytes "$remain_bytes")"

        # 进度条
        local pct=$(( used_bytes * 100 / limit_bytes ))
        [[ $pct -gt 100 ]] && pct=100
        local filled=$(( pct * 30 / 100 ))
        local bar=""
        for (( i=0; i<filled; i++ )); do bar+="█"; done
        for (( i=filled; i<30; i++ )); do bar+="░"; done
        local color=$GREEN
        [[ $pct -ge 80 ]] && color=$YELLOW
        [[ $pct -ge 95 ]] && color=$RED
        printf "  %-16s ${color}[%s]${NC} %d%%\n" "使用进度:" "$bar" "$pct"

        if [[ "${traffic_exceeded:-false}" == "true" ]]; then
            echo -e "\n  ${RED}${BOLD}⚠  已达上限，代理服务已停止${NC}"
            echo -e "  ${YELLOW}月初（每月1日）将自动重置并重启${NC}"
            echo -e "  或执行菜单「8」手动重置"
        fi
    else
        printf "  %-16s %s\n" "月度上限:" "不限制"
    fi

    printf "  %-16s %s\n" "月初自动重置:" "是（每月 1 日 00:00）"
    hr
}

# 手动重置本月流量（菜单调用）
reset_traffic_manual() {
    is_installed || { warn "尚未安装"; return; }
    read -rp "  确认手动重置本月流量统计? [y/N]: " c
    [[ "${c,,}" == "y" ]] || { info "取消"; return; }
    "${CONF_DIR}/traffic-reset.sh" 2>/dev/null \
        && info "流量已重置，服务已重启" \
        || warn "重置脚本执行失败，请检查 ${CONF_DIR}/traffic-reset.sh"
}

# ═══════════════════════════════════════════════════════════════════
#  中转/转发管理
# ═══════════════════════════════════════════════════════════════════

manage_relay() {
    is_installed || { warn "尚未安装"; return; }
    load_conf

    echo ""
    if [[ "${relay_enabled:-false}" == "true" ]]; then
        echo -e "  中转状态: ${GREEN}已启用${NC}"
        printf "  %-12s %s\n" "远程地址:" "${relay_host}:${relay_port}"
        printf "  %-12s %s\n" "远程域名:" "${relay_sni}"
        printf "  %-12s %s\n" "远程路径:" "${relay_ws_path}"
    else
        echo -e "  中转状态: ${YELLOW}未启用${NC}（直连出站）"
    fi
    hr
    echo "  1) 启用/修改中转"
    echo "  2) 禁用中转（切回直连）"
    echo "  0) 返回"
    read -rp "  选择 [0-2]: " rc_; echo ""
    case "$rc_" in
        1) _enable_relay   ;;
        2) _disable_relay  ;;
    esac
}

_enable_relay() {
    echo -e "${BOLD}  配置中转节点（远程 VLESS+WS+TLS 服务器）${NC}"

    local R_HOST R_PORT R_SNI R_UUID R_PATH
    while true; do
        read -rp "  远程服务器地址（IP 或域名）: " R_HOST
        [[ -n "$R_HOST" ]] && break; warn "不能为空"
    done
    while true; do
        read -rp "  远程服务器端口（例: 8443）: " R_PORT
        [[ "$R_PORT" =~ ^[0-9]+$ ]] && break; warn "请输入数字端口"
    done
    while true; do
        read -rp "  远程 SNI 域名（TLS 验证用，例: remote.example.com）: " R_SNI
        [[ -n "$R_SNI" ]] && break; warn "不能为空"
    done
    while true; do
        read -rp "  远程 UUID: " R_UUID
        [[ "$R_UUID" =~ ^[0-9a-f-]{36}$ ]] && break; warn "格式应为 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    done
    while true; do
        read -rp "  远程 WS 路径（例: /proxy）: " R_PATH
        [[ "$R_PATH" =~ ^/ ]] && break; warn "路径须以 / 开头"
    done

    # 更新 config.env
    _conf_set "relay_enabled"  "true"
    _conf_set "relay_host"     "$R_HOST"
    _conf_set "relay_port"     "$R_PORT"
    _conf_set "relay_sni"      "$R_SNI"
    _conf_set "relay_uuid"     "$R_UUID"
    _conf_set "relay_ws_path"  "$R_PATH"

    configure_core
    service_cmd restart "$(proxy_svc_name)"
    info "中转已启用: ${R_HOST}:${R_PORT}${R_PATH}"
}

_disable_relay() {
    _conf_set "relay_enabled" "false"
    configure_core
    service_cmd restart "$(proxy_svc_name)"
    info "中转已禁用，已切换为直连出站"
}

# 幂等写入 config.env 的 key=value（存在则替换，不存在则追加）
_conf_set() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$CONF_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$CONF_FILE"
    else
        echo "${key}=${val}" >> "$CONF_FILE"
    fi
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
        [[ "${mode:-ws_tls}" == "reality" && "$svc" == "caddy" ]] && continue
        if service_is_active "$svc"; then
            printf "  %-14s ${GREEN}● 运行中${NC}\n" "${svc}:"
        else
            printf "  %-14s ${RED}● 已停止${NC}\n" "${svc}:"
        fi
    done

    echo ""; echo -e "${BOLD}  端口监听${NC}"
    if ss -tlnp 2>/dev/null | grep -q ":${ext_port}"; then
        echo -e "  :${ext_port}   ${GREEN}✓ 已监听${NC}"
    else
        echo -e "  :${ext_port}   ${RED}✗ 未监听${NC}"
    fi
    if [[ "${mode:-ws_tls}" == "ws_tls" ]] && is_installed; then
        ss -tlnp 2>/dev/null | grep -q ":${local_port}" \
            && echo -e "  :${local_port}  ${GREEN}✓ 已监听${NC} (${CORE_SVC} 本地 WS)" \
            || echo -e "  :${local_port}  ${RED}✗ 未监听${NC}"
    fi
    hr
}

# ═══════════════════════════════════════════════════════════════════
#  重启服务
# ═══════════════════════════════════════════════════════════════════

restart_services() {
    load_conf 2>/dev/null
    local CORE_SVC
    CORE_SVC=$(proxy_svc_name)
    step "重启服务"
    [[ "${mode:-ws_tls}" == "ws_tls" ]] && service_cmd restart caddy && sleep 2
    service_cmd restart "$CORE_SVC"
    info "${CORE_SVC} 已重启"
    show_status
}

# ═══════════════════════════════════════════════════════════════════
#  查看日志
# ═══════════════════════════════════════════════════════════════════

show_logs() {
    load_conf 2>/dev/null
    local CORE_SVC
    CORE_SVC=$(proxy_svc_name)
    echo ""
    echo "  1) ${CORE_SVC} 日志（最近 80 行）"
    echo "  2) ${CORE_SVC} 错误日志（journalctl -xe，systemd 专用）"
    echo "  3) Caddy 日志"
    echo "  4) 流量操作日志"
    echo "  0) 返回"
    read -rp "  选择 [0-4]: " lc; echo ""
    case "$lc" in
        1)
            if [[ "$INIT_SYS" == "systemd" ]]; then
                journalctl -u "${CORE_SVC}" -n 80 --no-pager 2>/dev/null || echo "无日志"
            else
                tail -80 "/var/log/${CORE_SVC}.log" 2>/dev/null || warn "日志文件不存在"
            fi ;;
        2)
            [[ "$INIT_SYS" == "systemd" ]] \
                && journalctl -xe -u "${CORE_SVC}" --no-pager 2>/dev/null \
                || warn "journalctl -xe 仅 systemd 可用" ;;
        3)
            if [[ "$INIT_SYS" == "systemd" ]]; then
                journalctl -u caddy -n 80 --no-pager 2>/dev/null || echo "无日志"
            else
                warn "Caddy 访问日志已设为 discard（节省磁盘）"
            fi ;;
        4) tail -50 "$LOG_FILE" 2>/dev/null || echo "暂无流量操作日志" ;;
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
    _conf_set "uuid" "$NEW_UUID"
    configure_core
    service_cmd restart "$(proxy_svc_name)"
    info "UUID 已更换为: ${NEW_UUID}"
    show_config
}

# ═══════════════════════════════════════════════════════════════════
#  一键卸载
# ═══════════════════════════════════════════════════════════════════

uninstall() {
    echo ""
    echo -e "${RED}${BOLD}  ⚠  即将卸载 VLESS Personal Edition${NC}"
    echo -e "  将移除: 代理核心 + 配置 + 流量监控 + cron 任务"
    echo -e "  不影响: Caddy 本体（若非本脚本安装）+ 其他系统依赖"
    echo ""
    read -rp "  确认卸载? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { info "已取消"; return; }

    load_conf 2>/dev/null || true
    local CORE_SVC
    CORE_SVC=$(proxy_svc_name)

    step "停止并移除服务"
    service_cmd stop "$CORE_SVC" 2>/dev/null || true
    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl disable "$CORE_SVC" 2>/dev/null || true
        rm -f "/etc/systemd/system/${CORE_SVC}.service"
        systemctl daemon-reload 2>/dev/null || true
    else
        rc-update del "$CORE_SVC" default 2>/dev/null || true
        rm -f "/etc/init.d/${CORE_SVC}"
    fi

    step "移除代理核心文件"
    if [[ "${core_type:-xray}" == "singbox" ]]; then
        rm -f "$SBOX_BIN" "$SBOX_CONF"; rmdir "$SBOX_CONF_DIR" 2>/dev/null || true
    else
        rm -f "$XRAY_BIN" "$XRAY_CONF"; rm -rf /usr/local/share/xray; rmdir "$XRAY_CONF_DIR" 2>/dev/null || true
    fi
    rm -f /etc/modules-load.d/vless-bbr.conf /etc/sysctl.d/99-vless-bbr.conf

    step "清理 iptables 计数链"
    while iptables -D INPUT  -p tcp --dport "${ext_port}" -j VLESS_IN  2>/dev/null; do true; done
    while iptables -D OUTPUT -p tcp --sport "${ext_port}" -j VLESS_OUT 2>/dev/null; do true; done
    iptables -F VLESS_IN  2>/dev/null || true; iptables -X VLESS_IN  2>/dev/null || true
    iptables -F VLESS_OUT 2>/dev/null || true; iptables -X VLESS_OUT 2>/dev/null || true

    step "清理 cron 任务"
    if [[ "$OS_ID" == "alpine" ]]; then
        sed -i '/vless-personal/d' /etc/crontabs/root 2>/dev/null || true
    else
        rm -f /etc/cron.d/vless-personal
    fi

    if [[ "${mode:-ws_tls}" == "ws_tls" ]]; then
        step "移除 Caddy 站点配置"
        rm -f "$CADDY_VLESS_CONF"
        local BACKUP
        BACKUP=$(ls -t "${CADDY_MAIN_CONF}.bak."* 2>/dev/null | head -1)
        if [[ -n "$BACKUP" ]]; then
            cp "$BACKUP" "$CADDY_MAIN_CONF"; info "Caddy 主配置已从备份还原"
        elif grep -q "vless-personal" "$CADDY_MAIN_CONF" 2>/dev/null; then
            echo "# Caddy config - restored by vless-personal.sh" > "$CADDY_MAIN_CONF"
        fi
        service_cmd restart caddy 2>/dev/null || true

        if [[ "${caddy_preinstalled:-true}" == "false" ]]; then
            echo ""
            read -rp "  Caddy 由本脚本安装，是否一并卸载? [y/N]: " rm_caddy
            if [[ "${rm_caddy,,}" == "y" ]]; then
                service_cmd stop caddy 2>/dev/null || true
                [[ "$INIT_SYS" == "systemd" ]] && systemctl disable caddy 2>/dev/null \
                                               || rc-update del caddy default 2>/dev/null
                [[ "$PKG_MGR" == "apt" ]] \
                    && { apt-get remove -y caddy 2>/dev/null || true
                         rm -f /etc/apt/sources.list.d/caddy-stable.list
                         rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg; } \
                    || apk del caddy 2>/dev/null || true
                info "Caddy 已卸载"
            fi
        fi
    fi

    step "清理配置目录"
    rm -rf "$CONF_DIR" "$FAKE_WEBROOT"
    rm -f  "$SHORTCUT" "$LOG_FILE"

    echo ""
    echo -e "${GREEN}${BOLD}  ✓  卸载完成${NC}"
    echo -e "  BBR 参数已清除（重启后完全生效）"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════
#  主安装流程
# ═══════════════════════════════════════════════════════════════════

do_install() {
    if is_installed; then
        echo ""; warn "检测到已有安装实例"
        load_conf
        echo -e "  域名/模式: ${mode:-ws_tls}  核心: ${core_type:-xray}  UUID: ${uuid}"
        read -rp "  是否覆盖重新安装? [y/N]: " ri
        [[ "${ri,,}" == "y" ]] || return
        service_cmd stop "$(proxy_svc_name)" 2>/dev/null || true
        [[ "${mode:-ws_tls}" == "ws_tls" ]] && service_cmd stop caddy 2>/dev/null || true
    fi

    echo ""
    echo -e "${CYAN}${BOLD}══════════ VLESS Personal Edition — 安装向导 ══════════${NC}"
    echo ""

    # ── 1. 选择代理核心 ─────────────────────────────────────────
    echo -e "${BOLD}  ① 代理核心:${NC}"
    echo "    1) Xray-core   (github.com/XTLS/Xray-core)"
    echo "    2) sing-box    (github.com/SagerNet/sing-box)"
    local CORE_TYPE CORE_CHOICE
    while true; do
        read -rp "  选择 [1/2]（默认 1）: " CORE_CHOICE
        case "${CORE_CHOICE:-1}" in
            1) CORE_TYPE="xray";    break ;;
            2) CORE_TYPE="singbox"; break ;;
            *) warn "请输入 1 或 2" ;;
        esac
    done

    # ── 2. 选择协议模式 ─────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ② 协议模式:${NC}"
    echo "    1) VLESS + WS + TLS（需要自己的域名，通过 Caddy 自动续签证书）"
    echo "    2) VLESS + Reality  （无需域名，借用公共域名的 TLS 指纹）"
    local MODE DOMAIN EMAIL LOCAL_PORT WS_PATH
    local REALITY_DEST REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
    while true; do
        read -rp "  选择 [1/2]（默认 1）: " MC
        case "${MC:-1}" in
            1) MODE="ws_tls";  break ;;
            2) MODE="reality"; break ;;
            *) warn "请输入 1 或 2" ;;
        esac
    done

    # ── 3. 模式相关参数 ─────────────────────────────────────────
    echo ""
    if [[ "$MODE" == "ws_tls" ]]; then
        echo -e "${BOLD}  ③ WS+TLS 参数:${NC}"
        while true; do
            read -rp "  域名（例: proxy.example.com）: " DOMAIN
            DOMAIN="${DOMAIN// /}"
            [[ -n "$DOMAIN" && "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] && break
            warn "域名格式不正确"
        done
        while true; do
            read -rp "  邮箱（TLS 证书通知）: " EMAIL
            [[ "$EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break
            warn "邮箱格式不正确"
        done
        LOCAL_PORT=$(random_local_port)
        WS_PATH=$(ws_path_from_domain "$DOMAIN")
        read -rp "  自定义 WS 路径? 默认 ${WS_PATH} [y/N]: " cp_
        if [[ "${cp_,,}" == "y" ]]; then
            read -rp "  路径（以 / 开头）: " WS_PATH
            [[ "$WS_PATH" =~ ^/ ]] || WS_PATH="/${WS_PATH}"
        fi
    else
        echo -e "${BOLD}  ③ Reality 参数 — 选择伪装域名:${NC}"
        for i in "${!REALITY_DEST_LIST[@]}"; do
            printf "    %d) %s\n" "$(( i+1 ))" "${REALITY_DEST_LIST[$i]}"
        done
        while true; do
            read -rp "  选择 [1-${#REALITY_DEST_LIST[@]}]（默认 1）: " RDC
            RDC="${RDC:-1}"
            if [[ "$RDC" =~ ^[0-9]+$ ]] && [[ "$RDC" -ge 1 ]] && [[ "$RDC" -le "${#REALITY_DEST_LIST[@]}" ]]; then
                REALITY_DEST="${REALITY_DEST_LIST[$(( RDC-1 ))]}"; break
            fi
            warn "请输入 1~${#REALITY_DEST_LIST[@]}"
        done
        info "已选伪装域名: ${REALITY_DEST}"
    fi

    # ── 4. 自定义端口 ──────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ④ 外部监听端口（默认 8443）:${NC}"
    local EXT_PORT_IN
    while true; do
        read -rp "  端口 [1024-65535]（直接回车使用 8443）: " EXT_PORT_IN
        EXT_PORT_IN="${EXT_PORT_IN:-8443}"
        if [[ "$EXT_PORT_IN" =~ ^[0-9]+$ ]] && [[ "$EXT_PORT_IN" -ge 1024 ]] && [[ "$EXT_PORT_IN" -le 65535 ]]; then
            break
        fi
        warn "请输入 1024~65535 之间的数字"
    done

    # ── 5. UUID ────────────────────────────────────────────────
    local AUTO_UUID
    AUTO_UUID=$(gen_uuid)
    echo ""
    read -rp "  自定义 UUID? 默认随机生成 [y/N]: " cu
    if [[ "${cu,,}" == "y" ]]; then
        while true; do
            read -rp "  UUID（格式 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx）: " AUTO_UUID
            [[ "$AUTO_UUID" =~ ^[0-9a-f-]{36}$ ]] && break
            warn "格式不正确"
        done
    fi

    # ── 6. 流量限制 ────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ⑤ 月度流量限制（月初自动重置，0 = 不限制）:${NC}"
    local TRAFFIC_LIMIT_GB=0
    read -rp "  限制 GB 数（直接回车 = 不限制）: " TLG
    if [[ "$TLG" =~ ^[0-9]+$ ]] && [[ "$TLG" -gt 0 ]]; then
        TRAFFIC_LIMIT_GB="$TLG"
        info "月度限额: ${TRAFFIC_LIMIT_GB} GB"
    else
        info "流量不限制"
    fi

    # ── 7. 中转节点 ────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ⑥ 中转/转发到远程服务器?${NC}"
    echo "    启用后，本节点将作为中转，转发流量到指定的远程 VLESS+WS+TLS 服务器"
    local RELAY_ENABLED=false
    local RELAY_HOST="" RELAY_PORT="" RELAY_SNI="" RELAY_UUID="" RELAY_WS_PATH=""
    read -rp "  启用中转? [y/N]: " relay_yn
    if [[ "${relay_yn,,}" == "y" ]]; then
        RELAY_ENABLED=true
        while true; do read -rp "  远程地址（IP/域名）: " RELAY_HOST; [[ -n "$RELAY_HOST" ]] && break; warn "不能为空"; done
        while true; do read -rp "  远程端口: " RELAY_PORT; [[ "$RELAY_PORT" =~ ^[0-9]+$ ]] && break; warn "请输入数字"; done
        while true; do read -rp "  远程 SNI 域名: " RELAY_SNI; [[ -n "$RELAY_SNI" ]] && break; warn "不能为空"; done
        while true; do
            read -rp "  远程 UUID: " RELAY_UUID
            [[ "$RELAY_UUID" =~ ^[0-9a-f-]{36}$ ]] && break
            warn "格式应为 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        done
        while true; do read -rp "  远程 WS 路径（如 /proxy）: " RELAY_WS_PATH; [[ "$RELAY_WS_PATH" =~ ^/ ]] && break; warn "须以 / 开头"; done
    fi

    # ── 8. BBR ─────────────────────────────────────────────────
    echo ""
    local DO_BBR=true
    read -rp "  启用 BBR 网络加速? [Y/n]: " bbr_c
    [[ "${bbr_c,,}" == "n" ]] && DO_BBR=false

    # ── 9. 确认 ─────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ── 确认安装参数 ──${NC}"
    printf "  %-16s ${CYAN}%s${NC}\n" "代理核心:" "$([[ "$CORE_TYPE" == "singbox" ]] && echo 'sing-box' || echo 'Xray-core')"
    printf "  %-16s ${CYAN}%s${NC}\n" "协议模式:" "$([[ "$MODE" == "reality" ]] && echo 'VLESS+Reality' || echo 'VLESS+WS+TLS')"
    [[ "$MODE" == "ws_tls" ]] && printf "  %-16s ${CYAN}%s${NC}\n" "域名:" "${DOMAIN}"
    [[ "$MODE" == "reality" ]] && printf "  %-16s ${CYAN}%s${NC}\n" "伪装域名:" "${REALITY_DEST}"
    printf "  %-16s ${CYAN}%s${NC}\n" "外部端口:" "${EXT_PORT_IN}"
    printf "  %-16s %s\n"             "UUID:"     "${AUTO_UUID}"
    [[ "$MODE" == "ws_tls" ]] && printf "  %-16s %s\n" "WS 路径:" "${WS_PATH}"
    printf "  %-16s %s\n" "月度流量限制:" "$([[ "$TRAFFIC_LIMIT_GB" -gt 0 ]] && echo "${TRAFFIC_LIMIT_GB} GB" || echo '不限制')"
    printf "  %-16s %s\n" "中转转发:"    "$($RELAY_ENABLED && echo "→ ${RELAY_HOST}:${RELAY_PORT}" || echo '不启用')"
    printf "  %-16s %s\n" "BBR:"        "$($DO_BBR && echo '启用' || echo '不启用')"
    echo ""
    read -rp "  确认并开始安装? [Y/n]: " final_c
    [[ "${final_c,,}" == "n" ]] && { info "已取消"; return; }

    # ── 10. 安装各组件 ─────────────────────────────────────────
    install_base_deps

    if [[ "$CORE_TYPE" == "singbox" ]]; then
        install_singbox
    else
        install_xray
    fi

    # Reality 需要先安装好二进制才能生成密钥
    if [[ "$MODE" == "reality" ]]; then
        info "生成 Reality 密钥对..."
        # 临时设置 core_type 供 gen_reality_keys 识别
        core_type="$CORE_TYPE" gen_reality_keys
        REALITY_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
        REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY"
        REALITY_SHORT_ID="$REALITY_SHORT_ID"
        info "Reality 公钥: ${REALITY_PUBLIC_KEY}"
        info "Short ID:    ${REALITY_SHORT_ID}"
    fi

    # ── 11. 写 config.env ──────────────────────────────────────
    # ⚠ install_date 的值必须加双引号，否则 source 时时间中的空格会导致
    #   bash 把 "HH:MM:SS" 当命令执行（command not found bug）
    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" << EOF
# VLESS Personal Edition 配置文件（请勿手动修改）
core_type=${CORE_TYPE}
mode=${MODE}
uuid=${AUTO_UUID}
ext_port=${EXT_PORT_IN}
install_date="$(date '+%Y-%m-%d %H:%M:%S')"
traffic_limit_gb=${TRAFFIC_LIMIT_GB}
relay_enabled=${RELAY_ENABLED}
relay_host=${RELAY_HOST}
relay_port=${RELAY_PORT}
relay_sni=${RELAY_SNI}
relay_uuid=${RELAY_UUID}
relay_ws_path=${RELAY_WS_PATH}
EOF
    # 模式专属字段
    if [[ "$MODE" == "ws_tls" ]]; then
        cat >> "$CONF_FILE" << EOF
domain=${DOMAIN}
email=${EMAIL}
local_port=${LOCAL_PORT}
ws_path=${WS_PATH}
EOF
    else
        cat >> "$CONF_FILE" << EOF
reality_dest=${REALITY_DEST}
reality_private_key=${REALITY_PRIVATE_KEY}
reality_public_key=${REALITY_PUBLIC_KEY}
reality_short_id=${REALITY_SHORT_ID}
EOF
    fi

    # ── 12. 配置各组件 ────────────────────────────────────────
    if [[ "$MODE" == "ws_tls" ]]; then
        install_caddy
        configure_xray_ws 2>/dev/null || configure_singbox_ws 2>/dev/null || configure_core
        setup_fake_web
        configure_caddy
    else
        configure_core
    fi

    setup_services
    setup_firewall
    setup_traffic_monitoring
    $DO_BBR && enable_bbr || true
    setup_shortcut

    # ── 完成 ──────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║                  ✓  安装完成！                        ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    if [[ "$MODE" == "ws_tls" ]]; then
        echo -e "  ${YELLOW}⚠ 重要：${NC}请确保 ${CYAN}${DOMAIN}${NC} 的 DNS A 记录已解析到本机 IP"
        echo -e "  Caddy 通过 HTTP-01 验证申请 Let's Encrypt 证书（约 30~60 秒后可用）"
    else
        echo -e "  ${YELLOW}⚠ 注意：${NC}Reality 模式直接监听 :${EXT_PORT_IN}，无需域名，即可连接"
    fi
    echo ""
    show_config
}

# ═══════════════════════════════════════════════════════════════════
#  主菜单
# ═══════════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}${BOLD}║      VLESS Personal Edition  v3.0  (vless-p)            ║${NC}"
        echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════╝${NC}"

        if is_installed; then
            load_conf 2>/dev/null
            load_traffic 2>/dev/null || true
            local CORE_SVC xs cs used_str
            CORE_SVC=$(proxy_svc_name)
            service_is_active "$CORE_SVC" && xs="${GREEN}运行中${NC}" || xs="${RED}已停止${NC}"
            service_is_active caddy        && cs="${GREEN}运行中${NC}" || cs="${RED}已停止${NC}"
            local mode_str
            [[ "${mode:-ws_tls}" == "reality" ]] && mode_str="Reality" || mode_str="WS+TLS"
            printf "  核心: ${CYAN}%s${NC}(%s)  %s" "${core_type:-xray}" "$mode_str" "$(echo -e $xs)"
            [[ "${mode:-ws_tls}" == "ws_tls" ]] && printf "   Caddy: %s" "$(echo -e $cs)"
            echo ""
            printf "  端口: ${CYAN}%s${NC}" "${ext_port:-8443}"
            if [[ "${mode:-ws_tls}" == "ws_tls" ]]; then
                printf "   域名: %s  WS: %s" "${domain}" "${ws_path}"
            else
                printf "   伪装: %s" "${reality_dest}"
            fi
            echo ""
            # 流量简要
            local tlimit="${traffic_limit_gb:-0}"
            if [[ "$tlimit" -gt 0 ]]; then
                used_str="本月已用: $(human_bytes "${traffic_bytes_total:-0}") / ${tlimit}GB"
                [[ "${traffic_exceeded:-false}" == "true" ]] && used_str+=" ${RED}(已超限)${NC}"
                echo -e "  ${used_str}"
            fi
        else
            echo -e "  状态: ${YELLOW}未安装${NC}"
        fi
        hr
        echo "  1) 安装（选择核心 / 模式 / 端口 / 流量限制 / 中转）"
        echo "  2) 查看配置 / 链接"
        echo "  3) 服务状态"
        echo "  4) 重启服务"
        echo "  5) 查看日志"
        echo "  6) 更换 UUID"
        echo "  7) 流量统计 / 手动重置"
        echo "  8) 中转/转发设置"
        echo "  9) 一键卸载"
        echo "  0) 退出"
        hr
        read -rp "  请选择 [0-9]: " choice
        case "$choice" in
            1) do_install        ;;
            2) show_config       ;;
            3) show_status       ;;
            4) restart_services  ;;
            5) show_logs         ;;
            6) rotate_uuid       ;;
            7)
                show_traffic
                echo ""
                read -rp "  手动重置本月流量? [y/N]: " rst
                [[ "${rst,,}" == "y" ]] && reset_traffic_manual
                ;;
            8) manage_relay      ;;
            9) uninstall         ;;
            0) echo "  再见！"; exit 0 ;;
            *) warn "无效选项，请输入 0-9" ;;
        esac
    done
}

# ── 入口 ─────────────────────────────────────────────────────────
check_root
detect_os
main_menu
