#!/usr/bin/env bash
# ==============================================================================
# Local Check Checkmk: CPU Info & Metrics (Graph & Realtime Enabled)
# ==============================================================================

# 1. Dapatkan Spesifikasi CPU
cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | sed -e 's/^[ \t]*//' -e 's/(R)//g' -e 's/(TM)//g' -e 's/  */ /g' -e 's/ CPU//g' -e 's/ @.*//g')
[ -z "$cpu_model" ] && cpu_model=$(uname -p)

# 2. Dapatkan Clock Speed (GHz)
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq ]; then
    max_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)
    clock_speed=$(awk "BEGIN {printf \"%.1f\", $max_khz/1000000}")Ghz
elif [ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]; then
    max_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
    clock_speed=$(awk "BEGIN {printf \"%.1f\", $max_khz/1000000}")Ghz
else
    mhz=$(grep -m1 -i "cpu MHz" /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | sed 's/^[ \t]*//')
    if [ -n "$mhz" ]; then
        clock_speed=$(awk "BEGIN {printf \"%.1f\", $mhz/1000}")Ghz
    else
        clock_speed="N/A"
    fi
fi

# 3. Dapatkan Core / Thread
threads=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
phys_cores=$(grep -m1 "cpu cores" /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | xargs 2>/dev/null)
[ -z "$phys_cores" ] && phys_cores=$((threads / 2))
[ "$phys_cores" -eq 0 ] && phys_cores=1
cores_threads="${phys_cores}/${threads}"

# 4. Hitung Real-time CPU Load (Sampling 0.5 detik dari /proc/stat)
read -r _ a b c id e f g h i j < /proc/stat
prev_active=$((a + b + c + e + f + g + h + i + j))
prev_total=$((prev_active + id))

sleep 0.5

read -r _ a b c id e f g h i j < /proc/stat
active=$((a + b + c + e + f + g + h + i + j))
total=$((active + id))

diff_active=$((active - prev_active))
diff_total=$((total - prev_total))

if [ "$diff_total" -eq 0 ]; then
    cpu_load=0
else
    cpu_load=$(( 100 * diff_active / diff_total ))
fi

# 5. Dapatkan Suhu CPU secara akurat
get_cpu_temp() {
    local temp=""
    
    if command -v sensors >/dev/null 2>&1; then
        local sensors_out
        sensors_out=$(sensors 2>/dev/null)
        
        # A. Coba cari label sensor spesifik CPU: CPUTIN, Tdie, Tctl, Core 0
        local spec_line
        spec_line=$(echo "$sensors_out" | grep -i -E "CPUTIN|Tdie|Tctl|Core 0" | head -n1)
        if [ -n "$spec_line" ]; then
            local clean_line
            clean_line=$(echo "$spec_line" | cut -d':' -f2- | cut -d'(' -f1)
            temp=$(echo "$clean_line" | grep -o -E '[0-9.]+' | head -n1)
            if [ -n "$temp" ] && (( $(echo "$temp > 0" | bc -l 2>/dev/null || echo 0) )); then
                echo "$temp"
                return
            fi
        fi
        
        # B. Cari k10temp (CPU AMD) secara spesifik
        local k10_line
        k10_line=$(echo "$sensors_out" | grep -A 5 -i "k10temp" | grep -i "temp1" | head -n1)
        if [ -n "$k10_line" ]; then
            local clean_line
            clean_line=$(echo "$k10_line" | cut -d':' -f2- | cut -d'(' -f1)
            temp=$(echo "$clean_line" | grep -o -E '[0-9.]+' | head -n1)
            if [ -n "$temp" ] && (( $(echo "$temp > 0" | bc -l 2>/dev/null || echo 0) )); then
                echo "$temp"
                return
            fi
        fi

        # C. Cari coretemp (CPU Intel) secara spesifik
        local core_line
        core_line=$(echo "$sensors_out" | grep -A 5 -i "coretemp" | grep -i -E "temp[0-9]+|Core [0-9]+" | head -n1)
        if [ -n "$core_line" ]; then
            local clean_line
            clean_line=$(echo "$core_line" | cut -d':' -f2- | cut -d'(' -f1)
            temp=$(echo "$clean_line" | grep -o -E '[0-9.]+' | head -n1)
            if [ -n "$temp" ] && (( $(echo "$temp > 0" | bc -l 2>/dev/null || echo 0) )); then
                echo "$temp"
                return
            fi
        fi
        
        # D. Fallback umum: Cari "temp1" yang tidak di bawah blok GPU
        local in_gpu_block=0
        while read -r line; do
            if echo "$line" | grep -q -i -E "radeon|nvidia|amdgpu|nouveau"; then
                in_gpu_block=1
            elif [ "$in_gpu_block" -eq 1 ] && [ -z "$line" ]; then
                in_gpu_block=0
            elif [ "$in_gpu_block" -eq 0 ] && echo "$line" | grep -q -i -E "temp[0-9]+:|Core [0-9]+:"; then
                local clean_line
                clean_line=$(echo "$line" | cut -d':' -f2- | cut -d'(' -f1)
                temp=$(echo "$clean_line" | grep -o -E '[0-9.]+' | head -n1)
                if [ -n "$temp" ] && (( $(echo "$temp > 0" | bc -l 2>/dev/null || echo 0) )); then
                    echo "$temp"
                    return
                fi
            fi
        done <<EOF
$sensors_out
EOF
    fi
    
    # E. Fallback ke sysfs
    if [ -d /sys/class/thermal ]; then
        for tz in /sys/class/thermal/thermal_zone*/temp; do
            if [ -f "$tz" ]; then
                local t_raw
                t_raw=$(cat "$tz" 2>/dev/null || echo 0)
                local t=$((t_raw / 1000))
                if [ "$t" -gt 25 ] && [ "$t" -lt 105 ]; then
                    echo "$t"
                    return
                fi
            fi
        done
    fi
    
    echo "0"
}

temp_val=$(get_cpu_temp)
temp_int=$(printf "%.0f" "$temp_val" 2>/dev/null || echo "0")

# 6. Tentukan status Checkmk
# Status: 0=OK, 1=WARN, 2=CRIT
status=0
if [ "$temp_int" -gt 85 ] || [ "$cpu_load" -ge 95 ]; then
    status=2
elif [ "$temp_int" -gt 75 ] || [ "$cpu_load" -ge 85 ]; then
    status=1
fi

# 7. Format Performance Data (Metrik Grafik untuk Checkmk)
# Format: metricname=value;warn;crit;min;max
perf_metrics="load=${cpu_load}%;85;95;0;100|temp=${temp_int};75;85;0;110"

# Output Standar Checkmk Local Check dengan Performance Data
echo "$status \"Info_CPU\" $perf_metrics Spesifikasi : $cpu_model | Clock Speed : $clock_speed | Core/Thread : $cores_threads | CPU Load : ${cpu_load}% | CPU Temperature: ${temp_int} C"
