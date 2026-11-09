import AppKit
import SwiftUI

/// Иконка в строке меню и панель под ней.
///
/// Панель живёт внутри настоящего NSMenu (SwiftUI-вид в пункте меню). Так macOS
/// считает её открытым меню: в полноэкранном режиме строка меню не уезжает, пока
/// панель открыта, меню само закрывается по клику мимо, Esc, Cmd+Tab и смене стола,
/// а при изменении высоты растёт вниз от строки меню.
///
/// Раньше здесь было своё окно NSPanel, а ещё раньше MenuBarExtra. С окном строка
/// меню в полноэкранном режиме пряталась сразу после клика.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let monitor: Monitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let hosting: NSHostingView<AnyView>
    private let panelItem = NSMenuItem()
    /// Высота содержимого, как её меряет сам SwiftUI.
    private var contentHeight: CGFloat = 0

    private static let width = MenuView.width
    private let windows: WindowController

    init(monitor: Monitor, windows: WindowController) {
        self.monitor = monitor
        self.windows = windows
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()

        // Пока меню открыто, NSHostingController не сообщает о новом размере, поэтому
        // высоту меряем в самом SwiftUI и передаём меню вручную.
        let actions = MenuActions(openWindow: { [weak self] section in self?.openWindow(section) })
        hosting.rootView = AnyView(
            MenuView(monitor: monitor)
                .environment(\.menuActions, actions)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
                    self?.contentHeight = height
                    self?.resizePanel()
                }
        )
        hosting.sizingOptions = []
        hosting.frame.size = NSSize(width: Self.width, height: 300)
        panelItem.view = hosting
        resizePanel()
        menu.addItem(panelItem)
        menu.addItem(.separator())
        // Подписанные пункты вместо иконок без подписей: так их видно и находит VoiceOver.
        menu.addItem(withTitle: String(localized: "Открыть VPN Lens..."), action: #selector(openMain), keyEquivalent: "o").target = self
        menu.addItem(withTitle: String(localized: "Проверить сейчас"), action: #selector(checkNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: String(localized: "Скопировать отчёт"), action: #selector(copyReport), keyEquivalent: "c").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "О программе VPN Lens"), action: #selector(openAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Настройки..."), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: String(localized: "Выйти из VPN Lens"), action: #selector(quit), keyEquivalent: "q").target = self
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
    }

    // MARK: Иконка

    /// Перерисовывает иконку, как только меняется общий вердикт.
    private func updateIcon() {
        let symbol = withObservationTracking {
            monitor.overall.menuBarSymbol
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
        let description = "VPN Lens: " + monitor.overall.accessibilityText
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = description
    }

    // MARK: Меню

    func open() {
        statusItem.button?.performClick(nil)
    }

    /// Горячая клавиша: открыть меню, а если оно открыто - закрыть.
    func toggle() {
        if menuIsOpen {
            menu.cancelTracking()
        } else {
            open()
        }
    }

    private var menuIsOpen = false

    /// Закрыть меню и открыть окно. Окно открываем после выхода из цикла меню.
    private func openWindow(_ section: WindowSection) {
        menu.cancelTracking()
        DispatchQueue.main.async { [windows] in windows.show(section) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        monitor.panelOpened()
        resizePanel()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        monitor.panelClosed()
    }

    private func resizePanel() {
        let height = contentHeight > 0 ? contentHeight : hosting.fittingSize.height
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let maxHeight = (screen?.visibleFrame.height ?? 800) - 40
        let newSize = NSSize(width: Self.width, height: min(height.rounded(.up), maxHeight))
        guard hosting.frame.size != newSize else { return }
        hosting.frame.size = newSize
        // Само меню не следит за размером вида в пункте: без этого окно меню остаётся
        // прежней высоты, и верх панели срезается.
        menu.itemChanged(panelItem)
    }

    /// Всегда активен: отчёт может появиться, пока меню уже открыто.
    @objc private func copyReport() {
        monitor.copyReport()
    }

    @objc private func openMain() {
        windows.show(.overview)
    }

    @objc private func openAbout() {
        About.show()
    }

    @objc private func openSettings() {
        windows.show(.settings)
    }

    @objc private func checkNow() {
        monitor.inspect()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
