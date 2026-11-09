import SwiftUI
import VPNLensCore

/// Что меню умеет попросить у приложения: открыть окно на нужном разделе.
struct MenuActions {
    var openWindow: (WindowSection) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var menuActions = MenuActions()
}

/// Содержимое меню в строке меню: одна короткая сводка без вкладок.
/// Всё подробное живёт в окне VPN Lens.
struct MenuView: View {
    /// Ширина меню. Её же использует StatusController, чтобы задать размер пункта.
    static let width: CGFloat = 320

    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .tripped(let frozen, let closed) = monitor.appGuard.state, !(frozen.isEmpty && closed.isEmpty) {
                GuardBanner(frozen: frozen, closed: closed) {
                    monitor.appGuard.resumeAll(reason: String(localized: "Возобновлены вручную"))
                }
            }

            CurrentApp(monitor: monitor)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if let app = monitor.frontmost {
                QuickGuardRow(app: app, guard_: monitor.appGuard)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }

            Divider().padding(.horizontal, 14)
            OverallLine(monitor: monitor)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)

            Divider().padding(.horizontal, 14)
            Freshness(monitor: monitor)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .frame(width: Self.width)
    }
}

// MARK: - Активное приложение

private struct CurrentApp: View {
    let monitor: Monitor
    @Environment(\.menuActions) private var actions

    var body: some View {
        let verdict = monitor.frontmostVerdict
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 11) {
                AppIcon(app: monitor.frontmost).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.frontmost?.localizedName ?? String(localized: "Нет активного приложения"))
                        .font(.headline)
                        .lineLimit(1)
                    if let protection = verdict?.protection {
                        Label {
                            Text(protection.title).fontWeight(.medium)
                        } icon: {
                            Image(systemName: protection.symbol).foregroundStyle(protection.tint)
                        }
                        .font(.subheadline)
                    } else {
                        Text(monitor.report == nil && monitor.inspecting ? String(localized: "Проверяю сеть...") : String(localized: "Смотрю соединения..."))
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let verdict, let main = verdict.exits.first {
                // Один адрес - главный. Остальные и подробности - в окне.
                Button {
                    actions.openWindow(.overview)
                } label: {
                    HStack(spacing: 4) {
                        Text(verdict.protection == .exposed ? String(localized: "Сайты видят ваш адрес") : String(localized: "Сайты видят"))
                            .foregroundStyle(.secondary)
                        Text(main.ip).monospacedDigit()
                        if let country = main.countryName {
                            Text("· \(country)").foregroundStyle(.secondary)
                        }
                        if verdict.exits.count > 1 {
                            Text("+\(verdict.exits.count - 1)")
                                .foregroundStyle(.secondary)
                                .help(String(localized: "Часть сайтов видит другой адрес: так настроены правила VPN-клиента"))
                        }
                    }
                    .font(.callout)
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Подробнее в окне VPN Lens"))
            }

            if let protection = verdict?.protection, let hint = fixHint(for: protection, vpn: monitor.report?.vpn) {
                Label {
                    Text(hint).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb").foregroundStyle(.yellow)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Остальной Mac одной строкой

private struct OverallLine: View {
    let monitor: Monitor
    @Environment(\.menuActions) private var actions

    var body: some View {
        let (symbol, tint, text, section) = summary
        Button {
            actions.openWindow(section)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
                Text(text)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }

    private var summary: (String, Color, String, WindowSection) {
        guard let report = monitor.report else {
            return monitor.checksOnline
                ? ("hourglass", .secondary, String(localized: "Проверяю сеть..."), .overview)
                : ("pause.circle", .secondary, String(localized: "Сетевые проверки выключены"), .settings)
        }
        if report.vpn.proxyDead && report.vpn.tunnels.isEmpty {
            return ("exclamationmark.triangle.fill", .orange, String(localized: "VPN-клиент не отвечает"), .checks)
        }
        if !report.vpn.active {
            return ("shield.slash", .secondary, String(localized: "VPN не обнаружен: сайты видят адрес провайдера"), .overview)
        }
        let frontPid = monitor.app?.pid
        let exposed = monitor.apps.filter { app in
            guard app.pid != frontPid, let p = monitor.verdict(for: app)?.protection else { return false }
            return p == .exposed || p == .partial
        }
        if !exposed.isEmpty {
            let names = exposed.prefix(2).map(\.displayName).joined(separator: ", ")
            let more = exposed.count > 2 ? String(localized: " и ещё \(exposed.count - 2)") : ""
            return ("xmark.shield.fill", .red, String(localized: "Мимо VPN: \(names)\(more)"), .apps)
        }
        if let leak = report.checks.first(where: { $0.status == .leak }) {
            return ("xmark.octagon.fill", .red, leak.title, .checks)
        }
        if let warning = report.checks.first(where: { $0.status == .warning }) {
            return ("exclamationmark.triangle.fill", .orange, warning.title, .checks)
        }
        return ("checkmark.shield.fill", .green, String(localized: "Остальные программы тоже через VPN"), .apps)
    }
}

/// Подсветка строки при наведении, как у пунктов меню.
private struct MenuRowStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovered ? 0.07 : 0)))
            )
            .onHover { hovered = $0 }
    }
}

// MARK: - Низ

private struct Freshness: View {
    let monitor: Monitor

    var body: some View {
        HStack(spacing: 6) {
            if monitor.inspecting {
                ProgressView().controlSize(.mini)
                Text(String(localized: "Проверяю..."))
            } else if let date = monitor.inspectedAt {
                Text(String(localized: "Проверено в \(date.formatted(date: .omitted, time: .shortened))"))
            } else if !monitor.checksOnline {
                Text(String(localized: "Сетевые проверки выключены"))
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

/// VPN отключился, и защита приложений сработала.
struct GuardBanner: View {
    let frozen: [String]
    let closed: [String]
    let resume: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "pause.circle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "VPN отключился")).font(.callout.weight(.semibold))
                Text(AppGuard.describe(frozen: frozen, closed: closed)
                     + (frozen.isEmpty ? "" : String(localized: " Возобновлю сам, когда VPN вернётся.")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !frozen.isEmpty {
                Button(String(localized: "Возобновить"), action: resume)
                    .controlSize(.small)
                    .help(String(localized: "Разморозить сейчас, не дожидаясь VPN"))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}
