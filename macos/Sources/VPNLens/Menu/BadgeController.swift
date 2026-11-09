import AppKit
import VPNLensCore
import SwiftUI

/// Маленькая плашка в правом нижнем углу активного окна: через VPN ли оно ходит.
/// Выключена по умолчанию, включается в настройках окна VPN Lens.
///
/// Положение окна берём из CGWindowList: для рамок окон разрешения не нужны
/// (Screen Recording нужен только для заголовков). Опрос 4 раза в секунду, пока плашка включена.
@MainActor
final class BadgeController {
    private let monitor: Monitor
    private let panel: NSPanel
    private let hosting: NSHostingView<BadgeView>
    private var timer: Timer?

    private static let inset: CGFloat = 12

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "windowBadge") }
        set {
            UserDefaults.standard.set(newValue, forKey: "windowBadge")
            newValue ? start() : stop()
        }
    }

    init(monitor: Monitor) {
        self.monitor = monitor
        hosting = NSHostingView(rootView: BadgeView(protection: nil, country: nil))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 26),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        panel.contentView = hosting
        if enabled { start() }
    }

    private func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        update()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func update() {
        guard let app = monitor.frontmost,
              let verdict = monitor.frontmostVerdict,
              verdict.protection != .idle, verdict.protection != .localOnly,
              let frame = Self.mainWindowFrame(pid: app.processIdentifier)
        else {
            panel.orderOut(nil)
            return
        }
        let country = verdict.protection == .exposed ? nil : verdict.exits.first?.countryCode
        let view = BadgeView(protection: verdict.protection, country: country)
        if hosting.rootView != view { hosting.rootView = view }

        let size = hosting.fittingSize
        let origin = NSPoint(x: frame.maxX - size.width - Self.inset, y: frame.minY + Self.inset)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Рамка главного окна приложения в координатах Cocoa. nil - окна нет или оно на весь экран.
    private static func mainWindowFrame(pid: pid_t) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        guard let primary = NSScreen.screens.first else { return nil }

        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"], w > 240, h > 160,
                  let x = bounds["X"], let y = bounds["Y"]
            else { continue }
            // CG считает от верхнего левого угла главного экрана, Cocoa - от нижнего левого.
            let frame = NSRect(x: x, y: primary.frame.height - y - h, width: w, height: h)
            let fullscreen = NSScreen.screens.contains { $0.frame == frame }
            return fullscreen ? nil : frame
        }
        return nil
    }
}

struct BadgeView: View, Equatable {
    let protection: Protection?
    let country: String?

    var body: some View {
        if let protection {
            HStack(spacing: 4) {
                Image(systemName: protection.symbol)
                    .foregroundStyle(protection.tint)
                Text(label(protection))
                    .foregroundStyle(.primary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .fixedSize()
        }
    }

    private func label(_ p: Protection) -> String {
        switch p {
        case .protected: country.map { "VPN · \($0)" } ?? "VPN"
        case .partial: String(localized: "часть мимо VPN")
        case .exposed: String(localized: "мимо VPN")
        case .noVpn: String(localized: "без VPN")
        case .vpnClient: String(localized: "VPN-клиент")
        case .unverified: String(localized: "не проверено")
        case .localOnly, .idle: ""
        }
    }
}
