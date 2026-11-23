use chrono::Local;
use cmkagent_core::checkmk::{
    build_agent_status_check, build_checkmk_payload, build_transport_status_check, AgentOutputInput,
    LocalCheckItem,
};
use cmkagent_core::config::{normalize_remote_ip, AgentConfig};
use cmkagent_core::ping::PingMonitor;
use cmkagent_core::server::{PayloadProvider, PullServer};
use cmkagent_core::stats::{format_epoch_ms_and_age, AgentStats};
use jni::objects::{JClass, JString};
use jni::sys::{jboolean, jint, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, RwLock};

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct AndroidConfigPayload {
    hostname: String,
    port: u16,
    reported_version: String,
    allowed_servers: String,
    allow_all_private: bool,
    gateway_ip: String,
    push_enabled: bool,
    push_url: String,
    push_token: String,
    push_interval_sec: u64,
    ping_enabled: bool,
    local_ping_target: String,
    internet_ping_target: String,
    hw_sw_inventory: bool,
}

impl AndroidConfigPayload {
    fn into_core_config(self) -> AgentConfig {
        let mut cfg = AgentConfig::default();
        cfg.agent.hostname = self.hostname;
        cfg.agent.port = if self.port == 0 { 6556 } else { self.port };
        cfg.agent.agent_os = "android".to_string();
        if !self.reported_version.trim().is_empty() {
            cfg.agent.reported_version = self.reported_version;
        }
        cfg.network.allowed_servers = self.allowed_servers;
        cfg.network.allow_all_private = self.allow_all_private;
        cfg.network.gateway_ip = self.gateway_ip;
        cfg.push.enabled = self.push_enabled;
        cfg.push.url = self.push_url;
        cfg.push.token = self.push_token;
        cfg.push.interval_sec = self.push_interval_sec.max(60);
        cfg.ping.enabled = self.ping_enabled;
        if !self.local_ping_target.trim().is_empty() {
            cfg.ping.local_target = self.local_ping_target;
        }
        if !self.internet_ping_target.trim().is_empty() {
            cfg.ping.internet_target = self.internet_ping_target;
        }
        cfg.sections.hw_sw_inventory = self.hw_sw_inventory;
        cfg.sections.transport_status = true;
        cfg
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct AndroidLocalCheckInput {
    state: u8,
    service_name: String,
    metrics: String,
    summary: String,
    cache_ttl_sec: Option<u64>,
    cache_epoch_sec: Option<i64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct AndroidRawSectionInput {
    header: String,
    body: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct AndroidSnapshotPayload {
    hostname: String,
    gateway_ip: String,
    raw_sections: Vec<AndroidRawSectionInput>,
    local_checks: Vec<AndroidLocalCheckInput>,
}

#[derive(Debug, Serialize)]
struct StatsJsonOut {
    accepted_connections: u64,
    rejected_connections: u64,
    last_pull_str: String,
    last_pull_age: String,
    last_client_ip: String,
    last_rejected_ip: String,
    push_success_count: u64,
    push_failure_count: u64,
    last_push_str: String,
    last_push_age: String,
    last_push_code: u64,
    last_push_result: String,
    last_push_error: String,
}

struct RuntimeState {
    config: Arc<RwLock<AgentConfig>>,
    stats: Arc<AgentStats>,
    ping: Mutex<Arc<PingMonitor>>,
    snapshot: Mutex<AndroidSnapshotPayload>,
    data_dir: Mutex<PathBuf>,
    server: Mutex<Option<PullServer>>,
}

static RUNTIME: OnceLock<RuntimeState> = OnceLock::new();

fn runtime() -> &'static RuntimeState {
    RUNTIME.get_or_init(|| {
        let cfg = AgentConfig::default();
        let dir = PathBuf::from("/data/local/tmp/cmkagent");
        let ping = Arc::new(PingMonitor::new(&dir, &cfg.ping));
        RuntimeState {
            config: Arc::new(RwLock::new(cfg)),
            stats: Arc::new(AgentStats::new()),
            ping: Mutex::new(ping),
            snapshot: Mutex::new(AndroidSnapshotPayload::default()),
            data_dir: Mutex::new(dir),
            server: Mutex::new(None),
        }
    })
}

fn jstr_to_string(env: &mut JNIEnv, s: JString) -> String {
    if s.is_null() {
        return String::new();
    }
    env.get_string(&s)
        .map(|js| js.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn string_to_jstr(env: &mut JNIEnv, s: &str) -> jstring {
    match env.new_string(s) {
        Ok(js) => js.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn build_android_payload(rt: &RuntimeState) -> String {
    let cfg = rt.config.read().expect("config lock").clone();
    let stats_snap = rt.stats.snapshot();
    let snap = rt
        .snapshot
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default();
    let ping = rt.ping.lock().map(|g| Arc::clone(&*g)).ok();

    let hostname = cfg.resolved_hostname(&snap.hostname);
    let now_sec = Local::now().timestamp();

    let mut local_checks = Vec::new();
    if cfg.sections.agent_status {
        local_checks.push(build_agent_status_check(&cfg, &stats_snap));
    }

    if cfg.ping.enabled {
        if let Some(ref p) = ping {
            let gw = if cfg.network.gateway_ip.trim().is_empty() {
                snap.gateway_ip.as_str()
            } else {
                cfg.network.gateway_ip.trim()
            };
            let targets = PingMonitor::build_targets(&cfg.ping, gw);
            local_checks.extend(p.build_local_checks(&targets));
        }
    }

    for item in snap.local_checks {
        let cache = item.cache_ttl_sec.map(|ttl| {
            let epoch = item.cache_epoch_sec.unwrap_or(now_sec);
            (epoch, ttl)
        });
        local_checks.push(LocalCheckItem {
            state: item.state,
            service_name: item.service_name,
            metrics: item.metrics,
            summary: item.summary,
            cache,
        });
    }

    if cfg.sections.transport_status || cfg.push.enabled {
        local_checks.push(build_transport_status_check(
            &cfg,
            &stats_snap,
            Some((now_sec, 10_800)),
        ));
    }

    let raw_sections = if cfg.sections.hw_sw_inventory {
        snap.raw_sections
            .into_iter()
            .map(|r| (r.header, r.body))
            .collect()
    } else {
        Vec::new()
    };

    build_checkmk_payload(&AgentOutputInput {
        hostname,
        agent_os: "android".to_string(),
        reported_version: cfg.effective_version().to_string(),
        raw_sections,
        local_checks,
    })
}

#[no_mangle]
pub extern "system" fn Java_com_bcp_checkmkagent_NativeBridge_startPullServer(
    mut env: JNIEnv,
    _class: JClass,
    config_json: JString,
    data_dir: JString,
) -> jboolean {
    let cfg_str = jstr_to_string(&mut env, config_json);
    let dir_str = jstr_to_string(&mut env, data_dir);
    let rt = runtime();

    if let Ok(parsed) = serde_json::from_str::<AndroidConfigPayload>(&cfg_str) {
        let core_cfg = parsed.into_core_config();
        if let Ok(mut w) = rt.config.write() {
            *w = core_cfg;
        }
    }

    let path = PathBuf::from(if dir_str.trim().is_empty() {
        "/data/local/tmp/cmkagent"
    } else {
        dir_str.trim()
    });
    let _ = std::fs::create_dir_all(&path);
    if let Ok(mut d) = rt.data_dir.lock() {
        *d = path.clone();
    }
    if let Ok(mut p) = rt.ping.lock() {
        let cfg_snap = rt.config.read().expect("config lock").ping.clone();
        *p = Arc::new(PingMonitor::new(&path, &cfg_snap));
    }

    if let Ok(mut srv_guard) = rt.server.lock() {
        if let Some(mut old) = srv_guard.take() {
            old.stop();
        }
        let provider: PayloadProvider = Arc::new(|| build_android_payload(runtime()));
        match PullServer::start(Arc::clone(&rt.config), Arc::clone(&rt.stats), provider) {
            Ok(server) => {
                *srv_guard = Some(server);
                return JNI_TRUE;
            }
            Err(_) => return JNI_FALSE,
        }
    }
    JNI_FALSE
}

#[no_mangle]
pub extern "system" fn Java_com_bcp_checkmkagent_NativeBridge_stopPullServer(
    _env: JNIEnv,
    _class: JClass,
) {
    let rt = runtime();
    if let Ok(mut guard) = rt.server.lock() {
        if let Some(mut old) = guard.take() {
            old.stop();
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_com_bcp_checkmkagent_NativeBridge_updateConfig(
    mut env: JNIEnv,
    _class: JClass,
    config_json: JString,
) {
    let cfg_str = jstr_to_string(&mut env, config_json);
    if let Ok(parsed) = serde_json::from_str::<AndroidConfigPayload>(&cfg_str) {
        let core_cfg = parsed.into_core_config();
        let rt = runtime();
        if let Ok(mut w) = rt.config.write() {
            *w = core_cfg;
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_com_bcp_checkmkagent_NativeBridge_updateSnapshot(
    mut env: JNIEnv,
    _class: JClass,
    snapshot_json: JString,
) {
    let raw = jstr_to_string(&mut env, snapshot_json);
    if let Ok(parsed) = serde_json::from_str::<AndroidSnapshotPayload>(&raw) {
        let rt = runtime();
        if let Ok(mut g) = rt.snapshot.lock() {
            *g = parsed;
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_com_bcp_checkmkagent_NativeBridge_collectPingSample(
    mut env: JNIEnv,
    _class: JClass,
    gateway_ip: JString,
) {
    let gw = jstr_to_string(&mut env, gateway_ip);
    let rt = runtime();
    let cfg = rt.config.read().expect("config lock").ping.clone();
    if !cfg.enabled {
        return;
    }
    let ping = rt.ping.lock().map(|g| Arc::clone(&*g)).ok();
    if let Some(p) = ping {
        let targets = PingMonitor::build_targets(&cfg, &gw);
        p.collect_minute_sample(&targets);
    }
}

#[no_mangle]
pub extern "system" fn Java_com_bcp_checkmkagent_NativeBridge_buildFullPayload(
    mut env: JNIEnv,
    _class: JClass,
) -> jstring {
    let payload = build_android_payload(runtime());
    string_to_jstr(&mut env, &payload)
}

#[no_mangle]
pub extern "system" fn Java_com_bcp_checkmkagent_NativeBridge_readPingLogTail(
    mut env: JNIEnv,
    _class: JClass,
    max_lines: jint,
) -> jstring {
    let rt = runtime();
    let lines = max_lines.max(1) as usize;
    let text = rt
        .ping
        .lock()
        .map(|p| p.read_log_tail(lines))
        .unwrap_or_else(|_| "Ping monitor belum siap.".to_string());
    string_to_jstr(&mut env, &text)
}

#[no_mangle]
pub extern "system" fn Java_com_bcp_checkmkagent_NativeBridge_getStatsJson(
    mut env: JNIEnv,
    _class: JClass,
) -> jstring {
    let snap = runtime().stats.snapshot();
    let (last_pull_str, last_pull_age) = format_epoch_ms_and_age(snap.last_pull_epoch_ms);
    let (last_push_str, last_push_age) = format_epoch_ms_and_age(snap.last_push_epoch_ms);

    let out = StatsJsonOut {
        accepted_connections: snap.accepted_connections,
        rejected_connections: snap.rejected_connections,
        last_pull_str,
        last_pull_age,
        last_client_ip: snap.last_client_ip,
        last_rejected_ip: snap.last_rejected_ip,
        push_success_count: snap.push_success_count,
        push_failure_count: snap.push_failure_count,
        last_push_str,
        last_push_age,
        last_push_code: snap.last_push_code,
        last_push_result: snap.last_push_result,
        last_push_error: snap.last_push_error,
    };
    let json = serde_json::to_string(&out).unwrap_or_else(|_| "{}".to_string());
    string_to_jstr(&mut env, &json)
}

#[no_mangle]
pub extern "system" fn Java_com_bcp_checkmkagent_NativeBridge_recordPushResult(
    mut env: JNIEnv,
    _class: JClass,
    success: jboolean,
    http_code: jint,
    detail: JString,
) {
    let msg = jstr_to_string(&mut env, detail);
    let code = http_code.clamp(0, 999) as u16;
    if success != JNI_FALSE {
        runtime().stats.record_push_success(code, &msg);
    } else {
        runtime().stats.record_push_failure(code, &msg);
    }
}

#[no_mangle]
pub extern "system" fn Java_com_bcp_checkmkagent_NativeBridge_normalizeRemoteIp(
    mut env: JNIEnv,
    _class: JClass,
    ip: JString,
) -> jstring {
    let raw = jstr_to_string(&mut env, ip);
    let clean = normalize_remote_ip(&raw);
    string_to_jstr(&mut env, &clean)
}

#[no_mangle]
pub extern "system" fn Java_com_bcp_checkmkagent_NativeBridge_isClientAllowed(
    mut env: JNIEnv,
    _class: JClass,
    config_json: JString,
    remote_ip: JString,
) -> jboolean {
    let cfg_str = jstr_to_string(&mut env, config_json);
    let ip = jstr_to_string(&mut env, remote_ip);
    let core_cfg = serde_json::from_str::<AndroidConfigPayload>(&cfg_str)
        .map(AndroidConfigPayload::into_core_config)
        .unwrap_or_default();
    if core_cfg.is_client_allowed(&ip) {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}
