import Foundation
@testable import Aura
import Testing

// swiftlint:disable no_print_statements
// Test output is the deliverable here: the audit prints its coverage table.

/// The default filter set is what makes Aura's native content blocker uBO-grade, so the
/// catalog and the default selection have to stay in sync.
struct AdBlockCatalogTests {
    private static let uBlockGradeIDs = [
        FilterListCatalogService.uBlockFiltersID,
        FilterListCatalogService.uBlockBadwareID,
        FilterListCatalogService.uBlockPrivacyID,
        FilterListCatalogService.uBlockQuickFixesID,
        FilterListCatalogService.uBlockUnbreakID,
        FilterListCatalogService.easyListID,
        FilterListCatalogService.easyPrivacyID,
        FilterListCatalogService.peterLoweID,
        FilterListCatalogService.adGuardBaseID
    ]

    nonisolated static var runsCoverageAudit: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["ORA_FILTER_AUDIT"] == "1" || environment["TEST_RUNNER_ORA_FILTER_AUDIT"] == "1"
    }

    @Test func catalogShipsTheUBlockOriginGradeListSet() {
        let catalog = FilterListCatalogService.shared
        let recordsByID = Dictionary(uniqueKeysWithValues: catalog.builtinRecords.map { ($0.id, $0) })

        for id in Self.uBlockGradeIDs {
            let record = recordsByID[id]
            #expect(record != nil, "missing built-in list \(id)")
            #expect(record?.sourceURL.hasPrefix("https://") == true, "\(id) must be fetched over https")
            #expect(
                FilterListCatalogService.defaultBuiltinSelectionIDs.contains(id),
                "\(id) must be on by default"
            )
        }
    }

    @Test func adBlockingAndItsDefaultListsAreOnForANewSpace() {
        let settings = SpacePrivacySettings()

        #expect(settings.adBlock.enabled)
        #expect(Set(Self.uBlockGradeIDs).isSubset(of: Set(settings.adBlock.enabledBuiltinListIDs)))
    }

    /// WebKit has no blocking webRequest, but it does have `css-display-none`, so element
    /// hiding has to survive conversion even with advanced blocking switched off.
    @Test func cosmeticFiltersSurviveConversion() throws {
        let artifacts = try ContentBlockerCompileService().compile(
            record: Self.fixtureRecord,
            rawText: """
            ||ads.example^
            example.com##.ad-banner
            """
        )

        #expect(artifacts.jsonShards.contains { $0.contains("css-display-none") })
    }

    /// Downloads every built-in list and reports how much of it WebKit can express.
    /// Opt in with `ORA_FILTER_AUDIT=1`; it fetches ~10 MB and converts for minutes.
    @Test(.enabled(if: AdBlockCatalogTests.runsCoverageAudit), .timeLimit(.minutes(60)))
    func reportsPerListCoverage() async throws {
        let compiler = ContentBlockerCompileService()

        for record in FilterListCatalogService.shared.builtinRecords {
            guard let url = URL(string: record.sourceURL) else { continue }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let rawText = String(data: data, encoding: .utf8) else { continue }

            // Lists differ in line endings, so split on every newline flavour: splitting on
            // "\n" alone turns a CR-only list into one line and the denominator collapses.
            let filterLines = rawText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("!") && !$0.hasPrefix("[") }

            let coverage = try compiler.compile(record: record, rawText: rawText).coverage
            let unsupported = max(filterLines.count - coverage.convertedRuleCount, 0)
            let percentage = filterLines.isEmpty
                ? 0
                : Double(unsupported) / Double(filterLines.count) * 100

            print(
                "FILTERCOV \(record.id) filters=\(filterLines.count) converted=\(coverage.convertedRuleCount) "
                    + "safari=\(coverage.safariRuleCount) shards=\(coverage.shardCount) "
                    + "unsupported=\(String(format: "%.1f", percentage))%"
            )
        }
    }

    private static let fixtureRecord = FilterListRecord(
        id: "catalog-test-fixture",
        name: "Catalog Fixture",
        summary: "Fixture list",
        sourceKind: .custom,
        sourceURL: "https://example.com/filter.txt",
        isRecommended: false,
        enabledByDefault: false
    )
}

// swiftlint:enable no_print_statements
