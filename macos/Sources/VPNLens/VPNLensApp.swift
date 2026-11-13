import SwiftUI

@main
struct VPNLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Окон у приложения нет: всё живёт в строке меню (StatusController).
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Не оставлять чужие программы замороженными, если VPN Lens закрывают.
    func applicationWillTerminate(_ notification: Notification) {
        monitor?.appGuard.resumeAll(reason: String(localized: "VPN Lens закрыт"))
    }

    static private(set) weak var shared: AppDelegate?

    private(set) var monitor: Monitor?
    private(set) var status: StatusController?
    private(set) var badge: BadgeController?
    private(set) var windows: WindowController?
    private(set) var hotKey: HotKey?
    private var signalSources: [DispatchSourceSignal] = []

    /// `kill`, выход из системы через launchd, Ctrl+C: закрываемся как обычно, чтобы
    /// сработал applicationWillTerminate и замороженные программы не остались стоять.
    private func handleTerminationSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // В .app это делает LSUIElement, а здесь - для запуска через `swift run`.
        NSApp.setActivationPolicy(.accessory)
        Self.shared = self
        handleTerminationSignals()
        Migration.run()

        let monitor = Monitor()
        self.monitor = monitor
        let windows = WindowController(monitor: monitor)
        self.windows = windows
        status = StatusController(monitor: monitor, windows: windows)
        badge = BadgeController(monitor: monitor)
        hotKey = HotKey { [weak self] in self?.status?.toggle() }

        // `VPN Lens --window apps` - открыть окно на разделе (для проверки и скриншотов).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--window") {
            let section = i + 1 < args.count ? WindowSection(rawValue: args[i + 1]) : nil
            windows.navigation.showOnboarding = args.contains("--onboarding")
            windows.show(section ?? .overview)
        } else if windows.navigation.showOnboarding && !Snapshot.requested && !args.contains("--open") {
            // Первый запуск: окно с коротким объяснением, дальше VPN Lens живёт в строке меню.
            windows.show(.overview)
        }

        if Snapshot.requested {
            Snapshot.run(monitor: monitor)
        } else if CommandLine.arguments.contains("--open") {
            // Кнопке в строке меню нужно мгновение, чтобы встать на место. Таймер цикла
            // событий, а не Task: меню блокирует поток, и открывать его из задачи на
            // главном акторе значит заморозить все остальные задачи, пока оно открыто.
            let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.status?.open() }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}

/// `VPN Lens --snapshot out.png [--app Имя] [--dark]`: отрисовать содержимое меню в файл и выйти.
/// Нужно для README и чтобы проверять вёрстку без кликов. Окно снимается обычным
/// скриншотом: `VPN Lens --window <раздел>`.
@MainActor
enum Snapshot {
    static var requested: Bool { CommandLine.arguments.contains("--snapshot") }

    static func run(monitor: Monitor) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        let dark = args.contains("--dark")
        if let j = args.firstIndex(of: "--app"), j + 1 < args.count {
            let name = args[j + 1].lowercased()
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.lowercased() == name }) {
                monitor.focus(app)
            }
        }

        Task {
            // Ждём снимок сокетов и ответы проверочных сайтов.
            try? await Task.sleep(for: .seconds(9))
            let view = MenuView(monitor: monitor)
                .environment(\.isSnapshot, true)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage,
               let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
            NSApp.terminate(nil)
        }
    }
}
