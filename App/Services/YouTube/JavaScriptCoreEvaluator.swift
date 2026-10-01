import Foundation
import JavaScriptCore
import PixlNet

/// Runs the signature / `n` functions PixlNet extracts from base.js (Android `JsEvaluator`, a hidden WebView) with
/// JavaScriptCore. One virtual machine, a fresh context per call so nothing leaks between player versions; the
/// actor serialises calls (a `JSVirtualMachine` must not run on two threads at once). base.js itself is cached on
/// disk per player version by `BaseJsCachingHTTPClient`, and the extracted functions per process by
/// `SignatureCipherSolver`.
actor JavaScriptCoreEvaluator: JavaScriptEvaluating {
    private var machine: JSVirtualMachine?
    /// The last exception (diagnostics).
    private(set) var lastError: String?

    func evaluate(_ script: String) async -> String? {
        if machine == nil { machine = JSVirtualMachine() }
        guard let machine, let context = JSContext(virtualMachine: machine) else { return nil }
        let value = context.evaluateScript(script)
        if let exception = context.exception {
            lastError = exception.toString()
            return nil
        }
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        return value.toString()
    }
}
