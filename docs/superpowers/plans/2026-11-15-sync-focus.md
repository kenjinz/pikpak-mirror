# PikPak Sync (sync focus) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Narrow the app to folder sync: delete drives, Offload/Archive, the viewer role and the unmapped-folder watcher; make encrypted folders two-way; sync hourly with a per-day budget; rename the app to PikPak Sync.

**Architecture:** The engine stays PowerShell 5.1 + rclone bisync with the Tauri app on top. Encrypted folders stop having their own one-way path and run through the same bisync loop as synced folders, via one new list function (`Get-SyncFolders`). Removals come first so later tasks edit less code.

**Tech Stack:** Windows PowerShell 5.1, rclone 1.75.2 (bisync, crypt), Pester 5.7.1, Tauri 2 (Rust + plain JS UI), Windows Task Scheduler.

**Spec:** `docs/superpowers/specs/2026-11-15-sync-focus-design.md`. Read it before any task.

## Global Constraints

- Windows PowerShell 5.1 only. Script files stay ASCII; build non-ASCII characters with `[char]`.
- Unchanged names: rclone remotes `pikpak` and `private`; remote folders `PC-Mirror`, `PC-Holding`, `PC-Private`, `private:<Name>`, `private:_holding`; task `PikPakMirror-Sync`; state folder `%LOCALAPPDATA%\PikPakMirror`; Tauri `identifier`; Cargo package name (so the exe stays `pikpak-backup.exe`); env var `PIKPAK_BACKUP_REPO`; config keys `PrivatePaths`, `Pairs`.
- Nothing in PikPak is deleted by this work. `PikPak/Archive/` is never touched.
- Live checks use files of 1 MB at most, in folders made for the check.
- Old config keys `ArchiveRoot`, `CacheDir`, `WatchRoots`, `IgnoredFolders`, `RunBudgetGB` are never an error.
- Visible name is **PikPak Sync**; user-facing text says "sync", not "back up"; encrypted folders are called "Encrypted folders".
- Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1` (one file: add `-Filter <text>`). "Suite passes" means no failure other than those in the Task 0 baseline (J3 in `Config.Tests.ps1` is expected to fail on the free-account config).
- Work on branch `feat/sync-focus`. One commit per task, message `type(scope): summary`, ending with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Do not push.
- Every task also deletes or updates the tests, Rust bridge commands, capabilities, CSS and JS that only served what it removed. Find them with a search for the removed names; the file lists below are starting points.

## Review Focus

1. A synced folder and an encrypted folder with the same `Name` (both legal): state, filter file, holding folder, issues and Repair must never cross. Test in Task 4.
2. An old `state.json` (no `Day`, `DayBytes`, `Notified`; still has `NotifiedUnmapped`) and an old config (has `RunBudgetGB` and the removed keys, no `DailyBudgetGB`, no `SyncIntervalMinutes`) load and run. Tests in Tasks 1, 2 and 3.
3. Day and month rollover between two runs: today's count resets on a new day; a new month resets both. Test in Task 3.
4. Repair of an encrypted folder whose name has spaces (`private:My Photos`) survives the `conhost.exe` command line. Test in Task 4.
5. Holding listings containing things the app no longer knows: `<date>/_archive/...` left by old offloads, a removed folder's name, `<date>/_private` with nothing under it. They are skipped, never a crash. Test in Task 7.

---

### Task 0: Baseline and live check of bisync on the encrypted remote

**Files:** none changed. Notes go in `docs/superpowers/notes/2026-11-15-sync-focus-ledger.md` (create).

- [ ] **Step 1:** `git checkout -b feat/sync-focus`. Run the suite; write the pass and fail counts and the failing test names in the ledger as the baseline.
- [ ] **Step 2:** Make sure no sync is running (`Test-SyncRunning`), then disable the task for the check: `Disable-ScheduledTask -TaskName PikPakMirror-Sync` (note whether it was enabled; restore that at the end).
- [ ] **Step 3: Live check.** Local folder `<scratch>\synctest` with three files of a few bytes; remote `private:_synctest`; workdir `<scratch>\bisync`; holding `<scratch>\hold` and `private:_holding/_synctest`. Use the flag set of `New-BisyncArgs` (without `--max-transfer`, `--bwlimit`, `--filters-file`). Run and record the result of each:
  1. `--resync` first run: files appear under `private:_synctest`; `rclone lsf pikpak:PC-Private` shows only scrambled names.
  2. Add a file locally, run: it appears in `private:_synctest`.
  3. Add a file with `rclone copyto <file> private:_synctest/new.txt`, run: it appears locally.
  4. Delete one file **as the second app would**: find its scrambled path with `rclone cryptdecode --reverse private: _synctest/<name>` and delete it with `rclone deletefile pikpak:PC-Private/<scrambled path>`. Run: the local file is moved to `<scratch>\hold`.
  5. Delete a file locally, run: it is moved to `private:_holding/_synctest`.
  6. Empty the local folder except `RCLONE_TEST`, run with `--resync`: all remote files come back, nothing is deleted remotely.
- [ ] **Step 4:** Clean up: `rclone delete private:_synctest --rmdirs` and `rclone delete private:_holding/_synctest --rmdirs`. If a command is blocked, list what is left in the ledger for the owner.
- [ ] **Step 5: Gate.** If any of 1 to 6 fails, stop and report to the owner with the rclone log; do not start Task 1. Otherwise restore the task's enabled state and commit the ledger.

---

### Task 1: Remove Offload/Archive, the drives, the viewer role and the unmapped watcher

**Files:**
- Delete: `scripts\Move-ToArchive.ps1`, `scripts\Start-Mount.ps1`, `scripts\lib\Archive.ps1`, `tests\Archive.Tests.ps1`
- Modify: `scripts\lib\_load.ps1`, `RcloneArgs.ps1`, `Setup.ps1`, `InstallSteps.ps1`, `Run.ps1`, `Status.ps1`, `State.ps1`, `Config.ps1`, `ConfigWriter.ps1`, `Gui.ps1`, `GuiActions.ps1`, `scripts\Install.ps1`, `scripts\Get-Status.ps1`, `config\mirror.config.psd1`, `gui\ui\*`, `gui\src-tauri\src\*.rs`, `gui\src-tauri\capabilities\default.json`, the matching `tests\*.Tests.ps1`

**Interfaces:**
- Produces: `Stop-MirrorMounts` (in `InstallSteps.ps1`; the body of today's `Stop-GuiMounts`, moved; Task 8 calls it). `Get-MirrorStatus` and `Get-GuiStatus` results no longer have `Unmapped`. `New-MirrorTaskSpec -Kind` accepts only `Sync`. `Register-MirrorTasks` loses `-Kind` values `All` and `Mount` (keep the parameter with the single value `Sync` so callers keep working).

- [ ] **Step 1: Write the failing tests** (in `tests\Config.Tests.ps1` and `tests\State.Tests.ps1`):

```powershell
It 'accepts a config without ArchiveRoot, CacheDir, WatchRoots and IgnoredFolders' {
    $cfg = New-ValidConfig   # the file's existing helper for a valid config
    foreach ($k in 'ArchiveRoot','CacheDir','WatchRoots','IgnoredFolders') { $cfg.Remove($k) }
    @(Test-MirrorConfig -Config $cfg).Count | Should -Be 0
}
It 'still accepts a config that has the removed keys' {
    $cfg = New-ValidConfig
    $cfg.ArchiveRoot = 'Archive'; $cfg.CacheDir = 'D:\.pikpak-cache'; $cfg.WatchRoots = @('D:\'); $cfg.IgnoredFolders = @('Game')
    @(Test-MirrorConfig -Config $cfg).Count | Should -Be 0
}
It 'reserves the pair name _private and no longer reserves _archive' {
    # a pair named '_private' -> one error containing "reserved name '_private'"; a pair named '_archive' -> no error
}
It 'loads a state.json that still has NotifiedUnmapped' {
    # write {"NotifiedUnmapped":["D:\\X"],"Month":"2026-10"}; Get-MirrorState returns Month '2026-10' and has no NotifiedUnmapped property
}
It 'drops the removed keys when the config is written' {
    # ConvertTo-MirrorConfigText of a config with the four removed keys: output matches none of them
}
```

- [ ] **Step 2:** Run those tests; they fail.
- [ ] **Step 3: Remove, per the table in spec section 1.** Decisions the table leaves open:
  - `Test-MirrorConfig`: `ArchiveRoot` leaves the required list and the remote-roots check; `_archive` reservation is replaced by `_private` (Task 4 uses that folder name in local holding).
  - `Get-MirrorConfig`: stop normalising `CacheDir` and `WatchRoots`.
  - `ConvertTo-MirrorConfigText` (`ConfigWriter.ps1`, key-order list near line 48): remove the four keys from the list and make sure keys outside the list are not written.
  - `New-MirrorLocalFolders`: only `LocalHolding` and `StateDir`.
  - `Install.ps1`: delete `-Role`, the WinFsp step, the mount step, the Explorer-menu step.
  - `Invoke-GuiActionSetupFinish`: delete the WinFsp, Explorer-menu and mount steps; `New-GuiSetupConfig` writes none of the removed keys.
  - UI: delete the Offload screen, the "File Explorer" settings block, the Advanced "Folder for temporary files" row, the "Not backed up yet" block, the drive note on the setup "done" screen, the footer note on the restore screen. Replace the shortcut "Open my backup in File Explorer" with **"Open PikPak in my browser"**, which calls `openUrl('https://mypikpak.com/drive')` from `bridge.js`.
  - Rust: delete commands, tray items and capability entries that only served mounts or offload (for example file pickers used only by Offload).
  - `config\mirror.config.psd1`: delete the four keys and their comments.
- [ ] **Step 4:** Search must return nothing outside `docs\` and the ledger: `Mount|mount\.|Offload|offload|ArchiveRoot|_archive|WinFsp|CacheDir|WatchRoots|IgnoredFolders|Unmapped|Viewer` in `scripts`, `tests`, `config`, `gui\ui`, `gui\src-tauri\src`, `gui\src-tauri\capabilities` (allowed: `Stop-MirrorMounts` and its comment).
- [ ] **Step 5:** Suite passes. `cargo build` and `cargo test` in `gui\src-tauri` pass.
- [ ] **Step 6:** Commit `refactor: remove drives, offload, viewer role and unmapped watcher`.

---

### Task 2: Per-day transfer budget

**Files:** `scripts\lib\State.ps1`, `Config.ps1`, `ConfigWriter.ps1`, `Run.ps1`, `Status.ps1`, `Gui.ps1`, `GuiActions.ps1` (`New-GuiSetupConfig`), `gui\ui\settings.js`, `gui\ui\index.html`, `config\mirror.config.psd1`; tests `State.Tests.ps1`, `Config.Tests.ps1`, `Run.Tests.ps1`, `Gui.Tests.ps1`

**Interfaces (produces):**
- State gains `Day` (`'yyyy-MM-dd'` or `$null`) and `DayBytes` (`[long]`).
- `Get-DayKey -Now <datetime>` returns `'yyyy-MM-dd'`.
- `Get-DailyBudgetGB -Config <hashtable>` returns `DailyBudgetGB` when the key is present, else `RunBudgetGB`.
- `Add-TransferredBytes` (same signature) also adds to `DayBytes`, resetting it when `Day` differs from today.
- `Get-BudgetLeft -State -Config -Now` returns `@{ Day = [long]; Month = [long] }` (bytes, never below 0).
- `Get-RunBudget` (same signature) returns `min(Day, Month)` from `Get-BudgetLeft`.
- `LastRunInfo.Result` gains the value `'day-paused'`.
- `Get-MirrorStatus` gains `DayUsedGB` and `DayBudgetGB`.
- `Get-BudgetPreset` returns `DailyBudgetGB` instead of `RunBudgetGB` (free 1, premium 8).

- [ ] **Step 1: Write the failing tests.**

```powershell
# State.Tests.ps1
It 'counts bytes per day and resets on a new day' {
    $s = New-MirrorState
    Add-TransferredBytes -State $s -Bytes 100 -Now ([datetime]'2026-11-15T23:50:00')
    Add-TransferredBytes -State $s -Bytes 50  -Now ([datetime]'2026-11-16T00:10:00')
    $s.Day | Should -Be '2026-11-16'; $s.DayBytes | Should -Be 50; $s.TransferredBytes | Should -Be 150
}
It 'resets day and month counts on a new month' {
    # 100 bytes on 2026-11-30, then 7 bytes on 2026-12-01: DayBytes 7, TransferredBytes 7, Month '2026-12'
}
It 'limits a run to what is left today' {
    # DailyBudgetGB 1, MonthlyBudgetGB 30, DayBytes 0.75GB same day, month used 2GB -> Get-RunBudget = 0.25GB
}
It 'limits a run to what is left this month when that is less' {
    # DailyBudgetGB 8, MonthlyBudgetGB 30, month used 29.5GB, DayBytes 0 -> 0.5GB
}
It 'uses RunBudgetGB when DailyBudgetGB is missing' {
    Get-DailyBudgetGB -Config @{ RunBudgetGB = 3 } | Should -Be 3
    Get-DailyBudgetGB -Config @{ RunBudgetGB = 3; DailyBudgetGB = 5 } | Should -Be 5
}
It 'loads an old state.json without Day and DayBytes' { # Day $null, DayBytes 0 }
# Config.Tests.ps1
It 'accepts DailyBudgetGB without RunBudgetGB, and RunBudgetGB without DailyBudgetGB' { }
It 'rejects a config with neither' { # one error naming DailyBudgetGB }
# Run.Tests.ps1
It 'skips the run quietly when today''s budget is used up' {
    # state: Day = today, DayBytes = DailyBudgetGB; run -> no rclone calls, no toasts,
    # Skipped contains 'budget', saved LastRunInfo.Result -eq 'day-paused'
}
It 'passes what is left today as --max-transfer' { }
# Gui.Tests.ps1
It 'shows day-paused as a calm message, not as a failure' {
    # LastRunInfo.Result 'day-paused' -> Situation 'day-paused', Tone 'ok'
}
```

- [ ] **Step 2:** Run; they fail.
- [ ] **Step 3: Implement.**
  - `Invoke-MirrorRun` step 4: month used up keeps today's behaviour (`month-paused`, one toast). Else if `Get-BudgetLeft().Day -le 0`: `Write-MirrorLog` "today's transfer budget is used up; syncing continues tomorrow", add `'budget'` to skipped, result `'day-paused'`, return. No toast.
  - `Get-GuiStatus`: `'day-paused'` joins the results that are not failures (the condition near line 147). New situation, placed before the `'first'` check: `'day-paused'`, tone `ok`, title `Today's transfer limit is reached`, detail `Syncing carries on tomorrow. Nothing is lost.` The `'budget-stopped'` detail becomes `PikPak's transfer limit for today was reached. The rest carries on tomorrow.`
  - `ConvertTo-MirrorConfigText`: `DailyBudgetGB` takes `RunBudgetGB`'s place in the key order; when the config has `RunBudgetGB` and no `DailyBudgetGB`, write `DailyBudgetGB` with that value; never write `RunBudgetGB`.
  - Settings, Advanced: the field `advRun` reads and writes `DailyBudgetGB`; label `Transfer limit per day (GB)`. `advMonth` label `Transfer limit per month (GB)`.
  - `config\mirror.config.psd1`: `RunBudgetGB = 1` becomes `DailyBudgetGB = 1`; fix the comment (Premium: `DailyBudgetGB = 8`).
- [ ] **Step 4:** Suite passes.
- [ ] **Step 5:** Commit `feat(engine): transfer budget per day instead of per run`.

---

### Task 3: Notify once per problem

**Files:** `scripts\lib\State.ps1`, `Run.ps1`; tests `State.Tests.ps1`, `Run.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DayKey` (Task 2).
- Produces: State gains `Notified` (hashtable: key to `'yyyy-MM-dd'`), loaded and saved like `Pairs`. `Send-RunIssueToast -State -Config -Now -Key <string> -Message <string>` in `Run.ps1`: calls `Send-MirrorToast` only when `State.Notified[Key]` is not today's day key, then stores today's key. Key format: `'<folder key>|<kind>'`, with folder key `global` for problems that belong to no folder. In this task the folder key is the pair name or `private:<Name>`; Task 4 makes that `StateKey`.

- [ ] **Step 1: Write the failing tests** (`Run.Tests.ps1`; the existing mock records toasts in `$script:toasts`):

```powershell
It 'toasts a lasting problem once, not at every run of the same day' {
    # responder: bisync returns TooManyDeletes. Run twice with the same $Now date -> 1 toast in total
}
It 'toasts a lasting problem again the next day' {
    # same, second run with $Now.AddDays(1) -> 2 toasts
}
It 'toasts again the same day when the problem was solved in between' {
    # run 1 fails (1 toast), run 2 succeeds, run 3 fails again -> 2 toasts
}
It 'keeps the memory of a folder that was not reached because the budget stopped the run' {
    # two pairs; run 1: Beta fails (1 toast). run 2: Alpha hits the budget so Beta is not tried.
    # run 3 same day: Beta fails again -> still 1 toast
}
It 'loads an old state.json without Notified' { # Notified is an empty hashtable }
```

- [ ] **Step 2:** Run; they fail.
- [ ] **Step 3: Implement.**
  - Every `Send-MirrorToast` in `Invoke-MirrorRun` that reports an issue goes through `Send-RunIssueToast`: config errors (`global|config-invalid`), unconfirmed private folders, folder missing, sentinel failed, folder empty, delete safety, stuck upload, needs repair, other failures, prune failed, and the "no successful sync for N days" toast (`global|stale`). The toasts that already fire once (mapping changed, filters changed, month budget used up, 90% warning) stay as they are.
  - Solved problems are forgotten at the end of the run: remove every `Notified` key whose folder was attempted in this run and whose `<folder key>|<kind>` was not raised in this run. `global|...` keys are removed when the run got past the check that raises them and did not raise it.
  - The `Issues` list and `$errors` are filled exactly as before; only the toast is suppressed.
- [ ] **Step 4:** Suite passes.
- [ ] **Step 5:** Commit `feat(engine): notify once per problem per day`.

---

### Task 4: Encrypted folders through the bisync path

**Files:** `scripts\lib\Run.ps1`, `RcloneArgs.ps1`, `Status.ps1`, `State.ps1`, `Gui.ps1`, `GuiActions.ps1`, `scripts\Invoke-Sync.ps1`, `scripts\Get-Status.ps1`, `gui\ui\app.js`; tests `Run.Tests.ps1`, `RcloneArgs.Tests.ps1`, `Status.Tests.ps1`, `Gui.Tests.ps1`, `GuiAction.Tests.ps1`

**Interfaces (produces):**
- `Get-SyncFolders -Config <hashtable>` (in `Run.ps1`) returns hashtables, encrypted folders first in config order, then pairs by `Priority` then `Name`:

| Key | Synced folder | Encrypted folder |
|---|---|---|
| `Kind` | `'pair'` | `'private'` |
| `Name` | pair `Name` | entry `Name` |
| `Local` | pair `Local` | entry `Path` |
| `RemotePath` | `pikpak:PC-Mirror/<Remote>` | `private:<Name>` |
| `StateKey` | `<Name>` | `private:<Name>` |
| `HoldLocal` | `<Name>` | `_private\<Name>` |
| `HoldRemote` | `pikpak:PC-Holding` | `private:_holding` |
| `Priority` | pair `Priority` | `0` |

  (remote and root names come from the config, as today.)
- `New-BisyncArgs`: parameter `-Pair` is replaced by `-Folder` (one `Get-SyncFolders` item). Paths: local `Folder.Local`, remote `Folder.RemotePath`, `--backup-dir1 <LocalHolding>\<day>\<HoldLocal>`, `--backup-dir2 <HoldRemote>/<day>/<Name>`. All other flags unchanged.
- `Get-FolderIdentity -Folder` replaces `Get-PairIdentity` (hash of `<local>|<RemotePath>`, lower-case). For a pair it must return the same hash as `Get-PairIdentity` did, so live pairs are not resynced: keep hashing `<local>|<ConvertTo-RemoteKey Remote>` for `Kind = 'pair'`.
- `Update-FolderFilterFile -Config -Folder` replaces `Update-PairFilterFile`. Pairs: unchanged path and rules. Encrypted: file `<StateDir>\filters\private\<Name>.txt`, rules = the global rules only.
- State: per-folder entries live in `State.Pairs[<StateKey>]`.
- Issues gain `Private = [bool]`; `Get-MirrorState` keeps it when loading `LastRunInfo.Issues`.
- `Invoke-MirrorRun -ForceResync` and `Invoke-Sync.ps1 -Resync` match a folder by `StateKey` (case-insensitive). `Get-UnknownPairNames` checks against all `StateKey`s.
- `Get-MirrorStatus.Pairs` rows gain `Private = [bool]` and cover encrypted folders too (read from their `StateKey`).
- GUI action `sync.repair` takes `name` and optional `private` (bool) and passes `private:<Name>` for an encrypted folder.
- Deleted: `New-PrivateSyncArgs`, step 5 of `Invoke-MirrorRun`, issue kind `private-failed`.

- [ ] **Step 1: Write the failing tests.**

```powershell
# RcloneArgs.Tests.ps1
It 'builds bisync arguments for an encrypted folder' {
    $f = @(Get-SyncFolders -Config $cfg | Where-Object { $_.Kind -eq 'private' })[0]   # entry Name 'Photos', Path D:\Photos
    $a = New-BisyncArgs -Config $cfg -Folder $f -FiltersFile 'f.txt' -Date ([datetime]'2026-11-15') -BudgetBytes 1 -LogFile 'l.log'
    $a[0..2] | Should -Be @('bisync', 'D:\Photos', 'private:Photos')
    (Get-ArgValue $a '--backup-dir1') | Should -Be (Join-Path $cfg.LocalHolding '2026-11-15\_private\Photos')
    (Get-ArgValue $a '--backup-dir2') | Should -Be 'private:_holding/2026-11-15/Photos'
}
It 'keeps a pair''s arguments exactly as before' { # compare with the existing expected list for a pair }
# Run.Tests.ps1
It 'lists encrypted folders first, then pairs by priority and name' { }
It 'keeps the identity hash of an existing pair' {
    # Get-FolderIdentity for a pair equals the literal hash the old Get-PairIdentity test expects
}
It 'syncs an encrypted folder with bisync, resync on its first run' {
    # one PrivatePaths entry, confirmed: calls contain a copyto of RCLONE_TEST to private:<Name>/RCLONE_TEST
    # and a 'bisync' call with '--resync'; no call starts with 'sync'; state.Pairs['private:<Name>'].Seeded is $true
}
It 'keeps a synced folder and an encrypted folder of the same name apart' {
    # pair 'Docs' and private 'Docs'; the encrypted bisync fails (exit 1), the pair succeeds:
    # state.Pairs['Docs'].LastExit -eq 0; state.Pairs['private:Docs'].LastExit -eq 1;
    # exactly one issue, with Private $true; the two --filters-file values differ; the two --backup-dir1 values differ
}
It 'applies the delete safety stop to an encrypted folder' { # TooManyDeletes -> issue kind 'delete-safety', Private $true }
It 'resyncs only the encrypted folder named private:Docs' {
    # both seeded; -ForceResync 'private:Docs' -> only the private:Docs bisync has --resync
}
It 'accepts private:<Name> and rejects unknown names' {
    @(Get-UnknownPairNames -Config $cfg -Names 'private:Docs','Docs','private:Nope') | Should -Be @('private:Nope')
}
# Gui.Tests.ps1
It 'shows an encrypted folder as Part-way until its first sync finished' { }
It 'puts an issue of the encrypted folder on its row, not on the pair of the same name' { }
# GuiAction.Tests.ps1
It 'repairs an encrypted folder whose name has spaces' {
    # sync.repair { name='My Photos'; private=$true } in preview: the preview line ends with -Resync "private:My Photos"
}
```

- [ ] **Step 2:** Run; they fail.
- [ ] **Step 3: Implement.** `Invoke-MirrorRun` gets one loop over `Get-SyncFolders`, ordered: encrypted folders, then seeded pairs, then unseeded pairs. Messages use the folder's `Name`. `Get-GuiStatus` builds every row from `Get-MirrorStatus.Pairs` and matches issues on `Name` and `Private` together. `Get-Status.ps1` prints encrypted folders with their last result. In `app.js` the Repair button of an encrypted folder row sends `private: true`.
- [ ] **Step 4:** Suite passes.
- [ ] **Step 5:** Commit `feat(engine): encrypted folders sync both ways through bisync`.

---

### Task 5: Sync every N minutes

**Files:** `scripts\lib\Config.ps1`, `ConfigWriter.ps1`, `Setup.ps1`, `InstallSteps.ps1`, `GuiActions.ps1`, `gui\ui\settings.js`, `gui\ui\index.html`, `config\mirror.config.psd1`; tests `Config.Tests.ps1`, `Setup.Tests.ps1`, `InstallSteps.Tests.ps1`, `GuiAction.Tests.ps1`

**Interfaces (produces):**
- Config key `SyncIntervalMinutes`; allowed `0, 15, 30, 60, 180, 360`.
- `Get-SyncIntervalMinutes -Config` returns the key's value, or `60` when missing.
- `New-MirrorTaskSpec` gains `[int]$SyncIntervalMinutes = 60`. Triggers: the logon trigger as today when `SyncAtLogon`; then, for `0`, `@{ Type = 'Daily'; At = $SyncTime }`; otherwise `@{ Type = 'Repeat'; At = '00:00'; Minutes = <n> }`.
- Trigger signatures: `'Repeat@<minutes>'` from both `Get-SpecTriggerSignature` and `Get-TaskTriggerSignature`.
- `schedule.get` returns `intervalMinutes`; `schedule.set` accepts `intervalMinutes`.

- [ ] **Step 1: Write the failing tests.**

```powershell
It 'defaults to 60 minutes when the key is missing' { Get-SyncIntervalMinutes -Config @{} | Should -Be 60 }
It 'rejects an interval that is not offered' { # SyncIntervalMinutes = 45 -> one error naming SyncIntervalMinutes }
It 'accepts 0, 15, 30, 60, 180 and 360' { }
It 'builds a repeating trigger' {
    $s = New-MirrorTaskSpec -Kind Sync -RepoRoot 'C:\r' -ConfigPath 'C:\r\c.psd1' -SyncIntervalMinutes 60
    @($s.Triggers | Where-Object { $_.Type -eq 'Repeat' })[0].Minutes | Should -Be 60
    @($s.Triggers | Where-Object { $_.Type -eq 'Daily' }).Count | Should -Be 0
}
It 'builds the daily trigger for interval 0' { # Daily at SyncTime, no Repeat }
It 'signs a repeating trigger by its minutes' {
    Get-SpecTriggerSignature -Trigger @{ Type = 'Repeat'; At = '00:00'; Minutes = 180 } | Should -Be 'Repeat@180'
}
It 'reads PT1H and PT60M from a registered trigger as the same signature' {
    # fake trigger objects with CimClass name 'MSFT_TaskDailyTrigger' and Repetition.Interval 'PT1H' / 'PT60M' -> both 'Repeat@60'
}
It 'schedule.set saves intervalMinutes and re-registers the task' { # preview mode: preview names the new interval }
It 'schedule.set refuses an interval that is not offered' { # error code 'bad-request' }
```

- [ ] **Step 2:** Run; they fail.
- [ ] **Step 3: Implement.**
  - `Install-MirrorTask` builds a `Repeat` trigger as a daily trigger at `00:00` whose `Repetition` is taken from a `-Once` trigger: `(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes $n) -RepetitionDuration (New-TimeSpan -Days 1)).Repetition`. Parse a registered interval with `[System.Xml.XmlConvert]::ToTimeSpan`. A registered daily trigger without a repetition interval keeps the signature `Daily@HH:mm`.
  - `Register-MirrorTasks` passes `Get-SyncIntervalMinutes`.
  - Task description: `PikPak Sync: two-way sync of the configured folders with PikPak.`
  - Settings: the row "When to back up" becomes **How often to sync**, a select `setEvery` with: Every 15 minutes (15), Every 30 minutes (30), Every hour (60), Every 3 hours (180), Every 6 hours (360), Once a day (0). The existing time select `setTime` is shown only for "Once a day".
  - `ConvertTo-MirrorConfigText`: `SyncIntervalMinutes` goes after `SyncTime`. `New-GuiSetupConfig` and the shipped config set `SyncIntervalMinutes = 60`.
- [ ] **Step 4:** Suite passes. Then, by hand on this PC: `Install.ps1 -WhatIf` prints the repeating trigger; run `Install.ps1` and check `(Get-ScheduledTask PikPakMirror-Sync).Triggers` shows the daily trigger with a 1-hour repetition, and that the task's enabled state did not change.
- [ ] **Step 5:** Commit `feat: sync every hour by default, interval setting`.

---

### Task 6: Rename to PikPak Sync and reword

**Files:** `gui\src-tauri\tauri.conf.json`, `gui\src-tauri\src\tray.rs`, `main.rs`, `gui\ui\index.html`, `app.js`, `settings.js`, `setup.js`, `scripts\lib\Run.ps1`, `Gui.ps1`, `GuiActions.ps1`, `scripts\Invoke-Sync.ps1`, and the tests that assert these strings

- [ ] **Step 1:** Change the tests that assert user-facing strings to the new wording below; run; they fail.
- [ ] **Step 2: Apply.**
  - Name: `productName` and window `title` in `tauri.conf.json`, the `<title>`, the app bar, the tray tooltip and menu, `$script:MirrorToastTitle`, the toast title in `Invoke-Sync.ps1`, and every "PikPak Backup" / "PikPak Mirror" in user-facing messages become **PikPak Sync**. Not changed: `identifier`, Cargo package name, `PIKPAK_BACKUP_REPO`.
  - Fixed copy:

| Where | New text |
|---|---|
| Welcome title | Keep your folders in sync with PikPak |
| Welcome lead | Pick the folders you care about. Changes you make on this PC or in PikPak are copied to the other side every hour. |
| Welcome promise 1 | **Runs by itself** Every hour while your PC is on. You don't need to open this app. |
| Welcome promise 2 | **Deleted something by mistake?** Anything deleted or overwritten by a sync is kept for 30 days. |
| Welcome promise 3 | **Encrypted folders** Folders you mark encrypted are locked before they leave your PC. PikPak can't read them. |
| Home list heading | Synced folders |
| Home button / tray item | Sync now |
| Status `ok` title | Your folders are in sync |
| Status `running` title | Syncing now... |
| Status `paused` | Syncing is paused / Nothing is synced until you turn syncing back on. |
| Status `never` | Your first sync hasn't run yet / It runs by itself every hour. You can also press Sync now. |
| Status `first` | Your first sync is on its way / Big folders can take a few days. It carries on by itself. |
| Status `stale` detail | Check that this PC is on and that syncing is not paused. |
| Folder pill while running | Syncing |
| Settings heading "Backups" | Syncing |
| Settings "Pause backups" | Pause syncing |
| Settings "Private folders" / "Add private folder" | Encrypted folders / Add encrypted folder |
| Setup folder list, "Private" mark | Encrypted |
| Restore screen lead | Files deleted or overwritten by a sync are kept for 30 days. Pick one to put it back where it was. |

  - Every other "back up", "backup", "backed up" and "private folder" in user-facing text follows the same pattern ("sync", "Encrypted folder"). "Last backup" / "Next backup" become "Last sync" / "Next sync". Code identifiers and config keys are not renamed.
  - Old autostart entry: at start-up the app checks `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run` for a value named `PikPak Backup`; if present it deletes it and turns autostart on under the new name through the autostart plugin.
- [ ] **Step 3:** Search `gui\ui`, `gui\src-tauri\src` and `scripts` for `PikPak Backup|PikPak Mirror|[Bb]ack(ed)?[ -]?up|[Pp]rivate folder` in user-facing strings; only code identifiers, comments about history, and the old-autostart value name remain.
- [ ] **Step 4:** Suite passes; `cargo test` passes.
- [ ] **Step 5:** Commit `feat(ui): rename to PikPak Sync, sync wording`.

---

### Task 7: Deleted files of encrypted folders in the app

**Files:** `scripts\lib\Gui.ps1`, `GuiActions.ps1`, `gui\ui\app.js`; tests `Gui.Tests.ps1`, `GuiAction.Tests.ps1`

**Interfaces:**
- Consumes: holding locations from Task 4 (`<LocalHolding>\<date>\_private\<Name>\...` and `private:_holding/<date>/<Name>/...`).
- Produces: `ConvertTo-HoldingItems -Source` accepts `pc`, `cloud`, `private`. Items gain `Private = [bool]`. For an encrypted folder: `Pair` is its `Name`, `RestoreTo` is `<entry Path>\<rel>`; `HoldingPath` is the local path (source `pc`) or `_holding/<date>/<Name>/<rel>` (source `private`). `holding.restore` accepts `Source = 'private'` and reads `Private` from the item.

- [ ] **Step 1: Write the failing tests.**

```powershell
It 'lists a file an encrypted folder lost from the PikPak side' {
    # pc entry '2026-11-14/_private/Photos/a/b.jpg' with PrivatePaths Photos = D:\Photos ->
    # Private $true, Pair 'Photos', RelPath 'a\b.jpg', RestoreTo 'D:\Photos\a\b.jpg',
    # HoldingPath '<LocalHolding>\2026-11-14\_private\Photos\a\b.jpg'
}
It 'lists a file an encrypted folder lost from the PC side' {
    # private entry '2026-11-14/Photos/b.jpg' -> Source 'private', Private $true,
    # HoldingPath '_holding/2026-11-14/Photos/b.jpg', RestoreTo 'D:\Photos\b.jpg'
}
It 'skips entries it does not know' {
    # pc: '2026-11-01/_archive/x.txt', '2026-11-01/Gone/x.txt', '2026-11-01/_private/x.txt', '2026-11-01/_private/Gone/x.txt'
    # private: '2026-11-01/Gone/x.txt', 'notadate/Photos/x.txt'  -> zero items, no error
}
It 'does not mix a pair and an encrypted folder of the same name' {
    # pair Docs = D:\Docs, private Docs = E:\Docs; pc entries '.../Docs/x.txt' and '.../_private/Docs/x.txt'
    # -> RestoreTo 'D:\Docs\x.txt' (Private $false) and 'E:\Docs\x.txt' (Private $true)
}
It 'holding.list asks the encrypted remote only when there are encrypted folders' {
    # no PrivatePaths -> no rclone call whose arguments contain 'private:_holding'
}
It 'holding.list still returns the other sources when the encrypted remote cannot be listed' {
    # lsjson of private:_holding exits 1 -> ok envelope, warning set, pc and cloud items present
}
It 'holding.restore downloads from private:_holding in preview' {
    # item Source 'private' -> preview line names 'private:_holding/2026-11-14/Photos/b.jpg' and the target
}
```

- [ ] **Step 2:** Run; they fail.
- [ ] **Step 3: Implement.** `Invoke-GuiActionHoldingList` adds `rclone lsjson -R --files-only private:_holding` (exit 3 means empty, as for the cloud source). `Invoke-GuiActionHoldingRestore` re-derives paths from the config as today, with the same never-overwrite download for `private`. In `app.js` the list shows the encrypted folder's name with an "Encrypted" tag.
- [ ] **Step 4:** Suite passes.
- [ ] **Step 5:** Commit `feat(app): deleted files of encrypted folders can be restored`.

---

### Task 8: One-time cleanup of the live install

**Files:** `scripts\lib\InstallSteps.ps1`, `scripts\Install.ps1`, `scripts\lib\GuiActions.ps1`, `gui\ui\app.js`; tests `InstallSteps.Tests.ps1`, `GuiAction.Tests.ps1`

**Interfaces:**
- Consumes: `Stop-MirrorMounts` (Task 1), `Register-MirrorTasks` (Task 5).
- Produces: `Invoke-MirrorCleanup -Config -ConfigPath -RepoRoot [-WhatIf]` returning an install-step result (`Join-InstallStepResults -Name 'Cleanup'`). GUI action `cleanup` (needs config) returning `@{ done = [bool]; messages = [string[]] }`, with a preview mode.

- [ ] **Step 1: Write the failing tests** (mock `Get-ScheduledTask`, `Unregister-ScheduledTask`, `Stop-MirrorMounts`, `Register-MirrorTasks`, `Test-SyncRunning`; point the registry part at a test key through a parameter `-ClassesRoot` defaulting to `Software\Classes`):

```powershell
It 'removes the mount task and the two menu keys, and re-registers the sync task' { }
It 'does nothing the second time' { # every part reports Skipped; Unregister-ScheduledTask not called }
It 'changes nothing with -WhatIf' { # messages start with 'Would'; no mock that changes things was called }
It 'does not stop the mounts while a sync is running' { # Test-SyncRunning $true -> Stop-MirrorMounts not called, part reports a warning }
It 'cleanup action returns the would-lines in preview' { }
```

- [ ] **Step 2:** Run; they fail.
- [ ] **Step 3: Implement.** Parts, each skipped when there is nothing to do: stop the rclone mount processes (only when the `PikPakMirror-Mount` task exists; never during a sync); unregister `PikPakMirror-Mount`; delete `HKCU:\Software\Classes\*\shell\PikPakOffload` and `HKCU:\Software\Classes\Directory\shell\PikPakOffload` (use `-LiteralPath`; `*` is a real key name); `Register-MirrorTasks -Kind Sync` without `-EnableSchedule` (it keeps an enabled task enabled). `Install.ps1` runs it as a step. `app.js` calls `cleanup` once at start-up when the app is set up, and ignores a failure (it is logged).
- [ ] **Step 4:** Suite passes.
- [ ] **Step 5:** Commit `feat(install): one-time cleanup of drives and offload menu`.

---

### Task 9: Docs, build, live check

**Files:** `docs\README.md`, `docs\RECOVERY.md`, `docs\OPEN-REQUIREMENTS.md`, `docs\HANDOFF.md`, the ledger

- [ ] **Step 1: Docs**, per spec section 7. The README must cover: the two kinds of folder; hourly sync and the interval setting; the daily and monthly limits; deleted files (where each kind is kept, 30 days, the PC-side copies of encrypted folders are readable); Repair for a lost folder; the second-app rule (rclone crypt format, same password and salt, under `PC-Private/`); the 10% delete safety stop also applies to encrypted folders; hand cleanup (uninstall WinFsp, delete `D:\.pikpak-cache`, uninstall the old "PikPak Backup" Start-menu copy, `PikPak/Archive/` is yours to keep or delete); which exe to run. `RECOVERY.md`: new PC = setup with the recovery key, add the encrypted folder, Repair; or `rclone copy private:<Name> <folder>`; state that deleted-file copies kept on the PC are lost with the disk. No sentence about `P:`, `Q:`, Offload or the Archive feature remains in those four files.
- [ ] **Step 2:** Suite passes against the Task 0 baseline. In `gui`: `cargo test` and `cargo tauri build` succeed. Record counts in the ledger.
- [ ] **Step 3: Live check** with files of a few KB, in a new synced folder and a new encrypted folder made for the check (add them in the app). Record each result in the ledger:
  1. Start the built app: drives `P:`/`Q:` are gone, the task `PikPakMirror-Mount` and the right-click entry are gone, `PikPakMirror-Sync` repeats hourly.
  2. Wait for one scheduled run; it happens by itself.
  3. Synced folder: a file uploaded in the PikPak web app arrives on the PC; a file deleted on the PC appears in "Get back a deleted file" and restores.
  4. Encrypted folder: PikPak shows only scrambled names; a scrambled file deleted in the PikPak web app disappears from the PC at the next sync and appears in the deleted list; restoring it brings it back and the next sync uploads it.
  5. Empty the encrypted folder on the PC, sync (it stops with "the PC folder is empty"), press Repair: the files come back.
  6. Run two syncs with the same unsolved problem: one notification.
  7. Remove the two check folders from the app; list what is left in PikPak for the owner to delete.
- [ ] **Step 4:** Commit `docs: PikPak Sync guide, recovery and open requirements`.
