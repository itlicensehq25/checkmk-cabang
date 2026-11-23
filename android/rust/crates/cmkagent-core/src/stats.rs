use chrono::{Local, TimeZone};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

#[derive(Debug)]
pub struct AgentStats {
    accepted_connections: AtomicU64,
    rejected_connections: AtomicU64,
    last_pull_epoch_ms: AtomicU64,
    last_client_ip: Mutex<String>,
    last_rejected_ip: Mutex<String>,

    push_success_count: AtomicU64,
    push_failure_count: AtomicU64,
    last_push_epoch_ms: AtomicU64,
    last_push_code: AtomicU64,
    last_push_result: Mutex<String>,
    last_push_error: Mutex<String>,
    tls_label: Mutex<String>,
}

#[derive(Debug, Clone, Default)]
pub struct StatsSnapshot {
    pub accepted_connections: u64,
    pub rejected_connections: u64,
    pub last_pull_epoch_ms: u64,
    pub last_client_ip: String,
    pub last_rejected_ip: String,
    pub push_success_count: u64,
    pub push_failure_count: u64,
    pub last_push_epoch_ms: u64,
    pub last_push_code: u64,
    pub last_push_result: String,
    pub last_push_error: String,
    pub tls_label: String,
}

impl Default for AgentStats {
    fn default() -> Self {
        Self::new()
    }
}

impl AgentStats {
    pub fn new() -> Self {
        Self {
            accepted_connections: AtomicU64::new(0),
            rejected_connections: AtomicU64::new(0),
            last_pull_epoch_ms: AtomicU64::new(0),
            last_client_ip: Mutex::new(String::new()),
            last_rejected_ip: Mutex::new(String::new()),
            push_success_count: AtomicU64::new(0),
            push_failure_count: AtomicU64::new(0),
            last_push_epoch_ms: AtomicU64::new(0),
            last_push_code: AtomicU64::new(0),
            last_push_result: Mutex::new("Belum pernah push".to_string()),
            last_push_error: Mutex::new(String::new()),
            tls_label: Mutex::new(String::new()),
        }
    }

    pub fn set_tls_label(&self, label: &str) {
        if let Ok(mut guard) = self.tls_label.lock() {
            *guard = label.to_string();
        }
    }

    pub fn record_accepted(&self, ip: &str) {
        self.accepted_connections.fetch_add(1, Ordering::Relaxed);
        let now_ms = Local::now().timestamp_millis().max(0) as u64;
        self.last_pull_epoch_ms.store(now_ms, Ordering::Relaxed);
        if let Ok(mut guard) = self.last_client_ip.lock() {
            *guard = ip.to_string();
        }
    }

    pub fn record_rejected(&self, ip: &str) {
        self.rejected_connections.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut guard) = self.last_rejected_ip.lock() {
            *guard = ip.to_string();
        }
    }

    pub fn record_push_success(&self, http_code: u16, detail: &str) {
        self.push_success_count.fetch_add(1, Ordering::Relaxed);
        let now_ms = Local::now().timestamp_millis().max(0) as u64;
        self.last_push_epoch_ms.store(now_ms, Ordering::Relaxed);
        self.last_push_code
            .store(u64::from(http_code), Ordering::Relaxed);
        if let Ok(mut guard) = self.last_push_result.lock() {
            *guard = detail.to_string();
        }
        if let Ok(mut guard) = self.last_push_error.lock() {
            guard.clear();
        }
    }

    pub fn record_push_failure(&self, http_code: u16, error: &str) {
        self.push_failure_count.fetch_add(1, Ordering::Relaxed);
        let now_ms = Local::now().timestamp_millis().max(0) as u64;
        self.last_push_epoch_ms.store(now_ms, Ordering::Relaxed);
        self.last_push_code
            .store(u64::from(http_code), Ordering::Relaxed);
        if let Ok(mut guard) = self.last_push_result.lock() {
            *guard = format!("ERROR: {}", error);
        }
        if let Ok(mut guard) = self.last_push_error.lock() {
            *guard = error.to_string();
        }
    }

    pub fn snapshot(&self) -> StatsSnapshot {
        StatsSnapshot {
            accepted_connections: self.accepted_connections.load(Ordering::Relaxed),
            rejected_connections: self.rejected_connections.load(Ordering::Relaxed),
            last_pull_epoch_ms: self.last_pull_epoch_ms.load(Ordering::Relaxed),
            last_client_ip: self
                .last_client_ip
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default(),
            last_rejected_ip: self
                .last_rejected_ip
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default(),
            push_success_count: self.push_success_count.load(Ordering::Relaxed),
            push_failure_count: self.push_failure_count.load(Ordering::Relaxed),
            last_push_epoch_ms: self.last_push_epoch_ms.load(Ordering::Relaxed),
            last_push_code: self.last_push_code.load(Ordering::Relaxed),
            last_push_result: self
                .last_push_result
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default(),
            last_push_error: self
                .last_push_error
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default(),
            tls_label: self
                .tls_label
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default(),
        }
    }
}

pub fn format_epoch_ms_and_age(epoch_ms: u64) -> (String, String) {
    if epoch_ms == 0 {
        return ("N/A".to_string(), "N/A".to_string());
    }
    let sec = (epoch_ms / 1000) as i64;
    let formatted = Local
        .timestamp_opt(sec, 0)
        .single()
        .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
        .unwrap_or_else(|| "N/A".to_string());

    let now_ms = Local::now().timestamp_millis().max(0) as u64;
    let diff_min = now_ms.saturating_sub(epoch_ms) / 60_000;
    let age = if diff_min < 60 {
        format!("{}m ago", diff_min)
    } else {
        format!("{}h {}m ago", diff_min / 60, diff_min % 60)
    };
    (formatted, age)
}
