// SPDX-License-Identifier: GPL-3.0-or-later
// coldspot panel pill — reads /run/coldspot/status.json and shows MB + stance.
import GObject from 'gi://GObject';
import St from 'gi://St';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const STATUS = '/run/coldspot/status.json';
const STANCE_GLYPH = { open: '○', lean: '◐', siege: '●' };

const Pill = GObject.registerClass(
class Pill extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'coldspot');
        this._label = new St.Label({ text: 'coldspot', yAlign: 2 });
        this.add_child(this._label);
        this._detail = new PopupMenu.PopupMenuItem('', { reactive: false });
        this.menu.addMenuItem(this._detail);
        this._tick();
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            this._tick();
            return GLib.SOURCE_CONTINUE;
        });
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
        if (!st) { this._label.text = '⊘'; return; }
        const used = st.budget?.used_mb ?? 0;
        const glyph = STANCE_GLYPH[st.stance] ?? '○';
        let text = `${glyph} ${used} MB`;
        if (st.budget?.limit_mb) text += ` / ${st.budget.limit_mb}`;
        this._label.text = text;
        // color the pill as the budget heats up
        const state = st.budget?.state;
        this._label.style = state === 'over' ? 'color:#ff5555;'
            : state === 'warn' ? 'color:#ffb86c;' : '';
        const talkers = (st.talkers ?? []).slice(0, 5)
            .map(t => `  ${t.mb} MB  ${t.name}`).join('\n');
        this._detail.label.text =
            `${st.iface}  ·  ${st.stance}\n` +
            `today: ${((st.day?.rx_mb ?? 0) + (st.day?.tx_mb ?? 0)).toFixed(1)} MB\n` +
            (talkers ? talkers : '  (no per-app data)');
    }

    destroy() {
        if (this._timer) GLib.source_remove(this._timer);
        super.destroy();
    }
});

export default class ColdspotExtension {
    enable() { this._pill = new Pill(); Main.panel.addToStatusArea('coldspot', this._pill); }
    disable() { this._pill?.destroy(); this._pill = null; }
}
