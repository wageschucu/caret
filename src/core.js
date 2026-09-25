import { createHash } from 'node:crypto';
export const ABSTAIN = 'none_of_the_above';
export const THRESHOLDS = Object.freeze({
  version: 'v0.3-1',
  ready: 0.5,
  entry: 0.4,
  single: 0.55,
  margin: 0.15,
  hold: 0.35,
  largeSet: 20,
  ratio: 2,
  largeSetMargin: 0.02,
});
export const STATE_BYTES = 8000;
export const hash = (value) => createHash('sha256').update(JSON.stringify(value)).digest('hex');
export const redact = (text) =>
  String(text ?? '')
    .replace(/\b(?:sk-|ghp_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{12,}\b/g, '[REDACTED]')
    .replace(/\bBearer\s+\S+/gi, 'Bearer [REDACTED]')
    .replace(/\b(?:api[_-]?key|token|secret)\s*[:=]\s*["']?[^\s"']{8,}/gi, '[REDACTED]')
    .replace(/\b0x[a-fA-F0-9]{40,64}\b/g, '[REDACTED]')
    .replace(/\b(?:bc1|[13])[a-km-zA-HJ-NP-Z1-9]{25,62}\b/g, '[REDACTED]')
    .replace(/\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b/g, '[REDACTED]');
export function trimState(input = {}, now = Date.now()) {
  const denied = Array.isArray(input.deny_apps) ? input.deny_apps.map((x) => String(x).toLowerCase()) : [];
  if (input.secure || denied.includes(String(input.active_app).toLowerCase()))
    return { buffer: '', screens: [] };
  const clip = (s, n) => redact(s).slice(0, n);
  const state = {
    buffer: clip(input.buffer, 6000),
    active_app: clip(input.active_app, 100),
    window_title: clip(input.window_title, 200),
    url: clip(input.url, 500),
    selection: clip(input.selection, 1500),
    screens: [],
  };
  if (input.screen_context !== false && !input.paused) {
    const seen = new Set();
    for (const s of [...(Array.isArray(input.screens) ? input.screens : [])].sort(
      (a, b) => Date.parse(b.t) - Date.parse(a.t)
    )) {
      const time = Date.parse(s.t);
      if (
        !Number.isFinite(time) ||
        now - time > 300000 ||
        time > now + 5000 ||
        s.secure ||
        denied.includes(String(s.app).toLowerCase())
      )
        continue;
      const lines = redact(s.a11y || s.text)
        .split('\n')
        .filter((l) => !/^\s*(\d{1,2}:\d{2}|Dock|Menu Bar)\s*$/.test(l));
      const text = lines
        .filter((l) => {
          const key = l.trim();
          if (!key || seen.has(key)) return false;
          seen.add(key);
          return true;
        })
        .join('\n')
        .slice(0, 6000);
      if (text)
        state.screens.unshift({
          t: s.t,
          app: clip(s.app, 100),
          window_title: clip(s.window_title, 200),
          url: clip(s.url, 500),
          text,
        });
      if (state.screens.length === 4) break;
    }
    state.focused_window = clip(input.focused_window, 3000);
  }
  // UTF-8 byte count is a conservative token upper bound, including multilingual text.
  // 8,000 UTF-8 bytes is at most ~8k tokens (the spec's hard cap) and typically ~2-3k.
  while (Buffer.byteLength(JSON.stringify(state)) > STATE_BYTES) {
    if (state.screens.length) state.screens.shift();
    else {
      const key = ['focused_window', 'selection', 'url', 'window_title', 'active_app', 'buffer'].find(
        (k) => state[k]?.length
      );
      if (!key) break;
      state[key] = state[key].slice(0, -250);
    }
  }
  return state;
}
export function forwardContext(skill, state) {
  const result = {};
  for (const k of skill.context) {
    if (k === 'buffer') result.buffer = state.buffer;
    if (k === 'selection' && state.selection) result.selection = state.selection;
    if (k === 'focused-window' && state.focused_window)
      result['focused-window'] = { kind: 'untrusted-reference-data', text: state.focused_window };
    if (k === 'recent-screens')
      result['recent-screens'] = { kind: 'untrusted-reference-data', screens: state.screens };
  }
  return result;
}
export function selectRoute(ready, distribution, previous = [], buffer = 'x') {
  if (!buffer.trim()) return [];
  const all = Object.entries(distribution).sort((a, b) => b[1] - a[1]);
  if (!all.length || all[0][0] === ABSTAIN) return [];
  const skills = all.filter(([k]) => k !== ABSTAIN),
    [top, p] = skills[0];
  const second = all[1]?.[1] || 0,
    margin = p - second;
  if (previous[0] === top && p >= THRESHOLDS.hold && ready >= THRESHOLDS.hold)
    return previous.filter((k) => distribution[k] != null);
  if (ready < THRESHOLDS.ready) return [];
  if (all.length > THRESHOLDS.largeSet) {
    if (p / Math.max(second, 1e-9) >= THRESHOLDS.ratio) return [top];
    return margin >= THRESHOLDS.largeSetMargin ? skills.slice(0, 2).map(([k]) => k) : [];
  }
  if (p < THRESHOLDS.entry) return [];
  return p >= THRESHOLDS.single && margin + 1e-9 >= THRESHOLDS.margin
    ? [top]
    : skills.slice(0, 2).map(([k]) => k);
}
export function changedCharacters(a, b) {
  let i = 0;
  while (i < Math.min(a.length, b.length) && a[i] === b[i]) i++;
  let j = 0;
  while (j < Math.min(a.length, b.length) - i && a[a.length - 1 - j] === b[b.length - 1 - j]) j++;
  return Math.max(a.length, b.length) - i - j;
}
export class RouteSession {
  shown = [];
  suppressed = new Map();
  boundary = 0;
  // Spec §7.4: ready is high but the router abstains on two consecutive calls for the same buffer.
  abstainStreak = 0;
  abstainBuffer = '';
  dismiss(buffer, skills = []) {
    // Esc suppresses what was shown; a host also suppresses a skill that just acted on this text.
    for (const k of [...this.shown, ...skills]) this.suppressed.set(k, { buffer, boundary: this.boundary });
    this.shown = [];
    this.abstainStreak = 0;
  }
  update(ready, distribution, buffer, boundary = 0) {
    this.boundary = boundary;
    const picks = selectRoute(ready, distribution, this.shown, buffer);
    this.shown = picks.filter((k) => {
      const s = this.suppressed.get(k);
      return !s || changedCharacters(s.buffer, buffer) > 20 || boundary > s.boundary;
    });
    const sameThought =
      !this.abstainBuffer || buffer.startsWith(this.abstainBuffer) || this.abstainBuffer.startsWith(buffer);
    if (ready >= THRESHOLDS.ready && !this.shown.length && buffer.trim()) {
      this.abstainStreak = sameThought ? this.abstainStreak + 1 : 1;
      this.abstainBuffer = buffer;
    } else {
      this.abstainStreak = 0;
      this.abstainBuffer = '';
    }
    return this.shown;
  }
  /// True when an unrecognised but actionable intent deserves the "create a skill?" affordance.
  get proposal() {
    return this.abstainStreak >= 2;
  }
}
export const HOST_TOOLS = Object.freeze({
  'text.result': { effect: 'preview-only' },
  'file.save': { effect: 'reversible' },
  'calendar.create': { effect: 'sends-or-pays' },
  // Opens a page in the browser: nothing is sent or changed.
  'url.open': { effect: 'preview-only' },
  // Looks up a reference exchange rate; only amount and currency codes leave the machine.
  'fx.convert': { effect: 'preview-only' },
  // Read-only lookups usable during planning (see lookups.js); never side effects.
  'contacts.lookup': { effect: 'preview-only' },
  'github.contributors': { effect: 'preview-only' },
  // Opens a compose window with the draft; nothing is sent until the user does it.
  'mail.draft': { effect: 'reversible' },
});
export function permission(skill, hostTools = HOST_TOOLS) {
  const rank = { 'preview-only': 0, reversible: 1, 'sends-or-pays': 2, destructive: 3 };
  const allowed = skill.allowed_tools.filter(
    (t) => hostTools[t] && (skill.trust !== 'untrusted' || hostTools[t].effect === 'preview-only')
  );
  let effect = skill.side_effect_class in rank ? skill.side_effect_class : 'destructive';
  // A misclassified skill cannot downgrade a real tool's effects.
  for (const t of allowed) if (rank[hostTools[t].effect] > rank[effect]) effect = hostTools[t].effect;
  return {
    tools: allowed,
    effect,
    preview: skill.trust !== 'trusted' || rank[effect] >= 2,
    confirm: rank[effect] >= 2 || skill.trust === 'reviewed',
    scripts: false,
  };
}
