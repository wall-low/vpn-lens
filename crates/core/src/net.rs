//! Низкоуровневые запросы, которых нет в ureq: HTTPS через сокет, привязанный
//! к конкретному интерфейсу, и STUN по UDP.

use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, ToSocketAddrs, UdpSocket};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use rustls::pki_types::ServerName;
use socket2::{Domain, Protocol, Socket, Type};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(4);
const IO_TIMEOUT: Duration = Duration::from_secs(5);

/// GET по HTTPS на `ip:443`. `bind_to` - имя интерфейса (en0): соединение пойдёт через него,
/// а не по таблице маршрутов. Так проверяем, можно ли выйти мимо туннеля.
pub fn https_get(ip: IpAddr, path: &str, bind_to: Option<&str>) -> Result<String, String> {
    let socket = Socket::new(Domain::for_address(SocketAddr::new(ip, 443)), Type::STREAM, Some(Protocol::TCP))
        .map_err(|e| e.to_string())?;
    if let Some(iface) = bind_to {
        bind_to_interface(&socket, iface, ip.is_ipv6())?;
    }
    socket.connect_timeout(&SocketAddr::new(ip, 443).into(), CONNECT_TIMEOUT).map_err(|e| e.to_string())?;
    socket.set_read_timeout(Some(IO_TIMEOUT)).map_err(|e| e.to_string())?;
    socket.set_write_timeout(Some(IO_TIMEOUT)).map_err(|e| e.to_string())?;
    let tcp: std::net::TcpStream = socket.into();

    let name = ServerName::IpAddress(ip.into());
    let conn = rustls::ClientConnection::new(tls_config(), name).map_err(|e| e.to_string())?;
    let mut tls = rustls::StreamOwned::new(conn, tcp);

    let host = match ip {
        IpAddr::V4(v4) => v4.to_string(),
        IpAddr::V6(v6) => format!("[{v6}]"),
    };
    write!(tls, "GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: vpnlens\r\nConnection: close\r\n\r\n")
        .map_err(|e| e.to_string())?;

    let mut raw = Vec::new();
    // Часть серверов закрывает соединение без close_notify: всё, что успели прочитать, годится.
    if let Err(e) = tls.read_to_end(&mut raw)
        && raw.is_empty()
    {
        return Err(e.to_string());
    }
    let text = String::from_utf8_lossy(&raw);
    let (head, body) = text.split_once("\r\n\r\n").ok_or("empty response")?;
    if !head.starts_with("HTTP/1.1 200") && !head.starts_with("HTTP/1.0 200") {
        return Err(head.lines().next().unwrap_or("no status line").to_string());
    }
    Ok(body.to_string())
}

/// Внешний адрес по STUN, как его узнаёт WebRTC в браузере.
pub fn stun(server: &str) -> Result<IpAddr, String> {
    let addr = server
        .to_socket_addrs()
        .map_err(|e| e.to_string())?
        .find(|a| a.is_ipv4())
        .ok_or("STUN server has no IPv4 address")?;
    let socket = UdpSocket::bind("0.0.0.0:0").map_err(|e| e.to_string())?;

    let mut request = [0u8; 20];
    request[1] = 0x01; // Binding Request
    request[4..8].copy_from_slice(&MAGIC_COOKIE.to_be_bytes());
    // Идентификатор транзакции: случайность не криптографическая, нужна только чтобы отличить свой ответ.
    let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos() as u64)
        ^ u64::from(std::process::id()).rotate_left(32);
    let txid: [u8; 12] =
        std::array::from_fn(|i| (seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) >> ((i % 8) * 8)) as u8 ^ i as u8);
    request[8..20].copy_from_slice(&txid);

    // Ждём свой ответ до дедлайна: чужие и битые пакеты пропускаем, а не сдаёмся на первом.
    let mut buf = [0u8; 1024];
    let deadline = std::time::Instant::now() + Duration::from_secs(4);
    let mut next_send = std::time::Instant::now();
    while std::time::Instant::now() < deadline {
        if std::time::Instant::now() >= next_send {
            socket.send_to(&request, addr).map_err(|e| e.to_string())?;
            next_send = std::time::Instant::now() + Duration::from_millis(1500);
        }
        let wait = next_send.min(deadline).saturating_duration_since(std::time::Instant::now());
        socket.set_read_timeout(Some(wait.max(Duration::from_millis(10)))).map_err(|e| e.to_string())?;
        match socket.recv_from(&mut buf) {
            Ok((n, from)) if from == addr => {
                if let Some(ip) = parse_stun(&buf[..n], &txid) {
                    return Ok(ip);
                }
            }
            _ => {}
        }
    }
    Err("no answer over UDP".into())
}

const MAGIC_COOKIE: u32 = 0x2112_A442;

fn parse_stun(msg: &[u8], txid: &[u8; 12]) -> Option<IpAddr> {
    if msg.len() < 20 || msg[0..2] != [0x01, 0x01] || &msg[8..20] != txid {
        return None;
    }
    let mut i = 20;
    while i + 4 <= msg.len() {
        let kind = u16::from_be_bytes([msg[i], msg[i + 1]]);
        let len = u16::from_be_bytes([msg[i + 2], msg[i + 3]]) as usize;
        let value = msg.get(i + 4..i + 4 + len)?;
        // XOR-MAPPED-ADDRESS, семейство IPv4.
        if kind == 0x0020 && len >= 8 && value[1] == 0x01 {
            let raw = u32::from_be_bytes([value[4], value[5], value[6], value[7]]) ^ MAGIC_COOKIE;
            return Some(IpAddr::V4(raw.into()));
        }
        i += 4 + len.div_ceil(4) * 4;
    }
    None
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
            let config =
                rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                    .with_safe_default_protocol_versions()
                    .expect("ring поддерживает TLS 1.2 и 1.3")
                    .with_root_certificates(roots)
                    .with_no_client_auth();
            Arc::new(config)
        })
        .clone()
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn bind_to_interface(socket: &Socket, iface: &str, v6: bool) -> Result<(), String> {
    let name = std::ffi::CString::new(iface).map_err(|e| e.to_string())?;
    // SAFETY: if_nametoindex читает только переданную C-строку.
    let index = unsafe { libc::if_nametoindex(name.as_ptr()) };
    let index = std::num::NonZeroU32::new(index).ok_or_else(|| format!("no interface {iface}"))?;
    let result =
        if v6 { socket.bind_device_by_index_v6(Some(index)) } else { socket.bind_device_by_index_v4(Some(index)) };
    result.map_err(|e| e.to_string())
}

#[cfg(target_os = "linux")]
fn bind_to_interface(socket: &Socket, iface: &str, _v6: bool) -> Result<(), String> {
    // SO_BINDTODEVICE требует CAP_NET_RAW. Без него проверка честно вернёт ошибку.
    socket.bind_device(Some(iface.as_bytes())).map_err(|e| e.to_string())
}

#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "linux")))]
fn bind_to_interface(_socket: &Socket, _iface: &str, _v6: bool) -> Result<(), String> {
    // TODO: Windows - IP_UNICAST_IF.
    Err("binding to an interface is not supported on this OS yet".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stun_response() {
        let txid = [7u8; 12];
        let mut msg = vec![0x01, 0x01, 0x00, 0x0c];
        msg.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
        msg.extend_from_slice(&txid);
        // XOR-MAPPED-ADDRESS для 203.0.113.7:5000
        let ip = u32::from(std::net::Ipv4Addr::new(203, 0, 113, 7)) ^ MAGIC_COOKIE;
        msg.extend_from_slice(&[0x00, 0x20, 0x00, 0x08, 0x00, 0x01]);
        msg.extend_from_slice(&(5000u16 ^ 0x2112).to_be_bytes());
        msg.extend_from_slice(&ip.to_be_bytes());
        assert_eq!(parse_stun(&msg, &txid), Some("203.0.113.7".parse().unwrap()));
        assert_eq!(parse_stun(&msg, &[0u8; 12]), None);
    }
}
