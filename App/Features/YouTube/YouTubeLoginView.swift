import SwiftUI
import UIKit
import WebKit

/// YouTube sign-in (Android `YouTubeLoginScreen`): the "Connect YouTube" top bar over Google's own sign-in page in a
/// web view; the music.youtube.com session cookie is captured once it carries `SAPISID`, with the page's
/// `VISITOR_DATA`, and the screen closes. Google sometimes refuses embedded sign-in, so two iOS fallbacks sit under
/// the page as glass capsules: the device-code flow (Android's `YouTubeSignInDialog` — a code typed at
/// google.com/device) and pasting a cookie. Signed in, the screen shows Android's YouTube account card (from the
/// Spotify dashboard) with "Test playback" and "Disconnect YouTube".
struct YouTubeLoginView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AccountsStore.self) private var accounts
    @Environment(Router.self) private var router
    @Environment(PlaybackStore.self) private var playback
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var model = YouTubeLoginModel()

    private var demoScreen: DemoScreen? { env.launch.screen }

    private var isSignedIn: Bool {
        if demoScreen == .youTubeLoginSignedIn { return true }
        if case .signedIn = accounts.youtube { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            YouTubeTopBar(title: "Connect YouTube")
            if isSignedIn {
                signedIn
            } else {
                signInPage
            }
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.youTubeLogin")
        .sheet(isPresented: $model.showsCodeSheet, onDismiss: { if !env.launch.isUITest { model.cancelDeviceCode() } }) {
            DeviceCodeSheet(prompt: model.prompt ?? YouTubeLoginModel.demoPrompt) { model.cancelDeviceCode() }
                .pixlSheet(detents: [.medium])
        }
        .sheet(isPresented: $model.showsCookieSheet) {
            CookiePasteSheet(model: model) {
                Task { if await model.savePastedCookie(env.youtube) { dismiss() } }
            }
            .pixlSheet(detents: [.large])
        }
        .alert("YouTube sign-in", isPresented: Binding(get: { model.errorMessage != nil },
                                                        set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear(perform: applyDemoState)
    }

    // MARK: Signed out: the sign-in page

    private var signInPage: some View {
        VStack(spacing: 0) {
            Group {
                if env.youtube.isDemo {
                    demoPage
                } else {
                    YouTubeSignInWebView { cookie, visitorData in
                        Task {
                            if await model.captured(cookie: cookie, visitorData: visitorData, env.youtube) { dismiss() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.large, style: .continuous))
            .padding(.horizontal, 8)

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 10) {
                    GlassPillButton(title: "Use a code", systemImage: "key.horizontal",
                                    tint: theme.secondaryContainer.opacity(GlassTint.surface),
                                    foreground: theme.onSecondaryContainer) {
                        model.startDeviceCode(env.youtube) { dismiss() }
                    }
                    .accessibilityIdentifier("youtube.useCode")
                    GlassPillButton(title: "Paste a cookie", systemImage: "doc.on.clipboard",
                                    tint: theme.secondaryContainer.opacity(GlassTint.surface),
                                    foreground: theme.onSecondaryContainer) {
                        model.showsCookieSheet = true
                    }
                    .accessibilityIdentifier("youtube.pasteCookie")
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 8 + playback.miniPlayerClearance)
        }
    }

    /// UI tests never load Google: a stand-in for the page with the same frame.
    private var demoPage: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(theme.primary)
            Text("Sign in")
                .pixlFont(.headlineSmall)
                .foregroundStyle(theme.onSurface)
            Text("to continue to YouTube Music")
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurfaceVariant)
            Text("accounts.google.com")
                .pixlFont(.labelMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceContainerLowest)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("youtube.signInPage")
    }

    // MARK: Signed in

    private var signedIn: some View {
        ScrollView {
            VStack(spacing: YouTubeMetrics.itemSpacing) {
                YouTubeAccountCard(isSignedIn: true, onConnect: {}, onDisconnect: {
                    Task { await env.youtube.signOut() }
                })
                YouTubeWideButton(title: "Test playback", systemImage: "ladybug") {
                    router.push(.playbackDiagnostics)
                }
                .accessibilityIdentifier("youtube.testPlayback")
            }
            .padding(.horizontal, YouTubeMetrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, 12 + playback.miniPlayerClearance)
        }
        .scrollIndicators(.hidden)
    }

    private func applyDemoState() {
        switch demoScreen {
        case .youTubeLoginCode:
            model.prompt = YouTubeLoginModel.demoPrompt
            model.showsCodeSheet = true
        case .youTubeLoginCookie:
            model.cookieDraft = YouTubeLoginModel.demoCookie
            model.showsCookieSheet = true
        default:
            break
        }
    }
}

/// Android `YouTubeAccountCard` (Spotify dashboard): 24 pt card, 18 pt padding, 10 pt spacing; the red play icon,
/// the title, the explanation, and the connect / disconnect button.
struct YouTubeAccountCard: View {
    let isSignedIn: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        GlassCard(cornerRadius: 24, tint: theme.surfaceContainer.opacity(GlassTint.surface / GlassTint.container)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(YouTubeMetrics.youTubeRed)
                        .frame(width: 24, height: 24)
                    Text(isSignedIn ? "YouTube connected" : "YouTube account")
                        .pixlFont(.titleMedium, weight: .bold)
                        .foregroundStyle(theme.onSurface)
                }
                Text(isSignedIn
                     ? "Signed in. Playback requests now go out as your account, which gets past YouTube's \"not a bot\" checks."
                     : "Sign in with a Google account to let songs play reliably. You'll enter a short code on Google's own page — the app never sees your password.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                if isSignedIn {
                    YouTubeWideButton(title: "Disconnect YouTube", onGlass: true, action: onDisconnect)
                        .accessibilityIdentifier("youtube.disconnect")
                } else {
                    YouTubeWideButton(title: "Connect YouTube", systemImage: "play.circle.fill",
                                      tint: YouTubeMetrics.youTubeRed, foreground: .white, onGlass: true, action: onConnect)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Android `YouTubeSignInDialog`: the steps, the code in a 12 pt box, "Copy code", the note that it closes itself,
/// and Cancel / Open Google. Shown as a sheet; polling runs in the model meanwhile.
struct DeviceCodeSheet: View {
    let prompt: YouTubeLoginModel.Prompt
    let onCancel: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        SheetScaffold("Connect YouTube") {
            VStack(spacing: 12) {
                Text("1. Tap \"Open Google\" below (or go to \(prompt.verificationUrl)).\n2. Sign in and enter this code:")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(prompt.userCode)
                    .pixlFont(.headlineSmall.tracking(2), weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .pixlGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                               tint: theme.surfaceContainerHighest.opacity(GlassTint.surface))
                    .accessibilityIdentifier("youtube.userCode")
                GlassPillButton(title: copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = prompt.userCode
                    copied = true
                }
                Text("This window closes itself once you finish signing in.")
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    YouTubeWideButton(title: "Cancel", action: onCancel)
                    YouTubeWideButton(title: "Open Google", systemImage: "arrow.up.right.square",
                                      tint: theme.primary.opacity(GlassTint.prominent), foreground: theme.onPrimary) {
                        if let url = URL(string: prompt.verificationUrl) { openURL(url) }
                    }
                    .accessibilityIdentifier("youtube.openGoogle")
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, Tokens.Spacing.xxl)
            .padding(.bottom, Tokens.Spacing.xxl)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("youtube.codeSheet")
    }
}

/// The cookie paste fallback: how to copy the Cookie header, the text field, the SAPISID check and Save.
struct CookiePasteSheet: View {
    @Bindable var model: YouTubeLoginModel
    let onSave: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        SheetScaffold("Paste a cookie") {
            VStack(alignment: .leading, spacing: 12) {
                Text("If Google won't sign in here, sign in to music.youtube.com in a desktop browser, open the developer tools, copy the Cookie header of any request and paste it below. It must include SAPISID. It is stored only in this phone's Keychain.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $model.cookieDraft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .frame(minHeight: 160)
                    .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                               tint: theme.surfaceContainerHighest.opacity(GlassTint.surface))
                    .accessibilityIdentifier("youtube.cookieField")
                if let error = model.cookieError {
                    Text(error)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.error)
                }
                HStack(spacing: 10) {
                    YouTubeWideButton(title: "Paste", systemImage: "doc.on.clipboard") {
                        if let text = UIPasteboard.general.string { model.cookieDraft = text }
                    }
                    YouTubeWideButton(title: "Save", systemImage: "checkmark",
                                      tint: theme.primary.opacity(GlassTint.prominent), foreground: theme.onPrimary,
                                      enabled: !model.cookieDraft.isEmpty, action: onSave)
                        .accessibilityIdentifier("youtube.saveCookie")
                }
            }
            .padding(.horizontal, Tokens.Spacing.xxl)
            .padding(.bottom, Tokens.Spacing.xxl)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("youtube.cookieSheet")
    }
}

/// Google's sign-in page (Android: a `WebView` on `accounts.google.com/ServiceLogin?…music.youtube.com`). A private
/// data store per visit; once navigation reaches music.youtube.com with a cookie carrying `SAPISID`, the cookie and
/// `window.yt.config_.VISITOR_DATA` are handed over (an earlier hop without SAPISID is ignored, as on Android).
struct YouTubeSignInWebView: UIViewRepresentable {
    static let signInURL = "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F"
    /// A Safari identity (Google refuses sign-in to user agents it flags as embedded).
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"

    let onSession: (_ cookie: String, _ visitorData: String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSession: onSession) }

    func makeUIView(context: Context) -> WKWebView {
        // A web view prepared while nothing animated (see `YouTubeSignInWebViewWarmup`), else a new one, as before.
        let view = YouTubeSignInWebViewWarmup.take()
        view.navigationDelegate = context.coordinator
        if let url = URL(string: Self.signInURL) { view.load(URLRequest(url: url)) }
        return view
    }

    /// A configured web view with its own private data store (one per visit).
    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = userAgent
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSession: (String, String?) -> Void
        private var delivered = false

        init(onSession: @escaping (String, String?) -> Void) {
            self.onSession = onSession
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !delivered, let host = webView.url?.host?.lowercased(), host == "music.youtube.com" else { return }
            Task { await capture(webView) }
        }

        private func capture(_ webView: WKWebView) async {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let header = YouTubeCookieText.header(from: cookies.map { (domain: $0.domain, name: $0.name, value: $0.value) })
            // A first hop (security check) may not carry SAPISID yet: keep waiting for it.
            guard !delivered, YouTubeCookieText.hasSAPISID(header) else { return }
            let visitor = try? await webView.evaluateJavaScript(
                "(window.yt && window.yt.config_ && window.yt.config_.VISITOR_DATA) || ''", in: nil, contentWorld: .page)
            delivered = true
            let visitorData = (visitor as? String).flatMap { $0.isEmpty ? nil : $0 }
            onSession(header, visitorData)
        }
    }
}

/// Creating the first WKWebView of the process (WebKit's helper processes, a private data store) cost tens of
/// milliseconds on the main thread in the first frame of the sign-in push. The Spotify dashboard prepares one while
/// YouTube is signed out, after its own push has settled; the sign-in page takes it (still a fresh view and data store
/// per visit, loaded when the page appears). Without a spare, the page creates one as before.
enum YouTubeSignInWebViewWarmup {
    private static var spare: WKWebView?

    static func prepare() {
        if spare == nil { spare = YouTubeSignInWebView.makeWebView() }
    }

    static func take() -> WKWebView {
        defer { spare = nil }
        return spare ?? YouTubeSignInWebView.makeWebView()
    }

    static func discard() { spare = nil }
}
