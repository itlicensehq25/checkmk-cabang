use crate::checkmk::LocalCheckItem;
use crate::config::PingSection;
use chrono::{DateTime, Local, NaiveDateTime, TimeZone};
use std::collections::{HashMap, VecDeque};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;

const MAX_LOG_BYTES: u64 = 35 * 1024 * 1024; // 35 MB cap (~30d rolling)
const LOG_FILENAME: &str = "ping_history.log";

#[derive(Debug, Clone)]
pub struct PingTargetConfig {
    pub key: String,
    pub service_name: String,
    pub target_ip: String,
    pub display_label: String,
    pub warn_ms: f64,
    pub crit_ms: f64,
}

#[derive(Debug, Clone)]
pub struct PingSample {
    pub timestamp_sec: i64,
    pub hh_mm: String,
    pub tx: u32,
    pub rx: u32,
    pub loss_pct: f64,
    pub min_ms: f64,
    pub avg_ms: f64,
    pub max_ms: f64,
}

#[derive(Debug)]
struct PingMonitorState {
    history_24h: HashMap<String, VecDeque<PingSample>>,
    last_prune_epoch_sec: i64,
    last_targets: Vec<PingTargetConfig>,
}

pub struct PingMonitor {
    log_path: PathBuf,
    retention_days: u64,
    pings_per_minute: u32,
    report_interval_sec: u64,
    state: Mutex<PingMonitorState>,
}

impl PingMonitor {
    pub fn new(data_dir: &Path, cfg: &PingSection) -> Self {
        let log_path = data_dir.join(LOG_FILENAME);
        let monitor = Self {
            log_path,
            retention_days: cfg.log_retention_days.max(1),
            pings_per_minute: cfg.pings_per_minute.max(1),
            report_interval_sec: cfg.report_interval_sec.max(60),
            state: Mutex::new(PingMonitorState {
                history_24h: HashMap::new(),
                last_prune_epoch_sec: 0,
                last_targets: Vec::new(),
            }),
        };
        monitor.load_recent_from_log();
        monitor
    }

    pub fn log_path(&self) -> &Path {
        &self.log_path
    }

    pub fn build_targets(cfg: &PingSection, gateway_ip: &str) -> Vec<PingTargetConfig> {
        let mut out = Vec::with_capacity(3);

        let internet = cfg.internet_target.trim();
        if !internet.is_empty() {
            out.push(PingTargetConfig {
                key: "internet".to_string(),
                service_name: format!("Ping_{}", sanitize_service_suffix(internet)),
                target_ip: internet.to_string(),
                display_label: internet.to_string(),
                warn_ms: cfg.internet_warn_ms,
                crit_ms: cfg.internet_crit_ms,
            });
        }

        let local = cfg.local_target.trim();
        if !local.is_empty() {
            out.push(PingTargetConfig {
                key: "local".to_string(),
                service_name: format!("Ping_{}", sanitize_service_suffix(local)),
                target_ip: local.to_string(),
                display_label: local.to_string(),
                warn_ms: cfg.local_warn_ms,
                crit_ms: cfg.local_crit_ms,
            });
        }

        let gw = gateway_ip.trim();
        if !gw.is_empty() {
            out.push(PingTargetConfig {
                key: "gateway".to_string(),
                service_name: "Ping_Gateway".to_string(),
                target_ip: gw.to_string(),
                display_label: format!("{} (Gateway Cabang)", gw),
                warn_ms: cfg.gateway_warn_ms,
                crit_ms: cfg.gateway_crit_ms,
            });
        }

        out
    }

    /// Menjalankan ping 4x secara paralel ke semua target lalu menyimpannya ke memori & log 30 hari.
    pub fn collect_minute_sample(&self, targets: &[PingTargetConfig]) {
        if targets.is_empty() {
            return;
        }
        let count = self.pings_per_minute;
        let now = Local::now();
        let ts_sec = now.timestamp();
        let hh_mm = now.format("%H:%M").to_string();
        let full_ts = now.format("%Y-%m-%d %H:%M:%S").to_string();

        let hh_mm_ref = &hh_mm;
        let results: Vec<(PingTargetConfig, PingSample)> = std::thread::scope(|scope| {
            let handles: Vec<_> = targets
                .iter()
                .map(|target| {
                    scope.spawn(move || {
                        let sample = execute_os_ping(&target.target_ip, count, ts_sec, hh_mm_ref);
                        (target.clone(), sample)
                    })
                })
                .collect();

            handles
                .into_iter()
                .filter_map(|h| h.join().ok())
                .collect()
        });

        let mut log_lines = Vec::with_capacity(results.len());
        for (target, sample) in &results {
            let line = format_log_line(&full_ts, &target.target_ip, sample);
            log_lines.push(line);
        }
        self.append_log_lines(&log_lines, ts_sec);

        if let Ok(mut guard) = self.state.lock() {
            guard.last_targets = targets.to_vec();
            let cutoff_24h = ts_sec - 86_400;
            for (target, sample) in results {
                let entry = guard
                    .history_24h
                    .entry(target.target_ip.clone())
                    .or_default();
                entry.push_back(sample);
                while let Some(front) = entry.front() {
                    if front.timestamp_sec < cutoff_24h {
                        entry.pop_front();
                    } else {
                        break;
                    }
                }
            }
        }
    }

    pub fn record_sample(&self, target: &PingTargetConfig, sample: PingSample) {
        if let Ok(mut guard) = self.state.lock() {
            let cutoff_24h = sample.timestamp_sec - 86_400;
            let entry = guard
                .history_24h
                .entry(target.target_ip.clone())
                .or_default();
            entry.push_back(sample);
            while let Some(front) = entry.front() {
                if front.timestamp_sec < cutoff_24h {
                    entry.pop_front();
                } else {
                    break;
                }
            }
        }
    }

    pub fn build_local_checks(&self, targets: &[PingTargetConfig]) -> Vec<LocalCheckItem> {
        let now_sec = Local::now().timestamp();
        let cache_meta = Some((now_sec, 90u64));
        let window_sec = self.report_interval_sec as i64;
        let window_min = (self.report_interval_sec / 60).max(1);

        let guard = match self.state.lock() {
            Ok(g) => g,
            Err(_) => return Vec::new(),
        };

        let mut items = Vec::with_capacity(targets.len());
        for target in targets {
            let samples = guard.history_24h.get(&target.target_ip);
            let item = build_single_ping_check(
                target,
                samples,
                now_sec,
                window_sec,
                window_min,
                self.pings_per_minute,
                self.retention_days,
                cache_meta,
            );
            items.push(item);
        }
        items
    }

    pub fn read_log_tail(&self, max_lines: usize) -> String {
        let Ok(file) = File::open(&self.log_path) else {
            return "Log ping belum tersedia (menunggu siklus pertama 1 menit).".to_string();
        };
        let reader = BufReader::new(file);
        let mut ring: VecDeque<String> = VecDeque::with_capacity(max_lines);
        for line in reader.lines().map_while(Result::ok) {
            if ring.len() == max_lines {
                ring.pop_front();
            }
            ring.push_back(line);
        }
        if ring.is_empty() {
            return "Log ping masih kosong.".to_string();
        }
        ring.into_iter().collect::<Vec<_>>().join("\n")
    }

    fn load_recent_from_log(&self) {
        let Ok(file) = File::open(&self.log_path) else {
            return;
        };
        let cutoff_24h = Local::now().timestamp() - 86_400;
        let reader = BufReader::new(file);
        let Ok(mut guard) = self.state.lock() else {
            return;
        };

        for line in reader.lines().map_while(Result::ok) {
            if let Some((ip, sample)) = parse_log_line(&line) {
                if sample.timestamp_sec >= cutoff_24h {
                    guard
                        .history_24h
                        .entry(ip)
                        .or_default()
                        .push_back(sample);
                }
            }
        }
    }

    fn append_log_lines(&self, lines: &[String], now_sec: i64) {
        if lines.is_empty() {
            return;
        }
        if let Some(parent) = self.log_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(mut file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log_path)
        {
            for line in lines {
                let _ = writeln!(file, "{}", line);
            }
        }

        let need_prune = if let Ok(mut guard) = self.state.lock() {
            if now_sec - guard.last_prune_epoch_sec >= 3600 {
                guard.last_prune_epoch_sec = now_sec;
                true
            } else {
                false
            }
        } else {
            false
        };

        if need_prune {
            self.prune_log_if_needed(now_sec);
        }
    }

    fn prune_log_if_needed(&self, now_sec: i64) {
        let Ok(meta) = std::fs::metadata(&self.log_path) else {
            return;
        };
        let retention_sec = (self.retention_days as i64) * 86_400;
        let cutoff = now_sec - retention_sec;

        // Selalu rapikan jika melewati 35 MB atau sekali per jam
        let over_size = meta.len() > MAX_LOG_BYTES;
        let Ok(file) = File::open(&self.log_path) else {
            return;
        };
        let reader = BufReader::new(file);
        let mut kept: Vec<String> = Vec::new();
        let mut dropped_any = false;

        for line in reader.lines().map_while(Result::ok) {
            if let Some((_, sample)) = parse_log_line(&line) {
                if sample.timestamp_sec >= cutoff {
                    kept.push(line);
                } else {
                    dropped_any = true;
                }
            }
        }

        if over_size && kept.len() > 10_000 {
            let start = kept.len() - 10_000;
            kept.drain(0..start);
            dropped_any = true;
        }

        if dropped_any {
            let tmp = self.log_path.with_extension("tmp");
            let mut content = kept.join("\n");
            if !content.is_empty() {
                content.push('\n');
            }
            if std::fs::write(&tmp, content).is_ok() {
                let _ = std::fs::rename(&tmp, &self.log_path);
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn build_single_ping_check(
    target: &PingTargetConfig,
    samples_opt: Option<&VecDeque<PingSample>>,
    now_sec: i64,
    window_sec: i64,
    window_min: u64,
    pings_per_minute: u32,
    retention_days: u64,
    cache_meta: Option<(i64, u64)>,
) -> LocalCheckItem {
    let cutoff_window = now_sec - window_sec;
    let empty = VecDeque::new();
    let samples = samples_opt.unwrap_or(&empty);

    let win_samples: Vec<&PingSample> = samples
        .iter()
        .filter(|s| s.timestamp_sec >= cutoff_window)
        .collect();

    if win_samples.is_empty() {
        return LocalCheckItem {
            state: 0,
            service_name: target.service_name.clone(),
            metrics: "-".to_string(),
            summary: format!(
                "Status : OK | Target : {} | Mode : 1h Summary (60x{}={} pkt) | Menunggu sampel pertama...",
                target.display_label,
                pings_per_minute,
                60 * pings_per_minute
            ),
            cache: cache_meta,
        };
    }

    let mut total_tx: u64 = 0;
    let mut total_rx: u64 = 0;
    let mut weighted_rtt: f64 = 0.0;
    let mut min_rtt = f64::INFINITY;
    let mut max_rtt = 0.0_f64;
    let mut timeout_minutes: u64 = 0;

    for s in &win_samples {
        total_tx += u64::from(s.tx);
        total_rx += u64::from(s.rx);
        if s.rx > 0 {
            weighted_rtt += s.avg_ms * f64::from(s.rx);
            if s.min_ms < min_rtt {
                min_rtt = s.min_ms;
            }
            if s.max_ms > max_rtt {
                max_rtt = s.max_ms;
            }
        } else {
            timeout_minutes += 1;
        }
    }

    let loss_pct = if total_tx > 0 {
        ((total_tx - total_rx) as f64 / total_tx as f64) * 100.0
    } else {
        100.0
    };
    let avg_ms = if total_rx > 0 {
        weighted_rtt / (total_rx as f64)
    } else {
        0.0
    };
    if !min_rtt.is_finite() {
        min_rtt = 0.0;
    }

    let last = win_samples.last().copied().unwrap();
    let last_loss_pct = if last.tx > 0 {
        ((last.tx.saturating_sub(last.rx)) as f64 / f64::from(last.tx)) * 100.0
    } else {
        last.loss_pct.clamp(0.0, 100.0)
    };
    let last_str = if last.rx > 0 {
        format!("{:.1} ms", last.avg_ms)
    } else {
        "TIMEOUT".to_string()
    };

    let first_ts = win_samples.first().map(|s| s.hh_mm.as_str()).unwrap_or("--:--");
    let last_ts = last.hh_mm.as_str();

    // Hitung ringkasan 24 jam
    let mut day_tx: u64 = 0;
    let mut day_rx: u64 = 0;
    let mut day_weighted: f64 = 0.0;
    let mut outages: Vec<String> = Vec::new();
    let mut in_outage_start: Option<String> = None;
    let mut in_outage_mins: u32 = 0;
    let mut prev_hhmm = String::new();
    let mut prev_ts_sec: i64 = 0;

    for s in samples {
        if let Some(start) = (in_outage_start.is_some()
            && prev_ts_sec > 0
            && s.timestamp_sec - prev_ts_sec > 180)
            .then(|| in_outage_start.take())
            .flatten()
        {
            outages.push(format_outage_span(&start, &prev_hhmm, in_outage_mins, false));
            in_outage_mins = 0;
        }

        day_tx += u64::from(s.tx);
        day_rx += u64::from(s.rx);
        if s.rx > 0 {
            day_weighted += s.avg_ms * f64::from(s.rx);
            if let Some(start) = in_outage_start.take() {
                outages.push(format_outage_span(&start, &prev_hhmm, in_outage_mins, false));
                in_outage_mins = 0;
            }
        } else if in_outage_start.is_none() {
            in_outage_start = Some(s.hh_mm.clone());
            in_outage_mins = 1;
        } else {
            in_outage_mins += 1;
        }
        prev_hhmm = s.hh_mm.clone();
        prev_ts_sec = s.timestamp_sec;
    }
    if let Some(start) = in_outage_start.take() {
        outages.push(format_outage_span(&start, &prev_hhmm, in_outage_mins, true));
    }

    let day_avg_ms = if day_rx > 0 {
        day_weighted / (day_rx as f64)
    } else {
        0.0
    };
    let day_loss_pct = if day_tx > 0 {
        ((day_tx - day_rx) as f64 / day_tx as f64) * 100.0
    } else {
        100.0
    };
    let outage_desc = if outages.is_empty() {
        "Stabil (0 Putus)".to_string()
    } else {
        let preview: Vec<&str> = outages.iter().rev().take(8).map(String::as_str).collect();
        format!("Putus {}x ({})", outages.len(), preview.join(", "))
    };

    let state = if total_rx == 0 || loss_pct >= 50.0 || avg_ms >= target.crit_ms {
        2
    } else if loss_pct >= 20.0 || avg_ms >= target.warn_ms {
        1
    } else {
        0
    };
    let status_label = match state {
        2 => "CRITICAL",
        1 => "WARNING",
        _ => "OK",
    };

    let perf = format!(
        "rta={:.4};{:.3};{:.3};0|pl={:.1}%;20;50;0;100|rtmin={:.4}|rtmax={:.4}|ping_loss_1m={:.1}%;25;100;0;100",
        avg_ms / 1000.0,
        target.warn_ms / 1000.0,
        target.crit_ms / 1000.0,
        loss_pct,
        min_rtt / 1000.0,
        max_rtt / 1000.0,
        last_loss_pct,
    );

    let pkt_expected = 60 * u64::from(pings_per_minute);
    let summary = format!(
        "Status : {} | Target : {} | Mode : 1h Summary (60x{}={} pkt) | Loss 1m : {:.0}% ({}/{} rx) | Loss 1h : {:.1}% ({}/{} rx) | Avg RTT : {:.1} ms | Min/Max : {:.1}/{:.1} ms | Last : {} | Timeout Min : {}/{} | Window : {}-{} | Log : {}d Rolling\nRerata Ping (24 Jam) : {:.1}ms (Loss {:.1}%) | Kondisi Jaringan (24 Jam, terbaru dulu) : {}",
        status_label,
        target.display_label,
        pings_per_minute,
        pkt_expected,
        last_loss_pct,
        last.rx,
        last.tx,
        loss_pct,
        total_rx,
        total_tx,
        avg_ms,
        min_rtt,
        max_rtt,
        last_str,
        timeout_minutes,
        window_min.max(win_samples.len() as u64),
        first_ts,
        last_ts,
        retention_days,
        day_avg_ms,
        day_loss_pct,
        outage_desc,
    );

    LocalCheckItem {
        state,
        service_name: target.service_name.clone(),
        metrics: perf,
        summary,
        cache: cache_meta,
    }
}

fn format_outage_span(start: &str, end: &str, mins: u32, active: bool) -> String {
    let suffix = if active { ", aktif" } else { "" };
    if start == end {
        format!("{} ({}m{})", start, mins.max(1), suffix)
    } else {
        format!("{}-{} ({}m{})", start, end, mins.max(1), suffix)
    }
}

fn sanitize_service_suffix(raw: &str) -> String {
    raw.trim()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn format_log_line(ts_str: &str, target_ip: &str, s: &PingSample) -> String {
    if s.rx > 0 {
        format!(
            "[{}] PING {:<18} | tx={} rx={} loss={:.0}% min={:.1}ms avg={:.1}ms max={:.1}ms",
            ts_str, target_ip, s.tx, s.rx, s.loss_pct, s.min_ms, s.avg_ms, s.max_ms
        )
    } else {
        format!(
            "[{}] PING {:<18} | tx={} rx=0 loss=100% TIMEOUT",
            ts_str, target_ip, s.tx
        )
    }
}

fn parse_log_line(line: &str) -> Option<(String, PingSample)> {
    let rest = line.strip_prefix('[')?;
    let end_bracket = rest.find(']')?;
    let ts_str = &rest[..end_bracket];
    let ndt = NaiveDateTime::parse_from_str(ts_str, "%Y-%m-%d %H:%M:%S").ok()?;
    let dt: DateTime<Local> = Local.from_local_datetime(&ndt).single()?;
    let ts_sec = dt.timestamp();
    let hh_mm = dt.format("%H:%M").to_string();

    let after = rest[end_bracket + 1..].trim_start();
    let after_ping = after.strip_prefix("PING")?.trim_start();
    let pipe_pos = after_ping.find('|')?;
    let ip = after_ping[..pipe_pos].trim().to_string();
    let metrics = after_ping[pipe_pos + 1..].trim();

    let mut tx = 4u32;
    let mut rx = 0u32;
    let mut loss_pct = 100.0;
    let mut min_ms = 0.0;
    let mut avg_ms = 0.0;
    let mut max_ms = 0.0;

    for token in metrics.split_whitespace() {
        if let Some(v) = token.strip_prefix("tx=") {
            tx = v.parse().unwrap_or(4);
        } else if let Some(v) = token.strip_prefix("rx=") {
            rx = v.parse().unwrap_or(0);
        } else if let Some(v) = token.strip_prefix("loss=") {
            loss_pct = v.trim_end_matches('%').parse().unwrap_or(100.0);
        } else if let Some(v) = token.strip_prefix("min=") {
            min_ms = v.trim_end_matches("ms").parse().unwrap_or(0.0);
        } else if let Some(v) = token.strip_prefix("avg=") {
            avg_ms = v.trim_end_matches("ms").parse().unwrap_or(0.0);
        } else if let Some(v) = token.strip_prefix("max=") {
            max_ms = v.trim_end_matches("ms").parse().unwrap_or(0.0);
        }
    }

    Some((
        ip,
        PingSample {
            timestamp_sec: ts_sec,
            hh_mm,
            tx,
            rx,
            loss_pct,
            min_ms,
            avg_ms,
            max_ms,
        },
    ))
}

#[cfg(target_os = "windows")]
pub fn execute_os_ping(target_ip: &str, count: u32, ts_sec: i64, hh_mm: &str) -> PingSample {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    let count_str = count.to_string();
    let output = Command::new("ping")
        .args(["-n", &count_str, "-w", "2000", target_ip])
        .creation_flags(CREATE_NO_WINDOW)
        .output();

    match output {
        Ok(out) => {
            let text = String::from_utf8_lossy(&out.stdout);
            parse_windows_ping_output(&text, count, ts_sec, hh_mm)
        }
        Err(_) => PingSample {
            timestamp_sec: ts_sec,
            hh_mm: hh_mm.to_string(),
            tx: count,
            rx: 0,
            loss_pct: 100.0,
            min_ms: 0.0,
            avg_ms: 0.0,
            max_ms: 0.0,
        },
    }
}

#[cfg(not(target_os = "windows"))]
pub fn execute_os_ping(target_ip: &str, count: u32, ts_sec: i64, hh_mm: &str) -> PingSample {
    let count_str = count.to_string();
    let ping_bin = if Path::new("/system/bin/ping").exists() {
        "/system/bin/ping"
    } else {
        "ping"
    };

    let output = Command::new(ping_bin)
        .args(["-c", &count_str, "-W", "2", target_ip])
        .env("LC_ALL", "C")
        .output();

    match output {
        Ok(out) => {
            let text = format!(
                "{}\n{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            parse_unix_ping_output(&text, count, ts_sec, hh_mm)
        }
        Err(_) => PingSample {
            timestamp_sec: ts_sec,
            hh_mm: hh_mm.to_string(),
            tx: count,
            rx: 0,
            loss_pct: 100.0,
            min_ms: 0.0,
            avg_ms: 0.0,
            max_ms: 0.0,
        },
    }
}

pub fn parse_unix_ping_output(
    text: &str,
    default_tx: u32,
    ts_sec: i64,
    hh_mm: &str,
) -> PingSample {
    let mut tx = default_tx;
    let mut rx = 0u32;
    let mut min_ms = 0.0;
    let mut avg_ms = 0.0;
    let mut max_ms = 0.0;
    let mut parsed_summary_rtt = false;
    let mut rtts: Vec<f64> = Vec::new();

    for line in text.lines() {
        let trimmed = line.trim();
        // Per-packet fallback: "time=28.9 ms" or "time=0.451ms"
        if let Some(idx) = trimmed.find("time=") {
            let after = &trimmed[idx + 5..];
            let num_str: String = after
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '.')
                .collect();
            if let Ok(v) = num_str.parse::<f64>() {
                rtts.push(v);
            }
        }
        if trimmed.contains("transmitted") && trimmed.contains("received") {
            let nums = extract_integers(trimmed);
            if nums.len() >= 2 {
                tx = nums[0].max(1);
                rx = nums[1].min(tx);
            }
        }
        // Summary line: "rtt min/avg/max/mdev = 21.1/34.5/49.5/10.2 ms"
        if (trimmed.contains("min/avg/max") || trimmed.contains("round-trip"))
            && trimmed.contains('=')
        {
            if let Some((_, rhs)) = trimmed.split_once('=') {
                let parts: Vec<&str> = rhs.trim().split('/').collect();
                if parts.len() >= 3 {
                    min_ms = parse_first_float(parts[0]).unwrap_or(0.0);
                    avg_ms = parse_first_float(parts[1]).unwrap_or(0.0);
                    max_ms = parse_first_float(parts[2]).unwrap_or(0.0);
                    parsed_summary_rtt = true;
                }
            }
        }
    }

    if rx == 0 && !rtts.is_empty() {
        rx = (rtts.len() as u32).min(tx);
    }
    if !parsed_summary_rtt && !rtts.is_empty() {
        min_ms = rtts.iter().copied().fold(f64::INFINITY, f64::min);
        max_ms = rtts.iter().copied().fold(0.0_f64, f64::max);
        avg_ms = rtts.iter().sum::<f64>() / (rtts.len() as f64);
    }

    let loss_pct = if tx > 0 {
        ((tx.saturating_sub(rx)) as f64 / tx as f64) * 100.0
    } else {
        100.0
    };

    PingSample {
        timestamp_sec: ts_sec,
        hh_mm: hh_mm.to_string(),
        tx,
        rx,
        loss_pct,
        min_ms,
        avg_ms,
        max_ms,
    }
}

pub fn parse_windows_ping_output(
    text: &str,
    default_tx: u32,
    ts_sec: i64,
    hh_mm: &str,
) -> PingSample {
    let mut tx = default_tx;
    let mut rx = 0u32;
    let mut rtts: Vec<f64> = Vec::new();
    let mut min_ms = 0.0;
    let mut max_ms = 0.0;
    let mut avg_ms = 0.0;
    let mut parsed_summary_rtt = false;

    for line in text.lines() {
        let trimmed = line.trim();
        let lower = trimmed.to_ascii_lowercase();

        // Reply line: "time=28ms" or "time<1ms" or Indonesian "waktu=28ms"
        if lower.contains("ttl=") {
            if lower.contains("time<1ms") || lower.contains("waktu<1ms") {
                rtts.push(0.5);
            } else {
                for key in ["time=", "waktu="] {
                    if let Some(pos) = lower.find(key) {
                        let sub = &trimmed[pos + key.len()..];
                        if let Some(v) = parse_first_float(sub) {
                            rtts.push(v);
                            break;
                        }
                    }
                }
            }
        }

        // Packets summary: "Packets: Sent = 4, Received = 4, Lost = 0 (0% loss)"
        if (lower.contains("sent =") && lower.contains("received ="))
            || (lower.contains("dikirim =") && lower.contains("diterima ="))
        {
            let nums = extract_integers(trimmed);
            if nums.len() >= 2 {
                tx = nums[0].max(1);
                rx = nums[1].min(tx);
            }
        }

        // RTT summary: "Minimum = 20ms, Maximum = 49ms, Average = 34ms"
        if (lower.contains("minimum") && lower.contains("maximum"))
            || (lower.contains("minimum") && lower.contains("rata"))
        {
            let nums = extract_integers(trimmed);
            if nums.len() >= 3 {
                min_ms = nums[0] as f64;
                max_ms = nums[1] as f64;
                avg_ms = nums[2] as f64;
                parsed_summary_rtt = true;
            }
        }
    }

    if rx == 0 && !rtts.is_empty() {
        rx = (rtts.len() as u32).min(tx);
    }
    if !parsed_summary_rtt && !rtts.is_empty() {
        min_ms = rtts.iter().copied().fold(f64::INFINITY, f64::min);
        max_ms = rtts.iter().copied().fold(0.0_f64, f64::max);
        avg_ms = rtts.iter().sum::<f64>() / (rtts.len() as f64);
    }

    let loss_pct = if tx > 0 {
        ((tx.saturating_sub(rx)) as f64 / tx as f64) * 100.0
    } else {
        100.0
    };

    PingSample {
        timestamp_sec: ts_sec,
        hh_mm: hh_mm.to_string(),
        tx,
        rx,
        loss_pct,
        min_ms,
        avg_ms,
        max_ms,
    }
}

fn extract_integers(s: &str) -> Vec<u32> {
    let mut out = Vec::new();
    let mut buf = String::new();
    for c in s.chars() {
        if c.is_ascii_digit() {
            buf.push(c);
        } else if !buf.is_empty() {
            if let Ok(n) = buf.parse::<u32>() {
                out.push(n);
            }
            buf.clear();
        }
    }
    if !buf.is_empty() {
        if let Ok(n) = buf.parse::<u32>() {
            out.push(n);
        }
    }
    out
}

fn parse_first_float(s: &str) -> Option<f64> {
    let trimmed = s.trim_start();
    let num_str: String = trimmed
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    if num_str.is_empty() {
        None
    } else {
        num_str.parse::<f64>().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_unix_and_windows_ping() {
        let unix = "\
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=115 time=28.1 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=115 time=29.5 ms
4 packets transmitted, 4 received, 0% packet loss, time 3005ms
rtt min/avg/max/mdev = 27.500/28.900/29.500/0.800 ms";
        let s1 = parse_unix_ping_output(unix, 4, 1700000000, "12:00");
        assert_eq!(s1.tx, 4);
        assert_eq!(s1.rx, 4);
        assert!((s1.avg_ms - 28.9).abs() < 0.01);

        let win = "\
Pinging 192.168.55.1 with 32 bytes of data:
Reply from 192.168.55.1: bytes=32 time<1ms TTL=64
Packets: Sent = 4, Received = 4, Lost = 0 (0% loss),
Minimum = 0ms, Maximum = 1ms, Average = 0ms";
        let s2 = parse_windows_ping_output(win, 4, 1700000000, "12:00");
        assert_eq!(s2.tx, 4);
        assert_eq!(s2.rx, 4);
        assert!((s2.max_ms - 1.0).abs() < 0.01);
    }

    #[test]
    fn test_format_and_parse_log_roundtrip() {
        let sample = PingSample {
            timestamp_sec: 1794533994,
            hh_mm: "08:39".to_string(),
            tx: 4,
            rx: 4,
            loss_pct: 0.0,
            min_ms: 20.5,
            avg_ms: 34.5,
            max_ms: 49.5,
        };
        let line = format_log_line("2026-11-13 08:39:54", "192.168.122.10", &sample);
        let (ip, parsed) = parse_log_line(&line).expect("parse log line");
        assert_eq!(ip, "192.168.122.10");
        assert_eq!(parsed.tx, 4);
        assert_eq!(parsed.rx, 4);
        assert!((parsed.avg_ms - 34.5).abs() < 0.05);
    }

    #[test]
    fn test_ping_check_emits_realtime_loss_1m_and_newest_outages() {
        let target = PingTargetConfig {
            key: "internet".to_string(),
            service_name: "Ping_8.8.8.8".to_string(),
            target_ip: "8.8.8.8".to_string(),
            display_label: "8.8.8.8".to_string(),
            warn_ms: 150.0,
            crit_ms: 300.0,
        };

        let make_sample = |ts: i64, hhmm: &str, rx: u32, avg: f64| PingSample {
            timestamp_sec: ts,
            hh_mm: hhmm.to_string(),
            tx: 4,
            rx,
            loss_pct: ((4 - rx) as f64 / 4.0) * 100.0,
            min_ms: if rx > 0 { 12.0 } else { 0.0 },
            avg_ms: if rx > 0 { avg } else { 0.0 },
            max_ms: if rx > 0 { 20.0 } else { 0.0 },
        };

        let ts_14_37 = 1_795_012_120;
        let ts_14_42 = ts_14_37 + 300;
        let mut samples = VecDeque::from(vec![
            make_sample(1_795_000_000, "11:15", 0, 0.0),
            make_sample(ts_14_37, "14:37", 4, 15.0),
            make_sample(ts_14_37 + 60, "14:38", 4, 15.0),
            make_sample(ts_14_37 + 120, "14:39", 0, 0.0),
            make_sample(ts_14_37 + 180, "14:40", 0, 0.0),
            make_sample(ts_14_37 + 240, "14:41", 0, 0.0),
            make_sample(ts_14_42, "14:42", 0, 0.0),
        ]);

        let during_outage =
            build_single_ping_check(&target, Some(&samples), ts_14_42, 3600, 60, 4, 30, None);
        assert!(during_outage.metrics.contains("pl="));
        assert!(during_outage
            .metrics
            .contains("ping_loss_1m=100.0%;25;100;0;100"));
        assert!(during_outage.summary.contains("Loss 1m : 100% (0/4 rx)"));
        assert!(during_outage
            .summary
            .contains("Putus 2x (14:39-14:42 (4m, aktif), 11:15 (1m))"));

        let ts_14_43 = ts_14_42 + 60;
        samples.push_back(make_sample(ts_14_43, "14:43", 4, 16.0));
        let after_recovery =
            build_single_ping_check(&target, Some(&samples), ts_14_43, 3600, 60, 4, 30, None);
        assert!(after_recovery
            .metrics
            .contains("ping_loss_1m=0.0%;25;100;0;100"));
        assert!(after_recovery.summary.contains("Loss 1m : 0% (4/4 rx)"));
        assert!(after_recovery
            .summary
            .contains("Putus 2x (14:39-14:42 (4m), 11:15 (1m))"));
    }
}
