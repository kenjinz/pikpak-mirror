# PikPak Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unattended evening two-way sync of the user's media folders with PikPak (plain), an encrypted one-way backup of their private folders, a cloud-only Archive for offloading, and `P:`/`Q:` drives to browse PikPak without local copies.

**Architecture:** Thin PowerShell 5.1 scripts drive the `rclone` CLI. All decisions (which pairs, which flags, budget, gating) live in pure functions under `scripts/lib/` that build rclone argument arrays and are unit-tested with Pester. A single wrapper `Invoke-Rclone` is the only place that runs rclone, so orchestration tests mock it. Windows Task Scheduler runs `Invoke-Sync.ps1` and `Start-Mount.ps1`.

**Tech Stack:** Windows PowerShell 5.1, rclone v1.75.2 (`pikpak`, `crypt` backends, `bisync`, `mount`), WinFsp, Pester 5.7.1, Windows Task Scheduler, WinRT toast notifications.

**Spec:** `docs/superpowers/specs/2026-10-24-pikpak-mirror-design.md`

## Global Constraints

- Every script runs on **Windows PowerShell 5.1**: no `?:`, `??`, `?.`, `&&`/`||`, `-AsHashtable`, or pwsh-only cmdlets.
- rclone pinned to **v1.75.2** (`winget install --id Rclone.Rclone --version 1.75.2 -e`). Pester pinned to **5.7.1** (CurrentUser scope).
- Comparison is **size + modtime** (`--compare size,modtime`). Never use `--checksum` or hash compare (PikPak returns no MD5, rclone #9826).
- Remote names: `pikpak` (type pikpak), `private` (type crypt over `pikpak:PC-Private`). Remote roots: `PC-Mirror`, `PC-Holding`, `Archive`, `PC-Private`. Private holding: `private:_holding`.
- Local holding `D:\.pikpak-holding`; VFS cache `D:\.pikpak-cache`; state dir `%LOCALAPPDATA%\PikPakMirror`.
- Holding retention **30 days**; bisync `--max-delete 10` (percent); per-run transfer budget **8 GB**; monthly budget **250 GB**; quota warning at **90%**; stale-success warning after **3 days**; logs kept **60 days**.
- Mount: `P:` = `pikpak:` read-write; `Q:` = `private:` `--read-only` *(plan's call: two letters instead of one combined `P:` so the private view can be read-only)*; `--vfs-cache-mode full --vfs-cache-max-size 20G --vfs-cache-max-age 24h`.
- Tasks: `PikPakMirror-Sync` (at logon +15 min, daily 20:00, StartWhenAvailable, IgnoreNew); `PikPakMirror-Mount` (at logon).
- No secrets in the repo. rclone.conf stays at `%APPDATA%\rclone\rclone.conf`.
- Private-path confirmation is stored as a **hash in state** (not a config flag): changing `PrivatePaths` re-blocks plain pairs until `Confirm-PrivatePaths.ps1` is run again *(plan's call; stricter than the spec's config flag)*.
- Bytes counted against the budget are all bytes rclone reports transferred in a run, both directions *(plan's call; conservative)*.
- Every entry script (`Invoke-Sync`, `Move-ToArchive`, `Confirm-PrivatePaths`, `Get-Status`, `Start-Mount`, `Install`) takes `[-ConfigPath <string>]` defaulting to `<repo>\config\mirror.config.psd1`, and dot-sources `scripts/lib/_load.ps1`.

## Review Focus

1. **Offloading a large part of one folder** (e.g. half of `D:\Film`) looks like >10% deletes to bisync. The user expects the offload to just work → `Move-ToArchive` re-syncs that pair with `--force` under the lock (Task 7 test `runs a forced bisync on the owning pair`).
2. **Private paths changed after seeding.** The user expects the newly private folder never to be uploaded plain again → plain pairs blocked until reconfirmed. Then the changed filter triggers `--resync` and a toast tells the user to delete the old plain copy (Task 6 test `filter change forces resync and warns`).
3. **Folder names with spaces, parentheses, brackets, Vietnamese characters** (`New folder (3)`, `Nhạc`, `[2024] trip`) in filter rules and args → filter globs escaped, paths without trailing backslash (Task 2 tests `escapes glob metacharacters`, `keeps unicode`).
4. **A pair's local folder is missing** (drive not mounted, folder renamed) → that pair is skipped with a toast, never synced as "everything deleted" (Task 6 test `skips pair whose local folder is missing`).
5. **New top-level folder created on D: after setup** → the user expects it backed up, so they get a toast naming the unmapped folder, once per folder (Task 6 test `toasts once for unmapped top-level folder`).

---

## File Structure

```
.gitignore                         # logs/, *.local.psd1, .pikpak-* 
config/mirror.config.psd1          # all settings + pairs + private paths (hand-edited)
config/filters.txt                 # global rclone filter rules
scripts/lib/Config.ps1             # Get-MirrorConfig, Test-MirrorConfig, Get-PrivatePathsHash
scripts/lib/Filters.ps1            # ConvertTo-RcloneFilterPath, New-PairFilterRules, Get-TextHash
scripts/lib/RcloneArgs.ps1         # New-BisyncArgs, New-PrivateSyncArgs, New-PruneArgs, New-MountArgs, New-ArchiveMoveArgs
scripts/lib/State.ps1              # Get/Save-MirrorState, Add-TransferredBytes, Get-RunBudget, Test-StaleSuccess
scripts/lib/Runtime.ps1            # Invoke-Rclone, Get-TransferredBytesFromLog, Send-MirrorToast, Write-MirrorLog, Enter/Exit-MirrorLock
scripts/lib/Run.ps1                # Invoke-MirrorRun (orchestration), Find-UnmappedFolders
scripts/lib/Archive.ps1            # Get-ArchiveTarget, Invoke-Offload
scripts/Invoke-Sync.ps1            # entry: load config, Invoke-MirrorRun
scripts/Move-ToArchive.ps1         # entry: Invoke-Offload -Path
scripts/Confirm-PrivatePaths.ps1   # shows private paths, records hash on "YES"
scripts/Get-Status.ps1             # human/Claude-readable status
scripts/Start-Mount.ps1            # P: and Q: mounts
scripts/Install.ps1                # deps, remotes, tasks, context menu; -Role Master|Viewer
tests/run.ps1                      # imports Pester 5.7.1, runs tests/
tests/*.Tests.ps1                  # one per lib file
docs/README.md, docs/RECOVERY.md
.mcp.json                          # PikPak MCP (Task 10)
```

All lib files are dot-sourced by `scripts/lib/_load.ps1` (one line per file), which entry scripts and tests dot-source.

---

### Task 1: Repo scaffold, Pester, config loading and validation

**Files:**
- Create: `.gitignore`, `config/mirror.config.psd1`, `config/filters.txt`, `scripts/lib/_load.ps1`, `scripts/lib/Config.ps1`, `tests/run.ps1`, `tests/Config.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-MirrorConfig -Path <string> -> hashtable`. Keys are listed below. `%VAR%` in path values is expanded, and trailing `\` is stripped from every path except drive roots like `D:\`.
  - `Test-MirrorConfig -Config <hashtable> -> string[]` (empty = valid)
  - `Get-PrivatePathsHash -Config <hashtable> -> string` (SHA256 hex of sorted lower-cased `Path` values)

Config keys (psd1, `Import-PowerShellDataFile`-safe literals only):
```powershell
@{
  Remote='pikpak'; PrivateRemote='private'; MirrorRoot='PC-Mirror'; HoldingRoot='PC-Holding'; ArchiveRoot='Archive'
  LocalHolding='D:\.pikpak-holding'; CacheDir='D:\.pikpak-cache'; StateDir='%LOCALAPPDATA%\PikPakMirror'
  HoldingDays=30; MaxDeletePercent=10; RunBudgetGB=8; MonthlyBudgetGB=250; QuotaWarnPercent=90; StaleRunDays=3; LogKeepDays=60
  BwLimit='18:00,2M:off 23:00,off'
  WatchRoots=@('D:\'); IgnoredFolders=@('Game','One drive','msdownld.tmp','OneDriveTemp','.pikpak-holding','.pikpak-cache','.__capcut_export_temp_folder_*')
  PrivatePaths=@()          # @{ Path='D:\...'; Name='...' } entries, filled by the user before seeding
  Pairs=@( @{ Name='Holiday Photos'; Local='D:\Holiday Photos'; Remote='D/Holiday Photos'; Priority=1 } , ... )
}
```
Initial `Pairs` (Name = folder name; Remote = `D/<name>` or `C-Users/<name>`):
- Priority 1: `Holiday Photos`, `C:\Users\Alex\Pictures`
- Priority 2: `Music`, `Songs`, `Soundtracks`, `Lessons`, `C:\Users\Alex\Music`
- Priority 3: `C:\Users\Alex\Documents`, `Work`, `Misc`, `Trip 2024`
- Priority 4: `New folder`, `New folder (2)`, `New folder (3)`, `Download`, `Downloads2`, `Application`, `Film`, `C:\Users\Alex\Videos`
- Priority 5: `Small Files` (a folder of very many small files)

`config/filters.txt`: `- Thumbs.db`, `- desktop.ini`, `- ~$*`, `- *.tmp`, `- *.partial`, `- $RECYCLE.BIN/**`, `- System Volume Information/**`.

- [ ] **Step 1: Init repo and Pester.** Run `git init` in `G:\pikpak-mirror`, then `Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck`. Write `tests/run.ps1` so it runs `Import-Module Pester -RequiredVersion 5.7.1` and then `Invoke-Pester -Path $PSScriptRoot -Output Detailed`, passing through an optional `-Filter` name.
- [ ] **Step 2: Write failing tests** in `tests/Config.Tests.ps1` (use a temp psd1 per test):
  - `expands env vars and strips trailing backslash`: `StateDir` equals `"$env:LOCALAPPDATA\PikPakMirror"`. A pair `Local='D:\Music\'` becomes `D:\Music`. `WatchRoots` stays `D:\`.
  - `flags pair whose local is inside a private path`: PrivatePaths `D:\Secret`, pair `D:\Secret\Pics` → an error containing `D:\Secret\Pics`.
  - `flags pair that is itself private`: private `D:\New folder (3)` equals a pair Local → an error containing `remove the pair`.
  - `allows private path nested under a pair`: private `D:\New folder\Private` under pair `D:\New folder` → no error.
  - `flags duplicate pair names and private Name '_holding'` → two errors.
  - `hash ignores order and case`: `Get-PrivatePathsHash` of `D:\A`,`d:\b` equals that of `D:\B`,`D:\a`.
- [ ] **Step 3: Run** `powershell -NoProfile -File tests/run.ps1`. Expected: FAIL (`Get-MirrorConfig` not recognized).
- [ ] **Step 4: Implement** `Config.ps1` (path-prefix checks compare lower-cased paths with a trailing `\` appended) and `_load.ps1`. Write the real `config/mirror.config.psd1` and `config/filters.txt` with the values above.
- [ ] **Step 5: Run tests.** Expected: all PASS. Also run `Test-MirrorConfig (Get-MirrorConfig config/mirror.config.psd1)`. Expected: empty.
- [ ] **Step 6: Commit** with message `feat: config loading and validation`.

### Task 2: Filter rules

**Files:**
- Create: `scripts/lib/Filters.ps1`, `tests/Filters.Tests.ps1`

**Interfaces:**
- Consumes: `Get-MirrorConfig`
- Produces:
  - `ConvertTo-RcloneFilterPath -RelativePath <string> -> string`: forward slashes, leading `/`, and `\` before each of `[ ] { } * ?`.
  - `New-PairFilterRules -Config <hashtable> -Pair <hashtable> -GlobalRulesPath <string> -> string[]`: the global rules, then `- <escaped>/**` for each private path under `Pair.Local`.
  - `Get-TextHash -Lines <string[]> -> string` (SHA256 hex of lines joined with `\n`).

- [ ] **Step 1: Write failing tests:**
  - `escapes glob metacharacters`: `ConvertTo-RcloneFilterPath '[2024] trip\a*b'` equals `/\[2024\] trip/a\*b`.
  - `keeps unicode and parentheses`: `'Nhạc\New folder (3)'` becomes `/Nhạc/New folder (3)`.
  - `adds private exclude relative to pair`: pair `D:\New folder`, private `D:\New folder\Private` → last rule is `- /Private/**`.
  - `ignores private paths outside the pair`: pair `D:\Music`, private `D:\Secret` → the rules equal the global rules exactly.
- [ ] **Step 2: Run** `tests/run.ps1`. Expected: FAIL.
- [ ] **Step 3: Implement** `Filters.ps1`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** with message `feat: rclone filter generation`.

### Task 3: rclone argument builders

**Files:**
- Create: `scripts/lib/RcloneArgs.ps1`, `tests/RcloneArgs.Tests.ps1`

**Interfaces:**
- Consumes: config keys from Task 1
- Produces (all return `string[]`, with the rclone subcommand first):
  - `New-BisyncArgs -Config -Pair -FiltersFile <string> -Date <datetime> -BudgetBytes <long> [-Resync] [-Force] -LogFile <string>`
  - `New-PrivateSyncArgs -Config -Entry -Date -BudgetBytes -LogFile`
  - `New-PruneArgs -Target <string> -Days <int> -LogFile`
  - `New-MountArgs -Config -Which <'Cloud'|'Private'>`
  - `New-ArchiveMoveArgs -Source <string> -Dest <string> -IsDirectory <bool> -LogFile`

- [ ] **Step 1: Write failing tests** with a fixed date `2026-10-24` and pair `Music` (`D:\Music` ⇄ `D/Music`):
  - `bisync core args`: the result starts with `bisync`, `D:\Music`, `pikpak:PC-Mirror/D/Music`. It contains these consecutive pairs:
    - `--compare` `size,modtime`
    - `--conflict-resolve` `newer`
    - `--conflict-loser` `num`
    - `--max-delete` `10`
    - `--backup-dir1` `D:\.pikpak-holding\2026-10-24\Music`
    - `--backup-dir2` `pikpak:PC-Holding/2026-10-24/Music`
    - `--max-transfer` `8589934592`
    - `--cutoff-mode` `soft`
    - `--bwlimit` `18:00,2M:off 23:00,off`
    - `--filters-file` `<FiltersFile>`
    - `--workdir` `<StateDir>\bisync`
    - `--max-lock` `2h`

    It also contains `--check-access`, `--resilient`, `--recover`, `--use-json-log` and `--stats-log-level` `NOTICE`, and it does **not** contain `--checksum`, `--resync` or `--force`.
  - `bisync resync and force switches`: `-Resync` adds `--resync`. `-Force` adds `--force`.
  - `private sync args`: entry `@{Path='D:\Secret';Name='Secret'}` → `sync`, `D:\Secret`, `private:Secret`, `--backup-dir`, `private:_holding/2026-10-24/Secret`. Includes `--max-transfer`.
  - `prune args`: `New-PruneArgs 'pikpak:PC-Holding' 30` → `delete`, `pikpak:PC-Holding`, `--min-age`, `30d`, `--rmdirs`.
  - `mount args`: `Cloud` → `mount`, `pikpak:`, `P:`, `--vfs-cache-mode`, `full`, `--vfs-cache-max-size`, `20G`, `--vfs-cache-max-age`, `24h`, `--cache-dir`, `D:\.pikpak-cache`, with no `--read-only`. `Private` → `private:`, `Q:`, and contains `--read-only`.
  - `archive move args`: a directory uses `move` plus `--delete-empty-src-dirs`. A file uses `moveto`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** `RcloneArgs.ps1`. Budget bytes are passed as integer strings. Remote paths join as `<remote>:<root>/<rel>` with forward slashes.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** with message `feat: rclone argument builders`.

### Task 4: State and budget

**Files:**
- Create: `scripts/lib/State.ps1`, `tests/State.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-MirrorState -StateDir -> pscustomobject`. It has these fields:
    - `Month` (`yyyy-MM`) and `TransferredBytes` (long)
    - `LastSuccess` (ISO string or `$null`)
    - `PrivateConfirmedHash`
    - `Pairs`: name → `{Seeded:bool, FilterHash:string, LastExit:int, LastRun:string}`
    - `NotifiedUnmapped` (string[]) and `QuotaWarned` (bool)

    A missing file returns the defaults.
  - `Save-MirrorState -StateDir -State` (JSON in `state.json`, written to a temp file and then moved into place).
  - `Add-TransferredBytes -State -Bytes <long> -Now <datetime>`. On a month change it resets `TransferredBytes` and `QuotaWarned` first.
  - `Get-RunBudget -State -Config -Now -> long` = min(RunBudgetGB, MonthlyBudgetGB − used) in bytes, floored at 0, applying the month reset.
  - `Test-StaleSuccess -State -Config -Now -> bool`

- [ ] **Step 1: Write failing tests:**
  - `defaults when no file`: `Month` is `$null`, `TransferredBytes` is 0, `Pairs` is empty.
  - `round-trips through disk` (TestDrive).
  - `month rollover resets usage`: state `Month='2026-09'` with 200 GB used; `Get-RunBudget` at `2026-10-01` returns 8 GB.
  - `budget capped by monthly remainder`: 246 GB used → 4 GB. 250 GB used → 0.
  - `stale after 3 days`: LastSuccess 2026-10-20 at Now 2026-10-24 → `$true`. LastSuccess 2026-10-22 → `$false`. `$null` LastSuccess → `$false` (never run yet is not stale).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** `State.ps1` (`ConvertFrom-Json` gives a PSCustomObject; convert `Pairs` to a hashtable after loading).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** with message `feat: run state and transfer budget`.

### Task 5: Runtime: rclone wrapper, log parsing, toast, lock

**Files:**
- Create: `scripts/lib/Runtime.ps1`, `tests/Runtime.Tests.ps1`

**Interfaces:**
- Produces:
  - `Invoke-Rclone -Arguments <string[]> -> pscustomobject @{ ExitCode:int; Bytes:long; LogFile:string; NeedsResync:bool }`. It runs `rclone.exe` via `& rclone @Arguments`. The log file is the value after `--log-file` in Arguments. `NeedsResync` = the log contains `must run --resync`.
  - `Get-TransferredBytesFromLog -Path -> long`: the `stats.bytes` of the last JSON log line that has `stats`, or 0.
  - `Send-MirrorToast -Title -Message` (WinRT `Windows.UI.Notifications.ToastNotificationManager`, AppId `{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe`). Failures are swallowed and written to the log.
  - `Write-MirrorLog -Config -Message` (appends to `<StateDir>\logs\yyyy-MM-dd.log`).
  - `Enter-MirrorLock -StateDir -> System.IO.FileStream` or `$null` if held (`[IO.File]::Open(..., 'OpenOrCreate', 'ReadWrite', 'None')`).
  - `Exit-MirrorLock -Handle`
  - `Remove-OldLogs -Config -Now` deletes log files older than LogKeepDays.

- [ ] **Step 1: Write failing tests:**
  - `reads bytes from last stats line`: a fixture log with three JSON lines (two have `"stats":{"bytes":100}` and `{"bytes":2500}`) → 2500. A missing file → 0.
  - `second lock attempt fails while first held`: the first call returns non-null and the second returns `$null`. After `Exit-MirrorLock`, a third call returns non-null.
  - `deletes logs older than 60 days`: in TestDrive, an old file is removed and a new file is kept.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** `Runtime.ps1`.
- [ ] **Step 4: Run.** Expected: PASS. Then run `. scripts/lib/_load.ps1; Send-MirrorToast 'PikPak Mirror' 'test'`. Expected: a Windows notification appears.
- [ ] **Step 5: Commit** with message `feat: rclone wrapper, logging, toast, lock`.

### Task 6: Sync orchestration (`Invoke-MirrorRun`) and `Invoke-Sync.ps1`

**Files:**
- Create: `scripts/lib/Run.ps1`, `scripts/Invoke-Sync.ps1`, `tests/Run.Tests.ps1`

**Interfaces:**
- Consumes: all functions from Tasks 1–5.
- Produces:
  - `Invoke-MirrorRun -Config -Now <datetime> -> pscustomobject @{ Ran:string[]; Skipped:string[]; Errors:string[] }`
  - `Find-UnmappedFolders -Config -> string[]`: directories directly under each `WatchRoots` entry. A directory is excluded if it matches `IgnoredFolders` (wildcards), is a pair `Local`, or is a private `Path`.
  - `Invoke-Sync.ps1` takes `[-ConfigPath]` (default `config/mirror.config.psd1`). It loads the config and calls `Invoke-MirrorRun` with `Get-Date`. Exit code 0 on success, 1 if `Errors` is non-empty.

Run algorithm (the order matters and the tests pin it):
1. Take the lock. If it's held, return with Skipped=`locked`.
2. Load state. If `Test-MirrorConfig` returns errors, toast them all and stop.
3. If `PrivateConfirmedHash` ≠ `Get-PrivatePathsHash`, toast `Private folders not confirmed – run Confirm-PrivatePaths.ps1` and stop. Nothing runs, not even private sync.
4. Budget = `Get-RunBudget`. If it's 0, toast once per month (`QuotaWarned`) and stop.
5. Private entries in config order. For each: skip with a toast if `Path` is missing. Otherwise run `New-PrivateSyncArgs`, subtract its bytes from the budget, and add them via `Add-TransferredBytes`. Exit 8 → skip all remaining private entries and all pairs, then continue at step 7. Any other non-zero exit → toast plus an Errors entry.
6. Pairs sorted by Priority, then Name. For each pair:
   - If `Local` is missing, skip with a toast.
   - Generate the filter rules and write them to `<StateDir>\filters\<Name>.txt`.
   - Resync is needed when `Seeded` is false, or when the stored `FilterHash` differs from the new one.
   - If a seeded pair's filter changed, toast `Filters changed for <Name>: delete any plain copy of newly private folders under pikpak:PC-Mirror/<Remote>`.
   - Before a resync, create `RCLONE_TEST` locally (if absent) and run `touch <remote>/RCLONE_TEST` through `Invoke-Rclone`.
   - Run bisync.
   - Exit 0 → `Seeded=$true`, store FilterHash.
   - Exit 8 → budget exhausted. Record the bytes and stop processing further pairs. Keep `Seeded` unchanged, so an unfinished resync repeats next run.
   - `NeedsResync` → toast `<Name> needs attention: bisync requires --resync (see log)`. Do **not** auto-resync.
   - Any other non-zero exit → toast plus an Errors entry.
   - Always record LastExit and LastRun.
7. Prune `pikpak:PC-Holding`, `D:\.pikpak-holding` and `private:_holding` with HoldingDays. Then run `Remove-OldLogs`.
8. Unmapped folders not yet in `NotifiedUnmapped` → one toast listing them, then add them to the list.
9. Quota: if used ≥ 90% of monthly and not `QuotaWarned`, toast and set it.
10. If there are no Errors, set `LastSuccess`. If `Test-StaleSuccess`, toast `No successful backup for 3+ days`.
11. Save state and release the lock (in `finally`).

- [ ] **Step 1: Write failing tests.** Mock `Invoke-Rclone` to record args and return scripted `ExitCode`/`Bytes`. Mock `Send-MirrorToast` to record calls. Use TestDrive dirs for `Local` paths and StateDir.
  - `stops when private paths not confirmed`: `Invoke-Rclone` is called 0 times, and the toast contains `Confirm-PrivatePaths`.
  - `runs private first then pairs by priority`: the recorded first args are `sync`, then bisync for priority 1, then priority 2.
  - `first run uses resync and touches sentinel`: the args include `--resync`, a `touch` call precedes the bisync, and the local `RCLONE_TEST` exists. On a second run with state `Seeded`, there is no `--resync`.
  - `exit 8 keeps pair unseeded and stops remaining pairs`.
  - `filter change forces resync and warns`: the state has `Seeded=$true` with an old FilterHash, and the config adds a private path under the pair. Expect `--resync` and a toast containing `delete any plain copy`.
  - `skips pair whose local folder is missing`: no bisync for it, a toast names it, and the other pairs still run.
  - `needs-resync is reported, not auto-fixed`: the mock returns `NeedsResync=$true`, exit 7. Expect the toast and no second call carrying `--resync`.
  - `toasts once for unmapped top-level folder`: create `<watchroot>\NewStuff`. The first run toasts `NewStuff` and the second run doesn't.
  - `budget zero skips everything`: Invoke-Rclone is called 0 times and one toast is shown.
  - `prunes all three holding areas`: three `delete` calls with `--min-age 30d`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** `Run.ps1` and `Invoke-Sync.ps1`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** with message `feat: sync orchestration`.

### Task 7: Offload to Archive

**Files:**
- Create: `scripts/lib/Archive.ps1`, `scripts/Move-ToArchive.ps1`, `tests/Archive.Tests.ps1`

**Interfaces:**
- Consumes: `New-BisyncArgs`, `New-ArchiveMoveArgs`, `Invoke-Rclone`, `Enter-MirrorLock`, `New-PairFilterRules`
- Produces:
  - `Get-ArchiveTarget -Config -LocalPath -> pscustomobject @{ Pair; RelPath; MirrorPath; ArchivePath; IsDirectory }`. Example: `D:\Film\x.mkv` → MirrorPath `pikpak:PC-Mirror/D/Film/x.mkv`, ArchivePath `pikpak:Archive/D/Film/x.mkv`. It throws `not inside a synced folder` or `private folders cannot be archived`.
  - `Invoke-Offload -Config -LocalPath -Now -> bool`. In order:
    1. Take the lock, or throw `sync running, try later`.
    2. Run `copy`/`copyto` from local to MirrorPath (uploads anything missing).
    3. Run `check --size-only --one-way` from local to MirrorPath. Exit ≠ 0 → abort, keep the local copy.
    4. Run the archive move.
    5. Delete the local file/dir with `Remove-Item -Recurse`.
    6. Run bisync on the owning pair with `-Force`, using the pair's current filters file.
    7. Release the lock.
  - `Move-ToArchive.ps1 -Path <string>`: shows the target and asks `Offload? (y/N)` unless `-Yes`. It shows errors in the console and waits for a key press when launched from the context menu (`-FromExplorer`).

- [ ] **Step 1: Write failing tests** (with `Invoke-Rclone` mocked):
  - `maps file and directory targets` (both examples, including `C:\Users\Alex\Pictures\a.jpg` → `pikpak:Archive/C-Users/Pictures/a.jpg`).
  - `rejects paths outside pairs and private paths` → expected throws.
  - `aborts and keeps local when check fails`: the check mock returns exit 1. The local file still exists and no `moveto` call is made.
  - `runs a forced bisync on the owning pair`: on success the call order is `copyto`, `check`, `moveto`, `bisync` (with `--force`), and the local file is gone.
  - `refuses while lock is held`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** `Archive.ps1` and `Move-ToArchive.ps1`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** with message `feat: offload to cloud-only archive`.

### Task 8: Confirm-PrivatePaths and Get-Status

**Files:**
- Create: `scripts/Confirm-PrivatePaths.ps1`, `scripts/Get-Status.ps1`, `scripts/lib/Status.ps1`, `tests/Status.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-MirrorStatus -Config -State -Now -> pscustomobject` with these fields:
    - `LastSuccess`, `Month`, `UsedGB`, `BudgetGB`, `PrivateConfirmed:bool`
    - `Pairs` (Name, Priority, Seeded, LastExit, LastRun)
    - `Unmapped` (from `Find-UnmappedFolders`)
  - `Get-Status.ps1 [-Json]`: a table by default, or JSON for Claude.
  - `Confirm-PrivatePaths.ps1`:
    1. Lists each private path with its existence and size.
    2. Lists the pairs that will exclude it.
    3. Warns if `pikpak:PC-Mirror` already contains a matching plain path (`rclone lsf`).
    4. Requires typing `YES`, then saves `PrivateConfirmedHash`.

- [ ] **Step 1: Write failing tests**:
  - `status reports unconfirmed private paths and seeded pairs`: state with a mismatching hash → `PrivateConfirmed=$false`, and the pair fields come from state.
  - `UsedGB rounds to 0.1`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. Then run `scripts/Get-Status.ps1` against the real config. Expected: a table where every pair has `Seeded=False` and `PrivateConfirmed=False`.
- [ ] **Step 5: Commit** with message `feat: status and private-path confirmation`.

### Task 9: Install, mounts, scheduling, context menu, docs

**Files:**
- Create: `scripts/Install.ps1`, `scripts/Start-Mount.ps1`, `docs/README.md`, `docs/RECOVERY.md`

**Interfaces:**
- Consumes: `New-MountArgs`, `Get-MirrorConfig`
- Produces:
  - `Install.ps1 -Role <Master|Viewer> [-WhatIf]`, idempotent. Each step prints `[skip]` if it's already done:
    1. `winget install --id Rclone.Rclone --version 1.75.2 -e`, then `winget install --id WinFsp.WinFsp -e`.
    2. If remote `pikpak` is missing (`rclone listremotes`): prompt for email and password (`Read-Host -AsSecureString`), run `rclone config create pikpak pikpak user <email> pass <pw>`, and verify with `rclone about pikpak:`.
    3. If remote `private` is missing, offer two choices: (a) enter an existing password and salt (Viewer, or restore), or (b) generate both (Master: 32 random chars each via `RNGCryptoServiceProvider`). Run `rclone config create private crypt remote pikpak:PC-Private filename_encryption standard directory_name_encryption true password <p> password2 <s>`. For (b), print both once and require typing `SAVED`.
    4. Master only: register `PikPakMirror-Sync`. The action is `conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File <repo>\scripts\Invoke-Sync.ps1`. Triggers: AtLogOn with `Delay=PT15M`, and Daily 20:00. Settings: `-StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 0)`, LogonType Interactive.
    5. Both roles: register `PikPakMirror-Mount` (AtLogOn) running `Start-Mount.ps1` the same headless way.
    6. Master only: add the context menu under HKCU `Software\Classes\*\shell\PikPakOffload` and `Software\Classes\Directory\shell\PikPakOffload` (label `Offload to PikPak Archive`). The command runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <repo>\scripts\Move-ToArchive.ps1 -FromExplorer -Path "%1"`.
    7. Master only: create `LocalHolding`, `CacheDir` and `StateDir`.
  - `Start-Mount.ps1`: for `Cloud` and `Private`, skip if the drive letter already exists. Otherwise run `Start-Process rclone` with `New-MountArgs` (hidden window, `--log-file <StateDir>\logs\mount-<which>.log`).
  - `docs/README.md`: what runs when, how to add a pair or private path (edit the psd1, then run `Confirm-PrivatePaths.ps1`), offload/restore, status, logs, and the Vault rule (copy, never move).
  - `docs/RECOVERY.md`: a fresh PC restore covers `Install.ps1 -Role Viewer` with the saved password and salt, then `rclone copy pikpak:PC-Mirror/... D:\...`, `rclone copy private: ...`, and restoring from the holding areas.

- [ ] **Step 1: Dry run.** `powershell -File scripts/Install.ps1 -Role Master -WhatIf`. Expected: every step prints what it would do, and nothing changes. Confirm with `Get-ScheduledTask PikPakMirror*` returning nothing.
- [ ] **Step 2: Real install (user present).** Run `scripts/Install.ps1 -Role Master` using the **free test account**. Expected: `rclone version` shows `v1.75.2`, `rclone listremotes` shows `pikpak:` and `private:`, both tasks exist, and the context-menu entry appears on right-click.
- [ ] **Step 3: Mount check.** Run `scripts/Start-Mount.ps1`. Expected: `P:` lists the PikPak root, and `Q:` exists and rejects `New-Item Q:\x.txt` (read-only).
- [ ] **Step 4: Commit** with message `feat: installer, mounts, scheduling, docs`.

### Task 10: PikPak MCP and live verification on the test account

**Files:**
- Create: `.mcp.json` (via `claude mcp add`), `config/mirror.test.local.psd1` (gitignored by `*.local.psd1`), `docs/superpowers/plans/2026-10-24-verification.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Wire PikPak MCP.** The user copies the address from PikPak *Settings → Access & Integrations → MCP*. Then run `claude mcp add --transport http --scope project pikpak <url>` in `G:\pikpak-mirror`, restart Claude Code, and approve in the browser. Expected: `.mcp.json` contains the `pikpak` entry, and the PikPak MCP tools list the account's root folders. If MCP isn't available on the account (alpha), note it in `docs/README.md` and continue. Nothing else depends on it.
- [ ] **Step 2: Test config.** Create `config/mirror.test.local.psd1`:
  - pair `T1`: `D:\pikpak-test\Sync` ⇄ `Test/Sync`
  - private `D:\pikpak-test\Secret`
  - `RunBudgetGB=1`, `HoldingDays=0`

  Seed `D:\pikpak-test` with ~300 MB: nested dirs, `Nhạc (1)`, `[x] y.txt`, and a 100 MB file. Run `Confirm-PrivatePaths.ps1 -ConfigPath <test>`, then `Invoke-Sync.ps1 -ConfigPath <test>`.
- [ ] **Step 3: Walk the spec §8 checklist** and record each result in `docs/superpowers/plans/2026-10-24-verification.md`:
  1. Add/edit/delete/rename on the PC → appears in PikPak (check via MCP and `rclone lsf`).
  2. The same changes from the PikPak web app → appear on the PC.
  3. A deleted file lands in both holding areas, and prune with `HoldingDays=0` empties them.
  4. Editing on both sides keeps both versions (`.conflict` suffix).
  5. Rename `D:\pikpak-test\Sync` → toast, and no remote deletes.
  6. Empty the remote folder in the web UI → bisync aborts on `--check-access`, and no local deletes.
  7. `Secret` shows as gibberish names in the PikPak web UI and is readable on `Q:`.
  8. `Move-ToArchive` on a file → gone locally, present in `P:\Archive\Test\Sync`, and the next sync is a no-op.
  9. Kill `rclone.exe` mid-upload → the next run completes.
  10. The 1 GB budget stops the run with exit 8, and `Get-Status` shows the usage.
  11. Log off and on → the mount appears and the sync runs.
  12. Many-small-files timing: run `rclone lsf -R --fast-list pikpak:` on a test copy of 20k tiny files, and record the duration for the builder decision in spec §7.
- [ ] **Step 4: Fix** anything that failed, as a new test plus a fix in the owning task's files. Re-run `tests/run.ps1`. Expected: all PASS.
- [ ] **Step 5: Commit** with message `chore: MCP wiring and live verification on test account`.
- [ ] **Step 6: Hand-off (user, once Premium exists).**
  1. Re-run `rclone config reconnect pikpak:`, or recreate it with the Premium login.
  2. Fill `PrivatePaths` in `config/mirror.config.psd1` with the user's real private folders.
  3. Run `Confirm-PrivatePaths.ps1` and let the scheduled task take over.
  4. Check `Get-Status.ps1` daily for the first week.

---

## Amendments after Part 1 (Tasks 1–8) final review — 2026-10-24

These supersede the task text above where they conflict. The code and tests on `feat/part1-engine` already implement them.

- **Prune:** `New-PruneArgs -Target -Now -Days -LogFile` keeps date folders `/{today … today-(Days-1)}/**` and deletes the rest. No `--min-age`. It refuses bare remote roots and drive roots.
- **Sentinel:** `copyto <Local>\RCLONE_TEST <remote>/RCLONE_TEST --ignore-existing`, not `touch`. PikPak can't change the modtime of an existing file.
- **Paths:** config paths are trimmed and env-expanded, `/` becomes `\`, they go through GetFullPath, and trailing spaces and dots are stripped from each segment. Bisync uses `--ignore-case`. Private excludes come before the global rules in the filter file.
- **Validator:** rejects these configs:
  - unrooted or `%`-paths
  - private paths that are files
  - missing or overlapping roots
  - nested or duplicate pairs or remotes
  - bad names
  - non-positive budgets
- **Pair identity:** state stores an `Identity` hash of `Local|Remote` for each pair. Changing it triggers a resync.
- **Ordering:** seeded pairs run first, then unseeded pairs, each group sorted by priority and then name.
- **Offload:**
  - The copy uses `--bwlimit` plus the remaining run budget, and is refused when the budget is 0.
  - A file is checked against its parent folder.
  - The archive move uses `--backup-dir <HoldingRoot>/<date>/_archive/...`.
  - It re-checks just before deleting the local copy.
- **Logging:** `--log-level INFO` on all transferring commands. `BudgetPauseNotified` is separate from `QuotaWarned`.
- **Task 10 live checks to add:**
  - `copyto --ignore-existing` sentinel on an existing object
  - single-file `check` against the parent folder
  - the brace exclude syntax on PikPak
  - `move`/`moveto` with `--backup-dir`
  - bisync with `--ignore-case`
  - exit 8 mid-bisync, then a clean next run
  - the final JSON stats line gets parsed
  - an old file deleted on the phone is still in holding the next day
