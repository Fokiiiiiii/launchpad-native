import AppKit
import Localization
import SwiftUI

/// First-run wizard, shown once (see `OnboardingState`). Deliberately
/// read-only/informational — it explains the trigger methods and default
/// settings that already exist rather than letting the user configure them
/// here, so there's no duplicate settings-mutation logic to keep in sync
/// with the real Settings window. Page transitions use a plain SwiftUI
/// spring (critically damped, no bounce — this is a step-through wizard,
/// not a gesture-driven surface) rather than hand-rolled `CALayer`
/// transforms, since this is SwiftUI content, not the AppKit grid.
struct OnboardingView: View {
    let onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var pageIndex = 0
    @State private var movingForward = true

    private let pageCount = 4

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Group {
                    switch pageIndex {
                    case 0: WelcomePage()
                    case 1: TriggersPage()
                    case 2: PermissionsPage()
                    default: DonePage()
                    }
                }
                .id(pageIndex)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(x: movingForward ? 440 : -440).combined(with: .opacity),
                    removal: .offset(x: movingForward ? -440 : 440).combined(with: .opacity)
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                HStack(spacing: 12) {
                    pageDots
                    Spacer()
                    if pageIndex > 0 {
                        Button(L10n.onboardingBackButton) { advance(by: -1) }
                    }
                    Button(pageIndex == pageCount - 1 ? L10n.onboardingGetStartedButton : L10n.onboardingNextButton) {
                        if pageIndex == pageCount - 1 {
                            onFinished()
                        } else {
                            advance(by: 1)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 34)
            }
        }
        .frame(width: 540, height: 680)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var background: some View {
        ZStack {
            colorScheme == .dark ? Color(red: 0.04, green: 0.05, blue: 0.08) : Color.white
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.08, green: 0.27, blue: 0.42), Color(red: 0.03, green: 0.09, blue: 0.2), .clear]
                    : [Color(red: 0.77, green: 0.91, blue: 1), Color(red: 0.88, green: 0.93, blue: 1), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .accessibilityHidden(true)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { i in
                Circle()
                    .fill(i == pageIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private func advance(by delta: Int) {
        movingForward = delta > 0
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.5, dampingFraction: 1.0)) {
            pageIndex = max(0, min(pageCount - 1, pageIndex + delta))
        }
    }
}

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 112, height: 112)
            Text(L10n.onboardingWelcomeTitle)
                .font(.largeTitle)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text(L10n.onboardingWelcomeSubtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Spacer()
        }
        .padding(32)
    }
}

private struct TriggersPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Text(L10n.onboardingTriggersTitle)
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 14) {
                Label(L10n.onboardingTriggersHotCorner, systemImage: "rectangle.inset.filled")
                Label(L10n.onboardingTriggersHotkey, systemImage: "keyboard")
                Label(L10n.onboardingTriggersGesture, systemImage: "hand.draw")
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 48)

            Text(L10n.onboardingTriggersFootnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer()
        }
        .padding(32)
    }
}

private struct PermissionsPage: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "hand.raised")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(L10n.onboardingPermissionsTitle)
                .font(.title2)
                .fontWeight(.semibold)
            Text(L10n.onboardingPermissionsBody)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(L10n.openPrivacySettingsButton) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer()
        }
        .padding(32)
    }
}

private struct DonePage: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text(L10n.onboardingDoneTitle)
                .font(.title2)
                .fontWeight(.semibold)
            Text(L10n.onboardingDoneBody)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .padding(32)
    }
}
