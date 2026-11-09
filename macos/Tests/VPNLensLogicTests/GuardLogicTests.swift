import XCTest
@testable import VPNLensLogic

final class GuardLogicTests: XCTestCase {
    func testNoVpnFromTheStartNeverTrips() {
        // Человек без VPN: защита ждёт, а не замораживает всё подряд.
        XCTAssertEqual(GuardLogic.action(state: .waitingForVpn, vpnUp: false), .nothing)
        XCTAssertEqual(GuardLogic.action(state: .off, vpnUp: false), .nothing)
        XCTAssertEqual(GuardLogic.action(state: .off, vpnUp: true), .nothing)
    }

    func testFullCycle() {
        XCTAssertEqual(GuardLogic.action(state: .waitingForVpn, vpnUp: true), .arm)
        XCTAssertEqual(GuardLogic.action(state: .armed, vpnUp: true), .arm)
        XCTAssertEqual(GuardLogic.action(state: .armed, vpnUp: false), .trip)

        let tripped = GuardState.tripped(frozen: ["Telegram"], closed: [])
        XCTAssertEqual(GuardLogic.action(state: tripped, vpnUp: true), .scheduleResume)
        // VPN мигнул и снова пропал, пока ждали: отпускать нельзя.
        XCTAssertEqual(GuardLogic.action(state: tripped, vpnUp: false), .cancelResume)
    }

    func testDescribe() {
        XCTAssertEqual(GuardLogic.describe(frozen: [], closed: []), "")
        XCTAssertEqual(GuardLogic.describe(frozen: ["Telegram"], closed: []), "Заморожен: Telegram.")
        XCTAssertEqual(
            GuardLogic.describe(frozen: ["Telegram", "Chrome"], closed: ["Steam"]),
            "Заморожены: Telegram, Chrome. Закрыт: Steam."
        )
    }
}

final class KillSwitchResultTests: XCTestCase {
    func testPassedWhenNoInternetWithoutVpn() {
        let r = KillSwitchResult(internetWorked: false, exposedIP: nil, apps: ["Telegram"], incomplete: false)
        XCTAssertTrue(r.passed, "попытки без интернета - не утечка")
        XCTAssertEqual(r.title, "Kill switch сработал")
        XCTAssertTrue(r.summary.contains("Пытались выйти в сеть, но не смогли: Telegram."))
    }

    func testFailedWhenInternetWorked() {
        let r = KillSwitchResult(internetWorked: true, exposedIP: "198.51.100.7", apps: ["Chrome"], incomplete: false)
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.title, "Kill switch не сработал")
        XCTAssertTrue(r.summary.contains("198.51.100.7"))
        XCTAssertTrue(r.summary.contains("Успели выйти в сеть: Chrome."))
    }

    func testIncompleteWhenVpnNeverDropped() {
        let r = KillSwitchResult(internetWorked: false, exposedIP: nil, apps: [], incomplete: true)
        XCTAssertFalse(r.passed, "VPN не отключали - проверки не было")
        XCTAssertEqual(r.title, "Проверка не закончена")
        XCTAssertTrue(r.summary.contains("не отключился"))
    }
}
