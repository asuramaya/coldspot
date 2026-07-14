// SPDX-License-Identifier: GPL-3.0-or-later
// coldspot panel pill — the cockpit. Live ↑/↓ meter, governed/stabilized-state
// badge, per-network policy, multi-radio health + steer/bond control, one-tap
// stance + warm (uncap), and notifications when the link changes state or an
// app misbehaves. Reads /run/coldspot/status.json; applies actions via the
// `coldspot` CLI, which talks to the (already-root) daemon over its control
// socket — the pill never needs sudo, ever.
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
// glyph per per-network policy (open/cold shared with stance; stabilize gets
// its own — a network can be scarce (cold) or bad (stabilize), or neither)
const POLICIES = [['open', '○'], ['cold', '❄'], ['stabilize', '≈']];
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

// the layer-1/2 axis in the pill: a 4-bar signal glyph by health score
const SIG_BARS = { good: '▂▄▆█', ok: '▂▄▆_', weak: '▂▄__',
                   bad: '▂___', down: '____', unknown: '____' };

function activeLink(st) {
    const links = st.links || {};
    for (const k in links) if (links[k].active) return links[k];
    return null;
}

// same shape as daemon_stabilize()'s cap sizing (PHY × 0.5), so the pill can
// show an honest approximate cap even though status.json doesn't publish one
// (stabilize's cap is derived, not stored — this mirrors the same formula).
function stabilizeCapHint(h) {
    if (!h) return '';
    const rx = h.rx_mbps, tx = h.tx_mbps;
    if (!rx && !tx) return '';
    const dl = Math.round((rx || tx) * 1e6 * 0.5);
    const ul = Math.round((tx || rx) * 1e6 * 0.5);
    return ` ≈ down${humanBits(dl)}/up${humanBits(ul)}`;
}

const Pill = GObject.registerClass(
class Pill extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'coldspot');
        this._label = new St.Label({ text: 'coldspot', yAlign: 2 });
        this.add_child(this._label);

        // read-only summary lines
        this._header = new PopupMenu.PopupMenuItem('', { reactive: false });
        this._network = new PopupMenu.PopupMenuItem('', { reactive: false });
        this._budget = new PopupMenu.PopupMenuItem('', { reactive: false });
        this._govern = new PopupMenu.PopupMenuItem('', { reactive: false });
        this.menu.addMenuItem(this._header);
        this.menu.addMenuItem(this._network);
        this.menu.addMenuItem(this._budget);
        this.menu.addMenuItem(this._govern);

        // multi-radio: link health + steer + bond — only shown with 2+ radios
        this._radioSep = new PopupMenu.PopupSeparatorMenuItem();
        this.menu.addMenuItem(this._radioSep);
        this._radioHint = new PopupMenu.PopupMenuItem('radios — tap one to steer', { reactive: false });
        this.menu.addMenuItem(this._radioHint);
        this._radios = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._radios);

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

        // per-network policy — coldspot's own memory (v0.3+): what it does on
        // THIS network. Separate axis from stance: a stance is a one-shot
        // override until the next roam; a policy is what auto-applies every
        // time you're back on this network.
        const policy = new PopupMenu.PopupSubMenuMenuItem('Network policy (this network)');
        this._policyItems = {};
        for (const [name, glyph] of POLICIES) {
            const it = new PopupMenu.PopupMenuItem(`${glyph}  ${name}`);
            it.connect('activate', () => this._run([COLDSPOT, 'here', name]));
            this._policyItems[name] = it;
            policy.menu.addMenuItem(it);
        }
        this.menu.addMenuItem(policy);
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
        open.connect('activate', () => this._releaseAll());
        this.menu.addMenuItem(open);

        const reset = new PopupMenu.PopupMenuItem('Reset session meter');
        reset.connect('activate', () => this._run([COLDSPOT, 'reset']));
        this.menu.addMenuItem(reset);

        // notification de-dup state
        this._prevGoverned = false;
        this._prevStabilized = false;
        this._prevPrimary = null;
        this._prevBonded = '';
        this._prevBudgetState = 'off';
        this._seenAdvice = new Set();
        this._lastStabilizeIface = null;

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

    // "Release all" should really mean all: also drop a stabilize overlay,
    // which `coldspot open` alone doesn't touch (stance and stabilize are
    // independent axes — see the daemon's policy reconciler).
    _releaseAll() {
        this._run([COLDSPOT, 'open']);
        if (this._lastStabilizeIface) this._run([COLDSPOT, 'stabilize', 'off']);
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

        // a weak/lossy link just got smoothed (or stopped being smoothed)
        if (st.stabilized && !this._prevStabilized) {
            this._notify('coldspot: weak link', 'Stabilizing — ack-filter + download AQM engaged.');
        } else if (!st.stabilized && this._prevStabilized) {
            this._notify('coldspot: link stable', 'Stabilize released.');
        }
        this._prevStabilized = !!st.stabilized;

        // auto-steer (or a manual `coldspot steer`) moved the primary radio
        if (this._prevPrimary !== null && st.primary && st.primary !== this._prevPrimary) {
            this._notify('coldspot: steered', `Primary link is now ${st.primary}.`);
        }
        if (st.primary) this._prevPrimary = st.primary;

        // bonding engaged/changed/disengaged
        const bondedKey = (st.bonded || []).slice().sort().join(',');
        if (bondedKey !== this._prevBonded) {
            if (bondedKey) this._notify('coldspot: bonded', `Aggregating: ${bondedKey}.`);
            else if (this._prevBonded) this._notify('coldspot: unbonded', 'Back to single-link routing.');
        }
        this._prevBonded = bondedKey;

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
        const links = st.links || {};
        const lk = activeLink(st);
        const sig = (lk && lk.signal_dbm != null)
            ? `${SIG_BARS[lk.score] || '____'} ${lk.signal_dbm}dBm  ` : '';
        // if a healthier radio is sitting idle, say so right in the header —
        // the same nudge `coldspot link` prints on the CLI
        const better = (st.best_link && st.primary && st.best_link !== st.primary)
            ? `  ⚠ ${st.best_link} looks healthier` : '';
        this._header.label.text = `${sig}${conn}${m} · ${stance} · ↓${humanRate(r.rx)} ↑${humanRate(r.tx)}${better}`;

        // per-network policy line — coldspot's own memory for this SSID
        if (st.network && st.network !== '?') {
            const rec = (st.policies || {})[st.network];
            const src = rec?.source ? ` (${rec.source})` : '';
            this._network.label.text = `on ${st.network} → ${st.policy || 'open'}${src}`;
            this._network.visible = true;
        } else {
            this._network.visible = false;
        }

        const dayMb = ((st.day?.rx_mb ?? 0) + (st.day?.tx_mb ?? 0)).toFixed(1);
        let bline = limit
            ? `budget ${used}/${limit} MB (${st.budget?.pct ?? 0}%)   ·   today ${dayMb} MB`
            : `session ${used} MB   ·   today ${dayMb} MB`;
        const eta = st.budget?.eta;
        if (eta && state !== 'over')
            bline += `   ·   cap ~${GLib.DateTime.new_from_unix_local(eta).format('%H:%M')}`;
        this._budget.label.text = bline;

        // governed (cold) / stabilized (weak-link) badge — two independent
        // overlays the reconciler can apply; show whichever is live
        this._lastStabilizeIface = null;
        if (st.governed) {
            const cap = st.cap_bits ? ` ≤ ${humanBits(st.cap_bits)}` : '';
            this._govern.label.text = `❄ auto-cold${cap} — warm a task to prioritize it`;
            this._govern.visible = true;
        } else if (st.stabilized) {
            const sif = st.primary;
            this._lastStabilizeIface = sif;
            const cap = stabilizeCapHint(links[sif]);
            this._govern.label.text = `≈ stabilized on ${sif}${cap}`;
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
        for (const [name] of POLICIES) {
            this._policyItems[name].setOrnament(
                name === (st.policy || 'open') ? PopupMenu.Ornament.DOT : PopupMenu.Ornament.NONE);
        }

        // multi-radio: link health board + steer/bond — only worth a whole
        // section once there's actually more than one radio to manage
        const linkEntries = Object.entries(links)
            .sort((a, b) => (b[1].active ? 1 : 0) - (a[1].active ? 1 : 0) || a[0].localeCompare(b[0]));
        const showRadios = linkEntries.length >= 2;
        this._radioSep.visible = showRadios;
        this._radioHint.visible = showRadios;
        this._radios.removeAll();
        if (showRadios) {
            for (const [ifc, h] of linkEntries) {
                let text, reactive = false;
                if (!h.connected) {
                    text = `○ ${ifc}  disconnected`;
                } else {
                    const bars = SIG_BARS[h.score] || '____';
                    const sigTxt = h.signal_dbm != null ? `${h.signal_dbm}dBm` : '? dBm';
                    const band = h.band ? `${h.band}/ch${h.channel ?? '?'}` : '';
                    const mark = h.active ? '●' : '○';
                    text = `${mark} ${ifc}  ${h.score || '?'} ${sigTxt} ${bars}  ${band}`;
                    reactive = !h.active; // active radio: nothing to do; tap another to steer to it
                }
                const it = new PopupMenu.PopupMenuItem(text, { reactive });
                if (reactive) it.connect('activate', () => this._run([COLDSPOT, 'steer', ifc]));
                this._radios.addMenuItem(it);
            }
            const steerAuto = new PopupMenu.PopupMenuItem(
                `→ steer: auto (healthiest now)${st.auto_steer ? '  [auto-steer on]' : ''}`);
            steerAuto.connect('activate', () => this._run([COLDSPOT, 'steer', 'auto']));
            this._radios.addMenuItem(steerAuto);

            const bonded = st.bonded || [];
            const bondable = st.bondable || [];
            if (bonded.length) {
                this._radios.addMenuItem(new PopupMenu.PopupMenuItem(
                    `⇄ bonded: ${bonded.join(', ')}`, { reactive: false }));
                const off = new PopupMenu.PopupMenuItem('⇄ bond: off');
                off.connect('activate', () => this._run([COLDSPOT, 'bond', 'off']));
                this._radios.addMenuItem(off);
            } else if (bondable.length >= 2) {
                const names = bondable.map(([i, w]) => `${i} w${w}`).join(', ');
                this._radios.addMenuItem(new PopupMenu.PopupMenuItem(
                    `⇄ bondable: ${names}`, { reactive: false }));
                const auto = new PopupMenu.PopupMenuItem('⇄ bond: auto');
                auto.connect('activate', () => this._run([COLDSPOT, 'bond', 'auto']));
                this._radios.addMenuItem(auto);
            }
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
