import SwiftUI
import VPNLensCore

// MARK: - Обзор

struct OverviewPage: View {
    let monitor: Monitor
    let navigation: WindowNavigation

    var body: some View {
        Form {
            Section {
                StatusHeader(overall: monitor.overall, report: monitor.report, inspecting: monitor.inspecting)
            }

            if let report = monitor.report {
                Section(String(localized: "Сайты видят")) {
                    ForEach(report.exits, id: \.ip) { exit in
                        LabeledContent {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(exit.ip).monospacedDigit().textSelection(.enabled)
                                Text(exit.caption).font(.caption).foregroundStyle(.secondary)
                            }
                        } label: {
                            Text(exit.kind.title)
                        }
                    }
                    // Адрес запроса в обход туннеля - не правило для сайтов, его не считаем.
                    if report.exits.filter({ $0.paths.contains { $0 != .physical } }).count > 1 {
                        Text(String(localized: "Адрес зависит от сайта: VPN-клиент пускает часть сайтов другим путём."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("VPN") {
                    LabeledContent(String(localized: "Клиент"), value: report.vpn.client ?? (report.vpn.active ? String(localized: "не определён") : String(localized: "не обнаружен")))
                    LabeledContent(String(localized: "Туннель"), value: report.vpn.tunnels.isEmpty ? String(localized: "нет") : report.vpn.tunnels.joined(separator: ", "))
                    LabeledContent(String(localized: "Системный прокси"), value: report.vpn.proxy.endpoints.first.map { "\($0.host):\(String($0.port))" } ?? String(localized: "нет"))
                }

                Section {
                    ForEach(report.checks, id: \.title) { CheckRow(check: $0) }
                } header: {
                    HStack {
                        Text(String(localized: "Проверки"))
                        Spacer()
                        Button(String(localized: "Подробнее")) { navigation.section = .checks }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct StatusHeader: View {
    let overall: Monitor.Overall
    let report: NetworkReport?
    let inspecting: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var symbol: String {
        switch overall {
        case .protected: "checkmark.shield.fill"
        case .warning: "exclamationmark.shield.fill"
        case .leak: "xmark.shield.fill"
        case .noVpn: "shield.slash"
        case .unknown: "shield"
        }
    }

    private var tint: Color {
        switch overall {
        case .protected: .green
        case .warning: .orange
        case .leak: .red
        case .noVpn, .unknown: .secondary
        }
    }

    private var title: String {
        switch overall {
        case .protected: String(localized: "Защищено")
        case .warning: String(localized: "Есть риск")
        case .leak: String(localized: "Есть трафик мимо VPN")
        case .noVpn: String(localized: "VPN не обнаружен")
        case .unknown: inspecting ? String(localized: "Проверяю сеть") : String(localized: "Не проверено")
        }
    }

    private var subtitle: String {
        switch overall {
        case .protected: String(localized: "Проверенные соединения идут через VPN.")
        case .warning: String(localized: "Утечек не видно, но одна из проверок нашла риск.")
        case .leak: String(localized: "Часть трафика идёт через обычную сеть, и эти сайты видят ваш адрес.")
        case .noVpn: report?.vpn.proxyDead == true ? String(localized: "Прокси VPN-клиента указан, но не отвечает.") : String(localized: "Сейчас VPN Lens не видит VPN. Проверьте, включён ли он.")
        case .unknown: inspecting ? String(localized: "Это займёт несколько секунд.") : String(localized: "Сетевые проверки выключены в настройках.")
        }
    }
}
