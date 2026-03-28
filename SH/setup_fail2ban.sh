#!/bin/sh
# =============================================================================
# Fail2ban 一键安装配置脚本
# 支持系统：Debian/Ubuntu、Alpine Linux
# 功能：自动检测依赖、日志路径、防火墙类型，生成保守的 fail2ban 配置
# =============================================================================
# wget -O setup_fail2ban.sh https://raw.githubusercontent.com/SuzukiRenz/ScriptHub/refs/heads/main/SH/setup_fail2ban.sh && chmod +x setup_fail2ban.sh && ./setup_fail2ban.sh

set -e

# ─────────────────────────────────────────────
# 颜色输出
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "${CYAN}[信息]${NC} %s\n" "$1"; }
success() { printf "${GREEN}[成功]${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}[警告]${NC} %s\n" "$1"; }
error()   { printf "${RED}[错误]${NC} %s\n" "$1"; exit 1; }
step()    { printf "\n${BOLD}${BLUE}━━━ %s ━━━${NC}\n" "$1"; }
ask()     { printf "${YELLOW}[?]${NC} %s " "$1"; }

# ─────────────────────────────────────────────
# 必须以 root 运行
# ─────────────────────────────────────────────
[ "$(id -u)" -ne 0 ] && error "请以 root 用户运行此脚本（或使用 sudo）"

# ─────────────────────────────────────────────
# 检测操作系统
# ─────────────────────────────────────────────
step "检测操作系统"

OS=""
PKG_MGR=""
SVC_CMD=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        debian|ubuntu|raspbian)
            OS="debian"
            PKG_MGR="apt-get"
            SVC_CMD="systemctl"
            ;;
        alpine)
            OS="alpine"
            PKG_MGR="apk"
            SVC_CMD="rc-service"
            ;;
        *)
            # 尝试兼容基于 Debian 的衍生版
            if [ -f /etc/debian_version ]; then
                OS="debian"
                PKG_MGR="apt-get"
                SVC_CMD="systemctl"
                warn "检测到类 Debian 系统（$PRETTY_NAME），尝试以 Debian 模式继续"
            else
                error "不支持的系统：$PRETTY_NAME。本脚本仅支持 Debian/Ubuntu 和 Alpine。"
            fi
            ;;
    esac
else
    error "无法读取 /etc/os-release，无法识别操作系统"
fi

info "操作系统：${PRETTY_NAME:-$OS}"
info "包管理器：$PKG_MGR"

# ─────────────────────────────────────────────
# 辅助函数
# ─────────────────────────────────────────────
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

pkg_installed() {
    case "$OS" in
        debian) dpkg -l "$1" 2>/dev/null | grep -q "^ii"; ;;
        alpine) apk info -e "$1" 2>/dev/null; ;;
    esac
}

install_pkg() {
    info "正在安装：$1"
    case "$OS" in
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" >/dev/null 2>&1 \
                && success "已安装 $1" || error "安装 $1 失败"
            ;;
        alpine)
            apk add --no-cache "$1" >/dev/null 2>&1 \
                && success "已安装 $1" || error "安装 $1 失败"
            ;;
    esac
}

svc_enable() {
    case "$OS" in
        debian) systemctl enable "$1" >/dev/null 2>&1 ;;
        alpine) rc-update add "$1" default >/dev/null 2>&1 ;;
    esac
}

svc_restart() {
    case "$OS" in
        debian) systemctl restart "$1" >/dev/null 2>&1 ;;
        alpine) rc-service "$1" restart >/dev/null 2>&1 ;;
    esac
}

svc_status() {
    case "$OS" in
        debian) systemctl is-active "$1" 2>/dev/null ;;
        alpine) rc-service "$1" status 2>/dev/null | grep -q started && echo "active" || echo "inactive" ;;
    esac
}

prompt_yn() {
    # $1=问题  $2=默认(y/n)
    _default="${2:-y}"
    ask "$1 [$([ "$_default" = "y" ] && echo 'Y/n' || echo 'y/N')]:"
    read -r _ans
    _ans="${_ans:-$_default}"
    case "$_ans" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ─────────────────────────────────────────────
# 更新包列表
# ─────────────────────────────────────────────
step "更新软件包列表"
case "$OS" in
    debian)
        info "运行 apt-get update ..."
        apt-get update -qq >/dev/null 2>&1 && success "包列表已更新" || warn "apt-get update 失败，继续尝试"
        ;;
    alpine)
        info "运行 apk update ..."
        apk update >/dev/null 2>&1 && success "包列表已更新" || warn "apk update 失败，继续尝试"
        ;;
esac

# ─────────────────────────────────────────────
# 检测并安装 fail2ban
# ─────────────────────────────────────────────
step "检测 fail2ban"

F2B_INSTALLED=0
if cmd_exists fail2ban-client; then
    F2B_VER=$(fail2ban-client --version 2>/dev/null | head -1 | awk '{print $2}')
    success "fail2ban 已安装，版本：${F2B_VER:-未知}"
    F2B_INSTALLED=1
else
    warn "未检测到 fail2ban"
    if prompt_yn "是否立即安装 fail2ban？" "y"; then
        install_pkg "fail2ban"
        F2B_INSTALLED=1
    else
        error "fail2ban 未安装，脚本退出"
    fi
fi

# ─────────────────────────────────────────────
# 检测当前 SSH 连接端口（UFW 安全放行用）
# ─────────────────────────────────────────────

# 方法1：从当前 SSH 会话环境变量读取（最可靠）
detect_ssh_port() {
    _port=""

    # $SSH_CLIENT = "客户端IP 客户端端口 服务器端口"
    if [ -n "$SSH_CLIENT" ]; then
        _port=$(echo "$SSH_CLIENT" | awk '{print $3}')
    fi

    # $SSH_CONNECTION = "客户端IP 客户端端口 服务器IP 服务器端口"
    if [ -z "$_port" ] && [ -n "$SSH_CONNECTION" ]; then
        _port=$(echo "$SSH_CONNECTION" | awk '{print $4}')
    fi

    # 方法2：从 sshd_config 读取 Port 指令
    if [ -z "$_port" ]; then
        for _cfg in /etc/ssh/sshd_config /etc/sshd_config; do
            if [ -f "$_cfg" ]; then
                _port=$(grep -i "^Port " "$_cfg" 2>/dev/null | awk '{print $2}' | head -1)
                [ -n "$_port" ] && break
            fi
        done
    fi

    # 方法3：从 ss/netstat 检测 sshd 监听端口
    if [ -z "$_port" ] && cmd_exists ss; then
        _port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | grep -o '[0-9]*$' | head -1)
    fi

    # 兜底默认值
    echo "${_port:-22}"
}

# ─────────────────────────────────────────────
# 安全启用 UFW（先放行 SSH 再 enable）
# ─────────────────────────────────────────────
safe_enable_ufw() {
    # ── 第一步：探测 SSH 端口 ──────────────────
    _detected_port=$(detect_ssh_port)
    printf "\n"
    printf "${YELLOW}┌─────────────────────────────────────────────────┐${NC}\n"
    printf "${YELLOW}│  ⚠️  UFW 安全检查 — 防止 SSH 连接被锁门         │${NC}\n"
    printf "${YELLOW}└─────────────────────────────────────────────────┘${NC}\n"
    info "自动检测到 SSH 端口：${BOLD}${_detected_port}${NC}"
    ask "请确认/修改 SSH 端口（直接回车使用检测值 ${_detected_port}）:"
    read -r _confirm_port
    SSH_FW_PORT="${_confirm_port:-$_detected_port}"

    # ── 第二步：展示将要执行的操作，二次确认 ──
    printf "\n"
    info "UFW 启用前将执行以下操作："
    printf "  ${CYAN}①${NC} ufw allow ${SSH_FW_PORT}/tcp   ${YELLOW}# 放行 SSH 端口，防止断线${NC}\n"
    printf "  ${CYAN}②${NC} ufw default deny incoming      ${YELLOW}# 默认拒绝所有入站${NC}\n"
    printf "  ${CYAN}③${NC} ufw default allow outgoing     ${YELLOW}# 默认允许所有出站${NC}\n"
    printf "  ${CYAN}④${NC} ufw --force enable             ${YELLOW}# 启用 UFW${NC}\n"
    printf "\n"
    warn "启用后，除 SSH(${SSH_FW_PORT}) 外所有入站端口将被拒绝，请确认其他服务端口已放行！"
    printf "\n"

    # 询问是否还有其他需要放行的端口
    ask "是否需要额外放行其他端口？（留空跳过，多个用空格分隔，例: 80 443 8080）:"
    read -r _extra_ports

    # 再次确认
    printf "\n"
    if ! prompt_yn "确认以上操作无误，现在启用 UFW？" "n"; then
        warn "已取消 UFW 启用。切换为 iptables 模式继续..."
        install_pkg "iptables"
        HAS_IPTABLES=1
        return 1
    fi

    # ── 第三步：按顺序安全执行 ────────────────
    # 先放行 SSH，绝对第一步
    ufw allow "${SSH_FW_PORT}/tcp" comment 'SSH - added by setup_fail2ban.sh' >/dev/null 2>&1
    success "已放行 SSH 端口：${SSH_FW_PORT}/tcp"

    # 放行额外端口
    if [ -n "$_extra_ports" ]; then
        for _p in $_extra_ports; do
            ufw allow "$_p" comment 'Extra - added by setup_fail2ban.sh' >/dev/null 2>&1
            success "已放行额外端口：$_p"
        done
    fi

    # 设置默认策略
    ufw default deny incoming  >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # 最后才 enable
    ufw --force enable >/dev/null 2>&1
    success "UFW 已启用，当前规则："
    ufw status numbered 2>/dev/null | head -20
    return 0
}

# ─────────────────────────────────────────────
# 检测防火墙后端
# ─────────────────────────────────────────────
step "检测防火墙后端"

BANACTION="iptables-multiport"   # 默认
BANACTION_ALLPORTS="iptables-allports"
SSH_FW_PORT="22"   # 供摘要显示用，safe_enable_ufw 内会更新

HAS_UFW=0
HAS_IPTABLES=0
HAS_NFTABLES=0

if cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    HAS_UFW=1
    info "检测到 UFW 已启用（active）"
elif cmd_exists ufw; then
    info "检测到 UFW 已安装但未启用"
fi

if cmd_exists iptables; then
    HAS_IPTABLES=1
    info "检测到 iptables：$(iptables --version 2>/dev/null | head -1)"
fi

if cmd_exists nft; then
    HAS_NFTABLES=1
    info "检测到 nftables：$(nft --version 2>/dev/null | head -1)"
fi

# 选择 banaction
if [ "$HAS_UFW" -eq 1 ]; then
    # UFW 已经是 active 状态，直接使用
    BANACTION="ufw"
    BANACTION_ALLPORTS="ufw"
    success "防火墙后端：UFW（已激活）"
elif [ "$HAS_NFTABLES" -eq 1 ] && [ "$HAS_IPTABLES" -eq 0 ]; then
    BANACTION="nftables-multiport"
    BANACTION_ALLPORTS="nftables-allports"
    success "防火墙后端：nftables"
elif [ "$HAS_IPTABLES" -eq 1 ]; then
    success "防火墙后端：iptables"
else
    warn "未检测到任何已激活的防火墙工具（iptables / ufw / nftables）"
    printf "\n请选择要安装/启用的防火墙：\n"
    printf "  ${BOLD}1)${NC} iptables ${CYAN}（推荐）${NC}\n"
    printf "       安装后默认放行所有流量，fail2ban 动态追加封禁规则\n"
    printf "       ${GREEN}✓ 不会锁门，最安全的选择${NC}\n"
    printf "\n"
    printf "  ${BOLD}2)${NC} ufw ${YELLOW}（需谨慎）${NC}\n"
    printf "       启用后默认拒绝所有入站，脚本会自动检测 SSH 端口并先放行\n"
    printf "       ${YELLOW}⚠ 会展示操作预览并要求二次确认，防止锁门${NC}\n"
    printf "\n"
    printf "  ${BOLD}3)${NC} 跳过 ${RED}（仅记录，不封禁）${NC}\n"
    printf "       fail2ban 软封禁模式，触发时只写日志不实际阻断流量\n"
    printf "\n"
    ask "请输入选项 [1/2/3]（默认 1）:"
    read -r FW_CHOICE
    FW_CHOICE="${FW_CHOICE:-1}"
    case "$FW_CHOICE" in
        1)
            install_pkg "iptables"
            HAS_IPTABLES=1
            # iptables 安装后默认 ACCEPT，无需额外操作
            success "iptables 已安装，默认策略 ACCEPT，不影响现有连接"
            ;;
        2)
            # UFW 可能已安装但未激活，也可能需要安装
            if ! cmd_exists ufw; then
                install_pkg "ufw"
            fi
            # 安全启用（内部处理 SSH 放行 + 二次确认）
            if safe_enable_ufw; then
                HAS_UFW=1
                BANACTION="ufw"
                BANACTION_ALLPORTS="ufw"
            else
                # 用户取消 UFW，已在函数内切换到 iptables
                success "防火墙后端：iptables（UFW 取消后自动切换）"
            fi
            ;;
        3)
            warn "跳过防火墙安装，将使用软封禁模式（fail2ban 仅记录日志，不实际阻断）"
            BANACTION="dummy"
            BANACTION_ALLPORTS="dummy"
            ;;
        *)
            warn "无效选项，默认使用 iptables"
            install_pkg "iptables"
            HAS_IPTABLES=1
            ;;
    esac
fi

# ─────────────────────────────────────────────
# 检测日志路径
# ─────────────────────────────────────────────
step "检测服务日志路径"

# ---------- SSH ----------
detect_ssh_log() {
    # Debian/Ubuntu: /var/log/auth.log
    # Alpine/较新系统: journald 或 /var/log/messages
    for p in \
        /var/log/auth.log \
        /var/log/secure \
        /var/log/messages \
        /var/log/sshd.log; do
        if [ -f "$p" ]; then
            echo "$p"
            return
        fi
    done
    # journald 模式
    if cmd_exists journalctl; then
        echo "__journald__"
        return
    fi
    echo ""
}

SSH_LOG=$(detect_ssh_log)
SSH_BACKEND="auto"

if [ "$SSH_LOG" = "__journald__" ]; then
    info "SSH 日志：journald（systemd）"
    SSH_BACKEND="systemd"
    SSH_LOG=""
elif [ -n "$SSH_LOG" ]; then
    info "SSH 日志：$SSH_LOG"
else
    warn "未找到 SSH 日志文件"
fi

# ---------- NGINX ----------
NGINX_LOG=""
if cmd_exists nginx || [ -d /etc/nginx ]; then
    for p in \
        /var/log/nginx/error.log \
        /var/log/nginx/access.log \
        /usr/local/nginx/logs/error.log; do
        if [ -f "$p" ]; then
            NGINX_LOG="$p"
            break
        fi
    done
    # 尝试从 nginx 配置读取
    if [ -z "$NGINX_LOG" ] && cmd_exists nginx; then
        _log=$(nginx -T 2>/dev/null | grep -i 'error_log' | head -1 | awk '{print $2}' | tr -d ';')
        [ -f "$_log" ] && NGINX_LOG="$_log"
    fi
    if [ -n "$NGINX_LOG" ]; then
        info "Nginx 错误日志：$NGINX_LOG"
    else
        warn "未找到 Nginx 日志（Nginx 可能未运行或路径非默认）"
    fi
else
    info "未检测到 Nginx"
fi

# ---------- CADDY ----------
CADDY_LOG=""
if cmd_exists caddy || [ -d /etc/caddy ]; then
    for p in \
        /var/log/caddy/access.log \
        /var/log/caddy.log \
        /usr/local/var/log/caddy.log; do
        if [ -f "$p" ]; then
            CADDY_LOG="$p"
            break
        fi
    done
    if [ -n "$CADDY_LOG" ]; then
        info "Caddy 日志：$CADDY_LOG"
    else
        warn "未找到 Caddy 日志（Caddy 可能使用 journald 或自定义路径）"
    fi
else
    info "未检测到 Caddy"
fi

# ─────────────────────────────────────────────
# 检测现有 fail2ban 配置
# ─────────────────────────────────────────────
step "检测现有 fail2ban 配置"

F2B_CONF_DIR="/etc/fail2ban"
F2B_JAIL_LOCAL="$F2B_CONF_DIR/jail.local"
F2B_JAIL_CONF="$F2B_CONF_DIR/jail.conf"

EXISTING_CONFIG=0
if [ -f "$F2B_JAIL_LOCAL" ]; then
    warn "发现已有 jail.local 配置文件：$F2B_JAIL_LOCAL"
    EXISTING_CONFIG=1
    if prompt_yn "是否备份并覆盖现有 jail.local 配置？" "n"; then
        _bak="${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$F2B_JAIL_LOCAL" "$_bak"
        success "已备份到：$_bak"
    else
        info "保留现有配置，仅进行语法检查"
        SKIP_WRITE=1
    fi
fi

# ─────────────────────────────────────────────
# 用户自定义参数
# ─────────────────────────────────────────────
step "配置参数设定"

# 封禁时间
ask "封禁时长（秒，默认 3600 = 1小时，建议 86400 = 1天）:"
read -r BAN_TIME
BAN_TIME="${BAN_TIME:-3600}"

# 检测窗口
ask "检测时间窗口（秒，默认 600 = 10分钟内发生多次失败则封禁）:"
read -r FIND_TIME
FIND_TIME="${FIND_TIME:-600}"

# 最大失败次数
ask "最大允许失败次数（默认 5 次，保守建议 3 次）:"
read -r MAX_RETRY
MAX_RETRY="${MAX_RETRY:-5}"

# 邮件通知（可选）
DESTEMAIL=""
SENDEREMAIL=""
if prompt_yn "是否配置邮件封禁通知？" "n"; then
    ask "通知目标邮箱:"
    read -r DESTEMAIL
    ask "发件人邮箱:"
    read -r SENDEREMAIL
fi

# 白名单 IP
ask "白名单 IP（空格分隔，默认仅 127.0.0.1，例如: 192.168.1.0/24 10.0.0.1）:"
read -r WHITELIST_EXTRA
IGNOREIP="127.0.0.1/8 ::1 ${WHITELIST_EXTRA}"

# SSH 监控选项
ENABLE_SSH=1
if cmd_exists sshd || cmd_exists ssh; then
    if ! prompt_yn "是否启用 SSH 防暴力破解监控？" "y"; then
        ENABLE_SSH=0
    fi
fi

# Nginx 监控
ENABLE_NGINX=0
if [ -n "$NGINX_LOG" ]; then
    if prompt_yn "是否启用 Nginx 恶意扫描/错误监控？" "y"; then
        ENABLE_NGINX=1
    fi
fi

# Caddy 监控
ENABLE_CADDY=0
if [ -n "$CADDY_LOG" ]; then
    if prompt_yn "是否启用 Caddy 异常访问监控？" "y"; then
        ENABLE_CADDY=1
    fi
fi

# ─────────────────────────────────────────────
# 生成 jail.local 配置文件
# ─────────────────────────────────────────────
step "生成 fail2ban 配置"

if [ "${SKIP_WRITE:-0}" -ne 1 ]; then

    mkdir -p "$F2B_CONF_DIR"

    # 构建邮件 action 段
    if [ -n "$DESTEMAIL" ]; then
        ACTION_BLOCK="action = %(action_mwl)s"
        EMAIL_BLOCK="# 封禁事件邮件通知目标地址
destemail = ${DESTEMAIL}
# 通知邮件发件人
sender   = ${SENDEREMAIL:-fail2ban@localhost}
# 发送邮件工具（需系统安装 sendmail 或 msmtp）
mta      = sendmail"
    else
        ACTION_BLOCK="action = %(action_)s"
        EMAIL_BLOCK="# 未启用邮件通知（可设置 destemail 开启）"
    fi

    # SSH jail 段构建
    if [ "$ENABLE_SSH" -eq 1 ]; then
        if [ "$SSH_BACKEND" = "systemd" ]; then
            SSH_JAIL_BLOCK="[sshd]
# ── SSH 防暴力破解 ──────────────────────────────────────
# 监控 systemd journal 中的 sshd 日志
enabled  = true
# 使用 systemd journal 作为日志后端
backend  = systemd
# 匹配多次密码错误/非法用户登录
filter   = sshd
# 封禁触发后使用全端口封锁（更严格）
banaction = ${BANACTION_ALLPORTS}
# 单独覆盖：SSH 封禁时间更长（防持续扫描）
bantime  = 86400
maxretry = ${MAX_RETRY}"
        else
            _sshlog="${SSH_LOG:-/var/log/auth.log}"
            SSH_JAIL_BLOCK="[sshd]
# ── SSH 防暴力破解 ──────────────────────────────────────
enabled  = true
# SSH 认证日志路径
logpath  = ${_sshlog}
filter   = sshd
# SSH 封禁使用全端口封锁
banaction = ${BANACTION_ALLPORTS}
# SSH 单独设置较长封禁时间（24小时），防止持续扫描
bantime  = 86400
maxretry = ${MAX_RETRY}"
        fi
    else
        SSH_JAIL_BLOCK="# [sshd] 监控已禁用"
    fi

    # Nginx jail 段
    if [ "$ENABLE_NGINX" -eq 1 ]; then
        NGINX_JAIL_BLOCK="
[nginx-http-auth]
# ── Nginx HTTP 认证暴力破解 ─────────────────────────────
# 监控 Nginx basic-auth 失败（401 错误）
enabled  = true
logpath  = ${NGINX_LOG}
filter   = nginx-http-auth
maxretry = ${MAX_RETRY}

[nginx-botsearch]
# ── Nginx 恶意扫描器/爬虫 ───────────────────────────────
# 匹配扫描常见漏洞路径的请求（如 /wp-admin, /.env 等）
enabled  = true
logpath  = ${NGINX_LOG}
filter   = nginx-botsearch
# 扫描器封禁时间设为7天
bantime  = 604800
maxretry = 2

[nginx-limit-req]
# ── Nginx 请求频率限制超标 ──────────────────────────────
# 配合 nginx limit_req_zone 使用，封禁触发限流的 IP
enabled  = true
logpath  = ${NGINX_LOG}
filter   = nginx-limit-req
maxretry = 10"
    else
        NGINX_JAIL_BLOCK="# Nginx 监控未启用"
    fi

    # Caddy jail 段
    if [ "$ENABLE_CADDY" -eq 1 ]; then
        CADDY_JAIL_BLOCK="
[caddy-auth]
# ── Caddy 认证失败监控 ──────────────────────────────────
# 监控 Caddy 结构化 JSON 日志中的 4xx 认证错误
enabled  = true
logpath  = ${CADDY_LOG}
# 使用通用 HTTP 认证过滤器（Caddy 日志格式兼容）
filter   = caddy-auth
maxretry = ${MAX_RETRY}"
    else
        CADDY_JAIL_BLOCK="# Caddy 监控未启用"
    fi

    cat > "$F2B_JAIL_LOCAL" << JAILEOF
# =============================================================================
# /etc/fail2ban/jail.local — 本地自定义配置
# 由 setup_fail2ban.sh 脚本生成于 $(date '+%Y-%m-%d %H:%M:%S')
#
# 注意：请勿直接修改 jail.conf，所有本地覆盖均写在此文件中
# 生效优先级：jail.local > jail.d/ > jail.conf
# =============================================================================

[DEFAULT]
# ──────────────────────────────────────────────────────────────────────────────
# ❶ 白名单 IP / 网段（绝对不会被封禁）
# 格式：空格分隔，支持 CIDR，例如 192.168.1.0/24
# ──────────────────────────────────────────────────────────────────────────────
ignoreip = ${IGNOREIP}

# ──────────────────────────────────────────────────────────────────────────────
# ❷ 封禁时长（秒）
# 正数 = 固定秒数；-1 = 永久封禁（谨慎使用）
# 当前值：${BAN_TIME} 秒
# ──────────────────────────────────────────────────────────────────────────────
bantime  = ${BAN_TIME}

# ──────────────────────────────────────────────────────────────────────────────
# ❸ 检测时间窗口（秒）
# 在此时间窗口内累计失败次数超过 maxretry 才触发封禁
# 当前值：${FIND_TIME} 秒
# ──────────────────────────────────────────────────────────────────────────────
findtime = ${FIND_TIME}

# ──────────────────────────────────────────────────────────────────────────────
# ❹ 最大允许失败次数
# 保守建议：3～5 次；太低可能误封合法用户
# ──────────────────────────────────────────────────────────────────────────────
maxretry = ${MAX_RETRY}

# ──────────────────────────────────────────────────────────────────────────────
# ❺ 封禁动作（防火墙后端）
# iptables-multiport : 封禁特定端口（推荐）
# iptables-allports  : 封禁该 IP 所有流量
# ufw                : 通过 UFW 规则封禁
# nftables-multiport : 通过 nftables 封禁
# dummy              : 仅记录日志，不实际封禁（测试用）
# ──────────────────────────────────────────────────────────────────────────────
banaction = ${BANACTION}
banaction_allports = ${BANACTION_ALLPORTS}

# ──────────────────────────────────────────────────────────────────────────────
# ❻ 日志后端（auto 自动检测；systemd 用于 journald）
# ──────────────────────────────────────────────────────────────────────────────
backend = auto

# ──────────────────────────────────────────────────────────────────────────────
# ❼ 邮件通知配置
# ──────────────────────────────────────────────────────────────────────────────
${EMAIL_BLOCK}

# ──────────────────────────────────────────────────────────────────────────────
# ❽ 默认封禁动作策略
# %(action_)s      : 仅封禁，无通知（最轻量）
# %(action_mw)s   : 封禁 + 发邮件
# %(action_mwl)s  : 封禁 + 发邮件 + 附上相关日志行
# ──────────────────────────────────────────────────────────────────────────────
${ACTION_BLOCK}

# ──────────────────────────────────────────────────────────────────────────────
# ❾ 递增封禁时间（可选）
# 同一 IP 累计被封禁次数越多，封禁时间指数级增长
# 例：第2次封禁 = bantime * 2，第3次 = bantime * 4 ...
# ──────────────────────────────────────────────────────────────────────────────
# bantime.increment   = true
# bantime.rndtime     = 0
# bantime.maxtime     = 0
# bantime.factor      = 1
# bantime.formula     = ban.Time * (1<<(ban.Count if ban.Count<20 else 20)) * banFactor

# =============================================================================
# 各服务监控配置（Jail 定义）
# =============================================================================

${SSH_JAIL_BLOCK}
${NGINX_JAIL_BLOCK}
${CADDY_JAIL_BLOCK}

# =============================================================================
# 可扩展的服务 Jail 模板（取消注释以启用）
# =============================================================================

# [postfix]
# # ── Postfix 邮件服务防护 ─────────────────────────────────
# enabled  = true
# logpath  = /var/log/mail.log
# filter   = postfix
# maxretry = 3

# [dovecot]
# # ── Dovecot IMAP/POP3 防暴力破解 ────────────────────────
# enabled  = true
# logpath  = /var/log/mail.log
# filter   = dovecot
# maxretry = 3

# [vsftpd]
# # ── FTP 服务防暴力破解 ───────────────────────────────────
# enabled  = true
# logpath  = /var/log/vsftpd.log
# filter   = vsftpd
# maxretry = 3

# [php-url-fopen]
# # ── PHP 危险函数滥用检测 ─────────────────────────────────
# enabled  = true
# logpath  = /var/log/nginx/access.log
# filter   = php-url-fopen
# maxretry = 1
JAILEOF

    success "jail.local 已生成：$F2B_JAIL_LOCAL"
fi

# ─────────────────────────────────────────────
# 生成 Caddy 自定义 filter（如需）
# ─────────────────────────────────────────────
if [ "$ENABLE_CADDY" -eq 1 ]; then
    CADDY_FILTER="$F2B_CONF_DIR/filter.d/caddy-auth.conf"
    if [ ! -f "$CADDY_FILTER" ]; then
        cat > "$CADDY_FILTER" << 'FILTEREOF'
# /etc/fail2ban/filter.d/caddy-auth.conf
# Caddy 认证失败过滤器（适配 Caddy JSON 结构化日志）
[Definition]
# 匹配 Caddy JSON 日志中 status=401/403 的客户端 IP
failregex = ^.*"remote_ip":"<HOST>".*"status":(401|403).*$
ignoreregex =
FILTEREOF
        success "已创建 Caddy filter：$CADDY_FILTER"
    fi
fi

# ─────────────────────────────────────────────
# 语法自检
# ─────────────────────────────────────────────
step "语法自检"

if cmd_exists fail2ban-client; then
    info "运行 fail2ban-client --test ..."
    if fail2ban-client --test >/dev/null 2>&1; then
        success "fail2ban 配置语法检查通过"
    else
        warn "语法检查有警告，详细信息："
        fail2ban-client --test 2>&1 | head -30
        if ! prompt_yn "配置存在警告，是否仍然继续启动服务？" "n"; then
            error "请修正配置后重新运行脚本"
        fi
    fi
fi

# ─────────────────────────────────────────────
# 启动 / 重启 fail2ban
# ─────────────────────────────────────────────
step "启动 fail2ban 服务"

case "$OS" in
    debian)
        systemctl enable fail2ban >/dev/null 2>&1
        if systemctl is-active fail2ban >/dev/null 2>&1; then
            info "fail2ban 正在运行，重载配置..."
            systemctl reload-or-restart fail2ban
        else
            systemctl start fail2ban
        fi
        sleep 2
        if systemctl is-active fail2ban >/dev/null 2>&1; then
            success "fail2ban 服务运行正常（systemd）"
        else
            warn "fail2ban 服务可能未正常启动，请检查："
            systemctl status fail2ban --no-pager 2>&1 | tail -15
        fi
        ;;
    alpine)
        rc-update add fail2ban default >/dev/null 2>&1
        rc-service fail2ban restart >/dev/null 2>&1
        sleep 2
        if rc-service fail2ban status 2>/dev/null | grep -q started; then
            success "fail2ban 服务运行正常（OpenRC）"
        else
            warn "fail2ban 服务可能未正常启动，请检查：rc-service fail2ban status"
        fi
        ;;
esac

# ─────────────────────────────────────────────
# 验证 jail 状态
# ─────────────────────────────────────────────
step "验证 Jail 运行状态"

sleep 1
if cmd_exists fail2ban-client; then
    info "当前 fail2ban jail 状态："
    printf "${CYAN}%s${NC}\n" "─────────────────────────────"
    fail2ban-client status 2>/dev/null || warn "无法获取 fail2ban 状态，服务可能仍在初始化"
    printf "${CYAN}%s${NC}\n" "─────────────────────────────"
fi

# ─────────────────────────────────────────────
# 完成摘要
# ─────────────────────────────────────────────
printf "\n"
printf "${BOLD}${GREEN}════════════════════════════════════════════${NC}\n"
printf "${BOLD}${GREEN}  ✅  fail2ban 配置完成！${NC}\n"
printf "${BOLD}${GREEN}════════════════════════════════════════════${NC}\n"
printf "\n"
printf "${BOLD}配置摘要：${NC}\n"
printf "  %-20s %s\n" "配置文件："     "$F2B_JAIL_LOCAL"
printf "  %-20s %s\n" "防火墙后端："   "$BANACTION"
printf "  %-20s %s 秒\n" "封禁时长："  "$BAN_TIME"
printf "  %-20s %s 秒\n" "检测窗口："  "$FIND_TIME"
printf "  %-20s %s 次\n" "最大失败："  "$MAX_RETRY"
printf "  %-20s %s\n" "白名单："       "$IGNOREIP"
printf "\n"
printf "${BOLD}常用管理命令：${NC}\n"
printf "  ${CYAN}fail2ban-client status${NC}              # 查看所有 jail 状态\n"
printf "  ${CYAN}fail2ban-client status sshd${NC}         # 查看 SSH jail 详情\n"
printf "  ${CYAN}fail2ban-client set sshd unbanip IP${NC} # 手动解封某 IP\n"
printf "  ${CYAN}fail2ban-client set sshd banip IP${NC}   # 手动封禁某 IP\n"
printf "  ${CYAN}fail2ban-client reload${NC}              # 重载配置（不重启）\n"
printf "  ${CYAN}tail -f /var/log/fail2ban.log${NC}       # 实时查看封禁日志\n"
printf "\n"
printf "${YELLOW}提示：${NC}如需调整配置，编辑 ${BOLD}$F2B_JAIL_LOCAL${NC} 后执行 ${CYAN}fail2ban-client reload${NC}\n"
printf "\n"
