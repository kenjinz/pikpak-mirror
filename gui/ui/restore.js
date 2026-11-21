// Setup with a restore: after sign-in, setup.discover looks in PikPak for the folder list backup and for
// encrypted folders. Then: Recovery key of the earlier install (s-oldkey, only when PikPak holds encrypted
// folders this PC can't open yet) -> Found your folders (s-found, from the backup or, without one, from the
// folders' ID files) -> Done (setup.js runs setup.finish with args.restore). Nothing found: Choose folders.
//
// The typed recovery key (or password and salt) is read from its fields when Check key is pressed, sent once
// in setup.usekey's `recoveryKey` / `salt` args and never kept: the fields are emptied after a check that
// worked and whenever the key screen is left. It is never logged.

import { callFull, pickFolder } from './bridge.js';
import { ELLIPSIS, GIB, $, h, asList, say, messageOf, fmtSize, fmtDay } from './util.js';

const SKIP_NOTE = 'Your encrypted folders stay locked in PikPak. You can enter the key later in Settings.';
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
  active: false,      // the owner pressed Restore: setup.finish restores instead of using Choose folders
  checking: false,    // setup.usekey with a typed key is running
  pairMode: false,    // the key is a password and a salt
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
    keyAsked: false, keySkipped: false, fromScan: false, rows: [], active: false, pairMode: false, previewLines: []
  });
  clearKeyFields();
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

/** The key step is over (checked, skipped, or not needed): the backup's list, else the ID files. */
function afterKey() {
  const b = rs.discover && rs.discover.backup;
  if (b) {
    rs.fromScan = false;
    buildRows(asList(b.Pairs && asList(b.Pairs).length ? b.Pairs : (b.Config && b.Config.Pairs)));
    if (!rs.rows.length) { toFolders(); return; }
    showList();
    return;
  }
  runScan();
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
  go('found');
  renderFound();
  loadSizes();
}

/** Today's Choose folders screen (nothing found, Skip, or Start fresh instead). */
function toFolders() {
  rs.seq++;
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

function buildRows(pairs) {
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
    if (!f || !f.name) continue;
    const res = f.resolved || {};
    rows.push({
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
    });
  }
  // Ticked when its place is on this PC; a second folder with the same name stays unticked.
  for (const r of rows) {
    r.on = !r.driveMissing && !!r.path && !rows.some(o => o !== r && o.on && sameName(o.name, r.name));
  }
  rs.rows = rows;
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

function setTicked(r, on) {
  say('foundMsg', '');
  if (on) {
    if (!r.path) { r.on = false; return; }
    const other = rs.rows.find(o => o !== r && o.on && sameName(o.name, r.name));
    if (other) {
      r.on = false;
      say('foundMsg', 'Only one folder named ' + r.name + ' can be restored. Untick the other one first.', 'problem');
      return;
    }
  }
  r.on = on;
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
  if (!on.length) return '';
  if (on.some(r => r.bytes === undefined)) return 'Checking how much will come down from PikPak' + ELLIPSIS;
  const bytes = on.reduce((s, r) => s + (r.bytes || 0), 0);
  let text = 'About ' + fmtSize(bytes) + ' will come down from PikPak.';
  if (on.some(r => r.bytes === null)) text += ' Some sizes are unknown.';
  const free = !rs.account || rs.account.preset !== 'premium';
  if (free && bytes > FREE_DAILY_DOWNLOAD) text += ' PikPak lets a free account download about 5 GB a day, so this can take more than a day.';
  return text;
}

function rowView(r, i) {
  const box = h('input', { type: 'checkbox', 'aria-label': 'Restore ' + r.name, 'data-focus': 'on' + i });
  box.checked = r.on;
  box.disabled = !r.path;
  box.addEventListener('change', () => { setTicked(r, box.checked); renderFound(); });
  let size;
  if (r.bytes === undefined) size = ELLIPSIS;
  else if (r.bytes === null) size = '?';
  else size = fmtSize(r.bytes);
  const issues = [];
  if (r.driveMissing && !r.chosen) {
    const drive = driveOf(r.oldPath);
    issues.push(h('div', { class: 'fissue warn' },
      drive ? 'drive ' + drive + " isn't on this PC " : 'Choose where it goes on this PC ',
      h('button', { class: 'btn btn-quiet', text: 'Choose place' + ELLIPSIS, 'aria-label': 'Choose a place for ' + r.name, 'data-focus': 'place' + i, onclick: () => choosePlace(r) })));
  } else if (r.driveMissing) {
    issues.push(h('div', {},
      h('button', { class: 'btn btn-quiet', text: 'Choose place' + ELLIPSIS, 'aria-label': 'Choose another place for ' + r.name, 'data-focus': 'place' + i, onclick: () => choosePlace(r) })));
  }
  const pausedForKey = r.holds && !r.paused && (rs.keySkipped || !rs.rows.some(o => o.kind === 'enc' && o.on));
  if (pausedForKey) issues.push(h('div', { class: 'fissue warn', text: HOLDS_NOTE }));
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
      const day = fmtDay(String(b.Saved || '').slice(0, 10));
      lead = day ? 'Backed up ' + day + (b.PcName ? ' from ' + b.PcName : '') : 'Backed up' + (b.PcName ? ' from ' + b.PcName : '');
    } else {
      lead = NO_BACKUP;
      const problem = rs.discover && rs.discover.backupProblem;
      if (problem) lead = "Your settings backup in PikPak couldn't be used (" + String(problem).replace(/\.$/, '') + '). ' + lead;
    }
  }
  $('#foundLead').textContent = lead;

  if (loading) {
    const text = rs.phase === 'scan' ? 'Looking for your folders in PikPak' + ELLIPSIS : 'Checking your PikPak' + ELLIPSIS;
    list.replaceChildren(h('div', { class: 'lrow empty' },
      h('span', { text: text + ' ' }),
      rs.canSkip ? h('button', { class: 'btn btn-quiet', text: 'Skip', onclick: toFolders }) : null));
  } else if (rs.phase === 'error') {
    list.replaceChildren(h('div', { class: 'lrow empty' },
      h('span', { text: messageOf(rs.error, "PikPak couldn't be checked. Try again.") + ' ' }),
      h('button', { class: 'btn btn-quiet', text: 'Try again', onclick: () => rs.retry && rs.retry() }),
      rs.canSkip ? h('button', { class: 'btn btn-quiet', text: 'Skip', onclick: toFolders }) : null));
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

async function startFresh() {
  const ok = await hooks.confirmBox({
    title: 'Start fresh instead?',
    body: [h('p', { text: FRESH_TEXT })],
    ok: 'Start fresh'
  });
  if (ok) toFolders();
}

function restoreNow() {
  if (rs.phase !== 'list' || !ticked().length) return;
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

function clearKeyFields() {
  const k = $('#oldkeyKey');
  const s = $('#oldkeySalt');
  if (k) k.value = '';
  if (s) s.value = '';
}

function setPairMode(on) {
  rs.pairMode = on;
  $('#oldkeySaltRow').hidden = !on;
  $('#oldkeyLabel').textContent = on ? 'Password' : 'Recovery key';
  $('#oldkeyKey').type = on ? 'password' : 'text';
  $('#oldkeyPairLink').textContent = on ? 'My key is a recovery key' : 'My key is a password and a salt';
  if (!on) $('#oldkeySalt').value = '';
}

function showOldkey() {
  stepNumbers();
  if (!rs.checking) say('oldkeyMsg', '');
  setPairMode(rs.pairMode);
  $('#oldkeyKey').focus();
}

function setKeyBusy(busy) {
  rs.checking = busy;
  for (const id of ['#oldkeyKey', '#oldkeySalt', '#oldkeyCheck', '#oldkeySkip', '#oldkeyBack', '#oldkeyPairLink']) $(id).disabled = busy;
}

async function checkKey() {
  if (rs.checking) return;
  const args = { recoveryKey: $('#oldkeyKey').value };
  if (rs.pairMode) args.salt = $('#oldkeySalt').value;
  if (!args.recoveryKey.trim() || (rs.pairMode && !args.salt.trim())) {
    say('oldkeyMsg', rs.pairMode ? 'Type both the password and the salt of your key.' : 'Type your recovery key.', 'problem');
    return;
  }
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
    $('#oldkeyKey').focus();
    return;
  }
  clearKeyFields();
  say('oldkeyMsg', '');
  addPreview(d);
  rs.encrypted = d;
  rs.keySkipped = false;
  afterKey();
}

function skipKey() {
  if (rs.checking) return;
  clearKeyFields();
  say('oldkeyMsg', '');
  rs.encrypted = null;
  rs.keySkipped = true;
  afterKey();
}

// ===== what setup.js needs ==========================================================================

/** True when the owner pressed Restore (setup.finish then sends restoreArg()). */
export function active() {
  return rs.active;
}

/**
 * setup.finish's args.restore: the backup's settings, the ticked folders as they came with their place on
 * this PC, the backup's filter rules and whether the key was skipped. No UI keys go along.
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
  return arg;
}

/** The total of the ticked folders in bytes (unknown sizes count as 0). */
export function restoreBytes() {
  return ticked().reduce((s, r) => s + (r.bytes || 0), 0);
}

/** What discover / scan / usekey would have done, for the preview list on the Done screen. */
export function previewLines() {
  return rs.previewLines.slice();
}

/** The restore screens for app.js's router. hooks: go, current(), preview(), confirmBox. */
export function restoreScreens(x) {
  hooks = x;
  return {
    oldkey: { show: showOldkey, hide: clearKeyFields },
    found: { show: renderFound }
  };
}

export function wireRestore() {
  $('#oldkeyForm').addEventListener('submit', e => { e.preventDefault(); checkKey(); });
  $('#oldkeyPairLink').addEventListener('click', () => { setPairMode(!rs.pairMode); say('oldkeyMsg', ''); $('#oldkeyKey').focus(); });
  $('#oldkeySkip').addEventListener('click', skipKey);
  $('#oldkeyBack').addEventListener('click', () => { rs.seq++; rs.phase = 'off'; hooks.go('signin'); });
  $('#foundBack').addEventListener('click', foundBack);
  $('#foundFresh').addEventListener('click', startFresh);
  $('#foundRestore').addEventListener('click', restoreNow);
}
