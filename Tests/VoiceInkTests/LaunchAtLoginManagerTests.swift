import ServiceManagement
import XCTest

@testable import VoiceInk

/// Stands in for `SMAppService.mainApp`, so tests never register VoiceInk as a login item.
final class FakeLoginItem: LoginItem, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var currentStatus: SMAppService.Status
    private var started = false
    /// The status after a successful `register()`.
    let registeredStatus: SMAppService.Status
    let registerFails: Bool
    let unregisterFails: Bool
    /// When set, `register()` waits for it before it finishes.
    let registerGate: DispatchSemaphore?

    init(
        status: SMAppService.Status,
        registeredStatus: SMAppService.Status = .enabled,
        registerFails: Bool = false,
        unregisterFails: Bool = false,
        registerGate: DispatchSemaphore? = nil
    ) {
        currentStatus = status
        self.registeredStatus = registeredStatus
        self.registerFails = registerFails
        self.unregisterFails = unregisterFails
        self.registerGate = registerGate
    }

    var status: SMAppService.Status { lock.withLock { currentStatus } }

    /// True once `register()` has been called.
    var registerStarted: Bool { lock.withLock { started } }

    func register() throws {
        lock.withLock { started = true }
        registerGate?.wait()
        if registerFails { throw Failure() }
        lock.withLock { currentStatus = registeredStatus }
    }

    func unregister() throws {
        if unregisterFails { throw Failure() }
        lock.withLock { currentStatus = .notRegistered }
    }
}

@MainActor
final class LaunchAtLoginManagerTests: XCTestCase {
    func testEnablingReportsSuccess() async {
        let item = FakeLoginItem(status: .notRegistered)
        let succeeded = await LaunchAtLoginManager(loginItem: item).setEnabledAndWait(true)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(item.status, .enabled)
    }

    func testEnablingReportsAFailedRegistration() async {
        let item = FakeLoginItem(status: .notRegistered, registerFails: true)
        let succeeded = await LaunchAtLoginManager(loginItem: item).setEnabledAndWait(true)
        XCTAssertFalse(succeeded)
    }

    func testLoginItemWaitingForApprovalCountsAsEnabled() async {
        let item = FakeLoginItem(status: .notRegistered, registeredStatus: .requiresApproval)
        let succeeded = await LaunchAtLoginManager(loginItem: item).setEnabledAndWait(true)
        XCTAssertTrue(succeeded)
    }

    func testDisablingReportsSuccess() async {
        let item = FakeLoginItem(status: .enabled)
        let succeeded = await LaunchAtLoginManager(loginItem: item).setEnabledAndWait(false)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(item.status, .notRegistered)
    }

    func testDisablingReportsAFailedRemoval() async {
        let item = FakeLoginItem(status: .enabled, unregisterFails: true)
        let succeeded = await LaunchAtLoginManager(loginItem: item).setEnabledAndWait(false)
        XCTAssertFalse(succeeded)
    }

    func testLaterChangeFromThePersonCountsAsSuccess() async throws {
        let gate = DispatchSemaphore(value: 0)
        let item = FakeLoginItem(status: .notRegistered, registerGate: gate)
        let manager = LaunchAtLoginManager(loginItem: item)

        let change = Task { await manager.setEnabledAndWait(true) }
        for _ in 0..<100 where !item.registerStarted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(item.registerStarted)

        // The person turns Launch at Login off while VoiceInk's own change is still running.
        manager.setEnabled(false)
        gate.signal()
        let succeeded = await change.value

        XCTAssertTrue(succeeded, "The person's later choice must not count as a failure to retry")
        XCTAssertEqual(item.status, .notRegistered)
        XCTAssertFalse(manager.isEnabled)
    }
}
