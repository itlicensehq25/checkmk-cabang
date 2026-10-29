#!/usr/bin/env bash
# =============================================================================
# update_checks.sh - Auto-Update Skrip & Plugin Checkmk dari GitHub
# Repositori : itlicensehq25/checkmk-cabang
# Dijalankan secara otomatis oleh cron job /etc/cron.d/checkmk_auto_update
#
# Cara kerja:
#   1. Mengunduh berkas skrip ke direktori sementara (/tmp).
#   2. Membersihkan karakter \r (anti-CRLF).
#   3. Membandingkan hash SHA-256 antara berkas baru di GitHub vs berkas di Linux.
#      Hanya berkas yang BERBEDA yang ditimpa (Atomic Swap).
#   4. Memperbarui dirinya sendiri jika ada versi baru di GitHub.
# Log: /var/log/checkmk_custom/update_checks.log
# =============================================================================

export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"

GITHUB_USER="itlicensehq25"
GITHUB_REPO="checkmk-cabang"
BRANCH="main"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -g|--github) GITHUB_REPO="$2"; shift 2 ;;
        -b|--branch) BRANCH="$2"; shift 2 ;;
        *) shift ;;
    esac
done

BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/linux"
LOCAL_DIR="/usr/lib/check_mk_agent/local"
PLUGIN_DIR="/usr/lib/check_mk_agent/plugins"
LOG_DIR="/var/log/checkmk_custom"
LOG_FILE="${LOG_DIR}/update_checks.log"
TEMP_DIR="/tmp/checkmk_update_$$"

mkdir -p "$LOCAL_DIR" "$PLUGIN_DIR" "$LOG_DIR" "$TEMP_DIR" 2>/dev/null

# 10 Skrip Local Checks Linux
LOCAL_CHECKS=(
    "battery_health.sh"
    "cpu_info.sh"
    "disk_nvme_health.sh"
    "fan_health.sh"
    "info_network.sh"
    "info_OS_office.sh"
    "ram_health.sh"
    "ram_usage.sh"
    "remote_apps.sh"
    "storage_usage.sh"
)

# Plugin Resmi Linux
PLUGIN_FILES=(
    "mk_inventory.linux"
)

write_log() {
    local msg="$1"
    local now
    now=$(date "+%Y-%m-%d %H:%M:%S")
    local line="${now}  ${msg}"

    if [ -f "$LOG_FILE" ]; then
        local sz
        sz=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$sz" -gt 204800 ]; then
            local tmp_log="${LOG_FILE}.rot.$$"
            tail -n 200 "$LOG_FILE" > "$tmp_log" 2>/dev/null && mv -f "$tmp_log" "$LOG_FILE" 2>/dev/null
        fi
    fi
    echo "$line" >> "$LOG_FILE" 2>/dev/null
}

sync_file() {
    local url="$1"
    local dest="$2"
    local filename
    filename=$(basename "$dest")
    local tmp_file="${TEMP_DIR}/${filename}.new"

    # Unduh dan bersihkan \r (anti-CRLF)
    if ! curl -sSfL "$url" 2>/dev/null | tr -d '\r' > "$tmp_file"; then
        rm -f "$tmp_file" 2>/dev/null
        return 2 # gagal unduh
    fi

    if [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file" 2>/dev/null
        return 2 # file kosong
    fi

    local same=0
    if [ -f "$dest" ]; then
        local hash_new hash_old
        hash_new=$(sha256sum "$tmp_file" 2>/dev/null | awk '{print $1}')
        hash_old=$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')
        if [ -n "$hash_new" ] && [ "$hash_new" = "$hash_old" ]; then
            same=1
        fi
    fi

    if [ "$same" -eq 1 ]; then
        rm -f "$tmp_file" 2>/dev/null
        return 0 # tidak ada perubahan
    fi

    chmod +x "$tmp_file" 2>/dev/null
    mv -f "$tmp_file" "$dest" 2>/dev/null
    return 1 # berhasil diperbarui
}

UPDATED=0
FAILED=0
TOTAL=0

# ---------- 1. Sinkronisasi Local Checks ----------
for script in "${LOCAL_CHECKS[@]}"; do
    TOTAL=$(( TOTAL + 1 ))
    target_path="${LOCAL_DIR}/${script}"
    url="${BASE_URL}/local_checks/${script}?v=$(date +%s)"

    sync_file "$url" "$target_path"
    res=$?
    if [ "$res" -eq 1 ]; then
        UPDATED=$(( UPDATED + 1 ))
        write_log "DIPERBARUI (Local Check): ${script}"
    elif [ "$res" -eq 2 ]; then
        FAILED=$(( FAILED + 1 ))
        write_log "GAGAL: ${script} (Download error / timeout)"
    fi
done

# ---------- 2. Sinkronisasi Plugin ----------
for plugin in "${PLUGIN_FILES[@]}"; do
    TOTAL=$(( TOTAL + 1 ))
    target_path="${PLUGIN_DIR}/${plugin}"
    url="${BASE_URL}/plugins/${plugin}?v=$(date +%s)"

    sync_file "$url" "$target_path"
    res=$?
    if [ "$res" -eq 1 ]; then
        UPDATED=$(( UPDATED + 1 ))
        write_log "DIPERBARUI (Plugin): ${plugin}"
    elif [ "$res" -eq 2 ]; then
        FAILED=$(( FAILED + 1 ))
        write_log "GAGAL (Plugin): ${plugin}"
    fi
done

write_log "Pengecekan selesai. Diperbarui=${UPDATED}, Gagal=${FAILED}, Total Diperiksa=${TOTAL}"

# ---------- 3. Perbarui Skrip Ini Sendiri (Self-Update) ----------
self_path="/usr/local/bin/update_checks.sh"
[ ! -f "$self_path" ] && self_path="$0"

if [ -f "$self_path" ]; then
    url="${BASE_URL}/update_checks.sh?v=$(date +%s)"
    sync_file "$url" "$self_path"
    if [ "$?" -eq 1 ]; then
        write_log "update_checks.sh sendiri berhasil diperbarui (efektif pada jadwal berikutnya)"
    fi
fi

rm -rf "$TEMP_DIR" 2>/dev/null
exit 0
