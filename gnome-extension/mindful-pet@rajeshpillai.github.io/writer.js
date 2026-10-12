// Ordered, non-blocking line writer for one pet connection.
//
// Everything in a GNOME Shell extension runs on the compositor's main thread,
// so a write that blocks there freezes the whole desktop until the peer reads.
// A pet that is busy, stopped in a debugger, or simply not reading one of its
// sockets must therefore never be able to stall the shell. This writer queues
// bytes, writes whatever the socket accepts right now, waits for writability
// through the main loop for the rest, and gives up on the peer once `limit`
// bytes are waiting: at that point the peer is not reading at all.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GLibUnix from 'gi://GLibUnix';

export class LineWriter {
    /// `socket` is the connection's Gio.Socket (the output stream's
    /// non-blocking calls are not reachable from GJS, the socket's are).
    /// `onStall(reason)` is called once, after the writer has closed itself,
    /// when the peer stops reading or the socket breaks.
    constructor(socket, cancellable, { limit = 64 * 1024, onStall = null } = {}) {
        this._socket = socket;
        this._cancel = cancellable;
        this._limit = limit;
        this._onStall = onStall;
        this._encoder = new TextEncoder();
        this._chunks = [];
        this._pending = 0;
        this._watch = 0; // main-loop source id while waiting for POLLOUT
        this._closed = false;
    }

    /// Bytes queued and not yet accepted by the socket. Zero means the peer
    /// is keeping up, which is when best-effort lines are worth sending.
    get pending() {
        return this._pending;
    }

    /// Queue one line (the newline is added). Returns false when the line was
    /// dropped because the writer is closed or the peer has stalled.
    send(line) {
        if (this._closed)
            return false;
        const bytes = this._encoder.encode(line + '\n');
        if (this._pending + bytes.length > this._limit) {
            this._stall(`peer has not read ${this._pending} bytes`);
            return false;
        }
        this._chunks.push(bytes);
        this._pending += bytes.length;
        if (!this._watch)
            this._flush();
        return true;
    }

    close() {
        this._closed = true;
        if (this._watch) {
            GLib.source_remove(this._watch);
            this._watch = 0;
        }
        this._chunks = [];
        this._pending = 0;
    }

    _flush() {
        while (!this._closed && this._chunks.length > 0) {
            const head = this._chunks[0];
            let n;
            try {
                n = this._socket.send_with_blocking(head, false, this._cancel);
            } catch (e) {
                if (e.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.WOULD_BLOCK)) {
                    this._waitWritable();
                    return;
                }
                this._stall(e.message);
                return;
            }
            this._pending -= n;
            if (n < head.length)
                this._chunks[0] = head.slice(n);
            else
                this._chunks.shift();
        }
    }

    _waitWritable() {
        this._watch = GLibUnix.fd_add_full(GLib.PRIORITY_DEFAULT, this._socket.get_fd(),
            GLib.IOCondition.OUT | GLib.IOCondition.HUP | GLib.IOCondition.ERR, () => {
                this._watch = 0;
                this._flush();
                return GLib.SOURCE_REMOVE;
            });
    }

    _stall(reason) {
        this.close();
        this._onStall?.(reason);
    }
}
