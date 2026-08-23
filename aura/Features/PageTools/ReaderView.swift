import SwiftUI

/// `aura://reader?url=…`, rendered natively inside the tab like `aura://home`. The
/// article comes out of `ReaderExtractor`, which runs off the main actor: parsing a
/// large page takes long enough to drop frames if it does not.
struct ReaderView: View {
    let tab: Tab

    @Environment(\.theme) private var theme

    @State private var article: ReaderArticle?
    @State private var failure: String?
    @State private var isLoading = true

    /// Roughly 70 characters a line at the body size below, which is where long-form
    /// text stops being tiring to read.
    private static let columnWidth: CGFloat = 680
    private static let bodySize: CGFloat = 16
    private static let padding: CGFloat = 32

    private var target: URL? { tab.url.oraPageToolTarget }

    var body: some View {
        Group {
            if isLoading {
                centred { ProgressView().frame(width: 24, height: 24) }
            } else if let article {
                articleColumn(article)
            } else {
                centred {
                    VStack(spacing: 6) {
                        Text(failure ?? "No article found on this page.")
                            .font(.system(size: 13))
                        Text("Close this tab to go back to the page.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.mutedForeground)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.opacity(0.85))
        .task(id: tab.url) { await load() }
    }

    // MARK: - Article

    private func articleColumn(_ article: ReaderArticle) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(article.title)
                    .font(.system(size: 30, weight: .semibold))
                    .textSelection(.enabled)

                if let credit = credit(for: article) {
                    Text(credit)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.mutedForeground)
                }

                ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .padding(Self.padding)
            .frame(maxWidth: .infinity)
        }
    }

    private func credit(for article: ReaderArticle) -> String? {
        let parts = [article.byline, article.siteName].compactMap { $0 }
        return parts.isEmpty ? target?.host : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func view(for block: ReaderBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, 8)
        case let .paragraph(text):
            Text(text)
                .font(.system(size: Self.bodySize))
                .lineSpacing(6)
        case let .quote(text):
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(theme.border)
                    .frame(width: 2)
                Text(text)
                    .font(.system(size: Self.bodySize))
                    .foregroundStyle(theme.mutedForeground)
                    .lineSpacing(6)
            }
        case let .code(text):
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.foreground.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous))
        case let .list(ordered, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.system(size: Self.bodySize))
                            .foregroundStyle(theme.mutedForeground)
                        Text(item)
                            .font(.system(size: Self.bodySize))
                            .lineSpacing(6)
                    }
                }
            }
        case let .image(url, alt):
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Rectangle().fill(theme.foreground.opacity(0.05)).frame(height: 120)
                }
                .clipShape(RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous))
                if let alt {
                    Text(alt)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground)
                }
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 24
        case 2: return 20
        case 3: return 18
        default: return 16
        }
    }

    private func centred(@ViewBuilder _ content: () -> some View) -> some View {
        VStack { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func load() async {
        guard let target else {
            failure = "This address carries no page to read."
            isLoading = false
            return
        }
        isLoading = true
        failure = nil
        article = nil

        switch await PageSourceLoader.markup(for: target) {
        case let .success(html):
            let extracted = await Task.detached(priority: .userInitiated) {
                ReaderExtractor.article(fromHTML: html, baseURL: target)
            }.value
            if let extracted, extracted.isReadable {
                article = extracted
            } else {
                failure = "No article found on this page."
            }
        case .failure:
            failure = "Could not read \(target.absoluteString)."
        }
        isLoading = false
    }
}
