import FoundationModels
import SwiftUI

// Compat27 — the ONLY file allowed to use iOS 27-only APIs (CI enforces this in ci/check-forbidden.sh).
//
// The app deploys to iOS 26.1 and is built with Xcode 27 (Swift 6.4) on CI; a fallback lane still builds
// with Xcode 26.6 (Swift 6.2), whose SDK does not contain iOS 27 symbols. So every iOS 27 API is wrapped
// twice: `#if compiler(>=6.4)` hides it from the old compiler, `if #available(iOS 27, *)` guards it at
// run time, and the else branches fall back to iOS 26 behaviour. Call sites use the wrapper only.
//
// Pattern:
//
//     extension View {
//         /// Minimizes the navigation bar on scroll where the OS supports it (iOS 27+); no-op on iOS 26.
//         @ViewBuilder
//         func compatToolbarMinimizesOnScroll() -> some View {
//             #if compiler(>=6.4)
//             if #available(iOS 27, *) {
//                 self.toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
//             } else {
//                 self
//             }
//             #else
//             self
//             #endif
//         }
//     }
//
// Record each wrapped API in docs/api-notes.md (min OS 27.0, doc URL) and verify it on the xcode-27 lane
// AND the fallback-xcode26 lane before merging.

enum Compat27 {
    /// Whether this process runs on iOS 27 or later (for diagnostics and feature toggles).
    static var isRunningOnIOS27OrLater: Bool {
        if #available(iOS 27, *) {
            return true
        }
        return false
    }
}

// MARK: - Foundation Models (iOS 27 error types)

extension Compat27 {
    /// The iOS 27 Foundation Models errors as an `OnDeviceFailure` (nil for anything else, and always on iOS 26 or
    /// with the Xcode 26 compiler). The iOS 27 SDK deprecates `LanguageModelSession.GenerationError` in favour of
    /// `LanguageModelError`, `LanguageModelSession.Error` and `SystemLanguageModel.Error`; which ones an app built for
    /// iOS 26.1 receives on iOS 27 isn't documented, so `OnDeviceModel.failure(for:)` checks both generations.
    nonisolated static func onDeviceFailure(_ error: any Error) -> OnDeviceFailure? {
        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return .tooLong
                case .guardrailViolation, .refusal: return .blocked
                case .unsupportedLanguageOrLocale: return .language
                case .rateLimited: return .busy
                case .timeout: return .slow
                default: return .other(error.localizedDescription)
                }
            }
            if let error = error as? LanguageModelSession.Error {
                switch error {
                case .concurrentRequests: return .busy
                default: return .other(error.localizedDescription)
                }
            }
            if error is SystemLanguageModel.Error { return .notReady }
        }
        #endif
        return nil
    }
}
