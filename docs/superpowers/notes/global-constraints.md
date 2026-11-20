# Global constraints (verbatim from plan) + controller rulings

- Every script runs on **Windows PowerShell 5.1**: no `?:`, `??`, `?.`, `&&`/`||`, `-AsHashtable`, or pwsh-only cmdlets.
- rclone pinned to **v1.75.2**. Pester pinned to **5.7.1** (CurrentUser scope).
- Comparison is **size + modtime** (`--compare size,modtime`). Never use `--checksum` or hash compare.
- Remote names: `pikpak` (type pikpak), `private` (type crypt over `pikpak:PC-Private`). Remote roots: `PC-Mirror`, `PC-Holding`, `Archive`, `PC-Private`. Private holding: `private:_holding`.
- Local holding `D:\.pikpak-holding`; VFS cache `D:\.pikpak-cache`; state dir `%LOCALAPPDATA%\PikPakMirror`.
- Holding retention **30 days**; bisync `--max-delete 10` (percent); per-run transfer budget **8 GB**; monthly budget **250 GB**; quota warning at **90%**; stale-success warning after **3 days**; logs kept **60 days**.
- Mount: `P:` = `pikpak:` read-write; `Q:` = `private:` `--read-only`; `--vfs-cache-mode full --vfs-cache-max-size 20G --vfs-cache-max-age 24h`.
- No secrets in the repo.
- Private-path confirmation is stored as a **hash in state** (not a config flag).
- Bytes counted against the budget are all bytes rclone reports transferred in a run, both directions.
- Every entry script takes `[-ConfigPath <string>]` defaulting to `<repo>\config\mirror.config.psd1`, and dot-sources `scripts/lib/_load.ps1`.
- Tests: Pester 5.7.1, run with `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1` (optionally `-Filter`). Unit tests never touch the network or real rclone.
- Commit messages end with a blank line then `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Controller rulings that bind implementers
- R1: config key `GlobalFiltersFile='filters.txt'`; Get-MirrorConfig resolves it relative to the config file's directory → absolute path.
- R2: repo already initialised (branch feat/part1-engine); `.gitignore` exists — append `logs/`, `*.local.psd1`, `.pikpak-*`; do not `git init`.
- R3: New-BisyncArgs, New-PrivateSyncArgs, New-PruneArgs, New-ArchiveMoveArgs all emit `--log-file <LogFile>`; bisync and private sync also emit `--use-json-log` and `--stats-log-level NOTICE`.
- R4: New-PrivateSyncArgs also emits `--cutoff-mode soft` and `--bwlimit <BwLimit>`.
- R5: State = PSCustomObject; `Pairs` = hashtable name → hashtable @{Seeded;FilterHash;LastExit;LastRun}; `NotifiedUnmapped` = string[].
- R6: Get-RunBudget is pure (as-if month reset); only Add-TransferredBytes mutates.
- R7: Send-MirrorToast has optional `-Config`; on failure → Write-MirrorLog if Config given, else Write-Warning.
- R8: Run.ps1 exports `Update-PairFilterFile -Config -Pair -> pscustomobject @{ Path; Hash }` writing `<StateDir>\filters\<Name>.txt`; Task 7 reuses it.
- R9: Task 7 forced bisync uses `RunBudgetGB` bytes and records transferred bytes (Add-TransferredBytes + Save-MirrorState).
- R10: Task 7 builds copy/copyto and `check --size-only --one-way` args inside Archive.ps1, each with `--log-file`.
- R11: Confirm-PrivatePaths calls `& rclone lsf` directly.
- R12: Any file rclone reads (filter files) is written UTF-8 **without BOM** (`[IO.File]::WriteAllLines(path, lines, (New-Object Text.UTF8Encoding $false))`) — names like `Nhạc` must survive.
- R13: Functions returning arrays emit unrolled (Test-MirrorConfig, New-PairFilterRules); callers wrap with `@()`.

## Part 2 rulings (Task 9)
- R14: `PikPakMirror-Sync` is registered **Disabled** unless `Install.ps1 -EnableSchedule` is passed (testing phase must not run nightly against the real config). Re-running with `-EnableSchedule` enables an existing task. The mount task is always enabled.
- R15: Pure, testable builders live in `scripts/lib/Setup.ps1` (added to `_load.ps1`) with `tests/Setup.Tests.ps1`: task action/trigger/settings definitions, context-menu registry entries, crypt secret generation, rclone config-create argument arrays, mount process args (incl. `--log-file`). `Install.ps1` / `Start-Mount.ps1` only orchestrate. Unit tests never touch the registry, Task Scheduler, winget, or rclone.
- R16: Secrets: PikPak password read with `Read-Host -AsSecureString`, converted to plain only inside the rclone config-create call, never logged, echoed, or written to disk by our scripts; variables cleared after use. Generated crypt password + salt: 32 chars each from `RNGCryptoServiceProvider` over `[A-Za-z0-9]`; shown once; user must type `SAVED` (exact) to continue, else abort without creating the remote.
- R17: `-WhatIf` (SupportsShouldProcess) performs NO side effects and NO prompts: prints each step it would do. Each real step is idempotent and prints `[skip]` when already done. Version check: if `rclone version` ≠ v1.75.2 print a yellow warning (don't downgrade).
- R18: Reserve pair name `_archive` in `Test-MirrorConfig` (parked final-review item) with a test.
- R19: README documents that an offload aborted AFTER the archive move leaves the archived copy in PikPak Archive and the next sync moves the unchanged local files into local holding (30 days) — no data lost (parked wording item).
