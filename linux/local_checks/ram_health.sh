#!/usr/bin/env bash
# =====================================================================
# Local Check Checkmk: Weekly RAM Health & Slot Inventory (Asynchronous)
# Scheduled to run once a week on Saturday at 11:00 AM
# =====================================================================
CACHE_DIR="/var/lib/check_mk_agent/cache"
mkdir -p "$CACHE_DIR" 2>/dev/null
CACHE_FILE="$CACHE_DIR/cache_ram_health.txt"

# Get current day of week (1=Monday, ..., 7=Sunday) and hour
DOW=$(date +%u)
CURRENT_HOUR=$(date +%H)

# Find last Saturday 11:00 AM epoch
if [ "$DOW" -eq 6 ]; then
    if [ "$CURRENT_HOUR" -lt 11 ]; then
        LAST_SAT_11=$(date -d "last saturday 11:00:00" +%s 2>/dev/null)
    else
        LAST_SAT_11=$(date -d "today 11:00:00" +%s 2>/dev/null)
    fi
else
    LAST_SAT_11=$(date -d "last saturday 11:00:00" +%s 2>/dev/null)
fi

if [ -z "$LAST_SAT_11" ]; then
    # Fallback to 7 days ago if date -d fails
    LAST_SAT_11=$(( $(date +%s) - 604800 ))
fi

need_update() {
    local file=$1
    local threshold=$2
    local log_file="/var/log/checkmk_custom/memtester_health.log"
    
    # Jika file cache belum ada, wajib update
    if [ ! -f "$file" ]; then
        return 0
    fi
    
    local file_ts log_ts=0
    file_ts=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    
    # Jika file log memtester dimodifikasi setelah file cache dibuat (artinya ada pengetesan baru), wajib update
    if [ -f "$log_file" ]; then
        log_ts=$(stat -c %Y "$log_file" 2>/dev/null || echo 0)
        if [ "$log_ts" -gt "$file_ts" ]; then
            return 0
        fi
    fi
    
    # Jika waktu file cache lebih lama dari batas hari Sabtu pukul 11:00 AM terakhir, wajib update
    if [ "$file_ts" -lt "$threshold" ]; then
        return 0
    fi
    
    return 1
}

if need_update "$CACHE_FILE" "$LAST_SAT_11"; then
    > "$CACHE_FILE"
    
    # --- 1. DETEKSI SLOT RAM FISIK (dmidecode) ---
    total_slots=0
    used_slots=0
    empty_slots=0
    active_modules=()

    if command -v dmidecode >/dev/null 2>&1; then
        # Menggunakan regex ^[[:space:]]+Size: agar tidak keliru mencocokkan Volatile Size, Logical Size, dll.
        slots_raw=$(sudo dmidecode -t 17 2>/dev/null | grep -E -i '^[[:space:]]+Size:')
        
        if [ -n "$slots_raw" ]; then
            while read -r line; do
                [ -z "$line" ] && continue
                total_slots=$((total_slots + 1))
                
                # Ekstrak nilai setelah "Size:"
                val=$(echo "$line" | cut -d':' -f2- | xargs)
                val_lower=$(echo "$val" | tr 'A-Z' 'a-z')
                
                # Periksa apakah slot kosong (No Module, None, atau Unknown)
                if [ -z "$val" ] || [[ "$val_lower" =~ "no module" ]] || [ "$val_lower" = "none" ] || [ "$val_lower" = "unknown" ] || [ "$val_lower" = "no_module_installed" ]; then
                    empty_slots=$((empty_slots + 1))
                else
                    used_slots=$((used_slots + 1))
                    clean_size=$(echo "$val" | tr -d ' ')
                    active_modules+=("$clean_size")
                fi
            done <<< "$slots_raw"
            
            # Format list modul aktif
            if [ ${#active_modules[@]} -gt 0 ]; then
                IFS=','
                active_str="${active_modules[*]}"
                unset IFS
            else
                active_str="None"
            fi
            
            slot_output="Used Slots: ${used_slots}/${total_slots} (${empty_slots} Empty) ❘ Active Modules: [${active_str}]"
        else
            slot_output="Used Slots: N/A ❘ Active Modules: N/A"
        fi
    else
        slot_output="Used Slots: N/A (dmidecode not installed) ❘ Active Modules: N/A"
    fi

    # --- 2. PEMBACAAN LOG MEMTESTER ---
    LOG_FILE="/var/log/checkmk_custom/memtester_health.log"
    
    if [ ! -f "$LOG_FILE" ]; then
        # Jika file log tidak ada, anggap status OK karena memtester belum berjalan/baru diinstall
        echo "0 \"Health_RAM\" - Status : OK ❘ Result: Passed ❘ Tested Size: N/A ❘ Last Test: No test run yet ❘ ${slot_output} ❘ Log: Waiting for first scheduled memtester run on Saturday 11:00 AM." >> "$CACHE_FILE"
    else
        # Baca status keberhasilan
        status_line=$(grep "STATUS:" "$LOG_FILE" | tail -n 1)
        sample_line=$(grep "SAMPLE_SIZE:" "$LOG_FILE" | tail -n 1)
        start_line=$(grep "=== MEMTESTER START:" "$LOG_FILE" | tail -n 1)
        
        sample_size=$(echo "$sample_size_raw" | cut -d':' -f2 | xargs) # Note: sample_line parsing
        sample_size=$(echo "$sample_line" | cut -d':' -f2 | xargs)
        [ -z "$sample_size" ] && sample_size="Unknown"
        
        test_time=$(echo "$start_line" | sed 's/=== MEMTESTER START: \(.*\) ===/\1/' | xargs)
        if [ -n "$test_time" ]; then
            # Konversi tanggal ke format YYYY-MM-DD HH:MM jika menggunakan GNU date
            formatted_time=$(date -d "$test_time" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$test_time")
        else
            # Fallback menggunakan waktu perubahan log file
            formatted_time=$(date -r "$LOG_FILE" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown Date")
        fi
        
        status_code=0
        status_txt="OK"
        result_txt="Passed"
        log_summary="memtester passed successfully."
        
        if echo "$status_line" | grep -q "FAILED"; then
            status_code=2
            status_txt="Critical"
            result_txt="Failed"
            # Ambil kegagalan spesifik dari log (3 baris terakhir sebelum status)
            log_summary=$(grep -v "=== " "$LOG_FILE" | grep -v "STATUS:" | grep -v "SAMPLE_SIZE:" | tail -n 3 | tr '\n' ' ' | xargs)
            [ -z "$log_summary" ] && log_summary="Memory test failed during allocation or testing."
        fi
        
        echo "$status_code \"Health_RAM\" - Status : $status_txt ❘ Result: $result_txt ❘ Tested Size: $sample_size ❘ Last Test: $formatted_time ❘ ${slot_output} ❘ Log: $log_summary" >> "$CACHE_FILE"
    fi
fi

cat "$CACHE_FILE" 2>/dev/null
