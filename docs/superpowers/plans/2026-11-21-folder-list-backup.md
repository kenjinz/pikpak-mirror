# Folder list backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Back the folder list up to PikPak automatically and let a fresh install restore it (synced and encrypted folders, with the existing recovery key in either form), falling back to the folders' ID files when no backup exists.

**Architecture:** A new library `scripts\lib\Backup.ps1` builds, parses, uploads and restores the two backup files (readable `pikpak:PC-Mirror/.pikpak-sync-backup.json`, encrypted `private:.pikpak-sync-encrypted.json`) and keeps its own small status file `<StateDir>\backup.json`. New GUI actions live in a new `scripts\lib\GuiBackup.ps1` (dispatch stays in `GuiActions.ps1`). The sync script uploads on a hash change; the UI pushes after every config-changing action. Setup gains two screens (existing key, found folders) in a new `gui\ui\restore.js`; Settings gains "Enter recovery key…".

**Tech Stack:** Windows PowerShell 5.1, rclone v1.75.2, Pester 5.7.1, Tauri 2 (plain JS UI, Rust bridge).

**Spec:** `docs/superpowers/specs/2026-11-21-folder-list-backup-design.md`. Read it before any task. Where this plan and the spec disagree, the spec wins; report the conflict.

## Global Constraints

- Windows PowerShell 5.1 only: no `?:`, `??`, `?.`, `&&`/`||`, `-AsHashtable`. Script files stay ASCII; build non-ASCII with `[char]`.
- Every file rclone reads or uploads is UTF-8 **without BOM**.
- No secret ever goes into either backup file, a log line or an error message. The readable backup never contains `PrivatePaths` or any encrypted folder's name or path.
- Restore never deletes anything in PikPak; restored folders keep their `Id`, `Remote` (synced) and `Name` (encrypted).
- A new key is never made while `pikpak:PC-Private` holds data; a key that decrypts nothing is refused (`New-MirrorPrivateRemote -Mode Existing`, which already deletes the half-made remote).
- A failed backup upload never fails a save, a setup or a sync.
- Every new action has a preview that writes nothing and returns `preview` lines. Write actions refuse while a sync runs (`Assert-GuiNotSyncing`), except the setup ones (no config yet).
- Secrets travel only in args `recoveryKey` and `salt` (add `salt` to the cleared list in `Invoke-GuiRequest`).
- Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1` (`-Filter` matches test names). Unit tests never touch the network or real rclone (mock `Invoke-RcloneOutput` / `Invoke-GuiRclone` / `Invoke-RcloneCaptured`). "Suite passes" = no failure other than the baseline recorded in Task 0. `cargo test` in `gui\src-tauri` passes.
- **This PC is LIVE from `G:\pikpak-mirror` (branch `main`).** Work only in `G:\pikpak-mirror\.worktrees\folder-list-backup` (branch `folder-list-backup`). No rclone against the account and no app start against the real config, except in Task 7 after the owner says yes. No scheduled-task or registry changes.
- One commit per task, `type(scope): summary`, ending with a blank line and `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not push.

## Review Focus

1. A backup file that is empty, not JSON, of another `kind`/`app`, or a newer `version`: treated as missing with `backupProblem` set, never a crash, never a partial restore. Test in Task 1.
2. Paths written with `%USERPROFILE%`/`%VAR%` in the config stay unexpanded in the backup (so they move with the user), and literal `C:\Users\<old>\...` paths are moved to the new profile only when the old profile folder is missing. Tests in Task 1 and Task 4.
3. A synced folder with an encrypted folder inside, restored after "I don't have my key": restored paused; with the key, not paused. Test in Task 4.
4. Hand-editing the config (no app save): the next sync uploads; an unchanged config uploads nothing (hash over content, not `saved`). Test in Task 2.
5. A password+salt key with a character PowerShell 5.1 cannot pass (`"` or trailing `\`): refused with the installer's message, never sent to rclone. Test in Task 3.

---

### Task 0: Baseline

- [ ] **Step 1:** In the worktree, run the suite and `cargo test` (in `gui\src-tauri`); write the counts at the top of `.superpowers\sdd\2026-11-21-folder-list-backup\progress.md`.

### Task 1: Backup documents (build, parse, restore helpers)

**Files:**
- Create: `scripts\lib\Backup.ps1`, `tests\Backup.Tests.ps1`
- Modify: `scripts\lib\_load.ps1` (load `Backup.ps1` after `ConfigWriter.ps1`), `tests\Filters.Tests.ps1`

**Interfaces (produces):**
- `$script:BackupPlainName = '.pikpak-sync-backup.json'`, `$script:BackupEncryptedName = '.pikpak-sync-encrypted.json'`.
- `ConvertTo-BackupDocuments -RawConfig <hashtable> -GlobalFilters <string> -Now <datetime> -PcName <string> -AppVersion <string>` → `@{ Plain = <json>; Encrypted = <json>; Hash = <64 hex> }`.
  - Plain: `{ app: 'pikpak-mirror', kind: 'folder-list-backup', version: 1, saved, pcName, appVersion, config, globalFilters }`; `config` = raw config without `PrivatePaths`; each Pair whose expanded `Local` is a prefix (`ConvertTo-PrefixKey`) of an expanded `PrivatePaths.Path` gets `holdsEncrypted = $true`. Raw values (unexpanded `%VAR%`) are written as they are.
  - Encrypted: same header with `kind: 'encrypted-folder-list'` and `privatePaths` = the raw `PrivatePaths` entries (empty array allowed).
  - Hash: SHA-256 of a canonical JSON (keys sorted at every level) of `@{ config; globalFilters; privatePaths }`. `saved`, `pcName` and `appVersion` are not in it.
- `ConvertFrom-BackupText -Text <string> -Kind <'plain'|'encrypted'>` → `@{ Config; GlobalFilters; PrivatePaths; Saved; PcName }` (hashtables, not PSCustomObjects), or `@{ Invalid = $true; Reason = <string> }` when empty, not JSON, wrong `app`/`kind`, or `version` > 1.
- `Resolve-RestorePath -Path <raw path> -UserProfile <string> -PathExists <scriptblock>` → `@{ Path; Moved = [bool]; DriveMissing = [bool] }`. `%VAR%` paths are returned unchanged (`Moved` false). `C:\Users\<x>\<rest>` with `<x>` not the current profile's leaf and `C:\Users\<x>` not existing → `<UserProfile>\<rest>`, `Moved` true. `DriveMissing` when the path's drive root does not exist.
- `New-RestoreConfig -Settings <hashtable> -Pairs <hashtable[]> -PrivatePaths <hashtable[]> -Defaults <hashtable> -PathExists <scriptblock>` → raw config: `Settings` minus `Pairs`/`PrivatePaths`, plus the given entries (with `holdsEncrypted` removed); `LocalHolding`/`StateDir` replaced by `Defaults` values when their drive does not exist; any key missing from `Settings` taken from `Defaults`.

- [ ] **Step 1: Write the failing tests** in `tests\Backup.Tests.ps1`: `It 'leaves PrivatePaths out of the readable backup and flags pairs that hold encrypted folders'`; `It 'keeps %USERPROFILE% paths unexpanded'`; `It 'gives the same hash when only the time or PC name differ'`; `It 'changes the hash when a pair, a setting, the filters or an encrypted entry changes'`; `It 'round-trips non-ASCII names without BOM'` (`Nh` + `[char]0x1EA1` + `c`); `It 'reads empty, non-JSON, wrong kind and version 2 as Invalid'` (4 cases); `It 'moves C:\Users\Old paths to the current profile only when Old is missing'`; `It 'marks a missing drive'`; `It 'New-RestoreConfig replaces machine paths on a missing drive and fills missing settings from defaults'`. In `tests\Filters.Tests.ps1`: the global filters never exclude `.pikpak-sync-backup.json` or `.pikpak-sync-encrypted.json`.
- [ ] **Step 2:** `tests\run.ps1 -Filter Backup`: FAIL (functions not defined).
- [ ] **Step 3:** Implement the interfaces above in `Backup.ps1`; add it to `_load.ps1`.
- [ ] **Step 4:** Filtered tests PASS; suite passes.
- [ ] **Step 5:** Commit `feat(backup): build and parse the folder list backup`.

### Task 2: Uploading the backup (sync run and `backup.push`)

**Files:**
- Modify: `scripts\lib\Backup.ps1`, `scripts\Invoke-Sync.ps1`, `scripts\lib\GuiActions.ps1` (dispatch, `Invoke-GuiActionStatus`), `tests\Backup.Tests.ps1`, `tests\GuiAction.Tests.ps1`
- Create: `scripts\lib\GuiBackup.ps1` (loaded after `GuiActions.ps1`)

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `Get-BackupStatus -StateDir` → `@{ Hash; LastSuccess; FailingSince; EncryptedUploaded = [bool] }` from `<StateDir>\backup.json` (defaults when missing or unreadable). `Save-BackupStatus -StateDir -Status` writes it atomically (temp + move, UTF-8 no BOM). *(A separate file instead of `state.json`, so a push from the app never races the run's state save.)*
  - `Publish-ConfigBackup -ConfigPath <string> -Config <loaded config> -Now <datetime> [-Force]` → `@{ Uploaded = [bool]; Skipped = [bool]; Error = <string or $null> }`. Reads `Get-RawMirrorConfig` and the global filters file text; builds documents; skips when `Hash` equals the stored one (unless `-Force`). Uploads Plain with `rclone copyto <temp> <Remote>:<MirrorRoot>/<BackupPlainName>`; uploads Encrypted to `<PrivateRemote>:<BackupEncryptedName>` when `PrivatePaths` is not empty or `EncryptedUploaded` is true. Both uploads OK → store `Hash`, `LastSuccess`, clear `FailingSince`, set `EncryptedUploaded`. Any failure → log it (`Write-MirrorLog`), keep `Hash`, set `FailingSince` if empty, return `Error`. Never throws. Temp files deleted in `finally`. Uses `Invoke-RcloneOutput`.
  - Action `backup.push` (`Invoke-GuiActionBackupPush`): needs config; preview returns `Would upload your folder list to PikPak (<path>).`; otherwise `Publish-ConfigBackup` and returns `@{ uploaded; skipped; error }`. Not a write action.
  - `Invoke-GuiActionStatus` data gains `backup = @{ failingSince = <ISO or $null>; stale = [bool] }`; `stale` when `FailingSince` is older than `StaleRunDays` days.
- `Invoke-Sync.ps1`: after a full `Invoke-MirrorRun` (not `-OnlyFolders`), call `Publish-ConfigBackup` inside a `try` that only logs.

- [ ] **Step 1: Write the failing tests:** `It 'uploads both files and stores the hash'`; `It 'uploads nothing when the hash is unchanged'`; `It 'uploads after a hand edit'` (rewrite the config file, call again: one upload); `It 'keeps the hash and sets FailingSince when rclone fails, and does not throw'`; `It 'skips the encrypted file when there are no encrypted folders and none was uploaded before'`; `It 'uploads an empty encrypted list after the last encrypted folder is removed'`; GuiAction: `It 'backup.push in preview uploads nothing'`; `It 'status reports a stale backup after StaleRunDays'`.
- [ ] **Step 2:** Filtered tests FAIL.
- [ ] **Step 3:** Implement; register `backup.push` in the dispatch switch.
- [ ] **Step 4:** Filtered tests PASS; suite passes.
- [ ] **Step 5:** Commit `feat(backup): upload the folder list after saves and at sync`.

### Task 3: Using an existing recovery key

**Files:**
- Modify: `scripts\lib\GuiBackup.ps1`, `scripts\lib\GuiActions.ps1` (dispatch; `salt` in the secret list), `tests\GuiAction.Tests.ps1`

**Interfaces:**
- Consumes: `New-MirrorPrivateRemote -Mode Existing`, `ConvertTo-RecoveryKey`, `Test-NativeArgumentSafe`, `Get-UnsafePasswordMessage`, `Get-RemoteEntryCount`, `Get-GuiRemotePrivateNames`, `Get-FolderMarkerName`, `ConvertTo-RemoteMarkerResult`, Task 1.
- Produces:
  - `Get-GuiKeyArgs -Ctx` → `@{ Password; Salt }`. No `salt` (or empty): `Password = ConvertTo-RecoveryKey recoveryKey`, `bad-request` "That isn't a recovery key. It has 30 letters and numbers." when `$null`. With `salt`: both trimmed, both must pass `Test-NativeArgumentSafe` (else `bad-request` with `Get-UnsafePasswordMessage`), both non-empty.
  - `Get-GuiEncryptedRestoreList -Ctx` → `@{ source = 'backup'|'idfiles'; folders = @(@{ name; id; lastPath; paused; entry }) }`. Reads `private:<BackupEncryptedName>` (`rclone cat`); valid → its `privatePaths` (`entry` = the raw entry). Missing or invalid → one row per `Get-GuiRemotePrivateNames` folder with its ID file (`id`, `lastPath`), `paused` false, `entry` = `$null`.
  - Action `setup.usekey` (write, no config needed): refuses with `refused` when `pikpak:PC-Private` holds nothing. Deletes an existing `private` remote first (setup has no config yet), then `New-MirrorPrivateRemote -Name 'private' -BaseRemote 'pikpak' -Password -Salt -Mode Existing`. Its failure → `bad-key` "That key doesn't open your encrypted folders. Check it and try again." Success → `Get-GuiEncryptedRestoreList`.
  - Action `private.usekey` (write, needs config): same, but refuses with `refused` when a `private` remote already exists; it never deletes one.
  - Action `private.keyState` (read): `@{ hasKey = [bool]; encryptedData = [bool] }`; the remote count only runs when `hasKey` is false.

- [ ] **Step 1: Write the failing tests:** `It 'setup.usekey accepts a 30-character key in any case with spaces'`; `It 'setup.usekey passes password and salt as typed'` (assert the `New-MirrorPrivateRemote` mock got both); `It 'refuses a salt with a double quote or a trailing backslash without calling rclone'`; `It 'maps a key that decrypts nothing to bad-key and never echoes the key'` (message does not contain the key or salt); `It 'lists encrypted folders from the companion file when present'`; `It 'falls back to the ID files when the companion file is missing'`; `It 'private.usekey refuses when a private remote exists'`; `It 'setup.usekey refuses when PC-Private is empty'`.
- [ ] **Step 2:** Filtered tests FAIL.
- [ ] **Step 3:** Implement; register the three actions.
- [ ] **Step 4:** Filtered tests PASS; suite passes.
- [ ] **Step 5:** Commit `feat(setup): use an existing recovery key or password and salt`.

### Task 4: Discover, scan, sizes and restore in `setup.finish`

**Files:**
- Modify: `scripts\lib\GuiBackup.ps1`, `scripts\lib\GuiActions.ps1` (`Invoke-GuiActionSetupFinish`, dispatch), `tests\GuiAction.Tests.ps1`, `tests\Backup.Tests.ps1`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - Action `setup.discover` (read, no config): `@{ backup = <ConvertFrom-BackupText result + its Pairs, each with resolved path info from Resolve-RestorePath> | $null; backupProblem = <string or $null>; encryptedData = [bool] }`. `Get-RemoteEntryCount` < 0 → `remote-failed`.
  - `Find-RemoteSyncedFolders -Remote <string> -MirrorRoot <string>` (Backup.ps1) → `@(@{ Id; Name; Remote; LastPath })`: `rclone lsf -R --files-only --include ".pikpak-sync.json" <Remote>:<MirrorRoot>`, then `rclone cat` each; a marker whose folder is below another found folder is dropped; `kind` other than `synced` or invalid JSON is skipped and logged. Action `setup.scan` (read, no config) returns them as Pairs (`Name`, `Local` = `LastPath`, `Remote`, `Id`, `Priority` = 3) with resolved path info.
  - Action `setup.sizes` (read, no config): args `places` (array of `pikpak:...`/`private:...` paths) → `@{ sizes = @{ <place> = <bytes or $null> } }` via `rclone size --json`.
  - `setup.finish` with `args.restore = @{ settings; pairs; privatePaths; globalFilters; keySkipped = [bool] }` (instead of `folders`): builds the config with `New-RestoreConfig` (`Defaults` = `New-GuiSetupConfig` output for the preset); when `keySkipped`, every pair with `holdsEncrypted` gets `Paused = $true` and `PausedForKey = $true` (`Test-MirrorConfig` accepts `PausedForKey` as `[bool]`, same message style as `Paused`); writes `filters.txt` from `globalFilters` (UTF-8 no BOM) next to the config; the "Recovery key" step, when `privatePaths` is not empty, checks the `private` remote is listed and skips creating it (message "Recovery key from your earlier install is in use"); the remaining steps are today's; ends with `Publish-ConfigBackup -Force` (its failure is a quiet line, not a failed step).
  - Rust `bridge.rs`: `setup.scan` and `setup.sizes` get 300 s in `action_timeout`; `setup.usekey`, `private.usekey`, `private.restore` (Task 6) join `is_write_action`. Update its tests.

- [ ] **Step 1: Write the failing tests:** `It 'discover returns the parsed backup and encryptedData'`; `It 'discover reports a broken backup as backupProblem and backup null'`; `It 'scan finds synced folders from ID files and drops nested ones'`; `It 'finish with restore keeps Id, Remote and Name and writes filters.txt'`; `It 'finish with restore pauses pairs that hold encrypted folders when the key was skipped'`; `It 'finish with restore and the key does not pause them'`; `It 'Test-MirrorConfig rejects a non-bool PausedForKey'`; `It 'finish with restore does not make a new key'` (no `New-MirrorPrivateRemote -Mode New` call); `It 'finish with restore under preview writes nothing'`; cargo: the new timeouts and write actions.
- [ ] **Step 2:** Filtered tests FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Filtered tests and `cargo test` PASS; suite passes.
- [ ] **Step 5:** Commit `feat(setup): restore folders from the backup or the ID files`.

### Task 5: Setup screens (UI) and the push after saves

**Files:**
- Create: `gui\ui\restore.js`
- Modify: `gui\ui\setup.js` (`signIn` goes to `restore.afterSignin()` instead of `go('folders')`; `runFinish` sends `restore` args when chosen), `gui\ui\index.html` (sections `s-oldkey`, `s-found`), `gui\ui\app.js` (router entries; Home quiet note from `status.backup.stale`), `gui\ui\bridge.js`, `gui\ui\app.css` (only if needed)

**Interfaces:**
- Consumes: actions from Tasks 2–4.
- Produces: `restore.afterSignin()`; screens `oldkey` and `found` for the router; in `bridge.js`, after a successful non-preview `callFull` of one of `config.save`, `folders.add`, `folders.remove`, `folders.convert`, `folders.pause`, `folders.resume`, `folders.locate`, `folders.adopt`, `folders.newId`, `folders.ensureIds`, `private.add`, `private.remove`, `private.restore`, `schedule.set`, a fire-and-forget `call('backup.push')` whose failure is only `console.warn`ed.

Flow and fixed copy (from the spec):
1. `afterSignin`: `setup.discover`. `encryptedData` → `oldkey`; else backup → `found`; else `setup.scan` ("Looking for your folders in PikPak…", **Skip** → `folders`); nothing found → `folders`.
2. `oldkey`: heading "Your PikPak has encrypted folders", lead "Type your recovery key to open them.", one field, link "My key is a password and a salt" revealing a second field "Salt", buttons **Check key** and **I don't have my key**. `bad-key` shows its message under the field. Skip note: "Your encrypted folders stay locked in PikPak. You can enter the key later in Settings."
3. `found`: heading "Found your folders in PikPak"; sub "Backed up <date> from <pcName>" or, from the scan, "No backup of your settings was found. Your folders were found from PikPak; settings are back to defaults."; rows with tick, name, path, "(encrypted)", size (filled by `setup.sizes` after showing); `DriveMissing` rows unticked with **Choose place…** ("drive X: isn't on this PC"); `holdsEncrypted` rows after a skipped key show "Contains encrypted folders. It resumes once you enter your recovery key."; total line "About <size> will come down from PikPak." plus, on the free preset when the total is over 5 GB, " PikPak lets a free account download about 5 GB a day, so this can take more than a day."; **Restore** → `done` with restore args; **Start fresh instead** → confirm "Your old folder list in PikPak will be replaced the first time you save. The folders' ID files stay in PikPak." → `folders`.

- [ ] **Step 1:** Implement the screens and the bridge hook.
- [ ] **Step 2:** Run the app in preview (`--preview-setup`, worktree build, no real config) and walk: backup found / no backup + scan / encrypted with key / skip key / Start fresh. Preview mocks come from the actions' preview branches; where a preview cannot show a branch, note it in the ledger.
- [ ] **Step 3:** Suite and `cargo test` pass.
- [ ] **Step 4:** Commit `feat(ui): restore folders and enter the existing key in setup`.

### Task 6: Enter the key later (Settings) and `private.restore`

**Files:**
- Modify: `gui\ui\settings.js`, `gui\ui\index.html`, `scripts\lib\GuiBackup.ps1`, `scripts\lib\GuiActions.ps1` (dispatch), `tests\GuiAction.Tests.ps1`

**Interfaces:**
- Consumes: `private.keyState`, `private.usekey` (Task 3), `Get-GuiEncryptedRestoreList`.
- Produces: action `private.restore` (write, needs config, `Assert-GuiNotSyncing`): args `entries` (raw `PrivatePaths` entries, paths possibly changed) → adds them (skipping names already configured), clears `Paused` and `PausedForKey` on every pair with `PausedForKey = $true` (Task 4), saves with `Save-GuiConfig`, then `Save-PrivateConfirmation`.
- Settings, section *Encrypted folders*: when `private.keyState` says `hasKey` false and `encryptedData` true, a row "Your PikPak has encrypted folders this PC can't open yet." with **Enter recovery key…** opening the same two-field box; on success, the found rows (as in setup) with **Restore**; when the companion file is missing, the message points to *Encrypted folders in PikPak* → **Reconnect…**.

- [ ] **Step 1: Write the failing tests:** `It 'private.restore adds entries and resumes pairs paused for the key'`; `It 'private.restore leaves pairs the owner paused alone'` (paused without `PausedForKey`); `It 'private.restore refuses while a sync runs'`.
- [ ] **Step 2:** Filtered tests FAIL.
- [ ] **Step 3:** Implement the action and the Settings UI.
- [ ] **Step 4:** Filtered tests PASS; suite and `cargo test` pass; preview walk of the Settings box.
- [ ] **Step 5:** Commit `feat(settings): enter the recovery key later and restore encrypted folders`.

### Task 7: Docs and a live check

**Files:**
- Modify: `docs/RECOVERY.md` (section 2 becomes: sign in, restore, enter key; the manual way stays as the fallback), `README.md` (one paragraph on the automatic backup), `docs/superpowers/notes/dev-ledger.md`

- [ ] **Step 1:** Update the docs.
- [ ] **Step 2:** **Ask the owner first.** With a yes: from the worktree, run `backup.push` once against the real config (`'{"action":"backup.push"}' | powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-GuiAction.ps1 -ConfigPath <real config>`), then `rclone cat pikpak:PC-Mirror/.pikpak-sync-backup.json` shows no `PrivatePaths`, and `rclone cat private:.pikpak-sync-encrypted.json` lists the encrypted folders. Both files are a few KB.
- [ ] **Step 3:** Suite and `cargo test` pass.
- [ ] **Step 4:** Commit `docs: restore from the folder list backup`.
