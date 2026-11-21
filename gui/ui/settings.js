// Settings: syncing (pause, how often, logon run, go easy on my internet), encrypted folders, recovery key,
// start with Windows, the PikPak account and the Advanced limits.
//
// Every switch applies at once and goes back to its old position when the change fails. The recovery key
// is fetched only when the user presses "Show recovery key"; it lives in `settings.secret` and in the key
// tags, and is cleared as soon as Settings is left, the window is hidden or the key is hidden again.

import { call, invoke, pickFolder, pickSaveFile, writeTextFile, copyText, autostartEnabled, setAutostart } from './bridge.js';
import { ELLIPSIS, GIB, $, h, asList, say, messageOf, fmtSize, keyGroups, keySheetLines, keySheetText, fillKeySheet, clearKeySheet } from './util.js';
import { pikpakTip, copyPikpakName } from './pikpak-name.js';
import { keyBox, encRow, tickRow, tickDefaults, foundRow } from './restore.js';

const KEY_FILE_NAME = 'PikPak recovery key.txt';
const DEFAULT_BW = { from: '18:00', speed: '2M', to: '23:00' };   // BwLimit '18:00,2M:off 23:00,off'
const BW_PATTERN = /^(\d{2}:\d{2}),(\S+):off (\d{2}:\d{2}),off$/;
const TIME_PATTERN = /^([01]\d|2[0-3]):[0-5]\d$/;

const settings = {
  hooks: null,     // from app.js: confirmBox(opts), changeKind(path, to, msgId), addEncrypted(path, msgId), preview(), pcName()
  config: null,    // last config.get answer (raw hashtable)
  bw: { custom: false, speed: DEFAULT_BW.speed, from: DEFAULT_BW.from, to: DEFAULT_BW.to },   // last-known evening hours
  keyToken: 0,     // bumped whenever the key is hidden, so a late key.show answer is dropped
  secret: null,    // {kind:'single', key} | {kind:'pair', password, salt}; only while shown
  remote: null,    // last private.remoteList answer's folders (null = not loaded)
  loadId: 0,
  noKey: false,    // private.keyState: PikPak holds encrypted folders and this PC has no key for them
  keyPhase: 'off', // Enter recovery key: 'off' | 'row' (the row asks) | 'form' (the key box) | 'found' (the folders to restore)
  keyBusy: false,  // private.usekey or private.restore is running
  found: null      // {rows, waiting}: the encrypted folders the typed key opens
};
const useKeyBox = keyBox('setUseKey');

const isPreview = () => !!(settings.hooks && settings.hooks.preview());

// ===== small helpers ================================================================================

/** Runs `fn` with the control disabled; returns fn's result. */
async function whileBusy(el, fn) {
  el.disabled = true;
  try { return await fn(); } finally { el.disabled = false; }
}

function timeOptions() {
  // 18:00 to 02:00 in 30-minute steps.
  const out = [];
  for (let m = 18 * 60; m <= 26 * 60; m += 30) {
    const hh = Math.floor(m / 60) % 24, mm = m % 60;
    out.push(String(hh).padStart(2, '0') + ':' + String(mm).padStart(2, '0'));
  }
  return out;
}

function timeLabel(t) {
  const hh = Number(t.slice(0, 2));
  return (hh >= 6 && hh < 18 ? 'Every day at ' : hh >= 18 ? 'Every evening at ' : 'Every night at ') + t;
}

function fillTimeSelect(value) {
  const sel = $('#setTime');
  const times = timeOptions();
  if (value && !times.includes(value)) times.push(value);   // a time set by hand in the settings file
  sel.replaceChildren(...times.map(t => h('option', { value: t, text: timeLabel(t) })));
  sel.value = value || '20:00';
  sel.dataset.prev = sel.value;
}

function fillEverySelect(minutes) {
  const sel = $('#setEvery');
  const n = Number(minutes);
  const value = Number.isFinite(n) && [...sel.options].some(o => Number(o.value) === n) ? String(n) : '60';
  sel.value = value;
  sel.dataset.prev = value;
  $('#setTimeRow').hidden = value !== '0';   // the time of day only matters for "Once a day"
}

/** config.get -> change -> config.save, always from the file as it is now. */
async function saveConfigWith(change) {
  const cfg = await call('config.get');
  if (!cfg || typeof cfg !== 'object') throw { message: "The settings couldn't be read. Try again." };
  change(cfg);
  await call('config.save', { config: cfg });
  settings.config = cfg;
  return cfg;
}

function bwString(from, speed, to) {
  return from + ',' + speed + ':off ' + to + ',off';
}

function privatePaths(cfg) {
  return asList(cfg && cfg.PrivatePaths).filter(p => p && p.Path);
}

// ===== show / hide ==================================================================================

async function show() {
  const id = ++settings.loadId;
  hideKey();
  for (const m of ['setLoadMsg', 'setMsg', 'setPrivMsg', 'setRemoteMsg', 'setKeyMsg', 'setAutoMsg', 'advMsg']) say(m, '');
  say('setLoadMsg', 'Loading' + ELLIPSIS, 'quiet');
  // Each part loads on its own, so one slow or failing call doesn't hold up the rest.
  const parts = [loadSchedule(), loadConfig(), loadAutostart(), loadAccount(), loadKeyState()];
  await Promise.all(parts);
  if (id === settings.loadId) say('setLoadMsg', '');
}

function hide() {
  settings.loadId++;
  settings.remote = null;
  renderRemote();
  hideKey();
  settings.noKey = false;
  closeUseKey();
}

function failed(msgId, e, fallback) {
  say(msgId, messageOf(e, fallback), 'problem');
}

async function loadSchedule() {
  try {
    const s = await call('schedule.get');
    $('#setPause').checked = !!s.paused;
    fillTimeSelect(String(s.syncTime || '20:00'));
    fillEverySelect(s.intervalMinutes);
    $('#setLogon').checked = s.syncAtLogon !== false;
    // The tray may have paused or resumed since: bring its label in line with what the task really is.
    invoke('set_tray_paused', { paused: !!s.paused }).catch(() => {});
  } catch (e) { failed('setLoadMsg', e, "The sync schedule couldn't be read."); }
}

async function loadConfig() {
  try {
    const cfg = await call('config.get');
    settings.config = cfg;
    renderPrivate();
    renderAdvanced(cfg);
    renderBandwidth(cfg);
  } catch (e) { failed('setLoadMsg', e, "Your settings couldn't be read."); }
}

async function loadAutostart() {
  try {
    $('#setAutostart').checked = !!(await autostartEnabled());
  } catch (e) { failed('setAutoMsg', e, "Couldn't check whether the app starts with Windows."); }
}

async function loadAccount() {
  const el = $('#setAccount');
  try {
    const a = await call('about', { refresh: false });
    const kind = Number(a.totalBytes) > 10 * GIB ? 'Premium account' : 'Free account';
    el.replaceChildren(String(a.email || 'Your PikPak account'),
      h('span', { class: 'small', text: kind + ', ' + fmtSize(a.usedBytes) + ' used of ' + fmtSize(a.totalBytes) }));
  } catch (e) {
    el.replaceChildren('PikPak account', h('span', { class: 'small', text: messageOf(e, "Your account couldn't be checked right now.") }));
  }
}

// ===== syncing ======================================================================================

async function togglePause(ev) {
  const box = ev.currentTarget;
  const want = box.checked;
  say('setMsg', '');
  try {
    await whileBusy(box, () => call('schedule.set', { paused: want }));
    invoke('set_tray_paused', { paused: want }).catch(() => {});
    say('setMsg', want ? 'Syncing is paused.' : 'Syncing is on again.', 'done');
  } catch (e) {
    box.checked = !want;
    failed('setMsg', e, "Syncing couldn't be " + (want ? 'paused' : 'turned back on') + '.');
  }
}

async function changeSchedule(el, args, doneText, undo) {
  say('setMsg', '');
  try {
    await whileBusy(el, () => call('schedule.set', args));
    say('setMsg', doneText, 'done');
  } catch (e) {
    undo();
    failed('setMsg', e, "The schedule couldn't be changed.");
  }
}

function changeTime(ev) {
  const sel = ev.currentTarget;
  const prev = sel.dataset.prev || '20:00';
  const t = sel.value;
  changeSchedule(sel, { syncTime: t }, 'Syncing will start every day at ' + t + '.', () => { sel.value = prev; })
    .then(() => { sel.dataset.prev = sel.value; });
}

function everyText(n) {
  return n === 0 ? 'Syncing once a day.'
    : n === 60 ? 'Syncing every hour.'
    : n > 60 ? 'Syncing every ' + (n / 60) + ' hours.' : 'Syncing every ' + n + ' minutes.';
}

function changeEvery(ev) {
  const sel = ev.currentTarget;
  const prev = sel.dataset.prev || '60';
  const n = Number(sel.value);
  $('#setTimeRow').hidden = n !== 0;
  changeSchedule(sel, { intervalMinutes: n }, everyText(n), () => { sel.value = prev; $('#setTimeRow').hidden = prev !== '0'; })
    .then(() => { sel.dataset.prev = sel.value; });
}

function changeLogon(ev) {
  const box = ev.currentTarget;
  const want = box.checked;
  changeSchedule(box, { syncAtLogon: want },
    want ? "Syncing will also start soon after you turn on your PC." : "Syncing will no longer also start when you turn on your PC.",
    () => { box.checked = !want; });
}

function renderBandwidth(cfg) {
  const raw = String(cfg.BwLimit || '').trim();
  const m = BW_PATTERN.exec(raw);
  $('#setBw').checked = raw !== '';
  settings.bw.custom = raw !== '' && !m;
  if (m) { settings.bw.speed = m[2]; settings.bw.from = m[1]; settings.bw.to = m[3]; }
  const from = $('#advBwFrom'), to = $('#advBwTo');
  from.value = settings.bw.from;
  to.value = settings.bw.to;
  from.disabled = to.disabled = settings.bw.custom || raw === '';
  $('#advBwNote').textContent = settings.bw.custom ? 'A custom limit is set in the settings file, so the hours are left alone.' : '';
  $('#setBwNote').textContent = 'Uploads slowly between ' + from.value + ' and ' + to.value + " so videos and calls don't stutter.";
}

async function toggleBandwidth(ev) {
  const box = ev.currentTarget;
  const want = box.checked;
  say('setMsg', '');
  try {
    const from = $('#advBwFrom').value.trim(), to = $('#advBwTo').value.trim();
    const hours = TIME_PATTERN.test(from) && TIME_PATTERN.test(to) ? { from, to } : settings.bw;
    const cfg = await whileBusy(box, () => saveConfigWith(c => {
      if (!want) c.BwLimit = '';
      else if (!settings.bw.custom || String(c.BwLimit || '').trim() === '') c.BwLimit = bwString(hours.from, settings.bw.speed, hours.to);
    }));
    renderBandwidth(cfg);
    say('setMsg', want ? 'Uploads will go easy on your internet in the evening.' : 'Uploads will use all your internet at any hour.', 'done');
  } catch (e) {
    box.checked = !want;
    failed('setMsg', e, "That setting couldn't be saved.");
  }
}

// ===== encrypted folders ==============================================================================

function renderPrivate() {
  renderPausedKey();
  const list = privatePaths(settings.config);
  const box = $('#setPrivList');
  if (!list.length) {
    box.replaceChildren(h('div', { class: 'srow empty', text: 'No encrypted folders yet.' }));
    return;
  }
  box.replaceChildren(...list.map(p => h('div', { class: 'srow' },
    h('span', {}, String(p.Name || p.Path), h('span', { class: 'small path', text: String(p.Path) })),
    h('button', { class: 'btn', text: 'Remove', onclick: ev => removePrivate(p, ev.currentTarget) }))));
}

async function refreshConfig() {
  try {
    settings.config = await call('config.get');
    renderPrivate();
  } catch (e) { failed('setPrivMsg', e, "Your settings couldn't be read again. Close and open Settings."); }
}

async function addPrivate(ev) {
  const btn = ev.currentTarget;
  say('setPrivMsg', '');
  let path;
  try { path = await pickFolder('Choose a folder to encrypt'); }
  catch (e) { say('setPrivMsg', "The folder window didn't open. Try again.", 'problem'); return; }
  if (!path) return;
  // A folder that is already synced is changed by the background job (the same box as on Home).
  const same = p => String(p || '').replace(/[\\/]+$/, '').toLowerCase();
  if (asList(settings.config && settings.config.Pairs).some(x => same(x.Local) === same(path))) {
    btn.disabled = true;
    try {
      if (await settings.hooks.changeKind(path, 'encrypted', 'setPrivMsg')) await refreshConfig();
    } finally { btn.disabled = false; }
    return;
  }
  // Otherwise the same recognition as Home's Add a folder (an earlier copy, the same ID, a move), encrypted, with
  // the plain-copy check in its box. The flow says how it went on this section's line.
  btn.disabled = true;
  try {
    await settings.hooks.addEncrypted(path, 'setPrivMsg');
    await refreshConfig();
  } finally {
    btn.disabled = false;
  }
}

async function removePrivate(p, btn) {
  say('setPrivMsg', '');
  const ok = await settings.hooks.confirmBox({
    title: 'Stop encrypting this folder?',
    body: [h('p', {}, h('b', { text: String(p.Path) })),
      h('p', { text: "It won't be locked any more. What's already in PikPak stays there, still locked." }),
      h('p', { text: "If it's inside a synced folder, it will be synced normally from now on, without a lock." })],
    ok: 'Remove', danger: true
  });
  if (!ok) return;
  btn.disabled = true;
  try {
    const r = await call('private.remove', { path: String(p.Path) });
    await refreshConfig();
    const by = asList(r && r.backedUpPlainBy);
    say('setPrivMsg', by.length ? 'Removed. It is now synced normally as part of ' + by.join(', ') + '.' : 'The folder is no longer encrypted.', 'done');
  } catch (e) {
    btn.disabled = false;
    failed('setPrivMsg', e, "The folder couldn't be removed.");
  }
}

// ===== encrypted folders this PC can't open yet (enter the recovery key later) ========================
// Shown only when private.keyState says PikPak holds encrypted folders and this PC has no key. The typed key (or
// password and salt) is read once when Check key is pressed, sent in private.usekey's `recoveryKey` / `salt` args and
// never kept: the fields are emptied after the check, when the box is closed and whenever Settings is left.

const NO_LIST_TEXT = 'Your recovery key opens your encrypted folders, but PikPak has no list of where they were on your old PC. '
  + 'Connect each one yourself: press Reconnect' + ELLIPSIS + ' next to it under Encrypted folders in PikPak.';

async function loadKeyState() {
  const id = settings.loadId;
  let d = null;
  try { d = await call('private.keyState'); } catch (e) { d = null; }   // offline: no row, the rest of Settings still works
  if (id !== settings.loadId) return;
  settings.noKey = !!(d && d.hasKey === false && d.encryptedData === true);
  if (!settings.noKey) { closeUseKey(); return; }
  if (settings.keyPhase === 'off') settings.keyPhase = 'row';
  renderUseKey();
}

function renderUseKey() {
  const phase = settings.noKey || settings.keyPhase === 'found' ? settings.keyPhase : 'off';
  $('#setNoKey').hidden = phase !== 'row';
  $('#setUseKeyForm').hidden = phase !== 'form';
  $('#setFound').hidden = phase !== 'found';
  renderPausedKey();
}

/** Synced folders a restore paused for the missing key, as the config says now. */
function pausedForKey() {
  return asList(settings.config && settings.config.Pairs).filter(p => p && p.Paused === true && p.PausedForKey === true).map(p => String(p.Name));
}

/** The quiet row for folders still paused for their encrypted folders (key already on this PC). */
function renderPausedKey() {
  const names = pausedForKey();
  const show = names.length > 0 && !settings.noKey && settings.keyPhase !== 'found';
  $('#setPausedKey').hidden = !show;
  if (show) $('#setPausedKeyText').textContent = 'Some folders are paused until their encrypted folders are back (' + names.join(', ') + ').';
}

/** Closes the box and the found list and empties the key fields. */
function closeUseKey() {
  useKeyBox.clear();
  useKeyBox.setPairMode(false);
  settings.found = null;
  settings.keyBusy = false;
  settings.keyPhase = settings.noKey ? 'row' : 'off';
  for (const m of ['setUseKeyMsg', 'setFoundMsg']) say(m, '');
  renderUseKey();
}

function openUseKey() {
  say('setPrivMsg', '');
  say('setUseKeyMsg', '');
  settings.keyPhase = 'form';
  renderUseKey();
  useKeyBox.setPairMode(false);
  useKeyBox.focus();
}

function setUseKeyBusy(busy) {
  settings.keyBusy = busy;
  for (const id of ['#setUseKeyKey', '#setUseKeySalt', '#setUseKeyPairLink', '#setUseKeyCancel', '#setUseKeyCheck']) $(id).disabled = busy;
}

async function checkUseKey() {
  if (settings.keyBusy) return;
  const read = useKeyBox.read();
  if (read.problem) { say('setUseKeyMsg', read.problem, 'problem'); return; }
  const args = read.args;
  const id = settings.loadId;
  setUseKeyBusy(true);
  say('setUseKeyMsg', 'Checking your key' + ELLIPSIS, 'busy');
  let d = null;
  let failure = null;
  try {
    d = await call('private.usekey', args);
  } catch (e) {
    failure = e;
  } finally {
    args.recoveryKey = '';
    args.salt = '';
    setUseKeyBusy(false);
  }
  if (id !== settings.loadId) { useKeyBox.clear(); return; }   // Settings was left meanwhile
  if (failure) {
    say('setUseKeyMsg', messageOf(failure, "That key couldn't be checked. Try again."), 'problem');
    useKeyBox.focus();
    return;
  }
  useKeyBox.clear();
  d = d || {};
  if (!d.source && asList(d.preview).length) { say('setUseKeyMsg', 'Preview: ' + asList(d.preview).join(' '), 'done'); return; }
  say('setUseKeyMsg', '');
  // private.usekey made the key remote: from here on this PC has the key, whatever happens to the found list.
  settings.noKey = false;
  const rows = d.source === 'backup' ? asList(d.folders).map(encRow).filter(Boolean) : [];
  if (!rows.length) { await keyAcceptedWithoutList(); return; }
  showFound(rows);
}

/** The key works but PikPak has no usable list: the folders are connected one by one (Reconnect). */
async function keyAcceptedWithoutList() {
  closeUseKey();
  say('setPrivMsg', NO_LIST_TEXT, 'quiet');
  await loadRemote();
}

function showFound(rows) {
  const mine = new Set(privatePaths(settings.config).map(p => String(p.Name || '').toLowerCase()));
  for (const r of rows) {
    if (mine.has(r.name.toLowerCase())) { r.locked = true; r.note = 'Already set up on this PC.'; }
  }
  tickDefaults(rows);
  const waiting = pausedForKey();
  settings.found = { rows, waiting };
  settings.keyPhase = 'found';
  renderFound();
}

const foundActions = {
  sizes: false,
  tick: (r, on) => { say('setFoundMsg', tickRow(settings.found.rows, r, on), 'problem'); renderFound(); },
  choose: async r => {
    say('setFoundMsg', '');
    let path;
    try { path = await pickFolder('Where should ' + r.name + ' go on this PC?'); }
    catch (e) { say('setFoundMsg', "The folder picker didn't open. Try again.", 'problem'); return; }
    if (!path) return;
    r.path = path;
    r.chosen = true;
    say('setFoundMsg', tickRow(settings.found.rows, r, true), 'problem');
    renderFound();
  }
};

function renderFound() {
  renderUseKey();
  const f = settings.found;
  const list = $('#setFoundList');
  if (!f) { list.replaceChildren(); return; }
  $('#setFoundLead').textContent = 'Your recovery key opens these encrypted folders from your backup. Tick the ones to bring back and check where each one goes on this PC.';
  const note = $('#setFoundNote');
  note.textContent = f.waiting.length ? 'Synced folders that contain encrypted folders (' + f.waiting.join(', ') + ') are paused until these are restored.' : '';
  note.hidden = !f.waiting.length;
  const focused = document.activeElement && list.contains(document.activeElement) ? document.activeElement.dataset.focus : null;
  list.replaceChildren(...f.rows.map((r, i) => foundRow(r, i, foundActions)));
  if (focused) {
    const again = list.querySelector('[data-focus="' + focused + '"]');
    if (again) again.focus();
  }
  $('#setFoundRestore').disabled = settings.keyBusy || !f.rows.some(r => r.on);
}

/** The ticked rows as raw PrivatePaths entries (the backup's own fields kept) with the place chosen for this PC. */
function restoreEntries() {
  return settings.found.rows.filter(r => r.on && r.path && !r.locked).map(r => {
    if (r.src.entry) return { ...r.src.entry, Path: r.path };
    const e = { Path: r.path, Name: r.name };
    if (r.src.id) e.Id = String(r.src.id);
    return e;
  });
}

async function restoreFound() {
  if (settings.keyBusy || !settings.found) return;
  const entries = restoreEntries();
  if (!entries.length) return;
  const id = settings.loadId;
  settings.keyBusy = true;
  $('#setFoundRestore').disabled = true;
  $('#setFoundCancel').disabled = true;
  say('setFoundMsg', 'Restoring' + ELLIPSIS, 'busy');
  let r;
  try {
    r = await call('private.restore', { entries });
  } catch (e) {
    settings.keyBusy = false;
    $('#setFoundCancel').disabled = false;
    if (id === settings.loadId) { say('setFoundMsg', messageOf(e, "Your encrypted folders couldn't be restored."), 'problem'); renderFound(); }
    return;
  }
  settings.keyBusy = false;
  $('#setFoundCancel').disabled = false;
  if (id !== settings.loadId) return;
  if (r && r.saved === false && r.preview) { say('setFoundMsg', 'Preview: ' + asList(r.preview).join(' '), 'done'); renderFound(); return; }
  const text = restoreText(r);
  closeUseKey();
  say('setPrivMsg', text, 'done');
  await refreshConfig();
}

/** What a private.restore result did, in words. */
function restoreText(r) {
  const added = asList(r && r.added), resumed = asList(r && r.resumed), still = asList(r && r.stillPaused);
  const one = n => n === 1;
  const parts = [];
  if (added.length) parts.push('Restored ' + (one(added.length) ? "'" + added[0] + "'" : added.length + ' encrypted folders') + '. Their files come down at the next sync.');
  if (resumed.length) parts.push(resumed.join(', ') + (one(resumed.length) ? ' is' : ' are') + ' syncing again.');
  if (still.length) parts.push(still.join(', ') + (one(still.length) ? ' stays' : ' stay') + ' paused, because none of your encrypted folders is inside '
    + (one(still.length) ? 'it' : 'them') + '. Resume ' + (one(still.length) ? 'it' : 'them') + ' on Home when that is right.');
  return parts.length ? parts.join(' ') : 'Nothing needed to change.';
}

/** Not now: the key is already on this PC, the folders were not restored. Reconnect still works from the PikPak list. */
async function leaveFound() {
  if (settings.keyBusy) return;
  closeUseKey();
  say('setPrivMsg', 'Your recovery key is saved on this PC, but your encrypted folders were not restored. Reconnect them one by one under Encrypted folders in PikPak.', 'quiet');
  await loadRemote();
}

/** Check again: with no folders to add, private.restore only re-checks the folders paused for the key. */
async function checkPaused() {
  const btn = $('#setPausedKeyCheck');
  const id = settings.loadId;
  say('setPrivMsg', '');
  let r;
  try { r = await whileBusy(btn, () => call('private.restore', { entries: [] })); }
  catch (e) { failed('setPrivMsg', e, "The paused folders couldn't be checked."); return; }
  if (id !== settings.loadId) return;
  if (r && r.saved === false && r.preview) { say('setPrivMsg', 'Preview: ' + asList(r.preview).join(' '), 'done'); return; }
  say('setPrivMsg', restoreText(r), 'done');
  await refreshConfig();
}

// ===== encrypted folders in PikPak ====================================================================

const NO_KEY_TEXT = 'Encrypted folders need a recovery key on this PC.';

function remoteFailed(e, fallback) {
  const text = messageOf(e, fallback);
  say('setRemoteMsg', e && e.code === 'refused' && /recovery key/i.test(text) ? NO_KEY_TEXT : text, 'problem');
}

function renderRemote() {
  const box = $('#setRemoteList');
  const list = settings.remote;
  if (!list) { box.replaceChildren(h('div', { class: 'srow empty', text: 'Press Show to see the encrypted folders in PikPak.' })); return; }
  if (!list.length) { box.replaceChildren(h('div', { class: 'srow empty', text: 'There are no encrypted folders in PikPak yet.' })); return; }
  box.replaceChildren(...list.map(f => {
    const size = f.bytes === null || f.bytes === undefined ? 'size not known' : fmtSize(f.bytes);
    const where = f.connectedTo ? 'Connected to ' + f.connectedTo + (f.paused ? ' (paused)' : '') : 'Not connected';
    const row = h('div', { class: 'srow' },
      h('span', {}, pikpakTip(h('span', { text: String(f.name) }), String(f.name)), h('span', { class: 'small path', text: size + ', ' + where })),
      h('button', { class: 'btn btn-quiet', text: 'Copy PikPak name', onclick: () => copyRemoteName(f) }));
    if (!f.connectedTo) {
      row.append(
        h('button', { class: 'btn', text: 'Reconnect' + ELLIPSIS, onclick: ev => reconnectRemote(f, ev.currentTarget) }),
        h('button', { class: 'btn', text: 'Download a copy' + ELLIPSIS, onclick: ev => downloadRemote(f, ev.currentTarget) }),
        h('button', { class: 'btn danger', text: 'Delete from PikPak', onclick: ev => deleteRemote(f, ev.currentTarget) }));
    }
    return row;
  }));
}

async function loadRemote() {
  const btn = $('#setRemoteShow');
  const id = settings.loadId;
  say('setRemoteMsg', 'Looking in PikPak' + ELLIPSIS, 'quiet');
  try {
    const r = await whileBusy(btn, () => call('private.remoteList'));
    if (id !== settings.loadId) return;   // Settings was left meanwhile
    settings.remote = asList(r && r.folders).filter(f => f && f.name);
    renderRemote();
    say('setRemoteMsg', '');
  } catch (e) { remoteFailed(e, "The encrypted folders in PikPak couldn't be listed. Try again."); }
}

/**
 * Reads the settings and the PikPak list again after a change that worked. Returns '' or a hint to add to the
 * success line (a failed refresh is not the action failing).
 */
async function refreshRemote() {
  try {
    settings.config = await call('config.get');
    renderPrivate();
    const r = await call('private.remoteList');
    settings.remote = asList(r && r.folders).filter(f => f && f.name);
    renderRemote();
    return '';
  } catch (e) {
    return "The list couldn't be read again. Press Show.";
  }
}

/** Copies an encrypted folder's scrambled name in PikPak, to find it on the PikPak website. */
async function copyRemoteName(f) {
  try {
    const text = await copyPikpakName(String(f.name));
    say('setRemoteMsg', 'Copied ' + text + ". That is '" + f.name + "' on the PikPak website.", 'done');
  } catch (e) { say('setRemoteMsg', "The PikPak name of '" + f.name + "' couldn't be worked out or copied. Try again.", 'problem'); }
}

/** Runs fn with every button of btn's row off, so a second click can't open a second picker or box. */
async function rowBusy(btn, fn) {
  const row = btn && btn.closest ? btn.closest('.srow') : null;
  const buttons = row ? [...row.querySelectorAll('button')] : [btn];
  if (buttons.some(b => b && b.disabled)) return;
  for (const b of buttons) if (b) b.disabled = true;
  try { return await fn(); } finally { for (const b of buttons) if (b) b.disabled = false; }
}

/** A success line plus the refresh hint, if the list couldn't be read again. */
const doneWith = (text, hint) => say('setRemoteMsg', hint ? text + ' ' + hint : text, 'done');

function reconnectRemote(f, btn) {
  return rowBusy(btn, async () => {
    say('setRemoteMsg', '');
    let path;
    try { path = await pickFolder("Choose a folder for '" + f.name + "'"); }
    catch (e) { say('setRemoteMsg', "The folder window didn't open. Try again.", 'problem'); return; }
    if (!path) return;
    say('setRemoteMsg', 'Reconnecting' + ELLIPSIS, 'quiet');
    let r;
    try { r = await call('folders.add', { path, encrypted: true, name: f.name, id: f.id || undefined }); }
    catch (e) { failed('setRemoteMsg', e, "The folder couldn't be reconnected."); return; }
    if (r && r.preview) { say('setRemoteMsg', 'Preview: ' + asList(r.preview).join(' '), 'done'); return; }
    doneWith("'" + f.name + "' is connected to " + path + '. Its files sync at the next sync.', await refreshRemote());
  });
}

function downloadRemote(f, btn) {
  return rowBusy(btn, async () => {
    say('setRemoteMsg', '');
    let path;
    try { path = await pickFolder("Choose an empty folder for a copy of '" + f.name + "'"); }
    catch (e) { say('setRemoteMsg', "The folder window didn't open. Try again.", 'problem'); return; }
    if (!path) return;
    try {
      const r = await call('private.download', { name: f.name, path });
      if (r && r.started === false && r.preview) { say('setRemoteMsg', 'Preview: ' + asList(r.preview).join(' '), 'done'); return; }
      say('setRemoteMsg', "Downloading '" + f.name + "' to " + path + ". You'll get a notification when it's done. The folder isn't synced.", 'done');
    } catch (e) { failed('setRemoteMsg', e, "The download couldn't be started."); }
  });
}

function deleteRemote(f, btn) {
  return rowBusy(btn, async () => {
    say('setRemoteMsg', '');
    const size = f.bytes === null || f.bytes === undefined ? 'size not known' : fmtSize(f.bytes);
    const ok = await settings.hooks.confirmBox({
      title: 'Delete from PikPak?',
      body: [h('p', { text: "Delete '" + f.name + "' (" + size + ") from PikPak? It goes to PikPak's trash. Your recovery key can't bring it back after the trash is emptied." })],
      ok: 'Delete from PikPak', danger: true
    });
    if (!ok) return;
    let r;
    try { r = await call('private.deleteRemote', { name: f.name }); }
    catch (e) { failed('setRemoteMsg', e, "The folder couldn't be deleted."); return; }
    if (r && r.deleted === false && r.preview) { say('setRemoteMsg', 'Preview: ' + asList(r.preview).join(' '), 'done'); return; }
    doneWith("'" + f.name + "' was deleted from PikPak. It's in PikPak's trash.", await refreshRemote());
  });
}

// ===== recovery key =================================================================================

function keyEntries(s) {
  if (s.kind === 'pair') return [{ label: 'Password', value: String(s.password || '') }, { label: 'Salt', value: String(s.salt || '') }];
  return [{ value: keyGroups(String(s.key || '').replace(/\s+/g, '')) }];
}

async function toggleKey(ev) {
  const btn = ev.currentTarget;
  if (settings.secret) { hideKey(); return; }
  say('setKeyMsg', '');
  const token = settings.keyToken;
  try {
    const d = await whileBusy(btn, () => call('key.show'));
    if (token !== settings.keyToken) return;   // Settings was left meanwhile: drop the key
    if (!d || (d.kind !== 'single' && d.kind !== 'pair')) throw { message: "The recovery key couldn't be read." };
    settings.secret = d.kind === 'pair'
      ? { kind: 'pair', password: String(d.password || ''), salt: String(d.salt || '') }
      : { kind: 'single', key: String(d.key || '') };
    renderKey();
  } catch (e) { failed('setKeyMsg', e, "The recovery key couldn't be read."); }
}

function renderKey() {
  const s = settings.secret;
  const tags = $('#setKeyTags');
  if (!s) { tags.replaceChildren(); $('#setKeyBox').hidden = true; $('#setShowKey').textContent = 'Show recovery key'; return; }
  tags.replaceChildren(...keyEntries(s).map(k => h('div', { class: 'tag' },
    k.label ? h('div', { class: 'tagname', text: k.label }) : null,
    h('div', { class: 'key', text: k.value }))));
  $('#setKeyBox').hidden = false;
  $('#setShowKey').textContent = 'Hide recovery key';
}

/** Clears the key from the page and from this file's state. */
function hideKey() {
  settings.keyToken++;
  settings.secret = null;
  clearKeySheet();
  renderKey();
  say('setKeyMsg', '');
}

/** The key sheet's lines (the saved file and the printout say the same). */
function sheet() {
  return keySheetLines({ keys: keyEntries(settings.secret), pcName: settings.hooks.pcName(), pair: settings.secret.kind === 'pair' });
}

function keyCopyText() {
  const s = settings.secret;
  return s.kind === 'pair' ? 'Password: ' + s.password + '\r\nSalt: ' + s.salt : keyGroups(String(s.key).replace(/\s+/g, ''));
}

async function copyKeyNow() {
  if (!settings.secret) return;
  try {
    await copyText(keyCopyText());
    say('setKeyMsg', 'Copied. Paste it somewhere safe, like a notes app on your phone.', 'done');
  } catch (e) { say('setKeyMsg', "The key couldn't be copied. Try Save to a file or Print instead.", 'problem'); }
}

async function saveKeyNow() {
  if (!settings.secret) return;
  say('setKeyMsg', '');
  let path;
  try { path = await pickSaveFile('Save your recovery key', KEY_FILE_NAME); }
  catch (e) { say('setKeyMsg', "The Save window didn't open. Try again.", 'problem'); return; }
  if (!path) return;
  if (isPreview()) { say('setKeyMsg', 'Preview: the key would be saved to ' + path + '. Nothing was saved.', 'done'); return; }
  try {
    await writeTextFile(path, keySheetText(sheet()));
    say('setKeyMsg', 'Saved to ' + path + '. Keep it somewhere other than this PC, like a USB stick.', 'done');
  } catch (e) { say('setKeyMsg', "The key couldn't be saved there. Try another place, like a USB stick.", 'problem'); }
}

function printKeyNow() {
  if (!settings.secret) return;
  say('setKeyMsg', '');
  fillKeySheet(sheet());
  try {
    window.print();
    say('setKeyMsg', 'The print window opened. Keep the printed key somewhere safe, away from this PC.', 'done');
  } catch (e) {
    clearKeySheet();
    say('setKeyMsg', "The print window didn't open. Try Save to a file instead.", 'problem');
  }
}

// ===== Windows start-up =======================================================

async function toggleAutostart(ev) {
  const box = ev.currentTarget;
  const want = box.checked;
  say('setAutoMsg', '');
  try {
    await whileBusy(box, () => setAutostart(want));
    say('setAutoMsg', want ? 'PikPak Sync will start when you sign in to Windows.' : "PikPak Sync won't start by itself.", 'done');
  } catch (e) {
    box.checked = !want;
    failed('setAutoMsg', e, "That couldn't be changed.");
  }
}

// ===== advanced =====================================================================================

function renderAdvanced(cfg) {
  const set = (id, v) => { $(id).value = v === null || v === undefined ? '' : String(v); };
  set('#advRun', cfg.DailyBudgetGB);
  set('#advMonth', cfg.MonthlyBudgetGB);
  set('#advDays', cfg.HoldingDays);
  set('#advDelete', cfg.MaxDeletePercent);
  set('#advHolding', cfg.LocalHolding);
}

async function browseInto(inputId, title) {
  try {
    const p = await pickFolder(title);
    if (p) $(inputId).value = p;
  } catch (e) { say('advMsg', "The folder window didn't open. Try again.", 'problem'); }
}

function numberField(id, label) {
  const text = $(id).value.trim().replace(',', '.');
  const n = Number(text);
  if (text === '' || !isFinite(n) || n <= 0 || !Number.isInteger(n)) {
    throw { message: label + ': use a whole number above 0.' };
  }
  return n;
}

async function saveAdvanced(ev) {
  const btn = ev.currentTarget;
  say('advMsg', '');
  try {
    const run = numberField('#advRun', 'Transfer limit per day');
    const month = numberField('#advMonth', 'Transfer limit per month');
    const days = numberField('#advDays', 'Keep deleted files for');
    const del = numberField('#advDelete', 'Stop and ask me');
    if (del > 100) throw { message: 'Stop and ask me: enter a percentage up to 100.' };
    const holding = $('#advHolding').value.trim();
    if (!holding) throw { message: 'Folder for deleted files: choose a folder.' };
    const from = $('#advBwFrom').value.trim(), to = $('#advBwTo').value.trim();
    const hoursEditable = !settings.bw.custom && $('#setBw').checked;   // fields are disabled while the switch is off
    if (hoursEditable && (!TIME_PATTERN.test(from) || !TIME_PATTERN.test(to))) {
      throw { message: 'Go easy on my internet: write the hours like 18:00 and 23:00.' };
    }
    say('advMsg', 'Saving' + ELLIPSIS, 'quiet');
    const cfg = await whileBusy(btn, () => saveConfigWith(c => {
      c.DailyBudgetGB = run; c.MonthlyBudgetGB = month; c.HoldingDays = days; c.MaxDeletePercent = del;
      c.LocalHolding = holding;
      if (hoursEditable) c.BwLimit = bwString(from, settings.bw.speed, to);
    }));
    renderAdvanced(cfg);
    renderBandwidth(cfg);
    say('advMsg', 'Saved.', 'done');
  } catch (e) {
    say('advMsg', messageOf(e, "The settings couldn't be saved."), 'problem');
  }
}

// ===== wiring =======================================================================================

/** Screen entry for app.js: {show, hide, inApp}. hooks: confirmBox, preview, pcName. */
export function settingsScreen(hooks) {
  settings.hooks = hooks;
  return { show, hide, inApp: true };
}

/** The tray paused or resumed while Settings is open: read the switch again. */
export function settingsTrayChanged() {
  loadSchedule();
}

export function wireSettings() {
  $('#setPause').addEventListener('change', togglePause);
  $('#setEvery').addEventListener('change', changeEvery);
  $('#setTime').addEventListener('change', changeTime);
  $('#setLogon').addEventListener('change', changeLogon);
  $('#setBw').addEventListener('change', toggleBandwidth);
  $('#setAddPrivate').addEventListener('click', addPrivate);
  $('#setNoKeyEnter').addEventListener('click', openUseKey);
  $('#setUseKeyForm').addEventListener('submit', e => { e.preventDefault(); checkUseKey(); });
  $('#setUseKeyPairLink').addEventListener('click', () => { useKeyBox.setPairMode(!useKeyBox.pairMode); say('setUseKeyMsg', ''); useKeyBox.focus(); });
  $('#setUseKeyCancel').addEventListener('click', closeUseKey);
  $('#setFoundCancel').addEventListener('click', leaveFound);
  $('#setPausedKeyCheck').addEventListener('click', checkPaused);
  $('#setFoundRestore').addEventListener('click', restoreFound);
  $('#setRemoteShow').addEventListener('click', loadRemote);
  $('#setShowKey').addEventListener('click', toggleKey);
  $('#setKeyCopy').addEventListener('click', copyKeyNow);
  $('#setKeySave').addEventListener('click', saveKeyNow);
  $('#setKeyPrint').addEventListener('click', printKeyNow);
  $('#setAutostart').addEventListener('change', toggleAutostart);
  $('#advHoldingBrowse').addEventListener('click', () => browseInto('#advHolding', 'Choose a folder for deleted files'));
  $('#advSave').addEventListener('click', saveAdvanced);
  // The key must not stay on screen when the window goes to the tray.
  document.addEventListener('visibilitychange', () => { if (document.hidden) { hideKey(); useKeyBox.clear(); } });
}
