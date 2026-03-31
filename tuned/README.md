# Real-Time Tuned Profile Setup

This guide describes how to configure CPU isolation and real-time tuning on a
CentOS Stream 9 system with `kernel-rt`, using a custom `tuned` profile.

## Overview

| CPUs    | Role                              |
|---------|-----------------------------------|
| 0–13    | Real-time workloads (isolated)    |
| 14–19   | System, IRQs, background tasks    |

The setup script automates the following:
- Creates the `realtime-custom` tuned profile
- Configures CPU isolation, C-state disabling, and scheduler parameters
- Configures `irqbalance` to avoid placing IRQs on RT CPUs
- Applies kernel boot parameters via `grubby`

---

## Prerequisites

- CentOS Stream 9 installed with `kernel-rt`
- Packages installed: `tuned`, `tuned-profiles-realtime`, `irqbalance`, `realtime-tests`
- Root access

Verify before running:

```bash
rpm -q tuned tuned-profiles-realtime irqbalance realtime-tests kernel-rt
uname -r   # should show .rt in the kernel version
```

---

## Step 1 — Adapt the script variables

Open `setup-tuned-rt.sh` and adjust the variables at the top to match your
machine's CPU topology:

```bash
ISOLATED_CORES="0-13"        # CPUs dedicated to RT workloads
HOUSEKEEPING_CORES="14-19"   # CPUs for system and IRQs
IRQBALANCE_BANNED_CPUS="00003fff"  # Hex bitmask of isolated CPUs
```

To compute the bitmask for a different CPU range:

```bash
# Example: isolate CPUs 0-13 (14 CPUs)
python3 -c "print(hex(sum(1 << i for i in range(0, 14))))"
# Output: 0x3fff → use 00003fff
```

To inspect your CPU topology before deciding:

```bash
lscpu
lstopo        # requires hwloc
```

---

## Step 2 — Run the setup script

```bash
chmod +x setup-tuned-rt.sh
sudo ./setup-tuned-rt.sh
```

The script will:
1. Write the tuned profile to `/etc/tuned/realtime-custom/tuned.conf`
2. Configure `/etc/sysconfig/irqbalance`
3. Enable and start `tuned` and `irqbalance`
4. Apply the `realtime-custom` profile
5. Print a verification summary

---

## Step 3 — Review the verification output

Before rebooting, check the script output for:

| Check | Expected value |
|-------|---------------|
| Active tuned profile | `realtime-custom` |
| CPU governor | `performance` |
| Transparent Hugepages | `never` |
| `sched_rt_runtime_us` | `-1` |
| grubby args | contains `isolcpus=0-13 nohz_full=0-13` |

---

## Step 4 — Reboot

Bootloader parameters (`isolcpus`, `nohz_full`, `rcu_nocbs`, etc.) are only
applied after a reboot:

```bash
sudo reboot
```

---

## Step 5 — Post-reboot verification

### Verify CPU isolation

```bash
# Kernel command line should contain isolcpus, nohz_full, rcu_nocbs
cat /proc/cmdline

# Should show: 0-13
cat /sys/devices/system/cpu/isolated

# Should show: 14-19
cat /sys/devices/system/cpu/present
```

### Verify tuned profile

```bash
tuned-adm active
# Expected: Current active profile: realtime-custom
```

### Verify no system tasks are running on isolated CPUs

```bash
# List tasks with their CPU affinity — none should be on CPUs 0-13
ps -eo pid,psr,comm | awk '$2 <= 13 {print}'
```

### Verify IRQ affinity

```bash
# All IRQs should be routed to CPUs 14-19
for i in /proc/irq/*/smp_affinity_list; do
  echo "$i: $(cat $i)"
done
```

### Verify C-states are disabled

```bash
# All CPUs should show C0 only
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name
```

---

## Step 6 — Latency testing

Use `cyclictest` from the `realtime-tests` package to measure RT latency:

```bash
# Basic 60-second test on isolated CPUs
cyclictest -m -p95 -d0 -a 0-13 -t14 --duration=60

# With network load in parallel (stress the system CPUs)
stress-ng --cpu 6 --cpu-affinity 14-19 &
cyclictest -m -p95 -d0 -a 0-13 -t14 --duration=60
```

### Interpreting results

| Max latency | Assessment |
|-------------|------------|
| < 50 µs | Excellent |
| 50–100 µs | Good |
| 100–500 µs | Acceptable depending on application |
| > 500 µs | Investigate — likely a missing isolation parameter |

---

## Troubleshooting

### Profile not applying after reboot

```bash
# Check grubby applied the cmdline correctly
grubby --info=DEFAULT | grep args

# Re-apply manually if needed
tuned-adm profile realtime-custom
grubby --update-kernel=DEFAULT --args="isolcpus=0-13 nohz_full=0-13"
```

### High latency on isolated CPUs

Check for remaining interrupt sources:

```bash
# Watch for interrupts hitting isolated CPUs
watch -n1 'cat /proc/interrupts | grep -v "^  0:"'

# Check for kernel threads on isolated CPUs
ps -eo pid,psr,comm,cls | awk '$2 <= 13 && $4 != "-"'
```

### irqbalance not respecting banned CPUs

```bash
systemctl status irqbalance
cat /etc/sysconfig/irqbalance
# Should contain: IRQBALANCE_ARGS="--banirq=00003fff"

# Restart if needed
systemctl restart irqbalance
```

---

## File locations

| File | Description |
|------|-------------|
| `/etc/tuned/realtime-custom/tuned.conf` | Custom tuned profile |
| `/etc/sysconfig/irqbalance` | irqbalance configuration |
| `/proc/cmdline` | Active kernel parameters |
| `/sys/devices/system/cpu/isolated` | Currently isolated CPUs |
