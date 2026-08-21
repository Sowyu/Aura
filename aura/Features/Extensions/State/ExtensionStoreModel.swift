import Foundation

/// Search state behind `aura://extensions`: debounced query, filters, paging, installs.
@MainActor
@Observable
final class ExtensionStoreModel {
    private(set) var addons: [FirefoxAddon] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var message: String?
    private(set) var messageIsError = false
    private(set) var installingSlugs: Set<String> = []

    private(set) var type: FirefoxAddonType?
    private(set) var sort: FirefoxAddonSort = .users

    private var query = ""
    private var page = 1
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    // MARK: - Input

    /// Fires 250 ms after the last keystroke. Enter skips the wait through `search(_:)`.
    func scheduleSearch(_ text: String) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.search(text)
        }
    }

    func search(_ text: String) {
        debounceTask?.cancel()
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        reload()
    }

    func select(type newType: FirefoxAddonType?) {
        guard type != newType else { return }
        type = newType
        reload()
    }

    func select(sort newSort: FirefoxAddonSort) {
        guard sort != newSort else { return }
        sort = newSort
        reload()
    }

    /// The page's first load. Re-entering the tab keeps whatever was on screen.
    func loadIfNeeded() {
        guard addons.isEmpty, !isLoading else { return }
        reload()
    }

    func loadMore() {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        page += 1
        run(reset: false)
    }

    // MARK: - Install

    func install(_ addon: FirefoxAddon) {
        guard !installingSlugs.contains(addon.slug) else { return }
        installingSlugs.insert(addon.slug)
        message = nil
        Task { [weak self] in
            do {
                try await ExtensionManager.shared.installFirefoxAddon(addon)
                self?.report("Installed \(addon.name).", isError: false)
            } catch {
                self?.report(error.localizedDescription, isError: true)
            }
            self?.installingSlugs.remove(addon.slug)
        }
    }

    // MARK: - Fetching

    private func reload() {
        page = 1
        run(reset: true)
    }

    private func run(reset: Bool) {
        loadTask?.cancel()
        message = nil
        if reset { isLoading = true } else { isLoadingMore = true }

        let (text, kind, order, index) = (query, type, sort, page)
        loadTask = Task { [weak self] in
            do {
                let result: FirefoxAddonPage
                // An AMO listing URL pasted into the field resolves to that one add-on.
                if let slug = FirefoxAddonStore.slug(fromPageURL: text) {
                    result = FirefoxAddonPage(addons: [try await FirefoxAddonStore.shared.addon(slug: slug)])
                } else {
                    result = try await FirefoxAddonStore.shared.search(
                        text, type: kind, sort: order, page: index
                    )
                }
                guard !Task.isCancelled else { return }
                self?.apply(result, reset: reset)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error, reset: reset)
            }
        }
    }

    private func apply(_ result: FirefoxAddonPage, reset: Bool) {
        isLoading = false
        isLoadingMore = false
        hasMore = result.hasMore
        if reset {
            addons = result.addons
        } else {
            let known = Set(addons.map(\.id))
            addons += result.addons.filter { !known.contains($0.id) }
        }
        guard addons.isEmpty else { return }
        report(query.isEmpty ? "Nothing to show." : "No add-ons found for \"\(query)\".", isError: false)
    }

    private func fail(_ error: Error, reset: Bool) {
        isLoading = false
        isLoadingMore = false
        // A failed "load more" would otherwise skip a page on the next attempt.
        if !reset { page = max(page - 1, 1) }
        report(error.localizedDescription, isError: true)
    }

    private func report(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}
