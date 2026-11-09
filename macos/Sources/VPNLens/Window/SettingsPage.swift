import SwiftUI
import VPNLensCore

// MARK: - Настройки

struct SettingsPage: View {
    @Bindable var monitor: Monitor
    @State private var launchAtLogin = LoginItem.enabled
    @State private var loginError: String?
    @State private var hotKey = HotKeyOption.saved
    @State private var badge = UserDefaults.standard.bool(forKey: "windowBadge")
    @State private var confirmForget = false
    @State private var language = LanguageChoice.saved

    /// Выбранный язык отличается от того, с которым приложение запущено.
    private var needsRestart: Bool {
        let wanted = language == .system ? LanguageChoice.systemResolved : language
        return wanted != LanguageChoice.running
    }

    var body: some View {
        Form {
            Section(String(localized: "Основные")) {
                Toggle(String(localized: "Запускать VPN Lens при входе в систему"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        loginError = LoginItem.set(on)
                        launchAtLogin = LoginItem.enabled
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                } else if LoginItem.needsApproval {
                    Text(String(localized: "Разрешите запуск в Системных настройках → Основные → Объекты входа."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker(String(localized: "Язык интерфейса"), selection: $language) {
                    ForEach(LanguageChoice.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .onChange(of: language) { _, choice in choice.apply() }
                if needsRestart {
                    HStack {
                        Text(String(localized: "Язык сменится после перезапуска VPN Lens."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Перезапустить")) { Relaunch.now() }
                            .controlSize(.small)
                    }
                }
                Picker(String(localized: "Открыть меню VPN Lens сочетанием"), selection: $hotKey) {
                    ForEach(HotKeyOption.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: hotKey) { _, option in AppDelegate.shared?.hotKey?.apply(option) }
            }

            Section {
                Toggle(String(localized: "Проверять через интернет"), isOn: $monitor.checksOnline)
                Toggle(String(localized: "Проверять ещё и региональный сайт (ip.nic.ru)"), isOn: $monitor.regionalSite)
                    .help(String(localized: "Если VPN-клиент пускает сайты в зоне .ru другим путём, так будет видно, что адрес зависит от сайта."))
                Toggle(String(localized: "Показывать службы macOS"), isOn: $monitor.showSystemServices)
                Toggle(String(localized: "Плашка в углу активного окна"), isOn: $badge)
                    .onChange(of: badge) { _, on in AppDelegate.shared?.badge?.enabled = on }
            } header: {
                Text(String(localized: "Мониторинг"))
            } footer: {
                Text(String(localized: "Проверка через интернет отправляет запросы на cloudflare.com, ipify.org и STUN-серверы Google и Cloudflare, а с региональным сайтом ещё и на ip.nic.ru. Сайты видят только ваш внешний адрес, данные о программах никуда не уходят."))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "Уведомления"), isOn: $monitor.notificationsEnabled)
            } header: {
                Text(String(localized: "Уведомления"))
            } footer: {
                Text(String(localized: "Когда VPN отключился, когда программа пошла мимо VPN и когда проверка нашла утечку. Одно и то же - не чаще раза в 30 минут."))
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Данные")) {
                Button(String(localized: "Забыть адреса провайдеров...")) { confirmForget = true }
                    .confirmationDialog(String(localized: "Забыть адреса провайдеров?"), isPresented: $confirmForget) {
                        Button(String(localized: "Забыть"), role: .destructive, action: monitor.forgetProviders)
                    } message: {
                        Text(String(localized: "VPN Lens запоминает адрес провайдера для каждой сети, когда VPN выключен. Без него второй адрес будет подписан как «другой», пока VPN снова не выключат."))
                    }
            }
        }
        .formStyle(.grouped)
    }
}
