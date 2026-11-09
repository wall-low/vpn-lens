//! Типы, которые ядро отдаёт наружу: в CLI напрямую, в Swift через UniFFI.

/// Язык текстов проверок. Выбирает приложение по языку системы.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Enum)]
pub enum Lang {
    #[default]
    Ru,
    En,
}

/// Настройки полной проверки сети.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
pub struct InspectOptions {
    pub lang: Lang,
    /// Спрашивать ещё и региональный сайт (ip.nic.ru). Полезно там, где VPN-клиенты
    /// пускают местные сайты мимо сервера: так видно, что адрес зависит от сайта.
    pub regional_site: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum InterfaceKind {
    Wifi,
    Ethernet,
    Vpn,
    Loopback,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NetInterface {
    /// BSD-имя: en0, utun4.
    pub name: String,
    /// Человеческое имя, если ОС его знает: "Wi-Fi", "Thunderbolt Ethernet".
    pub display_name: Option<String>,
    pub kind: InterfaceKind,
    pub ipv4: Vec<String>,
    /// Без link-local (fe80::), они ничего не говорят пользователю.
    pub ipv6: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProxyKind {
    Http,
    Https,
    Socks,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProxyEndpoint {
    pub kind: ProxyKind,
    pub host: String,
    pub port: u16,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct ProxySettings {
    pub endpoints: Vec<ProxyEndpoint>,
    pub pac_url: Option<String>,
    /// Процесс, который слушает порт локального прокси.
    pub owner_process: Option<String>,
}

impl ProxySettings {
    pub fn is_enabled(&self) -> bool {
        !self.endpoints.is_empty() || self.pac_url.is_some()
    }
}

/// Что известно о VPN на машине.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct VpnState {
    /// Есть туннель или системный прокси.
    pub active: bool,
    /// Туннельные интерфейсы с адресами: utun4, wg0.
    pub tunnels: Vec<String>,
    pub proxy: ProxySettings,
    /// Процесс VPN-клиента, если удалось его узнать.
    pub client: Option<String>,
    /// Физический интерфейс, через который машина выходит в сеть: en0.
    pub physical: Option<String>,
    /// Отпечаток текущей сети (роутер и его MAC, захешированные). По нему адрес
    /// провайдера запоминается отдельно для дома, работы, кафе.
    pub network_id: Option<String>,
    /// Локальный прокси указан в системе, но на его порту никто не слушает:
    /// VPN-клиент, работающий как прокси, упал.
    pub proxy_dead: bool,
}

/// Быстрая проверка без снимка сокетов: есть ли туннель и жив ли локальный прокси.
/// Меньше миллисекунды, годится для реакции на события сети.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QuickVpn {
    pub tunnels: Vec<String>,
    pub proxy_configured: bool,
    /// None - прокси не локальный, проверить нельзя.
    pub proxy_alive: Option<bool>,
}

impl QuickVpn {
    pub fn up(&self) -> bool {
        !self.tunnels.is_empty() || (self.proxy_configured && self.proxy_alive != Some(false))
    }
}

/// Каким путём уходит одно соединение.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum Route {
    /// Внутри машины, не прокси.
    Loopback,
    /// В системный прокси. Дальше трафик ведёт тот, кто его держит.
    Proxy,
    /// Через туннельный интерфейс VPN.
    Tunnel { interface: String },
    /// Через физическую сеть в интернет. Утечка это или нет, решает проверка обхода.
    Physical { interface: String },
    /// В локальную сеть (роутер, принтер, NAS).
    Lan { interface: String },
    /// Локальный адрес не нашёлся среди интерфейсов.
    Unknown,
}

/// Что за адрес на той стороне. Нужно, чтобы не пугать человека служебными адресами.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RemoteKind {
    Public,
    Lan,
    Loopback,
    /// Порт системного прокси.
    LocalProxy,
    /// 198.18.0.0/15: подменные адреса, которые туннель выдаёт вместо настоящих.
    TunnelFakeIp,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Connection {
    pub pid: u32,
    pub process: String,
    pub local_addr: String,
    pub local_port: u16,
    pub remote_addr: String,
    pub remote_port: u16,
    pub remote_kind: RemoteKind,
    pub state: String,
    pub route: Route,
}

/// Сколько соединений приложения идёт каждым путём.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Record)]
pub struct RouteSummary {
    pub proxy: u32,
    pub tunnel: u32,
    pub physical: u32,
    pub lan: u32,
    pub local: u32,
}

impl RouteSummary {
    pub fn external(&self) -> u32 {
        self.proxy + self.tunnel + self.physical
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppNetwork {
    /// Корневой процесс приложения (тот, что запустил helper-процессы).
    pub pid: u32,
    pub name: String,
    /// Сколько процессов приложения держат соединения.
    pub process_count: u32,
    /// Это сам VPN-клиент: ему положено ходить через физическую сеть.
    pub is_vpn_client: bool,
    /// Служба macOS (/System, /usr): в списке сворачиваются в одну строку.
    pub is_system: bool,
    pub summary: RouteSummary,
    pub connections: Vec<Connection>,
}

/// Все приложения и отдельно выбранное, из одного снимка сокетов.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppsSnapshot {
    pub apps: Vec<AppNetwork>,
    pub focus: Option<AppNetwork>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum EgressPath {
    /// Обычный запрос без прокси: так ходят программы, которые прокси не используют.
    Default,
    /// Через системный прокси: так ходят браузеры и большинство приложений.
    SystemProxy,
    /// Сокет привязан к физическому интерфейсу: попытка выйти мимо туннеля.
    Physical,
}

/// Как один сайт увидел запрос, отправленный одним путём.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EgressProbe {
    pub path: EgressPath,
    pub site: String,
    pub ip: Option<String>,
    /// ISO 3166-1 alpha-2, если сайт его сообщает.
    pub country_code: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ExitKind {
    VpnServer,
    /// Настоящий адрес от провайдера.
    Provider,
    Unknown,
}

/// Внешний адрес, с которым машину видят сайты.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Exit {
    pub ip: String,
    pub country_code: Option<String>,
    pub kind: ExitKind,
    /// Сайты, которые увидели этот адрес.
    pub sites: Vec<String>,
    /// Пути, которыми запросы пришли с этого адреса.
    pub paths: Vec<EgressPath>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CheckId {
    Bypass,
    Udp,
    Ipv6,
    Dns,
    DomainRules,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, uniffi::Enum)]
pub enum CheckStatus {
    Ok,
    /// Справка, без оценки.
    Info,
    /// Не проверяли: например, VPN не включён.
    Skipped,
    /// Проверить не вышло. Это не "всё хорошо".
    Failed,
    /// Есть риск, но утечку не видели.
    Warning,
    Leak,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LeakCheck {
    pub id: CheckId,
    pub status: CheckStatus,
    pub title: String,
    pub summary: String,
    /// Что проверка доказывает и чего не доказывает.
    pub detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NetworkReport {
    pub vpn: VpnState,
    pub probes: Vec<EgressProbe>,
    pub exits: Vec<Exit>,
    pub checks: Vec<LeakCheck>,
    /// Адрес провайдера, если удалось его узнать. UI запоминает его на будущее.
    pub provider_ip: Option<String>,
    /// true: мимо туннеля выйти нельзя. false: можно. None: не проверяли.
    pub bypass_blocked: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Protection {
    /// Весь внешний трафик приложения идёт через VPN.
    Protected,
    /// Часть соединений идёт мимо VPN.
    Partial,
    /// Все внешние соединения идут мимо VPN.
    Exposed,
    /// VPN не включён: сайты видят адрес провайдера, как и задумано.
    NoVpn,
    /// Это сам VPN-клиент.
    VpnClient,
    LocalOnly,
    Idle,
    /// Есть соединения через физическую сеть, а проверить, выпускает ли VPN
    /// трафик мимо себя, не удалось.
    Unverified,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppVerdict {
    pub protection: Protection,
    /// Адреса, с которыми сайты видят это приложение.
    pub exits: Vec<Exit>,
    /// Адреса, с которыми уходят соединения мимо VPN (для Partial).
    pub exposed_exits: Vec<Exit>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DnsServerKind {
    /// Тот же оператор, что у VPN-сервера.
    SameAsVpn,
    /// Крупный публичный резолвер: Google, Cloudflare, Quad9 и т.п.
    Public,
    /// Кто-то ещё. Часто это DNS провайдера.
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DnsServer {
    pub ip: String,
    pub country_code: Option<String>,
    pub org: String,
    pub kind: DnsServerKind,
}

/// Результат внешнего DNS-теста: какие серверы на самом деле получили запросы.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DnsLeakResult {
    pub status: CheckStatus,
    pub summary: String,
    pub servers: Vec<DnsServer>,
    /// Кто проводил тест: запросы ушли туда.
    pub service: String,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum LensError {
    #[error("network: {0}")]
    Network(String),
    #[error("system: {0}")]
    System(String),
    #[error("no proxy configured")]
    NoProxy,
}
