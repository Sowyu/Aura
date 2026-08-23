import SwiftUI

/// `aura://view-source?url=…`, rendered natively inside the tab exactly like
/// `aura://home`. The markup comes from the capture the opening tab took off the live
/// page, so it is the DOM the user was looking at rather than what the server sent.
struct ViewSourceView: View {
    let tab: Tab

    @Environment(\.theme) private var theme

    @State private var lines: [SourceLine] = []
    @State private var markup = ""
    @State private var failure: String?
    @State private var isLoading = true

    private static let columnPadding: CGFloat = 20
    private static let fontSize: CGFloat = 11.5
    private static let rowSpacing: CGFloat = 1

    private var target: URL? { tab.url.oraPageToolTarget }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background.opacity(0.85))
        .task(id: tab.url) { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Page source")
                    .font(.system(size: 13, weight: .semibold))
                Text(target?.absoluteString ?? "No address")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if !lines.isEmpty {
                Text(lines.count == 1 ? "1 line" : "\(lines.count) lines")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
                Button("Copy Source") { ClipboardUtils.copyToClipboard(markup) }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Self.columnPadding)
        .padding(.vertical, 10)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if isLoading {
            centred { ProgressView().frame(width: 24, height: 24) }
        } else if let failure {
            centred {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        } else {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(lines) { line in
                        row(line)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, Self.columnPadding)
            }
        }
    }

    private func row(_ line: SourceLine) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(line.id))
                .font(.system(size: Self.fontSize, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.mutedForeground.opacity(0.7))
                .frame(width: gutterWidth, alignment: .trailing)
            // Selection is per row: SwiftUI scopes it to one `Text`, and a document this
            // size cannot go into a single one without the lazy stack losing its point.
            // "Copy Source" in the header is the whole-document path.
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: Self.fontSize, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var gutterWidth: CGFloat {
        // Monospaced digits at this size are close enough to 0.6 em that a fixed factor
        // beats measuring the glyph on every row.
        CGFloat(ViewSourceDocument.gutterDigits(for: lines.count)) * Self.fontSize * 0.62
    }

    private func centred(@ViewBuilder _ content: () -> some View) -> some View {
        VStack { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func load() async {
        guard let target else {
            failure = "This address carries no page to show the source of."
            isLoading = false
            return
        }
        isLoading = true
        failure = nil
        switch await PageSourceLoader.markup(for: target) {
        case let .success(html):
            markup = html
            lines = ViewSourceDocument.lines(from: html)
            if lines.isEmpty {
                failure = "The page returned nothing."
            }
        case .failure:
            markup = ""
            lines = []
            failure = "Could not read \(target.absoluteString)."
        }
        isLoading = false
    }
}
