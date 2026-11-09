import SwiftUI
import VPNLensCore

// MARK: - Сеть

struct NetworkPage: View {
    let report: NetworkReport?

    var body: some View {
        Form {
            if let vpn = report?.vpn {
                Section("VPN") {
                    LabeledContent(String(localized: "Клиент"), value: vpn.client ?? String(localized: "не определён"))
                    LabeledContent(String(localized: "Туннели"), value: vpn.tunnels.isEmpty ? String(localized: "нет") : vpn.tunnels.joined(separator: ", "))
                    ForEach(Array(Set(vpn.proxy.endpoints.map { "\($0.host):\(String($0.port))" })).sorted(), id: \.self) {
                        LabeledContent(String(localized: "Системный прокси"), value: $0)
                    }
                    if let pac = vpn.proxy.pacUrl { LabeledContent("PAC", value: pac) }
                    if vpn.proxyDead {
                        Text(String(localized: "Прокси указан, но на его порту никто не слушает.")).foregroundStyle(.orange)
                    }
                }
            }
            Section(String(localized: "Интерфейсы")) {
                ForEach(VPNLensCore.interfaces().filter { $0.kind != .loopback }, id: \.name) { iface in
                    LabeledContent {
                        Text((iface.ipv4 + iface.ipv6).joined(separator: "\n"))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    } label: {
                        Label("\(iface.title) (\(iface.name))", systemImage: iface.symbol)
                    }
                }
            }
            if let probes = report?.probes, !probes.isEmpty {
                Section {
                    ForEach(Array(probes.enumerated()), id: \.offset) { _, probe in
                        LabeledContent {
                            Text(probe.ip ?? (probe.error ?? "-"))
                                .monospacedDigit()
                                .foregroundStyle(probe.ip == nil ? .secondary : .primary)
                                .lineLimit(1)
                        } label: {
                            Text("\(probe.site) · \(pathTitle(probe.path))")
                        }
                    }
                } header: {
                    Text(String(localized: "Проверочные запросы"))
                } footer: {
                    Text(String(localized: "Каждый сайт спрашивается обычным путём и через системный прокси. Запрос через Wi-Fi или Ethernet в обход туннеля показывает, можно ли выйти мимо VPN."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pathTitle(_ path: EgressPath) -> String {
        switch path {
        case .default: String(localized: "обычный путь")
        case .systemProxy: String(localized: "через прокси")
        case .physical: String(localized: "в обход туннеля")
        }
    }
}
