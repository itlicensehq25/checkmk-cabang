#!/usr/bin/env bash
# ==============================================================================
# Local Check Checkmk: RAM Usage (Physical RAM Utilization)
# OK: < 85% | Warning: >= 85% | Critical: >= 95%
# ==============================================================================

WARN=85
CRIT=95

if [ -f /proc/meminfo ]; then
    mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    
    if [ -n "$mem_total" ] && [ -n "$mem_avail" ]; then
        mem_used=$((mem_total - mem_avail))
        pct=$((mem_used * 100 / mem_total))
        
        total_gb=$(awk "BEGIN {printf \"%.2f\", $mem_total/1024/1024}")
        used_gb=$(awk "BEGIN {printf \"%.2f\", $mem_used/1024/1024}")
        free_gb=$(awk "BEGIN {printf \"%.2f\", $mem_avail/1024/1024}")
        warn_gb=$(awk "BEGIN {printf \"%.2f\", ($mem_total/1024/1024)*($WARN/100)}")
        crit_gb=$(awk "BEGIN {printf \"%.2f\", ($mem_total/1024/1024)*($CRIT/100)}")
    else
        total_gb_int=$(free -g | awk '/^Mem:/{print $2}')
        used_gb_int=$(free -g | awk '/^Mem:/{print $3}')
        free_gb_int=$(free -g | awk '/^Mem:/{print $4}')
        pct=$((used_gb_int * 100 / total_gb_int))
        total_gb=$(printf "%.2f" "$total_gb_int")
        used_gb=$(printf "%.2f" "$used_gb_int")
        free_gb=$(printf "%.2f" "$free_gb_int")
        warn_gb=$(awk "BEGIN {printf \"%.2f\", $total_gb*($WARN/100)}")
        crit_gb=$(awk "BEGIN {printf \"%.2f\", $total_gb*($CRIT/100)}")
    fi
else
    total_gb_int=$(free -g | awk '/^Mem:/{print $2}')
    used_gb_int=$(free -g | awk '/^Mem:/{print $3}')
    free_gb_int=$(free -g | awk '/^Mem:/{print $4}')
    pct=$((used_gb_int * 100 / total_gb_int))
    total_gb=$(printf "%.2f" "$total_gb_int")
    used_gb=$(printf "%.2f" "$used_gb_int")
    free_gb=$(printf "%.2f" "$free_gb_int")
    warn_gb=$(awk "BEGIN {printf \"%.2f\", $total_gb*($WARN/100)}")
    crit_gb=$(awk "BEGIN {printf \"%.2f\", $total_gb*($CRIT/100)}")
fi

# Tentukan status alert
status=0
status_txt="OK"
if [ "$pct" -ge "$CRIT" ]; then
    status=2
    status_txt="Critical"
elif [ "$pct" -ge "$WARN" ]; then
    status=1
    status_txt="Warning"
fi

# Susun perfdata: 2 metrik (GB dan %) dipisahkan tanda pipe |
perfdata="ram_used=${used_gb}GB;${warn_gb};${crit_gb};0;${total_gb}|ram_percent=${pct}%;${WARN};${CRIT};0;100"

# Output format Checkmk local check
echo "$status \"Info_RAM_Usage\" $perfdata Status : $status_txt ❘ Used: ${pct}% ❘ Used Space: ${used_gb} GB ❘ Free: ${free_gb} GB ❘ Total: ${total_gb} GB"
