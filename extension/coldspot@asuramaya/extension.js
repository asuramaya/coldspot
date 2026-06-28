// SPDX-License-Identifier: GPL-3.0-or-later
// coldspot panel pill — live meter + one-click stance control.
// Reads /run/coldspot/status.json; applies stances via the `coldspot` CLI
// (which routes privileged work through the NOPASSWD helper).
import GObject from 'gi://GObject';
import St from 'gi://St';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const STATUS = '/run/coldspot/status.json';
const COLDSPOT = 'coldspot';
const STANCES = [['open', '○'], ['lean', '◐'], ['siege', '●']];

function humanRate(bps) {
    let b = bps || 0;
    for (const u of ['B', 'K', 'M']) {
        if (b < 1024) return `${Math.round(b)} ${u}/s`;
        b /= 1024;
    }
    return `${b.toFixed(1)} G/s`;
}

const Pill = GObject.registerClass(
class Pill extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'coldspot');
        this._label = new St.Label({ text: 'coldspot', yAlign: 2 });
        this.add_child(this._label);

        // header + budget summary (read-only)
        this._header = new PopupMenu.PopupMenuItem('', { reactive: false });
        this._budget = new PopupMenu.PopupMenuItem('', { reactive: false });
        this.menu.addMenuItem(this._header);
        this.menu.addMenuItem(this._budget);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // stance switcher — click applies via the CLI (NOPASSWD helper / bpf)
        this._stanceItems = {};
        for (const [name, glyph] of STANCES) {
            const it = new PopupMenu.PopupMenuItem(`${glyph}  ${name}`);
            it.connect('activate', () => this._run([COLDSPOT, 'stance', name]));
            this._stanceItems[name] = it;
            this.menu.addMenuItem(it);
        }
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // top talkers — rebuilt each tick
        this._talkers = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._talkers);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        const reset = new PopupMenu.PopupMenuItem('Reset session meter');
        reset.connect('activate', () => this._run([COLDSPOT, 'reset']));
        this.menu.addMenuItem(reset);

        this._tick();
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            this._tick();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _run(argv) {
        try {
            Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
        } catch (_e) { /* best-effort; status will reflect the result next tick */ }
    }

    _read() {
        try {
            const [ok, bytes] = GLib.file_get_contents(STATUS);
            if (!ok) return null;
            return JSON.parse(new TextDecoder().decode(bytes));
        } catch (_e) { return null; }
    }

    _tick() {
        const st = this._read();
        if (!st) {
            this._label.text = '⊘ coldspot';
            this._label.style = '';
            return;
        }
        const stance = st.stance || 'open';
        const glyph = (STANCES.find(s => s[0] === stance) || ['', '○'])[1];
        const used = st.budget?.used_mb ?? 0;
        const limit = st.budget?.limit_mb;

        // panel pill: stance glyph + MB (heats up as the budget fills)
        this._label.text = limit ? `${glyph} ${used}/${limit} MB` : `${glyph} ${used} MB`;
        const state = st.budget?.state;
        this._label.style = state === 'over' ? 'color:#ff5555;'
            : state === 'warn' ? 'color:#ffb86c;' : '';

        const r = st.rate_bps || {};
        this._header.label.text =
            `${st.iface || '?'} · ${stance} · ↓${humanRate(r.rx)} ↑${humanRate(r.tx)}`;
        const dayMb = ((st.day?.rx_mb ?? 0) + (st.day?.tx_mb ?? 0)).toFixed(1);
        this._budget.label.text = limit
            ? `budget ${used}/${limit} MB (${st.budget?.pct ?? 0}%)   ·   today ${dayMb} MB`
            : `session ${used} MB   ·   today ${dayMb} MB`;

        for (const [name] of STANCES) {
            this._stanceItems[name].setOrnament(
                name === stance ? PopupMenu.Ornament.DOT : PopupMenu.Ornament.NONE);
        }

        this._talkers.removeAll();
        const talkers = st.talkers || [];
        if (talkers.length) {
            for (const t of talkers.slice(0, 5)) {
                this._talkers.addMenuItem(new PopupMenu.PopupMenuItem(
                    `${Number(t.mb).toFixed(1)} MB   ${t.name}`, { reactive: false }));
            }
        } else {
            this._talkers.addMenuItem(new PopupMenu.PopupMenuItem(
                'no per-app data — load the bpf core', { reactive: false }));
        }
    }

    destroy() {
        if (this._timer) {
            GLib.source_remove(this._timer);
            this._timer = null;
        }
        super.destroy();
    }
});

export default class ColdspotExtension {
    enable() {
        this._pill = new Pill();
        Main.panel.addToStatusArea('coldspot', this._pill);
    }
    disable() {
        this._pill?.destroy();
        this._pill = null;
    }
}
