import Foundation
import Network
import PixlNet
import Synchronization

/// Claude in the cloud for every AI feature (spec A, owner decision 2026-10-23): the built-in key, the router's inputs
/// (the network, the monthly budget, the developer-mode override), the client and the usage it charges.
///
/// - The key comes from the build's XOR shares (`AnthropicKey`, written on CI from the ANTHROPIC_API_KEY secret) and is
///   combined once, in memory. It is never logged; `redact` strips it from anything bound for Diagnostics.
/// - The router (`PixlNet.AIRouter`): any working internet connection + the key + budget left → Claude Sonnet 5.5;
///   otherwise the on-device model. In developer mode a cloud assistant of the user's own overrides it.
/// - Thread-safe reads only (UserDefaults, a lock-protected network flag), so actors and background tasks ask freely.
// @unchecked: UserDefaults is thread-safe but not marked Sendable.
nonisolated final class ClaudeCloud: @unchecked Sendable {
    static let shared = ClaudeCloud()

    let apiKey: String?
    private let defaults: UserDefaults
    private let connectivity: AIConnectivity

    init(shares: [[UInt8]] = AnthropicKey.shares, defaults: UserDefaults = .standard, connectivity: AIConnectivity = .shared) {
        apiKey = ClaudeKeyShares.combine(shares)
        self.defaults = defaults
        self.connectivity = connectivity
    }

    /// This build carries a built-in key.
    var hasKey: Bool { apiKey != nil }

    /// Developer mode is on and a cloud assistant with the user's own key is selected.
    var ownProviderOverride: Bool {
        defaults.bool(forKey: PreferenceKeys.developerMode)
            && AiProvider.fromString(defaults.string(forKey: PreferenceKeys.aiProvider) ?? AiProvider.onDevice.rawValue) != .onDevice
    }

    /// Who answers an AI request now.
    func route() -> AIRoute {
        AIRouter.decide(AIRoutingInputs(isOnline: connectivity.isOnline(), hasBuiltInKey: hasKey,
                                        budgetExhausted: ClaudeBudgetStore.isExhausted(defaults),
                                        ownProviderOverride: ownProviderOverride))
    }

    /// A client for the built-in key (nil without one).
    func client() -> ClaudeClient? {
        guard let apiKey else { return nil }
        return ClaudeClient(apiKey: apiKey, http: URLSessionHTTPClient(), streamer: URLSessionClaudeStreamer())
    }

    /// Charges a response to this month's budget.
    func record(_ usage: ClaudeUsage) {
        ClaudeBudgetStore.record(usage, defaults: defaults)
    }

    /// A fallback or failure, for Diagnostics (the key is stripped).
    func logFallback(_ message: String) {
        DiagnosticsLog.shared.log("ai", redact("claude → on-device: " + message))
    }

    func redact(_ text: String) -> String { ClaudeKeyShares.redact(text, key: apiKey) }
}

/// The month's spend and the cap (Settings › AI features, developer mode: $0–$200, default $50), in UserDefaults.
/// Not in backups: the spend belongs to this device and its month.
nonisolated enum ClaudeBudgetStore {
    private static let lock = Mutex(())

    static func capDollars(_ defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: PreferenceKeys.aiClaudeMonthlyCap) != nil else { return ClaudeBudget.defaultCapDollars }
        return ClaudeBudget.clampCap(defaults.double(forKey: PreferenceKeys.aiClaudeMonthlyCap))
    }

    static func budget(_ defaults: UserDefaults) -> ClaudeBudget {
        ClaudeBudget(month: defaults.string(forKey: PreferenceKeys.aiClaudeSpendMonth) ?? "",
                     spentUnits: Int64(defaults.integer(forKey: PreferenceKeys.aiClaudeSpendUnits)))
    }

    static func isExhausted(_ defaults: UserDefaults, now: Date = Date()) -> Bool {
        budget(defaults).isExhausted(capDollars: capDollars(defaults), month: ClaudeBudget.monthKey(now))
    }

    static func spentDollars(_ defaults: UserDefaults, now: Date = Date()) -> Double {
        budget(defaults).spentDollars(month: ClaudeBudget.monthKey(now))
    }

    static func record(_ usage: ClaudeUsage, defaults: UserDefaults, now: Date = Date()) {
        lock.withLock { _ in
            let next = budget(defaults).recording(usage, month: ClaudeBudget.monthKey(now))
            defaults.set(next.month, forKey: PreferenceKeys.aiClaudeSpendMonth)
            defaults.set(Int(next.spentUnits), forKey: PreferenceKeys.aiClaudeSpendUnits)
        }
    }
}

/// Whether the phone has a working internet connection (one passive `NWPathMonitor`, started the first time an AI
/// feature asks — never at launch). Until the first report the answer is "online": Claude is tried, and a network
/// failure falls back to the on-device model for that request anyway.
nonisolated final class AIConnectivity: @unchecked Sendable {
    static let shared = AIConnectivity()

    private struct State {
        var started = false
        var online: Bool?
    }

    private let state = Mutex(State())
    private let monitor = NWPathMonitor()

    func isOnline() -> Bool {
        let snapshot = state.withLock { state in
            let current = (start: !state.started, online: state.online)
            state.started = true
            return current
        }
        let shouldStart = snapshot.start, online = snapshot.online
        if shouldStart {
            monitor.pathUpdateHandler = { [weak self] path in
                let satisfied = path.status == .satisfied
                self?.state.withLock { $0.online = satisfied }
            }
            monitor.start(queue: DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.ai-connectivity", qos: .utility))
        }
        return online ?? true
    }
}

/// Streams a Messages API response over URLSession (`bytes(for:)`, line by line). A non-2xx status ends the stream with
/// the API's error (read from the body), which the client retries or reports.
nonisolated struct URLSessionClaudeStreamer: ClaudeLineStreaming {
    func open(_ request: HTTPRequest) async throws -> ClaudeStreamOpening {
        guard let urlRequest = URLSessionHTTPClient.makeURLRequest(request) else { throw ClaudeError.invalidResponse }
        return .lines(AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw ClaudeError.network("No HTTP response") }
                    guard (200...299).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 65_536 { break }
                        }
                        let headers = http.allHeaderFields.map { HTTPHeader(String(describing: $0.key), String(describing: $0.value)) }
                        throw ClaudeError.fromResponse(HTTPResponse(statusCode: http.statusCode, headers: headers, body: body))
                    }
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch let error as ClaudeError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: ClaudeError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        })
    }
}
