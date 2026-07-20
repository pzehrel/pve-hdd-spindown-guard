# pve-hdd-spindown-guard

SATA HDD 空闲停转守护 — 跑在 PVE Host 上，监控直通给 VM 的机械硬盘，空闲后自动 `hdparm -y`。

> [English](README.md)

## 解决的问题

QEMU 持有直通块设备时会周期性发 flush/MODE_SENSE 等命令重置硬盘 idle timer，导致 `hdparm -S` 无论怎么设都无法触发自动停转。

本脚本通过 **`/proc/diskstats` 扇区计数监控** 替代 idle timer：QEMU 控制命令不产生数据扇区读写，不计入计数 → 真正空闲时计数不变 → 达到阈值后 `hdparm -y`。

## 安装

```bash
git clone https://github.com/pzehrel/pve-hdd-spindown-guard.git
cd pve-hdd-spindown-guard
make install
```

## 用法

```bash
spindown-guard                      # 直接运行 → 交互式选择
spindown-guard -h                   # 帮助
```

```bash
# 交互式选择
spindown-guard --select -t 20

# CLI 指定
spindown-guard -i ata-WDC_WD10PURX-...WD-WCAW3FTHF6L5 -t 20

# 监控所有 HDD
spindown-guard --all -t 20

# 查看状态
spindown-guard --status

# 立即停转（备份脚本末尾调用）
spindown-guard --once -s sdb

# 开机启动
spindown-guard --install
```

## 原理

```
/proc/diskstats 扇区计数 → 状态文件快照对比
  → 计数变化 → 盘在使用 → 重置空闲计时
  → 计数不变 → 累计空闲时间 → 达阈值 → hdparm -y
  → 已 standby → 跳过
```

通过 `at(1)` 自调度，下次检测时间 = 最短剩余空闲时间。所有盘 standby 后自动暂停。

## 依赖

- `bash`、`hdparm`、`at`、`smartmontools`（可选）

## License

MIT
