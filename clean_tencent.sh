#!/bin/bash
# ============================================================
# 腾讯云监控组件 完整清理脚本
# 适配: Debian 12/13, OpenCloudOS 9 / TencentOS / CentOS / RHEL 系
#
# 默认行为:
#   - 不重启任何进程
#   - 只切换软件源, 不改 DNS / NTP
#   - 清理所有已知的本地保活路径
#   - 验证新进程不再加载 libonion
#
# 可选:
#   --with-dns   同时替换 DNS
#   --with-ntp   同时替换 NTP
#
# 注意: 已经运行的进程在重启前仍持有 libonion 注入,
#       脚本结束时会列出这些进程并提醒。
# ============================================================

set +e  # 不因单条命令失败而退出，每步自行容错

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; }

WITH_DNS=0
WITH_NTP=0

usage() {
    cat <<'USAGE'
用法: sudo bash clean_tencent.sh [--with-dns] [--with-ntp]

默认只清理监控组件并切换软件源, 不改 DNS/NTP, 不重启任何进程。
  --with-dns   同时替换 DNS (Debian 会写入 dhcpcd 配置, 防止被 DHCP 覆盖)
  --with-ntp   同时替换 NTP
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --with-dns) WITH_DNS=1 ;;
        --with-ntp) WITH_NTP=1 ;;
        -h|--help) usage; exit 0 ;;
        *) warn "未知参数: $arg (忽略)" ;;
    esac
done

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_CODENAME="${VERSION_CODENAME:-}"
        case "$ID" in
            debian|ubuntu) OS_TYPE="debian" ;;
            opencloudos|centos|rhel|tencentos|rocky|alma) OS_TYPE="rhel" ;;
            *) OS_TYPE="unknown" ;;
        esac
    else
        OS_TYPE="unknown"
        OS_CODENAME=""
    fi
    log "检测到系统: ${PRETTY_NAME:-unknown} (类型: $OS_TYPE, codename: ${OS_CODENAME:-未知})"
}

# ============================================================
# 备份
# ============================================================
BACKUP="/root/tencent-clean-backup-$(date +%Y%m%d-%H%M%S)"

backup_configs() {
    log "备份关键配置到 $BACKUP ..."
    mkdir -p "$BACKUP"
    cp -a /etc/ld.so.preload "$BACKUP"/ 2>/dev/null
    cp -a /etc/apt/sources.list "$BACKUP"/ 2>/dev/null
    cp -a /etc/rc.local "$BACKUP"/ 2>/dev/null
    cp -a /etc/udev/rules.d/80-qcloud-nic.rules "$BACKUP"/ 2>/dev/null
    cp -a /etc/cron.d/sgagenttask /etc/cron.d/yunjing "$BACKUP"/ 2>/dev/null
    cp -a /etc/systemd/system/tat_agent.service "$BACKUP"/ 2>/dev/null
    cp -a /usr/lib/systemd/system/cloud-init*.service \
          /usr/lib/systemd/system/cloud-config.service \
          /usr/lib/systemd/system/cloud-final.service \
          /usr/lib/systemd/system/cloud-init.target \
          /usr/lib/systemd/system/nv_gpu_shutdown_pm.service "$BACKUP"/ 2>/dev/null
    crontab -l > "$BACKUP/root.crontab" 2>/dev/null
    ps aux > "$BACKUP/ps-before.txt"
    systemctl list-unit-files > "$BACKUP/systemd-unit-files-before.txt" 2>/dev/null
}

# ============================================================
# 第一步: 切断定时任务保活 (必须先做, 否则进程会被反复拉起)
# ============================================================
clean_crontab() {
    log "清理定时任务 ..."

    rm -f /etc/cron.d/sgagenttask
    rm -f /etc/cron.d/yunjing
    log "  已删除 /etc/cron.d/sgagenttask, yunjing"

    # root crontab
    if crontab -l 2>/dev/null | grep -qE '(qcloud|stargate|barad|yunjing|sgagent|tat_agent)'; then
        crontab -l 2>/dev/null | grep -vE '(qcloud|stargate|barad|yunjing|sgagent|tat_agent)' | crontab -
        log "  已清理 root crontab 中的腾讯云条目"
    fi

    # 其他用户 crontab
    for f in /var/spool/cron/crontabs/*; do
        [ -f "$f" ] || continue
        local u
        u=$(basename "$f")
        if crontab -u "$u" -l 2>/dev/null | grep -qE '(qcloud|stargate|barad|yunjing|sgagent|tat_agent)'; then
            crontab -u "$u" -l 2>/dev/null | grep -vE '(qcloud|stargate|barad|yunjing|sgagent|tat_agent)' | crontab -u "$u" -
            log "  已清理 $u 的 crontab"
        fi
    done

    # cron.hourly/daily/... 中如果还有引用, 只报告不删除
    local hits
    hits=$(grep -rliE 'qcloud|tencentyun|yunjing|barad|sgagent|stargate' \
        /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>/dev/null)
    [ -n "$hits" ] && warn "以下 cron 目录仍有引用, 请人工确认: $hits"
}

# ============================================================
# 第二步: 清理 systemd 服务
# ============================================================
clean_systemd() {
    log "清理 systemd 服务 ..."

    # tat_agent 有 Restart=always, 必须先 stop 再 disable
    systemctl stop tat_agent.service 2>/dev/null
    systemctl disable tat_agent.service 2>/dev/null
    rm -f /etc/systemd/system/tat_agent.service
    rm -f /etc/systemd/system/multi-user.target.wants/tat_agent.service

    for svc in cloud-init-local.service cloud-init.service cloud-config.service \
               cloud-final.service cloud-init.target nv_gpu_shutdown_pm.service; do
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
    done

    # cloud-init / GPU 服务单元 (镜像自带, 不是 apt 包)
    rm -f /usr/lib/systemd/system/cloud-init*.service \
          /usr/lib/systemd/system/cloud-config.service \
          /usr/lib/systemd/system/cloud-final.service \
          /usr/lib/systemd/system/cloud-init.target \
          /usr/lib/systemd/system/nv_gpu_shutdown_pm.service

    # 清理 wants 目录里的悬空链接
    find /etc/systemd/system -type l \( \
        -name 'cloud-init*' -o -name 'cloud-config*' -o -name 'cloud-final*' \
        -o -name 'nv_gpu_shutdown_pm*' -o -name 'tat_agent*' \) -delete 2>/dev/null

    systemctl daemon-reload 2>/dev/null
    systemctl reset-failed 2>/dev/null
}

# ============================================================
# 第三步: 停止所有腾讯云进程
# ============================================================
stop_processes() {
    log "停止腾讯云相关进程 ..."

    # 不调用任何官方脚本(uninst.sh 要验证码, stopYDCore.sh 也可能卡住)
    # 全部直接 pkill -9 强杀
    local procs="sgagent barad_agent YDService YDLive YDEdr tat_agent cosfs"
    for p in $procs; do
        if pgrep -x "$p" > /dev/null 2>&1; then
            log "  杀死进程: $p"
            pkill -9 -x "$p" 2>/dev/null || true
        fi
    done

    # 兜底: 杀掉所有从 /usr/local/qcloud 启动的进程
    ps -eo pid,args --no-headers | grep '/usr/local/qcloud/' | grep -v grep \
        | awk '{print $1}' | xargs -r kill -9 2>/dev/null || true

    # 杀死 YunJing 守护的 sleep 进程
    ps aux | grep '/bin/sh -c sleep' | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null || true

    # 卸载 cosfs 挂载
    if mount | grep -q cosfs; then
        log "  卸载 cosfs 挂载点"
        umount -l /lhcos-data 2>/dev/null || true
    fi

    sleep 1
    if ps -eo pid,comm,args --no-headers | grep -Ei \
        'sgagent|barad|YDService|YDLive|YDEdr|tat_agent|cosfs|/usr/local/qcloud/' \
        | grep -v grep >/dev/null; then
        warn "仍有腾讯云进程, 请稍后复查"
    fi
}

# ============================================================
# 第四步: 解除 libonion 全局注入 (关键)
# ============================================================
clean_ld_preload() {
    log "解除 libonion 全局注入 ..."
    if [ -f /etc/ld.so.preload ]; then
        log "  原内容: $(tr '\n' ' ' < /etc/ld.so.preload)"
        # 先清空再删除: 清空后新启动的进程就不再加载 libonion
        printf '' > /etc/ld.so.preload 2>/dev/null
        rm -f /etc/ld.so.preload
        log "  /etc/ld.so.preload 已删除"
    else
        log "  ld.so.preload 不存在, 跳过"
    fi
}

# ============================================================
# 第五步: 删除注入的 .so 文件
# ============================================================
clean_so_files() {
    log "清理 libonion / libsgmon .so 文件 ..."
    local files=(
        /lib64/libonion.so
        /lib64/libonion_security.so*
        /usr/lib64/libonion.so
        /usr/lib64/libonion_security.so*
        /lib/x86_64-linux-gnu/libonion.so
        /lib/x86_64-linux-gnu/libonion_security.so*
        /usr/lib/x86_64-linux-gnu/libonion.so
        /usr/lib/x86_64-linux-gnu/libonion_security.so*
        /lib/x86_64-linux-gnu/libsgmon.so*
        /usr/lib/x86_64-linux-gnu/libsgmon.so*
        /lib64/libsgmon.so
        /lib64/libsgmon.so.*
        /usr/lib64/libsgmon.so
        /usr/lib64/libsgmon.so.*
    )
    for f in "${files[@]}"; do
        # 使用通配符展开
        for ff in $f; do
            if [ -e "$ff" ] || [ -L "$ff" ]; then
                rm -f "$ff"
                log "  删除: $ff"
            fi
        done
    done
    ldconfig 2>/dev/null || true
}

# ============================================================
# 第六步: 删除文件和目录
# ============================================================
clean_files() {
    log "删除腾讯云文件和目录 ..."

    # 主目录
    rm -rf /usr/local/qcloud
    rm -rf /usr/local/sa
    rm -rf /usr/local/agenttools
    rm -rf /var/lib/qcloud

    # barad 客户端软链
    rm -f /usr/bin/cagent_tools

    # cosfs 二进制
    rm -f /usr/local/bin/cosfs

    # cosfs 挂载点
    rm -rf /lhcos-data

    # YunJing 替换过的 runc (containerd 未运行时才删)
    if pgrep -x containerd >/dev/null 2>&1; then
        warn "containerd 正在运行, 跳过 /opt/containerd (yunjing-runc)"
    else
        rm -rf /opt/containerd
    fi

    # cloud-init 状态与配置 (镜像自带, 不是 apt 包)
    rm -rf /var/lib/cloud
    rm -rf /etc/cloud

    # 配置文件
    rm -f /etc/qcloudzone
    rm -f /etc/tencentcloud_ipv6_base.sh

    # 日志与临时文件
    rm -f /var/log/qcloud_action.log
    rm -f /tmp/stargate.lock
    rm -f /tmp/sgdaemon.log
    rm -f /tmp/net_affinity.log /tmp/cpuidle_support.log /tmp/setRps.log \
          /tmp/set_xps.log /tmp/virtio_blk_affinity.log /tmp/nv_gpu_conf.log \
          /tmp/disable_rt_runtime_share.log

    log "  文件清理完成"
}

# ============================================================
# 第七步: 清理 udev / rc.local 等启动钩子
# ============================================================
clean_hooks() {
    log "清理 udev / rc.local 启动钩子 ..."

    # 80-qcloud-nic.rules 会调用 /usr/local/qcloud/udev_run/udev_run.sh
    # 注意: 不要删 70-persistent-net.rules, 那是网卡命名规则
    rm -f /etc/udev/rules.d/80-qcloud-nic.rules
    udevadm control --reload-rules 2>/dev/null || true

    # rc.local 里的 /usr/local/qcloud/* 启动命令
    if [ -f /etc/rc.local ]; then
        sed -i '/qcloud/d' /etc/rc.local
        log "  已清理 /etc/rc.local 中的腾讯云命令"
    fi
}

# ============================================================
# 第八步: 替换软件源 (默认只做这一步, 不动 DNS/NTP)
# ============================================================
fix_repos() {
    log "替换软件源为清华源 ..."

    if [ "$OS_TYPE" = "rhel" ]; then
        # OpenCloudOS / TencentOS / RHEL 系
        if [ -f /etc/yum.repos.d/OpenCloudOS.repo ]; then
            sed -i 's|mirrors\.tencentyun\.com/opencloudos|mirrors.tuna.tsinghua.edu.cn/opencloudos|g' /etc/yum.repos.d/OpenCloudOS.repo
            log "  OpenCloudOS.repo -> 清华源"
        fi
        if [ -f /etc/yum.repos.d/epol.repo ]; then
            sed -i 's|mirrors\.tencentyun\.com|mirrors.tuna.tsinghua.edu.cn|g' /etc/yum.repos.d/epol.repo
            log "  epol.repo -> 清华源"
        fi
        rm -f /etc/yum.repos.d/epol.repo.rpmnew
        dnf clean all 2>/dev/null || yum clean all 2>/dev/null || true
    else
        # Debian / Ubuntu: 只替换域名, 保留原有 codename (不要写死 bookworm)
        local changed=0
        if [ -f /etc/apt/sources.list ] && grep -q 'mirrors\.tencentyun\.com' /etc/apt/sources.list; then
            sed -i 's|mirrors\.tencentyun\.com|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list
            changed=1
            log "  /etc/apt/sources.list -> 清华源 (保留 ${OS_CODENAME:-原 codename})"
        fi
        for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [ -f "$f" ] || continue
            if grep -q 'mirrors\.tencentyun\.com' "$f"; then
                sed -i 's|mirrors\.tencentyun\.com|mirrors.tuna.tsinghua.edu.cn|g' "$f"
                changed=1
                log "  $f -> 清华源"
            fi
        done
        [ "$changed" = "0" ] && log "  未发现腾讯源, 跳过"

        rm -f /var/lib/apt/lists/mirrors.tencentyun.com_* 2>/dev/null

        # 只在确实换过源时更新索引
        if [ "$changed" = "1" ]; then
            if command -v timeout >/dev/null 2>&1; then
                timeout 90 apt-get update -o Acquire::Retries=1 -o Acquire::http::Timeout=10 </dev/null >/tmp/apt-update.log 2>&1
            else
                apt-get update -o Acquire::Retries=1 -o Acquire::http::Timeout=10 </dev/null >/tmp/apt-update.log 2>&1
            fi
            if [ $? -eq 0 ]; then
                log "  apt-get update 成功 (清华源可用)"
            else
                warn "  apt-get update 失败, 详见 /tmp/apt-update.log (源已替换, 可稍后重试)"
            fi
        fi
    fi
}

# ============================================================
# 可选: 替换 DNS (默认不执行)
# ============================================================
fix_dns() {
    log "替换 DNS 为公共 DNS ..."

    if [ "$OS_TYPE" = "rhel" ]; then
        cat > /etc/resolv.conf <<DNSEOF
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
DNSEOF
        if [ -d /etc/NetworkManager/conf.d ]; then
            cat > /etc/NetworkManager/conf.d/no-dns.conf <<NMEOF
[main]
dns=none
NMEOF
            systemctl restart NetworkManager 2>/dev/null || true
        fi
    else
        # Debian 13 由 dhcpcd 管理 resolv.conf, 必须先禁止 dhcpcd 覆盖
        if pgrep -x dhcpcd >/dev/null 2>&1; then
            if ! grep -qE '^[[:space:]]*nohook[[:space:]]+resolv\.conf' /etc/dhcpcd.conf 2>/dev/null; then
                echo "nohook resolv.conf" >> /etc/dhcpcd.conf
            fi
            if grep -qE '^[[:space:]]*static[[:space:]]+domain_name_servers=' /etc/dhcpcd.conf 2>/dev/null; then
                sed -i 's|^[[:space:]]*static[[:space:]]*domain_name_servers=.*|static domain_name_servers=223.5.5.5 119.29.29.29 8.8.8.8|' /etc/dhcpcd.conf
            else
                echo "static domain_name_servers=223.5.5.5 119.29.29.29 8.8.8.8" >> /etc/dhcpcd.conf
            fi
            log "  已写入 /etc/dhcpcd.conf (防止 DHCP 覆盖)"
        fi

        cat > /etc/resolv.conf <<DNSEOF
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
DNSEOF
    fi

    log "  DNS: 阿里(223.5.5.5) + DNSPod(119.29.29.29) + Google(8.8.8.8)"
}

# ============================================================
# 可选: 替换 NTP (默认不执行)
# ============================================================
fix_ntp() {
    log "替换 NTP 时间源 ..."

    if [ "$OS_TYPE" = "rhel" ]; then
        if [ -f /etc/chrony.conf ]; then
            sed -i '/tencentyun\.com/d' /etc/chrony.conf
            if ! grep -q 'ntp.aliyun.com' /etc/chrony.conf; then
                sed -i '1i server ntp.aliyun.com iburst\nserver ntp.tencent.com iburst\nserver cn.ntp.org.cn iburst\nserver ntp.ntsc.ac.cn iburst' /etc/chrony.conf
            fi
            systemctl restart chronyd 2>/dev/null || true
            log "  chrony: 阿里云NTP + 腾讯公共NTP + 国家授时中心"
        fi
    else
        if [ -f /etc/ntpsec/ntp.conf ]; then
            sed -i '/tencentyun\.com/d' /etc/ntpsec/ntp.conf
            if ! grep -q 'ntp.aliyun.com' /etc/ntpsec/ntp.conf; then
                sed -i '/^restrict ::1/a\\nserver ntp.aliyun.com iburst\nserver ntp.tencent.com iburst\nserver cn.ntp.org.cn iburst\nserver ntp.ntsc.ac.cn iburst' /etc/ntpsec/ntp.conf
            fi
            systemctl restart ntpsec 2>/dev/null || true
            log "  ntpsec: 阿里云NTP + 腾讯公共NTP + 国家授时中心"
        elif [ -f /etc/chrony/chrony.conf ]; then
            sed -i '/tencentyun\.com/d' /etc/chrony/chrony.conf
            if ! grep -q 'ntp.aliyun.com' /etc/chrony/chrony.conf; then
                sed -i '1i server ntp.aliyun.com iburst\nserver ntp.tencent.com iburst\nserver cn.ntp.org.cn iburst\nserver ntp.ntsc.ac.cn iburst' /etc/chrony/chrony.conf
            fi
            systemctl restart chronyd 2>/dev/null || true
            log "  chrony: 阿里云NTP + 腾讯公共NTP + 国家授时中心"
        fi
    fi
}

# ============================================================
# 清理 /etc/hosts 中的腾讯云条目 (如有)
# ============================================================
clean_hosts() {
    if grep -qiE '(tencentyun|qcloud)' /etc/hosts 2>/dev/null; then
        log "清理 /etc/hosts 中的腾讯云条目 ..."
        sed -i '/tencentyun/d;/qcloud/d' /etc/hosts
    fi
}

# ============================================================
# 验证
# ============================================================
old_processes() {
    local p
    for p in $(grep -l libonion /proc/[0-9]*/maps 2>/dev/null | cut -d/ -f3 | sort -u); do
        [ -r "/proc/$p/cmdline" ] || continue
        printf '%s\t%s\n' "$p" "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-90)"
    done
}

verify() {
    echo ""
    echo "========================================"
    log "清理完成! 验证结果:"
    echo "========================================"

    sleep 5

    echo ""
    echo "--- ld.so.preload 检查 ---"
    if [ ! -e /etc/ld.so.preload ]; then
        log "ld.so.preload 不存在 ✓"
    elif [ -s /etc/ld.so.preload ]; then
        err "ld.so.preload 仍有内容: $(tr '\n' ' ' < /etc/ld.so.preload)"
    else
        warn "ld.so.preload 仍存在(空文件), 可手动 rm -f /etc/ld.so.preload"
    fi

    echo ""
    echo "--- 新进程注入检查 ---"
    if env -i /bin/sh -c '/bin/grep -q libonion /proc/self/maps' 2>/dev/null; then
        err "新进程仍加载 libonion ✗ (可能有自愈, 请立即复查)"
    else
        log "新进程不再加载 libonion ✓"
    fi

    echo ""
    echo "--- 残留进程检查 ---"
    local remain
    remain=$(ps -eo pid,comm,args --no-headers | grep -Ei \
        'sgagent|barad|YDService|YDLive|YDEdr|tat_agent|cosfs|/usr/local/qcloud/' | grep -v grep)
    if [ -z "$remain" ]; then
        log "无腾讯云残留进程 ✓"
    else
        err "仍有残留进程:"
        echo "$remain"
    fi

    echo ""
    echo "--- 定时任务检查 ---"
    local cron_remain
    cron_remain=$(crontab -l 2>/dev/null | grep -E '(qcloud|stargate|barad|yunjing|sgagent|tat_agent)')
    if [ -z "$cron_remain" ] && [ ! -f /etc/cron.d/sgagenttask ] && [ ! -f /etc/cron.d/yunjing ]; then
        log "定时任务干净 ✓"
    else
        err "仍有腾讯云定时任务: $cron_remain"
    fi

    echo ""
    echo "--- systemd 单元检查 ---"
    local unit_remain
    # not-found 只是 systemd 内存中的历史单元元数据, 文件已删除, 不算磁盘残留
    unit_remain=$( { systemctl list-unit-files 2>/dev/null; \
        systemctl list-units --all --no-pager 2>/dev/null | grep -v 'not-found'; } \
        | grep -Ei 'qcloud|tencent|yunjing|barad|sgagent|tat_agent|cloud-init|nv_gpu' | sort -u)
    if [ -z "$unit_remain" ]; then
        log "systemd 单元干净 ✓"
    else
        err "仍有相关单元:"
        echo "$unit_remain"
    fi

    echo ""
    echo "--- 启动钩子检查 (udev / rc.local / cron) ---"
    local hook_remain
    hook_remain=$(grep -rIiE 'qcloud|tencentyun|yunjing|barad|sgagent|stargate' \
        /etc/rc.local /etc/udev/rules.d /etc/cron.d /etc/cron.hourly \
        /etc/cron.daily /etc/init.d /etc/profile.d 2>/dev/null)
    if [ -z "$hook_remain" ]; then
        log "启动钩子干净 ✓"
    else
        warn "仍有钩子引用, 请人工确认:"
        echo "$hook_remain"
    fi

    echo ""
    echo "--- 文件系统残留检查 ---"
    local leftover
    leftover=$(find / -xdev \( -iname '*qcloud*' -o -iname '*tencentyun*' \
        -o -iname '*yunjing*' -o -iname '*stargate*' -o -iname '*barad*' \
        -o -iname 'libonion*' -o -iname 'libsgmon*' \) 2>/dev/null \
        | grep -vE '^/(proc|sys|run)|^/root/tencent-clean-backup-')
    if [ -z "$leftover" ]; then
        log "文件系统无腾讯监控残留 ✓"
    else
        warn "发现以下残留(请人工确认):"
        echo "$leftover"
    fi

    echo ""
    echo "--- 软件源 ---"
    grep -vE '^\s*#|^\s*$' /etc/apt/sources.list 2>/dev/null

    echo ""
    echo "--- DNS / NTP (本次未改动) ---"
    grep -vE '^#' /etc/resolv.conf 2>/dev/null
    grep '^server' /etc/chrony/chrony.conf 2>/dev/null

    echo ""
    echo "--- 仍加载 libonion 的旧进程 ---"
    local old
    old=$(old_processes)
    if [ -z "$old" ]; then
        echo "(无)"
    else
        echo "$old"
    fi

    echo ""
    echo "================================================================"
    echo -e "${YELLOW}  重要提醒: 旧进程仍然处于 libonion 注入状态${NC}"
    echo "================================================================"
    echo "本次【没有重启任何进程】。上面列出的进程是在清理前启动的,"
    echo "它们的地址空间里仍然映射着已删除的 libonion, 直到各自被重新启动为止,"
    echo "仍可能受腾讯监控组件影响。"
    echo ""
    echo "新启动的进程不会再加载 libonion (已验证), 磁盘与自启项已清理干净。"
    echo "若要彻底清除旧进程内存中的映射, 请在业务允许时:"
    echo "  - 重启上面列出的进程/服务, 或"
    echo "  - 执行 systemctl soft-reboot (只重启用户空间, 不重启内核)"
    echo ""
    echo "DNS / NTP 未改动; 软件源已切换为清华源。"
    echo "备份目录: $BACKUP (确认无误后可删除)"
    echo ""
    echo "注意: 卸载后腾讯云控制台的监控、主机安全、TAT 远程命令、"
    echo "      重置密码/VNC 等功能将不可用。"
    echo "================================================================"
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo "========================================"
    echo "  腾讯云监控组件 完整清理脚本"
    echo "  模式: 不重启进程 / 仅换源"
    echo "========================================"
    echo ""

    detect_os

    if [ "$OS_TYPE" = "unknown" ]; then
        err "未识别的系统类型, 退出"
        exit 1
    fi

    backup_configs      # 0. 备份
    clean_crontab       # 1. 先切断 cron 保活
    clean_systemd       # 2. 停掉并删除 systemd 服务
    stop_processes      # 3. 杀死所有腾讯进程
    clean_ld_preload    # 4. 解除全局注入
    clean_so_files      # 5. 删除 .so 文件
    clean_files         # 6. 删除文件目录
    clean_hooks         # 7. 清理 udev / rc.local
    fix_repos           # 8. 只替换软件源
    [ "$WITH_DNS" = "1" ] && fix_dns
    [ "$WITH_NTP" = "1" ] && fix_ntp
    clean_hosts         # 9. 清理 hosts
    verify              # 10. 验证 + 旧进程提醒
}

main "$@"
