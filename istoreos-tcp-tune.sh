#!/bin/bash

# ==============================================================================
# J4125 软路由 2.5G 接口极限调优 v3.0 (Gemini Ultimate Edition)
# 目标：RPS/XPS 多核均衡 + RFS 缓存命中 + 硬中断合并 + CPU 满血模式
# ==============================================================================

echo "🚀 开始应用 J4125 极限网络优化..."

# --- 1. CPU 性能模式锁定 (防止降频导致延迟抖动) ---
# J4125 默认可能会为了省电而降频，强制它全核满血运行
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$governor"
    done
    echo "✅ CPU 已锁定 Performance 模式 (拒绝降频)"
else
    echo "⚠️ 未找到 CPU 频率控制文件，跳过 (可能是虚拟机或BIOS接管)"
fi

# --- 2. Sysctl 内核参数优化 ---
# 包含 64MB 大窗口 + BBR + RFS 全局流表 + 防止死机的缓冲限制
cat <<EOF > /etc/sysctl.d/99-gemini-tune.conf
# === 核心缓冲区 (64MB 激进模式) ===
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 67108864
net.core.wmem_default = 67108864
net.core.netdev_max_backlog = 30000
net.core.somaxconn = 8192

# === TCP 读写缓冲区 ===
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# === BBR 拥塞控制 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === 关键修正：防止大流量死机 ===
# 限制应用层积压数据量为 4MB，防止内存耗尽或内核锁死
net.ipv4.tcp_notsent_lowat = 4194304

# === RFS (Receive Flow Steering) 全局流表 ===
# 配合 RPS 使用，提高 CPU 缓存命中率
net.core.rps_sock_flow_entries = 32768

# === 杂项优化 ===
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_forward = 1
# 开启连接复用，适合高并发代理
net.ipv4.tcp_tw_reuse = 1 
EOF

# 应用 Sysctl
sysctl -p /etc/sysctl.d/99-gemini-tune.conf > /dev/null
echo "✅ 内核 Sysctl 参数已应用"

# --- 3. 网卡硬件与队列优化 (RPS/XPS/RFS/中断合并) ---
echo "⏳ 正在配置网卡队列与中断均衡..."

# 遍历所有物理网卡 (适配 eth0, eth1 等)
for dev in $(ls /sys/class/net | grep eth); do
    # 3.1 调整硬件卸载 (Offload)
    # ⚠️ 关键：开启 GRO/GSO 提升吞吐，但必须关闭 LRO (Large Receive Offload)
    # LRO 在软路由转发场景下经常导致问题
    ethtool -K "$dev" tso on gso on gro on sg on lro off >/dev/null 2>&1
    
    # 3.2 调整物理队列长度 (TxQueueLen)
    ip link set dev "$dev" txqueuelen 10000
    
    # 3.3 中断合并 (Interrupt Coalescing)
    # 减少 CPU 被打断的频率。rx-usecs 20 表示收到包后等待 20us 或凑够 5 个包再中断 CPU
    # 这能显著降低 softirq 占用，把算力留给代理软件
    ethtool -C "$dev" adaptive-rx on rx-usecs 20 rx-frames 5 >/dev/null 2>&1

    # 3.4 配置 RPS (Receive Packet Steering) - 接收软中断均衡
    # mask 'f' = 二进制 1111 = 使用 CPU 0-3 (J4125 全部 4 核)
    for file in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
        echo f > "$file"
    done
    
    # 3.5 配置 RFS (Receive Flow Steering) - 流表引导
    # 每个队列分配的流表数 = 全局 32768 / 队列数 (通常 4) = 8192
    for file in /sys/class/net/$dev/queues/rx-*/rps_flow_cnt; do
        echo 8192 > "$file"
    done

    # 3.6 配置 XPS (Transmit Packet Steering) - 发送软中断均衡
    for file in /sys/class/net/$dev/queues/tx-*/xps_cpus; do
        echo f > "$file"
    done
    
    echo "   -> 网卡 $dev 优化完毕: RPS/XPS/RFS(4核) + LRO关闭 + 中断合并"
done

# --- 4. 写入开机启动 (rc.local) ---
# 确保上述网卡层的设置在重启后依然生效

# 清理旧的 gemini 优化块 (防止重复写入)
sed -i '/# === Gemini Optimized Start ===/,/# === Gemini Optimized End ===/d' /etc/rc.local
# 如果文件末尾没有 exit 0，先补上，方便后续 sed 操作（有些系统默认没有）
if ! grep -q "exit 0" /etc/rc.local; then echo "exit 0" >> /etc/rc.local; fi
# 删掉 exit 0，准备追加内容
sed -i '/exit 0/d' /etc/rc.local

# 追加新的启动逻辑
cat <<EOF >> /etc/rc.local
# === Gemini Optimized Start ===
# 1. 锁定 CPU 频率
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > \$g; done

# 2. 网卡队列与中断优化
for dev in \$(ls /sys/class/net | grep eth); do
    ip link set dev \$dev txqueuelen 10000
    # 关闭 LRO，开启其他卸载
    ethtool -K \$dev tso on gso on gro on sg on lro off
    # 开启中断合并
    ethtool -C \$dev adaptive-rx on rx-usecs 20 rx-frames 5
    # RPS/RFS/XPS 均衡
    for file in /sys/class/net/\$dev/queues/rx-*/rps_cpus; do echo f > \$file; done
    for file in /sys/class/net/\$dev/queues/rx-*/rps_flow_cnt; do echo 8192 > \$file; done
    for file in /sys/class/net/\$dev/queues/tx-*/xps_cpus; do echo f > \$file; done
done
# === Gemini Optimized End ===

exit 0
EOF

# 赋予执行权限并确保服务激活
chmod +x /etc/rc.local
systemctl enable rc-local >/dev/null 2>&1

echo "======================================================"
echo "🎉 终极优化完成！"
echo "本次新增优化点："
echo "1. CPU 锁定 Performance 模式 (拒绝延迟抖动)"
echo "2. RFS 开启 (提升 CPU 缓存命中率)"
echo "3. 智能中断合并 (降低软中断 CPU 占用)"
echo "4. 关闭 LRO (防止软路由转发异常)"
echo "------------------------------------------------------"
echo "请重启路由器，然后进行最后一次测速！"
echo "======================================================"
