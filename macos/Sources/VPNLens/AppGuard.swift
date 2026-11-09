import AppKit
import Network
import Observation
import VPNLensCore
import VPNLensLogic

/// Защита выбранных приложений: если VPN пропал, VPN Lens их замораживает (SIGSTOP)
/// или закрывает, а когда VPN вернулся - размораживает. Что делать, запоминается
/// для каждого приложения отдельно.
///
/// Это не сетевой фильтр. Между падением туннеля и заморозкой проходят миллисекунды,
/// и что-то успевает уйти. Настоящая блокировка на уровне сети требует системного
/// расширения Network Extension, а для него нужен платный аккаунт Apple Developer.
///
/// Батарея: реакция на события сети (NWPathMonitor), плюс запасная проверка раз
/// в 5 секунд, пока список не пуст. Каждая проверка - меньше миллисекунды.
@MainActor
@Observable
final class AppGuard {
    enum Mode: String, CaseIterable, Identifiable, Codable {
        case freeze, quit
        var id: Self { self }
        var title: String { self == .freeze ? String(localized: "Заморозить") : String(localized: "Закрыть") }
        var symbol: String { self == .freeze ? "pause.circle" : "xmark.circle" }
    }

    typealias State = GuardState

    struct Guarded: Codable, Equatable, Identifiable {
        let bundleID: String
        let name: String
        var mode: Mode
        var id: String { bundleID }

        init(bundleID: String, name: String, mode: Mode) {
            self.bundleID = bundleID
            self.name = name
            self.mode = mode
        }

        // В прошлой версии режим был один на всех: записи без режима получают его.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bundleID = try c.decode(String.self, forKey: .bundleID)
            name = try c.decode(String.self, forKey: .name)
            let legacy = Mode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .freeze
            mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? legacy
        }
    }

    private(set) var guarded: [Guarded] = []
    private(set) var state: State = .off

    /// Что предлагать для нового приложения.
    var defaultMode: Mode {
        didSet { UserDefaults.standard.set(defaultMode.rawValue, forKey: Keys.mode) }
    }

    /// Браузеры на WebKit ходят в сеть через общий системный процесс: заморозка окна не поможет.
    static let unsupported: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    /// Запасная проверка VPN на случай, если событие сети не пришло.
    private static let fallbackInterval: TimeInterval = 5
    /// Список helper-процессов обновляется раз в столько проверок: 5 с x 6 = 30 с.
    private static let treeRefreshEvery = 6
    /// Сколько дать VPN устояться после возвращения, прежде чем отпускать приложения.
    private static let resumeDelay: Duration = .seconds(2)

    private enum Keys {
        static let list = "guardedApps"
        static let mode = "guardMode"
        static let frozen = "frozenPids"
    }

    private let notifier: Notifier
    private let history: History
    private let pathMonitor = NWPathMonitor()
    private var fallbackTimer: Timer?
    private var launchObserver: NSObjectProtocol?
    private var resumeTask: Task<Void, Never>?
    private var checking = false
    /// Заранее известные помощники защищённых приложений: при сбое замораживаем их
    /// сразу, не тратя ~10 мс на обход дерева процессов. Обновляется раз в 30 секунд.
    private var treeCache: [Int32: [Int32]] = [:]
    private var checksSinceTreeRefresh = 0

    /// Замороженные процессы: pid -> имя приложения. Хранятся на диске вместе со временем
    /// запуска процесса, чтобы после падения VPN Lens отпустить именно их, а не программу,
    /// которой тем временем достался тот же pid.
    private var frozen: [Int32: String] = [:] {
        didSet {
            let plain = Dictionary(uniqueKeysWithValues: frozen.map { pid, _ in
                (String(pid), ProcessInfoLite.startTime(pid) ?? 0)
            })
            UserDefaults.standard.set(plain, forKey: Keys.frozen)
        }
    }

    init(notifier: Notifier, history: History) {
        self.notifier = notifier
        self.history = history
        defaultMode = Mode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .freeze
        if let data = UserDefaults.standard.data(forKey: Keys.list),
           let list = try? JSONDecoder().decode([Guarded].self, from: data) {
            guarded = list
        }
        state = guarded.isEmpty ? .off : .waitingForVpn
        resumeLeftovers()

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        pathMonitor.start(queue: .global(qos: .userInitiated))

        // Приложение запустили, пока VPN нет: сразу делаем с ним то, что выбрано.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, case .tripped = self.state, self.mode(for: app) != nil else { return }
                self.stop([app])
            }
        }
        updateTimer()
        check()
    }

    // MARK: Список

    /// Что делать с приложением при падении VPN. nil - не защищается.
    func mode(for app: NSRunningApplication) -> Mode? {
        guard let id = app.bundleIdentifier else { return nil }
        return guarded.first { $0.bundleID == id }?.mode
    }

    /// Можно ли вообще защитить это приложение и почему нет.
    static func unsupportedReason(_ app: NSRunningApplication) -> String? {
        guard let id = app.bundleIdentifier else { return String(localized: "У программы нет идентификатора: защитить её нельзя.") }
        if unsupported.contains(id) {
            return String(localized: "Safari ходит в сеть через общий системный процесс WebKit, заморозка окна его не остановит.")
        }
        return nil
    }

    /// Включить, сменить или выключить защиту. Выбор запоминается для этого приложения.
    func setMode(_ mode: Mode?, for app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, Self.unsupportedReason(app) == nil else { return }
        setMode(mode, bundleID: id, name: app.localizedName ?? id)
    }

    func setMode(_ mode: Mode?, for item: Guarded) {
        setMode(mode, bundleID: item.bundleID, name: item.name)
    }

    private func setMode(_ mode: Mode?, bundleID: String, name: String) {
        if let mode {
            if let i = guarded.firstIndex(where: { $0.bundleID == bundleID }) {
                guarded[i].mode = mode
            } else {
                guarded.append(Guarded(bundleID: bundleID, name: name, mode: mode))
                guarded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        } else {
            guarded.removeAll { $0.bundleID == bundleID }
            // Убрали из списка во время сбоя: отпускаем именно его.
            for pid in frozen.filter({ $0.value == name }).map(\.key) {
                kill(pid, SIGCONT)
                frozen[pid] = nil
            }
        }
        save()
    }

    /// Обычные приложения, которые можно добавить.
    var candidates: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .filter { mode(for: $0) == nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(guarded) {
            UserDefaults.standard.set(data, forKey: Keys.list)
        }
        if guarded.isEmpty {
            resumeAll(reason: nil)
            state = .off
        } else if state == .off {
            state = .waitingForVpn
        }
        updateTimer()
        check()
    }

    private func updateTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        guard !guarded.isEmpty else { return }
        // Подстраховка на случай, если событие сети не пришло (прокси-клиент упал без смены интерфейсов).
        let timer = Timer(timeInterval: Self.fallbackInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = Self.fallbackInterval * 0.3
        // .common: проверка не должна вставать, пока открыто меню VPN Lens.
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    // MARK: Реакция на VPN

    func check() {
        guard !guarded.isEmpty, !checking else { return }
        checking = true
        Task {
            let up = await Task.detached { quickVpnUp(state: quickVpn()) }.value
            checking = false
            handle(vpnUp: up)
        }
    }

    private func handle(vpnUp: Bool) {
        switch GuardLogic.action(state: state, vpnUp: vpnUp) {
        case .nothing:
            return
        case .arm:
            if state != .armed || checksSinceTreeRefresh >= Self.treeRefreshEvery { refreshTreeCache() }
            checksSinceTreeRefresh += 1
            state = .armed
        case .trip:
            trip()
        case .scheduleResume:
            scheduleResume()
        case .cancelResume:
            resumeTask?.cancel()
            resumeTask = nil
        }
    }

    private func trip() {
        let running = NSWorkspace.shared.runningApplications.filter { mode(for: $0) != nil }
        stop(running)
        let name = { (app: NSRunningApplication) in app.localizedName ?? app.bundleIdentifier ?? "?" }
        let frozenNames = running.filter { mode(for: $0) == .freeze }.map(name)
        let closedNames = running.filter { mode(for: $0) == .quit }.map(name)
        state = .tripped(frozen: frozenNames, closed: closedNames)

        let summary = Self.describe(frozen: frozenNames, closed: closedNames)
        guard !summary.isEmpty else { return }
        history.add(.killSwitch, String(localized: "VPN пропал. \(summary)"))
        notifier.send(
            key: "guard-trip",
            title: String(localized: "VPN пропал"),
            body: summary + (frozenNames.isEmpty ? "" : String(localized: " Отпущу, когда VPN вернётся."))
        )
    }

    static func describe(frozen: [String], closed: [String]) -> String {
        GuardLogic.describe(frozen: frozen, closed: closed)
    }

    private func refreshTreeCache() {
        checksSinceTreeRefresh = 0
        let mains = NSWorkspace.shared.runningApplications
            .filter { mode(for: $0) == .freeze }
            .map(\.processIdentifier)
        Task {
            let tree = await Task.detached {
                Dictionary(uniqueKeysWithValues: mains.map { pid in
                    (pid, processDescendants(pid: UInt32(pid)).map { Int32($0) })
                })
            }.value
            treeCache = tree
        }
    }

    private func stop(_ apps: [NSRunningApplication]) {
        // 1. Сразу: главные процессы и заранее известные помощники. Микросекунды.
        var names: [Int32: String] = [:]
        for app in apps {
            let name = app.localizedName ?? app.bundleIdentifier ?? "?"
            switch mode(for: app) {
            case .quit:
                app.terminate()
            case .freeze:
                let main = app.processIdentifier
                names[main] = name
                for pid in [main] + (treeCache[main] ?? []) where kill(pid, SIGSTOP) == 0 {
                    frozen[pid] = name
                }
            case nil:
                continue
            }
        }
        // 2. Следом: помощники, которые появились после последнего обновления списка.
        let mains = Array(names.keys)
        guard !mains.isEmpty else { return }
        Task {
            let fresh = await Task.detached {
                mains.map { ($0, processDescendants(pid: UInt32($0)).map { Int32($0) }) }
            }.value
            for (main, children) in fresh {
                for pid in children where frozen[pid] == nil && kill(pid, SIGSTOP) == 0 {
                    frozen[pid] = names[main]
                }
            }
        }
    }

    /// VPN вернулся: даём ему пару секунд поднять маршруты и только потом отпускаем.
    private func scheduleResume() {
        guard resumeTask == nil else { return }
        resumeTask = Task {
            try? await Task.sleep(for: Self.resumeDelay)
            guard !Task.isCancelled else { return }
            let stillUp = await Task.detached { quickVpnUp(state: quickVpn()) }.value
            resumeTask = nil
            guard stillUp else { return }
            resumeAll(reason: String(localized: "VPN вернулся"))
            state = .armed
        }
    }

    /// Отпустить всех сейчас (кнопка в панели или выход из VPN Lens).
    func resumeAll(reason: String?) {
        let names = Array(Set(frozen.values)).sorted()
        for pid in frozen.keys { kill(pid, SIGCONT) }
        frozen = [:]
        if case .tripped = state { state = guarded.isEmpty ? .off : .waitingForVpn }
        if let reason, !names.isEmpty {
            history.add(.killSwitch, String(localized: "\(reason). Разморожены: \(names.joined(separator: ", "))"))
        }
    }

    /// После падения VPN Lens на диске могли остаться замороженные процессы: отпускаем.
    private func resumeLeftovers() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Keys.frozen), !saved.isEmpty else {
            return
        }
        for (key, value) in saved {
            guard let pid = Int32(key), let started = value as? UInt64 ?? (value as? NSNumber)?.uint64Value else { continue }
            // Тот же pid, но другое время запуска - это уже чужой процесс, его не трогаем.
            if started == 0 || ProcessInfoLite.startTime(pid) == started {
                kill(pid, SIGCONT)
            }
        }
        UserDefaults.standard.removeObject(forKey: Keys.frozen)
        state = guarded.isEmpty ? .off : .waitingForVpn
    }
}

/// Время запуска процесса из ядра: отличает процесс от другого с тем же pid.
enum ProcessInfoLite {
    static func startTime(_ pid: Int32) -> UInt64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }
}
