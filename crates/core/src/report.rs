//! Выводы из замеров: где выход VPN, где провайдер, есть ли утечки и что с каждым приложением.
//!
//! Всё, что здесь решается, - чистые функции от замеров. Так их можно проверить тестами
//! на конфигурациях, которых нет на машине разработчика: без VPN, только прокси,
//! полный туннель, раздельный туннель, правила по доменам.

use std::net::IpAddr;

use crate::connections::{Snapshot, is_fake_ip, is_private};
use crate::model::{
    AppNetwork, AppVerdict, CheckId, CheckStatus, EgressPath, EgressProbe, Exit, ExitKind, InspectOptions,
    InterfaceKind, Lang, LeakCheck, NetInterface, NetworkReport, Protection, QuickVpn, VpnState,
};
use crate::{dns, egress, interfaces, net, proxy};

const STUN_SERVERS: &[&str] = &["stun.l.google.com:19302", "stun.cloudflare.com:3478"];
/// one.one.one.one по IPv6: адрес без DNS и с сертификатом на IP.
const IPV6_PROBE: &str = "2606:4700:4700::1111";

// ---------------------------------------------------------------------------
// Сбор

pub fn vpn_state(snapshot: &Snapshot, ifaces: &[NetInterface]) -> VpnState {
    let tunnels: Vec<String> = ifaces
        .iter()
        .filter(|i| i.kind == InterfaceKind::Vpn && !(i.ipv4.is_empty() && i.ipv6.is_empty()))
        .map(|i| i.name.clone())
        .collect();
    let mut proxy = proxy::system();
    let owner = snapshot.proxy_owner(&proxy);
    proxy.owner_process = owner.and_then(|pid| snapshot.name_of(pid));

    let client = proxy.owner_process.clone().or_else(|| {
        let mut roots: Vec<u32> = snapshot.vpn_client_roots(&proxy).into_iter().collect();
        roots.sort_unstable();
        roots.first().and_then(|pid| snapshot.name_of(*pid))
    });
    let physical = ifaces
        .iter()
        .find(|i| matches!(i.kind, InterfaceKind::Wifi | InterfaceKind::Ethernet) && !i.ipv4.is_empty())
        .map(|i| i.name.clone());

    let network_id = physical.as_deref().and_then(crate::netid::network_id);
    // Прокси на этом компьютере, а порт никто не слушает: клиент упал, хоть настройка и осталась.
    let local_proxy = proxy.endpoints.iter().any(|e| proxy::is_local_host(&e.host));
    let proxy_dead = local_proxy && owner.is_none();
    let active = !tunnels.is_empty() || (proxy.is_enabled() && !proxy_dead);
    VpnState { active, tunnels, proxy, client, physical, network_id, proxy_dead }
}

/// Туннели по списку интерфейсов и пробное подключение к локальному прокси.
pub fn quick_vpn() -> QuickVpn {
    use std::net::{SocketAddr, TcpStream};
    use std::time::Duration;

    let tunnels = interfaces::tunnel_names();
    let settings = proxy::system();
    let local: Vec<u16> = settings.endpoints.iter().filter(|e| proxy::is_local_host(&e.host)).map(|e| e.port).collect();
    let proxy_alive = (!local.is_empty()).then(|| {
        local.iter().any(|port| {
            let addr = SocketAddr::from(([127, 0, 0, 1], *port));
            TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok()
        })
    });
    QuickVpn { tunnels, proxy_configured: settings.is_enabled(), proxy_alive }
}

pub fn inspect(known_provider: Option<String>, options: &InspectOptions) -> NetworkReport {
    let l = options.lang;
    let ifaces = interfaces::list();
    let vpn = Snapshot::take().map(|s| vpn_state(&s, &ifaces)).unwrap_or_default();
    let physical_v6 = physical_ipv6(&ifaces, vpn.physical.as_deref());

    let (probes, stun, v6_probe) = std::thread::scope(|s| {
        let physical = if vpn.active { vpn.physical.as_deref() } else { None };
        let proxy = &vpn.proxy;
        let regional = options.regional_site;
        let probes = s.spawn(move || egress::probe_all(proxy, physical, regional));
        let stun = s.spawn(|| {
            let mut last = Err("no STUN servers".to_string());
            for server in STUN_SERVERS {
                last = net::stun(server);
                if last.is_ok() {
                    break;
                }
            }
            last
        });
        let v6 = s.spawn(|| {
            if physical_v6.is_empty() {
                return None;
            }
            let ip: IpAddr = IPV6_PROBE.parse().expect("адрес задан константой");
            Some(
                net::https_get(ip, "/cdn-cgi/trace", None).map(|body| egress::parse_trace(&body).0.unwrap_or_default()),
            )
        });
        (probes.join().expect("поток упал"), stun.join().expect("поток упал"), v6.join().expect("поток упал"))
    });

    let analysis = analyze(&probes, &vpn, known_provider.as_deref());
    let checks = vec![
        check_bypass(&vpn, &analysis, &probes, l),
        check_udp(&vpn, &analysis, stun.as_ref().map(|ip| ip.to_string()).map_err(String::clone), l),
        check_ipv6(&vpn, &physical_v6, v6_probe, l),
        check_dns(&vpn, &analysis, &dns::resolvers(), l),
        check_domain_rules(&analysis, l),
    ];
    NetworkReport {
        vpn,
        probes,
        exits: analysis.exits,
        checks,
        provider_ip: analysis.provider_ip,
        bypass_blocked: analysis.bypass_blocked,
    }
}

fn physical_ipv6(ifaces: &[NetInterface], physical: Option<&str>) -> Vec<String> {
    ifaces
        .iter()
        .filter(|i| Some(i.name.as_str()) == physical)
        .flat_map(|i| i.ipv6.iter())
        .filter(|ip| ip.parse::<IpAddr>().is_ok_and(|ip| !is_private(&ip)))
        .cloned()
        .collect()
}

// ---------------------------------------------------------------------------
// Анализ выходов

pub(crate) struct Analysis {
    pub exits: Vec<Exit>,
    pub provider_ip: Option<String>,
    /// Адрес, который видят сайты, когда трафик идёт через VPN.
    pub vpn_ip: Option<String>,
    pub bypass_blocked: Option<bool>,
}

pub(crate) fn analyze(probes: &[EgressProbe], vpn: &VpnState, known_provider: Option<&str>) -> Analysis {
    let ok = |path: EgressPath| probes.iter().filter(move |p| p.path == path).filter_map(|p| p.ip.as_deref());

    // Через что ходит VPN: туннель ловит обычные запросы, а без туннеля работает только прокси.
    let main_path = if vpn.tunnels.is_empty() && ok(EgressPath::SystemProxy).next().is_some() {
        EgressPath::SystemProxy
    } else {
        EgressPath::Default
    };
    let vpn_ip = vpn.active.then(|| ok(main_path).next().map(String::from)).flatten();
    let physical = probes.iter().find(|p| p.path == EgressPath::Physical);
    let physical_ip = physical.and_then(|p| p.ip.clone());

    let provider_ip = if !vpn.active {
        ok(EgressPath::Default).next().map(String::from)
    } else if physical_ip.is_some() && physical_ip != vpn_ip {
        physical_ip.clone()
    } else {
        known_provider.filter(|p| Some(*p) != vpn_ip.as_deref()).map(String::from)
    };

    // Если запрос в обход не прошёл, это ещё не доказывает, что VPN его режет:
    // адрес мог быть недоступен по другой причине. Тогда честно говорим "не проверено".
    let bypass_blocked = match (vpn.active, physical.and_then(|p| p.ip.as_ref()), &vpn_ip) {
        (true, Some(ip), Some(vpn_ip)) => Some(ip == vpn_ip),
        _ => None,
    };

    let mut exits: Vec<Exit> = Vec::new();
    for p in probes {
        let Some(ip) = &p.ip else { continue };
        let kind = if !vpn.active || Some(ip) == provider_ip.as_ref() {
            ExitKind::Provider
        } else if Some(ip) == vpn_ip.as_ref() || provider_ip.is_some() {
            ExitKind::VpnServer
        } else {
            ExitKind::Unknown
        };
        match exits.iter_mut().find(|e| &e.ip == ip) {
            Some(e) => {
                if !e.sites.contains(&p.site) {
                    e.sites.push(p.site.clone());
                }
                if !e.paths.contains(&p.path) {
                    e.paths.push(p.path);
                }
                e.country_code = e.country_code.take().or_else(|| p.country_code.clone());
            }
            None => exits.push(Exit {
                ip: ip.clone(),
                country_code: p.country_code.clone(),
                kind,
                sites: vec![p.site.clone()],
                paths: vec![p.path],
            }),
        }
    }

    Analysis { exits, provider_ip, vpn_ip, bypass_blocked }
}

// ---------------------------------------------------------------------------
// Проверки

fn check(id: CheckId, status: CheckStatus, title: String, summary: String, detail: Option<String>) -> LeakCheck {
    LeakCheck { id, status, title, summary, detail }
}

pub(crate) fn exit_label(kind: ExitKind, l: Lang) -> String {
    match kind {
        ExitKind::VpnServer => t!(l, "VPN-сервер", "VPN server"),
        ExitKind::Provider => t!(l, "провайдер", "provider"),
        ExitKind::Unknown => t!(l, "другой адрес", "other address"),
    }
}

pub(crate) fn check_bypass(vpn: &VpnState, a: &Analysis, probes: &[EgressProbe], l: Lang) -> LeakCheck {
    let id = CheckId::Bypass;
    let phys = vpn.physical.clone().unwrap_or_else(|| t!(l, "физическую сеть", "the physical network"));
    if vpn.proxy_dead && vpn.tunnels.is_empty() {
        let ep = vpn.proxy.endpoints.first().map(|e| format!("{}:{}", e.host, e.port)).unwrap_or_default();
        return check(
            id,
            CheckStatus::Warning,
            t!(l, "VPN-клиент не отвечает", "VPN client is not responding"),
            t!(
                l,
                format!(
                    "В системе указан прокси {ep}, но на этом порту никто не слушает: похоже, VPN-клиент упал. Программы, которые пользуются прокси, сейчас без сети, остальные идут напрямую."
                ),
                format!(
                    "The system proxy is set to {ep}, but nothing is listening on that port: the VPN client seems to have crashed. Apps that use the proxy are offline, the rest go direct."
                )
            ),
            Some(t!(
                l,
                "Перезапустите VPN-клиент или выключите системный прокси в настройках сети.",
                "Restart the VPN client or turn off the system proxy in network settings."
            )),
        );
    }
    if !vpn.active {
        return check(
            id,
            CheckStatus::Skipped,
            t!(l, "VPN не включён", "VPN is off"),
            t!(
                l,
                "Туннеля и прокси нет: все программы выходят в сеть с адресом провайдера.",
                "No tunnel and no proxy: every app goes online with your provider's address."
            ),
            None,
        );
    }
    let physical = probes.iter().find(|p| p.path == EgressPath::Physical);
    match a.bypass_blocked {
        Some(true) => check(
            id,
            CheckStatus::Ok,
            t!(l, "Мимо VPN не выйти", "Nothing gets past the VPN"),
            t!(
                l,
                format!("Запрос, отправленный напрямую через {phys}, всё равно ушёл через VPN."),
                format!("A request sent directly through {phys} still went through the VPN.")
            ),
            Some(t!(
                l,
                "Это запрос самого VPN Lens. Программы, которые сами выбирают сеть, подчиняются тому же правилу.",
                "This is VPN Lens's own request. Apps that pick the network themselves follow the same rule."
            )),
        ),
        Some(false) => {
            let ip = physical.and_then(|p| p.ip.clone()).unwrap_or_default();
            let mut summary = t!(
                l,
                format!(
                    "Запрос напрямую через {phys} вышел с адресом {ip}. Программы, которые не пользуются VPN, видны сайтам с этим адресом."
                ),
                format!(
                    "A direct request through {phys} went out as {ip}. Apps that don't use the VPN are visible to sites with this address."
                )
            );
            if vpn.tunnels.is_empty() {
                summary.push_str(&t!(
                    l,
                    " Туннеля нет, VPN работает только как прокси, и программы без прокси идут мимо.",
                    " There is no tunnel: the VPN works only as a proxy, so apps that ignore the proxy go around it."
                ));
            }
            check(
                id,
                CheckStatus::Warning,
                t!(l, "Мимо VPN выйти можно", "Traffic can bypass the VPN"),
                summary,
                Some(t!(
                    l,
                    "Какие программы так делают, видно в разделе «Приложения».",
                    "See which apps do this in Apps."
                )),
            )
        }
        None => {
            let (summary, detail) = match (&vpn.physical, physical.and_then(|p| p.error.clone())) {
                (None, _) => (
                    t!(l, "Не нашёл Wi-Fi или Ethernet с адресом.", "No Wi-Fi or Ethernet interface with an address."),
                    None,
                ),
                _ if a.vpn_ip.is_none() => (
                    t!(
                        l,
                        "Проверочные сайты не ответили даже через VPN.",
                        "Test sites did not answer even through the VPN."
                    ),
                    None,
                ),
                (_, Some(_)) => (
                    t!(
                        l,
                        format!("Запрос напрямую через {phys} не дошёл до проверочного сайта."),
                        format!("A direct request through {phys} did not reach the test site.")
                    ),
                    Some(t!(
                        l,
                        "Так бывает, когда VPN не выпускает трафик мимо себя, но и когда сайт просто недоступен из этой сети. Отличить одно от другого отсюда нельзя.",
                        "This happens when the VPN blocks traffic around it, but also when the site is simply unreachable from this network. There is no way to tell which from here."
                    )),
                ),
                _ => (t!(l, "Проверочный сайт не ответил.", "The test site did not answer."), None),
            };
            check(id, CheckStatus::Failed, t!(l, "Обход VPN не проверен", "VPN bypass not checked"), summary, detail)
        }
    }
}

pub(crate) fn check_udp(vpn: &VpnState, a: &Analysis, stun: Result<String, String>, l: Lang) -> LeakCheck {
    let id = CheckId::Udp;
    let ip = match stun {
        Ok(ip) => ip,
        Err(err) => {
            return check(
                id,
                CheckStatus::Failed,
                t!(l, "UDP не проверен", "UDP not checked"),
                t!(l, format!("STUN-сервер не ответил: {err}"), format!("The STUN server did not answer: {err}")),
                Some(t!(
                    l,
                    "Если UDP заблокирован, звонки и WebRTC не работают, но и адрес не раскрывают.",
                    "If UDP is blocked, calls and WebRTC don't work, but they don't reveal your address either."
                )),
            );
        }
    };
    if !vpn.active {
        return check(
            id,
            CheckStatus::Skipped,
            t!(l, "UDP без VPN", "UDP without VPN"),
            t!(l, format!("Звонки и WebRTC выходят с адресом {ip}."), format!("Calls and WebRTC go out as {ip}.")),
            None,
        );
    }
    let detail = Some(t!(
        l,
        "Так браузер узнаёт адрес для WebRTC. Сайт может запросить его без вашего ведома.",
        "This is how a browser learns its address for WebRTC. A site can ask for it without you noticing."
    ));
    if Some(&ip) == a.vpn_ip.as_ref() || a.exits.iter().any(|e| e.ip == ip && e.kind == ExitKind::VpnServer) {
        check(
            id,
            CheckStatus::Ok,
            t!(l, "UDP идёт через VPN", "UDP goes through the VPN"),
            t!(
                l,
                format!("WebRTC в браузере, звонки и игры покажут {ip}."),
                format!("WebRTC, calls and games will show {ip}.")
            ),
            detail,
        )
    } else if Some(&ip) == a.provider_ip.as_ref() {
        check(
            id,
            CheckStatus::Leak,
            t!(l, "UDP идёт мимо VPN", "UDP bypasses the VPN"),
            t!(
                l,
                format!(
                    "WebRTC в браузере может показать сайтам адрес провайдера {ip}, даже если страница открыта через VPN."
                ),
                format!(
                    "WebRTC in the browser can reveal your provider's address {ip} to sites, even when the page is opened through the VPN."
                )
            ),
            detail,
        )
    } else {
        let vpn_ip = a.vpn_ip.clone().unwrap_or_else(|| t!(l, "неизвестен", "unknown"));
        check(
            id,
            CheckStatus::Warning,
            t!(l, "UDP выходит с другим адресом", "UDP goes out with a different address"),
            t!(
                l,
                format!(
                    "UDP выходит с {ip}, а сайты по TCP видят {vpn_ip}. Это может быть второй сервер VPN или провайдер."
                ),
                format!(
                    "UDP goes out as {ip}, while sites see {vpn_ip} over TCP. It may be a second VPN server or your provider."
                )
            ),
            detail,
        )
    }
}

pub(crate) fn check_ipv6(
    vpn: &VpnState,
    physical_v6: &[String],
    probe: Option<Result<String, String>>,
    l: Lang,
) -> LeakCheck {
    let id = CheckId::Ipv6;
    let phys = vpn.physical.clone().unwrap_or_else(|| t!(l, "сети", "the network"));
    let Some(probe) = probe.filter(|_| !physical_v6.is_empty()) else {
        return check(
            id,
            CheckStatus::Ok,
            t!(l, "IPv6 не используется", "IPv6 is not used"),
            t!(
                l,
                format!("У {phys} нет публичного IPv6-адреса, утечь через него нечему."),
                format!("{phys} has no public IPv6 address, so nothing can leak through it.")
            ),
            None,
        );
    };
    if !vpn.active {
        return check(
            id,
            CheckStatus::Skipped,
            t!(l, "IPv6 без VPN", "IPv6 without VPN"),
            t!(l, format!("У {phys} есть IPv6: {}.", physical_v6[0]), format!("{phys} has IPv6: {}.", physical_v6[0])),
            None,
        );
    }
    match probe {
        Ok(ip) if same_prefix64(&ip, physical_v6) => check(
            id,
            CheckStatus::Leak,
            t!(l, "IPv6 идёт мимо VPN", "IPv6 bypasses the VPN"),
            t!(
                l,
                format!("Сайты с поддержкой IPv6 видят {ip}, это адрес от провайдера."),
                format!("Sites that support IPv6 see {ip}, an address from your provider.")
            ),
            Some(t!(
                l,
                "Частая утечка: VPN перехватывает только IPv4. Помогает отключить IPv6 или включить его поддержку в VPN.",
                "A common leak: the VPN only captures IPv4. Turn off IPv6 or enable IPv6 support in the VPN."
            )),
        ),
        Ok(ip) => check(
            id,
            CheckStatus::Ok,
            t!(l, "IPv6 идёт через VPN", "IPv6 goes through the VPN"),
            t!(l, format!("Сайты с IPv6 видят {ip}."), format!("IPv6 sites see {ip}.")),
            None,
        ),
        Err(_) => check(
            id,
            CheckStatus::Ok,
            t!(l, "IPv6 перекрыт", "IPv6 is blocked"),
            t!(
                l,
                format!("У {phys} есть IPv6, но выйти через него не удалось: VPN его не выпускает."),
                format!("{phys} has IPv6, but nothing got out through it: the VPN blocks it.")
            ),
            None,
        ),
    }
}

fn same_prefix64(ip: &str, ours: &[String]) -> bool {
    let prefix = |s: &str| s.parse::<std::net::Ipv6Addr>().ok().map(|a| a.segments()[..4].to_vec());
    let Some(target) = prefix(ip) else { return false };
    ours.iter().any(|o| prefix(o).as_ref() == Some(&target))
}

pub(crate) fn check_dns(vpn: &VpnState, a: &Analysis, resolvers: &[IpAddr], l: Lang) -> LeakCheck {
    let id = CheckId::Dns;
    let detail = Some(t!(
        l,
        "Здесь видно, кому система отправляет DNS-запросы. Какой сервер в итоге их получает, покажет только внешний DNS-тест.",
        "This shows where the system sends DNS queries. Which server finally receives them only an external DNS test can tell."
    ));
    if resolvers.is_empty() {
        return check(
            id,
            CheckStatus::Failed,
            t!(l, "DNS не проверен", "DNS not checked"),
            t!(l, "Не удалось прочитать настройки DNS.", "Could not read DNS settings."),
            None,
        );
    }
    let list = resolvers.iter().map(ToString::to_string).collect::<Vec<_>>().join(", ");
    if !vpn.active {
        return check(
            id,
            CheckStatus::Skipped,
            t!(l, "DNS без VPN", "DNS without VPN"),
            t!(
                l,
                format!("Адреса сайтов система спрашивает у {list}."),
                format!("The system asks {list} for site addresses.")
            ),
            detail,
        );
    }

    let verdicts = resolvers.iter().map(|ip| {
        if is_fake_ip(ip) {
            (CheckStatus::Ok, t!(l, "DNS через VPN", "DNS goes through the VPN"),
                t!(l, format!("Система спрашивает адреса у {ip}, это сервер внутри туннеля."),
                    format!("The system asks {ip}, a server inside the tunnel.")))
        } else if ip.is_loopback() {
            (CheckStatus::Info, t!(l, "Локальный DNS-сервер", "Local DNS server"),
                t!(l, format!("Запросы принимает программа на этом компьютере ({ip}): обычно VPN-клиент или фильтр рекламы."),
                    format!("Queries go to a program on this Mac ({ip}): usually the VPN client or an ad blocker.")))
        } else if is_private(ip) {
            let summary = t!(l,
                format!("Запросы идут на {ip} в локальной сети, обычно это роутер, а от него к провайдеру. Провайдер видит, какие сайты вы открываете."),
                format!("Queries go to {ip} on the local network, usually the router, and from there to your provider. The provider sees which sites you open."));
            if a.bypass_blocked == Some(false) {
                (CheckStatus::Leak, t!(l, "DNS мимо VPN", "DNS bypasses the VPN"), summary)
            } else {
                (CheckStatus::Warning, t!(l, "DNS через роутер", "DNS goes to the router"), summary)
            }
        } else if a.bypass_blocked == Some(false) && vpn.tunnels.is_empty() {
            (CheckStatus::Warning, t!(l, "DNS может идти мимо VPN", "DNS may bypass the VPN"),
                t!(l, format!("Публичный DNS {ip}. Туннеля нет, поэтому запросы к нему идут не через VPN."),
                    format!("Public DNS {ip}. There is no tunnel, so queries to it don't go through the VPN.")))
        } else {
            (CheckStatus::Ok, t!(l, "DNS через VPN", "DNS goes through the VPN"),
                t!(l, format!("Публичный DNS {ip}, запросы к нему идут через туннель вместе с остальным трафиком."),
                    format!("Public DNS {ip}; queries to it go through the tunnel with the rest of the traffic.")))
        }
    });
    let (status, title, summary) = verdicts.max_by_key(|v| v.0).expect("список не пустой");
    check(id, status, title, summary, detail)
}

pub(crate) fn check_domain_rules(a: &Analysis, l: Lang) -> LeakCheck {
    let id = CheckId::DomainRules;
    let visible: Vec<&Exit> = a.exits.iter().filter(|e| e.paths.iter().any(|p| *p != EgressPath::Physical)).collect();
    match visible.len() {
        0 => check(
            id,
            CheckStatus::Failed,
            t!(l, "Адрес не проверен", "Address not checked"),
            t!(l, "Проверочные сайты не ответили.", "Test sites did not answer."),
            None,
        ),
        1 => check(
            id,
            CheckStatus::Ok,
            t!(l, "Все сайты видят один адрес", "All sites see one address"),
            format!("{}: {}.", visible[0].sites.join(", "), visible[0].ip),
            None,
        ),
        _ => {
            let parts: Vec<String> = visible
                .iter()
                .map(|e| {
                    t!(
                        l,
                        format!("{} видит {} ({})", e.sites.join(", "), e.ip, exit_label(e.kind, l)),
                        format!("{} sees {} ({})", e.sites.join(", "), e.ip, exit_label(e.kind, l))
                    )
                })
                .collect();
            check(
                id,
                CheckStatus::Info,
                t!(l, "Сайты видят разные адреса", "Sites see different addresses"),
                format!("{}.", parts.join("; ")),
                Some(t!(
                    l,
                    "Так работают правила VPN-клиента: часть сайтов он пускает другим путём. Если вы этого не настраивали, проверьте правила.",
                    "That's how the VPN client's rules work: it routes some sites differently. If you didn't set this up, check the rules."
                )),
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Приложение

pub fn verdict(app: &AppNetwork, r: &NetworkReport) -> AppVerdict {
    let s = app.summary;
    let exits_on =
        |path: EgressPath| -> Vec<Exit> { r.exits.iter().filter(|e| e.paths.contains(&path)).cloned().collect() };
    let none = |protection| AppVerdict { protection, exits: Vec::new(), exposed_exits: Vec::new() };

    if app.is_vpn_client {
        return none(Protection::VpnClient);
    }
    if s.external() == 0 {
        return none(if s.local + s.lan > 0 { Protection::LocalOnly } else { Protection::Idle });
    }
    if !r.vpn.active {
        return AppVerdict {
            protection: Protection::NoVpn,
            exits: exits_on(EgressPath::Default),
            exposed_exits: Vec::new(),
        };
    }

    let has_proxy_probes = r.probes.iter().any(|p| p.path == EgressPath::SystemProxy && p.ip.is_some());
    let protected_path = if s.proxy > 0 && s.proxy >= s.tunnel && has_proxy_probes {
        EgressPath::SystemProxy
    } else {
        EgressPath::Default
    };
    let protected_exits = exits_on(protected_path);
    let exposed_exits = || {
        let physical = exits_on(EgressPath::Physical);
        if physical.is_empty() {
            r.exits.iter().filter(|e| e.kind == ExitKind::Provider).cloned().collect()
        } else {
            physical
        }
    };
    let protected_count = s.proxy + s.tunnel;

    match (s.physical > 0, r.bypass_blocked) {
        (false, _) | (true, Some(true)) => {
            AppVerdict { protection: Protection::Protected, exits: protected_exits, exposed_exits: Vec::new() }
        }
        (true, Some(false)) if protected_count > 0 => {
            AppVerdict { protection: Protection::Partial, exits: protected_exits, exposed_exits: exposed_exits() }
        }
        (true, Some(false)) => {
            AppVerdict { protection: Protection::Exposed, exits: exposed_exits(), exposed_exits: Vec::new() }
        }
        (true, None) => {
            AppVerdict { protection: Protection::Unverified, exits: protected_exits, exposed_exits: Vec::new() }
        }
    }
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{ProxyEndpoint, ProxyKind, ProxySettings, RouteSummary};

    const VPN: &str = "203.0.113.24";
    const ISP: &str = "198.51.100.7";

    fn probe(path: EgressPath, site: &str, ip: Option<&str>) -> EgressProbe {
        EgressProbe {
            path,
            site: site.into(),
            ip: ip.map(String::from),
            country_code: None,
            error: ip.is_none().then(|| "timeout".into()),
        }
    }

    fn vpn(tunnel: bool, proxy: bool) -> VpnState {
        let proxy = if proxy {
            ProxySettings {
                endpoints: vec![ProxyEndpoint { kind: ProxyKind::Http, host: "127.0.0.1".into(), port: 1082 }],
                ..Default::default()
            }
        } else {
            ProxySettings::default()
        };
        VpnState {
            active: tunnel || proxy.is_enabled(),
            tunnels: if tunnel { vec!["utun4".into()] } else { vec![] },
            proxy,
            client: None,
            physical: Some("en0".into()),
            network_id: None,
            proxy_dead: false,
        }
    }

    fn report(vpn: VpnState, probes: Vec<EgressProbe>, known: Option<&str>) -> NetworkReport {
        let a = analyze(&probes, &vpn, known);
        NetworkReport {
            vpn,
            probes,
            exits: a.exits,
            checks: vec![],
            provider_ip: a.provider_ip,
            bypass_blocked: a.bypass_blocked,
        }
    }

    fn app(proxy: u32, tunnel: u32, physical: u32) -> AppNetwork {
        AppNetwork {
            pid: 1,
            name: "App".into(),
            process_count: 1,
            is_vpn_client: false,
            is_system: false,
            summary: RouteSummary { proxy, tunnel, physical, lan: 0, local: 0 },
            connections: vec![],
        }
    }

    use EgressPath::{Default as Def, Physical as Phys, SystemProxy as Prx};

    #[test]
    fn no_vpn() {
        let r = report(vpn(false, false), vec![probe(Def, "cloudflare.com", Some(ISP))], None);
        assert_eq!(r.provider_ip.as_deref(), Some(ISP));
        assert_eq!(r.exits[0].kind, ExitKind::Provider);
        assert_eq!(r.bypass_blocked, None);
        assert_eq!(verdict(&app(0, 0, 3), &r).protection, Protection::NoVpn);
    }

    #[test]
    fn full_tunnel_that_cannot_be_bypassed() {
        let v = vpn(true, false);
        let r = report(
            v.clone(),
            vec![probe(Def, "cloudflare.com", Some(VPN)), probe(Phys, "cloudflare.com", Some(VPN))],
            None,
        );
        assert_eq!(r.bypass_blocked, Some(true));
        assert_eq!(r.exits.len(), 1);
        assert_eq!(r.exits[0].kind, ExitKind::VpnServer);
        // Сокет на физическом интерфейсе всё равно ушёл в туннель: это не утечка.
        assert_eq!(verdict(&app(0, 2, 1), &r).protection, Protection::Protected);

        let a = analyze(&r.probes, &v, None);
        assert_eq!(check_bypass(&v, &a, &r.probes, Lang::Ru).status, CheckStatus::Ok);
    }

    #[test]
    fn failed_bypass_probe_is_not_proof() {
        // Запрос в обход не прошёл: может, VPN режет, а может, сайт недоступен. Не угадываем.
        let v = vpn(true, false);
        let probes = vec![probe(Def, "cloudflare.com", Some(VPN)), probe(Phys, "cloudflare.com", None)];
        let a = analyze(&probes, &v, None);
        assert_eq!(a.bypass_blocked, None);
        assert_eq!(check_bypass(&v, &a, &probes, Lang::Ru).status, CheckStatus::Failed);
    }

    #[test]
    fn proxy_only() {
        // Только прокси: браузер защищён, программы без прокси идут с адресом провайдера.
        let v = vpn(false, true);
        let probes = vec![
            probe(Def, "cloudflare.com", Some(ISP)),
            probe(Prx, "cloudflare.com", Some(VPN)),
            probe(Phys, "cloudflare.com", Some(ISP)),
        ];
        let r = report(v.clone(), probes.clone(), None);
        assert_eq!(r.provider_ip.as_deref(), Some(ISP));
        assert_eq!(r.bypass_blocked, Some(false));

        let browser = verdict(&app(5, 0, 0), &r);
        assert_eq!(browser.protection, Protection::Protected);
        assert_eq!(browser.exits[0].ip, VPN);

        let cli = verdict(&app(0, 0, 2), &r);
        assert_eq!(cli.protection, Protection::Exposed);
        assert_eq!(cli.exits[0].ip, ISP);

        let mixed = verdict(&app(5, 0, 1), &r);
        assert_eq!(mixed.protection, Protection::Partial);
        assert_eq!(mixed.exposed_exits[0].kind, ExitKind::Provider);

        let a = analyze(&probes, &v, None);
        assert_eq!(check_bypass(&v, &a, &probes, Lang::Ru).status, CheckStatus::Warning);
        assert_eq!(check_udp(&v, &a, Ok(ISP.into()), Lang::Ru).status, CheckStatus::Leak);
        assert_eq!(check_dns(&v, &a, &["192.168.1.1".parse().unwrap()], Lang::Ru).status, CheckStatus::Leak);
    }

    #[test]
    fn split_tunnel_by_routes() {
        let v = vpn(true, false);
        let r =
            report(v, vec![probe(Def, "cloudflare.com", Some(VPN)), probe(Phys, "cloudflare.com", Some(ISP))], None);
        assert_eq!(r.bypass_blocked, Some(false));
        assert_eq!(verdict(&app(0, 3, 0), &r).protection, Protection::Protected);
        assert_eq!(verdict(&app(0, 0, 1), &r).protection, Protection::Exposed);
    }

    #[test]
    fn domain_rules_inside_enforced_tunnel() {
        // Стенд разработчика: туннель + прокси одного клиента, .ru-сайты идут через провайдера.
        let v = vpn(true, true);
        let probes = vec![
            probe(Def, "cloudflare.com", Some(VPN)),
            probe(Prx, "cloudflare.com", Some(VPN)),
            probe(Def, "ip.nic.ru", Some(ISP)),
            probe(Prx, "ip.nic.ru", Some(ISP)),
            probe(Phys, "cloudflare.com", Some(VPN)),
        ];
        let a = analyze(&probes, &v, None);
        assert_eq!(a.bypass_blocked, Some(true));
        assert_eq!(a.exits.len(), 2);
        assert_eq!(a.exits[1].kind, ExitKind::Unknown, "без запомненного адреса провайдера не угадываем");
        assert_eq!(check_domain_rules(&a, Lang::Ru).status, CheckStatus::Info);

        let a = analyze(&probes, &v, Some(ISP));
        assert_eq!(a.exits[1].kind, ExitKind::Provider);

        let r = report(v.clone(), probes.clone(), Some(ISP));
        // Прокси и туннель вперемешку - не повод для тревоги.
        let chatgpt = verdict(&app(30, 1, 0), &r);
        assert_eq!(chatgpt.protection, Protection::Protected);
        assert_eq!(chatgpt.exits.len(), 2);

        assert_eq!(check_udp(&v, &a, Ok(VPN.into()), Lang::Ru).status, CheckStatus::Ok);
        assert_eq!(check_dns(&v, &a, &["198.18.0.2".parse().unwrap()], Lang::Ru).status, CheckStatus::Ok);
    }

    #[test]
    fn vpn_client_and_idle() {
        let r = report(vpn(true, false), vec![probe(Def, "cloudflare.com", Some(VPN))], None);
        let mut client = app(0, 0, 40);
        client.is_vpn_client = true;
        assert_eq!(verdict(&client, &r).protection, Protection::VpnClient);
        assert_eq!(verdict(&app(0, 0, 0), &r).protection, Protection::Idle);
        assert_eq!(verdict(&app(0, 0, 1), &r).protection, Protection::Unverified);
    }

    #[test]
    fn dead_proxy_client() {
        // Клиент-прокси упал, а настройка осталась: это не "VPN включён".
        let mut v = vpn(false, true);
        v.proxy_dead = true;
        v.active = false;
        let probes = vec![probe(Def, "cloudflare.com", Some(ISP))];
        let a = analyze(&probes, &v, None);
        let c = check_bypass(&v, &a, &probes, Lang::Ru);
        assert_eq!(c.status, CheckStatus::Warning);
        assert!(c.title.contains("не отвечает"));
        assert_eq!(a.exits[0].kind, ExitKind::Provider);

        let quick = QuickVpn { tunnels: vec![], proxy_configured: true, proxy_alive: Some(false) };
        assert!(!quick.up());
        assert!(QuickVpn { tunnels: vec!["utun4".into()], proxy_configured: true, proxy_alive: Some(false) }.up());
        assert!(
            QuickVpn { tunnels: vec![], proxy_configured: true, proxy_alive: None }.up(),
            "удалённый прокси не проверить"
        );
    }

    #[test]
    fn english_texts() {
        let v = vpn(true, false);
        let probes = vec![probe(Def, "cloudflare.com", Some(VPN)), probe(Phys, "cloudflare.com", Some(VPN))];
        let a = analyze(&probes, &v, None);
        let en = check_bypass(&v, &a, &probes, Lang::En);
        let ru = check_bypass(&v, &a, &probes, Lang::Ru);
        assert_eq!(en.status, ru.status, "язык не влияет на вердикт");
        assert_eq!(en.title, "Nothing gets past the VPN");
        assert!(!en.summary.chars().any(|c| ('а'..='я').contains(&c.to_ascii_lowercase())));
    }

    #[test]
    fn ipv6() {
        let v = vpn(true, false);
        let ours = vec!["2001:db8:1:2::10".to_string()];
        assert_eq!(check_ipv6(&v, &[], None, Lang::Ru).status, CheckStatus::Ok);
        assert_eq!(check_ipv6(&v, &ours, Some(Ok("2001:db8:1:2::99".into())), Lang::Ru).status, CheckStatus::Leak);
        assert_eq!(check_ipv6(&v, &ours, Some(Ok("2001:db8:ffff::5".into())), Lang::Ru).status, CheckStatus::Ok);
        assert_eq!(check_ipv6(&v, &ours, Some(Err("timeout".into())), Lang::Ru).status, CheckStatus::Ok);
    }
}
