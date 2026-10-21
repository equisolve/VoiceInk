import SwiftUI

/// The model managed onboarding waits for, and whether the organization chose it.
struct OnboardingManagedModel {
    let model: any TranscriptionModel
    let isOrganizationChoice: Bool
}

/// The model library's card for a Whisper or transcribe.cpp model, so managed onboarding can show and download the
/// organization's default whatever kind of local model it is.
struct ManagedModelDownloadCard: View {
    let model: any TranscriptionModel
    @EnvironmentObject private var whisperModelManager: WhisperModelManager

    private var downloadedWhisperFile: WhisperModelFile? {
        whisperModelManager.availableModels.first { $0.name == model.name }
    }

    var body: some View {
        ModelCardView(
            model: model,
            isDownloaded: downloadedWhisperFile != nil,
            downloadProgress: whisperModelManager.downloadProgress,
            modelURL: downloadedWhisperFile?.url,
            isWarming: false,
            deleteAction: {
                if let downloadedWhisperFile {
                    Task { await whisperModelManager.deleteModel(downloadedWhisperFile) }
                }
            },
            downloadAction: {
                if let whisperModel = model as? WhisperModel {
                    whisperModelManager.startDownload(whisperModel)
                }
            },
            cancelDownloadAction: {
                if let whisperModel = model as? WhisperModel {
                    whisperModelManager.cancelDownload(whisperModel)
                }
            }
        )
    }
}
