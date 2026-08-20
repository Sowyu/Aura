import AppKit
import SwiftUI

/// Keeps a SwiftUI `ScrollView` from rubber-banding vertically when everything already
/// fits, and stops it claiming horizontal scroll at all.
///
/// The tab list lives inside `NSPageView`, which pages between spaces on a horizontal
/// swipe. AppKit's `.automatic` elasticity bounces a short list up and down, and a
/// two-finger swipe that is even slightly off-axis gets eaten by that bounce instead of
/// reaching the page controller. `.none` on a list that fits hands those events straight
/// up the responder chain; a list long enough to scroll gets `.allowed` back.
struct ScrollElasticityAdjuster: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ElasticityProbe()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ElasticityProbe)?.sync()
    }
}

extension View {
    /// Apply to the content of a vertical `ScrollView`.
    func adaptiveScrollElasticity() -> some View {
        background(ScrollElasticityAdjuster().frame(width: 0, height: 0))
    }
}

private final class ElasticityProbe: NSView {
    private weak var attached: NSScrollView?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    override func layout() {
        super.layout()
        attach()
        sync()
    }

    private func attach() {
        guard let scrollView = enclosingScrollView, scrollView !== attached else { return }
        releaseObservers()
        attached = scrollView

        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView?.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        observe(NSView.frameDidChangeNotification, on: scrollView.documentView)
        observe(NSView.boundsDidChangeNotification, on: scrollView.contentView)
        sync()
    }

    private func observe(_ name: Notification.Name, on object: NSView?) {
        guard let object else { return }
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: object,
            queue: .main
        ) { [weak self] _ in
            self?.sync()
        }
        observers.append(token)
    }

    private func releaseObservers() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
    }

    func sync() {
        guard let scrollView = attached, let document = scrollView.documentView else { return }
        let overflow = document.frame.height - scrollView.contentView.bounds.height
        scrollView.verticalScrollElasticity = overflow > 0.5 ? .allowed : .none
    }

    deinit {
        releaseObservers()
    }
}
