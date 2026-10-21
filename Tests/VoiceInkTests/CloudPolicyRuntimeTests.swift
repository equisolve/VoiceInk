import Foundation
import XCTest

@testable import VoiceInk

/// Policy changes while the app runs move model selection off cloud models and back.
@MainActor
final class CloudPolicyRuntimeTests: XCTestCase {
    private let key = CloudPolicy.disableCloudServicesKey
    private let modelKey = "CurrentTranscriptionModel"
    private var savedValue: Any?
    private var savedModel: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedValue = UserDefaults.standard.object(forKey: key)
        savedModel = UserDefaults.standard.object(forKey: modelKey)
        UserDefaults.standard.removeObject(forKey: key)
        CloudPolicyMonitor.shared.start()
        CloudPolicyMonitor.shared.refresh()
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedValue, forKey: key)
        UserDefaults.standard.set(savedModel, forKey: modelKey)
        CloudPolicyMonitor.shared.refresh()
        try await super.tearDown()
    }

    private func makeManager() -> TranscriptionModelManager {
        let modelsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return TranscriptionModelManager(
            whisperModelManager: WhisperModelManager(modelsDirectory: modelsDirectory),
            fluidAudioModelManager: FluidAudioModelManager()
        )
    }

    private func waitForPolicyChange(_ change: () throws -> Void) async throws {
        let notified = expectation(forNotification: .cloudPolicyDidChange, object: nil)
        try change()
        await fulfillment(of: [notified], timeout: 5)
    }

    func testKeyChangeMovesOffCloudModelAndBack() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Needs Apple Speech as the local fallback model") }

        let cloudModel = try XCTUnwrap(
            TranscriptionModelRegistry.models.first { !CloudPolicy.isLocalTranscriptionProvider($0.provider) }
        )
        UserDefaults.standard.set(cloudModel.selectionKey, forKey: modelKey)
        let manager = makeManager()
        manager.loadCurrentTranscriptionModel()
        XCTAssertEqual(manager.currentTranscriptionModel?.selectionKey, cloudModel.selectionKey)

        try await waitForPolicyChange { UserDefaults.standard.set(true, forKey: key) }
        let fallback = try XCTUnwrap(manager.currentTranscriptionModel)
        XCTAssertTrue(CloudPolicy.isLocalTranscriptionProvider(fallback.provider), "Moved to \(fallback.name)")
        XCTAssertEqual(UserDefaults.standard.string(forKey: modelKey), cloudModel.selectionKey, "Saved choice is kept")

        // A refresh while blocked must not save the local stand-in over the user's choice.
        manager.refreshAllAvailableModels()
        XCTAssertEqual(UserDefaults.standard.string(forKey: modelKey), cloudModel.selectionKey)

        try await waitForPolicyChange { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertEqual(manager.currentTranscriptionModel?.selectionKey, cloudModel.selectionKey)
    }

    func testChangeFromAnotherProcessIsObserved() async throws {
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)

        try await waitForPolicyChange {
            try runDefaults(["write", domain, key, "-bool", "true"])
        }
        XCTAssertFalse(CloudPolicyMonitor.shared.isCloudAllowed)

        try await waitForPolicyChange {
            try runDefaults(["delete", domain, key])
        }
        XCTAssertTrue(CloudPolicyMonitor.shared.isCloudAllowed)
    }

    private func runDefaults(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "defaults \(arguments.joined(separator: " "))")
    }
}
