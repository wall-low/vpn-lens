import AppKit
import Network
import Observation
import VPNLensCore

/// Состояние панели. Всё, что ходит в Rust, выполняется вне главного потока.
@MainActor
@Observable
final class Monitor {
    private(set) var frontmost: NSRunningApplication?
    /// Сеть активного приложения.
    private(set) var app: AppNetwork?
    /// Все приложения с соединениями.
    private(set) var apps: [AppNetwork] = []
    /// Вердикты по pid, пересчитываются при новом снимке или новом отчёте.
    private(set) var verdicts: [UInt32: AppVerdict] = [:]
    private(set) var report: NetworkReport?
    private(set) var inspecting = false
    private(set) var inspectedAt: Date?
    private(set) var updatedAt: Date?

    let history = History()
    let notifier = Notifier()
    let killSwitch = KillSwitchTest()
    let appGuard: AppGuard

    /// Полная проверка ходит на проверочные сайты, поэтому выключается в настройках.
    var checksOnline: Bool {
        didSet {
            UserDefaults.standard.set(checksOnline, forKey: Keys.online)
            if checksOnline { inspect() } else { report = nil; recomputeVerdicts() }
        }
    }

    var notificationsEnabled: Bool {
        get { notifier.enabled }
        set { notifier.enabled = newValue }
    }

    var showSystemServices: Bool {
        didSet { UserDefaults.standard.set(showSystemServices, forKey: Keys.services) }
    }

    /// Спрашивать ещё и ip.nic.ru. По умолчанию - при регионе Россия или русском интерфейсе: там VPN-клиенты
    /// часто пускают зону .ru мимо сервера, и без этого сайта такие правила не видны.
    var regionalSite: Bool {
        didSet {
            UserDefaults.standard.set(regionalSite, forKey: Keys.regional)
            inspect()
        }
    }

    private enum Keys {
        static let online = "checksOnline"
        static let providers = "providerIPByNetwork"
        static let services = "showSystemServices"
        static let regional = "regionalSite"
    }

    // MARK: Адрес провайдера по сетям

    /// Адрес провайдера, увиденный без VPN, отдельно для каждой сети (дом, работа, кафе).
    private var providers: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Keys.providers) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.providers) }
    }

    func forgetProviders() {
        providers = [:]
        inspect()
    }

    // MARK: Опрос

    private static let reportMaxAge: TimeInterval = 180
    /// Панель открыта - обновляем часто; закрыта - реже, только ради иконки и уведомлений.
    private static let openInterval: TimeInterval = 3
    private static let closedInterval: TimeInterval = 10

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var pathDebounce: Task<Void, Never>?
    private var pinned = false

    /// Растёт при каждой смене сети. Проверка, начатая в старой сети, отбрасывается.
    private var networkGeneration = 0
    private var reinspectWhenDone = false
    /// Растёт при каждом опросе приложений. Опоздавший старый ответ не перезапишет новый.
    private var refreshGeneration = 0

    init() {
        appGuard = AppGuard(notifier: notifier, history: history)
        checksOnline = UserDefaults.standard.object(forKey: Keys.online) as? Bool ?? true
        showSystemServices = UserDefaults.standard.bool(forKey: Keys.services)
        regionalSite = UserDefaults.standard.object(forKey: Keys.regional) as? Bool
            ?? (Locale.current.region?.identifier == "RU" || AppLanguage.current == .ru)
        frontmost = Self.otherFrontmostApp()

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app) }
        }

        // VPN включили или выключили, сменилась сеть: результаты проверки устарели.
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        schedule(interval: Self.closedInterval)
        refreshApps()
        inspect()
    }

    func panelOpened() {
        schedule(interval: Self.openInterval)
        refreshApps()
        let stale = inspectedAt.map { Date().timeIntervalSince($0) > Self.reportMaxAge } ?? true
        if stale { inspect() }
    }

    func panelClosed() {
        schedule(interval: Self.closedInterval)
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        // .common: панель живёт в меню, а пока меню открыто, run loop крутится в режиме трекинга.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshApps() }
        }
        timer.tolerance = interval / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Вердикты

    func verdict(for app: AppNetwork) -> AppVerdict? {
        verdicts[app.pid]
    }

    var frontmostVerdict: AppVerdict? {
        guard let app, let report else { return nil }
        return verdicts[app.pid] ?? appVerdict(app: app, report: report)
    }

    /// Худшее, что сейчас происходит: для иконки в строке меню.
    var overall: Overall {
        guard let report else { return .unknown }
        if !report.vpn.active { return .noVpn }
        let leaking = verdicts.values.contains { $0.protection == .exposed || $0.protection == .partial }
        if leaking || report.checks.contains(where: { $0.status == .leak }) { return .leak }
        if report.checks.contains(where: { $0.status == .warning }) { return .warning }
        return .protected
    }

    enum Overall { case protected, warning, leak, noVpn, unknown }

    private func recomputeVerdicts() {
        guard let report else {
            verdicts = [:]
            return
        }
        var result: [UInt32: AppVerdict] = [:]
        for app in apps { result[app.pid] = appVerdict(app: app, report: report) }
        if let app { result[app.pid] = appVerdict(app: app, report: report) }
        verdicts = result
        noticeExposedApps()
    }

    // MARK: Проверка сети

    func inspect() {
        guard checksOnline else { return }
        guard !inspecting else {
            reinspectWhenDone = true
            return
        }
        inspecting = true
        reinspectWhenDone = false
        let generation = networkGeneration
        Task {
            // Сеть ещё не знаем, поэтому адрес провайдера подставим после первого снимка VPN.
            let vpn = await Task.detached { try? vpnState() }.value
            let known = vpn?.networkId.flatMap { self.providers[$0] }
            let options = InspectOptions(lang: AppLanguage.current, regionalSite: self.regionalSite)
            let report = await Task.detached { inspectNetwork(knownProviderIp: known, options: options) }.value
            self.inspecting = false

            // Пока проверяли, сеть сменилась: этот результат про старую сеть.
            if generation != self.networkGeneration || self.reinspectWhenDone {
                self.inspect()
                return
            }
            let previous = self.report
            self.report = Demo.enabled ? Demo.anonymize(report) : report
            self.inspectedAt = Date()
            self.rememberProvider(from: report)
            self.recomputeVerdicts()
            self.recordChanges(from: previous, to: report)
        }
    }

    /// Без VPN внешний адрес - это и есть провайдер. С VPN - только если обход удался.
    private func rememberProvider(from report: NetworkReport) {
        guard let ip = report.providerIp, let network = report.vpn.networkId else { return }
        if !report.vpn.active || report.bypassBlocked == false {
            providers[network] = ip
        }
    }

    // MARK: История и уведомления

    private func recordChanges(from old: NetworkReport?, to new: NetworkReport) {
        // Первая проверка после запуска VPN Lens - это не событие: сравнивать не с чем.
        guard let old else { return }
        let wasActive: Bool? = old.vpn.active
        if wasActive != new.vpn.active {
            if new.vpn.active {
                history.add(.vpnOn, String(localized: "VPN включился") + (new.vpn.client.map { ": \($0)" } ?? ""))
            } else {
                history.add(.vpnOff, String(localized: "VPN выключен"))
                // Если сработала защита приложений, она уже сообщила сама.
                let guardTripped = if case .tripped = appGuard.state { true } else { false }
                if wasActive == true, !killSwitch.isRunning, !guardTripped {
                    let online = apps.filter { $0.summary.external > 0 && !$0.isSystem && !$0.isVpnClient }
                    let names = online.prefix(3).map(\.displayName).joined(separator: ", ")
                    let more = online.count > 3 ? String(localized: " и ещё \(online.count - 3)") : ""
                    notifier.send(
                        key: "vpn-off",
                        title: String(localized: "VPN отключился"),
                        body: online.isEmpty
                            ? String(localized: "Сайты теперь видят ваш настоящий адрес.")
                            : String(localized: "Продолжают работать напрямую: \(names)\(more).")
                    )
                }
            }
        }

        let mainExit = new.exits.first { $0.kind != .provider } ?? new.exits.first
        let oldExit = old.exits.first { $0.kind != .provider } ?? old.exits.first
        if let mainExit, mainExit.ip != oldExit?.ip {
            let country = mainExit.countryName.map { " (\($0))" } ?? ""
            history.add(.exitChanged, String(localized: "Сайты видят \(mainExit.ip)\(country)"))
        }
        if old.vpn.networkId != new.vpn.networkId {
            history.add(.network, String(localized: "Другая сеть") + (new.vpn.physical.map { ": \($0)" } ?? ""))
        }
        for check in new.checks where check.status == .leak {
            let wasLeak = old.checks.contains { $0.id == check.id && $0.status == .leak }
            if !wasLeak {
                history.add(.leak, check.title)
                notifier.send(key: "check-\(check.id)", title: check.title, body: check.summary)
            }
        }
    }

    /// Кто ходил мимо VPN в прошлый раз: сообщаем только о новых.
    private var exposedNames: Set<String> = []

    /// Программа начала ходить мимо VPN: пишем в историю и сообщаем.
    private func noticeExposedApps() {
        guard report?.vpn.active == true, !killSwitch.isRunning else {
            exposedNames = []
            return
        }
        var now: Set<String> = []
        for app in apps where !app.isVpnClient {
            guard let verdict = verdicts[app.pid], verdict.protection == .exposed || verdict.protection == .partial else {
                continue
            }
            let name = app.displayName
            now.insert(name)
            guard !exposedNames.contains(name) else { continue }
            let address = (verdict.protection == .exposed ? verdict.exits : verdict.exposedExits).first?.ip
            history.add(.leak, String(localized: "\(name) ходит мимо VPN"))
            notifier.send(
                key: "app-\(name)",
                title: String(localized: "\(name) ходит мимо VPN"),
                body: address.map { String(localized: "Сайты видят ваш настоящий адрес \($0).") } ?? String(localized: "Сайты видят ваш настоящий адрес.")
            )
        }
        exposedNames = now
    }

    // MARK: Приложения

    func focus(_ app: NSRunningApplication) {
        activated(app)
        pinned = true
    }

    private func activated(_ app: NSRunningApplication?) {
        // Клик по панели активирует сам VPN Lens - это не повод показывать его сеть.
        guard !pinned, let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        frontmost = app
        self.app = nil
        refreshApps()
    }

    func refreshApps() {
        let pid = frontmost?.processIdentifier
        let usesWebKitNetworking = Self.webKitBrowsers.contains(frontmost?.bundleIdentifier ?? "")
        refreshGeneration += 1
        let generation = refreshGeneration
        Task {
            let snapshot = await Task.detached { try? appsSnapshot(focusPid: pid.map { UInt32($0) }) }.value
            guard generation == self.refreshGeneration, let snapshot else { return }
            var current = snapshot.focus
            // Сеть Safari живёт в отдельном XPC-сервисе, который запускает launchd.
            if usesWebKitNetworking, (current?.summary.external ?? 0) == 0,
               let webkit = snapshot.apps.first(where: { $0.name == Self.webKitNetworking }) {
                current = webkit
            }
            self.apps = snapshot.apps
            if pid == self.frontmost?.processIdentifier {
                self.app = current
            }
            self.updatedAt = Date()
            self.recomputeVerdicts()
        }
    }

    private func networkChanged() {
        networkGeneration += 1
        pathDebounce?.cancel()
        pathDebounce = Task {
            // VPN-клиенты поднимают туннель в несколько шагов: ждём, пока всё уляжется.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            inspect()
        }
    }

    // MARK: Продвинутое

    func copyReport() {
        guard let report else { return }
        let text = formatReport(report: report, apps: apps, lang: AppLanguage.current)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    nonisolated static let webKitNetworking = "com.apple.WebKit.Networking"
    private static let webKitBrowsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    private static func otherFrontmostApp() -> NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    }
}
