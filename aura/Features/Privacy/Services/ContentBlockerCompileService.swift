import ContentBlockerConverter
import Foundation

struct CompiledFilterArtifacts {
    let revision: String
    let coverage: FilterListCoverage
    let jsonShards: [String]
    /// Rules the Safari content blocking format cannot express, in AdGuard syntax.
    /// `AdvancedBlockingService` feeds these to `FilterEngine` and applies them per page.
    let advancedRulesText: String
    /// `$removeparam` rules, which the converter drops before we ever see them.
    let removeParamRules: [String]
}

final class ContentBlockerCompileService {
    private struct ShardOutput {
        var results: [ConversionResult] = []
        var advancedTexts: [String] = []
        var advancedCount = 0

        static func + (lhs: ShardOutput, rhs: ShardOutput) -> ShardOutput {
            ShardOutput(
                results: lhs.results + rhs.results,
                advancedTexts: lhs.advancedTexts + rhs.advancedTexts,
                advancedCount: lhs.advancedCount + rhs.advancedCount
            )
        }
    }

    private let artifactStore: ContentBlockerArtifactStore

    init(artifactStore: ContentBlockerArtifactStore = .shared) {
        self.artifactStore = artifactStore
    }

    func compile(record: FilterListRecord, rawText: String) throws -> CompiledFilterArtifacts {
        var contiguousRawText = rawText
        contiguousRawText.makeContiguousUTF8()
        let rules = contiguousRawText.components(separatedBy: .newlines)

        guard rules.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw AdBlockServiceError.emptyFilterList(record.name)
        }

        let revision = artifactStore.revisionHash(for: contiguousRawText)
        let output = compileShards(from: rules)
        let shardResults = output.results
        let jsonShards = shardResults
            .map(\.safariRulesJSON)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let advancedRulesText = output.advancedTexts.joined(separator: "\n")
        let advancedRuleCount = output.advancedCount
        let removeParamRules = rules.filter { $0.contains("removeparam") && !$0.hasPrefix("!") }

        let totalRuleCount = shardResults.reduce(0) { $0 + $1.sourceRulesCount }
        let convertedRuleCount = max(
            shardResults.reduce(0) { $0 + max($1.sourceSafariCompatibleRulesCount - $1.errorsCount, 0) },
            0
        )
        let skippedRuleCount = max(totalRuleCount - convertedRuleCount, 0)
        let safariRuleCount = shardResults.reduce(0) { $0 + $1.safariRulesCount }
        let coverage = FilterListCoverage(
            totalRuleCount: totalRuleCount,
            convertedRuleCount: convertedRuleCount,
            skippedRuleCount: skippedRuleCount,
            safariRuleCount: safariRuleCount,
            shardCount: jsonShards.count,
            advancedRuleCount: advancedRuleCount,
            removeParamRuleCount: RemoveParamRuleSet(lines: removeParamRules).ruleCount
        )

        guard coverage.shardCount > 0, coverage.safariRuleCount > 0 else {
            throw AdBlockServiceError.emptyFilterList(record.name)
        }

        return CompiledFilterArtifacts(
            revision: revision,
            coverage: coverage,
            jsonShards: jsonShards,
            advancedRulesText: advancedRulesText,
            removeParamRules: removeParamRules
        )
    }

    /// Converts a slice of rules, halving it whenever Safari's per-list limits force
    /// rules to be discarded. Advanced rules are collected from every accepted slice,
    /// including slices whose Safari JSON turned out empty.
    private func compileShards(from rules: [String]) -> ShardOutput {
        guard !rules.isEmpty else { return ShardOutput() }

        let result = ContentBlockerConverter().convertArray(
            rules: rules,
            safariVersion: .autodetect(),
            advancedBlocking: true
        )

        if result.discardedSafariRules > 0, rules.count > 1 {
            let midpoint = rules.count / 2
            return compileShards(from: Array(rules[..<midpoint]))
                + compileShards(from: Array(rules[midpoint...]))
        }

        var output = ShardOutput()
        if result.safariRulesCount > 0 {
            output.results.append(result)
        }
        if let advancedRulesText = result.advancedRulesText, !advancedRulesText.isEmpty {
            output.advancedTexts.append(advancedRulesText)
            output.advancedCount += result.advancedRulesCount
        }
        return output
    }
}
