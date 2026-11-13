import SwiftUI
import VPNLensCore

// MARK: - Приложения

struct AppsPage: View {
    let monitor: Monitor
    @Bindable var navigation: WindowNavigation
    @State private var search = ""

    private struct Item: Identifiable {
        let app: AppNetwork
        let verdict: AppVerdict?
        var id: UInt32 { app.pid }
        var rank: Int { verdict?.protection.rank ?? 9 }
    }

    private var items: [Item] {
        monitor.apps
            .filter { $0.summary.external > 0 && (monitor.showSystemServices || !$0.isSystem || isProblem($0)) }
            .filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
            .map { Item(app: $0, verdict: monitor.verdict(for: $0)) }
            .sorted { ($0.rank, $0.app.displayName) < ($1.rank, $1.app.displayName) }
    }

    private func isProblem(_ app: AppNetwork) -> Bool {
        guard let p = monitor.verdict(for: app)?.protection else { return false }
        return p == .exposed || p == .partial
    }

    var body: some View {
        let items = items
        Table(items, selection: $navigation.selectedApp) {
            TableColumn(String(localized: "Приложение")) { item in
                HStack(spacing: 8) {
                    NetworkAppIcon(app: item.app).frame(width: 18, height: 18)
                    Text(item.app.displayName)
                }
            }
            TableColumn(String(localized: "Статус")) { item in
                if let p = item.verdict?.protection {
                    Label {
                        Text(p.short)
                    } icon: {
                        Image(systemName: p.symbol).foregroundStyle(p.tint)
                    }
                }
            }
            .width(min: 120, ideal: 140)
            TableColumn(String(localized: "Соединений")) { item in
                Text("\(item.app.connections.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(80)
            TableColumn(String(localized: "Если VPN отключится")) { item in
                if let running = item.app.runningApp, running.activationPolicy == .regular,
                   AppGuard.unsupportedReason(running) == nil {
                    GuardPicker(choice: GuardChoice(monitor.appGuard.mode(for: running)), popup: true) {
                        monitor.appGuard.setMode($0.mode, for: running)
                    }
                } else {
                    Text("-").foregroundStyle(.tertiary)
                }
            }
            .width(min: 140, ideal: 150)
        }
        .searchable(text: $search, placement: .toolbar, prompt: String(localized: "Найти приложение"))
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? String(localized: "Нет соединений") : String(localized: "Ничего не найдено"),
                    systemImage: "square.grid.2x2",
                    description: Text(search.isEmpty ? String(localized: "Ни одна программа сейчас не ходит в интернет.") : String(localized: "Попробуйте другое название."))
                )
            }
        }
        .inspector(isPresented: .constant(navigation.selectedApp != nil)) {
            if let pid = navigation.selectedApp, let item = items.first(where: { $0.id == pid }) {
                AppInspector(app: item.app, verdict: item.verdict, vpn: monitor.report?.vpn)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
            }
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: Binding(get: { monitor.showSystemServices }, set: { monitor.showSystemServices = $0 })) {
                    Label(String(localized: "Службы macOS"), systemImage: "gearshape.2")
                }
                .help(String(localized: "Показывать службы macOS"))
            }
        }
    }
}

private struct AppInspector: View {
    let app: AppNetwork
    let verdict: AppVerdict?
    let vpn: VpnState?

    private struct Group: Identifiable {
        let label: String
        let route: String
        let count: Int
        var id: String { label + route }
    }

    /// Одинаковые соединения схлопываем, служебные адреса подписываем словами.
    private var groups: [Group] {
        var order: [String] = []
        var counts: [String: Group] = [:]
        for c in app.connections where c.route != .loopback {
            let label = c.remoteKind.title ?? (c.remoteAddr.contains(":") ? "[\(c.remoteAddr)]:\(c.remotePort)" : "\(c.remoteAddr):\(c.remotePort)")
            let key = label + c.route.title
            if let g = counts[key] {
                counts[key] = Group(label: g.label, route: g.route, count: g.count + 1)
            } else {
                order.append(key)
                counts[key] = Group(label: label, route: c.route.title, count: 1)
            }
        }
        return order.compactMap { counts[$0] }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    NetworkAppIcon(app: app).frame(width: 32, height: 32)
                    VStack(alignment: .leading) {
                        Text(app.displayName).font(.headline)
                        if let p = verdict?.protection {
                            Text(p.title).foregroundStyle(p == .protected ? .secondary : p.tint)
                        }
                    }
                }
                if let p = verdict?.protection {
                    Text(p.explanation).font(.callout).foregroundStyle(.secondary)
                    if let hint = fixHint(for: p, vpn: vpn) {
                        Label(hint, systemImage: "lightbulb").font(.callout)
                    }
                }
            }
            if let verdict, !verdict.exits.isEmpty {
                Section(String(localized: "Сайты видят")) {
                    ForEach(verdict.exits, id: \.ip) { exit in
                        LabeledContent(exit.kind.title) {
                            Text(exit.ip).monospacedDigit().textSelection(.enabled)
                        }
                    }
                }
            }
            Section(String(localized: "Соединения")) {
                ForEach(groups) { g in
                    LabeledContent {
                        Text(g.count > 1 ? "×\(g.count) · \(g.route)" : g.route).foregroundStyle(.secondary)
                    } label: {
                        Text(g.label).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
