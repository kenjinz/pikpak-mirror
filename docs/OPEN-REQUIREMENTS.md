# PikPak Sync: open requirements

As of 2026-11-16. The app is live on the free account; the branch `feat/sync-focus` (folder sync only, two-way
encrypted folders, hourly sync) is built and tested but **not merged yet**. See [HANDOFF.md](HANDOFF.md).

This list holds what is not built yet (R) and what is built but not yet confirmed on the live install (V).
When live checks or tests run, keep the files tiny (1 MB at most each), because the free account's quota is small.
Numbers are kept from earlier versions of this list; R4 and V5 no longer exist (they belonged to features that were removed).

## Not implemented

| # | Requirement | Why | Priority |
|---|---|---|---|
| R1 | **Full go-live on Premium.** Switch the commented-out pairs back on in `config\mirror.config.psd1` and set `DailyBudgetGB = 8` and `MonthlyBudgetGB = 230`. | Blocked: needs PikPak Premium (about 870 GB of data, 6 GiB free storage). | High, when Premium is available |
| R2 | **Storage-space check.** Before uploading, read free space (`rclone about`). Notify at about 90% full, and stop uploads before PikPak is full. | The app tracks the *transfer* limits but not *storage*. On 6 GiB, a full account makes every upload fail with a generic error. | High while on the free account |
| R3 | **Space held by trash and stubs.** Find out why "Used" stayed at 5.2 GiB after the 3.4 GiB test folder was deleted, then make the 30-day holding cleanup actually free space. | `--pikpak-use-trash=false` did not keep deleted files out of PikPak's trash listing. Hidden unfinished uploads may also hold space. Otherwise the holding cleanup frees nothing. | High while on the free account |
| R5 | **PikPak MCP** (optional), so Claude can look into PikPak directly. | Needs the MCP address from PikPak *Settings → Access & Integrations → MCP*. | Low |
| R6 | **Small deferred code issues.** These are listed in [dev-ledger.md](superpowers/notes/dev-ledger.md) as "minor (deferred)" and "parked". | None blocks use. All fail safe. | Low |

### Desktop app (not built)

| # | Requirement | Why | Priority |
|---|---|---|---|
| R7 | **"I deleted them on purpose" button** for the delete safety stop. | Repair (the "bring them back" part) is in the app. Deleting on purpose still means raising `MaxDeletePercent` for one sync (Settings, Advanced) and setting it back. | Medium |
| R12 | **Apply deletes once.** For a folder stopped by the delete safety stop (more than 10% would be deleted), a way to let that one sync carry out the deletes. Not built; waiting for the owner's decision. | The owner may delete many encrypted files in a second app. Today the only ways are Repair, which brings the files back, or raising the percentage in Settings, Advanced for one sync and setting it back. | Medium, waiting for the owner's decision |
| R8 | **Restoring encrypted files from the app.** | **Covered.** An encrypted folder is brought back with **Repair**, and files deleted from it are in **Get back a deleted file**. Still to confirm live: V12 to V14. | Done, pending live check |
| R9 | **Change account / sign out**, and **remove the app** from Settings. | Needs a safe way to change the rclone remotes and tasks. Use `rclone config` and README "Remove everything". | Low |
| R10 | **A real installer for other PCs.** | `cargo tauri build` makes an installer, but setting up a second PC is untested and needs a spare account or a VM. | Low |
| R11 | **Linux and macOS.** | The engine is Windows PowerShell 5.1 only. | Low |

(R2, the storage-full check, also belongs here: the app cannot warn about a full account either.)

## Built, not yet confirmed live

"Built" means the automated tests cover it. "Confirmed" means it was seen working on this PC with the real PikPak
account. The checks V10 to V23 need the branch merged to `main` and the app built there first (HANDOFF.md, "After
you merge to main").

| # | Check | How to confirm |
|---|---|---|
| V1 | The scheduled sync runs by itself | Look at `Get-Status.ps1` a day later: `LastSuccess` is recent. (V10 replaces the old nightly wording.) |
| V2 | Log off and on again: a sync starts about 15 min later | Log off and on, then check `Get-Status.ps1` after 20 min |
| V3 | Each notification fires once per change; a lasting problem notifies once a day at most | Wait until a problem happens; the automated tests cover the logic. See also V12. |
| V4 | On the live install: PikPak-side delete, edit, rename, conflict | 1 KB files in `Documents`. All passed on the Part 3 test setup |
| V6 | Upload from the PikPak phone app arrives on the PC | Upload a small photo into `PC-Mirror/C-Users/Documents` from the app, then sync |
| V7 | Restoring on a new PC with the saved password and salt | Follow [RECOVERY.md](RECOVERY.md) on a second PC or a VM |
| V8 | Daily limit stop on the live config (1 GB a day) | See V11 |
| V9 | The desktop app on the live install (after the merge) | Run the checklist "After you merge to main" in [HANDOFF.md](HANDOFF.md) |
| V10 | **Hourly schedule.** After the merge, the task `PikPakMirror-Sync` is registered with the hourly trigger and runs by itself. | `(Get-ScheduledTask PikPakMirror-Sync).Triggers | Format-List *` shows a trigger with `Repetition` and an `Interval` of `PT1H` (every 1 hour); after a full hour `Get-Status.ps1` shows a newer `LastRun`, with nobody pressing Sync now |
| V11 | **Daily limit stop.** When today's limit (1 GB) is used up, the next syncs of the day pause quietly and continue the next day. | Use a test folder with more than the limit (or set `DailyBudgetGB` low for a moment). Home says "Today's transfer limit is reached", no notification appears, the log says "today's transfer budget is used up", and the next day it carries on |
| V12 | **Notify once.** The same unsolved problem notifies once, not at every sync. | Make a problem (for example a folder whose path is missing), run two syncs: one notification, the second sync only writes "Notify (already shown today)" to the log |
| V13 | **Encrypted folder, two-way, on the live install**, including a delete made directly in PikPak by another app. | New small encrypted folder: PikPak shows only scrambled names; delete a scrambled file in `PikPak/PC-Private/` (the way a second app would); after the next sync it is gone from the PC and listed in **Get back a deleted file**; restore it, and the next sync uploads it |
| V14 | **Repair of an emptied encrypted folder.** | Empty the encrypted test folder on the PC, run a sync (it stops with "the PC folder is empty"), press **Repair**: the files come back and nothing is deleted in PikPak |
| V15 | **The one-time cleanup on this PC.** The old drives are stopped, the task `PikPakMirror-Mount` and the right-click menu entry are gone, the sync task has the new schedule. | Start the app once (or run `Install.ps1`). `Get-ScheduledTask PikPakMirror-Mount` finds nothing, `P:` and `Q:` are gone from Explorer, no right-click **Offload** entry, and today's log lists what the cleanup did |
| V16 | **The old autostart entry moves.** An old "PikPak Backup" start-with-Windows entry becomes "PikPak Sync". | After the first start of the new app, **Settings** shows "Start PikPak Sync when I sign in to Windows" switched on (if it was on before); the log says "autostart migration: moved the old PikPak Backup entry to PikPak Sync" |
| V17 | **First two-way run of the existing encrypted folder** (`PrivateMock`, which until now was uploaded one-way). | The first run after the merge is a merge of both sides: nothing changes on either side, and the folder shows **Up to date** |
| V18 | **A synced folder, two-way, on the live install** with a file deleted on the PC. | The deleted file is in **Get back a deleted file** and restores |
| V19 | **Pause and resume a folder.** | Pause a test folder (under 1 MB) on Home: it turns grey with **Resume**; add a file on the PC and run a sync: the file is not uploaded and nothing is reported. **Resume**, sync: the file goes up, and it was a normal sync, not a merge |
| V20 | **Move an encrypted folder and Locate it.** | Move a small encrypted test folder (under 1 MB) to another place in Explorer: Home shows **Folder not found** and **Locate...**. Pick the new place and confirm: the first sync is a merge and the transferred bytes in the log are about zero (nothing re-uploaded) |
| V21 | **A copied folder (same-ID box).** | Copy a small test folder (under 1 MB) in Explorer and add the copy: the same-ID box appears. **Give a new ID** adds it as its own folder; the original is unchanged |
| V22 | **Stop syncing an encrypted folder, then reconnect it.** | Use a small encrypted test folder (under 1 MB): **Stop syncing**. **Settings**, **Encrypted folders in PikPak**, **Show**: it says **Not connected**. **Reconnect...** to an empty folder: the files download and the folder is back on Home with its old name |
| V23 | **Delete a not-connected folder from PikPak.** | Stop syncing a small encrypted test folder (under 1 MB), then **Delete from PikPak** in the same list and confirm: it is gone from the list and in PikPak's trash; the other encrypted folders and `_holding` are untouched |
| V24 | **Remove encryption from a folder inside a synced folder.** | Use a small encrypted test folder (under 1 MB) inside a synced folder: **Remove encryption** on its row. After the job, its `.pikpak-encrypted.json` is gone on the PC and, after the next sync of the synced folder, the files appear readable in PikPak under that synced folder |

## Known limits (accepted, not planned)

- PikPak reports no file times. When a file was changed on both sides, the PC's version keeps the name and the other one is saved as `.conflict1`.
- An edit made in PikPak that keeps the exact same file size is not detected.
- A new file is safe in PikPak only after the sync that uploaded it (up to the sync interval).
- An upload killed by a power cut can leave a hidden stub that blocks that one file name in PikPak, and PikPak does not clear it by itself. The fix is to rename the file on the PC (README "Stuck uploads").
- Files deleted in PikPak are kept 30 days on this PC only; they are lost with its disk. For encrypted folders those PC-side copies are readable, not encrypted.
- `D:\PrivateMock` is mock data. Replace it with real files you want encrypted, then confirm again (the app does this when you add the folder).
