// Talks to the Rust shell (Tauri commands) and, through it, to the PowerShell bridge.
// Every bridge answer is an envelope {ok, data | error, warning?}; call() unwraps it.

const HELPER_FAILED = Object.freeze({
  code: 'internal',
  message: "PikPak Sync couldn't start its helper. Try again; if it keeps happening, restart the app."
});
// The Rust side stopped a call at its deadline: the work may still be finishing in the background.
const TIMED_OUT = Object.freeze({
  code: 'internal',
  timedOut: true,
  message: 'This is taking longer than expected. Check again in a few minutes; it may still finish.'
});

// Preview mode (app started with --preview-setup): every call asks for a preview.
let previewAll = false;

// Actions that change the config: once one has worked (not under preview), the folder list backup in PikPak is
// brought up to date in the background (backup.push uploads only when the list changed).
const PUSH_AFTER = new Set([
  'config.save', 'folders.add', 'folders.remove', 'folders.convert', 'folders.pause', 'folders.resume',
  'folders.locate', 'folders.adopt', 'folders.newId', 'folders.ensureIds', 'private.add', 'private.remove',
  'private.restore', 'schedule.set'
]);

/** Fire and forget: a failed backup upload never fails the change that came before it. */
function pushBackup() {
  call('backup.push')
    .then(d => { if (d && d.error) console.warn('backup.push did not upload:', String(d.error)); })
    .catch(e => console.warn('backup.push failed:', e && e.message ? e.message : e));
}

/** Turns preview mode on for every later call (the Rust side enforces it too). */
export function setPreviewAll(on) {
  previewAll = on === true;
}

function tauri() {
  const t = window.__TAURI__;
  if (!t || !t.core || typeof t.core.invoke !== 'function') throw new Error('Tauri API missing');
  return t;
}

/** A Tauri command (app_info, set_tray_status, ...). Rejects with whatever Rust returned. */
export function invoke(cmd, args = {}) {
  return tauri().core.invoke(cmd, args);
}

/**
 * Runs one bridge action. Resolves {data, warning} on ok; rejects with {code, message} otherwise.
 * `warning` is the envelope's optional quiet note (null when there is none).
 */
export async function callFull(action, args = {}, { preview } = {}) {
  let envelope;
  const asPreview = preview === true || previewAll;
  try {
    envelope = await invoke('gui_action', { action, args: args || {}, preview: asPreview });
  } catch (e) {
    // The rejection is the Rust side's own text ("internal: ..."), never the request or its secrets.
    console.error('gui_action ' + action + ' failed:', e);
    throw e === 'internal: timed out' ? { ...TIMED_OUT } : { ...HELPER_FAILED };
  }
  if (envelope && envelope.ok === true) {
    if (!asPreview && PUSH_AFTER.has(action)) pushBackup();
    return { data: envelope.data, warning: envelope.warning || null };
  }
  const err = (envelope && envelope.error) || {};
  throw {
    code: err.code || 'internal',
    message: err.message || 'Something went wrong in PikPak Sync. Details are in the log.'
  };
}

/** Runs one bridge action: resolves `data` on ok, rejects with {code, message} otherwise. */
export async function call(action, args = {}, { preview } = {}) {
  return (await callFull(action, args, { preview })).data;
}

// ----- plugins (global API when injected, plain plugin commands otherwise) -----

/** Windows' folder picker. Resolves the chosen path or null. */
export async function pickFolder(title) {
  const options = { directory: true, multiple: false, title };
  const t = tauri();
  const r = t.dialog ? await t.dialog.open(options) : await invoke('plugin:dialog|open', { options });
  return typeof r === 'string' && r ? r : null;
}

/**
 * Windows' Save dialog. Resolves the chosen path or null. The dialog plugin adds the picked path
 * to the fs scope, so writeTextFile may write there (and only there).
 */
export async function pickSaveFile(title, defaultPath) {
  const options = { title, defaultPath, filters: [{ name: 'Text file', extensions: ['txt'] }] };
  const t = tauri();
  const r = t.dialog ? await t.dialog.save(options) : await invoke('plugin:dialog|save', { options });
  return typeof r === 'string' && r ? r : null;
}

/** Writes a text file to a path the user picked in pickSaveFile. */
export async function writeTextFile(path, text) {
  const t = tauri();
  if (!t.fs || typeof t.fs.writeTextFile !== 'function') throw new Error('file API missing');
  return t.fs.writeTextFile(path, text);
}

/**
 * Puts text on the Windows clipboard. The Clipboard API refuses while the window isn't focused;
 * the older copy command still works then (its helper text box is removed straight away).
 */
export async function copyText(text) {
  try {
    if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
      await navigator.clipboard.writeText(text);
      return;
    }
  } catch (e) { /* fall back below */ }
  const box = document.createElement('textarea');
  box.value = text;
  box.setAttribute('readonly', '');
  box.style.position = 'fixed';
  box.style.opacity = '0';
  document.body.append(box);
  let ok = false;
  try {
    box.select();
    ok = document.execCommand('copy');
  } finally {
    box.value = '';
    box.remove();
  }
  if (!ok) throw new Error('clipboard refused');
}

/** Opens a folder in File Explorer. */
export async function openPath(path) {
  const t = tauri();
  if (t.opener && typeof t.opener.openPath === 'function') return t.opener.openPath(path);
  return invoke('plugin:opener|open_path', { path });
}

/** Opens a URL with its Windows handler; only URLs the capability's scope allows (PikPak's web page). */
export async function openUrl(url) {
  const t = tauri();
  if (t.opener && typeof t.opener.openUrl === 'function') return t.opener.openUrl(url);
  return invoke('plugin:opener|open_url', { url });
}

/** Whether the app starts when the user signs in to Windows. */
export async function autostartEnabled() {
  const t = tauri();
  if (t.autostart && typeof t.autostart.isEnabled === 'function') return t.autostart.isEnabled();
  return invoke('plugin:autostart|is_enabled');
}

/** Turns "start when I sign in to Windows" on or off. */
export async function setAutostart(on) {
  const t = tauri();
  if (t.autostart && typeof t.autostart.enable === 'function') return on ? t.autostart.enable() : t.autostart.disable();
  return invoke(on ? 'plugin:autostart|enable' : 'plugin:autostart|disable');
}

/** Listens to an app event (e.g. 'tray-action'). Does nothing when the event API is missing. */
export async function listen(event, handler) {
  const t = window.__TAURI__;
  if (t && t.event && typeof t.event.listen === 'function') return t.event.listen(event, handler);
  return () => {};
}
