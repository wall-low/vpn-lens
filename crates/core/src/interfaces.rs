use std::collections::{BTreeMap, HashMap};
use std::net::IpAddr;

use crate::model::{InterfaceKind, NetInterface};

/// Все интерфейсы с осмысленными адресами, в порядке: Wi-Fi/Ethernet, VPN, остальное.
pub fn list() -> Vec<NetInterface> {
    let Ok(addrs) = if_addrs::get_if_addrs() else {
        return Vec::new();
    };
    let names = platform_names();

    let mut by_name: BTreeMap<String, NetInterface> = BTreeMap::new();
    for a in addrs {
        let ip = a.ip();
        if is_link_local(&ip) {
            continue;
        }
        let entry = by_name.entry(a.name.clone()).or_insert_with(|| {
            let (kind, display_name) = classify(&a.name, &names);
            NetInterface { name: a.name.clone(), display_name, kind, ipv4: Vec::new(), ipv6: Vec::new() }
        });
        match ip {
            IpAddr::V4(v4) => entry.ipv4.push(v4.to_string()),
            IpAddr::V6(v6) => entry.ipv6.push(v6.to_string()),
        }
    }

    let mut list: Vec<_> = by_name.into_values().collect();
    list.sort_by_key(|i| {
        let rank = match i.kind {
            InterfaceKind::Wifi | InterfaceKind::Ethernet => 0,
            InterfaceKind::Vpn => 1,
            InterfaceKind::Other => 2,
            InterfaceKind::Loopback => 3,
        };
        (rank, i.name.clone())
    });
    list
}

/// Туннельные интерфейсы с адресами, только по именам: без SystemConfiguration,
/// поэтому быстро. Link-local не считаем: у macOS есть системные utun0-3 только с ними.
pub fn tunnel_names() -> Vec<String> {
    let mut names: Vec<String> = if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter(|a| !is_link_local(&a.ip()) && kind_by_name(&a.name) == InterfaceKind::Vpn)
        .map(|a| a.name)
        .collect();
    names.sort();
    names.dedup();
    names
}

/// Локальный IP -> (интерфейс, тип). Нужен, чтобы понять, через что ушло соединение.
pub fn owners() -> HashMap<IpAddr, (String, InterfaceKind)> {
    let names = platform_names();
    if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .map(|a| {
            let (kind, _) = classify(&a.name, &names);
            (a.ip(), (a.name, kind))
        })
        .collect()
}

fn is_link_local(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_link_local(),
        IpAddr::V6(v6) => (v6.segments()[0] & 0xffc0) == 0xfe80,
    }
}

fn classify(name: &str, platform: &HashMap<String, (InterfaceKind, String)>) -> (InterfaceKind, Option<String>) {
    if let Some((kind, display)) = platform.get(name) {
        return (*kind, Some(display.clone()));
    }
    (kind_by_name(name), None)
}

/// Эвристика по имени, когда ОС не сказала тип сама.
fn kind_by_name(name: &str) -> InterfaceKind {
    let n = name.to_ascii_lowercase();
    let starts = |prefixes: &[&str]| prefixes.iter().any(|p| n.starts_with(p));

    if starts(&["lo"]) {
        InterfaceKind::Loopback
    } else if starts(&["utun", "tun", "tap", "wg", "ipsec", "ppp", "nordlynx", "proton"]) {
        InterfaceKind::Vpn
    } else if starts(&["wlan", "wlp", "wl"]) || n.contains("wi-fi") || n.contains("wireless") {
        InterfaceKind::Wifi
    } else if starts(&["eth", "enp", "eno", "ens", "en"]) || n.contains("ethernet") {
        // На macOS en* бывает и Wi-Fi, но там тип приходит из SystemConfiguration раньше.
        InterfaceKind::Ethernet
    } else {
        InterfaceKind::Other
    }
}

#[cfg(target_os = "macos")]
fn platform_names() -> HashMap<String, (InterfaceKind, String)> {
    use system_configuration::network_configuration::{SCNetworkInterfaceType as T, get_interfaces};

    let mut map = HashMap::new();
    for iface in get_interfaces().iter() {
        let Some(bsd) = iface.bsd_name() else { continue };
        let kind = match iface.interface_type() {
            Some(T::IEEE80211) => InterfaceKind::Wifi,
            Some(T::Ethernet) => InterfaceKind::Ethernet,
            Some(T::IPSec | T::L2TP | T::PPP | T::PPTP) => InterfaceKind::Vpn,
            _ => kind_by_name(&bsd.to_string()),
        };
        let display = iface.display_name().map(|s| s.to_string()).unwrap_or_else(|| bsd.to_string());
        map.insert(bsd.to_string(), (kind, display));
    }
    map
}

#[cfg(not(target_os = "macos"))]
fn platform_names() -> HashMap<String, (InterfaceKind, String)> {
    // TODO: Windows (GetAdaptersAddresses -> IfType), Linux (/sys/class/net/*/wireless).
    HashMap::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(kind_by_name("utun4"), InterfaceKind::Vpn);
        assert_eq!(kind_by_name("wg0"), InterfaceKind::Vpn);
        assert_eq!(kind_by_name("wlp3s0"), InterfaceKind::Wifi);
        assert_eq!(kind_by_name("enp0s31f6"), InterfaceKind::Ethernet);
        assert_eq!(kind_by_name("lo0"), InterfaceKind::Loopback);
        assert_eq!(kind_by_name("Wi-Fi"), InterfaceKind::Wifi);
    }

    #[test]
    fn link_local() {
        assert!(is_link_local(&"fe80::1".parse().unwrap()));
        assert!(is_link_local(&"169.254.3.4".parse().unwrap()));
        assert!(!is_link_local(&"192.168.1.5".parse().unwrap()));
    }
}
