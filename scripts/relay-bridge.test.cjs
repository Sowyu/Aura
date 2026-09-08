const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const vm = require('node:vm');

const source = readFileSync(`${__dirname}/../aura/Resources/WebScripts/aura-shim.js`, 'utf8');
function event() {
    const listeners = new Set();
    return {
        addListener(fn) { listeners.add(fn); },
        removeListener(fn) { listeners.delete(fn); },
        fire(...args) { for (const fn of listeners) fn(...args); },
    };
}
function fixture() {
    const connections = [];
    const runtime = {
        id: 'test-extension', getURL(path) { return `webkit-extension://test/${path}`; },
        getManifest() { return {}; }, onMessage: event(), onConnect: event(),
        connectNative() {
            const port = { onMessage: event(), onDisconnect: event(), postMessage() {} };
            connections.push(port);
            return port;
        },
    };
    const context = vm.createContext({
        browser: { runtime }, __auraShimRole: 'page',
        location: { href: 'webkit-extension://test/popup.html' },
        setTimeout, clearTimeout, console,
    });
    vm.runInContext(source, context);
    return { runtime: context.browser.runtime, connections };
}

test('native relay disconnect settles pending messages and closes virtual ports', async () => {
    const f = fixture();
    const reply = f.runtime.sendMessage({ question: 'pending' });
    const port = f.runtime.connect({ name: 'pending-port' });
    let closed = 0;
    port.onDisconnect.addListener(() => closed++);
    f.connections[0].onDisconnect.fire();
    assert.equal(await reply, null);
    assert.equal(closed, 1);
    // Late native notifications cannot close the same virtual port twice.
    f.connections[0].onDisconnect.fire();
    assert.equal(closed, 1);
});
