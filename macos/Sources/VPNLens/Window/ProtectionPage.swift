import SwiftUI
import VPNLensCore

// MARK: - Защита

struct ProtectionPage: View {
    @Bindable var guard_: AppGuard

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: statusSymbol).font(.title).foregroundStyle(statusTint).frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(.headline)
                        Text(statusSubtitle).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if case .tripped(let frozen, _) = guard_.state, !frozen.isEmpty {
                    Button(String(localized: "Возобновить приложения сейчас")) { guard_.resumeAll(reason: String(localized: "Возобновлены вручную")) }
                }
            }

            Section {
                if guard_.guarded.isEmpty {
                    Text(String(localized: "Пока ни одной. Добавьте программы, которые не должны выходить в сеть без VPN."))
                        .foregroundStyle(.secondary)
                }
                ForEach(guard_.guarded) { item in
                    LabeledContent {
                        GuardPicker(choice: GuardChoice(item.mode), popup: true) { guard_.setMode($0.mode, for: item) }
                    } label: {
                        HStack(spacing: 8) {
                            BundleIcon(bundleID: item.bundleID).frame(width: 20, height: 20)
                            Text(item.name)
                        }
                    }
                }
                Menu(String(localized: "Добавить приложение")) {
                    ForEach(guard_.candidates, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? "?") { guard_.setMode(guard_.defaultMode, for: app) }
                            .disabled(AppGuard.unsupportedReason(app) != nil)
                    }
                }
                .fixedSize()
            } header: {
                Text(String(localized: "Приложения"))
            } footer: {
                Text(String(localized: "Если VPN отключится, VPN Lens заморозит или закроет эти программы и возобновит замороженные, когда VPN вернётся. Safari не поддерживается: его сеть идёт через общий процесс WebKit."))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(String(localized: "Действие для новых приложений"), selection: $guard_.defaultMode) {
                    ForEach(AppGuard.Mode.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(String(localized: "Заморозка уменьшает утечку, но не исключает её: в первые миллисекунды что-то может уйти. Надёжнее всего встроенный kill switch вашего VPN-клиента."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var statusSymbol: String {
        switch guard_.state {
        case .armed: "shield.lefthalf.filled"
        case .tripped: "pause.circle.fill"
        case .waitingForVpn: "hourglass"
        case .off: "shield"
        }
    }

    private var statusTint: Color {
        switch guard_.state {
        case .armed: .accentColor
        case .tripped: .orange
        case .waitingForVpn, .off: .secondary
        }
    }

    private var statusTitle: String {
        switch guard_.state {
        case .off: String(localized: "Защита выключена")
        case .waitingForVpn: String(localized: "Ждёт VPN")
        case .armed: String(localized: "Защита включена")
        case .tripped: String(localized: "VPN отключился")
        }
    }

    private var statusSubtitle: String {
        switch guard_.state {
        case .off: String(localized: "Ни одно приложение не выбрано.")
        case .waitingForVpn: String(localized: "Включится, как только VPN Lens увидит VPN.")
        case .armed: String(localized: "Если VPN отключится, VPN Lens сразу остановит выбранные приложения.")
        case .tripped(let frozen, let closed):
            AppGuard.describe(frozen: frozen, closed: closed).isEmpty
                ? String(localized: "Защищённые приложения не запущены.")
                : AppGuard.describe(frozen: frozen, closed: closed)
        }
    }
}
