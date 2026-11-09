import AppKit
import Observation
import SwiftUI

enum WindowSection: String, CaseIterable, Identifiable, Hashable {
    case overview, apps, protection, checks, history, network, settings
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: String(localized: "Обзор")
        case .apps: String(localized: "Приложения")
        case .protection: String(localized: "Защита")
        case .checks: String(localized: "Проверки")
        case .history: String(localized: "История")
        case .network: String(localized: "Сеть")
        case .settings: String(localized: "Настройки")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .apps: "square.grid.2x2"
        case .protection: "shield.lefthalf.filled"
        case .checks: "checklist"
        case .history: "clock.arrow.circlepath"
        case .network: "network"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class WindowNavigation {
    var section: WindowSection? = .overview
    var selectedApp: UInt32?
    var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarded")
}

/// Окно VPN Lens. Приложение живёт в строке меню без иконки в Dock; пока окно открыто,
/// иконка появляется, чтобы к окну можно было вернуться через Cmd+Tab и Dock.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    let navigation = WindowNavigation()
    private let monitor: Monitor
    private var window: NSWindow?

    init(monitor: Monitor) {
        self.monitor = monitor
    }

    func show(_ section: WindowSection? = nil) {
        if let section { navigation.section = section }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindowView(monitor: monitor, navigation: navigation))
        // Тулбар и заголовок из SwiftUI переносятся в само окно.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "VPN Lens"
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 820, height: 560))
        window.minSize = NSSize(width: 680, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("VPNLensMainWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Окно закрыли - VPN Lens снова живёт только в строке меню.
        NSApp.setActivationPolicy(.accessory)
    }
}
