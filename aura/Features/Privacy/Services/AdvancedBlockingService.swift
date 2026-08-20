import ContentBlockerConverter
import CryptoKit
import FilterEngine
import Foundation
import os.log

/// The rules Aura injects into one document.
struct AdvancedBlockingPayload: Equatable {
    /// The generated per-page script. Everything else is a constant library script.
    let source: String
    let needsExtendedCss: Bool
    let cssRuleCount: Int
    let extendedCssRuleCount: Int
    let scriptletCount: Int
    let scriptRuleCount: Int

    var byteCount: Int { source.utf8.count }

    var isEmpty: Bool {
        cssRuleCount + extendedCssRuleCount + scriptletCount + scriptRuleCount == 0
    }
}

/// Applies the filter rules WebKit's content blocking format cannot express.
///
/// Aura converts every list twice over: once into `WKContentRuleList` JSON, and once
/// into AdGuard's "advanced rules" text. This service indexes that text with
/// SafariConverterLib's own `FilterEngine`, looks it up per navigation, and turns the
/// hit into a small `WKUserScript`. It is the same split AdGuard for Safari uses, with
/// the web extension replaced by the fact that Aura owns the web view.
///
/// ponytail: one engine per space, rebuilt whole whenever the enabled lists or their
/// revisions change. Incremental rebuilds only matter if list updates start costing
/// noticeable CPU on a machine with many spaces.
///
/// `@unchecked Sendable`: every mutable field is guarded by `lock`, which is what lets
/// the build run on a background queue while navigations read the engine on the main one.
final class AdvancedBlockingService: @unchecked Sendable {
    static let shared = AdvancedBlockingService()

    /// Posted when the global toggle or a per-site rule changes. `userInfo["host"]`
    /// carries the affected registrable domain, or is absent for a global change.
    static let didChangeNotification = Notification.Name("AuraAdvancedBlockingChanged")

    private struct SpaceEngine {
        let signature: String
        let webExtension: WebExtension
        let removeParams: RemoveParamRuleSet
    }

    private let disabledHostsKey = "privacy.advancedBlocking.disabledHosts"

    private let defaults: UserDefaults
    private let artifactStore: ContentBlockerArtifactStore
    private let scriptletCompiler: ScriptletCompiler
    private let baseURL: URL
    private let buildQueue = DispatchQueue(label: "com.aurabrowser.advancedBlocking.build", qos: .utility)

    private let lock = NSLock()
    private var engines: [UUID: SpaceEngine] = [:]
    private var buildingSignatures: Set<String> = []
    private var disabledHosts: Set<String>
    private var settingsObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        artifactStore: ContentBlockerArtifactStore = .shared,
        scriptletCompiler: ScriptletCompiler = .shared,
        baseURL: URL? = nil
    ) {
        self.defaults = defaults
        self.artifactStore = artifactStore
        self.scriptletCompiler = scriptletCompiler
        self.baseURL = baseURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Aura", isDirectory: true)
            .appendingPathComponent("AdvancedBlocking", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AuraAdvancedBlocking")
        disabledHosts = Set(defaults.stringArray(forKey: disabledHostsKey) ?? [])

        // A finished list refresh or a changed list selection posts this, and either one
        // means the advanced rules on disk moved.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .spacePrivacySettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let spaceID = notification.userInfo?["containerId"] as? UUID else { return }
            MainActor.assumeIsolated {
                self?.prepare(spaceID: spaceID)
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    // MARK: - Toggles

    @MainActor
    var isGloballyEnabled: Bool {
        SettingsStore.shared.advancedBlockingEnabled
    }

    @MainActor
    func isEnabled(for url: URL) -> Bool {
        guard isGloballyEnabled else { return false }
        guard let host = registrableDomain(from: url) else { return true }
        return !isDisabled(host: host)
    }

    func isDisabled(host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disabledHosts.contains(host)
    }

    /// Turns advanced blocking off (or back on) for a registrable domain, permanently.
    func setEnabled(_ enabled: Bool, forHost host: String) {
        let key = registrableDomain(from: host)
        guard !key.isEmpty else { return }

        lock.lock()
        if enabled {
            disabledHosts.remove(key)
        } else {
            disabledHosts.insert(key)
        }
        let snapshot = disabledHosts.sorted()
        lock.unlock()

        defaults.set(snapshot, forKey: disabledHostsKey)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: ["host": key]
        )
    }

    // MARK: - Engine

    /// Builds (or refreshes) the engine for a space. Cheap and idempotent when the
    /// enabled lists have not changed since the last build.
    @MainActor
    func prepare(spaceID: UUID) {
        guard isGloballyEnabled else { return }

        let settings = SettingsStore.shared.privacySettings(for: spaceID)
        guard settings.adBlock.enabled else { return }

        let enabledIDs = Set(settings.adBlock.enabledListIDs)
        let sources = SettingsStore.shared.adBlockFilterLists
            .filter { enabledIDs.contains($0.id) }
            .compactMap { record -> (id: String, revision: String)? in
                guard let revision = record.activeRevision else { return nil }
                return (record.id, revision)
            }
            .sorted { $0.id < $1.id }

        guard !sources.isEmpty else { return }

        let signature = Self.signature(for: sources)
        lock.lock()
        let isCurrent = engines[spaceID]?.signature == signature || buildingSignatures.contains(signature)
        if !isCurrent {
            buildingSignatures.insert(signature)
        }
        lock.unlock()
        guard !isCurrent else { return }

        scriptletCompiler.warmUp()
        buildQueue.async { [weak self] in
            self?.build(spaceID: spaceID, sources: sources, signature: signature)
        }
    }

    private func build(spaceID: UUID, sources: [(id: String, revision: String)], signature: String) {
        defer {
            lock.lock()
            buildingSignatures.remove(signature)
            lock.unlock()
        }

        let rulesText = sources
            .compactMap { artifactStore.advancedRulesText(for: $0.id, revision: $0.revision) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let removeParamLines = sources.flatMap { artifactStore.removeParamRules(for: $0.id, revision: $0.revision) }

        do {
            try installEngine(
                spaceID: spaceID,
                advancedRulesText: rulesText,
                removeParamRules: removeParamLines,
                signature: signature
            )
        } catch {
            os_log(.error, "Advanced blocking engine build failed: %@", error.localizedDescription)
        }
    }

    /// Indexes the advanced rules and publishes the result as the space's engine.
    /// Synchronous and blocking; `prepare` is the call that keeps it off the main thread.
    func installEngine(
        spaceID: UUID,
        advancedRulesText: String,
        removeParamRules: [String],
        signature: String = UUID().uuidString
    ) throws {
        let containerURL = baseURL.appendingPathComponent(spaceID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)

        let builder = try WebExtension(containerURL: containerURL)
        _ = try builder.buildFilterEngine(rules: advancedRulesText)

        // A fresh instance so the first lookup deserialises the engine we just wrote, and
        // that deserialisation happens here rather than on the navigation that needs it.
        let reader = try WebExtension(containerURL: containerURL)
        if let warmUpURL = URL(string: "https://example.org/") {
            _ = reader.lookup(pageUrl: warmUpURL, topUrl: nil)
        }

        let engine = SpaceEngine(
            signature: signature,
            webExtension: reader,
            removeParams: RemoveParamRuleSet(lines: removeParamRules)
        )
        lock.lock()
        engines[spaceID] = engine
        lock.unlock()
    }

    private static func signature(for sources: [(id: String, revision: String)]) -> String {
        let joined = sources.map { "\($0.id):\($0.revision)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: - Per-navigation lookup

    /// Rules for a top-level document, ready to inject at document start.
    func payload(for url: URL, spaceID: UUID) -> AdvancedBlockingPayload? {
        guard let configuration = configuration(for: url, topURL: nil, spaceID: spaceID) else { return nil }
        return makePayload(configuration: configuration, url: url)
    }

    /// The script to evaluate inside a cross-origin subframe that asked for its own rules.
    ///
    /// ponytail: this arrives after the frame's document already started, so scriptlets
    /// here can lose the race against the frame's own scripts. Fixing that needs a
    /// per-frame `WKUserScript`, which WebKit does not offer.
    func frameScript(for url: URL, topURL: URL?, spaceID: UUID) -> String? {
        guard let configuration = configuration(for: url, topURL: topURL, spaceID: spaceID),
              let payload = makePayload(configuration: configuration, url: url, forFrame: true)
        else {
            return nil
        }

        let library = payload.needsExtendedCss ? Self.extendedCssLibrarySource : ""
        return library + payload.source
    }

    /// The document URL with `$removeparam` parameters stripped, or nil when unchanged.
    func strippedURL(for url: URL, spaceID: UUID) -> URL? {
        lock.lock()
        let removeParams = engines[spaceID]?.removeParams
        lock.unlock()
        return removeParams?.strippedURL(for: url)
    }

    private func configuration(
        for url: URL,
        topURL: URL?,
        spaceID: UUID
    ) -> WebExtension.Configuration? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }

        lock.lock()
        let webExtension = engines[spaceID]?.webExtension
        lock.unlock()

        guard let webExtension else { return nil }
        return webExtension.lookup(pageUrl: url, topUrl: topURL)
    }

    private func makePayload(
        configuration: WebExtension.Configuration,
        url: URL,
        forFrame: Bool = false
    ) -> AdvancedBlockingPayload? {
        let scriptlets = scriptletBlock(for: configuration.scriptlets)

        let payloadObject: [String: Any] = [
            "origin": Self.origin(of: url),
            "css": configuration.css,
            "extendedCss": configuration.extendedCss
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let scriptBodies = ([scriptlets.code] + configuration.js.map { "try {\n\($0)\n} catch (e) {}" })
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let source: String
        if forFrame {
            source = """
            (function () {
            \(scriptBodies)
            window.__auraAB && window.__auraAB.applyForFrame(\(json));
            })();
            """
        } else {
            source = """
            window.__auraAB && window.__auraAB.apply(\(json), function () {
            \(scriptBodies)
            });
            """
        }

        let payload = AdvancedBlockingPayload(
            source: source,
            needsExtendedCss: !configuration.extendedCss.isEmpty,
            cssRuleCount: configuration.css.count,
            extendedCssRuleCount: configuration.extendedCss.count,
            scriptletCount: scriptlets.count,
            scriptRuleCount: configuration.js.count
        )
        return payload.isEmpty ? nil : payload
    }

    /// Scriptlet code for one page, with each scriptlet's body emitted once no matter how
    /// many rules use it. The library inlines every helper into each scriptlet function, so
    /// a page like YouTube with 36 scriptlet rules would otherwise carry 500 KB of near
    /// duplicates.
    ///
    /// ponytail: still ~215 KB on YouTube, because different scriptlets inline the same
    /// helpers and only a bundler could spot that. Revisit if document-start time regresses.
    private func scriptletBlock(for scriptlets: [WebExtension.Scriptlet]) -> (code: String, count: Int) {
        var declarations: [String] = []
        var calls: [String] = []
        var indexByName: [String: Int] = [:]

        for scriptlet in scriptlets {
            let index: Int
            if let existing = indexByName[scriptlet.name] {
                index = existing
            } else {
                guard let functionSource = scriptletCompiler.functionSource(named: scriptlet.name) else { continue }
                index = declarations.count
                indexByName[scriptlet.name] = index
                declarations.append("var __auraScriptlet\(index) = (\(functionSource));")
            }

            guard let arguments = Self.callArguments(for: scriptlet) else { continue }
            calls.append("try { __auraScriptlet\(index)(\(arguments)); } catch (e) {}")
        }

        guard !calls.isEmpty else { return ("", 0) }
        return ((declarations + calls).joined(separator: "\n"), calls.count)
    }

    /// The `(source, args)` pair AdGuard's own `passSourceAndProps` would generate.
    private static func callArguments(for scriptlet: WebExtension.Scriptlet) -> String? {
        let source: [String: Any] = [
            "name": scriptlet.name,
            "args": scriptlet.args,
            "engine": ScriptletCompiler.engineName,
            "version": ContentBlockerConverterVersion.library,
            "verbose": false
        ]
        guard let sourceData = try? JSONSerialization.data(withJSONObject: source, options: [.sortedKeys]),
              let argsData = try? JSONSerialization.data(withJSONObject: scriptlet.args),
              let sourceJSON = String(data: sourceData, encoding: .utf8),
              let argsJSON = String(data: argsData, encoding: .utf8)
        else {
            return nil
        }
        return "\(sourceJSON), \(argsJSON)"
    }

    /// `location.origin` as the page will report it, so the applier can tell whether the
    /// rules it was handed belong to the frame it is running in.
    static func origin(of url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), let host = url.host else { return "null" }
        let defaultPort = scheme == "https" ? 443 : 80
        guard let port = url.port, port != defaultPort else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }
}

/// The constant half of the injection: the applier and the ExtendedCss library, both
/// read from the bundle once.
extension AdvancedBlockingService {
    // MARK: - Injected scripts

    /// The constant scripts: the applier, plus ExtendedCss when the page needs it.
    func userScripts(for payload: AdvancedBlockingPayload) -> [BrowserUserScript] {
        var scripts = [
            BrowserUserScript(
                name: "aura-advanced-blocking",
                source: Self.applierSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        ]

        if payload.needsExtendedCss {
            scripts.append(
                BrowserUserScript(
                    name: "aura-extended-css",
                    source: Self.extendedCssLibrarySource,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }

        scripts.append(
            BrowserUserScript(
                name: "aura-advanced-blocking-rules",
                source: payload.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        return scripts
    }

    static let applierSource: String = loadResource(named: "advanced-blocking") ?? ""

    /// The library declares a single top-level `var`, so wrapping it keeps the page's
    /// own globals untouched.
    static let extendedCssLibrarySource: String = {
        guard let source = loadResource(named: "adguard-extended-css") else { return "" }
        return """
        (function () {
        \(source)
        window.__auraExtendedCss = ExtendedCss;
        })();
        """
    }()

    private static func loadResource(named name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
