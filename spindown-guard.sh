#!/usr/bin/env bash
# =============================================================================
# spindown-guard — SATA HDD idle-spindown daemon for Proxmox VE
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
#   spindown-guard -i sdb -i sdd -t 20     # monitor specific disks
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

# ── Helpers ───────────────────────────────────────────────────────

log()    { [ "${QUIET}" = false ] && echo "[$(date '+%H:%M:%S')] ${*}" >&2; }
warn()   { echo "[$(date '+%H:%M:%S')] WARN: ${*}" >&2; }
err()    { echo "[$(date '+%H:%M:%S')] ERROR: ${*}" >&2; }
die()    { printf "%b\n" "$*" >&2; exit 1; }

resolve_dev() { basename "$(readlink -f "/dev/disk/by-id/${1}" 2>/dev/null)" 2>/dev/null; }

# Resolve a short device name (sdb, /dev/sdb) → full by-id path.
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
        die "Another spindown-guard instance is running (lock: ${LOCK_FILE})"
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
        log "[dry-run] would schedule: at ${at_when}"
    else
        echo "${at_cmd}  # ${AT_JOB_TAG}" | at "${at_when}" 2>/dev/null || {
            warn "at scheduling failed — is atd running?"
            warn "  Manual: ${at_cmd}"
            return 1
        }
        log "Next check: ${at_when} (in ${min_remain} min)"
    fi
}

# ── Core logic ────────────────────────────────────────────────────

process_disk() {
    local disk_id="${1}"
    local dev; dev=$(resolve_dev "${disk_id}") || { err "cannot resolve: ${disk_id}"; return 1; }

    local state_file="${STATE_DIR}/${dev}.state"
    local now; now=$(date +%s)
    local cur; cur=$(get_sectors "${dev}") || { err "failed to read I/O for ${dev}"; return 1; }
    local pwr; pwr=$(get_power_state "${dev}")

    # Already in standby/sleep — nothing to do
    case "${pwr}" in
        standby|sleep) rm -f "${state_file}"; return 0 ;;
        active/idle|active|idle) ;;
        *) warn "${dev}: unknown power state '${pwr}'"; return 1 ;;
    esac

    # Compare sector count with previous snapshot
    local prev_sectors=0 idle_since=0
    if [ -f "${state_file}" ]; then
        read -r prev_sectors idle_since < "${state_file}" 2>/dev/null || true
        prev_sectors="${prev_sectors:-0}"
        idle_since="${idle_since:-0}"
    fi

    if [ "${cur}" != "${prev_sectors}" ]; then
        [ "${QUIET}" = false ] && log "${dev}: I/O active — resetting idle timer"
        echo "${cur} ${now}" > "${state_file}"
        return 1
    fi

    [ "${idle_since}" -eq 0 ] && idle_since="${now}"

    local idle_secs=$(( now - idle_since ))
    local idle_mins=$(( idle_secs / 60 ))
    local threshold_secs=$(( IDLE_MIN * 60 ))

    if [ "${idle_secs}" -ge "${threshold_secs}" ]; then
        log "${dev}: idle ${idle_mins} min ≥ threshold ${IDLE_MIN} min → spinning down"
        if [ "${DRY_RUN}" = true ]; then
            log "[dry-run] hdparm -y /dev/${dev}"
        else
            sync
            hdparm -y "/dev/${dev}" >/dev/null 2>&1 && log "${dev}: → standby" || { warn "${dev}: hdparm -y failed"; return 1; }
        fi
        rm -f "${state_file}"
        return 0
    fi

    # Not yet at threshold — persist state, return remaining minutes
    local remain=$(( IDLE_MIN - idle_mins ))
    [ "${remain}" -lt 1 ] && remain=1
    [ "${QUIET}" = false ] && log "${dev}: idle ${idle_mins}/${IDLE_MIN} min (${remain} min remaining)"
    echo "${cur} ${idle_since}" > "${state_file}"
    echo "${remain}"
    return 2
}

# ── Status display ────────────────────────────────────────────────

cmd_status() {
    load_config || { echo "No config file (${CONFIG_FILE}). Run: spindown-guard -i sdb"; exit 1; }

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
        # Immediate spindown of a single disk
        local _dev; _dev="${SPIN_DEV#/dev/}"   # sdb, /dev/sdb → sdb
        local disk_path="/dev/${_dev}"
        [ -b "${disk_path}" ] || die "${disk_path} is not a valid block device"
        local pwr; pwr=$(get_power_state "${_dev}")
        case "${pwr}" in
            standby|sleep)
                echo "${_dev}: already ${pwr}, nothing to do"
                exit 0 ;;
        esac
        log "Spinning down ${_dev}..."
        if [ "${DRY_RUN}" = true ]; then
            log "[dry-run] hdparm -y ${disk_path}"
        else
            sync
            hdparm -y "${disk_path}" >/dev/null 2>&1 \
                && log "${_dev}: → standby" \
                || die "${_dev}: hdparm -y failed"
        fi
        exit 0
    fi

    # --once mode: process DISK_IDS, no config save, no scheduling
    [ "${#DISK_IDS[@]}" -gt 0 ] || die "--once requires -s <dev> or -i <id>"

    for disk_id in "${DISK_IDS[@]}"; do
        set +e; process_disk "${disk_id}"; set -e
    done
}

# ── Install / uninstall ───────────────────────────────────────────

SCRIPT_PATH="$(readlink -f "${0}")"
readonly SERVICE_NAME="spindown-guard"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cmd_install() {
    [ "$(id -u)" -eq 0 ] || die "root required to install systemd service"

    load_config || die "No config file. Run: spindown-guard -i sdb"

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

    echo "✔ systemd service installed: ${SERVICE_NAME}"
    echo "  systemctl status ${SERVICE_NAME}"
}

cmd_uninstall() {
    [ "$(id -u)" -eq 0 ] || die "root required"
    cancel_at_jobs
    systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "${UNIT_FILE}"
    systemctl daemon-reload
    rm -f "${CONFIG_FILE}"
    rm -rf "${STATE_DIR}"
    echo "✔ uninstalled"
}

# ── Default: run cycle ────────────────────────────────────────────

cmd_run() {
    # Use saved config if no disks specified on command line
    if [ "${#DISK_IDS[@]}" -eq 0 ]; then
        load_config || die "no config and no disks specified.\n  Usage: $(basename "${0}") -i sdb [-i sdc ...] [-t MIN]\n         $(basename "${0}") --all"
    else
        # Disks specified on CLI — persist to config
        save_config
    fi

    # Verify atd is running for self-scheduling
    if ! systemctl -q is-active atd 2>/dev/null && ! pgrep -x atd >/dev/null 2>&1; then
        warn "atd is not running — cannot self-schedule"
        warn "  Fix: apt install at && systemctl enable --now atd"
    fi

    echo "═══════════════════════════════════════════════════════"
    echo "  spindown-guard v${SCRIPT_VERSION}  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Threshold: ${IDLE_MIN} min  |  Disks: ${#DISK_IDS[@]}"
    [ "${DRY_RUN}" = true ] && echo "  *** DRY-RUN — no changes will be made ***"
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
            1) # Busy or error — recheck after full threshold
               [ "${IDLE_MIN}" -lt "${min_remain}" ] && min_remain="${IDLE_MIN}" ;;
        esac
    done

    if [ "${min_remain}" -lt 9999 ]; then
        schedule_next "${min_remain}"
    else
        log "All disks are standby — pausing scheduler."
        log "Disks will auto-wake on next access. Backup scripts can call spindown-guard --once."
    fi

    # Remove state files for disks no longer monitored
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
spindown-guard v${SCRIPT_VERSION} — SATA HDD idle-spindown daemon

Usage:
  $(basename "${0}")                        run with saved config (systemd / at)
  $(basename "${0}") -i sdb [-i ...] [-t N] specify disks and run
  $(basename "${0}") --status               show monitored disk states
  $(basename "${0}") --ls                   list all ATA disks
  $(basename "${0}") --once -s sdb          one-shot spindown
  $(basename "${0}") --install              install systemd service
  $(basename "${0}") --uninstall            remove everything

Options:
  -i, --disk <id>    disk by-id or short name sdb (repeatable)
  --all              auto-discover all SATA HDDs
  --once             run once, no config save, no scheduling
  -s, --spin <dev>   with --once, immediately spindown (e.g. sdb)
  -t, --idle <min>   idle threshold in minutes (default 20)
  --dry-run          simulate only, no changes
  -q, --quiet        suppress per-disk log lines
  --status           show monitored disk states
  --ls               list all ATA disks
  --install          install systemd service
  --uninstall        remove everything
  -h, --help         show this help

How it works:
  Reads /proc/diskstats sector counters → compares to snapshot
  → idle ≥ threshold → hdparm -y
  Self-schedules via at(1) at the optimal interval.
  Pauses when all disks are standby.

Examples:
  $(basename "${0}") -i sdb -t 20
  $(basename "${0}") --once -s sdb
  $(basename "${0}") --status
HELP
}

# ── Argument parsing ──────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "${1}" in
        -i|--disk)
            [ -n "${2:-}" ] || die "-i requires by-id or device name (e.g. sdb)"
            _arg="${2}"
            if [[ "${_arg}" =~ ^/dev/ ]] || [[ ! "${_arg}" =~ ^ata- ]]; then
                _resolved=$(resolve_to_id "${_arg}") || die "cannot resolve: ${_arg}"
                DISK_IDS+=("${_resolved}")
            else
                DISK_IDS+=("${_arg}")
            fi
            shift 2 ;;
        --ls)     COMMAND="ls"; shift ;;
        --status) COMMAND="status"; shift ;;
        --once)   COMMAND="once"; shift ;;
        -s|--spin)
            [ -n "${2:-}" ] || die "-s requires device name (e.g. sdb)"; SPIN_DEV="${2}"; shift 2 ;;
        --all)
            for l in /dev/disk/by-id/ata-*; do
                [ -e "${l}" ] || continue; [[ "$(basename "${l}")" =~ -part ]] && continue
                _d=$(basename "$(readlink -f "${l}")")
                is_rotational "${_d}" && DISK_IDS+=("$(basename "${l}")")
            done
            shift ;;
        -t|--idle)
            [ -n "${2:-}" ] || die "-t requires a number of minutes"; IDLE_MIN="${2}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -q|--quiet) QUIET=true; shift ;;
        --install) COMMAND="install"; shift ;;
        --uninstall) COMMAND="uninstall"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: ${1}\n  Try -h for help" ;;
    esac
done

# ── Dispatch ──────────────────────────────────────────────────────

acquire_lock

case "${COMMAND}" in
    ls)       cmd_ls ;;
    status)   cmd_status ;;
    install)  cmd_install ;;
    uninstall) cmd_uninstall ;;
    once)     cmd_once ;;
    "")
        if [ "${#DISK_IDS[@]}" -gt 0 ]; then
            cmd_run
        elif load_config 2>/dev/null; then
            # at-scheduled / systemd run — config loaded, proceed
            cmd_run
        else
            die "No disks specified.\n\n  Usage: $(basename "${0}") -i sdb [-i sdc ...] [-t MIN]\n         $(basename "${0}") --all\n\n  List available disks: $(basename "${0}") --ls"
        fi
        ;;
    *)        die "Unknown command: ${COMMAND}" ;;
esac
