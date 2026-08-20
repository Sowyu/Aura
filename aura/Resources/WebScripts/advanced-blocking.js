/*
 * Aura advanced blocking applier.
 *
 * Runs in the page world at document start in every frame. Swift builds a tiny
 * per-navigation payload script that calls `apply()` with the rules selected for
 * the document URL, so this file stays constant and WebKit can cache it.
 *
 * The logic mirrors @adguard/safari-extension's ContentScript (GPL-3.0), minus
 * the WebExtension messaging: scriptlet code is already generated in Swift via
 * JavaScriptCore, and user scripts are exempt from the page CSP, so there is no
 * need for the <script> tag / blob dance the extension has to do.
 */
(function () {
    'use strict';

    if (window.__auraAB) {
        return;
    }

    /**
     * A bare selector means "hide it"; anything ending in `}` is already a full rule.
     */
    function toCssRules(rules) {
        var out = [];
        for (var i = 0; i < rules.length; i += 1) {
            var rule = String(rules[i]).trim();
            if (!rule.length) {
                continue;
            }
            out.push(rule.charAt(rule.length - 1) === '}' ? rule : rule + ' {display:none!important;}');
        }
        return out;
    }

    function insertCss(rules) {
        if (!rules || !rules.length) {
            return;
        }
        try {
            var style = document.createElement('style');
            style.setAttribute('type', 'text/css');
            (document.head || document.documentElement).appendChild(style);
            if (!style.sheet) {
                return;
            }
            var cssRules = toCssRules(rules);
            for (var i = 0; i < cssRules.length; i += 1) {
                try {
                    style.sheet.insertRule(cssRules[i], style.sheet.cssRules.length);
                } catch (ignored) {
                    // One malformed selector must not drop the rest of the stylesheet.
                }
            }
        } catch (error) {
            // A document without a documentElement yet (rare) simply gets no CSS.
        }
    }

    function extendedCssConstructor() {
        var lib = window.__auraExtendedCss || window.ExtendedCss;
        if (!lib) {
            return null;
        }
        return typeof lib === 'function' ? lib : lib.ExtendedCss;
    }

    function insertExtendedCss(rules) {
        if (!rules || !rules.length) {
            return;
        }
        var Ctor = extendedCssConstructor();
        if (!Ctor) {
            return;
        }
        try {
            new Ctor({ cssRules: toCssRules(rules) }).apply();
        } catch (error) {
            // Procedural selectors are best-effort; a parse failure is not fatal.
        }
    }

    /**
     * True when the rules picked for `config.url` are the right rules for this frame.
     *
     * A frame with no real origin (about:blank, srcdoc, data:) inherits its parent's
     * origin, so the parent's rules are exactly what belongs there.
     */
    function frameMatches(config) {
        if (window.top === window) {
            return true;
        }
        var origin = location.origin;
        if (!origin || origin === 'null') {
            return true;
        }
        return origin === config.origin;
    }

    function requestFrameRules() {
        try {
            window.webkit.messageHandlers.advancedBlocking.postMessage({ url: location.href });
        } catch (error) {
            // No handler registered means advanced blocking is off for this page.
        }
    }

    window.__auraAB = {
        /**
         * @param {{origin: string, css: string[], extendedCss: string[]}} config
         * @param {Function} [runScripts] Scriptlet and script-rule code for this document.
         */
        apply: function (config, runScripts) {
            if (!frameMatches(config)) {
                requestFrameRules();
                return;
            }
            if (typeof runScripts === 'function') {
                try {
                    runScripts();
                } catch (error) {
                    // A broken scriptlet must not stop the cosmetic rules.
                }
            }
            insertCss(config.css);
            insertExtendedCss(config.extendedCss);
        },

        /**
         * Same as `apply`, minus the frame check: used for the cross-origin subframe
         * reply, where Swift already looked the rules up for this exact frame URL.
         */
        applyForFrame: function (config) {
            insertCss(config.css);
            insertExtendedCss(config.extendedCss);
        }
    };
})();
