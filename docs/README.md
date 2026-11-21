# PikPak Sync

Keeps chosen folders on this PC in two-way sync with PikPak. A file you add, change or delete on one side
reaches the other side by itself, every hour. Some folders can be **encrypted**: PikPak then holds only
scrambled files that nobody can read without your key. You only see a Windows notification when something needs
your attention.

All commands below are typed in **PowerShell**, started in the project folder (`G:\pikpak-mirror`). In Explorer:
open the folder, type `powershell` in the address bar, press Enter. If Windows refuses to run a script, put
`powershell -NoProfile -ExecutionPolicy Bypass -File` in front of it, for example
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Get-Status.ps1`.

## The two kinds of folder

| Kind | What happens | Where it is in PikPak |
|---|---|---|
| **Synced folder** | Two-way sync. You can open and use the files in PikPak (web, phone). | `PikPak/PC-Mirror/...` |
| **Encrypted folder** | Two-way sync too, but every file is locked on this PC before it is uploaded. PikPak shows only scrambled names. | `PikPak/PC-Private/`, with scrambled names |

- Both kinds copy changes **in both directions**. If you delete a file on the PC, it is deleted in PikPak (and the
  other way round). A copy is kept for 30 days: see *Getting deleted or overwritten files back*.
- Both kinds skip the same junk files (`config\filters.txt`: temporary files, `Thumbs.db` and so on).
- An encrypted folder needs the **recovery key**. Keep it outside this PC. Without it the encrypted files can
  never be opened, by anyone.

### Another app that uses the encrypted files

Another app can read, add and delete the encrypted files only if **all three** are true:
1. it uses rclone's *crypt* format;
2. it has the **same password and salt** as this PC (the recovery key);
3. it works inside `PikPak/PC-Private/`.

Then a change it makes there (for example a deleted picture) reaches this PC at the next sync. Setting that up
is your job: this app does not manage the other app.

Leave the file `RCLONE_TEST` alone. It appears in every synced and encrypted folder (also in `PC-Private/`), and
the sync uses it to check that the right folder is on both sides. If it is deleted on the PikPak side, that folder
stops syncing until you press **Repair**.

## The app (PikPak Sync)

PikPak Sync is a Windows app that does most of this guide with buttons: it shows whether your folders are in
sync, sets up a new PC, adds and removes folders, pauses syncing, sets how often to sync, repairs a folder, and
brings back deleted files. It uses the same scripts and the same config file as the rest of this guide, so you
can use the app, the commands, or both. Every manual way below still works.

### Download and run (most people)

Download `PikPak-Sync-v<version>-windows-x64.exe` from the **Releases** page of the repository and double-click
it. It is one file: the scripts are inside it, so there is nothing to install and no folder to keep next to it.

- Windows SmartScreen warns about the file because it is not code-signed. Click **More info**, then **Run anyway**.
- It needs the Microsoft WebView2 runtime (Windows 11 and current Windows 10 have it) and, on the first run, internet
  (setup downloads rclone).
- The first time it runs, it unpacks its scripts to `%LOCALAPPDATA%\PikPakSync`. Your settings live in
  `%LOCALAPPDATA%\PikPakSync\config\mirror.config.psd1`; sync state and logs stay in `%LOCALAPPDATA%\PikPakMirror`.
  The scheduled task runs the scripts from `%LOCALAPPDATA%\PikPakSync`, so syncing does not need the downloaded
  `.exe` afterwards. The tray app does: if you switch on **Start PikPak Sync when I sign in to Windows**, Windows
  starts that exact file, so keep it in a permanent place (not Downloads). If you move it later, switch that
  setting off and on again.
- **Update:** quit PikPak Sync from the tray icon (**Quit**), then run the new `.exe`. It replaces the scripts and
  keeps your settings (including an edited `config\filters.txt`). An older `.exe` never replaces the scripts of a
  newer one, so starting an old copy by mistake does no harm to the engine. If start-with-Windows is on, switch it
  off and on again from the new `.exe` so Windows starts the new file.
- **Check the download:** compare `(Get-FileHash .\PikPak-Sync-*.exe -Algorithm SHA256).Hash` with the `.sha256`
  file on the Releases page.
- Which scripts an `.exe` uses, in this order: the folder in `PIKPAK_BACKUP_REPO` if it is set; else the project
  folder above the `.exe` (a build made in the project); else the scripts inside the `.exe`.

### Build it yourself (developers)

**Build it** (once, or after the code changes). Open PowerShell in the project's `gui` folder
(`G:\pikpak-mirror\gui`) and run:

```
$env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"
cargo tauri build
```

This produces:
- the app: `gui\src-tauri\target\release\pikpak-backup.exe`. **This is the file to run.** The name still says
  "backup" on purpose; the window and the tray say PikPak Sync;
- an installer under `gui\src-tauri\target\release\bundle\nsis\`. It adds a **Start-menu shortcut** called
  **PikPak Sync**. The installed copy lives outside the project folder, so it uses the scripts built into it (and
  its own settings in `%LOCALAPPDATA%\PikPakSync`), **unless** the user environment variable `PIKPAK_BACKUP_REPO` is
  set. To make the installed copy use this project folder (your live setup), set it before you start the installed
  app: `[Environment]::SetEnvironmentVariable('PIKPAK_BACKUP_REPO', 'G:\pikpak-mirror', 'User')`

**Start it** from the Start-menu shortcut, or by running `pikpak-backup.exe` from the folder above.

- The `.exe` in `gui\src-tauri\target\release\` finds the scripts by looking upward from where it is. Any other
  copy of the `.exe` (the installed one, or one you moved) uses its built-in scripts, unless `PIKPAK_BACKUP_REPO`
  is set to `G:\pikpak-mirror`, as above.
- **Try the setup without changing anything:** `pikpak-backup.exe --preview-setup`. It walks through every setup
  screen and changes nothing on this PC or in PikPak.
- Close the window and the app keeps running in the tray (next to the clock). Right-click the tray icon for
  **Open**, **Sync now**, **Pause syncing** (or **Resume syncing**) and **Quit**.
- Every time the app starts, it runs a **one-time cleanup** of what older versions left on this PC (see
  *Cleaning up after the old version*). It writes what it did to the log.

What the app changes in your files:

| What | Where |
|---|---|
| Config changes from the app | `config\mirror.config.psd1` (your own file; it is not in the repository, and the app or `Install.ps1` creates it from `config\mirror.config.sample.psd1`). Before each change the app saves the old file as `mirror.config.psd1.bak`. |
| Your hand-made config | The first time, the app also saves your original file once as `mirror.config.original.psd1`. It keeps your comments and the commented-out Premium pairs. |
| How often to sync | Config keys `SyncIntervalMinutes`, `SyncTime` and `SyncAtLogon`. The app changes them under **Settings**, and the scheduled task follows. You can edit them by hand too. |
| Result of each run | `state.json` records how each run ended. Home shows "Waiting for the next sync" until the first run after an update. |

Not in the app yet: a button for the delete safety stop that says "I deleted them on purpose" (see
*A folder keeps failing*), a storage-full check, changing the PikPak account, removing the app from Settings,
and an installer for other PCs. Use the commands in this guide for those. Details:
[OPEN-REQUIREMENTS.md](OPEN-REQUIREMENTS.md).

For developers: the app talks to the scripts through `scripts\Invoke-GuiAction.ps1` (JSON in on stdin, JSON out on stdout).

## What runs when

| What | When | What it does |
|---|---|---|
| `PikPakMirror-Sync` (scheduled task) | **Every hour** by default, all day. Also 15 minutes after you log on. If the PC was off at the planned time it runs as soon as possible afterwards. Never two at once. | 1. Two-way syncs each encrypted folder. 2. Two-way syncs each synced folder with `PikPak/PC-Mirror/...` (folders already synced first, then new ones, in priority order). 3. Once a day, deletes holding copies older than 30 days. 4. Warns you about the monthly limit and about failures. |

The sync task is installed **switched off** by `Install.ps1`, so that testing never runs against your real
folders by accident. You switch it on when you are ready (step 4 of *First-time setup*).

**How often to sync.** In the app: **Settings**, **How often to sync**: every 15 minutes, every 30 minutes, every
hour, every 3 hours, every 6 hours, or once a day (then you also pick the time). The manual way: in
`config\mirror.config.psd1` set `SyncIntervalMinutes` to `15`, `30`, `60`, `180` or `360`. `0` means once a day
at `SyncTime` (for example `'20:00'`). `SyncAtLogon = $true` adds the run 15 minutes after logon. Then run
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1` so the scheduled task follows (the app does this itself).

Things you may notice:
- A new file is safe in PikPak **only after the sync that uploaded it**, so up to one sync interval later (an
  hour by default). Do not count on PikPak having a file you saved a minute ago.
- Files you add on the phone or in the PikPak web app reach the PC **only if they are saved under
  `PC-Mirror/...`** (for an encrypted folder: only if the other app works under `PC-Private/`, see above).
  Everything else in PikPak stays in the cloud.
- When both sides changed the same file, the PC's version keeps the name and the other version is kept next to it
  with `.conflict` and a number added (for example `photo.jpg.conflict2`).
- PikPak does not report file times to rclone, so a change made in PikPak (phone/web) is noticed when the file's
  **size** changes. An edit that keeps the exact same size is not copied to the PC (rare for photos, music and
  video).
- If one run would delete more than 10% of a folder (for example because a disk was missing), that folder is
  not synced and you get a notification. Nothing is deleted. This safety stop works for **both** kinds of
  folder. See *A folder keeps failing*.
- During the first upload (and after a run that used up its limit) a folder continues with a full compare at the
  next sync. If you deleted a file during that time on one side, it can come back from the other side once; delete
  it again.
  The same holds for an **edit** made on the PikPak side during that time: the PC's copy wins, and the replaced
  copy is kept in the deleted-files folder for 30 days.

## First-time setup (this PC)

You need your PikPak **email and password** (the account must use email + password, not Google/Apple sign-in).

**In the app:** start it. It walks you through: **Get started**, sign in to PikPak, choose the folders (tick
**Encrypted** for the ones to lock), save the **recovery key** (only when you chose an encrypted folder), then
**Start my first sync**. `pikpak-backup.exe --preview-setup` shows all of it without changing anything.

**The manual way.** Run every command in a PowerShell window opened in `G:\pikpak-mirror`.

1. **Dry run.** `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1 -WhatIf` lists what it would do and changes nothing.
2. **Install.** `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1`. It:
   - installs rclone 1.75.2 (downloaded from rclone.org, the download's checksum is verified) into
     `%LOCALAPPDATA%\Programs\rclone`;
   - asks for your PikPak email and password and checks that they work. The password is not shown or saved by
     these scripts. rclone keeps it, obscured, in `%APPDATA%\rclone\rclone.conf`;
   - sets up the encrypted remote. On a first install choose **b**: it generates a password and a salt and shows
     them **once**. Save **both** in your password manager **and** on paper, then type `SAVED`. Without them the
     encrypted folders can never be read again (see [RECOVERY.md](RECOVERY.md));
   - registers the scheduled task `PikPakMirror-Sync` (switched off);
   - runs the one-time cleanup of the old version (step 5 of the installer, see *Cleaning up after the old
     version*);
   - creates the folder for deleted files (`LocalHolding` in the config, `D:\.pikpak-holding` on this PC) and
     `%LOCALAPPDATA%\PikPakMirror`.

   You can run `Install.ps1` again at any time. Steps that are already done print `[skip]`.
3. **Name your encrypted folders.** (The app does this for you: **Add an encrypted folder** on Home. The
   manual way:) Open `config\mirror.config.psd1` in Notepad and fill in `PrivatePaths`, e.g.
   `PrivatePaths = @( @{ Path = 'D:\Personal'; Name = 'Personal' } )`.
   - If that exact folder is also listed in `Pairs`, **delete that folder's line from `Pairs`**. A folder cannot
     be both. **Never** solve this by removing the `PrivatePaths` entry: the folder would then be uploaded
     unencrypted.
   - An encrypted folder *inside* a synced folder (e.g. `D:\Music\Personal` while `D:\Music` is in `Pairs`) is
     fine; keep both lines. The synced folder leaves the encrypted one out.

   Then run `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Confirm-PrivatePaths.ps1`, check the list, and type `YES`. The sync refuses to run until you
   confirm.
4. **Switch the schedule on** when you are happy: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1 -EnableSchedule`. You can also run one sync
   by hand at any time with `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-Sync.ps1`.

The first upload of everything (about 870 GB) takes roughly 4 months on Premium because of the limits below.
That is deliberate.

## Adding a folder

**Synced folder.** In the app: on **Home** press **Add a folder**, pick the folder in the picker. A box shows the
folder and its size, with the tick box **Encrypt this folder** (off by default). Press **Add folder**. Nothing is
uploaded before that. With the tick box off, the folder is synced from the next sync on (press **Sync now** to
start at once). With it on, the folder is added as an encrypted folder: see *Adding an encrypted folder*. The
manual way:

1. Open `config\mirror.config.psd1` and add a line to `Pairs`:
   `@{ Name = 'Ebooks'; Local = 'D:\Ebooks'; Remote = 'D/Ebooks'; Priority = 3 }`
   - `Name` must be unique. `_private` is reserved.
   - `Remote` is the folder under `PikPak/PC-Mirror`: use `D/<name>` for `D:\` and `C-Users/<name>` for
     `C:\Users\<you>\...`.
   - `Priority`: 1 runs first, 5 last.
2. If the new folder contains an encrypted folder, the encrypted folder is left out of the plain sync
   automatically as long as it is listed in `PrivatePaths`.
3. The next sync uploads the new folder (within the limits).

If you edit the config and it has a mistake, the sync stops and a notification tells you what is wrong.

**Stop syncing a folder.** In the app: on Home, the **...** button on the folder's row, **Stop syncing**. Nothing
is deleted on either side. The manual way: delete its line from `Pairs`.

## Adding an encrypted folder

In the app: on **Home** press **Add a folder**, pick the folder and tick **Encrypt this folder**, then press
**Add folder**. Or press **Add an encrypted folder** on Home (this also takes a folder inside a synced folder) and pick the folder: a box titled
**Make this folder encrypted?** shows the folder, its size and any plain copy found in PikPak. Press **Make
encrypted**: that is also your confirmation. Both need the recovery key (the first time, the app asks you to save
it). If the folder is already a synced folder, use the change described in *Changing a folder between synced and
encrypted*. The manual way:

1. Add it to `PrivatePaths` in the config: `@{ Path = 'D:\Personal'; Name = 'Personal' }`. `Name` is the
   folder name inside the encrypted storage. It must be unique, and `_holding` is reserved.
2. If that exact folder is also listed in `Pairs`, **delete that folder's line from `Pairs`**. Keep the
   `PrivatePaths` entry: if the config check says the folder "is itself a private path", the fix is always to
   delete the `Pairs` line, **never** the `PrivatePaths` line. Removing the `PrivatePaths` line would upload the
   folder unencrypted.
3. Run `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Confirm-PrivatePaths.ps1` and type `YES`. **Until you do, the sync does not run at all.**
4. If that folder was synced *plain* before, its plain copy is still in `PikPak/PC-Mirror/...`. Delete that plain
   copy in the PikPak app or web page.

**Stop encrypting a folder.** In the app: on Home, the **...** button on the folder's row, **Remove encryption**
(see *Changing a folder between synced and encrypted*).

In the app, an encrypted folder shows an **Encrypted** label next to its name on Home. On Home, the **...** button on
the row of an encrypted folder also has **Stop syncing**: nothing is deleted on the PC or in PikPak, the encrypted copy
stays in PikPak, and new and changed files in the folder are no longer synced. A folder that is inside a synced folder
has no **Stop syncing**, because it would then be uploaded readable with that folder; use **Remove encryption** there.

## Changing a folder between synced and encrypted

Added a folder the wrong way? On **Home**, press the **...** button on the folder's row: a synced folder offers
**Make encrypted**, an encrypted folder offers **Remove encryption**. (On Home, **Add an encrypted folder** on a
folder that is already synced does the same as **Make encrypted**.) A box asks you to confirm. It says whether
PikPak can read the files afterwards, how big the folder is, and where the old copy in PikPak is.

What happens, in the background (you can close the window; you get one notification at the end):

1. The folder is synced one last time the old way. If that fails (a sync is already running, the daily transfer
   limit is reached, any error), **nothing is changed** and the notification says why.
2. The folder is switched to its new kind. It stays where it is on the PC, with the same name.
3. The old copy in PikPak is deleted, if the box **Delete the old copy from PikPak** is ticked (it is, by
   default). It goes to **PikPak's trash**: empty the trash in PikPak to remove it for good. If you untick the box,
   the old copy stays and the notification says where it is.
4. The folder is uploaded again in its new form. That counts toward your **daily transfer limit**, so a big folder
   can take several days; it carries on at the next syncs.

While the change runs, **Sync now**, **Repair** and another change are not offered. Files deleted earlier are
kept 30 days as usual (see *Getting deleted or overwritten files back*). If the old copy cannot be deleted safely,
the box shows the tick box off and says so: the change still works, and the old copy stays.

## Getting deleted or overwritten files back (30 days)

A file deleted or overwritten by the sync is not gone. It is kept for **30 days** (`HoldingDays`) in a folder
named after the date.

**In the app:** **Get back a deleted file** (Home, Shortcuts). Search by file name, pick the file, and it is put
back where it was. It never overwrites a file that exists now: if the name is taken, the restored file gets a free name. This works for both kinds of folder. The next sync
uploads the restored file again.

**By hand**, where the copies are:

| What happened | Where the copy is |
|---|---|
| Synced folder: deleted on the PC, so the sync removed it from PikPak | `PikPak/PC-Holding/<date>/<folder name>/...` (in PikPak) |
| Synced folder: deleted in PikPak or on the phone, so the sync removed it from the PC | `D:\.pikpak-holding\<date>\<folder name>\...` (on this PC) |
| Encrypted folder: deleted on the PC | In the encrypted storage: `private:_holding/<date>/<Name>/...`. It is **encrypted** there; the app can list and restore it. |
| Encrypted folder: deleted in PikPak (by another app) | `D:\.pikpak-holding\<date>\_private\<Name>\...` on this PC. **Readable, not encrypted**, for 30 days. |

`D:\.pikpak-holding` is the `LocalHolding` setting (Settings, Advanced, **Folder for deleted files on this PC**).
Keep that folder on a disk only you can use: the copies of encrypted files in it are readable. Folders older than
30 days are removed automatically. Copies kept on this PC are lost with this PC's disk.

## A folder keeps failing

The notification, or Home, says the PikPak folder (or the PC folder) is empty, that a folder needs a repair run,
or that more than 10% of a folder would be deleted. **Nothing was deleted**: the sync of that folder stopped on
purpose. Home shows the folder as **Needs attention**.

- If PikPak's copy was deleted by mistake: restore it from the PikPak app's **Trash** if you can, then wait for the
  next sync.
- Otherwise **repair** the folder. It merges both sides. **Nothing is deleted**; whatever is missing on one side is
  copied from the other. If a file differs on the two sides, the replaced copy is kept for 30 days. This is also
  how you bring back a folder that was lost or emptied (on the PC or in PikPak), for both kinds of folder.
  - In the app: on Home press **Repair <folder name>**, or the **...** button on the folder's row, **Repair**, then
    **Repair** in the box.
  - The manual way:
    `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-Sync.ps1 -Resync "<Name>"`
    (the `Name` as written in `Pairs`, for example `"Holiday Photos"`). For an encrypted folder write
    `private:` before the name: `-Resync "private:Personal"`.
  - What is missing is uploaded or downloaded. That counts against the limits, so a big folder can take several
    runs.
- **The 10% stop and deleting on purpose.** If you really deleted that many files, Repair would bring them back,
  so do not use it. Instead raise **Stop and ask me if a sync would delete more than (% of a folder)** (Settings,
  Advanced; config `MaxDeletePercent`) for one sync, then set it back.
- If you really meant to delete the folder from PikPak, delete it on the PC instead (or stop syncing it). If that
  deletes more than 10% of a folder, the 10% stop applies: see *The 10% stop and deleting on purpose* above.
- If the PC was switched off during a sync, the next sync simply continues. You don't need to do anything.

## Stuck uploads

If the PC lost power or was forced off while a file was uploading, PikPak can keep a hidden half-finished copy
that blocks that one file name. You get a notification naming the file(s). Everything else keeps syncing; only
that file keeps failing.

**Fix:** rename the file on the PC (for example add ` (2)` to the name). It uploads under the new name at the next
sync. A normal Windows shutdown does not cause this.

## Status

In the app, **Home** shows it. The manual way:
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Get-Status.ps1` shows:
- the last successful sync (`LastSuccess`);
- this month's transfer use against the monthly limit;
- whether the encrypted folders are confirmed (`PrivateConfirmed`);
- each folder's last result, synced and encrypted (`Private = True`) together (`LastExit 0` = OK).

`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Get-Status.ps1 -Json` gives the same as JSON.

## Logs

All in `%LOCALAPPDATA%\PikPakMirror\logs` (paste that into the Explorer address bar):
- `YYYY-MM-DD.log`: a short summary of each day (runs, cleanup, problems);
- `YYYY-MM-DD\HHmmss-<job>-<n>.log`: the detailed rclone log of each step. The notifications name the file to
  open.

Logs older than 60 days are deleted automatically.

## The Vault rule: copy, never move

PikPak's **Vault** can only be filled by hand from the phone app. When you put something from `PC-Mirror` into
the Vault, always **copy** it. **Never move it.** A move looks like a deletion to the sync, so the file would be
removed from the PC (kept for 30 days and then gone for good).

## Limits and notifications

PikPak gives apps like rclone only a quarter of the account's monthly transfer allowance. Going over it slows
everything to about 100 KB/s for weeks. So there are two limits. Uploads and downloads both count:
- **Per day** (`DailyBudgetGB`): all syncs of one day together stay within it. On Premium use 8 GB. **This PC uses
  1 GB a day** (free account). When today's limit is reached, syncing pauses **quietly** until tomorrow: no
  notification, and Home says "Today's transfer limit is reached". Once the daily limit has stopped a run, syncing
  waits until the next day, and **Repair** and **Sync now** are refused until then. An older config that still has `RunBudgetGB`
  keeps working: its number is read as the daily limit.
- **Per month** (`MonthlyBudgetGB`): on Premium use 230 GB (PikPak allows about 250 GB; the rest is a margin,
  because files already uploading may finish past the limit). **This PC uses 30 GB.** At **90%** of the month you
  get a warning. When the month is used up, syncing pauses (one notification) and resumes automatically on the 1st;
  Repair and Sync now are refused until then too.
- In the evening (18:00-23:00) uploads are limited to 2 MB/s, so gaming and browsing stay smooth
  (`BwLimit`; Settings: **Go easy on my internet in the evening**).
- If nothing has synced successfully for **3 days**, you get a notification.
- **A lasting problem notifies once a day at most.** If the same problem is still there at the next sync, you
  are not told again until the next day. It notifies again if it comes back after being solved. **Home always
  shows the current problems.**

The numbers live in `config\mirror.config.psd1`; the app shows them under **Settings**, **Advanced** (**Transfer
limit per day (GB)**, **Transfer limit per month (GB)**, `BwLimit`, ...).

## Moving a folder (Locate)

Each synced and encrypted folder has a small ID file at its top, `.pikpak-sync.json` (see below). If you move or
rename a folder in Explorer, the app can't find it any more. Home shows **Folder not found** and a **Locate...**
button. (When its drive is simply unplugged, Home shows **Drive not connected**: the folder just waits, with no
button, and carries on once the drive is back.) Press **Locate...** and pick the folder at its new place:

- If the folder has the same ID, a box says "This is '<Name>' (was at <old path>). Use it from now on?". Confirm
  and the app uses the new path.
- If it has no ID file, the app can't tell it is the same folder. A box asks whether to use it anyway. The first
  sync merges both sides and deletes nothing.
- If it has another folder's ID, it is refused.

For a synced folder the box also has a tick box, ticked: **Also move it in PikPak** to the new place. That is a
move inside PikPak, nothing is uploaded again. An encrypted folder keeps its place in PikPak.
The first sync after Locate is a merge of both sides: only what is missing is copied.

## Pause syncing

To let one folder rest, press **...** on its row on Home and choose **Pause syncing**. The folder stays on Home,
greyed, with a **Resume** button. While it is paused the sync skips it and does not complain about it, and its
files in PikPak are left as they are. **Resume** continues with a normal sync that only sends what changed.
An encrypted folder stays locked while it is paused: it is still never uploaded readable. The difference with
**Stop syncing**: that removes the folder from Home. (**Settings**, **Pause syncing** pauses everything.)

## The .pikpak-sync.json / .pikpak-encrypted.json file (don't delete it)

Every synced folder has a hidden file `.pikpak-sync.json` at its top, and every encrypted folder has
`.pikpak-encrypted.json`. It holds the folder's ID, name and last place, and no secrets. The app uses it to
recognise the folder after you move it, to notice a copy of a folder (two folders with the same ID: a box asks
what to do, and **Give a new ID** is one of the choices), and to reconnect an encrypted folder from PikPak.
It is synced like any file. Don't delete it: without it the app can't tell the folder after a move, and a new
one has to be made. If you copy a folder, the copy comes with its file, which is how copies are noticed.

## Pause or stop

In the app: **Settings** has **Pause syncing** and **How often to sync**. The tray icon has **Pause syncing** / **Resume syncing** too. The manual way:

- Pause syncing: `Disable-ScheduledTask -TaskName PikPakMirror-Sync`.
  Resume: `Enable-ScheduledTask -TaskName PikPakMirror-Sync`. You can also do this in the Task Scheduler app.

A sync that is interrupted (PC shut down, network gone) simply continues at the next run.

## Cleaning up after the old version

Older versions had two drive letters (`P:` and `Q:`), a right-click **Offload** menu and an extra Archive in the
cloud. They are gone. The one-time cleanup, run by `Install.ps1` and by the app every time it starts, does
this, and skips each part that is already done:
- stops the old drive programs (rclone programs for `P:` and `Q:`);
- removes the scheduled task `PikPakMirror-Mount`;
- removes the right-click **Offload** entry;
- gives the sync task the new schedule (it stays switched on or off, as it was).

It writes what it did to the daily log. If a sync is running at that moment it waits for the next time.

Only if you had **your own** rclone drive on `P:` or `Q:`, the cleanup stops it once. Start it again if you want it.

**Left for you, by hand, if you want it:**
- Uninstall **WinFsp** (the old drive driver): Windows **Settings**, **Apps**, WinFsp, Uninstall. PikPak Sync no
  longer needs it.
- Delete the old cache folder `D:\.pikpak-cache`.
- If you installed an older **PikPak Backup** with its installer, uninstall that copy too (Windows **Settings**,
  **Apps**, PikPak Backup). The new Start-menu shortcut is called **PikPak Sync**. The app moves an old "start
  with Windows" entry to the new name by itself.
- `PikPak/Archive/` in the cloud is yours: keep it or delete it in PikPak. PikPak Sync no longer uses it and
  never touches it. Files you saved in it are not synced to the PC.

## Remove everything

```
Unregister-ScheduledTask -TaskName PikPakMirror-Sync -Confirm:$false
```

If the app starts with Windows, turn that off first: **Settings**, **Start PikPak Sync when I sign in to
Windows**. Your files in PikPak and on the PC are not touched. (If the cleanup of the old version has not run
yet on this PC, the task `PikPakMirror-Mount` and the registry keys `HKCU:\Software\Classes\*\shell\PikPakOffload`
and `HKCU:\Software\Classes\Directory\shell\PikPakOffload` may still exist: the cleanup, or deleting them by
hand, removes them.)

## Known limits

- PikPak reports no file times. A change made in PikPak is noticed by the file's size. An edit there that keeps
  the exact same size is not copied to the PC.
- A new file is safe in PikPak only after the sync that uploaded it.
- Encrypted folders: the readable copies of files deleted in PikPak sit on this PC for 30 days.
- Files kept in the PC-side 30-day folder are lost if the disk is lost ([RECOVERY.md](RECOVERY.md)).
