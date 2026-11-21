// PikPak Sync page: a small router and one show/render function per screen.
// Home, Get back a deleted file and Free up space are built here; the first-time setup screens live in
// setup.js (and restore.js for an earlier install's folders); Settings lives in settings.js.
// No inline handlers (the CSP blocks them): every handler is attached with addEventListener.

import { call, callFull, invoke, openPath, openUrl, listen, pickFolder, setPreviewAll } from './bridge.js';
import { ELLIPSIS, GIB, $, $$, h, asList, say, messageOf, fmtSize, fmtDay, baseName } from './util.js';
import { initFolderBoxes, addFolder, addEncryptedFolder, pauseFolder, locateFolder, adoptFolder, giveNewId, chooseSameId } from './folders.js';
import { setupScreens, wireSetup } from './setup.js';
import { restoreScreens, wireRestore } from './restore.js';
import { pikpakTip, copyPikpakName } from './pikpak-name.js';
import { settingsScreen, wireSettings, settingsTrayChanged } from './settings.js';

// ===== confirm box ==================================================================================

let confirmResolve = null;

/**
 * Shows the in-page box. choices: [{key, text, danger?, disabled?}]; the last one is the primary button.
 * Resolves the chosen key, or '' when the box was cancelled (Cancel, Escape, another box replacing it).
 */
function openBox({ title, body = [], cancel = 'Cancel', choices }) {
  const dlg = $('#confirmBox');
  if (confirmResolve) { confirmResolve(''); confirmResolve = null; }
  $('#confirmTitle').textContent = title;
  $('#confirmBody').replaceChildren(...body.filter(Boolean));
  const okBtn = $('#confirmOk');
  $$('#confirmBox .choice').forEach(b => b.remove());
  for (const c of choices.slice(0, -1)) {
    okBtn.before(h('button', {
      class: 'btn choice' + (c.danger ? ' danger' : ''), text: c.text, disabled: !!c.disabled,
      onclick: () => dlg.close(c.key)
    }));
  }
  const last = choices[choices.length - 1];
  okBtn.textContent = last.text;
  okBtn.dataset.key = last.key;
  okBtn.disabled = !!last.disabled;
  okBtn.classList.toggle('danger', !!last.danger);
  $('#confirmCancel').textContent = cancel;
  dlg.returnValue = '';
  return new Promise(resolve => {
    confirmResolve = resolve;
    if (dlg.open) dlg.close();
    dlg.showModal();
    $('#confirmCancel').focus();
  });
}

/** In-page confirm. body: array of nodes. Resolves true only when the OK button was pressed. */
function confirmBox({ title, body = [], ok = 'OK', cancel = 'Cancel', danger = false }) {
  return openBox({ title, body, cancel, choices: [{ key: 'ok', text: ok, danger }] }).then(k => k === 'ok');
}

/** A box with more than one way forward (choices as in openBox). Resolves the chosen key, or null on cancel. */
function chooseBox({ title, body = [], cancel = 'Cancel', choices }) {
  return openBox({ title, body, cancel, choices }).then(k => (k && k !== 'cancel' ? k : null));
}

function initConfirmBox() {
  const dlg = $('#confirmBox');
  $('#confirmOk').addEventListener('click', ev => dlg.close(ev.currentTarget.dataset.key || 'ok'));
  $('#confirmCancel').addEventListener('click', () => dlg.close('cancel'));
  // Escape closes the dialog with an empty returnValue: that's a cancel.
  dlg.addEventListener('close', () => {
    const r = confirmResolve;
    confirmResolve = null;
    if (r) r(dlg.returnValue);
  });
}

// ===== router =======================================================================================

const app = {
  info: null,      // app_info(): {preview_setup, repo_root, version, pc_name, app_name}
  current: 'loading'
};

// What the setup screens (setup.js) need from the rest of the page.
const setupHooks = {
  go: (name, params) => go(name, params),
  current: () => app.current,
  preview: () => !!(app.info && app.info.preview_setup),
  pcName: () => (app.info && app.info.pc_name) || '',
  confirmBox: opts => confirmBox(opts),
  /** Setup is done (or skipped to Home): Home starts polling; `text` is shown under its status. */
  afterSetup(text, kind) {
    home.started = true;
    go('home');
    if (text) say('homeMsg', text, kind);
    pollSoon();
  },
  /** Signed in again from Home's "PikPak signed you out". */
  afterSigninAgain(text, kind) {
    go('home');
    if (text) say('homeMsg', text, kind);
    pollStatus();
    refreshSpace();
  }
};

const screens = {
  loading: {},
  // `setup` is the entry: the welcome screen, or with {signin: true} the sign-in screen in "sign in again" mode.
  setup: { show: params => go(params.signin ? 'signin' : 'welcome', { again: !!params.signin }) },
  ...setupScreens(setupHooks),
  ...restoreScreens(setupHooks),
  home: { show: showHome, inApp: true },
  restore: { show: showRestore, inApp: true },
  settings: settingsScreen({
    confirmBox,
    changeKind: (path, to, msgId) => changeKind(path, to, msgId),
    preview: () => !!(app.info && app.info.preview_setup),
    pcName: () => (app.info && app.info.pc_name) || ''
  })
};

function go(name, params = {}) {
  const screen = screens[name];
  if (!screen) return;
  closeMenus();
  const left = screens[app.current];
  if (left && left.hide && app.current !== name) left.hide();
  app.current = name;
  $$('.screen').forEach(s => s.classList.toggle('on', s.id === 's-' + name));
  $('#appbar').hidden = !screen.inApp;
  window.scrollTo(0, 0);
  if (screen.show) screen.show(params);
}

document.addEventListener('click', e => {
  const g = e.target.closest('[data-go]');
  if (g) go(g.dataset.go);
});

// ===== home =========================================================================================

const home = {
  status: null,    // last GuiStatus
  error: null,     // {code, message} when the last status call failed
  space: null,     // {used, total} from `about` or the status, whichever came last
  spaceError: null,
  started: false,  // polling runs once the app is set up
  inflight: null,
  again: false,
  lastPoll: 0,
  timer: null,
  fastUntil: 0,    // poll every 10 s until then (right after Sync now / Repair)
  configBusy: false
};

const isRunning = () => !!home.status && home.status.Situation === 'running';

function showHome() {
  renderHome();
  refreshSpace();
  if (home.started && Date.now() - home.lastPoll > 5000) pollStatus();
}

/** Starts the status polling; the setup flow calls this once the app is set up. */
function startPolling() {
  home.started = true;
  pollStatus();
}

/** Reads `status`; repeats every 10 s while a run is going (or just started), else every 60 s. */
function pollStatus() {
  if (!home.started) return Promise.resolve();
  if (home.inflight) { home.again = true; return home.inflight; }
  clearTimeout(home.timer);
  home.inflight = (async () => {
    try {
      home.status = await call('status');
      home.error = null;
      const sp = home.status.Space || {};
      if (sp.UsedBytes !== null && sp.UsedBytes !== undefined && sp.TotalBytes) {
        home.space = { used: Number(sp.UsedBytes), total: Number(sp.TotalBytes) };
      }
    } catch (e) {
      home.error = e;
    }
    home.lastPoll = Date.now();
    if (app.current === 'home') renderHome();
    updateTray();
  })().finally(() => {
    home.inflight = null;
    if (home.again) { home.again = false; pollStatus(); return; }
    const fast = isRunning() || Date.now() < home.fastUntil;
    clearTimeout(home.timer);
    home.timer = setTimeout(pollStatus, fast ? 10000 : 60000);
  });
  return home.inflight;
}

function pollSoon() {
  home.fastUntil = Date.now() + 2 * 60 * 1000;
  clearTimeout(home.timer);
  home.timer = setTimeout(pollStatus, 3000);
}

function onWindowBack() {
  if (home.started && Date.now() - home.lastPoll > 3000) pollStatus();
}
window.addEventListener('focus', onWindowBack);
document.addEventListener('visibilitychange', () => { if (!document.hidden) onWindowBack(); });

/** "PikPak Sync", or "PikPak Sync (dev · <folder>)" when the app runs scripts from a repo or worktree. */
function appName() {
  return (app.info && app.info.app_name) || 'PikPak Sync';
}

function updateTray() {
  let tone = 'attention';
  const name = appName();
  let tooltip = name + ": couldn't check your folders";
  const s = home.status;
  if (!home.error && s) {
    tone = s.Situation === 'running' ? 'working' : (s.Tone === 'ok' ? 'ok' : 'attention');
    tooltip = name + ': ' + (s.Title || '');
    // Keeps the tray's Pause/Resume item right when syncing was paused or resumed elsewhere.
    if (s.Situation !== 'config-error') invoke('set_tray_paused', { paused: s.Situation === 'paused' }).catch(() => {});
  }
  invoke('set_tray_status', { tone, tooltip }).catch(() => {});
}

function renderHome() {
  renderStatusBlock();
  renderFolders();
  renderSpace();
  renderDay();
  renderMonth();
}

function renderStatusBlock() {
  const st = $('#status');
  let tone = '';
  let title = 'Checking your folders' + ELLIPSIS;
  let detail = '';
  const actions = [];
  const s = home.status;
  if (home.error) {
    tone = 'bad';
    title = "Couldn't check your folders";
    detail = messageOf(home.error, 'Try again in a moment.');
    actions.push(h('button', { class: 'btn btn-primary', text: 'Try again', onclick: () => pollStatus() }));
  } else if (s) {
    tone = s.Tone === 'warn' || s.Tone === 'bad' ? s.Tone : '';
    title = s.Title || '';
    detail = s.Detail || '';
    if (s.Situation === 'signed-out') {
      actions.push(h('button', { class: 'btn btn-primary', text: 'Sign in again', onclick: () => go('setup', { signin: true }) }));
    } else if (s.Situation === 'config-error') {
      actions.push(h('button', { class: 'btn btn-primary', text: 'Open settings', onclick: () => go('settings') }));
    } else if (s.Situation !== 'running') {
      const broken = asList(s.Folders).find(canRepair);
      if (s.Situation === 'attention' && broken) {
        actions.push(h('button', { class: 'btn', text: 'Repair ' + broken.Name, onclick: () => repairFolder(broken) }));
      }
      actions.push(h('button', { class: 'btn btn-primary', text: 'Sync now', onclick: ev => backUpNow(ev.currentTarget) }));
    }
  }
  st.className = 'status' + (tone ? ' ' + tone : '');
  const parts = [h('div', {}, h('h3', { text: title }), h('p', { text: detail }))];
  if (actions.length) parts.push(h('div', { class: 'row-actions' }, actions));
  st.replaceChildren(...parts);
  renderBackupNote();
}

/** The quiet note when the folder list hasn't reached PikPak for a while (status.backup.stale). */
function renderBackupNote() {
  const el = $('#homeBackupNote');
  const b = !home.error && home.status && home.status.backup;
  const since = b && b.stale === true ? fmtDay(String(b.failingSince || '').slice(0, 10)) : '';
  el.textContent = since ? "Your folder list couldn't be backed up to PikPak since " + since + '.' : '';
  el.hidden = !since;
}

async function backUpNow(btn) {
  if (btn) btn.disabled = true;
  say('homeMsg', 'Starting the sync' + ELLIPSIS, 'busy');
  try {
    await call('sync.start');
    say('homeMsg', 'Sync started. You can keep using your PC.', 'done');
    pollSoon();
  } catch (e) {
    say('homeMsg', messageOf(e, "The sync couldn't start. Try again."), 'problem');
  } finally {
    if (btn) btn.disabled = false;
  }
}

function pillClass(tone) {
  return tone === 'wait' || tone === 'warn' || tone === 'bad' ? 'pill ' + tone : 'pill';
}

// The sync skipped these folders because of their ID: the row's own buttons sort them out, not Repair
// (a repair would merge into the same check and skip again).
const ID_ISSUES = ['folder-identity-mismatch', 'folder-marker-missing', 'folder-duplicate-id'];
const canRepair = f => f.Pill === 'Needs attention' && !ID_ISSUES.includes(f.IssueKind);

/** The buttons on a folder's row: Resume, Locate..., Use this folder anyway, Choose... */
function rowButtons(f) {
  const off = isRunning();
  const btn = (text, fn) => h('button', {
    class: 'btn', text, disabled: off, title: off ? 'A sync is running. Try again when it has finished.' : null, onclick: fn
  });
  const out = [];
  if (f.Paused) {
    out.push(btn('Resume', () => pauseFolder(f, false)));
  } else if (f.IssueKind === 'folder-duplicate-id') {
    out.push(btn('Choose' + ELLIPSIS, () => chooseSameId(f)));
  } else if (f.IssueKind === 'folder-identity-mismatch' || f.IssueKind === 'folder-marker-missing') {
    out.push(btn('Locate' + ELLIPSIS, () => locateFolder(f)));
    out.push(btn('Use this folder anyway', () => adoptFolder(f)));
  } else if (f.Missing === 'folder') {
    // A drive that isn't connected only waits: no button.
    out.push(btn('Locate' + ELLIPSIS, () => locateFolder(f)));
  }
  return out.length ? h('div', { class: 'row-actions row-btns' }, out) : null;
}

function renderFolders() {
  // Don't pull the rows away while a folder menu is open; the next poll catches up.
  if ($('#homeFolders .menu')) return;
  const list = $('#homeFolders');
  const s = home.status;
  if (!s) {
    list.replaceChildren(h('div', { class: 'hrow' },
      h('span', { class: 'small', text: home.error ? "Your folders couldn't be listed." : 'Checking' + ELLIPSIS })));
    return;
  }
  const folders = asList(s.Folders);
  if (!folders.length) {
    list.replaceChildren(h('div', { class: 'hrow' }, h('span', { class: 'small', text: 'No folders are synced yet.' })));
    return;
  }
  list.replaceChildren(...folders.map(f => {
    const more = h('button', {
      class: 'btn btn-quiet more', text: '\u22EF', title: 'More', 'aria-label': 'Options for ' + f.Name,
      'aria-haspopup': 'menu', 'aria-expanded': 'false'
    });
    const row = h('div', { class: f.Paused ? 'hrow paused' : 'hrow' },
      h('div', {},
        h('div', { class: 'fname' }, f.Name, f.Private ? [' ', pikpakTip(h('span', { class: 'pill wait', text: 'Encrypted' }), f.Name)] : null),
        h('div', { class: 'fpath', text: f.Local || '', title: f.Local || '' }),
        f.Issue ? h('div', { class: f.PillTone === 'bad' ? 'fissue' : 'fissue warn', text: f.Issue }) : null,
        rowButtons(f)),
      h('span', { class: pillClass(f.PillTone), text: f.Pill }),
      more);
    more.addEventListener('click', () => {
      const open = more.getAttribute('aria-expanded') === 'true';
      closeMenus();
      if (!open) openFolderMenu(row, more, f);
    });
    return row;
  }));
}

function openFolderMenu(row, button, f) {
  // While a sync or a change runs, a second change or Repair would be refused anyway: show them off.
  const running = isRunning();
  const items = [['Open folder', () => openFolder(f.Local)]];
  if (f.Private) items.push(['Copy PikPak folder name', () => copyPikpakFolder(f)]);
  if (canRepair(f)) items.push(['Repair', () => repairFolder(f), null, running]);
  // A paused folder can't be changed (the change syncs it one last time first): Resume it first.
  if (!f.Paused) {
    items.push(f.Private
      ? ['Remove encryption', () => changeKind(f.Local, 'plain'), null, running]
      : ['Make encrypted', () => changeKind(f.Local, 'encrypted'), null, running]);
  }
  items.push(['Give a new ID', () => giveNewId(f), null, running]);
  items.push(f.Paused
    ? ['Resume', () => pauseFolder(f, false), null, running]
    : ['Pause syncing', () => pauseFolder(f, true), null, running]);
  if (f.Private) {
    // Inside a synced folder, "Stop syncing" would upload the files readable with that folder: only the job is offered.
    if (!f.InsidePair) items.push(['Stop syncing', () => removeEncrypted(f), 'danger']);
  } else {
    items.push(['Stop syncing', () => removeFolder(f), 'danger']);
  }
  const menu = h('div', { class: 'menu', role: 'menu' }, items.map(([text, fn, cls, off]) =>
    h('button', {
      role: 'menuitem', class: cls || null, text, disabled: !!off, title: off ? 'A sync is running. Try again when it has finished.' : null,
      onclick: () => { closeMenus(); fn(); }
    })));
  row.append(menu);
  button.setAttribute('aria-expanded', 'true');
  menu.querySelector('button').focus();
}

function closeMenus() {
  $$('.menu').forEach(m => m.remove());
  $$('.more[aria-expanded="true"]').forEach(b => b.setAttribute('aria-expanded', 'false'));
}
document.addEventListener('click', e => {
  if (!e.target.closest('.menu') && !e.target.closest('.more')) closeMenus();
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeMenus(); });

/** Copies the encrypted folder's scrambled name in PikPak, to find it on the PikPak website. */
async function copyPikpakFolder(f) {
  try {
    const text = await copyPikpakName(f.Name);
    say('foldersMsg', 'Copied ' + text + '. That is ' + f.Name + ' on the PikPak website.', 'done');
  } catch (e) {
    say('foldersMsg', 'The PikPak name of ' + f.Name + " couldn't be worked out or copied. Try again.", 'problem');
  }
}

async function openFolder(path) {
  try {
    await openPath(path);
  } catch (e) {
    say('foldersMsg', "Couldn't open " + path + '. Check that the folder is still there.', 'problem');
  }
}

async function removeFolder(f) {
  if (home.configBusy) return;
  const all = asList(home.status && home.status.Folders);
  const pairs = all.filter(x => !x.Private);
  // The last synced folder may go when an encrypted folder remains; only the very last folder is kept.
  if (pairs.length <= 1 && all.length <= 1) {
    say('foldersMsg', 'Keep at least one folder, or pause syncing instead.', 'problem');
    return;
  }
  const ok = await confirmBox({
    title: 'Stop syncing ' + f.Name + '?',
    body: [
      h('p', { text: 'Nothing is deleted: the folder stays on this PC, and its copy stays in PikPak.' }),
      h('p', { text: 'New and changed files in it are no longer synced.' }),
      h('p', { text: 'To stop for a while instead, use Pause syncing.' })
    ],
    ok: 'Stop syncing',
    danger: true
  });
  if (!ok) return;
  home.configBusy = true;
  say('foldersMsg', 'Removing ' + f.Name + ' from syncing' + ELLIPSIS, 'busy');
  try {
    await call('folders.remove', { name: f.Name });
    say('foldersMsg', f.Name + ' is no longer synced. Nothing was deleted.', 'done');
    await pollStatus();
  } catch (e) {
    say('foldersMsg', messageOf(e, "That folder couldn't be removed. Try again."), 'problem');
  } finally {
    home.configBusy = false;
  }
}

/**
 * Add an encrypted folder: also a folder inside a synced folder, which Add a folder can't take. A folder that is
 * synced already is changed instead (the Make encrypted box).
 */
async function addEncrypted(btn) {
  if (home.configBusy) return;
  say('foldersMsg', '');
  let path;
  try { path = await pickFolder('Choose a folder to encrypt'); }
  catch (e) { say('foldersMsg', "The folder window didn't open. Try again.", 'problem'); return; }
  if (!path) return;
  const same = p => String(p || '').replace(/[\\/]+$/, '').toLowerCase();
  btn.disabled = true;
  try {
    const synced = asList(home.status && home.status.Folders).find(f => !f.Private && same(f.Local) === same(path));
    if (synced) await changeKind(path, 'encrypted');
    else await addEncryptedFolder(path, 'foldersMsg');
  } finally {
    btn.disabled = false;
  }
}

/** Stop syncing an encrypted folder (private.remove). Only for a folder that is not inside a synced folder (the menu hides it there). */
async function removeEncrypted(f) {
  if (home.configBusy) return;
  const all = asList(home.status && home.status.Folders);
  if (all.length <= 1) {
    say('foldersMsg', 'Keep at least one folder, or pause syncing instead.', 'problem');
    return;
  }
  const ok = await confirmBox({
    title: 'Stop syncing ' + f.Name + '?',
    body: [
      h('p', { text: 'Nothing is deleted: the folder stays on this PC.' }),
      h('p', { text: 'New and changed files in it are no longer synced.' }),
      h('p', { text: 'Its encrypted copy stays in PikPak. You can reconnect it or delete it in Settings, under Encryption.' }),
      h('p', { text: 'To stop for a while instead, use Pause syncing.' })
    ],
    ok: 'Stop syncing',
    danger: true
  });
  if (!ok) return;
  home.configBusy = true;
  say('foldersMsg', 'Removing ' + f.Name + ' from syncing' + ELLIPSIS, 'busy');
  try {
    await call('private.remove', { path: f.Local });
    say('foldersMsg', f.Name + ' is no longer synced separately. Nothing was deleted.', 'done');
    await pollStatus();
  } catch (e) {
    say('foldersMsg', messageOf(e, "That folder couldn't be removed. Try again."), 'problem');
  } finally {
    home.configBusy = false;
  }
}

/**
 * Change a folder between synced and encrypted (to: 'encrypted' | 'plain'). Asks first, then starts the
 * background job (folders.convert). msgId: where the progress line goes (Home's or Settings'). Returns true
 * when the job was started.
 */
async function changeKind(path, to, msgId = 'foldersMsg') {
  if (home.configBusy) return false;
  home.configBusy = true;
  try {
    say(msgId, 'Checking the folder' + ELLIPSIS, 'busy');
    let r;
    try { r = await call('folders.convertReview', { path, to }); }
    catch (e) { say(msgId, messageOf(e, "The folder couldn't be checked. Try again."), 'problem'); return false; }
    say(msgId, '');
    const name = r.name || baseName(path);
    const toEnc = to === 'encrypted';
    const canDelete = r.canDeleteOldCopy !== false;
    const hasSize = r.sizeGB !== null && r.sizeGB !== undefined;
    const sizeText = hasSize ? ' (' + (r.sizeComplete === false ? 'more than ' : '') + fmtSize(Number(r.sizeGB) * GIB) + ')' : '';
    const del = h('input', { type: 'checkbox', checked: canDelete, disabled: !canDelete });
    const body = [
      h('p', { text: toEnc
        ? "PikPak can't read " + name + " afterwards. Another app needs your recovery key to open the files."
        : 'PikPak can read the files in ' + name + ' afterwards. They are no longer locked with your recovery key.' }),
      h('p', { text: 'The folder is uploaded again' + sizeText + ". That counts toward your daily transfer limit." }),
      r.note ? h('p', { text: String(r.note) }) : null,
      h('p', { text: 'The old copy is ' + (r.oldCopyPlace || 'in PikPak') + '.' }),
      h('label', { class: 'check' }, del,
        h('span', {}, h('b', { text: 'Delete the old copy from PikPak' }), h('br'),
          h('span', { class: 'small', text: canDelete
            ? "It goes to PikPak's trash. Empty the trash there to remove it for good."
            : "It can't be deleted safely, so it stays in PikPak." })))
    ];
    const ok = await confirmBox({
      title: toEnc ? 'Make ' + name + ' encrypted?' : 'Remove encryption from ' + name + '?',
      body,
      ok: toEnc ? 'Make encrypted' : 'Remove encryption'
    });
    if (!ok) return false;
    say(msgId, 'Starting the change' + ELLIPSIS, 'busy');
    let started;
    try {
      started = await call('folders.convert', { path, to, deleteOldCopy: canDelete && del.checked });
    } catch (e) {
      say(msgId, messageOf(e, "The change couldn't start. Try again."), 'problem');
      return false;
    }
    if (started && started.started === false) {
      // Preview mode: nothing was started.
      say(msgId, 'Preview: ' + asList(started.preview).map(String).join(' ') + ' Nothing was changed.', 'done');
      return false;
    }
    say(msgId, 'Changing ' + name + '. This runs in the background; you get a notification when it is done.', 'done');
    pollSoon();
    return true;
  } finally {
    home.configBusy = false;
  }
}

/** Repair = Invoke-Sync -Resync <name> (private:<name> for an encrypted folder); the README's "A folder keeps failing" comes first. */
async function repairFolder(f) {
  const ok = await confirmBox({
    title: 'Repair ' + f.Name + '?',
    // Delete-safety: Repair merges both sides, so it brings the deleted files back.
    body: f.IssueKind === 'delete-safety' ? [
      f.Issue ? h('p', { text: f.Issue }) : null,
      h('p', { text: 'Nothing was deleted: the sync of this folder stopped on purpose.' }),
      h('ul', {},
        h('li', { text: 'Repair brings the deleted files back: it merges this PC and PikPak, so every file that is still on one side is copied to the other again.' }),
        h('li', { text: "Copying them back counts against PikPak's upload limit, so a big folder can take several days." }),
        h('li', { text: "If you deleted the files on purpose, don't repair. Raise 'Stop and ask me if a sync would delete more than' in Settings, Advanced, for one sync, then set it back." }))
    ] : [
      f.Issue ? h('p', { text: f.Issue }) : null,
      h('p', { text: 'Nothing was deleted: the sync of this folder stopped on purpose.' }),
      h('ul', {},
        h('li', { text: "If PikPak's copy was deleted by mistake, restore it from the PikPak app's Trash if you can, then wait for the next sync." }),
        h('li', { text: 'Otherwise, Repair merges this PC and PikPak. Nothing is deleted; if a file differs on the two sides, the replaced copy is kept in your deleted files for 30 days.' }),
        h('li', { text: "Whatever is missing is uploaded. That counts against PikPak's upload limit, so a big folder can take several days." }),
        h('li', { text: 'If you really meant to delete the folder from PikPak, delete it on this PC instead, or remove it from syncing.' }))
    ],
    ok: 'Repair'
  });
  if (!ok) return;
  say('homeMsg', 'Starting the repair of ' + f.Name + ELLIPSIS, 'busy');
  try {
    await call('sync.repair', { name: f.Name, private: !!f.Private });
    say('homeMsg', 'Repairing ' + f.Name + '. It runs in the background; you can keep using your PC.', 'done');
    pollSoon();
  } catch (e) {
    say('homeMsg', messageOf(e, "The repair couldn't start. Try again."), 'problem');
  }
}

let spaceInflight = false;
async function refreshSpace() {
  if (spaceInflight || !home.started) return;
  spaceInflight = true;
  try {
    const a = await call('about');
    if (a && a.usedBytes !== null && a.usedBytes !== undefined && a.totalBytes) {
      home.space = { used: Number(a.usedBytes), total: Number(a.totalBytes) };
    }
    home.spaceError = null;
  } catch (e) {
    home.spaceError = e;
  } finally {
    spaceInflight = false;
  }
  if (app.current === 'home') renderSpace();
}

function setBar(barId, fillId, pct, over) {
  $('#' + fillId).style.width = Math.max(0, Math.min(100, pct)) + '%';
  $('#' + barId).classList.toggle('over', !!over);
}

function renderSpace() {
  const sp = home.space;
  if (!sp || !sp.total) {
    setBar('spaceBar', 'spaceFill', 0, false);
    $('#spaceText').textContent = home.spaceError || home.error ? "Couldn't check right now." : 'Checking' + ELLIPSIS;
    return;
  }
  const pct = sp.used / sp.total * 100;
  setBar('spaceBar', 'spaceFill', pct, pct >= 90);
  $('#spaceText').textContent = fmtSize(sp.used) + ' of ' + fmtSize(sp.total) + ' used';
}

function renderDay() {
  const d = home.status && home.status.Day;
  if (!d) {
    setBar('dayBar', 'dayFill', 0, false);
    $('#dayText').textContent = home.error ? "Couldn't check right now." : 'Checking' + ELLIPSIS;
    return;
  }
  const used = Number(d.UsedGB) || 0;
  const budget = Number(d.BudgetGB) || 0;
  const pct = budget ? used / budget * 100 : 0;
  setBar('dayBar', 'dayFill', pct, budget && pct >= 100);
  $('#dayText').textContent = fmtSize(used * GIB) + (budget ? ' of ' + fmtSize(budget * GIB) : '');
}

function renderMonth() {
  const m = home.status && home.status.Month;
  if (!m) {
    setBar('monthBar', 'monthFill', 0, false);
    $('#monthText').textContent = home.error ? "Couldn't check right now." : 'Checking' + ELLIPSIS;
    return;
  }
  const used = Number(m.UsedGB) || 0;
  const budget = Number(m.BudgetGB) || 0;
  const pct = budget ? used / budget * 100 : 0;
  setBar('monthBar', 'monthFill', pct, budget && pct >= 100);
  $('#monthText').textContent = fmtSize(used * GIB) + (budget ? ' of ' + fmtSize(budget * GIB) : '');
}

/** PikPak's own web page, in the default browser. */
async function openPikpak(btn) {
  btn.disabled = true;
  say('shortcutMsg', '');
  try {
    await openUrl('https://mypikpak.com/drive');
  } catch (e) {
    say('shortcutMsg', messageOf(e, "PikPak couldn't be opened in your browser. Try again."), 'problem');
  } finally {
    btn.disabled = false;
  }
}

// ===== get back a deleted file ======================================================================

const restore = {
  items: null,           // HoldingItem list, null while loading or after a failed listing
  failed: false,         // the last listing failed: no list, only Try again
  restored: new Map(),   // item key -> restoredTo
  restoring: new Set(),  // item keys with a restore under way
  seq: 0
};

const itemKey = it => [it.Source, it.Date, it.Private ? 'enc' : 'plain', it.Pair, it.RelPath].join('|');

async function showRestore() {
  const seq = ++restore.seq;
  restore.items = null;
  restore.failed = false;
  renderRestore();
  say('restoreMsg', 'Looking for deleted files' + ELLIPSIS, 'busy');
  let items = null;
  let note = '';
  let kind = 'quiet';
  try {
    const r = await callFull('holding.list');
    items = asList(r.data);
    note = r.warning || '';
  } catch (e) {
    // Never "No deleted files" after a failed listing: the error and Try again, no list.
    note = messageOf(e, "The deleted files couldn't be listed. Try again.");
    kind = 'problem';
  }
  if (seq !== restore.seq) return;
  restore.items = items;
  restore.failed = items === null;
  say('restoreMsg', note, kind);
  renderRestore();
}

function renderRestore() {
  const list = $('#restoreList');
  if (restore.failed) {
    list.hidden = false;
    list.replaceChildren(h('div', { class: 'lrow empty' }, h('button', { class: 'btn', text: 'Try again', onclick: showRestore })));
    return;
  }
  if (restore.items === null) { list.hidden = true; list.replaceChildren(); return; }
  list.hidden = false;
  const q = $('#restoreSearch').value.trim().toLowerCase();
  const shown = restore.items.filter(it => !q
    || String(it.Name || '').toLowerCase().includes(q)
    || String(it.RelPath || '').toLowerCase().includes(q));
  if (!restore.items.length) {
    list.replaceChildren(h('div', { class: 'lrow empty', text: 'No deleted files from the last 30 days.' }));
    return;
  }
  if (!shown.length) {
    list.replaceChildren(h('div', { class: 'lrow empty', text: 'No deleted files match "' + $('#restoreSearch').value.trim() + '".' }));
    return;
  }
  list.replaceChildren(...shown.map(it => {
    const rel = String(it.RelPath || '');
    const cut = rel.lastIndexOf('\\');
    const from = 'From ' + it.Pair + (cut > 0 ? '\\' + rel.slice(0, cut) : '');
    const key = itemKey(it);
    const done = restore.restored.get(key);
    let action;
    if (done !== undefined) {
      action = h('span', { class: 'pill', text: 'Back in ' + it.Pair, title: done || '' });
    } else if (restore.restoring.has(key)) {
      action = h('button', { class: 'btn', text: 'Restoring' + ELLIPSIS, disabled: true });
    } else {
      action = h('button', { class: 'btn', text: 'Restore', onclick: () => restoreItem(it) });
    }
    return h('div', { class: 'lrow' },
      h('div', {}, h('div', { class: 'fname', text: it.Name }), h('div', { class: 'fpath', text: from, title: it.RestoreTo || '' }, ...(it.Private ? [' ', h('span', { class: 'pill wait', text: 'Encrypted' })] : []))),
      h('span', { class: 'small', text: 'Deleted ' + fmtDay(it.Date) }),
      action);
  }));
}

async function restoreItem(it) {
  // One restore per item at a time: a re-drawn list (search, reopening the screen) shows it as under way.
  const key = itemKey(it);
  if (restore.restoring.has(key) || restore.restored.has(key)) return;
  restore.restoring.add(key);
  renderRestore();
  say('restoreMsg', '');
  try {
    const r = await call('holding.restore', { item: it });
    const to = (r && r.restoredTo) || '';
    restore.restored.set(key, to);
    if (to && baseName(to) !== it.Name) {
      say('restoreMsg', it.Name + ' is back as "' + baseName(to) + '", because a file with that name is already there.', 'done');
    }
  } catch (e) {
    say('restoreMsg', messageOf(e, it.Name + " couldn't be restored. Try again."), 'problem');
  } finally {
    restore.restoring.delete(key);
    renderRestore();
  }
}

// ===== start-up =====================================================================================

function wire() {
  initConfirmBox();
  initFolderBoxes({
    confirmBox,
    chooseBox,
    rows: () => asList(home.status && home.status.Folders),
    isBusy: () => home.configBusy,
    setBusy: on => { home.configBusy = !!on; },
    refresh: () => pollStatus(),
    refreshSoon: () => pollSoon()
  });
  wireSetup();
  wireRestore();
  wireSettings();
  $('#addFolder').addEventListener('click', () => addFolder());
  $('#addEncrypted').addEventListener('click', ev => addEncrypted(ev.currentTarget));
  $('#openPikpak').addEventListener('click', ev => openPikpak(ev.currentTarget));
  $('#restoreSearch').addEventListener('input', renderRestore);
  // The tray's Sync now / Pause run outside the page: look at the status again afterwards.
  listen('tray-action', ev => {
    const p = (ev && ev.payload) || {};
    if (p.action === 'sync.start' && p.result && p.result.ok) pollSoon();
    else pollStatus();
    if (app.current === 'settings') settingsTrayChanged();
  }).catch(() => {});
}

async function start() {
  wire();
  try { app.info = await invoke('app_info'); } catch (e) { app.info = null; }
  document.title = appName();
  $('.appname').textContent = appName();
  if (app.info && app.info.preview_setup) {
    // Preview mode walks the setup screens whatever this PC has; every call runs as a preview.
    setPreviewAll(true);
    $('#previewBanner').hidden = false;
    go('setup');
    return;
  }
  try {
    await call('config.get');
  } catch (e) {
    if (e && e.code === 'config-missing') { go('setup'); return; }
    // Anything else (a broken settings file, the helper not starting): Home shows it as its status.
  }
  home.started = true;
  go('home'); // showHome reads `status` and `about`, and polling carries on from there
  runCleanupOnce();
}

/**
 * One-time cleanup of what the old version left on this PC (drives, Explorer menu, old sync trigger).
 * Runs once per app start, after the first status read so Home is never delayed. A failure is ignored
 * here: the bridge has already logged it.
 */
async function runCleanupOnce() {
  try {
    if (home.inflight) await home.inflight;
    await call('cleanup');
  } catch (e) { /* logged by the bridge; never blocks the app */ }
  // Folders set up before folder IDs get theirs once (adopting an ID file already in the folder).
  // While a sync runs it answers `later`; the next app start tries again.
  try {
    const r = await call('folders.ensureIds');
    if (r && Number(r.assigned) > 0 && !asList(r.preview).length) pollStatus();
  } catch (e) {
    console.error('folders.ensureIds failed:', e);
  }
}

start();
