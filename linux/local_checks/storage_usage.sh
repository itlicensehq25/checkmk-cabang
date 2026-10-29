#!/usr/bin/env bash
# ==============================================================================
# Local Check Checkmk: Daily Storage Usage (Robust Multi-Platform)
# Scheduled to run once a day at 16:00
# ==============================================================================
CACHE_DIR="/var/lib/check_mk_agent/cache"
mkdir -p "$CACHE_DIR" 2>/dev/null
CACHE_FILE="$CACHE_DIR/cache_storage_usage.txt"

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
    
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    df_output=$(df -PT 2>/dev/null)

    if [ -z "$df_output" ]; then
        df_output=$(df -T 2>/dev/null)
    fi

    if [ -z "$df_output" ]; then
        df_output=$(df 2>/dev/null)
    fi

    echo "$df_output" | tail -n +2 | while read -r fs type total used avail pct mount; do
        [ -z "$fs" ] && continue

        # 1. Kecualikan sistem berkas virtual/semu
        case "$type" in
            tmpfs|devtmpfs|devfs|sysfs|proc|udev|cgroup|squashfs|configfs|pstore|bpf|autofs|securityfs|hugetlbfs|mqueue|devpts|fusectl|nsfs)
                continue
                ;;
        esac

        # 2. Tangani kasus 'overlay' (Docker/LXC)
        if [ "$type" = "overlay" ] && [ "$mount" != "/" ]; then
            continue
        fi

        # 3. Kecualikan direktori sistem virtual
        case "$mount" in
            /proc*|/sys*|/dev*|/run*|/var/lib/docker*|/var/lib/kubelet*|/snap*)
                continue
                ;;
        esac

        # 4. Hilangkan tanda persen
        used_pct=$(echo "$pct" | tr -d '%')
        if ! [[ "$used_pct" =~ ^[0-9]+$ ]]; then
            continue
        fi

        # 5. Konversi block biner ke GB
        total_gb=$(awk "BEGIN {printf \"%.2f\", $total / 1048576}")
        free_gb=$(awk "BEGIN {printf \"%.2f\", $avail / 1048576}")

        # 6. Bersihkan nama mount point untuk nama service Checkmk
        mount_clean=$(echo "$mount" | sed 's|/$|root|' | sed 's|^/||' | sed 's|/|_|g')
        if [ -z "$mount_clean" ]; then
            mount_clean="root"
        fi
        service_name="Storage_Usage_${mount_clean}"

        # 7. Evaluasi Status Checkmk (OK < 85%, WARNING >= 85%, CRITICAL >= 95%)
        status=0
        if [ "$used_pct" -ge 95 ]; then
            status=2
        elif [ "$used_pct" -ge 85 ]; then
            status=1
        fi

        status_label="OK"
        if [ "$status" -eq 1 ]; then
            status_label="Warning"
        elif [ "$status" -eq 2 ]; then
            status_label="Critical"
        fi

        echo "$status \"$service_name\" - Status : $status_label ❘ Partition: $mount ❘ Used: ${used_pct}% ❘ Free: ${free_gb} GB ❘ Total: ${total_gb} GB" >> "$CACHE_FILE"
    done
fi

cat "$CACHE_FILE" 2>/dev/null
