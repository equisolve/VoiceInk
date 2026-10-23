import SwiftUI

struct OnboardingExperienceIntroCard: View {
    let step: OnboardingExperienceStep
    let shortcutAction: ShortcutAction
    let hasShortcut: Bool
    var isRecommendedShortcut = false
    var showsUsageHint = false
    let onShortcutChanged: () -> Void

    @State private var isVisible = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(introText))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppTheme.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showsShortcutControl {
                    OnboardingShortcutSetupView(
                        action: shortcutAction,
                        onShortcutChanged: onShortcutChanged
                    )
                }
            }

            if showsShortcutControl, isRecommendedShortcut {
                Label("Recommended by your organization", systemImage: "building.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Text.secondary)
            }

            if showsShortcutControl, showsUsageHint, hasShortcut {
                Text("Hold the shortcut while you talk and let go to stop, or press it once to start and once more to stop.")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: false)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.98)
        .offset(y: isVisible ? 0 : 10)
        .onAppear {
            isVisible = false
            withAnimation(.easeInOut(duration: 0.3).delay(0.08)) {
                isVisible = true
            }
        }
    }

    private var introText: String {
        if let shortcutIntroTitle = step.shortcutIntroTitle {
            return shortcutIntroTitle
        }

        return hasShortcut ? "Shortcut:" : "Choose a shortcut to get started."
    }

    private var showsShortcutControl: Bool {
        step.showsShortcutControl
    }
}
