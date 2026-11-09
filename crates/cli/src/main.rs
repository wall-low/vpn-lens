//! Консольная версия VPN Lens.
//!
//!   vpnlens               полная проверка: VPN, адреса, утечки, приложения
//!   vpnlens --offline     только локальное: VPN и приложения, без запросов в интернет
//!   vpnlens app <имя|pid> соединения одного приложения
//!   vpnlens report        отчёт простым текстом
//!   vpnlens dns           внешний DNS-тест (запросы уходят на bash.ws)
//!
//! Язык - по переменным LC_ALL, LC_MESSAGES и LANG: английский, если там en, иначе русский.

use std::process::ExitCode;

use vpnlens_core::{
    AppNetwork, CheckStatus, ExitKind, InspectOptions, Lang, NetworkReport, Protection, RemoteKind, Route, VpnState,
};

macro_rules! t {
    ($l:expr, $ru:expr, $en:expr $(,)?) => {
        match $l {
            Lang::Ru => ($ru).to_string(),
            Lang::En => ($en).to_string(),
        }
    };
}

fn main() -> ExitCode {
    let l = lang();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let options = InspectOptions { lang: l, regional_site: l == Lang::Ru || args.iter().any(|a| a == "--regional") };
    let result = match args.first().map(String::as_str) {
        None | Some("--regional") => summary(l, Some(options)),
        Some("--offline") => summary(l, None),
        Some("report") => {
            let report = vpnlens_core::inspect_network(None, options);
            vpnlens_core::network_apps()
                .map_err(|e| e.to_string())
                .map(|apps| print!("{}", vpnlens_core::format_report(&report, &apps, l)))
        }
        Some("dns") => vpnlens_core::dns_leak_test(l).map_err(|e| e.to_string()).map(|r| {
            println!("{}", r.summary);
            for s in r.servers {
                println!("  {:<40} {:<3} {}", s.ip, s.country_code.unwrap_or_default(), s.org);
            }
        }),
        Some("app") => match args.get(1) {
            Some(query) => show_app(l, query),
            None => Err(t!(l, "укажите имя приложения или pid", "give an app name or pid")),
        },
        Some("-h" | "--help") => {
            println!("vpnlens [--offline | --regional] | vpnlens app <name|pid> | vpnlens report | vpnlens dns");
            Ok(())
        }
        Some(other) => Err(t!(l, format!("непонятный аргумент: {other}"), format!("unknown argument: {other}"))),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("vpnlens: {e}");
            ExitCode::FAILURE
        }
    }
}

fn lang() -> Lang {
    let value = ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
        .unwrap_or_default();
    if value.starts_with("en") { Lang::En } else { Lang::Ru }
}

fn summary(l: Lang, online: Option<InspectOptions>) -> Result<(), String> {
    let report = match online {
        Some(options) => vpnlens_core::inspect_network(None, options),
        None => {
            let vpn = vpnlens_core::vpn_state().map_err(|e| e.to_string())?;
            NetworkReport {
                vpn,
                probes: vec![],
                exits: vec![],
                checks: vec![],
                provider_ip: None,
                bypass_blocked: None,
            }
        }
    };
    print_vpn(l, &report.vpn);

    if online.is_some() {
        println!("\n{}", t!(l, "Как вас видят сайты", "How sites see you"));
        for e in &report.exits {
            println!(
                "  {:<16} {:<4} {:<14} {}",
                e.ip,
                e.country_code.as_deref().unwrap_or(""),
                exit_label(l, e.kind),
                e.sites.join(", ")
            );
        }
        println!("\n{}", t!(l, "Проверки", "Checks"));
        for c in &report.checks {
            println!("  {} {}\n      {}", status_mark(l, c.status), c.title, c.summary);
        }
    }

    println!("\n{}", t!(l, "Приложения", "Apps"));
    let apps = vpnlens_core::network_apps().map_err(|e| e.to_string())?;
    for app in apps.iter().filter(|a| a.summary.external() > 0).take(15) {
        let v = vpnlens_core::app_verdict(app, &report);
        let seen = v.exits.iter().map(|e| e.ip.as_str()).collect::<Vec<_>>().join(", ");
        println!("  {:<28} {:<24} {}", truncate(&app.name, 28), protection_label(l, v.protection), seen);
    }
    Ok(())
}

fn print_vpn(l: Lang, vpn: &VpnState) {
    println!("VPN");
    if !vpn.active {
        println!("  {}", t!(l, "не обнаружен", "not detected"));
    }
    if !vpn.tunnels.is_empty() {
        println!("  {:<12} {}", t!(l, "туннель", "tunnel"), vpn.tunnels.join(", "));
    }
    for e in &vpn.proxy.endpoints {
        println!("  {:<12} {}:{} ({:?})", t!(l, "прокси", "proxy"), e.host, e.port, e.kind);
    }
    if let Some(client) = &vpn.client {
        println!("  {:<12} {client}", t!(l, "клиент", "client"));
    }
    if let Some(phys) = &vpn.physical {
        println!("  {:<12} {phys}", t!(l, "сеть", "network"));
    }
}

fn show_app(l: Lang, query: &str) -> Result<(), String> {
    let app: AppNetwork = match query.parse::<u32>() {
        Ok(pid) => vpnlens_core::app_network(pid).map_err(|e| e.to_string())?,
        Err(_) => {
            let needle = query.to_lowercase();
            vpnlens_core::network_apps()
                .map_err(|e| e.to_string())?
                .into_iter()
                .find(|a| a.name.to_lowercase().contains(&needle))
                .ok_or_else(|| {
                    t!(
                        l,
                        format!("нет приложения с соединениями: {query}"),
                        format!("no app with connections: {query}")
                    )
                })?
        }
    };
    let s = app.summary;
    println!(
        "{} (pid {}){}",
        app.name,
        app.pid,
        if app.is_vpn_client { t!(l, ", VPN-клиент", ", VPN client") } else { String::new() }
    );
    println!(
        "{}\n",
        t!(
            l,
            format!(
                "прокси {} · туннель {} · напрямую {} · LAN {} · локально {}",
                s.proxy, s.tunnel, s.physical, s.lan, s.local
            ),
            format!(
                "proxy {} · tunnel {} · direct {} · LAN {} · local {}",
                s.proxy, s.tunnel, s.physical, s.lan, s.local
            )
        )
    );
    for c in &app.connections {
        println!(
            "  {:<22} {:<40} {:<28} {}",
            route_label(l, &c.route),
            format!("{}:{}", c.remote_addr, c.remote_port),
            remote_label(l, c.remote_kind),
            c.process
        );
    }
    Ok(())
}

fn exit_label(l: Lang, kind: ExitKind) -> String {
    match kind {
        ExitKind::VpnServer => t!(l, "VPN-сервер", "VPN server"),
        ExitKind::Provider => t!(l, "провайдер", "provider"),
        ExitKind::Unknown => "?".into(),
    }
}

fn status_mark(l: Lang, s: CheckStatus) -> String {
    let mark = match s {
        CheckStatus::Ok => t!(l, "ок", "ok"),
        CheckStatus::Info => t!(l, "инфо", "info"),
        CheckStatus::Skipped => t!(l, "пропуск", "skip"),
        CheckStatus::Failed => t!(l, "ошибка", "error"),
        CheckStatus::Warning => t!(l, "риск", "risk"),
        CheckStatus::Leak => t!(l, "УТЕЧКА", "LEAK"),
    };
    format!("{:<10}", format!("[{mark}]"))
}

fn protection_label(l: Lang, p: Protection) -> String {
    match p {
        Protection::Protected => t!(l, "через VPN", "via VPN"),
        Protection::Partial => t!(l, "ЧАСТЬ МИМО VPN", "PARTLY BYPASSES VPN"),
        Protection::Exposed => t!(l, "МИМО VPN", "BYPASSES VPN"),
        Protection::NoVpn => t!(l, "без VPN", "no VPN"),
        Protection::VpnClient => t!(l, "VPN-клиент", "VPN client"),
        Protection::LocalOnly => t!(l, "только локально", "local only"),
        Protection::Idle => t!(l, "нет соединений", "idle"),
        Protection::Unverified => t!(l, "не проверено", "not verified"),
    }
}

fn route_label(l: Lang, route: &Route) -> String {
    match route {
        Route::Loopback => t!(l, "локально", "local"),
        Route::Proxy => t!(l, "прокси", "proxy"),
        Route::Tunnel { interface } => t!(l, format!("туннель {interface}"), format!("tunnel {interface}")),
        Route::Physical { interface } => t!(l, format!("напрямую {interface}"), format!("direct {interface}")),
        Route::Lan { interface } => format!("LAN {interface}"),
        Route::Unknown => "?".into(),
    }
}

fn remote_label(l: Lang, kind: RemoteKind) -> String {
    match kind {
        RemoteKind::Public => String::new(),
        RemoteKind::Lan => t!(l, "локальная сеть", "local network"),
        RemoteKind::Loopback => t!(l, "этот компьютер", "this Mac"),
        RemoteKind::LocalProxy => t!(l, "прокси VPN-клиента", "VPN client proxy"),
        RemoteKind::TunnelFakeIp => t!(l, "служебный адрес туннеля", "tunnel placeholder address"),
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() } else { s.chars().take(max - 1).chain(['.']).collect() }
}
