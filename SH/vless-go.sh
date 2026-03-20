#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════╗
# ║          VLESS Personal Edition  v3.1                             ║
# ║  支持系统: Debian / Ubuntu / Alpine                                ║
# ║  代理核心: Xray-core 或 sing-box（安装时选择）                     ║
# ║  协议模式: VLESS+WS+TLS（需域名）| VLESS+Reality（无需域名）       ║
# ║  TLS前端:  Caddy（WS+TLS 模式，自动续签 Let's Encrypt）            ║
# ║  TLS端口:  443 / 8443 / 2053 / 2083 / 2087 / 2096（可选）         ║
# ║  WS路径:   普通 HTTP 访问伪装成 404                                ║
# ║  流量限制: 可选，超限自动停止，月初自动重置                         ║
# ║  中转转发: 菜单独立设置，不干扰主节点安装                          ║
# ║  下载源:   Xray     → github.com/XTLS/Xray-core/releases          ║
# ║            sing-box → github.com/SagerNet/sing-box/releases       ║
# ╚═══════════════════════════════════════════════════════════════════╝
# wget -O vless-go.sh https://raw.githubusercontent.com/SuzukiRenz/ScriptHub/refs/heads/main/SH/vless-go.sh && chmod +x vless-go.sh && ./vless-go.sh

# ── 颜色（$'\033[...]' 在赋值时转义，避免 printf 输出字面 \033 乱码）─
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

# ── 路径常量 ─────────────────────────────────────────────────────────
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

# ── TLS 支持端口列表（Caddy 可监听任意端口，但以下为主流 TLS 端口）──
# 443  : 标准 HTTPS
# 8443 : 次标准 HTTPS（默认）
# 2053 : Cloudflare CDN 兼容
# 2083 : Cloudflare CDN 兼容
# 2087 : Cloudflare CDN 兼容
# 2096 : Cloudflare CDN 兼容
TLS_PORTS=(443 8443 2053 2083 2087 2096)

# ── Reality 可借用的公共域名（x-ui 项目同款）──────────────────────────
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
#  基础工具函数
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

pkg_update()  { [[ "$PKG_MGR" == "apt" ]] && apt-get update -qq 2>/dev/null || apk update -q 2>/dev/null; }
pkg_install() { [[ "$PKG_MGR" == "apt" ]] && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" || apk add --quiet "$@"; }

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

load_conf()    { [[ -f "$CONF_FILE" ]]   || return 1; source "$CONF_FILE"; }
load_traffic() { [[ -f "$TRAFFIC_FILE" ]] || return 1; source "$TRAFFIC_FILE"; }

service_cmd()    { [[ "$INIT_SYS" == "systemd" ]] && systemctl "$1" "$2" 2>/dev/null || rc-service "$2" "$1" 2>/dev/null; }
service_enable() { [[ "$INIT_SYS" == "systemd" ]] && systemctl enable "$1" 2>/dev/null || rc-update add "$1" default 2>/dev/null; }
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

# 根据 config.env 中 core_type 返回服务名 / 二进制路径 / 配置文件路径
proxy_svc_name() { load_conf 2>/dev/null; [[ "${core_type:-xray}" == "singbox" ]] && echo "sing-box" || echo "xray"; }
core_bin()       { load_conf 2>/dev/null; [[ "${core_type:-xray}" == "singbox" ]] && echo "$SBOX_BIN"  || echo "$XRAY_BIN"; }
core_conf_file() { load_conf 2>/dev/null; [[ "${core_type:-xray}" == "singbox" ]] && echo "$SBOX_CONF" || echo "$XRAY_CONF"; }

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        if(b<1048576)      printf "%.1f KB", b/1024
        else if(b<1073741824) printf "%.2f MB", b/1048576
        else               printf "%.3f GB", b/1073741824
    }'
}

# 幂等写入 config.env 的 key=value
_conf_set() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$CONF_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$CONF_FILE"
    else
        echo "${key}=${val}" >> "$CONF_FILE"
    fi
}

# ═══════════════════════════════════════════════════════════════════
#  安装基础依赖
# ═══════════════════════════════════════════════════════════════════

install_base_deps() {
    step "安装基础依赖"
    pkg_update
    if [[ "$PKG_MGR" == "apt" ]]; then
        pkg_install curl wget unzip tar iproute2 openssl ca-certificates gnupg lsb-release iptables cron
    else
        pkg_install curl wget unzip tar iproute2 openssl ca-certificates util-linux iptables dcron
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
        _conf_set "caddy_preinstalled" "true"
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
    _conf_set "caddy_preinstalled" "false"
    info "Caddy 安装完成: $(caddy version 2>/dev/null | head -1)"
}

# ═══════════════════════════════════════════════════════════════════
#  安装 Xray-core
#  官方仓库: github.com/XTLS/Xray-core/releases
#  包格式:   Xray-linux-{arch}.zip
# ═══════════════════════════════════════════════════════════════════

install_xray() {
    step "安装 Xray-core"
    local ARCH TMP VER URL
    ARCH=$(xray_arch); TMP=$(mktemp -d)
    info "查询最新版本..."
    VER=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
          | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    [[ -z "$VER" ]] && VER="v25.3.6"
    URL="https://github.com/XTLS/Xray-core/releases/download/${VER}/Xray-linux-${ARCH}.zip"
    info "版本: ${VER}  arch: ${ARCH}"
    info "下载: ${URL}"
    wget -qO "${TMP}/xray.zip" "$URL" || error "Xray 下载失败，请检查网络"
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
#  安装 sing-box
#  官方仓库: github.com/SagerNet/sing-box/releases
#  包格式:   sing-box-{ver}-linux-{arch}.tar.gz
# ═══════════════════════════════════════════════════════════════════

install_singbox() {
    step "安装 sing-box"
    local ARCH TMP VER VER_NUM PKG URL
    ARCH=$(sbox_arch); TMP=$(mktemp -d)
    info "查询最新稳定版本（过滤 alpha/beta/rc）..."
    VER=$(curl -s --max-time 10 "https://api.github.com/repos/SagerNet/sing-box/releases" \
          | grep '"tag_name"' | grep -v 'alpha\|beta\|rc' | head -1 | cut -d'"' -f4)
    [[ -z "$VER" ]] && VER="v1.11.4"
    VER_NUM="${VER#v}"
    PKG="sing-box-${VER_NUM}-linux-${ARCH}"
    URL="https://github.com/SagerNet/sing-box/releases/download/${VER}/${PKG}.tar.gz"
    info "版本: ${VER}  arch: ${ARCH}"
    info "下载: ${URL}"
    wget -qO "${TMP}/sing-box.tar.gz" "$URL" || error "sing-box 下载失败，请检查网络"
    tar -xzf "${TMP}/sing-box.tar.gz" -C "${TMP}/"
    install -m 755 "${TMP}/${PKG}/sing-box" "$SBOX_BIN"
    rm -rf "$TMP"
    info "sing-box 安装完成: $("$SBOX_BIN" version 2>&1 | head -1)"
}

# ═══════════════════════════════════════════════════════════════════
#  Reality 密钥生成（需要核心二进制已安装）
# ═══════════════════════════════════════════════════════════════════

gen_reality_keys() {
    # 返回到全局变量: REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
    local output private_key public_key
    REALITY_SHORT_ID=$(openssl rand -hex 8 2>/dev/null \
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
h1{color:#1a1a2e;font-size:2rem;margin-bottom:12px}p{color:#666;line-height:1.7;font-size:.95rem}
.s{margin-top:24px;font-size:.8rem;color:#aaa}hr{border:none;border-top:1px solid #eee;margin:24px 0}
</style></head><body><div class="c">
<h1>Welcome to nginx!</h1><hr>
<p>If you see this page, the nginx web server is successfully installed and working.
Further configuration is required.</p>
<p class="s">nginx/1.24.0 — Thank you for using nginx.</p>
</div></body></html>
HTMLEOF
    info "伪装网站: ${FAKE_WEBROOT}"
}

# ═══════════════════════════════════════════════════════════════════
#  生成代理核心配置
#  规则：从 CONF_FILE 读取所有参数，根据 core_type + mode 生成对应 JSON
# ═══════════════════════════════════════════════════════════════════

configure_core() {
    load_conf || error "配置文件不存在，请先安装"
    step "生成 ${core_type} 配置 (${mode})"

    # ── 出站：直连 or 中转 ──────────────────────────────────────
    local OUT_TAG="direct"
    if [[ "${relay_enabled:-false}" == "true" ]]; then
        OUT_TAG="relay"
    fi

    if [[ "${core_type}" == "singbox" ]]; then
        _configure_singbox "$OUT_TAG"
    else
        _configure_xray "$OUT_TAG"
    fi
}

# ── Xray 配置生成 ───────────────────────────────────────────────

_configure_xray() {
    local OUT_TAG="$1"
    mkdir -p "$XRAY_CONF_DIR"

    # 出站 JSON 片段
    local outbound_direct='{
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "UseIPv4" }
    }'
    local outbound_relay=''
    if [[ "${relay_enabled:-false}" == "true" ]]; then
        outbound_relay=",
    {
      \"protocol\": \"vless\",
      \"tag\": \"relay\",
      \"settings\": {
        \"vnext\": [{
          \"address\": \"${relay_host}\",
          \"port\": ${relay_port},
          \"users\": [{\"id\": \"${relay_uuid}\", \"encryption\": \"none\"}]
        }]
      },
      \"streamSettings\": {
        \"network\": \"ws\",
        \"security\": \"tls\",
        \"tlsSettings\": {\"serverName\": \"${relay_sni}\", \"allowInsecure\": false},
        \"wsSettings\": {\"path\": \"${relay_ws_path}\", \"headers\": {\"Host\": \"${relay_sni}\"}}
      }
    }"
    fi

    if [[ "${mode}" == "ws_tls" ]]; then
        cat > "$XRAY_CONF" << EOF
{
  "log": { "loglevel": "warning", "access": "none" },
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": ${local_port},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${uuid}", "level": 0 }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "none",
      "wsSettings": { "path": "${ws_path}" }
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
  }],
  "outbounds": [
    ${outbound_direct}${outbound_relay},
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "${OUT_TAG}" }
    ]
  }
}
EOF
    else
        # Reality 模式
        cat > "$XRAY_CONF" << EOF
{
  "log": { "loglevel": "warning", "access": "none" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${ext_port},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision", "level": 0 }],
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
    "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
  }],
  "outbounds": [
    ${outbound_direct}${outbound_relay},
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "${OUT_TAG}" }
    ]
  }
}
EOF
    fi
    info "Xray 配置已写入: ${XRAY_CONF}"
}

# ── sing-box 配置生成 ────────────────────────────────────────────

_configure_singbox() {
    local OUT_TAG="$1"
    mkdir -p "$SBOX_CONF_DIR"

    local outbound_direct='{
      "type": "direct",
      "tag": "direct"
    }'
    local outbound_relay=''
    if [[ "${relay_enabled:-false}" == "true" ]]; then
        outbound_relay=",
    {
      \"type\": \"vless\",
      \"tag\": \"relay\",
      \"server\": \"${relay_host}\",
      \"server_port\": ${relay_port},
      \"uuid\": \"${relay_uuid}\",
      \"tls\": { \"enabled\": true, \"server_name\": \"${relay_sni}\" },
      \"transport\": {
        \"type\": \"ws\",
        \"path\": \"${relay_ws_path}\",
        \"headers\": { \"Host\": \"${relay_sni}\" }
      }
    }"
    fi

    if [[ "${mode}" == "ws_tls" ]]; then
        cat > "$SBOX_CONF" << EOF
{
  "log": { "level": "warn", "output": "stderr", "timestamp": true },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "127.0.0.1",
    "listen_port": ${local_port},
    "users": [{ "uuid": "${uuid}" }],
    "transport": {
      "type": "ws",
      "path": "${ws_path}"
    }
  }],
  "outbounds": [
    ${outbound_direct}${outbound_relay},
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "block" },
      { "network": ["tcp","udp"], "outbound": "${OUT_TAG}" }
    ],
    "final": "${OUT_TAG}"
  }
}
EOF
    else
        # Reality 模式
        cat > "$SBOX_CONF" << EOF
{
  "log": { "level": "warn", "output": "stderr", "timestamp": true },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "0.0.0.0",
    "listen_port": ${ext_port},
    "users": [{ "uuid": "${uuid}", "flow": "xtls-rprx-vision" }],
    "tls": {
      "enabled": true,
      "server_name": "${reality_dest}",
      "reality": {
        "enabled": true,
        "handshake": { "server": "${reality_dest}", "server_port": 443 },
        "private_key": "${reality_private_key}",
        "short_id": ["${reality_short_id}"]
      }
    }
  }],
  "outbounds": [
    ${outbound_direct}${outbound_relay},
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "block" },
      { "network": ["tcp","udp"], "outbound": "${OUT_TAG}" }
    ],
    "final": "${OUT_TAG}"
  }
}
EOF
    fi
    info "sing-box 配置已写入: ${SBOX_CONF}"
}

# ═══════════════════════════════════════════════════════════════════
#  配置 Caddy（WS+TLS 模式专用）
#
#  WS 路径双层匹配策略：
#  ① WebSocket 升级请求（含 Upgrade: websocket）→ 透传给代理核心
#  ② 同路径的普通 HTTP 请求                     → 返回 404（伪装探测无效）
#  ③ 其余所有路径                               → 返回 nginx 伪装页面
# ═══════════════════════════════════════════════════════════════════

configure_caddy() {
    load_conf || error "配置文件不存在"
    step "生成 Caddy 配置"
    mkdir -p "$CADDY_CONF_DIR"

    # 备份已有主配置（仅首次）
    if [[ -f "$CADDY_MAIN_CONF" ]] && ! grep -q "vless-personal" "$CADDY_MAIN_CONF" 2>/dev/null; then
        cp "$CADDY_MAIN_CONF" "${CADDY_MAIN_CONF}.bak.$(date +%s)"
        info "原 Caddyfile 已备份"
    fi

    cat > "$CADDY_MAIN_CONF" << EOF
# ── VLESS Personal Edition ─────────────────────────────────────────
# 修改站点配置: ${CADDY_VLESS_CONF}
# 重载生效:     caddy reload --config ${CADDY_MAIN_CONF}
# ──────────────────────────────────────────────────────────────────
{
    email ${email}
    admin off
    servers { protocols h1 h2 }
}
import ${CADDY_VLESS_CONF}
EOF

    cat > "$CADDY_VLESS_CONF" << EOF
# ── VLESS+WS+TLS 站点 ─────────────────────────────────────────────
# 域名: ${domain}  外部端口: ${ext_port}  内部端口: ${local_port}
# 生成: $(date '+%Y-%m-%d_%H:%M:%S')
# ─────────────────────────────────────────────────────────────────

${domain}:${ext_port} {

    # Caddy 自动向 Let's Encrypt 申请证书并续签
    # HTTP-01 验证需要 80 端口可访问
    tls {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    }

    # ① WS 升级请求（含 Upgrade: websocket header）→ 转发给代理核心
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
            # 强制 HTTP/1.1，WebSocket 不支持 HTTP/2
            transport http { versions 1.1 }
        }
    }

    # ② 普通 HTTP 访问 WS 路径 → 404（让扫描探测得到 404，不暴露路径存在）
    handle ${ws_path} {
        respond 404
    }

    # ③ 其余路径 → 伪装 nginx 静态页面
    handle {
        root * ${FAKE_WEBROOT}
        file_server
        header Server "nginx/1.24.0"
        header -X-Powered-By
    }

    # 关闭访问日志（减少磁盘 IO，避免泄露访问记录）
    log { output discard }
}
EOF
    info "Caddy 主配置: ${CADDY_MAIN_CONF}"
    info "站点配置:     ${CADDY_VLESS_CONF}"
}

# ═══════════════════════════════════════════════════════════════════
#  systemd 服务单元
# ═══════════════════════════════════════════════════════════════════

_write_systemd_unit() {
    load_conf
    local CORE_SVC BIN CONF EXEC_ARGS AFTER_SVC
    CORE_SVC=$(proxy_svc_name); BIN=$(core_bin); CONF=$(core_conf_file)
    [[ "${core_type:-xray}" == "singbox" ]] && EXEC_ARGS="run -c ${CONF}" || EXEC_ARGS="run -config ${CONF}"
    [[ "${mode:-ws_tls}" == "ws_tls" ]] && AFTER_SVC="caddy.service" || AFTER_SVC="network-online.target"

    cat > "/etc/systemd/system/${CORE_SVC}.service" << EOF
[Unit]
Description=VLESS Personal - ${CORE_SVC}
After=network-online.target ${AFTER_SVC}
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStartPre=${CONF_DIR}/restore-iptables.sh
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
#  OpenRC 服务脚本（Alpine）
# ═══════════════════════════════════════════════════════════════════

_write_openrc_unit() {
    load_conf
    local CORE_SVC BIN CONF EXEC_ARGS AFTER_DEPS
    CORE_SVC=$(proxy_svc_name); BIN=$(core_bin); CONF=$(core_conf_file)
    [[ "${core_type:-xray}" == "singbox" ]] && EXEC_ARGS="run -c ${CONF}" || EXEC_ARGS="run -config ${CONF}"
    [[ "${mode:-ws_tls}" == "ws_tls" ]] && AFTER_DEPS="after caddy" || AFTER_DEPS=""

    cat > "/etc/init.d/${CORE_SVC}" << RCEOF
#!/sbin/openrc-run
description="VLESS Personal - ${CORE_SVC}"
command="${BIN}"
command_args="${EXEC_ARGS}"
command_background=true
pidfile="/run/${CORE_SVC}.pid"
output_log="/var/log/${CORE_SVC}.log"
error_log="/var/log/${CORE_SVC}.log"
start_pre() { ${CONF_DIR}/restore-iptables.sh; }
depend() { need net; ${AFTER_DEPS}; }
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
    step "配置系统服务 (${CORE_SVC})"

    if [[ "$INIT_SYS" == "systemd" ]]; then
        _write_systemd_unit
        systemctl daemon-reload
        if [[ "${mode:-ws_tls}" == "ws_tls" ]]; then
            service_enable caddy
            info "启动 Caddy（首次申请 Let's Encrypt 证书，约 30~60 秒）..."
            systemctl restart caddy
            sleep 6
        fi
        service_enable "$CORE_SVC"
        systemctl restart "$CORE_SVC"
    else
        _write_openrc_unit
        if [[ "${mode:-ws_tls}" == "ws_tls" ]]; then
            service_enable caddy
            rc-service caddy restart
            sleep 6
        fi
        service_enable "$CORE_SVC"
        rc-service "$CORE_SVC" start
    fi
    info "服务配置完成"
}

# ═══════════════════════════════════════════════════════════════════
#  流量监控（iptables 计数链 + cron）
# ═══════════════════════════════════════════════════════════════════

_setup_iptables_chain() {
    local port="$1"
    iptables -N VLESS_IN  2>/dev/null || true
    iptables -N VLESS_OUT 2>/dev/null || true
    while iptables -D INPUT  -p tcp --dport "$port" -j VLESS_IN  2>/dev/null; do true; done
    while iptables -D OUTPUT -p tcp --sport "$port" -j VLESS_OUT 2>/dev/null; do true; done
    iptables -I INPUT  -p tcp --dport "$port" -j VLESS_IN
    iptables -I OUTPUT -p tcp --sport "$port" -j VLESS_OUT
    iptables -F VLESS_IN;  iptables -A VLESS_IN  -j RETURN
    iptables -F VLESS_OUT; iptables -A VLESS_OUT -j RETURN
}

setup_traffic_monitoring() {
    load_conf
    step "配置流量监控"
    mkdir -p "$CONF_DIR"

    # 初始化流量记录
    if [[ ! -f "$TRAFFIC_FILE" ]]; then
        cat > "$TRAFFIC_FILE" << 'EOF'
traffic_month=""
traffic_bytes_saved=0
traffic_bytes_total=0
traffic_exceeded=false
EOF
    fi

    # 建立 iptables 计数链
    command -v iptables &>/dev/null && _setup_iptables_chain "${ext_port}" && info "iptables 计数链已建立（端口 ${ext_port}）" \
        || warn "iptables 不可用，流量统计将不工作"

    # ── restore-iptables.sh：服务启动时恢复计数链（重启后规则丢失）
    cat > "${CONF_DIR}/restore-iptables.sh" << 'EOFI'
#!/bin/bash
source /etc/vless-personal/config.env 2>/dev/null || exit 0
command -v iptables &>/dev/null || exit 0
# 链已存在说明规则还在，直接退出
iptables -L VLESS_IN -n &>/dev/null && exit 0
# 重建计数链
iptables -N VLESS_IN  2>/dev/null || true
iptables -N VLESS_OUT 2>/dev/null || true
while iptables -D INPUT  -p tcp --dport "${ext_port}" -j VLESS_IN  2>/dev/null; do true; done
while iptables -D OUTPUT -p tcp --sport "${ext_port}" -j VLESS_OUT 2>/dev/null; do true; done
iptables -I INPUT  -p tcp --dport "${ext_port}" -j VLESS_IN
iptables -I OUTPUT -p tcp --sport "${ext_port}" -j VLESS_OUT
iptables -F VLESS_IN;  iptables -A VLESS_IN  -j RETURN
iptables -F VLESS_OUT; iptables -A VLESS_OUT -j RETURN
EOFI
    chmod +x "${CONF_DIR}/restore-iptables.sh"

    # ── traffic-check.sh：每小时检查流量，超限则停止服务
    cat > "${CONF_DIR}/traffic-check.sh" << 'EOFC'
#!/bin/bash
CONF_FILE="/etc/vless-personal/config.env"
TRAFFIC_FILE="/etc/vless-personal/traffic.env"
LOG_FILE="/var/log/vless-personal.log"
[[ -f "$CONF_FILE" ]] || exit 0
source "$CONF_FILE"
source "$TRAFFIC_FILE" 2>/dev/null || true

# 确保计数链存在
iptables -L VLESS_IN -n &>/dev/null || /etc/vless-personal/restore-iptables.sh

# 本次会话 iptables 累计字节
IN_B=$(iptables  -L VLESS_IN  -n -v -x 2>/dev/null | awk 'NR==3{print $2+0}')
OUT_B=$(iptables -L VLESS_OUT -n -v -x 2>/dev/null | awk 'NR==3{print $2+0}')
CURRENT=$(( IN_B + OUT_B ))

# 总流量 = 历史保存值 + 本次会话计数
TOTAL=$(( ${traffic_bytes_saved:-0} + CURRENT ))

# 更新 traffic.env
sed -i "s/^traffic_bytes_total=.*/traffic_bytes_total=${TOTAL}/" "$TRAFFIC_FILE" \
    2>/dev/null || echo "traffic_bytes_total=${TOTAL}" >> "$TRAFFIC_FILE"

# 检查月份是否已切换（用于保护性检查，正式重置由 traffic-reset.sh 负责）
CUR_MONTH=$(date +%Y-%m)
[[ "${traffic_month}" != "$CUR_MONTH" ]] && /etc/vless-personal/traffic-reset.sh && exit 0

# 限额检查（0 = 不限制）
LIMIT_GB="${traffic_limit_gb:-0}"
[[ "$LIMIT_GB" -le 0 ]] && exit 0
LIMIT=$(( LIMIT_GB * 1024 * 1024 * 1024 ))
if [[ "$TOTAL" -ge "$LIMIT" ]] && [[ "${traffic_exceeded:-false}" != "true" ]]; then
    CORE_SVC="xray"
    [[ "${core_type}" == "singbox" ]] && CORE_SVC="sing-box"
    systemctl stop  "$CORE_SVC" 2>/dev/null || rc-service "$CORE_SVC" stop 2>/dev/null || true
    sed -i 's/^traffic_exceeded=.*/traffic_exceeded=true/' "$TRAFFIC_FILE" \
        || echo "traffic_exceeded=true" >> "$TRAFFIC_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 流量超限（${LIMIT_GB}GB），服务已停止。" >> "$LOG_FILE"
fi
EOFC
    chmod +x "${CONF_DIR}/traffic-check.sh"

    # ── traffic-reset.sh：月初重置（cron 每月 1 日 00:05 执行）
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

# 重置流量文件
cat > "$TRAFFIC_FILE" << ENVEOF
traffic_month=$(date +%Y-%m)
traffic_bytes_saved=0
traffic_bytes_total=0
traffic_exceeded=false
ENVEOF

# 若因超限停止则重启
CORE_SVC="xray"
[[ "${core_type}" == "singbox" ]] && CORE_SVC="sing-box"
systemctl start "$CORE_SVC" 2>/dev/null || rc-service "$CORE_SVC" start 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 月度流量已重置。" >> "$LOG_FILE"
EOFR
    chmod +x "${CONF_DIR}/traffic-reset.sh"

    _setup_cron
    info "流量监控部署完成"
}

_setup_cron() {
    if [[ "$OS_ID" == "alpine" ]]; then
        sed -i '/vless-personal/d' /etc/crontabs/root 2>/dev/null || true
        cat >> /etc/crontabs/root << 'EOF'
# vless-personal
0 * * * * /etc/vless-personal/traffic-check.sh >/dev/null 2>&1
5 0 1 * * /etc/vless-personal/traffic-reset.sh >/dev/null 2>&1
EOF
        rc-service crond restart 2>/dev/null || rc-service dcron restart 2>/dev/null || true
    else
        cat > /etc/cron.d/vless-personal << 'EOF'
# vless-personal traffic monitoring
0 * * * * root /etc/vless-personal/traffic-check.sh >/dev/null 2>&1
5 0 1 * * root /etc/vless-personal/traffic-reset.sh >/dev/null 2>&1
EOF
        systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || true
    fi
    info "Cron 任务已注册（每小时检查，每月 1 日 00:05 重置）"
}

# ═══════════════════════════════════════════════════════════════════
#  防火墙
# ═══════════════════════════════════════════════════════════════════

setup_firewall() {
    load_conf
    step "配置防火墙"
    local PORTS=("${ext_port}")
    [[ "${mode:-ws_tls}" == "ws_tls" ]] && PORTS+=(80)

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
        [[ "$OS_ID" == "alpine" ]] \
            && iptables-save > /etc/iptables/rules-save 2>/dev/null || true
        info "iptables: 已放行端口 ${PORTS[*]}"
    else
        warn "请手动放行端口: ${PORTS[*]}"
    fi
}

# ═══════════════════════════════════════════════════════════════════
#  BBR（Debian/Ubuntu；Alpine 通常无此内核模块，跳过）
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
#  快捷命令 vless-p
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
        printf "  %-16s %s\n"             "公钥 pbk:" "${reality_public_key}"
        printf "  %-16s %s\n"             "Short ID:" "${reality_short_id}"
        printf "  %-16s %s\n"             "流量控制:" "xtls-rprx-vision"
    fi

    printf "  %-16s ${CYAN}%s${NC}\n" "UUID:"      "${uuid}"

    if [[ "${relay_enabled:-false}" == "true" ]]; then
        printf "  %-16s ${YELLOW}%s${NC}\n" "中转模式:" "已启用 → ${relay_host}:${relay_port}"
    fi

    printf "  %-16s %s\n" "月度流量限制:" "$([[ "${traffic_limit_gb:-0}" -gt 0 ]] && echo "${traffic_limit_gb} GB" || echo '不限制')"
    printf "  %-16s %s\n" "安装时间:"    "${install_date}"

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
        printf "  %-12s %s\n" "地址:"      "${server_ip}"
        printf "  %-12s %s\n" "端口:"      "${ext_port}"
        printf "  %-12s %s\n" "UUID:"      "${uuid}"
        printf "  %-12s %s\n" "传输:"      "TCP | 流控: xtls-rprx-vision"
        printf "  %-12s %s\n" "TLS:"       "Reality | SNI: ${reality_dest}"
        printf "  %-12s %s\n" "公钥:"      "${reality_public_key}"
        printf "  %-12s %s\n" "Short ID:"  "${reality_short_id}"
        printf "  %-12s %s\n" "指纹:"      "chrome"
    fi
    echo ""
    command -v qrencode &>/dev/null && { echo -e "${BOLD}  ✦ 二维码:${NC}"; qrencode -t ansiutf8 "$LINK" 2>/dev/null; echo ""; }
    hr
}

# ═══════════════════════════════════════════════════════════════════
#  流量统计与管理
# ═══════════════════════════════════════════════════════════════════

show_traffic() {
    is_installed || { warn "尚未安装"; return; }
    load_conf
    # 先更新一次流量数据
    [[ -x "${CONF_DIR}/traffic-check.sh" ]] && "${CONF_DIR}/traffic-check.sh" 2>/dev/null
    load_traffic 2>/dev/null || true

    local used="${traffic_bytes_total:-0}"
    local limit_gb="${traffic_limit_gb:-0}"
    local month="${traffic_month:-$(date +%Y-%m)}"

    echo ""; hr
    echo -e "${BOLD}  流量统计 — ${month}${NC}"; hr
    printf "  %-16s %s\n" "本月已用:" "$(human_bytes "$used")"

    if [[ "$limit_gb" -gt 0 ]]; then
        local limit_bytes=$(( limit_gb * 1024 * 1024 * 1024 ))
        local remain=$(( limit_bytes - used ))
        [[ $remain -lt 0 ]] && remain=0
        printf "  %-16s %s\n" "月度上限:" "${limit_gb} GB"
        printf "  %-16s %s\n" "剩余流量:" "$(human_bytes "$remain")"

        local pct=$(( used * 100 / limit_bytes )); [[ $pct -gt 100 ]] && pct=100
        local filled=$(( pct * 28 / 100 ))
        local bar=""; for (( i=0; i<filled; i++ )); do bar+="█"; done; for (( i=filled; i<28; i++ )); do bar+="░"; done
        local color=$GREEN; [[ $pct -ge 80 ]] && color=$YELLOW; [[ $pct -ge 95 ]] && color=$RED
        printf "  %-16s ${color}[%s]${NC} %d%%\n" "使用进度:" "$bar" "$pct"

        if [[ "${traffic_exceeded:-false}" == "true" ]]; then
            echo -e "\n  ${RED}${BOLD}⚠  已达上限，代理服务已停止${NC}"
            echo -e "  ${YELLOW}月初（每月1日 00:05）将自动重置并重启${NC}"
        fi
    else
        printf "  %-16s %s\n" "月度上限:" "不限制"
    fi
    printf "  %-16s %s\n" "自动重置:" "每月 1 日 00:05"
    hr
}

reset_traffic_manual() {
    is_installed || { warn "尚未安装"; return; }
    read -rp "  确认手动重置本月流量统计? [y/N]: " c
    [[ "${c,,}" == "y" ]] || { info "取消"; return; }
    "${CONF_DIR}/traffic-reset.sh" && info "流量已重置，服务已重启" || warn "重置失败"
}

# ═══════════════════════════════════════════════════════════════════
#  中转/转发管理（独立于主节点安装，不干扰正常使用）
# ═══════════════════════════════════════════════════════════════════

manage_relay() {
    is_installed || { warn "尚未安装主节点"; return; }
    load_conf

    echo ""
    hr
    echo -e "${BOLD}  中转/转发设置${NC}"
    hr
    if [[ "${relay_enabled:-false}" == "true" ]]; then
        echo -e "  状态: ${GREEN}已启用${NC}"
        printf "  %-12s %s\n" "远程地址:" "${relay_host}:${relay_port}"
        printf "  %-12s %s\n" "远程域名:" "${relay_sni}"
        printf "  %-12s %s\n" "WS 路径:"  "${relay_ws_path}"
    else
        echo -e "  状态: ${YELLOW}未启用（直连出站）${NC}"
    fi
    hr
    echo "  1) 启用/修改中转节点"
    echo "  2) 禁用中转（切回直连）"
    echo "  0) 返回"
    read -rp "  选择 [0-2]: " rc_; echo ""
    case "$rc_" in
        1) _enable_relay  ;;
        2) _disable_relay ;;
    esac
}

_enable_relay() {
    echo -e "${BOLD}  填写远程 VLESS+WS+TLS 中转节点信息:${NC}"
    local R_HOST R_PORT R_SNI R_UUID R_PATH

    while true; do read -rp "  远程地址（IP 或域名）: " R_HOST; [[ -n "$R_HOST" ]] && break; warn "不能为空"; done
    while true; do read -rp "  远程端口（例: 8443）: " R_PORT; [[ "$R_PORT" =~ ^[0-9]+$ ]] && break; warn "请输入数字"; done
    while true; do read -rp "  远程 SNI 域名: " R_SNI;  [[ -n "$R_SNI" ]]  && break; warn "不能为空"; done
    while true; do
        read -rp "  远程 UUID: " R_UUID
        [[ "$R_UUID" =~ ^[0-9a-f-]{36}$ ]] && break
        warn "格式: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    done
    while true; do read -rp "  远程 WS 路径（如 /proxy）: " R_PATH; [[ "$R_PATH" =~ ^/ ]] && break; warn "须以 / 开头"; done

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

# ═══════════════════════════════════════════════════════════════════
#  服务状态
# ═══════════════════════════════════════════════════════════════════

show_status() {
    load_conf 2>/dev/null
    local CORE_SVC
    CORE_SVC=$(proxy_svc_name)
    echo ""; hr; echo -e "${BOLD}  服务状态${NC}"; hr

    [[ "${mode:-ws_tls}" == "ws_tls" ]] && for svc in caddy "$CORE_SVC"; do
        service_is_active "$svc" \
            && printf "  %-14s ${GREEN}● 运行中${NC}\n" "${svc}:" \
            || printf "  %-14s ${RED}● 已停止${NC}\n" "${svc}:"
    done || {
        service_is_active "$CORE_SVC" \
            && printf "  %-14s ${GREEN}● 运行中${NC}\n" "${CORE_SVC}:" \
            || printf "  %-14s ${RED}● 已停止${NC}\n" "${CORE_SVC}:"
    }

    echo ""; echo -e "${BOLD}  端口监听${NC}"
    ss -tlnp 2>/dev/null | grep -q ":${ext_port}" \
        && echo -e "  :${ext_port}   ${GREEN}✓ 已监听${NC}" \
        || echo -e "  :${ext_port}   ${RED}✗ 未监听${NC}"
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
    [[ "${mode:-ws_tls}" == "ws_tls" ]] && { service_cmd restart caddy; sleep 2; }
    service_cmd restart "$CORE_SVC"
    info "服务已重启"; show_status
}

# ═══════════════════════════════════════════════════════════════════
#  查看日志
# ═══════════════════════════════════════════════════════════════════

show_logs() {
    load_conf 2>/dev/null
    local CORE_SVC; CORE_SVC=$(proxy_svc_name)
    echo ""
    echo "  1) ${CORE_SVC} 日志（最近 80 行）"
    echo "  2) ${CORE_SVC} 错误上下文（journalctl -xe）"
    echo "  3) Caddy 日志"
    echo "  4) 流量操作日志"
    echo "  0) 返回"
    read -rp "  选择 [0-4]: " lc; echo ""
    case "$lc" in
        1) [[ "$INIT_SYS" == "systemd" ]] \
               && journalctl -u "${CORE_SVC}" -n 80 --no-pager 2>/dev/null \
               || tail -80 "/var/log/${CORE_SVC}.log" 2>/dev/null \
               || warn "暂无日志，请确认服务已启动" ;;
        2) [[ "$INIT_SYS" == "systemd" ]] \
               && journalctl -xe -u "${CORE_SVC}" --no-pager 2>/dev/null \
               || warn "journalctl -xe 仅 systemd 可用" ;;
        3) [[ "$INIT_SYS" == "systemd" ]] \
               && journalctl -u caddy -n 80 --no-pager 2>/dev/null \
               || warn "Caddy 访问日志已设为 discard（节省磁盘）" ;;
        4) tail -50 "$LOG_FILE" 2>/dev/null || echo "暂无流量操作日志" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════
#  更换 UUID
# ═══════════════════════════════════════════════════════════════════

rotate_uuid() {
    is_installed || { warn "尚未安装"; return; }
    load_conf
    local NEW_UUID; NEW_UUID=$(gen_uuid)
    read -rp "  新 UUID: ${NEW_UUID}，确认更换? [y/N]: " c
    [[ "${c,,}" == "y" ]] || { info "取消"; return; }
    _conf_set "uuid" "$NEW_UUID"
    configure_core
    service_cmd restart "$(proxy_svc_name)"
    info "UUID 已更换为: ${NEW_UUID}"
    show_config
}

# ═══════════════════════════════════════════════════════════════════
#  一键卸载（精准移除本脚本组件，不影响其他依赖）
# ═══════════════════════════════════════════════════════════════════

uninstall() {
    echo ""
    echo -e "${RED}${BOLD}  ⚠  即将卸载 VLESS Personal Edition${NC}"
    echo -e "  将移除: 代理核心 + 配置 + 流量监控 + Cron 任务"
    echo -e "  不影响: Caddy 本体（若非本脚本安装）+ 其他系统依赖"
    echo ""
    read -rp "  确认卸载? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { info "已取消"; return; }

    load_conf 2>/dev/null || true
    local CORE_SVC; CORE_SVC=$(proxy_svc_name)

    # 1. 停止并移除服务
    step "停止代理服务"
    service_cmd stop "$CORE_SVC" 2>/dev/null || true
    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl disable "$CORE_SVC" 2>/dev/null || true
        rm -f "/etc/systemd/system/${CORE_SVC}.service"
        systemctl daemon-reload 2>/dev/null || true
    else
        rc-update del "$CORE_SVC" default 2>/dev/null || true
        rm -f "/etc/init.d/${CORE_SVC}"
    fi

    # 2. 移除二进制和配置
    step "移除核心文件"
    if [[ "${core_type:-xray}" == "singbox" ]]; then
        rm -f "$SBOX_BIN" "$SBOX_CONF"; rmdir "$SBOX_CONF_DIR" 2>/dev/null || true
    else
        rm -f "$XRAY_BIN" "$XRAY_CONF"; rm -rf /usr/local/share/xray; rmdir "$XRAY_CONF_DIR" 2>/dev/null || true
    fi
    rm -f /etc/modules-load.d/vless-bbr.conf /etc/sysctl.d/99-vless-bbr.conf

    # 3. 清理 iptables 计数链
    step "清理 iptables"
    while iptables -D INPUT  -p tcp --dport "${ext_port}" -j VLESS_IN  2>/dev/null; do true; done
    while iptables -D OUTPUT -p tcp --sport "${ext_port}" -j VLESS_OUT 2>/dev/null; do true; done
    iptables -F VLESS_IN  2>/dev/null || true; iptables -X VLESS_IN  2>/dev/null || true
    iptables -F VLESS_OUT 2>/dev/null || true; iptables -X VLESS_OUT 2>/dev/null || true

    # 4. 清理 Cron 任务
    step "清理 Cron"
    [[ "$OS_ID" == "alpine" ]] && sed -i '/vless-personal/d' /etc/crontabs/root 2>/dev/null || rm -f /etc/cron.d/vless-personal

    # 5. 移除 Caddy 站点配置
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
                [[ "$INIT_SYS" == "systemd" ]] && systemctl disable caddy 2>/dev/null || rc-update del caddy default 2>/dev/null
                [[ "$PKG_MGR" == "apt" ]] \
                    && { apt-get remove -y caddy 2>/dev/null; rm -f /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg; } \
                    || apk del caddy 2>/dev/null || true
                info "Caddy 已卸载"
            fi
        fi
    fi

    # 6. 清理所有配置目录
    step "清理配置"
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
        echo -e "  模式: ${mode:-ws_tls}  核心: ${core_type:-xray}  端口: ${ext_port}"
        read -rp "  是否覆盖重新安装? [y/N]: " ri
        [[ "${ri,,}" == "y" ]] || return
        service_cmd stop "$(proxy_svc_name)" 2>/dev/null || true
        [[ "${mode:-ws_tls}" == "ws_tls" ]] && service_cmd stop caddy 2>/dev/null || true
    fi

    echo ""
    echo -e "${CYAN}${BOLD}══════════ VLESS Personal Edition — 安装向导 ══════════${NC}"
    echo ""

    # ── ① 代理核心 ──────────────────────────────────────────────
    echo -e "${BOLD}  ① 代理核心:${NC}"
    echo "     1) Xray-core   (github.com/XTLS/Xray-core)"
    echo "     2) sing-box    (github.com/SagerNet/sing-box)"
    local CORE_TYPE
    while true; do
        read -rp "  选择 [1/2]（默认 1）: " c_; c_="${c_:-1}"
        case "$c_" in 1) CORE_TYPE="xray"; break ;; 2) CORE_TYPE="singbox"; break ;; *) warn "请输入 1 或 2" ;; esac
    done

    # ── ② 协议模式 ──────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ② 协议模式:${NC}"
    echo "     1) VLESS + WS + TLS  ── 需要自己的域名，Caddy 自动申请证书"
    echo "     2) VLESS + Reality   ── 无需域名，借用公共网站 TLS 指纹"
    local MODE
    while true; do
        read -rp "  选择 [1/2]（默认 1）: " m_; m_="${m_:-1}"
        case "$m_" in 1) MODE="ws_tls"; break ;; 2) MODE="reality"; break ;; *) warn "请输入 1 或 2" ;; esac
    done

    # ── ③ 模式专属参数 ──────────────────────────────────────────
    echo ""
    local DOMAIN="" EMAIL="" LOCAL_PORT="" WS_PATH=""
    local REALITY_DEST="" R_PRIV_KEY="" R_PUB_KEY="" R_SHORT_ID=""

    if [[ "$MODE" == "ws_tls" ]]; then
        echo -e "${BOLD}  ③ WS+TLS 参数:${NC}"
        while true; do
            read -rp "  域名（例: proxy.example.com）: " DOMAIN
            DOMAIN="${DOMAIN// /}"
            [[ -n "$DOMAIN" && "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] && break; warn "域名格式不正确"
        done
        while true; do
            read -rp "  邮箱（TLS 证书通知）: " EMAIL
            [[ "$EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break; warn "邮箱格式不正确"
        done
        LOCAL_PORT=$(random_local_port)
        WS_PATH=$(ws_path_from_domain "$DOMAIN")
        read -rp "  自定义 WS 路径? 默认 ${WS_PATH} [y/N]: " _cp
        if [[ "${_cp,,}" == "y" ]]; then
            read -rp "  路径（以 / 开头）: " WS_PATH
            [[ "$WS_PATH" =~ ^/ ]] || WS_PATH="/${WS_PATH}"
        fi
    else
        echo -e "${BOLD}  ③ Reality 伪装域名（借用其 TLS 指纹）:${NC}"
        for i in "${!REALITY_DEST_LIST[@]}"; do printf "     %d) %s\n" "$(( i+1 ))" "${REALITY_DEST_LIST[$i]}"; done
        while true; do
            read -rp "  选择 [1-${#REALITY_DEST_LIST[@]}]（默认 1）: " _rd; _rd="${_rd:-1}"
            if [[ "$_rd" =~ ^[0-9]+$ ]] && (( _rd >= 1 && _rd <= ${#REALITY_DEST_LIST[@]} )); then
                REALITY_DEST="${REALITY_DEST_LIST[$(( _rd-1 ))]}"; break
            fi
            warn "请输入 1~${#REALITY_DEST_LIST[@]}"
        done
        info "伪装域名: ${REALITY_DEST}"
    fi

    # ── ④ TLS 端口选择 ──────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ④ 外部端口选择:${NC}"
    if [[ "$MODE" == "ws_tls" ]]; then
        echo -e "     ${YELLOW}WS+TLS 模式建议使用以下端口（Cloudflare CDN 兼容）:${NC}"
    else
        echo -e "     ${YELLOW}Reality 模式可使用任意端口，以下为推荐 TLS 端口:${NC}"
    fi
    for i in "${!TLS_PORTS[@]}"; do
        local mark=""
        [[ "${TLS_PORTS[$i]}" == "8443" ]] && mark=" ← 默认"
        printf "     %d) %s%s\n" "$(( i+1 ))" "${TLS_PORTS[$i]}" "$mark"
    done
    echo "     7) 自定义端口"
    local EXT_PORT_IN="8443"
    while true; do
        read -rp "  选择 [1-7]（默认 2，即 8443）: " _pc; _pc="${_pc:-2}"
        if [[ "$_pc" =~ ^[1-6]$ ]]; then
            EXT_PORT_IN="${TLS_PORTS[$(( _pc-1 ))]}"; break
        elif [[ "$_pc" == "7" ]]; then
            while true; do
                read -rp "  输入端口 [1024-65535]: " EXT_PORT_IN
                [[ "$EXT_PORT_IN" =~ ^[0-9]+$ ]] && (( EXT_PORT_IN >= 1024 && EXT_PORT_IN <= 65535 )) && break
                warn "端口范围: 1024~65535"
            done
            break
        else
            warn "请输入 1~7"
        fi
    done
    info "已选端口: ${EXT_PORT_IN}"

    # ── ⑤ UUID ──────────────────────────────────────────────────
    echo ""
    local AUTO_UUID; AUTO_UUID=$(gen_uuid)
    read -rp "  ⑤ 自定义 UUID? 默认随机生成 [y/N]: " _cu
    if [[ "${_cu,,}" == "y" ]]; then
        while true; do
            read -rp "  UUID（格式 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx）: " AUTO_UUID
            [[ "$AUTO_UUID" =~ ^[0-9a-f-]{36}$ ]] && break; warn "格式不正确"
        done
    fi

    # ── ⑥ 月度流量限制 ──────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ⑥ 月度流量限制（月初自动重置，0 = 不限制）:${NC}"
    local TRAFFIC_LIMIT_GB=0
    read -rp "  限制 GB 数（直接回车 = 不限制）: " _tg
    if [[ "$_tg" =~ ^[0-9]+$ ]] && [[ "$_tg" -gt 0 ]]; then
        TRAFFIC_LIMIT_GB="$_tg"; info "月度限额: ${TRAFFIC_LIMIT_GB} GB"
    else
        info "流量不限制"
    fi

    # ── ⑦ BBR ───────────────────────────────────────────────────
    echo ""
    local DO_BBR=true
    read -rp "  ⑦ 启用 BBR 加速? [Y/n]: " _bbr
    [[ "${_bbr,,}" == "n" ]] && DO_BBR=false

    # ── 确认 ─────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  ── 确认安装参数 ──${NC}"
    local CORE_LABEL="Xray-core"; [[ "$CORE_TYPE" == "singbox" ]] && CORE_LABEL="sing-box"
    printf "  %-16s ${CYAN}%s${NC}\n" "代理核心:" "${CORE_LABEL}"
    printf "  %-16s ${CYAN}%s${NC}\n" "协议模式:" "$([[ "$MODE" == "reality" ]] && echo 'VLESS+Reality' || echo 'VLESS+WS+TLS')"
    [[ "$MODE" == "ws_tls"  ]] && printf "  %-16s ${CYAN}%s${NC}\n" "域名:"     "${DOMAIN}"
    [[ "$MODE" == "reality" ]] && printf "  %-16s ${CYAN}%s${NC}\n" "伪装域名:" "${REALITY_DEST}"
    printf "  %-16s ${CYAN}%s${NC}\n" "外部端口:" "${EXT_PORT_IN}"
    printf "  %-16s %s\n"             "UUID:"     "${AUTO_UUID}"
    [[ "$MODE" == "ws_tls" ]] && printf "  %-16s %s\n" "WS 路径:" "${WS_PATH}"
    printf "  %-16s %s\n" "月度限制:" "$([[ "$TRAFFIC_LIMIT_GB" -gt 0 ]] && echo "${TRAFFIC_LIMIT_GB} GB" || echo '不限制')"
    printf "  %-16s %s\n" "BBR:"      "$($DO_BBR && echo '启用' || echo '不启用')"
    echo ""
    read -rp "  确认并开始安装? [Y/n]: " _fc
    [[ "${_fc,,}" == "n" ]] && { info "已取消"; return; }

    # ── 安装核心二进制 ────────────────────────────────────────────
    install_base_deps
    [[ "$CORE_TYPE" == "singbox" ]] && install_singbox || install_xray

    # ── Reality 需要核心已安装才能生成密钥 ────────────────────────
    if [[ "$MODE" == "reality" ]]; then
        info "生成 Reality 密钥对..."
        core_type="$CORE_TYPE"     # gen_reality_keys 内部使用
        gen_reality_keys
        R_PRIV_KEY="$REALITY_PRIVATE_KEY"
        R_PUB_KEY="$REALITY_PUBLIC_KEY"
        R_SHORT_ID="$REALITY_SHORT_ID"
        info "公钥:     ${R_PUB_KEY}"
        info "Short ID: ${R_SHORT_ID}"
    fi

    # ── 写入 config.env ──────────────────────────────────────────
    # ⚠ install_date 必须加双引号：否则 source 时时间中的空格导致
    #   bash 将 "HH:MM:SS" 当命令执行，报 command not found
    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" << EOF
# VLESS Personal Edition 配置文件（请勿手动修改）
core_type=${CORE_TYPE}
mode=${MODE}
uuid=${AUTO_UUID}
ext_port=${EXT_PORT_IN}
traffic_limit_gb=${TRAFFIC_LIMIT_GB}
relay_enabled=false
relay_host=
relay_port=
relay_sni=
relay_uuid=
relay_ws_path=
install_date="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    # 模式专属字段追加
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
reality_private_key=${R_PRIV_KEY}
reality_public_key=${R_PUB_KEY}
reality_short_id=${R_SHORT_ID}
EOF
    fi

    # ── 配置各组件 ─────────────────────────────────────────────
    # configure_core 从 CONF_FILE 读取参数，根据 core_type + mode 生成正确的 JSON
    configure_core

    if [[ "$MODE" == "ws_tls" ]]; then
        install_caddy
        setup_fake_web
        configure_caddy
    fi

    setup_services
    setup_firewall
    setup_traffic_monitoring
    $DO_BBR && enable_bbr || true
    setup_shortcut

    # ── 完成 ────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║                  ✓  安装完成！                        ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    if [[ "$MODE" == "ws_tls" ]]; then
        echo -e "  ${YELLOW}⚠ 重要：${NC}请确保 ${CYAN}${DOMAIN}${NC} 的 DNS A 记录已指向本机 IP"
        echo -e "  Caddy 通过 HTTP-01（端口 80）申请 Let's Encrypt 证书，约需 30~60 秒"
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
        echo -e "${CYAN}${BOLD}║      VLESS Personal Edition  v3.1  (vless-p)            ║${NC}"
        echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════╝${NC}"

        if is_installed; then
            load_conf 2>/dev/null
            load_traffic 2>/dev/null || true
            local CORE_SVC xs cs mode_str
            CORE_SVC=$(proxy_svc_name)
            service_is_active "$CORE_SVC" && xs="${GREEN}运行中${NC}" || xs="${RED}已停止${NC}"
            service_is_active caddy        && cs="${GREEN}运行中${NC}" || cs="${RED}已停止${NC}"
            [[ "${mode:-ws_tls}" == "reality" ]] && mode_str="Reality" || mode_str="WS+TLS"
            printf "  核心: ${CYAN}%s${NC}(%s) 状态: " "${core_type:-xray}" "$mode_str"
            echo -e "$(echo -e $xs)"
            printf "  端口: ${CYAN}%s${NC}" "${ext_port:-8443}"
            [[ "${mode:-ws_tls}" == "ws_tls" ]] \
                && printf "   域名: %s  WS: %s  Caddy: " "${domain}" "${ws_path}" \
                && echo -e "$(echo -e $cs)" \
                || { printf "   伪装: %s\n" "${reality_dest}"; }
            local tlimit="${traffic_limit_gb:-0}"
            [[ "$tlimit" -gt 0 ]] && {
                local used_str="流量: $(human_bytes "${traffic_bytes_total:-0}") / ${tlimit}GB"
                [[ "${traffic_exceeded:-false}" == "true" ]] && used_str+=" ${RED}[已超限]${NC}"
                echo -e "  ${used_str}"
            }
            [[ "${relay_enabled:-false}" == "true" ]] && echo -e "  中转: ${YELLOW}→ ${relay_host}:${relay_port}${NC}"
        else
            echo -e "  状态: ${YELLOW}未安装${NC}"
        fi
        hr
        echo "  1) 安装 / 重新安装"
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
            1) do_install       ;;
            2) show_config      ;;
            3) show_status      ;;
            4) restart_services ;;
            5) show_logs        ;;
            6) rotate_uuid      ;;
            7) show_traffic
               echo ""
               read -rp "  手动重置本月流量? [y/N]: " _rst
               [[ "${_rst,,}" == "y" ]] && reset_traffic_manual ;;
            8) manage_relay     ;;
            9) uninstall        ;;
            0) echo "  再见！"; exit 0 ;;
            *) warn "无效选项，请输入 0-9" ;;
        esac
    done
}

# ── 入口 ─────────────────────────────────────────────────────────
check_root
detect_os
main_menu
