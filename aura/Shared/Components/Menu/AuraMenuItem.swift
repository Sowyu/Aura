import SwiftUI

/// One row of an Aura menu.
///
/// Menus are arrays of these rather than view builders, so a single definition drives
/// rendering, hit testing and the keyboard walker instead of three separate ones.
struct AuraMenuItem: Identifiable {
    enum Kind {
        case item
        case separator
        case submenu
        case header
    }

    /// Leading marker drawn in the icon slot when the row represents a setting.
    enum SelectionState {
        case none
        case checked
        case radioOn
    }

    let id = UUID()
    var kind: Kind = .item
    var title = ""
    /// SF Symbol name.
    var icon: String?
    /// Right-aligned hint such as "⌘T". Purely cosmetic: the menu never handles it.
    var shortcut: String?
    var state: SelectionState = .none
    var isDestructive = false
    var isDisabled = false
    var action: (() -> Void)?
    var items: [AuraMenuItem] = []

    /// True for rows the pointer and the arrow keys may land on.
    var isSelectable: Bool {
        guard !isDisabled else { return false }
        return kind == .item || kind == .submenu
    }
}

// MARK: - Builders

extension AuraMenuItem {
    static func item(
        _ title: String,
        icon: String? = nil,
        shortcut: String? = nil,
        state: SelectionState = .none,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> AuraMenuItem {
        AuraMenuItem(
            kind: .item,
            title: title,
            icon: icon,
            shortcut: shortcut,
            state: state,
            isDestructive: isDestructive,
            isDisabled: isDisabled,
            action: action
        )
    }

    /// Same, with the hint taken from a shortcut definition so a rebind shows up here too.
    static func item(
        _ title: String,
        icon: String? = nil,
        shortcut: KeyboardShortcutDefinition,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> AuraMenuItem {
        item(
            title,
            icon: icon,
            shortcut: shortcut.currentChord.display,
            isDestructive: isDestructive,
            isDisabled: isDisabled,
            action: action
        )
    }

    /// A row that only reads back state, used for "No recent history" style placeholders.
    static func disabled(_ title: String, icon: String? = nil) -> AuraMenuItem {
        AuraMenuItem(kind: .item, title: title, icon: icon, isDisabled: true)
    }

    /// Computed, not a stored constant: every separator needs its own identity for `ForEach`.
    static var separator: AuraMenuItem {
        AuraMenuItem(kind: .separator)
    }

    static func submenu(_ title: String, icon: String? = nil, items: [AuraMenuItem]) -> AuraMenuItem {
        AuraMenuItem(kind: .submenu, title: title, icon: icon, isDisabled: items.isEmpty, items: items)
    }

    static func header(_ text: String) -> AuraMenuItem {
        AuraMenuItem(kind: .header, title: text)
    }
}

// MARK: - Array building

/// Lets a menu be written with `if` and `for` while still producing a plain array.
@resultBuilder
enum AuraMenuBuilder {
    static func buildBlock(_ parts: [AuraMenuItem]...) -> [AuraMenuItem] {
        parts.flatMap { $0 }
    }

    static func buildExpression(_ expression: AuraMenuItem) -> [AuraMenuItem] {
        [expression]
    }

    static func buildExpression(_ expression: [AuraMenuItem]) -> [AuraMenuItem] {
        expression
    }

    static func buildOptional(_ component: [AuraMenuItem]?) -> [AuraMenuItem] {
        component ?? []
    }

    static func buildEither(first component: [AuraMenuItem]) -> [AuraMenuItem] {
        component
    }

    static func buildEither(second component: [AuraMenuItem]) -> [AuraMenuItem] {
        component
    }

    static func buildArray(_ components: [[AuraMenuItem]]) -> [AuraMenuItem] {
        components.flatMap { $0 }
    }
}

extension Array where Element == AuraMenuItem {
    init(@AuraMenuBuilder _ build: () -> [AuraMenuItem]) {
        self = build()
    }

    /// Drops separators that ended up leading, trailing or doubled once optional
    /// sections were compiled out, so callers never have to guard each one.
    func tidied() -> [AuraMenuItem] {
        var result: [AuraMenuItem] = []
        for item in self {
            if item.kind == .separator, result.last?.kind != .item, result.last?.kind != .submenu {
                continue
            }
            result.append(item)
        }
        while result.last?.kind == .separator {
            result.removeLast()
        }
        return result
    }
}
