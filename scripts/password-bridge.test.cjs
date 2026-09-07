const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { webcrypto } = require('node:crypto');
const { test } = require('node:test');
const vm = require('node:vm');

const source = readFileSync(process.env.AURA_PASSWORD_SCRIPT || `${__dirname}/../aura/Resources/WebScripts/password-manager.js`, 'utf8');

// Exercise the shipped script. The DOM stub only supplies fields and events;
// document IDs, message construction and fill decisions come from production.
function documentFixture(extraInputs = 0) {
    const events = {};
    const messages = [];
    const frames = [];
    const metrics = { bounds: 0, styles: 0 };
    class Input {
        constructor(type) {
            this.type = type;
            this.name = type;
            this.dataset = {};
            this.style = { backgroundColor: '' };
            this.value = '';
            this.rect = { x: 0, y: 0, width: 100, height: 20 };
        }
        getAttribute() { return null; }
        getBoundingClientRect() { metrics.bounds++; return { ...this.rect }; }
        closest() { return form; }
        focus() { document.activeElement = this; }
        dispatchEvent() {}
    }
    class Form {
        querySelector() { return password; }
        querySelectorAll() { return inputs; }
    }
    const username = new Input('email');
    const password = new Input('password');
    const form = new Form();
    const inputs = [...Array.from({ length: extraInputs }, () => new Input('text')), username, password];
    username.form = password.form = form;
    const document = {
        activeElement: password,
        addEventListener(name, callback) { events[name] = callback; },
        querySelectorAll() { return inputs; },
    };
    const window = {
        location: { hostname: 'example.test' },
        crypto: webcrypto,
        webkit: { messageHandlers: { passwordManager: {
            postMessage(message) { messages.push(JSON.parse(message)); },
        } } },
        getComputedStyle() { metrics.styles++; return { display: 'block', visibility: 'visible' }; },
        addEventListener(name, callback) { events[name] = callback; },
        requestAnimationFrame(callback) { frames.push(callback); return frames.length; },
        setTimeout() { return 1; },
        clearTimeout() {},
    };
    vm.runInNewContext(source, {
        window, document, crypto: webcrypto,
        HTMLInputElement: Input, HTMLFormElement: Form, HTMLTextAreaElement: class {},
        InputEvent: class {}, Event: class {},
    });
    events.focusin({ target: password });
    const focus = messages.at(-1);
    return {
        window, events, messages, username, password, form, focus, metrics, inputs, Input,
        frame() { frames.splice(0).forEach(callback => callback()); },
    };
}

function fillRequest(fixture) {
    return {
        documentID: fixture.focus.documentID,
        usernameFieldID: fixture.focus.focus.usernameFieldID,
        passwordFieldIDs: fixture.focus.focus.passwordFieldIDs,
        username: 'person@example.test',
        password: '  secret\t\n',
    };
}

test('a fill reaches only the document that requested it', () => {
    const first = documentFixture();
    const request = fillRequest(first);
    first.window.__oraPasswordManager.fillCredentials(request);
    assert.equal(first.password.value, request.password);
    assert.equal(first.username.value, request.username);

    const next = documentFixture();
    // Even copied DOM attributes cannot authorise a fill in the new document.
    next.username.dataset = { ...first.username.dataset };
    next.password.dataset = { ...first.password.dataset };
    next.window.__oraPasswordManager.fillCredentials(request);
    assert.equal(next.password.value, '');
    assert.equal(next.username.value, '');
});

test('a fill without a document ID is refused', () => {
    const fixture = documentFixture();
    const request = fillRequest(fixture);
    delete request.documentID;
    fixture.window.__oraPasswordManager.fillCredentials(request);
    assert.equal(fixture.password.value, '');
});

test('page-generated Enter events cannot activate autofill', () => {
    const fixture = documentFixture();
    fixture.window.__oraPasswordManager.setOverlayKeyboardActive(true);
    const event = {
        key: 'Enter', target: fixture.password, isTrusted: false,
        preventDefault() {}, stopPropagation() {},
    };
    const before = fixture.messages.length;
    fixture.events.keydown(event);
    assert.equal(fixture.messages.length, before);
    fixture.events.keydown({ ...event, isTrusted: true });
    assert.equal(fixture.messages.at(-1).keyCommand, 'activate');
});

test('submitted passwords retain whitespace and their document ID', () => {
    const fixture = documentFixture();
    fixture.password.value = '  secret\t\n';
    fixture.events.submit({ target: fixture.form });
    const message = fixture.messages.at(-1);
    assert.equal(typeof message.documentID, 'string');
    assert.ok(message.documentID.length > 0);
    assert.equal(message.submit.password, fixture.password.value);
    assert.equal(message.documentID, fixture.focus.documentID);
});

test('large forms only measure fields that can supply credentials', t => {
    const fixture = documentFixture(1000);
    t.diagnostic(`focus bounds=${fixture.metrics.bounds}, styles=${fixture.metrics.styles}`);
    assert.equal(fixture.focus.focus.usernameFieldID, fixture.username.dataset.oraPasswordFieldId);
    assert.deepEqual(fixture.focus.focus.passwordFieldIDs, [fixture.password.dataset.oraPasswordFieldId]);
    assert.equal(fixture.metrics.bounds, 3);
    assert.equal(fixture.metrics.styles, 2);
    fixture.metrics.bounds = fixture.metrics.styles = 0;
    fixture.password.value = 'secret';
    fixture.username.value = 'person@example.test';
    fixture.events.submit({ target: fixture.form });
    assert.equal(fixture.messages.at(-1).submit.username, fixture.username.value);
    assert.equal(fixture.metrics.bounds, 2);
});

test('scroll bursts send the final geometry once per frame', t => {
    const fixture = documentFixture();
    fixture.metrics.bounds = fixture.metrics.styles = 0;
    for (let index = 1; index <= 100; index++) {
        fixture.password.rect.y = index;
        fixture.events.scroll();
    }
    fixture.frame();
    const updates = fixture.messages.filter(message => message.type === 'rect');
    t.diagnostic(`100 scroll events: bounds=${fixture.metrics.bounds}, styles=${fixture.metrics.styles}, messages=${updates.length}`);
    assert.equal(updates.length, 1);
    assert.equal(updates[0].rect.y, 100);
    assert.equal(fixture.metrics.bounds, 1);
    assert.equal(fixture.metrics.styles, 1);

    fixture.events.resize();
    fixture.frame();
    assert.equal(fixture.messages.filter(message => message.type === 'rect').length, 1);
    fixture.password.rect.width = 200;
    fixture.events.resize();
    fixture.frame();
    assert.equal(fixture.messages.at(-1).rect.width, 200);
});

test('irrelevant focus does no layout work and cancels pending geometry', () => {
    const fixture = documentFixture(1000);
    fixture.events.scroll();
    fixture.metrics.bounds = fixture.metrics.styles = 0;
    const before = fixture.messages.length;
    fixture.events.focusin({ target: fixture.inputs[0] });
    fixture.frame();
    assert.equal(fixture.metrics.bounds, 0);
    assert.equal(fixture.metrics.styles, 0);
    assert.equal(fixture.messages.length, before);
});

test('hidden and disabled fields preserve username and password selection', () => {
    const fixture = documentFixture();
    const hidden = new fixture.Input('password');
    hidden.rect.width = 0;
    const disabled = new fixture.Input('email');
    disabled.disabled = true;
    const nearest = new fixture.Input('email');
    fixture.inputs.splice(1, 0, hidden, nearest, disabled);
    fixture.events.focusin({ target: fixture.password });
    const focus = fixture.messages.at(-1).focus;
    assert.equal(focus.usernameFieldID, nearest.dataset.oraPasswordFieldId);
    assert.deepEqual(focus.passwordFieldIDs, [fixture.password.dataset.oraPasswordFieldId]);
    assert.equal(focus.action, 'login');
});
