import Foundation

/// The plain-text CSV every password manager reads.
///
/// Column set and order are Chrome's, which is also what Bitwarden, 1Password and
/// KeePassXC expect from a "Chrome CSV": `name,url,username,password,note`. Renaming or
/// reordering a column turns a working import into a silent one, so the header is a
/// constant and the tests pin it.
///
/// Assembly is a pure function that never touches the keychain, so the escaping can be
/// tested against nasty values without an authenticated reveal, and so nothing here can
/// log a secret: the only place a password exists is the string this returns.
enum PasswordCSVExport {
    static let header = "name,url,username,password,note"

    struct Row: Equatable {
        var name: String
        var url: String
        var username: String
        var password: String
        var note: String

        init(name: String, url: String, username: String, password: String, note: String = "") {
            self.name = name
            self.url = url
            self.username = username
            self.password = password
            self.note = note
        }
    }

    static func csv(_ rows: [Row]) -> String {
        var out = header + "\n"
        for row in rows {
            out += [row.name, row.url, row.username, row.password, row.note]
                .map(field)
                .joined(separator: ",")
            out += "\n"
        }
        return out
    }

    /// RFC 4180 quoting. A field is wrapped when it holds a comma, a quote, a newline or
    /// an edge space; inner quotes double.
    ///
    /// Deliberately no spreadsheet-injection guard: prefixing a leading `=` or `+` would
    /// protect a spreadsheet and corrupt the password, and the file this writes exists to
    /// be read back by a password manager.
    static func field(_ value: String) -> String {
        let needsQuotes = value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            || value.hasPrefix(" ")
            || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// What one saved credential looks like as a row, minus the secret. Split out so the
    /// call site's only job is to fetch the password and drop it in, which keeps the
    /// authenticated reveal to one line.
    static func row(host: String, origin: String?, username: String, password: String) -> Row {
        Row(
            name: host,
            url: origin ?? "https://\(host)",
            username: username,
            password: password
        )
    }
}
