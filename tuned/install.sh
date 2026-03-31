#!/bin/bash
#
# Real-time tuned profile setup script
# Run after system installation to configure CPU isolation and RT tuning
#
# Usage: sudo ./setup-tuned-rt.sh
#
# This script:
#   1. Creates the realtime-custom tuned profile
#   2. Activates the profile
#   3. Configures irqbalance
#   4. Verifies the configuration
#

set -Eeuo pipefail

##
## Variables — adjust according to the target machine
##
ISOLATED_CORES="0-13"
HOUSEKEEPING_CORES="14-19"
# Hexadecimal bitmask of isolated CPUs
# CPUs 0-13 = 14 CPUs = 0x3FFF
IRQBALANCE_BANNED_CPUS="00003fff"

PROFILE_NAME="realtime-custom"
PROFILE_DIR="/etc/tuned/${PROFILE_NAME}"

##
## Pre-flight checks
##
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo)" >&2
  exit 1
fi

if ! rpm -q tuned &>/dev/null; then
  echo "tuned is not installed" >&2
  exit 1
fi

if ! rpm -q kernel-rt &>/dev/null; then
  echo "WARNING: kernel-rt does not appear to be installed"
fi

echo "==> Creating tuned profile ${PROFILE_NAME}..."
mkdir -p "${PROFILE_DIR}"

##
## Write the tuned profile
##
cat > "${PROFILE_DIR}/tuned.conf" << EOF
#
# Custom real-time tuned profile
# CPUs ${ISOLATED_CORES}  : real-time workloads (isolated)
# CPUs ${HOUSEKEEPING_CORES} : system, IRQ, background tasks
#

[main]
summary=Balanced RT profile — isolated CPUs ${ISOLATED_CORES} / system CPUs ${HOUSEKEEPING_CORES}
include=realtime

[variables]
isolated_cores=${ISOLATED_CORES}
housekeeping_cores=${HOUSEKEEPING_CORES}

[cpu]
# Use performance governor for consistent CPU frequency
governor=performance
energy_perf_bias=performance
min_perf_pct=100
# Disable C-states via PM QoS — combined with idle=poll in bootloader
force_latency=0
# Disable turbo boost to avoid frequency variations that hurt RT determinism
no_turbo=1

[vm]
# Disable transparent hugepages — unpredictable allocation latency
transparent_hugepages=never
# Reduce background page flush activity
dirty_background_ratio=3
dirty_ratio=10
# Disable swap for RT workloads
swappiness=0
zone_reclaim_mode=0
# Reserve enough memory to avoid late allocations
min_free_kbytes=131072
page-cluster=0
# Reduce VM stats frequency (fewer interruptions)
stat_interval=120

[sysctl]
# Allow RT tasks to consume 100% CPU without throttling
kernel.sched_rt_runtime_us=-1
# Disable timer migration to other CPUs
kernel.timer_migration=0
# Disable watchdog — generates periodic interrupts
kernel.watchdog=0
kernel.nmi_watchdog=0
# Keep softlockup backtrace on all CPUs for debugging
kernel.softlockup_all_cpu_backtrace=1
# Network busy polling to reduce IRQ latency
net.core.busy_poll=50
net.core.busy_read=50
# Disable scheduler autogroup — hurts RT scheduling
kernel.sched_autogroup_enabled=0
# AIO limit for I/O intensive workloads
fs.aio-max-nr=1048576
# Disable NUMA automatic rebalancing
kernel.numa_balancing=0
# Limit perf event impact on RT CPUs
kernel.perf_cpu_time_max_percent=2

[scheduler]
# Isolate CPUs from the general scheduler
isolated_cores=\${isolated_cores}
# Disable load balancing on isolated CPUs
no_balance_cores=\${isolated_cores}

[bootloader]
# Kernel parameters for RT isolation:
# isolcpus              : exclude CPUs from general scheduler
# nohz_full             : disable timer ticks on isolated CPUs
# rcu_nocbs             : offload RCU callbacks off isolated CPUs
# rcu_nocb_poll         : RCU polling instead of interrupts
# irqaffinity           : force IRQs onto system CPUs
# mitigations=off       : disable Spectre/Meltdown (~10-15% latency gain)
# intel_pstate=disable  : disable Intel dynamic frequency scaling
# intel_idle.max_cstate=0 + processor.max_cstate=0 + idle=poll :
#   disable all C-states, keep CPUs in active polling
# clocksource=tsc + tsc=reliable + skew_tick=1 :
#   stable TSC clock, staggered ticks between CPUs
# nosoftlockup + nowatchdog : disable kernel watchdog mechanisms
cmdline_realtime=+isolcpus=\${isolated_cores} nohz_full=\${isolated_cores} rcu_nocbs=\${isolated_cores} rcu_nocb_poll irqaffinity=\${housekeeping_cores} mitigations=off intel_pstate=disable clocksource=tsc tsc=reliable skew_tick=1 rcupdate.rcu_normal_after_boot=1 nosoftlockup nowatchdog intel_idle.max_cstate=0 processor.max_cstate=0 idle=poll nohz=on quiet

[irqbalance]
# Hexadecimal bitmask of isolated CPUs (0-13 = 0x3FFF)
# Prevents irqbalance from placing IRQs on RT CPUs
banned_cpus=${IRQBALANCE_BANNED_CPUS}
EOF

echo "==> Profile written to ${PROFILE_DIR}/tuned.conf"

##
## Configure irqbalance
##
echo "==> Configuring irqbalance..."
cat > /etc/sysconfig/irqbalance << EOF
IRQBALANCE_ARGS="--banirq=${IRQBALANCE_BANNED_CPUS}"
EOF

##
## Enable and start services
##
echo "==> Enabling and starting tuned..."
systemctl enable --now tuned

echo "==> Enabling and starting irqbalance..."
systemctl enable --now irqbalance

##
## Apply the profile
##
echo "==> Applying profile ${PROFILE_NAME}..."
tuned-adm profile "${PROFILE_NAME}"

##
## Immediate verification (before reboot)
##
echo ""
echo "=========================================="
echo "  CONFIGURATION VERIFICATION"
echo "=========================================="

echo ""
echo "--- Active tuned profile ---"
tuned-adm active

echo ""
echo "--- CPU governor (should be 'performance') ---"
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u \
  || echo "cpufreq not available"

echo ""
echo "--- Transparent Hugepages (should be 'never') ---"
cat /sys/kernel/mm/transparent_hugepage/enabled

echo ""
echo "--- sched_rt_runtime_us (should be -1) ---"
cat /proc/sys/kernel/sched_rt_runtime_us

echo ""
echo "--- Current kernel command line ---"
cat /proc/cmdline

echo ""
echo "--- Kernel command line after reboot (grubby) ---"
grubby --info=DEFAULT | grep args

echo ""
echo "--- irqbalance status ---"
systemctl status irqbalance --no-pager -l

echo ""
echo "=========================================="
echo "  NEXT STEPS"
echo "=========================================="
echo ""
echo "1. Verify the tuned profile is active in the output above"
echo "2. Reboot to apply bootloader parameters (isolcpus, nohz_full, etc.):"
echo "   sudo reboot"
echo ""
echo "After reboot, verify CPU isolation:"
echo "   cat /proc/cmdline | grep isolcpus"
echo "   cat /sys/devices/system/cpu/isolated        # should show 0-13"
echo "   ps -eo pid,psr,comm | grep -v '1[4-9]\$'    # tasks off isolated CPUs"
echo ""
echo "Run a latency test (60 seconds):"
echo "   cyclictest -m -p95 -d0 -a ${ISOLATED_CORES} -t14 --duration=60"
echo ""
echo "Target: max latency < 100us under normal load, ideally < 50us"
echo ""