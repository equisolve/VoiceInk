import SwiftUI

struct OnboardingExperienceScreen: View {
    @ObservedObject private var cloudPolicyMonitor = CloudPolicyMonitor.shared
    let step: OnboardingExperienceStep
    let isInIntroPhase: Bool
    let shortcutAction: ShortcutAction
    let hasShortcut: Bool
    var isRecommendedShortcut = false
    var showsShortcutUsageHint = false
    @Binding var text: String
    let isLastStep: Bool
    let isReady: Bool
    let isComplete: Bool
    /// Set when the step runs AI enhancement through the organization endpoint and the person must sign in first.
    let signInRequiredURL: URL?
    let onBackFromIntro: () -> Void
    let onContinueIntro: () -> Void
    let onBackFromPractice: () -> Void
    let onAdvance: () -> Void
    let onSkipSignIn: () -> Void
    let onShortcutChanged: () -> Void
    let onAppear: () -> Void

    var body: some View {
        Group {
            if isInIntroPhase {
                introScreen
                    .transition(.opacity)
            } else {
                practiceScreen
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isInIntroPhase)
        .onAppear(perform: onAppear)
    }

    private var introScreen: some View {
        OnboardingStepScreen(
            systemImage: systemImage,
            title: step.title,
            subtitle: step.subtitle,
            contentMaxWidth: 560,
            showsHeader: true
        ) {
            OnboardingExperienceIntroCard(
                step: step,
                shortcutAction: shortcutAction,
                hasShortcut: hasShortcut,
                isRecommendedShortcut: isRecommendedShortcut,
                showsUsageHint: showsShortcutUsageHint,
                onShortcutChanged: onShortcutChanged
            )
            .id(step.id)
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: hasShortcut,
                onLeading: onBackFromIntro,
                onPrimary: onContinueIntro
            )
        }
    }

    private var practiceScreen: some View {
        OnboardingStepScreen(
            systemImage: systemImage,
            title: step.title,
            subtitle: step.subtitle,
            contentMaxWidth: 700,
            showsHeader: true
        ) {
            VStack(spacing: 16) {
                // Enhancement through the organization endpoint needs a signed-in key when sign-in is set up. Until
                // the person signs in, the practice area is turned off and only Sign In or Skip leaves the step.
                if let signInRequiredURL {
                    OnboardingSignInRequiredCard(signInURL: signInRequiredURL, onSkip: onSkipSignIn)
                } else if step.kind == .enhance, let endpoint = cloudPolicyMonitor.managedEndpoint,
                    endpoint.signInURL != nil
                {
                    ManagedAIProviderCard(endpoint: endpoint)
                }

                OnboardingExperienceCard(
                    step: step,
                    shortcutAction: shortcutAction,
                    hasShortcut: hasShortcut,
                    text: $text,
                    onShortcutChanged: onShortcutChanged
                )
                .disabled(signInRequiredURL != nil)
                .opacity(signInRequiredURL != nil ? 0.4 : 1)
                .accessibilityHint(signInRequiredURL != nil ? Text("Sign in with Equisolve to try this step.") : Text(""))
            }
            .animation(.easeInOut(duration: 0.2), value: signInRequiredURL)
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: isLastStep ? "Continue" : "Next",
                isPrimaryEnabled: isReady && isComplete && signInRequiredURL == nil,
                onLeading: onBackFromPractice,
                onPrimary: onAdvance
            )
        }
    }

    private var systemImage: String {
        step.systemImage
    }
}
