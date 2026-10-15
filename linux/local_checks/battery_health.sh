#!/usr/bin/env bash
# =====================================================================
# Local Check Checkmk: Daily Battery Health Monitor
# Scheduled to run once a day at 16:00
# =====================================================================
CACHE_DIR="/var/lib/check_mk_agent/cache"
mkdir -p "$CACHE_DIR" 2>/dev/null
CACHE_FILE="$CACHE_DIR/cache_battery_health.txt"

# Get current hour and today's 16:00 epoch
CURRENT_HOUR=$(date +%H)
TODAY_16=$(date -d "16:00:00" +%s 2>/dev/null)

if [ -z "$TODAY_16" ]; then
    TODAY_16=$(date +%s -d "16:00:00" 2>/dev/null)
fi

if [ "$CURRENT_HOUR" -lt 16 ]; then
    LAST_16=$(date -d "yesterday 16:00:00" +%s 2>/dev/null)
else
    LAST_16=$TODAY_16
fi

if [ -z "$LAST_16" ]; then
    LAST_16=$(( TODAY_16 - 86400 ))
fi

need_update() {
    local file=$1
    local threshold=$2
    if [ ! -f "$file" ]; then
        return 0
    fi
    local file_ts
    file_ts=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    if [ "$file_ts" -lt "$threshold" ]; then
        return 0
    fi
    return 1
}

if need_update "$CACHE_FILE" "$LAST_16"; then
    > "$CACHE_FILE"
    
    # Deteksi Baterai menggunakan UPower terlebih dahulu
    has_battery=false
    bat_path=""
    
    if command -v upower >/dev/null 2>&1; then
        bat_path=$(upower -e 2>/dev/null | grep -i "battery" | head -n 1)
        if [ -n "$bat_path" ]; then
            has_battery=true
        fi
    fi
    
    # Inisialisasi variabel default
    state="Unknown"
    bat_level="N/A"
    health="100"
    design_cap="N/A"
    current_cap="N/A"
    
    # Jika ada baterai via UPower
    if [ "$has_battery" = true ]; then
        bat_info=$(upower -i "$bat_path" 2>/dev/null)
        
        # Ambil State
        raw_state=$(echo "$bat_info" | grep -i "state" | head -n 1 | cut -d':' -f2 | xargs)
        case "${raw_state,,}" in
            fully-charged) state="Fully Charged" ;;
            discharging) state="Discharging" ;;
            charging) state="Charging" ;;
            pending-charge) state="Pending Charge" ;;
            not-charging) state="Not Charging" ;;
            empty) state="Empty" ;;
            *)
                if [ -n "$raw_state" ]; then
                    state=$(echo "$raw_state" | sed 's/[-_]/ /g' | awk '{for(i=1;i<=NF;i++)sub(/./,toupper(substr($i,1,1)),$i)}1')
                else
                    state="Unknown"
                fi
                ;;
        esac
        
        # Ambil Battery Level (percentage)
        bat_level=$(echo "$bat_info" | grep -i "percentage" | head -n 1 | cut -d':' -f2 | xargs | tr -d '%')
        [ -z "$bat_level" ] && bat_level="N/A"
        
        # Ambil Health (capacity)
        health_str=$(echo "$bat_info" | grep -i "capacity" | head -n 1 | cut -d':' -f2 | xargs | tr -d '%')
        if [[ "$health_str" =~ ^[0-9.]+$ ]]; then
            health=$(awk "BEGIN {print int($health_str + 0.5)}")
        else
            health=100
        fi
        
        # Ambil Design & Current Capacity (dalam Wh)
        design_str=$(echo "$bat_info" | grep -i "energy-full-design" | cut -d':' -f2 | xargs | awk '{print $1}')
        current_str=$(echo "$bat_info" | grep -i "energy-full" | grep -v "design" | cut -d':' -f2 | xargs | awk '{print $1}')
        
        if [[ "$design_str" =~ ^[0-9.]+$ ]]; then
            design_cap=$(awk "BEGIN {print int($design_str + 0.5)}")
        fi
        if [[ "$current_str" =~ ^[0-9.]+$ ]]; then
            current_cap=$(awk "BEGIN {print int($current_str + 0.5)}")
        fi
        
    else
        # Fallback ke Sysfs jika UPower tidak mendeteksi baterai
        sys_bat_dir=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n 1)
        if [ -n "$sys_bat_dir" ]; then
            has_battery=true
            
            raw_state=$(cat "$sys_bat_dir/status" 2>/dev/null | tr 'A-Z' 'a-z')
            case "${raw_state,,}" in
                fully-charged|full) state="Fully Charged" ;;
                discharging) state="Discharging" ;;
                charging) state="Charging" ;;
                "not charging"|pending-charge) state="Pending Charge" ;;
                empty) state="Empty" ;;
                *) state="Unknown" ;;
            esac
            
            bat_level=$(cat "$sys_bat_dir/capacity" 2>/dev/null || echo "N/A")
            
            # Hitung kapasitas Wh dari energy atau charge
            raw_design=$(cat "$sys_bat_dir/energy_full_design" 2>/dev/null || cat "$sys_bat_dir/charge_full_design" 2>/dev/null)
            raw_current=$(cat "$sys_bat_dir/energy_full" 2>/dev/null || cat "$sys_bat_dir/charge_full" 2>/dev/null)
            raw_voltage=$(cat "$sys_bat_dir/voltage_min_design" 2>/dev/null || cat "$sys_bat_dir/voltage_now" 2>/dev/null || echo "11100000")
            
            if [ -n "$raw_design" ] && [ -n "$raw_current" ]; then
                if [ -f "$sys_bat_dir/energy_full_design" ]; then
                    design_cap=$(awk "BEGIN {print int(($raw_design / 1000000) + 0.5)}")
                    current_cap=$(awk "BEGIN {print int(($raw_current / 1000000) + 0.5)}")
                else
                    design_cap=$(awk "BEGIN {print int((($raw_design * $raw_voltage) / 1000000000000) + 0.5)}")
                    current_cap=$(awk "BEGIN {print int((($raw_current * $raw_voltage) / 1000000000000) + 0.5)}")
                fi
                
                if [ -n "$design_cap" ] && [ "$design_cap" -gt 0 ] 2>/dev/null; then
                    health=$(awk "BEGIN {print int((($current_cap / $design_cap) * 100) + 0.5)}")
                else
                    health=100
                fi
            else
                design_cap="N/A"
                current_cap="N/A"
                health=100
            fi
        fi
    fi
    
    # Output hasil sesuai tipe perangkat
    if [ "$has_battery" = true ]; then
        remark=""

        # Deteksi Anomali Baterai Drop / Mati (hanya bisa nyala saat charger menancap)
        # Kondisi: Battery Level 0% (atau <= 5% dengan status tidak mengisi / tertahan di Pending Charge)
        if [[ "$bat_level" =~ ^[0-9]+$ ]]; then
            if [ "$bat_level" -eq 0 ] || { [ "$bat_level" -le 5 ] && [[ "${state,,}" =~ ^(pending charge|not charging|empty|unknown)$ ]]; }; then
                health=0
                current_cap=0
                remark=" ❘ Remark : Battery Drop/Dead (AC Power Only)"
            fi
        fi

        # Evaluasi Threshold:
        # >= 60%   : OK (0)
        # 40% - 59%: WARNING (1)
        # <= 39%   : CRITICAL (2)
        if [ "$health" -le 39 ]; then
            status=2
        elif [ "$health" -le 59 ]; then
            status=1
        else
            status=0
        fi
        
        echo "$status \"Health_Battery\" -  Status Battery : $state ❘ Design Capacity : ${design_cap}w/h ❘ Current Capacity : ${current_cap}w/h ❘ Health : ${health}% ❘ Battery Level : ${bat_level}%${remark}" >> "$CACHE_FILE"
    else
        # Jika PC Desktop / Tidak ada baterai
        echo "0 \"Health_Battery\" -  Status Battery : N/A ❘ Device is PC/Desktop, there is no battery." >> "$CACHE_FILE"
    fi
fi

cat "$CACHE_FILE" 2>/dev/null
