#!/usr/bin/env bash
# =============================================================================
# spindown-guard — SATA HDD idle-spindown daemon
#
# Monitors HDDs via /proc/diskstats sector counters. When a disk has been
# idle (no data I/O) for a configurable threshold, issues hdparm -y.
#
# The script self-schedules via at(1) at the optimal interval (shortest
# remaining idle time across all monitored disks). When all disks are
# already standby the chain pauses until the next external trigger.
#
# Usage:
#   spindown-guard                         # run with saved config
#   spindown-guard -i ata-DISK1 -i ata-DISK2   # overwrite config & run
#   spindown-guard -i sdb -i sdd -t 20     # specify disks
#   spindown-guard --status                # show per-disk state
#   spindown-guard --once -s sdb           # one-shot spindown (no config)
#   spindown-guard --install               # systemd service
# =============================================================================

set -euo pipefail

readonly SCRIPT_VERSION="1.2.0"
readonly CONFIG_FILE="/etc/spindown-guard.conf"
readonly STATE_DIR="/var/lib/spindown-guard"
readonly AT_JOB_TAG="spindown-guard"
readonly LOCK_FILE="/var/run/spindown-guard.lock"

# ── CLI defaults ──────────────────────────────────────────────────
IDLE_MIN=20
DRY_RUN=false
QUIET=false
COMMAND=""                     # ""=run, ls, status, install, uninstall, once
DISK_IDS=()                    # by-id strings
SPIN_DEV=""                    # for --once -s
IS_TTY=false
[ -t 0 ] && [ -t 1 ] && IS_TTY=true

# ── Helpers ───────────────────────────────────────────────────────

log()    { [ "${QUIET}" = false ] && echo "[$(date '+%H:%M:%S')] ${*}" >&2; }
warn()   { echo "[$(date '+%H:%M:%S')] WARN: ${*}" >&2; }
err()    { echo "[$(date '+%H:%M:%S')] ERROR: ${*}" >&2; }
die()    { printf "%b\n" "$*" >&2; exit 1; }

resolve_dev() { basename "$(readlink -f "/dev/disk/by-id/${1}" 2>/dev/null)" 2>/dev/null; }

# Resolve a short name (sdb, /dev/sdb) → full by-id
# Returns the by-id string, or empty if not found.
resolve_to_id() {
    local input="${1#/dev/}"          # strip /dev/ prefix if present
    local dev; dev=$(basename "${input}")  # pure kernel name: sdb

    for link in /dev/disk/by-id/ata-*; do
        [ -e "${link}" ] || continue
        [[ "$(basename "${link}")" =~ -part ]] && continue
        local target; target=$(basename "$(readlink -f "${link}")")
        if [ "${target}" = "${dev}" ]; then
            basename "${link}"
            return 0
        fi
    done
    return 1
}

get_sectors() {
    local dev="${1}"
    awk -v d=" ${dev} " '$3==d{print $6+$10; exit}' /proc/diskstats
}

get_power_state() {
    local dev="${1}"
    LC_ALL=C hdparm -C "/dev/${dev}" 2>/dev/null \
        | grep -i "drive state is:" \
        | sed -E 's/.*drive state is:\s*//; s/[[:space:]]//g' \
        | tr '[:upper:]' '[:lower:]' \
        | head -1
}

is_rotational() {
    local r; r=$(cat "/sys/block/${1}/queue/rotational" 2>/dev/null || echo "0")
    [ "${r}" = "1" ]
}

smart_passed() {
    command -v smartctl >/dev/null 2>&1 || { echo "-"; return 0; }
    local out; out=$(smartctl -H "/dev/${1}" 2>&1) || true
    echo "${out}" | grep -qi "PASSED" && { echo "✓"; return 0; } || { echo "✗"; return 0; }
}
# Check if a disk is held by a QEMU/KVM process
disk_holders() {
    local dev="${1}"
    local pids; pids=$(fuser "/dev/${dev}" 2>/dev/null | tr -d ' ') || true
    if [ -n "${pids}" ]; then
        for pid in ${pids}; do
            local comm; comm=$(ps -o comm= -p "${pid}" 2>/dev/null || true)
            if echo "${comm}" | grep -qi "qemu\|kvm"; then
                echo "qemu"
                return 0
            fi
        done
        echo "other"
        return 0
    fi
    echo "none"
    return 0
}

# ── Locking ───────────────────────────────────────────────────────

LOCK_FD=""
acquire_lock() {
    mkdir -p "$(dirname "${LOCK_FILE}")"
    exec {LOCK_FD}>"${LOCK_FILE}"
    if ! flock -n "${LOCK_FD}"; then
        die "另一个 spindown-guard 实例正在运行（lock: ${LOCK_FILE}）"
    fi
}

# ── Config file ───────────────────────────────────────────────────

load_config() {
    [ -f "${CONFIG_FILE}" ] || return 1
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    return 0
}

save_config() {
    mkdir -p "$(dirname "${CONFIG_FILE}")"
    cat > "${CONFIG_FILE}" <<EOF
# spindown-guard config — $(date)
IDLE_MIN=${IDLE_MIN}
DISK_IDS=(
$(printf '  %s\n' "${DISK_IDS[@]}")
)
EOF
}

# ── at scheduling ─────────────────────────────────────────────────

cancel_at_jobs() {
    for job_id in $(atq 2>/dev/null | awk '{print $1}'); do
        if at -c "${job_id}" 2>/dev/null | grep -q "${AT_JOB_TAG}"; then
            atrm "${job_id}" 2>/dev/null || true
        fi
    done
}

schedule_next() {
    local min_remain="${1}"
    cancel_at_jobs
    local script_path; script_path="$(readlink -f "${0}")"
    local at_cmd="${script_path}"
    local at_when="now + ${min_remain} minutes"

    if [ "${DRY_RUN}" = true ]; then
        log "[dry-run] 将调度: at ${at_when}"
    else
        echo "${at_cmd}  # ${AT_JOB_TAG}" | at "${at_when}" 2>/dev/null || {
            warn "at 调度失败 — atd 是否在运行？"
            warn "  手动: ${at_cmd}"
            return 1
        }
        log "下次检测: ${at_when}（${min_remain} 分钟后）"
    fi
}

# ── Core logic ────────────────────────────────────────────────────

process_disk() {
    local disk_id="${1}"
    local dev; dev=$(resolve_dev "${disk_id}") || { err "无法解析: ${disk_id}"; return 1; }

    local state_file="${STATE_DIR}/${dev}.state"
    local now; now=$(date +%s)
    local cur; cur=$(get_sectors "${dev}") || { err "读取 ${dev} I/O 失败"; return 1; }
    local pwr; pwr=$(get_power_state "${dev}")

    # Already sleeping — done
    case "${pwr}" in
        standby|sleep) rm -f "${state_file}"; return 0 ;;
        active/idle|active|idle) ;;
        *) warn "${dev}: 未知电源状态 '${pwr}'"; return 1 ;;
    esac

    # Compare with snapshot
    local prev_sectors=0 idle_since=0
    if [ -f "${state_file}" ]; then
        read -r prev_sectors idle_since < "${state_file}" 2>/dev/null || true
        prev_sectors="${prev_sectors:-0}"
        idle_since="${idle_since:-0}"
    fi

    if [ "${cur}" != "${prev_sectors}" ]; then
        [ "${QUIET}" = false ] && log "${dev}: I/O 活跃 → 重置空闲计时"
        echo "${cur} ${now}" > "${state_file}"
        return 1
    fi

    [ "${idle_since}" -eq 0 ] && idle_since="${now}"

    local idle_secs=$(( now - idle_since ))
    local idle_mins=$(( idle_secs / 60 ))
    local threshold_secs=$(( IDLE_MIN * 60 ))

    if [ "${idle_secs}" -ge "${threshold_secs}" ]; then
        log "${dev}: 空闲 ${idle_mins} 分钟 ≥ ${IDLE_MIN} 分钟 → 停转"
        if [ "${DRY_RUN}" = true ]; then
            log "[dry-run] hdparm -y /dev/${dev}"
        else
            sync
            hdparm -y "/dev/${dev}" >/dev/null 2>&1 && log "${dev}: → standby" || { warn "${dev}: hdparm -y 失败"; return 1; }
        fi
        rm -f "${state_file}"
        return 0
    fi

    # Not yet — update state, return remaining minutes
    local remain=$(( IDLE_MIN - idle_mins ))
    [ "${remain}" -lt 1 ] && remain=1
    [ "${QUIET}" = false ] && log "${dev}: 空闲 ${idle_mins}/${IDLE_MIN} min（还需 ${remain} min）"
    echo "${cur} ${idle_since}" > "${state_file}"
    echo "${remain}"
    return 2
}

# ── Status display ────────────────────────────────────────────────

cmd_status() {
    load_config || { echo "无配置文件 (${CONFIG_FILE})。请先用 -i 指定磁盘。"; exit 1; }

    printf "%-6s %-55s %-10s %-7s %s\n" "DEV" "BY-ID" "STATE" "HELD" "IDLE"
    printf "%-6s %-55s %-10s %-7s %s\n" "---" "-----" "-----" "-----" "----"

    for disk_id in "${DISK_IDS[@]}"; do
        local dev; dev=$(resolve_dev "${disk_id}" 2>/dev/null) || { printf "%-6s %-55s %-10s %-7s %s\n" "?" "${disk_id:0:54}" "ERR" "-" "-"; continue; }
        local pwr; pwr=$(get_power_state "${dev}" 2>/dev/null || echo "unknown")
        local cur; cur=$(get_sectors "${dev}" 2>/dev/null || echo "?")

        local state_str="${pwr}"
        local idle_str="-"
        local state_file="${STATE_DIR}/${dev}.state"

        if [ -f "${state_file}" ]; then
            local prev=0 since=0
            read -r prev since < "${state_file}" 2>/dev/null || true
            if [ "${cur}" = "${prev}" ] && [ "${since}" -gt 0 ]; then
                local idle_mins=$(( ($(date +%s) - since) / 60 ))
                state_str="${pwr}"
                idle_str="${idle_mins} min"
            elif [ "${cur}" != "${prev}" ]; then
                state_str="${pwr}"
                idle_str="busy"
            fi
        fi

        local holder; holder=$(disk_holders "${dev}")
        printf "%-6s %-55s %-10s %-7s %s\n" "${dev}" "${disk_id:0:54}" "${state_str}" "${holder}" "${idle_str}"
    done
}

# ── List disks ────────────────────────────────────────────────────

cmd_ls() {
    printf "%-5s %-55s %8s %-7s %s\n" "DEV" "BY-ID" "SIZE" "HELD" "SMART"
    printf "%-5s %-55s %8s %-7s %s\n" "---" "-----" "----" "-----" "-----"
    for link in /dev/disk/by-id/ata-*; do
        [ -e "${link}" ] || continue
        [[ "$(basename "${link}")" =~ -part ]] && continue
        local id; id=$(basename "${link}")
        local dev; dev=$(basename "$(readlink -f "${link}")")
        local sz; sz=$(lsblk -dno SIZE "/dev/${dev}" 2>/dev/null || echo "?")
        local hdd; hdd=""
        is_rotational "${dev}" && hdd="HDD" || hdd="SSD"
        local holder; holder=$(disk_holders "${dev}")
        local sm; sm=$(smart_passed "${dev}")
        printf "%-5s %-55s %8s %-7s %s\n" "${dev}" "${id:0:54}" "${sz}" "${holder}" "${sm}"
    done
}

# ── One-shot spindown ─────────────────────────────────────────────

cmd_once() {
    if [ -n "${SPIN_DEV}" ]; then
        # Immediate spindown of a specific disk
        local _dev; _dev="${SPIN_DEV#/dev/}"   # sdb, /dev/sdb → sdb
        local disk_path="/dev/${_dev}"
        [ -b "${disk_path}" ] || die "${disk_path} 不是有效的块设备"
        local pwr; pwr=$(get_power_state "${_dev}")
        case "${pwr}" in
            standby|sleep)
                echo "${_dev}: 已是 ${pwr}，无需操作"
                exit 0 ;;
        esac
        log "立即停转 ${_dev}..."
        if [ "${DRY_RUN}" = true ]; then
            log "[dry-run] hdparm -y ${disk_path}"
        else
            sync
            hdparm -y "${disk_path}" >/dev/null 2>&1 \
                && log "${_dev}: → standby" \
                || die "${_dev}: hdparm -y 失败"
        fi
        exit 0
    fi

    # --once without -s: process DISK_IDS once, no config save, no scheduling
    [ "${#DISK_IDS[@]}" -gt 0 ] || die "--once 需要 -s <dev> 或 -i <id>"

    for disk_id in "${DISK_IDS[@]}"; do
        set +e; process_disk "${disk_id}"; set -e
    done
}

# ── Install / uninstall ───────────────────────────────────────────

SCRIPT_PATH="$(readlink -f "${0}")"
readonly SERVICE_NAME="spindown-guard"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cmd_install() {
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限安装 systemd service"

    load_config || die "未找到配置文件。请先运行 --select 或 -i 保存配置。"

    cat > "${UNIT_FILE}" <<UNIT
[Unit]
Description=SATA HDD spindown guard
Documentation=https://github.com/pzehrel/pve-hdd-spindown-guard
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=${SCRIPT_PATH}

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    systemctl start "${SERVICE_NAME}.service" 2>/dev/null || true

    echo "✔ systemd service 已安装: ${SERVICE_NAME}"
    echo "  systemctl status ${SERVICE_NAME}"
}

cmd_uninstall() {
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限"
    cancel_at_jobs
    systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "${UNIT_FILE}"
    systemctl daemon-reload
    rm -f "${CONFIG_FILE}"
    rm -rf "${STATE_DIR}"
    echo "✔ 已卸载"
}

# ── Default: run cycle ────────────────────────────────────────────

cmd_run() {
    # Load config unless disks were explicitly passed
    if [ "${#DISK_IDS[@]}" -eq 0 ]; then
        load_config || die "无配置文件且未指定磁盘。\n  用法: $(basename "${0}") --select\n  或:   $(basename "${0}") -i <by-id>"
    else
        # Disks specified on CLI — save to config
        save_config
    fi

    # Check atd is running
    if ! systemctl -q is-active atd 2>/dev/null && ! pgrep -x atd >/dev/null 2>&1; then
        warn "atd 未运行 — 将无法自动调度下次检测"
        warn "  安装: apt install at && systemctl enable --now atd"
    fi

    echo "═══════════════════════════════════════════════════════"
    echo "  spindown-guard v${SCRIPT_VERSION}  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  阈值: ${IDLE_MIN} min  |  磁盘: ${#DISK_IDS[@]} 块"
    [ "${DRY_RUN}" = true ] && echo "  *** DRY-RUN — 不会实际操作 ***"
    echo "═══════════════════════════════════════════════════════"

    mkdir -p "${STATE_DIR}"

    local min_remain=9999
    for disk_id in "${DISK_IDS[@]}"; do
        set +e; output=$(process_disk "${disk_id}"); rc=$?; set -e
        case ${rc} in
            2) local remain; remain=$(echo "${output}" | tail -1)
               if [[ "${remain}" =~ ^[0-9]+$ ]] && [ "${remain}" -lt "${min_remain}" ]; then
                   min_remain="${remain}"
               fi ;;
            1) # I/O 活跃或错误 → 按满阈值重检
               [ "${IDLE_MIN}" -lt "${min_remain}" ] && min_remain="${IDLE_MIN}" ;;
        esac
    done

    if [ "${min_remain}" -lt 9999 ]; then
        schedule_next "${min_remain}"
    else
        log "所有磁盘已 standby，暂停调度。"
        log "备份脚本中已包含立即停转，磁盘将在下次访问时自动唤醒。"
    fi

    # Cleanup stale state files
    local -A active_devs
    for id in "${DISK_IDS[@]}"; do
        local d; d=$(resolve_dev "${id}" 2>/dev/null || true)
        [ -n "${d}" ] && active_devs["${d}"]=1
    done
    for sf in "${STATE_DIR}"/*.state; do
        [ -f "${sf}" ] || continue
        local sdev; sdev=$(basename "${sf}" .state)
        [ -n "${active_devs[${sdev}]:-}" ] || rm -f "${sf}"
    done
}

# ── Usage ─────────────────────────────────────────────────────────

usage() {
    cat <<HELP
spindown-guard v${SCRIPT_VERSION} — SATA HDD 空闲停转守护

用法:
  $(basename "${0}")                        从配置文件读取并运行（用于 systemd / at）
  $(basename "${0}") -i <by-id> [-i ...]    指定磁盘，写入配置并运行
  $(basename "${0}") --status               查看监控状态
  $(basename "${0}") --ls                   列出所有 ATA 磁盘
  $(basename "${0}") --once -s <dev>        立即停转一块盘
  $(basename "${0}") --install              安装 systemd 开机启动
  $(basename "${0}") --uninstall            卸载

参数:
  -i, --disk <id>    磁盘 by-id 或设备名 sdb（可重复，每次覆盖完整列表）
  --all              自动选择所有 SATA HDD
  --once             单次运行，不保存配置、不调度后续
  -s, --spin <dev>   配合 --once，立即停转指定盘（如 sdb）
  -t, --idle <min>   空闲阈值（分钟），默认 20
  --dry-run          只报告，不实际操作
  -q, --quiet        减少输出
  --status           查看状态
  --ls               列出所有 ATA 磁盘
  --install          安装 systemd service
  --uninstall        卸载
  -h, --help         帮助

原理:
  读取 /proc/diskstats 扇区计数 → 对比快照 → 空闲达阈值后 hdparm -y
  通过 at(1) 自调度，间隔 = 最短剩余空闲时间。所有盘 standby 后暂停。

示例:
  $(basename "${0}") -i ata-DISK1 -i ata-DISK2          # 监控两块盘
  $(basename "${0}") --once -s sdb           # 立即停转 sdb
  $(basename "${0}") --status               # 查看所有盘状态
HELP
}

# ── Argument parsing ──────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "${1}" in
        -i|--disk)
            [ -n "${2:-}" ] || die "-i 需要 by-id 或设备名（如 sdb）"
            _arg="${2}"
            if [[ "${_arg}" =~ ^/dev/ ]] || [[ ! "${_arg}" =~ ^ata- ]]; then
                _resolved=$(resolve_to_id "${_arg}") || die "无法解析: ${_arg}"
                DISK_IDS+=("${_resolved}")
            else
                DISK_IDS+=("${_arg}")
            fi
            shift 2 ;;
        --ls)     COMMAND="ls"; shift ;;
        --status) COMMAND="status"; shift ;;
        --once)   COMMAND="once"; shift ;;
        -s|--spin)
            [ -n "${2:-}" ] || die "-s 需要设备名（如 sdb）"; SPIN_DEV="${2}"; shift 2 ;;
        --all)
            for l in /dev/disk/by-id/ata-*; do
                [ -e "${l}" ] || continue; [[ "$(basename "${l}")" =~ -part ]] && continue
                _d=$(basename "$(readlink -f "${l}")")
                is_rotational "${_d}" && DISK_IDS+=("$(basename "${l}")")
            done
            shift ;;
        -t|--idle)
            [ -n "${2:-}" ] || die "-t 需要分钟数"; IDLE_MIN="${2}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -q|--quiet) QUIET=true; shift ;;
        --install) COMMAND="install"; shift ;;
        --uninstall) COMMAND="uninstall"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: ${1}\n  用 -h 查看帮助" ;;
    esac
done

# ── Dispatch ──────────────────────────────────────────────────────

acquire_lock

case "${COMMAND}" in
    select)   cmd_select; [ "${#DISK_IDS[@]}" -gt 0 ] && { save_config; cmd_run; } || echo "未选择磁盘，退出。" ;;
    ls)       cmd_ls ;;
    status)   cmd_status ;;
    install)  cmd_install ;;
    uninstall) cmd_uninstall ;;
    once)     cmd_once ;;
    "")
        if [ "${#DISK_IDS[@]}" -gt 0 ]; then
            cmd_run
        elif load_config 2>/dev/null; then
            # at-scheduled / systemd run — ok, config loaded
            cmd_run
        else
            die "未指定磁盘。\n\n  用法: $(basename "${0}") -i sdb [-i sdc ...] [-t 分钟]\n        $(basename "${0}") --all\n\n  查看可用磁盘: $(basename "${0}") --ls"
        fi
        ;;
    *)        die "未知命令: ${COMMAND}" ;;
esac
