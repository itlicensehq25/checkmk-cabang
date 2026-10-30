#!/usr/bin/env bash
# ==============================================================================
# Local Check Checkmk: Multi-Layer FAN & Thermal Cooling Health (Linux)
# Perbaikan Utama:
#   1. Auto-load modul kernel sensor kipas sesuai vendor motherboard/laptop
#      (Dell SMM, ThinkPad ACPI, ASUS WMI, HP WMI, Nuvoton/ITE Super I/O)
#   2. Multi-source fan reader: lm-sensors, /sys/class/hwmon, /proc/acpi/ibm/fan
#   3. Smart EC/BIOS Thermal Correlation untuk PC/Laptop keluaran terbaru
#   4. Standardisasi nama service "FAN_Health" & perfdata grafik
# ==============================================================================

export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"

# ------------------------------------------------------------------------------
# 1. AUTO-PROBE MODUL KERNEL SENSOR FAN VENDOR (Non-Destructive)
# ------------------------------------------------------------------------------
ensure_vendor_fan_modules() {
    [ "$(id -u)" -ne 0 ] && return 0
    command -v modprobe >/dev/null 2>&1 || return 0

    # Jika sudah ada fan*_input yang aktif di sysfs, tidak perlu modprobe ulang
    if compgen -G "/sys/class/hwmon/hwmon*/fan*_input" >/dev/null 2>&1; then
        return 0
    fi

    local vendor=""
    [ -f /sys/class/dmi/id/sys_vendor ] && vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
    local product=""
    [ -f /sys/class/dmi/id/product_name ] && product=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    local combined="${vendor} ${product}"

    case "${combined^^}" in
        *DELL*)
            modprobe dell_smm_hwmon ignore_dmi=1 restricted=0 2>/dev/null || modprobe dell_smm_hwmon 2>/dev/null || true
            ;;
        *MICRO-STAR*|*MSI*)
            modprobe nct6683 force=1 2>/dev/null || modprobe nct6683 2>/dev/null || true
            if [ -w /etc/modules ] && ! grep -q "^nct6683" /etc/modules 2>/dev/null; then
                echo "nct6683" >> /etc/modules 2>/dev/null || true
                echo "options nct6683 force=1" > /etc/modprobe.d/nct6683.conf 2>/dev/null || true
            fi
            modprobe nct6687 2>/dev/null || true
            modprobe nct6775 2>/dev/null || true
            ;;
        *GIGABYTE*|*AORUS*)
            # Motherboard Desktop Gigabyte (B760, B660, B550, dll.) menggunakan chip ITE (IT8689E/IT87xx) & gigabyte_wmi
            modprobe gigabyte_wmi 2>/dev/null || true
            modprobe it87 ignore_resource_conflict=1 force_id=0x8689 2>/dev/null || modprobe it87 ignore_resource_conflict=1 2>/dev/null || true
            if [ -w /etc/modules ] && lsmod | grep -q "it87" && ! grep -q "^it87" /etc/modules 2>/dev/null; then
                echo "it87" >> /etc/modules 2>/dev/null || true
                echo "options it87 ignore_resource_conflict=1 force_id=0x8689" > /etc/modprobe.d/it87.conf 2>/dev/null || true
            fi
            ;;
        *ASUS*|*ASUSTEK*)
            # Motherboard Desktop ASUS (PRIME, TUF, ROG, ProArt) -> asus_ec_sensors & nct6775
            modprobe asus_ec_sensors 2>/dev/null || true
            modprobe asus_nb_wmi 2>/dev/null || true
            modprobe asus_wmi 2>/dev/null || true
            modprobe nct6775 2>/dev/null || true
            ;;
        *ASROCK*)
            # Motherboard Desktop ASRock -> nct6775 & w83627ehf
            modprobe nct6775 2>/dev/null || true
            modprobe w83627ehf 2>/dev/null || true
            ;;
        *LENOVO*|*THINKPAD*|*THINKCENTRE*)
            modprobe thinkpad_acpi 2>/dev/null || true
            modprobe ideapad_laptop 2>/dev/null || true
            ;;
        *HP*|*HEWLETT*)
            modprobe hp_wmi 2>/dev/null || true
            ;;
        *ACER*)
            modprobe acer_wmi 2>/dev/null || true
            ;;
        *APPLE*)
            modprobe applesmc 2>/dev/null || true
            ;;
    esac

    # Modul Super I/O populer pada motherboard PC Desktop modern (MSI/ASUS/Gigabyte/ASRock)
    modprobe asus_ec_sensors 2>/dev/null || true
    modprobe nct6683 force=1 2>/dev/null || modprobe nct6683 2>/dev/null || true
    modprobe nct6687 2>/dev/null || true
    modprobe nct6775 2>/dev/null || true
    modprobe it87 ignore_resource_conflict=1 2>/dev/null || modprobe it87 2>/dev/null || true
    modprobe gigabyte_wmi 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 2. DAPATKAN SUHU CPU SECARA AKURAT (Multi-Sensor Fallback)
# ------------------------------------------------------------------------------
get_cpu_temp() {
    local temp=""

    if command -v sensors >/dev/null 2>&1; then
        local sensors_out
        sensors_out=$(sensors 2>/dev/null)

        # A. Cari label sensor spesifik CPU: Package id 0, CPUTIN, Tdie, Tctl, Core 0
        local spec_line
        spec_line=$(echo "$sensors_out" | grep -i -E "Package id 0|CPUTIN|Tdie|Tctl|Core 0" | head -n1)
        if [ -n "$spec_line" ]; then
            temp=$(echo "$spec_line" | cut -d':' -f2- | cut -d'(' -f1 | grep -o -E '[0-9]+(\.[0-9]+)?' | head -n1)
            if [ -n "$temp" ] && awk "BEGIN {exit !($temp > 10 && $temp < 115)}"; then
                echo "$temp"
                return
            fi
        fi

        # B. Cari k10temp / zenpower (CPU AMD)
        local k10_line
        k10_line=$(echo "$sensors_out" | grep -A 5 -i -E "k10temp|zenpower" | grep -i "temp1" | head -n1)
        if [ -n "$k10_line" ]; then
            temp=$(echo "$k10_line" | cut -d':' -f2- | cut -d'(' -f1 | grep -o -E '[0-9]+(\.[0-9]+)?' | head -n1)
            if [ -n "$temp" ] && awk "BEGIN {exit !($temp > 10 && $temp < 115)}"; then
                echo "$temp"
                return
            fi
        fi

        # C. Cari coretemp (CPU Intel)
        local core_line
        core_line=$(echo "$sensors_out" | grep -A 5 -i "coretemp" | grep -i -E "Package|temp[0-9]+|Core [0-9]+" | head -n1)
        if [ -n "$core_line" ]; then
            temp=$(echo "$core_line" | cut -d':' -f2- | cut -d'(' -f1 | grep -o -E '[0-9]+(\.[0-9]+)?' | head -n1)
            if [ -n "$temp" ] && awk "BEGIN {exit !($temp > 10 && $temp < 115)}"; then
                echo "$temp"
                return
            fi
        fi
    fi

    # D. Fallback ke /sys/class/hwmon/hwmon*/temp*_input (prioritaskan coretemp/k10temp/cpu)
    for hw in /sys/class/hwmon/hwmon*; do
        [ ! -d "$hw" ] && continue
        local hname=""
        [ -f "$hw/name" ] && hname=$(cat "$hw/name" 2>/dev/null)
        if [[ "$hname" =~ (coretemp|k10temp|zenpower|cpu|acpitz|dell_smm|thinkpad) ]]; then
            for tf in "$hw"/temp*_input; do
                [ ! -f "$tf" ] && continue
                local traw
                traw=$(cat "$tf" 2>/dev/null || echo 0)
                local t=$((traw / 1000))
                if [ "$t" -gt 15 ] && [ "$t" -lt 115 ]; then
                    echo "$t"
                    return
                fi
            done
        fi
    done

    # E. Fallback terakhir ke /sys/class/thermal/thermal_zone*/temp
    for tz in /sys/class/thermal/thermal_zone*/temp; do
        [ ! -f "$tz" ] && continue
        local t_raw
        t_raw=$(cat "$tz" 2>/dev/null || echo 0)
        local t=$((t_raw / 1000))
        if [ "$t" -gt 15 ] && [ "$t" -lt 115 ]; then
            echo "$t"
            return
        fi
    done

    echo "0"
}

# ------------------------------------------------------------------------------
# 3. DAPATKAN KECEPATAN KIPAS (Multi-Layer Fan RPM Reader)
# ------------------------------------------------------------------------------
ensure_vendor_fan_modules

temp_val=$(get_cpu_temp)
temp_int=$(printf "%.0f" "$temp_val" 2>/dev/null || echo "0")

fan_speed=0

# Lapis 1: Baca dari /sys/class/hwmon/hwmon*/fan*_input
for f_in in /sys/class/hwmon/hwmon*/fan*_input /sys/devices/platform/*/hwmon/hwmon*/fan*_input; do
    [ ! -f "$f_in" ] && continue
    val=$(cat "$f_in" 2>/dev/null | tr -dc '0-9')
    if [ -n "$val" ] && [ "$val" -gt "$fan_speed" ] && [ "$val" -lt 15000 ]; then
        fan_speed="$val"
    fi
done

# Lapis 2: Baca dari output lm-sensors (jika ada format khusus)
if [ "$fan_speed" -eq 0 ] && command -v sensors >/dev/null 2>&1; then
    fan_lines=$(sensors 2>/dev/null | grep -i -E "fan|cooling|rpm" | cut -d':' -f2-)
    if [ -n "$fan_lines" ]; then
        while read -r line; do
            line_clean=$(echo "$line" | cut -d'(' -f1)
            speed_raw=$(echo "$line_clean" | grep -o -E '[0-9]+\s*[rR][pP][mM]' | grep -o -E '[0-9]+' | head -n1)
            if [ -n "$speed_raw" ] && [ "$speed_raw" -gt "$fan_speed" ] && [ "$speed_raw" -lt 15000 ]; then
                fan_speed="$speed_raw"
            fi
        done <<< "$fan_lines"
    fi
fi

# Lapis 3: Baca dari /proc/acpi/ibm/fan (Khusus Lenovo ThinkPad)
if [ "$fan_speed" -eq 0 ] && [ -f /proc/acpi/ibm/fan ]; then
    tp_speed=$(awk '/^speed:/ {print $2}' /proc/acpi/ibm/fan 2>/dev/null | tr -dc '0-9')
    if [ -n "$tp_speed" ] && [ "$tp_speed" -gt 0 ] && [ "$tp_speed" -lt 15000 ]; then
        fan_speed="$tp_speed"
    fi
fi

# ------------------------------------------------------------------------------
# 4. EVALUASI STATUS BERDASARKAN KORELASI RPM & SUHU CPU (EC/BIOS Aware)
# ------------------------------------------------------------------------------
status=0
status_txt="OK"
perf_temp=""
temp_info=""

if [ "$temp_int" -gt 0 ]; then
    perf_temp="|cpu_temp=${temp_int};75;85;0;110"
    temp_info=" | CPU Temp: ${temp_int}C"
fi

if [ "$fan_speed" -gt 0 ]; then
    if [ "$temp_int" -gt 85 ] && [ "$fan_speed" -lt 1600 ]; then
        status=2
        status_txt="CRITICAL"
        kondisi="Suhu CPU Tinggi (${temp_int}C) namun putaran Fan lemah (<1600 RPM) - Cek Kipas/Thermal Paste!"
    elif [ "$temp_int" -gt 75 ] && [ "$fan_speed" -lt 1000 ]; then
        status=1
        status_txt="WARNING"
        kondisi="Suhu CPU Panas (${temp_int}C) dengan RPM rendah - Pantau Pendinginan"
    elif [ "$fan_speed" -ge 5500 ]; then
        kondisi="Maximum / Turbo Cooling"
    elif [ "$fan_speed" -ge 4500 ]; then
        kondisi="High Speed (Heavy Load)"
    elif [ "$fan_speed" -ge 2500 ]; then
        kondisi="Medium (Active Cooling)"
    else
        kondisi="Low / Silent (Normal)"
    fi
    echo "$status \"FAN_Health\" fan_speed=${fan_speed};5500;6000;0;6500${perf_temp} Status: $status_txt - FAN Speed: ${fan_speed} rpm${temp_info} - Kondisi: $kondisi"
else
    # Jika sensor RPM dikunci oleh EC/BIOS Laptop atau mode 0dB Passive Cooling aktif
    if [ "$temp_int" -gt 85 ]; then
        status=2
        status_txt="CRITICAL"
        kondisi="CPU Overheat (${temp_int}C) - Periksa Kipas Pendingin / Thermal Paste!"
    elif [ "$temp_int" -gt 75 ]; then
        status=1
        status_txt="WARNING"
        kondisi="CPU Cukup Panas (${temp_int}C) - EC/BIOS Auto Cooling Aktif"
    else
        status=0
        status_txt="OK"
        kondisi="EC/BIOS Auto Managed (Zero-RPM Idle / Sensor Dikunci Firmware, Suhu Aman)"
    fi
    echo "$status \"FAN_Health\" fan_speed=0;5500;6000;0;6500${perf_temp} Status: $status_txt - FAN Speed: EC/Auto${temp_info} - Kondisi: $kondisi"
fi
