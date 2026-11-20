# Folder identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every synced and encrypted folder an ID stored in a marker file, so the app can locate a moved folder, catch copies, reconnect encrypted folders that are in PikPak, and pause a folder instead of removing it.

**Architecture:** A new library `scripts\lib\Marker.ps1` reads and writes the marker (`.pikpak-sync.json` / `.pikpak-encrypted.json`). The config entries gain `Id` and `Paused`. The sync run checks the marker before each folder, writes it when it is missing for the first time, and skips paused folders. Synced folders' bisync gets `--exclude-if-present .pikpak-encrypted.json`. New GUI actions (pause/resume, identify, locate, adopt, new ID, the PikPak list of encrypted folders, download, delete) sit in `GuiActions.ps1`. Home and Settings get the boxes and buttons.

**Tech Stack:** Windows PowerShell 5.1, rclone v1.75.2, Pester 5.7.1, Tauri 2 (plain JS UI, Rust bridge).

**Spec:** `docs/superpowers/specs/2026-11-19-folder-identity-design.md`. Read it before any task. Where this plan and the spec disagree, the spec wins; report the conflict.

## Global Constraints

- Windows PowerShell 5.1 only: no `?:`, `??`, `?.`, `&&`/`||`, `-AsHashtable`. Script files stay ASCII; build non-ASCII with `[char]`.
- Any file rclone reads, and the marker, is written UTF-8 **without BOM**.
- An encrypted folder's content never reaches the plain remote: the path-based excludes stay, and are applied also for a paused encrypted folder.
- Nothing is deleted in PikPak except by "Delete from PikPak" on a not-connected encrypted folder: exactly `private:<Name>`, never `private:`, never `private:_holding`.
- The app never changes an ID, moves anything in PikPak or switches a folder's path without the owner confirming in a box.
- Every new write action refuses while a sync runs (`Assert-GuiNotSyncing`; `folders.ensureIds` defers instead) and, in preview mode, changes nothing and returns `preview` lines saying what it would do.
- An existing seeded folder that has an `Id` and a matching marker keeps its bisync args, state key, filter file and identity hash: no forced resync. **Exception, on purpose:** adding `--exclude-if-present` to every synced folder's bisync args does not change `Get-FolderIdentity` and needs no resync.
- User-facing wording: "PikPak Sync", "sync", "Encrypted"/"encrypted folder", "Pause syncing", "Resume", "Locate…", "Give a new ID". Exact copy below is fixed where quoted.
- Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1` (`-Filter` matches test names). Unit tests never touch the network or real rclone; they use a temp `StateDir` under `TestDrive`. "Suite passes" = no failure other than the known `J3` in `Config.Tests.ps1` (record the baseline count in Task 0).
- **This PC is LIVE from `G:\pikpak-mirror` (branch `main`).** Work only in `G:\pikpak-mirror\.worktrees\folder-identity` (branch `feat/folder-identity`). No rclone against the account, no `Install.ps1` without `-WhatIf`, no scheduled-task or registry changes, do not start the app from `main`. Rclone on local temp folders is allowed.
- One commit per task, `type(scope): summary`, ending with a blank line and `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not push.

## Review Focus

1. A marker that is empty, truncated, not JSON, or has a malformed `id` (hand-edited, half-written): treated as "a different folder" and skipped, never a crash, never synced. Tests in Task 1 (`Read-FolderMarker` → `Invalid`) and Task 2 (run skips with `folder-identity-mismatch`).
2. Names and paths with spaces and non-ASCII (`Nhạc`, `New folder`) round-trip through the marker JSON without BOM. Test in Task 1.
3. A paused encrypted folder inside a synced folder: the synced folder's filter rules still exclude it. Test in Task 2.
4. A missing folder on an unplugged drive shows "Drive not connected" with no Locate; on a connected drive "Folder not found" with Locate. Test in Task 4.
5. Two config entries with the same `Id`, one of them paused: the active one is skipped with `folder-duplicate-id`, not synced. Test in Task 2.

---

### Task 0: Baseline

- [ ] **Step 1:** In `G:\pikpak-mirror\.worktrees\folder-identity`, run the suite and write the counts (passed / failed, expected only `J3`) at the top of the ledger `.superpowers\sdd\2026-11-19-folder-identity\progress.md`. Run `cargo test` in `gui\src-tauri` and record its counts.

### Task 1: Marker library and config fields

**Files:**
- Create: `scripts\lib\Marker.ps1`, `tests\Marker.Tests.ps1`
- Modify: `scripts\lib\_load.ps1` (load `Marker.ps1` after `Runtime.ps1`), `scripts\lib\Runtime.ps1` (`Invoke-RcloneOutput`), `scripts\lib\Config.ps1` (`Test-MirrorConfig`), `tests\Config.Tests.ps1`

**Interfaces (produces):**
- `$script:MarkerSyncedName = '.pikpak-sync.json'`, `$script:MarkerEncryptedName = '.pikpak-encrypted.json'`.
- `Get-FolderMarkerName -Kind <'pair'|'private'>` → the file name for that kind.
- `New-FolderId` → `[guid]::NewGuid().ToString('D')` (lower case). `Test-FolderId [string]` → `$true` for that shape (`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`, case-insensitive).
- `ConvertFrom-MarkerText [string]` → `@{ Id; Kind ('synced'|'encrypted'); Name; PikPak; LastPath; Updated }`, or `@{ Invalid = $true }` when not JSON, `app` is not `pikpak-mirror`, or `id` fails `Test-FolderId`.
- `Read-FolderMarker -Path <folder>` → `$null` when neither file exists; else the parsed marker plus `File` (full path) and `FileKind` ('pair'|'private' from the file name). When both files exist, the encrypted one is read. Unreadable → `@{ Invalid = $true; File }`.
- `ConvertTo-MarkerText -Folder <Get-SyncFolders item> -Now <datetime>` → JSON with keys in this order: `app` = `pikpak-mirror`, `version` = 1, `id` = `$Folder.Id`, `kind` = `synced`|`encrypted`, `name`, `pikpak` = `$Folder.RemotePath`, `lastPath` = `$Folder.Local`, `updated` = `yyyy-MM-dd`.
- `Write-FolderMarker -Folder <item> -Now <datetime> [-Force]` → `$true` when it wrote. Writes the kind's file (UTF-8 no BOM), sets Hidden, deletes the other kind's file. Without `-Force` it throws when the existing marker has another `id`. It does nothing when the existing file's fields other than `updated` already match, except re-setting Hidden. Throws when `$Folder.Id` is empty.
- `Find-NestedMarkers -Path <folder> [-MaxSeconds 20]` → `@{ Items = @(@{ Path = <folder>; Marker = <parsed> }); Complete = [bool] }`: every marker below the top (not the top itself). It never follows reparse points and stops at the time limit, the same way `Measure-GuiFolder` walks.
- `Invoke-RcloneOutput -Arguments <string[]>` (Runtime.ps1) → `[pscustomobject]@{ ExitCode; Output = <string[]> }`, with UTF-8 console decoding as in `Invoke-GuiRclone`. `Get-RemoteMarker -RemotePath <remote folder> -Kind <'pair'|'private'> -LogFile <path>` (Marker.ps1) → `@{ Found = [bool]; Marker = <parsed or $null>; Failed = [bool] }`. It uses `rclone cat <RemotePath>/<marker name>`: exit 0 is found, exit 3 or 4 is not found, anything else is Failed.
- `Test-MirrorConfig` adds: an entry's `Id`, when present, must pass `Test-FolderId` (message `"<label> has an invalid Id '<v>'."`); `Paused`, when present, must be `[bool]` (`"<label> Paused must be `$true or `$false."`). Duplicate Ids are **not** a config error (the run handles them).

- [ ] **Step 1: Write the failing tests** in `tests\Marker.Tests.ps1`: `It 'round-trips a marker with non-ASCII and spaces'` (folder `Nh` + `[char]0x1EA1` + `c\New folder`, read back equal, file bytes do not start with `EF BB BF`, attribute Hidden); `It 'reads empty, truncated, non-JSON and bad-id markers as Invalid'` (4 cases); `It 'prefers the encrypted file when both exist'`; `It 'Write-FolderMarker switches file name with the kind and deletes the other'`; `It 'Write-FolderMarker refuses another id without -Force'`; `It 'Write-FolderMarker does not rewrite when only updated differs'` (LastWriteTime unchanged); `It 'Find-NestedMarkers lists markers below the top only'`; `It 'Get-RemoteMarker maps exit 0/3/4/other'` (mock `Invoke-RcloneOutput`). In `tests\Config.Tests.ps1`: invalid `Id`, non-bool `Paused`, and two entries with the same valid `Id` (no error).
- [ ] **Step 2:** Run `tests\run.ps1 -Filter Marker` and the Config tests: FAIL (functions not defined / no new errors).
- [ ] **Step 3:** Implement the interfaces above. Add `Marker.ps1` to `_load.ps1` after `Runtime.ps1`.
- [ ] **Step 4:** The filtered tests PASS; the full suite passes.
- [ ] **Step 5:** Commit `feat(marker): folder ID marker files and config Id/Paused`.

### Task 2: The sync run checks IDs, writes markers, skips paused folders, excludes moved encrypted folders

**Files:**
- Modify: `scripts\lib\Run.ps1` (`New-SyncFolder`, `Invoke-MirrorRun`), `scripts\lib\RcloneArgs.ps1` (`New-BisyncArgs`), `tests\Run.Tests.ps1`, `tests\RcloneArgs.Tests.ps1`

**Interfaces:**
- Consumes: Task 1.
- Produces: `New-SyncFolder` items carry `Id` (string or `$null`) and `Paused` (`[bool]`). State entry key `MarkerWritten` (`[bool]`). Issue kinds `folder-identity-mismatch`, `folder-marker-missing`, `folder-duplicate-id` (folder issues: `Pair` = Name, `Private` flag, as today).

Behaviour, inserted into the folder loop in this order. Copy is fixed:
1. `Paused` → `continue` before the missing-folder check: not attempted, no issue, no notification.
2. Missing folder: unchanged.
3. When `Id` is not empty:
   - **Duplicate:** another config entry (paused or not) has the same `Id` (case-insensitive). Skip with issue `folder-duplicate-id`: `"{0}: another folder ({1}) has the same ID, so nothing was synced. Open PikPak Sync to choose."`
   - **Read the PC marker.** `Invalid`, or a different `id`: skip with `folder-identity-mismatch`: `"{0}: the folder at {1} is a different folder (it belongs to '{2}'). Nothing was synced. Open PikPak Sync to sort it out."` (`{2}` is the marker's `name`, or `unknown` when Invalid).
   - **No marker, and `MarkerWritten`:** skip with `folder-marker-missing`: `"{0}: the folder at {1} has lost its ID file, so it may be a different folder. Nothing was synced. Open PikPak Sync to sort it out."`
   - Otherwise call `Write-FolderMarker` (this also refreshes `lastPath`, `name`, `pikpak` and the file name) and set `MarkerWritten = $true`.
   - **When this run will resync the folder** (the existing `$resync` flag), call `Get-RemoteMarker` before the sentinel step. Found with a different `id`: skip with `folder-identity-mismatch`: `"{0}: the PikPak copy at {1} belongs to another folder ('{2}'). Nothing was synced. Open PikPak Sync to sort it out."` Failed: skip with issue `other`: `"{0}: couldn't read the ID file in PikPak, so nothing was synced. It is tried again at the next sync."`
   - A skipped folder counts as attempted (its notifications follow the existing rules) and adds to `$errors`.
4. With an empty `Id`: as today, no marker step.
- `New-BisyncArgs`: for `Kind -eq 'pair'` only, append `'--exclude-if-present', '.pikpak-encrypted.json'`. (Verified 2026-11-19 with rclone v1.75.2 on local folders: honoured on `--resync` and normal runs, also for a folder moved in after seeding.)
- `New-PairFilterRules` is unchanged: it already excludes every `PrivatePaths` entry by path, paused or not.

- [ ] **Step 1: Write the failing tests** in `tests\Run.Tests.ps1`, using the existing `Mock Invoke-Rclone` harness and mocking `Invoke-RcloneOutput`:
  - `It 'skips a paused folder without issue or rclone call'`: no bisync call has its `Local`; no issue for it; `Ran` lacks it.
  - `It 'writes the marker on the first run and records MarkerWritten'`
  - `It 'skips a folder whose marker has another id'`: issue kind and message; no bisync for it; other folders still sync.
  - `It 'skips a folder whose marker is invalid'`
  - `It 'skips a folder whose marker disappeared after it was written'`
  - `It 'skips both entries with the same Id, also when one is paused'`
  - `It 'checks the PikPak marker only when resyncing'`: a seeded folder makes no `cat` call; an unseeded one makes one call; a different remote id → skipped; exit 4 → synced.
  - `It 'keeps excluding a paused encrypted folder inside a synced folder'`: the pair's filter file contains `- /<rel>/**`.
  - `It 'leaves a folder without Id as before'`: no marker written; synced.
  - In `tests\RcloneArgs.Tests.ps1`: `It 'adds exclude-if-present for synced folders only'`.
- [ ] **Step 2:** Run them: FAIL.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Tests PASS; the full suite passes (existing Run tests without `Id` must be unchanged).
- [ ] **Step 5:** Commit `feat(engine): check folder IDs before syncing, pause folders, never upload a moved encrypted folder`.

### Task 3: Changing a folder's kind keeps its ID

**Files:** Modify `scripts\lib\Convert.ps1` (`Get-FolderConversionPlan`), `tests\Convert.Tests.ps1`

- [ ] **Step 1:** Failing tests: `It 'carries Id and Paused to the new entry'` in both directions, including the "inside a synced folder" case, which has no new entry, so nothing is carried.
- [ ] **Step 2:** FAIL. **Step 3:** Copy `Id` (and `Paused` when present) from the old entry to the new one. The marker's file name is switched by the next sync (Task 2's `Write-FolderMarker`), and that runs before bisync. **Step 4:** PASS + suite. **Step 5:** Commit `feat(convert): keep the folder ID when its kind changes`.

### Task 4: Home status, pause/resume, ID assignment

**Files:** Modify `scripts\lib\Gui.ps1` (`Get-GuiStatus`), `scripts\lib\GuiActions.ps1` (`Invoke-GuiActionStatus`, dispatch, new actions), `tests\Gui.Tests.ps1`, `tests\GuiAction.Tests.ps1`

**Interfaces (produces):**
- `Get-GuiStatus` reads `Facts['MissingDrives']` (string[] of drive letters like `'E'` that are not present). `Invoke-GuiActionStatus` fills it from the folders' drive letters with `Test-Path '<L>:\'`.
- Each folder row gains `Paused` (`[bool]`), `Missing` (`'drive'`|`'folder'`|`$null`), and `Id`.
  - A paused row: `Pill = 'Paused'`, `PillTone = 'wait'`, issue fields `$null`, issues ignored.
  - A missing row: `Pill = 'Drive not connected'` (`'warn'`) when its drive letter is in `MissingDrives`, else the existing `'Folder not found'`.
  - Paused rows do not count toward `anyUnseeded`.
- New situation, checked after `running` and before `signed-out`: every row paused (at least one row) → `'all-paused'`, `'warn'`, `'All folders are paused'`, `'Nothing is synced until you resume a folder.'`.
- The `missing` situation:
  - drive → title `"{0} isn't connected"` (drive, like `E:`), detail `"{0} is on {1}, which isn't connected. It syncs again when the drive is back."`;
  - folder → the existing title, detail `"{0} wasn't there at the last sync, so it was skipped. If you moved it, use Locate on its row to show where it went."`
- Actions (write unless noted). Each takes `name` + `private` (`[bool]`) to pick the entry, the same way `sync.repair` picks it, refuses while a sync runs (`Assert-GuiNotSyncing`), and in preview returns `preview` lines:
  - `folders.pause` sets `Paused = $true`; `folders.resume` removes `Paused`. Both return `@{ saved = $true }`.
  - `folders.ensureIds` takes no args. Every entry without `Id` gets one: a valid PC marker's `id` when no other entry uses it, else `New-FolderId`. One `Save-GuiConfig`. Returns `@{ assigned = <int> }`. While a sync runs it returns `@{ assigned = 0; later = $true }` instead of refusing.

- [ ] **Step 1:** Failing tests: in `Gui.Tests.ps1`, the paused row; all paused; drive vs folder missing (Review Focus 4); a paused unseeded folder doesn't give `first`. In `GuiAction.Tests.ps1`: pause/resume round trip, which keeps the other fields and doesn't change `Get-PrivatePathsHash`; `ensureIds` adopts a PC marker's id, makes a new one when that id is taken, and saves once; refusal while syncing; preview changes nothing.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS + suite. **Step 5:** Commit `feat(app): pause and resume folders, give existing folders IDs, tell an unplugged drive from a missing folder`.

### Task 5: Identify, add, locate, adopt, new ID

**Files:** Modify `scripts\lib\GuiActions.ps1`, `tests\GuiAction.Tests.ps1`

**Interfaces (produces):**
- `folders.identify` (read). Args `{ path; encrypted: bool }`. Returns:
  ```
  @{ path; marker = $null | @{ id; kind; name }
     case = 'new' | 'moved' | 'copy' | 'reconnect'
     configured = $null | @{ name; private; path; exists }        # moved, copy
     pikpak = $null | @{ remote; name; matches = [bool] }          # reconnect
     kind = 'synced' | 'encrypted'; kindNote = $null | <string>
     nested = @(@{ path; kind; name; configured = $null | @{ name; private; path; exists } }); nestedComplete = [bool] }
  ```
  Rules, in order (spec, *Adding a folder*):
  1. The marker's `id` is a config entry's `Id`. That entry's path missing → `moved`; it exists → `copy`.
  2. The marker is valid and unknown: `Get-RemoteMarker` at `marker.pikpak` with the same id → `reconnect`, `matches = $true`, `remote = marker.pikpak`, `name` = the part after `private:` (encrypted).
  3. Otherwise, look at the place the folder would get: for synced, the `New-MirrorPair` remote; for encrypted, the leaf name. When a folder exists there (`rclone lsf <place> --max-depth 1` exit 0, or for encrypted the leaf in `rclone lsf private: --dirs-only`) and no config entry uses it → `reconnect`, `matches = $false`.
  4. Else `new`.

  `kind` is the marker's kind when there is a marker, else from `encrypted`. `kindNote` is set when they differ: `"This folder was encrypted before; it will be reconnected encrypted."` or `"This folder was synced normally before; it will be reconnected that way."` `nested` comes from `Find-NestedMarkers`. Rclone failures in rules 2–3 fall through to `new` and add the warning `"PikPak couldn't be checked for an earlier copy of this folder."`
- `folders.add` gains optional args:
  - `id`: use this ID; must pass `Test-FolderId` and must not be in use.
  - `remote`: synced reconnect, the exact `Remote`. Must be relative and not used by another pair.
  - `name`: encrypted reconnect, the exact `Name`. Must not be used.
  - `newId` (`[bool]`): keep both. The new entry gets `New-FolderId`, the folder's marker is rewritten now (`Write-FolderMarker -Force`), and the place is the free one (as `folders.newId`).

  New refusals:
  - The folder's marker kind differs from the requested kind and `newId` is not set: `'refused'`, with `kindNote`'s text.
  - The marker id is a config entry's `Id` and `newId` is not set: `'refused'`, `"This folder has the same ID as '{0}'. Choose what to do in the box."`
  - Otherwise, with no `id`/`newId`: the entry's `Id` is a valid marker's id, else `New-FolderId`.

  The encrypted path keeps all `private.add` checks.
- `folders.locateReview` (read). Args `{ name; private; path }`. Returns `@{ match = 'same'|'none'|'other'; otherName; oldPath; newRemote = $null|<string>; nested = <as identify> }`. `newRemote` is the synced path-derived remote made free (rule as `folders.newId`), or `$null` when it equals the current `Remote`.
- `folders.locate`. Args `{ name; private; path; movePikpak: bool; force: bool; alsoLocate: @(@{ name; path }) }`.
  - Re-checks `match`: `'other'` → `'refused'` `"This is '{0}', not '{1}'."`; `'none'` without `force` → `'refused'` `"This folder has no ID. Confirm to use it anyway."`
  - Overlap rules: `Get-GuiPairOverlapMessage`, or the `private.add` checks, against the config without this entry. Also not a drive root.
  - Synced with `movePikpak` and a `newRemote`: `rclone lsf <new place>` must fail with exit 3 (the place is free); then `rclone moveto <old place> <new place>`. On failure, nothing is saved and the result is `'refused'` with the reason.
  - Updates `Local`/`Path` (and `Remote`), plus each `alsoLocate` encrypted entry's `Path`, whose marker id must match. One save, then `Save-GuiPrivateConfirmation` when a `Path` changed.
- `folders.adopt`. Args `{ name; private }`. The folder must exist. `Write-FolderMarker -Force` with the entry's `Id`, then the existing repair start (`Invoke-GuiActionSyncRepair` with the same ctx). Returns the repair result.
- `folders.newId`. Args `{ name; private }`. Gives a new `Id`.
  - Synced: `Remote` becomes the path-derived remote; when that is the current one or taken by another pair, append `' (2)'`, `' (3)'`… until free.
  - Encrypted: `Name` becomes `New-ConversionPrivateName` with the current name counted as taken.
  - The marker is rewritten now when the folder exists.
  - Returns `@{ saved; remote | name }`.

- [ ] **Step 1:** Failing tests, one `It` per rule above:
  - identify: each case `new`/`moved`/`copy`/`reconnect` (matches true/false), the kind note, nested markers;
  - add: with `id`, `remote`, `name`, `newId`; each refusal;
  - locate: same/none/other; overlap refused; `movePikpak` success and target taken (no save); `alsoLocate`; confirmation hash updated;
  - adopt;
  - newId: suffix for synced, next name for encrypted.

  Mock `Invoke-GuiRclone` / `Invoke-RcloneOutput` and `Start-GuiDetached`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS + suite. **Step 5:** Commit `feat(app): recognise folders by ID when adding, locate moved folders, keep both copies`.

### Task 6: Encrypted folders in PikPak: list, download, delete

**Files:**
- Create: `scripts\Copy-EncryptedFolder.ps1`
- Modify: `scripts\lib\GuiActions.ps1`, `tests\GuiAction.Tests.ps1`

**Interfaces (produces):**
- `private.remoteList` (read). Needs a private remote (`Assert-GuiPrivateRemote`).
  - Lists with `rclone lsf private: --dirs-only` and drops `_holding`. For each folder: `Get-RemoteMarker`, then `rclone size private:<n> --json` (its `bytes`).
  - Returns `@{ folders = @(@{ name; bytes; id; connectedTo = <path>|$null; paused = [bool] }) }`.
  - Connected = an entry whose `Id` equals the marker `id`; or, when the folder has no marker, the entry whose `Name` equals the folder name.
  - A listing failure → `'remote-failed'`, `"Your encrypted folders in PikPak couldn't be listed. Try again."`
- `private.download`. Args `{ name; path }`.
  - `path` must not exist or must be an empty folder. `name` must be in the listing and must not be `_holding` or contain `\ / : * ? " < > |`.
  - Starts `scripts\Copy-EncryptedFolder.ps1 -ConfigPath <full> -Name <n> -Target <path>` detached, the same way repair starts. Returns `@{ started = $true }`.
- `Copy-EncryptedFolder.ps1`:
  - Takes the sync lock with `Enter-MirrorLock`. When the lock is held, it toasts `"Downloading {0} has to wait: a sync is running. Try again when it has finished."` and exits 1.
  - Budget: `Get-RunBudget`. When it is 0, toasts `"Downloading {0} waits for tomorrow: today's transfer limit is reached."` and exits 1.
  - Runs `rclone copy private:<n> <Target> --exclude /.pikpak-encrypted.json --exclude /RCLONE_TEST --max-transfer <bytes>B --cutoff-mode soft --log-file <log>`, then `Add-TransferredBytes` + `Save-MirrorState`.
  - Toasts `"{0} is downloaded to {1}."`, or when the limit is reached `"Part of {0} is downloaded to {1}. Download it again tomorrow; it carries on where it stopped."`, or on error `"Downloading {0} failed. See the log."`
- `private.deleteRemote`. Args `{ name }`. Refuses a connected folder (`"'{0}' is connected to {1}. Stop syncing it first."`). Checks the name as above, refuses while a sync runs, then `New-PurgeArgs -Target 'private:<n>'`. Returns `@{ deleted = $true }`.

- [ ] **Step 1:** Failing tests: the list (connected by id, by name without a marker, `_holding` dropped, listing failure); download refusals (non-empty target, bad name) and its started line in preview; delete refusals (connected, `_holding`, `''`, `a/b`) and the purge args. Script logic: put the body in a function `Invoke-EncryptedFolderCopy` in `GuiActions.ps1` or `Marker.ps1` (your choice), with a test for lock held, budget 0, and the copy args.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS + suite. **Step 5:** Commit `feat(app): list encrypted folders in PikPak, download or delete the ones not connected`.

### Task 7: Bridge

**Files:** Modify `gui\src-tauri\src\bridge.rs` (and its tests)

- [ ] **Step 1:** Failing Rust tests:
  - `is_write_action` is true for `folders.ensureIds`, `folders.pause`, `folders.resume`, `folders.locate`, `folders.adopt`, `folders.newId`, `private.download`, `private.deleteRemote`, and false for `folders.identify`, `folders.locateReview`, `private.remoteList`;
  - `action_timeout("private.remoteList")` is 300 s.
- [ ] **Step 2:** `cargo test` FAIL. **Step 3:** Implement. **Step 4:** `cargo test` PASS (baseline + new). **Step 5:** Commit `feat(bridge): new folder actions`.

### Task 8: Home UI

**Files:** Modify `gui\ui\app.js` (and `gui\ui\app.css` / `index.html` only as needed)

What the user sees (copy fixed where quoted; layout in the app's existing style):
- **App start:** after the cleanup call, call `folders.ensureIds` once (errors only logged to the console).
- **Rows:**
  - Paused: greyed out (`class 'paused'`) with a `Resume` button.
  - `Missing === 'folder'`: a `Locate…` button. A drive that isn't connected gets no button.
  - Issue kinds `folder-identity-mismatch` and `folder-marker-missing`: `Locate…` and `Use this folder anyway` (confirm: `"Use the folder at {path} as '{name}'? Its files and the PikPak copy are merged; nothing is deleted."` → `folders.adopt`).
  - `folder-duplicate-id`: `Choose…`, which opens the same-ID box.
- **Menu:**
  - `Pause syncing` / `Resume` (no confirm box).
  - `Give a new ID` (confirm: `"{name} gets a new ID and is uploaded as a new folder ({size}). The current copy in PikPak stays where it is."` → `folders.newId`).
  - Both Stop syncing boxes get the line `"To stop for a while instead, use Pause syncing."` The encrypted one
    also gets `"Its encrypted copy stays in PikPak. You can reconnect it or delete it in Settings, Encrypted folders in PikPak."`
- **Add a folder:** after the folder is picked, call `folders.identify`, then by `case`:
  - `new`: the existing box. When `kindNote` is set it shows the note, and the tick follows `kind`.
  - `moved`: `"This looks like '{name}', which was at {path}. Same folder, moved?"` with buttons `Use this one` (→ the Locate flow with this path) and `Add as a separate folder` (→ the same-ID box's keep-both).
  - `copy`: the same-ID box.
  - `reconnect`: matches → `"This folder was synced before, as '{name}'. Reconnect to it?"`; not matching → `"PikPak already has a folder called '{name}' that belongs to another folder. Reconnect to it, or start a new one?"` Buttons `Reconnect` (→ `folders.add` with `remote` or `name`, and `id` when matches) and `Start a new copy` (→ `folders.add` with `newId`).
  - `nested`: listed in the box, one line each: `"Inside it: {name} ({kind}) — synced separately"` when configured, else `"— not synced; it is left out until you reconnect it"` for encrypted, or `"— was synced before"`.
- **Locate…:** pick a folder, then `folders.locateReview`:
  - `same`: `"This is '{name}' (was at {oldPath}). Use it from now on?"`
  - `none`: `"This folder has no ID, so PikPak Sync can't tell if it is '{name}'. Use it anyway? The first sync merges both sides and deletes nothing."`
  - `other`: an error line.
  - For a synced folder with `newRemote`: a ticked checkbox `"Also move it in PikPak to {MirrorRoot}/{newRemote} (moved inside PikPak, nothing is uploaded)"`.
  - Nested encrypted entries whose configured path is missing: a ticked line `"{name} moved with it: update it too"` (→ `alsoLocate`).
  - Confirm → `folders.locate`.
- **Same-ID box:** both paths, sizes (`folders.size`) and last-changed dates. Buttons:
  - `Keep {A} only`: from add, do nothing; from the issue, remove the other entry with the existing remove action.
  - `Switch to {B}`: the Locate flow.
  - `Keep both`: a radio picks which keeps the ID (default: the configured one); confirm `"{path} gets a new ID and is uploaded as a new folder ({size})."` → `folders.add` with `newId`, or `folders.newId` for a configured entry.

- [ ] **Step 1:** Implement. **Step 2:** `node --check gui\ui\app.js` passes; build with `cargo tauri build` in the worktree's `gui` (not `main`'s) and click through each box against a **copy of the config** in a temp folder with `preview` on (the app's preview switch). Do not run a real sync. Note anything that you could not check in the ledger. **Step 3:** Commit `feat(app): Home boxes for pause, locate, same ID and reconnect`.

### Task 9: Settings UI and docs

**Files:** Modify `gui\ui\settings.js` (and `index.html`), `docs\README.md`, `docs\RECOVERY.md`, `docs\OPEN-REQUIREMENTS.md`

- [ ] **Step 1:** Under the encrypted folders list, add a section `Encrypted folders in PikPak` with a `Show` button (loads `private.remoteList`; it is not loaded on every Settings open).
  - Each row shows the name, the size, and `Connected to {path}` (with `(paused)` when paused) or `Not connected`.
  - A not-connected row has three buttons:
    - `Reconnect…`: pick a folder, then `folders.add` with `encrypted`, `name` and `id`.
    - `Download a copy…`: pick an empty folder, then `private.download`.
    - `Delete from PikPak`: confirm `"Delete '{name}' ({size}) from PikPak? It goes to PikPak's trash. Your recovery key can't bring it back after the trash is emptied."`, then `private.deleteRemote`.
  - Without a recovery key: `"Encrypted folders need a recovery key on this PC."`
- [ ] **Step 2:** Docs:
  - README: a short section each for "Moving a folder (Locate)", "Pause syncing", and "The .pikpak-sync.json / .pikpak-encrypted.json file (don't delete it)".
  - RECOVERY: step 2 mentions that the app recognises re-added folders by their ID file and that Settings lists encrypted folders in PikPak.
  - OPEN-REQUIREMENTS: live checks V-next, each with a ≤1 MB test folder:
    - pause/resume;
    - move an encrypted folder to another place and Locate it (nothing re-uploaded: check the transferred bytes);
    - copy a folder and add the copy (same-ID box);
    - Stop syncing an encrypted folder, then reconnect it from the PikPak list;
    - delete a not-connected test folder from PikPak.
- [ ] **Step 3:** `node --check gui\ui\settings.js`; the same preview click-through as Task 8. **Step 4:** Commit `feat(app): encrypted folders in PikPak in Settings; docs`.
