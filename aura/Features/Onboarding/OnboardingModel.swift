import Foundation
import SwiftUI

/// The screens of the welcome flow, in order. There is no progress counter on screen:
/// Arc shipped one and removed it, Zen shipped one and removed it, and at six screens
/// the button labels carry the position on their own.
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case bring
    case style
    case space
    case favorites
    case blocking
    case finish

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// A site offered on the favourites screen. A symbol stands in for the favicon on
/// purpose: nothing is fetched for a site until the user opens its tab.
struct OnboardingSite: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let symbol: String
}

enum OnboardingSites {
    /// None pre-selected. A pre-ticked favourite is a tab the user never asked for.
    static let suggestions: [OnboardingSite] = [
        site("gmail", "Gmail", "https://mail.google.com", "envelope"),
        site("calendar", "Google Calendar", "https://calendar.google.com", "calendar"),
        site("github", "GitHub", "https://github.com", "chevron.left.forwardslash.chevron.right"),
        site("notion", "Notion", "https://www.notion.so", "doc.text"),
        site("figma", "Figma", "https://www.figma.com", "paintbrush.pointed"),
        site("slack", "Slack", "https://app.slack.com", "number"),
        site("youtube", "YouTube", "https://www.youtube.com", "play.rectangle"),
        site("reddit", "Reddit", "https://www.reddit.com", "bubble.left.and.bubble.right"),
        site("wikipedia", "Wikipedia", "https://www.wikipedia.org", "book")
    ]

    private static func site(_ id: String, _ name: String, _ url: String, _ symbol: String) -> OnboardingSite {
        // swiftlint:disable:next force_unwrapping
        OnboardingSite(id: id, name: name, url: URL(string: url)!, symbol: symbol)
    }
}

/// Everything the flow collects. Nothing is applied until the last screen, so quitting
/// halfway leaves the browser exactly as it was — except the accent and appearance,
/// which write straight through so the room recolours as you pick.
@Observable
@MainActor
final class OnboardingDraft {
    var step: OnboardingStep = .welcome
    var makeDefaultBrowser = true
    var didImportBookmarks = false
    var spaceName = ""
    var spaceEmoji = ""
    var spaceIconSymbol: String? = ContainerConstants.defaultIconSymbol
    var spaceIconColorHex: String?
    var selectedSiteIDs: Set<String> = []
    var blockAds = true

    var isFirst: Bool { step == .welcome }

    func advance() {
        if let next = step.next { step = next }
    }

    func goBack() {
        if let previous = step.previous { step = previous }
    }

    func toggle(_ site: OnboardingSite) {
        if selectedSiteIDs.contains(site.id) {
            selectedSiteIDs.remove(site.id)
        } else {
            selectedSiteIDs.insert(site.id)
        }
    }

    var selectedSites: [OnboardingSite] {
        OnboardingSites.suggestions.filter { selectedSiteIDs.contains($0.id) }
    }

    /// The space screen was touched: a name, or an icon other than the stock heart.
    var customisesSpace: Bool {
        !spaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !spaceEmoji.isEmpty
            || spaceIconSymbol != ContainerConstants.defaultIconSymbol
            || spaceIconColorHex != nil
    }
}

/// Whether the welcome flow belongs on screen.
enum OnboardingPolicy {
    /// Never in a private window and never once finished. The "finished" flag is also
    /// what a replay clears, so this is the whole rule for a window that is open.
    static func shouldShow(completed: Bool, isPrivate: Bool) -> Bool {
        !completed && !isPrivate
    }

    /// A profile that predates the flow is not a first run: an upgrade lands with spaces
    /// and tabs already in it. A fresh profile has one space holding at most the home
    /// page.
    static func isExistingProfile(spaceCount: Int, tabsBeyondHome: Int) -> Bool {
        spaceCount > 1 || tabsBeyondHome > 0
    }
}

/// Turns the draft into browser state, once, when the last screen is dismissed.
@MainActor
enum OnboardingCommit {
    static func apply(_ draft: OnboardingDraft, tabManager: TabManager) {
        let settings = SettingsStore.shared

        if draft.makeDefaultBrowser {
            DefaultBrowserManager.requestSetAsDefault()
            DefaultBrowserManager.shared.updateIsDefault()
        }

        if let space = tabManager.activeContainer {
            if draft.customisesSpace {
                let name = draft.spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                tabManager.renameContainer(
                    space,
                    name: name.isEmpty ? space.name : name,
                    emoji: draft.spaceEmoji.isEmpty ? ContainerConstants.defaultEmoji : draft.spaceEmoji,
                    iconSymbol: draft.spaceIconSymbol,
                    iconColorHex: draft.spaceIconColorHex
                )
            }
            addFavorites(draft.selectedSites, to: space, tabManager: tabManager)
        }

        // Full blocking is the default, so this only ever turns it off; the plan runs
        // and may queue a relaunch, which the Privacy pane reports.
        if settings.extensionFullAdBlocking != draft.blockAds {
            BundledExtensions.setFullBlocking(draft.blockAds)
        }

        // The home page's own first-run card asks the same default-browser question;
        // it has been answered here.
        settings.firstRunCardDismissed = true
        settings.onboardingCompleted = true
    }

    /// The chosen sites become favourite tabs of the space, unloaded: the row is there
    /// and the page loads on the first click, so picking nine sites costs no requests.
    static func addFavorites(_ sites: [OnboardingSite], to space: TabContainer, tabManager: TabManager) {
        guard !sites.isEmpty else { return }
        for site in sites {
            let tab = tabManager.addTab(
                title: site.name,
                url: site.url,
                container: space,
                isPrivate: false,
                activateAfterAdding: false
            )
            tab.type = .fav
            tab.savedURL = site.url
        }
        saveOrLog(tabManager.modelContext)
    }
}
