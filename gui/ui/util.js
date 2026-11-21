// Small page helpers shared by app.js (Home, Restore, Free up space, Settings) and setup.js.
// No inline handlers (the CSP blocks them): h() attaches on<Event> props with addEventListener.

export const ELLIPSIS = '…';
export const CHECK = '✓';
export const GIB = 1024 * 1024 * 1024;

export const $ = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

/** Builds an element. props: class, text, on<Event> (function), anything else becomes an attribute. */
export function h(tag, props = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') e.className = v;
    else if (k === 'text') e.textContent = v;
    else if (k.startsWith('on') && typeof v === 'function') e.addEventListener(k.slice(2).toLowerCase(), v);
    else e.setAttribute(k, v === true ? '' : String(v));
  }
  for (const c of kids.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    e.append(c instanceof Node ? c : String(c));
  }
  return e;
}

/** A value from the bridge that should be a list (PowerShell may send one item, null or a list). */
export function asList(v) {
  if (Array.isArray(v)) return v.filter(x => x !== null && x !== undefined);
  if (v === null || v === undefined || v === '') return [];
  return [v];
}

const msgTimers = new Map();
/**
 * One-line message under a part of a screen. kind: 'busy' (quiet progress), 'quiet', 'done', 'problem'.
 * Empty text hides it. Done messages fade out on their own after a while.
 */
export function say(id, text, kind = 'done') {
  const el = document.getElementById(id);
  if (!el) return;
  clearTimeout(msgTimers.get(id));
  if (!text) { el.hidden = true; el.textContent = ''; el.className = 'msg'; return; }
  el.className = 'msg ' + (kind === 'quiet' ? 'busy' : kind);
  el.textContent = (kind === 'done' ? CHECK + ' ' : '') + text;
  el.hidden = false;
  if (kind === 'done') msgTimers.set(id, setTimeout(() => say(id, ''), 20000));
}

/** Plain message text of a bridge rejection or anything else thrown. */
export function messageOf(e, fallback) {
  if (e && typeof e.message === 'string' && e.message) return e.message;
  return fallback;
}

export function num(n) {
  return n < 10 ? String(Math.round(n * 10) / 10) : String(Math.round(n));
}

/** Bytes in words: 46 bytes, 3 KB, 120 MB, 5.2 GB (binary units, like PikPak and Windows). */
export function fmtSize(bytes) {
  const b = Number(bytes);
  if (!isFinite(b) || b < 0) return '?';
  if (b === 0) return '0 GB';
  if (b < 1024) return b + ' bytes';
  if (b < 1024 * 1024) return Math.max(1, Math.round(b / 1024)) + ' KB';
  if (b < GIB) return num(b / (1024 * 1024)) + ' MB';
  return num(b / GIB) + ' GB';
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** 'yyyy-MM-dd' -> '25 Oct' (with the year when it isn't this year). */
export function fmtDay(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || ''));
  if (!m) return String(iso || '');
  const text = Number(m[3]) + ' ' + MONTHS[Number(m[2]) - 1];
  return Number(m[1]) === new Date().getFullYear() ? text : text + ' ' + m[1];
}

/** A saved timestamp as the browser shows dates (the setup list and the Done screen); '' when it is empty or can't be read. */
export function fmtLocalDay(saved) {
  const d = new Date(String(saved || ''));
  return isNaN(d.getTime()) ? '' : d.toLocaleDateString();
}

export function baseName(path) {
  const p = String(path || '').replace(/[\\/]+$/, '');
  const i = Math.max(p.lastIndexOf('\\'), p.lastIndexOf('/'));
  return i >= 0 ? p.slice(i + 1) || p : p;
}

// ===== recovery key helpers (setup and Settings) ====================================================

/** A key in groups of five: 'ABCDEFGHIJ' -> 'ABCDE FGHIJ'. */
export const keyGroups = key => String(key || '').replace(/(.{5})(?=.)/g, '$1 ');

export function todayInWords() {
  return new Date().toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });
}

/**
 * The key sheet's lines; the saved file and the printout say the same (setup and Settings).
 * keys: [{label?, value}]. pair: an older key kept as a password and a salt.
 */
export function keySheetLines({ keys, pcName, pair = false }) {
  return {
    title: 'PikPak Sync recovery key',
    keys,
    made: 'Made on ' + todayInWords() + (pcName ? ' on the PC named ' + pcName : '') + '.',
    about: [
      'You need this key to open your encrypted folders if this PC breaks or is replaced.',
      'Keep it somewhere other than this PC. Nobody else has a copy, not even PikPak.'
    ],
    restoreTitle: 'To open your encrypted folders on a new PC:',
    restore: [
      "1. Install rclone and copy this app's folder to the new PC (see RECOVERY.md).",
      '2. Run scripts\\Install.ps1 and choose a) when it asks about the encryption key.',
      pair ? '3. Type the password above as the password, then type the salt above when it asks for the salt.'
           : "3. Type this key as the password (spaces don't matter), then press Enter twice when it asks for the salt."
    ]
  };
}

/** The key sheet as text for the saved file. */
export function keySheetText(s) {
  return [s.title, '', ...s.keys.flatMap(k => (k.label ? [k.label + ':'] : []).concat(['    ' + k.value, ''])),
    s.made, '', ...s.about, '', s.restoreTitle, ...s.restore, ''].join('\r\n');
}

/** Fills the print-only key sheet. s: {title, keys: [{label?, value}], made, about[], restoreTitle, restore[]}. */
export function fillKeySheet(s) {
  $('#keySheet').replaceChildren(
    h('h1', { text: s.title }),
    ...s.keys.flatMap(k => [k.label ? h('p', { text: k.label }) : null, h('p', { class: 'key', text: k.value })]),
    h('p', { text: s.made }),
    ...s.about.map(t => h('p', { text: t })),
    h('h2', { text: s.restoreTitle }),
    ...s.restore.map(t => h('p', { text: t })));
}

export function clearKeySheet() {
  $('#keySheet').replaceChildren();
}
