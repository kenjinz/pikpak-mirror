// The scrambled folder an encrypted folder has in PikPak (PC-Private/<scrambled>): a hover tooltip on Home and
// Settings, and "Copy PikPak folder name". The bridge works it out from the recovery key on this PC
// (private.pikpakNames) without contacting PikPak. Answers are kept in memory only, for this window's life:
// nothing is written to disk, and nothing pairs a real name with its scrambled one outside the encryption.

import { call, copyText } from './bridge.js';

const known = new Map();     // Name -> 'PC-Private/<scrambled>'
const failed = new Set();    // names the last lookup couldn't answer (no tooltip text, Copy says so)
let pending = null;          // the lookup in flight: Promise

/** Looks up the names not known yet (one bridge call for all of them). Resolves when they are known or failed. */
async function lookUp(names) {
  const missing = [...new Set(names)].filter(n => n && !known.has(n));
  if (!missing.length) return;
  if (pending) { await pending.catch(() => {}); return lookUp(names); }
  pending = call('private.pikpakNames', { names: missing });
  try {
    const r = await pending;
    for (const f of [].concat((r && r.folders) || [])) if (f && f.name && f.pikpak) known.set(String(f.name), String(f.pikpak));
  } catch (e) { /* left as failed below */ }
  finally { pending = null; }
  for (const n of missing) { if (known.has(n)) failed.delete(n); else failed.add(n); }
}

const tipText = name => (known.has(name) ? 'In PikPak: ' + known.get(name) : failed.has(name) ? "PikPak name couldn't be worked out" : '');

/**
 * Gives el a hover (and keyboard focus) tooltip naming the encrypted folder's place in PikPak. Fills it in when
 * the lookup answers, so the rows never wait for it.
 */
export function pikpakTip(el, name) {
  el.classList.add('tip');
  el.tabIndex = 0;
  const fill = () => {
    const t = tipText(name);
    if (t) { el.dataset.tip = t; el.setAttribute('aria-label', t); }
  };
  fill();
  if (!known.has(name)) lookUp([name]).then(fill);
  return el;
}

/** Copies the encrypted folder's PikPak name. Resolves the copied text; throws when it can't be worked out or copied. */
export async function copyPikpakName(name) {
  if (!known.has(name)) { failed.delete(name); await lookUp([name]); }
  if (!known.has(name)) throw new Error('unknown');
  const text = known.get(name);
  await copyText(text);
  return text;
}
