import Foundation
@preconcurrency import WebKit

/// Track 2 experiment (see UBLOCK-ORIGIN.md): keep pages on the injected-bundle
/// pool painting.
///
/// The Development WebContent service loses its RunningBoard foreground assertion
/// and its layer backing stores are purged about a second after first paint. The
/// same measurement that proved the purge also proved the process still renders on
/// demand: `takeSnapshot` came back correct while the screen was blank. So a page
/// that keeps asking for frames may never present a purged tree at all. This
/// injects a `requestAnimationFrame` loop that nudges a one-pixel composited layer
/// every frame, which forces a rendering update and a fresh layer commit each time.
///
/// Costs a trivial style write per frame on pages that are already opted into the
/// fragile stack. `AURA_PAINT_KEEPALIVE=0` switches it off for a session, so the
/// macOS side can A/B it against the purge directly. Remove together with the
/// injected bundle once blocking no longer needs one.
enum AuraPaintKeepAlive {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["AURA_PAINT_KEEPALIVE"] != "0"
    }

    /// Top frame only: one driven layer per page is enough to keep the rendering
    /// updates coming, and subframes ride the same commit.
    static let scriptSource = """
    (function () {
        if (window !== window.top) { return; }
        var host = document.documentElement;
        if (!host || host.__auraKeepAlive) { return; }
        host.__auraKeepAlive = true;
        var pixel = document.createElement('div');
        pixel.style.cssText = 'position:fixed;left:0;top:0;width:1px;height:1px;' +
            'opacity:0.001;pointer-events:none;z-index:-2147483648;will-change:transform;';
        host.appendChild(pixel);
        var flip = 0;
        var tick = function () {
            flip ^= 1;
            pixel.style.transform = 'translateZ(0) translateX(' + flip * 0.5 + 'px)';
            window.requestAnimationFrame(tick);
        };
        window.requestAnimationFrame(tick);
    })();
    """

    /// Adds the loop to `configuration`. The caller gates on the injected bundle
    /// being active; pages on the ordinary WebContent service never see this.
    static func apply(to configuration: WKWebViewConfiguration) {
        guard isEnabled else { return }
        configuration.userContentController.addUserScript(WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }
}
