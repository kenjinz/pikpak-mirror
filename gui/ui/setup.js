// First-time setup: Welcome -> Sign in -> Choose folders -> Recovery key (only with an encrypted folder) -> Done.
// After sign-in, restore.js first looks in PikPak for an earlier install's folders (Recovery key of that install,
// Found your folders); Done then restores them, and nothing found goes on to Choose folders. A backup found in PikPak
// is restored without a list: Done runs setup.finish at once and says what was restored.
// The sign-in screen doubles as "Sign in again" when Home finds that PikPak signed the user out.
//
// The recovery key lives only in `setup.key` and on the key screen until setup finishes. It goes nowhere
// but setup.finish's args and the file, printout or clipboard the user picks; it is never logged and is
// cleared from the page once setup.finish has run. The PikPak password is read from its field when the
// user signs in, sent once with setup.signin and never kept.

import { callFull, pickFolder, pickSaveFile, writeTextFile, copyText } from './bridge.js';
import { ELLIPSIS, CHECK, GIB, $, h, asList, say, messageOf, fmtSize, fmtLocalDay, baseName, keyGroups, keySheetLines, keySheetText, fillKeySheet, clearKeySheet } from './util.js';
import * as restore from './restore.js';

const KEY_FILE_NAME = 'PikPak recovery key.txt';
const MEASURE_SECONDS = 20;
const DAILY_BUDGET_GB = { free: 1, premium: 8 };   // DailyBudgetGB of each preset (Get-BudgetPreset)

const setup = {
  hooks: null,           // from app.js: go, preview(), pcName(), afterSetup(text, kind), afterSigninAgain(text, kind)
  again: false,          // the sign-in screen was opened from Home ("Sign in again")
  signingIn: false,
  account: null,         // setup.signin's answer: {email, totalBytes, usedBytes, preset}
  signinPreview: [],     // what sign-in would have done (preview mode)
  rows: null,            // folder rows; null until folders.suggest answered
  suggesting: false,
  suggestError: null,
  key: null,             // the new recovery key, 30 characters without spaces
  keyLoading: false,
  finishing: false,
  timedOut: false,       // the last setup.finish timed out (it may still be running)
  finished: false,       // setup.finish has run all its steps
  settingsWritten: false // a real run got as far as writing the config (folders can't change any more)
};

// ===== small helpers ================================================================================

const isPreview = () => !!(setup.hooks && setup.hooks.preview());
const chosenRows = () => (setup.rows || []).filter(r => r.on);
const anyPrivate = () => !restore.active() && chosenRows().some(r => r.priv);

function freeBytes() {
  const a = setup.account;
  if (!a) return 0;
  return Math.max(0, Number(a.totalBytes || 0) - Number(a.usedBytes || 0));
}

/** Total of the ticked folders: {bytes, incomplete (a size is only a lower bound), measuring, failed (ticked folders that couldn't be measured)}. */
function chosenTotal() {
  let bytes = 0;
  let incomplete = false;
  let measuring = false;
  let failed = 0;
  for (const r of chosenRows()) {
    if (r.measuring) { measuring = true; continue; }
    if (r.error) { failed++; continue; }
    bytes += r.bytes || 0;
    if (!r.complete) incomplete = true;
  }
  return { bytes, incomplete, measuring, failed };
}

function updateStepNumbers() {
  const total = restore.stepTotal() || (anyPrivate() ? 4 : 3);
  $('#stepSignin').textContent = 'Step 1 of ' + total;
  $('#stepFolders').textContent = 'Step 2 of ' + total;
  $('#stepDone').textContent = 'Step ' + total + ' of ' + total;
}

// ===== sign in ======================================================================================

function showSignin(params = {}) {
  setup.again = !!params.again;
  $('#stepSignin').hidden = setup.again;
  $('#signinTitle').textContent = setup.again ? 'Sign in to PikPak again' : 'Sign in to PikPak';
  $('#signinLead').textContent = setup.again
    ? 'PikPak signed you out. Sign in again so syncing can carry on. Use the same email and password as the PikPak app on your phone.'
    : 'Use the same email and password as the PikPak app on your phone.';
  updateStepNumbers();
  if (!setup.signingIn) say('signinMsg', '');
  $('#signinPassword').value = '';
  const email = $('#signinEmail');
  if (!email.value && setup.account && setup.account.email) email.value = setup.account.email;
  (email.value ? $('#signinPassword') : email).focus();
}

function setSigninBusy(busy) {
  setup.signingIn = busy;
  for (const id of ['#signinEmail', '#signinPassword', '#signinBtn', '#signinBack']) $(id).disabled = busy;
}

async function signIn() {
  if (setup.signingIn) return;
  const email = $('#signinEmail').value.trim();
  if (!email || !$('#signinPassword').value) {
    say('signinMsg', 'Type your PikPak email and password.', 'problem');
    return;
  }
  setSigninBusy(true);
  say('signinMsg', 'Checking your PikPak account' + ELLIPSIS, 'busy');
  // The first sign-in may also install rclone: say so once it takes a while.
  const slow = setTimeout(() => {
    say('signinMsg', 'Checking your PikPak account' + ELLIPSIS + ' The first time, this also gets PikPak Sync ready and can take a few minutes.', 'busy');
  }, 15000);
  let result = null;
  let failure = null;
  try {
    result = await callFull('setup.signin', { email, password: $('#signinPassword').value });
  } catch (e) {
    failure = e;
  } finally {
    clearTimeout(slow);
    setSigninBusy(false);
  }
  if (failure) {
    let text = messageOf(failure, "Signing in didn't work. Try again.");
    if (failure.code === 'auth') text = "PikPak didn't accept that email and password.";
    else if (failure.code === 'network') text = "Couldn't reach PikPak. Check your internet connection and try again.";
    say('signinMsg', text, 'problem');
    if (failure.code === 'auth') $('#signinPassword').select();
    return;
  }
  $('#signinPassword').value = '';
  say('signinMsg', '');
  const data = (result && result.data) || {};
  const previewLines = asList(data.preview).map(String);
  if (setup.again) {
    if (previewLines.length) setup.hooks.afterSigninAgain('Preview: ' + previewLines.join(' ') + ' Nothing was changed.', 'quiet');
    else setup.hooks.afterSigninAgain("You're signed in again. The next sync runs as usual.", 'done');
    return;
  }
  const before = setup.account;
  setup.account = {
    email: String(data.email || email),
    totalBytes: Number(data.totalBytes) || 0,
    usedBytes: Number(data.usedBytes) || 0,
    preset: data.preset === 'premium' ? 'premium' : 'free'
  };
  setup.signinPreview = previewLines;
  // Another account (or different free space): tick again what fits, keeping what the user chose.
  if (before && freeBytesOf(before) !== freeBytes()) preTick();
  // An earlier install's folders (backup or ID files) and encrypted folders come first; nothing found: Choose folders.
  restore.afterSignin(setup.account);
}

function freeBytesOf(a) {
  return Math.max(0, Number(a.totalBytes || 0) - Number(a.usedBytes || 0));
}

// ===== choose folders ===============================================================================

function showFolders() {
  updateStepNumbers();
  if (setup.rows === null && !setup.suggesting) loadSuggestions();
  renderFolders();
}

async function loadSuggestions() {
  setup.suggesting = true;
  setup.suggestError = null;
  renderFolders();
  let list = null;
  try {
    list = asList((await callFull('folders.suggest')).data);
  } catch (e) {
    setup.suggestError = e;
  }
  setup.suggesting = false;
  if (list) {
    setup.rows = list.filter(f => f && f.exists && f.path).map(f => newRow(String(f.name || baseName(f.path)), String(f.path), false));
    setup.rows.forEach(measure);
  }
  renderFolders();
}

function newRow(name, path, chosenByUser) {
  return { name, path, on: chosenByUser, touched: chosenByUser, priv: false, bytes: 0, complete: false, measuring: true, error: '' };
}

/** Measures one folder in the background; once nothing is measuring any more, ticks what fits. */
async function measure(row) {
  row.measuring = true;
  row.error = '';
  try {
    const s = (await callFull('folders.size', { path: row.path, maxSeconds: MEASURE_SECONDS })).data || {};
    row.bytes = Number(s.bytes) || 0;
    row.complete = s.complete === true;
  } catch (e) {
    row.error = messageOf(e, "This folder couldn't be measured.");
  }
  row.measuring = false;
  if (!(setup.rows || []).some(r => r.measuring)) preTick();
  if (setup.hooks.current() === 'folders') renderFolders();
}

/**
 * Ticks, in list order, the folders the user hasn't touched that fit in the free PikPak space next to
 * what is already ticked. A folder too big to measure quickly isn't ticked (it may not fit).
 */
function preTick() {
  if (!setup.rows || !setup.account) return;
  const free = freeBytes();
  let used = 0;
  for (const r of setup.rows) if (r.touched && r.on && !r.error) used += r.bytes || 0;
  for (const r of setup.rows) {
    if (r.touched || r.measuring) continue;
    r.on = !r.error && r.complete && used + r.bytes <= free;
    if (r.on) used += r.bytes;
    else r.priv = false;
  }
}

function renderFolders() {
  const list = $('#folderList');
  const focused = document.activeElement && list.contains(document.activeElement) ? document.activeElement.dataset.focus : null;

  if (setup.rows === null) {
    if (setup.suggestError) {
      list.replaceChildren(h('div', { class: 'lrow empty' },
        h('span', { text: messageOf(setup.suggestError, "Your folders couldn't be listed.") + ' ' }),
        h('button', { class: 'btn btn-quiet', text: 'Try again', onclick: () => loadSuggestions() })));
    } else {
      list.replaceChildren(h('div', { class: 'lrow empty', text: 'Looking for your folders' + ELLIPSIS }));
    }
  } else if (!setup.rows.length) {
    list.replaceChildren(h('div', { class: 'lrow empty', text: 'Add the folders you want to sync.' }));
  } else {
    list.replaceChildren(...setup.rows.map((r, i) => {
      const box = h('input', { type: 'checkbox', 'aria-label': 'Sync ' + r.name, 'data-focus': 'on' + i });
      box.checked = r.on;
      box.addEventListener('change', () => {
        r.on = box.checked;
        r.touched = true;
        if (!r.on) r.priv = false;
        renderFolders();
      });
      const lock = h('input', { type: 'checkbox', 'aria-label': 'Make ' + r.name + ' encrypted', 'data-focus': 'priv' + i });
      lock.checked = r.priv;
      lock.disabled = !r.on;
      lock.addEventListener('change', () => { r.priv = lock.checked; renderFolders(); });
      let size;
      if (r.measuring) size = 'Measuring' + ELLIPSIS;
      else if (r.error) size = '?';
      else size = (r.complete ? '' : 'more than ') + fmtSize(r.bytes);
      return h('div', { class: 'frow' + (r.on ? '' : ' off') },
        box,
        h('div', {},
          h('div', { class: 'fname', text: r.name }),
          h('div', { class: 'fpath', text: r.path, title: r.path }),
          r.error ? h('div', { class: 'fissue warn' },
            "Couldn't measure this folder. ",
            h('button', { class: 'btn btn-quiet', text: 'Measure again', title: r.error, 'aria-label': 'Measure ' + r.name + ' again', onclick: () => { measure(r); renderFolders(); } })) : null),
        h('div', { class: 'fsize', text: size }),
        h('label', { class: 'lock' }, lock, ' Encrypted'));
    }));
  }
  if (focused) {
    const again = list.querySelector('[data-focus="' + focused + '"]');
    if (again) again.focus();
  }
  renderSpace();
  updateStepNumbers();
}

function renderSpace() {
  const a = setup.account;
  const free = freeBytes();
  const t = chosenTotal();
  const over = !!a && t.bytes > free;
  $('#setupSpaceFill').style.width = (free > 0 ? Math.min(100, t.bytes / free * 100) : (t.bytes > 0 ? 100 : 0)) + '%';
  $('#setupSpaceBar').classList.toggle('over', over);
  let used;
  if (t.measuring) used = 'Measuring' + ELLIPSIS;
  else used = (t.incomplete ? 'At least ' : '') + fmtSize(t.bytes) + ' of ' + fmtSize(free) + (a && a.usedBytes > 0 ? ' free' : '');
  if (!t.measuring && t.failed) used += ". Some sizes are unknown";
  $('#setupSpaceUsed').textContent = a ? used : '';
  $('#setupSpaceAcct').textContent = a
    ? (a.preset === 'premium' ? 'PikPak Premium, ' : 'Free PikPak account, ') + fmtSize(a.totalBytes)
    : '';
  const warn = $('#setupSpaceWarn');
  warn.hidden = !over;
  warn.textContent = over
    ? "That's " + fmtSize(t.bytes - free) + ' more than your PikPak has room for. Untick something, or '
      + (a.preset === 'premium' ? 'make room in your PikPak first.' : 'upgrade to PikPak Premium for more space.')
    : '';
  $('#foldersNext').disabled = !a || over || t.measuring || t.failed > 0 || chosenRows().length === 0 || setup.suggesting;
}

async function addAnotherFolder() {
  say('folderListMsg', '');
  let path;
  try {
    path = await pickFolder('Choose a folder to sync');
  } catch (e) {
    say('folderListMsg', "The folder picker didn't open. Try again.", 'problem');
    return;
  }
  if (!path) return;
  const norm = p => String(p).replace(/[\\/]+$/, '').toLowerCase();
  if (setup.rows === null) setup.rows = [];
  const already = setup.rows.find(r => norm(r.path) === norm(path));
  if (already) {
    already.on = true;
    already.touched = true;
    say('folderListMsg', already.name + ' is already in the list. It is ticked now.', 'quiet');
    renderFolders();
    return;
  }
  const row = newRow(baseName(path) || path, path, true);
  setup.rows.push(row);
  renderFolders();
  measure(row);
}

function foldersNext() {
  if ($('#foldersNext').disabled) return;
  setup.hooks.go(anyPrivate() ? 'key' : 'done');
}

// ===== recovery key =================================================================================

function showKey() {
  updateStepNumbers();
  $('#keyNext').disabled = !$('#keyKept').checked;
  if (setup.key) { $('#keyText').textContent = keyGroups(setup.key); return; }
  if (!setup.keyLoading) loadKey();
}

async function loadKey() {
  setup.keyLoading = true;
  $('#keyText').textContent = ELLIPSIS;
  say('keyLoadMsg', '');
  setKeyButtons(false);
  try {
    const data = (await callFull('setup.newkey')).data || {};
    const key = String(data.key || '').replace(/\s+/g, '');
    if (!/^[A-Z2-9]{30}$/.test(key)) throw { message: "A recovery key couldn't be made. Try again." };
    setup.key = key;
    $('#keyText').textContent = keyGroups(key);
    setKeyButtons(true);
  } catch (e) {
    $('#keyText').textContent = '';
    say('keyLoadMsg', messageOf(e, "A recovery key couldn't be made. Go back and try again."), 'problem');
  } finally {
    setup.keyLoading = false;
  }
}

function setKeyButtons(enabled) {
  for (const id of ['#keySave', '#keyPrint', '#keyCopy', '#keyKept']) $(id).disabled = !enabled;
  if (!enabled) $('#keyNext').disabled = true;
}

function keyNote(text, ok = true) {
  const el = $('#keyMsg');
  el.classList.toggle('bad', !ok);
  el.textContent = text ? (ok ? CHECK + ' ' : '') + text : '';
}

/** The key sheet's lines (the saved file and the printout say the same). */
function sheet() {
  return keySheetLines({ keys: [{ value: keyGroups(setup.key) }], pcName: setup.hooks.pcName() });
}

async function saveKey() {
  if (!setup.key) return;
  keyNote('');
  let path;
  try {
    path = await pickSaveFile('Save your recovery key', KEY_FILE_NAME);
  } catch (e) {
    keyNote("The Save window didn't open. Try again.", false);
    return;
  }
  if (!path) return;
  if (isPreview()) {
    keyNote('Preview: the key would be saved to ' + path + '. Nothing was saved.');
    return;
  }
  try {
    await writeTextFile(path, keySheetText(sheet()));
    keyNote('Saved to ' + path + '. Keep it somewhere other than this PC, like a USB stick.');
  } catch (e) {
    keyNote("The key couldn't be saved there. Try another place, like a USB stick.", false);
  }
}

function printKey() {
  if (!setup.key) return;
  keyNote('');
  fillKeySheet(sheet());
  try {
    window.print();
    keyNote('The print window opened. Keep the printed key somewhere safe, away from this PC.');
  } catch (e) {
    clearKeySheet();
    keyNote("The print window didn't open. Try Save to a file instead.", false);
  }
}

async function copyKey() {
  if (!setup.key) return;
  try {
    await copyText(keyGroups(setup.key));
    keyNote('Copied. Paste it somewhere safe, like a notes app on your phone.');
  } catch (e) {
    keyNote("The key couldn't be copied. Try Save to a file or Print instead.", false);
  }
}

/** Forgets the recovery key everywhere on the page (after setup.finish has run). */
function forgetKey() {
  setup.key = null;
  $('#keyText').textContent = '';
  clearKeySheet();
  $('#keyKept').checked = false;
  keyNote('');
}

// ===== done =========================================================================================

let progressTimer = null;

function showDone() {
  updateStepNumbers();
  if (setup.timedOut) { renderTimedOut(); return; }
  if (!setup.finishing && !setup.finished) runFinish(false);
}

function finishArgs(resume) {
  const preset = setup.account ? setup.account.preset : 'free';
  // A restore: the earlier install's folders and settings instead of the chosen folders; no new key.
  if (restore.active()) {
    const args = { restore: restore.restoreArg(), preset };
    if (resume) args.resume = true;
    return args;
  }
  const args = {
    folders: chosenRows().map(r => ({ path: r.path, private: !!r.priv })),
    preset
  };
  if (anyPrivate() && setup.key) args.recoveryKey = setup.key;
  if (resume) args.resume = true;
  return args;
}

function resetDone() {
  $('#doneLead').textContent = '';
  $('#doneRestored').hidden = true;
  $('#doneRestored').replaceChildren();
  for (const id of ['#doneSteps', '#donePreview', '#doneActions', '#doneRetryActions', '#doneHomeActions']) $(id).hidden = true;
  say('doneMsg', '');
  say('doneProgress', '');
}

async function runFinish(resume) {
  if (setup.finishing || retryTimer) return;   // during the hold the first run may still be going
  setup.timedOut = false;
  setup.finishing = true;
  resetDone();
  $('#doneTitle').textContent = 'Setting up your PC';
  const started = Date.now();
  const tick = () => {
    const s = Math.round((Date.now() - started) / 1000);
    const took = s < 60 ? s + ' s' : Math.floor(s / 60) + ' min ' + (s % 60) + ' s';
    say('doneProgress', 'Setting up your PC' + ELLIPSIS + ' This can take a few minutes; you can leave this window open. (' + took + ' so far)', 'busy');
  };
  tick();
  clearInterval(progressTimer);
  progressTimer = setInterval(tick, 1000);

  let data = null;
  let failure = null;
  try {
    data = (await callFull('setup.finish', finishArgs(resume))).data || {};
  } catch (e) {
    failure = e;
  } finally {
    clearInterval(progressTimer);
    progressTimer = null;
    say('doneProgress', '');
    setup.finishing = false;
  }
  if (failure) {
    if (failure.timedOut === true) {
      setup.timedOut = true;
      holdRetry();
      renderTimedOut();
    } else {
      renderFinishFailed([], null, messageOf(failure, "Setup couldn't finish. Try again."));
    }
    return;
  }

  const steps = asList(data.steps);
  const preview = isPreview();
  const previewLines = asList(data.preview).map(String);
  // Under preview no step is "done"; a failed step is the one that has no preview line.
  const failed = preview
    ? (steps.length > previewLines.length ? steps[steps.length - 1] : null)
    : (data.complete === true ? null : (steps.find(s => !s.done) || steps[steps.length - 1] || {}));
  if (!preview && steps.some(s => s.name === 'Settings' && s.done)) setup.settingsWritten = true;
  if (failed) { renderFinishFailed(steps, failed, ''); return; }

  setup.finished = true;
  forgetKey();
  $('#doneTitle').textContent = "You're all set";
  renderRestored(data.restored);
  $('#doneLead').textContent = firstSyncSentence();
  if (preview) {
    $('#donePreviewList').replaceChildren(...[...setup.signinPreview, ...restore.previewLines(), ...previewLines].map(t => h('li', { text: t })));
    $('#donePreview').hidden = false;
  } else {
    renderSteps(steps, null);
  }
  $('#doneActions').hidden = false;
  $('#doneStart').disabled = false;
  $('#doneStart').focus();
}

let retryTimer = null;
const RETRY_HOLD_MS = 5 * 60 * 1000;
/**
 * After a timeout the first setup.finish may still be running. For 5 minutes no new run can start
 * (runFinish refuses, Back is hidden, showDone only shows the message). The timer lives in setup
 * state, so leaving and coming back neither resets nor skips it.
 */
function holdRetry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(() => {
    retryTimer = null;
    if (setup.hooks.current() === 'done' && setup.timedOut) renderTimedOut();
  }, RETRY_HOLD_MS);
}

function renderTimedOut() {
  const holding = !!retryTimer;
  resetDone();
  $('#doneTitle').textContent = 'Setup is taking a while';
  $('#doneLead').textContent = 'Nothing is lost. Setup may still be finishing in the background.';
  say('doneMsg', holding
    ? 'Setup may still be finishing in the background. You can try again in a few minutes.'
    : 'You can try again now.', holding ? 'problem' : 'busy');
  $('#doneBack').hidden = holding || setup.settingsWritten;
  $('#doneRetry').disabled = holding;
  $('#doneRetryActions').hidden = false;
  if (!holding) $('#doneRetry').focus();
}

function renderSteps(steps, failed) {
  const list = $('#doneSteps');
  list.replaceChildren(...steps.map(s => {
    const bad = s === failed;
    return h('div', { class: 'lrow step-row' },
      h('span', { class: bad ? 'step-mark bad' : 'step-mark', text: bad ? '!' : CHECK, 'aria-hidden': 'true' }),
      h('div', {},
        h('div', { class: 'fname', text: String(s.name || '') }),
        s.message ? h('div', { class: bad ? 'fissue' : 'fpath', text: String(s.message), title: String(s.message) }) : null),
      h('span', { class: bad ? 'pill bad' : 'pill', text: bad ? "Didn't work" : 'Done' }));
  }));
  list.hidden = steps.length === 0;
}

function renderFinishFailed(steps, failed, message) {
  $('#doneTitle').textContent = 'Setup stopped part-way';
  $('#doneLead').textContent = steps.length
    ? 'The steps with a tick are done. Fix what the last step says, then try again to finish the rest.'
    : 'Nothing more was done.';
  renderSteps(steps, failed);
  if (message) say('doneMsg', message, 'problem');
  // Once the settings are written the chosen folders can't change here any more (Home can add more).
  $('#doneBack').hidden = setup.settingsWritten;
  $('#doneRetryActions').hidden = false;
  if (!$('#doneRetry').disabled) $('#doneRetry').focus();
}

/**
 * What a restore did (setup.finish's `restored`): how many folders came back and which still wait. Only shown when this
 * setup is a restore: a normal setup that is resumed gets a `restored` too and says nothing of it.
 */
function renderRestored(restored) {
  const box = $('#doneRestored');
  if (!restore.active() || !restored) { box.hidden = true; box.replaceChildren(); return; }
  const count = Number(restored.count) || 0;
  const day = fmtLocalDay(restored.saved);
  const lines = ['Restored ' + count + (count === 1 ? ' folder' : ' folders') + ' from your backup' + (day ? ' of ' + day : '') + '.'];
  const drives = asList(restored.driveMissing).map(String);
  const paused = asList(restored.pausedForKey).map(String);
  if (drives.length) lines.push('Waiting for a drive: ' + drives.join(', ') + '.');
  if (paused.length) lines.push('Paused until you enter your recovery key: ' + paused.join(', ') + '.');
  for (const p of asList(restored.problems)) lines.push(String((p && p.name) || '') + ': ' + String((p && p.reason) || ''));
  box.replaceChildren(...lines.map(t => h('p', { class: 'lead', style: 'margin-bottom:.5rem', text: t })));
  box.hidden = false;
}

/** "takes about N days": N = ceil(chosen GB / DailyBudgetGB of the preset). */
function firstSyncSentence() {
  if (restore.active()) {
    return 'Your folders come down from PikPak over the first syncs. After that, it runs every hour while your PC is on.';
  }
  const t = chosenTotal();
  const preset = setup.account && setup.account.preset === 'premium' ? 'premium' : 'free';
  const budget = DAILY_BUDGET_GB[preset];
  const gb = t.bytes / GIB;
  if (!t.incomplete && gb <= budget) {
    return 'Your first sync takes a few minutes. After that, it runs every hour while your PC is on.';
  }
  const n = Math.max(1, Math.ceil(gb / budget));
  const days = n + (n === 1 ? ' day' : ' days');
  const allowance = preset === 'premium'
    ? 'PikPak lets a Premium account upload about ' + budget + ' GB each day'
    : 'PikPak lets a free account upload about ' + budget + ' GB each day';
  return 'Your first sync is ' + (t.incomplete ? 'more than ' : '') + fmtSize(t.bytes) + '. ' + allowance
    + ', so it finishes in ' + (t.incomplete ? 'at least ' : 'about ') + days
    + '. After that, only new and changed files are synced.';
}

async function startFirstSync() {
  const btn = $('#doneStart');
  btn.disabled = true;
  say('doneMsg', 'Starting your first sync' + ELLIPSIS, 'busy');
  try {
    const data = (await callFull('sync.start')).data || {};
    const lines = asList(data.preview).map(String);
    say('doneMsg', '');
    if (lines.length) setup.hooks.afterSetup('Preview: ' + lines.join(' ') + ' Nothing was started.', 'quiet');
    else setup.hooks.afterSetup('Your first sync has started. You can keep using your PC.', 'done');
  } catch (e) {
    btn.disabled = false;
    say('doneMsg', messageOf(e, "The sync couldn't start. Try again, or go to Home."), 'problem');
    $('#doneHomeActions').hidden = false;
  }
}

// ===== wiring =======================================================================================

/** The setup screens for app.js's router. hooks: go, current(), preview(), pcName(), afterSetup, afterSigninAgain. */
export function setupScreens(hooks) {
  setup.hooks = hooks;
  return {
    welcome: {},
    signin: { show: showSignin },
    folders: { show: showFolders },
    key: { show: showKey },
    done: { show: showDone }
  };
}

export function wireSetup() {
  const go = name => setup.hooks.go(name);
  $('#welcomeNext').addEventListener('click', () => go('signin'));
  $('#signinForm').addEventListener('submit', e => { e.preventDefault(); signIn(); });
  $('#signinBack').addEventListener('click', () => go(setup.again ? 'home' : 'welcome'));
  $('#setupAddFolder').addEventListener('click', addAnotherFolder);
  $('#foldersBack').addEventListener('click', () => go('signin'));
  $('#foldersNext').addEventListener('click', foldersNext);
  $('#keySave').addEventListener('click', saveKey);
  $('#keyPrint').addEventListener('click', printKey);
  $('#keyCopy').addEventListener('click', copyKey);
  $('#keyKept').addEventListener('change', e => { $('#keyNext').disabled = !e.target.checked || !setup.key; });
  $('#keyBack').addEventListener('click', () => go('folders'));
  $('#keyNext').addEventListener('click', () => { if (setup.key && $('#keyKept').checked) go('done'); });
  $('#doneRetry').addEventListener('click', () => runFinish(true));
  $('#doneBack').addEventListener('click', () => go(restore.active() ? 'found' : 'folders'));
  $('#doneStart').addEventListener('click', startFirstSync);
  $('#doneHome').addEventListener('click', () => setup.hooks.afterSetup('', 'quiet'));
  // The printed sheet is only needed while printing.
  window.addEventListener('afterprint', clearKeySheet);
}
