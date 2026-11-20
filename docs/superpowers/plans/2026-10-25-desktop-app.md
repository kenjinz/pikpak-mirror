# PikPak Backup desktop app Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Windows desktop app (Tauri 2 / Rust) that replaces every PowerShell command and Notepad edit in day-to-day use of PikPak Mirror, with the screens of the approved prototype.

**Architecture:** The existing PowerShell 5.1 engine stays the engine. New PowerShell functions (`scripts/lib/Gui.ps1`, `scripts/lib/ConfigWriter.ps1`, `scripts/lib/InstallSteps.ps1`) hold all new logic, Pester-tested. One entry script, `scripts/Invoke-GuiAction.ps1`, reads a JSON request on stdin and writes a JSON envelope on stdout. A thin Tauri app (`gui/`) shows the prototype's HTML, runs that script, and provides the tray icon and native dialogs.

**Tech Stack:** Windows PowerShell 5.1, Pester 5.7.1, rclone v1.75.2, Rust stable (`x86_64-pc-windows-msvc`), Tauri 2, `tauri-plugin-dialog`, `tauri-plugin-autostart`, `tauri-plugin-single-instance`, plain HTML/CSS/JS (no framework, no bundler).

**Spec:** [docs/superpowers/specs/2026-10-25-desktop-app-design.md](../specs/2026-10-25-desktop-app-design.md). Visual reference: [2026-10-25-desktop-app-prototype.html](../specs/2026-10-25-desktop-app-prototype.html).

## Global Constraints

- All rules in [global-constraints.md](../notes/global-constraints.md) apply to PowerShell code: PS 5.1 syntax only, ASCII source files (non-ASCII via `[char]`), functions returning arrays emit unrolled, unit tests never touch rclone / network / registry / Task Scheduler, files rclone reads are UTF-8 without BOM.
- Full suite stays green: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1`.
- Secrets go from the app to PowerShell **on stdin only**, never as process arguments; never written to disk or logs by our code. PowerShell to rclone reuses `New-PikPakRemoteArgs` / `New-CryptRemoteArgs` (R16).
- The app never shows "backed up" unless the last run record says `ok` (spec anti-goal 1).
- Config writes: validate before writing; keep `mirror.config.psd1.bak`; copy the hand-made file once to `mirror.config.original.psd1` before the first app write.
- Live checks use files of 1 MB at most (free account quota).
- UI copy: sentence case, plain words, the prototype's wording where it exists; errors say what happened and what to do; no raw rclone output in the UI.
- Look: prototype tokens — ink `#1F2A37`, muted `#5B6776`, line `#D6DEE6`, window `#F3F6F9`, teal `#0F6E6A`, key tag `#F6E3A1`/`#C9A93F`, warn `#9A5B00`/`#FBF0DC`, bad `#B3261E`/`#FBE7E5`; Segoe UI Variable; recovery key in Cascadia Mono / Consolas.
- Commit messages end with a blank line then `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A run that failed before touching any folder** (private folders not confirmed, config invalid, private sync failed, prune failed) must make Home say *Needs attention*, not *Backed up*. Pinned in Task 1 and Task 5 tests.
2. **Paths with spaces, apostrophes and non-ASCII names** (`D:\Nhạc`, `C:\Users\O'Brien\Music`) must survive config write → engine read unchanged. Pinned in Task 4.
3. **A folder picked in the dialog that overlaps an existing pair or private folder** (parent, child, same folder, different case) must be refused with a plain message, not written. Pinned in Task 4 (via `Test-MirrorConfig`) and Task 7.
4. **PowerShell missing, rclone missing, or `state.json` absent** (fresh PC, never synced) must give a readable Home message, not a crash or empty window. Pinned in Task 5 (`never`, `config-error`), Task 7 (bridge error envelopes) and Task 8 (helper failed to start).
5. **Restoring onto a file that already exists** must not overwrite it. Pinned in Task 6.

---

## File structure

| File | Responsibility |
|---|---|
| `scripts/lib/State.ps1` (modify) | `LastRunInfo` in state: load/save |
| `scripts/lib/Run.ps1` (modify) | Record each run's result and classified issues |
| `scripts/lib/Runtime.ps1` (modify) | `Invoke-Rclone` also reports `TooManyDeletes`; `Test-SyncRunning` |
| `scripts/lib/Setup.ps1` (modify) | Task times from config; `New-RecoveryKey`; crypt args with optional salt |
| `scripts/lib/Config.ps1` (modify) | Validate `SyncTime` / `SyncAtLogon` |
| `scripts/lib/InstallSteps.ps1` (new) | The side-effecting install steps, moved out of `Install.ps1`, callable non-interactively, `-WhatIf` aware |
| `scripts/Install.ps1` (modify) | Console orchestration only, calling InstallSteps |
| `scripts/lib/ConfigWriter.ps1` (new) | Raw config read, psd1 text writer, validated save, pair derivation |
| `scripts/lib/Gui.ps1` (new) | Pure functions the app needs: status situation, holding listing, restore target, size presets |
| `scripts/Invoke-GuiAction.ps1` (new) | stdin JSON → action → stdout JSON envelope |
| `scripts/lib/_load.ps1` (modify) | Dot-source the new lib files |
| `tests/*.Tests.ps1` | One test file per lib file (new: `ConfigWriter`, `Gui`, `GuiAction`, `InstallSteps`) |
| `gui/src-tauri/` (new) | Rust: window, tray, `gui_action` command, process runner, autostart, single instance |
| `gui/ui/` (new) | `index.html`, `app.css`, `app.js`: the prototype, wired to the bridge |
| `docs/README.md`, `docs/RECOVERY.md`, `docs/HANDOFF.md` (modify) | How to build/start the app; single-key restore |

## Bridge contract (shared by Tasks 7–11)

Request on stdin: `{"action": "<name>", "args": { ... }, "preview": false}`.
Response on stdout, exactly one JSON object: `{"ok": true, "data": ...}` or `{"ok": false, "error": {"code": "<code>", "message": "<plain words>"}}`.
Error codes: `config-invalid`, `config-missing`, `rclone-missing`, `auth`, `network`, `locked`, `refused`, `not-found`, `bad-request`, `internal`.

| Action | args | data |
|---|---|---|
| `status` | — | `GuiStatus` (Task 5) |
| `about` | `{refresh: bool}` | `{usedBytes, totalBytes, email, checkedAt}`; cached in `<StateDir>\gui-about.json` for 10 min unless `refresh` |
| `config.get` | — | raw config hashtable as JSON (paths unexpanded) |
| `config.save` | `{config}` | `{saved: true}` or error `config-invalid` with all messages joined |
| `folders.suggest` | — | `[{name, path, exists}]` for Pictures, Documents, Desktop, Music, Videos of the current user |
| `folders.size` | `{path, maxSeconds}` | `{bytes, complete: bool}` (stops counting at `maxSeconds`, default 20) |
| `folders.add` | `{path}` | updated pair list; error `refused` on overlap |
| `folders.remove` | `{name}` | updated pair list |
| `private.review` | `{path}` | `{path, exists, sizeGB, plainCopy: {verified, found, message}, alsoPair: name|null}` |
| `private.add` | `{path}` | saves config (removing a pair with the same Local) + confirmation hash |
| `private.remove` | `{path}` | saves config + confirmation hash |
| `sync.start` | — | `{started: true}` (`Start-ScheduledTask PikPakMirror-Sync`) |
| `sync.repair` | `{name}` | `{started: true}` (headless `Invoke-Sync.ps1 -Resync <name>`, detached) |
| `schedule.get` / `schedule.set` | `{paused?, syncTime?, syncAtLogon?}` | `{paused, syncTime, syncAtLogon, nextRun}` |
| `mount.get` / `mount.set` | `{enabled}` | `{enabled, mounted: {P: bool, Q: bool}}` |
| `mount.start` | — | `{mounted}` (runs `Start-Mount.ps1`) |
| `holding.list` | — | `[HoldingItem]` (Task 6) |
| `holding.restore` | `{item}` | `{restoredTo}` |
| `offload` | `{path}` | `{offloaded: bool, message}` |
| `key.show` | — | `{kind: "single"|"pair", key?, password?, salt?}` |
| `setup.signin` | `{email, password}` (stdin) | `{email, totalBytes, usedBytes, preset: "free"|"premium"}` |
| `setup.finish` | `{folders:[{path, private}], recoveryKey?, holding?, cache?}` | `{steps: [{name, done, message}]}` |
| `setup.newkey` | — | `{key}` (30 chars, not saved anywhere) |

`preview: true` makes every write action run with `-WhatIf`, write no config, register nothing, upload nothing, and return what it would do in `data.preview` (array of strings).

---

### Task 1: Record each run's result in state

**Files:**
- Modify: `scripts/lib/State.ps1` (`New-MirrorState`, `Get-MirrorState`)
- Modify: `scripts/lib/Runtime.ps1` (`Invoke-Rclone`; new `Test-SyncRunning`)
- Modify: `scripts/lib/Run.ps1` (`Invoke-MirrorRun`)
- Test: `tests/State.Tests.ps1`, `tests/Runtime.Tests.ps1`, `tests/Run.Tests.ps1`

**Interfaces:**
- Produces: `state.LastRunInfo = @{ Started=<iso>; Finished=<iso>; Result='ok'|'failed'|'budget-stopped'|'month-paused'; Issues=@(@{ Pair=<name|$null>; Kind=<kind>; Message=<text>; Log=<path|$null> }) }`, `$null` until the first run.
- `Kind` ∈ `config-invalid`, `private-unconfirmed`, `private-failed`, `folder-empty`, `delete-safety`, `needs-repair`, `stuck-upload`, `sentinel-failed`, `prune-failed`, `folder-missing`, `other`.
- `Invoke-Rclone` result gains `TooManyDeletes [bool]` (log contains `too many deletes`, case-insensitive).
- `Test-SyncRunning -StateDir <string> -> [bool]` ($true when `sync.lock` cannot be opened exclusively).
- `Invoke-MirrorRun` return value unchanged (`Ran`, `Skipped`, `Errors` strings) so `Invoke-Sync.ps1` and existing tests keep working.

- [ ] **Step 1: Write failing tests**

In `tests/State.Tests.ps1`:
```powershell
It 'LastRunInfo round-trips through save and load' {
    $s = New-MirrorState
    $s.LastRunInfo = @{ Started = '2026-10-25T20:00:00.0000000+07:00'; Finished = '2026-10-25T20:05:00.0000000+07:00'; Result = 'failed'
        Issues = @(@{ Pair = 'Documents'; Kind = 'folder-empty'; Message = 'm'; Log = 'C:\l.log' }) }
    Save-MirrorState -StateDir $TestDrive -State $s
    $r = Get-MirrorState -StateDir $TestDrive
    $r.LastRunInfo.Result | Should -BeExactly 'failed'
    @($r.LastRunInfo.Issues).Count | Should -Be 1
    $r.LastRunInfo.Issues[0].Kind | Should -BeExactly 'folder-empty'
    $r.LastRunInfo.Issues[0].Pair | Should -BeExactly 'Documents'
}
It 'old state.json without LastRunInfo loads with LastRunInfo = $null' { ... }
```
In `tests/Runtime.Tests.ps1`: `It 'reports TooManyDeletes when bisync aborts on too many deletes'` (log line `{"level":"error","msg":"Safety abort: too many deletes (>10%, 4 of 10) on Path1 \"D:\\x\""}` → `$r.TooManyDeletes | Should -BeTrue`); `It 'Test-SyncRunning is true while the lock is held and false after'` (hold with `Enter-MirrorLock`, assert, `Exit-MirrorLock`, assert).
In `tests/Run.Tests.ps1` (reuse the existing mocks in that Describe):
- `It 'records Result ok and no issues after a clean run'`
- `It 'records private-unconfirmed and Result failed when private paths are not confirmed'` (assert `LastRunInfo.Issues[0].Kind -eq 'private-unconfirmed'`, `Pair -eq $null`)
- `It 'records config-invalid for each config error'`
- `It 'records month-paused, not ok, when the month budget is used up'` (also `LastSuccess` unchanged)
- `It 'records budget-stopped when a pair hits the run budget and nothing failed'`
- `It 'records folder-empty / stuck-upload / needs-repair / delete-safety with the pair name and log path'` (one `It` per kind; `delete-safety` via mocked `TooManyDeletes = $true`, checked after EmptyListing and before NeedsResync)
- `It 'records prune-failed with Pair $null'`
- `It 'a locked run writes no LastRunInfo'`

- [ ] **Step 2: Run them, expect FAIL** — `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1 -Filter LastRun` (and `TooManyDeletes`, `Test-SyncRunning`). Expected: failures for the missing property / function.

- [ ] **Step 3: Implement**
  - `New-MirrorState` adds `LastRunInfo = $null`; `Get-MirrorState` converts the JSON object to a hashtable with `Issues` as an array of hashtables (empty array, never `$null`, when present).
  - `Invoke-MirrorRun`: keep `$errors` strings; add a parallel `$issues` list and a local helper `$addIssue = { param($Pair, $Kind, $Message, $Log) ... }` called next to every existing `$errors.Add(...)`; `folder-missing` is recorded for the missing pair / private folder skips (not an error today, stays not an error: it does not make Result `failed`). A new `delete-safety` branch after `EmptyListing`: message `'{0}: more than {1}% of the folder would be deleted, so nothing was synced. If you meant to delete those files, use Repair in the app.'` with `MaxDeletePercent`. In the `finally`, before `Save-MirrorState`, set `$state.LastRunInfo` (Result: `month-paused` if the step-4 budget check returned; else `failed` if any issue other than `folder-missing`; else `budget-stopped` if `$skipped` contains `budget`; else `ok`). `Finished = (Get-Date).ToString('o')`, `Started = $Now.ToString('o')`.

- [ ] **Step 4: Run full suite, expect PASS** — `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1`. Expected: all tests pass (353 + new).

- [ ] **Step 5: Commit** — `git add scripts/lib/State.ps1 scripts/lib/Runtime.ps1 scripts/lib/Run.ps1 tests/State.Tests.ps1 tests/Runtime.Tests.ps1 tests/Run.Tests.ps1` then `git commit -m "feat: record each run's result and issues in state"`.

### Task 2: Sync time and logon run from config; recovery key; optional salt

**Files:**
- Modify: `scripts/lib/Setup.ps1` (`New-MirrorTaskSpec`, `New-CryptRemoteArgs`; new `New-RecoveryKey`, `ConvertTo-RecoveryKey`)
- Modify: `scripts/lib/Config.ps1` (`Test-MirrorConfig`)
- Modify: `config/mirror.config.psd1` (add `SyncTime = '20:00'`, `SyncAtLogon = $true` with a comment)
- Test: `tests/Setup.Tests.ps1`, `tests/Config.Tests.ps1`

**Interfaces:**
- `New-MirrorTaskSpec ... [-SyncTime <string> = '20:00'] [-SyncAtLogon <bool> = $true]`: Sync triggers are `@(AtLogOn PT15M)` only when `SyncAtLogon`, then `Daily At=SyncTime`. Mount unchanged.
- `New-RecoveryKey -> [string]`: 30 chars from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (no 0, O, 1, I, L), `RNGCryptoServiceProvider` with rejection sampling (as `New-CryptSecret`).
- `ConvertTo-RecoveryKey -Text <string> -> [string]`: upper-cases, removes spaces and `-`; returns `$null` unless the result is 30 chars from that alphabet.
- `New-CryptRemoteArgs -Salt` becomes optional (`[AllowEmptyString()]`, default `''`); when empty, `password2` is omitted from the arguments entirely.
- `Test-MirrorConfig`: `SyncTime`, if present, must match `^([01]\d|2[0-3]):[0-5]\d$`; `SyncAtLogon`, if present, must be `[bool]`.

- [ ] **Step 1: Write failing tests** — in `tests/Setup.Tests.ps1`:
  - `It 'Sync uses -SyncTime for the daily trigger'` (`-SyncTime '22:30'` → Daily At `'22:30'`)
  - `It 'Sync has only the daily trigger when -SyncAtLogon $false'` (`@($t.Triggers).Count | Should -Be 1`)
  - `It 'New-RecoveryKey is 30 chars from the no-look-alike alphabet'` (`-cmatch '^[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{30}$'`, two calls differ)
  - `It 'ConvertTo-RecoveryKey accepts grouped lower-case input and rejects bad characters'` (`'7hqx2 mpd4t-w9kzr c3vne 6bjya fu8ls'` → `'7HQX2MPD4TW9KZRC3VNE6BJYAFU8LS'`; a key containing `O` → `$null`; 29 chars → `$null`)
  - `It 'New-CryptRemoteArgs omits password2 when the salt is empty'` (`$a -notcontains 'password2'`) and the existing salt test still passes.
  In `tests/Config.Tests.ps1`: `It 'rejects SyncTime 24:00 and 8pm'`, `It 'accepts SyncTime 07:05 and no SyncTime at all'`, `It 'rejects SyncAtLogon = "yes"'`.
- [ ] **Step 2: Run, expect FAIL** — `tests\run.ps1 -Filter Sync` / `-Filter Recovery`.
- [ ] **Step 3: Implement** as in Interfaces. Existing default test (`AtLogOn +15 min and daily 20:00`) must still pass unchanged.
- [ ] **Step 4: Run full suite, expect PASS.**
- [ ] **Step 5: Commit** — `feat: configurable sync time, recovery key, optional crypt salt`.

### Task 3: Install steps as reusable, non-interactive functions

**Files:**
- Create: `scripts/lib/InstallSteps.ps1`; add to `scripts/lib/_load.ps1`
- Modify: `scripts/Install.ps1` (calls the new functions; keeps all prompts, output and exit codes as today)
- Test: `tests/InstallSteps.Tests.ps1`

**Interfaces** (all `[CmdletBinding(SupportsShouldProcess)]`, return `[pscustomobject]@{ Name; Done [bool]; Skipped [bool]; Message [string] }`, throw on failure with a plain message; under `-WhatIf` they change nothing and return `Message` = what they would do):
- `Install-MirrorRclone` (the pinned download + SHA256 + PATH, moved from Install.ps1 step 1)
- `Install-MirrorWinFsp` (winget, moved)
- `New-MirrorPikPakRemote -Name <string> -Email <string> -Password <string>` (create + `rclone about` verify + delete on failure; error message starts with `PikPak didn't accept` when `about` fails with an auth error, else `Couldn't reach PikPak`)
- `New-MirrorPrivateRemote -Name <string> -BaseRemote <string> -Password <string> [-Salt <string> = ''] -Mode New|Existing` (New: refuses when `<base>:PC-Private` has entries; Existing: refuses when data exists but nothing decrypts)
- `Register-MirrorTasks -Config <hashtable> -ConfigPath <string> -RepoRoot <string> [-EnableSchedule]` (uses `SyncTime`/`SyncAtLogon` from config; the "same task" check compares trigger types **and** times, so a changed time re-registers)
- `Register-MirrorOffloadMenu -RepoRoot <string> -ConfigPath <string>`
- `New-MirrorLocalFolders -Config <hashtable>`
- Move `Invoke-RcloneCaptured`, `Get-RemoteEntryCount`, `Test-RcloneInstalled`, `Test-WinFspInstalled`, `Update-SessionPath`, `Install-MirrorTask` from `Install.ps1` into this file unchanged.

- [ ] **Step 1: Write failing tests** (Pester `Mock` for `Invoke-RcloneCaptured`, `Get-ScheduledTask`, `Register-ScheduledTask`, `Disable-ScheduledTask`, `Enable-ScheduledTask`; nothing real is called):
  - `It 'New-MirrorPikPakRemote deletes the remote and says PikPak did not accept it when about fails with 401'`
  - `It 'New-MirrorPrivateRemote -Mode New refuses when PC-Private already has entries'`
  - `It 'New-MirrorPrivateRemote passes no password2 when Salt is empty'` (inspect mocked args)
  - `It 'Register-MirrorTasks re-registers the sync task when SyncTime changed'`
  - `It 'every step under -WhatIf calls no rclone/registry/scheduler mutation and returns a Message'`
- [ ] **Step 2: Run, expect FAIL** — `tests\run.ps1 -Filter InstallSteps`.
- [ ] **Step 3: Implement** by moving code out of `Install.ps1`; `Install.ps1` keeps the console prompts (`Read-Host`, a/b choice, `SAVED`) and passes the answers into these functions. Option a) in the console accepts an empty salt (press Enter twice) for single-key setups.
- [ ] **Step 4: Run full suite, expect PASS**, then `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1 -WhatIf` on this PC. Expected: same steps as before, every step `[skip]` (already installed), exit 0.
- [ ] **Step 5: Commit** — `refactor: install steps as reusable functions for the app`.

### Task 4: Config writer and folder-to-pair derivation

**Files:**
- Create: `scripts/lib/ConfigWriter.ps1`; add to `_load.ps1`
- Test: `tests/ConfigWriter.Tests.ps1`

**Interfaces:**
- `Get-RawMirrorConfig -Path <string> -> [hashtable]` (`Import-PowerShellDataFile`, no path expansion).
- `ConvertTo-MirrorConfigText -Config <hashtable> -> [string]`: psd1 text. Fixed key order: `Remote, PrivateRemote, MirrorRoot, HoldingRoot, ArchiveRoot, LocalHolding, CacheDir, StateDir, GlobalFiltersFile, HoldingDays, MaxDeletePercent, RunBudgetGB, MonthlyBudgetGB, QuotaWarnPercent, StaleRunDays, LogKeepDays, BwLimit, SyncTime, SyncAtLogon, WatchRoots, IgnoredFolders, PrivatePaths, Pairs`, then any other keys alphabetically. Strings single-quoted with `'` doubled; `[bool]` as `$true`/`$false`; ints bare; arrays as `@( ... )` one item per line; hashtables as `@{ K = V; ... }` on one line (pairs keep `Name; Local; Remote; Priority` order). Header comment: `# Managed by the PikPak Backup app. You can still edit it by hand; the app keeps the previous version as mirror.config.psd1.bak.` Non-ASCII characters are written as-is and the file is saved UTF-8 **with** BOM (PS 5.1 `Import-PowerShellDataFile` reads BOM-less files as ANSI).
- `Save-MirrorConfig -Path <string> -Config <hashtable> -> [string[]]` (validation errors; empty = saved). Writes to `<Path>.tmp`, loads it with `Get-MirrorConfig` + `Test-MirrorConfig`; on errors deletes the tmp and returns them; else copies `<Path>` to `mirror.config.original.psd1` if that does not exist yet, copies `<Path>` to `<Path>.bak`, moves tmp over `<Path>`.
- `New-MirrorPair -Path <string> -Config <hashtable> -> [hashtable]`: `Name` = folder leaf, made unique by appending ` (2)`, ` (3)`… against existing pair names (case-insensitive); `Remote` = `C-Users/<rest>` when the path is under `$env:USERPROFILE`'s parent `C:\Users\<me>\` (i.e. `C:\Users\Alex\Pictures` → `C-Users/Pictures`), else `<DriveLetter>/<rest with / separators>` (`D:\Holiday Photos` → `D/Holiday Photos`); `Priority` = 3.

- [ ] **Step 1: Write failing tests:**
  - `It 'round-trips the shipped config: text -> file -> Get-RawMirrorConfig equals the input'` (load `config\mirror.config.psd1` raw, write to `$TestDrive`, reload, compare every key incl. pair hashtables)
  - `It 'keeps apostrophes, spaces and non-ASCII names'` (pair `Local = "D:\Nh$([char]0x1EA1)c"`, `Name = "O'Brien's music"` survive the round trip)
  - `It 'Save-MirrorConfig refuses an overlapping pair and leaves the file untouched'` (add pair `D:\Music\Live` next to `D:\Music`; returns the overlap message; file hash unchanged; no `.bak` written)
  - `It 'Save-MirrorConfig keeps .bak and writes .original only once'`
  - `It 'New-MirrorPair derives C-Users and drive remotes and unique names'` (`C:\Users\<me>\Pictures` → `C-Users/Pictures`; `D:\Holiday Photos` → `D/Holiday Photos`; a second `Music` → `Music (2)`)
- [ ] **Step 2: Run, expect FAIL** — `tests\run.ps1 -Filter ConfigWriter`.
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run full suite, expect PASS.**
- [ ] **Step 5: Commit** — `feat: config writer for the desktop app`.

### Task 5: Home status from config, state and live facts

**Files:**
- Create: `scripts/lib/Gui.ps1`; add to `_load.ps1`
- Test: `tests/Gui.Tests.ps1`

**Interfaces:**
- `Get-GuiStatus -Config <hashtable> -State <object> -Now <datetime> -Facts <hashtable> -> GuiStatus`. Pure. `Facts` = `@{ SyncRunning=[bool]; TaskEnabled=[bool]; NextRun=<iso|$null>; About=@{ UsedBytes; TotalBytes; Error=$null|'auth'|'network' }; ConfigErrors=[string[]] }`.
- `GuiStatus` = `@{ Situation; Tone ('ok'|'warn'|'bad'); Title; Detail; Folders=@(@{ Name; Local; Private=[bool]; Pill; PillTone ('ok'|'wait'|'warn'|'bad'); Issue=$null|<message> }); LastSuccess; NextRun; Month=@{ UsedGB; BudgetGB }; Space=@{ UsedBytes; TotalBytes }; Unmapped=[string[]] }`.
- Situations, first match wins: `config-error` (bad) → `paused` (TaskEnabled false; warn; "Backups are paused") → `running` (ok; "Backing up now…") → `signed-out` (About.Error auth; bad; "PikPak signed you out") → `month-paused` (LastRunInfo.Result month-paused or month UsedGB ≥ BudgetGB; warn; "Backups are paused until 1 <Month>") → `attention` (LastRunInfo.Result failed; bad; title names the first issue's folder, detail is that issue's message) → `never` (no LastRunInfo and no LastSuccess; ok; "Your first backup hasn't run yet") → `first` (any pair not Seeded; ok; "Your first backup is on its way") → `stale` (`Test-StaleSuccess`; warn; "No backup for <n> days") → `ok` ("Your files are backed up"; detail "Last backup: <today at HH:mm|yesterday at HH:mm|d MMM at HH:mm>. Next backup: <same format>.").
- Folder pills: issue for that pair in LastRunInfo → `Needs attention` (bad, `Issue` = message); not Seeded → `Part-way` (wait); running → `Backing up` (wait); else `Up to date` (ok).
- `Get-BudgetPreset -TotalBytes <long> -> @{ Name='free'|'premium'; RunBudgetGB; MonthlyBudgetGB }`: `TotalBytes` ≤ 10 GiB → `free`, 1, 30; else `premium`, 8, 230. Test: `It 'picks free at 6 GiB and at exactly 10 GiB, premium above'`.

- [ ] **Step 1: Write failing tests** — one `It` per situation, each with the smallest config/state/facts that triggers it, asserting `Situation`, `Tone` and `Title`; plus:
  - `It 'a failed run with no pair issues is attention, not ok, even with a recent LastSuccess'` (Review Focus 1: `LastRunInfo = @{ Result='failed'; Issues=@(@{ Pair=$null; Kind='private-unconfirmed'; Message='x' }) }`, `LastSuccess` 1 hour ago)
  - `It 'paused wins over running and attention'`
  - `It 'month-paused names the next month in the title'` (`Now` 2026-10-25 → `'Backups are paused until 1 November'`)
  - `It 'folder pill shows the pair issue message'`
  - `It 'never: no state.json at all gives a readable title'`
- [ ] **Step 2: Run, expect FAIL** — `tests\run.ps1 -Filter Get-GuiStatus`.
- [ ] **Step 3: Implement.** Copy strings for titles/details come from the prototype's `states` object where they exist.
- [ ] **Step 4: Run full suite, expect PASS.**
- [ ] **Step 5: Commit** — `feat: home status for the desktop app`.

### Task 6: Deleted-file listing and restore targets

**Files:**
- Modify: `scripts/lib/Gui.ps1`; Test: `tests/Gui.Tests.ps1`

**Interfaces:**
- `HoldingItem` = `@{ Source ('pc'|'cloud'); Date ('yyyy-MM-dd'); Pair; RelPath; Name; Size; HoldingPath; RestoreTo }`.
- `ConvertTo-HoldingItems -Config <hashtable> -Source pc|cloud -Entries <object[]> -> HoldingItem[]` (pure). `Entries` = `@{ Path='<yyyy-MM-dd>/<pair>/<rel>'; Size; IsDir }` (pc: built from `Get-ChildItem -Recurse -File` under `LocalHolding`; cloud: `rclone lsjson -R --files-only <remote>:<HoldingRoot>` objects). Skips dirs, entries whose date folder doesn't parse, `_archive`, and pairs no longer in config. `RestoreTo` = `<pair Local>\<rel with \>`. Sorted newest date first, then name.
- `Get-RestoreTarget -Path <string> -Exists <scriptblock> -> [string]`: the path itself if `& $Exists $path` is false; else `<dir>\<base> (restored)<ext>`, then `(restored 2)`, … (Review Focus 5).

- [ ] **Step 1: Write failing tests:** `It 'maps pc and cloud entries to items with RestoreTo under the pair'`, `It 'skips _archive, unknown pairs and folders'`, `It 'sorts newest first'`, `It 'Get-RestoreTarget never returns an existing path'` (exists for `a.txt` and `a (restored).txt` → `a (restored 2).txt`), `It 'Get-RestoreTarget handles names without extension and dotfiles'`.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4: Full suite PASS.**
- [ ] **Step 5: Commit** — `feat: deleted-file listing for the desktop app`.

### Task 7: Bridge script (`Invoke-GuiAction.ps1`)

**Files:**
- Create: `scripts/Invoke-GuiAction.ps1`
- Modify: `scripts/lib/Gui.ps1` (add `Invoke-GuiRequest`)
- Test: `tests/GuiAction.Tests.ps1`

**Interfaces:**
- `Invoke-GuiRequest -Request <pscustomobject> -ConfigPath <string> -> [hashtable]` returns the envelope (see *Bridge contract*). One `switch` over `action`; each action is a small function `Invoke-GuiAction<Name>` in `Gui.ps1` built on Tasks 1–6 and existing libs (`Get-MirrorStatus`, `Get-PrivatePathReport`, `Get-PlainCopyCheckResult`, `Save-PrivateConfirmation`, `Invoke-Offload`, `Get-ArchiveTarget`, `Start-ScheduledTask`, `Enable/Disable-ScheduledTask`, `Get-ScheduledTaskInfo`, InstallSteps).
- `Invoke-GuiAction.ps1 [-ConfigPath]`: reads all of stdin (`[Console]::In.ReadToEnd()`), `ConvertFrom-Json`, calls `Invoke-GuiRequest`, writes `ConvertTo-Json -Depth 8 -Compress` to stdout as UTF-8, exit 0 even on a handled error. An unhandled exception → `{ok:false, error:{code:'internal', message:'Something went wrong in PikPak Backup. Details are in the log.'}}` and the exception text goes to `Write-MirrorLog` when the config loads. Nothing else is ever written to stdout (all `Write-Host` in called scripts is captured/suppressed).
- `key.show`: `rclone config dump` → the `PrivateRemote` entry's `password` and `password2` → `rclone reveal` each. `password2` empty → `kind: single`, `key` grouped in 5s; else `kind: pair`.
- `about`: follows one level of `alias` remotes to find `user` (this PC: `pikpak` is an alias of `Pikpak remote:`); `auth` when rclone output matches `401|unauthori|invalid_grant|captcha`, else `network`.
- `setup.*` and other writes honour `preview` (pass `-WhatIf`, skip `Save-MirrorConfig`, collect messages).
- `folders.suggest` uses `[Environment]::GetFolderPath('MyPictures'|'MyDocuments'|'Desktop'|'MyMusic'|'MyVideos')`.
- `setup.signin` first runs `Install-MirrorRclone` and `Install-MirrorWinFsp` when missing, then `New-MirrorPikPakRemote`, then `rclone about --json` and `Get-BudgetPreset`. `setup.finish` writes a new config from the shipped defaults (`Remote 'pikpak'`, `PrivateRemote 'private'`, roots, `LocalHolding`/`CacheDir` from args or `<drive with most free space>:\.pikpak-holding` / `.pikpak-cache`, `StateDir '%LOCALAPPDATA%\PikPakMirror'`, `WatchRoots` = that drive's root, the preset budgets, one pair per chosen non-private folder via `New-MirrorPair`, one `PrivatePaths` entry per private folder), then `New-MirrorPrivateRemote -Mode New` (only when a recovery key is given), `Register-MirrorTasks -EnableSchedule`, `Register-MirrorOffloadMenu`, `New-MirrorLocalFolders`, `Save-PrivateConfirmation`, `Start-Mount.ps1`. A failing step stops the rest and is reported with what was already done.

- [ ] **Step 1: Write failing tests** (mock the libs, not rclone): `It 'unknown action -> bad-request envelope'`, `It 'missing config -> config-missing envelope with a plain message'`, `It 'status returns Get-GuiStatus output in data'`, `It 'config.save returns config-invalid with the validator messages'`, `It 'folders.add refuses an overlapping folder with code refused'` (Review Focus 3), `It 'private.add removes a pair with the same Local and saves the confirmation'`, `It 'setup.finish with preview writes nothing'` (assert `Save-MirrorConfig`, `Register-MirrorTasks` called with `-WhatIf` / not called), `It 'key.show returns single when password2 is empty'`, `It 'about maps a 401 to auth'`, `It 'script writes exactly one JSON object to stdout'` (run `Invoke-GuiAction.ps1` in a child `powershell.exe` with `{"action":"nope"}` piped in; parse stdout).
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4: Full suite PASS**, then a manual smoke on this PC: `'{"action":"status"}' | powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-GuiAction.ps1` → `ok: true` with the real situation.
- [ ] **Step 5: Commit** — `feat: JSON bridge for the desktop app`.

### Task 8: Tauri shell

**Files:**
- Create: `gui/src-tauri/Cargo.toml`, `gui/src-tauri/tauri.conf.json`, `gui/src-tauri/build.rs`, `gui/src-tauri/capabilities/default.json`, `gui/src-tauri/src/main.rs`, `gui/src-tauri/src/bridge.rs`, `gui/src-tauri/src/tray.rs`, `gui/src-tauri/icons/*`, `gui/ui/index.html` (placeholder "Loading…")
- Modify: `.gitignore` (`gui/src-tauri/target/`)

**Interfaces:**
- Prerequisite check (first step): `rustc --version`, `cargo --version`, and `link.exe` reachable (VS Build Tools C++ workload). If missing, stop and report; do not install anything.
- Tauri command `gui_action(action: String, args: serde_json::Value, preview: bool) -> Result<serde_json::Value, String>`: async; runs `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <repo>\scripts\Invoke-GuiAction.ps1` with `CREATE_NO_WINDOW` (0x08000000), writes the request JSON to stdin, closes stdin, reads stdout, parses one JSON object and returns it as-is (the page reads `ok`). Non-JSON stdout or non-zero exit → `Err("internal: ...")` and the raw text is logged to `<StateDir>\logs\gui.log` (never shown).
- Command `app_info() -> { preview_setup: bool, repo_root: String, version: String, pc_name: String }` (`--preview-setup` CLI flag; `pc_name` from `COMPUTERNAME`).
- `bridge::find_repo_root(start: &Path) -> Option<PathBuf>`: walks up from the exe's folder to the first folder containing `scripts\Invoke-GuiAction.ps1`; overridable by env `PIKPAK_BACKUP_REPO`.
- Window: 1100×720, min 860×600, title `PikPak Backup`, remembers size/position (`tauri-plugin-window-state`). Close button hides to tray. `tauri-plugin-single-instance` focuses the existing window.
- Tray (`tray.rs`): menu *Open*, *Back up now* (`sync.start`), *Pause backups*/*Resume backups* (`schedule.set`), *Quit*. Command `set_tray_status(tone: String, tooltip: String)` swaps between three icons (`tray-ok.ico`, `tray-working.ico`, `tray-attention.ico`).
- Plugins: `tauri-plugin-dialog`, `tauri-plugin-fs` (write scope limited to paths the user picked in a save dialog), `tauri-plugin-opener` (open folders and `P:`), `tauri-plugin-autostart` (args `--minimized`), `tauri-plugin-single-instance`, `tauri-plugin-window-state`.

- [ ] **Step 1: Write failing Rust unit tests** in `bridge.rs`: `find_repo_root_walks_up`, `request_json_has_action_args_preview`, `parse_envelope_rejects_non_json`, `parse_envelope_takes_last_line_when_noise_precedes` (defensive).
- [ ] **Step 2: Run** `cargo test --manifest-path gui/src-tauri/Cargo.toml` — expect FAIL (functions missing).
- [ ] **Step 3: Implement** the shell per Interfaces.
- [ ] **Step 4: Verify** — `cargo test` PASS; `cargo tauri dev` (run from `gui/`) opens the window showing "Loading…"; tray icon shows; closing hides; second launch focuses the first.
- [ ] **Step 5: Commit** — `feat: Tauri shell for the desktop app`.

### Task 9: Home, deleted files and free-up-space screens

**Files:**
- Create: `gui/ui/index.html`, `gui/ui/app.css`, `gui/ui/app.js`, `gui/ui/bridge.js`
- Source to port: `docs/superpowers/specs/2026-10-25-desktop-app-prototype.html` (drop the prototype panel, feedback mode and fake data)

**Interfaces:**
- `bridge.js`: `export async function call(action, args = {}, {preview} = {})` → resolves `data` on `ok`, rejects with `{code, message}` otherwise; a failed `invoke` becomes `{code:'internal', message:'PikPak Backup couldn't start its helper. Try again; if it keeps happening, restart the app.'}`.
- Start-up: `app_info` → `config.get`; `config-missing` → setup (Task 10); else Home.
- Home renders `status` (Task 5 `GuiStatus`): status block (tone class), folder list with pills and per-folder menu (*Open folder* via `opener`, *Remove from backup* with a confirm, *Repair* only when the pill is `Needs attention`, showing the README "A folder keeps failing" explanation before running `sync.repair`), space panel (`about`), month panel, unmapped folders line with *Add*, shortcuts. Polls `status` every 10 s while a run is going, else every 60 s and on window focus. Calls `set_tray_status` after each poll.
- *Back up now* → `sync.start`; *Add a folder* → folder dialog → `folders.add` (error `refused` shows its message inline under the list).
- *Open my backup in File Explorer* → `mount.get`; if `P:` mounted open `P:\` else `mount.start` then open.
- Deleted files: `holding.list`, client-side search, *Restore* → `holding.restore` → pill `Back in <folder>`; footer line: "Private files and Archive: use drive Q: or P:\Archive in File Explorer."
- Free up space: *Choose files to move…* (multi file dialog) and *Choose a folder to move…* → one `offload` call per item, results listed.

- [ ] **Step 1: Verify the start-up path manually** — `cargo tauri dev`: Home shows this PC's real situation (compare with `Get-Status.ps1`).
- [ ] **Step 2: Live checks (≤1 MB files):** add `D:\pikpak-gui-test` (one 1 KB file) with the picker → appears in the list; *Back up now* → *Backing up now…* then pill `Up to date`; delete the 1 KB file, *Back up now*, it appears in Deleted files (`cloud`), *Restore* brings it back; *Free up space* on a 1 KB file → `Archive` in PikPak; *Remove from backup* for the test folder.
- [ ] **Step 3: Commit** — `feat: home, restore and offload screens`.

### Task 10: Setup flow and preview mode

**Files:**
- Modify: `gui/ui/index.html`, `gui/ui/app.js`, `gui/ui/app.css`

**Interfaces:**
- Screens from the prototype: Welcome → Sign in (`setup.signin`; while waiting: "Checking your PikPak account…"; `auth` → "PikPak didn't accept that email and password."; `network` → "Couldn't reach PikPak. Check your internet connection and try again.") → Choose folders (`folders.suggest` + `folders.size` per row, "Measuring…" until done, `complete:false` shows "more than <n> GB"; free space = `totalBytes − usedBytes`; *Add another folder* = folder dialog; *Continue* disabled when over) → Recovery key (only if any Private; key from `setup.newkey`; Save to a file = save dialog (default name `PikPak recovery key.txt`), then the page writes it with `tauri-plugin-fs` `writeTextFile`: the key in groups of five, the date, the PC name (`app_info`), and three lines on restoring (install, sign in, enter this key when asked for the encryption password and leave the salt empty); Print = `window.print()` of a print-only key sheet; Copy = clipboard; *Continue* enabled by the tick box) → Done (`setup.finish`, each returned step listed with a tick or the error; "takes about N evenings" from the preset: N = ceil(chosenGB / RunBudgetGB)) → *Start my first backup* (`sync.start`) → Home.
- Preview mode (`app_info().preview_setup`): a banner "Preview: nothing will be installed, saved or uploaded"; every `call` passes `preview: true`; `setup.signin` in preview skips rclone and returns `{preset:'free', totalBytes: 6 GiB, usedBytes: 0}`; Done lists `data.preview` lines.

- [ ] **Step 1: Verify** `cargo tauri dev -- -- --preview-setup` walks all screens on this PC; afterwards `git status` shows no change to `config\`, `rclone listremotes` unchanged, `Get-ScheduledTask PikPakMirror-*` unchanged.
- [ ] **Step 2: Commit** — `feat: first-time setup screens with preview mode`.

### Task 11: Settings and tray behaviour

**Files:**
- Modify: `gui/ui/*`; `gui/src-tauri/src/main.rs` (autostart toggle commands if the plugin's JS API isn't used)

**Interfaces:**
- Sections as in the prototype and spec: Pause backups (`schedule.set {paused}`); When to back up (time select 18:00–02:00 in 30-min steps + logon checkbox → `schedule.set`); Go easy on my internet (on = `BwLimit '18:00,2M:off 23:00,off'` or the Advanced hours; off = `BwLimit ''`; via `config.save`); Private folders (list, *Add private folder* → folder dialog → `private.review` → confirm dialog showing size, "a plain copy is already on PikPak" warning when `found`, and "will be removed from the normal backup" when `alsoPair` → `private.add`; *Remove* → `private.remove`); Recovery key (`key.show`: `single` → key tag; `pair` → two tags labelled Password and Salt; Copy/Save/Print as in setup); File Explorer drives (`mount.set`); PikPak account (email + size from `about`); Advanced, collapsed (RunBudgetGB, MonthlyBudgetGB, HoldingDays, MaxDeletePercent, evening hours, LocalHolding and CacheDir each with *Browse…* folder dialog) with one *Save changes* button → `config.save`, errors shown inline; Start with Windows (autostart plugin).
- Removing the last folder is refused in the UI ("Keep at least one folder, or pause backups instead.").

- [ ] **Step 1: Verify on this PC:** change backup time to 22:00 → `Get-ScheduledTask PikPakMirror-Sync` shows Daily 22:00, then set back to 20:00; pause/resume shows Disabled/Ready; *Show recovery key* shows the existing Password and Salt (compare with the saved ones; do not paste them anywhere); Advanced: Browse a new cache folder, save, `config\mirror.config.psd1` has it and `.bak` + `.original` exist, then set it back; tray menu *Pause backups* flips the Settings switch.
- [ ] **Step 2: Commit** — `feat: settings screen and tray actions`.

### Task 12: Docs and hand-off

**Files:** `docs/README.md` (new first section "The app": build with `cargo tauri build` in `gui/`, start from the Start-menu shortcut the installer bundle creates or `gui\src-tauri\target\release\pikpak-backup.exe`, `--preview-setup`), `docs/RECOVERY.md` (single-key restore: console option a), key as password, Enter twice for the salt), `docs/HANDOFF.md` (app status, what's not built: delete-choice buttons, private restore, R2), `docs/OPEN-REQUIREMENTS.md` (add the app's not-built items).

- [ ] **Step 1: Write the docs.**
- [ ] **Step 2: Full suite PASS and `cargo test` PASS.**
- [ ] **Step 3: Commit** — `docs: desktop app`.
