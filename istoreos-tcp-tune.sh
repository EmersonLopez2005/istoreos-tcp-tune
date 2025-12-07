#!/bin/bash

# ==============================================================================
# J4125 软路由 2.5G 接口极限调优 (Extreme Performance Edition)
# 目标：双端 128MB 缓冲区同步 + RPS 多核均衡 + CPU 满血模式
# 适配：2000M+ 宽带 / BBR+FQ / AnyTLS & VLESS 高并发
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
# 重点：此处已配置为 128MB，与服务端发送窗口完全对齐
cat <<EOF > /etc/sysctl.d/99-extreme-tune.conf
# === 核心缓冲区 (128MB 满血同步模式) ===
# 必须与服务端保持一致，防止接收端窗口太小导致被削顶
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 134217728
net.core.wmem_default = 134217728
net.core.netdev_max_backlog = 30000
net.core.somaxconn = 8192

# === TCP 读写缓冲区 (128MB) ===
# 中间值提升至 128k，最大值提升至 128MB
net.ipv4.tcp_rmem = 4096 131072 134217728
net.ipv4.tcp_wmem = 4096 131072 134217728

# === BBR 拥塞控制 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === 关键修正：防止大流量死机 ===
# 限制应用层积压数据量为 4MB (实测最佳甜点值)
# 既能跑满 1.7G+，又不至于让 J4125 内存溢出
net.ipv4.tcp_notsent_lowat = 4194304

# === RFS (Receive Flow Steering) 全局流表 ===
# 配合 RPS 使用，提高 CPU 缓存命中率
net.core.rps_sock_flow_entries = 32768

# === 杂项优化 ===
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
# 禁止保存之前的慢速记录，每次连接都重新探测极限
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_forward = 1
# 开启连接复用，适合高并发代理
net.ipv4.tcp_tw_reuse = 1 
EOF

# 应用 Sysctl
sysctl -p /etc/sysctl.d/99-extreme-tune.conf > /dev/null
echo "✅ 内核 Sysctl 参数已应用 (128MB 缓冲区生效)"

# --- 3. 网卡硬件与队列优化 (RPS/XPS/RFS/中断合并) ---
echo "⏳ 正在配置网卡队列与中断均衡..."

# 遍历所有物理网卡 (适配 eth0, eth1 等)
for dev in $(ls /sys/class/net | grep eth); do
    # 3.1 调整硬件卸载 (Offload)
    # ⚠️ 关键：开启 GRO/GSO 提升吞吐，但必须关闭 LRO (Large Receive Offload)
    # LRO 在软路由转发场景下经常导致问题
    ethtool -K "$dev" tso on gso on gro on sg on lro off >/dev/null 2>&1
    
    # 3.2 调整物理队列长度 (TxQueueLen)
    # 防止物理层丢包
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

# 清理旧的优化块 (防止重复写入)
sed -i '/# === Network Optimized Start ===/,/# === Network Optimized End ===/d' /etc/rc.local
# 如果文件末尾没有 exit 0，先补上
if ! grep -q "exit 0" /etc/rc.local; then echo "exit 0" >> /etc/rc.local; fi
# 删掉 exit 0，准备追加内容
sed -i '/exit 0/d' /etc/rc.local

# 追加新的启动逻辑
cat <<EOF >> /etc/rc.local
# === Network Optimized Start ===
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
# === Network Optimized End ===

exit 0
EOF

# 赋予执行权限并确保服务激活
chmod +x /etc/rc.local
systemctl enable rc-local >/dev/null 2>&1

echo "======================================================"
echo "🎉 极限优化执行完成！"
echo "------------------------------------------------------"
echo "配置已同步："
echo "1. 缓冲区大小：128MB (与服务端一致)"
echo "2. 喂饭阈值：4MB (CPU 减负)"
echo "3. CPU/网卡：全核均衡与性能模式"
echo "------------------------------------------------------"
echo "⚠️ 请执行 'reboot' 重启路由器以生效"
echo "======================================================"
