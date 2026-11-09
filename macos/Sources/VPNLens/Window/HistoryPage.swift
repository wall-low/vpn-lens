import SwiftUI
import VPNLensCore

// MARK: - История

struct HistoryPage: View {
    let history: History
    @State private var confirmClear = false

    var body: some View {
        List(history.events) { event in
            HStack(spacing: 10) {
                Image(systemName: symbol(event.kind)).foregroundStyle(tint(event.kind)).frame(width: 18)
                Text(event.text)
                Spacer()
                Text(event.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if history.events.isEmpty {
                ContentUnavailableView(
                    String(localized: "Пока пусто"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(String(localized: "Здесь появятся события: VPN включился или отключился, сменился адрес, программа пошла мимо VPN."))
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button(String(localized: "Очистить")) { confirmClear = true }
                    .disabled(history.events.isEmpty)
            }
        }
        .confirmationDialog(String(localized: "Очистить историю?"), isPresented: $confirmClear) {
            Button(String(localized: "Очистить"), role: .destructive, action: history.clear)
        }
    }

    private func symbol(_ kind: History.Event.Kind) -> String {
        switch kind {
        case .vpnOn: "lock.shield"
        case .vpnOff: "shield.slash"
        case .exitChanged: "globe"
        case .network: "wifi"
        case .leak: "exclamationmark.triangle"
        case .killSwitch: "bolt.shield"
        }
    }

    private func tint(_ kind: History.Event.Kind) -> Color {
        switch kind {
        case .vpnOn: .green
        case .leak: .orange
        default: .secondary
        }
    }
}
