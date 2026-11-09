//! Отпечаток сети: чтобы адрес провайдера из дома не подписывал выходы в кафе.

/// Короткий хеш подписи сети, к которой подключён `physical`. MAC роутера наружу не отдаём.
pub fn network_id(physical: &str) -> Option<String> {
    platform(physical).map(|signature| format!("{:016x}", fnv1a(signature.as_bytes())))
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, b| (hash ^ u64::from(*b)).wrapping_mul(0x0000_0100_0000_01b3))
}

/// macOS сама считает подпись сети для каждой службы:
/// `IPv4.Router=192.168.1.1;IPv4.RouterHardwareAddress=aa:bb:...`.
#[cfg(target_os = "macos")]
fn platform(physical: &str) -> Option<String> {
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::CFString;
    use system_configuration::dynamic_store::SCDynamicStoreBuilder;

    let store = SCDynamicStoreBuilder::new("vpnlens").build()?;
    let keys = store.get_keys("State:/Network/Service/.*/IPv4")?;
    for key in keys.iter() {
        let Some(dict) = store.get(key.clone()).and_then(|v| v.downcast_into::<CFDictionary>()) else {
            continue;
        };
        // SAFETY: состояние служб SystemConfiguration - словарь CFString -> CFType.
        let dict: CFDictionary<CFString, CFType> =
            unsafe { CFDictionary::wrap_under_get_rule(dict.as_concrete_TypeRef()) };
        let string =
            |name: &str| dict.find(CFString::new(name)).and_then(|v| v.downcast::<CFString>()).map(|s| s.to_string());
        if string("InterfaceName").as_deref() == Some(physical)
            && let Some(signature) = string("NetworkSignature")
        {
            return Some(signature);
        }
    }
    None
}

#[cfg(not(target_os = "macos"))]
fn platform(_physical: &str) -> Option<String> {
    // TODO: Linux - шлюз и его MAC из /proc/net/route и /proc/net/arp.
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_is_stable_and_distinct() {
        let home = fnv1a(b"IPv4.Router=192.168.1.1;IPv4.RouterHardwareAddress=aa:bb:cc:dd:ee:ff");
        let cafe = fnv1a(b"IPv4.Router=192.168.1.1;IPv4.RouterHardwareAddress=11:22:33:44:55:66");
        assert_ne!(home, cafe, "одинаковый адрес роутера, но разные сети");
        assert_eq!(home, fnv1a(b"IPv4.Router=192.168.1.1;IPv4.RouterHardwareAddress=aa:bb:cc:dd:ee:ff"));
    }
}
