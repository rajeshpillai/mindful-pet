// Mindful Pet: the GNOME Shell half of the `gnome` window backend.
//
// A native Wayland client cannot read the global pointer, place itself at
// absolute coordinates or stay above other windows, so under GNOME the pet
// runs as an X11 client inside XWayland and goes blind whenever the pointer
// is over a native window. This extension is the way out: the Zig program
// keeps all the behaviour and the pixels, and asks the shell to do only the
// things a client cannot. Every pet window becomes one Clutter actor here.
//
// Protocol: one Unix socket at $XDG_RUNTIME_DIR/mindful-pet-shell.sock, one
// connection per pet window, newline-separated text lines both ways.
//
//   pet -> shell   hello W H [VERSION]  window size; must be the first line
//                  img BASE64           W*H*4 bytes, BGRA premultiplied (0xAARRGGBB little-endian)
//                  move X Y             screen coordinates
//                  show | hide | raise
//                  input 0|1           click-through or alpha hit-testing (v2)
//   shell -> pet   capabilities input  before screen, for v2 peers
//   shell -> pet   screen X Y W H       the primary monitor's rectangle in stage
//                                       coordinates; sent once on connect, and
//                                       when monitors change
//                  pointer X Y          whenever the pointer moves
//                  press B X Y LX LY    button 1/2/3, screen coords, window-local coords
//                  release B X Y
// Legacy peers omit VERSION: they receive screen W H for the whole stage.
//
// Every coordinate on the wire is in stage (whole-desktop) space. The pet keeps
// to one monitor, so its side of the protocol translates with the `screen`
// origin; the shell only reports where that monitor is.
//
// Clicks land on the actor only where its pixels are opaque; elsewhere it is
// made non-reactive so they fall through, which is what the X11 backend does
// with an XFixes input shape. A window that sent `input 0` (the speech bubble)
// is never reactive. The pet gets a `release` even when the drag ends off the
// actor, because the shell watches the button state itself.
//
// Nothing here may block: this code runs on the compositor's main thread, and
// a blocked write to a pet that is not reading would freeze the whole desktop
// (it did, once). Writes go through LineWriter, which drops a pet that stops
// reading; `pointer` lines are skipped while the pet is behind.
//
//     journalctl --user -f -o cat /usr/bin/gnome-shell | grep mindful-pet

import Clutter from 'gi://Clutter';
import Cogl from 'gi://Cogl';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import { LineWriter } from './writer.js';

// The monitor the pet lives on. With several monitors the stage is their
// bounding box, and its bottom edge may lie beside, not under, a screen, so
// a pet that walked along the stage floor could leave every monitor.
function screenLine(version = 1) {
    if (version < 2)
        return `screen ${global.screen_width} ${global.screen_height}`;
    const m = Main.layoutManager.primaryMonitor;
    if (m)
        return `screen ${m.x} ${m.y} ${m.width} ${m.height}`;
    return `screen 0 0 ${global.screen_width} ${global.screen_height}`;
}

const LOG = '[mindful-pet]';
const SOCKET_NAME = 'mindful-pet-shell.sock';
const TICK_MS = 33;
const BUTTON_MASKS = {
    1: Clutter.ModifierType.BUTTON1_MASK,
    2: Clutter.ModifierType.BUTTON2_MASK,
    3: Clutter.ModifierType.BUTTON3_MASK,
};

/// One connected pet window: a socket connection and the actor that shows it.
class PetWindow {
    constructor(connection, owner) {
        this._conn = connection;
        this._owner = owner;
        this._cancel = new Gio.Cancellable();
        this._writer = new LineWriter(connection.get_socket(), this._cancel, {
            onStall: reason => {
                console.log(`${LOG} pet window ${this._w}x${this._h} stopped reading (${reason}), dropping it`);
                this.destroy();
            },
        });
        this._in = new Gio.DataInputStream({ base_stream: connection.get_input_stream() });
        this._in.set_buffer_size(512 * 1024); // an `img` line for a 192px window is ~200 KB
        this._actor = null;
        this._pixels = null;
        this._w = 0;
        this._h = 0;
        this._held = 0;
        this._protocol = 1;
        this._inputEnabled = true;
        this._lastPointer = null;
        this._destroyed = false;
        this._readLine();
    }

    destroy() {
        if (this._destroyed) return;
        this._destroyed = true;
        this._cancel.cancel();
        this._writer.close();
        if (this._actor)
            console.log(`${LOG} pet window ${this._w}x${this._h} disconnected`);
        if (this._actor) {
            Main.layoutManager.removeChrome(this._actor);
            this._actor.destroy();
            this._actor = null;
        }
        try {
            this._conn.close(null);
        } catch (_e) {
            // Already gone.
        }
        this._owner._forget(this);
    }

    /// Queue a line for the pet; never blocks. A pet that stops reading is
    /// dropped by the writer's onStall.
    send(line) {
        this._writer.send(line);
    }

    _readLine() {
        this._in.read_line_async(GLib.PRIORITY_DEFAULT, this._cancel, (stream, res) => {
            let line;
            try {
                [line] = stream.read_line_finish_utf8(res);
            } catch (e) {
                // A pet that quits resets the connection; that is not an error.
                const quiet = e.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED) ||
                    e.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CONNECTION_CLOSED) ||
                    e.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.BROKEN_PIPE) ||
                    e.message.includes('reset by peer');
                if (!quiet)
                    console.log(`${LOG} read failed (${e.message})`);
                this.destroy();
                return;
            }
            if (line === null) {
                this.destroy(); // pet closed the connection
                return;
            }
            try {
                this._handle(line);
            } catch (e) {
                console.log(`${LOG} bad line "${line.slice(0, 40)}": ${e.message}`);
            }
            if (!this._destroyed)
                this._readLine();
        });
    }

    _handle(line) {
        const sp = line.indexOf(' ');
        const cmd = sp < 0 ? line : line.slice(0, sp);
        const rest = sp < 0 ? '' : line.slice(sp + 1);
        switch (cmd) {
        case 'hello': {
            const [w, h, version = 1] = rest.split(' ').map(Number);
            this._protocol = version;
            this._create(w, h);
            break;
        }
        case 'img': {
            if (!this._actor) break;
            const bytes = GLib.base64_decode(rest);
            if (bytes.length !== this._w * this._h * 4)
                throw new Error(`img has ${bytes.length} bytes, want ${this._w * this._h * 4}`);
            this._pixels = bytes;
            const image = new Clutter.Image();
            image.set_data(bytes, Cogl.PixelFormat.BGRA_8888_PRE, this._w, this._h, this._w * 4);
            this._actor.set_content(image);
            break;
        }
        case 'move': {
            const [x, y] = rest.split(' ').map(Number);
            this._actor?.set_position(x, y);
            break;
        }
        case 'show':
            this._actor?.show();
            break;
        case 'hide':
            this._actor?.hide();
            break;
        case 'raise':
            if (this._actor)
                this._actor.get_parent()?.set_child_above_sibling(this._actor, null);
            break;
        case 'input':
            this._inputEnabled = rest === '1';
            if (!this._inputEnabled && this._actor)
                this._actor.reactive = false;
            break;
        default:
            throw new Error('unknown command');
        }
    }

    _create(w, h) {
        if (this._actor || !(w > 0 && h > 0 && w <= 2048 && h <= 2048))
            throw new Error(`bad hello ${w}x${h}`);
        this._w = w;
        this._h = h;
        this._actor = new Clutter.Actor({
            name: 'mindful-pet',
            width: w,
            height: h,
            reactive: false,
            visible: false,
        });
        this._actor.set_content_scaling_filters(Clutter.ScalingFilter.NEAREST, Clutter.ScalingFilter.NEAREST);
        this._actor.connect('button-press-event', (_a, event) => {
            const [x, y] = event.get_coords();
            const [ax, ay] = this._actor.get_position();
            const button = event.get_button();
            this._held = button;
            this.send(`press ${button} ${Math.round(x)} ${Math.round(y)} ${Math.round(x - ax)} ${Math.round(y - ay)}`);
            return Clutter.EVENT_STOP;
        });
        this._actor.connect('button-release-event', (_a, event) => {
            const [x, y] = event.get_coords();
            this._release(event.get_button(), x, y);
            return Clutter.EVENT_STOP;
        });
        // Above windows, hidden while a fullscreen window has focus.
        Main.layoutManager.addTopChrome(this._actor, { affectsInputRegion: false });
        if (this._protocol >= 2)
            this.send('capabilities input');
        this.send(screenLine(this._protocol));
        if (this._destroyed) return;
        this._owner._ensureTick();
        console.log(`${LOG} pet window ${w}x${h} connected (${this._owner._windows.size} open)`);
    }

    _release(button, x, y) {
        if (this._held !== button) return;
        this._held = 0;
        this.send(`release ${button} ${Math.round(x)} ${Math.round(y)}`);
    }

    /// Called ~30 times a second while any pet is connected.
    tick(px, py, mods) {
        if (!this._actor) return;
        // Pointer updates are best effort: only while the pet is keeping up,
        // so a slow pet gets the latest position later instead of a backlog.
        if (this._writer.pending === 0 &&
            (!this._lastPointer || this._lastPointer[0] !== px || this._lastPointer[1] !== py)) {
            this._lastPointer = [px, py];
            this.send(`pointer ${px} ${py}`);
        }
        // A drag that ends off the actor never delivers a release event to it.
        if (this._held && !(mods & BUTTON_MASKS[this._held]))
            this._release(this._held, px, py);
        if (this._actor)
            this._actor.reactive = this._inputEnabled && (this._held !== 0 || this._opaqueAt(px, py));
    }

    _opaqueAt(px, py) {
        if (!this._pixels || !this._actor.visible) return false;
        const [ax, ay] = this._actor.get_position();
        const lx = Math.floor(px - ax);
        const ly = Math.floor(py - ay);
        if (lx < 0 || ly < 0 || lx >= this._w || ly >= this._h) return false;
        return this._pixels[(ly * this._w + lx) * 4 + 3] !== 0;
    }

    screenChanged() {
        this.send(screenLine(this._protocol));
    }
}

export default class MindfulPetExtension extends Extension {
    enable() {
        this._windows = new Set();
        this._tickId = 0;
        this._path = GLib.build_filenamev([GLib.get_user_runtime_dir(), SOCKET_NAME]);
        GLib.unlink(this._path); // a stale socket from a crashed shell would block bind

        this._service = new Gio.SocketService();
        this._service.add_address(
            Gio.UnixSocketAddress.new(this._path),
            Gio.SocketType.STREAM,
            Gio.SocketProtocol.DEFAULT,
            null
        );
        this._service.connect('incoming', (_service, connection) => {
            this._windows.add(new PetWindow(connection, this));
            return true;
        });
        this._service.start();

        this._monitorsId = Main.layoutManager.connect('monitors-changed', () => {
            for (const w of this._windows) w.screenChanged();
        });
        console.log(`${LOG} enabled, listening on ${this._path}`);
    }

    disable() {
        if (this._monitorsId) {
            Main.layoutManager.disconnect(this._monitorsId);
            this._monitorsId = 0;
        }
        if (this._tickId) {
            GLib.source_remove(this._tickId);
            this._tickId = 0;
        }
        for (const w of [...this._windows]) w.destroy();
        this._windows.clear();
        if (this._service) {
            this._service.stop();
            this._service.close();
            this._service = null;
        }
        GLib.unlink(this._path);
        console.log(`${LOG} disabled`);
    }

    _forget(window) {
        this._windows.delete(window);
        if (this._windows.size === 0 && this._tickId) {
            GLib.source_remove(this._tickId);
            this._tickId = 0;
        }
    }

    _ensureTick() {
        if (this._tickId) return;
        this._tickId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, TICK_MS, () => {
            const [px, py, mods] = global.get_pointer();
            for (const w of this._windows) w.tick(px, py, mods);
            return GLib.SOURCE_CONTINUE;
        });
    }
}
