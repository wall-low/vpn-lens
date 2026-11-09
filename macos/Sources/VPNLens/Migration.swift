import Foundation

/// Перенос настроек со старого имени (Peek, app.peek.mac) один раз при первом запуске.
/// Защищённые программы, адреса провайдеров и история не должны теряться из-за переименования.
enum Migration {
    private static let oldDomain = "app.peek.mac"
    private static let doneKey = "migratedFromPeek"
    private static let keys = [
        "guardedApps", "guardMode", "providerIPByNetwork", "checksOnline", "showSystemServices",
        "windowBadge", "hotKey", "notifications", "onboarded",
    ]

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        if let old = UserDefaults(suiteName: oldDomain) {
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }

        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldHistory = support.appendingPathComponent("Peek/history.json")
        let newDir = support.appendingPathComponent("VPN Lens", isDirectory: true)
        let newHistory = newDir.appendingPathComponent("history.json")
        if fm.fileExists(atPath: oldHistory.path), !fm.fileExists(atPath: newHistory.path) {
            try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
            try? fm.copyItem(at: oldHistory, to: newHistory)
        }
    }
}
