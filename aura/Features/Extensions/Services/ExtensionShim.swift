import Foundation
import os

/// Patches an installed extension so its blocking `webRequest` listeners reach
/// Aura instead of WebKit's observe-only implementation.
///
/// WebKit owns the extension's background page: there is no hook to run code in
/// it before the extension's own scripts. So the patch happens on disk. The
/// shim is copied into the extension folder and made the first thing the
/// background context runs, which is early enough to replace
/// `browser.webRequest` before the extension touches it.
///
/// The original manifest is kept as `manifest.original.json`, and the patched
/// one records `aura_shim_version`, so re-running this is free and a shim
/// change re-patches by itself.
enum ExtensionShim {
    /// Must match `SHIM_VERSION` in aura-shim.js.
    static let version = 1

    static let scriptName = "aura-shim.js"
    /// Generated per extension: `runtime.getManifest()` returns undefined under
    /// WebKit, so the manifest is written out as a script the shim can read.
    static let manifestScriptName = "aura-shim-manifest.js"
    static let versionKey = "aura_shim_version"
    static let originalManifestName = "manifest.original.json"

    private static let log = Logger(subsystem: "com.aurabrowser.app", category: "extensions")

    enum ShimError: LocalizedError {
        case missingShimScript
        case unreadableManifest

        var errorDescription: String? {
            switch self {
            case .missingShimScript: return "Aura's extension shim is missing from the app bundle."
            case .unreadableManifest: return "The extension's manifest.json could not be read."
            }
        }
    }

    /// `apply` wrapped for the install path: honours the setting and turns a
    /// failure into the note Settings shows next to the extension.
    @MainActor
    static func patch(at directory: URL) -> String? {
        guard SettingsStore.shared.nativeRequestBlockingEnabled else { return nil }
        do {
            try apply(at: directory)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Patches the extension at `directory` if it wants blocking `webRequest`
    /// and is not already patched. Returns true when the manifest was rewritten.
    @discardableResult
    static func apply(at directory: URL) throws -> Bool {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ShimError.unreadableManifest
        }

        if manifest[versionKey] as? Int == version { return false }
        // Fast path for the overwhelming majority: an extension that never
        // mentions webRequest is left exactly as it was downloaded.
        guard wantsBlockingWebRequest(manifest) else { return false }

        guard let source = Bundle.main.url(forResource: "aura-shim", withExtension: "js") else {
            throw ShimError.missingShimScript
        }

        // Only back up a manifest that has never been through here, so a repeat
        // patch cannot overwrite the original with a patched copy.
        if manifest[versionKey] == nil {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(originalManifestName))
            try? data.write(to: directory.appendingPathComponent(originalManifestName))
        }

        let destination = directory.appendingPathComponent(scriptName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        try writeManifestScript(manifest, to: directory)

        manifest["background"] = patchedBackground(manifest["background"] as? [String: Any], in: directory)
        manifest["permissions"] = withNativeMessaging(manifest["permissions"] as? [Any] ?? [])
        manifest[versionKey] = version

        let patched = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try patched.write(to: manifestURL, options: .atomic)
        log.info("shimmed extension at \(directory.lastPathComponent, privacy: .public)")
        return true
    }

    static func isPatched(at directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return manifest[versionKey] as? Int == version
    }

    /// True when the extension declares webRequest at all. `webRequestBlocking`
    /// on its own is the Firefox spelling; Chrome MV2 grants blocking to any
    /// extension holding `webRequest`, so both count.
    static func wantsBlockingWebRequest(_ manifest: [String: Any]) -> Bool {
        let declared = (manifest["permissions"] as? [Any] ?? [])
            + (manifest["optional_permissions"] as? [Any] ?? [])
        let names = Set(declared.compactMap { $0 as? String })
        return names.contains("webRequest") || names.contains("webRequestBlocking")
    }

    /// The extension sees the manifest it shipped, not the patched one: the
    /// shim's own entries are Aura's business.
    private static func writeManifestScript(_ manifest: [String: Any], to directory: URL) throws {
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let source = "globalThis.__auraManifest = " + (String(data: json, encoding: .utf8) ?? "{}") + ";\n"
        try source.write(to: directory.appendingPathComponent(manifestScriptName), atomically: true, encoding: .utf8)
    }

    // MARK: - Manifest surgery

    private static func withNativeMessaging(_ permissions: [Any]) -> [Any] {
        let names = permissions.compactMap { $0 as? String }
        guard !names.contains("nativeMessaging") else { return permissions }
        // The shim's only way back to Aura is a native message port.
        return permissions + ["nativeMessaging"]
    }

    /// Makes the shim the first script the background context evaluates,
    /// whichever of the three shapes the extension uses.
    private static func patchedBackground(_ background: [String: Any]?, in directory: URL) -> [String: Any] {
        var background = background ?? [:]

        let prelude = [manifestScriptName, scriptName]

        if var scripts = background["scripts"] as? [String] {
            scripts.removeAll(where: prelude.contains)
            background["scripts"] = prelude + scripts
            return background
        }

        if let worker = background["service_worker"] as? String {
            let isModule = (background["type"] as? String) == "module"
            let wrapper = "aura-shim-worker.js"
            let files = prelude + [worker]
            let body = isModule
                ? files.map { "import './\($0)';\n" }.joined()
                : "importScripts(" + files.map { "'\($0)'" }.joined(separator: ", ") + ");\n"
            try? body.write(to: directory.appendingPathComponent(wrapper), atomically: true, encoding: .utf8)
            background["service_worker"] = wrapper
            return background
        }

        if let page = background["page"] as? String {
            injectScriptTags(into: directory.appendingPathComponent(page), scripts: prelude)
            return background
        }

        // No background at all: the extension cannot have listeners either, but
        // giving it the shim costs nothing and keeps the manifest consistent.
        background["scripts"] = prelude
        return background
    }

    /// Puts the shim's script tags ahead of every other script in a background
    /// page. Text surgery rather than an HTML parser: the file is the
    /// extension's own boilerplate, not arbitrary web content.
    private static func injectScriptTags(into pageURL: URL, scripts: [String]) {
        guard var html = try? String(contentsOf: pageURL, encoding: .utf8),
              !html.contains(scriptName)
        else { return }

        // Root-relative so it resolves the same whether the page sits at the
        // extension root or in a subfolder.
        let tag = scripts.map { "<script src=\"/\($0)\"></script>" }.joined(separator: "\n")
        if let range = html.range(of: "<script", options: .caseInsensitive) {
            html.replaceSubrange(range.lowerBound..<range.lowerBound, with: tag + "\n")
        } else if let range = html.range(of: "</head>", options: .caseInsensitive) {
            html.replaceSubrange(range.lowerBound..<range.lowerBound, with: tag + "\n")
        } else {
            html = tag + "\n" + html
        }
        try? html.write(to: pageURL, atomically: true, encoding: .utf8)
    }
}
