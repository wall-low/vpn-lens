import Foundation

/// Итог проверки kill switch: работал ли интернет без VPN и кто успел выйти в сеть.
public struct KillSwitchResult: Equatable, Sendable {
    /// Без VPN интернет работал.
    public let internetWorked: Bool
    /// Адрес, с которым сайты видели машину без VPN.
    public let exposedIP: String?
    /// Кто пытался открыть соединения наружу.
    public let apps: [String]
    /// VPN так и не пропал или не вернулся вовремя.
    public let incomplete: Bool

    public init(internetWorked: Bool, exposedIP: String?, apps: [String], incomplete: Bool) {
        self.internetWorked = internetWorked
        self.exposedIP = exposedIP
        self.apps = apps
        self.incomplete = incomplete
    }

    /// Попытки соединиться без интернета не страшны: важно, что наружу ничего не вышло.
    public var passed: Bool { !internetWorked && !incomplete }

    public var title: String {
        if incomplete && !internetWorked { return String(localized: "Проверка не закончена") }
        return internetWorked ? String(localized: "Kill switch не сработал") : String(localized: "Kill switch сработал")
    }

    public var summary: String {
        var parts: [String] = []
        if internetWorked {
            parts.append(String(localized: "Без VPN интернет работал") + (exposedIP.map { String(localized: ", сайты видели \($0)") } ?? "") + ".")
        } else {
            parts.append(String(localized: "Пока VPN был выключен, интернета не было."))
        }
        if !apps.isEmpty {
            let names = apps.prefix(5).joined(separator: ", ")
            parts.append(internetWorked
                ? String(localized: "Успели выйти в сеть: \(names).")
                : String(localized: "Пытались выйти в сеть, но не смогли: \(names)."))
        }
        if incomplete {
            parts.append(internetWorked || !apps.isEmpty
                ? String(localized: "VPN не вернулся за отведённое время, проверка остановлена.")
                : String(localized: "VPN так и не отключился за минуту."))
        }
        return parts.joined(separator: " ")
    }
}
