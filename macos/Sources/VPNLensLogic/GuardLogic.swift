import Foundation

/// Состояние защиты приложений. Без AppKit и системных вызовов: так его можно проверить тестами.
public enum GuardState: Equatable, Sendable {
    /// Список пуст.
    case off
    /// VPN ещё ни разу не видели: замораживать нечего и незачем.
    case waitingForVpn
    /// VPN есть, защита взведена.
    case armed
    /// VPN пропал: эти приложения заморожены, а эти закрыты.
    case tripped(frozen: [String], closed: [String])
}

/// Что сделать в ответ на очередную проверку VPN.
public enum GuardAction: Equatable, Sendable {
    case nothing
    /// VPN на месте: взвести защиту (или подтвердить, что она взведена).
    case arm
    /// VPN пропал после того, как был: остановить приложения.
    case trip
    /// VPN вернулся: отпустить приложения, когда он устоится.
    case scheduleResume
    /// VPN снова пропал, пока ждали: не отпускать.
    case cancelResume
}

public enum GuardLogic {
    public static func action(state: GuardState, vpnUp: Bool) -> GuardAction {
        switch (state, vpnUp) {
        case (.off, _): .nothing
        case (.waitingForVpn, true), (.armed, true): .arm
        // Без VPN с самого начала защита не срабатывает, иначе заморозила бы всё у человека без VPN.
        case (.waitingForVpn, false): .nothing
        case (.armed, false): .trip
        case (.tripped, true): .scheduleResume
        case (.tripped, false): .cancelResume
        }
    }

    /// "Заморожены: Telegram, Chrome. Закрыт: Steam."
    public static func describe(frozen: [String], closed: [String]) -> String {
        var parts: [String] = []
        if !frozen.isEmpty {
            let label = frozen.count == 1 ? String(localized: "Заморожен") : String(localized: "Заморожены")
            parts.append(String(localized: "\(label): \(frozen.joined(separator: ", "))."))
        }
        if !closed.isEmpty {
            let label = closed.count == 1 ? String(localized: "Закрыт") : String(localized: "Закрыты")
            parts.append(String(localized: "\(label): \(closed.joined(separator: ", "))."))
        }
        return parts.joined(separator: " ")
    }
}
