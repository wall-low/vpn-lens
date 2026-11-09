import Foundation
import Observation
import VPNLensCore
import VPNLensLogic

/// Проверка kill switch: человек выключает VPN, а мы смотрим, работал ли без него
/// интернет и какие программы успели выйти в сеть с настоящим адресом.
@MainActor
@Observable
final class KillSwitchTest {
    enum Phase: Equatable {
        case idle
        /// Ждём, пока VPN пропадёт.
        case waitingForDrop
        /// VPN нет: смотрим, кто выходит в сеть.
        case observing
        case done(Result)
    }

    typealias Result = KillSwitchResult

    private(set) var phase: Phase = .idle
    private(set) var secondsLeft = 0
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .waitingForDrop, .observing: true
        default: false
        }
    }

    private static let dropTimeout = 60
    private static let observeLimit = 45

    func start() {
        task?.cancel()
        phase = .waitingForDrop
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        phase = .idle
    }

    private func run() async {
        // 1. Ждём, пока VPN пропадёт.
        secondsLeft = Self.dropTimeout
        while secondsLeft > 0 {
            if Task.isCancelled { return }
            if await !Self.vpnActive() { break }
            try? await Task.sleep(for: .seconds(1))
            secondsLeft -= 1
        }
        // Отменили, пока ждали ответа о VPN: не переходим к наблюдению.
        if Task.isCancelled { return }
        guard secondsLeft > 0 else {
            phase = .done(Result(internetWorked: false, exposedIP: nil, apps: [], incomplete: true))
            return
        }

        // 2. VPN нет. Каждую секунду смотрим сокеты, каждые две - жив ли интернет.
        phase = .observing
        var seenApps: [String] = []
        var exposedIP: String?
        var tick = 0
        secondsLeft = Self.observeLimit
        while secondsLeft > 0 {
            if Task.isCancelled { return }
            if await Self.vpnActive() { break }

            let snapshot = await Task.detached { try? appsSnapshot(focusPid: nil) }.value
            for app in snapshot?.apps ?? [] where !app.isVpnClient && !app.isSystem && app.summary.physical > 0 {
                let name = app.displayName
                if !seenApps.contains(name) { seenApps.append(name) }
            }
            if tick % 2 == 0, exposedIP == nil {
                exposedIP = await Task.detached { quickExitIp() }.value
            }
            tick += 1
            try? await Task.sleep(for: .seconds(1))
            secondsLeft -= 1
        }

        if Task.isCancelled { return }
        phase = .done(Result(
            internetWorked: exposedIP != nil,
            exposedIP: exposedIP,
            apps: seenApps,
            incomplete: secondsLeft <= 0
        ))
    }

    private static func vpnActive() async -> Bool {
        await Task.detached { (try? vpnState())?.active ?? false }.value
    }
}
