import Foundation
import JavaScriptCore
@testable import Aura
import Testing

// swiftlint:disable no_print_statements
// The coverage audit prints its table; that output is the deliverable.

/// Everything WebKit's content blocking format throws away (scriptlets, procedural
/// selectors, CSS injection, `$removeparam`) is meant to survive in the advanced layer.
struct AdvancedBlockingTests {
    private static let fixtureRules = """
    ||ads.example^
    example.com##.plain-banner
    example.com##+js(set-constant, foo, bar)
    example.com#?#div:has(> .ad)
    """

    private static let fixtureRecord = FilterListRecord(
        id: "advanced-test-fixture",
        name: "Advanced Fixture",
        summary: "Fixture list",
        sourceKind: .custom,
        sourceURL: "https://example.com/filter.txt",
        isRecommended: false,
        enabledByDefault: false
    )

    nonisolated static var runsCoverageAudit: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["ORA_FILTER_AUDIT"] == "1" || environment["TEST_RUNNER_ORA_FILTER_AUDIT"] == "1"
    }

    private static func makeService() throws -> AdvancedBlockingService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-advanced-\(UUID().uuidString)", isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: "aura.tests.\(UUID().uuidString)"))
        return AdvancedBlockingService(defaults: defaults, baseURL: directory)
    }

    @Test func conversionKeepsTheRulesSafariCannotExpress() throws {
        let artifacts = try ContentBlockerCompileService().compile(
            record: Self.fixtureRecord,
            rawText: Self.fixtureRules
        )

        #expect(!artifacts.advancedRulesText.isEmpty)
        #expect(artifacts.advancedRulesText.contains("set-constant"))
        #expect(artifacts.advancedRulesText.contains("div:has(> .ad)"))
        #expect((artifacts.coverage.advancedRuleCount ?? 0) >= 2)
        // The plain selector still belongs to WebKit; only the rest moves to the JS layer.
        #expect(artifacts.jsonShards.contains { $0.contains("css-display-none") })
    }

    @Test func lookupSelectsRulesByDomain() throws {
        let artifacts = try ContentBlockerCompileService().compile(
            record: Self.fixtureRecord,
            rawText: Self.fixtureRules
        )
        let service = try Self.makeService()
        let spaceID = UUID()
        try service.installEngine(
            spaceID: spaceID,
            advancedRulesText: artifacts.advancedRulesText,
            removeParamRules: []
        )

        let payload = try #require(service.payload(for: URL(string: "https://example.com/page")!, spaceID: spaceID))
        #expect(payload.scriptletCount == 1)
        #expect(payload.extendedCssRuleCount == 1)
        #expect(payload.needsExtendedCss)

        #expect(service.payload(for: URL(string: "https://other.com/page")!, spaceID: spaceID) == nil)
    }

    @Test func injectedScriptCarriesTheScriptletAndTheExtendedSelector() throws {
        let artifacts = try ContentBlockerCompileService().compile(
            record: Self.fixtureRecord,
            rawText: Self.fixtureRules
        )
        let service = try Self.makeService()
        let spaceID = UUID()
        try service.installEngine(
            spaceID: spaceID,
            advancedRulesText: artifacts.advancedRulesText,
            removeParamRules: []
        )

        let payload = try #require(service.payload(for: URL(string: "https://example.com/page")!, spaceID: spaceID))
        #expect(payload.source.contains("set-constant"))
        #expect(payload.source.contains("div:has(> .ad)"))
        // JSONSerialization escapes the slashes, so match the host rather than the origin.
        #expect(payload.source.contains("example.com"))

        let scripts = service.userScripts(for: payload)
        #expect(scripts.count == 3)
        #expect(scripts.contains { $0.name == "aura-extended-css" })
        #expect(scripts.allSatisfy { script in
            guard case .atDocumentStart = script.injectionTime else { return false }
            return !script.forMainFrameOnly
        })

        let libraryBytes = AdvancedBlockingService.extendedCssLibrarySource.utf8.count
        let applierBytes = AdvancedBlockingService.applierSource.utf8.count
        print("ADVCOST payload=\(payload.byteCount)B extendedCss=\(libraryBytes)B applier=\(applierBytes)B")
    }

    /// The scriptlets library runs in JavaScriptCore inside the app, so pages only ever
    /// get the code for the scriptlets that matched them.
    @Test func scriptletCompilerGeneratesCode() {
        let code = ScriptletCompiler.shared.functionSource(named: "set-constant")
        #expect(code?.hasPrefix("function setConstant") == true)
        #expect(ScriptletCompiler.shared.functionSource(named: "definitely-not-a-scriptlet") == nil)
    }

    /// The applier decides what a frame gets. Run it against a stub DOM in JavaScriptCore
    /// so the frame gating is covered without standing up a web view.
    @Test func applierAppliesRulesOnlyToMatchingFrames() throws {
        let sameOrigin = try Self.runApplier(frameOrigin: "https://example.com", isTopFrame: false)
        #expect(sameOrigin.cssRules == ["#ad {display:none!important;}"])
        #expect(sameOrigin.ranScripts)
        #expect(sameOrigin.postedURLs.isEmpty)

        // A cross-origin subframe was handed the top document's rules, so it must ask for
        // its own instead of hiding elements with selectors meant for another site.
        let crossOrigin = try Self.runApplier(frameOrigin: "https://ads.other.com", isTopFrame: false)
        #expect(crossOrigin.cssRules.isEmpty)
        #expect(!crossOrigin.ranScripts)
        #expect(crossOrigin.postedURLs == ["https://ads.other.com/frame"])

        // A frame with no origin of its own (about:blank, srcdoc) inherits the parent's.
        let blankFrame = try Self.runApplier(frameOrigin: "null", isTopFrame: false)
        #expect(blankFrame.ranScripts)
    }

    private struct ApplierRun {
        let cssRules: [String]
        let ranScripts: Bool
        let postedURLs: [String]
    }

    private static func runApplier(frameOrigin: String, isTopFrame: Bool) throws -> ApplierRun {
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }

        context.evaluateScript("""
        var window = this;
        window.top = \(isTopFrame ? "window" : "{}");
        var insertedRules = [];
        var postedURLs = [];
        var ranScripts = false;
        var styleElement = {
            setAttribute: function () {},
            sheet: {
                cssRules: [],
                insertRule: function (rule) { insertedRules.push(rule); this.cssRules.push(rule); }
            }
        };
        var document = {
            createElement: function () { return styleElement; },
            documentElement: { appendChild: function () {} },
            head: null
        };
        var location = { origin: "\(frameOrigin)", href: "\(frameOrigin)/frame" };
        window.webkit = {
            messageHandlers: {
                advancedBlocking: { postMessage: function (message) { postedURLs.push(message.url); } }
            }
        };
        """)

        context.evaluateScript(AdvancedBlockingService.applierSource)
        context.evaluateScript("""
        window.__auraAB.apply(
            { origin: "https://example.com", css: ["#ad"], extendedCss: [] },
            function () { ranScripts = true; }
        );
        """)

        #expect(failure == nil)
        return ApplierRun(
            cssRules: context.objectForKeyedSubscript("insertedRules")?.toArray() as? [String] ?? [],
            ranScripts: context.objectForKeyedSubscript("ranScripts")?.toBool() ?? false,
            postedURLs: context.objectForKeyedSubscript("postedURLs")?.toArray() as? [String] ?? []
        )
    }

    @Test func removeParamStripsTrackingParametersOnly() {
        let rules = RemoveParamRuleSet(lines: [
            "$removeparam=utm_source",
            "$removeparam=/^pk_/",
            "||example.com^$removeparam=sessionid",
            "@@||keepme.example^$removeparam=utm_source"
        ])

        let stripped = rules.strippedURL(for: URL(string: "https://news.test/a?utm_source=x&id=7&pk_camp=1")!)
        #expect(stripped?.absoluteString == "https://news.test/a?id=7")

        // Host-scoped rules must not reach other hosts.
        #expect(rules.strippedURL(for: URL(string: "https://other.test/a?sessionid=1")!) == nil)
        #expect(
            rules.strippedURL(for: URL(string: "https://www.example.com/a?sessionid=1")!)?.absoluteString
                == "https://www.example.com/a"
        )
        // An exception rule keeps the parameter.
        #expect(rules.strippedURL(for: URL(string: "https://keepme.example/a?utm_source=x")!) == nil)
        // A URL with nothing to strip is left alone, so no navigation is re-issued.
        #expect(rules.strippedURL(for: URL(string: "https://news.test/a?id=7")!) == nil)
    }

    @Test func removeParamIgnoresRulesItCannotApplyFaithfully() {
        let rules = RemoveParamRuleSet(lines: [
            // Inverted: "keep only this one" needs whole-query rewriting.
            "$removeparam=~keep",
            // Path-scoped rules target subresources, which decidePolicyFor cannot rewrite.
            "||googletagmanager.com/gtag/js?id=$removeparam=gtm",
            "! $removeparam=commented-out"
        ])

        #expect(rules.isEmpty)
    }

    /// Re-runs the filter audit with the advanced layer counted in.
    /// Opt in with `ORA_FILTER_AUDIT=1`; it fetches ~10 MB and converts for minutes.
    @Test(.enabled(if: AdvancedBlockingTests.runsCoverageAudit), .timeLimit(.minutes(60)))
    func reportsAdvancedCoverage() async throws {
        let compiler = ContentBlockerCompileService()
        var advancedRules: [String] = []
        var removeParamRules: [String] = []

        for record in FilterListCatalogService.shared.builtinRecords {
            guard let url = URL(string: record.sourceURL) else { continue }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let rawText = String(data: data, encoding: .utf8) else { continue }

            let filterLines = rawText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("!") && !$0.hasPrefix("[") }

            let artifacts = try compiler.compile(record: record, rawText: rawText)
            advancedRules.append(artifacts.advancedRulesText)
            removeParamRules.append(contentsOf: artifacts.removeParamRules)
            let coverage = artifacts.coverage
            let advanced = coverage.advancedRuleCount ?? 0
            let removeParam = coverage.removeParamRuleCount ?? 0
            let denominator = Double(max(filterLines.count, 1))
            let wasUnsupported = max(filterLines.count - coverage.convertedRuleCount, 0)
            let stillUnsupported = max(wasUnsupported - advanced - removeParam, 0)

            print(
                "ADVCOV \(record.id) filters=\(filterLines.count) safariRules=\(coverage.convertedRuleCount) "
                    + "advanced=\(advanced) removeparam=\(removeParam) "
                    + "wasUnsupported=\(String(format: "%.1f", Double(wasUnsupported) / denominator * 100))% "
                    + "nowUnsupported=\(String(format: "%.1f", Double(stillUnsupported) / denominator * 100))%"
            )
        }

        try Self.reportPerPageCost(
            advancedRulesText: advancedRules.joined(separator: "\n"),
            removeParamRules: removeParamRules
        )
    }

    /// What one navigation actually costs once every built-in list is in the engine.
    private static func reportPerPageCost(advancedRulesText: String, removeParamRules: [String]) throws {
        let service = try makeService()
        let spaceID = UUID()
        let buildStart = Date()
        try service.installEngine(
            spaceID: spaceID,
            advancedRulesText: advancedRulesText,
            removeParamRules: removeParamRules
        )
        let buildSeconds = String(format: "%.2f", -buildStart.timeIntervalSinceNow)
        print("ADVBUILD rules=\(advancedRulesText.count)B seconds=\(buildSeconds)")

        let sites = [
            "https://www.youtube.com/watch?v=1",
            "https://www.reddit.com/r/all",
            "https://edition.cnn.com/",
            "https://www.amazon.com/dp/B0",
            "https://www.nytimes.com/"
        ]

        for site in sites {
            guard let url = URL(string: site) else { continue }
            let start = Date()
            var payload: AdvancedBlockingPayload?
            for _ in 0..<20 {
                payload = service.payload(for: url, spaceID: spaceID)
            }
            let millis = -start.timeIntervalSinceNow / 20 * 1000

            print(
                "ADVPAGE \(url.host ?? site) payload=\(payload?.byteCount ?? 0)B "
                    + "css=\(payload?.cssRuleCount ?? 0) extCss=\(payload?.extendedCssRuleCount ?? 0) "
                    + "scriptlets=\(payload?.scriptletCount ?? 0) "
                    + "lookupMs=\(String(format: "%.2f", millis))"
            )
        }
    }
}

// swiftlint:enable no_print_statements
