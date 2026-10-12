// Exercise the real protocol and hit-testing code without a desktop session.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

class Actor {
    constructor(props) { Object.assign(this, props); }
    set_content_scaling_filters() {}
    connect() {}
    get_position() { return [0, 0]; }
}
const layoutManager = {
    primaryMonitor: { x: 710, y: 1080, width: 1366, height: 768 },
    addTopChrome() {},
};
const context = {
    Clutter: { Actor, ScalingFilter: { NEAREST: 0 }, ModifierType: {} },
    Main: { layoutManager },
    global: { screen_width: 2076, screen_height: 1848 },
    console: { log() {} },
};
vm.createContext(context);
const source = fs.readFileSync(new URL('../gnome-extension/mindful-pet@rajeshpillai.github.io/extension.js', import.meta.url), 'utf8');
const body = source.slice(source.indexOf('function screenLine'), source.indexOf('export default class'));
vm.runInContext(body + '\nthis.PetWindow = PetWindow;', context);
function window() {
    const w = Object.create(context.PetWindow.prototype);
    Object.assign(w, {
        _actor: null, _protocol: 1, _inputEnabled: true, _destroyed: false,
        _held: 0, _writer: { pending: 0 }, _lastPointer: [0, 0],
        _owner: { _windows: new Set(), _ensureTick() {} },
        lines: [], send(line) { this.lines.push(line); },
    });
    return w;
}
const legacy = window();
legacy._handle('hello 64 64');
assert.deepEqual(legacy.lines, ['screen 2076 1848']);
const current = window();
current._handle('hello 64 64 2');
assert.deepEqual(current.lines, ['capabilities input', 'screen 710 1080 1366 768']);
current._actor.visible = true;
current._pixels = new Uint8Array(64 * 64 * 4);
current._pixels[3] = 255;
current.tick(0, 0, 0);
assert.equal(current._actor.reactive, true);
current._handle('input 0');
current.tick(0, 0, 0);
assert.equal(current._actor.reactive, false, 'bubble must stay click-through on opaque pixels');
current._handle('input 1');
current.tick(0, 0, 0);
assert.equal(current._actor.reactive, true);
current._lastPointer = [1, 0];
current.tick(1, 0, 0);
assert.equal(current._actor.reactive, false, 'transparent pixels must pass clicks through');
layoutManager.primaryMonitor = { x: 0, y: 0, width: 800, height: 600 };
current.screenChanged();
legacy.screenChanged();
assert.equal(current.lines.at(-1), 'screen 0 0 800 600');
assert.equal(legacy.lines.at(-1), 'screen 2076 1848');
console.log('Extension regression checks passed (legacy/v2, monitor changes, click-through).');
