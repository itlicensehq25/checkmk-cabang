use serde::{Deserialize, Serialize};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::{Path, PathBuf};

pub const DEFAULT_PORT: u16 = 6556;
pub const DEFAULT_AGENT_VERSION: &str = "1.3.8";
pub const DEFAULT_REPORTED_VERSION: &str = "Agen BMS : 1.3.8";
pub const DEFAULT_RELEASE_REPO: &str = "Dot-Dodik/public-rilis";
pub const DEFAULT_UPDATE_INTERVAL_SEC: u64 = 14_400; // 4 jam

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct AgentConfig {
    pub agent: AgentSection,
    pub network: NetworkSection,
    pub ping: PingSection,
    pub push: PushSection,
    pub update: UpdateSection,
    pub tls: TlsSection,
    pub sections: SectionsConfig,
    pub paths: PathsConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AgentSection {
    pub hostname: String,
    pub port: u16,
    pub agent_os: String,
    pub reported_version: String,
}

impl Default for AgentSection {
    fn default() -> Self {
        Self {
            hostname: String::new(),
            port: DEFAULT_PORT,
            agent_os: String::new(),
            reported_version: DEFAULT_REPORTED_VERSION.to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct NetworkSection {
    /// Kosongkan atau "*" untuk perilaku terbuka seperti agent Windows/Linux.
    pub allowed_servers: String,
    /// Jika true, semua IP private RFC1918 (10/8, 172.16/12, 192.168/16),
    /// CGNAT/VPN (100.64/10), dan loopback selalu diizinkan (anti NAT/MikroTik block).
    pub allow_all_private: bool,
    /// Kosong = auto-detect default gateway OS.
    pub gateway_ip: String,
}

impl Default for NetworkSection {
    fn default() -> Self {
        Self {
            allowed_servers: String::new(),
            allow_all_private: true,
            gateway_ip: String::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct PingSection {
    pub enabled: bool,
    pub local_target: String,
    pub internet_target: String,
    pub pings_per_minute: u32,
    pub report_interval_sec: u64,
    pub log_retention_days: u64,
    pub local_warn_ms: f64,
    pub local_crit_ms: f64,
    pub internet_warn_ms: f64,
    pub internet_crit_ms: f64,
    pub gateway_warn_ms: f64,
    pub gateway_crit_ms: f64,
}

impl Default for PingSection {
    fn default() -> Self {
        Self {
            enabled: true,
            local_target: "192.168.122.10".to_string(),
            internet_target: "8.8.8.8".to_string(),
            pings_per_minute: 4,
            report_interval_sec: 3600,
            log_retention_days: 30,
            local_warn_ms: 100.0,
            local_crit_ms: 250.0,
            internet_warn_ms: 150.0,
            internet_crit_ms: 300.0,
            gateway_warn_ms: 50.0,
            gateway_crit_ms: 150.0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct PushSection {
    pub enabled: bool,
    pub url: String,
    pub token: String,
    pub interval_sec: u64,
}

impl Default for PushSection {
    fn default() -> Self {
        Self {
            enabled: false,
            url: String::new(),
            token: String::new(),
            interval_sec: 300,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct UpdateSection {
    pub enabled: bool,
    pub repo: String,
    pub release_tag: String,
    pub mirror_base_url: String,
    pub interval_sec: u64,
    pub allow_restart: bool,
}

impl Default for UpdateSection {
    fn default() -> Self {
        Self {
            enabled: true,
            repo: DEFAULT_RELEASE_REPO.to_string(),
            release_tag: "auto-latest".to_string(),
            mirror_base_url: String::new(),
            interval_sec: DEFAULT_UPDATE_INTERVAL_SEC,
            allow_restart: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct SectionsConfig {
    // Built-in Checkmk sections (dibatasi agar tidak memicu puluhan discovery clutter)
    pub uptime: bool,
    pub cpu_load: bool,
    pub cpu_util: bool,
    pub memory: bool,
    pub win_license: bool,
    pub hw_sw_inventory: bool,

    // Custom/local checks standar Anda
    pub agent_status: bool,
    pub transport_status: bool,
    pub cpu_info: bool,
    pub fan_health: bool,
    pub battery_health: bool,
    pub ram_usage: bool,
    pub ram_health: bool,
    pub storage_usage: bool,
    pub storage_health: bool,
    pub network_info: bool,
    pub os_office_info: bool,
    pub remote_support: bool,
}

impl Default for SectionsConfig {
    fn default() -> Self {
        Self {
            uptime: true,
            cpu_load: true,
            cpu_util: true,
            memory: true,
            win_license: true,
            hw_sw_inventory: true,
            agent_status: true,
            transport_status: false,
            cpu_info: true,
            fan_health: true,
            battery_health: true,
            ram_usage: true,
            ram_health: true,
            storage_usage: true,
            storage_health: true,
            network_info: true,
            os_office_info: true,
            remote_support: true,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct PathsConfig {
    pub data_dir: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct TlsSection {
    /// "auto" (wajib mTLS jika terdaftar, fallback plain jika belum),
    /// "required" (selalu tolak plain TCP jika belum terdaftar),
    /// atau "disabled" (paksa plain TCP).
    pub mode: String,
    /// Otomatis salin & impor registered_connections.json milik Checkmk agent bawaan saat install/start.
    pub auto_import_legacy: bool,
    /// Otomatis perbarui sertifikat sebelum masa berlaku habis (< 45 hari) atau kurang ekstensi AKI (Checkmk 3.0).
    pub auto_renew: bool,
}

impl Default for TlsSection {
    fn default() -> Self {
        Self {
            mode: "auto".to_string(),
            auto_import_legacy: true,
            auto_renew: true,
        }
    }
}

impl TlsSection {
    pub fn effective_mode(&self) -> &'static str {
        match self.mode.trim().to_ascii_lowercase().as_str() {
            "required" | "strict" | "enforce" => "required",
            "disabled" | "off" | "plain" | "false" => "disabled",
            _ => "auto",
        }
    }
}

impl AgentConfig {
    pub fn load_or_default(path: Option<&Path>) -> Self {
        let Some(p) = path else {
            return Self::default();
        };
        match std::fs::read_to_string(p) {
            Ok(content) => toml::from_str::<AgentConfig>(&content).unwrap_or_else(|e| {
                eprintln!("[cmkagent] Gagal parse config {:?}: {} (memakai default)", p, e);
                Self::default()
            }),
            Err(_) => Self::default(),
        }
    }

    pub fn from_toml_str(content: &str) -> Result<Self, toml::de::Error> {
        toml::from_str(content)
    }

    pub fn default_os_name() -> &'static str {
        if cfg!(target_os = "android") {
            "android"
        } else if cfg!(target_os = "windows") {
            "windows"
        } else if cfg!(target_os = "linux") {
            "linux"
        } else {
            std::env::consts::OS
        }
    }

    pub fn effective_agent_os(&self) -> String {
        let trimmed = self.agent.agent_os.trim();
        if trimmed.is_empty() {
            Self::default_os_name().to_string()
        } else {
            trimmed.to_string()
        }
    }

    pub fn effective_port(&self) -> u16 {
        if self.agent.port == 0 {
            DEFAULT_PORT
        } else {
            self.agent.port
        }
    }

    pub fn effective_version(&self) -> &str {
        let trimmed = self.agent.reported_version.trim();
        if trimmed.is_empty() || trimmed == "2.0.0" {
            DEFAULT_REPORTED_VERSION
        } else {
            trimmed
        }
    }

    pub fn effective_status_version(&self) -> &str {
        let ver = self.effective_version();
        ver.strip_prefix("Agen BMS :")
            .or_else(|| ver.strip_prefix("Agen BMS"))
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(DEFAULT_AGENT_VERSION)
    }

    pub fn resolved_hostname(&self, system_hostname: &str) -> String {
        let candidate = if self.agent.hostname.trim().is_empty() {
            system_hostname
        } else {
            self.agent.hostname.trim()
        };
        sanitize_hostname(candidate)
    }

    pub fn resolved_data_dir(&self) -> PathBuf {
        let custom = self.paths.data_dir.trim();
        if !custom.is_empty() {
            return PathBuf::from(custom);
        }
        if cfg!(target_os = "windows") {
            PathBuf::from(r"C:\ProgramData\cmkagent")
        } else {
            PathBuf::from("/var/lib/cmkagent")
        }
    }

    pub fn allowed_mode_label(&self) -> String {
        let raw = self.network.allowed_servers.trim();
        let has_wildcard = raw
            .split(|c: char| c == ',' || c.is_whitespace())
            .any(|t| matches!(t.trim(), "*" | "0.0.0.0" | "0.0.0.0/0"));
        if has_wildcard {
            return "Open".to_string();
        }
        if raw.is_empty() {
            if self.network.allow_all_private {
                "Open".to_string()
            } else {
                "Loopback only".to_string()
            }
        } else if self.network.allow_all_private {
            format!("{} + Open", raw)
        } else {
            raw.to_string()
        }
    }

    /// Resolves the active GitHub release repository, migrating the legacy private source repo
    /// (`Dot-Dodik/cmkagent-rust`) transparently to `Dot-Dodik/public-rilis`.
    pub fn effective_update_repo(&self) -> &str {
        let trimmed = self.update.repo.trim().trim_matches('/');
        if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("Dot-Dodik/cmkagent-rust") {
            DEFAULT_RELEASE_REPO
        } else {
            trimmed
        }
    }

    pub fn is_client_allowed(&self, remote_ip: &str) -> bool {
        let clean = normalize_remote_ip(remote_ip);
        if clean.is_empty() {
            return false;
        }

        let raw = self.network.allowed_servers.trim();
        let tokens: Vec<&str> = raw
            .split(|c: char| c == ',' || c.is_whitespace())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .collect();

        if tokens
            .iter()
            .any(|&t| t == "*" || t == "0.0.0.0" || t == "0.0.0.0/0")
        {
            return true;
        }

        if self.network.allow_all_private && is_private_or_internal_ip(&clean) {
            return true;
        }

        if tokens.is_empty() {
            return clean == "127.0.0.1" || clean == "::1";
        }

        for token in tokens {
            let norm_token = normalize_remote_ip(token);
            if norm_token == clean || matches_cidr(&clean, token) {
                return true;
            }
        }
        false
    }
}

pub fn sanitize_hostname(raw: &str) -> String {
    let cleaned: String = raw
        .trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
        .collect();
    if cleaned.is_empty() {
        "CMKAGENT-HOST".to_string()
    } else {
        cleaned
    }
}

/// Menghapus kurung IPv6 `[...]`, scope interface `%wlan0`, dan memetakan
/// IPv4-mapped IPv6 (`::ffff:192.168.x.x`) ke bentuk IPv4 murni.
pub fn normalize_remote_ip(ip: &str) -> String {
    let mut s = ip.trim();
    if let Some(stripped) = s.strip_prefix('[') {
        if let Some(end) = stripped.find(']') {
            s = &stripped[..end];
        }
    }
    if let Some(idx) = s.find('%') {
        s = &s[..idx];
    }
    if s.len() > 7 && s[..7].eq_ignore_ascii_case("::ffff:") {
        s = &s[7..];
    }
    if let Ok(IpAddr::V6(v6)) = s.parse::<IpAddr>() {
        if let Some(v4) = ipv6_mapped_to_v4(v6) {
            return v4.to_string();
        }
    }
    s.to_string()
}

fn ipv6_mapped_to_v4(v6: Ipv6Addr) -> Option<Ipv4Addr> {
    let octets = v6.octets();
    if octets[..10] == [0u8; 10] && octets[10] == 0xff && octets[11] == 0xff {
        Some(Ipv4Addr::new(octets[12], octets[13], octets[14], octets[15]))
    } else {
        None
    }
}

pub fn is_private_or_internal_ip(ip: &str) -> bool {
    let clean = normalize_remote_ip(ip);
    let Ok(addr) = clean.parse::<IpAddr>() else {
        return false;
    };
    match addr {
        IpAddr::V4(v4) => is_private_v4(v4),
        IpAddr::V6(v6) => {
            if let Some(v4) = ipv6_mapped_to_v4(v6) {
                return is_private_v4(v4);
            }
            if v6.is_loopback() {
                return true;
            }
            let seg0 = v6.segments()[0];
            // fe80::/10 link-local atau fc00::/7 ULA
            (seg0 & 0xffc0) == 0xfe80 || (seg0 & 0xfe00) == 0xfc00
        }
    }
}

fn is_private_v4(v4: Ipv4Addr) -> bool {
    let o = v4.octets();
    // 10.0.0.0/8 (RFC1918)
    o[0] == 10
        // 172.16.0.0/12 (RFC1918)
        || (o[0] == 172 && (16..=31).contains(&o[1]))
        // 192.168.0.0/16 (RFC1918)
        || (o[0] == 192 && o[1] == 168)
        // 100.64.0.0/10 (CGNAT / VPN / Tailscale)
        || (o[0] == 100 && (64..=127).contains(&o[1]))
        // 127.0.0.0/8 (Loopback)
        || o[0] == 127
        // 169.254.0.0/16 (Link-local)
        || (o[0] == 169 && o[1] == 254)
}

pub fn matches_cidr(ip: &str, cidr: &str) -> bool {
    let Some((net_raw, prefix_raw)) = cidr.split_once('/') else {
        return false;
    };
    let Ok(prefix) = prefix_raw.trim().parse::<u32>() else {
        return false;
    };
    let Ok(target_ip) = normalize_remote_ip(ip).parse::<IpAddr>() else {
        return false;
    };
    let Ok(net_ip) = normalize_remote_ip(net_raw).parse::<IpAddr>() else {
        return false;
    };
    match (target_ip, net_ip) {
        (IpAddr::V4(t), IpAddr::V4(n)) if prefix <= 32 => {
            let mask = if prefix == 0 {
                0u32
            } else {
                !0u32 << (32 - prefix)
            };
            (u32::from(t) & mask) == (u32::from(n) & mask)
        }
        (IpAddr::V6(t), IpAddr::V6(n)) if prefix <= 128 => {
            let mask = if prefix == 0 {
                0u128
            } else {
                !0u128 << (128 - prefix)
            };
            (u128::from(t) & mask) == (u128::from(n) & mask)
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_and_private_ip_rfc1918() {
        assert_eq!(normalize_remote_ip("::ffff:192.168.108.1"), "192.168.108.1");
        assert_eq!(normalize_remote_ip("fe80::1%wlan0"), "fe80::1");
        assert!(is_private_or_internal_ip("192.168.108.1"));
        assert!(is_private_or_internal_ip("192.168.146.1"));
        assert!(is_private_or_internal_ip("::ffff:192.168.55.112"));
        assert!(is_private_or_internal_ip("10.10.2.5"));
        assert!(is_private_or_internal_ip("172.16.0.1"));
        assert!(is_private_or_internal_ip("172.31.255.254"));
        assert!(is_private_or_internal_ip("100.64.0.10"));
        assert!(!is_private_or_internal_ip("8.8.8.8"));
        assert!(!is_private_or_internal_ip("172.32.0.1"));
    }

    #[test]
    fn test_client_allowed_mikrotik_nat_bypass() {
        let mut cfg = AgentConfig::default();
        cfg.network.allowed_servers = "192.168.55.112".to_string();
        cfg.network.allow_all_private = true;
        // NAT MikroTik depo tetap lolos
        assert!(cfg.is_client_allowed("::ffff:192.168.108.1"));
        assert!(cfg.is_client_allowed("192.168.146.1"));
        assert!(!cfg.is_client_allowed("1.2.3.4"));

        // Mode ketat jika allow_all_private dimatikan
        cfg.network.allow_all_private = false;
        assert!(cfg.is_client_allowed("192.168.55.112"));
        assert!(!cfg.is_client_allowed("192.168.108.1"));

        // CIDR match
        cfg.network.allowed_servers = "192.168.55.0/24".to_string();
        assert!(cfg.is_client_allowed("192.168.55.112"));
        assert!(!cfg.is_client_allowed("192.168.56.10"));
    }

    #[test]
    fn test_tls_section_defaults_and_toml_deserialization() {
        // Tanpa [tls] section -> memakai nilai default aman
        let cfg_omitted = AgentConfig::from_toml_str("[agent]\nport = 6556\n").unwrap();
        assert_eq!(cfg_omitted.tls.effective_mode(), "auto");
        assert!(cfg_omitted.tls.auto_import_legacy);
        assert!(cfg_omitted.tls.auto_renew);

        // Dengan [tls] section -> parsing varian mode yang didukung
        let cfg_req = AgentConfig::from_toml_str(
            "[tls]\nmode = \"required\"\nauto_import_legacy = false\nauto_renew = false\n",
        )
        .unwrap();
        assert_eq!(cfg_req.tls.effective_mode(), "required");
        assert!(!cfg_req.tls.auto_import_legacy);
        assert!(!cfg_req.tls.auto_renew);

        let cfg_dis = AgentConfig::from_toml_str("[tls]\nmode = \"disabled\"\n").unwrap();
        assert_eq!(cfg_dis.tls.effective_mode(), "disabled");
    }
}
