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
//
// The same file also runs in the extension's own pages (popup, options,
// sidebar), where it does a second job: WebKit never delivers
// runtime.connect()/runtime.sendMessage() from an extension page to that
// extension's background page, so both are tunnelled through the host over a
// native port. Content scripts are left on WebKit's native path, which works.

'use strict';

(function auraShim() {
    const NATIVE_APPLICATION = 'app.aurabrowser.bridge';
    // Two identifiers rather than one plus a handshake: the host can tell which
    // side of the tunnel a port belongs to the moment it arrives.
    const RELAY_BACKGROUND = 'app.aurabrowser.relay.background';
    const RELAY_PAGE = 'app.aurabrowser.relay.page';
    // Bumped when the protocol changes so a stale patched extension is repatched.
    const SHIM_VERSION = 3;

    const api = typeof browser !== 'undefined' ? browser : (typeof chrome !== 'undefined' ? chrome : null);
    if (!api || globalThis.__auraShimInstalled) { return; }
    globalThis.__auraShimInstalled = SHIM_VERSION;

    // The patcher writes 'page' into every extension page it injects into. The
    // background context gets no marker, so anything unmarked is the background.
    const IS_PAGE = globalThis.__auraShimRole === 'page';

    // -----------------------------------------------------------------------
    // WebKit strictness polyfills
    // -----------------------------------------------------------------------

    // WebKit gives an extension background page no requestIdleCallback. uBlock
    // Origin schedules its badge updates through it and the TypeError aborts
    // whatever start-up step it landed in. Deferred work run late is exactly
    // what the caller asked for, so a timer is a faithful stand-in.
    if (typeof globalThis.requestIdleCallback !== 'function') {
        globalThis.requestIdleCallback = (callback, options) => setTimeout(
            () => callback({ didTimeout: true, timeRemaining: () => 0 }),
            options && typeof options.timeout === 'number' ? Math.min(options.timeout, 50) : 1
        );
        globalThis.cancelIdleCallback = id => clearTimeout(id);
    }

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

    // WebKit throws on i18n.getMessage('') where Firefox and Chrome return the
    // empty string. uBlock Origin's popup markup carries valueless `aria-label`
    // attributes, its i18n pass feeds each one straight in, and the throw kills
    // the module that every other popup script imports. That is what left the
    // panel blank even once messaging worked.
    if (api.i18n && typeof api.i18n.getMessage === 'function') {
        const nativeGetMessage = api.i18n.getMessage.bind(api.i18n);
        const i18nMembers = new Map();
        i18nMembers.set('getMessage', (name, substitutions) => {
            if (typeof name !== 'string' || name === '') { return ''; }
            try {
                const text = substitutions === undefined
                    ? nativeGetMessage(name)
                    : nativeGetMessage(name, substitutions);
                return typeof text === 'string' ? text : '';
            } catch (_) {
                return '';
            }
        });
        overrides.set('i18n', namespaceProxy(api.i18n, i18nMembers));
    }

    // WebKit rejects a menu entry whose URL patterns it does not recognise
    // (uBlock Origin registers one for `abp:*` subscription links) and throws
    // out of menus.create. uBO builds its whole context menu in one unguarded
    // loop, so one bad pattern costs every entry after it. Dropping the
    // patterns costs that one entry its URL filter and keeps the rest.
    for (const namespace of ['menus', 'contextMenus']) {
        const native = api[namespace];
        if (!native || typeof native.create !== 'function') { continue; }
        const nativeCreate = native.create.bind(native);
        const create = (properties, callback) => {
            const attempt = value => (callback === undefined ? nativeCreate(value) : nativeCreate(value, callback));
            try {
                return attempt(properties);
            } catch (_) { /* retried below */ }
            if (!properties || typeof properties !== 'object') { return undefined; }
            const relaxed = Object.assign({}, properties);
            delete relaxed.targetUrlPatterns;
            delete relaxed.documentUrlPatterns;
            try {
                return attempt(relaxed);
            } catch (_) {
                return undefined;
            }
        };
        overrides.set(namespace, namespaceProxy(native, new Map([['create', create]])));
    }

    // -----------------------------------------------------------------------
    // Intra-extension messaging relay
    //
    // WKWebExtension routes runtime.connect/sendMessage from an extension page
    // into the void: neither onConnect nor onMessage ever fires on the
    // background page. Both sides open a native port to the host instead, and
    // the host forwards frames between them. Port identity, message order and
    // disconnection all survive; the objects handed to the extension are
    // ordinary JS objects shaped like a WebExtensions Port.
    // -----------------------------------------------------------------------

    let relayPort = null;
    let relayUsable = false;
    let relayConnecting = false;
    const relayQueue = [];

    function relaySend(frame) {
        // A dropped relay port used to strand every later frame in the queue,
        // which showed up as a popup that opened blank after the first one.
        // Guarded: relayConnect drains the queue through this function, and a
        // port that throws on its first post would otherwise reconnect once per
        // queued frame.
        if (relayPort === null && !relayConnecting) {
            relayConnecting = true;
            try { relayConnect(); } finally { relayConnecting = false; }
        }
        if (relayPort === null) {
            if (relayQueue.length < 256) { relayQueue.push(frame); }
            return;
        }
        try {
            relayPort.postMessage(frame);
        } catch (_) {
            relayPort = null;
            if (relayQueue.length < 256) { relayQueue.push(frame); }
        }
    }

    function relayConnect() {
        if (typeof api.runtime.connectNative !== 'function') { return false; }
        let opened;
        try {
            opened = api.runtime.connectNative(IS_PAGE ? RELAY_PAGE : RELAY_BACKGROUND);
        } catch (_) {
            return false;
        }
        if (!opened) { return false; }
        relayPort = opened;
        relayPort.onMessage.addListener(onRelayFrame);
        if (relayPort.onDisconnect) {
            relayPort.onDisconnect.addListener(() => { relayPort = null; });
        }
        const queued = relayQueue.splice(0, relayQueue.length);
        for (const frame of queued) { relaySend(frame); }
        return true;
    }

    /// The smallest thing that answers to addListener/removeListener/hasListener
    /// and can be fired. Listener identity is what removeListener needs, so a Set.
    function relayEvent() {
        const listeners = new Set();
        return {
            addListener(fn) { if (typeof fn === 'function') { listeners.add(fn); } },
            removeListener(fn) { listeners.delete(fn); },
            hasListener(fn) { return listeners.has(fn); },
            fire(args) {
                for (const fn of Array.from(listeners)) {
                    try { fn.apply(null, args); } catch (_) { /* one bad listener is not fatal */ }
                }
            },
        };
    }

    // portId -> { port, onMessage, onDisconnect }
    const relayPorts = new Map();
    let nextRelayPortId = 1;
    // Ids are minted on the page side and never interpreted by the host, so a
    // per-document prefix keeps two open pages from colliding.
    const relayPrefix = Math.random().toString(36).slice(2, 10);

    function newPortId() {
        return relayPrefix + '-' + (nextRelayPortId++);
    }

    /// Both ends see the same object shape; only who sends the opening frame
    /// differs. `sender` is set on the background's copy, as onConnect promises.
    function makeRelayPort(portId, name, sender) {
        const onMessage = relayEvent();
        const onDisconnect = relayEvent();
        let alive = true;
        const port = {
            name: typeof name === 'string' ? name : '',
            onMessage: onMessage,
            onDisconnect: onDisconnect,
            postMessage(message) {
                if (!alive) { return; }
                relaySend({ op: 'post', portId: portId, message: message });
            },
            disconnect() {
                if (!alive) { return; }
                alive = false;
                relayPorts.delete(portId);
                relaySend({ op: 'disconnect', portId: portId });
            },
        };
        if (sender !== undefined) { port.sender = sender; }
        relayPorts.set(portId, { port: port, onMessage: onMessage, onDisconnect: onDisconnect,
                                 close() { alive = false; } });
        return port;
    }

    function senderInfo() {
        const sender = { url: location.href, frameId: 0 };
        try {
            if (typeof api.runtime.id === 'string') { sender.id = api.runtime.id; }
        } catch (_) { /* WebKit does not always expose it */ }
        return sender;
    }

    // Background side: listeners the extension registered, fired by hand when a
    // tunnelled frame arrives. They stay registered natively too, so content
    // scripts keep reaching the extension on WebKit's own path.
    const relayConnectListeners = relayEvent();
    const relayMessageListeners = [];
    // portId -> resolve, for the one-shot sendMessage on the page side.
    const relayReplies = new Map();

    function dispatchOneShot(frame) {
        let answered = false;
        const respond = value => {
            if (answered) { return; }
            answered = true;
            relaySend({ op: 'response', portId: frame.portId, message: value === undefined ? null : value });
        };
        let asynchronous = false;
        for (const fn of relayMessageListeners.slice()) {
            let result;
            try {
                result = fn(frame.message, frame.sender, respond);
            } catch (_) {
                continue;
            }
            if (result && typeof result.then === 'function') {
                asynchronous = true;
                result.then(respond, () => respond(null));
                break;
            }
            // Chrome's contract: true means "I will call sendResponse later".
            if (result === true) { asynchronous = true; break; }
            if (result !== undefined) { respond(result); break; }
        }
        if (!asynchronous) { respond(null); }
    }

    function onRelayFrame(frame) {
        if (!frame || typeof frame !== 'object' || typeof frame.portId !== 'string') { return; }
        const entry = relayPorts.get(frame.portId);
        switch (frame.op) {
        case 'connect':
            if (IS_PAGE || entry !== undefined) { return; }
            relayConnectListeners.fire([makeRelayPort(frame.portId, frame.name, frame.sender || {})]);
            break;
        case 'post':
            if (entry === undefined) { return; }
            entry.onMessage.fire([frame.message, entry.port]);
            break;
        case 'disconnect':
            if (entry === undefined) { return; }
            relayPorts.delete(frame.portId);
            entry.close();
            entry.onDisconnect.fire([entry.port]);
            break;
        case 'message':
            if (IS_PAGE) { return; }
            dispatchOneShot(frame);
            break;
        case 'response': {
            const resolve = relayReplies.get(frame.portId);
            if (resolve === undefined) { return; }
            relayReplies.delete(frame.portId);
            resolve(frame.message);
            break;
        }
        default:
            break;
        }
    }

    function installRelayMembers() {
        if (IS_PAGE) {
            const nativeConnect = typeof api.runtime.connect === 'function'
                ? api.runtime.connect.bind(api.runtime) : null;
            const nativeSend = typeof api.runtime.sendMessage === 'function'
                ? api.runtime.sendMessage.bind(api.runtime) : null;

            runtimeMembers.set('connect', function connect(...args) {
                if (!relayUsable) { return nativeConnect ? nativeConnect(...args) : undefined; }
                const last = args[args.length - 1];
                const info = last !== null && typeof last === 'object' ? last : {};
                const portId = newPortId();
                const port = makeRelayPort(portId, info.name, undefined);
                relaySend({ op: 'connect', portId: portId, name: port.name, sender: senderInfo() });
                return port;
            });

            runtimeMembers.set('sendMessage', function sendMessage(...args) {
                if (!relayUsable) { return nativeSend ? nativeSend(...args) : Promise.resolve(); }
                const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
                // (extensionId, message, options) or (message, options).
                const message = args.length >= 2 && typeof args[0] === 'string' ? args[1] : args[0];
                const portId = newPortId();
                const promise = new Promise(resolve => { relayReplies.set(portId, resolve); });
                relaySend({ op: 'message', portId: portId, message: message, sender: senderInfo() });
                if (callback === null) { return promise; }
                promise.then(callback, () => {});
                return undefined;
            });
            return;
        }

        const nativeConnectEvent = api.runtime.onConnect;
        runtimeMembers.set('onConnect', {
            __auraShim: true,
            addListener(fn) {
                relayConnectListeners.addListener(fn);
                if (nativeConnectEvent) { try { nativeConnectEvent.addListener(fn); } catch (_) {} }
            },
            removeListener(fn) {
                relayConnectListeners.removeListener(fn);
                if (nativeConnectEvent) { try { nativeConnectEvent.removeListener(fn); } catch (_) {} }
            },
            hasListener(fn) { return relayConnectListeners.hasListener(fn); },
        });

        const nativeMessageEvent = api.runtime.onMessage;
        runtimeMembers.set('onMessage', {
            __auraShim: true,
            addListener(fn) {
                if (typeof fn !== 'function' || relayMessageListeners.includes(fn)) { return; }
                relayMessageListeners.push(fn);
                if (nativeMessageEvent) { try { nativeMessageEvent.addListener(fn); } catch (_) {} }
            },
            removeListener(fn) {
                const at = relayMessageListeners.indexOf(fn);
                if (at !== -1) { relayMessageListeners.splice(at, 1); }
                if (nativeMessageEvent) { try { nativeMessageEvent.removeListener(fn); } catch (_) {} }
            },
            hasListener(fn) { return relayMessageListeners.includes(fn); },
        });
    }

    relayUsable = relayConnect();
    // Read by Aura's tests and by anyone inspecting a popup: false here means
    // the page fell back to WebKit's own (silently lossy) messaging.
    globalThis.__auraShimRelay = relayUsable;
    installRelayMembers();

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

    // Only the background context blocks requests; a popup registering a
    // blocking listener would be a bug, so it keeps WebKit's own webRequest.
    if (!IS_PAGE) {
        overrides.set('webRequest', namespaceProxy(nativeWebRequest, webRequestMembers));
    }
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

    if (!IS_PAGE) {
        startTabTracking();
        connect();
    }

    // Neither a background page nor a popup has a console the browser can read,
    // so the shim says what it managed to wire up. One message, at start-up.
    if (typeof api.runtime.sendNativeMessage === 'function') {
        try {
            api.runtime.sendNativeMessage(NATIVE_APPLICATION, {
                op: 'hello',
                shimVersion: SHIM_VERSION,
                role: IS_PAGE ? 'page' : 'background',
                url: location.href,
                relay: relayUsable,
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
