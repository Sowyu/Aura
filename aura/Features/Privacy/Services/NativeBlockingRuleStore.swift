import CryptoKit
import Foundation
import os.log

/// Keeps the injected bundle's rule file in step with the enabled filter lists.
///
/// The bundle lives in the WebContent process and cannot read the app's state, so
/// everything it needs (rules plus the per-site kill switch) is serialised into
/// one file inside the injected bundle's own directory. That directory is the only
/// path WebKit hands the web process a sandbox extension for.
///
/// ponytail: one rule file for the whole app. The injected bundle is process-wide,
/// so per-space rule sets would need one process pool per space. Revisit if spaces
/// start needing genuinely different blocking.
final class NativeBlockingRuleStore: @unchecked Sendable {
    static let shared = NativeBlockingRuleStore()

    private let artifactStore: ContentBlockerArtifactStore
    private let queue = DispatchQueue(label: "com.aurabrowser.nativeBlocking.build", qos: .utility)
    private let lock = NSLock()
    private var lastSignature: String?
    private var knownContainerIDs: [UUID] = []
    private var observer: NSObjectProtocol?

    private(set) var lastStats: NativeBlockingRuleSet.Stats?

    init(artifactStore: ContentBlockerArtifactStore = .shared) {
        self.artifactStore = artifactStore
        observer = NotificationCenter.default.addObserver(
            forName: AdvancedBlockingService.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let containerIDs = self.knownContainerIDs
            self.lock.unlock()
            MainActor.assumeIsolated { self.scheduleRebuild(containerIDs: containerIDs) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Reads the enabled lists on the main actor, then compiles off it.
    @MainActor
    func scheduleRebuild(containerIDs: [UUID]) {
        lock.lock()
        knownContainerIDs = Array(Set(knownContainerIDs).union(containerIDs)).sorted { $0.uuidString < $1.uuidString }
        let allContainerIDs = knownContainerIDs
        lock.unlock()

        guard SettingsStore.shared.nativeRequestBlockingEnabled else {
            queue.async { [weak self] in self?.removeRuleFile() }
            return
        }

        let sources = enabledSources(containerIDs: allContainerIDs)
        let allowlist = AdvancedBlockingService.shared.disabledHostList
        let signature = Self.signature(sources: sources, allowlist: allowlist)

        lock.lock()
        let unchanged = lastSignature == signature
        lock.unlock()
        guard !unchanged else { return }

        queue.async { [weak self] in
            self?.rebuild(sources: sources, allowlist: allowlist, signature: signature)
        }
    }

    @MainActor
    private func enabledSources(containerIDs: [UUID]) -> [(id: String, revision: String)] {
        let store = SettingsStore.shared
        var enabledIDs: Set<String> = []
        for containerID in containerIDs {
            let settings = store.privacySettings(for: containerID)
            guard settings.adBlock.enabled else { continue }
            enabledIDs.formUnion(settings.adBlock.enabledListIDs)
        }

        return store.adBlockFilterLists
            .filter { enabledIDs.contains($0.id) }
            .compactMap { record in
                guard let revision = record.activeRevision else { return nil }
                return (record.id, revision)
            }
            .sorted { $0.id < $1.id }
    }

    /// Compiles and writes the file. Synchronous; `scheduleRebuild` keeps it off
    /// the main thread. Exposed for tests.
    @discardableResult
    func rebuild(
        sources: [(id: String, revision: String)],
        allowlist: [String],
        signature: String = UUID().uuidString
    ) -> NativeBlockingRuleSet.Stats? {
        let lines = sources
            .compactMap { artifactStore.rawListText(for: $0.id) }
            .flatMap { $0.components(separatedBy: .newlines) }

        let ruleSet = NativeBlockingRuleSet.make(fromFilterLines: lines, allowlist: allowlist)
        guard write(ruleSet: ruleSet, revision: signature) else { return nil }

        lock.lock()
        lastSignature = signature
        lastStats = ruleSet.stats
        lock.unlock()

        os_log(
            "native blocking: %d block, %d allow, %d removeparam, %d redirect, %d dropped",
            ruleSet.stats.block, ruleSet.stats.allow, ruleSet.stats.removeParam,
            ruleSet.stats.redirect, ruleSet.stats.skipped
        )
        return ruleSet.stats
    }

    private func write(ruleSet: NativeBlockingRuleSet, revision: String) -> Bool {
        guard AuraWebBundle.install() != nil, let url = AuraWebBundle.rulesFileURL else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try ruleSet.jsonData(revision: revision).write(to: url, options: .atomic)
            return true
        } catch {
            os_log(.error, "native blocking rule write failed: %@", error.localizedDescription)
            return false
        }
    }

    private func removeRuleFile() {
        guard let url = AuraWebBundle.rulesFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        lock.lock()
        lastSignature = nil
        lastStats = nil
        lock.unlock()
    }

    private static func signature(sources: [(id: String, revision: String)], allowlist: [String]) -> String {
        let joined = sources.map { "\($0.id):\($0.revision)" }.joined(separator: "|")
            + "#" + allowlist.sorted().joined(separator: ",")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
