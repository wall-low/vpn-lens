use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

use ureq::{Agent, Proxy};

use crate::model::{EgressPath, EgressProbe, ProxyKind, ProxySettings};
use crate::{net, proxy};

/// Сайты, которые сообщают адрес клиента. Взяты из разных доменных зон: VPN-клиенты
/// с правилами по доменам часто пускают их разными путями, и это видно по ответам.
/// Сайтам уходит только сам запрос, никаких данных о процессах.
const SITES: &[Site] = &[
    Site { host: "cloudflare.com", url: "https://www.cloudflare.com/cdn-cgi/trace", format: Format::CloudflareTrace },
    Site { host: "ipify.org", url: "https://api.ipify.org/", format: Format::FirstIpv4 },
];

/// Региональный сайт: в России VPN-клиенты часто пускают зону .ru мимо сервера.
/// Включается настройкой, по умолчанию - когда регион системы Россия.
const REGIONAL_SITE: Site = Site { host: "ip.nic.ru", url: "https://ip.nic.ru/", format: Format::FirstIpv4 };

/// Для пути мимо туннеля нужен адрес без DNS: туннель может подменять ответы DNS.
const PHYSICAL_SITE: &str = "cloudflare.com";
const PHYSICAL_IP: IpAddr = IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1));

struct Site {
    host: &'static str,
    url: &'static str,
    format: Format,
}

enum Format {
    /// key=value построчно, есть ip= и loc=.
    CloudflareTrace,
    /// Любой текст или HTML: берём первый публичный IPv4.
    FirstIpv4,
}

/// Все проверки внешнего адреса: каждый сайт обычным путём и через прокси,
/// плюс одна попытка через физический интерфейс в обход туннеля.
pub fn probe_all(proxy_settings: &ProxySettings, physical: Option<&str>, regional: bool) -> Vec<EgressProbe> {
    let sites: Vec<&Site> = SITES.iter().chain(regional.then_some(&REGIONAL_SITE)).collect();
    let proxy_agent = proxy::preferred(proxy_settings).and_then(|ep| {
        let scheme = match ep.kind {
            ProxyKind::Socks => "socks5",
            ProxyKind::Http | ProxyKind::Https => "http",
        };
        Proxy::new(&format!("{scheme}://{}:{}", ep.host, ep.port)).ok().map(|p| agent(Some(p)))
    });
    let direct_agent = agent(None);

    std::thread::scope(|s| {
        let mut handles = Vec::new();
        for site in sites {
            let direct = &direct_agent;
            handles.push(s.spawn(move || probe_site(direct, site, EgressPath::Default)));
            if let Some(proxied) = &proxy_agent {
                handles.push(s.spawn(move || probe_site(proxied, site, EgressPath::SystemProxy)));
            }
        }
        if let Some(iface) = physical {
            handles.push(s.spawn(move || probe_physical(iface)));
        }
        handles.into_iter().map(|h| h.join().expect("probe thread panicked")).collect()
    })
}

/// Один быстрый запрос обычным путём: жив ли интернет и с каким адресом.
pub fn quick_default() -> Option<String> {
    let agent = Agent::config_builder().timeout_global(Some(Duration::from_secs(3))).proxy(None).build().new_agent();
    let body = agent.get(SITES[0].url).call().ok()?.body_mut().read_to_string().ok()?;
    parse_trace(&body).0
}

fn agent(proxy: Option<Proxy>) -> Agent {
    Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(6)))
        // Без явного None ureq подхватит HTTP(S)_PROXY из окружения.
        .proxy(proxy)
        .build()
        .new_agent()
}

fn probe_site(agent: &Agent, site: &Site, path: EgressPath) -> EgressProbe {
    let body = agent
        .get(site.url)
        .call()
        .and_then(|mut r| r.body_mut().with_config().limit(256 * 1024).read_to_string())
        .map_err(|e| e.to_string());
    finish(path, site.host, body, &site.format)
}

fn probe_physical(iface: &str) -> EgressProbe {
    let body = net::https_get(PHYSICAL_IP, "/cdn-cgi/trace", Some(iface));
    finish(EgressPath::Physical, PHYSICAL_SITE, body, &Format::CloudflareTrace)
}

fn finish(path: EgressPath, site: &str, body: Result<String, String>, format: &Format) -> EgressProbe {
    let mut probe = EgressProbe { path, site: site.into(), ip: None, country_code: None, error: None };
    match body {
        Ok(body) => {
            let (ip, country) = match format {
                Format::CloudflareTrace => parse_trace(&body),
                Format::FirstIpv4 => (first_public_ipv4(&body), None),
            };
            if ip.is_none() {
                probe.error = Some("no address in the response".into());
            }
            probe.ip = ip;
            probe.country_code = country;
        }
        Err(e) => probe.error = Some(e),
    }
    probe
}

pub(crate) fn parse_trace(body: &str) -> (Option<String>, Option<String>) {
    let mut ip = None;
    let mut loc = None;
    for line in body.lines() {
        match line.split_once('=') {
            Some(("ip", v)) => ip = Some(v.trim().to_string()),
            // XX - Cloudflare сам не знает страну.
            Some(("loc", v)) if v.trim() != "XX" => loc = Some(v.trim().to_string()),
            _ => {}
        }
    }
    (ip, loc)
}

fn first_public_ipv4(body: &str) -> Option<String> {
    body.split(|c: char| !(c.is_ascii_digit() || c == '.'))
        .filter_map(|token| token.trim_matches('.').parse::<Ipv4Addr>().ok())
        .find(|ip| {
            let ip = IpAddr::V4(*ip);
            !ip.is_loopback() && !ip.is_unspecified() && !crate::connections::is_private(&ip)
        })
        .map(|ip| ip.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trace() {
        let body = "fl=1\nh=www.cloudflare.com\nip=203.0.113.7\nts=1\nloc=NL\ntls=TLSv1.3\n";
        assert_eq!(parse_trace(body), (Some("203.0.113.7".into()), Some("NL".into())));
        assert_eq!(parse_trace("ip=1.2.3.4\nloc=XX"), (Some("1.2.3.4".into()), None));
    }

    #[test]
    fn ipv4_in_html() {
        let html = r#"<meta content="1.0.2"><p>Ваш IP: <b>198.51.100.7</b></p> 8.8.8.8"#;
        assert_eq!(first_public_ipv4(html).as_deref(), Some("198.51.100.7"));
        assert_eq!(first_public_ipv4("from 192.168.1.1 and 127.0.0.1"), None);
    }
}
