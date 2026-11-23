use crate::config::AgentConfig;
use crate::stats::{format_epoch_ms_and_age, StatsSnapshot};
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub struct LocalCheckItem {
    /// 0 = OK, 1 = WARN, 2 = CRIT, 3 = UNKNOWN
    pub state: u8,
    pub service_name: String,
    /// Checkmk perfdata atau "-" jika tidak ada metrik
    pub metrics: String,
    /// Deskripsi singkat + opsional detail setelah '\n'
    pub summary: String,
    /// None -> `<<<local:sep(0)>>>`; Some((epoch_sec, ttl_sec)) -> `<<<local:cached(epoch,ttl):sep(0)>>>`
    pub cache: Option<(i64, u64)>,
}

impl LocalCheckItem {
    pub fn format_line(&self) -> String {
        let safe_name: String = self
            .service_name
            .trim()
            .chars()
            .filter(|&c| c != '\r' && c != '\n' && c != '"')
            .collect();

        let safe_metrics = {
            let m = self.metrics.trim();
            if m.is_empty() {
                "-".to_string()
            } else {
                m.replace(['\r', '\n'], " ")
            }
        };

        // Checkmk local:sep(0) memakai literal "\n" untuk detail baris berikutnya
        let safe_summary = self
            .summary
            .replace("\r\n", "\n")
            .replace('\r', "")
            .replace('\n', "\\n");

        format!(
            "{} \"{}\" {} {}",
            self.state.min(3),
            safe_name,
            safe_metrics,
            safe_summary
        )
    }
}

#[derive(Debug, Clone, Default)]
pub struct AgentOutputInput {
    pub hostname: String,
    pub agent_os: String,
    pub reported_version: String,
    /// Section Checkmk mentah seperti ("<<<uptime>>>", "12345") atau ("<<<dmidecode:sep(58)>>>", "...")
    pub raw_sections: Vec<(String, String)>,
    pub local_checks: Vec<LocalCheckItem>,
}

pub fn build_checkmk_payload(input: &AgentOutputInput) -> String {
    let mut out = String::with_capacity(4096);
    out.push_str("<<<check_mk>>>\n");
    out.push_str(&format!("Version: {}\n", input.reported_version));
    out.push_str(&format!("AgentOS: {}\n", input.agent_os));
    out.push_str(&format!("Hostname: {}\n", input.hostname));

    for (header, body) in &input.raw_sections {
        let trimmed = body.trim_end();
        if trimmed.is_empty() {
            continue;
        }
        out.push_str(header.trim());
        out.push('\n');
        out.push_str(trimmed);
        out.push('\n');
    }

    let mut live_items: Vec<&LocalCheckItem> = Vec::new();
    let mut cached_groups: BTreeMap<(i64, u64), Vec<&LocalCheckItem>> = BTreeMap::new();

    for item in &input.local_checks {
        if item.service_name.trim().is_empty() {
            continue;
        }
        match item.cache {
            None => live_items.push(item),
            Some(key) => cached_groups.entry(key).or_default().push(item),
        }
    }

    if !live_items.is_empty() {
        out.push_str("<<<local:sep(0)>>>\n");
        for item in live_items {
            out.push_str(&item.format_line());
            out.push('\n');
        }
    }

    for ((epoch, ttl), items) in cached_groups {
        out.push_str(&format!("<<<local:cached({},{}):sep(0)>>>\n", epoch, ttl));
        for item in items {
            out.push_str(&item.format_line());
            out.push('\n');
        }
    }

    out
}

pub fn build_agent_status_check(config: &AgentConfig, stats: &StatsSnapshot) -> LocalCheckItem {
    let (last_pull_str, last_pull_age) = format_epoch_ms_and_age(stats.last_pull_epoch_ms);
    let last_client = if stats.last_client_ip.is_empty() {
        "N/A".to_string()
    } else {
        stats.last_client_ip.clone()
    };

    let mode = if config.push.enabled && !config.push.url.trim().is_empty() {
        "Hybrid (pull primary + push backup)"
    } else {
        "Pull primary"
    };

    let tls_suffix = if stats.tls_label.trim().is_empty() {
        String::new()
    } else {
        format!(" | TLS : {}", stats.tls_label.trim())
    };

    let summary = format!(
        "Status : OK | Version : {} | Last Pull : {} ({}) | Last Client : {} | Allowed : {} | Collection : {}{}",
        config.effective_status_version(),
        last_pull_str,
        last_pull_age,
        last_client,
        config.allowed_mode_label(),
        mode,
        tls_suffix
    );

    let metrics = format!(
        "connections={}|rejected={}",
        stats.accepted_connections, stats.rejected_connections
    );

    LocalCheckItem {
        state: 0,
        service_name: "Agent_Status".to_string(),
        metrics,
        summary,
        cache: None,
    }
}

pub fn build_transport_status_check(
    config: &AgentConfig,
    stats: &StatsSnapshot,
    cache_meta: Option<(i64, u64)>,
) -> LocalCheckItem {
    let push_enabled = config.push.enabled && !config.push.url.trim().is_empty();
    let receiver = if config.push.url.trim().is_empty() {
        "Not configured".to_string()
    } else {
        config.push.url.trim().to_string()
    };
    let (last_push_str, last_push_age) = format_epoch_ms_and_age(stats.last_push_epoch_ms);
    let http_code_str = if stats.last_push_code > 0 {
        stats.last_push_code.to_string()
    } else {
        "N/A".to_string()
    };
    let detail = if stats.last_push_error.is_empty() {
        if push_enabled {
            "OK".to_string()
        } else {
            "-".to_string()
        }
    } else {
        stats.last_push_error.clone()
    };

    let state = if !push_enabled || stats.last_push_error.is_empty() {
        0
    } else {
        1
    };
    let status_label = if state == 0 { "OK" } else { "WARNING" };

    let summary = format!(
        "Status : {} | Primary : PULL | Backup : PUSH HTTP(S) | Receiver : {} | Push Interval : {} sec | Last Push : {} ({}) | Last Push Result : {} | HTTP Code : {} | Detail : {}",
        status_label,
        receiver,
        config.push.interval_sec,
        last_push_str,
        last_push_age,
        stats.last_push_result,
        http_code_str,
        detail
    );

    let metrics = format!(
        "push_success={}|push_failure={}",
        stats.push_success_count, stats.push_failure_count
    );

    LocalCheckItem {
        state,
        service_name: "Transport_Status".to_string(),
        metrics,
        summary,
        cache: cache_meta,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_checkmk_payload_sections_and_escaping() {
        let input = AgentOutputInput {
            hostname: "BCPKDR-TEST".to_string(),
            agent_os: "linux".to_string(),
            reported_version: "Agen BMS : 1.0.2".to_string(),
            raw_sections: vec![("<<<uptime>>>".to_string(), "12345.00 98765.00".to_string())],
            local_checks: vec![
                LocalCheckItem {
                    state: 0,
                    service_name: "Info_CPU".to_string(),
                    metrics: "load=10%;85;95;0;100".to_string(),
                    summary: "Spesifikasi : i3-14100\nBaris 2".to_string(),
                    cache: None,
                },
                LocalCheckItem {
                    state: 0,
                    service_name: "Info_OS".to_string(),
                    metrics: "-".to_string(),
                    summary: "OK - OS: Linux Mint 22.3".to_string(),
                    cache: Some((1794500000, 86400)),
                },
            ],
        };

        let out = build_checkmk_payload(&input);
        assert!(out.contains("<<<check_mk>>>\nVersion: Agen BMS : 1.0.2\nAgentOS: linux\nHostname: BCPKDR-TEST\n"));
        assert!(out.contains("<<<uptime>>>\n12345.00 98765.00\n"));
        assert!(out.contains("<<<local:sep(0)>>>\n0 \"Info_CPU\" load=10%;85;95;0;100 Spesifikasi : i3-14100\\nBaris 2\n"));
        assert!(out.contains("<<<local:cached(1794500000,86400):sep(0)>>>\n0 \"Info_OS\" - OK - OS: Linux Mint 22.3\n"));
    }

    #[test]
    fn test_agent_status_hides_port_and_formats_version() {
        let cfg = AgentConfig::default();
        let snap = StatsSnapshot {
            accepted_connections: 5,
            rejected_connections: 0,
            last_pull_epoch_ms: 1795060011000,
            last_client_ip: "192.168.55.112".to_string(),
            ..Default::default()
        };
        let item = build_agent_status_check(&cfg, &snap);
        assert_eq!(cfg.effective_version(), "Agen BMS : 1.3.8");
        assert!(item.summary.starts_with("Status : OK | Version : 1.3.8 | Last Pull : "));
        assert!(item.summary.contains(" | Last Client : 192.168.55.112 | Allowed : Open | Collection : Pull primary"));
        assert!(!item.summary.contains("Port"));
        assert!(!item.summary.contains("6556"));
    }
}
