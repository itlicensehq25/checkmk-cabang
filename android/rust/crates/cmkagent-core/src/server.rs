use crate::config::{normalize_remote_ip, AgentConfig};
use crate::stats::AgentStats;
use std::io::Write;
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};
use std::thread::{self, JoinHandle};
use std::time::Duration;

pub type PayloadProvider = Arc<dyn Fn() -> String + Send + Sync>;
pub type ConnectionHandler = Arc<
    dyn Fn(TcpStream, SocketAddr, &Arc<RwLock<AgentConfig>>, &Arc<AgentStats>, &PayloadProvider)
        + Send
        + Sync,
>;

pub struct PullServer {
    running: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl PullServer {
    pub fn start(
        config: Arc<RwLock<AgentConfig>>,
        stats: Arc<AgentStats>,
        payload_provider: PayloadProvider,
    ) -> std::io::Result<Self> {
        Self::start_with_handler(
            config,
            stats,
            payload_provider,
            Arc::new(|stream, peer_addr, cfg, st, prov| {
                handle_plain_client(stream, peer_addr, cfg, st, prov);
            }),
        )
    }

    pub fn start_with_handler(
        config: Arc<RwLock<AgentConfig>>,
        stats: Arc<AgentStats>,
        payload_provider: PayloadProvider,
        handler: ConnectionHandler,
    ) -> std::io::Result<Self> {
        let port = config
            .read()
            .map(|c| c.effective_port())
            .unwrap_or(crate::config::DEFAULT_PORT);
        let addr = SocketAddr::from(([0, 0, 0, 0], port));
        let listener = TcpListener::bind(addr)?;
        listener.set_nonblocking(true)?;

        let running = Arc::new(AtomicBool::new(true));
        let running_clone = Arc::clone(&running);

        let handle = thread::Builder::new()
            .name("cmkagent-tcp-6556".to_string())
            .spawn(move || {
                while running_clone.load(Ordering::Acquire) {
                    match listener.accept() {
                        Ok((stream, peer_addr)) => {
                            let _ = stream.set_nonblocking(false);
                            let _ = stream.set_nodelay(true);
                            let cfg_ref = Arc::clone(&config);
                            let stats_ref = Arc::clone(&stats);
                            let provider = Arc::clone(&payload_provider);
                            let conn_handler = Arc::clone(&handler);
                            thread::spawn(move || {
                                conn_handler(stream, peer_addr, &cfg_ref, &stats_ref, &provider);
                            });
                        }
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(120));
                        }
                        Err(_) => {
                            if !running_clone.load(Ordering::Acquire) {
                                break;
                            }
                            thread::sleep(Duration::from_millis(200));
                        }
                    }
                }
            })?;

        Ok(Self {
            running,
            handle: Some(handle),
        })
    }

    pub fn stop(&mut self) {
        self.running.store(false, Ordering::Release);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for PullServer {
    fn drop(&mut self) {
        self.stop();
    }
}

pub fn handle_plain_client(
    mut stream: TcpStream,
    peer_addr: SocketAddr,
    config: &Arc<RwLock<AgentConfig>>,
    stats: &Arc<AgentStats>,
    provider: &PayloadProvider,
) {
    let remote_ip = normalize_remote_ip(&peer_addr.ip().to_string());
    let allowed = config
        .read()
        .map(|c| c.is_client_allowed(&remote_ip))
        .unwrap_or(false);

    if !allowed {
        stats.record_rejected(&remote_ip);
        let _ = stream.shutdown(Shutdown::Both);
        return;
    }

    stats.record_accepted(&remote_ip);
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_nodelay(true);
    let _ = stream.set_write_timeout(Some(Duration::from_secs(15)));

    let payload = provider();
    let _ = stream.write_all(payload.as_bytes());
    let _ = stream.flush();
    let _ = stream.shutdown(Shutdown::Write);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::sync::Mutex;

    #[test]
    fn test_pull_server_accepted_stream_is_blocking() {
        let tmp_listener = TcpListener::bind("0.0.0.0:0").unwrap();
        let port = tmp_listener.local_addr().unwrap().port();
        drop(tmp_listener);
        assert_ne!(port, 0);

        let mut cfg = AgentConfig::default();
        cfg.agent.port = port;
        cfg.network.allow_all_private = true;

        let shared_cfg = Arc::new(RwLock::new(cfg));
        let stats = Arc::new(AgentStats::new());
        let provider: PayloadProvider = Arc::new(String::new);

        let result_slot: Arc<Mutex<Option<Result<[u8; 4], std::io::ErrorKind>>>> =
            Arc::new(Mutex::new(None));
        let slot_for_handler = Arc::clone(&result_slot);

        let handler: ConnectionHandler = Arc::new(move |mut stream, _peer, _cfg, _st, _prov| {
            let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
            let mut buf = [0u8; 4];
            let res = stream.read_exact(&mut buf).map(|()| buf).map_err(|e| e.kind());
            if let Ok(mut guard) = slot_for_handler.lock() {
                *guard = Some(res);
            }
        });

        let mut server =
            PullServer::start_with_handler(shared_cfg, stats, provider, handler).unwrap();

        let mut client = TcpStream::connect(("127.0.0.1", port)).unwrap();
        thread::sleep(Duration::from_millis(80));
        client.write_all(b"PING").unwrap();
        client.flush().unwrap();

        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        let observed = loop {
            if let Ok(guard) = result_slot.lock() {
                if let Some(res) = *guard {
                    break Some(res);
                }
            }
            if std::time::Instant::now() >= deadline {
                break None;
            }
            thread::sleep(Duration::from_millis(10));
        };

        server.stop();
        assert_eq!(observed, Some(Ok(*b"PING")));
    }
}
