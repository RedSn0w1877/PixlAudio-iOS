import Foundation
import Observation
import PixlNet

/// State of the YouTube sign-in screen (Android `YouTubeLoginScreen` + the dashboard's device-code dialog
/// `YouTubeSignInDialog` / `SpotifyDashboardViewModel` sign-in steps). Three ways in:
/// - the Google sign-in page in a web view (Android's flow): the music.youtube.com cookie is captured once it carries
///   `SAPISID`, with the page's `VISITOR_DATA`;
/// - the device-code flow (`google.com/device` + a short code; the token authenticates the TVHTML5 client);
/// - pasting a cookie copied from a desktop browser (when Google refuses embedded sign-in).
@MainActor
@Observable
final class YouTubeLoginModel {
    nonisolated struct Prompt: Equatable, Sendable {
        var userCode: String
        var verificationUrl: String
    }

    var prompt: Prompt?
    var showsCodeSheet = false
    var showsCookieSheet = false
    var isRequestingCode = false
    var cookieDraft = ""
    var cookieError: String?
    /// Android `youTubeSignInError` (the alert after a failed sign-in).
    var errorMessage: String?
    /// The web view captured a session (stops further captures).
    private(set) var didCapture = false

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    static let demoPrompt = Prompt(userCode: "PXL-AUD-ION", verificationUrl: "https://www.google.com/device")
    static let demoCookie = "SID=g.a000demo; HSID=Ademo; SSID=Ademo; APISID=demo/Ademo; SAPISID=demo/Asapisid"

    // MARK: Device code

    /// Step 1 shows the code; step 2 polls in the background until Google says yes, no or the code expires.
    func startDeviceCode(_ youtube: YouTubeServices, onSignedIn: @escaping @MainActor () -> Void) {
        guard let auth = youtube.deviceAuth, !isRequestingCode else { return }
        isRequestingCode = true
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let device = await auth.requestDeviceCode() else {
                self?.isRequestingCode = false
                self?.errorMessage = "Google did not answer. Check the connection and try again."
                return
            }
            guard let self else { return }
            self.isRequestingCode = false
            self.prompt = Prompt(userCode: device.userCode, verificationUrl: device.verification)
            self.showsCodeSheet = true
            let result = try? await auth.pollForToken(device)
            guard !Task.isCancelled else { return }
            self.showsCodeSheet = false
            self.prompt = nil
            switch result {
            case .success:
                await youtube.refreshAccountState()
                onSignedIn()
            case .failed(let reason):
                self.errorMessage = reason
            case nil:
                break
            }
        }
    }

    func cancelDeviceCode() {
        pollTask?.cancel()
        pollTask = nil
        prompt = nil
        showsCodeSheet = false
        isRequestingCode = false
    }

    // MARK: Cookie

    /// The paste fallback; false (with `cookieError`) when the text has no `SAPISID`.
    func savePastedCookie(_ youtube: YouTubeServices) async -> Bool {
        guard YouTubeCookieText.hasSAPISID(cookieDraft) else {
            cookieError = "That cookie has no SAPISID. Copy the whole Cookie header from a signed-in music.youtube.com tab."
            return false
        }
        guard await youtube.saveCookie(cookieDraft, visitorData: nil) else {
            cookieError = "Couldn't save the cookie."
            return false
        }
        cookieError = nil
        cookieDraft = ""
        showsCookieSheet = false
        return true
    }

    /// The web view reached music.youtube.com with a complete session.
    func captured(cookie: String, visitorData: String?, _ youtube: YouTubeServices) async -> Bool {
        guard !didCapture, YouTubeCookieText.hasSAPISID(cookie) else { return false }
        didCapture = true
        let saved = await youtube.saveCookie(cookie, visitorData: visitorData)
        if !saved { didCapture = false }
        return saved
    }
}
