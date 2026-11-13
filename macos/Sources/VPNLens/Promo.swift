import AppKit
import SwiftUI
import VPNLensCore

/// `--promo apps|drop`: заранее заданная картина для съёмки ролика. Вместо настоящих
/// соединений - несколько программ с известным итогом, адреса из RFC 5737.
/// Настоящий список защищённых программ и история не читаются и не меняются.
///
/// - `apps`: VPN работает, Claude и ChatGPT идут через него, Codex - мимо;
/// - `drop`: VPN отключился, защита заморозила выбранные программы.
enum Promo {
    enum Stage: String { case apps, drop }

    static let stage: Stage? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--promo") else { return nil }
        return i + 1 < args.count ? Stage(rawValue: args[i + 1]) ?? .apps : .apps
    }()

    static var enabled: Bool { stage != nil }

    private static let vpnExit = Exit(
        ip: "203.0.113.24", countryCode: "NL", kind: .vpnServer,
        sites: ["cloudflare.com", "ipify.org"], paths: [.default, .systemProxy]
    )
    private static let providerExit = Exit(
        ip: "198.51.100.42", countryCode: nil, kind: .provider,
        sites: ["cloudflare.com"], paths: [.physical]
    )

    private struct Item {
        let name: String
        let bundleID: String?
        let proxy: UInt32
        let physical: UInt32
        var vpnClient = false
    }

    private static let items: [Item] = [
        Item(name: "Claude", bundleID: "com.anthropic.claudefordesktop", proxy: 14, physical: 0),
        Item(name: "ChatGPT", bundleID: "com.openai.codex", proxy: 9, physical: 0),
        // Консольные утилиты не смотрят на системный прокси: частый случай обхода VPN.
        Item(name: "codex", bundleID: nil, proxy: 0, physical: 6),
        Item(name: "Telegram", bundleID: "ru.keepcoder.Telegram", proxy: 4, physical: 0),
        Item(name: "Google Chrome", bundleID: "com.google.Chrome", proxy: 22, physical: 0),
        Item(name: "ExampleVPN", bundleID: nil, proxy: 0, physical: 2, vpnClient: true),
    ]

    /// Программы, которые защита замораживает на этапе `drop`.
    static let guarded: [AppGuard.Guarded] = [
        .init(bundleID: "com.anthropic.claudefordesktop", name: "Claude", mode: .freeze),
        .init(bundleID: "com.openai.codex", name: "ChatGPT", mode: .freeze),
        .init(bundleID: "ru.keepcoder.Telegram", name: "Telegram", mode: .freeze),
    ]

    /// Bundle ID программы из сценария: иконка нужна, даже если она не запущена.
    static func bundleID(for app: AppNetwork) -> String? {
        guard enabled else { return nil }
        return items.first { $0.name == app.name }?.bundleID
    }

    /// pid запущенной программы, чтобы в списке была её настоящая иконка.
    private static func pid(for item: Item, index: Int) -> UInt32 {
        if let id = item.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            return UInt32(app.processIdentifier)
        }
        return 90_000 + UInt32(index)
    }

    static var apps: [AppNetwork] {
        items.enumerated().map { index, item in
            let pid = pid(for: item, index: index)
            var connections: [Connection] = []
            for n in 0..<item.proxy {
                connections.append(Connection(
                    pid: pid, process: item.name, localAddr: "127.0.0.1", localPort: UInt16(52_000 + n),
                    remoteAddr: "127.0.0.1", remotePort: 1082, remoteKind: .localProxy,
                    state: "Established", route: .proxy
                ))
            }
            for n in 0..<item.physical {
                connections.append(Connection(
                    pid: pid, process: item.name, localAddr: "192.0.2.10", localPort: UInt16(53_000 + n),
                    remoteAddr: "203.0.113.\(100 + n)", remotePort: 443, remoteKind: .public,
                    state: "Established", route: .physical(interface: "en0")
                ))
            }
            return AppNetwork(
                pid: pid, name: item.name, processCount: 1,
                isVpnClient: item.vpnClient, isSystem: false,
                summary: RouteSummary(proxy: item.proxy, tunnel: 0, physical: item.physical, lan: 0, local: 0),
                connections: connections
            )
        }
    }

    static func verdict(for app: AppNetwork) -> AppVerdict {
        if app.isVpnClient { return AppVerdict(protection: .vpnClient, exits: [], exposedExits: []) }
        if stage == .drop { return AppVerdict(protection: .noVpn, exits: [providerExit], exposedExits: []) }
        if app.summary.physical > 0 {
            return AppVerdict(protection: .exposed, exits: [providerExit], exposedExits: [providerExit])
        }
        return AppVerdict(protection: .protected, exits: [vpnExit], exposedExits: [])
    }

    /// Настоящий отчёт (уже обезличенный) с нужным состоянием VPN и адресами.
    static func adjust(_ report: NetworkReport) -> NetworkReport {
        var r = report
        r.vpn.active = stage != .drop
        r.exits = stage == .drop ? [providerExit] : [vpnExit]
        r.providerIp = providerExit.ip
        return r
    }
}

/// Иконка программы из списка соединений. В `--promo` берётся по bundle ID.
struct NetworkAppIcon: View {
    let app: AppNetwork

    var body: some View {
        if app.runningApp == nil, let id = Promo.bundleID(for: app) {
            BundleIcon(bundleID: id)
        } else {
            AppIcon(app: app.runningApp)
        }
    }
}
