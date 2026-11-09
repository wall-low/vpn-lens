use crate::model::{ProxyEndpoint, ProxyKind, ProxySettings};

/// Системные настройки прокси. Владельца (кто слушает порт) заполняет `connections`.
pub fn system() -> ProxySettings {
    platform()
}

/// Прокси, через который имеет смысл проверять внешний IP: HTTPS, потом SOCKS, потом HTTP.
pub fn preferred(settings: &ProxySettings) -> Option<&ProxyEndpoint> {
    [ProxyKind::Https, ProxyKind::Socks, ProxyKind::Http]
        .iter()
        .find_map(|k| settings.endpoints.iter().find(|e| e.kind == *k))
}

pub fn is_local_host(host: &str) -> bool {
    matches!(host, "127.0.0.1" | "localhost" | "::1" | "[::1]")
}

#[cfg(target_os = "macos")]
fn platform() -> ProxySettings {
    use core_foundation::base::CFType;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::number::CFNumber;
    use core_foundation::string::CFString;
    use system_configuration::dynamic_store::SCDynamicStoreBuilder;

    let Some(dict) = SCDynamicStoreBuilder::new("vpnlens").build().and_then(|store| store.get_proxies()) else {
        return ProxySettings::default();
    };

    let get = |d: &CFDictionary<CFString, CFType>, key: &str| -> Option<CFType> {
        d.find(CFString::new(key)).map(|v| v.clone())
    };
    let int = |key: &str| -> Option<i64> { get(&dict, key)?.downcast::<CFNumber>()?.to_i64() };
    let string = |key: &str| -> Option<String> { Some(get(&dict, key)?.downcast::<CFString>()?.to_string()) };

    let mut settings = ProxySettings::default();
    for (prefix, kind) in [("HTTP", ProxyKind::Http), ("HTTPS", ProxyKind::Https), ("SOCKS", ProxyKind::Socks)] {
        if int(&format!("{prefix}Enable")) != Some(1) {
            continue;
        }
        let host = string(&format!("{prefix}Proxy"));
        let port = int(&format!("{prefix}Port")).and_then(|p| u16::try_from(p).ok());
        if let (Some(host), Some(port)) = (host, port) {
            settings.endpoints.push(ProxyEndpoint { kind, host, port });
        }
    }
    if int("ProxyAutoConfigEnable") == Some(1) {
        settings.pac_url = string("ProxyAutoConfigURLString");
    }
    settings
}

#[cfg(not(target_os = "macos"))]
fn platform() -> ProxySettings {
    // TODO: Windows (WinHttpGetIEProxyConfigForCurrentUser), GNOME/KDE.
    // Пока только переменные окружения, их понимает большинство CLI-утилит.
    let mut settings = ProxySettings::default();
    for (var, kind) in
        [("HTTPS_PROXY", ProxyKind::Https), ("HTTP_PROXY", ProxyKind::Http), ("ALL_PROXY", ProxyKind::Socks)]
    {
        let value = std::env::var(var).or_else(|_| std::env::var(var.to_lowercase()));
        if let Ok(value) = value {
            if let Some(ep) = parse_env(&value, kind) {
                settings.endpoints.push(ep);
            }
        }
    }
    settings
}

#[cfg_attr(target_os = "macos", allow(dead_code))]
fn parse_env(value: &str, kind: ProxyKind) -> Option<ProxyEndpoint> {
    let rest = value.split_once("://").map_or(value, |(_, r)| r);
    let rest = rest.rsplit_once('@').map_or(rest, |(_, r)| r).trim_end_matches('/');
    let (host, port) = rest.rsplit_once(':')?;
    Some(ProxyEndpoint { kind, host: host.to_string(), port: port.parse().ok()? })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn env_values() {
        let ep = parse_env("http://user:pw@127.0.0.1:8080/", ProxyKind::Http).unwrap();
        assert_eq!((ep.host.as_str(), ep.port), ("127.0.0.1", 8080));
        assert!(parse_env("garbage", ProxyKind::Http).is_none());
    }

    #[test]
    fn preference_order() {
        let s = ProxySettings {
            endpoints: vec![
                ProxyEndpoint { kind: ProxyKind::Http, host: "a".into(), port: 1 },
                ProxyEndpoint { kind: ProxyKind::Socks, host: "b".into(), port: 2 },
            ],
            ..Default::default()
        };
        assert_eq!(preferred(&s).unwrap().kind, ProxyKind::Socks);
    }
}
