import Foundation
import UserNotifications

/// Лента событий: VPN включился и выключился, сменился адрес, что-то пошло мимо VPN.
/// Хранится в ~/Library/Application Support/VPN Lens/history.json, последние 200 записей.
@MainActor
@Observable
final class History {
    struct Event: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case vpnOn, vpnOff, exitChanged, network, leak, killSwitch }
        var id = UUID()
        let date: Date
        let kind: Kind
        let text: String
    }

    private(set) var events: [Event] = []
    private static let limit = 200

    private let url: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("VPN Lens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        if let url, let data = try? Data(contentsOf: url) {
            events = (try? JSONDecoder().decode([Event].self, from: data)) ?? []
        }
    }

    func add(_ kind: Event.Kind, _ text: String) {
        // Одно и то же подряд не пишем: опрос идёт каждые несколько секунд.
        if let last = events.first, last.kind == kind, last.text == text { return }
        events.insert(Event(date: Date(), kind: kind, text: text), at: 0)
        if events.count > Self.limit { events.removeLast(events.count - Self.limit) }
        save()
    }

    func clear() {
        events = []
        save()
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Системные уведомления. Одно и то же не повторяем чаще раза в 30 минут.
@MainActor
final class Notifier {
    private func deliver(key: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(key)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifications") }
    }

    private var lastSent: [String: Date] = [:]
    private static let cooldown: TimeInterval = 30 * 60
    private var authorized: Bool?

    func send(key: String, title: String, body: String) {
        guard enabled else { return }
        if let last = lastSent[key], Date().timeIntervalSince(last) < Self.cooldown { return }
        lastSent[key] = Date()

        if authorized == true {
            deliver(key: key, title: title, body: body)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.authorized = granted
                if granted { self.deliver(key: key, title: title, body: body) }
            }
        }
    }
}
