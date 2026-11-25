import PixlLibrary
import PixlModel
import PixlNet
import SwiftUI

/// Taizo — TAIS Engine 3's chat (Android `AskTaizoSheet`), redesign 2 (2026-11-25, mockup AndroidAskTaizo): the
/// owner's rule is back for this sheet, so it is Android's layout with Liquid Glass in place of Material.
///
/// - **Header:** a 52 pt Sunny avatar, "Taizo" over the mode line, Recent chats and New chat squares.
/// - **Empty:** the 72 pt avatar, "Hey, I'm Taizo", one paragraph and the outlined suggestion chips.
/// - **Conversation:** the user's `primaryContainer` bubbles on the trailing side; Taizo's turns under a 28 pt avatar
///   and its name, the answer as plain text (an error keeps a bubble); queue, mix and confirm cards; rows 16 pt apart.
/// - **Input:** the split pills — Close, and the `primaryContainer` pill with the field and mic / send / stop — in a
///   bottom `safeAreaBar` so it rides the keyboard and the scroll edge effect softens what scrolls under it.
///
/// Glass: the pills, chips, bubbles and cards are each one glass shape; buttons and rows on them are fills (no glass
/// on glass). Performance: nothing animates continuously; typing re-renders only the input.
///
/// Ask Taizo (2026-10-23, spec A4): online, Claude answers — streamed, with the song's context, tools (search, play,
/// queue, playlists, likes, insights, lyrics, Sing) and the web (sources listed under the answer); large actions show
/// a Confirm / Cancel card. The header's menu starts a new chat or reopens one of the last five. Reached from Home's
/// sparkles button, the full player's sparkles circle and Settings › AI features.
struct TaisChatSheet: View {
    /// Opened from "Ask the host" of Endless Listening: the host's chips show above the composer and typed text carries the host's short
    /// addendum (`TaisChatModel.hostMode`).
    var hostMode = false

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var sheetVisible = false
    /// The visible height of the empty state's scroll view (between the bars), to centre the hero in it.
    @State private var emptyHeight: CGFloat = 0

    private var model: TaisChatModel { env.ai.chat }

    /// The UI tests' scripted conversation (`-screen taisChatConversation`): a genre request answered from the
    /// demo library with the AI intro line, then a music question answered by the scripted provider.
    static let demoScript = ["Play some indie songs", "Who produced Random Access Memories?"]
    /// `-screen taisChatCloud`: the scripted Claude — a streamed answer with a source, then a 60-song playlist waiting
    /// for its Confirm tap.
    static let cloudDemoScript = ["What's this song about?", "Make me a road-trip playlist from my library"]

    var body: some View {
        @Bindable var chat = model
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
            header(thinking: thinking)
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0) {
                if hostMode { HostChipsRow(enabled: !thinking, onChip: { model.hostChip($0) }) }
                TaizoInputPills(model: model, onSend: { send($0) }, onClose: { dismiss() })
            }
        }
        // "Why this song" from the host's chips: the existing sheet, over the chat.
        .sheet(item: $chat.hostWhy) { ref in
            WhyThisSongSheet(song: ref.song, why: ref.why).pixlSheet()
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: isEmpty)
        .onAppear {
            sheetVisible = true
            model.hostMode = hostMode
            model.restoreIfNeeded()
            // The on-device model loads while the user types (nothing in UI tests or with a cloud assistant).
            env.ai.prewarm(.chat)
        }
        .onDisappear {
            sheetVisible = false
            if hostMode { model.hostMode = false }
        }
        .task {
            guard model.messages.isEmpty else { return }
            if env.launch.screen == .taisChatConversation { await model.runScript(Self.demoScript) }
            if env.launch.screen == .taisChatCloud { await model.runScript(Self.cloudDemoScript) }
        }
    }


    // MARK: Header

    /// Redesign 2 (Android `TaizoHeader`, mockup AndroidAskTaizo): a 52 pt Sunny avatar, 12 pt, "Taizo" 28/34 bold
    /// over the mode line 14/20 `onSurfaceVariant` ("Thinking…" while a prompt is in flight); Recent chats and New chat
    /// as 48 pt neutral glass squares (22 dp icons).
    private func header(thinking: Bool) -> some View {
        // The last answer's route (the router is asked once, before the first prompt).
        let cloud = model.lastRoute.map { $0 == .claude } ?? model.routesToCloud
        return HStack(spacing: 12) {
            HStack(spacing: 12) {
                TaizoShapeAvatar(size: 52)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "Taizo")
                        .pixlFont(.redesignCompactTitle)
                        .foregroundStyle(theme.onSurface)
                    Text(thinking ? LocalizedStringKey("Thinking…")
                             : (cloud ? LocalizedStringKey("Online") : LocalizedStringKey("On this iPhone")))
                        .pixlFont(.custom(size: 14, lineHeight: 20))
                        .foregroundStyle(thinking ? theme.primary : theme.onSurfaceVariant)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: thinking)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            TaizoChatsMenu(model: model)
            RedesignHeaderButton(systemImage: "square.and.pencil", accessibilityLabel: "New chat", iconSize: 19) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { model.newChat() }
            }
            .accessibilityIdentifier("ai.taizo.newChat")
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    // MARK: Empty state

    /// Android `TAIZO_SUGGESTIONS`.
    static let suggestions = [
        "What's this song about?",
        "Play something like this",
        "What have I been listening to this week?",
        "Make me a chill evening playlist",
        "Any news about this artist?",
    ]

    /// Redesign 2 (Android `TaizoEmptyState`): centred — the 72 pt avatar, 16 pt, "Hey, I'm Taizo" (22 bold), 6 pt,
    /// the body (14/20, 28 pt in), 24 pt, the outlined suggestion chips (8 pt apart, centred rows, 12 pt in).
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 0) {
                TaizoShapeAvatar(size: 72)
                Spacer().frame(height: 16)
                Text("Hey, I'm Taizo")
                    .pixlFont(.titleLarge, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .accessibilityAddTraits(.isHeader)
                Spacer().frame(height: 6)
                Text("Ask me about the song that's playing, your listening, or any artist. I can play music, build playlists and look things up for you.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Spacer().frame(height: 24)
                AIFlowLayout(horizontalSpacing: 8, verticalSpacing: 8, centered: true) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        TaizoOutlinedChip(text: suggestion) { send(suggestion) }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
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
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.messages) { message in
                        TaisChatMessageRow(message: message, isResolvingOnlineTracks: model.isResolvingOnlineTracks,
                                           onPlay: { songs in
                                               model.play(songs)
                                               dismiss()
                                           },
                                           onQueue: { model.queue($0) },
                                           onResolve: { items, source, play in
                                               model.resolveOnlineTracks(items, source: source, thenPlay: play) { dismiss() }
                                           },
                                           onConfirm: { id, approved in model.resolveConfirmation(id: id, approved: approved) },
                                           onMixPlay: { model.playMix(id: $0) },
                                           onMixSave: { model.saveMix(id: $0) },
                                           onMixChip: { model.applyChip(id: $0, chip: $1) },
                                           onLessTap: { model.tapLess(id: $0) },
                                           onLessUndo: { model.undoLess(id: $0) })
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

/// The input (redesign 2, Android `TaizoInputPills`): the nav's split pills, 10 pt apart — a 68 pt round Close pill
/// (`surfaceContainerHigh` glass, 26 dp icon) and a 68 pt-min `primaryContainer` glass pill (34 pt corners, 16 / 11 pt
/// padding) with a 22 dp sparkle, the field (15/20, hint "Ask Taizo anything…" at 72 %) and a 46 pt
/// `onPrimaryContainer` circle (a fill on the pill): the mic while the field is empty and the phone can listen (what is
/// said is sent), send, or stop while Taizo answers. Its own view, so a keystroke re-renders only this.
struct TaizoInputPills: View {
    @Bindable var model: TaisChatModel
    /// Sends the typed prompt (nil) or the spoken text.
    let onSend: (String?) -> Void
    let onClose: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(PlaybackStore.self) private var playback
    @FocusState private var focused: Bool
    @State private var voice = TaizoVoiceInput()
    @State private var voiceAvailable = false

    private enum Action { case stop, mic, send }

    var body: some View {
        let isResponding = model.isThinking
        let hasText = !model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let action: Action = isResponding ? .stop : (voice.isListening ? .stop : (!hasText && voiceAvailable ? .mic : .send))
        let enabled = isResponding || voice.isListening || hasText || voiceAvailable
        let pill = theme.primaryContainer
        let onPill = theme.onPrimaryContainer
        HStack(alignment: .bottom, spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(theme.onSurface)
                    .frame(width: 68, height: 68)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Circle(), tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("taisChat.close")
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(onPill)
                    .accessibilityHidden(true)
                TextField("", text: voice.isListening ? .constant(voice.transcript) : $model.inputText,
                          prompt: Text(voice.isListening ? "Listening…" : "Ask Taizo anything…")
                              .foregroundStyle(onPill.opacity(0.72)),
                          axis: .vertical)
                    .pixlFont(.custom(size: 15, lineHeight: 20))
                    .foregroundStyle(onPill)
                    .tint(onPill)
                    .lineLimit(1 ... 4)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { if hasText && !isResponding { onSend(nil) } }
                    .accessibilityIdentifier("taisChat.input")
                Button {
                    switch action {
                    case .stop:
                        if voice.isListening { voice.stop() } else { model.stop() }
                    case .mic: startVoice()
                    case .send: onSend(nil)
                    }
                } label: {
                    Image(systemName: action == .stop ? "stop.fill" : (action == .mic ? "mic.fill" : "arrow.up"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(pill)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(enabled ? onPill : onPill.opacity(0.38)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.88))
                .disabled(!enabled || (action == .send && (!hasText || isResponding)))
                .accessibilityLabel(action == .stop ? "Stop" : (action == .mic ? "Voice search" : "Send"))
                .accessibilityIdentifier("taisChat.send")
            }
            .padding(.leading, 16)
            .padding(.trailing, 11)
            .padding(.vertical, 11)
            .frame(minHeight: 68)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 34, style: .continuous),
                       tint: pill.opacity(GlassTint.prominent))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .task { voiceAvailable = TaizoVoiceInput.isAvailable && !LaunchConfiguration.current.isUITest }
    }

    private func startVoice() {
        focused = false
        Task {
            await voice.start(pausePlayback: {
                guard playback.isPlaying else { return nil }
                playback.pause()
                return { [playback] in playback.resume() }
            }, onFinish: { text in onSend(text) })
        }
    }
}

/// The header's Recent chats (redesign 2: a 48 pt neutral glass square; the menu is the system's): the last five
/// conversations, or "No saved chats yet".
struct TaizoChatsMenu: View {
    let model: TaisChatModel

    @Environment(\.appTheme) private var theme

    var body: some View {
        Menu {
            let others = model.recentConversations.filter { $0.id != model.conversation?.id }
            if others.isEmpty {
                Text("No saved chats yet")
            } else {
                Section("Recent chats") {
                    ForEach(others) { record in
                        Button(record.title.isEmpty ? "Chat" : record.title) {
                            withAnimation(PixlMotion.state) { model.open(record.id) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(theme.onSurface)
                .frame(width: Redesign.headerButtonSize, height: Redesign.headerButtonSize)
                .contentShape(.rect(cornerRadius: Redesign.headerButtonCorner))
        }
        .pixlGlass(in: RoundedRectangle(cornerRadius: Redesign.headerButtonCorner, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
        .accessibilityLabel("Recent chats")
        .accessibilityIdentifier("ai.taizo.menu")
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
