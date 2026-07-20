# pve-hdd-spindown-guard

SATA HDD 空闲停转守护 — 跑在 PVE Host 上，监控直通给 VM 的机械硬盘，空闲后自动 `hdparm -y`。

> [English](README.md)

## 解决的问题

QEMU 持有直通块设备时会周期性发 flush/MODE_SENSE 等命令重置硬盘 idle timer，导致 `hdparm -S` 无论怎么设都无法触发自动停转。

本脚本通过 **`/proc/diskstats` 扇区计数监控** 替代 idle timer：QEMU 控制命令不产生数据扇区读写，不计入计数 → 真正空闲时计数不变 → 达到阈值后 `hdparm -y`。

## 安装

```bash
# 依赖
apt install hdparm at

git clone https://github.com/pzehrel/pve-hdd-spindown-guard.git
cd pve-hdd-spindown-guard
make install
```

## 用法

```bash
spindown-guard --ls                    # 列出所有 ATA 磁盘
spindown-guard -h                      # 帮助
```

```bash
# CLI 指定（支持简写 sdb，自动解析为 by-id）
spindown-guard -i sdb -i sdd -t 20

# 完整 by-id 也可以
spindown-guard -i ata-WDC_WD10PURX-...WD-WCAW3FTHF6L5 -t 20

# 监控所有 HDD
spindown-guard --all -t 20

# 查看状态（含 QEMU 持有信息）
spindown-guard --status

# 列出所有磁盘（含 SMART 和 QEMU 持有信息）
spindown-guard --ls

# 立即停转（备份脚本末尾调用）
spindown-guard --once -s sdb
```

### 开机启动

```bash
# 安装 systemd service — 开机自动运行，通过 at(1) 自调度
spindown-guard --install

# 查看状态
systemctl status spindown-guard

# 卸载
spindown-guard --uninstall
```

## 原理

```
/proc/diskstats 扇区计数 → 状态文件快照对比
  → 计数变化 → 盘在使用 → 重置空闲计时
  → 计数不变 → 累计空闲时间 → 达阈值 → hdparm -y
  → 已 standby → 跳过
```

通过 `at(1)` 自调度，下次检测时间 = 最短剩余空闲时间。所有盘 standby 后自动暂停。

## License

MIT
