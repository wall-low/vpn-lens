import SwiftUI
import VPNLensCore

// MARK: - Проверки

struct ChecksPage: View {
    let monitor: Monitor

    var body: some View {
        Form {
            Section {
                if let report = monitor.report {
                    ForEach(report.checks, id: \.title) { CheckRow(check: $0) }
                } else {
                    Text(monitor.checksOnline ? String(localized: "Проверяю...") : String(localized: "Сетевые проверки выключены в настройках."))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Автоматически"))
            } footer: {
                Text(String(localized: "VPN Lens проверяет сеть сам: при запуске, при смене сети или VPN и при открытии меню, если прошло больше трёх минут."))
                    .foregroundStyle(.secondary)
            }

            KillSwitchSection(test: monitor.killSwitch)
            DnsTestSection()
        }
        .formStyle(.grouped)
    }
}

private struct KillSwitchSection: View {
    let test: KillSwitchTest

    var body: some View {
        Section {
            switch test.phase {
            case .idle:
                Button(String(localized: "Начать проверку"), action: test.start)
            case .waitingForDrop:
                ProgressRow(text: String(localized: "Отключите VPN. Жду \(test.secondsLeft) с."))
                Button(String(localized: "Отменить"), action: test.cancel)
            case .observing:
                ProgressRow(text: String(localized: "VPN отключён, смотрю, кто выходит в сеть. Включите VPN обратно, когда будете готовы (осталось \(test.secondsLeft) с)."))
                Button(String(localized: "Отменить"), action: test.cancel)
            case .done(let result):
                CheckRow(check: LeakCheck(
                    id: .bypass,
                    status: result.passed ? .ok : (result.internetWorked ? .leak : .failed),
                    title: result.title,
                    summary: result.summary,
                    detail: nil
                ))
                Button(String(localized: "Проверить ещё раз"), action: test.start)
            }
        } header: {
            Text(String(localized: "Проверить kill switch"))
        } footer: {
            Text(String(localized: "Kill switch должен отрезать интернет, если VPN внезапно упадёт. Отключите VPN так, как будто он упал: например, закройте VPN-клиент через Мониторинг системы. Обычное выключение кнопкой многие клиенты не считают сбоем."))
                .foregroundStyle(.secondary)
        }
    }
}

private struct DnsTestSection: View {
    @State private var running = false
    @State private var result: DnsLeakResult?
    @State private var error: String?

    var body: some View {
        Section {
            if let result {
                CheckRow(check: LeakCheck(id: .dns, status: result.status, title: title(result.status), summary: result.summary, detail: nil))
                ForEach(result.servers, id: \.ip) { server in
                    LabeledContent(server.org.isEmpty ? server.ip : server.org) {
                        Text(server.countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .help(server.ip)
                }
            } else if let error {
                CheckRow(check: LeakCheck(id: .dns, status: .failed, title: String(localized: "Тест не удался"), summary: error, detail: nil))
            }
            if running {
                ProgressRow(text: String(localized: "Проверяю, это займёт несколько секунд..."))
            } else {
                Button(result == nil && error == nil ? String(localized: "Запустить тест") : String(localized: "Повторить"), action: run)
            }
        } header: {
            Text(String(localized: "Проверить DNS через bash.ws"))
        } footer: {
            Text(String(localized: "VPN Lens откроет несколько уникальных адресов, а сервис bash.ws покажет, какие DNS-серверы пришли за ними. Сервис увидит ваш внешний адрес и адреса ваших DNS-серверов."))
                .foregroundStyle(.secondary)
        }
    }

    private func title(_ status: CheckStatus) -> String {
        switch status {
        case .ok: String(localized: "DNS не утекает")
        case .warning, .leak: String(localized: "Возможна утечка DNS")
        default: String(localized: "Результат неясен")
        }
    }

    private func run() {
        running = true
        error = nil
        Task {
            let outcome = await Task.detached { () -> Result<DnsLeakResult, Error> in
                Result { try dnsLeakTest(lang: AppLanguage.current) }
            }.value
            running = false
            switch outcome {
            case .success(let r): result = r
            case .failure(let e): error = (e as? LensError).map { "\($0)" } ?? e.localizedDescription
            }
        }
    }
}

private struct ProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
