#!/bin/sh
# =============================================================================
# Fail2ban 交互式安装配置脚本
# 支持系统：Debian/Ubuntu、Alpine Linux
# 功能：检测依赖、日志路径、防火墙类型；通过菜单确认后安装、写配置、管理服务
# =============================================================================

# 不使用 set -e：交互脚本应尽量给出明确错误，并允许用户返回菜单继续处理。
# wget -O vless-go.sh https://raw.githubusercontent.com/SuzukiRenz/ScriptHub/refs/heads/main/SH/setup_fail2ban.sh && chmod +x setup_fail2ban.sh && ./setup_fail2ban.sh

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
error()   { printf "${RED}[错误]${NC} %s\n" "$1"; }
step()    { printf "\n${BOLD}${BLUE}━━━ %s ━━━${NC}\n" "$1"; }
ask()     { printf "${YELLOW}[?]${NC} %s " "$1"; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

pause_enter() {
    printf "\n按回车返回菜单..."
    read -r _pause
}

prompt_yn() {
    # $1=问题  $2=默认(y/n)
    _default="${2:-n}"
    ask "$1 [$([ "$_default" = "y" ] && echo 'Y/n' || echo 'y/N')]:"
    read -r _ans
    _ans="${_ans:-$_default}"
    case "$_ans" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

confirm_action() {
    # $1=标题 $2=详情 $3=默认(y/n)
    _title="$1"
    _detail="$2"
    _default="${3:-n}"
    printf "\n${YELLOW}即将执行：${NC}%s\n" "$_title"
    printf "%s\n" "$_detail"
    if prompt_yn "确认执行？" "$_default"; then
        return 0
    fi
    warn "已取消：$_title"
    return 1
}

is_number() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_port() {
    is_number "$1" || return 1
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

read_number_default() {
    # $1=提示 $2=默认值
    _prompt="$1"
    _default="$2"
    while :; do
        ask "$_prompt（默认 $_default）:"
        read -r _value
        _value="${_value:-$_default}"
        if is_number "$_value"; then
            printf "%s" "$_value"
            return 0
        fi
        warn "请输入数字"
    done
}

# ─────────────────────────────────────────────
# 全局状态
# ─────────────────────────────────────────────
OS=""
PKG_MGR=""
SVC_CMD=""
PRETTY_NAME=""

F2B_CONF_DIR="/etc/fail2ban"
F2B_JAIL_LOCAL="$F2B_CONF_DIR/jail.local"
PREVIEW_FILE="/tmp/setup_fail2ban.jail.local.preview"

HAS_UFW=0
UFW_ACTIVE=0
HAS_IPTABLES=0
HAS_NFTABLES=0

BANACTION="iptables-multiport"
BANACTION_ALLPORTS="iptables-allports"
SSH_FW_PORT="22"

SSH_LOG=""
SSH_BACKEND="auto"
NGINX_ERROR_LOG=""
NGINX_ACCESS_LOG=""
CADDY_LOG=""

BAN_TIME="3600"
FIND_TIME="600"
MAX_RETRY="5"
IGNOREIP="127.0.0.1/8 ::1"
DESTEMAIL=""
SENDEREMAIL=""
ENABLE_SSH=1
ENABLE_NGINX_AUTH=0
ENABLE_NGINX_BOT=0
ENABLE_NGINX_LIMIT=0
ENABLE_CADDY=0

DETECTED=0
CONFIG_GENERATED=0
CONFIG_WRITTEN=0

# ─────────────────────────────────────────────
# 系统检测与包管理
# ─────────────────────────────────────────────
detect_os() {
    step "检测操作系统"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        PRETTY_NAME="${PRETTY_NAME:-$ID}"
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
                if [ -f /etc/debian_version ]; then
                    OS="debian"
                    PKG_MGR="apt-get"
                    SVC_CMD="systemctl"
                    warn "检测到类 Debian 系统（$PRETTY_NAME），尝试以 Debian 模式继续"
                else
                    error "不支持的系统：$PRETTY_NAME。本脚本仅支持 Debian/Ubuntu 和 Alpine。"
                    exit 1
                fi
                ;;
        esac
    else
        error "无法读取 /etc/os-release，无法识别操作系统"
        exit 1
    fi
    info "操作系统：${PRETTY_NAME:-$OS}"
    info "包管理器：$PKG_MGR"
}

pkg_installed() {
    case "$OS" in
        debian) dpkg -l "$1" 2>/dev/null | grep -q "^ii" ;;
        alpine) apk info -e "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

install_pkg() {
    _pkg="$1"
    if pkg_installed "$_pkg" || cmd_exists "$_pkg"; then
        success "$_pkg 已存在"
        return 0
    fi

    if ! confirm_action "安装 $_pkg" "将通过 $PKG_MGR 安装 $_pkg。" "n"; then
        return 1
    fi

    case "$OS" in
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$_pkg"
            ;;
        alpine)
            apk add --no-cache "$_pkg"
            ;;
    esac
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        success "已安装 $_pkg"
        return 0
    fi
    error "安装 $_pkg 失败"
    return 1
}

update_pkg_index() {
    step "更新软件包列表"
    case "$OS" in
        debian)
            confirm_action "更新 apt 软件包列表" "将执行：apt-get update" "y" || return 0
            apt-get update
            ;;
        alpine)
            confirm_action "更新 apk 软件包列表" "将执行：apk update" "y" || return 0
            apk update
            ;;
    esac
    if [ "$?" -eq 0 ]; then
        success "软件包列表已更新"
    else
        warn "软件包列表更新失败，请检查网络或软件源"
    fi
}

menu_install_fail2ban() {
    step "安装/检查 fail2ban"
    if cmd_exists fail2ban-client; then
        F2B_VER=$(fail2ban-client --version 2>/dev/null | head -1 | awk '{print $2}')
        success "fail2ban 已安装，版本：${F2B_VER:-未知}"
        return 0
    fi
    warn "未检测到 fail2ban"
    install_pkg "fail2ban"
}

# ─────────────────────────────────────────────
# 检测函数
# ─────────────────────────────────────────────
detect_ssh_port() {
    _port=""
    if [ -n "$SSH_CLIENT" ]; then
        _port=$(echo "$SSH_CLIENT" | awk '{print $3}')
    fi
    if [ -z "$_port" ] && [ -n "$SSH_CONNECTION" ]; then
        _port=$(echo "$SSH_CONNECTION" | awk '{print $4}')
    fi
    if [ -z "$_port" ]; then
        for _cfg in /etc/ssh/sshd_config /etc/sshd_config; do
            if [ -f "$_cfg" ]; then
                _port=$(grep -i "^Port " "$_cfg" 2>/dev/null | awk '{print $2}' | head -1)
                [ -n "$_port" ] && break
            fi
        done
    fi
    if [ -z "$_port" ] && cmd_exists ss; then
        _port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | grep -o '[0-9]*$' | head -1)
    fi
    echo "${_port:-22}"
}

detect_ssh_log() {
    for p in /var/log/auth.log /var/log/secure /var/log/messages /var/log/sshd.log; do
        if [ -f "$p" ]; then
            echo "$p"
            return
        fi
    done
    if cmd_exists journalctl; then
        echo "__journald__"
        return
    fi
    echo ""
}

detect_firewalls() {
    HAS_UFW=0
    UFW_ACTIVE=0
    HAS_IPTABLES=0
    HAS_NFTABLES=0

    if cmd_exists ufw; then
        HAS_UFW=1
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            UFW_ACTIVE=1
        fi
    fi
    cmd_exists iptables && HAS_IPTABLES=1
    cmd_exists nft && HAS_NFTABLES=1
}

detect_logs() {
    SSH_LOG=$(detect_ssh_log)
    SSH_BACKEND="auto"
    if [ "$SSH_LOG" = "__journald__" ]; then
        SSH_BACKEND="systemd"
        SSH_LOG=""
    fi

    NGINX_ERROR_LOG=""
    NGINX_ACCESS_LOG=""
    if cmd_exists nginx || [ -d /etc/nginx ]; then
        for p in /var/log/nginx/error.log /usr/local/nginx/logs/error.log; do
            [ -f "$p" ] && NGINX_ERROR_LOG="$p" && break
        done
        for p in /var/log/nginx/access.log /usr/local/nginx/logs/access.log; do
            [ -f "$p" ] && NGINX_ACCESS_LOG="$p" && break
        done
        if [ -z "$NGINX_ERROR_LOG" ] && cmd_exists nginx; then
            _log=$(nginx -T 2>/dev/null | grep -i 'error_log' | head -1 | awk '{print $2}' | tr -d ';')
            [ -f "$_log" ] && NGINX_ERROR_LOG="$_log"
        fi
        if [ -z "$NGINX_ACCESS_LOG" ] && cmd_exists nginx; then
            _log=$(nginx -T 2>/dev/null | grep -i 'access_log' | head -1 | awk '{print $2}' | tr -d ';')
            [ -f "$_log" ] && NGINX_ACCESS_LOG="$_log"
        fi
    fi

    CADDY_LOG=""
    if cmd_exists caddy || [ -d /etc/caddy ]; then
        for p in /var/log/caddy/access.log /var/log/caddy.log /usr/local/var/log/caddy.log; do
            [ -f "$p" ] && CADDY_LOG="$p" && break
        done
    fi
}

initial_detect() {
    detect_os
    detect_firewalls
    detect_logs
    SSH_FW_PORT=$(detect_ssh_port)

    if [ -n "$NGINX_ERROR_LOG" ]; then
        ENABLE_NGINX_AUTH=1
        ENABLE_NGINX_LIMIT=1
    fi
    if [ -n "$NGINX_ACCESS_LOG" ]; then
        ENABLE_NGINX_BOT=1
    fi
    [ -n "$CADDY_LOG" ] && ENABLE_CADDY=1

    DETECTED=1
}

show_detect_result() {
    step "当前检测结果"
    printf "%-24s %s\n" "操作系统:" "${PRETTY_NAME:-$OS}"
    printf "%-24s %s\n" "包管理器:" "$PKG_MGR"
    if cmd_exists fail2ban-client; then
        printf "%-24s %s\n" "fail2ban:" "已安装 ($(fail2ban-client --version 2>/dev/null | head -1))"
    else
        printf "%-24s %s\n" "fail2ban:" "未安装"
    fi

    printf "\n${BOLD}防火墙：${NC}\n"
    [ "$HAS_UFW" -eq 1 ] && printf "  UFW: %s\n" "$([ "$UFW_ACTIVE" -eq 1 ] && echo active || echo installed/inactive)" || printf "  UFW: 未检测到\n"
    [ "$HAS_IPTABLES" -eq 1 ] && printf "  iptables: 可用\n" || printf "  iptables: 未检测到\n"
    [ "$HAS_NFTABLES" -eq 1 ] && printf "  nftables: 可用\n" || printf "  nftables: 未检测到\n"
    printf "  当前选择 banaction: %s / %s\n" "$BANACTION" "$BANACTION_ALLPORTS"

    printf "\n${BOLD}日志路径：${NC}\n"
    if [ "$SSH_BACKEND" = "systemd" ]; then
        printf "  SSH: journald/systemd\n"
    elif [ -n "$SSH_LOG" ]; then
        printf "  SSH: %s\n" "$SSH_LOG"
    else
        printf "  SSH: 未找到\n"
    fi
    printf "  Nginx error: %s\n" "${NGINX_ERROR_LOG:-未找到}"
    printf "  Nginx access: %s\n" "${NGINX_ACCESS_LOG:-未找到}"
    printf "  Caddy: %s\n" "${CADDY_LOG:-未找到}"

    printf "\n${BOLD}配置参数：${NC}\n"
    printf "  bantime=%s, findtime=%s, maxretry=%s\n" "$BAN_TIME" "$FIND_TIME" "$MAX_RETRY"
    printf "  ignoreip=%s\n" "$IGNOREIP"
    printf "  SSH=%s, NginxAuth=%s, NginxBot=%s, NginxLimit=%s, Caddy=%s\n" \
        "$ENABLE_SSH" "$ENABLE_NGINX_AUTH" "$ENABLE_NGINX_BOT" "$ENABLE_NGINX_LIMIT" "$ENABLE_CADDY"
}

# ─────────────────────────────────────────────
# 防火墙菜单
# ─────────────────────────────────────────────
confirm_ssh_port_safety() {
    # 动态识别 SSH 端口，并要求用户二次确认。所有可能影响防火墙的流程都应先调用它。
    _detected_port=$(detect_ssh_port)
    printf "\n"
    printf "${YELLOW}┌─────────────────────────────────────────────────┐${NC}\n"
    printf "${YELLOW}│  SSH 端口安全确认：防止防火墙操作锁门           │${NC}\n"
    printf "${YELLOW}└─────────────────────────────────────────────────┘${NC}\n"
    info "动态识别到当前 SSH 端口：${_detected_port}"

    while :; do
        ask "第一次确认：SSH 端口是多少？（直接回车使用检测值 ${_detected_port}）:"
        read -r _confirm_port
        SSH_FW_PORT="${_confirm_port:-$_detected_port}"
        is_port "$SSH_FW_PORT" && break
        warn "端口必须是 1-65535 的数字"
    done

    while :; do
        ask "第二次确认：请再次输入 SSH 端口 ${SSH_FW_PORT} 以继续:"
        read -r _confirm_port_again
        if [ "$_confirm_port_again" = "$SSH_FW_PORT" ]; then
            success "SSH 端口已二次确认：$SSH_FW_PORT"
            return 0
        fi
        warn "两次输入不一致。为避免锁门，已取消本次防火墙操作。"
        return 1
    done
}

safe_enable_ufw() {
    printf "\n"
    printf "${YELLOW}┌─────────────────────────────────────────────────┐${NC}\n"
    printf "${YELLOW}│  UFW 安全检查：先放行 SSH，再启用 UFW           │${NC}\n"
    printf "${YELLOW}└─────────────────────────────────────────────────┘${NC}\n"

    confirm_ssh_port_safety || return 1

    ask "是否需要额外放行其他端口？（留空跳过，多个用空格分隔，例: 80 443 8080）:"
    read -r _extra_ports

    printf "\n将执行以下 UFW 操作：\n"
    printf "  1) ufw allow %s/tcp    # 放行 SSH\n" "$SSH_FW_PORT"
    if [ -n "$_extra_ports" ]; then
        for _p in $_extra_ports; do
            printf "  2) ufw allow %s         # 额外放行\n" "$_p"
        done
    fi
    printf "  3) ufw default deny incoming\n"
    printf "  4) ufw default allow outgoing\n"
    printf "  5) ufw --force enable\n"
    warn "启用后，未放行的入站端口将被拒绝。请确认 SSH 和其他业务端口已包含在上方列表中。"

    if ! prompt_yn "确认启用 UFW？" "n"; then
        warn "已取消 UFW 启用。未做任何防火墙修改。"
        return 1
    fi

    ufw allow "${SSH_FW_PORT}/tcp" comment 'SSH - added by setup_fail2ban.sh' || return 1
    if [ -n "$_extra_ports" ]; then
        for _p in $_extra_ports; do
            ufw allow "$_p" comment 'Extra - added by setup_fail2ban.sh' || return 1
        done
    fi
    ufw default deny incoming || return 1
    ufw default allow outgoing || return 1
    ufw --force enable || return 1
    success "UFW 已启用"
    ufw status numbered 2>/dev/null | head -30
    detect_firewalls
    return 0
}

choose_firewall_backend() {
    detect_firewalls
    while :; do
        step "选择 fail2ban 防火墙后端"
        printf "检测结果：UFW=%s, UFW_ACTIVE=%s, iptables=%s, nftables=%s\n" \
            "$HAS_UFW" "$UFW_ACTIVE" "$HAS_IPTABLES" "$HAS_NFTABLES"
        printf "\n1) 使用 iptables（推荐，封禁特定端口/全端口）\n"
        printf "2) 使用 UFW（未启用时会进入 SSH 端口安全确认）\n"
        printf "3) 使用 nftables\n"
        printf "4) dummy 测试模式（只记录，不实际封禁）\n"
        printf "0) 返回主菜单\n"
        ask "请输入选项:"
        read -r fw
        case "$fw" in
            1)
                if ! cmd_exists iptables; then
                    install_pkg "iptables" || return 0
                fi
                BANACTION="iptables-multiport"
                BANACTION_ALLPORTS="iptables-allports"
                success "已选择 iptables"
                return 0
                ;;
            2)
                if ! cmd_exists ufw; then
                    install_pkg "ufw" || return 0
                fi
                if ufw status 2>/dev/null | grep -q "Status: active"; then
                    BANACTION="ufw"
                    BANACTION_ALLPORTS="ufw"
                    success "已选择 UFW（当前已启用）"
                    return 0
                fi
                if safe_enable_ufw; then
                    BANACTION="ufw"
                    BANACTION_ALLPORTS="ufw"
                    success "已选择 UFW"
                    return 0
                fi
                ;;
            3)
                if ! cmd_exists nft; then
                    warn "未检测到 nft 命令。请先安装 nftables，或选择其他后端。"
                else
                    BANACTION="nftables-multiport"
                    BANACTION_ALLPORTS="nftables-allports"
                    success "已选择 nftables"
                    return 0
                fi
                ;;
            4)
                BANACTION="dummy"
                BANACTION_ALLPORTS="dummy"
                success "已选择 dummy 测试模式"
                return 0
                ;;
            0) return 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# 防火墙端口管理菜单
# ─────────────────────────────────────────────
normalize_proto() {
    _proto="$1"
    case "$_proto" in
        udp|UDP) echo "udp" ;;
        *) echo "tcp" ;;
    esac
}

read_port_or_range() {
    # 允许单端口 80 或范围 10000:20000 / 10000-20000（内部统一为冒号）
    FW_PORT_SELECTED=""
    while :; do
        ask "请输入端口或端口范围（例: 22、80、443、10000-20000）:"
        read -r _raw_port
        case "$_raw_port" in
            *-*) _fw_port=$(echo "$_raw_port" | sed 's/-/:/g') ;;
            *) _fw_port="$_raw_port" ;;
        esac
        case "$_fw_port" in
            *:*)
                _start=$(echo "$_fw_port" | awk -F: '{print $1}')
                _end=$(echo "$_fw_port" | awk -F: '{print $2}')
                if is_port "$_start" && is_port "$_end" && [ "$_start" -le "$_end" ] 2>/dev/null; then
                    FW_PORT_SELECTED="$_fw_port"
                    return 0
                fi
                ;;
            *)
                if is_port "$_fw_port"; then
                    FW_PORT_SELECTED="$_fw_port"
                    return 0
                fi
                ;;
        esac
        warn "端口必须是 1-65535，范围格式示例：10000-20000"
    done
}

show_listening_ports() {
    step "查看端口占用/监听"
    if cmd_exists ss; then
        ss -tulpen 2>/dev/null || ss -tuln 2>/dev/null
    elif cmd_exists netstat; then
        netstat -tulpen 2>/dev/null || netstat -tuln 2>/dev/null
    elif cmd_exists lsof; then
        lsof -i -P -n 2>/dev/null | grep LISTEN || true
    else
        warn "未检测到 ss/netstat/lsof，无法查看端口占用。可安装 iproute2 获取 ss 命令。"
    fi
}

show_firewall_rules() {
    step "查看当前防火墙规则"
    detect_firewalls
    if [ "$HAS_UFW" -eq 1 ]; then
        printf "\n${BOLD}UFW:${NC}\n"
        ufw status numbered 2>/dev/null || warn "无法读取 UFW 状态"
    fi
    if [ "$HAS_IPTABLES" -eq 1 ]; then
        printf "\n${BOLD}iptables INPUT 规则（前 80 行）:${NC}\n"
        iptables -L INPUT -n --line-numbers 2>/dev/null | sed -n '1,80p' || warn "无法读取 iptables 规则"
    fi
    if [ "$HAS_NFTABLES" -eq 1 ]; then
        printf "\n${BOLD}nftables ruleset（前 120 行）:${NC}\n"
        nft list ruleset 2>/dev/null | sed -n '1,120p' || warn "无法读取 nftables 规则"
    fi
    if [ "$HAS_UFW" -eq 0 ] && [ "$HAS_IPTABLES" -eq 0 ] && [ "$HAS_NFTABLES" -eq 0 ]; then
        warn "未检测到 UFW / iptables / nftables"
    fi
}

choose_firewall_tool_for_port() {
    FW_TOOL_SELECTED=""
    detect_firewalls
    while :; do
        printf "\n请选择要操作的防火墙工具：\n"
        printf "1) UFW%s\n" "$([ "$HAS_UFW" -eq 1 ] && echo '' || echo '（未安装）')"
        printf "2) iptables%s\n" "$([ "$HAS_IPTABLES" -eq 1 ] && echo '' || echo '（未安装）')"
        printf "3) nftables%s\n" "$([ "$HAS_NFTABLES" -eq 1 ] && echo '' || echo '（未安装/未检测到 nft）')"
        printf "0) 取消\n"
        ask "请输入选项:"
        read -r _tool_choice
        case "$_tool_choice" in
            1)
                if ! cmd_exists ufw; then
                    install_pkg "ufw" || return 1
                fi
                FW_TOOL_SELECTED="ufw"
                return 0
                ;;
            2)
                if ! cmd_exists iptables; then
                    install_pkg "iptables" || return 1
                fi
                FW_TOOL_SELECTED="iptables"
                return 0
                ;;
            3)
                if ! cmd_exists nft; then
                    warn "未检测到 nft 命令。请先安装 nftables，或选择其他工具。"
                else
                    FW_TOOL_SELECTED="nftables"
                    return 0
                fi
                ;;
            0) return 1 ;;
            *) warn "无效选项" ;;
        esac
    done
}

firewall_open_port() {
    step "开放防火墙端口"
    show_listening_ports
    confirm_ssh_port_safety || return 1
    choose_firewall_tool_for_port || return 0
    _fw_tool="$FW_TOOL_SELECTED"
    read_port_or_range || return 0
    _fw_port="$FW_PORT_SELECTED"
    ask "协议 tcp/udp（默认 tcp）:"
    read -r _proto
    _proto=$(normalize_proto "$_proto")

    if [ "$_fw_port" = "$SSH_FW_PORT" ] && [ "$_proto" != "tcp" ]; then
        warn "SSH 通常使用 tcp；你输入的是 SSH 端口但协议不是 tcp。"
    fi

    case "$_fw_tool" in
        ufw)
            _cmd="ufw allow ${_fw_port}/${_proto} comment 'opened by setup_fail2ban.sh'"
            ;;
        iptables)
            _cmd="iptables -I INPUT -p ${_proto} --dport ${_fw_port} -j ACCEPT"
            ;;
        nftables)
            _nft_port=$(echo "$_fw_port" | sed 's/:/-/g')
            _cmd="nft add rule inet filter input ${_proto} dport ${_nft_port} accept"
            ;;
    esac

    if ! confirm_action "开放 ${_proto}/${_fw_port}" "将执行：$_cmd\n注意：iptables/nftables 规则是否持久化取决于你的系统配置。" "n"; then
        return 0
    fi
    sh -c "$_cmd"
    [ "$?" -eq 0 ] && success "已开放 ${_proto}/${_fw_port}" || error "开放端口失败"
}

firewall_close_port() {
    step "关闭防火墙端口"
    show_firewall_rules
    confirm_ssh_port_safety || return 1
    choose_firewall_tool_for_port || return 0
    _fw_tool="$FW_TOOL_SELECTED"
    read_port_or_range || return 0
    _fw_port="$FW_PORT_SELECTED"
    ask "协议 tcp/udp（默认 tcp）:"
    read -r _proto
    _proto=$(normalize_proto "$_proto")

    if [ "$_fw_port" = "$SSH_FW_PORT" ] && [ "$_proto" = "tcp" ]; then
        warn "你正在尝试关闭已确认的 SSH 端口：${SSH_FW_PORT}/tcp。这个操作可能立刻导致 SSH 断开且无法重新连接。"
        if ! prompt_yn "第三次确认：仍然要关闭 SSH 端口？" "n"; then
            warn "已取消关闭 SSH 端口"
            return 0
        fi
    fi

    case "$_fw_tool" in
        ufw)
            _cmd="ufw delete allow ${_fw_port}/${_proto}"
            ;;
        iptables)
            _cmd="iptables -D INPUT -p ${_proto} --dport ${_fw_port} -j ACCEPT"
            ;;
        nftables)
            warn "nftables 删除规则通常需要 handle 编号，脚本将显示 ruleset，请手动按 handle 删除更安全。"
            nft -a list ruleset 2>/dev/null | sed -n '1,160p'
            return 0
            ;;
    esac

    if ! confirm_action "关闭 ${_proto}/${_fw_port}" "将执行：$_cmd\n注意：iptables 删除只会删除完全匹配的 ACCEPT 规则；若规则不存在会失败。" "n"; then
        return 0
    fi
    sh -c "$_cmd"
    [ "$?" -eq 0 ] && success "已关闭/删除 ${_proto}/${_fw_port} 的放行规则" || warn "关闭端口失败，可能没有完全匹配的放行规则"
}

firewall_port_menu() {
    while :; do
        step "防火墙/端口管理"
        printf "1) 查看端口占用/监听进程\n"
        printf "2) 查看当前防火墙规则\n"
        printf "3) 交互式开放端口\n"
        printf "4) 交互式关闭端口\n"
        printf "5) 仅重新动态识别并二次确认 SSH 端口\n"
        printf "0) 返回主菜单\n"
        ask "请输入选项:"
        read -r _fw_menu_choice
        case "$_fw_menu_choice" in
            1) show_listening_ports; pause_enter ;;
            2) show_firewall_rules; pause_enter ;;
            3) firewall_open_port; pause_enter ;;
            4) firewall_close_port; pause_enter ;;
            5) confirm_ssh_port_safety; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# 参数与 Jail 菜单
# ─────────────────────────────────────────────
config_base_params() {
    step "配置基础参数"
    BAN_TIME=$(read_number_default "封禁时长 bantime，秒；3600=1小时，86400=1天" "$BAN_TIME")
    printf "\n"
    FIND_TIME=$(read_number_default "检测时间窗口 findtime，秒；600=10分钟" "$FIND_TIME")
    printf "\n"
    MAX_RETRY=$(read_number_default "最大失败次数 maxretry；建议 3-5" "$MAX_RETRY")
    printf "\n"

    ask "白名单 IP / 网段（空格分隔，默认当前值：$IGNOREIP）:"
    read -r _ignore
    [ -n "$_ignore" ] && IGNOREIP="127.0.0.1/8 ::1 $_ignore"

    if prompt_yn "是否配置邮件封禁通知？" "$([ -n "$DESTEMAIL" ] && echo y || echo n)"; then
        ask "通知目标邮箱:"
        read -r DESTEMAIL
        ask "发件人邮箱（默认 fail2ban@localhost）:"
        read -r SENDEREMAIL
        SENDEREMAIL="${SENDEREMAIL:-fail2ban@localhost}"
        if ! cmd_exists sendmail && ! cmd_exists msmtp; then
            warn "未检测到 sendmail/msmtp。脚本会写入邮件配置，但发送可能无法工作。"
        fi
    else
        DESTEMAIL=""
        SENDEREMAIL=""
    fi
    success "基础参数已更新"
}

choose_jails() {
    step "选择启用的 Jail"
    if cmd_exists sshd || cmd_exists ssh || [ -n "$SSH_LOG" ] || [ "$SSH_BACKEND" = "systemd" ]; then
        prompt_yn "启用 SSH 防暴力破解监控？" "$([ "$ENABLE_SSH" -eq 1 ] && echo y || echo n)" && ENABLE_SSH=1 || ENABLE_SSH=0
    else
        warn "未检测到 SSH 服务或日志，仍可手动启用但可能无法工作。"
        prompt_yn "仍然启用 SSH jail？" "n" && ENABLE_SSH=1 || ENABLE_SSH=0
    fi

    if [ -n "$NGINX_ERROR_LOG" ]; then
        prompt_yn "启用 Nginx HTTP 认证失败监控（使用 error log）？" "$([ "$ENABLE_NGINX_AUTH" -eq 1 ] && echo y || echo n)" && ENABLE_NGINX_AUTH=1 || ENABLE_NGINX_AUTH=0
        prompt_yn "启用 Nginx limit_req 超限监控（使用 error log）？" "$([ "$ENABLE_NGINX_LIMIT" -eq 1 ] && echo y || echo n)" && ENABLE_NGINX_LIMIT=1 || ENABLE_NGINX_LIMIT=0
    else
        ENABLE_NGINX_AUTH=0
        ENABLE_NGINX_LIMIT=0
        info "未找到 Nginx error log，跳过 nginx-http-auth / nginx-limit-req"
    fi

    if [ -n "$NGINX_ACCESS_LOG" ]; then
        prompt_yn "启用 Nginx botsearch 恶意扫描监控（使用 access log）？" "$([ "$ENABLE_NGINX_BOT" -eq 1 ] && echo y || echo n)" && ENABLE_NGINX_BOT=1 || ENABLE_NGINX_BOT=0
    else
        ENABLE_NGINX_BOT=0
        info "未找到 Nginx access log，跳过 nginx-botsearch"
    fi

    if [ -n "$CADDY_LOG" ]; then
        prompt_yn "启用 Caddy 401/403 异常访问监控？" "$([ "$ENABLE_CADDY" -eq 1 ] && echo y || echo n)" && ENABLE_CADDY=1 || ENABLE_CADDY=0
    else
        ENABLE_CADDY=0
        info "未找到 Caddy 日志，跳过 Caddy jail"
    fi
    success "Jail 选择已更新"
}

# ─────────────────────────────────────────────
# 配置生成、预览、写入
# ─────────────────────────────────────────────
generate_config() {
    if [ -n "$DESTEMAIL" ]; then
        EMAIL_BLOCK="# 封禁事件邮件通知目标地址
destemail = ${DESTEMAIL}
# 通知邮件发件人
sender   = ${SENDEREMAIL:-fail2ban@localhost}
# 发送邮件工具（需系统安装 sendmail 或 msmtp）
mta      = sendmail"
        ACTION_BLOCK="action = %(action_mwl)s"
    else
        EMAIL_BLOCK="# 未启用邮件通知（可设置 destemail 开启）"
        ACTION_BLOCK="action = %(action_)s"
    fi

    if [ "$ENABLE_SSH" -eq 1 ]; then
        if [ "$SSH_BACKEND" = "systemd" ]; then
            SSH_JAIL_BLOCK="[sshd]
# SSH 防暴力破解：systemd journal 后端
enabled  = true
backend  = systemd
filter   = sshd
banaction = ${BANACTION_ALLPORTS}
bantime  = 86400
maxretry = ${MAX_RETRY}"
        else
            _sshlog="${SSH_LOG:-/var/log/auth.log}"
            SSH_JAIL_BLOCK="[sshd]
# SSH 防暴力破解：日志文件后端
enabled  = true
logpath  = ${_sshlog}
filter   = sshd
banaction = ${BANACTION_ALLPORTS}
bantime  = 86400
maxretry = ${MAX_RETRY}"
        fi
    else
        SSH_JAIL_BLOCK="# [sshd] 监控已禁用"
    fi

    NGINX_JAIL_BLOCK="# Nginx 监控未启用"
    if [ "$ENABLE_NGINX_AUTH" -eq 1 ] || [ "$ENABLE_NGINX_BOT" -eq 1 ] || [ "$ENABLE_NGINX_LIMIT" -eq 1 ]; then
        NGINX_JAIL_BLOCK=""
        if [ "$ENABLE_NGINX_AUTH" -eq 1 ]; then
            NGINX_JAIL_BLOCK="${NGINX_JAIL_BLOCK}
[nginx-http-auth]
# Nginx HTTP Basic Auth 失败监控
enabled  = true
logpath  = ${NGINX_ERROR_LOG}
filter   = nginx-http-auth
maxretry = ${MAX_RETRY}
"
        fi
        if [ "$ENABLE_NGINX_BOT" -eq 1 ]; then
            NGINX_JAIL_BLOCK="${NGINX_JAIL_BLOCK}
[nginx-botsearch]
# Nginx 恶意扫描器/爬虫监控，建议使用 access log
enabled  = true
logpath  = ${NGINX_ACCESS_LOG}
filter   = nginx-botsearch
bantime  = 604800
maxretry = 2
"
        fi
        if [ "$ENABLE_NGINX_LIMIT" -eq 1 ]; then
            NGINX_JAIL_BLOCK="${NGINX_JAIL_BLOCK}
[nginx-limit-req]
# Nginx limit_req 超限监控，通常记录在 error log
enabled  = true
logpath  = ${NGINX_ERROR_LOG}
filter   = nginx-limit-req
maxretry = 10
"
        fi
    fi

    if [ "$ENABLE_CADDY" -eq 1 ]; then
        CADDY_JAIL_BLOCK="
[caddy-auth]
# Caddy 401/403 异常访问监控
enabled  = true
logpath  = ${CADDY_LOG}
filter   = caddy-auth
maxretry = ${MAX_RETRY}"
    else
        CADDY_JAIL_BLOCK="# Caddy 监控未启用"
    fi

    cat > "$PREVIEW_FILE" << JAILEOF
# =============================================================================
# /etc/fail2ban/jail.local — 本地自定义配置
# 由 setup_fail2ban.sh 交互式脚本生成于 $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

[DEFAULT]
# 白名单 IP / 网段（空格分隔，支持 CIDR）
ignoreip = ${IGNOREIP}

# 封禁时长（秒）
bantime  = ${BAN_TIME}

# 检测时间窗口（秒）
findtime = ${FIND_TIME}

# 最大允许失败次数
maxretry = ${MAX_RETRY}

# 封禁动作（防火墙后端）
banaction = ${BANACTION}
banaction_allports = ${BANACTION_ALLPORTS}

# 日志后端
backend = auto

# 邮件通知配置
${EMAIL_BLOCK}

# 默认封禁动作策略
${ACTION_BLOCK}

# 可选：递增封禁时间（默认关闭）
# bantime.increment   = true
# bantime.rndtime     = 0
# bantime.maxtime     = 0
# bantime.factor      = 1

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
# enabled  = true
# logpath  = /var/log/mail.log
# filter   = postfix
# maxretry = 3

# [dovecot]
# enabled  = true
# logpath  = /var/log/mail.log
# filter   = dovecot
# maxretry = 3

# [vsftpd]
# enabled  = true
# logpath  = /var/log/vsftpd.log
# filter   = vsftpd
# maxretry = 3
JAILEOF
    CONFIG_GENERATED=1
    success "配置预览已生成：$PREVIEW_FILE"
}

preview_config() {
    step "预览配置"
    generate_config || return 1
    printf "\n${CYAN}以下是完整配置预览：${NC}\n"
    printf "${CYAN}%s${NC}\n" "────────────────────────────────────────"
    sed -n '1,220p' "$PREVIEW_FILE"
    printf "${CYAN}%s${NC}\n" "────────────────────────────────────────"
}

write_caddy_filter_if_needed() {
    [ "$ENABLE_CADDY" -eq 1 ] || return 0
    CADDY_FILTER="$F2B_CONF_DIR/filter.d/caddy-auth.conf"
    [ -f "$CADDY_FILTER" ] && return 0

    if ! confirm_action "创建 Caddy fail2ban filter" "将写入：$CADDY_FILTER" "n"; then
        return 0
    fi

    mkdir -p "$F2B_CONF_DIR" || { error "无法创建目录：$F2B_CONF_DIR"; return 1; }
    cp "$PREVIEW_FILE" "$F2B_JAIL_LOCAL" || { error "写入失败：$F2B_JAIL_LOCAL"; return 1; }
    success "已写入：$F2B_JAIL_LOCAL"
    CONFIG_WRITTEN=1
    write_caddy_filter_if_needed
}

# ─────────────────────────────────────────────
# fail2ban 检查和服务管理
# ─────────────────────────────────────────────
test_fail2ban_config() {
    step "语法自检"
    if ! cmd_exists fail2ban-client; then
        warn "未检测到 fail2ban-client，请先安装 fail2ban"
        return 1
    fi
    info "运行 fail2ban-client --test ..."
    fail2ban-client --test
    if [ "$?" -eq 0 ]; then
        success "fail2ban 配置语法检查通过"
        return 0
    fi
    warn "语法检查失败或存在警告，请根据上方输出修正"
    return 1
}

service_enable_start_reload() {
    step "启用并启动/重载 fail2ban"
    if ! cmd_exists fail2ban-client; then
        warn "未检测到 fail2ban-client，请先安装 fail2ban"
        return 1
    fi
    if ! confirm_action "启用并启动/重载 fail2ban 服务" "可能执行 systemctl enable/start/reload-or-restart 或 OpenRC 对应命令。" "n"; then
        return 0
    fi

    case "$OS" in
        debian)
            systemctl enable fail2ban || return 1
            if systemctl is-active fail2ban >/dev/null 2>&1; then
                systemctl reload-or-restart fail2ban || return 1
            else
                systemctl start fail2ban || return 1
            fi
            ;;
        alpine)
            rc-update add fail2ban default || return 1
            rc-service fail2ban restart || return 1
            ;;
    esac
    sleep 1
    success "fail2ban 服务已启用并运行/重载"
}

service_restart() {
    step "重启 fail2ban"
    if ! confirm_action "重启 fail2ban 服务" "将重启 fail2ban，短时间内封禁规则可能会重新加载。" "n"; then
        return 0
    fi
    case "$OS" in
        debian) systemctl restart fail2ban ;;
        alpine) rc-service fail2ban restart ;;
    esac
    if [ "$?" -eq 0 ]; then
        success "fail2ban 已重启"
    else
        error "fail2ban 重启失败"
    fi
}

service_disable_stop() {
    step "停用 fail2ban"
    warn "停用 fail2ban 会停止自动封禁；已有防火墙规则是否立即清理取决于 fail2ban 和后端行为。"
    if ! confirm_action "停用并停止 fail2ban 服务" "将执行 disable + stop。" "n"; then
        return 0
    fi
    case "$OS" in
        debian)
            systemctl disable fail2ban
            systemctl stop fail2ban
            ;;
        alpine)
            rc-update del fail2ban default
            rc-service fail2ban stop
            ;;
    esac
    if [ "$?" -eq 0 ]; then
        success "fail2ban 已停用并停止"
    else
        warn "停用/停止过程中出现错误，请检查服务状态"
    fi
}

show_service_status() {
    step "fail2ban 状态"
    if cmd_exists fail2ban-client; then
        fail2ban-client status 2>/dev/null || warn "无法获取 fail2ban-client 状态"
    else
        warn "未检测到 fail2ban-client"
    fi

    case "$OS" in
        debian) systemctl status fail2ban --no-pager 2>/dev/null | sed -n '1,18p' ;;
        alpine) rc-service fail2ban status 2>/dev/null ;;
    esac
}

view_logs_menu() {
    while :; do
        step "查看状态/日志"
        printf "1) 查看 fail2ban 总状态\n"
        printf "2) 查看 sshd jail 状态\n"
        printf "3) 查看 /var/log/fail2ban.log 最近 80 行\n"
        printf "4) 查看 systemd journal 最近 80 行（Debian/Ubuntu）\n"
        printf "5) 实时追踪 /var/log/fail2ban.log（Ctrl+C 结束）\n"
        printf "0) 返回主菜单\n"
        ask "请输入选项:"
        read -r log_choice
        case "$log_choice" in
            1)
                show_service_status
                pause_enter
                ;;
            2)
                if cmd_exists fail2ban-client; then
                    fail2ban-client status sshd 2>/dev/null || warn "无法获取 sshd jail 状态，可能未启用或服务未运行"
                else
                    warn "未检测到 fail2ban-client"
                fi
                pause_enter
                ;;
            3)
                if [ -f /var/log/fail2ban.log ]; then
                    tail -80 /var/log/fail2ban.log
                else
                    warn "未找到 /var/log/fail2ban.log"
                fi
                pause_enter
                ;;
            4)
                if [ "$OS" = "debian" ] && cmd_exists journalctl; then
                    journalctl -u fail2ban --no-pager -n 80
                else
                    warn "当前系统不可用 journalctl 或不是 systemd 系统"
                fi
                pause_enter
                ;;
            5)
                if [ -f /var/log/fail2ban.log ]; then
                    warn "进入实时追踪，按 Ctrl+C 结束"
                    tail -f /var/log/fail2ban.log
                else
                    warn "未找到 /var/log/fail2ban.log"
                fi
                ;;
            0) return 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# 推荐流程与主菜单
# ─────────────────────────────────────────────
recommended_wizard() {
    step "推荐交互流程"
    show_detect_result
    update_pkg_index
    menu_install_fail2ban
    choose_firewall_backend
    config_base_params
    choose_jails
    preview_config
    write_config
    test_fail2ban_config
    service_enable_start_reload
}

print_summary() {
    printf "\n${BOLD}${GREEN}当前配置摘要${NC}\n"
    printf "  %-18s %s\n" "配置文件:" "$F2B_JAIL_LOCAL"
    printf "  %-18s %s / %s\n" "防火墙后端:" "$BANACTION" "$BANACTION_ALLPORTS"
    printf "  %-18s %s 秒\n" "封禁时长:" "$BAN_TIME"
    printf "  %-18s %s 秒\n" "检测窗口:" "$FIND_TIME"
    printf "  %-18s %s 次\n" "最大失败:" "$MAX_RETRY"
    printf "  %-18s %s\n" "白名单:" "$IGNOREIP"
    printf "  %-18s %s\n" "SSH端口:" "$SSH_FW_PORT"
}

main_menu() {
    while :; do
        printf "\n${BOLD}${BLUE}====== Fail2ban 交互式配置菜单 ======${NC}\n"
        printf "a) 推荐流程：检查 → 安装 → 配置 → 预览 → 写入 → 启动\n"
        printf "1) 查看检测结果/当前参数\n"
        printf "2) 更新软件包列表\n"
        printf "3) 安装/检查 fail2ban\n"
        printf "4) 选择防火墙后端\n"
        printf "5) 配置基础参数\n"
        printf "6) 选择启用的 jail（SSH/Nginx/Caddy）\n"
        printf "7) 预览将写入的配置\n"
        printf "8) 写入配置文件\n"
        printf "9) 语法检查\n"
        printf "10) 启用并启动/重载 fail2ban\n"
        printf "11) 重启 fail2ban\n"
        printf "12) 停用并停止 fail2ban\n"
        printf "13) 查看状态/日志\n"
        printf "14) 防火墙/端口管理（开放、关闭、查看占用）\n"
        printf "r) 重新检测系统/日志/防火墙\n"
        printf "0) 退出\n"
        ask "请选择操作:"
        read -r choice
        case "$choice" in
            a|A) recommended_wizard; pause_enter ;;
            1) show_detect_result; print_summary; pause_enter ;;
            2) update_pkg_index; pause_enter ;;
            3) menu_install_fail2ban; pause_enter ;;
            4) choose_firewall_backend; pause_enter ;;
            5) config_base_params; pause_enter ;;
            6) choose_jails; pause_enter ;;
            7) preview_config; pause_enter ;;
            8) write_config; pause_enter ;;
            9) test_fail2ban_config; pause_enter ;;
            10) service_enable_start_reload; pause_enter ;;
            11) service_restart; pause_enter ;;
            12) service_disable_stop; pause_enter ;;
            13) view_logs_menu ;;
            14) firewall_port_menu ;;
            r|R) initial_detect; pause_enter ;;
            0)
                print_summary
                success "已退出。未选择执行的操作不会被自动执行。"
                exit 0
                ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# 入口
# ─────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    error "请以 root 用户运行此脚本（或使用 sudo）"
    exit 1
fi

initial_detect
main_menu
