#!/usr/bin/env bash
# ==============================================================================
# Local Check Checkmk: Real-Time Network Info, Throughput & 3-Line Ping Monitor
# Platform   : Linux Host (Debian/Ubuntu/RHEL/Fedora/Rocky/Alma)
# Fitur Baru :
#   1. Real-Time Interface Throughput (RX/TX Rate & Total Download/Upload)
#   2. Ping 4x setiap 1 menit ke 3 Target (192.168.122.10, 8.8.8.8, & Gateway Cabang)
#   3. Akumulasi laporan 1 Jam (60x4 = 240 paket) dikirim ke Checkmk dalam 3 baris
#   4. Log lokal (ping_history.log) dengan retensi bergulir 30 hari ala CCTV
#      (otomatis menghapus log di hari ke-31 dan seterusnya)
# ==============================================================================

export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"

COLLECT_ONLY=0
if [ "${1:-}" = "--collect-only" ] || [ "${1:-}" = "-c" ]; then
    COLLECT_ONLY=1
fi

# ------------------------------------------------------------------------------
# 1. KONFIGURASI TARGET PING & RETENSI LOG (Identik dengan Android PDA v1.3.7)
# ------------------------------------------------------------------------------
# Isi MANUAL_GATEWAY_IP jika ingin mengunci IP Gateway Cabang secara manual di skrip,
# atau biarkan kosong ("") agar membaca dari /etc/check_mk/gateway_ip.conf
# maupun deteksi otomatis dari Default Gateway cabang yang sedang aktif.
MANUAL_GATEWAY_IP=""
TARGET_LOCAL="192.168.122.10"
TARGET_INTERNET="8.8.8.8"

SERVICE_LOCAL="Ping_192.168.122.10"
SERVICE_INTERNET="Ping_8.8.8.8"
SERVICE_GATEWAY="Ping_Gateway"

PINGS_PER_MINUTE=4
REPORT_INTERVAL_SEC=3600    # 1 Jam (3600 detik)
SAMPLES_PER_HOUR=60         # 60 sampel x 1 menit = 1 jam (240 paket)
LOG_RETENTION_DAYS=30       # Retensi log 30 hari (Hari ke-31+ otomatis dihapus)
PRUNE_INTERVAL_SEC=3600     # Interval pemeriksaan pemangkasan log (1 jam)
MAX_EMERGENCY_BYTES=36700160 # 35 MB

CONFIG_DIR="/etc/check_mk"
GATEWAY_CONF="${CONFIG_DIR}/gateway_ip.conf"
LOG_DIR="/var/log/checkmk_custom"
PING_LOG_FILE="${LOG_DIR}/ping_history.log"
CACHE_DIR="/var/lib/check_mk_agent/cache"
PING_STATE_DIR="${CACHE_DIR}/ping_monitor"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$PING_STATE_DIR" 2>/dev/null

# ------------------------------------------------------------------------------
# 2. FUNGSI HELPER: VALIDASI IP & DETEKSI GATEWAY CABANG
# ------------------------------------------------------------------------------
is_valid_ipv4() {
    local ip="${1:-}"
    [ -z "$ip" ] && return 1
    [ "$ip" = "0.0.0.0" ] && return 1
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local i
        for i in 1 2 3 4; do
            local oct="${BASH_REMATCH[$i]}"
            if [ "$oct" -lt 0 ] || [ "$oct" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

detect_default_gateway() {
    local gw=""
    if command -v ip >/dev/null 2>&1; then
        gw=$(ip -4 route show default 2>/dev/null | awk '/default via/ {print $3; exit}')
    fi
    if ! is_valid_ipv4 "$gw" && command -v route >/dev/null 2>&1; then
        gw=$(route -n 2>/dev/null | awk '$1=="0.0.0.0" && $2!="0.0.0.0" {print $2; exit}')
    fi
    if is_valid_ipv4 "$gw"; then
        echo "$gw"
        return 0
    fi
    echo ""
    return 1
}

get_branch_gateway_ip() {
    # Prioritas 1: Variabel manual di skrip
    if is_valid_ipv4 "$MANUAL_GATEWAY_IP"; then
        echo "$MANUAL_GATEWAY_IP"
        return 0
    fi

    # Prioritas 2: File konfigurasi /etc/check_mk/gateway_ip.conf
    local saved_ip=""
    if [ -f "$GATEWAY_CONF" ]; then
        local raw
        raw=$(head -n 1 "$GATEWAY_CONF" 2>/dev/null | tr -d '\r\n ')
        if [[ "${raw^^}" == LOCKED:* ]]; then
            local locked_ip="${raw#*:}"
            if is_valid_ipv4 "$locked_ip"; then
                echo "$locked_ip"
                return 0
            fi
        elif is_valid_ipv4 "$raw"; then
            saved_ip="$raw"
        fi
    fi

    # Prioritas 3: Deteksi otomatis dari tabel routing aktif & simpan sebagai fallback
    local detected
    detected=$(detect_default_gateway)
    if is_valid_ipv4 "$detected"; then
        if [ "$detected" != "$saved_ip" ]; then
            echo "$detected" > "$GATEWAY_CONF" 2>/dev/null
        fi
        echo "$detected"
        return 0
    fi

    echo "$saved_ip"
}

# ------------------------------------------------------------------------------
# 3. FUNGSI REGISTRASI CRON 1 MENIT (SELF-HEALING)
# ------------------------------------------------------------------------------
ensure_ping_cron() {
    if [ "$(id -u)" -eq 0 ] && [ -d "/etc/cron.d" ]; then
        local cron_file="/etc/cron.d/checkmk_ping_monitor"
        local script_path="/usr/lib/check_mk_agent/local/info_network.sh"
        if [ ! -f "$cron_file" ] && [ -f "$script_path" ]; then
            cat <<EOF > "$cron_file" 2>/dev/null
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
* * * * * root $script_path --collect-only >/dev/null 2>&1
EOF
            chmod 644 "$cron_file" 2>/dev/null
        fi
    fi
}

# ------------------------------------------------------------------------------
# 4. FUNGSI EKSEKUSI PING 4X & FORMAT LOG
# ------------------------------------------------------------------------------
run_single_ping_4x() {
    local target="$1"
    local out_file="$2"
    local raw
    raw=$(ping -n -c "$PINGS_PER_MINUTE" -i 0.2 -W 1 "$target" 2>&1)

    echo "$raw" | awk -v tgt="$target" -v def_tx="$PINGS_PER_MINUTE" '
    BEGIN {
        tx = def_tx; rx = 0; min = -1; avg = -1; max = -1;
        sum_rtt = 0; cnt_rtt = 0;
    }
    /packets transmitted/ {
        for (i=1; i<=NF; i++) {
            if ($(i+1) == "packets" && $(i+2) == "transmitted," || $(i+1) == "packets" && $(i+2) == "transmitted") {
                tx = $i + 0;
            }
            if ($(i+1) == "received," || $(i+1) == "received") {
                rx = $i + 0;
            }
        }
    }
    /time=[0-9.]+/ {
        match($0, /time=[0-9.]+/);
        val = substr($0, RSTART+5, RLENGTH-5) + 0.0;
        sum_rtt += val;
        cnt_rtt++;
        if (min < 0 || val < min) min = val;
        if (max < 0 || val > max) max = val;
    }
    /min\/avg\/max/ {
        split($0, parts, "=");
        if (length(parts) >= 2) {
            gsub(/^[ \t]+/, "", parts[2]);
            split(parts[2], nums, "/");
            if (length(nums) >= 3) {
                min = nums[1] + 0.0;
                avg = nums[2] + 0.0;
                max = nums[3] + 0.0;
            }
        }
    }
    END {
        if (rx == 0 && cnt_rtt > 0) rx = cnt_rtt;
        if (avg < 0 && cnt_rtt > 0) avg = sum_rtt / cnt_rtt;
        if (tx <= 0) tx = def_tx;
        loss = ((tx - rx) * 100.0) / tx;
        printf "%d|%d|%.1f|%.2f|%.2f|%.2f\n", tx, rx, loss, min, avg, max;
    }' > "$out_file"
}

format_sample_log_line() {
    local ts="$1"
    local label="$2"
    local sample_str="$3"

    echo "$sample_str" | awk -F'|' -v ts="$ts" -v lbl="$label" '{
        tx = $1 + 0; rx = $2 + 0; loss = $3 + 0.0;
        min = $4 + 0.0; avg = $5 + 0.0; max = $6 + 0.0;
        min_s = (min >= 0) ? sprintf("%.1fms", min) : "-";
        avg_s = (avg >= 0) ? sprintf("%.1fms", avg) : "TIMEOUT";
        max_s = (max >= 0) ? sprintf("%.1fms", max) : "-";
        printf "[%s] PING %-24s | tx=%d rx=%d loss=%.0f%% min=%s avg=%s max=%s\n", ts, lbl, tx, rx, loss, min_s, avg_s, max_s;
    }'
}

# ------------------------------------------------------------------------------
# 5. RETENSI LOG 30 HARI ALA CCTV (HARI KE-31+ OTOMATIS DIHAPUS)
# ------------------------------------------------------------------------------
prune_ping_logs_30days() {
    [ ! -f "$PING_LOG_FILE" ] && return 0

    local cutoff_ts
    cutoff_ts=$(date -d "${LOG_RETENTION_DAYS} days ago" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    if [ -z "$cutoff_ts" ]; then
        local now_s
        now_s=$(date +%s)
        local cut_s=$(( now_s - (LOG_RETENTION_DAYS * 86400) ))
        cutoff_ts=$(date -d "@$cut_s" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    fi
    [ -z "$cutoff_ts" ] && return 0

    local file_size
    file_size=$(stat -c %s "$PING_LOG_FILE" 2>/dev/null || echo 0)
    local needs_prune=0

    if [ "$file_size" -gt "$MAX_EMERGENCY_BYTES" ]; then
        needs_prune=1
    else
        local first_ts
        first_ts=$(head -n 5 "$PING_LOG_FILE" 2>/dev/null | awk 'substr($0,1,1)=="[" && substr($0,21,1)=="]" {print substr($0,2,19); exit}')
        if [ -n "$first_ts" ] && [[ "$first_ts" < "$cutoff_ts" ]]; then
            needs_prune=1
        fi
    fi

    [ "$needs_prune" -eq 0 ] && return 0

    local tmp_log="${PING_LOG_FILE}.tmp.$$"
    if awk -v cutoff="$cutoff_ts" '
        BEGIN { keep = 0 }
        {
            if (!keep) {
                if (substr($0, 1, 1) == "[" && substr($0, 21, 1) == "]") {
                    ts = substr($0, 2, 19);
                    if (ts >= cutoff) keep = 1;
                }
            }
            if (keep) print $0;
        }
    ' "$PING_LOG_FILE" > "$tmp_log" 2>/dev/null; then
        mv -f "$tmp_log" "$PING_LOG_FILE" 2>/dev/null
    else
        rm -f "$tmp_log" 2>/dev/null
    fi
}

# ------------------------------------------------------------------------------
# 6. FORMAT BARIS OUTPUT CHECKMK & UPDATE AKUMULATOR 1 JAM
# ------------------------------------------------------------------------------
build_checkmk_ping_line() {
    local svc_name="$1"
    local tgt_display="$2"
    local samples="$3"
    local tx="$4"
    local rx="$5"
    local fail_min="$6"
    local avg_ms="$7"
    local min_ms="$8"
    local max_ms="$9"
    local last_ms="${10}"
    local start_sec="${11}"
    local end_sec="${12}"
    local warn_rtt="${13}"
    local crit_rtt="${14}"
    local completed_hour="${15}"

    local start_hm end_hm
    start_hm=$(date -d "@$start_sec" "+%H:%M" 2>/dev/null || echo "00:00")
    end_hm=$(date -d "@$end_sec" "+%H:%M" 2>/dev/null || echo "00:00")

    awk -v svc="$svc_name" \
        -v tgt="$tgt_display" \
        -v samples="$samples" \
        -v tx="$tx" \
        -v rx="$rx" \
        -v fail_min="$fail_min" \
        -v avg_ms="$avg_ms" \
        -v min_ms="$min_ms" \
        -v max_ms="$max_ms" \
        -v last_ms="$last_ms" \
        -v win_str="${start_hm}-${end_hm}" \
        -v warn_rtt="$warn_rtt" \
        -v crit_rtt="$crit_rtt" \
        -v done_hr="$completed_hour" '
    BEGIN {
        loss_pct = (tx > 0) ? (((tx - rx) * 100.0) / tx) : 0.0;
        state = 0;
        if (tx > 0 && (loss_pct >= 50.0 || (avg_ms >= 0 && avg_ms >= crit_rtt))) {
            state = 2;
        } else if (tx > 0 && (loss_pct >= 20.0 || (avg_ms >= 0 && avg_ms >= warn_rtt))) {
            state = 1;
        }
        state_str = (state == 2) ? "CRITICAL" : ((state == 1) ? "WARNING" : "OK");

        rta_m = (avg_ms >= 0) ? sprintf("rta=%.2fms;%.0f;%.0f;0", avg_ms, warn_rtt, crit_rtt) : sprintf("rta=0.00ms;%.0f;%.0f;0", warn_rtt, crit_rtt);
        pl_m  = sprintf("pl=%.1f%%;20;50;0;100", loss_pct);
        min_m = (min_ms >= 0) ? sprintf("|rtmin=%.2fms", min_ms) : "";
        max_m = (max_ms >= 0) ? sprintf("|rtmax=%.2fms", max_ms) : "";
        metrics = rta_m "|" pl_m min_m max_m;

        avg_s = (avg_ms >= 0) ? sprintf("%.1f ms", avg_ms) : "TIMEOUT";
        mm_s  = (min_ms >= 0 && max_ms >= 0) ? sprintf("%.1f/%.1f ms", min_ms, max_ms) : "N/A";
        lst_s = (last_ms >= 0) ? sprintf("%.1f ms", last_ms) : "TIMEOUT";

        mode_lbl = (done_hr == 1) ? sprintf("1h Summary (%dx4=%d pkt)", samples, tx) : sprintf("Buffering 1h (%d/60m, %d pkt)", samples, tx);
        max_smp = (samples > 0) ? samples : 1;

        printf "%d \"%s\" %s Status : %s | Target : %s | Mode : %s | Loss : %.1f%% (%d/%d rx) | Avg RTT : %s | Min/Max : %s | Last : %s | Timeout Min : %d/%d | Window : %s | Log : 30d Rolling\n",
            state, svc, metrics, state_str, tgt, mode_lbl, loss_pct, rx, tx, avg_s, mm_s, lst_s, fail_min, max_smp, win_str;
    }'
}

update_target_accumulator() {
    local key="$1"
    local svc_name="$2"
    local tgt_display="$3"
    local sample_str="$4"
    local now_sec="$5"
    local now_ts="$6"
    local warn_rtt="$7"
    local crit_rtt="$8"

    local state_file="${PING_STATE_DIR}/${key}.state"
    local pub_file="${PING_STATE_DIR}/${key}.pub"

    local win_start_sec=0 win_samples=0 win_tx=0 win_rx=0 win_fail_min=0
    local win_rtt_count=0 win_rtt_sum="0.0" win_rtt_min="-1.0" win_rtt_max="-1.0"
    local last_sample_sec=0 last_avg_ms="-1.0" last_loss="0.0"

    if [ -f "$state_file" ]; then
        IFS='|' read -r win_start_sec win_samples win_tx win_rx win_fail_min win_rtt_count win_rtt_sum win_rtt_min win_rtt_max last_sample_sec last_avg_ms last_loss < "$state_file"
    fi

    if [ -z "$win_start_sec" ] || [ "$win_start_sec" -le 0 ] || [ "$now_sec" -lt "$win_start_sec" ]; then
        win_start_sec="$now_sec"
    fi

    local s_tx s_rx s_loss s_min s_avg s_max
    IFS='|' read -r s_tx s_rx s_loss s_min s_avg s_max <<< "$sample_str"

    win_samples=$(( win_samples + 1 ))
    win_tx=$(( win_tx + s_tx ))
    win_rx=$(( win_rx + s_rx ))
    if [ "$s_rx" -eq 0 ]; then
        win_fail_min=$(( win_fail_min + 1 ))
    fi

    read -r win_rtt_count win_rtt_sum win_rtt_min win_rtt_max <<< "$(awk \
        -v cnt="$win_rtt_count" -v sum="$win_rtt_sum" -v cur_min="$win_rtt_min" -v cur_max="$win_rtt_max" \
        -v s_min="$s_min" -v s_avg="$s_avg" -v s_max="$s_max" '
    BEGIN {
        if (s_avg + 0.0 >= 0) {
            cnt = cnt + 1;
            sum = sum + s_avg;
        }
        if (s_min + 0.0 >= 0) {
            if (cur_min + 0.0 < 0 || s_min + 0.0 < cur_min + 0.0) cur_min = s_min;
        }
        if (s_max + 0.0 >= 0) {
            if (cur_max + 0.0 < 0 || s_max + 0.0 > cur_max + 0.0) cur_max = s_max;
        }
        printf "%d %.4f %.2f %.2f\n", cnt, sum, cur_min, cur_max;
    }')"

    last_sample_sec="$now_sec"
    last_avg_ms="$s_avg"
    last_loss="$s_loss"

    local elapsed=$(( now_sec - win_start_sec ))
    if [ "$elapsed" -ge "$REPORT_INTERVAL_SEC" ] || [ "$win_samples" -ge "$SAMPLES_PER_HOUR" ]; then
        local avg_ms
        avg_ms=$(awk -v cnt="$win_rtt_count" -v sum="$win_rtt_sum" 'BEGIN { if (cnt > 0) printf "%.2f", sum / cnt; else print "-1.0"; }')
        local hourly_line
        hourly_line=$(build_checkmk_ping_line "$svc_name" "$tgt_display" "$win_samples" "$win_tx" "$win_rx" "$win_fail_min" "$avg_ms" "$win_rtt_min" "$win_rtt_max" "$last_avg_ms" "$win_start_sec" "$now_sec" "$warn_rtt" "$crit_rtt" 1)

        echo "${now_sec}|${hourly_line}" > "${pub_file}.tmp.$$" && mv -f "${pub_file}.tmp.$$" "$pub_file"

        # Catat baris rangkuman 1 jam ke dalam ping_history.log
        local start_hm end_hm
        start_hm=$(date -d "@$win_start_sec" "+%H:%M" 2>/dev/null || echo "00:00")
        end_hm=$(date -d "@$now_sec" "+%H:%M" 2>/dev/null || echo "00:00")
        awk -v ts="$now_ts" -v tgt="$tgt_display" -v win="${start_hm}-${end_hm}" \
            -v smp="$win_samples" -v tx="$win_tx" -v rx="$win_rx" \
            -v avg="$avg_ms" -v min="$win_rtt_min" -v max="$win_rtt_max" '
        BEGIN {
            loss = (tx > 0) ? (((tx - rx) * 100.0) / tx) : 100.0;
            avg_s = (avg + 0.0 >= 0) ? sprintf("%.1fms", avg) : "TIMEOUT";
            mm_s  = (min + 0.0 >= 0 && max + 0.0 >= 0) ? sprintf("%.1f/%.1fms", min, max) : "N/A";
            printf "[%s] === 1H CHECKMK REPORT [%s] window=%s samples=%d pkt=%d/%d loss=%.1f%% avg=%s min/max=%s ===\n",
                ts, tgt, win, smp, rx, tx, loss, avg_s, mm_s;
        }' >> "$PING_LOG_FILE" 2>/dev/null

        # Reset window 1 jam untuk jam berikutnya
        win_start_sec="$now_sec"
        win_samples=0
        win_tx=0
        win_rx=0
        win_fail_min=0
        win_rtt_count=0
        win_rtt_sum="0.0"
        win_rtt_min="-1.0"
        win_rtt_max="-1.0"
    fi

    echo "${win_start_sec}|${win_samples}|${win_tx}|${win_rx}|${win_fail_min}|${win_rtt_count}|${win_rtt_sum}|${win_rtt_min}|${win_rtt_max}|${last_sample_sec}|${last_avg_ms}|${last_loss}" > "${state_file}.tmp.$$"
    mv -f "${state_file}.tmp.$$" "$state_file" 2>/dev/null
}

get_target_checkmk_output() {
    local key="$1"
    local svc_name="$2"
    local tgt_display="$3"
    local warn_rtt="$4"
    local crit_rtt="$5"
    local now_sec="$6"

    local pub_file="${PING_STATE_DIR}/${key}.pub"
    local state_file="${PING_STATE_DIR}/${key}.state"

    if [ -f "$pub_file" ]; then
        local pub_line
        pub_line=$(cut -d'|' -f2- "$pub_file" 2>/dev/null)
        if [ -n "$pub_line" ]; then
            echo "$pub_line"
            return 0
        fi
    fi

    local win_start_sec="$now_sec" win_samples=0 win_tx=0 win_rx=0 win_fail_min=0
    local win_rtt_count=0 win_rtt_sum="0.0" win_rtt_min="-1.0" win_rtt_max="-1.0"
    local last_sample_sec="$now_sec" last_avg_ms="-1.0" last_loss="0.0"

    if [ -f "$state_file" ]; then
        IFS='|' read -r win_start_sec win_samples win_tx win_rx win_fail_min win_rtt_count win_rtt_sum win_rtt_min win_rtt_max last_sample_sec last_avg_ms last_loss < "$state_file"
    fi

    local avg_ms
    avg_ms=$(awk -v cnt="$win_rtt_count" -v sum="$win_rtt_sum" 'BEGIN { if (cnt > 0) printf "%.2f", sum / cnt; else print "-1.0"; }')

    build_checkmk_ping_line "$svc_name" "$tgt_display" "$win_samples" "$win_tx" "$win_rx" "$win_fail_min" "$avg_ms" "$win_rtt_min" "$win_rtt_max" "$last_avg_ms" "$win_start_sec" "$last_sample_sec" "$warn_rtt" "$crit_rtt" 0
}

collect_minute_ping_samples() {
    local now_sec now_ts
    now_sec=$(date +%s)
    now_ts=$(date "+%Y-%m-%d %H:%M:%S")

    local last_collect_file="${PING_STATE_DIR}/last_collect.ts"
    local last_prune_file="${PING_STATE_DIR}/last_prune.ts"
    local last_gw_file="${PING_STATE_DIR}/last_gateway.ip"

    local gw_ip
    gw_ip=$(get_branch_gateway_ip)
    local prev_gw=""
    [ -f "$last_gw_file" ] && prev_gw=$(cat "$last_gw_file" 2>/dev/null)

    if [ "$gw_ip" != "$prev_gw" ]; then
        echo "$gw_ip" > "$last_gw_file" 2>/dev/null
        rm -f "${PING_STATE_DIR}/gateway.state" "${PING_STATE_DIR}/gateway.pub" 2>/dev/null
    fi

    local last_collect=0
    [ -f "$last_collect_file" ] && last_collect=$(cat "$last_collect_file" 2>/dev/null || echo 0)

    # Hindari duplikasi sampel dalam menit yang sama (< 45 detik)
    if [ "$last_collect" -gt 0 ] && [ $(( now_sec - last_collect )) -lt 45 ]; then
        return 0
    fi
    echo "$now_sec" > "$last_collect_file" 2>/dev/null

    local tmp_local="${PING_STATE_DIR}/sample_local.$$"
    local tmp_net="${PING_STATE_DIR}/sample_net.$$"
    local tmp_gw="${PING_STATE_DIR}/sample_gw.$$"

    # Jalankan 4x ping ke ke-3 target secara paralel agar selesai < 1 detik
    run_single_ping_4x "$TARGET_LOCAL" "$tmp_local" &
    local pid_local=$!
    run_single_ping_4x "$TARGET_INTERNET" "$tmp_net" &
    local pid_net=$!
    local pid_gw=""
    if is_valid_ipv4 "$gw_ip"; then
        run_single_ping_4x "$gw_ip" "$tmp_gw" &
        pid_gw=$!
    fi

    wait "$pid_local" 2>/dev/null
    wait "$pid_net" 2>/dev/null
    [ -n "$pid_gw" ] && wait "$pid_gw" 2>/dev/null

    local s_local s_net s_gw=""
    s_local=$(cat "$tmp_local" 2>/dev/null)
    s_net=$(cat "$tmp_net" 2>/dev/null)
    [ -f "$tmp_gw" ] && s_gw=$(cat "$tmp_gw" 2>/dev/null)
    rm -f "$tmp_local" "$tmp_net" "$tmp_gw" 2>/dev/null

    # 1. Tulis ke ping_history.log
    {
        [ -n "$s_local" ] && format_sample_log_line "$now_ts" "$TARGET_LOCAL" "$s_local"
        [ -n "$s_net" ]   && format_sample_log_line "$now_ts" "$TARGET_INTERNET" "$s_net"
        [ -n "$s_gw" ]    && format_sample_log_line "$now_ts" "${gw_ip} (GW)" "$s_gw"
    } >> "$PING_LOG_FILE" 2>/dev/null

    # 2. Update akumulator 1 jam untuk ke-3 target
    [ -n "$s_local" ] && update_target_accumulator "local" "$SERVICE_LOCAL" "$TARGET_LOCAL" "$s_local" "$now_sec" "$now_ts" 100 250
    [ -n "$s_net" ]   && update_target_accumulator "internet" "$SERVICE_INTERNET" "$TARGET_INTERNET" "$s_net" "$now_sec" "$now_ts" 150 300
    [ -n "$s_gw" ]    && update_target_accumulator "gateway" "$SERVICE_GATEWAY" "${gw_ip} (Gateway Cabang)" "$s_gw" "$now_sec" "$now_ts" 50 150

    # 3. Pangkas log > 30 hari (Hari ke-31+) setiap 1 jam
    local last_prune=0
    [ -f "$last_prune_file" ] && last_prune=$(cat "$last_prune_file" 2>/dev/null || echo 0)
    if [ "$last_prune" -le 0 ] || [ $(( now_sec - last_prune )) -ge "$PRUNE_INTERVAL_SEC" ]; then
        prune_ping_logs_30days
        echo "$now_sec" > "$last_prune_file" 2>/dev/null
    fi
}

# ------------------------------------------------------------------------------
# 7. MODE EKSEKUSI: BACKGROUND COLLECTOR VS CHECKMK AGENT POLL
# ------------------------------------------------------------------------------
if [ "$COLLECT_ONLY" -eq 1 ]; then
    collect_minute_ping_samples
    exit 0
fi

ensure_ping_cron
collect_minute_ping_samples

# ------------------------------------------------------------------------------
# 8. REAL-TIME NETWORK INTERFACE THROUGHPUT (Info_Network_<IFACE>)
# ------------------------------------------------------------------------------
declare -A RX_OLD
declare -A TX_OLD
declare -A IP_ADDR

for IFACE in $(ls /sys/class/net/ 2>/dev/null | grep -v "^lo$"); do
    STATE=$(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null)
    if [ "$STATE" = "up" ]; then
        RX_OLD[$IFACE]=$(cat "/sys/class/net/$IFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
        TX_OLD[$IFACE]=$(cat "/sys/class/net/$IFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
        IP_ADDR[$IFACE]=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
    fi
done

if [ "${#RX_OLD[@]}" -eq 0 ]; then
    echo "0 \"Info_Network_NoActive\" - OK - No active network interfaces detected."
else
    sleep 1

    for IFACE in "${!RX_OLD[@]}"; do
        RX_NEW=$(cat "/sys/class/net/$IFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
        TX_NEW=$(cat "/sys/class/net/$IFACE/statistics/tx_bytes" 2>/dev/null || echo 0)

        RX_RATE=$((RX_NEW - RX_OLD[$IFACE]))
        TX_RATE=$((TX_NEW - TX_OLD[$IFACE]))

        [ "$RX_RATE" -lt 0 ] && RX_RATE=0
        [ "$TX_RATE" -lt 0 ] && TX_RATE=0

        RX_TOTAL_HR=$(awk -v b="$RX_NEW" 'BEGIN {
            if(b>=1073741824) printf "%.2f GB", b/1073741824;
            else if(b>=1048576) printf "%.2f MB", b/1048576;
            else printf "%.2f KB", b/1024;
        }')
        TX_TOTAL_HR=$(awk -v b="$TX_NEW" 'BEGIN {
            if(b>=1073741824) printf "%.2f GB", b/1073741824;
            else if(b>=1048576) printf "%.2f MB", b/1048576;
            else printf "%.2f KB", b/1024;
        }')

        RX_RATE_HR=$(awk -v b="$RX_RATE" 'BEGIN {
            if(b>=1048576) printf "%.2f MB/s", b/1048576;
            else if(b>=1024) printf "%.2f KB/s", b/1024;
            else printf "%d B/s", b;
        }')
        TX_RATE_HR=$(awk -v b="$TX_RATE" 'BEGIN {
            if(b>=1048576) printf "%.2f MB/s", b/1048576;
            else if(b>=1024) printf "%.2f KB/s", b/1024;
            else printf "%d B/s", b;
        }')

        IP=${IP_ADDR[$IFACE]}
        [ -z "$IP" ] && IP="No IP"

        echo "0 \"Info_Network_$IFACE\" in=${RX_NEW}c|out=${TX_NEW}c OK - IP Address: $IP | Total Download: $RX_TOTAL_HR | Total Upload: $TX_TOTAL_HR | RX Rate : $RX_RATE_HR | TX Rate : $TX_RATE_HR"
    done
fi

# ------------------------------------------------------------------------------
# 9. CETAK 3 BARIS PING MONITOR KE CHECKMK (192.168.122.10, 8.8.8.8, & Gateway)
# ------------------------------------------------------------------------------
NOW_EPOCH_OUT=$(date +%s)
GW_IP_OUT=$(get_branch_gateway_ip)

get_target_checkmk_output "local" "$SERVICE_LOCAL" "$TARGET_LOCAL" 100 250 "$NOW_EPOCH_OUT"
get_target_checkmk_output "internet" "$SERVICE_INTERNET" "$TARGET_INTERNET" 150 300 "$NOW_EPOCH_OUT"

if is_valid_ipv4 "$GW_IP_OUT"; then
    get_target_checkmk_output "gateway" "$SERVICE_GATEWAY" "${GW_IP_OUT} (Gateway Cabang)" 50 150 "$NOW_EPOCH_OUT"
else
    echo "1 \"${SERVICE_GATEWAY}\" - Status : WARNING | Target : Belum Terdeteksi | Remark : Isi IP Gateway Cabang di ${GATEWAY_CONF}"
fi
