#!/bin/bash
# =============================================================
#  warp-go 自动安装脚本（修复版 v2）
#  - warp-go 核心，纯 IPv6 补 v4 / 纯 IPv4 补 v6 / 双栈全接管
#  - 每次安装强制申请新账户
#  - IP 掉线自动重连（systemd Restart + watchdog 服务）
#  - 支持子命令: install / uninstall / status / reinstall
# =============================================================

export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export LANG=en_US.UTF-8

red()    { echo -e "\033[31m\033[01m$1\033[0m"; }
green()  { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
blue()   { echo -e "\033[36m\033[01m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "请以 root 身份运行" && exit 1

# ── 路径常量 ──────────────────────────────────────────────────
WARPGO_BIN="/usr/local/bin/warp-go"
WARPGO_CONF="/usr/local/bin/warp.conf"
WARPGO_SVC="/lib/systemd/system/warp-go.service"
WD_SVC="/lib/systemd/system/warp-go-watchdog.service"
WD_SCRIPT="/usr/local/bin/warp-go-watchdog.sh"
LOGDIR="/var/log/warp-go"
LOGFILE="${LOGDIR}/watchdog.log"
WARP_PUBKEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

# ══════════════════════════════════════════════════════════════
#  系统 & 架构检测
# ══════════════════════════════════════════════════════════════
detect_system() {
    if   grep -qi centos /etc/redhat-release 2>/dev/null; then RELEASE=centos
    elif grep -qi debian /etc/issue          2>/dev/null; then RELEASE=debian
    elif grep -qi ubuntu /etc/issue          2>/dev/null; then RELEASE=ubuntu
    elif grep -qi centos /proc/version       2>/dev/null; then RELEASE=centos
    elif grep -qi debian /proc/version       2>/dev/null; then RELEASE=debian
    elif grep -qi ubuntu /proc/version       2>/dev/null; then RELEASE=ubuntu
    else red "不支持当前系统（需要 Ubuntu / Debian / CentOS）" && exit 1
    fi

    case $(uname -m) in
        x86_64)  ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
        *) red "不支持架构: $(uname -m)" && exit 1 ;;
    esac
}

# ══════════════════════════════════════════════════════════════
#  安装依赖
# ══════════════════════════════════════════════════════════════
install_deps() {
    yellow "检查并安装依赖..."
    if [[ $RELEASE == centos ]]; then
        yum install -y epel-release iproute iputils curl wget
    else
        apt-get update -qq
        apt-get install -y -q iproute2 iputils-ping curl wget openresolv
    fi
}

# ══════════════════════════════════════════════════════════════
#  检测主机 IP 栈
# ══════════════════════════════════════════════════════════════
detect_ip_stack() {
    yellow "检测主机 IP 栈..."
    HOST_V4=$(curl -s4m8 https://icanhazip.com -k 2>/dev/null | tr -d '[:space:]')
    HOST_V6=$(curl -s6m8 https://icanhazip.com -k 2>/dev/null | tr -d '[:space:]')

    if   [[ -n $HOST_V4 && -z $HOST_V6 ]]; then
        IP_STACK=v4only
        green "纯 IPv4 主机 ($HOST_V4) → 添加 WARP IPv6"
    elif [[ -z $HOST_V4 && -n $HOST_V6 ]]; then
        IP_STACK=v6only
        green "纯 IPv6 主机 ($HOST_V6) → 添加 WARP IPv4"
    elif [[ -n $HOST_V4 && -n $HOST_V6 ]]; then
        IP_STACK=dualstack
        green "双栈主机 (v4=$HOST_V4 / v6=$HOST_V6) → 添加 WARP 双栈"
    else
        red "无法获取主机 IP，请检查网络" && exit 1
    fi
}

# ══════════════════════════════════════════════════════════════
#  计算最优 MTU
# ══════════════════════════════════════════════════════════════
calc_mtu() {
    yellow "计算最优 MTU..."
    if [[ $IP_STACK == v6only ]]; then
        PING_BIN=ping6; T1="2606:4700:4700::1111"; T2="2001:4860:4860::8888"
    else
        PING_BIN=ping;  T1="1.1.1.1"; T2="8.8.8.8"
    fi
    M=1500; S=10
    while true; do
        if ${PING_BIN} -c1 -W1 -s$((M-28)) -Mdo $T1 &>/dev/null \
        || ${PING_BIN} -c1 -W1 -s$((M-28)) -Mdo $T2 &>/dev/null; then
            S=1; M=$((M+S))
        else
            M=$((M-S))
            [[ $S -eq 1 ]] && break
        fi
        [[ $M -le 1360 ]] && M=1360 && break
    done
    MTU=$((M-80))
    green "最优 MTU = $MTU"
}

# ══════════════════════════════════════════════════════════════
#  选择 Endpoint
# ══════════════════════════════════════════════════════════════
select_endpoint() {
    [[ $IP_STACK == v6only ]] \
        && ENDPOINT="[2606:4700:d0::a29f:c001]:2408" \
        || ENDPOINT="162.159.192.1:2408"
}

# ══════════════════════════════════════════════════════════════
#  下载 warp-go
# ══════════════════════════════════════════════════════════════
download_warpgo() {
    if [[ -f $WARPGO_BIN ]]; then
        yellow "warp-go 已存在，跳过下载"
        return
    fi
    yellow "下载 warp-go ($ARCH)..."
    wget -q --show-progress \
        "https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_${ARCH}" \
        -O "$WARPGO_BIN" \
    || curl -L --progress-bar \
        "https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_${ARCH}" \
        -o "$WARPGO_BIN" \
    || { red "下载 warp-go 失败"; exit 1; }
    chmod +x "$WARPGO_BIN"
    green "warp-go 下载完成"
}

# ══════════════════════════════════════════════════════════════
#  注册 WARP 账户（每次安装都强制申请新账户）
# ══════════════════════════════════════════════════════════════
register_account() {
    yellow "申请新 WARP 账户（每次安装都重新申请）..."

    local API="/tmp/warpapi_$$"
    curl -Ls --retry 3 \
        "https://gitlab.com/rwkgyg/CFwarp/-/raw/main/point/cpu1/${ARCH}" \
        -o "$API" 2>/dev/null && chmod +x "$API"

    PRIV_KEY=""; DEV_ID=""; WARP_TOKEN=""

    if [[ -x "$API" ]]; then
        local OUT
        OUT=$("$API" 2>/dev/null)
        PRIV_KEY=$(echo  "$OUT" | awk -F': ' '/private_key/{print $2}')
        DEV_ID=$(echo    "$OUT" | awk -F': ' '/device_id/{print $2}')
        WARP_TOKEN=$(echo "$OUT"| awk -F': ' '/token/{print $2}')
    fi
    rm -f "$API"

    # 备用：直接调 Cloudflare 注册 API
    if [[ -z $PRIV_KEY ]]; then
        yellow "工具注册失败，尝试直接调用 Cloudflare API..."
        local TS RESP
        TS=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
        RESP=$(curl -s --retry 3 \
            -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
            -H "User-Agent: okhttp/3.12.1" \
            -H "CF-Client-Version: a-6.30-2158" \
            -H "Content-Type: application/json" \
            -d "{\"key\":\"$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 44)\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"${TS}\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"zh-CN\"}" 2>/dev/null)
        PRIV_KEY=$(echo  "$RESP" | grep -oP '"private_key"\s*:\s*"\K[^"]+')
        DEV_ID=$(echo    "$RESP" | grep -oP '"id"\s*:\s*"\K[^"]+' | head -1)
        WARP_TOKEN=$(echo "$RESP"| grep -oP '"token"\s*:\s*"\K[^"]+')
    fi

    if [[ -z $PRIV_KEY || -z $DEV_ID || -z $WARP_TOKEN ]]; then
        red "账户注册失败！请检查网络后重试"
        exit 1
    fi

    green "账户注册成功 (Device: ${DEV_ID:0:8}...)"
}

# ══════════════════════════════════════════════════════════════
#  生成 warp.conf
#  重要：AllowedIPs 必须在 [Peer] 下；PostUp/Down 在 [Script] 下
# ══════════════════════════════════════════════════════════════
gen_warp_conf() {
    # 停掉旧服务
    systemctl stop warp-go &>/dev/null
    kill -15 "$(pgrep warp-go)" &>/dev/null
    sleep 1

    # AllowedIPs
    case $IP_STACK in
        v4only)    ALLOWED="::/0"               ;;   # 通过 WARP 走 IPv6
        v6only)    ALLOWED="0.0.0.0/0"          ;;   # 通过 WARP 走 IPv4
        dualstack) ALLOWED="0.0.0.0/0, ::/0"   ;;
    esac

    # 获取原生出口 IP（用于路由保留规则）
    SRC4=""; SRC6=""
    if [[ $IP_STACK != v6only ]]; then
        SRC4=$(ip route get 162.159.192.1 2>/dev/null | grep -oP 'src \K\S+')
    fi
    if [[ $IP_STACK != v4only ]]; then
        SRC6=$(ip route get 2606:4700:d0::a29f:c001 2>/dev/null | grep -oP 'src \K\S+')
    fi

    mkdir -p "$(dirname "$WARPGO_CONF")"

    # 写 warp.conf —— AllowedIPs 在 [Peer] 内
    {
        echo "[Account]"
        echo "Device     = ${DEV_ID}"
        echo "PrivateKey = ${PRIV_KEY}"
        echo "Token      = ${WARP_TOKEN}"
        echo "Type       = free"
        echo "Name       = WARP"
        echo "MTU        = ${MTU}"
        echo ""
        echo "[Peer]"
        echo "PublicKey  = ${WARP_PUBKEY}"
        echo "Endpoint   = ${ENDPOINT}"
        echo "AllowedIPs = ${ALLOWED}"
        echo "KeepAlive  = 30"
        echo ""
        echo "[Script]"
        # PostUp/PostDown 保留原生出口路由
        if [[ -n $SRC4 ]]; then
            echo "PostUp   = ip -4 rule add    from ${SRC4} lookup main"
            echo "PostDown = ip -4 rule delete from ${SRC4} lookup main"
        fi
        if [[ -n $SRC6 ]]; then
            echo "PostUp   = ip -6 rule add    from ${SRC6} lookup main"
            echo "PostDown = ip -6 rule delete from ${SRC6} lookup main"
        fi
    } > "$WARPGO_CONF"

    chmod 600 "$WARPGO_CONF"
    green "warp.conf 生成完毕"
    yellow "── warp.conf 内容 ──────────────────"
    cat "$WARPGO_CONF"
    yellow "────────────────────────────────────"
}

# ══════════════════════════════════════════════════════════════
#  安装 warp-go systemd 服务
# ══════════════════════════════════════════════════════════════
install_warpgo_service() {
    cat > "$WARPGO_SVC" <<EOF
[Unit]
Description=WARP-GO Tunnel
After=network.target network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/root/
ExecStart=${WARPGO_BIN} --config=${WARPGO_CONF}
Environment=LOG_LEVEL=verbose
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-go
    systemctl restart warp-go
    sleep 5
    green "warp-go 服务已启动"
}

# ══════════════════════════════════════════════════════════════
#  Watchdog 服务（掉线自动重连）
# ══════════════════════════════════════════════════════════════
install_watchdog() {
    mkdir -p "$LOGDIR"
    cat > "$WD_SCRIPT" <<'WDEOF'
#!/bin/bash
LOGFILE="/var/log/warp-go/watchdog.log"
CHECK_OK=600
CHECK_FAIL=30
MAX_FAILS=5

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

check_warp() {
    local v4 v6
    v4=$(curl -s4m10 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep '^warp=' | cut -d= -f2)
    v6=$(curl -s6m10 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep '^warp=' | cut -d= -f2)
    [[ $v4 =~ on|plus || $v6 =~ on|plus ]]
}

fail=0
while true; do
    if check_warp; then
        log "WARP 正常 [v4=${v4:-N/A} v6=${v6:-N/A}]，${CHECK_OK}s 后复查"
        fail=0
        sleep $CHECK_OK
    else
        fail=$((fail+1))
        log "WARP 掉线！第 ${fail}/${MAX_FAILS} 次，重启中..."
        systemctl restart warp-go
        sleep 12
        if check_warp; then
            log "重连成功！"
            fail=0; sleep $CHECK_OK
        elif [[ $fail -ge $MAX_FAILS ]]; then
            log "连续 ${MAX_FAILS} 次失败，暂停 10 分钟后重试"
            systemctl stop warp-go; sleep 600
            log "重新启动 WARP..."
            systemctl start warp-go; sleep 15; fail=0
        else
            sleep $CHECK_FAIL
        fi
    fi
done
WDEOF
    chmod +x "$WD_SCRIPT"

    cat > "$WD_SVC" <<EOF
[Unit]
Description=WARP-GO Watchdog (auto-reconnect)
After=warp-go.service

[Service]
ExecStart=${WD_SCRIPT}
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable  warp-go-watchdog
    systemctl restart warp-go-watchdog
    green "Watchdog 已启动"
}

# ══════════════════════════════════════════════════════════════
#  固定 DNS
# ══════════════════════════════════════════════════════════════
lock_dns() {
    chattr -i /etc/resolv.conf &>/dev/null
    [[ ! -f /etc/resolv.conf.bak ]] && cp /etc/resolv.conf /etc/resolv.conf.bak
    cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
    chattr +i /etc/resolv.conf &>/dev/null
    green "DNS 已锁定"
}

prefer_ipv4() {
    grep -qE '^ *precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null \
    || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
}

# ══════════════════════════════════════════════════════════════
#  验证上线
# ══════════════════════════════════════════════════════════════
verify_warp() {
    yellow "等待 WARP 上线（最多 60 秒）..."
    local wv4 wv6
    for i in $(seq 1 12); do
        sleep 5
        wv4=$(curl -s4m10 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep '^warp=' | cut -d= -f2)
        wv6=$(curl -s6m10 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep '^warp=' | cut -d= -f2)
        if [[ $wv4 =~ on|plus || $wv6 =~ on|plus ]]; then
            green "✓ WARP 上线成功！(v4=${wv4:-N/A} / v6=${wv6:-N/A})"
            show_status
            return 0
        fi
        yellow "第 $i/12 次检测..."
    done
    red "✗ WARP 60 秒内未上线"
    red "  查看日志 : journalctl -u warp-go -n 30 --no-pager"
    red "  查看配置 : cat ${WARPGO_CONF}"
    red "  重新安装 : bash $0 reinstall"
    return 1
}

# ══════════════════════════════════════════════════════════════
#  状态显示
# ══════════════════════════════════════════════════════════════
show_status() {
    echo
    blue "════════════ WARP 状态 ════════════"
    local v4 v6 wv4 wv6
    v4=$(curl  -s4m8 https://icanhazip.com -k 2>/dev/null | tr -d '[:space:]')
    v6=$(curl  -s6m8 https://icanhazip.com -k 2>/dev/null | tr -d '[:space:]')
    wv4=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep '^warp=' | cut -d= -f2)
    wv6=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep '^warp=' | cut -d= -f2)
    [[ -n $v4 ]] && green  "  IPv4 出口 : $v4  [WARP: ${wv4:-off}]" || yellow "  IPv4 出口 : 无"
    [[ -n $v6 ]] && green  "  IPv6 出口 : $v6  [WARP: ${wv6:-off}]" || yellow "  IPv6 出口 : 无"
    echo
    [[ $(systemctl is-active warp-go)          == active ]] && green "  warp-go          : 运行中 ✓" || red  "  warp-go          : 未运行 ✗"
    [[ $(systemctl is-active warp-go-watchdog) == active ]] && green "  warp-go-watchdog : 运行中 ✓" || red  "  warp-go-watchdog : 未运行 ✗"
    blue "════════════════════════════════════"
    echo
    blue "常用命令:"
    echo "  实时日志 : journalctl -u warp-go -f"
    echo "  Watchdog : tail -f ${LOGFILE}"
    echo "  重启     : systemctl restart warp-go"
    echo "  停止     : systemctl stop warp-go warp-go-watchdog"
    echo "  重装     : bash \$0 reinstall"
    echo "  卸载     : bash \$0 uninstall"
}

# ══════════════════════════════════════════════════════════════
#  卸载
# ══════════════════════════════════════════════════════════════
uninstall() {
    yellow "正在卸载 WARP-GO..."
    systemctl stop    warp-go warp-go-watchdog &>/dev/null
    systemctl disable warp-go warp-go-watchdog &>/dev/null
    kill -15 "$(pgrep warp-go)" &>/dev/null
    rm -f "$WARPGO_BIN" "$WARPGO_CONF" "$WARPGO_SVC" "$WD_SVC" "$WD_SCRIPT"
    systemctl daemon-reload
    chattr -i /etc/resolv.conf &>/dev/null
    [[ -f /etc/resolv.conf.bak ]] \
        && cp /etc/resolv.conf.bak /etc/resolv.conf && green "DNS 已恢复" \
        || yellow "DNS 备份不存在，请手动检查 /etc/resolv.conf"
    sed -i '/^precedence ::ffff:0:0\/96  100/d' /etc/gai.conf &>/dev/null
    rm -rf "$LOGDIR"
    green "卸载完成 ✓"
}

# ══════════════════════════════════════════════════════════════
#  主入口
# ══════════════════════════════════════════════════════════════
do_install() {
    green "════════════════════════════════════════"
    green "   warp-go 自动安装脚本（修复版 v2）"
    green "════════════════════════════════════════"
    echo
    detect_system
    install_deps
    detect_ip_stack
    calc_mtu
    select_endpoint
    download_warpgo
    register_account
    gen_warp_conf
    install_warpgo_service
    install_watchdog
    lock_dns
    prefer_ipv4
    verify_warp
}

case "${1:-install}" in
    install)            do_install ;;
    reinstall)          uninstall && do_install ;;
    uninstall|remove)   uninstall ;;
    status)             show_status ;;
    *)
        echo "用法: bash $0 [install|reinstall|uninstall|status]"
        echo "  install   - 安装（默认）"
        echo "  reinstall - 卸载后重新安装（换新账号）"
        echo "  uninstall - 完全卸载"
        echo "  status    - 查看运行状态"
        ;;
esac
