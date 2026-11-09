import SwiftUI
import VPNLensCore

// Тексты, цвета и символы. Красный - только для подтверждённого обхода VPN.

extension Protection {
    var title: String {
        switch self {
        case .protected: String(localized: "Через VPN")
        case .partial: String(localized: "Часть трафика мимо VPN")
        case .exposed: String(localized: "Мимо VPN")
        case .noVpn: String(localized: "VPN выключен")
        case .vpnClient: String(localized: "Это VPN-клиент")
        case .localOnly: String(localized: "Только локальная сеть")
        case .idle: String(localized: "Сейчас не в сети")
        case .unverified: String(localized: "Не проверено")
        }
    }

    var explanation: String {
        switch self {
        case .protected: String(localized: "Сайты видят адрес VPN, а не ваш.")
        case .partial: String(localized: "Часть соединений идёт мимо VPN, и эти сайты видят ваш настоящий адрес.")
        case .exposed: String(localized: "Сайты видят ваш настоящий адрес.")
        case .noVpn: String(localized: "Сайты видят адрес провайдера.")
        case .vpnClient: String(localized: "Он держит туннель, поэтому ходит в сеть напрямую.")
        case .localOnly: String(localized: "Соединения только с этим компьютером или локальной сетью.")
        case .idle: String(localized: "Открытых соединений нет.")
        case .unverified: String(localized: "Есть соединения напрямую через Wi-Fi, а проверить, выпускает ли VPN трафик мимо себя, не удалось.")
        }
    }

    var short: String {
        switch self {
        case .protected: String(localized: "через VPN")
        case .partial: String(localized: "часть мимо VPN")
        case .exposed: String(localized: "мимо VPN")
        case .noVpn: String(localized: "без VPN")
        case .vpnClient: String(localized: "VPN-клиент")
        case .localOnly: String(localized: "локально")
        case .idle: String(localized: "не в сети")
        case .unverified: String(localized: "не проверено")
        }
    }

    var symbol: String {
        switch self {
        case .protected: "checkmark.shield.fill"
        case .partial: "exclamationmark.shield.fill"
        case .exposed: "xmark.shield.fill"
        case .noVpn: "shield.slash"
        case .vpnClient: "network.badge.shield.half.filled"
        case .localOnly: "house"
        case .idle: "moon.zzz"
        case .unverified: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .protected: .green
        case .partial: .orange
        case .exposed: .red
        case .vpnClient: .blue
        case .noVpn, .localOnly, .idle, .unverified: .secondary
        }
    }

    /// Порядок в списке приложений: проблемы наверху.
    var rank: Int {
        switch self {
        case .exposed: 0
        case .partial: 1
        case .unverified: 2
        case .noVpn: 3
        case .protected: 4
        case .localOnly: 5
        case .idle: 6
        case .vpnClient: 7
        }
    }
}

extension CheckStatus {
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .skipped: "minus.circle"
        case .failed: "questionmark.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .leak: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ok: .green
        case .info: .blue
        case .skipped, .failed: .secondary
        case .warning: .orange
        case .leak: .red
        }
    }
}

extension ExitKind {
    var title: String {
        switch self {
        case .vpnServer: String(localized: "VPN-сервер")
        case .provider: String(localized: "Провайдер")
        case .unknown: String(localized: "Другой адрес")
        }
    }
}

extension Exit {
    var countryName: String? {
        countryCode.map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
    }

    /// "Финляндия · cloudflare.com"
    var caption: String {
        ([countryName].compactMap { $0 } + [sites.joined(separator: ", ")]).joined(separator: " · ")
    }
}

extension RemoteKind {
    var title: String? {
        switch self {
        case .public: nil
        case .lan: String(localized: "локальная сеть")
        case .loopback: String(localized: "этот компьютер")
        case .localProxy: String(localized: "прокси VPN-клиента")
        case .tunnelFakeIp: String(localized: "служебный адрес туннеля")
        }
    }
}

extension Route {
    var title: String {
        switch self {
        case .loopback: String(localized: "локально")
        case .proxy: String(localized: "прокси")
        case .tunnel(let interface): String(localized: "туннель \(interface)")
        case .physical(let interface): String(localized: "напрямую \(interface)")
        case .lan(let interface): "LAN \(interface)"
        case .unknown: "?"
        }
    }
}

extension NetInterface {
    var symbol: String {
        switch kind {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .vpn: "lock.shield"
        case .loopback, .other: "network"
        }
    }

    var title: String {
        if kind == .vpn { return String(localized: "Туннель \(name)") }
        return displayName ?? name
    }
}

extension Monitor.Overall {
    /// Для VoiceOver и подсказки над иконкой: цвет и форма щита не должны быть единственным сигналом.
    var accessibilityText: String {
        switch self {
        case .protected: String(localized: "защищено, трафик идёт через VPN")
        case .warning: String(localized: "есть риск, подробности в окне VPN Lens")
        case .leak: String(localized: "есть трафик мимо VPN")
        case .noVpn: String(localized: "VPN не обнаружен")
        case .unknown: String(localized: "сеть ещё не проверена")
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .protected: "checkmark.shield"
        case .warning: "exclamationmark.shield"
        case .leak: "xmark.shield"
        case .noVpn: "shield.slash"
        case .unknown: "shield"
        }
    }
}

extension RouteSummary {
    var external: UInt32 { proxy + tunnel + physical }
}

extension AppNetwork {
    var runningApp: NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid_t(pid))
    }

    var displayName: String {
        if name == Monitor.webKitNetworking { return String(localized: "Safari (сеть WebKit)") }
        return runningApp?.localizedName ?? name
    }
}

/// Что делать, если программа ходит мимо VPN. Зависит от того, как устроен VPN.
func fixHint(for protection: Protection, vpn: VpnState?) -> String? {
    guard protection == .exposed || protection == .partial, let vpn else { return nil }
    if vpn.tunnels.isEmpty {
        return String(localized: "Программа не пользуется системным прокси, а туннеля у VPN нет. Включите в VPN-клиенте режим TUN (весь трафик) или укажите прокси в настройках самой программы.")
    }
    return String(localized: "VPN пропускает эти соединения мимо туннеля. Проверьте исключения (split tunneling) в настройках VPN-клиента.")
}

/// Язык интерфейса: как в системе. Английский - если он выбран в macOS, иначе русский
/// (язык разработки, на него macOS откатывается для любых других языков).
enum AppLanguage {
    static var current: Lang {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? .en : .ru
    }
}
