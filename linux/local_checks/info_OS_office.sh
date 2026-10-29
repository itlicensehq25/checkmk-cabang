#!/usr/bin/env bash
# =====================================================================
# Local Check Checkmk: Daily OS & Office (LibreOffice + WPS + Onlyoffice) Check (16:00)
# =====================================================================
CACHE_DIR="/var/lib/check_mk_agent/cache"
mkdir -p "$CACHE_DIR" 2>/dev/null

# --- LOGIKA PENJADWALAN UPDATE 16:00 ---
CURRENT_HOUR=$(date +%H)

if [ "$CURRENT_HOUR" -ge 16 ]; then
    # Jika sekarang pukul 16:00 atau lebih, batas waktu adalah hari ini pukul 16:00
    LAST_SCHEDULE=$(date -d "today 16:00:00" +%s 2>/dev/null)
else
    # Jika sekarang sebelum pukul 16:00, batas waktu adalah kemarin pukul 16:00
    LAST_SCHEDULE=$(date -d "yesterday 16:00:00" +%s 2>/dev/null)
fi

OS_OFFICE_CACHE="$CACHE_DIR/cache_os_office_info.txt"

need_update() {
    local file=$1; local schedule_ts=$2; local file_ts=0
    if [ ! -f "$file" ]; then return 0; fi
    file_ts=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    if [ "$file_ts" -lt "$schedule_ts" ]; then return 0; else return 1; fi
}

# --- PROSES CEK DAN UPDATE CACHE ---
if need_update "$OS_OFFICE_CACHE" "$LAST_SCHEDULE"; then
    > "$OS_OFFICE_CACHE"
    
    # Generate timestamp
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    
    # --- 1. PENGECEKAN OS LINUX ---
    OS_NAME=$(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || echo "Unknown Linux")
    OS_KERNEL=$(uname -r); OS_ARCH=$(uname -m)
    echo "0 \"Info_OS\" - OK - OS: $OS_NAME | Kernel: $OS_KERNEL | Arch: $OS_ARCH ❘ Checked At: $TIMESTAMP" >> "$OS_OFFICE_CACHE"

    # --- 2. PENGECEKAN OFFICE ---
    OFFICE_LIST=()

    # A. Cek LibreOffice
    if command -v libreoffice >/dev/null 2>&1; then
        LO_VER=$(libreoffice --version 2>/dev/null | head -n 1)
        [ -n "$LO_VER" ] && OFFICE_LIST+=("$LO_VER")
    fi

    # B. Cek WPS Office (dpkg, rpm, flatpak, snap)
    WPS_VER=""
    # 1. Check if command or package exists
    if command -v wps >/dev/null 2>&1 || command -v wps-office >/dev/null 2>&1 || { command -v dpkg >/dev/null 2>&1 && dpkg -s wps-office >/dev/null 2>&1; } || { command -v rpm >/dev/null 2>&1 && rpm -q wps-office >/dev/null 2>&1; }; then
        if command -v dpkg-query >/dev/null 2>&1 && dpkg -s wps-office >/dev/null 2>&1; then
            WPS_VER=$(dpkg-query -W -f='${Version}' wps-office 2>/dev/null)
        elif command -v rpm >/dev/null 2>&1 && rpm -q wps-office >/dev/null 2>&1; then
            WPS_VER=$(rpm -q --queryformat '%{VERSION}' wps-office 2>/dev/null)
        fi
    fi
    
    # 2. Check flatpak (system and user level)
    if [ -z "$WPS_VER" ] && command -v flatpak >/dev/null 2>&1; then
        flatpak_out=$(flatpak list --columns=application,version 2>/dev/null)
        if [ -n "$SUDO_USER" ]; then
            flatpak_out_user=$(sudo -u "$SUDO_USER" flatpak list --columns=application,version 2>/dev/null)
            flatpak_out="$flatpak_out"$'\n'"$flatpak_out_user"
        fi
        WPS_VER=$(echo "$flatpak_out" | grep -i "com.wps.Office" | awk -F'\t' '{print $2}' | head -n 1 | xargs)
    fi
    
    # 3. Check snap
    if [ -z "$WPS_VER" ] && command -v snap >/dev/null 2>&1; then
        WPS_VER=$(snap list 2>/dev/null | grep -i "wps-office" | awk '{print $2}' | head -n 1 | xargs)
    fi

    if [ -n "$WPS_VER" ] && [[ ! "$WPS_VER" =~ "not installed" ]] && [[ ! "$WPS_VER" =~ "is not" ]]; then
        OFFICE_LIST+=("WPS Office v$WPS_VER")
    elif command -v wps >/dev/null 2>&1 || command -v wps-office >/dev/null 2>&1; then
        OFFICE_LIST+=("WPS Office Terinstal")
    fi

    # C. Cek Onlyoffice (dpkg, rpm, flatpak, snap)
    ONLYOFFICE_VER=""
    # 1. Check if command or package exists
    if command -v onlyoffice >/dev/null 2>&1 || command -v onlyoffice-desktopeditors >/dev/null 2>&1 || { command -v dpkg >/dev/null 2>&1 && dpkg -s onlyoffice >/dev/null 2>&1; } || { command -v dpkg >/dev/null 2>&1 && dpkg -s onlyoffice-desktopeditors >/dev/null 2>&1; } || { command -v rpm >/dev/null 2>&1 && rpm -q onlyoffice >/dev/null 2>&1; } || { command -v rpm >/dev/null 2>&1 && rpm -q onlyoffice-desktopeditors >/dev/null 2>&1; }; then
        if command -v dpkg-query >/dev/null 2>&1; then
            if dpkg -s onlyoffice >/dev/null 2>&1; then
                ONLYOFFICE_VER=$(dpkg-query -W -f='${Version}' onlyoffice 2>/dev/null)
            elif dpkg -s onlyoffice-desktopeditors >/dev/null 2>&1; then
                ONLYOFFICE_VER=$(dpkg-query -W -f='${Version}' onlyoffice-desktopeditors 2>/dev/null)
            fi
        elif command -v rpm >/dev/null 2>&1; then
            if rpm -q onlyoffice >/dev/null 2>&1; then
                ONLYOFFICE_VER=$(rpm -q --queryformat '%{VERSION}' onlyoffice 2>/dev/null)
            elif rpm -q onlyoffice-desktopeditors >/dev/null 2>&1; then
                ONLYOFFICE_VER=$(rpm -q --queryformat '%{VERSION}' onlyoffice-desktopeditors 2>/dev/null)
            fi
        fi
    fi
    
    # 2. Check flatpak (system and user level)
    if [ -z "$ONLYOFFICE_VER" ] && command -v flatpak >/dev/null 2>&1; then
        flatpak_out=$(flatpak list --columns=application,version 2>/dev/null)
        if [ -n "$SUDO_USER" ]; then
            flatpak_out_user=$(sudo -u "$SUDO_USER" flatpak list --columns=application,version 2>/dev/null)
            flatpak_out="$flatpak_out"$'\n'"$flatpak_out_user"
        fi
        ONLYOFFICE_VER=$(echo "$flatpak_out" | grep -i "onlyoffice" | awk -F'\t' '{print $2}' | head -n 1 | xargs)
    fi
    
    # 3. Check snap
    if [ -z "$ONLYOFFICE_VER" ] && command -v snap >/dev/null 2>&1; then
        ONLYOFFICE_VER=$(snap list 2>/dev/null | grep -i "onlyoffice" | awk '{print $2}' | head -n 1 | xargs)
    fi

    if [ -n "$ONLYOFFICE_VER" ] && [[ ! "$ONLYOFFICE_VER" =~ "not installed" ]] && [[ ! "$ONLYOFFICE_VER" =~ "is not" ]]; then
        OFFICE_LIST+=("Onlyoffice v$ONLYOFFICE_VER")
    elif command -v onlyoffice >/dev/null 2>&1 || command -v onlyoffice-desktopeditors >/dev/null 2>&1; then
        OFFICE_LIST+=("Onlyoffice Terinstal")
    fi

    # D. Format Output Office
    if [ ${#OFFICE_LIST[@]} -gt 0 ]; then
        # Join elements with " + "
        FINAL_OFFICE=""
        for item in "${OFFICE_LIST[@]}"; do
            if [ -z "$FINAL_OFFICE" ]; then
                FINAL_OFFICE="$item"
            else
                FINAL_OFFICE="$FINAL_OFFICE + $item"
            fi
        done
        echo "0 \"Info_Office\" - OK - Product: $FINAL_OFFICE | Status: Native Linux Application ❘ Checked At: $TIMESTAMP" >> "$OS_OFFICE_CACHE"
    else
        echo "0 \"Info_Office\" - OK - Product: Tidak ada aplikasi Office (Native Linux) ❘ Checked At: $TIMESTAMP" >> "$OS_OFFICE_CACHE"
    fi
fi

# Cetak hasil dari cache
cat "$OS_OFFICE_CACHE" 2>/dev/null
