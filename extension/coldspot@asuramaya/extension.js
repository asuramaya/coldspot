// SPDX-License-Identifier: GPL-3.0-or-later
// coldspot panel pill — the cockpit. Live ↑/↓ meter, governed/stabilized-state
// badge, per-network policy, link health (signal + gateway ping/jitter/loss —
// useful at home as much as on a hotspot), multi-radio steer/bond control,
// one-tap stance + warm (uncap), and notifications when the link changes
// state or an app misbehaves. Reads /run/coldspot/status.json; applies
// actions via the `coldspot` CLI, which talks to the (already-root) daemon
// over its control socket — the pill never needs sudo, ever.
import GObject from 'gi://GObject';
import St from 'gi://St';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {QuickMenuToggle, SystemIndicator} from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const STATUS = '/run/coldspot/status.json';
const COLDSPOT = 'coldspot';
// glyph per stance; cold is the metered default (snowflake)
const STANCES = [['open', '○'], ['lean', '◐'], ['cold', '❄'], ['siege', '●']];
// glyph per per-network policy (open/cold shared with stance; stabilize gets
// its own — a network can be scarce (cold) or bad (stabilize), or neither)
const POLICIES = [['open', '○'], ['cold', '❄'], ['stabilize', '≈']];
const LIMITS = [['1mbps', '1 Mbit/s'], ['500kbps', '500 kbit/s'], ['off', 'no cap']];

// shared family palette (FAMILY.md doctrine #12) — same five colors as every
// other pill in the kast/phanspeed/coldspot/ByeByte/RAMstein family.
const PALETTE = { ACCENT: '#b9acff', DIM: '#9aa0a6', GOOD: '#4caf50',
                   WARN: '#ffbb33', BAD: '#ff5b5b' };
const VERSION_FILE = '/usr/local/share/coldspot/VERSION';

// chip styling for the stance row (kast/phanspeed idiom)
const CHIP = 'border-radius:13px; padding:6px 10px; margin:0 2px; color:#dedde6;'
    + ' background-color:rgba(255,255,255,0.07);';
const CHIP_ON = 'border-radius:13px; padding:6px 10px; margin:0 2px; color:#ffffff;'
    + ' font-weight:bold; background-color:#5b50a8;';

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

// real icon per signal score, for the tile itself — verified present in
// Adwaita on this shell version (network-wireless-signal-* + offline/plain).
const SIG_ICON = {
    good: 'network-wireless-signal-excellent-symbolic',
    ok: 'network-wireless-signal-good-symbolic',
    weak: 'network-wireless-signal-weak-symbolic',
    bad: 'network-wireless-signal-none-symbolic',
    down: 'network-wireless-offline-symbolic',
    unknown: 'network-wireless-symbolic',
};
const DEFAULT_ICON = 'network-wireless-symbolic';
// a hard governance stance dominates the icon over live signal (cold/siege
// are deliberate, sticky states worth seeing at a glance); lean/open defer
// to the live signal-quality icon below since they're not a hard block.
const STANCE_ICON = { cold: 'weather-snow-symbolic', siege: 'changes-prevent-symbolic' };

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

const ColdspotToggle = GObject.registerClass(
class ColdspotToggle extends QuickMenuToggle {
    _init() {
        super._init({ title: 'coldspot', iconName: DEFAULT_ICON, toggleMode: true });
        this.menu.setHeader(DEFAULT_ICON, 'coldspot', 'Cold-link cockpit');

        // link health — signal + gateway ping/jitter/loss, always visible.
        // This is the "at a glance" readout: as meaningful on an unmetered
        // home network (is the wifi itself laggy?) as on a metered hotspot.
        this._linkItem = new PopupMenu.PopupMenuItem('', { reactive: false });
        this.menu.addMenuItem(this._linkItem);

        // per-network policy — coldspot's own memory of what it does HERE.
        this._network = new PopupMenu.PopupMenuItem('', { reactive: false });
        this.menu.addMenuItem(this._network);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // stance switcher — chips, one tap, current one lit
        this._stanceItems = {};
        const stanceRow = new PopupMenu.PopupBaseMenuItem({ reactive: false, can_focus: false });
        const stanceBox = new St.BoxLayout({ x_expand: true });
        for (const [name, glyph] of STANCES) {
            const btn = new St.Button({ label: glyph, x_expand: true, can_focus: true, style: CHIP });
            btn.connect('clicked', () => this._run([COLDSPOT, name]));
            stanceBox.add_child(btn);
            this._stanceItems[name] = btn;
        }
        stanceRow.add_child(stanceBox);
        this.menu.addMenuItem(stanceRow);
        this._govern = new PopupMenu.PopupMenuItem('', { reactive: false });
        this.menu.addMenuItem(this._govern);
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

        // history — per-connection today/month totals (`coldspot history`,
        // previously CLI-only: the daemon already tracks and publishes this,
        // the pill just never surfaced it).
        const history = new PopupMenu.PopupSubMenuMenuItem('History (per network)');
        this._historyItem = history;
        this.menu.addMenuItem(history);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // multi-radio: link health + steer + bond — only shown with 2+ radios
        this._radioSep = new PopupMenu.PopupSeparatorMenuItem();
        this.menu.addMenuItem(this._radioSep);
        this._radioHint = new PopupMenu.PopupMenuItem('radios — tap one to steer', { reactive: false });
        this.menu.addMenuItem(this._radioHint);
        this._radios = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._radios);

        // talkers — tap one to warm it (full speed / priority under cold)
        this._talkHint = new PopupMenu.PopupMenuItem('top apps — tap to warm', { reactive: false });
        this.menu.addMenuItem(this._talkHint);
        this._talkers = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._talkers);

        // ledger — today's PERSISTED per-app totals (`coldspot ledger`),
        // distinct from the live talkers above: survives roams/reloads, so an
        // app that finished an hour ago still shows its share of today.
        const ledger = new PopupMenu.PopupSubMenuMenuItem("Today's ledger (all apps)");
        this._ledgerItem = ledger;
        this.menu.addMenuItem(ledger);
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

        // dim version footer (shared family idiom) — read once, doesn't change
        // at runtime, so no need to touch this again in refresh().
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._footer = new PopupMenu.PopupMenuItem(`coldspot ${this._readVersion()}`,
            { reactive: false });
        this._footer.label.style = `color:${PALETTE.DIM}; font-size:0.85em;`;
        this.menu.addMenuItem(this._footer);

        // tap the pill body: quick engage/release, same two states the tile's
        // checked reflects — mirrors how a Wi-Fi/Bluetooth tile's tap works.
        this._stance = 'open';
        this._lastStabilizeIface = null;
        this.connect('clicked', () => {
            if (this._stance === 'open') this._run([COLDSPOT, 'cold']);
            else this._releaseAll();
        });

        // notification de-dup state
        this._prevGoverned = false;
        this._prevStabilized = false;
        this._prevPrimary = null;
        this._prevBonded = '';
        this._prevBudgetState = 'off';
        this._seenAdvice = new Set();

        this.refresh();
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            this.refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _readVersion() {
        try {
            const [ok, bytes] = GLib.file_get_contents(VERSION_FILE);
            if (ok) return new TextDecoder().decode(bytes).trim();
        } catch (_e) { /* fall through */ }
        return 'dev';
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

    refresh() {
        const st = this._read();
        if (!st) {
            this.subtitle = 'daemon offline';
            this.iconName = DEFAULT_ICON;
            this.checked = false;
            this._linkItem.label.text = 'no data';
            this._network.visible = false;
            this._govern.visible = false;
            return;
        }
        const stance = st.stance || 'open';
        this._stance = stance;
        const glyph = (STANCES.find(s => s[0] === stance) || ['', '○'])[1];
        const used = st.budget?.used_mb ?? 0;
        const limit = st.budget?.limit_mb;
        const state = st.budget?.state;
        const r = st.rate_bps || {};
        const lk = activeLink(st);

        // tile: icon — a hard stance (cold/siege) wins; otherwise the live
        // signal-quality icon, which is exactly as informative at home as on
        // a hotspot (that's the whole point of surfacing it here).
        this.iconName = STANCE_ICON[stance] || SIG_ICON[(lk && lk.score) || 'unknown'] || DEFAULT_ICON;
        this.checked = stance !== 'open' || !!st.governed || !!st.stabilized;

        // tile: subtitle — budget/stance framing once something's actually
        // engaged (governed, capped, or a manual non-open stance); otherwise
        // (the common "open, at home" case) lead with link health instead of
        // a meaningless "0 MB" budget line.
        let subtitle;
        if (st.governed) {
            const cap = st.cap_bits ? ` ≤${humanBits(st.cap_bits)}` : '';
            subtitle = `❄ auto-cold${cap}`;
        } else if (limit) {
            subtitle = `${glyph} ${used}/${limit} MB`;
        } else if (stance !== 'open') {
            subtitle = st.stabilized ? '≈ stabilized' : `${glyph} ${stance}`;
        } else {
            const sig = (lk && lk.signal_dbm != null) ? `${lk.signal_dbm}dBm` : '';
            const lat = (st.latency_ms != null) ? `${Math.round(st.latency_ms)}ms` : '';
            subtitle = [sig, lat].filter(Boolean).join(' · ')
                || `↓${humanRate(r.rx)} ↑${humanRate(r.tx)}`;
        }
        this.subtitle = subtitle;
        this.menu.setHeader(this.iconName, 'coldspot',
            `${st.connection || st.iface || '?'}${st.metered ? ' ·metered' : ''} · ${stance} · ${subtitle}`);

        // link health row — signal + gateway ping/jitter/loss, always visible;
        // the same nudge `coldspot link`/`coldspot aim` print on the CLI.
        const linkParts = [];
        if (lk) {
            const bars = SIG_BARS[lk.score] || '____';
            const dbm = lk.signal_dbm != null ? ` ${lk.signal_dbm}dBm` : '';
            linkParts.push(`${bars}${dbm}`);
        }
        if (st.latency_ms != null) {
            const jit = st.jitter_ms != null ? ` ±${st.jitter_ms}ms` : '';
            linkParts.push(`ping ${Math.round(st.latency_ms)}ms${jit}`);
        }
        if (st.loss_pct) linkParts.push(`${st.loss_pct}% loss`);
        const better = (st.best_link && st.primary && st.best_link !== st.primary)
            ? `  ⚠ ${st.best_link} looks healthier` : '';
        this._linkItem.label.text = (linkParts.length ? linkParts.join('   ·   ') : 'no link data') + better;

        // per-network policy line — coldspot's own memory for this SSID
        if (st.network && st.network !== '?') {
            const rec = (st.policies || {})[st.network];
            const src = rec?.source ? ` (${rec.source})` : '';
            this._network.label.text = `on ${st.network} → ${st.policy || 'open'}${src}`;
            this._network.visible = true;
        } else {
            this._network.visible = false;
        }

        // governed (cold) / stabilized (weak-link) badge — two independent
        // overlays the reconciler can apply; show whichever is live
        const links = st.links || {};
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

        for (const [name] of STANCES)
            this._stanceItems[name].set_style(name === stance ? CHIP_ON : CHIP);
        for (const [name] of POLICIES) {
            this._policyItems[name].setOrnament(
                name === (st.policy || 'open') ? PopupMenu.Ornament.DOT : PopupMenu.Ornament.NONE);
        }

        // history — per-connection today/month, persisted (`coldspot history`)
        this._historyItem.menu.removeAll();
        const histEntries = Object.entries(st.history || {})
            .sort((a, b) => b[1].today_mb - a[1].today_mb);
        if (histEntries.length) {
            for (const [hconn, h] of histEntries.slice(0, 8)) {
                const met = h.metered ? ' ·metered' : '';
                this._historyItem.menu.addMenuItem(new PopupMenu.PopupMenuItem(
                    `${h.today_mb} MB today (↓${h.today_rx_mb}/↑${h.today_tx_mb}) · ` +
                    `${h.month_mb} MB/mo${met}  —  ${hconn}`, { reactive: false }));
            }
        } else {
            this._historyItem.menu.addMenuItem(
                new PopupMenu.PopupMenuItem('no history yet', { reactive: false }));
        }

        // ledger — today's persisted per-app totals (`coldspot ledger`)
        this._ledgerItem.menu.removeAll();
        const led = st.ledger || [];
        if (led.length) {
            for (const e of led.slice(0, 10)) {
                this._ledgerItem.menu.addMenuItem(new PopupMenu.PopupMenuItem(
                    `↑${e.tx_mb} ↓${e.rx_mb} MB   ${e.name}`, { reactive: false }));
            }
        } else {
            this._ledgerItem.menu.addMenuItem(
                new PopupMenu.PopupMenuItem('no ledger data yet', { reactive: false }));
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

const ColdspotIndicator = GObject.registerClass(
class ColdspotIndicator extends SystemIndicator {
    _init() {
        super._init();
        this.toggle = new ColdspotToggle();
        this.quickSettingsItems.push(this.toggle);
    }
});

export default class ColdspotExtension extends Extension {
    enable() {
        this._indicator = new ColdspotIndicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }
    disable() {
        this._indicator?.quickSettingsItems.forEach(i => i.destroy());
        this._indicator?.destroy();
        this._indicator = null;
    }
}
