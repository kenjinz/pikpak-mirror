# PikPak Backup desktop app: design

Date: 2026-10-25. Status: agreed in brainstorming; to be planned and built.
Prototype the look and flow are taken from: [2026-10-25-desktop-app-prototype.html](2026-10-25-desktop-app-prototype.html) (approved as "go with this one first"; open it in a browser).

## Why

PikPak Mirror works, but using it means PowerShell commands, editing `config\mirror.config.psd1` in Notepad, typing `SAVED` / `YES` / `a` / `b` at prompts and reading `Get-Status.ps1` tables.
The owner wants a normal Windows app instead: open it, see whether the backup is fine, change folders and paths with a folder-picker dialog, and never type a command.
Success = the owner can do everything in [README.md](../../README.md) that they do day to day without opening PowerShell or Notepad.

The user for now is **the owner, on this Windows 11 PC**. Build what is convenient for them first and improve later.

## Goals

1. A desktop window with the prototype's screens: first-time setup, Home, Get back a deleted file, Free up space, Settings.
2. On this PC (already installed and live) it opens straight to **Home**, reading the real config, state and PikPak.
3. Every path is chosen with a **folder-picker dialog** (Windows' own), never typed: backed-up folders, private folders, holding folder, cache folder.
4. Everything the scripts currently ask for interactively has a screen or a sensible default instead.
5. A tray icon so the window can be closed while the app keeps showing status.

## Non-goals (for now)

- Linux / macOS.
- A polished installer for other people's PCs. The app runs from this repo on this PC; a Start-menu shortcut is enough.
- Rewriting the sync engine. The PowerShell scripts and their 353 tests stay the engine. Small, tested extensions are allowed where the app needs them (see *Engine changes*).
- The second-PC "Viewer" role and full new-PC restore in the app (RECOVERY.md stays the way to do that).
- Storage-space checking (OPEN-REQUIREMENTS R2) and trash cleanup (R3). The app only *shows* space; R2/R3 are separate work.

## Anti-goals (would make this a failure even if it works)

- The app shows "backed up" when the last run actually failed or never ran.
- A secret (PikPak password, recovery key) ends up in a log, on the app-to-PowerShell command line, or in a file the scripts write. (PowerShell passing it on to rclone as arguments, as `Install.ps1` already does under rule R16, stays accepted on this single-user PC.)
- The app writes a config that the engine rejects or reads differently, or silently drops pairs.
- A private folder gets uploaded unencrypted because the app skipped the existing private-path safety checks.

## How it's built (decided)

- **Window:** **Tauri 2 (Rust)**, the owner's choice. It uses the WebView2 runtime already on Windows 11. The UI is the prototype's HTML/CSS/JS, plain (no front-end framework, no npm build step needed for the page itself), shipped as the app's frontend.
- **Toolchain:** Rust (rustup, stable, `x86_64-pc-windows-msvc`) and the Visual Studio Build Tools C++ workload must be installed on this PC first; neither is installed today. Node is installed and can run the Tauri CLI if wanted, but `cargo tauri` alone is fine.
- **Engine:** the existing PowerShell 5.1 scripts. The app never re-implements sync logic.
- **Bridge:** one new entry script `scripts/Invoke-GuiAction.ps1 -Action <name>` that reads a JSON request on **stdin** and writes one JSON result on stdout. All new logic it needs lives as testable functions in a new `scripts/lib/Gui.ps1` (Pester tests in `tests/Gui.Tests.ps1`), following the existing rules in [global-constraints.md](../notes/global-constraints.md) (PS 5.1 syntax, unit tests never touch rclone/network/registry).
- **Rust stays thin:** window, tray icon (Tauri tray API), native dialogs (`tauri-plugin-dialog`: folder picker, file picker, save dialog), starting PowerShell processes with no console window and passing JSON between them and the page via Tauri commands. No business logic in Rust.
- **Secrets travel from the app to PowerShell on stdin only**, never as process arguments, and are never written by our code to disk or logs. From PowerShell to rclone, the existing builders (`New-PikPakRemoteArgs`, `New-CryptRemoteArgs`) are reused as they are (rule R16). *Show recovery key* may call `rclone reveal` with the obscured value from `rclone.conf` (that value is already readable in the user's own profile).
- Windows only. Code lives in `gui/` at the repo root.

## Engine changes (builder's call, made in brainstorming review)

Allowed, each with Pester tests, keeping the existing suite green:

1. **A structured last-run record in state.** `Invoke-MirrorRun` writes `LastRun = @{ Started; Finished; Result = ok|failed|budget-stopped|month-paused; Errors = @(@{ Pair; Kind; Message }) }`, where `Kind` names the known reasons (folder empty, delete safety stop, needs repair, stuck upload, private not confirmed, config invalid, private sync failed, prune failed, other). Home reads this instead of guessing from `LastSuccess`. A run stopped by the month budget is `month-paused`, not a plain success. The delete safety stop is detected from rclone's output where bisync reports it; if it cannot be told apart reliably, it is `other` with the log file named.
2. **Configurable sync task times:** `New-MirrorTaskSpec` reads `SyncTime` and `SyncAtLogon` (defaults `'20:00'`, `$true`).
3. **Non-interactive install steps** callable from the bridge: create the PikPak remote from given credentials; create the crypt remote from a given key (or skip it when no folder is private); register tasks / context menu / local folders. `Install.ps1` keeps working as it does today for the console; both share the same functions.
4. **Empty salt accepted** for restoring a single-key setup (console option a) and the bridge).

## Screens and behaviour

The prototype is the reference for layout, wording and colours. Below is what each part does for real.

### Start-up

- If the config exists **and** rclone has the `pikpak` remote: open **Home**.
- Otherwise: open the **setup** flow.
- The window remembers its size and position. Closing the window hides it to the tray; "Quit" is in the tray menu.

### Setup flow (fresh PC)

1. **Welcome**: as in the prototype.
2. **Sign in**: email + password → create the `pikpak` remote and verify with `rclone about` (the same steps and clean-up as `Install.ps1` step 2). On failure, show what went wrong in plain words ("PikPak didn't accept that email and password") and stay on the screen. Install rclone / WinFsp first if missing (same pinned download and SHA256 check as `Install.ps1`), with a progress line.
   - Account size from `rclone about --json` picks the budget preset: up to 10 GiB total = free (`RunBudgetGB 1`, `MonthlyBudgetGB 30`), else Premium (`8` / `230`).
3. **Choose folders**: pre-filled with Pictures, Documents, Desktop, Music and Videos when they exist, each measured in the background ("Measuring…" until done). Pre-tick what fits in the free PikPak space. **Add another folder** opens the folder picker. A **Private** tick box per folder. Space bar as in the prototype; *Continue* is blocked when the ticked folders don't fit.
4. **Recovery key** (only if a folder is Private): prototype option A. See *Recovery key* below.
5. **Done**: writes the config, then runs the rest of today's install non-interactively: scheduled tasks (sync **enabled**), right-click Offload menu, local folders, private-path confirmation, mounts. Then *Start my first backup* starts a sync. The "takes about N evenings" sentence uses the real budget.

### Home

- **Status message**: one of the prototype's situations, chosen from real data:
  - *Backing up now*: a sync is running (the sync lock is held / the scheduled task is running).
  - *Backed up*: last run succeeded and no folder failed. Shows last backup time and the next scheduled run.
  - *First backup on its way*: some folders are not yet seeded.
  - *Paused until the 1st*: month budget used up.
  - *PikPak signed you out*: `rclone about` fails with an authentication error.
  - *Needs attention*: a folder's last result failed. Names the folder and, where the engine tells us why (delete safety stop, folder empty, stuck upload), says what to do in plain words. The prototype's "Bring them back / I deleted them on purpose" buttons are **not** built yet; the message points to the fix instead.
  - *Not backed up for 3+ days*: the existing stale-success rule.
  - *Paused by you*: sync task disabled.
- **Back up now**: starts the sync task (`Start-ScheduledTask PikPakMirror-Sync`), so it runs exactly like the evening run and respects the lock.
- **Folder list**: each pair with a status pill from state (`Seeded`, `LastExit`, `LastRun`), private folders marked. Per folder: *Open folder*, *Remove from backup* (config only, deletes nothing), and *Repair* for a failing folder (runs `Invoke-Sync.ps1 -Resync <Name>`, with the README's explanation shown first).
- **Add a folder**: folder picker → added to `Pairs` with a derived remote path (`C:\Users\<me>\X` → `C-Users/X`, otherwise `<Drive>/<rest>`, matching today's config) and priority 3. Existing pairs keep their names and remote paths.
- **Space panel**: used / total from `rclone about --json`, refreshed when Home opens and at most every 10 minutes.
- **This month's uploads**: `UsedGB` / `BudgetGB` from `Get-MirrorStatus`.
- **Shortcuts**: *Open my backup in File Explorer* (P:, or start the mount if it isn't up), *Get back a deleted file*, *Free up space on this PC*.
- **Not-backed-up folders**: `Unmapped` from status, shown as a quiet line with *Add* next to each.

### Get back a deleted file

- Lists files in the local holding folder (`LocalHolding\<date>\<pair>\...`) and in `pikpak:PC-Holding/<date>/<pair>/...` (one `rclone lsjson -R` call), newest first, with a search box.
- **Restore** puts the file back at `<pair Local>\<relative path>`. If something is already there, it is restored as `name (restored).ext` instead of overwriting.
- Private holding (`private:_holding`) and Archive restores are out of scope; a line tells the user to use `Q:` / `P:\Archive`.

### Free up space

- *Choose files to move…* (file picker, multi-select) and *Choose a folder to move…* (folder picker) → `Move-ToArchive.ps1 -Path <p> -Yes` for each, with the outcome per item. The script's existing refusals (private, whole pair, outside a pair, links) are shown as plain messages.

### Settings

- **Pause backups**: disables / enables `PikPakMirror-Sync`.
- **When to back up**: time of the daily run (new config key `SyncTime`, default `'20:00'`), and *Also back up soon after I turn on my PC* (new config key `SyncAtLogon`, default `$true`). Changing either re-registers the sync task.
- **Go easy on my internet in the evening**: on = today's `BwLimit` value; off = no limit. The hours are editable under Advanced.
- **Private folders**: list, *Add private folder* (folder picker), *Remove*. Adding runs the same checks as `Confirm-PrivatePaths.ps1` (exists, size, a plain copy already on PikPak, overlap with a pair) and shows them as a confirm dialog; confirming saves the confirmation hash exactly as the script does. A folder that is also a pair is removed from `Pairs` (never the other way round).
- **Recovery key**: *Show recovery key*. See below.
- **File Explorer drives**: P: and Q: on/off (the mount task; P: and Q: are mounted together today, so this is one switch unless splitting is trivial).
- **PikPak account**: email (from the rclone config) and account size. *Change account* is out of scope for now.
- **Advanced** (collapsed): per-run and monthly upload limits, days to keep deleted files, delete safety stop %, evening bandwidth hours, and the **holding** and **cache** folders, each with *Browse…* (folder picker). Saving validates with `Test-MirrorConfig` before writing.
- **Start PikPak Backup when I sign in to Windows** (tray icon at logon).

### Tray icon

- Icon colour/tooltip follows the Home status (fine / working / needs attention).
- Menu: *Open*, *Back up now*, *Pause backups* / *Resume backups*, *Quit*.

## Recovery key

- **This PC (existing install):** the `private` remote already has a 32-character password and a 32-character salt. *Show recovery key* reveals both (from the rclone config, `rclone reveal`), labelled "Password" and "Salt", with Copy / Save to a file / Print, as in prototype option A.
- **Fresh setup:** generate **one** key: 30 characters from an alphabet without look-alikes (no 0/O, 1/I/L), shown in groups of five as in the prototype. It is used as the crypt **password**; the salt (`password2`) is left empty so rclone uses its built-in salt. Then the one key is all a restore needs. RECOVERY.md gets a short section for this case.
- Same safeguards as today: refuse to make a new key if `pikpak:PC-Private` already holds data; the user must tick "I've kept it somewhere other than this PC" before continuing (replaces typing `SAVED`).
- Save to a file: a plain text file with the key, the date, the PC name and three lines on how to restore, written only where the user picks in the Save dialog.

## Config writing

- The app writes `config\mirror.config.psd1` itself (folders, private folders, paths, budgets, new keys). Before each write it keeps the previous file as `mirror.config.psd1.bak` and validates the new one with `Get-MirrorConfig` + `Test-MirrorConfig`; if validation fails, nothing is written and the error is shown.
- Comments in the hand-edited file are lost on the first app write. A short header comment says the file is managed by the app and can still be edited by hand.
- Commented-out pairs (the Premium-only ones today) are lost too. Before the first write, the app copies the original to `mirror.config.original.psd1` so they can be restored by hand.
- New keys (`SyncTime`, `SyncAtLogon`) are optional for the engine: missing = today's behaviour.

## Error handling

- Every bridge call returns `{ ok, data | error }`. Errors are shown in the app's voice: what happened, and what to do. Raw rclone output goes to the log only.
- A bridge call that is still running shows a quiet progress line, never a frozen window (PowerShell runs off the UI thread).
- If PowerShell, rclone or the config is missing/broken at start-up, Home shows that as its status message with the fix.

## Testing

- New PowerShell functions: Pester tests in `tests/Gui.Tests.ps1`, same style and rules as the existing suite; the full suite still passes.
- Rust: `cargo test` unit tests only for non-trivial pure code, if any (e.g. building the PowerShell command line, parsing the bridge result). The window itself is checked by running the app.
- A live check on this PC with ≤1 MB test files (free account quota): Home shows the real status, add/remove a folder with the picker, restore a deleted file, offload a small file, show the recovery key.
- **Setup flow (owner's decision):** unit tests for every setup step, plus a **preview mode** (app started with `--preview-setup`) that walks the setup screens on this PC and shows what each step would do (`-WhatIf`-style) without creating remotes, registering tasks, writing the live config or uploading. A real end-to-end setup run waits for a spare PikPak account or a VM.

## Left to the builder

- Exact bridge action names and JSON shapes.
- Tauri command names and how long-running calls report progress (events vs polling).
- How "sync is running" is detected (lock file, task state, or both).
- How folder sizes are measured without freezing the UI (and capping time for huge folders).
- App icon, tray icon artwork.
- How the app finds the repo's `scripts\` folder (e.g. a path stored on first run, defaulting to the folder the exe was built from).
