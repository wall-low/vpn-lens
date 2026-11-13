//! Отчёт простым текстом: скопировать и отправить в поддержку VPN или на форум.

use std::fmt::Write;

use crate::model::{AppNetwork, CheckStatus, Lang, NetworkReport, Protection};
use crate::report::{exit_label, verdict};

pub fn format(report: &NetworkReport, apps: &[AppNetwork], l: Lang) -> String {
    let mut out = String::new();
    let vpn = &report.vpn;
    let _ = writeln!(out, "{}\n", t!(l, "Отчёт VPN Lens о сети", "VPN Lens network report"));

    if vpn.active {
        let mut parts = Vec::new();
        if let Some(client) = &vpn.client {
            parts.push(t!(l, format!("клиент {client}"), format!("client {client}")));
        }
        if !vpn.tunnels.is_empty() {
            let tunnels = vpn.tunnels.join(", ");
            parts.push(t!(l, format!("туннель {tunnels}"), format!("tunnel {tunnels}")));
        }
        if let Some(ep) = vpn.proxy.endpoints.first() {
            let addr = format!("{}:{}", ep.host, ep.port);
            parts.push(t!(l, format!("системный прокси {addr}"), format!("system proxy {addr}")));
        }
        let _ = writeln!(out, "VPN: {} ({})", t!(l, "включён", "on"), parts.join(", "));
    } else {
        let _ = writeln!(out, "VPN: {}", t!(l, "не обнаружен", "not detected"));
    }

    let _ = writeln!(out, "\n{}", t!(l, "Сайты видят:", "Sites see:"));
    for e in &report.exits {
        let country = e.country_code.as_deref().map(|c| format!(", {c}")).unwrap_or_default();
        let _ = writeln!(out, "- {} ({}{country}): {}", e.ip, exit_label(e.kind, l), e.sites.join(", "));
    }

    let _ = writeln!(out, "\n{}", t!(l, "Проверки:", "Checks:"));
    for c in &report.checks {
        let mark = match c.status {
            CheckStatus::Ok => t!(l, "ок", "ok"),
            CheckStatus::Info => t!(l, "инфо", "info"),
            CheckStatus::Skipped => t!(l, "пропущено", "skipped"),
            CheckStatus::Failed => t!(l, "не удалось", "failed"),
            CheckStatus::Warning => t!(l, "риск", "risk"),
            CheckStatus::Leak => t!(l, "УТЕЧКА", "LEAK"),
        };
        let _ = writeln!(out, "- [{mark}] {}: {}", c.title, c.summary);
    }

    let problems: Vec<String> = apps
        .iter()
        .filter_map(|a| {
            let label = match verdict(a, report).protection {
                Protection::Exposed => t!(l, "мимо VPN", "bypasses the VPN"),
                Protection::Partial => t!(l, "частично мимо VPN", "partly bypasses the VPN"),
                Protection::Unverified => t!(l, "не проверено", "not verified"),
                _ => return None,
            };
            Some(format!("- {}: {label}", a.name))
        })
        .collect();
    let _ = writeln!(out, "\n{}", t!(l, "Приложения:", "Apps:"));
    if !vpn.active {
        let _ = writeln!(
            out,
            "- {}",
            t!(
                l,
                "VPN не включён: все программы выходят с адресом провайдера",
                "VPN is off: every app goes out with the provider's address"
            )
        );
    } else if problems.is_empty() {
        let _ = writeln!(
            out,
            "- {}",
            t!(l, "все внешние соединения идут через VPN", "all external connections go through the VPN")
        );
    } else {
        for line in problems {
            let _ = writeln!(out, "{line}");
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::VpnState;

    #[test]
    fn without_vpn_does_not_claim_protection() {
        let report = NetworkReport {
            vpn: VpnState::default(),
            probes: vec![],
            exits: vec![],
            checks: vec![],
            provider_ip: None,
            bypass_blocked: None,
        };
        let text = format(&report, &[], Lang::Ru);
        assert!(text.contains("VPN не включён"), "{text}");
        assert!(!text.contains("идут через VPN"), "{text}");
    }
}
