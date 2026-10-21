import CoreML
import CryptoKit
import FluidAudio
import Foundation

/// One file of a pinned model download, with the size and SHA-256 published at the pinned commit.
struct PinnedModelFile: Sendable, Equatable {
    let path: String
    let size: Int64
    let sha256: String
}

/// A Hugging Face model repository fixed to one commit, listing every file VoiceInk downloads from it.
struct PinnedModelRepository: Sendable {
    let displayName: String
    /// The upstream `owner/name` path FluidAudio downloads from. Must match `Repo.remotePath`.
    let remotePath: String
    /// A full Hugging Face commit SHA. Branch names are not allowed.
    let revision: String
    let files: [PinnedModelFile]
}

enum PinnedModelVerificationError: LocalizedError {
    case missingFile(model: String, path: String)
    case invalidFileSize(model: String, path: String, expected: Int64, actual: Int64)
    case invalidChecksum(model: String, path: String)
    case unexpectedFile(model: String, path: String)

    var errorDescription: String? {
        switch self {
        case let .missingFile(model, path):
            return String(
                localized: "\(model) failed integrity verification because \(path) is missing. The model files were removed. Download the model again."
            )
        case let .invalidFileSize(model, path, expected, actual):
            return String(
                localized: "\(model) failed integrity verification because \(path) is \(actual) bytes instead of \(expected) bytes. The model files were removed. Download the model again."
            )
        case let .invalidChecksum(model, path):
            return String(
                localized: "\(model) failed integrity verification because the SHA-256 of \(path) does not match the pinned value. The model files were removed. Download the model again."
            )
        case let .unexpectedFile(model, path):
            return String(
                localized: "\(model) failed integrity verification because \(path) is not part of the pinned model. The model files were removed. Download the model again."
            )
        }
    }
}

extension Notification.Name {
    /// Posted, from any thread, after VoiceInk deletes a pinned model folder that failed verification. When the user
    /// should be told, `userInfo[pinnedModelErrorKey]` holds the error. It is absent when VoiceInk downloads the model
    /// again right away.
    static let pinnedFluidAudioModelRemoved = Notification.Name("VoiceInkPinnedFluidAudioModelRemoved")
}

let pinnedModelErrorKey = "error"

/// Fixes the FluidAudio models VoiceInk downloads to exact Hugging Face commits and checks every
/// downloaded file against a hard-coded SHA-256 before the model is loaded.
///
/// To update a pin, see "Updating pinned dependencies" in BUILDING.md.
enum PinnedFluidAudioModels {
    static let parakeetV3 = PinnedModelRepository(
        displayName: "Parakeet V3",
        remotePath: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        files: [
            PinnedModelFile(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
            PinnedModelFile(path: "Decoder.mlmodelc/coremldata.bin", size: 554, sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
            PinnedModelFile(path: "Decoder.mlmodelc/metadata.json", size: 3_427, sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
            PinnedModelFile(path: "Decoder.mlmodelc/model.mil", size: 13_110, sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
            PinnedModelFile(path: "Decoder.mlmodelc/weights/weight.bin", size: 23_604_992, sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
            PinnedModelFile(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
            PinnedModelFile(path: "Encoder.mlmodelc/coremldata.bin", size: 485, sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
            PinnedModelFile(path: "Encoder.mlmodelc/metadata.json", size: 2_921, sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
            PinnedModelFile(path: "Encoder.mlmodelc/model.mil", size: 959_769, sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
            PinnedModelFile(path: "Encoder.mlmodelc/weights/weight.bin", size: 445_187_200, sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
            PinnedModelFile(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
            PinnedModelFile(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 521, sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
            PinnedModelFile(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3_453, sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
            PinnedModelFile(path: "JointDecisionv3.mlmodelc/model.mil", size: 11_775, sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
            PinnedModelFile(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12_642_764, sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
            PinnedModelFile(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
            PinnedModelFile(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
            PinnedModelFile(path: "Preprocessor.mlmodelc/metadata.json", size: 2_841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
            PinnedModelFile(path: "Preprocessor.mlmodelc/model.mil", size: 28_181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
            PinnedModelFile(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491_072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
            PinnedModelFile(path: "config.json", size: 475, sha256: "97f19ecccd0fdc730d76fb918090fa8bc64bce8ea4ad43715d5e9c2c7350db66"),
            PinnedModelFile(path: "parakeet_v3_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
            PinnedModelFile(path: "parakeet_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ]
    )

    static let vad = PinnedModelRepository(
        displayName: "Silero VAD",
        remotePath: "FluidInference/silero-vad-coreml",
        revision: "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
        files: [
            PinnedModelFile(path: "config.json", size: 2, sha256: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"),
            PinnedModelFile(path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909"),
            PinnedModelFile(path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin", size: 625, sha256: "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41"),
            PinnedModelFile(path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/metadata.json", size: 3_335, sha256: "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6"),
            PinnedModelFile(path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil", size: 176_918, sha256: "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270"),
            PinnedModelFile(path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin", size: 882_304, sha256: "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063"),
        ]
    )

    static let all = [parakeetV3, vad]

    /// The pinned repository for a Parakeet version, or nil when that version still follows FluidAudio's default revision.
    static func repository(for version: AsrModelVersion) -> PinnedModelRepository? {
        version == .v3 ? parakeetV3 : nil
    }

    // FluidAudio's own revision marker, and the record VoiceInk writes after a full hash check.
    private static let fluidAudioRevisionMarker = ".fluidaudio-revision"
    private static let verificationRecordFilename = ".voiceink-integrity.json"
    private static let verificationRecordVersion = 1

    // MARK: - Revision pins

    private static let revisionPinsInstalled: Void = {
        var overrides = ModelRegistry.revisionOverrides
        for repository in all {
            overrides[repository.remotePath] = repository.revision
        }
        ModelRegistry.revisionOverrides = overrides
    }()

    /// Points FluidAudio's downloader at the pinned commits. Safe to call repeatedly; runs once.
    static func installRevisionPins() {
        _ = revisionPinsInstalled
    }

    // MARK: - Directories

    static var fluidAudioModelsRootDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static var vadDirectory: URL {
        fluidAudioModelsRootDirectory.appendingPathComponent(Repo.vad.folderName, isDirectory: true)
    }

    // MARK: - Verification

    /// Ensures `directory` holds exactly the pinned files with the pinned hashes.
    ///
    /// A matching verification record from an earlier full check is accepted when every file still has its recorded
    /// size and modification time. Otherwise every file is hashed. On any mismatch the directory is deleted, the
    /// `pinnedFluidAudioModelRemoved` notification is posted with the error so the user is told, and the error is
    /// rethrown. Runs off the calling actor.
    static func ensureVerified(_ repository: PinnedModelRepository, at directory: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try verifyIfNeeded(repository, at: directory, reportFailure: true)
        }.value
    }

    /// Checks an install that is already on disk before a download, so a matching install is kept instead of being
    /// downloaded again. Returns false when any pinned file is missing, or when verification fails, in which case the
    /// directory is deleted and `pinnedFluidAudioModelRemoved` is posted without an error, because the caller
    /// downloads the model again right away. Runs off the calling actor.
    static func verifyExistingInstall(_ repository: PinnedModelRepository, at directory: URL) async -> Bool {
        guard allFilesPresent(repository, at: directory) else {
            return false
        }
        let verified: Void? = try? await Task.detached(priority: .userInitiated) {
            try verifyIfNeeded(repository, at: directory, reportFailure: false)
        }.value
        return verified != nil
    }

    /// Hashes every pinned file and rejects any file that is not pinned, unless a valid verification record makes
    /// that unnecessary. On success writes the verification record and FluidAudio's revision marker, so FluidAudio
    /// treats the folder as a download of the pinned commit and keeps it. On failure deletes `directory`, posts
    /// `pinnedFluidAudioModelRemoved`, and rethrows.
    private static func verifyIfNeeded(
        _ repository: PinnedModelRepository,
        at directory: URL,
        reportFailure: Bool
    ) throws {
        if !hasValidRecord(repository, at: directory) {
            do {
                try verifyContents(repository, at: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                NotificationCenter.default.post(
                    name: .pinnedFluidAudioModelRemoved,
                    object: nil,
                    userInfo: reportFailure ? [pinnedModelErrorKey: error] : nil
                )
                throw error
            }
            try persistRecord(for: repository, at: directory)
        }
        try writeRevisionMarkerIfNeeded(for: repository, at: directory)
    }

    /// FluidAudio deletes a model folder before downloading when its marker names a different commit, or when there
    /// is no marker and the pinned commit is not `main`. Installs made before the pin have no marker.
    private static func writeRevisionMarkerIfNeeded(for repository: PinnedModelRepository, at directory: URL) throws {
        let marker = directory.appendingPathComponent(fluidAudioRevisionMarker)
        let stored = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored != repository.revision else {
            return
        }
        try Data((repository.revision + "\n").utf8).write(to: marker, options: .atomic)
    }

    /// True when every pinned file is present, whatever its contents. Used to decide whether to check an existing
    /// install before downloading.
    static func allFilesPresent(_ repository: PinnedModelRepository, at directory: URL) -> Bool {
        repository.files.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.path).path)
        }
    }

    private static func verifyContents(_ repository: PinnedModelRepository, at directory: URL) throws {
        let pinnedPaths = Set(repository.files.map(\.path))
        for path in try regularFilePaths(in: directory) where !pinnedPaths.contains(path) {
            throw PinnedModelVerificationError.unexpectedFile(model: repository.displayName, path: path)
        }

        for file in repository.files {
            let url = directory.appendingPathComponent(file.path)
            guard let actualSize = fileSize(at: url) else {
                throw PinnedModelVerificationError.missingFile(model: repository.displayName, path: file.path)
            }
            guard actualSize == file.size else {
                throw PinnedModelVerificationError.invalidFileSize(
                    model: repository.displayName,
                    path: file.path,
                    expected: file.size,
                    actual: actualSize
                )
            }
            guard try sha256(of: url) == file.sha256 else {
                throw PinnedModelVerificationError.invalidChecksum(model: repository.displayName, path: file.path)
            }
        }
    }

    /// Relative paths of every regular file under `directory`, except bookkeeping files that are never loaded:
    /// FluidAudio's revision marker, VoiceInk's verification record, and Finder's `.DS_Store`.
    private static func regularFilePaths(in directory: URL) throws -> [String] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
            )
        else {
            return []
        }

        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true {
                continue
            }
            let name = url.lastPathComponent
            if name == ".DS_Store" {
                continue
            }
            let fullPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            let relativePath = fullPath.hasPrefix(rootPath) ? String(fullPath.dropFirst(rootPath.count)) : name
            if relativePath == fluidAudioRevisionMarker || relativePath == verificationRecordFilename {
                continue
            }
            // Symlinks and other non-regular entries are reported so they fail verification.
            paths.append(relativePath)
        }
        return paths
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return size.int64Value
    }

    // MARK: - Verification record

    private struct VerificationRecord: Codable, Equatable {
        let version: Int
        let revision: String
        let files: [FileRecord]
    }

    private struct FileRecord: Codable, Equatable {
        let path: String
        let size: Int64
        let sha256: String
        let modificationTime: TimeInterval
    }

    /// The record describing what is on disk now, or nil when any pinned file is missing or has the wrong size.
    private static func currentRecord(for repository: PinnedModelRepository, at directory: URL) -> VerificationRecord? {
        var files: [FileRecord] = []
        files.reserveCapacity(repository.files.count)
        for file in repository.files {
            let url = directory.appendingPathComponent(file.path)
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let size = (attributes[.size] as? NSNumber)?.int64Value,
                size == file.size,
                let modificationDate = attributes[.modificationDate] as? Date
            else {
                return nil
            }
            files.append(
                FileRecord(
                    path: file.path,
                    size: size,
                    sha256: file.sha256,
                    modificationTime: modificationDate.timeIntervalSinceReferenceDate
                )
            )
        }
        return VerificationRecord(version: verificationRecordVersion, revision: repository.revision, files: files)
    }

    /// True when an earlier full check recorded this exact set of files for this revision and nothing changed since.
    static func hasValidRecord(_ repository: PinnedModelRepository, at directory: URL) -> Bool {
        let recordURL = directory.appendingPathComponent(verificationRecordFilename)
        guard
            let data = try? Data(contentsOf: recordURL),
            let stored = try? JSONDecoder().decode(VerificationRecord.self, from: data),
            let current = currentRecord(for: repository, at: directory),
            stored == current,
            let paths = try? regularFilePaths(in: directory),
            Set(paths) == Set(repository.files.map(\.path))
        else {
            return false
        }
        return true
    }

    private static func persistRecord(for repository: PinnedModelRepository, at directory: URL) throws {
        guard let record = currentRecord(for: repository, at: directory) else {
            throw PinnedModelVerificationError.missingFile(
                model: repository.displayName,
                path: verificationRecordFilename
            )
        }
        let data = try JSONEncoder().encode(record)
        try data.write(to: directory.appendingPathComponent(verificationRecordFilename), options: .atomic)
    }

    // MARK: - Voice activity detection

    /// Makes sure the pinned VAD model is on disk and verified, downloading it from the pinned commit when needed.
    static func prepareVad(progressHandler: ProgressHandler? = nil) async throws {
        installRevisionPins()
        let directory = vadDirectory
        if await verifyExistingInstall(vad, at: directory) {
            return
        }
        try await ModelHub.download(.vad, to: fluidAudioModelsRootDirectory, progressHandler: progressHandler)
        try await ensureVerified(vad, at: directory)
    }

    /// Loads the VAD model only after its files pass verification. FluidAudio's `VadManager(config:)` would download
    /// and load without a hash check, so VoiceInk loads the compiled model itself.
    static func loadVerifiedVadManager(config: VadConfig = .default) async throws -> VadManager {
        try await prepareVad()
        let modelURL = vadDirectory.appendingPathComponent(ModelNames.VAD.sileroVadFile)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = config.computeUnits
        configuration.allowLowPrecisionAccumulationOnGPU = true
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        return VadManager(config: config, vadModel: model)
    }
}
