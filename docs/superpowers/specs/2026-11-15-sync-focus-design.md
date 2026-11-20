# PikPak Sync: narrow the app to folder sync

Date: 2026-11-15. Status: design, waiting for approval.

## Intent

The app grew into a general PikPak client: drive letters, a cloud-only Archive, a viewer mode for a second PC.
The owner wants one thing from it: **add a folder, and the app keeps that folder the same on the PC and in
PikPak, in both directions, by itself.** Some folders are sensitive and must be encrypted before they leave the PC.
Everything that does not serve that goes.

Who it is for: one person, one Windows PC, a free PikPak account today (6 GiB, about 5 GB/day for connected
apps), possibly Premium later.

## Goals

1. Two kinds of folders, nothing else:
   - **Synced folder**: two-way with `PikPak/PC-Mirror/...`. A file added, changed or deleted on either side
     reaches the other side.
   - **Encrypted folder**: also two-way, but through the encrypted remote. PikPak sees only scrambled names
     and content. Another app that holds the same key can show, add and delete files there, and those
     changes reach the PC.
2. Syncing happens often enough to feel automatic: every hour by default.
3. A 30-day safety net for deleted and overwritten files stays, for both kinds of folder.
4. A lost encrypted folder can be brought back from the app, without a drive letter.
5. Less code: the drive layer, Offload/Archive, the viewer role and the unmapped-folder watcher are deleted,
   with their tests and docs.
6. The app calls itself a sync app: **PikPak Sync**.

## Non-goals

- Real version history (several old versions per file). The 30-day holding area is the only safety net.
- Instant sync (file watchers, PikPak change events). Hourly polling is enough.
- Browsing PikPak or single encrypted files in File Explorer.
- A second PC, Linux, macOS, an installer for other PCs.
- Rewriting the engine. It stays PowerShell 5.1 + rclone bisync, with the Tauri app on top.
- Removing the command-line scripts that still serve sync (`Install.ps1`, `Invoke-Sync.ps1`, `Get-Status.ps1`,
  `Confirm-PrivatePaths.ps1`). They share code with the app and the scheduled task needs `Invoke-Sync.ps1`.

## Anti-goals

- Losing a file because of this cleanup. Nothing in PikPak is deleted by the migration, including the existing
  `Archive/` folder.
- Uploading an encrypted folder's content in plain form. A restore must never land inside a synced folder.
- Going over PikPak's daily or monthly transfer limit because the sync now runs 24 times a day.
- A notification every hour for the same unsolved problem.

## Constraints

- Windows PowerShell 5.1; script files stay ASCII (existing rule).
- The live install must keep working: same `state.json`, same rclone remotes (`pikpak`, `private`), same
  remote layout (`PC-Mirror`, `PC-Holding`, `private:<Name>`, `private:_holding`), same scheduled-task name
  `PikPakMirror-Sync`, same state folder `%LOCALAPPDATA%\PikPakMirror`.
- Live tests use files of 1 MB at most (free account).
- PikPak reports no file times; changes made in PikPak are noticed by size (known limit, unchanged).

## Approaches considered

The cleanup itself has one sensible shape (delete the features, keep the sync core). The real choice was how
encrypted files are reached once the drives are gone:

- **A. Remove both drives; add Restore for encrypted folders in the app.** Removes WinFsp, the mount task and
  the 20 GB cache. Costs one new app action. No Explorer browsing of single encrypted files.
- **B. Keep `Q:` only.** Keeps Explorer browsing, but also keeps about half of the drive code for one read-only
  drive.
- **C. Remove both drives; restore by `rclone copy` command only.** Least code; awkward for anything but an
  emergency.

**Chosen: A** (owner's decision, 2026-11-15). It removes the whole drive layer and still gives a button for the
one job `Q:` did.

**Revised the same day.** The owner manages encrypted images from a second app that has the key, and deletes
images there. Those deletes must reach the PC. So encrypted folders become two-way, and that makes a separate
Restore feature unnecessary: an encrypted folder is brought back with the same **Repair** that synced folders
already have. Approach A stands (no drives, restore from the app); only its mechanism changed.

## Decided by the owner

- Keep encryption for chosen folders.
- Approach A above.
- The app is a sync app, not a backup app.
- Encrypted folders sync in both directions; changes made by another app with the key reach the PC.

## Design (my calls unless marked)

### 1. What is removed

| Feature | Code to delete (starting points) |
|---|---|
| Drives `P:` / `Q:` | `scripts\Start-Mount.ps1`; `New-MountArgs`; mount helpers in `lib\Setup.ps1` (`Get-MountDriveLetter`, `New-MountProcessArgs`, `Invoke-MountAttempts`, the `Mount` kind of `New-MirrorTaskSpec`); `Install-MirrorWinFsp`, `Test-WinFspInstalled`; the Mount task in `Register-MirrorTasks`; GUI actions `mount.get/set/start`, `Stop-GuiMounts`, `Test-GuiDrive`; the "File Explorer" block in Settings; the "Open my backup in File Explorer" shortcut; the drive note on the setup "done" screen; config key `CacheDir` and its Advanced field. |
| Offload / Archive | `scripts\Move-ToArchive.ps1`; `lib\Archive.ps1`; `New-ArchiveMoveArgs`; `New-ContextMenuEntries`; `Register-MirrorOffloadMenu`; GUI action `offload`; the Offload screen and its shortcut; config key `ArchiveRoot`; the reserved pair name `_archive` and the `_archive` holding case; `tests\Archive.Tests.ps1`. |
| Viewer role | `-Role Viewer` in `Install.ps1`. |
| Unmapped-folder watcher | `Find-UnmappedFolders`; step 8 of `Invoke-MirrorRun`; `NotifiedUnmapped` in state; config keys `WatchRoots`, `IgnoredFolders`; the "Not backed up yet" block on Home; the unmapped part of `Get-Status`. The setup screen's folder *suggestions* stay. |

Anything else that only exists for these features (Rust bridge commands, capabilities, CSS, tests) goes with
them. The builder finds the full list by search; the table is the starting point.

**Old config keys** (`ArchiveRoot`, `CacheDir`, `WatchRoots`, `IgnoredFolders`) must not be an error when they
are still in a config file. They are ignored on load and dropped the next time the app saves the config. The
shipped `config\mirror.config.psd1` is edited to remove them.

### 2. What stays unchanged

Bisync per pair with its flags, the delete safety stop (`MaxDeletePercent`), conflict handling, stuck-upload
handling, repair (`-Resync`), the holding areas and their 30-day prune, filters, the private-paths confirmation,
the recovery key, logs, the lock, the monthly budget, the evening bandwidth limit, the tray, setup, the
deleted-files screen.

### 3. Sync every hour

- New config key `SyncIntervalMinutes` (whole number, default `60` when the key is missing; allowed values
  15, 30, 60, 180, 360, or `0`).
  - Above 0: the `PikPakMirror-Sync` task repeats at that interval all day, and still runs 15 minutes after
    logon when `SyncAtLogon` is true.
  - `0`: once a day at `SyncTime`, as today.
- Settings: "When to back up" becomes **"How often to sync"** with the choices: every 15 minutes, every 30
  minutes, every hour, every 3 hours, every 6 hours, once a day. "Once a day" shows the existing time picker.
- Runs never overlap (existing lock and `MultipleInstances = IgnoreNew`).
- **Budget becomes per day, not per run.** With 24 runs a day, a per-run cap of 1 GB would allow 24 GB/day.
  - New config key `DailyBudgetGB`. When it is missing, the value of the old `RunBudgetGB` is used, so the live
    config keeps its meaning (1 GB a day). `RunBudgetGB` is no longer written by the app.
  - `state.json` tracks the bytes transferred today, next to the existing monthly count. Each run may transfer
    `min(left today, left this month)`.
  - When today's budget is used up, runs are skipped quietly until the next day (logged, no notification; the
    Home screen says so). The monthly rules are unchanged.
  - Settings, Advanced: "Upload limit per evening (GB)" becomes "Transfer limit per day (GB)".
- **No repeated notifications.** A problem that is still there at the next run (same folder, same kind of
  problem) does not notify again. It notifies again when it comes back after having been solved, or once a day
  at most while it lasts. The Home screen always shows the current problems. The builder checks every
  `Send-MirrorToast` call in `Invoke-MirrorRun` against this rule; some already follow it.
- The "no successful backup for N days" check keeps working with hourly runs.

### 4. Encrypted folders

An encrypted folder becomes **a synced folder whose PikPak side is the encrypted remote**. It runs through the
same code path as a synced folder, not a separate one.

- Each `PrivatePaths` entry is synced with `rclone bisync <Path> private:<Name>`, with the same flags as a
  synced folder (`New-BisyncArgs`), and:
  - `--backup-dir1` = `<LocalHolding>\<date>\<holding name>` (files deleted or replaced from the PikPak side,
    kept on the PC, readable);
  - `--backup-dir2` = `private:_holding/<date>/<Name>` (files deleted or replaced from the PC side, kept in
    PikPak, encrypted). This is the location the one-way sync already uses.
- Everything a synced folder has applies: first-run and changed-mapping resync, the `RCLONE_TEST` sentinel,
  the delete safety stop, conflicts (`.conflictN`, PC wins), stuck uploads, Repair, the per-pair state in
  `state.json`, the budget.
- The one-way path (`New-PrivateSyncArgs` and step 5 of `Invoke-MirrorRun`) is deleted.
- Encrypted folders run before synced folders in a run, as today.
- The state entry and the local holding folder of an encrypted folder must not collide with a synced folder
  of the same name (a synced `Documents` and an encrypted `Documents` are both legal today). The builder picks
  the scheme (for example a `private:` prefix in state and a `_private\<Name>` folder in local holding).
- **Live install.** The existing `private:PrivateMock` already matches the PC folder. Its first two-way run
  is a resync (merge), which changes nothing.
- In the app they are called **Encrypted folders** (was "Private folders"). Config key `PrivatePaths`, the
  confirmation step and the recovery key keep their names and behaviour.
- **Getting a lost encrypted folder back.** No separate Restore feature. When the PC folder is empty or was
  recreated, the sync stops for that folder ("the PC folder is empty", existing behaviour) and the user presses
  **Repair** on it, which merges both sides and so downloads everything. If the daily budget stops it, it
  continues at the next run by itself (existing behaviour). On a new PC: set up with the recovery key, add the
  encrypted folder at the wanted place, Repair. The builder confirms on the live account, with tiny files,
  that Repair into an empty folder downloads the content and deletes nothing; if rclone refuses an empty
  folder there, the app creates the folder with the sentinel file first.
- **Deleted encrypted files** appear on the deleted-files screen from both sides:
  - deleted in PikPak (by the other app): in the local holding folder, source `pc`, as for synced folders;
  - deleted on the PC: `private:_holding/<date>/<Name>/...`, a third source next to `pc` and `cloud`.
  Restoring one puts it back in the encrypted folder on the PC with the same never-overwrite rule as today;
  the next sync uploads it again. If listing the encrypted remote fails, the screen shows the other sources
  and a warning, as it already does for the cloud source.
- The footer text on that screen about `Q:` and `P:\Archive` is removed.
- **Second app.** It must use rclone's crypt format with the same password and salt, and work under
  `PC-Private/`. That is the owner's responsibility; the README says so.
- **First build step: a live check** that bisync against the crypt remote on PikPak behaves like the plain
  pairs (add, delete and rename on each side; a delete made directly in `PC-Private` as the second app would do
  it). If it does not, stop and report before building the rest.

### 5. Name and wording

- Visible name becomes **PikPak Sync**: window title, app bar, tray, notification title, Tauri `productName`,
  Start-menu shortcut. "Back up now" becomes "Sync now", "Backed-up folders" becomes "Synced folders",
  "Checking your backup" becomes "Checking your folders", and so on through the UI and the notifications.
- The welcome screen says what the app does now: two-way sync, every hour, deleted files kept 30 days,
  encrypted folders.
- **Kept as they are**, to avoid a migration: the Tauri `identifier`, the env var `PIKPAK_BACKUP_REPO`, the
  task name `PikPakMirror-Sync`, the state folder, the repo name, the remote folder names.
- The "Open my backup in File Explorer" shortcut is replaced by **"Open PikPak in my browser"**
  (`https://mypikpak.com/drive`).
- If changing `productName` changes the exe name or leaves the old autostart entry or Start-menu shortcut
  behind, the builder handles it: the old entry is removed or the new app takes it over, and the README says
  which exe to run.

### 6. Migration of the live install

A one-time, repeatable cleanup step, run by `Install.ps1` and by the app at start-up (whichever comes first;
each part is skipped when already done):

1. Unmount `P:` and `Q:` (stop the rclone mount processes only, never a running sync).
2. Unregister the task `PikPakMirror-Mount`.
3. Remove the two `PikPakOffload` registry keys under `HKCU:\Software\Classes`.
4. Re-register `PikPakMirror-Sync` with the hourly trigger, keeping its enabled or disabled state.

Left alone, and listed in the README for the owner to do by hand if wanted:

- WinFsp stays installed (uninstall in Windows Settings).
- The cache folder `D:\.pikpak-cache` is not deleted automatically (delete it by hand).
- `PikPak/Archive/` in the cloud is not touched.

### 7. Docs

- `docs\README.md` rewritten around the two folder kinds, hourly sync, restore, and the hand cleanup above.
- `docs\RECOVERY.md`: the `Q:` steps are replaced by Repair in the app and the `rclone copy` command.
- `docs\OPEN-REQUIREMENTS.md`: drop items about drives, Offload and the Archive (R4, V2's drive part, V5);
  mark the encrypted-folder part of R8 as covered by Repair and the deleted-files list; add checks for hourly sync, the daily budget and
  restore.
- `docs\HANDOFF.md` updated. Older specs, plans and ledgers stay as history.

### 8. Tests

- Tests for removed features are deleted with them.
- New or changed behaviour gets Pester tests in the existing style: daily budget and day rollover; the
  `RunBudgetGB` fallback; old config keys ignored; `SyncIntervalMinutes` validation and the task triggers built
  from it; notify-once; encrypted folders going through the bisync path (arguments, holding locations, state
  not colliding with a synced folder of the same name, resync on first run); the third holding source; the
  migration step being repeatable.
- The whole suite (`tests\run.ps1`) passes at the end, except tests that already fail before this work
  (the ledger mentions J3, which fails on purpose on the free account). The builder records the baseline first.
- `cargo tauri build` succeeds.
- Live check on the free account with tiny files: one hourly run happens by itself; a file added in PikPak
  arrives on the PC; a delete on the PC shows in the deleted-files list; a file deleted directly in
  `PC-Private` disappears from the PC and shows in the deleted-files list; Repair brings an emptied encrypted
  folder back and the content matches.

## Left to the builder

- The order of the work and how it is split into commits.
- The exact Task Scheduler trigger for the repetition, and how the app's schedule code reads and writes it.
- Exact UI layout and wording, within section 5.
- How state remembers which problems were already notified.
- Whether `Get-Status.ps1` output needs more than the removals.
