import CoreML
import Foundation
import PixlNet

/// Where the downloaded AI model runs (2026-10-07, local AI phase 2): one serial queue that owns the tokenizer, the
/// Core ML model and its key/value cache, so generation never blocks the main thread or a Swift concurrency thread,
/// and requests run one after another (they share one cache).
///
/// - **Lazy:** the tokenizer loads on the first request (or token count), the model on the first generation or a
///   prewarm (a sheet opening). Both are released after `idleSeconds` without use, on a memory warning and when the
///   app goes to the background (a ~1 GB model must not make the system end background playback).
/// - **Cancellable:** a cancelled task stops the generation before its next model step (`LocalLLMGenerator`).
/// - **GPU first:** `.cpuAndGPU`; if a step ever produces NaN there, the model reloads on the CPU (the configuration
///   the CI parity gate measured) and the request runs again once, and the CPU stays in use until the app restarts.
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

    static let idleSeconds: Double = 180

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
    /// `body` before its next model step (and a request still waiting for the queue before it starts).
    func run<T: Sendable>(_ body: @escaping @Sendable (Session) throws -> T) async throws -> T {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async {
                    guard !flag.isSet else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.idleUnload?.cancel()
                    defer { self.scheduleIdleUnload() }
                    do {
                        let session = Session(tokenizer: try self.loadTokenizer(), runtime: self, flag: flag)
                        continuation.resume(returning: try body(session))
                    } catch let error as LocalGenerationError where error == .cancelled {
                        continuation.resume(throwing: CancellationError())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    /// Loads the model ahead of a request (a sheet opening); errors wait for the request itself.
    func prewarm() {
        queue.async {
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
        let started = Date()
        do {
            let loaded = try CoreMLCausalModel(compiledURL: url, computeUnits: prefersCPU ? .cpuOnly : .cpuAndGPU)
            let generator = LocalLLMGenerator(model: loaded)
            model = loaded
            self.generator = generator
            pendingLoadSeconds = Date().timeIntervalSince(started)
            return (loaded, generator)
        } catch {
            throw LoadError(detail: "it couldn't be loaded")
        }
    }

    fileprivate func generate(_ request: LocalGenerationRequest, stopWhen: ([Int]) -> Bool,
                              flag: CancelFlag) throws -> LocalGenerationResult {
        var (model, generator) = try loadModel()
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

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
