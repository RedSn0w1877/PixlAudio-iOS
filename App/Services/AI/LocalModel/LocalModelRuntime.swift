import CoreML
import Foundation
import PixlModel
import os
import PixlNet

/// Where the downloaded AI model runs (2026-10-07, local AI phase 2): one serial queue that owns the tokenizer, the
/// Core ML model and its key/value cache, so generation never blocks the main thread or a Swift concurrency thread,
/// and requests run one after another (they share one cache).
///
/// - **Lazy:** the tokenizer loads on the first request (or token count), the model on the first generation or a
///   prewarm (a sheet opening). Both are released after `idleSeconds` without use, on a memory warning and when the
///   app goes to the background (a ~1 GB model must not make the system end background playback).
/// - **Cancellable:** a cancelled task stops the generation before its next model step (`LocalLLMGenerator`).
/// - **GPU first, foreground only:** `.cpuAndGPU` while the app is in front; if a step ever produces NaN there, the model
///   reloads on the CPU (the configuration the CI parity gate measured) and the request runs again once, and the CPU stays
///   in use until the app restarts. A backgrounded app may not submit GPU work, and the 2026-10-08 crash report caught
///   exactly that: this queue was still inside a Metal Performance Shaders Graph step when the app went to the
///   background (the unload below used to queue behind the running generation). Now a generation stops at its next
///   step once the app has been out of the foreground for 1.5 s (a short pull-down of Control Center only pauses it),
///   and nothing loads or generates while the app is not in front.
/// - **Prefix reuse:** the cache survives between requests, so Taizo's next turn only feeds the new message.
nonisolated final class LocalModelRuntime: @unchecked Sendable {
    static let shared = LocalModelRuntime(descriptor: ModelCatalog.llm)

    /// The last generation's numbers, for Settings (what only the phone can measure).
    nonisolated struct Stats: Sendable, Equatable {
        var promptTokens: Int
        var reusedTokens: Int
        var answerTokens: Int
        var prefillSeconds: Double
        var tokensPerSecond: Double
        var loadSeconds: Double?
        var onCPU: Bool
    }

    nonisolated struct LoadError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    /// What a request's body gets, on the queue.
    nonisolated struct Session {
        let tokenizer: BytePairTokenizer
        fileprivate let runtime: LocalModelRuntime
        fileprivate let flag: CancelFlag

        /// The model's context length.
        var contextLength: Int { ModelCatalog.LocalLLM.context }

        /// Runs a generation (loading the model first when needed), retrying once on the CPU after bad numerics.
        func generate(_ request: LocalGenerationRequest,
                      stopWhen: ([Int]) -> Bool = { _ in false }) throws -> LocalGenerationResult {
            try runtime.generate(request, stopWhen: stopWhen, flag: flag)
        }
    }

    /// Unloaded this long after the last request (the model is ~900 MB; a chat burst keeps it a moment).
    static let idleSeconds: Double = 12

    let descriptor: ModelDescriptor
    private let queue = DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.localmodel", qos: .userInitiated)

    // Queue-confined.
    private var tokenizer: BytePairTokenizer?
    private var model: CoreMLCausalModel?
    private var generator: LocalLLMGenerator?
    private var prefersCPU = false
    private var idleUnload: DispatchWorkItem?
    private var pendingLoadSeconds: Double?

    private let statsLock = NSLock()
    private var storedStats: Stats?
    private var observers: [any NSObjectProtocol] = []

    init(descriptor: ModelDescriptor) {
        self.descriptor = descriptor
        // By name: this initialiser is not on the main actor (UIApplication's constants are).
        for name in ["UIApplicationDidReceiveMemoryWarningNotification", "UIApplicationDidEnterBackgroundNotification"] {
            observers.append(NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil,
                                                                    queue: nil) { [weak self] _ in self?.unload() })
        }
    }

    /// The last generation's numbers (nil before the first one this launch).
    var lastStats: Stats? {
        statsLock.lock()
        defer { statsLock.unlock() }
        return storedStats
    }

    // MARK: Requests

    /// Runs `body` on the queue with the tokenizer loaded. Cancelling the calling task stops a generation inside
    /// `body` before its next model step; a request still waiting for the queue throws `CancellationError` at once
    /// and never runs (so a time-out or a closed sheet doesn't wait behind another request's generation).
    func run<T: Sendable>(_ body: @escaping @Sendable (Session) throws -> T) async throws -> T {
        // The one gate: automatic callers, safe mode, low memory, Low Power Mode, heat and "not in front" never load it.
        if case .denied(let why) = LocalModelGate.canLoad() { throw LoadError(detail: why) }
        let flag = CancelFlag()
        let handle = HeavyWorkGate.shared.registerCancel { flag.set() }
        defer { HeavyWorkGate.shared.unregisterCancel(handle) }
        await MainActor.run { LocalModelActivity.shared.requestQueued() }
        var failure: String?
        do {
            let value = try await runGated(flag, body)
            Task { @MainActor in LocalModelActivity.shared.requestEnded(failure: nil) }
            return value
        } catch {
            if !(error is CancellationError) { failure = (error as? LoadError)?.detail ?? error.localizedDescription }
            let message = failure
            Task { @MainActor in LocalModelActivity.shared.requestEnded(failure: message) }
            throw error
        }
    }

    /// Stops every request (Cancel on the row, Cancel all, Emergency stop) and frees the model.
    func cancelAll() {
        HeavyWorkGate.shared.abortHeavyWork()
        unload()
    }

    private func runGated<T: Sendable>(_ flag: CancelFlag, _ body: @escaping @Sendable (Session) throws -> T) async throws -> T {
        let pending = PendingRequest<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                // Already cancelled: answered with the error, nothing to queue.
                guard pending.install(continuation) else { return }
                queue.async {
                    // Cancelled while waiting: its caller already has the error.
                    guard pending.begin() else { return }
                    self.idleUnload?.cancel()
                    defer { self.scheduleIdleUnload() }
                    JobTelemetry.shared.started("localModel", id: "request")
                    DiagnosticsLog.shared.log("memory", "model request begins; \(LocalModelGate.memoryText())")
                    Task { @MainActor in LocalModelActivity.shared.set(.loading) }
                    defer { DiagnosticsLog.shared.log("memory", "model request ends; \(LocalModelGate.memoryText())") }
                    do {
                        let session = Session(tokenizer: try self.loadTokenizer(), runtime: self, flag: flag)
                        let value = try body(session)
                        JobTelemetry.shared.ended("localModel", id: "request", .finished)
                        pending.succeed(value)
                    } catch let error as LocalGenerationError where error == .cancelled {
                        JobTelemetry.shared.ended("localModel", id: "request", .cancelled("stopped"))
                        if flag.lowMemory {
                            // Not enough memory: free it at once and say why.
                            self.model = nil
                            self.generator = nil
                            self.tokenizer = nil
                            pending.fail(LoadError(detail: "Not enough memory on this phone"))
                        } else {
                            pending.fail(CancellationError())
                        }
                    } catch {
                        JobTelemetry.shared.ended("localModel", id: "request", .failed(error.localizedDescription))
                        pending.fail(error)
                    }
                }
            }
        } onCancel: {
            flag.set()
            pending.cancelIfWaiting()
        }
    }

    /// Loads the model ahead of a request (a sheet opening); errors wait for the request itself.
    func prewarm() {
        queue.async {
            // Not while the app is out of the foreground (a compile / GPU load there is what the system punishes).
            guard LocalModelGate.canLoad() == .allowed else { return }
            self.idleUnload?.cancel()
            _ = try? self.loadTokenizer()
            _ = try? self.loadModel()
            self.scheduleIdleUnload()
        }
    }

    /// Releases the model and the tokenizer (memory warning, idle, the model deleted or the switch turned off).
    func unload() {
        queue.async {
            self.idleUnload?.cancel()
            self.idleUnload = nil
            self.model = nil
            self.generator = nil
            self.tokenizer = nil
        }
    }

    // MARK: On the queue

    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.model = nil
            self?.generator = nil
            self?.tokenizer = nil
        }
        idleUnload = item
        queue.asyncAfter(deadline: .now() + Self.idleSeconds, execute: item)
    }

    private func loadTokenizer() throws -> BytePairTokenizer {
        if let tokenizer { return tokenizer }
        guard ModelManager.isInstalled(descriptor),
              let url = ModelManager.extraFileURL(descriptor, ModelCatalog.LocalLLM.tokenizerFile) else {
            throw OnDeviceFailure.localModelMissing
        }
        do {
            let loaded = try BytePairTokenizer(contentsOf: url)
            tokenizer = loaded
            return loaded
        } catch {
            throw LoadError(detail: "its tokenizer couldn't be read")
        }
    }

    private func loadModel() throws -> (CoreMLCausalModel, LocalLLMGenerator) {
        if let model, let generator { return (model, generator) }
        guard ModelManager.isInstalled(descriptor), let url = ModelManager.compiledURL(descriptor) else {
            throw OnDeviceFailure.localModelMissing
        }
        // A load while the app is out of the foreground (a queued request that ran late) is refused: GPU work and the
        // first-use compile belong to the foreground.
        guard HeavyWorkGate.shared.isForeground || HeavyWorkGate.shared.hasBackgroundWindow else {
            throw LoadError(detail: "PixlAudio was not in front")
        }
        let started = Date()
        DiagnosticsLog.shared.log("memory", "model load begins; \(LocalModelGate.memoryText())")
        do {
            // CPU only: the configuration the parity gate measured. The GPU (and its first-use compile) is never used.
            let loaded = try CoreMLCausalModel(compiledURL: url, computeUnits: .cpuOnly)
            DiagnosticsLog.shared.log("memory", "model loaded; \(LocalModelGate.memoryText())")
            if LocalModelGate.availableBytes() < LocalModelGatePolicy.floorBytes {
                throw LoadError(detail: "Not enough memory on this phone")
            }
            let generator = LocalLLMGenerator(model: loaded)
            model = loaded
            self.generator = generator
            pendingLoadSeconds = Date().timeIntervalSince(started)
            return (loaded, generator)
        } catch let error as LoadError {
            model = nil
            generator = nil
            throw error
        } catch {
            throw LoadError(detail: "it couldn't be loaded")
        }
    }

    fileprivate func generate(_ request: LocalGenerationRequest, stopWhen: ([Int]) -> Bool,
                              flag: CancelFlag) throws -> LocalGenerationResult {
        var (model, generator) = try loadModel()
        Task { @MainActor in LocalModelActivity.shared.set(.generating) }
        let result: LocalGenerationResult
        do {
            result = try generator.generate(request, stopWhen: stopWhen, isCancelled: { flag.isSet })
        } catch LocalGenerationError.nonFiniteLogits where model.computeUnits != .cpuOnly {
            // The GPU's float16 overflowed somewhere: the CPU, from a fresh cache.
            prefersCPU = true
            self.model = nil
            self.generator = nil
            (model, generator) = try loadModel()
            result = try generator.generate(request, stopWhen: stopWhen, isCancelled: { flag.isSet })
        }
        let stats = Stats(promptTokens: result.promptTokens, reusedTokens: result.reusedTokens,
                          answerTokens: result.tokens.count, prefillSeconds: result.prefillSeconds,
                          tokensPerSecond: result.tokensPerSecond, loadSeconds: pendingLoadSeconds,
                          onCPU: model.computeUnits == .cpuOnly)
        pendingLoadSeconds = nil
        statsLock.lock()
        storedStats = stats
        statsLock.unlock()
        return result
    }
}

/// A cancellation flag set from a task's cancellation handler and read on the queue.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// `HeavyWorkGate`'s abort count when the request began: a critical memory event or an Emergency stop bumps it.
    private let epoch = HeavyWorkGate.shared.abortEpoch
    private var lowMemoryHit = false

    /// The generation stopped because free memory fell under the floor.
    var lowMemory: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lowMemoryHit
    }

    /// Whether the generation must stop before its next model step: the task was cancelled, everything heavy was told to
    /// stop, or the app has not been in the foreground for 1.5 s (a short interruption only pauses it).
    var isSet: Bool {
        lock.lock()
        let cancelled = value
        lock.unlock()
        if cancelled { return true }
        let gate = HeavyWorkGate.shared
        if gate.abortEpoch != epoch { return true }
        if LocalModelGate.availableBytes() < LocalModelGatePolicy.floorBytes {
            lock.lock()
            lowMemoryHit = true
            lock.unlock()
            DiagnosticsLog.shared.log("memory", "generation stopped: free memory under the floor; \(LocalModelGate.memoryText())")
            return true
        }
        if gate.isForeground { return false }
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.05)
            if gate.isForeground { return false }
        }
        DiagnosticsLog.shared.log("model", "generation stopped: the app left the foreground")
        return true
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// One `run` request's continuation, resumed exactly once: by the queue when the request ran, or by the task's
/// cancellation handler when it was cancelled before the queue reached it.
nonisolated final class PendingRequest<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var started = false
    private var cancelled = false

    /// Keeps the continuation; false (and resumed with `CancellationError`) when the task was already cancelled.
    func install(_ continuation: CheckedContinuation<T, any Error>) -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// The queue reached the request: false when it was cancelled first (its caller already has the error).
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        started = true
        return true
    }

    /// The task was cancelled: a request that hasn't started is answered now; a running one stops through its flag.
    func cancelIfWaiting() {
        lock.lock()
        cancelled = true
        let waiting = started ? nil : continuation
        if waiting != nil { continuation = nil }
        lock.unlock()
        waiting?.resume(throwing: CancellationError())
    }

    func succeed(_ value: T) {
        take()?.resume(returning: value)
    }

    func fail(_ error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
}
