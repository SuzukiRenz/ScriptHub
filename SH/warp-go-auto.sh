#!/bin/bash
# =============================================================
#  warp-go 自动安装脚本（精简优化版）
#  功能：
#    - 仅使用 warp-go 核心
#    - 自动识别主机 IP 栈：
#        纯 IPv6 → 自动添加 WARP IPv4
#        纯 IPv4 → 自动添加 WARP IPv6
#        双栈    → 添加 WARP 双栈
#    - IP 掉线自动重连（systemd Restart + 独立 watchdog 服务）
#    - 全程后台运行，无需交互
# =============================================================

export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export LANG=en_US.UTF-8

# ---------- 颜色输出 ----------
red()    { echo -e "\033[31m\033[01m$1\033[0m"; }
green()  { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
blue()   { echo -e "\033[36m\033[01m$1\033[0m"; }

# ---------- 权限检查 ----------
[[ $EUID -ne 0 ]] && red "请以 root 身份运行此脚本" && exit 1

# ---------- 常量 ----------
WARPGO_BIN="/usr/local/bin/warp-go"
WARPGO_CONF="/usr/local/bin/warp.conf"
WARPGO_SERVICE="/lib/systemd/system/warp-go.service"
WATCHDOG_SERVICE="/lib/systemd/system/warp-go-watchdog.service"
WATCHDOG_SCRIPT="/usr/local/bin/warp-go-watchdog.sh"
LOGDIR="/var/log/warp-go"
LOGFILE="${LOGDIR}/watchdog.log"
WARP_PUBKEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

# ---------- 系统/架构检测 ----------
detect_system() {
    if   grep -qi centos  /etc/redhat-release 2>/dev/null; then release="centos"
    elif grep -qi debian  /etc/issue 2>/dev/null;          then release="debian"
    elif grep -qi ubuntu  /etc/issue 2>/dev/null;          then release="ubuntu"
    elif grep -qi centos  /proc/version 2>/dev/null;       then release="centos"
    elif grep -qi debian  /proc/version 2>/dev/null;       then release="debian"
    elif grep -qi ubuntu  /proc/version 2>/dev/null;       then release="ubuntu"
    else red "不支持当前系统，请使用 Ubuntu / Debian / CentOS" && exit 1
    fi

    case $(uname -m) in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) red "不支持架构: $(uname -m)" && exit 1 ;;
    esac

    case "$release" in
        centos) PKG="yum -y" ;;
        *)      PKG="apt-get -y" ;;
    esac
}

# ---------- 安装依赖 ----------
install_deps() {
    yellow "安装依赖..."
    if [[ $release == centos ]]; then
        yum install -y epel-release iproute iputils curl wget
    else
        apt-get update -y
        apt-get install -y iproute2 iputils-ping curl wget openresolv dnsutils
    fi
}

# ---------- 检测主机 IP 栈 ----------
detect_ip_stack() {
    yellow "检测主机 IP 栈..."
    HOST_V4=$(curl -s4m8 https://icanhazip.com -k 2>/dev/null | tr -d '[:space:]')
    HOST_V6=$(curl -s6m8 https://icanhazip.com -k 2>/dev/null | tr -d '[:space:]')

    if   [[ -n $HOST_V4 && -z $HOST_V6 ]]; then
        IP_STACK="v4only"
        green "检测到纯 IPv4 主机 ($HOST_V4)，将添加 WARP IPv6"
    elif [[ -z $HOST_V4 && -n $HOST_V6 ]]; then
        IP_STACK="v6only"
        green "检测到纯 IPv6 主机 ($HOST_V6)，将添加 WARP IPv4"
    elif [[ -n $HOST_V4 && -n $HOST_V6 ]]; then
        IP_STACK="dualstack"
        green "检测到双栈主机 (v4=$HOST_V4 v6=$HOST_V6)，将添加 WARP 双栈"
    else
        red "无法获取主机 IP，请检查网络" && exit 1
    fi
}

# ---------- 计算最优 MTU ----------
calc_mtu() {
    yellow "计算最优 MTU..."
    if [[ $IP_STACK == "v6only" ]]; then
        PING_CMD="ping6"; TEST_IP1="2606:4700:4700::1111"; TEST_IP2="2001:4860:4860::8888"
    else
        PING_CMD="ping";  TEST_IP1="1.1.1.1"; TEST_IP2="8.8.8.8"
    fi
    MTU_VAL=1500; STEP=10
    while true; do
        if ${PING_CMD} -c1 -W1 -s$((MTU_VAL - 28)) -Mdo ${TEST_IP1} &>/dev/null \
        || ${PING_CMD} -c1 -W1 -s$((MTU_VAL - 28)) -Mdo ${TEST_IP2} &>/dev/null; then
            STEP=1; MTU_VAL=$((MTU_VAL + STEP))
        else
            MTU_VAL=$((MTU_VAL - STEP))
            [[ $STEP -eq 1 ]] && break
        fi
        [[ $MTU_VAL -le 1360 ]] && MTU_VAL=1360 && break
    done
    MTU=$((MTU_VAL - 80))
    green "最优 MTU = $MTU"
}

# ---------- 选择 Endpoint ----------
select_endpoint() {
    if [[ $IP_STACK == "v6only" ]]; then
        ENDPOINT="[2606:4700:d0::a29f:c001]:2408"
    else
        ENDPOINT="162.159.192.1:2408"
    fi
}

# ---------- 下载 warp-go 二进制 ----------
download_warpgo() {
    if [[ -f $WARPGO_BIN ]]; then
        yellow "warp-go 已存在，跳过下载"
        return
    fi
    yellow "下载 warp-go ($ARCH)..."
    local URL="https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_${ARCH}"
    wget -q --show-progress -O "$WARPGO_BIN" "$URL" \
    || curl -L --progress-bar -o "$WARPGO_BIN" "$URL" \
    || { red "下载 warp-go 失败"; exit 1; }
    chmod +x "$WARPGO_BIN"
    green "warp-go 下载完成"
}

# ---------- 注册 WARP 账户 & 生成配置 ----------
gen_warp_conf() {
    if [[ -s $WARPGO_CONF ]]; then
        yellow "已存在 warp.conf，跳过账户注册"
        return
    fi
    yellow "正在注册 WARP 普通账户..."

    # 尝试通过 API 工具注册
    local APIBIN="/tmp/warpapi"
    curl -Ls --retry 2 -o "$APIBIN" \
        "https://gitlab.com/rwkgyg/CFwarp/-/raw/main/point/cpu1/${ARCH}" 2>/dev/null \
    && chmod +x "$APIBIN"

    if [[ -x "$APIBIN" ]]; then
        local OUT; OUT=$("$APIBIN" 2>/dev/null)
        PRIV_KEY=$(echo "$OUT" | awk -F': ' '/private_key/{print $2}')
        DEV_ID=$(echo  "$OUT" | awk -F': ' '/device_id/{print $2}')
        WARP_TOKEN=$(echo "$OUT" | awk -F': ' '/token/{print $2}')
        rm -f "$APIBIN"
    fi

    # 回退：写入占位配置（手动填写）
    if [[ -z $PRIV_KEY ]]; then
        yellow "自动注册失败，写入模板配置（需手动填写 PrivateKey / Device / Token）"
        PRIV_KEY="<YOUR_PRIVATE_KEY>"; DEV_ID="<YOUR_DEVICE_ID>"; WARP_TOKEN="<YOUR_TOKEN>"
    fi

    mkdir -p "$(dirname $WARPGO_CONF)"
    cat > "$WARPGO_CONF" <<EOF
[Account]
Device     = ${DEV_ID}
PrivateKey = ${PRIV_KEY}
Token      = ${WARP_TOKEN}
Type       = free
Name       = WARP
MTU        = ${MTU}

[Peer]
PublicKey  = ${WARP_PUBKEY}
Endpoint   = ${ENDPOINT}
KeepAlive  = 30

[Script]
EOF
    chmod 600 "$WARPGO_CONF"
    green "warp.conf 生成完毕"
}

# ---------- 设置 AllowedIPs 与路由规则 ----------
configure_routes() {
    yellow "配置路由规则 (IP_STACK=$IP_STACK)..."

    # 先清理旧的 AllowedIPs 行与 PostUp/PostDown
    sed -i '/AllowedIPs/d;/PostUp/d;/PostDown/d' "$WARPGO_CONF"

    case $IP_STACK in
      v4only)
        # 纯 IPv4 主机：通过 WARP 走 IPv6 流量，保留原 IPv4 出口
        SRC4=$(ip route get 162.159.192.1 2>/dev/null | grep -oP 'src \K\S+')
        sed -i "/\[Script\]/a AllowedIPs = ::/0" "$WARPGO_CONF"
        [[ -n $SRC4 ]] && sed -i "/\[Script\]/a PostUp   = ip -4 rule add    from ${SRC4} lookup main\nPostDown  = ip -4 rule delete from ${SRC4} lookup main" "$WARPGO_CONF"
        ;;
      v6only)
        # 纯 IPv6 主机：通过 WARP 走 IPv4 流量，保留原 IPv6 出口
        SRC6=$(ip route get 2606:4700:d0::a29f:c001 2>/dev/null | grep -oP 'src \K\S+')
        sed -i "/\[Script\]/a AllowedIPs = 0.0.0.0/0" "$WARPGO_CONF"
        [[ -n $SRC6 ]] && sed -i "/\[Script\]/a PostUp   = ip -6 rule add    from ${SRC6} lookup main\nPostDown  = ip -6 rule delete from ${SRC6} lookup main" "$WARPGO_CONF"
        ;;
      dualstack)
        # 双栈：WARP 同时接管 IPv4 + IPv6
        SRC4=$(ip route get 162.159.192.1       2>/dev/null | grep -oP 'src \K\S+')
        SRC6=$(ip route get 2606:4700:d0::a29f:c001 2>/dev/null | grep -oP 'src \K\S+')
        sed -i "/\[Script\]/a AllowedIPs = 0.0.0.0/0,::/0" "$WARPGO_CONF"
        [[ -n $SRC4 ]] && sed -i "/\[Script\]/a PostUp   = ip -4 rule add    from ${SRC4} lookup main\nPostDown  = ip -4 rule delete from ${SRC4} lookup main" "$WARPGO_CONF"
        [[ -n $SRC6 ]] && sed -i "/\[Script\]/a PostUp   = ip -6 rule add    from ${SRC6} lookup main\nPostDown  = ip -6 rule delete from ${SRC6} lookup main" "$WARPGO_CONF"
        ;;
    esac
    green "路由规则配置完毕"
}

# ---------- 固定 DNS 防止解析被劫持 ----------
lock_dns() {
    if [[ ! -f /etc/resolv.conf.bak ]]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
    fi
    chattr -i /etc/resolv.conf &>/dev/null
    cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
    chattr +i /etc/resolv.conf &>/dev/null
    green "DNS 已锁定"
}

# ---------- 优先使用 IPv4（解决双栈优先级问题） ----------
prefer_ipv4() {
    grep -qE '^ *precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null \
    || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
}

# ---------- 安装 warp-go systemd 服务 ----------
install_warpgo_service() {
    cat > "$WARPGO_SERVICE" <<EOF
[Unit]
Description=WARP-GO Tunnel
After=network.target network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/root/
ExecStart=${WARPGO_BIN} --config=${WARPGO_CONF}
Environment=LOG_LEVEL=verbose
Restart=always
RestartSec=10
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-go
    systemctl restart warp-go
    green "warp-go 服务已启动并设置开机自启"
}

# ---------- 写入 Watchdog 脚本 ----------
write_watchdog() {
    mkdir -p "$LOGDIR"
    cat > "$WATCHDOG_SCRIPT" <<'WDEOF'
#!/bin/bash
# warp-go watchdog：检测 WARP IP 状态，掉线自动重连

LOGFILE="/var/log/warp-go/watchdog.log"
MAX_FAILS=5        # 连续失败次数上限，超过则停止 WARP 恢复原 IP
CHECK_OK=600       # 正常时检测间隔（秒）
CHECK_FAIL=30      # 失败时重试间隔（秒）

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

check_warp() {
    wgcfv4=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
    wgcfv6=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
    [[ $wgcfv4 =~ on|plus || $wgcfv6 =~ on|plus ]]
}

restart_warp() {
    log "尝试重启 warp-go..."
    kill -15 "$(pgrep warp-go)" &>/dev/null
    sleep 3
    systemctl restart warp-go
    sleep 8
}

fail_count=0

while true; do
    if check_warp; then
        log "WARP 运行正常 (v4=${wgcfv4:-N/A} v6=${wgcfv6:-N/A})，${CHECK_OK}s 后复查"
        fail_count=0
        sleep $CHECK_OK
    else
        fail_count=$((fail_count + 1))
        log "WARP 连接异常！第 ${fail_count}/${MAX_FAILS} 次失败，尝试重连..."
        restart_warp

        if check_warp; then
            log "WARP 重连成功！"
            fail_count=0
            sleep $CHECK_OK
        else
            if [[ $fail_count -ge $MAX_FAILS ]]; then
                log "连续 ${MAX_FAILS} 次失败，停止 WARP，恢复原始 IP"
                systemctl stop  warp-go
                systemctl disable warp-go
                fail_count=0
                # 等待 10 分钟后再尝试重新启动
                sleep 600
                log "10 分钟后重新尝试启动 WARP..."
                systemctl enable warp-go
                systemctl start  warp-go
                sleep 30
            else
                sleep $CHECK_FAIL
            fi
        fi
    fi
done
WDEOF
    chmod +x "$WATCHDOG_SCRIPT"
    green "Watchdog 脚本写入完毕: $WATCHDOG_SCRIPT"
}

# ---------- 安装 Watchdog systemd 服务 ----------
install_watchdog_service() {
    cat > "$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=WARP-GO Watchdog (auto-reconnect)
After=warp-go.service
Requires=warp-go.service

[Service]
ExecStart=${WATCHDOG_SCRIPT}
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-go-watchdog
    systemctl restart warp-go-watchdog
    green "Watchdog 服务已启动并设置开机自启"
}

# ---------- 验证 WARP 是否上线 ----------
verify_warp() {
    yellow "等待 WARP 上线，最多尝试 10 次..."
    for i in $(seq 1 10); do
        sleep 5
        wgcfv4=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
        wgcfv6=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
        if [[ $wgcfv4 =~ on|plus || $wgcfv6 =~ on|plus ]]; then
            green "✓ WARP 上线成功！(第 $i 次)"
            show_status
            return 0
        fi
        yellow "第 $i/10 次检测中..."
        systemctl restart warp-go &>/dev/null
    done
    red "✗ WARP 上线失败，请检查 warp.conf 或网络环境"
    red "  日志: journalctl -u warp-go -n 50"
    return 1
}

# ---------- 显示当前状态 ----------
show_status() {
    echo
    blue "======== WARP 状态概览 ========"
    local v4 v6 wv4 wv6
    v4=$(curl  -s4m8 icanhazip.com -k 2>/dev/null | tr -d '[:space:]')
    v6=$(curl  -s6m8 icanhazip.com -k 2>/dev/null | tr -d '[:space:]')
    wv4=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
    wv6=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2)
    [[ -n $v4  ]] && green  "  出口 IPv4 : $v4  (WARP状态: ${wv4:-off})" || yellow "  出口 IPv4 : 无"
    [[ -n $v6  ]] && green  "  出口 IPv6 : $v6  (WARP状态: ${wv6:-off})" || yellow "  出口 IPv6 : 无"
    blue "================================"
    echo
    green "服务状态:"
    systemctl is-active warp-go          && green "  warp-go          : 运行中" || red   "  warp-go          : 未运行"
    systemctl is-active warp-go-watchdog && green "  warp-go-watchdog : 运行中" || red   "  warp-go-watchdog : 未运行"
    echo
    blue "常用命令:"
    echo "  查看 warp-go 日志  : journalctl -u warp-go -f"
    echo "  查看 watchdog 日志 : tail -f ${LOGFILE}"
    echo "  重启 warp-go       : systemctl restart warp-go"
    echo "  停止 WARP          : systemctl stop warp-go warp-go-watchdog"
    echo "  卸载 WARP          : bash $0 uninstall"
}

# ---------- 卸载 ----------
uninstall() {
    yellow "正在卸载 WARP-GO..."
    systemctl stop    warp-go warp-go-watchdog &>/dev/null
    systemctl disable warp-go warp-go-watchdog &>/dev/null
    kill -15 "$(pgrep warp-go)" &>/dev/null
    rm -f "$WARPGO_BIN" "$WARPGO_CONF" "$WARPGO_SERVICE" \
          "$WATCHDOG_SERVICE" "$WATCHDOG_SCRIPT"
    systemctl daemon-reload
    chattr -i /etc/resolv.conf &>/dev/null
    [[ -f /etc/resolv.conf.bak ]] && cp /etc/resolv.conf.bak /etc/resolv.conf
    sed -i '/^precedence ::ffff:0:0\/96  100/d' /etc/gai.conf &>/dev/null
    rm -rf "$LOGDIR"
    green "WARP-GO 已完全卸载"
}

# ============================================================
#  主流程
# ============================================================
main() {
    case "${1:-}" in
        uninstall|remove) uninstall; exit 0 ;;
        status)           show_status; exit 0 ;;
    esac

    green "========================================"
    green "   warp-go 自动安装脚本（精简优化版）"
    green "========================================"
    echo

    detect_system
    install_deps
    detect_ip_stack
    calc_mtu
    select_endpoint
    download_warpgo
    gen_warp_conf
    configure_routes
    install_warpgo_service
    write_watchdog
    install_watchdog_service
    lock_dns
    prefer_ipv4
    verify_warp
}

main "$@"
