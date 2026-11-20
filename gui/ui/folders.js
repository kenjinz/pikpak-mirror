// Home's folder boxes for folder IDs: Pause syncing / Resume, Locate..., Use this folder anyway, Give a new ID,
// the same-ID box, and Add a folder (which first asks folders.identify who the folder is).
// app.js renders the rows and the menu and hands these functions its confirm boxes (initFolderBoxes).
// Nothing here changes an ID, moves anything in PikPak or switches a folder's path without a box first.

import { call, callFull, pickFolder } from './bridge.js';
import { ELLIPSIS, h, asList, say, messageOf, fmtSize, fmtDay, baseName } from './util.js';

const HOME_MSG = 'foldersMsg';
// Where this file's progress lines go: Home's line, or Settings' while its Add encrypted folder runs this flow.
let MSG = HOME_MSG;
// True while Settings' Add encrypted folder runs the add flow: the folder is added encrypted, and folders.add gets
// reviewed (its box showed the plain-copy check, so a folder inside a synced folder may be added).
let fromSettings = false;
const DASH = String.fromCharCode(0x2014); // em dash

// From app.js: confirmBox(opts) -> bool, chooseBox(opts) -> key | null, rows() (status Folders),
// isBusy(), setBusy(on), refresh() (status now), refreshSoon() (a run just started).
let hooks = null;

export function initFolderBoxes(x) {
  hooks = x;
}

// ===== small helpers ================================================================================

/** One change at a time (Home's config lock): a second click while one runs does nothing. */
async function locked(fn) {
  if (hooks.isBusy()) return;
  hooks.setBusy(true);
  try {
    await fn();
  } finally {
    hooks.setBusy(false);
  }
}

const p = text => h('p', { text });

/** folders.add, marked reviewed when Settings' Add encrypted folder runs the flow. */
const addCall = args => call('folders.add', fromSettings ? { ...args, reviewed: true } : args);
const samePath = (a, b) => String(a || '').replace(/[\\/]+$/, '').toLowerCase() === String(b || '').replace(/[\\/]+$/, '').toLowerCase();

/** A done line, or in preview mode what would have happened. */
function sayResult(r, doneText) {
  const lines = r && !Array.isArray(r) ? asList(r.preview).map(String) : [];
  if (lines.length) say(MSG, 'Preview: ' + lines.join(' ') + ' Nothing was changed.', 'done');
  else say(MSG, doneText, 'done');
  return lines.length > 0;
}

/** {text, changed}: the folder's size in words (null when unknown) and its last-changed day (null when unknown). */
async function measure(path) {
  try {
    const s = await call('folders.size', { path, maxSeconds: 8 });
    if (s && s.bytes !== null && s.bytes !== undefined) {
      return { text: (s.complete ? '' : 'more than ') + fmtSize(Number(s.bytes)), changed: s.changed || null };
    }
  } catch (e) { /* only information */ }
  return { text: null, changed: null };
}

const sizeWords = m => (m && m.text) || 'size not known';

/** The folders with an ID file inside the chosen one, one line each. */
function nestedList(nested) {
  const items = asList(nested).map(n => {
    const kind = n.kind === 'encrypted' ? 'encrypted' : 'synced';
    const name = (n.configured && n.configured.name) || n.name || baseName(n.path);
    let tail = 'was synced before';
    if (n.configured) tail = 'synced separately';
    else if (n.kind === 'encrypted') tail = 'not synced; it is left out until you reconnect it';
    return h('li', { text: 'Inside it: ' + name + ' (' + kind + ') ' + DASH + ' ' + tail });
  });
  return items.length ? h('ul', {}, items) : null;
}

/** The status row (or configured folder) a box acts on: {name, private, path, insidePair}. */
const fromRow = f => ({ name: f.Name, private: !!f.Private, path: f.Local || '', insidePair: !!f.InsidePair });
const fromConfigured = c => ({ name: c.name, private: !!c.private, path: c.path || '', exists: c.exists !== false });

// The PikPak folder synced folders live under (MirrorRoot). Read once; '' while it couldn't be read (asked again next time).
let mirrorRootCache = '';
async function mirrorRoot() {
  if (mirrorRootCache) return mirrorRootCache;
  try {
    const cfg = await call('config.get');
    if (cfg && cfg.MirrorRoot) mirrorRootCache = String(cfg.MirrorRoot);
  } catch (e) { /* the box then names no place */ }
  return mirrorRootCache;
}

// ===== Pause syncing / Resume =======================================================================

/** Pause syncing (pause = true) or Resume. No box: nothing is deleted and Resume undoes it. */
export function pauseFolder(f, pause) {
  return locked(async () => {
    say(MSG, (pause ? 'Pausing ' : 'Resuming ') + f.Name + ELLIPSIS, 'busy');
    try {
      const r = await call(pause ? 'folders.pause' : 'folders.resume', { name: f.Name, private: !!f.Private });
      sayResult(r, pause
        ? f.Name + ' is paused. Nothing in it is synced until you resume it.'
        : f.Name + ' is synced again from the next sync on.');
      await hooks.refresh();
    } catch (e) {
      say(MSG, messageOf(e, pause ? "That folder couldn't be paused. Try again." : "That folder couldn't be resumed. Try again."), 'problem');
    }
  });
}

// ===== Locate... ====================================================================================

/** Locate... on a row: pick where the folder is now, then the Locate box. */
export function locateFolder(f) {
  return locked(async () => {
    say(MSG, '');
    let path;
    try {
      path = await pickFolder('Where is ' + f.Name + ' now?');
    } catch (e) {
      say(MSG, "The folder picker didn't open. Try again.", 'problem');
      return;
    }
    if (!path) return;
    await locateTo(fromRow(f), path);
  });
}

/** The Locate box for folder t ({name, private}) at path: locateReview, the box, then folders.locate. */
async function locateTo(t, path) {
  say(MSG, 'Checking the folder' + ELLIPSIS, 'busy');
  let r;
  try {
    r = await call('folders.locateReview', { name: t.name, private: t.private, path });
  } catch (e) {
    say(MSG, messageOf(e, "The folder couldn't be checked. Try again."), 'problem');
    return false;
  }
  if (r.match === 'other') {
    say(MSG, "This is '" + (r.otherName || baseName(path)) + "', not '" + t.name + "'.", 'problem');
    return false;
  }
  const body = [
    p(r.match === 'same'
      ? "This is '" + t.name + "' (was at " + r.oldPath + '). Use it from now on?'
      : "This folder has no ID, so PikPak Sync can't tell if it is '" + t.name + "'. Use it anyway? The first sync merges both sides and deletes nothing."),
    h('p', {}, h('b', { text: path }))
  ];
  let move = null;
  if (!t.private && r.newRemote) {
    const root = await mirrorRoot();
    move = h('input', { type: 'checkbox', checked: true });
    body.push(h('label', { class: 'check' }, move,
      h('span', { text: root
        ? 'Also move it in PikPak to ' + root + '/' + r.newRemote + ' (moved inside PikPak, nothing is uploaded)'
        : 'Also move it in PikPak (moved inside PikPak, nothing is uploaded)' })));
  }
  // Encrypted folders that moved with it are switched in the same step: the parent never goes without them,
  // or a sync of the parent could upload them readable.
  const also = asList(r.nested).filter(n => n.kind === 'encrypted' && n.configured && n.configured.private && n.configured.exists === false);
  for (const n of also) {
    body.push(h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: true, disabled: true }),
      h('span', { text: n.configured.name + ' moved with it: update it too' })));
  }
  say(MSG, '');
  const ok = await hooks.confirmBox({ title: 'Locate ' + t.name + '?', body, ok: 'Use this folder' });
  if (!ok) return false;
  const movePikpak = !!(move && move.checked);
  say(MSG, (movePikpak ? 'Moving ' + t.name + ' in PikPak' : 'Switching ' + t.name + ' to ' + path) + ELLIPSIS, 'busy');
  try {
    const res = await call('folders.locate', {
      name: t.name, private: t.private, path, movePikpak, force: r.match === 'none',
      alsoLocate: also.map(n => ({ name: n.configured.name, path: n.path }))
    });
    sayResult(res, t.name + ' now uses ' + path + '. The next sync merges both sides and deletes nothing.');
    await hooks.refresh();
    return true;
  } catch (e) {
    say(MSG, messageOf(e, "The folder couldn't be switched. Nothing was changed."), 'problem');
    return false;
  }
}

// ===== Use this folder anyway / Give a new ID ========================================================

/** Use this folder anyway: the folder at the configured path takes the ID; a merge (Repair) starts. */
export function adoptFolder(f) {
  return locked(async () => {
    const ok = await hooks.confirmBox({
      title: 'Use this folder anyway?',
      body: [p('Use the folder at ' + f.Local + " as '" + f.Name + "'? Its files and the PikPak copy are merged; nothing is deleted.")],
      ok: 'Use this folder'
    });
    if (!ok) return;
    say(MSG, 'Starting the merge of ' + f.Name + ELLIPSIS, 'busy');
    try {
      const r = await call('folders.adopt', { name: f.Name, private: !!f.Private });
      sayResult(r, f.Name + ' uses the folder at ' + f.Local + '. The merge runs in the background; you can keep using your PC.');
      hooks.refreshSoon();
    } catch (e) {
      say(MSG, messageOf(e, "The folder couldn't be used. Try again."), 'problem');
    }
  });
}

/** Give a new ID (menu): the folder starts a new copy in PikPak; the old copy stays where it is. */
export function giveNewId(f) {
  return locked(async () => {
    say(MSG, 'Checking the folder' + ELLIPSIS, 'busy');
    const m = await measure(f.Local);
    say(MSG, '');
    const ok = await hooks.confirmBox({
      title: 'Give ' + f.Name + ' a new ID?',
      body: [p(f.Name + ' gets a new ID and is uploaded as a new folder (' + sizeWords(m) + '). The current copy in PikPak stays where it is.')],
      ok: 'Give a new ID'
    });
    if (!ok) return;
    say(MSG, 'Giving ' + f.Name + ' a new ID' + ELLIPSIS, 'busy');
    try {
      const r = await call('folders.newId', { name: f.Name, private: !!f.Private });
      sayResult(r, f.Name + ' has a new ID. It is uploaded as a new folder from the next sync on.');
      await hooks.refresh();
    } catch (e) {
      say(MSG, messageOf(e, "The folder couldn't get a new ID. Try again."), 'problem');
    }
  });
}

// ===== the same-ID box ==============================================================================

/** Choose... on a folder-duplicate-id row: the other configured folder with the same ID is on Home too. */
export function chooseSameId(f) {
  return locked(async () => {
    say(MSG, '');
    const id = String(f.Id || '').toLowerCase();
    const other = hooks.rows().find(x => x !== f && id && String(x.Id || '').toLowerCase() === id
      && !(x.Name === f.Name && !!x.Private === !!f.Private));
    if (!other) {
      say(MSG, "The other folder with the same ID isn't listed any more. Check again after the next sync.", 'problem');
      return;
    }
    await sameIdBox({ a: fromRow(f), b: fromRow(other), fromIssue: true });
  });
}

/**
 * Two folders on this PC carry the same ID. a: the configured folder ({name, private, path}); b: the other one,
 * configured too when fromIssue, else only a path picked in Add a folder. encrypted: the kind a new copy gets.
 */
async function sameIdBox({ a, b, fromIssue, encrypted = a.private, notes = [] }) {
  say(MSG, 'Checking both folders' + ELLIPSIS, 'busy');
  const ma = await measure(a.path);
  const mb = await measure(b.path);
  say(MSG, '');
  const line = (path, m) => h('li', {}, h('b', { text: path }), h('br'),
    h('span', { class: 'small', text: sizeWords(m) + (m.changed ? ', last changed ' + fmtDay(m.changed) : '') }));
  // From the issue, "Keep A only" removes B's entry and "Switch to B" removes A's. An encrypted folder inside a
  // synced folder can't stop syncing on its own (its files would be uploaded readable with that folder).
  const blockedA = fromIssue && a.private && a.insidePair;
  const blockedB = fromIssue && b.private && b.insidePair;
  const choice = await hooks.chooseBox({
    title: 'Two folders have the same ID',
    body: [
      p(fromIssue
        ? "These folders both say they are '" + a.name + "', so neither is synced until you choose."
        : "The folder you chose has the same ID as '" + a.name + "', which is synced from here:"),
      h('ul', {}, line(a.path, ma), line(b.path, mb)),
      fromIssue ? p('Switch to ' + b.path + ' stops syncing the other one; nothing is deleted.') : null,
      ...notes,
      blockedA || blockedB ? h('p', { class: 'small', text: 'An encrypted folder inside a synced folder keeps syncing; use Remove encryption on its row instead.' }) : null
    ],
    choices: [
      { key: 'keep', text: 'Keep ' + a.path + ' only', disabled: blockedB },
      { key: 'switch', text: 'Switch to ' + b.path, disabled: blockedA },
      { key: 'both', text: 'Keep both' }
    ]
  });
  if (choice === 'keep') {
    if (!fromIssue) { say(MSG, 'Nothing was added.', 'done'); return; }
    await stopEntry(b);
  } else if (choice === 'switch') {
    if (fromIssue) await stopEntry(a);
    else await locateTo(a, b.path);
  } else if (choice === 'both') {
    await keepBoth({ a, b, fromIssue, encrypted, sizes: { a: ma, b: mb }, canSwap: fromIssue || a.exists !== false });
  }
}

/** Stops syncing one configured folder of a same-ID pair (the existing remove actions). Nothing is deleted. */
async function stopEntry(e) {
  say(MSG, 'Removing ' + e.name + ' from syncing' + ELLIPSIS, 'busy');
  try {
    const r = await (e.private ? call('private.remove', { path: e.path }) : call('folders.remove', { name: e.name }));
    sayResult(r, e.path + ' is no longer synced. Nothing was deleted.');
    await hooks.refresh();
  } catch (err) {
    say(MSG, messageOf(err, "That folder couldn't be removed. Try again."), 'problem');
  }
}

/**
 * Keep both: one keeps the ID and its PikPak place (default: a, the configured one), the other gets a new ID
 * and is uploaded as a new folder. canSwap: false when a's folder is gone (moved), so only b can get the new ID.
 */
async function keepBoth({ a, b, fromIssue, encrypted, sizes, canSwap }) {
  const sentence = h('p');
  const setSentence = keeper => {
    const other = keeper === 'a' ? b : a;
    const m = keeper === 'a' ? sizes.b : sizes.a;
    sentence.textContent = other.path + ' gets a new ID and is uploaded as a new folder (' + sizeWords(m) + ').';
  };
  const body = [];
  const radios = [];
  if (canSwap) {
    body.push(p('Which one keeps the ID and its place in PikPak?'));
    for (const [key, f] of [['a', a], ['b', b]]) {
      const r = h('input', { type: 'radio', name: 'keepsId', value: key, checked: key === 'a' });
      r.addEventListener('change', () => { if (r.checked) setSentence(key); });
      radios.push(r);
      body.push(h('label', { class: 'check' }, r, h('span', { text: f.path })));
    }
  }
  setSentence('a');
  body.push(sentence);
  const ok = await hooks.confirmBox({ title: 'Keep both folders?', body, ok: 'Keep both' });
  if (!ok) return;
  const keeper = (radios.find(r => r.checked) || { value: 'a' }).value;
  const fresh = keeper === 'a' ? b : a;
  say(MSG, 'Giving ' + fresh.path + ' a new ID' + ELLIPSIS, 'busy');
  try {
    if (fromIssue) {
      // Both are configured: the other entry gets the new ID (and a place of its own).
      const r = await call('folders.newId', { name: fresh.name, private: fresh.private });
      sayResult(r, fresh.path + ' has a new ID. It is uploaded as a new folder from the next sync on.');
    } else if (keeper === 'a') {
      const r = await addCall({ path: b.path, encrypted, newId: true });
      sayResult(r, b.path + ' is added with a new ID. It is uploaded as a new folder from the next sync on.');
    } else {
      // b takes over a's ID and place (a Locate that keeps the PikPak place), then a is added as a new folder.
      const r = await call('folders.locate', { name: a.name, private: a.private, path: b.path, movePikpak: false, force: false, alsoLocate: [] });
      if (sayResult(r, '')) {
        say(MSG, 'Preview: ' + asList(r.preview).map(String).join(' ') + ' Would then add ' + a.path + ' with a new ID. Nothing was changed.', 'done');
      } else {
        // The locate is done; a failed add must say plainly that a's old folder is not synced now.
        try {
          const r2 = await addCall({ path: a.path, encrypted, newId: true });
          sayResult(r2, a.name + ' now uses ' + b.path + ', and ' + a.path + ' is added with a new ID. Both are synced from the next sync on.');
        } catch (e2) {
          let why = messageOf(e2, 'it could not be added.');
          if (!/[.!?]$/.test(why)) why += '.';
          say(MSG, "'" + a.name + "' now uses " + b.path + ' and keeps its place in PikPak. ' + a.path
            + " was not added, so it isn't synced: " + why + ' You can add it again with Add a folder.', 'problem');
        }
      }
    }
    await hooks.refresh();
  } catch (e) {
    say(MSG, messageOf(e, "That couldn't be done. Try again."), 'problem');
    await hooks.refresh();
  }
}

// ===== Add a folder =================================================================================

/** Add a folder: pick it, ask folders.identify who it is, then the box for its case. */
export function addFolder() {
  return locked(async () => {
    say(MSG, '');
    let path;
    try {
      path = await pickFolder('Choose a folder to sync');
    } catch (e) {
      say(MSG, "The folder picker didn't open. Try again.", 'problem');
      return;
    }
    if (!path) return;
    say(MSG, 'Checking the folder' + ELLIPSIS, 'busy');
    let id;
    try {
      id = await identify(path, false);
    } catch (e) {
      say(MSG, messageOf(e, "The folder couldn't be checked. Try again."), 'problem');
      return;
    }
    // Nothing is uploaded before the choice. The size is a best guess within a few seconds.
    const size = await measure(path);
    say(MSG, '');
    await addByCase(id, size);
  });
}

/**
 * Settings, Add encrypted folder (path already picked, not a synced folder itself): the same recognition as Home's
 * Add a folder, with the tick forced on and the plain-copy check of private.review in the box. msgId: Settings' line.
 */
export function addEncryptedFolder(path, msgId) {
  if (hooks.isBusy()) {
    say(msgId, 'Another change is running. Try again when it has finished.', 'problem');
    return Promise.resolve();
  }
  return locked(async () => {
    MSG = msgId || HOME_MSG;
    fromSettings = true;
    try {
      say(MSG, 'Checking the folder' + ELLIPSIS, 'busy');
      let id, review;
      try {
        [id, review] = await Promise.all([identify(path, true), call('private.review', { path })]);
      } catch (e) {
        say(MSG, messageOf(e, "The folder couldn't be checked. Try again."), 'problem');
        return;
      }
      const plain = (review && review.plainCopy) || {};
      id.extraNotes = [
        plain.found ? h('p', { class: 'msg problem', text: 'A plain copy is already on PikPak. Making this folder encrypted does not remove it; delete that copy in PikPak if you don' + String.fromCharCode(0x2019) + 't want it there.' }) : null,
        !plain.found && plain.verified === false ? h('p', { class: 'msg problem', text: plain.message || "We couldn't check whether a plain copy is already on PikPak." }) : null,
        review && review.alsoPair ? p('It will stop being synced normally (' + review.alsoPair + ').') : null
      ];
      const size = await measure(path);
      say(MSG, '');
      await addByCase(id, size);
    } finally {
      MSG = HOME_MSG;
      fromSettings = false;
    }
  });
}

async function identify(path, encrypted) {
  const r = await callFull('folders.identify', { path, encrypted });
  return { ...(r.data || {}), warning: r.warning };
}

async function addByCase(id, size) {
  const c = id.configured;
  if (id.case === 'copy' && c && samePath(c.path, id.path)) {
    say(MSG, id.path + " is already synced (as '" + c.name + "').", 'problem');
    return;
  }
  // From Settings, a folder that a synced folder's ID file claims is never re-pointed or swapped (Switch, Use this
  // one, Keep both with a swap): that would upload it readable. It becomes a new encrypted folder with its own ID.
  if (fromSettings && (id.kind !== 'encrypted' || ((id.case === 'copy' || id.case === 'moved') && c && !c.private))) {
    return addNewEncrypted(id, size);
  }
  if (id.case === 'moved') return addMoved(id, size);
  if (id.case === 'copy') return sameIdBox({ a: fromConfigured(c), b: { path: id.path }, fromIssue: false, encrypted: fromSettings || id.kind === 'encrypted', notes: addNotes(id) });
  if (id.case === 'reconnect') return addReconnect(id);
  return addNew(id, size);
}

/** Lines every add box shows under the question: the kind note, a PikPak check that failed, the nested folders. */
const addNotes = id => [
  id.kindNote ? p(String(id.kindNote)) : null,
  id.warning ? h('p', { class: 'small', text: String(id.warning) }) : null,
  nestedList(id.nested),
  ...asList(id.extraNotes)
];

async function addNew(id, size) {
  // From Settings the folder is always added encrypted; a folder whose ID file says it was synced normally then
  // gets a new ID (its old copy in PikPak stays where it is).
  if (fromSettings) return addNewEncrypted(id, size);
  // The kind in the folder's ID file wins over the tick: then the tick shows it and can't be changed.
  const box = h('input', { type: 'checkbox', id: 'addEncrypted', checked: id.kind === 'encrypted', disabled: !!id.marker });
  const ok = await hooks.confirmBox({
    title: 'Add this folder?',
    body: [
      h('p', {}, h('b', { text: id.path })),
      p('Size: ' + (size.text || 'not known') + '.'),
      ...addNotes(id),
      h('label', { class: 'check' }, box,
        h('span', {}, h('b', { text: 'Encrypt this folder' }), h('br'),
          h('span', { class: 'small', text: "PikPak can't read it. Another app needs your recovery key to open the files." })))
    ],
    ok: 'Add folder'
  });
  if (!ok) return;
  const encrypted = box.checked;
  if (encrypted && id.kind !== 'encrypted') {
    // PikPak was checked for an earlier synced copy; an encrypted folder lives elsewhere there: look again.
    say(MSG, 'Checking the folder' + ELLIPSIS, 'busy');
    let again;
    try {
      again = await identify(id.path, true);
    } catch (e) {
      say(MSG, messageOf(e, "The folder couldn't be checked. Try again."), 'problem');
      return;
    }
    say(MSG, '');
    if (again.case !== 'new') return addByCase(again, size);
  }
  await addWith({ path: id.path, encrypted }, null);
}

/** Settings' new encrypted folder: the tick is on and fixed. A synced ID file means a new ID. */
async function addNewEncrypted(id, size) {
  const c = id.configured;
  const claimed = (id.case === 'copy' || id.case === 'moved') && c && !c.private;
  const wasSynced = claimed || (!!id.marker && id.kind !== 'encrypted');
  const ok = await hooks.confirmBox({
    title: 'Make this folder encrypted?',
    body: [
      h('p', {}, h('b', { text: id.path })),
      p('Size: ' + (size.text || 'not known') + '.'),
      p("It will be locked with your recovery key before it's uploaded."),
      claimed
        ? p("This folder has the ID of the synced folder '" + c.name + "'. It will be added as a new encrypted folder with its own ID.")
        : wasSynced ? p('This folder was synced normally before. Encrypted, it gets a new ID; its old copy in PikPak stays where it is.') : null,
      id.warning ? h('p', { class: 'small', text: String(id.warning) }) : null,
      nestedList(id.nested),
      ...asList(id.extraNotes)
    ],
    ok: 'Make encrypted'
  });
  if (!ok) return;
  await addWith(wasSynced ? { path: id.path, encrypted: true, newId: true } : { path: id.path, encrypted: true },
    id.path + ' is encrypted now. It is synced from the next sync on.');
}

async function addMoved(id, size) {
  const c = id.configured;
  const choice = await hooks.chooseBox({
    title: 'Same folder, moved?',
    body: [
      p("This looks like '" + c.name + "', which was at " + c.path + '. Same folder, moved?'),
      h('p', {}, h('b', { text: id.path })),
      ...addNotes(id)
    ],
    choices: [
      { key: 'separate', text: 'Add as a separate folder' },
      { key: 'use', text: 'Use this one' }
    ]
  });
  if (choice === 'use') {
    await locateTo(fromConfigured(c), id.path);
  } else if (choice === 'separate') {
    const a = fromConfigured(c);
    await keepBoth({
      a, b: { path: id.path }, fromIssue: false, encrypted: fromSettings || id.kind === 'encrypted',
      sizes: { a: { text: null, changed: null }, b: size }, canSwap: a.exists
    });
  }
}

async function addReconnect(id) {
  const pk = id.pikpak || {};
  const encrypted = id.kind === 'encrypted';
  const choice = await hooks.chooseBox({
    title: pk.matches ? 'Reconnect this folder?' : 'PikPak already has this folder name',
    body: [
      p(pk.matches
        ? "This folder was synced before, as '" + pk.name + "'. Reconnect to it?"
        : "PikPak already has a folder called '" + pk.name + "' that belongs to another folder. Reconnect to it, or start a new one?"),
      h('p', {}, h('b', { text: id.path })),
      ...addNotes(id)
    ],
    choices: [
      { key: 'new', text: 'Start a new copy' },
      { key: 'reconnect', text: 'Reconnect' }
    ]
  });
  if (choice === 'reconnect') {
    const args = { path: id.path, encrypted };
    if (encrypted) args.name = pk.name; else args.remote = pk.name;
    // The ID of the ID file in PikPak (also when it isn't this folder's): the folder takes it, so its first sync
    // isn't stopped by the PikPak ID check. This box is the owner's confirmation.
    if (pk.id) args.id = pk.id;
    else if (pk.matches && id.marker && id.marker.id) args.id = id.marker.id;
    await addWith(args, id.path + ' is reconnected' + (encrypted ? ' as an encrypted folder' : '') + '. The first sync merges both sides and deletes nothing.');
  } else if (choice === 'new') {
    await addWith({ path: id.path, encrypted, newId: true }, id.path + ' is added with a new ID. It is uploaded as a new folder from the next sync on.');
  }
}

async function addWith(args, doneText) {
  say(MSG, 'Adding ' + args.path + ELLIPSIS, 'busy');
  try {
    const r = await addCall(args);
    sayResult(r, doneText || (args.path + (args.encrypted ? ' is added as an encrypted folder.' : ' is added.') + ' It is synced from the next sync on.'));
    await hooks.refresh();
  } catch (e) {
    say(MSG, messageOf(e, "That folder couldn't be added. Try again."), 'problem');
  }
}
