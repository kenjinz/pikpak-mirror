# PikPak Sync: where the project stands and what's next

Last updated 2026-11-16. Read this first when you pick the project up again.

## What changed on the branch `feat/sync-focus` (not merged yet)

The app used to be a general PikPak client: drive letters `P:` and `Q:`, an Archive with right-click "Offload", a
viewer role for a second PC, and warnings about new folders. It is now **PikPak Sync**, which does one thing: keep
folders the same on the PC and in PikPak, in both directions, by itself. Design:
[the spec](superpowers/specs/2026-11-15-sync-focus-design.md). Build log: [the ledger](superpowers/notes/2026-11-15-sync-focus-ledger.md).

- **Two kinds of folder.** Synced folders (two-way with `PikPak/PC-Mirror/...`) and encrypted folders (two-way
  through the encrypted remote `private:`, stored in `PikPak/PC-Private/`). Changes another app makes there, with
  the same key, reach the PC.
- **Every hour by default** (`SyncIntervalMinutes`, Settings: **How often to sync**), plus 15 minutes after logon.
- **Limit per day** (`DailyBudgetGB`) and per month (`MonthlyBudgetGB`). An old `RunBudgetGB` is still read as the
  daily limit. When today's limit is reached, syncing pauses quietly until tomorrow.
- **A lasting problem notifies once a day at most.** Home always shows the current problems.
- **Deleted files kept 30 days**, for both kinds of folder, restored in the app (**Get back a deleted file**).
  Encrypted folders: deleted on the PC, kept encrypted in `private:_holding`; deleted in PikPak, kept readable in
  `<LocalHolding>\<date>\_private\<Name>` on the PC.
- **Repair** (Home, or `scripts\Invoke-Sync.ps1 -Resync "<Name>"` / `-Resync "private:<Name>"`) merges both sides
  and also brings back a lost or emptied folder. The 10% delete safety stop covers both kinds.
- **Removed:** the drives `P:` and `Q:` (and WinFsp as a need), Offload and the Archive feature, the viewer role
  (`Install.ps1 -Role`), the "new folders not synced" warnings, the config keys `ArchiveRoot`, `CacheDir`,
  `WatchRoots`, `IgnoredFolders` (still accepted in an old config, ignored).
- **One-time cleanup**, run by `Install.ps1` and by the app at every start: stops the old drive programs,
  removes the task `PikPakMirror-Mount` and the right-click entry, gives `PikPakMirror-Sync` the new schedule.
  It writes to the log. The app also moves an old "PikPak Backup" start-with-Windows entry to the new name.
- **Names:** the window, tray, notifications and the Start-menu shortcut say **PikPak Sync**. Unchanged on
  purpose: the exe `gui\src-tauri\target\release\pikpak-backup.exe`, the environment variable
  `PIKPAK_BACKUP_REPO`, the task name `PikPakMirror-Sync`, the state folder `%LOCALAPPDATA%\PikPakMirror`.

**Test status:** `tests\run.ps1` passes except `J3` ("shipped config keeps a 20 GB margin"), which fails on purpose
while the config uses the free account's small budget. `cargo test` and `cargo tauri build` pass. Exact counts: the
ledger, "Task 9".

**The live checks on the real install have not been done.** They wait until the branch is merged (below).

## After you merge to main: checklist

These checks could not be done from the branch without touching the live sync. Do them once, after the merge.

1. **Merge when no sync is running** (Home does not say "Syncing"). The branch lives in the worktree
   `G:\pikpak-mirror\.worktrees\sync-focus`.
2. **Build the app** in `G:\pikpak-mirror\gui`:
   ```
   $env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"
   cargo tauri build
   ```
   Never run an exe or installer built in the worktree: it would use the worktree's scripts and config.
3. **Run the cleanup.** Start `G:\pikpak-mirror\gui\src-tauri\target\release\pikpak-backup.exe` once (the cleanup
   runs by itself), **or** run
   `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1` in `G:\pikpak-mirror` (every step
   that is already done prints `[skip]`). If you use the installer of the app, set
   `PIKPAK_BACKUP_REPO=G:\pikpak-mirror` first (README, "The app").
4. **The live checks** (details and how to confirm each one: [OPEN-REQUIREMENTS.md](OPEN-REQUIREMENTS.md), V10 to V18):
   - the hourly schedule is registered and runs by itself (V10);
   - the daily limit stop (V11);
   - notify-once (V12);
   - an encrypted folder two-way on the live install, including a delete made directly in PikPak (V13);
   - Repair of an emptied encrypted folder (V14);
   - the one-time cleanup on this PC (V15);
   - the old autostart entry migration (V16);
   - the first two-way run of the existing encrypted folder `PrivateMock` (V17);
   - a synced folder two-way, with a deleted file restored (V18).

   Use files of a few KB in new check folders, and remove the check folders from the app afterwards. List what
   is left in PikPak for the owner to delete.
5. **Hand cleanup** if you want it (README, "Cleaning up after the old version"): uninstall WinFsp, delete
   `D:\.pikpak-cache`, uninstall an old installed "PikPak Backup" copy. `PikPak/Archive/` is yours to keep or delete.
6. **Tidy the branch:** `git worktree remove G:\pikpak-mirror\.worktrees\sync-focus`, then
   `git branch -d feat/sync-focus`.

## Free and Premium accounts

On a **free account** (6 GiB storage) keep the limits low: `DailyBudgetGB = 1` and `MonthlyBudgetGB = 30` (the
sample config uses them), and keep encrypted test folders small.

With **Premium**, set `DailyBudgetGB = 8` and `MonthlyBudgetGB = 230` in `config\mirror.config.psd1`. The first
upload of a large library then takes months, so list the most important folders first (`Priority`).

**What's left:** see [OPEN-REQUIREMENTS.md](OPEN-REQUIREMENTS.md). It lists what is not built yet and what is not yet confirmed live.

## Things worth knowing (found in testing)

- **Conflicts:** PikPak doesn't report file times to rclone. When a file was changed on both sides, the **PC's version keeps the name** and the other one is kept as `name.conflict1`.
- **Same-size edits:** an edit made in PikPak that keeps the exact same file size is not noticed (rare for photos, music and video).
- **Power loss during an upload** can leave one file name blocked in PikPak. You get a notification naming the file. Rename it on the PC and it uploads at the next sync. A normal Windows shutdown doesn't cause this.
- **Limit overshoot:** a run can go a little over its limit, because files already uploading may finish. The monthly margin (20 GB on Premium) covers that.
- **After a limit stop**, a folder does a full compare at the next sync. A file you deleted during that time can come back once; delete it again.
- **A folder that keeps failing:** Repair in the app, or `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-Sync.ps1 -Resync "<Name>"` (`private:<Name>` for an encrypted folder) merges both sides without deleting anything.
- **A folder with very many small files** (for example 230,679 files) needs about 64 hours of upload for the first copy. PikPak takes about 1 second per small file. It's last in line, so it never holds up other folders.
- **PikPak MCP** (optional): lets Claude look into your PikPak directly. Copy the address from PikPak *Settings → Access & Integrations → MCP* and give it to Claude, which runs `claude mcp add --transport http --scope project pikpak <address>`. Nothing depends on it.
- **Live facts that shaped the code:**
  - rclone reads a bare `--max-transfer` number as KiB, so it must be `<bytes>B`.
  - In bisync a budget cutoff is exit 7 + "must resync", never 8.
  - PikPak reports no modtimes and no MD5.
  - winget has no rclone 1.75.2.
  - bisync works on the crypt remote with the same flags as a plain folder (checked live in Task 0 of the ledger).

## Where everything is

| File | What |
|---|---|
| `docs/README.md` | User guide: the app, the two kinds of folder, daily use, deleted files, limits, cleanup, removal |
| `docs/OPEN-REQUIREMENTS.md` | What is not built yet, and what is not yet confirmed live |
| `docs/RECOVERY.md` | Getting everything back on a new PC (needs the saved recovery key, or the password and salt) |
| `docs/superpowers/specs/2026-11-15-sync-focus-design.md` | The design of this branch |
| `docs/superpowers/notes/2026-11-15-sync-focus-ledger.md` | Build log of this branch: baseline, live check, test and build results |
| `docs/superpowers/` (older specs, plans, ledgers) | History of earlier versions. They still describe drives and Offload; do not follow them for the current app |
| `gui/` | The desktop app code (Tauri). `scripts\Invoke-GuiAction.ps1` is the helper it uses |
| `config/mirror.config.sample.psd1` | Template for your config. The app (or `Install.ps1`) copies it to `config/mirror.config.psd1`, which is yours and is not in the repository |
| `scripts/` | The scripts. `tests/` holds the automated tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1` |

## For a developer continuing the code

- **GitHub:** https://github.com/kenjinz/pikpak-mirror. Commits use GitHub's anonymous noreply address, so no personal email is published.
- **Desktop app:** tests: `cargo test --manifest-path gui/src-tauri/Cargo.toml`, with `%USERPROFILE%\.cargo\bin` on PATH. The app talks to the engine only through `scripts\Invoke-GuiAction.ps1` (JSON on stdin and stdout).
- **Branches:** the engine and the first desktop app are on `main`. This work is on `feat/sync-focus`, not merged.
- **Deferred items:** small known issues are listed in `docs/superpowers/notes/dev-ledger.md` (lines marked "minor (deferred)" and "parked"). None blocks use.
