// SPDX-License-Identifier: GPL-3.0-or-later
// coldspot panel pill — the cockpit. Live ↑/↓ meter, governed-state badge, the
// active cap, one-tap stance + warm (uncap) control, and notifications when the
// link goes cold or an app misbehaves. Reads /run/coldspot/status.json; applies
// actions via the `coldspot` CLI (NOPASSWD helper / bpf core).
import GObject from 'gi://GObject';
import St from 'gi://St';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const STATUS = '/run/coldspot/status.json';
const COLDSPOT = 'coldspot';
// glyph per stance; cold is the metered default (snowflake)
const STANCES = [['open', '○'], ['lean', '◐'], ['cold', '❄'], ['siege', '●']];
const LIMITS = [['1mbps', '1 Mbit/s'], ['500kbps', '500 kbit/s'], ['off', 'no cap']];

function humanRate(bps) {
    let b = bps || 0;
    for (const u of ['B', 'K', 'M']) {
        if (b < 1024) return `${Math.round(b)} ${u}/s`;
        b /= 1024;
    }
    return `${b.toFixed(1)} G/s`;
}

function humanBits(bits) {
    let b = bits || 0;
    for (const u of ['bit', 'kbit', 'Mbit']) {
        if (b < 1000) return `${Math.round(b)} ${u}/s`;
        b /= 1000;
    }
    return `${b.toFixed(1)} Gbit/s`;
}

const Pill = GObject.registerClass(
class Pill extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'coldspot');
        this._label = new St.Label({ text: 'coldspot', yAlign: 2 });
        this.add_child(this._label);

        // read-only summary lines
        this._header = new PopupMenu.PopupMenuItem('', { reactive: false });
        this._budget = new PopupMenu.PopupMenuItem('', { reactive: false });
        this._govern = new PopupMenu.PopupMenuItem('', { reactive: false });
        this.menu.addMenuItem(this._header);
        this.menu.addMenuItem(this._budget);
        this.menu.addMenuItem(this._govern);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // stance switcher — one tap, current is dotted
        this._stanceItems = {};
        for (const [name, glyph] of STANCES) {
            const it = new PopupMenu.PopupMenuItem(`${glyph}  ${name}`);
            it.connect('activate', () => this._run([COLDSPOT, name]));
            this._stanceItems[name] = it;
            this.menu.addMenuItem(it);
        }
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // talkers — tap one to warm it (full speed / priority under cold)
        this._talkHint = new PopupMenu.PopupMenuItem('top apps — tap to warm', { reactive: false });
        this.menu.addMenuItem(this._talkHint);
        this._talkers = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._talkers);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // quick speed cap
        const limit = new PopupMenu.PopupSubMenuMenuItem('Speed cap');
        for (const [arg, label] of LIMITS) {
            const it = new PopupMenu.PopupMenuItem(label);
            it.connect('activate', () => this._run([COLDSPOT, 'limit', arg]));
            limit.menu.addMenuItem(it);
        }
        this.menu.addMenuItem(limit);

        const open = new PopupMenu.PopupMenuItem('Release all (open)');
        open.connect('activate', () => this._run([COLDSPOT, 'open']));
        this.menu.addMenuItem(open);

        const reset = new PopupMenu.PopupMenuItem('Reset session meter');
        reset.connect('activate', () => this._run([COLDSPOT, 'reset']));
        this.menu.addMenuItem(reset);

        // notification de-dup state
        this._prevGoverned = false;
        this._prevBudgetState = 'off';
        this._seenAdvice = new Set();

        this._tick();
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            this._tick();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _run(argv) {
        try {
            Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
        } catch (_e) { /* best-effort; status reflects the result next tick */ }
    }

    _read() {
        try {
            const [ok, bytes] = GLib.file_get_contents(STATUS);
            if (!ok) return null;
            return JSON.parse(new TextDecoder().decode(bytes));
        } catch (_e) { return null; }
    }

    _notify(title, body) {
        try { Main.notify(title, body); } catch (_e) { /* no tray; skip */ }
    }

    _checkNotifications(st) {
        // link just went cold automatically
        if (st.governed && !this._prevGoverned) {
            this._notify('coldspot: metered link',
                'Governing (cold) — total speed capped. Tap an app in the pill to ' +
                'give it priority, or use Release all.');
        }
        this._prevGoverned = !!st.governed;

        // budget crossed into warn/over
        const bs = st.budget?.state || 'off';
        if (bs !== this._prevBudgetState && (bs === 'warn' || bs === 'over')) {
            const u = st.budget?.used_mb ?? 0;
            const l = st.budget?.limit_mb ?? 0;
            this._notify(bs === 'over' ? 'coldspot: budget exceeded' : 'coldspot: budget warning',
                `${u}/${l} MB used.`);
        }
        this._prevBudgetState = bs;

        // a new advisory / anomaly appeared
        for (const a of st.advice || []) {
            const key = `${a.app}:${a.kind}`;
            if (!this._seenAdvice.has(key)) {
                this._seenAdvice.add(key);
                this._notify('coldspot', a.hint || `${a.app}: ${a.kind}`);
            }
        }
        if (this._seenAdvice.size > 64) this._seenAdvice.clear();
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

        // panel pill: stance glyph + MB; heats up as the budget fills, blue when cold
        this._label.text = limit ? `${glyph} ${used}/${limit} MB` : `${glyph} ${used} MB`;
        const state = st.budget?.state;
        this._label.style = state === 'over' ? 'color:#ff5555;'
            : state === 'warn' ? 'color:#ffb86c;'
            : (stance === 'cold') ? 'color:#8be9fd;' : '';

        const r = st.rate_bps || {};
        const conn = st.connection || st.iface || '?';
        const m = st.metered ? ' ·metered' : '';
        this._header.label.text = `${conn}${m} · ${stance} · ↓${humanRate(r.rx)} ↑${humanRate(r.tx)}`;

        const dayMb = ((st.day?.rx_mb ?? 0) + (st.day?.tx_mb ?? 0)).toFixed(1);
        let bline = limit
            ? `budget ${used}/${limit} MB (${st.budget?.pct ?? 0}%)   ·   today ${dayMb} MB`
            : `session ${used} MB   ·   today ${dayMb} MB`;
        const eta = st.budget?.eta;
        if (eta && state !== 'over')
            bline += `   ·   cap ~${GLib.DateTime.new_from_unix_local(eta).format('%H:%M')}`;
        this._budget.label.text = bline;

        // governed badge + active cap
        if (st.governed) {
            const cap = st.cap_bits ? ` ≤ ${humanBits(st.cap_bits)}` : '';
            this._govern.label.text = `❄ auto-cold${cap} — warm a task to prioritize it`;
            this._govern.visible = true;
        } else if (st.auto_govern && st.metered) {
            this._govern.label.text = 'auto-govern armed (will cold this metered link)';
            this._govern.visible = true;
        } else {
            this._govern.visible = false;
        }

        for (const [name] of STANCES) {
            this._stanceItems[name].setOrnament(
                name === stance ? PopupMenu.Ornament.DOT : PopupMenu.Ornament.NONE);
        }

        this._talkers.removeAll();
        const talkers = st.talkers || [];
        if (talkers.length) {
            for (const t of talkers.slice(0, 6)) {
                const up = Number(t.tx_mb ?? 0).toFixed(1);
                const dn = Number(t.rx_mb ?? 0).toFixed(1);
                const it = new PopupMenu.PopupMenuItem(`↑${up} ↓${dn} MB   ${t.name}`);
                it.connect('activate', () => this._run([COLDSPOT, 'uncap', t.name]));
                this._talkers.addMenuItem(it);
            }
        } else {
            this._talkers.addMenuItem(new PopupMenu.PopupMenuItem(
                'no per-app data — load the bpf core', { reactive: false }));
        }

        this._checkNotifications(st);
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
