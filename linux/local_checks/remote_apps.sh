#!/usr/bin/env bash
# =====================================================================
# Local Check Checkmk: Daily Remote Support (AnyDesk + RustDesk) Check (16:00)
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

# Nama file cache khusus untuk Remote Support
REMOTE_SUPPORT_CACHE="$CACHE_DIR/cache_remote_support_info.txt"

need_update() {
    local file=$1; local schedule_ts=$2; local file_ts=0
    if [ ! -f "$file" ]; then return 0; fi
    file_ts=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    if [ "$file_ts" -lt "$schedule_ts" ]; then return 0; else return 1; fi
}

# --- PROSES CEK DAN UPDATE CACHE ---
if need_update "$REMOTE_SUPPORT_CACHE" "$LAST_SCHEDULE"; then
    > "$REMOTE_SUPPORT_CACHE"
    
    # Generate timestamp
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

    anydesk_id="Not Installed"
    rustdesk_id="Not Installed"

    # ==========================================
    # 1. CARI ID ANYDESK
    # ==========================================
    if [ -f "/etc/anydesk/system.conf" ]; then
        ad_id=$(grep "^ad.anynet.id=" /etc/anydesk/system.conf | cut -d'=' -f2)
        if [ -n "$ad_id" ]; then
            anydesk_id="$ad_id"
        fi
    fi

    # ==========================================
    # 2. CARI ID RUSTDESK (Dengan Prioritas Bertingkat)
    # ==========================================
    # Cek apakah RustDesk terinstal (Native atau Flatpak)
    if command -v rustdesk >/dev/null 2>&1 || flatpak list 2>/dev/null | grep -q com.rustdesk.RustDesk; then
        
        rd_id=""
        active_user=$(who | awk '{print $1}' | head -n 1)
        
        # -----------------------------------------------------
        # PRIORITAS 1: Coba baca via CLI (--get-id)
        # -----------------------------------------------------
        if command -v rustdesk >/dev/null 2>&1; then
            # Instalasi Native
            if [ -n "$active_user" ] && [ "$active_user" != "root" ]; then
                rd_id=$(su - "$active_user" -c "rustdesk --get-id 2>/dev/null" | tr -d '[:space:]')
            else
                rd_id=$(rustdesk --get-id 2>/dev/null | tr -d '[:space:]')
            fi
        else
            # Instalasi Flatpak
            if [ -n "$active_user" ] && [ "$active_user" != "root" ]; then
                rd_id=$(su - "$active_user" -c "flatpak run com.rustdesk.RustDesk --get-id 2>/dev/null" | tr -d '[:space:]')
            else
                rd_id=$(flatpak run com.rustdesk.RustDesk --get-id 2>/dev/null | tr -d '[:space:]')
            fi
        fi

        # -----------------------------------------------------
        # PRIORITAS 2: Coba baca file rustdesk_id.txt
        # -----------------------------------------------------
        # (Jika hasil CLI kosong, gagal, atau error)
        if [[ -z "$rd_id" || "$rd_id" == *"error"* || "$rd_id" == *"Failed"* ]]; then
            DUMMY_FILE="/etc/rustdesk_id.txt"
            
            if [ -f "$DUMMY_FILE" ]; then
                rd_id=$(cat "$DUMMY_FILE" | tr -d '[:space:]')
            fi
        fi

        # -----------------------------------------------------
        # PRIORITAS 3: Gunakan Hostname
        # -----------------------------------------------------
        # (Jika file dummy juga tidak ada atau kosong)
        if [ -z "$rd_id" ]; then
            rd_id=$(hostname)
        fi

        # Terapkan hasil akhir ke variabel utama
        if [ -n "$rd_id" ]; then
            rustdesk_id="$rd_id"
        fi
    fi

    # ==========================================
    # 3. KIRIM OUTPUT KE CACHE CHECKMK
    # ==========================================
    echo "0 \"Info_Remote_Support\" - OK - AnyDesk: $anydesk_id | RustDesk: $rustdesk_id ❘ Checked At: $TIMESTAMP" >> "$REMOTE_SUPPORT_CACHE"
fi

# Cetak hasil dari cache ke Checkmk server
cat "$REMOTE_SUPPORT_CACHE" 2>/dev/null
