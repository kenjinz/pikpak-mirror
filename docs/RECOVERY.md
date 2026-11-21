# Recovery: getting everything back on a new or reinstalled PC

Read this when the PC died or Windows was reinstalled. Nothing here deletes anything in PikPak.

## What you need

| Item | Needed for | Where it should be |
|---|---|---|
| PikPak **email + password** | everything | your password manager |
| Crypt **password** (`password`) and **salt** (`password2`), both 32 characters | the **encrypted folders** only | your password manager **and** on paper, saved when `Install.ps1` showed them with "SAVE THESE NOW" |
| This project folder (`pikpak-mirror`) | the easy way below | a copy off this PC (USB stick, private Git repository, ...). It contains no secrets. |

**Setups made by the app use a single recovery key** instead of a password and a salt. In **Settings**,
**Show recovery key** shows it, and you can save it as a file, print it or copy it. Keep it in your password
manager **and** on paper, like the pair.

| Your setup | What you saved |
|---|---|
| Made by the app (a fresh PC) | One **recovery key** |
| This PC's existing encrypted storage (made with `Install.ps1`) | The **password and salt** pair. **Settings, Show recovery key** shows both. |

**Without the crypt password and salt (or the recovery key) the encrypted folders cannot be opened by anyone,
ever.** Keep it somewhere other than this PC. The synced folders (`PC-Mirror`, `PC-Holding`) only need the PikPak
login.

If the old Windows disk is still readable, its `C:\Users\<you>\AppData\Roaming\rclone\rclone.conf` also holds
both keys, in obscured form: `rclone config show private` on a PC using that file, and `rclone reveal <value>`
turns an obscured value back into the original. Treat that file as a secret.

## 1. Install and sign in on the new PC

1. Copy the project folder to the new PC (for example `G:\pikpak-mirror`). Open `config\mirror.config.psd1` and
   check it: if the drive letters changed, fix `LocalHolding`, `StateDir` and the `Local` paths of your folders.
2. In PowerShell, in the project folder:
   `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1`
   - enter the PikPak email and password;
   - for the encrypted remote choose **a)** and enter the **saved password and salt**, each twice.
     With a single recovery key from the app: type the key as the password, then press **Enter twice** for the
     salt (it stays empty). If PikPak already holds encrypted data and nothing decrypts with what you typed, the
     installer says so, removes the remote, and you can try again.

   The sync task is registered **switched off**, so nothing can touch your cloud copy while you restore.
   (The app does the same in its setup: start it, sign in, and enter the recovery key when it asks. See the
   easy way in step 2: the app also restores your folder list by itself.)
3. Check the key: `rclone lsf private:` should list your encrypted folder names.

## 2. Bring the folders back

**The easy way: restore from the folder list backup.** The app saves your folder list to PikPak by itself, every
time you change it. A new install reads it back by itself: sign in, enter the key if it asks, and your folders
come back. There is no list to confirm.

1. Start the app and sign in with your PikPak email and password.
2. If PikPak holds encrypted folders and this PC's rclone has no key that opens them, the app asks for your
   **recovery key**. Type the 30-character key, with or without spaces. If your encrypted storage came from
   `Install.ps1`, click **My key is a password and a salt** and type the saved password and salt instead. The app
   checks the key against your encrypted folders: a wrong key is refused, and nothing is changed. **I don't have
   my key** skips this step (see below).
   If this PC already has a `private` remote that opens your encrypted folders, setup uses it without asking.
   If this PC's rclone already has a different key that doesn't open your data, setup refuses and says to remove
   it with `rclone config` first. Setup never deletes an existing `private` remote.
3. When PikPak holds the backup with folders, the app restores it straight away: every folder at its old place,
   plus the settings and filters. A folder that is missing on a connected drive is created empty, so its first
   sync brings it down from PikPak. The first sync of each folder is a **merge**: it only adds what is missing on
   either side and deletes nothing. Downloads count against the PikPak limits
   ([user guide](README.md#limits-and-notifications)); a big folder takes several days and continues by itself.
   A holding or state folder on a drive this PC doesn't have goes back to its default place.
   If a folder can't be restored by itself (the backup has no place for it on this PC, or another folder has the
   same name), the app first shows the list *Found your folders in PikPak* with a tick for each folder: choose a
   place for it or untick the other one, then press **Restore**. Nothing is left out without your choice.
4. The last setup screen says "Restored N folders from your backup of <date>." with a line for each of these,
   when it applies:
   - **Waiting for a drive**: the folder's drive is not connected on this PC. The folder is restored at its old
     path and waits on Home ("Drive not connected"). Connect the drive and it carries on.
   - **Paused until you enter your recovery key**: see below.
   - Problems, if any step failed.

   A path written as `C:\Users\<old>\...` moves to the new profile by itself when that old profile folder doesn't
   exist on this PC. Paths written with `%USERPROFILE%` stay as they are and simply work.

While the app looks for the backup and restores it, **Set up from scratch instead** skips the restore and goes to
the normal *Choose folders* screen, where you pick your folders yourself. The old list in PikPak is replaced at
the first save. Your folders in PikPak stay.

What the backup holds, and what it does not:

- It holds the folder list and the settings (schedule, budgets, filters). It never holds your password or your
  recovery key.
- It does not hold the **names or paths of encrypted folders** in readable form. They are saved in a second file
  that PikPak stores encrypted, so only your key opens it.
- It does not hold sync history, logs or the holding folders.
- No backup in PikPak (for example, it was never uploaded)? The app finds your folders from the ID files in
  your PikPak folders and shows them as a list with ticks, as before. Untick what you don't want, use
  **Choose place...** for a folder whose drive is missing, and click **Restore**. Your settings are then the
  defaults.

**If you skipped the recovery key.** When the folder list backup was found, a synced folder that holds an
encrypted folder (for example `D:\Documents` with `D:\Documents\Private` inside) is restored **paused**, so it
cannot upload the private files readable. This happens whenever none of its encrypted folders came back inside
it: the key was skipped or the encrypted folder could not be restored. The last setup screen lists it under
"Paused until you enter your recovery key". Afterwards, **Settings** shows
"Some folders are paused until their encrypted folders are back" with **Check again**.

Without the backup (folders found from their ID files), the app cannot know which synced folders hold encrypted
ones, so they are restored **unpaused**. An encrypted folder that comes back with its ID file
(`.pikpak-encrypted.json`) is still left out of its synced folder, but check any folders copied from an old disk
before the first sync.

To resume a paused folder:

1. Go to **Settings**, **Encrypted folders**, and click **Enter recovery key...**. The box takes the same two
   forms of the key.
2. Restore the encrypted folders it offers. If there is no list, use **Encrypted folders in PikPak**, **Reconnect...**
   on each one.
3. Click **Check again**. The paused folders resume once their encrypted folders are back.

**The fallback: add the folders again, then repair.** Use this when the restore is not available (for
example, you set up with the command-line install), or when you want a different layout. It works for both kinds
of folder.

1. Add each folder again **at the place you want it** on the new PC. In the app: **Add a folder** on Home for a
   synced folder, **Settings**, **Encrypted folders**, **Add encrypted folder** for an encrypted one. The manual
   way: add the lines to `Pairs` and `PrivatePaths` in the config (see [README.md](README.md)), and for the
   encrypted ones run `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Confirm-PrivatePaths.ps1` and type `YES`.
   - A synced folder must use the same `Remote` as before. The app works it out from the folder's path
     (`D:\Music` becomes `D/Music`, `C:\Users\<you>\Pictures` becomes `C-Users/Pictures`), so add the folder at
     the same path. If the path is different, use the manual way and write the old `Remote`.
   - An encrypted folder must have the same `Name` as before: it is the folder name inside `private:`.
   - The app recognises a folder you add again by its ID file (`.pikpak-sync.json` or `.pikpak-encrypted.json`),
     so a folder restored with its files keeps its identity. **Settings**, **Encrypted folders in PikPak**, **Show**
     lists the encrypted folders that are in PikPak, and **Reconnect...** connects one to an empty folder on this PC
     with the right name.
   - A folder you add by hand in the config (no `Id` line) gets its ID when the app starts: the ID in its ID file
     on the PC; without one, the ID in the ID file of its folder in PikPak (so it matches its PikPak copy and the
     first sync is not stopped); without either, a new one. If PikPak can't be reached at that moment, that folder
     gets no ID yet and the app tries again the next time it starts. **Reconnect** in the add box also takes the
     ID of the ID file in PikPak.
2. Switch syncing on (`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1 -EnableSchedule`, or **Settings** in the
   app) or run one sync by hand: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-Sync.ps1`.
   The first sync of a folder is a **merge** of both sides. It only adds what is missing on either side and
   deletes nothing.
3. If a folder stops with a message that the PC folder is empty, press **Repair** on it in the app (Home), or type
   `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-Sync.ps1 -Resync "<Name>"` (for an encrypted folder:
   `-Resync "private:<Name>"`). Repair merges both sides, so everything in PikPak is downloaded to the empty PC
   folder. Nothing is deleted.
4. Downloads count against the PikPak limits ([user guide](README.md#limits-and-notifications)). A big folder
   takes several days. It continues at every sync by itself.

**The command way: copy with rclone.** Useful for one folder, or when you want the files now.

For a synced folder (each pair in the config maps `Local` to `PikPak/PC-Mirror/<Remote>`: `D/<name>` is
`D:\<name>`, and `C-Users/<name>` is `C:\Users\<you>\<name>`):

```
rclone copy "pikpak:PC-Mirror/D/Music" "D:\Music" --progress
rclone copy "pikpak:PC-Mirror/C-Users/Pictures" "C:\Users\<you>\Pictures" --progress
```

Or everything from one drive at once: `rclone copy "pikpak:PC-Mirror/D" "D:\" --progress`.

For an encrypted folder, each `PrivatePaths` entry `@{ Path = 'D:\X'; Name = 'N' }` is stored in `private:N`:

```
rclone copy "private:N" "D:\X" --progress
```

- `copy` never deletes anything. You can stop with Ctrl+C and run the same command again; it skips what is
  already there.
- Downloads count against PikPak's monthly app quota (about 1 TB/month on Premium). For very large restores add
  `--max-transfer 200G` and continue the next day, or copy the most important folders first.
- Small empty files named `RCLONE_TEST` come along. They are part of the sync; leave them.
- After a `copy`, add the folder in the app (or the config) as in the normal way above. The first sync merges.
  Files you restored with `rclone copy` keep their dates, so they are not uploaded again.

## 3. Recently deleted or overwritten files

Files that the sync deleted or replaced in the last 30 days are kept by date. In the app: **Get back a deleted
file**. By hand:

```
rclone lsf pikpak:PC-Holding                       # list the dates
rclone copy "pikpak:PC-Holding/2026-10-20/Music" "D:\Restore\Music 2026-10-20" --progress
rclone copy "private:_holding/2026-10-20" "D:\Restore\Private 2026-10-20" --progress
```

- `pikpak:PC-Holding` holds files of synced folders that were deleted or replaced **on the PC**.
  `private:_holding` holds the same for encrypted folders (stored encrypted, shown readable through `private:`).
- Files deleted or replaced **in PikPak** are kept on the old PC, in `LocalHolding` (`D:\.pikpak-holding\<date>\...`,
  for encrypted folders `D:\.pikpak-holding\<date>\_private\<Name>\...`). **They are lost with the disk.** If the
  old disk is still readable, copy from it with Explorer.

## 4. Check, then switch the schedule on

1. Run `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Get-Status.ps1`. Every folder should show `LastExit 0`.
2. `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1 -EnableSchedule` to switch the hourly sync on (if you have not yet).

## If the project folder is lost too

rclone alone is enough. Install it (download the Windows zip for 1.75.2 from https://downloads.rclone.org/v1.75.2/ and put `rclone.exe` in a folder on your PATH; winget only has up to 1.75.1), then create the
two remotes by hand in PowerShell. `--obscure` is required.

Replace each value between the single quotes with your real value, and keep the quotes. If a value itself
contains a single quote `'`, type it twice: `it's` becomes `'it''s'`.

```
rclone config create pikpak pikpak user 'you@example.com' pass 'your PikPak password' --obscure
rclone config create private crypt remote pikpak:PC-Private filename_encryption standard directory_name_encryption true password 'crypt password' password2 'crypt salt' --obscure
```

If a password or salt contains a double quote `"` or ends with a backslash `\`, Windows PowerShell cannot pass it
to rclone correctly. In that case run `rclone config` instead and answer its questions: `n` for a new remote,
then name, type and the values exactly as in the commands above. It asks for passwords itself.

Then use the `rclone copy` commands in step 2 (and 3). Typing a password on the command line leaves it in the
PowerShell history: afterwards run `Clear-History` and delete `(Get-PSReadLineOption).HistorySavePath`.
