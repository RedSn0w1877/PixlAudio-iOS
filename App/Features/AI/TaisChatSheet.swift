import PixlLibrary
import PixlModel
import PixlNet
import SwiftUI

/// Taizo — TAIS Engine 3's chat (Android `TaisChatSheet`), redesigned for iOS at the owner's request (2026-10-03:
/// "make taizo up much better and more beautiful"; the port rule is relaxed for this sheet only).
///
/// - **Empty:** a living orb (`TaizoOrb`, the app's accent palette drifting in a mesh gradient), a greeting for the
///   time of day, a one-line subtitle and the suggestion chips (glass, each with a symbol and a mood tint, centred
///   in a flow layout; the listener's top artist / genre lead when Home's stats know them).
/// - **Conversation:** the orb flies into the header (one identity, `matchedGeometryEffect`) and stirs while Taizo is
///   thinking; bubbles slide in; a play/queue/find prompt answers with a queue card (artwork mosaic, count, Play / Add
///   to Queue, the songs — tap one to play it); anything else is answered by the configured AI provider.
/// - **Composer:** one glass capsule with the send button inside it (accent when there is text, dimmed otherwise), in
///   a bottom `safeAreaBar` so it rides the keyboard and the scroll edge effect softens what scrolls under it.
///
/// Glass: the composer, chips, bubbles and the queue card are each one glass shape; buttons and rows on them are fills
/// (no glass on glass). Performance: the orb is the only thing that animates continuously (≤ 24 fps, paused off
/// screen, when the sheet is gone, in the background and with Reduce Motion); typing re-renders only the composer.
struct TaisChatSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var orbSpace

    @State private var sheetVisible = false
    @State private var heroVisible = true
    @State private var greeting = TaizoGreeting.make(isUITest: LaunchConfiguration.current.isUITest)
    @State private var personalSuggestions: [TaizoSuggestion] = []
    /// The visible height of the empty state's scroll view (between the bars), to centre the hero in it.
    @State private var emptyHeight: CGFloat = 0

    private var model: TaisChatModel { env.ai.chat }

    /// The UI tests' scripted conversation (`-screen taisChatConversation`): a genre request answered from the
    /// demo library with the AI intro line, then a music question answered by the scripted provider.
    static let demoScript = ["Play some indie songs", "Who produced Random Access Memories?"]

    var body: some View {
        let isEmpty = model.messages.isEmpty
        let thinking = model.isThinking
        Group {
            if isEmpty {
                emptyState
            } else {
                messageList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // On the content, not around the bars: an identifier set outside the `safeAreaBar`s reached the composer's
        // field too and replaced its own `taisChat.input` (CI run 37130222151).
        .accessibilityIdentifier("screen.taisChat")
        .safeAreaBar(edge: .top) {
            if !isEmpty { header(thinking: thinking) }
        }
        .safeAreaBar(edge: .bottom) {
            TaizoComposer(model: model, onSend: { send(nil) })
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: isEmpty)
        .onAppear {
            sheetVisible = true
            if personalSuggestions.isEmpty {
                personalSuggestions = TaizoSuggestion.personal(from: env.home.content.statsOverview)
            }
        }
        .onDisappear { sheetVisible = false }
        .task {
            guard env.launch.screen == .taisChatConversation, model.messages.isEmpty else { return }
            await model.runScript(Self.demoScript)
        }
    }

    private var orbAnimates: Bool { sheetVisible && scenePhase == .active }

    // MARK: Header (conversation)

    /// The orb the hero collapsed into, "Taizo" and a status line ("Thinking…" while a prompt is in flight).
    private func header(thinking: Bool) -> some View {
        HStack(spacing: 12) {
            TaizoOrb(energy: thinking ? 1 : 0, animated: thinking && orbAnimates, sparkleSize: 0.42)
                .matchedGeometryEffect(id: "taizo.orb", in: orbSpace)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Taizo")
                    .pixlFont(.titleMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                Text(thinking ? LocalizedStringKey("Thinking…") : LocalizedStringKey("Your on-device AI DJ"))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(thinking ? theme.primary : theme.onSurfaceVariant)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: thinking)
            }
            .transition(.opacity.combined(with: .offset(x: -8)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 0) {
                TaizoOrb(energy: 0, animated: heroVisible && orbAnimates, glow: true, sparkleSize: 0.36)
                    .matchedGeometryEffect(id: "taizo.orb", in: orbSpace)
                    .frame(width: 112, height: 112)
                    .onScrollVisibilityChange(threshold: 0.05) { heroVisible = $0 }
                Spacer().frame(height: 30)
                VStack(spacing: 6) {
                    Text(greeting)
                        .pixlFont(.headlineMedium, weight: .bold)
                        .foregroundStyle(theme.onSurface)
                    Text("I'm Taizo, your on-device AI DJ.\nPick a vibe, or ask me anything.")
                        .pixlFont(.bodyLarge)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer().frame(height: 28)
                TaizoSuggestionCloud(suggestions: personalSuggestions + TaizoSuggestion.moods) { suggestion in
                    send(suggestion.prompt)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, minHeight: emptyHeight, alignment: .center)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom
        } action: { height in
            emptyHeight = max(height, 0)
        }
    }

    // MARK: Conversation

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.messages) { message in
                        TaisChatMessageRow(message: message, isResolvingOnlineTracks: model.isResolvingOnlineTracks,
                                           onPlay: { songs in
                                               model.play(songs)
                                               dismiss()
                                           },
                                           onQueue: { model.queue($0) },
                                           onResolve: { items, source, play in
                                               model.resolveOnlineTracks(items, source: source, thenPlay: play) { dismiss() }
                                           })
                            .id(message.id)
                            .transition(message.insertionTransition)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.last?.id) { _, _ in
                guard let last = model.messages.last else { return }
                withAnimation(PixlMotion.state) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.84), value: model.messages.last?.id)
    }

    // MARK: Sending

    /// Sends the typed prompt (`nil`) or a suggestion, animating the hero into the header on the first one.
    private func send(_ prompt: String?) {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
            if let prompt {
                model.send(prompt)
            } else {
                model.sendPrompt()
            }
        }
    }
}

/// The prompt field: one glass capsule holding the text field and the send button (a fill on the capsule, like the
/// system's message composers — accent when there is something to send, dimmed and disabled otherwise). Its own view,
/// so a keystroke re-renders only this.
struct TaizoComposer: View {
    @Bindable var model: TaisChatModel
    let onSend: () -> Void

    @Environment(\.appTheme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        let canSend = !model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 8) {
            TextField("", text: $model.inputText,
                      prompt: Text("Ask Taizo anything").foregroundStyle(theme.onSurfaceVariant))
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurface)
                .tint(theme.primary)
                .lineLimit(1)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .padding(.leading, 20)
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("taisChat.input")
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(canSend ? theme.onPrimary : theme.onSurface.opacity(0.38))
                    .frame(width: 40, height: 40)
                    .background(canSend ? theme.primary : theme.onSurface.opacity(0.08), in: Circle())
                    .scaleEffect(canSend ? 1 : 0.92)
                    .contentShape(Circle().inset(by: -4))
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.88))
            .disabled(!canSend)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("taisChat.send")
            .padding(.trailing, 8)
        }
        .frame(height: 56)
        .pixlGlass(in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// "Good morning" … by the hour (Home's day phases); a fixed evening in UI tests so screenshots are stable.
enum TaizoGreeting {
    static func make(isUITest: Bool, now: Date = Date()) -> String {
        let hour = isUITest ? 18 : Calendar.current.component(.hour, from: now)
        switch HomeLogic.dayPhase(hour: hour) {
        case "morning": return "Good morning"
        case "afternoon": return "Good afternoon"
        case "evening": return "Good evening"
        default: return "Hey, night owl"
        }
    }
}
