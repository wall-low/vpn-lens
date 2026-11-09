use std::net::IpAddr;

/// Адреса DNS-серверов, которыми пользуется система по умолчанию.
pub fn resolvers() -> Vec<IpAddr> {
    let mut list = platform();
    list.dedup();
    list
}

#[cfg(target_os = "macos")]
fn platform() -> Vec<IpAddr> {
    use core_foundation::array::CFArray;
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::CFString;
    use system_configuration::dynamic_store::SCDynamicStoreBuilder;

    let Some(store) = SCDynamicStoreBuilder::new("vpnlens").build() else {
        return Vec::new();
    };
    let Some(value) = store.get("State:/Network/Global/DNS") else {
        return Vec::new();
    };
    let Some(dict) = value.downcast_into::<CFDictionary>() else {
        return Vec::new();
    };
    // SAFETY: в этом ключе SystemConfiguration хранит словарь CFString -> CFType.
    let dict: CFDictionary<CFString, CFType> = unsafe { CFDictionary::wrap_under_get_rule(dict.as_concrete_TypeRef()) };
    let Some(servers) = dict.find(CFString::new("ServerAddresses")) else {
        return Vec::new();
    };
    let Some(array) = servers.downcast::<CFArray>() else {
        return Vec::new();
    };
    // SAFETY: ServerAddresses - массив строк.
    let array: CFArray<CFString> = unsafe { CFArray::wrap_under_get_rule(array.as_concrete_TypeRef()) };
    array.iter().filter_map(|s| s.to_string().parse().ok()).collect()
}

#[cfg(target_os = "linux")]
fn platform() -> Vec<IpAddr> {
    std::fs::read_to_string("/etc/resolv.conf").map(|s| parse_resolv_conf(&s)).unwrap_or_default()
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform() -> Vec<IpAddr> {
    // TODO: Windows - GetAdaptersAddresses, FirstDnsServerAddress.
    Vec::new()
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn parse_resolv_conf(text: &str) -> Vec<IpAddr> {
    text.lines()
        .filter_map(|l| l.trim().strip_prefix("nameserver"))
        .filter_map(|rest| rest.trim().split('%').next()?.parse().ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolv_conf() {
        let text = "# generated\nnameserver 127.0.0.53\nnameserver fe80::1%eth0\nsearch lan\n";
        assert_eq!(parse_resolv_conf(text), vec!["127.0.0.53".parse::<IpAddr>().unwrap(), "fe80::1".parse().unwrap()]);
    }
}
