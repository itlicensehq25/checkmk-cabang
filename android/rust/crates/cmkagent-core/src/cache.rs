use chrono::{DateTime, Datelike, Duration, Local, NaiveTime, TimeZone, Timelike, Weekday};
use std::path::Path;
use std::time::UNIX_EPOCH;

/// Mengembalikan epoch second dari waktu anchor harian terakhir (mis. hari ini jam 16:00,
/// atau kemarin jam 16:00 jika saat ini belum mencapai jam 16:00).
pub fn most_recent_daily_anchor(now: DateTime<Local>, hour: u32, minute: u32) -> i64 {
    let target_time = NaiveTime::from_hms_opt(hour, minute, 0).unwrap_or_default();
    let today_target = now.date_naive().and_time(target_time);
    let today_dt = Local
        .from_local_datetime(&today_target)
        .single()
        .unwrap_or(now);
    if now.time() >= target_time {
        today_dt.timestamp()
    } else {
        let yesterday_target = (now.date_naive() - Duration::days(1)).and_time(target_time);
        Local
            .from_local_datetime(&yesterday_target)
            .single()
            .map(|dt| dt.timestamp())
            .unwrap_or_else(|| today_dt.timestamp() - 86_400)
    }
}

/// Mengembalikan epoch second dari waktu anchor mingguan terakhir (mis. Sabtu jam 11:00).
pub fn most_recent_weekly_anchor(
    now: DateTime<Local>,
    weekday: Weekday,
    hour: u32,
    minute: u32,
) -> i64 {
    let target_time = NaiveTime::from_hms_opt(hour, minute, 0).unwrap_or_default();
    let current_wd = now.weekday().num_days_from_monday() as i64;
    let target_wd = weekday.num_days_from_monday() as i64;
    let mut days_back = (current_wd - target_wd).rem_euclid(7);
    if days_back == 0 && (now.hour(), now.minute()) < (hour, minute) {
        days_back = 7;
    }
    let anchor_date = now.date_naive() - Duration::days(days_back);
    let anchor_naive = anchor_date.and_time(target_time);
    Local
        .from_local_datetime(&anchor_naive)
        .single()
        .map(|dt| dt.timestamp())
        .unwrap_or_else(|| now.timestamp() - days_back * 86_400)
}

pub fn file_mtime_epoch(path: &Path) -> Option<i64> {
    let meta = std::fs::metadata(path).ok()?;
    let modified = meta.modified().ok()?;
    let dur = modified.duration_since(UNIX_EPOCH).ok()?;
    Some(dur.as_secs() as i64)
}

fn is_older_than_running_exe(cache_mtime: i64) -> bool {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_mtime) = file_mtime_epoch(&exe) {
            return cache_mtime < exe_mtime;
        }
    }
    false
}

pub fn read_cached_if_fresh_daily(path: &Path, hour: u32, minute: u32) -> Option<String> {
    let mtime = file_mtime_epoch(path)?;
    if is_older_than_running_exe(mtime) {
        return None;
    }
    let anchor = most_recent_daily_anchor(Local::now(), hour, minute);
    if mtime >= anchor {
        let content = std::fs::read_to_string(path).ok()?;
        if !content.trim().is_empty() {
            return Some(content);
        }
    }
    None
}

pub fn read_cached_if_fresh_weekly(
    path: &Path,
    weekday: Weekday,
    hour: u32,
    minute: u32,
) -> Option<String> {
    let mtime = file_mtime_epoch(path)?;
    if is_older_than_running_exe(mtime) {
        return None;
    }
    let anchor = most_recent_weekly_anchor(Local::now(), weekday, hour, minute);
    if mtime >= anchor {
        let content = std::fs::read_to_string(path).ok()?;
        if !content.trim().is_empty() {
            return Some(content);
        }
    }
    None
}

pub fn write_cache_file(path: &Path, content: &str) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("tmp");
    if std::fs::write(&tmp, content).is_ok() && std::fs::rename(&tmp, path).is_ok() {
        return;
    }
    let _ = std::fs::write(path, content);
}
