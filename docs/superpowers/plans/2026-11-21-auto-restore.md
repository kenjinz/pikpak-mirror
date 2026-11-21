# Automatic restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When PikPak holds a folder list backup, a fresh install restores it right after sign-in (and the key step) with no list to confirm, creating missing folders on present drives so the first sync downloads them.

**Architecture:** Engine: `setup.finish` with `restore` gains a `Restored folders` step (after `Settings`) that creates each restored folder's directory when its drive exists, and its result carries a `restored` summary. UI: `restore.js` skips the *Found your folders* list when the rows come from a backup and goes straight to the Done screen, with a "Set up from scratch instead" link while restoring; the Done screen shows the summary. The scan (no backup) path keeps the list.

**Tech Stack:** Windows PowerShell 5.1, Pester 5.7.1, Tauri 2 plain-JS UI.

**Spec:** `docs/superpowers/specs/2026-11-21-auto-restore-design.md` (amends `2026-11-21-folder-list-backup-design.md`). Read both. The spec wins over this plan.

## Global Constraints

- Windows PowerShell 5.1 only: no `?:`, `??`, `?.`, `&&`/`||`, `-AsHashtable`. Script files stay ASCII.
- Never create a folder on a drive that does not exist; never delete anything; preview mode creates nothing.
- Restored folders keep `Id`, `Remote`, `Name`, `Paused`, `PausedForKey` exactly as the existing restore sets them; the pause rule for synced folders holding encrypted folders is unchanged.
- The key is never logged or kept; the key screen and its rules are unchanged.
- Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1` (`-Filter`). Baseline recorded in Task 0. No network, no real rclone, no app launch (the live app runs from a copy outside the repo with `%LOCALAPPDATA%\PikPakSync`).
- Work only in `G:\pikpak-mirror\.worktrees\auto-restore` (branch `auto-restore`). One commit per task, `type(scope): summary`, ending with a blank line and `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not push.

## Review Focus

1. A restored folder on a missing drive: no folder created, no error, step still done, and it is named in the summary. Test in Task 1.
2. A restored folder whose path exists as a FILE: not touched, reported as a problem line, setup continues. Test in Task 1.
3. Resume after a partial restore (config already written): the `Restored folders` step runs again on resume and is idempotent. Test in Task 1.
4. Backup with zero folders: no auto restore of nothing — goes to *Choose folders* as today. Static walk in Task 2.
5. The user presses "Set up from scratch instead" while discover/key is running: no `setup.finish` with `restore` is sent. Static walk in Task 2.

---

### Task 0: Baseline

- [ ] **Step 1:** Run the suite and `cargo test` in `gui\src-tauri`; note the counts in the ledger.

### Task 1: Engine — create restored folders, report a summary

**Files:**
- Modify: `scripts\lib\GuiBackup.ps1`, `scripts\lib\GuiActions.ps1` (`Invoke-GuiActionSetupFinish`: the step, and the resume path), `tests\GuiAction.Tests.ps1`

**Interfaces (produces):**
- `New-GuiRestoredFolders -Config <loaded config> [-WhatIf]` → `@{ Done = $true; Message; Created = @(paths); DriveMissing = @(@{ Name; Path }); Problems = @(@{ Name; Path; Reason }) }`. For every `Pairs` and `PrivatePaths` entry: path exists as a folder → nothing; drive root missing → `DriveMissing`; path exists as a file or creation throws → `Problems` (never throws); else `New-Item -ItemType Directory` (under `-WhatIf`: no creation, message "Would create …").
- `setup.finish` with `restore`: new step `Restored folders` right after `Settings` and before the install steps; also run on `resume` when the saved config came from a restore (detect: any entry has an `Id` and the config has no folders' directories — simplest: always run it on resume; it is idempotent). The result gains `restored = @{ count = <Pairs + PrivatePaths>; saved = <backup Saved, passed in restore args as `saved`, may be empty>; driveMissing = @(names); pausedForKey = @(names); problems = @(@{ name; reason }) }` when `restore` was given (or on resume, from the config).

- [ ] **Step 1: Write the failing tests:** `It 'finish with restore creates missing folders on present drives'` (TestDrive paths); `It 'finish with restore does not create folders on a missing drive and names them'` (use a drive letter that does not exist, found at test time); `It 'finish with restore reports a path that is a file and still completes'`; `It 'resume runs the restored folders step again without errors'`; `It 'finish with restore under preview creates nothing'`; `It 'finish with restore returns the restored summary'` (count, driveMissing, pausedForKey names).
- [ ] **Step 2:** Filtered tests FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Filtered tests PASS; full suite passes.
- [ ] **Step 5:** Commit `feat(setup): create restored folders and report what was restored`.

### Task 2: UI — restore automatically when a backup is found

**Files:**
- Modify: `gui\ui\restore.js`, `gui\ui\setup.js`, `gui\ui\index.html` (only if a new element is needed)

**Interfaces:**
- Consumes: Task 1's `restored` summary in `setup.finish`'s answer.
- Behaviour:
  - `afterKey()`: when the rows come from a backup (`!rs.fromScan`) and there is at least one row, every row is chosen (including `DriveMissing` rows, at `Resolved.Path`; encrypted rows only when the key was given), `rs.active = true`, and setup goes to `done` (which runs `setup.finish` with `restoreArg()`), without showing the list. Pass the backup's `Saved` as `restore.saved`.
  - While discover / key check / existing-key run, the restoring screen shows "Restoring your folders from PikPak…" and a quiet link **Set up from scratch instead** → the existing Start-fresh confirmation → *Choose folders*. Once `setup.finish` has started, the link is gone.
  - The scan path (no backup) is unchanged: the list with ticks and **Restore**.
  - Done screen, when `restored` is present: lead "Restored N folders from your backup of <local date>." (or "Restored N folders from your backup." when `saved` is empty); then, when not empty, "Waiting for a drive: <names>." , "Paused until you enter your recovery key: <names>." and one line per problem "<name>: <reason>". `firstSyncSentence` during a restore: "Your folders come down from PikPak over the first syncs. After that, it runs every hour while your PC is on." (no size — sizes are no longer fetched).
  - Drop the `setup.sizes` call on the auto path.
- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `node --check` each changed module (copy to `.mjs` if needed); write a static walk of: backup + key on PC; backup + key asked; backup + key skipped; backup with a missing drive; no backup (scan list); Set up from scratch during discover; zero-folder backup.
- [ ] **Step 3:** Suite and `cargo test` pass.
- [ ] **Step 4:** Commit `feat(ui): restore automatically after sign-in when a backup is found`.

### Task 3: Docs

**Files:**
- Modify: `docs/RECOVERY.md` (section 2: the restore is automatic when the backup is found; only the key may be asked; missing drives wait on Home), `README.md` (the "Your folder list is backed up" paragraph), `docs/OPEN-REQUIREMENTS.md` (V25 wording: no list, automatic)
- [ ] **Step 1:** Update; repo is public, no personal names.
- [ ] **Step 2:** Commit `docs: the restore after sign-in is automatic`.
