// Setup with a restore: after sign-in, setup.discover looks in PikPak for the folder list backup and for
// encrypted folders. Then: Recovery key of the earlier install (s-oldkey, only when PikPak holds encrypted
// folders this PC can't open yet) -> Done (setup.js runs setup.finish with args.restore).
//   - A backup with at least one folder restores by itself: every folder in it is chosen, no list is shown.
//     Until setup.finish starts, "Set up from scratch instead" leads to Choose folders.
//   - No backup: Found your folders (s-found), built from the folders' ID files, with ticks and Restore.
//   - Nothing found: Choose folders.
//
// The typed recovery key (or password and salt) is read from its fields when Check key is pressed, sent once
// in setup.usekey's `recoveryKey` / `salt` args and never kept: the fields are emptied after a check that
// worked and whenever the key screen is left. It is never logged.

import { callFull, pickFolder } from './bridge.js';
import { ELLIPSIS, GIB, $, h, asList, say, messageOf, fmtSize, fmtLocalDay } from './util.js';

const SKIP_NOTE = 'Your encrypted folders stay locked in PikPak. You can enter the key later in Settings.';
const RESTORING_TEXT = 'Restoring your folders from PikPak' + ELLIPSIS;
const LOOKING_TEXT = 'Looking for your folders in PikPak' + ELLIPSIS;
const SCRATCH_TEXT = 'Nothing from an earlier install will be restored. You choose which folders to sync yourself.';
const NO_BACKUP = 'No backup of your settings was found. Your folders were found from PikPak; settings are back to defaults.';
const HOLDS_NOTE = 'Contains encrypted folders. It resumes once you enter your recovery key.';
const FRESH_TEXT = "Your old folder list in PikPak will be replaced the first time you save. The folders' ID files stay in PikPak.";
const FREE_DAILY_DOWNLOAD = 5 * GIB;   // about what PikPak lets a free account download each day
const BASE_REMOTE = 'pikpak';          // the rclone remote names setup makes (setup.signin, setup.usekey)
const PRIVATE_REMOTE = 'private';

// From setup.js / app.js: go(name), current(), preview(), confirmBox(opts) -> bool.
let hooks = null;

const rs = {
  account: null,      // setup.signin's answer (setup.js): {preset, ...}
  phase: 'off',       // 'discover' | 'existing' (using this PC's key) | 'scan' | 'error' | 'list' | 'off'
  error: null,        // the failure shown in phase 'error'
  retry: null,        // what Try again runs in phase 'error'
  canSkip: false,     // phase 'scan' / its error: Skip goes to Choose folders
  seq: 0,             // a newer step (or Skip) makes older answers stale
  discover: null,     // setup.discover's answer
  encrypted: null,    // setup.usekey's answer: {source, folders, usedExisting}
  keyAsked: false,    // the key screen was part of this setup
  keySkipped: false,  // the owner pressed "I don't have my key"
  fromScan: false,    // the rows came from setup.scan (no usable backup)
  rows: [],
  active: false,      // setup.finish restores instead of using Choose folders (a backup was found, or Restore was pressed)
  asking: false,      // the Start fresh / Set up from scratch confirmation is open
  held: false,        // an answer came in while it was open: afterKey runs when it is cancelled
  auto: false,        // a backup restores by itself: sizes were not fetched, so the list (if Back shows it) has none
  leftOut: [],        // names of backup folders the automatic restore leaves out (no place, or a name used twice)
  checking: false,    // setup.usekey with a typed key is running
  previewLines: []    // what discover / scan / usekey would have done (preview mode)
};

const isPreview = () => !!(hooks && hooks.preview());
const ticked = () => rs.rows.filter(r => r.on);
const sameName = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
const driveOf = p => { const m = /^([A-Za-z]:)/.exec(String(p || '')); return m ? m[1].toUpperCase() : ''; };

function addPreview(data) {
  rs.previewLines.push(...asList(data && data.preview).map(String));
}

function go(name) {
  if (hooks.current() !== name) hooks.go(name);
  else if (name === 'found') renderFound();
}

// ===== the flow =====================================================================================

/** After a successful first-time sign-in (setup.js). account: setup.signin's answer. */
export function afterSignin(account) {
  rs.account = account || null;
  rs.seq++;
  Object.assign(rs, {
    phase: 'discover', error: null, retry: null, canSkip: false, discover: null, encrypted: null,
    keyAsked: false, keySkipped: false, fromScan: false, rows: [], active: false, asking: false, held: false, auto: false, leftOut: [], previewLines: []
  });
  oldBox.pairMode = false;
  oldBox.clear();
  go('found');
  runDiscover();
}

function fail(e, retry, canSkip) {
  rs.phase = 'error';
  rs.error = e;
  rs.retry = retry;
  rs.canSkip = !!canSkip;
  renderFound();
}

async function runDiscover() {
  const seq = ++rs.seq;
  rs.phase = 'discover';
  rs.canSkip = false;
  renderFound();
  let d;
  try {
    d = (await callFull('setup.discover')).data || {};
  } catch (e) {
    if (seq === rs.seq) fail(e, runDiscover, false);
    return;
  }
  if (seq !== rs.seq) return;
  addPreview(d);
  rs.discover = d;
  if (d.encryptedData && d.hasKey) { useExistingKey(); return; }
  if (d.encryptedData) {
    rs.keyAsked = true;
    go('oldkey');
    return;
  }
  afterKey();
}

/** This PC's rclone already has a key that opens the encrypted folders: list them without asking (Ruling 8). */
async function useExistingKey() {
  const seq = ++rs.seq;
  rs.phase = 'existing';
  renderFound();
  let d;
  try {
    d = (await callFull('setup.usekey', {})).data || {};
  } catch (e) {
    if (seq !== rs.seq) return;
    // The key on this PC no longer opens them: ask for the key.
    if (e && e.code === 'bad-request') { rs.keyAsked = true; go('oldkey'); return; }
    fail(e, useExistingKey, false);
    return;
  }
  if (seq !== rs.seq) return;
  addPreview(d);
  rs.encrypted = d;
  rs.keySkipped = false;
  afterKey();
}

/**
 * The key step is over (checked, skipped, or not needed): a backup restores by itself, else the ID files are listed.
 * Nothing happens once the owner left the restore (phase 'off': Set up from scratch, Back), and an answer that came in
 * while the Set up from scratch question is open waits for its outcome.
 */
function afterKey() {
  if (rs.phase === 'off') return;
  if (rs.asking) { rs.held = true; return; }
  const b = rs.discover && rs.discover.backup;
  if (b) {
    rs.fromScan = false;
    buildRows(backupPairs(b), true);
    if (!rs.rows.length) { toFolders(); return; }
    // Folders without any place (the backup has no path for them) can't be restored by themselves: the list lets the
    // owner choose places.
    if (!ticked().length) { showList(); return; }
    restoreAuto();
    return;
  }
  runScan();
}

/** The folders of a backup (its Pairs, else its Config's). */
function backupPairs(b) {
  return asList(b.Pairs && asList(b.Pairs).length ? b.Pairs : (b.Config && b.Config.Pairs));
}

/** A backup with folders in it is known: it will restore by itself. */
function restoreKnown() {
  const b = rs.discover && rs.discover.backup;
  return !!b && backupPairs(b).some(p => p && p.Name);
}

/** Every folder of the backup is chosen: straight to Done, where setup.finish restores them. */
function restoreAuto() {
  rs.leftOut = rs.rows.filter(r => !r.on).map(r => r.name);   // named on the Done screen, never dropped silently
  rs.phase = 'list';   // Back from a Done screen that failed lands on the list of what was chosen
  rs.canSkip = false;
  rs.auto = true;
  rs.active = true;
  hooks.go('done');
}

async function runScan() {
  const seq = ++rs.seq;
  rs.phase = 'scan';
  rs.canSkip = true;
  go('found');
  renderFound();
  let d;
  try {
    d = (await callFull('setup.scan')).data || {};
  } catch (e) {
    if (seq === rs.seq) fail(e, runScan, true);
    return;
  }
  if (seq !== rs.seq) return;
  addPreview(d);
  rs.fromScan = true;
  buildRows(asList(d.pairs));
  if (!rs.rows.length) { toFolders(); return; }
  showList();
}

function showList() {
  rs.phase = 'list';
  rs.canSkip = false;
  rs.auto = false;
  rs.leftOut = [];
  go('found');
  renderFound();
  loadSizes();
}

/** Today's Choose folders screen (nothing found, Skip, or Start fresh instead). */
function toFolders() {
  rs.seq++;
  rs.held = false;
  rs.leftOut = [];
  rs.active = false;
  rs.phase = 'off';
  hooks.go('folders');
  if (rs.keySkipped) say('folderListMsg', SKIP_NOTE, 'quiet');
}

// ===== rows =========================================================================================

function placeOfPair(p) {
  const b = rs.discover && rs.discover.backup;
  const root = (b && b.Config && b.Config.MirrorRoot) || 'PC-Mirror';
  return p && p.Remote ? BASE_REMOTE + ':' + root + '/' + String(p.Remote) : null;
}

/**
 * One row of the found list for an encrypted folder of private.usekey / setup.usekey's answer ({name, id, lastPath,
 * paused, entry, resolved}); null when it has no name. Shared with Settings (Enter recovery key).
 */
export function encRow(f) {
  if (!f || !f.name) return null;
  const res = f.resolved || {};
  return {
    kind: 'enc', name: String(f.name), src: f,
    path: res.Path ? String(res.Path) : null,
    oldPath: f.lastPath ? String(f.lastPath) : '',
    driveMissing: res.DriveMissing === true || !res.Path,
    chosen: false,
    holds: false,
    paused: f.paused === true,
    place: PRIVATE_REMOTE + ':' + String(f.name),
    bytes: undefined,
    on: false
  };
}

/** `all`: a backup restores everything, so a folder whose drive is missing is chosen too (at its old place). */
function buildRows(pairs, all) {
  const rows = [];
  for (const p of pairs) {
    if (!p || !p.Name) continue;
    const res = p.Resolved || {};
    rows.push({
      kind: 'pair', name: String(p.Name), src: p,
      path: res.Path ? String(res.Path) : null,
      oldPath: p.Local ? String(p.Local) : '',
      driveMissing: res.DriveMissing === true || !res.Path,
      chosen: false,
      holds: p.holdsEncrypted === true,
      paused: p.Paused === true,
      place: placeOfPair(p),
      bytes: undefined,
      on: false
    });
  }
  const enc = rs.encrypted && !rs.keySkipped ? asList(rs.encrypted.folders) : [];
  for (const f of enc) {
    const r = encRow(f);
    if (r) rows.push(r);
  }
  tickDefaults(rows, all);
  rs.rows = rows;
}

/**
 * Ticked when its place is on this PC (with `all`, also when its drive is missing); a second folder with the same name
 * stays unticked. A locked row never is.
 */
export function tickDefaults(rows, all) {
  for (const r of rows) {
    r.on = r.locked !== true && (all || !r.driveMissing) && !!r.path && !rows.some(o => o !== r && o.on && sameName(o.name, r.name));
  }
}

async function loadSizes() {
  const seq = rs.seq;
  const places = [...new Set(rs.rows.map(r => r.place).filter(Boolean))];
  for (const r of rs.rows) if (!r.place) r.bytes = null;
  if (!places.length) { renderFound(); return; }
  let sizes = {};
  try {
    const d = (await callFull('setup.sizes', { places })).data || {};
    addPreview(d);
    sizes = d.sizes || {};
  } catch (e) {
    sizes = {};
  }
  if (seq !== rs.seq) return;
  for (const r of rs.rows) {
    if (!r.place) continue;
    const v = sizes[r.place];
    r.bytes = v === null || v === undefined || !isFinite(Number(v)) ? null : Number(v);
  }
  if (hooks.current() === 'found') renderFound();
}

/**
 * Ticks or unticks a row of `rows`. Returns '' or the problem to show: a row without a place can't be ticked and
 * only one folder of a name can be restored. Shared with Settings.
 */
export function tickRow(rows, r, on) {
  if (on) {
    if (!r.path) { r.on = false; return ''; }
    const other = rows.find(o => o !== r && o.on && sameName(o.name, r.name));
    if (other) {
      r.on = false;
      return 'Only one folder named ' + r.name + ' can be restored. Untick the other one first.';
    }
  }
  r.on = on;
  return '';
}

function setTicked(r, on) {
  const problem = tickRow(rs.rows, r, on);
  say('foundMsg', problem, 'problem');
}

async function choosePlace(r) {
  say('foundMsg', '');
  let path;
  try {
    path = await pickFolder('Where should ' + r.name + ' go on this PC?');
  } catch (e) {
    say('foundMsg', "The folder picker didn't open. Try again.", 'problem');
    return;
  }
  if (!path) return;
  r.path = path;
  r.chosen = true;
  setTicked(r, true);
  renderFound();
}

// ===== the found screen =============================================================================

function stepNumbers() {
  const total = stepTotal();
  $('#stepOldkey').textContent = 'Step 2 of ' + total;
  $('#stepFound').textContent = 'Step ' + (rs.keyAsked ? 3 : 2) + ' of ' + total;
}

/** How many setup steps a restore has (sign in, key when asked, found, done); null outside a restore. */
export function stepTotal() {
  return rs.phase === 'off' && !rs.active ? null : (rs.keyAsked ? 4 : 3);
}

function totalLine() {
  const on = ticked();
  if (!on.length || rs.auto) return '';
  if (on.some(r => r.bytes === undefined)) return 'Checking how much will come down from PikPak' + ELLIPSIS;
  const bytes = on.reduce((s, r) => s + (r.bytes || 0), 0);
  let text = 'About ' + fmtSize(bytes) + ' will come down from PikPak.';
  if (on.some(r => r.bytes === null)) text += ' Some sizes are unknown.';
  const free = !rs.account || rs.account.preset !== 'premium';
  if (free && bytes > FREE_DAILY_DOWNLOAD) text += ' PikPak lets a free account download about 5 GB a day, so this can take more than a day.';
  return text;
}

/**
 * One row of a found list. `on` is what the screen does: tick(r, on) after the box changed, choose(r) for Choose
 * place; on.sizes === false leaves the size column empty. A row with `locked` (and a `note`) can't be ticked.
 * Shared with Settings (Enter recovery key).
 */
export function foundRow(r, i, on) {
  const box = h('input', { type: 'checkbox', 'aria-label': 'Restore ' + r.name, 'data-focus': 'on' + i });
  box.checked = r.on;
  box.disabled = !r.path || r.locked === true;
  box.addEventListener('change', () => on.tick(r, box.checked));
  let size;
  if (on.sizes === false) size = '';
  else if (r.bytes === undefined) size = ELLIPSIS;
  else if (r.bytes === null) size = '?';
  else size = fmtSize(r.bytes);
  const issues = [];
  if (r.driveMissing && !r.chosen) {
    const drive = driveOf(r.oldPath);
    issues.push(h('div', { class: 'fissue warn' },
      drive ? 'drive ' + drive + " isn't on this PC " : 'Choose where it goes on this PC ',
      h('button', { class: 'btn btn-quiet', text: 'Choose place' + ELLIPSIS, 'aria-label': 'Choose a place for ' + r.name, 'data-focus': 'place' + i, onclick: () => on.choose(r) })));
  } else if (r.driveMissing) {
    issues.push(h('div', {},
      h('button', { class: 'btn btn-quiet', text: 'Choose place' + ELLIPSIS, 'aria-label': 'Choose another place for ' + r.name, 'data-focus': 'place' + i, onclick: () => on.choose(r) })));
  }
  const pausedForKey = r.holds && !r.paused && (rs.keySkipped || !rs.rows.some(o => o.kind === 'enc' && o.on));
  if (pausedForKey) issues.push(h('div', { class: 'fissue warn', text: HOLDS_NOTE }));
  if (r.note) issues.push(h('div', { class: 'fissue warn', text: r.note }));
  const shownPath = r.path || r.oldPath;
  return h('div', { class: 'frow' + (r.on ? '' : ' off') },
    box,
    h('div', {},
      h('div', { class: 'fname' }, r.name, r.kind === 'enc' ? h('span', { class: 'small', text: ' (encrypted)' }) : null),
      shownPath ? h('div', { class: 'fpath', text: shownPath, title: shownPath }) : null,
      issues),
    h('div', { class: 'fsize', text: size }),
    r.paused ? h('span', { class: 'pill wait', text: 'Paused' }) : h('span'));
}

const setupRowActions = {
  tick: (r, on) => { setTicked(r, on); renderFound(); },
  choose: r => choosePlace(r),
  get sizes() { return !rs.auto; }
};
const rowView = (r, i) => foundRow(r, i, setupRowActions);

function renderFound() {
  stepNumbers();
  const list = $('#foundList');
  const loading = rs.phase === 'discover' || rs.phase === 'existing' || rs.phase === 'scan';
  const isList = rs.phase === 'list';
  $('#foundTitle').textContent = isList ? 'Found your folders in PikPak' : 'Looking in PikPak';
  $('#foundFresh').hidden = !isList;
  $('#foundRestore').hidden = !isList;
  const note = $('#foundNote');
  const notes = [];
  if (rs.keySkipped) notes.push(SKIP_NOTE);
  else if (rs.encrypted && rs.encrypted.usedExisting) notes.push('Your encrypted folders open with the recovery key already on this PC.');
  note.textContent = notes.join(' ');
  note.hidden = !isList || !notes.length;

  let lead = '';
  if (isList) {
    const b = rs.discover && rs.discover.backup;
    if (b && !rs.fromScan) {
      const day = fmtLocalDay(b.Saved);
      lead = day ? 'Backed up ' + day + (b.PcName ? ' from ' + b.PcName : '') : 'Backed up' + (b.PcName ? ' from ' + b.PcName : '');
    } else {
      lead = NO_BACKUP;
      const problem = rs.discover && rs.discover.backupProblem;
      if (problem) lead = "Your settings backup in PikPak couldn't be used (" + String(problem).replace(/\.$/, '') + '). ' + lead;
    }
  }
  $('#foundLead').textContent = lead;

  if (loading) {
    const scan = rs.phase === 'scan';
    // "Restoring" only once a backup with folders is known; until then the screen just says it is looking.
    const text = !scan && restoreKnown() ? RESTORING_TEXT : LOOKING_TEXT;
    list.replaceChildren(h('div', { class: 'lrow empty' },
      h('span', { text: text + ' ' }),
      rs.canSkip ? h('button', { class: 'btn btn-quiet', text: 'Skip', onclick: toFolders }) : null,
      scan ? null : scratchLink()));
  } else if (rs.phase === 'error') {
    list.replaceChildren(h('div', { class: 'lrow empty' },
      h('span', { text: messageOf(rs.error, "PikPak couldn't be checked. Try again.") + ' ' }),
      h('button', { class: 'btn btn-quiet', text: 'Try again', onclick: () => rs.retry && rs.retry() }),
      rs.canSkip ? h('button', { class: 'btn btn-quiet', text: 'Skip', onclick: toFolders }) : scratchLink()));
  } else if (isList) {
    const focused = document.activeElement && list.contains(document.activeElement) ? document.activeElement.dataset.focus : null;
    list.replaceChildren(...rs.rows.map(rowView));
    if (focused) {
      const again = list.querySelector('[data-focus="' + focused + '"]');
      if (again) again.focus();
    }
  } else {
    list.replaceChildren();
  }
  const total = isList ? totalLine() : '';
  $('#foundTotal').textContent = total;
  $('#foundTotal').hidden = !total;
  $('#foundRestore').disabled = !isList || ticked().length === 0;
}

/** The quiet link of the restoring screen (before setup.finish starts): Choose folders instead, after the question. */
function scratchLink() {
  return h('button', { class: 'btn btn-quiet', text: 'Set up from scratch instead', onclick: startFresh });
}

/**
 * Start fresh (the list's button and the restoring screen's link): after the question, Choose folders. Pressing it
 * ends the restore for good (toFolders drops every answer still on its way); an answer that arrives while the
 * question is open waits, and carries on only when the question is cancelled.
 */
async function startFresh() {
  if (rs.asking) return;
  rs.asking = true;
  let ok = false;
  try {
    // Before a backup or a list is known, nothing is there to be replaced: the question says only what happens.
    const known = rs.phase === 'list' || !!(rs.discover && rs.discover.backup);
    ok = await hooks.confirmBox(known
      ? { title: 'Start fresh instead?', body: [h('p', { text: FRESH_TEXT })], ok: 'Start fresh' }
      : { title: 'Set up from scratch instead?', body: [h('p', { text: SCRATCH_TEXT })], ok: 'Set up from scratch' });
  } finally {
    rs.asking = false;
  }
  if (ok) { toFolders(); return; }
  if (rs.held) { rs.held = false; afterKey(); }
}

function restoreNow() {
  if (rs.phase !== 'list' || !ticked().length) return;
  rs.leftOut = [];   // the ticks are the owner's choice now
  rs.active = true;
  hooks.go('done');
}

function foundBack() {
  rs.seq++;   // a step still running is dropped
  if (rs.keyAsked) { hooks.go('oldkey'); return; }
  rs.phase = 'off';
  hooks.go('signin');
}

// ===== the key screen ===============================================================================

/**
 * The key fields of a form whose elements are <prefix>Key, <prefix>Label, <prefix>SaltRow, <prefix>Salt and
 * <prefix>PairLink: one field for the 30-character recovery key, or Password plus Salt for a key made by the
 * installer. The setup key screen ('oldkey') and Settings ('setUseKey') use the same box. The typed values live only
 * in the fields; clear() empties them.
 */
export function keyBox(prefix) {
  const q = s => $('#' + prefix + s);
  const box = {
    pairMode: false,
    clear() {
      for (const id of ['Key', 'Salt']) { const el = q(id); if (el) el.value = ''; }
    },
    setPairMode(on) {
      box.pairMode = on;
      q('SaltRow').hidden = !on;
      q('Label').textContent = on ? 'Password' : 'Recovery key';
      q('Key').type = on ? 'password' : 'text';
      q('PairLink').textContent = on ? 'My key is a recovery key' : 'My key is a password and a salt';
      if (!on) q('Salt').value = '';
    },
    /** {args: {recoveryKey, salt?}} to send once, or {problem} when a field is empty. */
    read() {
      const args = { recoveryKey: q('Key').value };
      if (box.pairMode) args.salt = q('Salt').value;
      if (!args.recoveryKey.trim() || (box.pairMode && !args.salt.trim())) {
        return { problem: box.pairMode ? 'Type both the password and the salt of your key.' : 'Type your recovery key.' };
      }
      return { args };
    },
    focus() { q('Key').focus(); }
  };
  return box;
}

const oldBox = keyBox('oldkey');

function showOldkey() {
  stepNumbers();
  if (!rs.checking) say('oldkeyMsg', '');
  oldBox.setPairMode(oldBox.pairMode);
  oldBox.focus();
}

function setKeyBusy(busy) {
  rs.checking = busy;
  for (const id of ['#oldkeyKey', '#oldkeySalt', '#oldkeyCheck', '#oldkeySkip', '#oldkeyBack', '#oldkeyPairLink']) $(id).disabled = busy;
}

async function checkKey() {
  if (rs.checking) return;
  const read = oldBox.read();
  if (read.problem) {
    say('oldkeyMsg', read.problem, 'problem');
    return;
  }
  const args = read.args;
  setKeyBusy(true);
  say('oldkeyMsg', 'Checking your key' + ELLIPSIS, 'busy');
  const seq = ++rs.seq;
  let d = null;
  let failure = null;
  try {
    d = (await callFull('setup.usekey', args)).data || {};
  } catch (e) {
    failure = e;
  } finally {
    args.recoveryKey = '';
    args.salt = '';
    setKeyBusy(false);
  }
  if (seq !== rs.seq) return;
  if (failure) {
    say('oldkeyMsg', messageOf(failure, "That key couldn't be checked. Try again."), 'problem');
    oldBox.focus();
    return;
  }
  oldBox.clear();
  say('oldkeyMsg', '');
  addPreview(d);
  rs.encrypted = d;
  rs.keySkipped = false;
  afterKey();
}

function skipKey() {
  if (rs.checking) return;
  oldBox.clear();
  say('oldkeyMsg', '');
  rs.encrypted = null;
  rs.keySkipped = true;
  afterKey();
}

// ===== what setup.js needs ==========================================================================

/** True when this setup restores (a backup was found, or Restore was pressed): setup.finish then sends restoreArg(). */
export function active() {
  return rs.active;
}

/**
 * setup.finish's args.restore: the backup's settings, the ticked folders as they came with their place on
 * this PC, the backup's filter rules, when the backup was saved and whether the key was skipped. No UI keys go along.
 */
export function restoreArg() {
  const b = rs.discover && rs.discover.backup;
  const pairs = [];
  const privatePaths = [];
  for (const r of ticked()) {
    if (!r.path) continue;
    if (r.kind === 'pair') {
      const p = { ...r.src, Local: r.path };
      delete p.Resolved;
      pairs.push(p);
    } else if (r.src.entry) {
      privatePaths.push({ ...r.src.entry, Path: r.path });
    } else {
      const e = { Path: r.path, Name: r.name };
      if (r.src.id) e.Id = String(r.src.id);
      privatePaths.push(e);
    }
  }
  const arg = { pairs, privatePaths, globalFilters: (b && !rs.fromScan && typeof b.GlobalFilters === 'string') ? b.GlobalFilters : '', keySkipped: rs.keySkipped };
  if (b && !rs.fromScan && b.Config) arg.settings = b.Config;
  if (b && !rs.fromScan) arg.saved = String(b.Saved || '');
  return arg;
}

/** Names of the backup's folders the automatic restore left out (no place, or a name used twice); empty otherwise. */
export function leftOut() {
  return rs.active ? rs.leftOut.slice() : [];
}

/** What discover / scan / usekey would have done, for the preview list on the Done screen. */
export function previewLines() {
  return rs.previewLines.slice();
}

/** The restore screens for app.js's router. hooks: go, current(), preview(), confirmBox. */
export function restoreScreens(x) {
  hooks = x;
  return {
    oldkey: { show: showOldkey, hide: () => oldBox.clear() },
    found: { show: renderFound }
  };
}

export function wireRestore() {
  $('#oldkeyForm').addEventListener('submit', e => { e.preventDefault(); checkKey(); });
  $('#oldkeyPairLink').addEventListener('click', () => { oldBox.setPairMode(!oldBox.pairMode); say('oldkeyMsg', ''); oldBox.focus(); });
  $('#oldkeySkip').addEventListener('click', skipKey);
  $('#oldkeyBack').addEventListener('click', () => { rs.seq++; rs.phase = 'off'; hooks.go('signin'); });
  $('#foundBack').addEventListener('click', foundBack);
  $('#foundFresh').addEventListener('click', startFresh);
  $('#foundRestore').addEventListener('click', restoreNow);
}
