import SwiftUI

struct OnboardingModelScreen: View {
    let contentMaxWidth: CGFloat
    let localModel: FluidAudioModel?
    var managedModel: OnboardingManagedModel?
    let setupKind: OnboardingTranscriptionSetupKind
    let providerOptions: [any CloudProvider]
    @Binding var selectedProviderKey: String
    let isLocalDownloaded: Bool
    let isLocalDownloading: Bool
    let localDownloadStatus: FluidAudioDownloadStatus?
    let isSetupReady: Bool
    let onSelectSetupKind: (OnboardingTranscriptionSetupKind) -> Void
    let onDownload: (FluidAudioModel) -> Void
    let onCancelDownload: (FluidAudioModel) -> Void
    let onVerificationChanged: () -> Void
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScreen(
            stage: .model,
            subtitle: managedModel == nil ? nil : "Download a transcription model that runs on this Mac.",
            contentMaxWidth: contentMaxWidth
        ) {
            OnboardingTranscriptionSetupCard(
                localModel: localModel,
                managedModel: managedModel,
                setupKind: setupKind,
                providerOptions: providerOptions,
                selectedProviderKey: $selectedProviderKey,
                isLocalDownloaded: isLocalDownloaded,
                isLocalDownloading: isLocalDownloading,
                localDownloadStatus: localDownloadStatus,
                onSelectSetupKind: onSelectSetupKind,
                onDownloadLocalModel: onDownload,
                onCancelLocalModelDownload: onCancelDownload,
                onVerificationChanged: onVerificationChanged
            )
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: isSetupReady && !(setupKind == .local && isLocalDownloading),
                onLeading: onBack,
                onPrimary: onContinue
            )
        }
    }
}
