#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║          SingBox Go  v4.0  —  SSH Only Edition                ║
# ╠═══════════════════════════════════════════════════════════════════════════╣
# ║  纯命令行多节点代理管理 —— 无 Web 面板、无监听端口、无浏览器依赖            ║
# ║                                                                           ║
# ║  支持系统 : Debian / Ubuntu / Alpine                                       ║
# ║  代理核心 : Xray-core 或 sing-box（安装时选择，可后续切换）                ║
# ║  TLS 前端 : Caddy（WS 系节点自动申请 Let's Encrypt 并续签）                ║
# ║                                                                           ║
# ║  节点协议（sing-box 核心，10 种）：                                        ║
# ║    VLESS   : Reality / WS+TLS                                             ║
# ║    VMess   : WS+TLS / 裸 TCP                                              ║
# ║    Trojan  : Reality / WS+TLS                                             ║
# ║    Shadowsocks 2022                                                       ║
# ║    SOCKS5 / HTTP（带认证）                                                 ║
# ║    Hysteria2 / TUIC v5 / AnyTLS（自签证书）                                ║
# ║    WireGuard（sing-box endpoints 段）                                      ║
# ║                                                                           ║
# ║  Xray 核心仅支持 VLESS / VMess / Trojan / SS / SOCKS / HTTP                ║
# ║                                                                           ║
# ║  管理方式 : SSH 菜单 `singbox-go`，或子命令 `singbox-go --help`                  ║
# ║                                                                           ║
# ║  安装: wget -O singbox-go.sh https://raw.githubusercontent.com/SuzukiRenz/ScriptHub/refs/heads/main/SH/singbox-go.sh && chmod +x singbox-go.sh && ./singbox-go.sh
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# 设计要点（与 Web 面板版的关键差异）
#   1. 没有面板进程、没有监听端口、没有登录口令 —— 攻击面为零
#   2. 节点以 /etc/singbox-go/nodes/<id>.env 存储，纯文本可直接备份
#   3. 全部配置由 jq 结构化生成，改完先 `sing-box check` 校验，失败自动回滚
#   4. 流量统计走 iptables 每端口计数链，不依赖内核模块或第三方探针
#   5. WS 系节点统一由 Caddy 终止 TLS，核心只监听 127.0.0.1
#
set -o pipefail

# ═══════════════════════════════════════════════════════════════════════════
#  0. 常量
# ═══════════════════════════════════════════════════════════════════════════

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'

CONF_DIR="/etc/singbox-go"
CONF_FILE="${CONF_DIR}/config.env"
NODE_DIR="${CONF_DIR}/nodes"
TRAFFIC_FILE="${CONF_DIR}/traffic.env"
CERT_DIR="${CONF_DIR}/certs"
LOG_FILE="/var/log/singbox-go.log"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/etc/xray"
XRAY_CONF="${XRAY_CONF_DIR}/config.json"

SBOX_BIN="/usr/local/bin/sing-box"
SBOX_CONF_DIR="/etc/sing-box"
SBOX_CONF="${SBOX_CONF_DIR}/config.json"

CADDY_CONF="/etc/caddy/Caddyfile"
FAKE_WEBROOT="/var/www/vless-fake"
SHORTCUT="/usr/local/bin/singbox-go"

TLS_PORTS=(443 8443 2053 2083 2087 2096)

REALITY_DESTS=(
    "www.apple.com" "www.microsoft.com" "yahoo.com" "www.cloudflare.com"
    "addons.mozilla.org" "store.steampowered.com" "www.swift.org" "www.samsung.com"
)

# ═══════════════════════════════════════════════════════════════════════════
#  1. 输出辅助
# ═══════════════════════════════════════════════════════════════════════════

# 提示类输出一律走 stderr：配置生成函数用 stdout 输出 JSON，
# 若 info/warn 混进 stdout，会把 JSON 污染成非法文本。
info()  { printf '%s[✓]%s %s\n' "$GREEN" "$NC" "$*" >&2; }
warn()  { printf '%s[!]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
errln() { printf '%s[✗]%s %s\n' "$RED" "$NC" "$*" >&2; }
die()   { errln "$*"; exit 1; }
step()  { printf '\n%s%s▶ %s%s\n' "$CYAN" "$BOLD" "$*" "$NC" >&2; }
hr()    { printf '%s──────────────────────────────────────────────────────────────%s\n' "$DIM" "$NC"; }
# 按显示宽度补齐（CJK 占 2 列），避免中文备注把表格撑歪
pad() {
    local s="$1" want="$2" w=0 i c
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        if [[ "$c" =~ [\x{4e00}-\x{9fff}\x{3000}-\x{303f}\x{ff00}-\x{ffef}] ]]; then w=$((w+2)); else w=$((w+1)); fi
    done
    printf '%s' "$s"
    for (( i=w; i<want; i++ )); do printf ' '; done
}

kv()    { printf '  %s %s\n' "$(pad "$1" 14)" "$2"; }

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

# ask <提示> [默认值] -> 通过 stdout 返回输入值。
# read -p 的提示符走 stderr，所以 $(ask ...) 只捕获到值，提示照常显示在屏幕上。
ask() {
    local prompt="$1" def="${2:-}" v
    if [[ -n "$def" ]]; then
        read -rp "  ${prompt} [${def}]: " v || v=""
        printf '%s' "${v:-$def}"
    else
        read -rp "  ${prompt}: " v || v=""
        printf '%s' "$v"
    fi
}

confirm() {
    # confirm <提示> [y|n 默认]
    local prompt="$1" def="${2:-n}" v
    read -rp "  ${prompt} [$([[ $def == y ]] && echo 'Y/n' || echo 'y/N')]: " v || v=""
    v="${v:-$def}"; [[ "${v,,}" == y* ]]
}

pause_() { read -rp "  按回车返回..." _; }

# ═══════════════════════════════════════════════════════════════════════════
#  2. 系统检测与依赖
# ═══════════════════════════════════════════════════════════════════════════

check_root() { [[ ${EUID} -eq 0 ]] || die "请以 root 运行: sudo bash $0"; }

detect_os() {
    [[ -f /etc/os-release ]] || die "无法识别操作系统"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    case "$OS_ID" in
        debian|ubuntu) PKG_MGR="apt";   INIT_SYS="systemd" ;;
        alpine)        PKG_MGR="apk";   INIT_SYS="openrc"  ;;
        *)             die "不支持的系统: ${OS_ID}（仅支持 Debian / Ubuntu / Alpine）" ;;
    esac
}

pkg_install() {
    if [[ "$PKG_MGR" == "apt" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
    else
        apk add --quiet --no-progress "$@" >/dev/null 2>&1
    fi
}

install_deps() {
    step "安装基础依赖"
    local pkgs=(curl wget tar unzip openssl ca-certificates jq iptables iproute2)
    [[ "$PKG_MGR" == "apk" ]] && pkgs+=(gcompat dcron) || pkgs+=(cron gnupg lsb-release)
    pkg_install "${pkgs[@]}" || warn "部分依赖安装失败，可手动补装"
    for b in curl jq openssl iptables; do
        command -v "$b" >/dev/null || die "缺少关键依赖: $b"
    done
    info "依赖就绪"
}

xray_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "64" ;;
        aarch64|arm64)  echo "arm64-v8a" ;;
        armv7*)         echo "arm32-v7a" ;;
        *) die "Xray 不支持该架构: $(uname -m)" ;;
    esac
}

sbox_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*)        echo "armv7" ;;
        *) die "sing-box 不支持该架构: $(uname -m)" ;;
    esac
}

# ── 服务控制统一封装 ────────────────────────────────────────────────────────
svc()        { [[ "$INIT_SYS" == systemd ]] && systemctl "$1" "$2" 2>/dev/null || rc-service "$2" "$1" 2>/dev/null; }
svc_enable() { [[ "$INIT_SYS" == systemd ]] && systemctl enable "$1" >/dev/null 2>&1 || rc-update add "$1" default >/dev/null 2>&1; }
svc_active() {
    if [[ "$INIT_SYS" == systemd ]]; then systemctl is-active --quiet "$1" 2>/dev/null
    else rc-service "$1" status 2>/dev/null | grep -q started; fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  3. 全局配置读写
# ═══════════════════════════════════════════════════════════════════════════

cfg_init() {
    mkdir -p "$CONF_DIR" "$NODE_DIR" "$CERT_DIR"
    [[ -f "$CONF_FILE" ]] && return 0
    cat >"$CONF_FILE" <<EOF
core_type=singbox
server_ip=$(detect_public_ip)
email=
caddy_port=443
traffic_limit_gb=0
relay_enabled=false
relay_host=
relay_port=
relay_sni=
relay_uuid=
relay_path=
relay_mode=none
install_date="$(date '+%F %T')"
EOF
}

cfg_load() { [[ -f "$CONF_FILE" ]] && . "$CONF_FILE"; return 0; }

cfg_set() {
    local k="$1" v="$2"
    [[ -f "$CONF_FILE" ]] || : >"$CONF_FILE"
    if grep -q "^${k}=" "$CONF_FILE" 2>/dev/null; then
        local tmp; tmp=$(mktemp)
        sed "s|^${k}=.*|${k}=${v}|" "$CONF_FILE" >"$tmp" && mv "$tmp" "$CONF_FILE"
    else
        printf '%s=%s\n' "$k" "$v" >>"$CONF_FILE"
    fi
}

cfg_get() { grep "^$1=" "$CONF_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }

detect_public_ip() {
    local ip
    ip=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -6 -fsS --max-time 6 https://api6.ipify.org 2>/dev/null) \
        || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
    printf '%s' "$ip"
}

node_count() { find "$NODE_DIR" -maxdepth 1 -name '*.env' 2>/dev/null | wc -l | tr -d ' '; }

# ═══════════════════════════════════════════════════════════════════════════
#  4. 节点存储
# ═══════════════════════════════════════════════════════════════════════════

node_file() { printf '%s/%s.env' "$NODE_DIR" "$1"; }

node_load() {
    local f; f=$(node_file "$1")
    [[ -f "$f" ]] || return 1
    unset N_ID N_REMARK N_PROTO N_MODE N_PORT N_ENABLED N_UUID N_PASS N_FLOW \
          N_PATH N_DOMAIN N_SNI N_DEST N_PRIV N_PUB N_SID N_METHOD N_USER \
          N_LOCAL_PORT N_UP N_DOWN N_WG_PRIV N_WG_PUB N_WG_CLI_PRIV N_WG_CLI_PUB N_WG_IP N_SECURE
    # shellcheck disable=SC1090
    . "$f"
    # set -u 下保证所有字段都有定义（旧节点文件可能缺字段）
    N_ID="${N_ID:-$1}"; N_REMARK="${N_REMARK:-node-$1}"; N_PROTO="${N_PROTO:-}"
    N_MODE="${N_MODE:-direct}"; N_PORT="${N_PORT:-0}"; N_LOCAL_PORT="${N_LOCAL_PORT:-0}"
    N_ENABLED="${N_ENABLED:-true}"; N_UUID="${N_UUID:-}"; N_PASS="${N_PASS:-}"
    N_FLOW="${N_FLOW:-}"; N_PATH="${N_PATH:-}"; N_DOMAIN="${N_DOMAIN:-}"
    N_SNI="${N_SNI:-}"; N_DEST="${N_DEST:-}"; N_PRIV="${N_PRIV:-}"
    N_PUB="${N_PUB:-}"; N_SID="${N_SID:-}"; N_METHOD="${N_METHOD:-}"
    N_USER="${N_USER:-}"; N_UP="${N_UP:-}"; N_DOWN="${N_DOWN:-}"
    N_WG_PRIV="${N_WG_PRIV:-}"; N_WG_PUB="${N_WG_PUB:-}"
    N_WG_CLI_PRIV="${N_WG_CLI_PRIV:-}"; N_WG_CLI_PUB="${N_WG_CLI_PUB:-}"
    N_WG_IP="${N_WG_IP:-}"; N_SECURE="${N_SECURE:-}"
    return 0
}

node_save() {
    # 从 N_* 变量写回文件
    local f; f=$(node_file "$N_ID")
    {
    printf 'N_ID=%q\n'        "$N_ID"
    printf 'N_REMARK=%q\n'    "${N_REMARK:-}"
    printf 'N_PROTO=%q\n'     "${N_PROTO:-}"
    printf 'N_MODE=%q\n'      "${N_MODE:-}"
    printf 'N_PORT=%q\n'      "${N_PORT:-}"
    printf 'N_LOCAL_PORT=%q\n' "${N_LOCAL_PORT:-0}"
    printf 'N_ENABLED=%q\n'   "${N_ENABLED:-true}"
    printf 'N_UUID=%q\n'      "${N_UUID:-}"
    printf 'N_PASS=%q\n'      "${N_PASS:-}"
    printf 'N_FLOW=%q\n'      "${N_FLOW:-}"
    printf 'N_PATH=%q\n'      "${N_PATH:-}"
    printf 'N_DOMAIN=%q\n'    "${N_DOMAIN:-}"
    printf 'N_SNI=%q\n'       "${N_SNI:-}"
    printf 'N_DEST=%q\n'      "${N_DEST:-}"
    printf 'N_PRIV=%q\n'      "${N_PRIV:-}"
    printf 'N_PUB=%q\n'       "${N_PUB:-}"
    printf 'N_SID=%q\n'       "${N_SID:-}"
    printf 'N_METHOD=%q\n'    "${N_METHOD:-}"
    printf 'N_USER=%q\n'      "${N_USER:-}"
    printf 'N_UP=%q\n'        "${N_UP:-}"
    printf 'N_DOWN=%q\n'      "${N_DOWN:-}"
    printf 'N_WG_PRIV=%q\n'   "${N_WG_PRIV:-}"
    printf 'N_WG_PUB=%q\n'    "${N_WG_PUB:-}"
    printf 'N_WG_CLI_PRIV=%q\n' "${N_WG_CLI_PRIV:-}"
    printf 'N_WG_CLI_PUB=%q\n'  "${N_WG_CLI_PUB:-}"
    printf 'N_WG_IP=%q\n'     "${N_WG_IP:-}"
    } >"$f"
    chmod 600 "$f"
}


node_next_id() {
    local max=0 id
    for f in "$NODE_DIR"/*.env; do
        [[ -e "$f" ]] || continue
        id="${f##*/}"; id="${id%.env}"
        [[ "$id" =~ ^[0-9]+$ ]] && (( id > max )) && max="$id"
    done
    echo $((max + 1))
}

node_delete() {
    local id="$1" f; f=$(node_file "$id")
    [[ -f "$f" ]] || die "节点 ${id} 不存在"
    node_load "$id"
    rm -f "$f"
    # 清理该节点的自签证书
    rm -f "${CERT_DIR}/${id}.crt" "${CERT_DIR}/${id}.key" 2>/dev/null
    info "节点 ${id}（${N_REMARK}）已删除"
}

# 列出所有节点 id
node_ids() {
    local f
    for f in "$NODE_DIR"/*.env; do
        [[ -e "$f" ]] || continue
        f="${f##*/}"; printf '%s\n' "${f%.env}"
    done | sort -n
}

# ── 密钥 / 端口工具 ─────────────────────────────────────────────────────────
gen_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null; then uuidgen | tr 'A-Z' 'a-z'
    else openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
    fi
}

gen_hex() { openssl rand -hex "${1:-8}"; }

gen_password() { openssl rand -base64 18 | tr -d '/+=' | cut -c1-20; }

port_in_use() {
    local p="$1"
    ss -ltnu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}$"
}

port_used_by_node() {
    local p="$1" skip="${2:-}" id
    for id in $(node_ids); do
        [[ "$id" == "$skip" ]] && continue
        node_load "$id"
        [[ "${N_PORT}" == "$p" ]] && return 0
    done
    return 1
}

pick_port() {
    local def="${1:-0}" p
    while true; do
        p=$(ask "端口" "${def:-443}")
        if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then warn "端口需在 1-65535"; continue; fi
        if port_used_by_node "$p"; then warn "端口 ${p} 已被其他节点占用"; continue; fi
        printf '%s' "$p"; return
    done
}

pick_local_port() {
    local p
    while true; do
        p=$(shuf -i 10000-59999 -n1 2>/dev/null || awk 'BEGIN{srand();print int(rand()*49999)+10000}')
        port_in_use "$p" || { printf '%s' "$p"; return; }
    done
}

pick_reality_sni() {
    local i
    echo "" >&2
    for i in "${!REALITY_DESTS[@]}"; do printf '     %2d) %s\n' "$((i+1))" "${REALITY_DESTS[$i]}" >&2; done
    while true; do
        local c; read -rp "  选择伪装域名 [1-${#REALITY_DESTS[@]}] (默认 1): " c
        c="${c:-1}"
        if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#REALITY_DESTS[@]} )); then
            printf '%s' "${REALITY_DESTS[$((c-1))]}"; return
        fi
        warn "请输入 1-${#REALITY_DESTS[@]}" >&2
    done
}

# ═══════════════════════════════════════════════════════════════════════════
#  5. 核心与 Caddy 安装
# ═══════════════════════════════════════════════════════════════════════════

install_xray() {
    step "安装 Xray-core"
    local arch ver url tmp
    arch=$(xray_arch); tmp=$(mktemp -d)
    ver=$(curl -fsSL --max-time 15 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
          | jq -r '.tag_name // empty' 2>/dev/null)
    [[ -z "$ver" ]] && ver="v25.3.6"
    url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${arch}.zip"
    info "版本 ${ver} / 架构 ${arch}"
    curl -fsSL --max-time 120 -o "${tmp}/x.zip" "$url" || die "Xray 下载失败"
    unzip -qo "${tmp}/x.zip" -d "${tmp}/out" || die "Xray 解压失败"
    install -m 755 "${tmp}/out/xray" "$XRAY_BIN"
    # geoip.dat / geosite.dat 是路由规则依赖，缺了 geoip:private 规则会直接报错
    install -d /usr/local/share/xray
    local f
    for f in geoip.dat geosite.dat; do
        [[ -f "${tmp}/out/${f}" ]] && install -m 644 "${tmp}/out/${f}" "/usr/local/share/xray/${f}"
    done
    rm -rf "$tmp"
    info "Xray 安装完成: $("$XRAY_BIN" version 2>&1 | head -1)"
}

install_singbox() {
    step "安装 sing-box"
    local arch ver pkg url tmp
    arch=$(sbox_arch); tmp=$(mktemp -d)
    ver="${SBOX_VERSION:-}"
    if [[ -z "$ver" ]]; then
        ver=$(curl -fsSL --max-time 15 "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=20" 2>/dev/null \
              | jq -r '[.[] | select(.prerelease == false)][0].tag_name // empty' 2>/dev/null)
    fi
    [[ -z "$ver" ]] && ver="v1.14.4"
    [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "sing-box 版本格式无效: $ver"
    pkg="sing-box-${ver#v}-linux-${arch}"
    url="https://github.com/SagerNet/sing-box/releases/download/${ver}/${pkg}.tar.gz"
    info "版本 ${ver} / 架构 ${arch}"
    curl -fsSL --max-time 120 -o "${tmp}/s.tar.gz" "$url" || die "sing-box 下载失败"
    tar -xzf "${tmp}/s.tar.gz" -C "$tmp" || die "sing-box 解压失败"
    install -m 755 "${tmp}/${pkg}/sing-box" "$SBOX_BIN"
    rm -rf "$tmp"
    if [[ "$PKG_MGR" == apk ]] && ldd "$SBOX_BIN" 2>&1 | grep -qi 'ld-linux'; then
        pkg_install gcompat || true
    fi
    info "sing-box 安装完成: $("$SBOX_BIN" version 2>&1 | head -1)"
}

install_caddy() {
    command -v caddy >/dev/null && { info "Caddy 已存在: $(caddy version 2>/dev/null | head -1)"; return; }
    step "安装 Caddy"
    if [[ "$PKG_MGR" == apt ]]; then
        pkg_install debian-keyring debian-archive-keyring apt-transport-https gpg
        curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
        curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
        pkg_install caddy
    else
        apk add --quiet --no-progress --repository https://dl-cdn.alpinelinux.org/alpine/edge/community caddy \
            || pkg_install caddy
    fi
    command -v caddy >/dev/null || die "Caddy 安装失败"
    info "Caddy 安装完成: $(caddy version 2>/dev/null | head -1)"
}

ensure_core() {
    local want="$1"
    if [[ "$want" == singbox ]]; then
        [[ -x "$SBOX_BIN" ]] || install_singbox
    else
        [[ -x "$XRAY_BIN" ]] || install_xray
    fi
}

gen_reality_keys() {
    # 输出: "私钥 公钥"
    local core="$1" out priv pub
    if [[ "$core" == singbox ]]; then
        out=$("$SBOX_BIN" generate reality-keypair 2>/dev/null)
        priv=$(printf '%s' "$out" | awk '/PrivateKey/{print $NF}')
        pub=$(printf '%s' "$out" | awk '/PublicKey/{print $NF}')
    else
        out=$("$XRAY_BIN" x25519 2>/dev/null)
        priv=$(printf '%s' "$out" | awk -F': ' '/Private key/{print $2}')
        pub=$(printf '%s' "$out" | awk -F': ' '/Public key/{print $2}')
    fi
    [[ -n "$priv" && -n "$pub" ]] || die "Reality 密钥生成失败"
    printf '%s %s' "$priv" "$pub"
}

gen_selfsigned_cert() {
    # gen_selfsigned_cert <id> <CN域名>
    local id="$1" cn="$2"
    local crt="${CERT_DIR}/${id}.crt" key="${CERT_DIR}/${id}.key"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key" -out "$crt" -days 3650 -nodes \
        -subj "/CN=${cn}" -addext "subjectAltName=DNS:${cn}" >/dev/null 2>&1 \
    || openssl req -x509 -newkey rsa:2048 -keyout "$key" -out "$crt" -days 3650 -nodes \
        -subj "/CN=${cn}" >/dev/null 2>&1
    [[ -f "$crt" && -f "$key" ]] || die "自签证书生成失败"
    chmod 600 "$key"
}

# ═══════════════════════════════════════════════════════════════════════════
#  6. 节点创建
# ═══════════════════════════════════════════════════════════════════════════

proto_rank_name() {
    case "$1" in
        vless)      echo "VLESS" ;;
        vmess)      echo "VMess" ;;
        trojan)     echo "Trojan" ;;
        ss)         echo "Shadowsocks" ;;
        socks)      echo "SOCKS5" ;;
        http)       echo "HTTP" ;;
        hysteria2)  echo "Hysteria2" ;;
        tuic)       echo "TUIC v5" ;;
        anytls)     echo "AnyTLS" ;;
        wireguard)  echo "WireGuard" ;;
        *)          echo "$1" ;;
    esac
}

xray_supported() {
    case "$1" in vless|vmess|trojan|ss|socks|http) return 0 ;; *) return 1 ;; esac
}

node_new() {
    cfg_load
    local core="${core_type:-singbox}"

    echo ""
    echo -e "${BOLD}  新建节点${NC}"
    hr
    node_load 0 2>/dev/null || true

    N_ID=$(node_next_id)
    N_REMARK=$(ask "备注名" "node-${N_ID}")
    N_ENABLED=true
    N_LOCAL_PORT=0

    echo ""
    echo "  协议："
    echo "    1) VLESS        2) VMess        3) Trojan"
    echo "    4) Shadowsocks  5) SOCKS5       6) HTTP"
    echo "    7) Hysteria2    8) TUIC v5      9) AnyTLS     10) WireGuard"
    local pc
    while true; do
        pc=$(ask "选择" "1")
        case "$pc" in
            1) N_PROTO=vless ;;     2) N_PROTO=vmess ;;
            3) N_PROTO=trojan ;;    4) N_PROTO=ss ;;
            5) N_PROTO=socks ;;     6) N_PROTO=http ;;
            7) N_PROTO=hysteria2 ;; 8) N_PROTO=tuic ;;
            9) N_PROTO=anytls ;;    10) N_PROTO=wireguard ;;
            *) warn "请输入 1-10"; continue ;;
        esac
        break
    done
    [[ "$core" == xray ]] && ! xray_supported "$N_PROTO" && \
        die "Xray 核心不支持 $(proto_rank_name "$N_PROTO")，请先在 全局设置 切换为 sing-box"

    # ── 传输模式 ──
    case "$N_PROTO" in
        vless|trojan)
            echo ""
            echo "  模式："
            echo "    1) Reality       无需域名，直接监听公网端口"
            echo "    2) WS + TLS      需要域名，Caddy 自动签发证书"
            local c; c=$(ask "选择" "1")
            [[ "$c" == 2 ]] && N_MODE=ws || N_MODE=reality
            ;;
        vmess)
            echo ""
            echo "  模式："
            echo "    1) WS + TLS      需要域名，走 Caddy"
            echo "    2) 裸 TCP        无 TLS，建议仅用于内网/中转"
            local c; c=$(ask "选择" "1")
            [[ "$c" == 2 ]] && N_MODE=tcp || N_MODE=ws
            ;;
        *) N_MODE=direct ;;
    esac

    # ── 端口 ──
    echo ""
    if [[ "$N_MODE" == ws ]]; then
        local cport; cport=$(cfg_get caddy_port); cport="${cport:-443}"
        N_PORT="${cport}"
        N_LOCAL_PORT=$(pick_local_port)
        info "对外由 Caddy 监听 ${N_PORT}，核心监听 127.0.0.1:${N_LOCAL_PORT}"
        N_DOMAIN=$(ask "该节点域名（例: node1.example.com）")
        [[ -n "$N_DOMAIN" ]] || die "WS 模式必须填写域名"
        N_SNI="$N_DOMAIN"
        local defp="/${N_DOMAIN%%.*}-${N_ID}"
        N_PATH=$(ask "WS 路径" "$defp")
        [[ "$N_PATH" == /* ]] || N_PATH="/${N_PATH}"
    else
        N_PORT=$(pick_port "")
        N_DOMAIN=""; N_PATH=""
    fi

    # ── 各协议凭据 ──
    case "$N_PROTO" in
        vless)
            N_UUID=$(gen_uuid)
            if [[ "$N_MODE" == reality ]]; then
                N_FLOW=xtls-rprx-vision
                echo ""
                N_DEST=$(pick_reality_sni)
                N_SNI="$N_DEST"
                local pair; pair=$(gen_reality_keys "$core")
                N_PRIV="${pair%% *}"; N_PUB="${pair##* }"
                N_SID=$(gen_hex 8)
            else
                N_FLOW=""
            fi
            ;;
        vmess)
            N_UUID=$(gen_uuid)
            ;;
        trojan)
            N_PASS=$(gen_password)
            if [[ "$N_MODE" == reality ]]; then
                echo ""
                N_DEST=$(pick_reality_sni)
                N_SNI="$N_DEST"
                local pair; pair=$(gen_reality_keys "$core")
                N_PRIV="${pair%% *}"; N_PUB="${pair##* }"
                N_SID=$(gen_hex 8)
            fi
            ;;
        ss)
            N_METHOD="2022-blake3-aes-128-gcm"
            # SS2022 要求密钥是定长 base64
            N_PASS=$(openssl rand -base64 16)
            ;;
        socks|http)
            N_USER=$(ask "用户名" "u$(gen_hex 3)")
            N_PASS=$(ask "密码" "$(gen_password)")
            ;;
        hysteria2|tuic)
            N_PASS=$(gen_password)
            [[ "$N_PROTO" == tuic ]] && N_UUID=$(gen_uuid)
            N_SNI=$(ask "SNI（自签证书 CN，随便填域名即可）" "node${N_ID}.local")
            gen_selfsigned_cert "$N_ID" "$N_SNI"
            ;;
        anytls)
            N_USER="user"
            N_PASS=$(gen_password)
            N_SNI=$(ask "SNI（自签证书 CN）" "node${N_ID}.local")
            gen_selfsigned_cert "$N_ID" "$N_SNI"
            ;;
        wireguard)
            # 服务端与客户端各自一对 X25519 密钥；peer 里放的是「客户端公钥」
            local sp spub cp cpub pair
            pair=$(gen_wg_pair) || die "WireGuard 服务端密钥生成失败"
            sp="${pair%% *}"; spub="${pair##* }"
            pair=$(gen_wg_pair) || die "WireGuard 客户端密钥生成失败"
            cp="${pair%% *}"; cpub="${pair##* }"
            N_WG_PRIV="$sp"
            N_WG_PUB="$spub"          # 服务端公钥，给客户端填 Peer PublicKey
            N_WG_CLI_PRIV="$cp"       # 客户端私钥，给客户端填 Interface PrivateKey
            N_WG_CLI_PUB="$cpub"      # 放进服务端 peers
            N_WG_IP="10.0.0.2/32"
            ;;
    esac

    # ── 确认 ──
    echo ""
    hr
    kv "备注"   "$N_REMARK"
    kv "协议"   "$(proto_rank_name "$N_PROTO")"
    kv "模式"   "$N_MODE"
    kv "端口"   "$N_PORT"
    [[ -n "$N_DOMAIN" ]] && kv "域名" "$N_DOMAIN"
    [[ -n "$N_PATH"   ]] && kv "路径" "$N_PATH"
    [[ -n "$N_SNI"    ]] && kv "SNI"  "$N_SNI"
    hr
    confirm "创建该节点?" y || { info "已取消"; return 1; }

    node_save
    info "节点 ${N_ID} 已创建"
    apply_all && node_show "$N_ID"
}

# ── WireGuard 密钥（纯 openssl，不依赖 python / 额外包）─────────────────────
# PKCS#8 里 X25519 私钥的固定前缀：302e020100300506032b656e04220420
_WG_PKCS8_HEAD="302e020100300506032b656e04220420"

# 生成 32 字节 X25519 私钥（base64，与 wg 工具同格式）
gen_wg_priv() { openssl rand -base64 32 | tr -d '\n'; }

# 由私钥派生公钥：把 raw 私钥包成 PKCS#8 DER，交给 openssl 求公钥，
# 再从 SubjectPublicKeyInfo DER 的末尾取 32 字节 raw 公钥。
wg_pub() {
    local priv="$1" der pubder
    [[ -n "$priv" ]] || return 1
    der=$(printf '%s' "${_WG_PKCS8_HEAD}$(printf '%s' "$priv" | base64 -d 2>/dev/null | od -An -tx1 -v | tr -d ' \n')" \
          | xxd -r -p 2>/dev/null | base64 -w0 2>/dev/null)
    [[ -n "$der" ]] || return 1
    pubder=$(printf '%s' "$der" | base64 -d 2>/dev/null \
             | openssl pkey -inform DER -pubout -outform DER 2>/dev/null \
             | od -An -tx1 -v | tr -d ' \n')
    [[ ${#pubder} -ge 64 ]] || return 1
    # SubjectPublicKeyInfo 固定 12 字节头 + 32 字节公钥
    printf '%s' "${pubder: -64}" | xxd -r -p 2>/dev/null | base64 -w0 2>/dev/null
}

# 生成一对 WireGuard 密钥，回显 "私钥 公钥"
gen_wg_pair() {
    local priv pub
    priv=$(gen_wg_priv)
    pub=$(wg_pub "$priv")
    [[ -n "$priv" && -n "$pub" ]] || return 1
    printf '%s %s' "$priv" "$pub"
}

# ═══════════════════════════════════════════════════════════════════════════
#  7. 配置生成 —— sing-box
# ═══════════════════════════════════════════════════════════════════════════

# 生成单个入站/端点的 JSON（单行），写入 stdout
sb_node_json() {
    local id="$1"
    node_load "$id" || return 1
    [[ "${N_ENABLED}" == "true" ]] || return 1

    local tag="in-${N_ID}"
    local listen="::"
    [[ "$N_MODE" == ws ]] && listen="127.0.0.1"
    local port="${N_PORT:-0}"
    [[ "$N_MODE" == ws ]] && port="${N_LOCAL_PORT:-0}"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 )) || { errln "节点 ${N_ID} 端口非法: '${port}'"; return 1; }

    case "$N_PROTO" in
    vless)
        if [[ "$N_MODE" == reality ]]; then
            jq -cn \
                --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                --arg uuid "$N_UUID" --arg flow "$N_FLOW" \
                --arg sni "$N_SNI" --arg dest "$N_DEST" \
                --arg priv "$N_PRIV" --arg sid "$N_SID" \
                '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,
                  users:[({uuid:$uuid} + (if $flow=="" then {} else {flow:$flow} end))],
                  tls:{enabled:true,server_name:$sni,
                       reality:{enabled:true,
                                handshake:{server:$dest,server_port:443},
                                private_key:$priv,short_id:[$sid]}}}'
        else
            jq -cn \
                --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                --arg uuid "$N_UUID" --arg path "$N_PATH" \
                '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,
                  users:[{uuid:$uuid}],
                  transport:{type:"ws",path:$path}}'
        fi
        ;;
    vmess)
        if [[ "$N_MODE" == ws ]]; then
            jq -cn \
                --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                --arg uuid "$N_UUID" --arg path "$N_PATH" \
                '{type:"vmess",tag:$tag,listen:$listen,listen_port:$port,
                  users:[{uuid:$uuid,alterId:0}],
                  transport:{type:"ws",path:$path}}'
        else
            jq -cn \
                --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                --arg uuid "$N_UUID" \
                '{type:"vmess",tag:$tag,listen:$listen,listen_port:$port,
                  users:[{uuid:$uuid,alterId:0}]}'
        fi
        ;;
    trojan)
        if [[ "$N_MODE" == reality ]]; then
            jq -cn \
                --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                --arg pass "$N_PASS" --arg sni "$N_SNI" --arg dest "$N_DEST" \
                --arg priv "$N_PRIV" --arg sid "$N_SID" \
                '{type:"trojan",tag:$tag,listen:$listen,listen_port:$port,
                  users:[{password:$pass}],
                  tls:{enabled:true,server_name:$sni,
                       reality:{enabled:true,
                                handshake:{server:$dest,server_port:443},
                                private_key:$priv,short_id:[$sid]}}}'
        else
            jq -cn \
                --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                --arg pass "$N_PASS" --arg path "$N_PATH" \
                '{type:"trojan",tag:$tag,listen:$listen,listen_port:$port,
                  users:[{password:$pass}],
                  transport:{type:"ws",path:$path}}'
        fi
        ;;
    ss)
        jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
               --arg method "$N_METHOD" --arg pass "$N_PASS" \
               '{type:"shadowsocks",tag:$tag,listen:$listen,listen_port:$port,
                 method:$method,password:$pass}'
        ;;
    socks|http)
        jq -cn --arg t "$N_PROTO" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
               --arg u "$N_USER" --arg p "$N_PASS" \
               '{type:$t,tag:$tag,listen:$listen,listen_port:$port,
                 users:[{username:$u,password:$p}]}'
        ;;
    hysteria2)
        jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
               --arg pass "$N_PASS" --arg sni "$N_SNI" \
               --arg crt "${CERT_DIR}/${N_ID}.crt" --arg key "${CERT_DIR}/${N_ID}.key" \
               '{type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,
                 users:[{password:$pass}],
                 tls:{enabled:true,server_name:$sni,alpn:["h3"],
                      certificate_path:$crt,key_path:$key}}'
        ;;
    tuic)
        jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
               --arg uuid "$N_UUID" --arg pass "$N_PASS" --arg sni "$N_SNI" \
               --arg crt "${CERT_DIR}/${N_ID}.crt" --arg key "${CERT_DIR}/${N_ID}.key" \
               '{type:"tuic",tag:$tag,listen:$listen,listen_port:$port,
                 users:[{uuid:$uuid,password:$pass}],
                 congestion_control:"bbr",zero_rtt_handshake:false,
                 tls:{enabled:true,server_name:$sni,alpn:["h3"],
                      certificate_path:$crt,key_path:$key}}'
        ;;
    anytls)
        jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
               --arg name "$N_USER" --arg pass "$N_PASS" --arg sni "$N_SNI" \
               --arg crt "${CERT_DIR}/${N_ID}.crt" --arg key "${CERT_DIR}/${N_ID}.key" \
               '{type:"anytls",tag:$tag,listen:$listen,listen_port:$port,
                 users:[{name:$name,password:$pass}],
                 tls:{enabled:true,server_name:$sni,
                      certificate_path:$crt,key_path:$key}}'
        ;;
    *)
        return 1
        ;;
    esac
}

# WireGuard 是 endpoints，不是 inbounds
sb_wg_json() {
    local id="$1"
    node_load "$id" || return 1
    [[ "${N_ENABLED}" == "true" && "${N_PROTO}" == "wireguard" ]] || return 1
    local tag="wg-${N_ID}"
    jq -cn --arg tag "$tag" --argjson port "$N_PORT" \
           --arg priv "$N_WG_PRIV" --arg pub "$N_WG_CLI_PUB" --arg ip "$N_WG_IP" \
           '{type:"wireguard",tag:$tag,system:false,mtu:1420,
             address:["10.0.0.1/32"],private_key:$priv,
             listen_port:$port,
             peers:[{public_key:$pub,allowed_ips:[$ip]}]}'
}

sb_generate() {
    local inbounds='[]' endpoints='[]' rules='[]' outs='[]' id json
    local relay_mode relay_json

    for id in $(node_ids); do
        node_load "$id" || continue
        [[ "${N_ENABLED}" == "true" ]] || continue
        if [[ "${N_PROTO}" == "wireguard" ]]; then
            json=$(sb_wg_json "$id") || continue
            [[ -n "$json" ]] || continue
            endpoints=$(jq -c --argjson o "$json" '. + [$o]' <<<"$endpoints") \
                || { errln "WireGuard 端点 ${id} 拼接失败"; return 1; }
        else
            json=$(sb_node_json "$id") || continue
            [[ -n "$json" ]] || { warn "节点 ${id}（${N_PROTO}）生成失败，已跳过"; continue; }
            inbounds=$(jq -c --argjson o "$json" '. + [$o]' <<<"$inbounds") \
                || { errln "节点 ${id} 入站 JSON 拼接失败"; return 1; }
        fi
    done

    # 出站：direct 必在首位
    outs='[{"type":"direct","tag":"direct"}]'

    relay_mode=$(cfg_get relay_mode)
    relay_mode="${relay_mode:-none}"
    if [[ "$relay_mode" == chain ]]; then
        local rh rp rsid rpub rpath
        rh=$(cfg_get relay_host); rp=$(cfg_get relay_port)
        rsid=$(cfg_get relay_sni); rpub=$(cfg_get relay_public_key)
        rpath=$(cfg_get relay_path)
        if [[ -n "$rh" && -n "$rp" ]]; then
            relay_json=$(jq -cn --arg s "$rh" --argjson p "${rp:-0}" \
                --arg uuid "$(cfg_get relay_uuid)" --arg sni "$rsid" \
                --arg pbk "$rpub" --arg sid "$(cfg_get relay_short_id)" \
                --arg path "${rpath:-/}" \
                '{type:"vless",tag:"relay",server:$s,server_port:$p,uuid:$uuid,
                  flow:"xtls-rprx-vision",
                  tls:{enabled:true,server_name:$sni,
                       utls:{enabled:true,fingerprint:"chrome"},
                       reality:{enabled:true,public_key:$pbk,short_id:$sid}}}')
            [[ -n "$relay_json" ]] && {
                outs=$(jq -c --argjson o "$relay_json" '. + [$o]' <<<"$outs")
                rules=$(jq -c --argjson r '{"network":["tcp","udp"],"action":"route","outbound":"relay"}' \
                    '. + [$r]' <<<"$rules")
            }
        fi
    fi

    jq -n --argjson inb "$inbounds" --argjson ep "$endpoints" \
          --argjson outs "$outs" --argjson rules "$rules" '
      ({
        log: {level:"warn", timestamp:true},
        inbounds: $inb,
        outbounds: ($outs + [{type:"block",tag:"block"}]),
        route: {rules: ($rules + [{ip_is_private:true,outbound:"block"}]), final:"direct"}
      } + (if ($ep|length) > 0 then {endpoints:$ep} else {} end))'
}

# ═══════════════════════════════════════════════════════════════════════════
#  8. 配置生成 —— Xray
# ═══════════════════════════════════════════════════════════════════════════

xray_node_json() {
    local id="$1"
    node_load "$id" || return 1
    [[ "${N_ENABLED}" == "true" ]] || return 1
    local tag="in-${N_ID}"
    local listen="0.0.0.0" port="${N_PORT:-0}" net="tcp" sec="none"
    [[ "$N_MODE" == ws ]] && { listen="127.0.0.1"; port="${N_LOCAL_PORT:-0}"; net="ws"; }
    # 端口必须是非 0 整数，否则 jq --argjson 会因空串/非法值整份生成失败
    [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 )) || { errln "节点 ${N_ID} 端口非法: '${port}'"; return 1; }

    case "$N_PROTO" in
    vless)
        if [[ "$N_MODE" == reality ]]; then
            jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                   --arg uuid "$N_UUID" --arg flow "$N_FLOW" \
                   --arg dest "$N_DEST" --arg priv "$N_PRIV" --arg sid "$N_SID" \
                   '{tag:$tag,listen:$listen,port:$port,protocol:"vless",
                     settings:{clients:[{id:$uuid,flow:$flow,level:0}],decryption:"none"},
                     streamSettings:{network:"tcp",security:"reality",
                       realitySettings:{show:false,dest:($dest+":443"),xver:0,
                         serverNames:[$dest],privateKey:$priv,shortIds:[$sid]}},
                     sniffing:{enabled:true,destOverride:["http","tls","quic"]}}'
        else
            jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                   --arg uuid "$N_UUID" --arg path "$N_PATH" \
                   '{tag:$tag,listen:$listen,port:$port,protocol:"vless",
                     settings:{clients:[{id:$uuid,level:0}],decryption:"none"},
                     streamSettings:{network:"ws",security:"none",wsSettings:{path:$path}},
                     sniffing:{enabled:true,destOverride:["http","tls","quic"]}}'
        fi
        ;;
    vmess)
        if [[ "$N_MODE" == ws ]]; then
            jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                   --arg uuid "$N_UUID" --arg path "$N_PATH" \
                   '{tag:$tag,listen:$listen,port:$port,protocol:"vmess",
                     settings:{clients:[{id:$uuid,alterId:0,level:0}]},
                     streamSettings:{network:"ws",security:"none",wsSettings:{path:$path}},
                     sniffing:{enabled:true,destOverride:["http","tls","quic"]}}'
        else
            jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                   --arg uuid "$N_UUID" \
                   '{tag:$tag,listen:$listen,port:$port,protocol:"vmess",
                     settings:{clients:[{id:$uuid,alterId:0,level:0}]},
                     streamSettings:{network:"tcp",security:"none"},
                     sniffing:{enabled:true,destOverride:["http","tls","quic"]}}'
        fi
        ;;
    trojan)
        if [[ "$N_MODE" == reality ]]; then
            jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                   --arg pass "$N_PASS" --arg dest "$N_DEST" \
                   --arg priv "$N_PRIV" --arg sid "$N_SID" \
                   '{tag:$tag,listen:$listen,port:$port,protocol:"trojan",
                     settings:{clients:[{password:$pass,level:0}]},
                     streamSettings:{network:"tcp",security:"reality",
                       realitySettings:{show:false,dest:($dest+":443"),xver:0,
                         serverNames:[$dest],privateKey:$priv,shortIds:[$sid]}},
                     sniffing:{enabled:true,destOverride:["http","tls","quic"]}}'
        else
            jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
                   --arg pass "$N_PASS" --arg path "$N_PATH" \
                   '{tag:$tag,listen:$listen,port:$port,protocol:"trojan",
                     settings:{clients:[{password:$pass,level:0}]},
                     streamSettings:{network:"ws",security:"none",wsSettings:{path:$path}},
                     sniffing:{enabled:true,destOverride:["http","tls","quic"]}}'
        fi
        ;;
    ss)
        jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
               --arg method "$N_METHOD" --arg pass "$N_PASS" \
               '{tag:$tag,listen:$listen,port:$port,protocol:"shadowsocks",
                 settings:{method:$method,password:$pass,network:"tcp,udp"},
                 sniffing:{enabled:true,destOverride:["http","tls","quic"]}}'
        ;;
    socks|http)
        jq -cn --arg t "$N_PROTO" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
               --arg u "$N_USER" --arg p "$N_PASS" \
               '{tag:$tag,listen:$listen,port:$port,protocol:$t,
                 settings:{auth:"password",accounts:[{user:$u,pass:$p}],udp:true},
                 sniffing:{enabled:true,destOverride:["http","tls","quic"]}}'
        ;;
    esac
}

xray_generate() {
    local inbounds='[]' outs='[{"protocol":"freedom","tag":"direct","settings":{"domainStrategy":"UseIPv4"}}]'
    local id json relay_mode

    for id in $(node_ids); do
        node_load "$id" || continue
        [[ "${N_ENABLED}" == "true" ]] || continue
        json=$(xray_node_json "$id") || continue
        [[ -n "$json" ]] || { warn "节点 ${id}（${N_PROTO}）当前核心不支持，已跳过"; continue; }
        inbounds=$(jq -c --argjson o "$json" '. + [$o]' <<<"$inbounds") \
            || { errln "节点 ${id} 入站 JSON 拼接失败"; return 1; }
    done

    relay_mode=$(cfg_get relay_mode); relay_mode="${relay_mode:-none}"
    if [[ "$relay_mode" == chain ]]; then
        local rh rp rsid
        rh=$(cfg_get relay_host); rp=$(cfg_get relay_port); rsid=$(cfg_get relay_sni)
        if [[ -n "$rh" && -n "$rp" ]]; then
            json=$(jq -cn --arg s "$rh" --argjson p "$rp" \
                --arg uuid "$(cfg_get relay_uuid)" --arg sni "$rsid" \
                --arg pbk "$(cfg_get relay_public_key)" --arg sid "$(cfg_get relay_short_id)" \
                '{protocol:"vless",tag:"relay",
                  settings:{vnext:[{address:$s,port:$p,users:[{id:$uuid,encryption:"none",flow:"xtls-rprx-vision"}]}]},
                  streamSettings:{network:"tcp",security:"reality",
                    realitySettings:{serverName:$sni,fingerprint:"chrome",publicKey:$pbk,shortId:$sid}}}')
            outs=$(jq -c --argjson o "$json" '. + [$o]' <<<"$outs")
        fi
    fi
    outs=$(jq -c '. + [{"protocol":"blackhole","tag":"block"}]' <<<"$outs")

    jq -n --argjson inb "$inbounds" --argjson outs "$outs" '
      {log:{loglevel:"warning",access:"none"},
       inbounds:$inb,
       outbounds:$outs,
       routing:{domainStrategy:"AsIs",rules:[{type:"field",ip:["geoip:private"],outboundTag:"block"}]}}'
}

# ═══════════════════════════════════════════════════════════════════════════
#  9. Caddy 配置（WS 系节点）
# ═══════════════════════════════════════════════════════════════════════════

caddy_generate() {
    local email cport ws_nodes=0 id body=""
    email=$(cfg_get email); cport=$(cfg_get caddy_port); cport="${cport:-443}"

    for id in $(node_ids); do
        node_load "$id" || continue
        [[ "${N_ENABLED}" == "true" && "${N_MODE}" == ws ]] || continue
        ws_nodes=$((ws_nodes + 1))
        local dom="${N_DOMAIN:-${N_SNI}}"
        [[ -n "$dom" ]] || continue
        body="${body}
${dom} {
	@ws {
		path ${N_PATH}
		header Connection *Upgrade*
		header Upgrade websocket
	}
	reverse_proxy @ws 127.0.0.1:${N_LOCAL_PORT}
	@probe {
		path ${N_PATH}
	}
	respond @probe 404
	handle {
		root * ${FAKE_WEBROOT}
		file_server
	}
}
"
    done

    if (( ws_nodes == 0 )); then
        printf '%s' "$body" >"$CADDY_CONF"
        return 0
    fi

    {
        printf '{\n'
        [[ -n "$email" ]] && printf '\temail %s\n' "$email"
        printf '\tadmin off\n'
        printf '\tservers {\n\t\tprotocols h1 h2\n'
        (( cport != 443 )) && printf '\t\tlisten [::]:%s\n' "$cport"
        printf '\t}\n}\n'
        printf '%s' "$body"
    } >"$CADDY_CONF"
}

# ═══════════════════════════════════════════════════════════════════════════
#  10. 应用配置（校验 + 回滚）
# ═══════════════════════════════════════════════════════════════════════════

apply_all() {
    cfg_load
    local core="${core_type:-singbox}"
    local tmp_sb tmp_xr had_ws=0

    step "生成并校验配置"
    mkdir -p "$SBOX_CONF_DIR" "$XRAY_CONF_DIR" "$FAKE_WEBROOT"

    if [[ "$core" == singbox ]]; then
        tmp_sb=$(mktemp)
        sb_generate >"$tmp_sb" || die "sing-box 配置生成失败"
        if ! "$SBOX_BIN" check -c "$tmp_sb" 2>/tmp/sbcheck.err; then
            errln "sing-box 配置校验未通过："
            sed 's/^/    /' /tmp/sbcheck.err >&2
            rm -f "$tmp_sb"
            return 1
        fi
        [[ -f "$SBOX_CONF" ]] && cp "$SBOX_CONF" "${SBOX_CONF}.bak"
        mv "$tmp_sb" "$SBOX_CONF"
        chmod 600 "$SBOX_CONF"
        info "sing-box 配置已写入并校验通过"
    else
        tmp_xr=$(mktemp)
        xray_generate >"$tmp_xr" || die "Xray 配置生成失败"
        if ! XRAY_LOCATION_ASSET=/usr/local/share/xray "$XRAY_BIN" run -test -c "$tmp_xr" >/tmp/xrcheck.err 2>&1; then
            errln "Xray 配置校验未通过："
            sed 's/^/    /' /tmp/xrcheck.err >&2
            rm -f "$tmp_xr"
            return 1
        fi
        [[ -f "$XRAY_CONF" ]] && cp "$XRAY_CONF" "${XRAY_CONF}.bak"
        mv "$tmp_xr" "$XRAY_CONF"
        chmod 600 "$XRAY_CONF"
        info "Xray 配置已写入并校验通过"
    fi

    # Caddy
    local id
    for id in $(node_ids); do
        node_load "$id" || continue
        [[ "${N_ENABLED}" == "true" && "${N_MODE}" == ws ]] && had_ws=1
    done

    if (( had_ws )); then
        command -v caddy >/dev/null || install_caddy
        install -d "$FAKE_WEBROOT"
        [[ -f "${FAKE_WEBROOT}/index.html" ]] || setup_fake_web
        mkdir -p "$(dirname "$CADDY_CONF")"
        [[ -f "$CADDY_CONF" ]] && cp "$CADDY_CONF" "${CADDY_CONF}.bak"
        caddy_generate
        if ! caddy validate --config "$CADDY_CONF" --adapter caddyfile >/tmp/cdcheck.err 2>&1; then
            errln "Caddyfile 校验未通过："
            sed 's/^/    /' /tmp/cdcheck.err >&2
            [[ -f "${CADDY_CONF}.bak" ]] && cp "${CADDY_CONF}.bak" "$CADDY_CONF"
            return 1
        fi
        info "Caddyfile 已写入并校验通过"
    fi

    setup_services_unit "$core"
    setup_traffic_chains

    # 重启
    if (( had_ws )); then
        svc_enable caddy
        svc restart caddy
        sleep 2
        svc_active caddy || warn "Caddy 未启动，查看: journalctl -u caddy -n 30"
    else
        svc stop caddy 2>/dev/null || true
    fi

    svc_enable "$([[ "$core" == singbox ]] && echo sing-box || echo xray)"
    if ! restart_core; then
        errln "核心启动失败，回滚到上一份配置"
        if [[ "$core" == singbox && -f "${SBOX_CONF}.bak" ]]; then
            cp "${SBOX_CONF}.bak" "$SBOX_CONF"; restart_core && warn "已回滚到上一份可用配置"
        elif [[ "$core" == xray && -f "${XRAY_CONF}.bak" ]]; then
            cp "${XRAY_CONF}.bak" "$XRAY_CONF"; restart_core && warn "已回滚到上一份可用配置"
        fi
        return 1
    fi

    log "配置已应用（核心=$core，节点数=$(node_count)）"
    info "全部服务已重启"
    return 0
}

restart_core() {
    cfg_load
    local s; s=$([[ "${core_type:-singbox}" == singbox ]] && echo sing-box || echo xray)
    svc restart "$s"
    sleep 2
    svc_active "$s" || return 1
    return 0
}

setup_services_unit() {
    local core="$1"
    local bin conf args
    if [[ "$core" == singbox ]]; then
        bin="$SBOX_BIN"; conf="$SBOX_CONF"; args="run -c ${conf}"
    else
        bin="$XRAY_BIN"; conf="$XRAY_CONF"; args="run -config ${conf}"
    fi
    local svcname=$([[ "$core" == singbox ]] && echo sing-box || echo xray)

    if [[ "$INIT_SYS" == systemd ]]; then
        cat >"/etc/systemd/system/${svcname}.service" <<EOF
[Unit]
Description=SingBox Go - ${svcname}
After=network-online.target ${CONF_DIR}/restore-iptables.sh
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStartPre=-${CONF_DIR}/restore-iptables.sh
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=${bin} ${args}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        cat >"/etc/init.d/${svcname}" <<EOF
#!/sbin/openrc-run
description="SingBox Go - ${svcname}"
command="${bin}"
command_args="${args}"
command_background=true
pidfile="/run/${svcname}.pid"
output_log="/var/log/${svcname}.log"
error_log="/var/log/${svcname}.log"
start_pre() { [ -x "${CONF_DIR}/restore-iptables.sh" ] && ${CONF_DIR}/restore-iptables.sh; }
depend() { need net; }
EOF
        chmod +x "/etc/init.d/${svcname}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  11. 流量统计（每端口 iptables 计数链）
# ═══════════════════════════════════════════════════════════════════════════

_port_has_udp() {
    case "$1" in hysteria2|tuic) return 0 ;; *) return 1 ;; esac
}

_chain_name() {
    # 链名上限 28 字符
    printf 'VP_I_%s' "$1"
}
_output_chain_name() { printf 'VP_O_%s' "$1"; }

setup_traffic_chains() {
    cfg_load
    [[ -f "$TRAFFIC_FILE" ]] || cat >"$TRAFFIC_FILE" <<'EOF'
traffic_month=""
traffic_bytes_saved=0
traffic_bytes_total=0
traffic_exceeded=false
EOF

    local id port ci co proto
    for id in $(node_ids); do
        node_load "$id" || continue
        [[ "${N_ENABLED}" == "true" ]] || continue
        port="$N_PORT"; proto="$N_PROTO"
        ci=$(_chain_name "$port"); co=$(_output_chain_name "$port")

        iptables -N "$ci" 2>/dev/null || true
        iptables -N "$co" 2>/dev/null || true

        local pflag=(-p tcp)
        _port_has_udp "$proto" && pflag=(-p udp)
        [[ "$proto" == wireguard ]] && pflag=(-p udp)

        while iptables -D INPUT "${pflag[@]}" --dport "$port" -j "$ci" 2>/dev/null; do :; done
        while iptables -D OUTPUT "${pflag[@]}" --sport "$port" -j "$co" 2>/dev/null; do :; done
        iptables -I INPUT  "${pflag[@]}" --dport "$port" -j "$ci" 2>/dev/null
        iptables -I OUTPUT "${pflag[@]}" --sport "$port" -j "$co" 2>/dev/null
        # 保持链里有 RETURN 终止符且保留计数
        if ! iptables -C "$ci" -j RETURN 2>/dev/null; then
            iptables -A "$ci" -j RETURN 2>/dev/null
            iptables -A "$co" -j RETURN 2>/dev/null
        fi
    done

    cat >"${CONF_DIR}/restore-iptables.sh" <<'EOFI'
#!/bin/bash
CONF_FILE="/etc/singbox-go/config.env"
NODE_DIR="/etc/singbox-go/nodes"
command -v iptables >/dev/null || exit 0
[[ -d "$NODE_DIR" ]] || exit 0
for f in "$NODE_DIR"/*.env; do
    [[ -e "$f" ]] || continue
    ( . "$f"
      [ "${N_ENABLED}" = "true" ] || exit 0
      port="$N_PORT"
      case "$N_PROTO" in hysteria2|tuic|wireguard) pf="-p udp" ;; *) pf="-p tcp" ;; esac
      ci="VP_I_${port}"; co="VP_O_${port}"
      iptables -N "$ci" 2>/dev/null || true
      iptables -N "$co" 2>/dev/null || true
      iptables -C INPUT $pf --dport "$port" -j "$ci" 2>/dev/null || \\
        iptables -I INPUT $pf --dport "$port" -j "$ci"
      iptables -C OUTPUT $pf --sport "$port" -j "$co" 2>/dev/null || \\
        iptables -I OUTPUT $pf --sport "$port" -j "$co"
      iptables -C "$ci" -j RETURN 2>/dev/null || iptables -A "$ci" -j RETURN
      iptables -C "$co" -j RETURN 2>/dev/null || iptables -A "$co" -j RETURN
    )
done
EOFI
    chmod +x "${CONF_DIR}/restore-iptables.sh"

    cat >"${CONF_DIR}/traffic-check.sh" <<'EOFC'
#!/bin/bash
CONF_FILE="/etc/singbox-go/config.env"
TRAFFIC_FILE="/etc/singbox-go/traffic.env"
NODE_DIR="/etc/singbox-go/nodes"
LOG_FILE="/var/log/singbox-go.log"
[[ -f "$CONF_FILE" ]] || exit 0
. "$CONF_FILE"
[ -f "$TRAFFIC_FILE" ] && . "$TRAFFIC_FILE"

total_now=0
for f in "$NODE_DIR"/*.env; do
    [[ -e "$f" ]] || continue
    ( . "$f"
      [ "${N_ENABLED}" = "true" ] || exit 0
      i=$(iptables -L "VP_I_${N_PORT}" -n -v -x 2>/dev/null | awk 'NR==3{print $2+0}')
      o=$(iptables -L "VP_O_${N_PORT}" -n -v -x 2>/dev/null | awk 'NR==3{print $2+0}')
      echo $(( ${i:-0} + ${o:-0} ))
    )
done | awk '{s+=$1} END{print s+0}' > /tmp/.vp_total
total_now=$(cat /tmp/.vp_total 2>/dev/null); total_now="${total_now:-0}"
TOTAL=$(( ${traffic_bytes_saved:-0} + total_now ))

sed -i "s/^traffic_bytes_total=.*/traffic_bytes_total=${TOTAL}/" "$TRAFFIC_FILE" 2>/dev/null \
  || echo "traffic_bytes_total=${TOTAL}" >> "$TRAFFIC_FILE"

CUR_MONTH=$(date +%Y-%m)
if [ "${traffic_month}" != "$CUR_MONTH" ]; then /etc/singbox-go/traffic-reset.sh; exit 0; fi

LIMIT_GB="${traffic_limit_gb:-0}"
[ "${LIMIT_GB:-0}" -le 0 ] && exit 0
LIMIT=$(( LIMIT_GB * 1024 * 1024 * 1024 ))
if [ "$TOTAL" -ge "$LIMIT" ] && [ "${traffic_exceeded:-false}" != "true" ]; then
    SVC="xray"; [ "${core_type}" = "singbox" ] && SVC="sing-box"
    systemctl stop "$SVC" 2>/dev/null || rc-service "$SVC" stop 2>/dev/null || true
    sed -i 's/^traffic_exceeded=.*/traffic_exceeded=true/' "$TRAFFIC_FILE" \
      || echo "traffic_exceeded=true" >> "$TRAFFIC_FILE"
    echo "[$(date '+%F %T')] 流量超限（${LIMIT_GB}GB），服务已停止。" >> "$LOG_FILE"
fi
EOFC
    chmod +x "${CONF_DIR}/traffic-check.sh"

    cat >"${CONF_DIR}/traffic-reset.sh" <<'EOFR'
#!/bin/bash
CONF_FILE="/etc/singbox-go/config.env"
TRAFFIC_FILE="/etc/singbox-go/traffic.env"
NODE_DIR="/etc/singbox-go/nodes"
LOG_FILE="/var/log/singbox-go.log"
[[ -f "$CONF_FILE" ]] || exit 0
. "$CONF_FILE"

for f in "$NODE_DIR"/*.env; do
    [[ -e "$f" ]] || continue
    ( . "$f"
      iptables -Z "VP_I_${N_PORT}" 2>/dev/null || true
      iptables -Z "VP_O_${N_PORT}" 2>/dev/null || true
    )
done

cat > "$TRAFFIC_FILE" <<ENVEOF
traffic_month=$(date +%Y-%m)
traffic_bytes_saved=0
traffic_bytes_total=0
traffic_exceeded=false
ENVEOF

SVC="xray"; [ "${core_type}" = "singbox" ] && SVC="sing-box"
systemctl start "$SVC" 2>/dev/null || rc-service "$SVC" start 2>/dev/null || true
echo "[$(date '+%F %T')] 月度流量已重置。" >> "$LOG_FILE"
EOFR
    chmod +x "${CONF_DIR}/traffic-reset.sh"

    setup_cron
}

setup_cron() {
    if [[ "$OS_ID" == alpine ]]; then
        sed -i '/singbox-go/d' /etc/crontabs/root 2>/dev/null || true
        printf '0 * * * * /etc/singbox-go/traffic-check.sh >/dev/null 2>&1\n' >>/etc/crontabs/root
        printf '5 0 1 * * /etc/singbox-go/traffic-reset.sh >/dev/null 2>&1\n' >>/etc/crontabs/root
        rc-service crond restart 2>/dev/null || rc-service dcron restart 2>/dev/null || true
    else
        cat >/etc/cron.d/singbox-go <<'EOF'
0 * * * * root /etc/singbox-go/traffic-check.sh >/dev/null 2>&1
5 0 1 * * root /etc/singbox-go/traffic-reset.sh >/dev/null 2>&1
EOF
        systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || true
    fi
}

show_traffic() {
    cfg_load
    [[ -x "${CONF_DIR}/traffic-check.sh" ]] && "${CONF_DIR}/traffic-check.sh" 2>/dev/null
    [[ -f "$TRAFFIC_FILE" ]] && . "$TRAFFIC_FILE"

    echo ""; hr
    printf '%s  流量统计 — %s%s\n' "$BOLD" "${traffic_month:-$(date +%Y-%m)}" "$NC"; hr

    local id
    for id in $(node_ids); do
        node_load "$id" || continue
        local ci co ib ob
        ci=$(_chain_name "$N_PORT"); co=$(_output_chain_name "$N_PORT")
        ib=$(iptables -L "$ci" -n -v -x 2>/dev/null | awk 'NR==3{print $2+0}')
        ob=$(iptables -L "$co" -n -v -x 2>/dev/null | awk 'NR==3{print $2+0}')
        printf '  %-3s %-14s :%-5s %s\n' "$N_ID" "${N_REMARK}" "$N_PORT" \
            "$(human_bytes $(( ${ib:-0} + ${ob:-0} )))"
    done

    hr
    kv "本月合计" "$(human_bytes "${traffic_bytes_total:-0}")"
    local lim="${traffic_limit_gb:-0}"
    if (( lim > 0 )); then
        local lb=$(( lim * 1024 * 1024 * 1024 ))
        local used="${traffic_bytes_total:-0}"
        local pct=$(( used * 100 / lb )); (( pct > 100 )) && pct=100
        kv "月度上限" "${lim} GB"
        kv "使用进度" "${pct}%"
        [[ "${traffic_exceeded:-false}" == "true" ]] && \
            printf '  %s⚠ 已超限，服务已停止，月初自动恢复%s\n' "$RED" "$NC"
    else
        kv "月度上限" "不限制"
    fi
    hr
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        if (b < 1024) printf "%d B", b
        else if (b < 1048576) printf "%.1f KB", b/1024
        else if (b < 1073741824) printf "%.2f MB", b/1048576
        else printf "%.2f GB", b/1073741824
    }'
}

# ═══════════════════════════════════════════════════════════════════════════
#  12. 客户端链接
# ═══════════════════════════════════════════════════════════════════════════

node_host() {
    cfg_load
    if [[ "$N_MODE" == ws ]]; then printf '%s' "${N_DOMAIN:-${N_SNI}}"
    else printf '%s' "$(cfg_get server_ip)"; fi
}

_urlesc() { jq -rn --arg s "$1" '$s|@uri'; }

node_link() {
    local id="$1"
    node_load "$id" || return 1
    local host; host=$(node_host)
    local tag; tag=$(printf '%s' "${N_REMARK}" | sed 's/ /_/g')
    local tagq; tagq=$(_urlesc "$tag")

    case "$N_PROTO" in
    vless)
        if [[ "$N_MODE" == reality ]]; then
            printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s' \
                "$N_UUID" "$host" "$N_PORT" "$N_SNI" "$N_PUB" "$N_SID" "$tagq"
        else
            local p; p=$(_urlesc "$N_PATH")
            printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#%s' \
                "$N_UUID" "$host" "$N_PORT" "$N_DOMAIN" "$N_DOMAIN" "$p" "$tagq"
        fi
        ;;
    vmess)
        local obj
        if [[ "$N_MODE" == ws ]]; then
            obj=$(jq -cn --arg ps "$N_REMARK" --arg add "$host" --arg port "$N_PORT" \
                        --arg id "$N_UUID" --arg host "$N_DOMAIN" --arg path "$N_PATH" \
                '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",
                  net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$host}')
        else
            obj=$(jq -cn --arg ps "$N_REMARK" --arg add "$host" --arg port "$N_PORT" \
                        --arg id "$N_UUID" \
                '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",
                  net:"tcp",type:"none",host:"",path:"",tls:""}')
        fi
        printf 'vmess://%s' "$(printf '%s' "$obj" | base64 -w0)"
        ;;
    trojan)
        if [[ "$N_MODE" == reality ]]; then
            printf 'trojan://%s@%s:%s?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
                "$N_PASS" "$host" "$N_PORT" "$N_SNI" "$N_PUB" "$N_SID" "$tagq"
        else
            local p; p=$(_urlesc "$N_PATH")
            printf 'trojan://%s@%s:%s?security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
                "$N_PASS" "$host" "$N_PORT" "$N_DOMAIN" "$N_DOMAIN" "$p" "$tagq"
        fi
        ;;
    ss)
        local cred; cred=$(printf '%s:%s' "$N_METHOD" "$N_PASS" | base64 -w0 | tr -d '=' | tr '+/' '-_')
        printf 'ss://%s@%s:%s#%s' "$cred" "$host" "$N_PORT" "$tagq"
        ;;
    socks)
        printf 'socks://%s:%s@%s:%s#%s' \
            "$(_urlesc "$N_USER")" "$(_urlesc "$N_PASS")" "$host" "$N_PORT" "$tagq"
        ;;
    http)
        printf 'http://%s:%s@%s:%s#%s' \
            "$(_urlesc "$N_USER")" "$(_urlesc "$N_PASS")" "$host" "$N_PORT" "$tagq"
        ;;
    hysteria2)
        printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1#%s' \
            "$N_PASS" "$host" "$N_PORT" "$N_SNI" "$tagq"
        ;;
    tuic)
        printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=1#%s' \
            "$N_UUID" "$N_PASS" "$host" "$N_PORT" "$N_SNI" "$tagq"
        ;;
    anytls)
        printf 'anytls://%s@%s:%s?sni=%s&insecure=1#%s' \
            "$N_PASS" "$host" "$N_PORT" "$N_SNI" "$tagq"
        ;;
    wireguard)
        cat <<EOF
[Interface]
PrivateKey = ${N_WG_CLI_PRIV}
Address = ${N_WG_IP}
DNS = 1.1.1.1

[Peer]
PublicKey = ${N_WG_PUB}
Endpoint = ${host}:${N_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
EOF
        ;;
    esac
}

node_show() {
    local id="${1:-}"; [[ -n "$id" ]] || return 1
    node_load "$id" || { warn "节点不存在"; return 1; }
    cfg_load
    local host; host=$(node_host)

    echo ""; hr
    printf '%s  节点 %s — %s%s\n' "$BOLD" "$N_ID" "$N_REMARK" "$NC"; hr
    kv "协议"   "$(proto_rank_name "$N_PROTO")"
    kv "模式"   "$N_MODE"
    kv "状态"   "$([[ "$N_ENABLED" == true ]] && echo '启用' || echo '停用')"
    kv "地址"   "$host"
    kv "端口"   "$N_PORT"
    [[ "$N_MODE" == ws ]] && kv "核心端口" "127.0.0.1:${N_LOCAL_PORT}"
    [[ -n "$N_DOMAIN" ]] && kv "域名" "$N_DOMAIN"
    [[ -n "$N_PATH" ]] && kv "路径" "$N_PATH"
    [[ -n "$N_SNI" && "$N_MODE" != ws ]] && kv "SNI" "$N_SNI"
    [[ -n "$N_UUID" && "$N_PROTO" != wireguard ]] && kv "UUID" "$N_UUID"
    [[ -n "$N_PASS" ]] && kv "密码" "$N_PASS"
    [[ -n "$N_USER" && ( "$N_PROTO" == socks || "$N_PROTO" == http ) ]] && kv "用户名" "$N_USER"
    [[ "$N_MODE" == reality ]] && { kv "公钥 pbk" "$N_PUB"; kv "Short ID" "$N_SID"; }

    hr
    printf '%s  链接：%s\n' "$YELLOW" "$NC"
    local link; link=$(node_link "$id")
    printf '%s\n\n' "$GREEN$link$NC"
    if command -v qrencode >/dev/null && [[ "$N_PROTO" != wireguard ]]; then
        qrencode -t ansiutf8 "$link" 2>/dev/null
    fi
    hr
}

node_list() {
    local ids; ids=$(node_ids)
    if [[ -z "$ids" ]]; then warn "暂无节点，选择「1」新建"; return; fi
    echo ""; hr
    printf '  %s %s %s %s %s %s\n' "$(pad ID 4)" "$(pad 备注 20)" "$(pad 协议 13)" \
        "$(pad 模式 9)" "$(pad 端口 7)" "状态"
    hr
    local id
    for id in $ids; do
        node_load "$id" || continue
        printf '  %s %s %s %s %s %s\n' \
            "$(pad "$N_ID" 4)" "$(pad "$N_REMARK" 20)" "$(pad "$(proto_rank_name "$N_PROTO")" 13)" \
            "$(pad "$N_MODE" 9)" "$(pad "$N_PORT" 7)" \
            "$([[ "$N_ENABLED" == true ]] && echo "${GREEN}启用${NC}" || echo "${DIM}停用${NC}")"
    done
    hr
}

node_toggle() {
    local id; id=$(ask "节点 ID")
    node_load "$id" || die "节点 $id 不存在"
    if [[ "$N_ENABLED" == true ]]; then N_ENABLED=false; else N_ENABLED=true; fi
    node_save
    local st; [[ "$N_ENABLED" == true ]] && st="启用" || st="停用"
    info "节点 ${id} 已${st}"
    apply_all
}

node_remove() {
    local id; id=$(ask "节点 ID")
    node_load "$id" || die "节点 $id 不存在"
    kv "备注" "$N_REMARK"; kv "协议" "$(proto_rank_name "$N_PROTO")"
    confirm "确认删除节点 ${id}?" n || { info "已取消"; return; }
    node_delete "$id"
    apply_all
}

# ═══════════════════════════════════════════════════════════════════════════
#  13. 假站点 / 防火墙 / BBR
# ═══════════════════════════════════════════════════════════════════════════

setup_fake_web() {
    mkdir -p "$FAKE_WEBROOT"
    cat >"${FAKE_WEBROOT}/index.html" <<'HTMLEOF'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>Welcome to nginx!</title>
<style>body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f2f5;margin:0;
display:flex;align-items:center;justify-content:center;min-height:100vh}
.c{background:#fff;border-radius:10px;box-shadow:0 4px 20px rgba(0,0,0,.08);
padding:60px 80px;text-align:center;max-width:520px}
h1{color:#1a1a2e;font-size:2rem;margin:0 0 12px}p{color:#666;line-height:1.7}
hr{border:none;border-top:1px solid #eee;margin:20px 0}
.s{font-size:.8rem;color:#aaa}</style></head>
<body><div class="c"><h1>Welcome to nginx!</h1><hr>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>
<hr><p class="s">nginx/1.24.0</p></div></body></html>
HTMLEOF
}

setup_firewall() {
    local ports=() id
    for id in $(node_ids); do
        node_load "$id" || continue
        [[ "$N_ENABLED" == true ]] && ports+=("$N_PORT")
    done
    local cport; cport=$(cfg_get caddy_port)
    [[ -n "$cport" ]] && ports+=("$cport")
    (( ${#ports[@]} )) || { warn "无启用节点，跳过防火墙"; return; }

    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active; then
        for p in "${ports[@]}"; do ufw allow "$p"/tcp >/dev/null 2>&1; ufw allow "$p"/udp >/dev/null 2>&1; done
        info "ufw 已放行: ${ports[*]}"
        return
    fi
    for p in "${ports[@]}"; do
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
        iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
        if command -v ip6tables >/dev/null; then
            ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT
            ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$p" -j ACCEPT
        fi
    done
    info "iptables 已放行: ${ports[*]}"
}

enable_bbr() {
    [[ "$OS_ID" == alpine ]] && { warn "Alpine 内核通常无 BBR"; return; }
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr ]]; then
        info "BBR 已启用"; return
    fi
    modprobe tcp_bbr 2>/dev/null || true
    echo tcp_bbr >/etc/modules-load.d/vless-bbr.conf 2>/dev/null || true
    cat >/etc/sysctl.d/99-vless-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || true
    info "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
}

# ═══════════════════════════════════════════════════════════════════════════
#  14. 中转 / 链式出站
# ═══════════════════════════════════════════════════════════════════════════

relay_menu() {
    cfg_load
    local mode; mode=$(cfg_get relay_mode); mode="${mode:-none}"
    echo ""; hr; printf '%s  中转 / 链式出站%s\n' "$BOLD" "$NC"; hr
    if [[ "$mode" == chain ]]; then
        printf '  状态: %s已启用（全部流量走 VLESS+Reality 上游）%s\n' "$GREEN" "$NC"
        kv "上游" "$(cfg_get relay_host):$(cfg_get relay_port)"
        kv "SNI"  "$(cfg_get relay_sni)"
    else
        printf '  状态: %s未启用（直连出站）%s\n' "$YELLOW" "$NC"
    fi
    hr
    echo "  1) 配置并启用"
    echo "  2) 关闭"
    echo "  0) 返回"
    local c; c=$(ask "选择" "0")
    case "$c" in
        1)
            local h p sni uuid pbk sid
            h=$(ask "上游地址（IP 或域名）")
            p=$(ask "上游端口" "443")
            sno=$(ask "上游 SNI（Reality 伪装域名）" "www.apple.com")
            uuid=$(ask "上游 UUID")
            pbk=$(ask "上游公钥 pbk")
            sid=$(ask "上游 Short ID")
            cfg_set relay_mode chain
            cfg_set relay_host "$h"
            cfg_set relay_port "$p"
            cfg_set relay_sni "$sno"
            cfg_set relay_uuid "$uuid"
            cfg_set relay_public_key "$pbk"
            cfg_set relay_short_id "$sid"
            apply_all && info "中转已启用"
            ;;
        2)
            cfg_set relay_mode none
            apply_all && info "已关闭中转"
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
#  15. 全局设置 / 服务管理 / 日志
# ═══════════════════════════════════════════════════════════════════════════

settings_menu() {
    cfg_load
    while true; do
        echo ""; hr; printf '%s  全局设置%s\n' "$BOLD" "$NC"; hr
        kv "代理核心" "${core_type:-singbox}"
        kv "服务器 IP" "$(cfg_get server_ip)"
        kv "Caddy 端口" "$(cfg_get caddy_port)"
        kv "证书邮箱" "$(cfg_get email || echo '未设置')"
        kv "月度限额" "$( [ "$(cfg_get traffic_limit_gb)" -gt 0 ] 2>/dev/null && echo "$(cfg_get traffic_limit_gb) GB" || echo '不限制')"
        hr
        echo "  1) 切换核心（Xray / sing-box）"
        echo "  2) 设置证书邮箱"
        echo "  3) 设置 Caddy 端口"
        echo "  4) 设置月度流量限额"
        echo "  5) 重新检测公网 IP"
        echo "  0) 返回"
        local c; c=$(ask "选择" "0")
        case "$c" in
            1)
                local n; n=$(ask "1=Xray 2=sing-box" "2")
                if [[ "$n" == 1 ]]; then
                    local id
                    for id in $(node_ids); do
                        node_load "$id"; xray_supported "$N_PROTO" || {
                            warn "节点 ${N_ID}（$N_PROTO）不被 Xray 支持，请先删除"; return; }
                    done
                    cfg_set core_type xray; ensure_core xray
                else
                    cfg_set core_type singbox; ensure_core singbox
                fi
                apply_all
                ;;
            2) cfg_set email "$(ask "邮箱（Let's Encrypt 通知）")" ;;
            3) cfg_set caddy_port "$(ask "Caddy 监听端口" "443")" ;;
            4) cfg_set traffic_limit_gb "$(ask "月度限额 GB（0=不限）" "0")" ;;
            5) cfg_set server_ip "$(detect_public_ip)"; info "IP: $(cfg_get server_ip)" ;;
            0) return ;;
        esac
    done
}

service_menu() {
    cfg_load
    local s; s=$([[ "${core_type:-singbox}" == singbox ]] && echo sing-box || echo xray)
    echo ""; hr; printf '%s  服务管理%s\n' "$BOLD" "$NC"; hr
    svc_active "$s" && printf '  %-10s %s运行中%s\n' "$s" "$GREEN" "$NC" \
                    || printf '  %-10s %s已停止%s\n' "$s" "$RED" "$NC"
    if command -v caddy >/dev/null; then
        svc_active caddy && printf '  %-10s %s运行中%s\n' caddy "$GREEN" "$NC" \
                         || printf '  %-10s %s已停止%s\n' caddy "$RED" "$NC"
    fi
    hr
    local id
    for id in $(node_ids); do
        node_load "$id" || continue
        if ss -ltnu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${N_PORT}$"; then
            printf '  :%-6s %s✓%s %s (%s)\n' "$N_PORT" "$GREEN" "$NC" "$N_REMARK" "$N_PROTO"
        else
            printf '  :%-6s %s✗%s %s (%s)\n' "$N_PORT" "$RED" "$NC" "$N_REMARK" "$N_PROTO"
        fi
    done
    hr
    echo "  1) 重启核心  2) 重启 Caddy  3) 全部重启  4) 停止全部  0) 返回"
    local c; c=$(ask "选择" "0")
    case "$c" in
        1) svc restart "$s" && info "已重启" ;;
        2) svc restart caddy ;;
        3) svc restart "$s"; svc restart caddy ;;
        4) svc stop "$s"; svc stop caddy ;;
    esac
}

show_logs() {
    cfg_load
    local s; s=$([[ "${core_type:-singbox}" == singbox ]] && echo sing-box || echo xray)
    echo "  1) 核心日志  2) Caddy 日志  3) 脚本日志  0) 返回"
    local c; c=$(ask "选择" "1")
    case "$c" in
        1) [[ "$INIT_SYS" == systemd ]] && journalctl -u "$s" -n 60 --no-pager || tail -60 "/var/log/${s}.log" ;;
        2) [[ "$INIT_SYS" == systemd ]] && journalctl -u caddy -n 60 --no-pager || tail -60 /var/log/caddy.log ;;
        3) tail -60 "$LOG_FILE" 2>/dev/null || warn "暂无日志" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
#  16. 安装 / 卸载
# ═══════════════════════════════════════════════════════════════════════════

do_install() {
    echo ""
    printf '%s%s╔══════════════════════════════════════════════════════════╗%s\n' "$CYAN" "$BOLD" "$NC"
    printf '%s%s║        SingBox Go v4.0 — 安装向导            ║%s\n' "$CYAN" "$BOLD" "$NC"
    printf '%s%s╚══════════════════════════════════════════════════════════╝%s\n' "$CYAN" "$BOLD" "$NC"

    install_deps
    cfg_init

    echo ""
    echo "  代理核心："
    echo "    1) sing-box   （推荐，支持全部 10 种协议）"
    echo "    2) Xray-core  （仅 VLESS/VMess/Trojan/SS/SOCKS/HTTP）"
    local c; c=$(ask "选择" "1")
    local core; [[ "$c" == 2 ]] && core=xray || core=singbox
    cfg_set core_type "$core"
    ensure_core "$core"

    cfg_set server_ip "$(detect_public_ip)"
    [[ -n "$(cfg_get server_ip)" ]] || warn "未检测到公网 IP，稍后可在全局设置中修正"

    local em; em=$(ask "证书邮箱（WS 节点申请 Let's Encrypt 用，可留空）" "")
    [[ -n "$em" ]] && cfg_set email "$em"

    local cp; cp=$(ask "Caddy 对外 HTTPS 端口" "443")
    cfg_set caddy_port "$cp"

    local tg; tg=$(ask "月度流量限额 GB（0 = 不限制）" "0")
    cfg_set traffic_limit_gb "${tg:-0}"

    confirm "启用 BBR 加速?" y && enable_bbr

    setup_fake_web
    setup_shortcut
    setup_firewall || true

    info "基础环境就绪，接下来创建第一个节点"
    node_new
}

setup_shortcut() {
    local self; self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    [[ "$self" != "$SHORTCUT" ]] && { cp "$self" "$SHORTCUT"; chmod +x "$SHORTCUT"; info "快捷命令: singbox-go"; }
}

do_uninstall() {
    confirm "确认卸载（保留节点配置备份）?" n || { info "已取消"; return; }
    cfg_load
    local s; s=$([[ "${core_type:-singbox}" == singbox ]] && echo sing-box || echo xray)
    svc stop "$s" 2>/dev/null || true
    svc stop caddy 2>/dev/null || true
    rm -f "/etc/systemd/system/${s}.service" "/etc/init.d/${s}" 2>/dev/null
    [[ "$INIT_SYS" == systemd ]] && systemctl daemon-reload
    rm -f "$XRAY_BIN" "$SBOX_BIN" "$SHORTCUT"
    rm -f /etc/cron.d/singbox-go
    sed -i '/singbox-go/d' /etc/crontabs/root 2>/dev/null || true
    local id
    for id in $(node_ids); do
        node_load "$id"; iptables -D INPUT -p tcp --dport "$N_PORT" -j "$(_chain_name "$N_PORT")" 2>/dev/null || true
        iptables -F "$(_chain_name "$N_PORT")" 2>/dev/null; iptables -X "$(_chain_name "$N_PORT")" 2>/dev/null
        iptables -F "$(_output_chain_name "$N_PORT")" 2>/dev/null; iptables -X "$(_output_chain_name "$N_PORT")" 2>/dev/null
    done
    local backup="/root/singbox-go-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$backup" -C /etc singbox-go 2>/dev/null
    rm -rf "$CONF_DIR" "$XRAY_CONF_DIR" "$SBOX_CONF_DIR" "$FAKE_WEBROOT"
    info "卸载完成，备份: $backup"
}

purge_all() {
    confirm "彻底清除所有残留（含节点与证书）?" n || { info "已取消"; return; }
    do_uninstall
    rm -rf "$CONF_DIR"
    info "已清空"
}

# ═══════════════════════════════════════════════════════════════════════════
#  17. 主菜单
# ═══════════════════════════════════════════════════════════════════════════

banner() {
    cfg_load
    echo ""
    printf '%s%s╔══════════════════════════════════════════════════════════╗%s\n' "$CYAN" "$BOLD" "$NC"
    printf '%s%s║   SingBox Go  v4.0   (SSH Only / no panel)   ║%s\n' "$CYAN" "$BOLD" "$NC"
    printf '%s%s╚══════════════════════════════════════════════════════════╝%s\n' "$CYAN" "$BOLD" "$NC"

    if [[ -f "$CONF_FILE" ]]; then
        local s; s=$([[ "${core_type:-singbox}" == singbox ]] && echo sing-box || echo xray)
        local st; svc_active "$s" && st="${GREEN}运行中${NC}" || st="${RED}已停止${NC}"
        printf '  核心: %s%s%s   节点: %s   状态: %b\n' "$CYAN" "$s" "$NC" "$(node_count)" "$st"
        printf '  IP: %s   Caddy 端口: %s\n' "$(cfg_get server_ip)" "$(cfg_get caddy_port)"
    else
        printf '  %s尚未安装%s\n' "$YELLOW" "$NC"
    fi
}

main_menu() {
    while true; do
        banner
        hr
        echo "  1) 新建节点"
        echo "  2) 节点列表"
        echo "  3) 查看节点 / 链接"
        echo "  4) 启用 / 停用节点"
        echo "  5) 删除节点"
        echo "  6) 全部链接"
        echo "  7) 流量统计"
        echo "  8) 中转 / 链式出站"
        echo "  9) 服务管理"
        echo " 10) 全局设置"
        echo " 11) 查看日志"
        echo " 12) 重装 / 重建配置"
        echo " 13) 卸载"
        echo "  0) 退出"
        hr
        local c; c=$(ask "请选择" "0")
        case "$c" in
            1)  node_new ;;
            2)  node_list; pause_ ;;
            3)  node_list; local id; id=$(ask "节点 ID" "1"); node_show "$id"; pause_ ;;
            4)  node_list; node_toggle; pause_ ;;
            5)  node_list; node_remove; pause_ ;;
            6)  for i in $(node_ids); do node_show "$i"; done; pause_ ;;
            7)  show_traffic; pause_ ;;
            8)  relay_menu; pause_ ;;
            9)  service_menu; pause_ ;;
            10) settings_menu ;;
            11) show_logs; pause_ ;;
            12) do_install ;;
            13) do_uninstall; pause_ ;;
            0)  printf '  再见\n'; exit 0 ;;
            *)  warn "无效选项" ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════
#  18. 入口
# ═══════════════════════════════════════════════════════════════════════════

usage() {
    cat <<EOF
SingBox Go v4.0 — SSH Only

用法:
  singbox-go                 交互式菜单
  singbox-go list            列出节点
  singbox-go show <id>       查看节点与链接
  singbox-go link <id>       只输出链接（可管道）
  singbox-go add             新建节点
  singbox-go del <id>        删除节点
  singbox-go on <id>         启用节点
  singbox-go off <id>        停用节点
  singbox-go apply           重建并校验配置后重启
  singbox-go status          服务与端口状态
  singbox-go traffic         流量统计
  singbox-go logs [core|caddy]
  singbox-go uninstall       卸载
EOF
}

main() {
    check_root
    detect_os

    local cmd="${1:-menu}"
    case "$cmd" in
        menu)      cfg_init; main_menu ;;
        --help|-h|help) usage ;;
        list)      node_list ;;
        show)      node_show "${2:?需要节点 ID}" ;;
        link)      node_link "${2:?需要节点 ID}"; echo ;;
        add)       node_new ;;
        del)       node_remove ;;
        on)        node_load "${2:?需要节点 ID}" || die "节点不存在"
                   N_ENABLED=true; node_save; apply_all ;;
        off)       node_load "${2:?需要节点 ID}" || die "节点不存在"
                   N_ENABLED=false; node_save; apply_all ;;
        apply)     apply_all ;;
        status)    service_menu </dev/null ;;
        traffic)   show_traffic ;;
        logs)      show_logs ;;
        uninstall) do_uninstall ;;
        *)         usage ;;
    esac
}

main "$@"
