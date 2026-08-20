import Foundation
import JavaScriptCore

/// Turns a scriptlet rule (`example.com#%#//scriptlet('set-constant', 'foo', 'bar')`)
/// into the JavaScript that AdGuard's Scriptlets library would run for it.
///
/// The library is ~650 KB. AdGuard's Safari extension ships it inside the content
/// script, which means every page pays to parse it. Aura evaluates it once in a
/// JavaScriptCore context inside the app instead, so a page only ever receives the
/// few kilobytes of code belonging to the scriptlets that actually match it.
final class ScriptletCompiler {
    static let shared = ScriptletCompiler()

    /// The `engine` string AdGuard's own Safari extension passes; scriptlets read it off
    /// the `source` object at run time.
    static let engineName = "safari-extension"

    private let lock = NSLock()
    private var context: JSContext?
    private var didAttemptLoad = false
    /// Function source by scriptlet name. An empty string caches a known-bad name.
    private var cache: [String: String] = [:]

    /// Loads the library off the main thread so the first navigation does not pay for it.
    func warmUp() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            lock.lock()
            defer { lock.unlock() }
            _ = loadedContext()
        }
    }

    /// The scriptlet's function source, or nil when the library does not know the name.
    ///
    /// Deliberately the bare function rather than a ready-to-run snippet: the library
    /// inlines every helper a scriptlet needs into its body, so a page that uses the same
    /// scriptlet fifteen times would otherwise carry fifteen copies of ~14 KB.
    func functionSource(named name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[name] {
            return cached.isEmpty ? nil : cached
        }

        let generated = generate(name: name) ?? ""
        cache[name] = generated
        return generated.isEmpty ? nil : generated
    }

    /// Caller must hold `lock`.
    private func generate(name: String) -> String? {
        guard let context = loadedContext(),
              let scriptlets = context.objectForKeyedSubscript("scriptlets"),
              !scriptlets.isUndefined,
              let function = scriptlets.invokeMethod("getScriptletFunction", withArguments: [name]),
              !function.isUndefined,
              !function.isNull,
              let source = function.toString(),
              source.hasPrefix("function")
        else {
            return nil
        }
        return source
    }

    /// Caller must hold `lock`.
    private func loadedContext() -> JSContext? {
        if didAttemptLoad { return context }
        didAttemptLoad = true

        guard let url = Bundle.main.url(forResource: "adguard-scriptlets", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let created = JSContext()
        else {
            return nil
        }

        created.exceptionHandler = { _, _ in
            // A scriptlet name the library rejects is a normal outcome; the caller sees nil.
        }
        created.evaluateScript(source)
        context = created
        return created
    }
}
