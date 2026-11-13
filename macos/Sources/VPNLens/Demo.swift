import Foundation
import VPNLensCore

/// `--demo`: подменить настоящие адреса адресами для документации (RFC 5737)
/// и обезличить VPN-клиента. Только для скриншотов в README, чтобы не публиковать
/// свой IP и адрес VPN-сервера.
enum Demo {
    static let enabled = CommandLine.arguments.contains("--demo") || Promo.enabled

    private static let fakeAddresses = ["203.0.113.24", "198.51.100.7", "203.0.113.80", "198.51.100.42"]
    private static let fakeClient = "ExampleVPN"

    /// Процесс VPN-клиента в списке программ называется по имени клиента: его тоже прячем.
    static func anonymize(_ apps: [AppNetwork]) -> [AppNetwork] {
        apps.map { app in
            guard app.isVpnClient else { return app }
            var copy = app
            copy.name = fakeClient
            return copy
        }
    }

    /// Разделы окна для GIF: без «Истории» и «Сети», там настоящие адреса локальной сети.
    static let tourSections: [WindowSection] = [.overview, .apps, .protection, .checks]
    static let tourStep: Duration = .seconds(2.5)

    static func anonymize(_ report: NetworkReport) -> NetworkReport {
        var real: [String] = []
        let remember = { (ip: String?) in
            if let ip, !ip.isEmpty, !real.contains(ip) { real.append(ip) }
        }
        report.exits.forEach { remember($0.ip) }
        report.probes.forEach { remember($0.ip) }
        remember(report.providerIp)

        func scrub(_ text: String) -> String {
            var out = text
            for (i, ip) in real.enumerated() {
                out = out.replacingOccurrences(of: ip, with: fakeAddresses[i % fakeAddresses.count])
            }
            if let client = report.vpn.client { out = out.replacingOccurrences(of: client, with: fakeClient) }
            return out
        }

        var r = report
        r.exits = r.exits.map { var e = $0; e.ip = scrub(e.ip); return e }
        r.probes = r.probes.map { var p = $0; p.ip = p.ip.map(scrub); p.error = p.error.map(scrub); return p }
        r.checks = r.checks.map { var c = $0; c.title = scrub(c.title); c.summary = scrub(c.summary); c.detail = c.detail.map(scrub); return c }
        r.providerIp = r.providerIp.map(scrub)
        r.vpn.client = r.vpn.client.map { _ in fakeClient }
        r.vpn.proxy.ownerProcess = r.vpn.proxy.ownerProcess.map { _ in fakeClient }
        return r
    }
}
