const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const vm = require('node:vm');

const swift = readFileSync(process.env.AURA_MEDIA_SCRIPT || `${__dirname}/../aura/Core/BrowserEngine/Scripts/AuraBrowserScripts.swift`, 'utf8');
const source = swift.match(/    \(function \(\) \{\n        if \(window\.__auraMediaInstalled\)[\s\S]*?\n    \}\)\(\);/)?.[0];
assert.ok(source, 'The shipped media script must be present');

function fixture() {
    const messages = [], observers = [], timers = [], events = {};
    const element = { tagName: 'VIDEO', paused: true, volume: 1, addEventListener() {} };
    const media = [element];
    const controls = { next: true };
    let scans = 0;
    const document = {
        title: 'test player', documentElement: {},
        querySelectorAll() { scans++; return [...media]; },
        querySelector(selector) {
            if (selector === 'video, audio') return media[0];
            return selector === '.ytp-next-button' && controls.next ? {} : null;
        },
        addEventListener(name, callback) { events[name] = callback; },
    };
    const window = { __auraBridge: { postMessage(_name, payload) { messages.push(JSON.parse(payload)); } } };
    vm.runInNewContext(source, {
        window, document,
        setTimeout(callback) { timers.push(callback); return timers.length; },
        MutationObserver: class {
            constructor(callback) { this.callback = callback; observers.push(this); }
            observe() { this.active = true; }
            disconnect() { this.active = false; }
        },
    });
    return {
        messages, media, element, controls, window, events,
        get scans() { return scans; },
        mutate() {
            observers.filter(observer => observer.active).forEach(observer => observer.callback());
            timers.splice(0).forEach(callback => callback());
        },
    };
}

test('unchanged media controls do not send repeated native messages', t => {
    const page = fixture();
    for (let index = 0; index < 100; index++) page.mutate();
    const caps = page.messages.filter(message => message.type === 'caps');
    t.diagnostic(`100 DOM batches: capability messages=${caps.length}`);
    assert.equal(caps.length, 1);
    page.controls.next = false;
    page.mutate();
    assert.equal(page.messages.at(-1).hasNext, false);
    page.events.play({ target: page.element });
    assert.equal(page.messages.at(-1).type, 'caps', 'A new native session still needs its capabilities');
});

test('removing the last media element stops scans and releases the active element', t => {
    const page = fixture();
    page.window.__auraMedia._pick();
    page.media.length = 0;
    page.mutate();
    assert.equal(page.messages.at(-1).type, 'removed');
    const before = page.scans;
    for (let index = 0; index < 100; index++) page.mutate();
    t.diagnostic(`100 DOM batches after media removal: scans=${page.scans - before}`);
    assert.equal(page.scans, before);
    assert.equal(page.window.__auraMedia.active, null);
    page.media.push(page.element);
    page.events.loadedmetadata({ target: page.element });
    page.controls.next = false;
    page.mutate();
    assert.equal(page.messages.at(-1).hasNext, false, 'The observer restarts when media returns');
});
