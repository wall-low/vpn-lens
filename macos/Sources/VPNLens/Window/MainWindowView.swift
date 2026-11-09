import SwiftUI
import VPNLensCore

/// Окно VPN Lens: боковая панель и подробные разделы.
struct MainWindowView: View {
    @Bindable var monitor: Monitor
    @Bindable var navigation: WindowNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.section) {
                Section {
                    ForEach([WindowSection.overview, .apps, .protection, .checks, .history]) { section in
                        Label(section.title, systemImage: section.symbol)
                            .badge(badge(for: section))
                            .tag(section)
                    }
                }
                Section {
                    ForEach([WindowSection.network, .settings]) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                switch navigation.section ?? .overview {
                case .overview: OverviewPage(monitor: monitor, navigation: navigation)
                case .apps: AppsPage(monitor: monitor, navigation: navigation)
                case .protection: ProtectionPage(guard_: monitor.appGuard)
                case .checks: ChecksPage(monitor: monitor)
                case .history: HistoryPage(history: monitor.history)
                case .network: NetworkPage(report: monitor.report)
                case .settings: SettingsPage(monitor: monitor)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        monitor.inspect()
                    } label: {
                        Label(String(localized: "Проверить сейчас"), systemImage: "arrow.clockwise")
                    }
                    .disabled(monitor.inspecting || !monitor.checksOnline)
                    .help(String(localized: "Проверить сеть заново"))
                }
            }
        }
        // Заголовок на уровне всего окна: внутри разделов его перебивают поиск и тулбары.
        .navigationTitle((navigation.section ?? .overview).title)
        .task {
            // `--tour`: разделы по очереди, для GIF в README.
            guard CommandLine.arguments.contains("--tour") else { return }
            try? await Task.sleep(for: .seconds(4))
            for section in Demo.tourSections + [Demo.tourSections[0]] {
                navigation.section = section
                try? await Task.sleep(for: Demo.tourStep)
            }
        }
        .sheet(isPresented: $navigation.showOnboarding) {
            OnboardingSheet(monitor: monitor) {
                UserDefaults.standard.set(true, forKey: "onboarded")
                navigation.showOnboarding = false
            }
        }
    }

    private func badge(for section: WindowSection) -> Int {
        switch section {
        case .apps:
            monitor.apps.filter { app in
                guard let p = monitor.verdict(for: app)?.protection else { return false }
                return p == .exposed || p == .partial
            }.count
        case .protection: monitor.appGuard.guarded.count
        case .checks: monitor.report?.checks.filter { $0.status == .leak || $0.status == .warning }.count ?? 0
        default: 0
        }
    }
}
