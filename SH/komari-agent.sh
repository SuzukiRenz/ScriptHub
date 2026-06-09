#!/bin/bash

# Komari Agent installation script with interactive menu fallback.
# Behavior:
#   - If agent arguments are provided, install and enable monitoring directly (compatible with original install.sh).
#   - If no agent arguments are provided, show a guided menu for install/uninstall/status and SSH quick menu setup.
#   wget -O /usr/local/bin/komari-agent.sh https://raw.githubusercontent.com/SuzukiRenz/ScriptHub/refs/heads/main/SH/komari-agent.sh && chmod +x /usr/local/bin/komari-agent.sh && komari-agent.sh --install-menu-shortcut
#   SSH 里输入 komari-agent-menu 就能唤出菜单
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

log_info() { echo -e "${NC} $1"; }
log_success() { echo -e "${GREEN}${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${NC} $1"; }
log_config() { echo -e "${CYAN}[CONFIG]${NC} $1"; }

service_name="komari-agent"
target_dir="/opt/komari"
github_proxy=""
install_version=""
quick_menu_command="komari-agent-menu"
quick_menu_path="/usr/local/bin/${quick_menu_command}"
script_self_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
komari_args=""
explicit_agent_args=false

os_type=$(uname -s)
case $os_type in
    Darwin)
        os_name="darwin"
        target_dir="/usr/local/komari"
        if [ ! -w "/usr/local" ] && [ "$EUID" -ne 0 ]; then
            target_dir="$HOME/.komari"
            log_info "No write permission to /usr/local, using user directory: $target_dir"
        fi
        ;;
    Linux) os_name="linux" ;;
    FreeBSD) os_name="freebsd" ;;
    MINGW*|MSYS*|CYGWIN*) os_name="windows"; target_dir="/c/komari" ;;
    *) log_error "Unsupported operating system: $os_type"; exit 1 ;;
esac

usage() {
    cat <<EOF
Komari Agent 增强安装脚本

用法：
  $0                         无监控参数时进入菜单引导
  $0 [agent 参数...]          有监控参数时直接安装并启用监控
  $0 --menu                  强制打开菜单
  $0 --uninstall             卸载 Komari Agent
  $0 --status                查看服务状态
  $0 --install-menu-shortcut 安装 SSH 快捷菜单命令：${quick_menu_command}

原 install 参数仍兼容：
  --install-dir DIR
  --install-service-name NAME
  --install-ghproxy URL
  --install-version VERSION
EOF
}

parse_args() {
    force_menu=false
    action=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --install-dir)
                target_dir="$2"; shift 2 ;;
            --install-service-name)
                service_name="$2"; shift 2 ;;
            --install-ghproxy)
                github_proxy="$2"; shift 2 ;;
            --install-version)
                install_version="$2"; shift 2 ;;
            --menu)
                force_menu=true; shift ;;
            --uninstall)
                action="uninstall"; shift ;;
            --status)
                action="status"; shift ;;
            --install-menu-shortcut)
                action="install_shortcut"; shift ;;
            --help|-h)
                usage; exit 0 ;;
            --install*)
                log_warning "Unknown install parameter: $1"; shift ;;
            *)
                komari_args="$komari_args $1"
                explicit_agent_args=true
                shift ;;
        esac
    done

    komari_args="${komari_args# }"
    komari_agent_path="${target_dir}/agent"
}

if [ "$os_name" = "darwin" ] && command -v brew >/dev/null 2>&1; then
    require_root_for_deps=false
else
    require_root_for_deps=true
fi

require_root() {
    if [ "$EUID" -ne 0 ] && [ "$require_root_for_deps" = true ]; then
        log_error "Please run as root"
        exit 1
    fi
}

detect_init_system() {
    if [ -f /etc/NIXOS ]; then echo "nixos"; return; fi
    if [ -f /etc/alpine-release ]; then
        if command -v rc-service >/dev/null 2>&1 || [ -f /sbin/openrc-run ]; then echo "openrc"; return; fi
    fi

    local pid1_process
    pid1_process=$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')

    if [ "$pid1_process" = "systemd" ] || [ -d /run/systemd/system ]; then
        if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then echo "systemd"; return; fi
    fi
    if [ "$pid1_process" = "openrc-init" ] && command -v rc-service >/dev/null 2>&1; then echo "openrc"; return; fi
    if [ "$pid1_process" = "init" ] && [ ! -f /etc/alpine-release ]; then
        if [ -d /run/openrc ] && command -v rc-service >/dev/null 2>&1; then echo "openrc"; return; fi
        if [ -f /sbin/openrc ] && command -v rc-service >/dev/null 2>&1; then echo "openrc"; return; fi
    fi
    if command -v uci >/dev/null 2>&1 && [ -f /etc/rc.common ]; then echo "procd"; return; fi
    if [ "$os_name" = "darwin" ] && command -v launchctl >/dev/null 2>&1; then echo "launchd"; return; fi
    if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then echo "systemd"; return; fi
    if command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ]; then echo "openrc"; return; fi
    if command -v initctl >/dev/null 2>&1 && [ -d /etc/init ]; then echo "upstart"; return; fi
    echo "unknown"
}

uninstall_previous() {
    log_step "Checking for previous installation..."

    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "${service_name}.service"; then
        log_info "Stopping and disabling existing systemd service..."
        systemctl stop ${service_name}.service 2>/dev/null || true
        systemctl disable ${service_name}.service 2>/dev/null || true
        rm -f "/etc/systemd/system/${service_name}.service"
        systemctl daemon-reload 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1 && [ -f "/etc/init.d/${service_name}" ]; then
        log_info "Stopping and disabling existing OpenRC service..."
        rc-service ${service_name} stop 2>/dev/null || true
        rc-update del ${service_name} default 2>/dev/null || true
        rm -f "/etc/init.d/${service_name}"
    elif command -v uci >/dev/null 2>&1 && [ -f "/etc/init.d/${service_name}" ]; then
        log_info "Stopping and disabling existing procd service..."
        /etc/init.d/${service_name} stop 2>/dev/null || true
        /etc/init.d/${service_name} disable 2>/dev/null || true
        rm -f "/etc/init.d/${service_name}"
    elif command -v initctl >/dev/null 2>&1 && [ -f "/etc/init/${service_name}.conf" ]; then
        log_info "Stopping and removing existing upstart service..."
        initctl stop ${service_name} 2>/dev/null || true
        rm -f "/etc/init/${service_name}.conf"
    elif [ "$os_name" = "darwin" ] && command -v launchctl >/dev/null 2>&1; then
        system_plist="/Library/LaunchDaemons/com.komari.${service_name}.plist"
        user_plist="$HOME/Library/LaunchAgents/com.komari.${service_name}.plist"
        if [ -f "$system_plist" ]; then
            log_info "Stopping and removing existing system launchd service..."
            launchctl bootout system "$system_plist" 2>/dev/null || true
            rm -f "$system_plist"
        fi
        if [ -f "$user_plist" ]; then
            log_info "Stopping and removing existing user launchd service..."
            launchctl bootout gui/$(id -u) "$user_plist" 2>/dev/null || true
            rm -f "$user_plist"
        fi
    fi

    if [ -f "$komari_agent_path" ]; then
        log_info "Removing old binary..."
        rm -f "$komari_agent_path"
    fi
}

uninstall_agent() {
    require_root
    uninstall_previous
    rm -rf "$target_dir"
    log_success "Komari Agent 已卸载：${service_name}"
}

install_dependencies() {
    log_step "Checking and installing dependencies..."

    local deps="curl"
    local missing_deps=""
    for cmd in $deps; do
        if ! command -v $cmd >/dev/null 2>&1; then missing_deps="$missing_deps $cmd"; fi
    done

    if [ -n "$missing_deps" ]; then
        if command -v apt >/dev/null 2>&1; then
            log_info "Using apt to install dependencies..."; apt update; apt install -y $missing_deps
        elif command -v yum >/dev/null 2>&1; then
            log_info "Using yum to install dependencies..."; yum install -y $missing_deps
        elif command -v apk >/dev/null 2>&1; then
            log_info "Using apk to install dependencies..."; apk add $missing_deps
        elif command -v brew >/dev/null 2>&1; then
            log_info "Using Homebrew to install dependencies..."; brew install $missing_deps
        else
            log_error "No supported package manager found (apt/yum/apk/brew)"; exit 1
        fi
        for cmd in $missing_deps; do
            if ! command -v $cmd >/dev/null 2>&1; then log_error "Failed to install $cmd"; exit 1; fi
        done
        log_success "Dependencies installed successfully"
    else
        log_success "Dependencies already satisfied"
    fi
}

detect_arch() {
    arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        i386|i686)
            case $os_name in freebsd|linux|windows) arch="386" ;; *) log_error "32-bit x86 architecture not supported on $os_name"; exit 1 ;; esac ;;
        armv7*|armv6*)
            case $os_name in freebsd|linux) arch="arm" ;; *) log_error "32-bit ARM architecture not supported on $os_name"; exit 1 ;; esac ;;
        *) log_error "Unsupported architecture: $arch on $os_name"; exit 1 ;;
    esac
    log_info "Detected OS: ${GREEN}$os_name${NC}, Architecture: ${GREEN}$arch${NC}"
}

install_service() {
    init_system=$(detect_init_system)
    log_info "Detected init system: ${GREEN}$init_system${NC}"

    if [ "$init_system" = "nixos" ]; then
        log_warning "NixOS detected. System services must be configured declaratively."
        cat <<EOF

systemd.services.${service_name} = {
  description = "Komari Agent Service";
  after = [ "network.target" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "simple";
    ExecStart = "${komari_agent_path} ${komari_args}";
    WorkingDirectory = "${target_dir}";
    Restart = "always";
    User = "root";
  };
};

EOF
        log_warning "Service not started automatically on NixOS. Please rebuild your configuration."
    elif [ "$init_system" = "openrc" ]; then
        service_file="/etc/init.d/${service_name}"
        cat > "$service_file" <<EOF
#!/sbin/openrc-run
name="Komari Agent Service"
description="Komari monitoring agent"
command="${komari_agent_path}"
command_args="${komari_args}"
command_user="root"
directory="${target_dir}"
pidfile="/run/${service_name}.pid"
retry="SIGTERM/30"
supervisor=supervise-daemon

depend() {
    need net
    after network
}
EOF
        chmod +x "$service_file"
        rc-update add ${service_name} default
        rc-service ${service_name} start
        log_success "OpenRC service configured and started"
    elif [ "$init_system" = "systemd" ]; then
        service_file="/etc/systemd/system/${service_name}.service"
        cat > "$service_file" <<EOF
[Unit]
Description=Komari Agent Service
After=network.target

[Service]
Type=simple
ExecStart=${komari_agent_path} ${komari_args}
WorkingDirectory=${target_dir}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${service_name}.service
        systemctl start ${service_name}.service
        log_success "Systemd service configured and started"
    elif [ "$init_system" = "procd" ]; then
        service_file="/etc/init.d/${service_name}"
        cat > "$service_file" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
PROG="${komari_agent_path}"
ARGS="${komari_args}"

start_service() {
    procd_open_instance
    procd_set_param command \$PROG \$ARGS
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param user root
    procd_close_instance
}

stop_service() {
    killall \$(basename \$PROG)
}

reload_service() {
    stop
    start
}
EOF
        chmod +x "$service_file"
        /etc/init.d/${service_name} enable
        /etc/init.d/${service_name} start
        log_success "procd service configured and started"
    elif [ "$init_system" = "launchd" ]; then
        if [[ "$target_dir" =~ ^/Users/.* ]] || [ "$EUID" -ne 0 ]; then
            plist_dir="$HOME/Library/LaunchAgents"
            plist_file="$plist_dir/com.komari.${service_name}.plist"
            service_user="$(whoami)"
            log_dir="$HOME/Library/Logs"
            mkdir -p "$plist_dir"
        else
            plist_dir="/Library/LaunchDaemons"
            plist_file="$plist_dir/com.komari.${service_name}.plist"
            service_user="root"
            log_dir="/var/log"
        fi
        cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.komari.${service_name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${komari_agent_path}</string>
EOF
        if [ -n "$komari_args" ]; then echo "$komari_args" | xargs -n1 printf "        <string>%s</string>\n" >> "$plist_file"; fi
        cat >> "$plist_file" <<EOF
    </array>
    <key>WorkingDirectory</key><string>${target_dir}</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>UserName</key><string>${service_user}</string>
    <key>StandardOutPath</key><string>${log_dir}/${service_name}.log</string>
    <key>StandardErrorPath</key><string>${log_dir}/${service_name}.log</string>
</dict>
</plist>
EOF
        if [[ "$target_dir" =~ ^/Users/.* ]] || [ "$EUID" -ne 0 ]; then
            launchctl bootstrap gui/$(id -u) "$plist_file"
        else
            launchctl bootstrap system "$plist_file"
        fi
        log_success "launchd service configured and started"
    elif [ "$init_system" = "upstart" ]; then
        service_file="/etc/init/${service_name}.conf"
        cat > "$service_file" <<EOF
# KOMARI Agent
description "Komari Agent Service"
chdir ${target_dir}
start on filesystem or runlevel [2345]
stop on runlevel [!2345]
respawn
respawn limit 10 5
umask 022
console none
pre-start script
    test -x ${komari_agent_path} || { stop; exit 0; }
end script
script
    exec ${komari_agent_path} ${komari_args}
end script
EOF
        initctl reload-configuration
        initctl start ${service_name}
        log_success "Upstart service configured and started"
    else
        log_error "Unsupported or unknown init system detected: $init_system"
        exit 1
    fi
}

install_agent() {
    if [ -z "$komari_args" ]; then
        log_error "缺少 Komari Agent 运行参数。请通过菜单引导安装，或在脚本后追加原 agent 参数。"
        exit 1
    fi

    require_root

    echo -e "${WHITE}===========================================${NC}"
    echo -e "${WHITE}    Komari Agent Installation Script     ${NC}"
    echo -e "${WHITE}===========================================${NC}"
    log_config "Service name: ${GREEN}$service_name${NC}"
    log_config "Install directory: ${GREEN}$target_dir${NC}"
    log_config "GitHub proxy: ${GREEN}${github_proxy:-"(direct)"}${NC}"
    log_config "Binary arguments: ${GREEN}$komari_args${NC}"
    if [ -n "$install_version" ]; then log_config "Specified agent version: ${GREEN}$install_version${NC}"; else log_config "Agent version: ${GREEN}Latest${NC}"; fi
    echo ""

    uninstall_previous
    install_dependencies
    detect_arch

    version_to_install="latest"
    if [ -n "$install_version" ]; then
        log_info "Attempting to install specified version: ${GREEN}$install_version${NC}"
        version_to_install="$install_version"
    else
        log_info "No version specified, installing the latest version."
    fi

    file_name="komari-agent-${os_name}-${arch}"
    if [ "$version_to_install" = "latest" ]; then download_path="latest/download"; else download_path="download/${version_to_install}"; fi
    if [ -n "$github_proxy" ]; then
        download_url="${github_proxy}/https://github.com/komari-monitor/komari-agent/releases/${download_path}/${file_name}"
    else
        download_url="https://github.com/komari-monitor/komari-agent/releases/${download_path}/${file_name}"
    fi

    log_step "Creating installation directory: ${GREEN}$target_dir${NC}"
    mkdir -p "$target_dir"

    log_step "Downloading $file_name..."
    log_info "URL: ${CYAN}$download_url${NC}"
    if ! curl -L -o "$komari_agent_path" "$download_url"; then log_error "Download failed"; exit 1; fi
    chmod +x "$komari_agent_path"
    log_success "Komari-agent installed to ${GREEN}$komari_agent_path${NC}"

    log_step "Configuring system service..."
    install_service

    echo ""
    echo -e "${WHITE}===========================================${NC}"
    log_success "Komari-agent installation completed!"
    log_config "Service: ${GREEN}$service_name${NC}"
    log_config "Arguments: ${GREEN}$komari_args${NC}"
    echo -e "${WHITE}===========================================${NC}"
}

show_status() {
    echo -e "${WHITE}===========================================${NC}"
    echo -e "${WHITE}        Komari Agent 状态检查             ${NC}"
    echo -e "${WHITE}===========================================${NC}"
    log_config "Service name: ${GREEN}$service_name${NC}"
    log_config "Install directory: ${GREEN}$target_dir${NC}"
    log_config "Binary path: ${GREEN}$komari_agent_path${NC}"

    if [ -x "$komari_agent_path" ]; then
        log_success "二进制文件存在"
        "$komari_agent_path" --version 2>/dev/null || true
    else
        log_warning "未找到可执行文件"
    fi

    init_system=$(detect_init_system)
    log_config "Init system: ${GREEN}$init_system${NC}"
    case "$init_system" in
        systemd) systemctl status ${service_name}.service --no-pager 2>/dev/null || true ;;
        openrc) rc-service ${service_name} status 2>/dev/null || true ;;
        procd) /etc/init.d/${service_name} status 2>/dev/null || true ;;
        launchd) launchctl list | grep "com.komari.${service_name}" || true ;;
        upstart) initctl status ${service_name} 2>/dev/null || true ;;
        *) log_warning "未知 init 系统，无法查询服务状态" ;;
    esac
}

install_menu_shortcut() {
    require_root
    if [ ! -f "$script_self_path" ]; then
        log_error "无法定位当前脚本路径，不能安装快捷菜单。"
        exit 1
    fi

    cat > "$quick_menu_path" <<EOF
#!/bin/sh
exec "$script_self_path" --menu "\$@"
EOF
    chmod +x "$quick_menu_path"
    log_success "SSH 终端快捷菜单已安装：${quick_menu_command}"
    log_info "以后登录终端后运行 ${GREEN}${quick_menu_command}${NC} 即可唤出菜单。"
}

prompt_install_args() {
    echo ""
    log_info "请输入 Komari Agent 的运行参数。"
    log_info "示例：--endpoint https://example.com --token xxxxx"
    printf "Agent 参数: "
    read -r komari_args

    if [ -z "$komari_args" ]; then
        log_error "Agent 参数不能为空。"
        return 1
    fi

    printf "安装目录 [%s]: " "$target_dir"
    read -r input_target_dir
    [ -n "$input_target_dir" ] && target_dir="$input_target_dir"

    printf "服务名 [%s]: " "$service_name"
    read -r input_service_name
    [ -n "$input_service_name" ] && service_name="$input_service_name"

    printf "GitHub 代理（留空直连）[%s]: " "${github_proxy:-direct}"
    read -r input_github_proxy
    [ -n "$input_github_proxy" ] && github_proxy="$input_github_proxy"

    printf "指定版本（留空 latest）[%s]: " "${install_version:-latest}"
    read -r input_install_version
    [ -n "$input_install_version" ] && install_version="$input_install_version"

    komari_agent_path="${target_dir}/agent"
    install_agent
}

interactive_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${WHITE}===========================================${NC}"
        echo -e "${WHITE}        Komari Agent 菜单引导             ${NC}"
        echo -e "${WHITE}===========================================${NC}"
        echo "1) 引导安装并启用监控"
        echo "2) 卸载 Komari Agent"
        echo "3) 安装 SSH 终端快捷菜单命令 (${quick_menu_command})"
        echo "4) 查看状态"
        echo "5) 显示脚本用法"
        echo "0) 退出"
        echo ""
        printf "请选择 [0-5]: "
        read -r choice
        case "$choice" in
            1) prompt_install_args; printf "\n按 Enter 返回菜单..."; read -r _ ;;
            2) uninstall_agent; printf "\n按 Enter 返回菜单..."; read -r _ ;;
            3) install_menu_shortcut; printf "\n按 Enter 返回菜单..."; read -r _ ;;
            4) show_status; printf "\n按 Enter 返回菜单..."; read -r _ ;;
            5) usage; printf "\n按 Enter 返回菜单..."; read -r _ ;;
            0) exit 0 ;;
            *) log_warning "无效选择"; sleep 1 ;;
        esac
    done
}

main() {
    parse_args "$@"

    case "$action" in
        uninstall) uninstall_agent; exit 0 ;;
        status) show_status; exit 0 ;;
        install_shortcut) install_menu_shortcut; exit 0 ;;
    esac

    if [ "$force_menu" = true ] || [ "$explicit_agent_args" = false ]; then
        interactive_menu
    else
        install_agent
    fi
}

main "$@"
