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

/// Язык интерфейса. Как и у системных программ, хранится в AppleLanguages в домене
/// самого приложения и применяется при следующем запуске.
enum LanguageChoice: String, CaseIterable, Identifiable {
    case system, ru, en
    var id: Self { self }

    var title: String {
        switch self {
        case .system: String(localized: "Как в системе")
        // Название языка - на самом языке, как в системных настройках.
        case .ru: "Русский"
        case .en: "English"
        }
    }

    static var saved: LanguageChoice {
        guard let id = Bundle.main.bundleIdentifier,
              let own = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String],
              let first = own.first
        else { return .system }
        return first.hasPrefix("en") ? .en : first.hasPrefix("ru") ? .ru : .system
    }

    func apply() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .ru, .en: UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Какой язык выберет macOS для «Как в системе»: первый из языков системы, который
    /// есть в приложении. Если ни одного нет - русский, язык разработки.
    static var systemResolved: LanguageChoice {
        let system = UserDefaults(suiteName: UserDefaults.globalDomain)?.stringArray(forKey: "AppleLanguages") ?? []
        let pick = Bundle.preferredLocalizations(from: ["ru", "en"], forPreferences: system).first
        return pick == "en" ? .en : .ru
    }

    /// Язык, с которым приложение запущено сейчас.
    static var running: LanguageChoice {
        AppLanguage.current == .en ? .en : .ru
    }
}

/// Перезапуск приложения: новый экземпляр стартует, когда этот уже закрылся,
/// чтобы в строке меню не было двух иконок и защита не сработала дважды.
@MainActor
enum Relaunch {
    static func now() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
