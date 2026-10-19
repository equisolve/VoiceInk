import XCTest

@testable import VoiceInk

/// Stands in for the running app so tests can see what managed defaults change.
@MainActor
private final class FakeManagedDefaultsTarget: ManagedDefaultsTarget {
    var transcriptionModels: [any TranscriptionModel] = TranscriptionModelRegistry.models
    var currentTranscriptionSelectionKey: String? = "apple-speech"
    var canApplySettings = true
    var downloaded: [ManagedModelDownload] = []
    var downloading: [ManagedModelDownload] = []

    var selectedModels: [String] = []
    var enhancements: [(provider: AIProvider?, model: String?, enabled: Bool?)] = []
    var startedDownloads: [ManagedModelDownload] = []

    func isDownloaded(_ download: ManagedModelDownload) -> Bool { downloaded.contains(download) }
    func isDownloading(_ download: ManagedModelDownload) -> Bool { downloading.contains(download) }
    func startDownload(_ download: ManagedModelDownload) { startedDownloads.append(download) }

    func selectTranscriptionModel(_ model: any TranscriptionModel) {
        selectedModels.append(model.selectionKey)
        currentTranscriptionSelectionKey = model.selectionKey
    }

    func applyEnhancement(provider: AIProvider?, model: String?, enabled: Bool?) {
        enhancements.append((provider, model, enabled))
    }
}

/// Every test reads and writes its own defaults suite, never the app's settings.
@MainActor
final class ManagedDefaultsTests: XCTestCase {
    private let parakeet = "parakeet-tdt-0.6b-v3"
    private let parakeetV2 = "parakeet-tdt-0.6b-v2"
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var target: FakeManagedDefaultsTarget!
    private var cloudAllowed = true

    override func setUp() async throws {
        suiteName = "ManagedDefaultsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        target = FakeManagedDefaultsTarget()
        cloudAllowed = true
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeApplier() -> ManagedDefaultsApplier {
        ManagedDefaultsApplier(defaults: defaults, target: target, isCloudAllowed: { [unowned self] in cloudAllowed })
    }

    private func setProfile(
        transcription: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        enabled: Bool? = nil,
        downloads: [String]? = nil,
        version: Int?
    ) {
        defaults.set(transcription, forKey: ManagedDefaults.transcriptionModelKey)
        defaults.set(provider, forKey: ManagedDefaults.enhancementProviderKey)
        defaults.set(model, forKey: ManagedDefaults.enhancementModelKey)
        defaults.set(enabled, forKey: ManagedDefaults.enhancementEnabledKey)
        defaults.set(downloads, forKey: ManagedDefaults.autoDownloadModelsKey)
        defaults.set(version, forKey: ManagedDefaults.versionKey)
    }

    private var cloudTranscriptionModel: any TranscriptionModel {
        TranscriptionModelRegistry.models.first {
            !CloudPolicy.isLocalTranscriptionProvider($0.provider) && $0.provider != .custom
                && $0.provider != .openRouter
        }!
    }

    // MARK: - Apply once

    func testAppliesOnceOnly() {
        target.downloaded = [.transcription(selectionKey: parakeet)]
        setProfile(transcription: parakeet, provider: "VoiceInk Refine", enabled: true, version: 1)

        makeApplier().apply()
        XCTAssertEqual(target.selectedModels, [parakeet])
        XCTAssertEqual(target.enhancements.count, 1)
        XCTAssertEqual(target.enhancements.first?.provider, .voiceInkRefine)
        XCTAssertEqual(target.enhancements.first?.enabled, true)
        XCTAssertEqual(defaults.integer(forKey: ManagedDefaults.appliedVersionKey), 1)

        makeApplier().apply()
        makeApplier().apply()
        XCTAssertEqual(target.selectedModels, [parakeet], "The same version must not be applied twice")
        XCTAssertEqual(target.enhancements.count, 1)
    }

    func testVersionBumpReapplies() {
        target.downloaded = [.transcription(selectionKey: parakeet)]
        setProfile(transcription: parakeet, version: 1)
        makeApplier().apply()

        target.currentTranscriptionSelectionKey = parakeetV2
        defaults.set(2, forKey: ManagedDefaults.versionKey)
        makeApplier().apply()

        XCTAssertEqual(target.selectedModels, [parakeet, parakeet])
        XCTAssertEqual(target.currentTranscriptionSelectionKey, parakeet)
        XCTAssertEqual(defaults.integer(forKey: ManagedDefaults.appliedVersionKey), 2)
    }

    func testLowerVersionDoesNotApply() {
        defaults.set(5, forKey: ManagedDefaults.appliedVersionKey)
        target.downloaded = [.transcription(selectionKey: parakeet)]
        setProfile(transcription: parakeet, version: 4)

        makeApplier().apply()

        XCTAssertEqual(target.selectedModels, [])
        XCTAssertEqual(defaults.integer(forKey: ManagedDefaults.appliedVersionKey), 5)
    }

    func testUserChangeSurvivesRelaunch() {
        target.downloaded = [.transcription(selectionKey: parakeet)]
        setProfile(transcription: parakeet, provider: "VoiceInk Refine", enabled: true, version: 1)
        makeApplier().apply()

        // The person picks another model, then VoiceInk relaunches with the same profile.
        target.currentTranscriptionSelectionKey = parakeetV2
        let relaunched = FakeManagedDefaultsTarget()
        relaunched.currentTranscriptionSelectionKey = parakeetV2
        relaunched.downloaded = target.downloaded
        target = relaunched
        makeApplier().apply()

        XCTAssertEqual(target.selectedModels, [])
        XCTAssertEqual(target.enhancements.count, 0)
        XCTAssertEqual(target.currentTranscriptionSelectionKey, parakeetV2)
    }

    func testMissingVersionAppliesNothing() {
        target.downloaded = [.transcription(selectionKey: parakeet)]
        setProfile(transcription: parakeet, downloads: [parakeet], version: nil)

        makeApplier().apply()

        XCTAssertEqual(target.selectedModels, [])
        XCTAssertNil(defaults.object(forKey: ManagedDefaults.appliedVersionKey))
    }

    func testWaitsForOnboardingBeforeApplying() {
        target.canApplySettings = false
        target.downloaded = [.transcription(selectionKey: parakeet)]
        setProfile(transcription: parakeet, downloads: ["VoiceInk Refine V1"], version: 1)

        makeApplier().apply()
        XCTAssertEqual(target.selectedModels, [])
        XCTAssertEqual(target.startedDownloads, [.voiceInkRefine], "Downloads start during onboarding")
        XCTAssertEqual(defaults.integer(forKey: ManagedDefaults.appliedVersionKey), 0)

        target.canApplySettings = true
        makeApplier().apply()
        XCTAssertEqual(target.selectedModels, [parakeet])
    }

    func testRuntimeProfileChangeApplies() async throws {
        target.downloaded = [.transcription(selectionKey: parakeet)]
        let applier = makeApplier()
        applier.start()
        defer { applier.stop() }
        XCTAssertEqual(target.selectedModels, [])

        setProfile(transcription: parakeet, version: 1)
        for _ in 0..<50 where target.selectedModels.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(target.selectedModels, [parakeet])
    }

    func testAbsentKeysChangeNothing() {
        let managed = ManagedDefaults(defaults: defaults)
        XCTAssertFalse(managed.isPresent)

        makeApplier().apply()

        XCTAssertEqual(target.selectedModels, [])
        XCTAssertEqual(target.enhancements.count, 0)
        XCTAssertEqual(target.startedDownloads, [])
        XCTAssertNil(defaults.object(forKey: ManagedDefaults.appliedVersionKey))
    }

    // MARK: - Cloud block

    func testCloudDefaultsIgnoredWhileCloudIsOff() {
        cloudAllowed = false
        let cloudModel = cloudTranscriptionModel
        setProfile(transcription: cloudModel.selectionKey, provider: "Groq", model: "llama", enabled: true, version: 1)

        let resolution = ManagedDefaultsResolution(
            ManagedDefaults(defaults: defaults), transcriptionModels: target.transcriptionModels, isCloudAllowed: false)
        XCTAssertNil(resolution.transcriptionModel)
        XCTAssertNil(resolution.enhancementProvider)
        XCTAssertEqual(resolution.ignored.count, 2, "\(resolution.ignored)")

        makeApplier().apply()

        XCTAssertEqual(target.selectedModels, [])
        XCTAssertEqual(target.enhancements.count, 1)
        XCTAssertNil(target.enhancements.first?.provider, "The blocked provider is not applied")
        XCTAssertEqual(target.enhancements.first?.enabled, true)
    }

    func testCloudDefaultsAppliedWhenCloudIsAllowed() {
        let cloudModel = cloudTranscriptionModel
        setProfile(transcription: cloudModel.selectionKey, provider: "Groq", model: "llama", version: 1)

        makeApplier().apply()

        XCTAssertEqual(target.selectedModels, [cloudModel.selectionKey], "Cloud models need no download")
        XCTAssertEqual(target.enhancements.first?.provider, .groq)
        XCTAssertEqual(target.enhancements.first?.model, "llama")
    }

    func testLocalProvidersAllowedWhileCloudIsOff() {
        let resolution = ManagedDefaultsResolution(
            ManagedDefaults(transcriptionModel: parakeet, enhancementProvider: "voiceink refine", enhancementModel: "other"),
            transcriptionModels: target.transcriptionModels,
            isCloudAllowed: false
        )
        XCTAssertEqual(resolution.transcriptionModel?.selectionKey, parakeet)
        XCTAssertEqual(resolution.enhancementProvider, .voiceInkRefine)
        XCTAssertEqual(resolution.enhancementModel, VoiceInkRefineService.modelName, "Refine has one model")
        XCTAssertEqual(resolution.ignored, [])
    }

    // MARK: - Downloads

    func testAutoDownloadListResolution() {
        let cloudID = cloudTranscriptionModel.selectionKey
        let resolution = ManagedDefaultsResolution(
            ManagedDefaults(autoDownloadModels: [
                parakeet, "VoiceInk Refine V1", "apple-speech", "no-such-model", cloudID, parakeet, "VoiceInk Refine",
            ]),
            transcriptionModels: target.transcriptionModels,
            isCloudAllowed: true
        )

        XCTAssertEqual(resolution.downloads, [.transcription(selectionKey: parakeet), .voiceInkRefine])
        XCTAssertEqual(resolution.ignored.count, 3, "\(resolution.ignored)")
    }

    func testDownloadsStartOnlyForMissingModelsAndRetryNextLaunch() {
        target.downloaded = [.transcription(selectionKey: parakeetV2)]
        target.downloading = [.voiceInkRefine]
        setProfile(downloads: [parakeet, parakeetV2, "VoiceInk Refine V1"], version: nil)

        makeApplier().apply()
        XCTAssertEqual(target.startedDownloads, [.transcription(selectionKey: parakeet)])

        // The download failed, so the next launch starts it again.
        target.downloading = []
        makeApplier().apply()
        XCTAssertEqual(
            target.startedDownloads,
            [.transcription(selectionKey: parakeet), .transcription(selectionKey: parakeet), .voiceInkRefine]
        )
    }

    func testSwitchesToDefaultModelWhenItsDownloadFinishes() {
        setProfile(transcription: parakeet, downloads: [parakeet], version: 1)
        let applier = makeApplier()
        applier.apply()

        XCTAssertEqual(target.selectedModels, [], "Keep the current model until the download finishes")
        XCTAssertEqual(target.currentTranscriptionSelectionKey, "apple-speech")
        XCTAssertEqual(defaults.integer(forKey: ManagedDefaults.appliedVersionKey), 1)

        applier.switchToPendingTranscriptionModel()
        XCTAssertEqual(target.selectedModels, [])

        target.downloaded = [.transcription(selectionKey: parakeet)]
        applier.switchToPendingTranscriptionModel()
        XCTAssertEqual(target.selectedModels, [parakeet])

        applier.switchToPendingTranscriptionModel()
        XCTAssertEqual(target.selectedModels, [parakeet], "Switches once")
    }

    func testNoSwitchAfterThePersonPicksAnotherModel() {
        setProfile(transcription: parakeet, version: 1)
        let applier = makeApplier()
        applier.apply()

        target.currentTranscriptionSelectionKey = parakeetV2
        target.downloaded = [.transcription(selectionKey: parakeet)]
        applier.switchToPendingTranscriptionModel()

        XCTAssertEqual(target.selectedModels, [])
        XCTAssertNil(defaults.string(forKey: ManagedDefaults.pendingTranscriptionModelKey))
    }

    func testNoSwitchAfterTheOrganizationChangesTheDefault() {
        setProfile(transcription: parakeet, version: 1)
        let applier = makeApplier()
        applier.apply()

        defaults.set(parakeetV2, forKey: ManagedDefaults.transcriptionModelKey)
        target.downloaded = [.transcription(selectionKey: parakeet)]
        applier.switchToPendingTranscriptionModel()

        XCTAssertEqual(target.selectedModels, [])
    }

    // MARK: - Onboarding

    func testOnboardingKeepsEveryStepWithoutManagedDefaults() {
        let coordinator = OnboardingCoordinator(defaults: defaults)

        XCTAssertFalse(coordinator.isManagedSetup)
        XCTAssertEqual(coordinator.stageAfterMicrophone, .model)
        XCTAssertEqual(coordinator.stageBeforeExperience, .api)
        XCTAssertFalse(coordinator.skipsAPISetup)
        XCTAssertFalse(coordinator.isTranscriptionSetupReady(isTranscriptionModelDownloaded: false))
    }

    func testOnboardingSkipsModelAndAPIKeyStepsWithManagedDefaults() {
        defaults.set(parakeetV2, forKey: ManagedDefaults.transcriptionModelKey)
        let coordinator = OnboardingCoordinator(defaults: defaults)

        XCTAssertTrue(coordinator.isManagedSetup)
        XCTAssertEqual(coordinator.stageAfterMicrophone, .experience)
        XCTAssertEqual(coordinator.stageBeforeExperience, .microphone)
        XCTAssertTrue(coordinator.skipsAPISetup)
        XCTAssertTrue(coordinator.isTranscriptionSetupReady(isTranscriptionModelDownloaded: false))
        XCTAssertEqual(coordinator.selectedOnboardingTranscriptionModelName, parakeetV2)
        XCTAssertFalse(coordinator.activeExperienceSteps.isEmpty)
        XCTAssertTrue(coordinator.activeExperienceSteps.allSatisfy { !$0.requiresVerifiedAPIProvider })
    }

    func testOnboardingSkipsWhenOnlyEnhancementIsManaged() {
        defaults.set("VoiceInk Refine", forKey: ManagedDefaults.enhancementProviderKey)
        XCTAssertTrue(OnboardingCoordinator(defaults: defaults).isManagedSetup)
    }

    func testVersionAloneIsNotManagedSetup() {
        defaults.set(3, forKey: ManagedDefaults.versionKey)
        XCTAssertFalse(OnboardingCoordinator(defaults: defaults).isManagedSetup)
    }
}

/// Checks the connection to the running app: the default mode, the global model choice, and the AI service. Runs
/// in the test host's own settings domain and restores every key it touches.
@MainActor
final class LiveManagedDefaultsTargetTests: XCTestCase {
    private let touchedKeys = [
        "modeConfigurationsV2", "activeConfigurationId", "CurrentTranscriptionModel", "SelectedLanguage",
        "selectedAIProvider", "VoiceInk RefineSelectedModel",
    ]
    private var savedValues: [String: Any] = [:]
    private var savedConfigurations: [ModeConfig] = []
    private var modelsDirectory: URL!

    override func setUp() async throws {
        for key in touchedKeys {
            savedValues[key] = UserDefaults.standard.object(forKey: key)
        }
        savedConfigurations = ModeManager.shared.configurations
        modelsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        ModeManager.shared.replaceConfigurations(savedConfigurations)
        for key in touchedKeys {
            UserDefaults.standard.set(savedValues[key], forKey: key)
        }
        try? FileManager.default.removeItem(at: modelsDirectory)
    }

    private func makeTarget() -> LiveManagedDefaultsTarget {
        let whisper = WhisperModelManager(modelsDirectory: modelsDirectory)
        let fluidAudio = FluidAudioModelManager()
        return LiveManagedDefaultsTarget(
            transcriptionModelManager: TranscriptionModelManager(
                whisperModelManager: whisper, fluidAudioModelManager: fluidAudio),
            whisperModelManager: whisper,
            fluidAudioModelManager: fluidAudio,
            aiService: AIService()
        )
    }

    func testWritesDefaultsIntoTheDefaultMode() throws {
        let other = ModeConfig(name: "Other", isAIEnhancementEnabled: false, selectedTranscriptionModelName: "x")
        let dictation = ModeConfig(
            name: "Dictation", isAIEnhancementEnabled: false, selectedTranscriptionModelName: "apple-speech",
            isDefault: true)
        ModeManager.shared.replaceConfigurations([other, dictation])
        let target = makeTarget()
        let parakeet = try XCTUnwrap(
            TranscriptionModelRegistry.models.first { $0.selectionKey == "parakeet-tdt-0.6b-v2" })

        target.selectTranscriptionModel(parakeet)
        target.applyEnhancement(provider: .voiceInkRefine, model: VoiceInkRefineService.modelName, enabled: true)

        let mode = try XCTUnwrap(ModeManager.shared.getConfiguration(with: dictation.id))
        XCTAssertEqual(mode.selectedTranscriptionModelName, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(mode.selectedAIProvider, "VoiceInk Refine")
        XCTAssertEqual(mode.selectedAIModel, VoiceInkRefineService.modelName)
        XCTAssertTrue(mode.isAIEnhancementEnabled)
        XCTAssertEqual(mode.selectedPrompt, PromptTemplates.defaultPromptId.uuidString)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "CurrentTranscriptionModel"), "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedAIProvider"), "VoiceInk Refine")
        XCTAssertEqual(target.currentTranscriptionSelectionKey, "parakeet-tdt-0.6b-v2")

        let untouched = try XCTUnwrap(ModeManager.shared.getConfiguration(with: other.id))
        XCTAssertEqual(untouched.selectedTranscriptionModelName, "x")
        XCTAssertNil(untouched.selectedAIProvider)
    }

    func testTurningEnhancementOffKeepsTheProvider() throws {
        let dictation = ModeConfig(
            name: "Dictation", isAIEnhancementEnabled: true, selectedAIProvider: "Ollama", isDefault: true)
        ModeManager.shared.replaceConfigurations([dictation])

        makeTarget().applyEnhancement(provider: nil, model: nil, enabled: false)

        let mode = try XCTUnwrap(ModeManager.shared.getConfiguration(with: dictation.id))
        XCTAssertFalse(mode.isAIEnhancementEnabled)
        XCTAssertEqual(mode.selectedAIProvider, "Ollama")
    }
}
