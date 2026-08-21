// Aura's blocking-webRequest shim.
//
// WebKit implements browser.webRequest as observe-only: a listener registered
// with "blocking" runs, but whatever it returns is ignored, so uBlock Origin
// counts ads it cannot stop. Aura prepends this file to an extension's
// background scripts at install time so the extension talks to the browser
// instead of to WebKit's stub.
//
// A listener registered with "blocking" is kept here and announced to the host
// over a native message port. When the injected bundle is about to start a
// subresource load it asks the host, the host asks this file, and the answer
// travels back before the request exists. Everything without "blocking" is
// handed to WebKit untouched.

'use strict';

(function auraShim() {
    const NATIVE_APPLICATION = 'app.aurabrowser.bridge';
    // Bumped when the protocol changes so a stale patched extension is repatched.
    const SHIM_VERSION = 1;

    const api = typeof browser !== 'undefined' ? browser : (typeof chrome !== 'undefined' ? chrome : null);
    if (!api || globalThis.__auraShimInstalled) { return; }
    globalThis.__auraShimInstalled = SHIM_VERSION;

    // -----------------------------------------------------------------------
    // WebKit strictness polyfills
    // -----------------------------------------------------------------------

    // WebKit builds browser.* out of native JSC class objects whose property
    // getters win over anything defined on the instance, so nothing here can be
    // patched in place. What can be replaced is the `browser` global itself, so
    // the shim hands the extension a proxy that answers for the members it
    // overrides and forwards everything else to the real namespace.
    const overrides = new Map();

    /// A no-op event. WebKit ships a partial browser.* surface, and an extension
    /// that calls addListener on an event WebKit lacks dies on the spot. A stub
    /// costs it the event, not its whole background page.
    function eventStub() {
        return {
            __auraStub: true,
            addListener() {},
            removeListener() {},
            hasListener() { return false; },
        };
    }

    function namespaceProxy(native, members) {
        const bound = new Map();
        const stubs = new Map();
        return new Proxy(native, {
            get(target, property) {
                if (members !== null && members.has(property)) { return members.get(property); }
                const value = target[property];
                if (typeof value === 'function') {
                    // Bound to the native object: WebKit's API methods reject a
                    // proxy as `this`. Cached so the identity stays stable, which
                    // is what removeListener(fn) relies on.
                    let fn = bound.get(property);
                    if (fn === undefined) {
                        fn = value.bind(target);
                        bound.set(property, fn);
                    }
                    return fn;
                }
                if (value === undefined && typeof property === 'string' && /^on[A-Z]/.test(property)) {
                    let stub = stubs.get(property);
                    if (stub === undefined) {
                        stub = eventStub();
                        stubs.set(property, stub);
                    }
                    return stub;
                }
                return value;
            },
            has(target, property) {
                return (members !== null && members.has(property)) || property in target;
            },
        });
    }

    // uBO calls vAPI.getURL('') to get its own root. WebKit's getURL rejects an
    // empty path, and the TypeError lands in uBO's start-up path, which is why
    // the popup used to come up blank.
    const runtimeMembers = new Map();
    if (api.runtime && typeof api.runtime.getURL === 'function') {
        const native = api.runtime;
        let root = '';
        const rootURL = () => {
            if (root === '') {
                try {
                    root = native.getURL('manifest.json').replace(/manifest\.json$/, '');
                } catch (_) {
                    root = '';
                }
            }
            return root;
        };
        // WebKit's runtime.getManifest() returns undefined. Extensions read
        // their own version out of it during start-up, so the patcher writes the
        // manifest out as a script and this hands it back.
        runtimeMembers.set('getManifest', () => {
            try {
                const native = api.runtime.getManifest();
                if (native && typeof native === 'object') { return native; }
            } catch (_) { /* fall through */ }
            return globalThis.__auraManifest || {};
        });

        runtimeMembers.set('getURL', path => {
            if (path === '' || path === undefined || path === null) { return rootURL(); }
            try {
                const resolved = native.getURL(path);
                if (typeof resolved === 'string' && resolved !== '') { return resolved; }
            } catch (_) { /* fall through to manual resolution */ }
            return rootURL() + String(path).replace(/^\//, '');
        });
    }

    // -----------------------------------------------------------------------
    // Native port
    // -----------------------------------------------------------------------

    let port = null;
    let nextListenerId = 1;
    // listenerId -> { event, fn, filter, extra }
    const blockingListeners = new Map();
    const pendingAnnouncements = [];

    function send(message) {
        if (port === null) {
            pendingAnnouncements.push(message);
            return;
        }
        try {
            port.postMessage(message);
        } catch (_) {
            port = null;
            pendingAnnouncements.push(message);
            connect();
        }
    }

    let lastConnectError = '';

    function connect() {
        if (port !== null || typeof api.runtime.connectNative !== 'function') { return; }
        let opened;
        try {
            opened = api.runtime.connectNative(NATIVE_APPLICATION);
        } catch (error) {
            lastConnectError = String(error);
            return;
        }
        if (!opened) { return; }
        port = opened;
        port.onMessage.addListener(onHostMessage);
        if (port.onDisconnect) {
            port.onDisconnect.addListener(() => { port = null; });
        }
        const queued = pendingAnnouncements.splice(0, pendingAnnouncements.length);
        for (const message of queued) { send(message); }
    }

    // -----------------------------------------------------------------------
    // Tab identity
    //
    // The injected bundle knows which page issued a request but not which tab
    // id WebKit handed the extension, and there is no API to ask. This keeps a
    // page-URL to tab-id map from the tabs API, which is the same information
    // seen from the other side.
    // -----------------------------------------------------------------------

    const tabIdByURL = new Map();
    let activeTabId = -1;

    function rememberTab(tab) {
        if (tab && typeof tab.id === 'number' && typeof tab.url === 'string' && tab.url !== '') {
            tabIdByURL.set(tab.url, tab.id);
        }
    }

    function startTabTracking() {
        if (!api.tabs || typeof api.tabs.query !== 'function') { return; }
        try {
            const query = api.tabs.query({}, tabs => { (tabs || []).forEach(rememberTab); });
            if (query && typeof query.then === 'function') {
                query.then(tabs => { (tabs || []).forEach(rememberTab); }, () => {});
            }
        } catch (_) { /* no tabs permission */ }

        if (api.tabs.onUpdated) {
            api.tabs.onUpdated.addListener((tabId, changeInfo, tab) => rememberTab(tab));
        }
        if (api.tabs.onActivated) {
            api.tabs.onActivated.addListener(info => { activeTabId = info.tabId; });
        }
        if (api.tabs.onRemoved) {
            api.tabs.onRemoved.addListener(tabId => {
                for (const [url, id] of tabIdByURL) {
                    if (id === tabId) { tabIdByURL.delete(url); }
                }
            });
        }
    }

    function tabIdForPage(pageUrl) {
        if (typeof pageUrl === 'string') {
            const exact = tabIdByURL.get(pageUrl);
            if (exact !== undefined) { return exact; }
        }
        return activeTabId;
    }

    // -----------------------------------------------------------------------
    // Decisions
    // -----------------------------------------------------------------------

    function detailsFromHost(raw) {
        const details = {
            requestId: String(raw.requestId),
            url: raw.url,
            method: raw.method || 'GET',
            frameId: typeof raw.frameId === 'number' ? raw.frameId : 0,
            parentFrameId: typeof raw.parentFrameId === 'number' ? raw.parentFrameId : -1,
            tabId: tabIdForPage(raw.pageUrl),
            type: raw.type || 'other',
            timeStamp: Date.now(),
        };
        if (typeof raw.documentUrl === 'string') {
            details.documentUrl = raw.documentUrl;
            details.originUrl = raw.documentUrl;
            details.initiator = raw.documentUrl;
        }
        return details;
    }

    function matchesFilter(entry, details) {
        const filter = entry.filter;
        if (!filter) { return true; }
        if (Array.isArray(filter.types) && filter.types.length > 0 && !filter.types.includes(details.type)) {
            return false;
        }
        if (Array.isArray(filter.urls) && filter.urls.length > 0) {
            return filter.urls.some(pattern => matchPattern(pattern).test(details.url));
        }
        return true;
    }

    const patternCache = new Map();

    // A match pattern is scheme://host/path with * as the only wildcard, so a
    // regexp built from it is exact rather than a heuristic.
    function matchPattern(pattern) {
        let expression = patternCache.get(pattern);
        if (expression !== undefined) { return expression; }
        if (pattern === '<all_urls>') {
            expression = /^(https?|wss?|ftp|file|data):/;
        } else {
            const escaped = pattern
                .replace(/[.+?^${}()|[\]\\]/g, '\\$&')
                .replace(/^\\\*\\\*/, '*')
                .replace(/\*/g, '.*');
            expression = new RegExp('^' + escaped.replace(/^\.\*:/, '[a-z]+:') + '$');
        }
        patternCache.set(pattern, expression);
        return expression;
    }

    function decide(id, raw) {
        const details = detailsFromHost(raw);
        let verdict = null;
        for (const entry of blockingListeners.values()) {
            if (entry.event !== 'onBeforeRequest' || !matchesFilter(entry, details)) { continue; }
            let result;
            try {
                result = entry.fn(details);
            } catch (error) {
                continue;
            }
            if (!result || typeof result !== 'object') { continue; }
            if (result.cancel === true) { verdict = { cancel: true }; break; }
            if (typeof result.redirectUrl === 'string' && result.redirectUrl !== '') {
                verdict = { redirectUrl: result.redirectUrl };
                break;
            }
        }
        send({ op: 'verdict', id: id, cancel: verdict ? verdict.cancel === true : false,
               redirectUrl: verdict && verdict.redirectUrl ? verdict.redirectUrl : null });
    }

    function onHostMessage(message) {
        if (!message || message.op !== 'decide') { return; }
        try {
            decide(message.id, message.details || {});
        } catch (_) {
            send({ op: 'verdict', id: message.id, cancel: false, redirectUrl: null });
        }
    }

    // -----------------------------------------------------------------------
    // browser.webRequest
    // -----------------------------------------------------------------------

    const BLOCKING_EVENTS = ['onBeforeRequest', 'onBeforeSendHeaders', 'onHeadersReceived'];
    // ponytail: only onBeforeRequest is answered natively. The injected bundle
    // sees a request before headers exist and never sees a response, so the
    // other two run observe-only. Wire them up when header rewriting lands.
    const NATIVE_EVENTS = ['onBeforeRequest'];

    const nativeWebRequest = api.webRequest || {};
    const webRequestMembers = new Map();

    for (const event of BLOCKING_EVENTS) {
        const native = nativeWebRequest[event];
        const nativeAdd = native && typeof native.addListener === 'function'
            ? native.addListener.bind(native) : null;
        const nativeRemove = native && typeof native.removeListener === 'function'
            ? native.removeListener.bind(native) : null;
        const nativeHas = native && typeof native.hasListener === 'function'
            ? native.hasListener.bind(native) : null;
        const shimmed = new Map();

        webRequestMembers.set(event, {
            __auraShim: true,
            addListener(fn, filter, extraInfoSpec) {
                const spec = Array.isArray(extraInfoSpec) ? extraInfoSpec : [];
                const isBlocking = spec.includes('blocking') && NATIVE_EVENTS.includes(event);
                if (!isBlocking) {
                    // Includes blocking listeners on the two events Aura answers
                    // observe-only: registering them without "blocking" still
                    // runs the extension's bookkeeping.
                    if (nativeAdd) { nativeAdd(fn, filter, spec.filter(item => item !== 'blocking')); }
                    return;
                }
                const id = nextListenerId++;
                shimmed.set(fn, id);
                blockingListeners.set(id, { event: event, fn: fn, filter: filter, extra: spec });
                send({
                    op: 'register',
                    id: id,
                    event: event,
                    urls: (filter && filter.urls) || ['<all_urls>'],
                    types: (filter && filter.types) || [],
                });
            },
            removeListener(fn) {
                const id = shimmed.get(fn);
                if (id === undefined) {
                    if (nativeRemove) { nativeRemove(fn); }
                    return;
                }
                shimmed.delete(fn);
                blockingListeners.delete(id);
                send({ op: 'unregister', id: id });
            },
            hasListener(fn) {
                if (shimmed.has(fn)) { return true; }
                return nativeHas ? nativeHas(fn) : false;
            },
        });
    }

    // Chrome's cap on how often a listener may be called. uBO reads it and
    // divides by it, so an undefined value turns into NaN.
    if (typeof nativeWebRequest.MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES !== 'number') {
        webRequestMembers.set('MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES', 20);
    }
    if (typeof nativeWebRequest.handlerBehaviorChanged !== 'function') {
        webRequestMembers.set('handlerBehaviorChanged', () => {});
    }

    overrides.set('webRequest', namespaceProxy(nativeWebRequest, webRequestMembers));
    if (runtimeMembers.size > 0) {
        overrides.set('runtime', namespaceProxy(api.runtime, runtimeMembers));
    }

    // The swap. Everything the extension loads after this line sees the proxy.
    const wrappedNamespaces = new Map();
    const shimmedAPI = new Proxy(api, {
        get(target, property) {
            if (overrides.has(property)) { return overrides.get(property); }
            const value = target[property];
            if (value === null || typeof value !== 'object') { return value; }
            let wrapped = wrappedNamespaces.get(property);
            if (wrapped === undefined) {
                wrapped = namespaceProxy(value, null);
                wrappedNamespaces.set(property, wrapped);
            }
            return wrapped;
        },
    });
    let installedGlobals = 0;
    for (const name of ['browser', 'chrome']) {
        if (typeof globalThis[name] === 'undefined') { continue; }
        try {
            Object.defineProperty(globalThis, name, {
                value: shimmedAPI,
                writable: true,
                configurable: true,
                enumerable: true,
            });
            installedGlobals += globalThis[name] === shimmedAPI ? 1 : 0;
        } catch (_) { /* reported in the hello below */ }
    }

    startTabTracking();
    connect();

    // The background page has no console the browser can read, so the shim says
    // what it managed to wire up. One message, at start-up.
    if (typeof api.runtime.sendNativeMessage === 'function') {
        try {
            api.runtime.sendNativeMessage(NATIVE_APPLICATION, {
                op: 'hello',
                shimVersion: SHIM_VERSION,
                connectNative: typeof api.runtime.connectNative,
                connected: port !== null,
                connectError: lastConnectError,
                globals: installedGlobals,
                patched: !!(globalThis.browser && globalThis.browser.webRequest
                    && globalThis.browser.webRequest.onBeforeRequest
                    && globalThis.browser.webRequest.onBeforeRequest.__auraShim),
            });
        } catch (_) { /* nothing left to report through */ }
    }
}());
