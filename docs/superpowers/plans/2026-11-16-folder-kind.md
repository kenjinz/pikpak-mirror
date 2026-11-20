# Folder kind (synced or encrypted) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the owner choose "encrypted" when adding a folder on Home, and change a folder's kind later in both directions without losing files.

**Architecture:** A change of kind is a detached job (`scripts\Convert-Folder.ps1` over `Invoke-MirrorFolderConversion`): last sync of that folder in the old form, config switch, old sync state forgotten, old PikPak copy deleted when asked, first sync in the new form. The GUI gets one new action that starts the job, a flag on `folders.add`, a box on Home and a menu on each folder row.

**Tech Stack:** Windows PowerShell 5.1, rclone, Pester 5.7.1, Tauri 2 (plain JS UI).

**Spec:** `docs/superpowers/specs/2026-11-16-folder-kind-design.md`. Read it before any task.

## Global Constraints

- Windows PowerShell 5.1 only. Script files stay ASCII; build non-ASCII characters with `[char]`.
- An encrypted folder's content never reaches the plain remote or a plain holding area.
- An existing seeded folder that is not being changed keeps its bisync arguments, state key, filter file and identity hash (no forced resync).
- Nothing is deleted in PikPak except, when asked, exactly the changed folder's old copy: `pikpak:<MirrorRoot>/<pair Remote>` or `private:<Name>`. Never a remote root, never `PC-Holding`, never `private:_holding`.
- The old copy is deleted only after the last sync in the old form succeeded and the config switch was saved.
- User-facing wording: "PikPak Sync", "sync" (not "back up"), "Encrypted" / "encrypted folder" (not "private"). Identifiers, config keys and existing action names keep their names.
- Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1` (`-Filter` matches test names). "Suite passes" = no failure other than `J3` in `Config.Tests.ps1` (baseline 603 passed, 1 failed).
- This PC is a LIVE install whose scheduled task runs the code in `G:\pikpak-mirror\.worktrees\sync-focus`. Work only in `G:\pikpak-mirror\.worktrees\folder-kind` (branch `feat/folder-kind`). No `Install.ps1` without `-WhatIf`, no scheduled-task or registry changes, no rclone against the account, do not start the app. Tests must not write into the real `%LOCALAPPDATA%\PikPakMirror` (use a temp `StateDir`).
- One commit per task, `type(scope): summary`, ending with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Do not push.

## Review Focus

1. The last sync fails or is skipped (lock held, day paused, delete safety stop, folder missing): nothing is switched, nothing deleted. Test in Task 1.
2. The job is interrupted between the config switch and the deletion: the next normal run must be safe (new form resyncs; old copy merely remains). Test in Task 1 (state after step 2 alone is a valid config and state).
3. A synced folder and an encrypted folder with the same `Name`: the change touches only the right state key, filter file and remote path. Test in Task 1.
4. A pair whose `Remote` is unusual (`C-Users/Documents`, spaces, a drive root `D`): the purge target is built from the pair's own `Remote`, and a drive-root or empty remote is refused. Test in Task 1.
5. The user changes a folder, and changes it back the same day: the second change must not trust state of the first form. Test in Task 1.

---

### Task 1: The change job (engine)

**Files:**
- Create: `scripts\lib\Convert.ps1`, `scripts\Convert-Folder.ps1`, `tests\Convert.Tests.ps1`
- Modify: `scripts\lib\_load.ps1` (load `Convert.ps1` after `Run.ps1`), `scripts\lib\Run.ps1` (`-OnlyFolders`), `scripts\lib\RcloneArgs.ps1` (`New-PurgeArgs`), `tests\Run.Tests.ps1`, `tests\RcloneArgs.Tests.ps1`

**Interfaces (produces):**
- `Invoke-MirrorRun` gains `[string[]]$OnlyFolders = @()`: when not empty, only folders whose `StateKey` is listed (case-insensitive) are synced; the others are not attempted (so their notification memory and state are untouched), and the prune and stale-success steps are skipped. Everything else (lock, config check, confirmation gate, budget, pause) is unchanged.
- `New-PurgeArgs -Target <string> -LogFile <string>` returns `@('purge', <Target>, '--log-level', 'INFO', '--log-file', <LogFile>)`; throws for an empty target, a bare remote root (`^[^:]+:/*$`), or a target that has only one path segment equal to the config roots is the caller's check (below).
- `Get-FolderConversionPlan -Config <raw config hashtable> -Path <string> -To <'encrypted'|'plain'>` (pure): returns `@{ From = <Get-SyncFolders item of the old form>; NewConfig = <raw config after the switch>; NewKind; NewName; OldRemote = <full remote path of the old copy>; Note = <string or $null> }`, or throws with a plain message when the change is not allowed. Rules: `To = 'encrypted'` needs a pair whose `Local` is that path (else "is not a synced folder"); new `PrivatePaths` entry named as `private.add` names it today (leaf, made unique against `_holding` and existing names); refused when the folder contains an encrypted folder. `To = 'plain'` needs a `PrivatePaths` entry at that path; when the path is inside a pair's `Local`, no pair is added and `Note` says it becomes part of that synced folder; otherwise the new pair comes from `New-MirrorPair`. `OldRemote` is refused when it is a remote root or equals `<Remote>:<MirrorRoot>`, `<Remote>:<HoldingRoot>` or `<PrivateRemote>:_holding`.
- `Invoke-MirrorFolderConversion -ConfigPath <string> -Path <string> -To <...> [-DeleteOldCopy] -Now <datetime>` returns `[pscustomobject]@{ Changed = [bool]; OldCopyDeleted = [bool]; Message = <string> }` and sends one toast with `Message`. Steps exactly as the spec's "The change job", using `Invoke-MirrorRun -OnlyFolders` for steps 1 and 5, `Save-MirrorConfig` (the same writer the app uses, with its backup) for step 2, and for step 3: remove `State.Pairs[<old StateKey>]`, every `State.Notified` key of that folder, the old filter file, and the old form's listing files in `<StateDir>\bisync` (bisync names them from the two paths; delete the files whose name contains both sanitised paths — read how rclone names them from an existing workdir test fixture or the rclone docs, and cover it with a test using fake files). The encrypted-folder confirmation hash is saved with the new config (same as `Save-PrivateConfirmation`).
- `scripts\Convert-Folder.ps1 -ConfigPath -Path -To [-DeleteOldCopy]`: thin entry point, exit 0 when `Changed`, else 1; an unexpected error is logged and toasted once.

- [ ] **Step 1: Write the failing tests** (`tests\Convert.Tests.ps1`; mock `Invoke-Rclone` and `Send-MirrorToast` as `tests\Run.Tests.ps1` does; every config uses a temp `StateDir`):

```powershell
It 'plans synced to encrypted' {
    # pair Docs = <root>\Docs (Remote 'D/Docs') -> NewConfig has no pair Docs and a PrivatePaths entry
    # @{Path=<root>\Docs; Name='Docs'}; OldRemote -eq 'pikpak:PC-Mirror/D/Docs'; NewKind 'private'
}
It 'plans encrypted to synced with a new pair' { # OldRemote -eq 'private:Docs'; NewConfig.Pairs has the New-MirrorPair entry }
It 'plans encrypted to synced inside a synced folder without a new pair' { # Note not null; pair count unchanged }
It 'refuses a folder that is not of the old kind' { }
It 'refuses to plan a purge of a root' {
    # pair with Remote 'D' is fine ('pikpak:PC-Mirror/D'); a hand-made item whose OldRemote would be
    # 'pikpak:PC-Mirror', 'pikpak:PC-Holding', 'private:_holding' or 'private:' throws
}
It 'changes nothing when the last sync fails' {
    # responder: the bisync of Docs exits 1 -> Changed $false; config file bytes unchanged; no 'purge' call;
    # state.Pairs still has 'Docs'
}
It 'changes nothing when a sync is already running (lock held)' { }
It 'changes nothing when today''s transfer limit is reached' { }
It 'switches, forgets the old state, purges the old copy and syncs the new form' {
    # -DeleteOldCopy: calls in order: bisync of the old form; purge 'pikpak:PC-Mirror/D/Docs';
    # sentinel copy + bisync --resync to 'private:Docs'. State has no 'Docs', has 'private:Docs'.
    # Old filter file gone. OldCopyDeleted $true.
}
It 'keeps the old copy when not asked to delete it' { # no purge call; Message names 'pikpak:PC-Mirror/D/Docs' }
It 'reports a failed purge without undoing the change' { # purge exits 1 -> Changed $true, OldCopyDeleted $false }
It 'touches only the changed folder when a folder of the other kind has the same name' {
    # pair Docs and encrypted Docs at different paths; change the pair to encrypted (new name 'Docs (2)'):
    # state.Pairs['private:Docs'] untouched, its filter file untouched, purge target is the pair's remote
}
It 'starts clean when a folder is changed and changed back' {
    # to encrypted then to plain: the last run syncs 'pikpak:PC-Mirror/D/Docs' with --resync (state was forgotten)
}
It 'leaves a valid config and state if it stops right after the switch' {
    # run steps 1-3 only (mock the purge to throw a terminating error): Test-MirrorConfig on the saved
    # config returns no errors; a following Invoke-MirrorRun resyncs the new form
}
# Run.Tests.ps1
It 'syncs only the listed folders' {
    # three folders, -OnlyFolders 'private:B': one bisync call (B); state of A and C unchanged; no prune call
}
```

- [ ] **Step 2:** Run them; they fail.
- [ ] **Step 3:** Implement. `Invoke-MirrorRun -OnlyFolders` filters the ordered folder list before the loop and skips the prune and stale steps; with an empty list nothing changes for any caller.
- [ ] **Step 4:** Suite passes.
- [ ] **Step 5:** Commit `feat(engine): change a folder between synced and encrypted`.

---

### Task 2: App actions, Home box and row menus, docs

**Files:** `scripts\lib\GuiActions.ps1`, `gui\ui\app.js`, `gui\ui\settings.js`, `gui\ui\index.html`, `gui\ui\app.css`, `gui\src-tauri\src\bridge.rs` (action tables), `tests\GuiAction.Tests.ps1`, `docs\README.md`

**Interfaces:**
- Consumes: `Get-FolderConversionPlan`, `scripts\Convert-Folder.ps1` (Task 1); existing `private.add`, `private.remove`, `private.review`, `folders.size`, `Get-HeadlessPowerShellArgument`, `Start-GuiDetached`, `Assert-GuiNotSyncing`.
- Produces:
  - `folders.add` accepts `encrypted` (bool, default false). True: same result as `private.add` for that path (all its refusals apply) and returns the same shape as today plus `encrypted = $true`.
  - New action `folders.convert` with `path`, `to` (`'encrypted'` | `'plain'`), `deleteOldCopy` (bool): validates with `Get-FolderConversionPlan` (a refusal becomes error code `refused` with the plan's message), refuses while a sync runs (`Assert-GuiNotSyncing`) and while syncing is paused by a transfer limit (the existing pause check), then starts `Convert-Folder.ps1` detached and returns `@{ started = $true }`. Preview: starts nothing, returns `preview` lines (what would be switched, the old copy path, whether it would be deleted).
  - New action `folders.convertReview` with `path`, `to`: returns `@{ name; path; sizeGB; oldRemote; note }` for the confirm box (no change, works in preview).

- [ ] **Step 1: Write the failing tests** (`tests\GuiAction.Tests.ps1`):

```powershell
It 'folders.add with encrypted adds an encrypted folder, not a pair' { }
It 'folders.add without the flag still adds a pair' { }
It 'folders.convert starts the job with the right arguments' {
    # mock Start-GuiDetached: the line ends with Convert-Folder.ps1 ... -Path "<path>" -To encrypted -DeleteOldCopy
    # and has no -DeleteOldCopy when deleteOldCopy is false; a path with spaces is quoted
}
It 'folders.convert refuses what the plan refuses, and starts nothing' { }
It 'folders.convert refuses while a sync runs and while syncing is paused by a limit' { }
It 'folders.convert in preview starts nothing and lists what it would do' { }
It 'folders.convertReview returns the old copy path and the size' { }
```

- [ ] **Step 2:** Run; they fail.
- [ ] **Step 3: Implement.**
  - Home, `Add a folder`: after the folder picker, a box with the path, the size (`folders.size`), the checkbox **Encrypt this folder** with the line "PikPak can't read it. Another app needs your recovery key to open the files.", buttons **Cancel** and **Add folder**. Unticked: today's behaviour. Ticked: `folders.add` with `encrypted: true`; when no recovery key exists yet the existing refusal message is shown.
  - Home, folder rows: a menu on every row. Synced folder: **Make encrypted**, **Stop syncing**. Encrypted folder: **Remove encryption**, **Stop syncing** (calls `private.remove`, with a confirm box in the wording of the synced folder's "Stop syncing": nothing is deleted on the PC or in PikPak).
  - Confirm box of a change (data from `folders.convertReview`): title "Make <Name> encrypted?" / "Remove encryption from <Name>?"; lines: what PikPak can read afterwards; "The folder is uploaded again (<size>). That counts toward your daily transfer limit."; the `note` when present; a ticked checkbox **Delete the old copy from PikPak** with "It goes to PikPak's trash. Empty the trash there to remove it for good."; buttons **Cancel** and **Make encrypted** / **Remove encryption**. After starting: "Changing <Name>. This runs in the background; you get a notification when it is done."
  - Settings, "Add encrypted folder": when the picked folder is already a synced folder, use the same confirm box and `folders.convert`; otherwise unchanged.
  - `bridge.rs`: add the two actions to the tables (`folders.convert` is a write action).
  - `docs\README.md`: in "Adding a folder" describe the checkbox; add a short section "Changing a folder between synced and encrypted" (what happens, the old copy and PikPak's trash, the re-upload and the daily limit, that a failed last sync changes nothing); update the sentences that say encryption is chosen in Settings only.
- [ ] **Step 4:** Suite passes; `cargo test` in `gui\src-tauri` passes; `node --check` on the changed JS files.
- [ ] **Step 5:** Commit `feat(app): choose encryption when adding a folder, change a folder's kind from Home`.
