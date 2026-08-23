import Foundation

/// Resolving `__MSG_name__` placeholders in a manifest against the extension's own
/// `_locales` files.
///
/// Every translated add-on names itself this way, so without this the browser shows
/// the folder id where the add-on's name belongs. Chrome's rules, which Firefox
/// follows: the placeholder is `__MSG_key__` anywhere in the string, keys are matched
/// case-insensitively, and messages live at `_locales/<locale>/messages.json` as
/// `{"key": {"message": "..."}}`.
enum ExtensionLocalization {
    /// Locale folders to try, best first: the languages the user asked for, each also
    /// tried without its region, then the extension's own default.
    ///
    /// Folder names spell locales with an underscore (`en_GB`) while the system spells
    /// them with a hyphen (`en-GB`), so everything is normalised on the way in.
    static func candidateLocales(preferred: [String], defaultLocale: String?) -> [String] {
        var candidates: [String] = []
        for language in preferred {
            let folder = language.replacingOccurrences(of: "-", with: "_")
            candidates.append(folder)
            if let base = folder.split(separator: "_").first.map(String.init), base != folder {
                candidates.append(base)
            }
        }
        if let defaultLocale {
            candidates.append(defaultLocale.replacingOccurrences(of: "-", with: "_"))
        }
        var seen: Set<String> = []
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// One locale's messages, keyed by lowercased name. Empty when the file is absent
    /// or unreadable, which is the same thing as far as the caller is concerned.
    static func messages(in directory: URL, locale: String) -> [String: String] {
        let url = directory
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent(locale, isDirectory: true)
            .appendingPathComponent("messages.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var messages: [String: String] = [:]
        for (key, entry) in json {
            guard let message = (entry as? [String: Any])?["message"] as? String else { continue }
            messages[key.lowercased()] = message
        }
        return messages
    }

    /// `value` with every placeholder substituted, or nil when one of them has no
    /// message in this locale. Nil rather than a half-substituted string: a name
    /// reading "__MSG_extName__ for Aura" is worse than falling back to the next
    /// locale, and the last fallback is the folder id.
    ///
    /// `__MSG_@@...__` is Chrome's predefined set (`@@extension_id`, `@@ui_locale`),
    /// which no manifest name uses and none of which Aura can answer, so a string
    /// carrying one resolves to nil as well.
    static func resolve(_ value: String, messages: [String: String]) -> String? {
        guard value.contains("__MSG_") else { return value }

        var result = ""
        var rest = Substring(value)
        while let start = rest.range(of: "__MSG_") {
            guard let end = rest.range(of: "__", range: start.upperBound ..< rest.endIndex) else { return nil }
            let key = String(rest[start.upperBound ..< end.lowerBound])
            guard let message = messages[key.lowercased()] else { return nil }
            result += rest[rest.startIndex ..< start.lowerBound] + message
            rest = rest[end.upperBound...]
        }
        return result + rest
    }

    /// A manifest string as the user should read it. Untranslated strings come back
    /// unchanged, so this is safe to call on every manifest value.
    static func localized(
        _ value: String?,
        in directory: URL,
        defaultLocale: String?,
        preferred: [String] = Locale.preferredLanguages
    ) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.contains("__MSG_") else { return value }

        for locale in candidateLocales(preferred: preferred, defaultLocale: defaultLocale) {
            let messages = messages(in: directory, locale: locale)
            if messages.isEmpty {
                continue
            }
            if let resolved = resolve(value, messages: messages), !resolved.isEmpty {
                return resolved
            }
        }
        return nil
    }
}
