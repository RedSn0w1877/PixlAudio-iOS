import PixlLibrary
import PixlModel
import SwiftUI

/// A made-for-you list other than Daily Mix 1 and Your Mix (docs/brain-spec.md, 8.2): Daily Mix 2 to 6, First Listen, Just
/// Dropped, On Repeat, Rediscover. The same screen as the two mixes (`MixScreen`); the list is read from the served log, and
/// built when today has none yet. Android `MixDetailScreen`.
struct MixDetailView: View {
    let mixId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var view: MixView?
    @State private var loaded = false
    /// The weekly note of First Listen (docs/brain-spec.md, 9.3): from the list itself, made when the list is opened, never at app start.
    @State private var note: String?

    var body: some View {
        Group {
            if let view, !view.songs.isEmpty {
                MixScreen(title: LocalizedStringKey(Self.title(view)), songs: view.songs, playsFromLibrary: false,
                          screenID: "mixDetail", titleLeading: 28, trailingHeaderButton: nil, topTrailingButton: nil,
                          brain: BrainMixRows(BrainMixDetails.Part(view)), note: note)
            } else {
                ZStack {
                    theme.surface.ignoresSafeArea()
                    VStack(spacing: 16) {
                        if loaded {
                            Text(verbatim: BrainStrings.mixNothingYet)
                                .pixlFont(.bodyLarge)
                                .foregroundStyle(theme.onSurfaceVariant)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        } else {
                            ProgressView().controlSize(.large).tint(theme.primary)
                        }
                    }
                    VStack {
                        HStack {
                            GlassCircleButton(systemImage: "arrow.backward", accessibilityLabel: "Back",
                                              tint: theme.surface.opacity(GlassTint.surface)) { router.pop() }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        Spacer()
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .accessibilityIdentifier("screen.mixDetail")
            }
        }
        .task(id: mixId) { await load() }
    }

    private func load() async {
        guard let mixes = env.brain.mixes, let spec = MixSpec.of(surfaceId: mixId) else {
            loaded = true
            return
        }
        // What was built today first; a list nobody built yet is built now (off the main actor).
        var found = await mixes.savedOf(spec)
        if found == nil { found = await mixes.todayOf(spec) }
        if var found {
            env.brain.register(found.engineTracks)
            found.songs = found.songs.map { env.brain.linked($0) }
            view = found
            let current = found
            if current.kind == MixKinds.firstListen {
                note = await env.brain.assist?.firstListen.note(for: current)
            }
        }
        loaded = true
    }

    static func title(_ view: MixView) -> String {
        switch view.spec.kind {
        case MixKinds.daily: view.number > 0 ? BrainStrings.mixDailyNumber(view.number) : BrainStrings.mixDaily
        case MixKinds.your: BrainStrings.mixYour
        case MixKinds.firstListen: BrainStrings.mixFirstListen
        case MixKinds.justDropped: BrainStrings.mixJustDropped
        case MixKinds.onRepeat: BrainStrings.mixOnRepeat
        default: BrainStrings.mixRediscover
        }
    }
}
