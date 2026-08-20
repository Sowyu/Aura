import Foundation

struct FilterListCatalogService {
    static let shared = FilterListCatalogService()

    static let uBlockFiltersID = "ublock-filters"
    static let uBlockBadwareID = "ublock-badware"
    static let uBlockPrivacyID = "ublock-privacy"
    static let uBlockQuickFixesID = "ublock-quick-fixes"
    static let uBlockUnbreakID = "ublock-unbreak"
    static let easyListID = "easylist"
    static let easyPrivacyID = "easyprivacy"
    static let peterLoweID = "peter-lowe"
    static let adGuardBaseID = "adguard-base"
    static let adGuardMobileAdsID = "adguard-mobile-ads"
    static let adGuardTrackingProtectionID = "adguard-tracking-protection"
    static let adGuardURLTrackingID = "adguard-url-tracking"
    static let adGuardAnnoyancesID = "adguard-annoyances"

    /// uBlock Origin's own default selection, plus the AdGuard lists Ora already shipped.
    /// WebKit cannot run uBO itself, so matching its list set is how Ora gets the same coverage.
    static let defaultBuiltinSelectionIDs = [
        uBlockFiltersID,
        uBlockBadwareID,
        uBlockPrivacyID,
        uBlockQuickFixesID,
        uBlockUnbreakID,
        easyListID,
        easyPrivacyID,
        peterLoweID,
        adGuardBaseID,
        adGuardMobileAdsID
    ]

    let builtinRecords: [FilterListRecord] = [
        FilterListRecord(
            id: FilterListCatalogService.uBlockFiltersID,
            name: "uBlock filters",
            summary: "uBlock Origin's own ad and nuisance rules.",
            sourceKind: .builtin,
            sourceURL: "https://ublockorigin.github.io/uAssets/filters/filters.txt",
            isRecommended: true,
            enabledByDefault: true,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.uBlockBadwareID,
            name: "uBlock Badware risks",
            summary: "Domains known to host malware, scams, and unwanted software.",
            sourceKind: .builtin,
            sourceURL: "https://ublockorigin.github.io/uAssets/filters/badware.txt",
            isRecommended: true,
            enabledByDefault: true,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.uBlockPrivacyID,
            name: "uBlock Privacy",
            summary: "Trackers and telemetry endpoints beyond what EasyPrivacy covers.",
            sourceKind: .builtin,
            sourceURL: "https://ublockorigin.github.io/uAssets/filters/privacy.txt",
            isRecommended: true,
            enabledByDefault: true,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.uBlockQuickFixesID,
            name: "uBlock Quick fixes",
            summary: "Fast-moving fixes uBlock Origin ships between list releases.",
            sourceKind: .builtin,
            sourceURL: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt",
            isRecommended: true,
            enabledByDefault: true,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.uBlockUnbreakID,
            name: "uBlock Unbreak",
            summary: "Exception rules that repair sites the other lists break.",
            sourceKind: .builtin,
            sourceURL: "https://ublockorigin.github.io/uAssets/filters/unbreak.txt",
            isRecommended: true,
            enabledByDefault: true,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.easyListID,
            name: "EasyList",
            summary: "The baseline ad-blocking list most blockers build on.",
            sourceKind: .builtin,
            sourceURL: "https://easylist.to/easylist/easylist.txt",
            isRecommended: true,
            enabledByDefault: true,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.easyPrivacyID,
            name: "EasyPrivacy",
            summary: "Tracking scripts, analytics beacons, and web bugs.",
            sourceKind: .builtin,
            sourceURL: "https://easylist.to/easylist/easyprivacy.txt",
            isRecommended: true,
            enabledByDefault: true,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.peterLoweID,
            name: "Peter Lowe's Ad and tracking server list",
            summary: "A hand-maintained blocklist of ad and tracking servers.",
            sourceKind: .builtin,
            sourceURL: "https://pgl.yoyo.org/adservers/serverlist.php" +
                "?hostformat=adblockplus&showintro=0&mimetype=plaintext",
            isRecommended: true,
            enabledByDefault: true,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.adGuardBaseID,
            name: "AdGuard Base",
            summary: "Core AdGuard ads list for general web ad blocking.",
            sourceKind: .builtin,
            sourceURL: "https://filters.adtidy.org/extension/chromium/filters/2.txt",
            isRecommended: true,
            enabledByDefault: true,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.adGuardMobileAdsID,
            name: "AdGuard Mobile Ads",
            summary: "Additional mobile ad-network coverage for embedded and responsive mobile ads.",
            sourceKind: .builtin,
            sourceURL: "https://filters.adtidy.org/extension/chromium/filters/11.txt",
            isRecommended: true,
            enabledByDefault: true,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.adGuardTrackingProtectionID,
            name: "AdGuard Tracking Protection",
            summary: "Broader tracker and analytics coverage from AdGuard’s privacy list.",
            sourceKind: .builtin,
            sourceURL: "https://filters.adtidy.org/extension/chromium/filters/3.txt",
            isRecommended: false,
            enabledByDefault: false,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.adGuardURLTrackingID,
            name: "AdGuard URL Tracking",
            summary: "Removes common tracking parameters from requested URLs when WebKit rules can express them.",
            sourceKind: .builtin,
            sourceURL: "https://filters.adtidy.org/windows/filters/17.txt",
            isRecommended: false,
            enabledByDefault: false,
            status: .idle
        ),
        FilterListRecord(
            id: FilterListCatalogService.adGuardAnnoyancesID,
            name: "AdGuard Annoyances",
            summary: "Targets cookie notices, popups, widgets, and other page annoyances.",
            sourceKind: .builtin,
            sourceURL: "https://filters.adtidy.org/extension/chromium/filters/14.txt",
            isRecommended: false,
            enabledByDefault: false,
            status: .idle
        )
    ]

    func normalizedRecords(from stored: [FilterListRecord]) -> [FilterListRecord] {
        let builtinByID = Dictionary(uniqueKeysWithValues: builtinRecords.map { ($0.id, $0) })
        let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })

        let mergedBuiltins = builtinRecords.map { builtin -> FilterListRecord in
            guard let storedBuiltin = storedByID[builtin.id] else { return builtin }

            var merged = builtin
            merged.status = storedBuiltin.status
            merged.lastErrorMessage = storedBuiltin.lastErrorMessage
            merged.lastFetchAt = storedBuiltin.lastFetchAt
            merged.lastSuccessfulRefreshAt = storedBuiltin.lastSuccessfulRefreshAt
            merged.etag = storedBuiltin.etag
            merged.lastModified = storedBuiltin.lastModified
            merged.activeRevision = storedBuiltin.activeRevision
            merged.coverage = storedBuiltin.coverage
            return merged
        }

        let customRecords = stored
            .filter { $0.sourceKind == .custom && builtinByID[$0.id] == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return mergedBuiltins + customRecords
    }
}
