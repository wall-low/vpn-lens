import SwiftUI
import VPNLensCore

// MARK: - Первый запуск

struct OnboardingSheet: View {
    @Bindable var monitor: Monitor
    let done: () -> Void
    @State private var launchAtLogin = LoginItem.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 36)).foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text("VPN Lens").font(.title.weight(.semibold))
                    Text(String(localized: "Видно, как программы ходят в сеть и работает ли VPN")).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Point(symbol: "menubar.rectangle", text: String(localized: "Живёт в строке меню. Щит показывает, всё ли в порядке, а клик - что видят сайты у активной программы."))
                Point(symbol: "network", text: String(localized: "Чтобы узнать ваш внешний адрес, VPN Lens спрашивает cloudflare.com и ipify.org. Данные о программах никуда не уходят."))
                Point(symbol: "pause.circle", text: String(localized: "Может заморозить выбранные программы, если VPN отключится. Это не сетевой фильтр: надёжнее всего kill switch самого VPN-клиента."))
            }
            Divider()
            Toggle(String(localized: "Запускать VPN Lens при входе в систему"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in _ = LoginItem.set(on) }
            Toggle(String(localized: "Уведомлять, если VPN отключится или программа пойдёт мимо него"), isOn: $monitor.notificationsEnabled)
            HStack {
                Spacer()
                Button(String(localized: "Начать"), action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private struct Point: View {
        let symbol: String
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 26)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
