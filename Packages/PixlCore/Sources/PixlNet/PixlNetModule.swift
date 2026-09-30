// PixlNet — HTTPClient protocol, InnerTube contexts/requests/parsing, AAC format selection, TrackMatcher, cipher-regex extraction, Piped, Spotify endpoints/PKCE (SHA-256 injected), token rotation, Google device flow, AMLL/NetEase/LRCLIB, Gemini/OpenAI codecs, prompt engine, DJ intent parser.
// Placeholder from stage 0. Keep the `PixlNetModule` enum: the app's Diagnostics screen lists it.

import PixlFoundation
import PixlModel
import PixlLyrics

/// Identity of the `PixlNet` module.
public enum PixlNetModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlNet"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = [PixlFoundationModule.name, PixlModelModule.name, PixlLyricsModule.name]
}
