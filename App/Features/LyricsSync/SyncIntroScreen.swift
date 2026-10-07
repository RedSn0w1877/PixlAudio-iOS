import PixlLyrics
import SwiftUI

/// The frame of the short screens (Android `SyncCardScreen`): top bar, content centred (scrolling when tall), actions
/// at the bottom 8 pt apart. 16 pt side padding, content inset 8 × 24.
private struct SyncCardScreen<Actions: View, Content: View>: View {
    let session: LyricsSyncSession
    let palette: SyncEditorPalette
    var speed: Float?
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SyncTopBar(title: session.title, palette: palette, onClose: session.requestClose, speed: speed,
                       onSpeedChange: session.setSpeed)
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0, content: content)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            GlassEffectContainer(spacing: 4) {
                VStack(spacing: 8, content: actions)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
    }
}

/// 30 pt bold white title (Android `Title`).
private struct SyncTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .pixlFont(.custom(size: 30, weight: .bold, lineHeight: 36))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 16 pt body at 72 % (Android `Body`).
private struct SyncBody: View {
    let text: String
    var body: some View {
        Text(text)
            .pixlFont(.custom(size: 16, lineHeight: 22))
            .foregroundStyle(.white.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A plain text button (Android `TextButton` on the artwork).
private struct SyncTextButton: View {
    let text: String
    var color: Color = .white.opacity(0.8)
    var weight: Font.Weight = .regular
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .pixlFont(.custom(size: 15, weight: weight))
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .contentShape(.capsule)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
    }
}

/// "Sync the words yourself": three short steps and the speed choice (Android `SyncIntroScreen`, spec §2.4).
struct SyncIntroScreen: View {
    let session: LyricsSyncSession
    let palette: SyncEditorPalette

    var body: some View {
        let alreadyTimed = session.origin == .wordSynced || session.origin == .userSynced
        SyncCardScreen(session: session, palette: palette) {
            EditorButton(palette: palette, prominent: true, fillWidth: true,
                         action: { session.startFromIntro(dontShowAgain: false) }) { color in
                EditorButtonText(text: SyncStrings.start, color: color)
            }
            .accessibilityIdentifier("sync.start")
            if alreadyTimed {
                EditorButton(palette: palette, fillWidth: true, action: { session.goToPreview() }) { color in
                    EditorButtonText(text: SyncStrings.seeResult, color: color, bold: false)
                }
            } else {
                SyncTextButton(text: SyncStrings.gotIt) { session.startFromIntro(dontShowAgain: true) }
            }
        } content: {
            SyncTitle(text: SyncStrings.yourselfTitle)
            Spacer().frame(height: 24)
            IntroStep(systemImage: "play.fill", text: SyncStrings.intro1, palette: palette)
            IntroStep(systemImage: "hand.tap.fill", text: SyncStrings.intro2, palette: palette)
            IntroStep(systemImage: "arrow.uturn.backward", text: SyncStrings.intro3, palette: palette)
            if alreadyTimed {
                SyncBody(text: SyncStrings.alreadyTimed).padding(.top, 8)
            }
            Spacer().frame(height: 28)
            Text(SyncStrings.speedLabel)
                .pixlFont(.custom(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Spacer().frame(height: 10)
            SpeedSegments(speed: session.speed, palette: palette, onSpeedChange: session.setSpeed)
            SyncBody(text: SyncStrings.speedHelp).padding(.top, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync.intro")
    }
}

/// One intro step: a 44 pt accent circle with the icon, then 17 pt medium text (Android `IntroStep`).
private struct IntroStep: View {
    let systemImage: String
    let text: String
    let palette: SyncEditorPalette

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .frame(width: 44, height: 44)
                .glassEffect(palette.accentGlass(interactive: false), in: Circle())
            Text(text)
                .pixlFont(.custom(size: 17, weight: .medium, lineHeight: 23))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}

/// "Pick up where you left off?" (Android `SyncResumeScreen`, spec §2.2).
struct SyncResumeScreen: View {
    let tapped: Int
    let total: Int
    let session: LyricsSyncSession
    let palette: SyncEditorPalette

    var body: some View {
        SyncCardScreen(session: session, palette: palette) {
            EditorButton(palette: palette, prominent: true, fillWidth: true, action: session.resumeKeepGoing) { color in
                EditorButtonText(text: SyncStrings.keepGoing, color: color)
            }
            EditorButton(palette: palette, fillWidth: true, action: session.resumeStartOver) { color in
                EditorButtonText(text: SyncStrings.startOver, color: color, bold: false)
            }
        } content: {
            SyncTitle(text: SyncStrings.resumeTitle)
            Spacer().frame(height: 12)
            SyncBody(text: SyncStrings.resumeBody(tapped, total))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync.resume")
    }
}

/// The song is already user-synced: Fix timing · Start over · Remove my timing (Android `SyncManageScreen`).
struct SyncManageScreen: View {
    let session: LyricsSyncSession
    let palette: SyncEditorPalette
    @State private var confirmRemove = false

    var body: some View {
        SyncCardScreen(session: session, palette: palette) {
            EditorButton(palette: palette, prominent: true, fillWidth: true, action: session.manageFixTiming) { color in
                EditorButtonText(text: SyncStrings.fixTiming, color: color)
            }
            EditorButton(palette: palette, fillWidth: true, action: session.manageStartOver) { color in
                EditorButtonText(text: SyncStrings.startOver, color: color, bold: false)
            }
            SyncTextButton(text: SyncStrings.remove, color: Color(argb: 0xFFFFB4AB), weight: .medium) {
                confirmRemove = true
            }
        } content: {
            SyncTitle(text: SyncStrings.fixTitle)
            Spacer().frame(height: 12)
            SyncBody(text: session.title)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync.manage")
        .alert(SyncStrings.remove, isPresented: $confirmRemove) {
            Button(SyncStrings.commonRemove, role: .destructive) { session.removeMyTiming() }
            Button(SyncStrings.cancel, role: .cancel) {}
        } message: {
            Text(SyncStrings.removeBody)
        }
    }
}

/// Spinner; the text appears only if getting ready takes more than 600 ms (Android `SyncLoadingScreen`).
struct SyncLoadingScreen: View {
    @State private var slow = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            if slow {
                Text(SyncStrings.loading)
                    .pixlFont(.custom(size: 15))
                    .foregroundStyle(.white.opacity(0.8))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeOut(duration: 0.2)) { slow = true }
        }
    }
}

/// A message and Close (Android `SyncErrorScreen`).
struct SyncErrorScreen: View {
    let message: String
    let session: LyricsSyncSession
    let palette: SyncEditorPalette

    var body: some View {
        VStack(spacing: 24) {
            Text(message)
                .pixlFont(.custom(size: 20, weight: .semibold, lineHeight: 26))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            EditorButton(palette: palette, prominent: true, action: { session.close(.user) }) { color in
                EditorButtonText(text: SyncStrings.close, color: color)
            }
            .accessibilityIdentifier("sync.error.close")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync.error")
    }
}
