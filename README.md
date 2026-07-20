# pve-hdd-spindown-guard

SATA HDD idle-spindown daemon for Proxmox VE. Runs on the PVE host, monitors pass-through HDDs via `/proc/diskstats`, and issues `hdparm -y` when disks are idle.

> [中文](README_zh.md)

## The Problem

QEMU holding a pass-through block device periodically issues flush / MODE_SENSE commands that reset the drive's firmware idle timer. This makes `hdparm -S` unusable — the drive never enters standby automatically.

## The Solution

This script replaces firmware idle timers with **`/proc/diskstats` sector-count monitoring**. QEMU control commands don't read or write data sectors, so they never increment the counters. When the counter stays flat long enough, the disk is truly idle and `hdparm -y` is safe to call.

## Install

```bash
git clone https://github.com/pzehrel/pve-hdd-spindown-guard.git
cd pve-hdd-spindown-guard
make install
```

## Usage

```bash
# No args — interactive disk picker (TTY required)
spindown-guard

# Pick disks interactively
spindown-guard --select -t 20

# Specify disks by name (resolves to by-id automatically)
spindown-guard -i sdb -i sdd -t 20

# Full by-id works too
spindown-guard -i ata-WDC_WD10PURX-...WD-WCAW3FTHF6L5 -t 20

# All rotational ATA disks
spindown-guard --all -t 20

# Show monitored disk states
spindown-guard --status

# List all ATA disks
spindown-guard --ls

# One-shot spindown (call from backup scripts)
spindown-guard --once -s sdb
```

### Auto-start on boot

```bash
# Install systemd service — runs on boot, self-schedules via at(1)
spindown-guard --install

# Check status
systemctl status spindown-guard

# Remove
spindown-guard --uninstall
```

## How It Works

```
read /proc/diskstats sector counters → compare to snapshot
  → changed → disk is busy → reset idle timer
  → unchanged → accumulating idle time → threshold reached → hdparm -y
  → already standby → skip
```

Self-schedules via `at(1)` at the optimal interval (shortest remaining idle time). Pauses when all disks are standby.

## Dependencies

`bash`, `hdparm`, `at`, `smartmontools` (optional, for SMART status in `--ls`)

## License

MIT
