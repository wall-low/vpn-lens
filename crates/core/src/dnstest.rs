//! Внешний DNS-тест: настоящие запросы к уникальным поддоменам bash.ws, после чего
//! сервис говорит, какие DNS-серверы к нему за ними пришли. Только по кнопке:
//! сервис видит ваш адрес и адреса ваших DNS-серверов.

use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

use serde::Deserialize;
use ureq::Agent;

use crate::model::{CheckStatus, DnsLeakResult, DnsServer, DnsServerKind, Lang, LensError};

const SERVICE: &str = "bash.ws";
const LOOKUPS: u32 = 6;

#[derive(Deserialize)]
struct Entry {
    ip: String,
    #[serde(default)]
    country: String,
    #[serde(default)]
    asn: String,
    #[serde(default)]
    org: String,
    #[serde(rename = "type")]
    kind: String,
}

pub fn run(lang: Lang) -> Result<DnsLeakResult, LensError> {
    let agent: Agent = Agent::config_builder().timeout_global(Some(Duration::from_secs(10))).build().new_agent();
    let get = |url: &str| -> Result<String, LensError> {
        agent
            .get(url)
            .call()
            .and_then(|mut r| r.body_mut().read_to_string())
            .map_err(|e| LensError::Network(e.to_string()))
    };

    let id = get(&format!("https://{SERVICE}/id"))?.trim().to_string();
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Err(LensError::Network("the service returned an unexpected id".into()));
    }

    // Туннели с подменными адресами (fake-IP) не спрашивают настоящий DNS, пока к имени
    // не подключились. Поэтому не только резолвим, но и стучимся на 80 порт.
    std::thread::scope(|s| {
        for i in 1..=LOOKUPS {
            let host = format!("{i}.{id}.{SERVICE}");
            s.spawn(move || touch(&host));
        }
    });
    // Сервису нужно мгновение, чтобы записать пришедшие запросы.
    std::thread::sleep(Duration::from_millis(800));

    let body = get(&format!("https://{SERVICE}/dnsleak/test/{id}?json"))?;
    let entries: Vec<Entry> = serde_json::from_str(&body).map_err(|_| {
        LensError::Network(if body.contains("No DNS servers") {
            "DNS queries did not reach the service".into()
        } else {
            "unexpected response from the service".into()
        })
    })?;
    Ok(judge(&entries, lang))
}

/// Резолвим имя и делаем HTTP-запрос: туннель с подменными адресами идёт в настоящий
/// DNS только тогда, когда открывает соединение наружу, а не в момент резолва.
fn touch(host: &str) {
    use std::io::{Read, Write};
    let Some(addr) = (host, 80).to_socket_addrs().ok().and_then(|mut a| a.next()) else {
        return;
    };
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, Duration::from_secs(2)) else {
        return;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = write!(stream, "GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n");
    let _ = stream.read(&mut [0u8; 256]);
}

fn judge(entries: &[Entry], l: Lang) -> DnsLeakResult {
    let exit = entries.iter().find(|e| e.kind == "ip");
    let exit_asn = exit.map(|e| e.asn.as_str()).unwrap_or_default();
    let servers: Vec<DnsServer> = entries
        .iter()
        .filter(|e| e.kind == "dns")
        .map(|e| DnsServer {
            ip: e.ip.clone(),
            country_code: (!e.country.is_empty()).then(|| e.country.to_uppercase()),
            org: if e.org.is_empty() { e.asn.clone() } else { e.org.clone() },
            kind: if !exit_asn.is_empty() && e.asn == exit_asn {
                DnsServerKind::SameAsVpn
            } else if is_public_resolver(&e.asn) {
                DnsServerKind::Public
            } else {
                DnsServerKind::Other
            },
        })
        .collect();

    let others: Vec<&DnsServer> = servers.iter().filter(|s| s.kind == DnsServerKind::Other).collect();
    let (status, summary) = if servers.is_empty() {
        (
            CheckStatus::Failed,
            t!(l, "Ни один DNS-сервер не обратился к сервису.", "No DNS server contacted the service."),
        )
    } else if others.is_empty() {
        let names = orgs(&servers, l);
        (
            CheckStatus::Ok,
            t!(
                l,
                format!("Запросы получили {names}: это сервер VPN или крупный публичный DNS."),
                format!("Queries reached {names}: the VPN server or a major public DNS.")
            ),
        )
    } else {
        let names = orgs(&others.iter().map(|s| (*s).clone()).collect::<Vec<_>>(), l);
        (
            CheckStatus::Warning,
            t!(
                l,
                format!("Часть запросов получил {names}. Если это ваш провайдер, он видит, какие сайты вы открываете."),
                format!("Some queries reached {names}. If that's your provider, it sees which sites you open.")
            ),
        )
    };
    DnsLeakResult { status, summary, servers, service: SERVICE.into() }
}

fn orgs(servers: &[DnsServer], l: Lang) -> String {
    let mut names: Vec<&str> = servers.iter().map(|s| s.org.as_str()).filter(|s| !s.is_empty()).collect();
    names.dedup();
    names.sort_unstable();
    names.dedup();
    if names.is_empty() { t!(l, "неизвестные серверы", "unknown servers") } else { names.join(", ") }
}

/// Операторы крупных публичных резолверов.
fn is_public_resolver(asn: &str) -> bool {
    [
        "AS15169",  // Google
        "AS13335",  // Cloudflare
        "AS19281",  // Quad9
        "AS42",     // Quad9 / PCH
        "AS36692",  // Cisco OpenDNS
        "AS205157", // AdGuard
    ]
    .iter()
    .any(|prefix| asn == *prefix || asn.starts_with(&format!("{prefix} ")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(ip: &str, asn: &str, org: &str, kind: &str) -> Entry {
        Entry { ip: ip.into(), country: "fi".into(), asn: asn.into(), org: org.into(), kind: kind.into() }
    }

    #[test]
    fn through_vpn_and_public() {
        let r = judge(
            &[
                entry("203.0.113.24", "AS64500 Example VPN Hosting", "Example VPN Hosting", "ip"),
                entry("203.0.113.53", "AS64500 Example VPN Hosting", "Example VPN Hosting", "dns"),
                entry("74.125.74.144", "AS15169 Google LLC", "Google LLC", "dns"),
                entry("DNS may be leaking.", "", "", "conclusion"),
            ],
            Lang::Ru,
        );
        assert_eq!(r.status, CheckStatus::Ok);
        assert_eq!(r.servers[0].kind, DnsServerKind::SameAsVpn);
        assert_eq!(r.servers[1].kind, DnsServerKind::Public);
    }

    #[test]
    fn provider_dns() {
        let r = judge(
            &[
                entry("203.0.113.24", "AS64500 Example VPN Hosting", "Example VPN Hosting", "ip"),
                entry("198.51.100.53", "AS64501 Example ISP", "Example ISP", "dns"),
            ],
            Lang::Ru,
        );
        assert_eq!(r.status, CheckStatus::Warning);
        assert!(r.summary.contains("Example ISP"));
    }
}
