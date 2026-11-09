import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Запуск при входе в систему через SMAppService.
@MainActor
enum LoginItem {
    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Пользователь должен подтвердить в Системных настройках (Объекты входа).
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// nil - получилось, иначе текст ошибки для интерфейса.
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Сочетание клавиш, которое открывает меню VPN Lens из любого приложения.
/// Выбор из готовых вариантов: проще, чем запись произвольного сочетания, и без конфликтов
/// с системными.
enum HotKeyOption: String, CaseIterable, Identifiable {
    case off, ctrlOptP, optCmdP, ctrlOptCmdP
    var id: Self { self }

    var title: String {
        switch self {
        case .off: String(localized: "Выключено")
        case .ctrlOptP: "⌃⌥P"
        case .optCmdP: "⌥⌘P"
        case .ctrlOptCmdP: "⌃⌥⌘P"
        }
    }

    fileprivate var modifiers: UInt32? {
        switch self {
        case .off: nil
        case .ctrlOptP: UInt32(controlKey | optionKey)
        case .optCmdP: UInt32(optionKey | cmdKey)
        case .ctrlOptCmdP: UInt32(controlKey | optionKey | cmdKey)
        }
    }

    static var saved: HotKeyOption {
        HotKeyOption(rawValue: UserDefaults.standard.string(forKey: "hotKey") ?? "") ?? .off
    }
}

/// Глобальная горячая клавиша через Carbon: не требует разрешения Accessibility.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        installHandler()
        apply(.saved)
    }

    func apply(_ option: HotKeyOption) {
        UserDefaults.standard.set(option.rawValue, forKey: "hotKey")
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let modifiers = option.modifiers else { return }
        let id = EventHotKeyID(signature: OSType(0x5045_454B), id: 1) // "PEEK"
        RegisterEventHotKey(UInt32(kVK_ANSI_P), modifiers, id, GetEventDispatcherTarget(), 0, &ref)
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { hotKey.action() } }
            return noErr
        }, 1, &spec, context, &handler)
    }
}

/// Окно «О программе»: стандартное, с версией, лицензией и ссылкой на исходники.
@MainActor
enum About {
    static let repository = URL(string: "https://github.com/wall-low/vpn-lens")!

    static func show() {
        let credits = NSMutableAttributedString(
            string: String(localized: "Исходный код и описание:") + " ",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        credits.append(NSAttributedString(
            string: "github.com/wall-low/vpn-lens",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: repository]
        ))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
