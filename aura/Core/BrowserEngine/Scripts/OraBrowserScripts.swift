import Foundation

enum OraBrowserScripts {
    static func userScripts() -> [BrowserUserScript] {
        allUserScripts
    }

    /// The sources never vary per web view, so build them once instead of re-reading
    /// password-manager.js off disk for every tab.
    private static let allUserScripts: [BrowserUserScript] = {
        var scripts = [
            BrowserUserScript(
                name: "ora-bridge",
                source: bridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ),
            BrowserUserScript(
                name: "ora-navigation",
                source: navigationAndMediaScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ),
            // Subframes included: a right-click inside an iframe still has to describe the
            // element under the pointer, and this script does not depend on the bridge.
            BrowserUserScript(
                name: "ora-context-menu",
                source: contextMenuScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        ]

        if let passwordManagerScript = loadResourceScript(named: "password-manager") {
            scripts.append(
                BrowserUserScript(
                    name: "ora-password-manager",
                    source: passwordManagerScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }

        return scripts
    }()

    private static func loadResourceScript(named name: String) -> String? {
        guard let scriptURL = Bundle.main.url(forResource: name, withExtension: "js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8)
        else {
            return nil
        }
        return script
    }

    /// Reports what is under the pointer on every right-click. WebKit dispatches the DOM
    /// `contextmenu` event before AppKit builds its menu, so the native side always has a
    /// fresh answer by the time `willOpenMenu` runs.
    private static let contextMenuScript = """
    (function () {
        if (window.__oraContextMenuInstalled) {
            return;
        }
        window.__oraContextMenuInstalled = true;

        function closest(element, selector) {
            return element && element.closest ? element.closest(selector) : null;
        }

        function isEditable(element) {
            if (!element) return false;
            if (element.isContentEditable) return true;
            var field = closest(element, 'input, textarea');
            if (!field) return false;
            if (field.disabled || field.readOnly) return false;
            return field.tagName === 'TEXTAREA' || /^(text|search|url|email|tel|password|number)$/i
                .test(field.type || 'text');
        }

        document.addEventListener('contextmenu', function (event) {
            var target = event.target;
            var anchor = closest(target, 'a[href]');
            var image = target && target.tagName === 'IMG' ? target : closest(target, 'img[src]');
            var media = closest(target, 'video, audio');
            var selection = '';
            try {
                selection = String(window.getSelection() || '');
            } catch (error) {}

            try {
                window.webkit.messageHandlers.contextMenu.postMessage({
                    link: anchor ? anchor.href : '',
                    linkText: anchor ? (anchor.textContent || '').trim().slice(0, 120) : '',
                    image: image ? image.currentSrc || image.src || '' : '',
                    media: media ? media.currentSrc || media.src || '' : '',
                    selection: selection.slice(0, 500),
                    isEditable: isEditable(target)
                });
            } catch (error) {}
        }, { capture: true });
    })();
    """

    private static let bridgeScript = """
    (function () {
        if (window.__oraBridge && typeof window.__oraBridge.postMessage === 'function') {
            return;
        }

        window.__oraBridge = {
            postMessage: function(name, payload) {
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
                        window.webkit.messageHandlers[name].postMessage(payload);
                        return true;
                    }
                } catch (error) {}
                return false;
            }
        };
    })();
    """
}

/// The page-side script lives in its own extension so the enum body stays readable.
private extension OraBrowserScripts {
    private static let navigationAndMediaScript = """
    (function () {
        let lastHref = location.href;
        let lastTitle = document.title;

        function post(name, payload) {
            try {
                window.__oraBridge && window.__oraBridge.postMessage(name, payload);
            } catch (error) {}
        }

        function notifyChange(force = false) {
            if (force || location.href !== lastHref || document.title !== lastTitle) {
                lastHref = location.href;
                lastTitle = document.title;
                post('listener', JSON.stringify({ href: lastHref, title: lastTitle }));
            }
        }

        // A router-driven app can call pushState hundreds of times a second, and every
        // message costs a hop into the native side. One message per 150 ms is as fresh as
        // the sidebar can show anyway.
        let notifyTimer = 0;

        function scheduleNotify() {
            if (notifyTimer) return;
            notifyTimer = setTimeout(() => {
                notifyTimer = 0;
                notifyChange();
            }, 150);
        }

        const titleObserver = new MutationObserver(scheduleNotify);

        function observeTitle() {
            const titleElement = document.querySelector('title');
            if (!titleElement) return false;
            titleObserver.observe(titleElement, { childList: true });
            return true;
        }

        // A document that has no <title> yet gets one watch on <head> until it grows one.
        // Everything else is event driven: polling the URL and title from a timer costs
        // every page in the browser, benchmark pages included.
        if (!observeTitle() && document.head) {
            const headObserver = new MutationObserver(() => {
                if (observeTitle()) {
                    headObserver.disconnect();
                    scheduleNotify();
                }
            });
            headObserver.observe(document.head, { childList: true });
        }

        for (const method of ['pushState', 'replaceState']) {
            const original = history[method];
            if (typeof original !== 'function') continue;
            history[method] = function () {
                const result = original.apply(this, arguments);
                scheduleNotify();
                return result;
            };
        }

        window.addEventListener('popstate', scheduleNotify, { passive: true });
        window.addEventListener('hashchange', scheduleNotify, { passive: true });
        notifyChange(true);

        let lastHover = null;

        function postHover(url) {
            const href = url || "";
            // mouseover fires for every element under the cursor; only the changes matter.
            if (href === lastHover) return;
            lastHover = href;
            post('linkHover', href);
        }

        function onMouseOver(event) {
            const anchor = event.target.closest && event.target.closest('a[href]');
            postHover(anchor ? anchor.href : '');
        }

        function onMouseOut(event) {
            const related = event.relatedTarget;
            if (!related || !event.currentTarget.contains(related)) {
                postHover("");
            }
        }

        document.addEventListener('mouseover', onMouseOver, { capture: true, passive: true });
        document.addEventListener('mouseout', onMouseOut, { capture: true, passive: true });
    })();

    (function () {
        if (window.__oraMediaInstalled) {
            return;
        }
        window.__oraMediaInstalled = true;

        function post(payload) {
            try {
                window.__oraBridge && window.__oraBridge.postMessage('mediaEvent', JSON.stringify(payload));
            } catch (error) {}
        }

        function findNextButton() {
            const selectors = [
                '.ytp-next-button',
                'button[aria-label*="Next" i]',
                'button[title*="Next" i]',
                '[data-testid="control-button-skip-forward"]'
            ];
            for (const selector of selectors) {
                const element = document.querySelector(selector);
                if (element) return element;
            }
            return null;
        }

        function findPrevButton() {
            const selectors = [
                '.ytp-prev-button',
                'button[aria-label*="Previous" i]',
                'button[title*="Previous" i]',
                '[data-testid="control-button-skip-backward"]'
            ];
            for (const selector of selectors) {
                const element = document.querySelector(selector);
                if (element) return element;
            }
            return null;
        }

        function caps() {
            post({
                type: 'caps',
                hasNext: !!findNextButton(),
                hasPrevious: !!findPrevButton()
            });
        }

        const stateFrom = (element) => ({
            type: 'state',
            wasPlayed: element && element.__oraWasPlayed,
            state: element && !element.paused ? 'playing' : 'paused',
            volume: element ? (element.muted ? 0 : element.volume) : undefined,
            title: document.title
        });

        function attach(element) {
            if (!element || element.__oraAttached) return;
            element.__oraAttached = true;
            const update = () => post(stateFrom(element));
            element.addEventListener('play', () => {
                update();
                element.__oraWasPlayed = true;
            });
            element.addEventListener('pause', update);
            element.addEventListener('ended', () => post({ type: 'ended' }));
            element.addEventListener('volumechange', () =>
                post({ type: 'volume', volume: element.muted ? 0 : element.volume })
            );
            if (!element.paused) {
                element.__oraWasPlayed = true;
                update();
            }
        }

        let hadMedia = false;
        let scanPending = false;
        let treeObserver = null;

        function scan() {
            const elements = document.querySelectorAll('video, audio');
            // A media-less page that was already media-less has nothing to report, and
            // the observer fires on every DOM batch. One message still goes out when
            // media disappears so the native side can clear its session.
            if (elements.length === 0 && !hadMedia) return;
            if (elements.length === 0) {
                hadMedia = false;
                post({ type: 'removed' });
                return;
            }
            hadMedia = true;
            elements.forEach(attach);
            caps();
        }

        function scheduleScan() {
            if (scanPending) return;
            scanPending = true;
            setTimeout(() => {
                scanPending = false;
                scan();
            }, 250);
        }

        // Watching every DOM mutation in the document is the single most expensive thing
        // this script can do, so a page without media never starts the observer. The
        // capture listeners below cost nothing until a media element actually loads.
        function startWatchingTree() {
            if (treeObserver) return;
            treeObserver = new MutationObserver(scheduleScan);
            treeObserver.observe(document.documentElement, { childList: true, subtree: true });
        }

        function onMediaLifecycle(event) {
            const element = event.target;
            if (!element || (element.tagName !== 'VIDEO' && element.tagName !== 'AUDIO')) return;
            startWatchingTree();
            hadMedia = true;
            attach(element);
            caps();
        }

        for (const name of ['play', 'playing', 'loadedmetadata', 'loadeddata']) {
            document.addEventListener(name, onMediaLifecycle, { capture: true, passive: true });
        }

        if (document.querySelector('video, audio')) {
            startWatchingTree();
            scan();
        }

        window.__oraMedia = {
            active: null,
            _pick() {
                const elements = Array.from(document.querySelectorAll('video, audio'));
                const playing = elements.find((element) => !element.paused);
                this.active = playing || elements[0] || null;
                return this.active;
            },
            play() {
                try { (this._pick() || {}).play(); return true; } catch (error) { return false; }
            },
            pause() {
                try { (this._pick() || {}).pause(); return true; } catch (error) { return false; }
            },
            toggle() {
                const element = this._pick();
                if (!element) return false;
                if (element.paused) {
                    element.play();
                } else {
                    element.pause();
                }
                return true;
            },
            setVolume(value) {
                const element = this._pick();
                if (!element) return false;
                element.muted = false;
                element.volume = Math.max(0, Math.min(1, value));
                post({ type: 'volume', volume: element.volume });
                return true;
            },
            deltaVolume(delta) {
                const element = this._pick();
                if (!element) return false;
                element.muted = false;
                element.volume = Math.max(0, Math.min(1, (element.volume || 0) + delta));
                post({ type: 'volume', volume: element.volume });
                return true;
            },
            next() {
                const element = findNextButton();
                if (!element) return false;
                element.click();
                caps();
                return true;
            },
            previous() {
                const element = findPrevButton();
                if (!element) return false;
                element.click();
                caps();
                return true;
            },
            title() {
                return document.title;
            }
        };

        window.__oraTriggerPiP = function(isActive = false) {
            const video = document.querySelector('video');

            function hasAudio(target) {
                if (!target) return false;
                if (target.audioTracks && target.audioTracks.length > 0) return true;
                if (!target.muted && target.volume > 0) return true;
                return false;
            }

            if (
                video &&
                video.tagName === 'VIDEO' &&
                !document.pictureInPictureElement &&
                !video.paused &&
                !isActive &&
                hasAudio(video)
            ) {
                video.requestPictureInPicture().catch(() => {});
            } else if (document.pictureInPictureElement) {
                document.exitPictureInPicture().catch(() => {});
            }
        };

        post({ type: 'ready', title: document.title });
    })();
    """
}
