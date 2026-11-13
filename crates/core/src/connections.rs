use std::collections::{BTreeMap, HashMap, HashSet};
use std::net::IpAddr;

use netstat2::{AddressFamilyFlags, ProtocolFlags, ProtocolSocketInfo, TcpState};
use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

use crate::interfaces;
use crate::model::{AppNetwork, Connection, InterfaceKind, LensError, ProxySettings, RemoteKind, Route, RouteSummary};
use crate::proxy;

pub(crate) struct Proc {
    pub name: String,
    pub parent: Option<u32>,
    pub exe: Option<String>,
}

struct TcpSocket {
    pid: u32,
    local: IpAddr,
    local_port: u16,
    remote: IpAddr,
    remote_port: u16,
    state: TcpState,
}

/// Все потомки процесса (helper-процессы, рендереры), без него самого.
pub fn descendants(pid: u32) -> Vec<u32> {
    let procs = processes();
    let mut out = Vec::new();
    let mut queue = vec![pid];
    while let Some(parent) = queue.pop() {
        for (child, p) in &procs {
            if p.parent == Some(parent) && *child != pid && !out.contains(child) {
                out.push(*child);
                queue.push(*child);
            }
        }
    }
    out
}

/// Снимок: процессы и сокеты на один момент.
pub(crate) struct Snapshot {
    procs: HashMap<u32, Proc>,
    sockets: Vec<TcpSocket>,
    owners: HashMap<IpAddr, (String, InterfaceKind)>,
}

impl Snapshot {
    pub fn take() -> Result<Self, LensError> {
        Ok(Self { procs: processes(), sockets: tcp_sockets()?, owners: interfaces::owners() })
    }

    /// Все приложения, у которых есть TCP-соединения, по убыванию числа соединений.
    pub fn apps(&self, settings: &ProxySettings) -> Vec<AppNetwork> {
        let clients = self.vpn_client_roots(settings);
        let mut groups: BTreeMap<u32, Vec<Connection>> = BTreeMap::new();
        for s in self.sockets.iter().filter(|s| is_live(s.state)) {
            groups.entry(root_of(s.pid, &self.procs)).or_default().push(self.connection(s, settings));
        }
        let mut apps: Vec<AppNetwork> = groups
            .into_iter()
            .map(|(root, conns)| build_app(root, conns, &self.procs, clients.contains(&root)))
            .collect();
        apps.sort_by_key(|a| std::cmp::Reverse(a.connections.len()));
        apps
    }

    pub fn app(&self, pid: u32, settings: &ProxySettings) -> AppNetwork {
        self.focus(pid, &self.apps(settings))
    }

    /// Приложение, которому принадлежит `pid`, из уже посчитанного списка.
    pub fn focus(&self, pid: u32, apps: &[AppNetwork]) -> AppNetwork {
        let root = root_of(pid, &self.procs);
        apps.iter().find(|a| a.pid == root).cloned().unwrap_or_else(|| build_app(root, Vec::new(), &self.procs, false))
    }

    /// Корневой процесс, который слушает порт локального прокси.
    pub fn proxy_owner(&self, settings: &ProxySettings) -> Option<u32> {
        let ports: HashSet<u16> =
            settings.endpoints.iter().filter(|e| proxy::is_local_host(&e.host)).map(|e| e.port).collect();
        let pid = self.sockets.iter().find(|s| s.state == TcpState::Listen && ports.contains(&s.local_port))?.pid;
        Some(root_of(pid, &self.procs))
    }

    pub fn name_of(&self, pid: u32) -> Option<String> {
        self.procs.get(&pid).map(|p| p.name.clone())
    }

    /// Процессы VPN-клиентов: владелец локального прокси, расширения Network Extension
    /// и известные демоны. Их соединения через физическую сеть - это сам туннель, не утечка.
    pub fn vpn_client_roots(&self, settings: &ProxySettings) -> HashSet<u32> {
        let mut roots: HashSet<u32> = self.proxy_owner(settings).into_iter().collect();
        for s in &self.sockets {
            let root = root_of(s.pid, &self.procs);
            let looks_like_client =
                [s.pid, root].iter().filter_map(|pid| self.procs.get(pid)).any(is_vpn_client_process);
            if looks_like_client {
                roots.insert(root);
            }
        }
        roots
    }

    fn connection(&self, s: &TcpSocket, settings: &ProxySettings) -> Connection {
        let remote_kind = remote_kind(s.remote, s.remote_port, settings);
        Connection {
            pid: s.pid,
            process: self.name_of(s.pid).unwrap_or_else(|| s.pid.to_string()),
            local_addr: s.local.to_string(),
            local_port: s.local_port,
            remote_addr: s.remote.to_string(),
            remote_port: s.remote_port,
            remote_kind,
            state: s.state.to_string(),
            route: route_for(s.local, remote_kind, &self.owners),
        }
    }
}

fn is_vpn_client_process(p: &Proc) -> bool {
    const NAMES: &[&str] = &["packettunnel", "networkextension", "openvpn", "wireguard", "tailscaled"];
    // Слова в пути расширения, по которым видно, что оно держит туннель или прокси.
    const EXTENSION_HINTS: &[&str] =
        &["tunnel", "vpn", "networkextension", "network-extension", "wireguard", "proxy", "tailscale"];

    let name = p.name.to_lowercase();
    if NAMES.iter().any(|k| name.contains(k)) {
        return true;
    }
    // Network Extension на macOS живёт в .appex или .systemextension. Но .appex - это ещё
    // и виджеты, расширения Safari, "Поделиться": их соединения напрямую - не туннель,
    // и прятать их под "VPN-клиент" нельзя. Поэтому смотрим на название расширения.
    let Some(exe) = p.exe.as_deref().map(str::to_lowercase) else { return false };
    let extension = [".appex/", ".systemextension/"].iter().find_map(|ext| {
        let end = exe.find(ext)?;
        Some(&exe[exe[..end].rfind('/').map_or(0, |i| i + 1)..end])
    });
    extension.is_some_and(|ext| EXTENSION_HINTS.iter().any(|hint| ext.contains(hint)))
}

/// Службы macOS: сами по себе не интересны, пока не ходят мимо VPN.
fn is_system_process(p: &Proc) -> bool {
    p.exe.as_deref().is_some_and(|exe| {
        ["/System/", "/usr/", "/Library/Apple/", "/sbin/"].iter().any(|prefix| exe.starts_with(prefix))
    })
}

fn build_app(
    root: u32,
    mut connections: Vec<Connection>,
    procs: &HashMap<u32, Proc>,
    is_vpn_client: bool,
) -> AppNetwork {
    connections.sort_by(|a, b| {
        (route_rank(&a.route), &a.remote_addr, a.remote_port).cmp(&(
            route_rank(&b.route),
            &b.remote_addr,
            b.remote_port,
        ))
    });
    let process_count = connections.iter().map(|c| c.pid).collect::<HashSet<_>>().len() as u32;
    let proc = procs.get(&root);
    AppNetwork {
        pid: root,
        name: proc.map_or_else(|| root.to_string(), |p| p.name.clone()),
        process_count,
        is_vpn_client,
        is_system: proc.is_some_and(is_system_process),
        summary: summarize(&connections),
        connections,
    }
}

fn route_rank(r: &Route) -> u8 {
    match r {
        Route::Physical { .. } => 0,
        Route::Proxy => 1,
        Route::Tunnel { .. } => 2,
        Route::Lan { .. } => 3,
        Route::Unknown => 4,
        Route::Loopback => 5,
    }
}

pub(crate) fn summarize(conns: &[Connection]) -> RouteSummary {
    let mut s = RouteSummary::default();
    for c in conns {
        match c.route {
            Route::Proxy => s.proxy += 1,
            Route::Tunnel { .. } => s.tunnel += 1,
            Route::Physical { .. } => s.physical += 1,
            Route::Lan { .. } => s.lan += 1,
            Route::Loopback | Route::Unknown => s.local += 1,
        }
    }
    s
}

fn remote_kind(remote: IpAddr, port: u16, settings: &ProxySettings) -> RemoteKind {
    let to_proxy = settings.endpoints.iter().any(|e| {
        e.port == port && (e.host == remote.to_string() || (proxy::is_local_host(&e.host) && remote.is_loopback()))
    });
    if to_proxy {
        RemoteKind::LocalProxy
    } else if remote.is_loopback() {
        RemoteKind::Loopback
    } else if is_fake_ip(&remote) {
        RemoteKind::TunnelFakeIp
    } else if is_private(&remote) {
        RemoteKind::Lan
    } else {
        RemoteKind::Public
    }
}

fn route_for(local: IpAddr, remote: RemoteKind, owners: &HashMap<IpAddr, (String, InterfaceKind)>) -> Route {
    match remote {
        RemoteKind::LocalProxy => return Route::Proxy,
        RemoteKind::Loopback => return Route::Loopback,
        _ => {}
    }
    let Some((iface, kind)) = owners.get(&local) else {
        return Route::Unknown;
    };
    let interface = iface.clone();
    match (remote, kind) {
        // Подменный адрес существует только внутри туннеля, каким бы ни был локальный адрес.
        (RemoteKind::TunnelFakeIp, _) | (_, InterfaceKind::Vpn) => Route::Tunnel { interface },
        (RemoteKind::Lan, _) => Route::Lan { interface },
        (_, InterfaceKind::Loopback) => Route::Loopback,
        _ => Route::Physical { interface },
    }
}

/// 198.18.0.0/15 (RFC 2544): этот диапазон туннели раздают как подменные адреса для доменов.
pub(crate) fn is_fake_ip(ip: &IpAddr) -> bool {
    matches!(ip, IpAddr::V4(v4) if v4.octets()[0] == 198 && (v4.octets()[1] & 0xfe) == 18)
}

pub(crate) fn is_private(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            // 100.64/10 - CGNAT, там же сидят Tailscale и часть провайдеров.
            v4.is_private() || v4.is_link_local() || (o[0] == 100 && (o[1] & 0xc0) == 64)
        }
        IpAddr::V6(v6) => {
            let first = v6.segments()[0];
            (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
        }
    }
}

fn is_live(state: TcpState) -> bool {
    !matches!(state, TcpState::Listen | TcpState::Closed | TcpState::TimeWait | TcpState::Unknown)
}

fn tcp_sockets() -> Result<Vec<TcpSocket>, LensError> {
    let af = AddressFamilyFlags::IPV4 | AddressFamilyFlags::IPV6;
    let iter = netstat2::iterate_sockets_info(af, ProtocolFlags::TCP).map_err(|e| LensError::System(e.to_string()))?;

    let mut out = Vec::new();
    // Чужие процессы (root, другие пользователи) могут не отдаться - пропускаем их, а не падаем.
    for info in iter.flatten() {
        let ProtocolSocketInfo::Tcp(tcp) = info.protocol_socket_info else {
            continue;
        };
        for pid in info.associated_pids {
            out.push(TcpSocket {
                pid,
                local: tcp.local_addr,
                local_port: tcp.local_port,
                remote: tcp.remote_addr,
                remote_port: tcp.remote_port,
                state: tcp.state,
            });
        }
    }
    Ok(out)
}

fn processes() -> HashMap<u32, Proc> {
    let Ok(mut sys) = System::new() else {
        return HashMap::new();
    };
    sys.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::nothing().with_exe(UpdateKind::OnlyIfNotSet),
    );
    sys.processes()
        .iter()
        .map(|(pid, p)| {
            (
                pid.as_u32(),
                Proc {
                    name: p.name().to_string_lossy().into_owned(),
                    parent: p.parent().map(|pp| pp.as_u32()),
                    exe: p.exe().map(|e| e.to_string_lossy().into_owned()),
                },
            )
        })
        .collect()
}

/// Поднимаемся по родителям до процесса, которого запустил launchd/init.
/// Helper-процессы браузера так склеиваются с самим браузером.
/// Ограничение: XPC-сервисы (сеть Safari живёт в com.apple.WebKit.Networking)
/// запускает launchd, и они остаются отдельным "приложением".
fn root_of(pid: u32, procs: &HashMap<u32, Proc>) -> u32 {
    let mut current = pid;
    for _ in 0..64 {
        match procs.get(&current).and_then(|p| p.parent) {
            Some(parent) if parent > 1 && procs.contains_key(&parent) => current = parent,
            _ => break,
        }
    }
    current
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{ProxyEndpoint, ProxyKind};

    fn proc(name: &str, parent: u32) -> Proc {
        Proc { name: name.into(), parent: Some(parent), exe: None }
    }

    #[test]
    fn ranges() {
        for ip in ["10.0.0.1", "192.168.1.1", "100.100.1.1", "fd00::1"] {
            assert!(is_private(&ip.parse().unwrap()), "{ip}");
        }
        for ip in ["1.1.1.1", "100.128.0.1", "2a00:1450::1", "198.18.0.14"] {
            assert!(!is_private(&ip.parse().unwrap()), "{ip}");
        }
        assert!(is_fake_ip(&"198.18.0.14".parse().unwrap()));
        assert!(is_fake_ip(&"198.19.255.1".parse().unwrap()));
        assert!(!is_fake_ip(&"198.20.0.1".parse().unwrap()));
    }

    #[test]
    fn routes() {
        let mut owners = HashMap::new();
        owners.insert("192.168.1.5".parse().unwrap(), ("en0".to_string(), InterfaceKind::Wifi));
        owners.insert("10.8.0.2".parse().unwrap(), ("utun4".to_string(), InterfaceKind::Vpn));
        let proxy = ProxySettings {
            endpoints: vec![ProxyEndpoint { kind: ProxyKind::Http, host: "127.0.0.1".into(), port: 1082 }],
            ..Default::default()
        };
        let route = |local: &str, remote: &str, port| {
            let kind = remote_kind(remote.parse().unwrap(), port, &proxy);
            route_for(local.parse().unwrap(), kind, &owners)
        };
        let en0 = || "en0".to_string();
        let utun = || "utun4".to_string();

        assert_eq!(route("127.0.0.1", "127.0.0.1", 1082), Route::Proxy);
        assert_eq!(route("127.0.0.1", "127.0.0.1", 5432), Route::Loopback);
        assert_eq!(route("10.8.0.2", "142.250.1.1", 443), Route::Tunnel { interface: utun() });
        assert_eq!(route("192.168.1.5", "142.250.1.1", 443), Route::Physical { interface: en0() });
        assert_eq!(route("192.168.1.5", "192.168.1.1", 80), Route::Lan { interface: en0() });
        assert_eq!(route("192.168.1.5", "198.18.0.14", 443), Route::Tunnel { interface: en0() });
    }

    #[test]
    fn roots() {
        let mut procs = HashMap::new();
        procs.insert(100, proc("Chrome", 1));
        procs.insert(200, proc("Helper", 100));
        procs.insert(300, proc("Renderer", 200));
        assert_eq!(root_of(300, &procs), 100);
        assert_eq!(root_of(100, &procs), 100);
        assert_eq!(root_of(999, &procs), 999);
    }

    #[test]
    fn vpn_clients() {
        let ext = Proc {
            name: "Something".into(),
            parent: Some(1),
            exe: Some("/Applications/X.app/Contents/PlugIns/Tunnel.appex/Contents/MacOS/Tunnel".into()),
        };
        assert!(is_vpn_client_process(&ext));
        // Виджет или расширение "Поделиться" - не VPN-клиент, даже если ходит в сеть.
        let widget = Proc {
            name: "WeatherWidget".into(),
            parent: Some(1),
            exe: Some("/Applications/X.app/Contents/PlugIns/WeatherWidget.appex/Contents/MacOS/WeatherWidget".into()),
        };
        assert!(!is_vpn_client_process(&widget));
        // Слово в пути приложения, а не расширения, не считается.
        let share = Proc {
            name: "Share".into(),
            parent: Some(1),
            exe: Some("/Applications/Some VPN.app/Contents/PlugIns/Share.appex/Contents/MacOS/Share".into()),
        };
        assert!(!is_vpn_client_process(&share));
        let sysext = Proc {
            name: "x".into(),
            parent: Some(1),
            exe: Some(
                "/Library/SystemExtensions/AB/com.example.vpn.network-extension.systemextension/Contents/MacOS/x"
                    .into(),
            ),
        };
        assert!(is_vpn_client_process(&sysext));
        assert!(is_vpn_client_process(&proc("ExamplePacketTunnel", 1)));
        assert!(is_vpn_client_process(&proc("openvpn", 1)));
        assert!(!is_vpn_client_process(&proc("Google Chrome", 1)));
    }

    #[test]
    fn system_services() {
        let with_exe = |exe: &str| Proc { name: "x".into(), parent: Some(1), exe: Some(exe.into()) };
        assert!(is_system_process(&with_exe("/usr/libexec/trustd")));
        assert!(is_system_process(&with_exe(
            "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd"
        )));
        assert!(!is_system_process(&with_exe("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")));
        assert!(!is_system_process(&proc("python", 1)));
    }
}
