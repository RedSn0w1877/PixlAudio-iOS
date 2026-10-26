// The one AI router every AI feature asks (spec A2, owner decision 2026-10-23: "always cloud for everything; if no
// internet fall back to local"): with a working internet connection, the built-in Claude key and budget left this
// month, Claude answers; otherwise the on-device model does. The developer-mode "Cloud assistants (optional)" providers
// (the user's own keys) stay an override, in developer mode only. Same rules and wording on Android.

import Foundation

/// Who answers an AI request.
public enum AIRoute: Sendable, Hashable {
    /// Claude Sonnet 5.5 with the built-in key.
    case claude
    /// Developer mode: the user's own cloud provider (Settings › AI features › Cloud assistants).
    case ownProvider
    /// The on-device model, and why.
    case onDevice(AIRouteReason)

    public var isClaude: Bool { self == .claude }
}

/// Why a request stays on the device.
public enum AIRouteReason: String, Sendable, Hashable {
    case offline
    /// This build carries no built-in Claude key (forks, pull requests, local builds).
    case noBuiltInKey
    /// The monthly budget of the built-in key is used up.
    case budgetUsed
}

/// What the router decides from.
public struct AIRoutingInputs: Sendable, Hashable {
    /// The device has a working internet connection (any network).
    public var isOnline: Bool
    public var hasBuiltInKey: Bool
    public var budgetExhausted: Bool
    /// Developer mode is on and a cloud assistant of the user's own is selected.
    public var ownProviderOverride: Bool

    public init(isOnline: Bool, hasBuiltInKey: Bool, budgetExhausted: Bool, ownProviderOverride: Bool = false) {
        self.isOnline = isOnline
        self.hasBuiltInKey = hasBuiltInKey
        self.budgetExhausted = budgetExhausted
        self.ownProviderOverride = ownProviderOverride
    }
}

public enum AIRouter {
    public static func decide(_ inputs: AIRoutingInputs) -> AIRoute {
        if inputs.ownProviderOverride { return .ownProvider }
        if !inputs.hasBuiltInKey { return .onDevice(.noBuiltInKey) }
        if !inputs.isOnline { return .onDevice(.offline) }
        if inputs.budgetExhausted { return .onDevice(.budgetUsed) }
        return .claude
    }

    /// Settings › AI features' status line.
    public static func statusLine(_ route: AIRoute) -> String {
        switch route {
        case .claude: "Claude (cloud) — switches to this phone when offline"
        case .ownProvider: "Your own cloud assistant (developer mode)"
        case .onDevice(.offline): "This phone's AI — no internet right now"
        case .onDevice(.noBuiltInKey): "This phone's AI — cloud AI isn't set up in this build"
        case .onDevice(.budgetUsed): "This phone's AI — this month's cloud AI limit is used up"
        }
    }

    /// The one-line note an AI screen shows while it runs on the device for a reason the user may not expect.
    public static func note(_ route: AIRoute) -> String? {
        switch route {
        case .onDevice(.offline): "You're offline, so this phone's AI is answering. Web search is off."
        case .onDevice(.budgetUsed): "This month's cloud AI limit is used up, so this phone's AI is answering."
        default: nil
        }
    }
}
