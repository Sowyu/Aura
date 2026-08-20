import Foundation
@preconcurrency import WebKit

final class BrowserEngineProfile {
    let identifier: UUID
    let isPrivate: Bool
    let dataStore: WKWebsiteDataStore

    init(identifier: UUID, isPrivate: Bool) {
        self.identifier = identifier
        self.isPrivate = isPrivate
        if isPrivate {
            dataStore = WKWebsiteDataStore.nonPersistent()
        } else {
            dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        }
    }

    func clearData(
        ofTypes types: Set<BrowserWebsiteDataType>,
        forHost host: String? = nil,
        completion: (() -> Void)? = nil
    ) {
        let mappedTypes = mapWebsiteDataTypes(types)
        guard let host, !host.isEmpty else {
            dataStore.removeData(ofTypes: mappedTypes, modifiedSince: .distantPast) {
                completion?()
            }
            return
        }

        dataStore.fetchDataRecords(ofTypes: mappedTypes) { records in
            // Match the exact registrable domain or its subdomains, never arbitrary substrings.
            let targetHost = host.lowercased()
            let targetRecords = records.filter { record in
                let recordDomain = record.displayName.lowercased()
                return recordDomain == targetHost
                    || recordDomain.hasSuffix("." + targetHost)
                    || targetHost.hasSuffix("." + recordDomain)
            }
            guard !targetRecords.isEmpty else {
                completion?()
                return
            }

            self.dataStore.removeData(ofTypes: mappedTypes, for: targetRecords) {
                completion?()
            }
        }
    }

    private func mapWebsiteDataTypes(_ types: Set<BrowserWebsiteDataType>) -> Set<String> {
        if types.contains(.all) {
            return WKWebsiteDataStore.allWebsiteDataTypes()
        }

        var mapped: Set<String> = []
        if types.contains(.cookies) {
            mapped.insert(WKWebsiteDataTypeCookies)
        }
        if types.contains(.cache) {
            mapped.formUnion([
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeFetchCache
            ])
        }
        return mapped
    }
}
