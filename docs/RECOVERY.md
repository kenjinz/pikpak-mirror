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
   (The app does the same in its setup: start it, sign in, and enter the recovery key when it asks.)
3. Check the key: `rclone lsf private:` should list your encrypted folder names.

## 2. Bring the folders back

**The normal way: add the folders again, then repair.** This is the one to use for both kinds of folder.

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
4. Downloads count against the PikPak limits (README, *Limits and notifications*). A big folder takes several
   days. It continues at every sync by itself.

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
