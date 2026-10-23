import SwiftUI

/// Shown above a practice step that runs AI enhancement through the organization AI endpoint before the person has
/// signed in. Offers Sign in with Equisolve, or Skip to leave the step and sign in later in AI Models.
struct OnboardingSignInRequiredCard: View {
    let signInURL: URL
    let onSkip: () -> Void
    @ObservedObject private var controller = ManagedAISignInController.shared

    private enum Metrics {
        static let buttonHeight: CGFloat = 38
        static let skipButtonWidth: CGFloat = 96
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(AppTheme.Action.primaryFill)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to use AI enhancement")
                        .font(.system(size: 15, weight: .semibold))
                    Text(
                        "Your organization's AI cleanup needs your Equisolve account. Sign in to try it here, or skip and sign in later in AI Models."
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                if controller.isSigningIn {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Cancel") { controller.cancelSignIn() }
                        .controlSize(.large)
                } else {
                    Button {
                        controller.signIn(signInURL: signInURL)
                    } label: {
                        Text("Sign in with Equisolve")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.Action.primaryForeground)
                            .padding(.horizontal, 18)
                            .frame(minHeight: Metrics.buttonHeight)
                            .background(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                                    .fill(AppTheme.Action.primaryFill)
                            )
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                }

                Button {
                    controller.cancelSignIn()
                    onSkip()
                } label: {
                    Text("Skip")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.Action.secondaryForeground)
                        .frame(width: Metrics.skipButtonWidth, height: Metrics.buttonHeight)
                        .background(AppMaterialCardBackground(cornerRadius: AppTheme.Radius.control))
                }
                .buttonStyle(.plain)
                .help("Continue without signing in. You can sign in later in AI Models.")
            }

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppMaterialCardBackground(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.Action.primaryFill.opacity(0.55), lineWidth: 1)
        )
        .onAppear { controller.reload() }
    }
}
