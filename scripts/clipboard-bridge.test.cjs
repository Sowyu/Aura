const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const vm = require('node:vm');

const swift = readFileSync(`${__dirname}/../aura/Features/Extensions/Services/ExtensionPopupClipboard.swift`, 'utf8');
const source = swift.match(/static let polyfillSource = """([\s\S]*?)"""/)[1]
    .replace('\\(handlerName)', 'clipboard');

function fixture(start, end) {
    const messages = [], commands = [];
    const input = { tagName: 'INPUT', value: 'abcdef', selectionStart: start, selectionEnd: end };
    const document = {
        activeElement: input,
        execCommand(command) {
            commands.push(command);
            if (command !== 'delete') return false;
            input.value = input.value.slice(0, start) + input.value.slice(end);
            return true;
        },
        addEventListener() {},
    };
    const window = { webkit: { messageHandlers: { clipboard: { postMessage(text) { messages.push(text); } } } } };
    vm.runInNewContext(source, { window, document, navigator: {} });
    return { input, document, messages, commands };
}

test('cut copies and removes only the selection when the popup denies native clipboard access', () => {
    const f = fixture(1, 4);
    assert.equal(f.document.execCommand('cut'), true);
    assert.deepEqual(f.messages, ['bcd']);
    assert.deepEqual(f.commands, ['cut', 'delete']);
    assert.equal(f.input.value, 'aef');
});

test('cut without a selection does not copy the whole field or delete text', () => {
    const f = fixture(2, 2);
    assert.equal(f.document.execCommand('cut'), false);
    assert.deepEqual(f.messages, []);
    assert.deepEqual(f.commands, ['cut']);
    assert.equal(f.input.value, 'abcdef');
});
