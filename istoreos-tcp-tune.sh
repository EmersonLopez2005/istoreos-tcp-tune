#!/bin/sh
# ============================================================================
#  iStoreOS 24.10.x  TCP 一键调优脚本（IPv4/IPv6 双栈共享 BBR）
#  用法：chmod +x istoreos-tcp-tune.sh && ./istoreos-tcp-tune.sh
# ============================================================================

set -e

log()  { echo -e "\033[32m[$(date +%H:%M:%S)] $*\033[0m"; }
warn() { echo -e "\033[33m[$(date +%H:%M:%S)] $*\033[0m"; }

# 1. 安装/加载 BBR（IPv4 加载即双栈生效）
if ! lsmod | grep -q tcp_bbr; then
    opkg update >/dev/null 2>&1
    opkg install kmod-tcp-bbr >/dev/null 2>&1 && modprobe tcp_bbr
fi

# 2. 备份 & 清理旧参数
[ ! -f /etc/sysctl.conf.bak ] && cp -f /etc/sysctl.conf /etc/sysctl.conf.bak
sed -i '/^net\./d' /etc/sysctl.conf

# 3. 写入新参数（IPv4 唯一入口，双栈共享）
cat >> /etc/sysctl.conf <<'EOF'
# ====== TCP 调优（IPv4/IPv6 共享） ======
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 40000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 10000
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 131072 8388608
net.ipv4.tcp_wmem = 4096 131072 8388608
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syncookies = 1
net.netfilter.nf_conntrack_max = 307200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 540
net.core.default_qdisc = fq_codel
EOF

sysctl -p >/dev/null 2>&1

# 4. 挂 fq_codel
for nic in $(ls /sys/class/net | grep -E 'eth|wan|lan'); do
    tc qdisc replace dev "$nic" root fq_codel 2>/dev/null && log "$nic fq_codel 已挂"
done

# 5. 开机自启
ln -sf /etc/sysctl.conf /etc/sysctl.d/99-ztune.conf

# 6. 结果
log "TCP 拥塞算法: $(cat /proc/sys/net/ipv4/tcp_congestion_control)（IPv4/IPv6 双栈共享）"
log "连接跟踪: $(cat /proc/sys/net/netfilter/nf_conntrack_count)/307200"
log "内存剩余: $(free -h | awk 'NR==2{print $7}')"
log "✅ 调优完成，重启依旧生效！"