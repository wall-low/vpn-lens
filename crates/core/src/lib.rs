//! Ядро vpnlens: как машина выходит в сеть, каким адресом её видят сайты
//! и не ходит ли что-то мимо VPN.
//!
//! Все функции блокирующие и без состояния. Вызывать не с главного потока:
//! снимок сокетов занимает десятки миллисекунд, `inspect_network` - до 6 секунд.

/// Текст на языке интерфейса: `t!(lang, "по-русски", "in English")`.
/// Вычисляется только нужная ветка, поэтому format! внутри ничего не стоит.
macro_rules! t {
    ($l:expr, $ru:expr, $en:expr $(,)?) => {
        match $l {
            crate::model::Lang::Ru => ($ru).to_string(),
            crate::model::Lang::En => ($en).to_string(),
        }
    };
}

mod connections;
mod dns;
mod dnstest;
mod egress;
mod interfaces;
mod model;
mod net;
mod netid;
mod proxy;
mod report;
mod summary;

pub use model::*;

uniffi::setup_scaffolding!();

/// Сетевые интерфейсы с адресами.
#[uniffi::export]
pub fn interfaces() -> Vec<NetInterface> {
    interfaces::list()
}

/// Туннели, прокси и VPN-клиент. Быстро, без запросов в интернет.
#[uniffi::export]
pub fn vpn_state() -> Result<VpnState, LensError> {
    let snapshot = connections::Snapshot::take()?;
    Ok(report::vpn_state(&snapshot, &interfaces::list()))
}

/// Все приложения с TCP-соединениями.
#[uniffi::export]
pub fn network_apps() -> Result<Vec<AppNetwork>, LensError> {
    Ok(connections::Snapshot::take()?.apps(&proxy::system()))
}

/// Все приложения и выбранное (`focus_pid`) из одного снимка сокетов.
/// Для периодического опроса: дешевле и согласованнее, чем два отдельных вызова.
#[uniffi::export]
pub fn apps_snapshot(focus_pid: Option<u32>) -> Result<AppsSnapshot, LensError> {
    let snapshot = connections::Snapshot::take()?;
    let apps = snapshot.apps(&proxy::system());
    let focus = focus_pid.map(|pid| snapshot.focus(pid, &apps));
    Ok(AppsSnapshot { apps, focus })
}

/// Сеть приложения, которому принадлежит `pid` (вместе с его helper-процессами).
#[uniffi::export]
pub fn app_network(pid: u32) -> Result<AppNetwork, LensError> {
    Ok(connections::Snapshot::take()?.app(pid, &proxy::system()))
}

/// Полная проверка: внешние адреса по сайтам и путям, обход VPN, UDP, IPv6, DNS.
/// Делает запросы в интернет. `known_provider_ip` - адрес провайдера, запомненный
/// раньше, когда VPN был выключен: с ним проще подписать выходы.
#[uniffi::export]
pub fn inspect_network(known_provider_ip: Option<String>, options: InspectOptions) -> NetworkReport {
    report::inspect(known_provider_ip, &options)
}

/// Защищено ли приложение и с какими адресами его видят сайты.
#[uniffi::export]
pub fn app_verdict(app: &AppNetwork, report: &NetworkReport) -> AppVerdict {
    report::verdict(app, report)
}

/// Внешний адрес обычным путём, быстро (до 3 секунд). Для теста kill switch:
/// `None` значит, что интернет недоступен.
#[uniffi::export]
pub fn quick_exit_ip() -> Option<String> {
    egress::quick_default()
}

/// Внешний DNS-тест через bash.ws. Только по явному действию пользователя.
#[uniffi::export]
pub fn dns_leak_test(lang: Lang) -> Result<DnsLeakResult, LensError> {
    dnstest::run(lang)
}

/// Отчёт простым текстом.
#[uniffi::export]
pub fn format_report(report: &NetworkReport, apps: &[AppNetwork], lang: Lang) -> String {
    summary::format(report, apps, lang)
}

/// Есть ли туннель и жив ли локальный прокси. Без снимка сокетов, меньше миллисекунды:
/// для реакции на события сети.
#[uniffi::export]
pub fn quick_vpn() -> QuickVpn {
    report::quick_vpn()
}

/// Потомки процесса: helper-процессы, которые нужно заморозить вместе с приложением.
#[uniffi::export]
pub fn process_descendants(pid: u32) -> Vec<u32> {
    connections::descendants(pid)
}

/// Поднят ли VPN по быстрой проверке (то же, что `QuickVpn::up`).
#[uniffi::export]
pub fn quick_vpn_up(state: &QuickVpn) -> bool {
    state.up()
}
