# Folder list backup: restore your folders on a fresh install

Date: 2026-11-21. Status: approved by the owner on 2026-11-21. The owner decided: the app backs the folder list up
to PikPak automatically and offers to restore it in setup; when the backup is missing it rebuilds the list from
the folders' ID files in PikPak; encrypted folders are included; the recovery key is asked right after sign-in
when PikPak already holds encrypted data; one person, one PikPak account, one key for all encrypted folders.
Calls marked *(my call)* are mine.

## Intent

The folder list lives only on the PC, in `%LOCALAPPDATA%\PikPakSync\config\mirror.config.psd1`. Downloading
the app again on the same PC keeps it (the engine unpack never touches it), but a new PC, a Windows reinstall
or a wiped AppData loses it. Today the owner must then add every folder again by hand, at the same paths
(`docs/RECOVERY.md`, section 2), and encrypted folders need the PowerShell installer because the app's setup
can only make a new key.

The owner wants a fresh install to bring the folders back: sign in, confirm, done.

## Goals

1. **Automatic backup.** Whenever the config changes, a copy goes to PikPak. The owner does nothing.
2. **Restore in setup.** After sign-in, setup finds the backup and offers the folders it lists; the owner
   confirms (and fixes a path only when its drive is gone). The restored folders sync as before, into the
   same PikPak places, with the same IDs.
3. **Existing recovery key in setup.** When PikPak already holds encrypted data, setup asks for the recovery
   key right after sign-in, checks it against that data, and uses it. One key opens all encrypted folders.
4. **Fallback without a backup.** When the backup file is missing or unreadable, setup builds the same list
   from the ID files (`.pikpak-sync.json`, `.pikpak-encrypted.json`) in PikPak. Settings are then the defaults.
5. **Enter the key later.** An owner who skipped the key in setup can enter it in Settings and then reconnect
   the encrypted folders with the existing *Encrypted folders in PikPak* list.

## Non-goals

- Several PCs, several accounts, several keys. One backup file, one key.
- Backing up the recovery key or the PikPak password. Never.
- Restoring sync history. The first sync of each restored folder is a merge (resync), as after Reconnect today.
- Restoring into an app that is already set up. Restore is a setup step only. (Same PC re-download needs nothing:
  the config survives.)
- Restoring logs, holding folders (`PC-Holding`, `LocalHolding` contents) or budget counters.
- Keeping a history of backups.

## Anti-goals

- Any secret in PikPak in readable form.
- The names or paths of encrypted folders in PikPak in readable form (that is what encryption hides).
- A restore that deletes anything in PikPak, or syncs a folder into a PikPak place whose ID does not match.
- A wrong key accepted, or a new key made while PikPak holds encrypted data.
- A backup upload failure that blocks or breaks a save, a setup or a sync.

## Approaches

- **A. Automatic backup in PikPak, plus a scan of ID files as fallback (chosen by the owner).** Fast restore
  with all settings; still works when the backup is missing.
- **B. Export / Import settings button.** Simple, but only helps if the owner remembered to export and kept the
  file somewhere else.
- **C. Scan of ID files only.** No extra file, but slower (lists all of `PC-Mirror`) and loses the settings
  (budgets, schedule, filters).

## Design

### The backup file

`<Remote>:<MirrorRoot>/.pikpak-sync-backup.json` (today `pikpak:PC-Mirror/.pikpak-sync-backup.json`). JSON,
UTF-8 *(my call: JSON instead of a `.psd1`, because a file downloaded from the cloud is parsed as data only,
and the UI can read it too)*. It sits at the root of `PC-Mirror`, outside every synced folder's place, so no
bisync touches it.

```json
{ "app": "pikpak-mirror", "kind": "folder-list-backup", "version": 1,
  "saved": "<ISO date>", "pcName": "<computer name>", "appVersion": "<x.y.z>",
  "config": { ...the raw config, without PrivatePaths... },
  "globalFilters": "<text of filters.txt>" }
```

- **`config`** is the raw config as `Save-MirrorConfig` writes it (Pairs with `Id`, `Remote`, `Priority`,
  paused state and per-folder fields; every setting), **minus `PrivatePaths`** *(my call)*, so the readable
  backup never shows what an encrypted folder is called or where it lives.
- **`holdsEncrypted: true`** is added to each Pair that has an encrypted folder inside it (the pairs whose
  filter rules `New-PairFilterRules` builds from `PrivatePaths`). No names, only the flag *(my call)*. See
  *Synced folders with encrypted folders inside*.

### The encrypted companion file

`private:.pikpak-sync-encrypted.json` (a file at the root of the crypt remote, so PikPak stores it with its name
and contents encrypted) holds the `PrivatePaths` entries exactly as in the config (`Path`, `Name`, `Id`,
`Paused`, any other per-folder field), with the same header fields as the backup *(my call)*. It is written
alongside the backup whenever a `private` remote exists, under the same hash (the hash covers both files).
`Get-GuiRemotePrivateNames` lists directories only, so the file never shows up as an encrypted folder.

Restore takes encrypted folders from this file when it is there (their settings, paused state included, come
back), and from the ID files in `private:` when it is not (then with default settings).

### Synced folders with encrypted folders inside

A synced folder such as `D:\Documents` keeps `D:\Documents\Private` out of PikPak only through filter rules
built from `PrivatePaths`. When the owner skips the key, those entries are unknown, so a restored `Documents`
would upload `Private` readable on its first merge if the files are on disk. Therefore *(my call)*: a Pair with
`holdsEncrypted` is restored **paused** when the key was skipped, with the row note "Contains encrypted folders.
It resumes once you enter your recovery key." Entering the key later (Settings) restores the encrypted entries
from the companion file and resumes those pairs. With the key, nothing is paused.
- **`globalFilters`** carries the owner's edits to `config\filters.txt` (they are not in the config).
- No secrets: the config holds none (passwords and keys live in `rclone.conf`). A test pins that the backup
  never contains `PrivatePaths` and never a value from the rclone config.

### Keeping it up to date

- **After every app save.** Every config change goes through `Save-GuiConfig`, `Convert.ps1`'s save or
  `setup.finish`. When a save succeeds (not under preview), the UI makes a separate bridge call, `backup.push`,
  in the background, so a slow upload never holds the screen. `backup.push` writes the JSON to a temp file and
  runs `rclone copyto` to the backup path.
- **At every sync run.** `Invoke-MirrorRun` builds the backup text and compares its hash with
  `State.BackupHash`. When it differs (an earlier push failed, the app was closed, the owner edited the config
  by hand), the run uploads it. `backup.push` stores the hash too, so a push that worked is not repeated.
  The hash covers `config` and `globalFilters`, not `saved`, so an unchanged config is not uploaded again.
- **Failures are quiet.** A failed upload is logged and leaves `State.BackupHash` unchanged; the next run tries
  again. After 3 days without a successful backup while the config differs, Home shows a quiet note "Your folder
  list couldn't be backed up to PikPak since <date>" *(my call: the existing stale pattern, `StaleRunDays`)*.
- The filters never exclude the backup file name (test).

### Setup with a restore

Today: Welcome → Sign in → Choose folders → Recovery key (only with an encrypted folder) → Done.
New, after a successful sign-in, a new action `setup.discover` reports:

- `backup`: the parsed backup (`saved`, `pcName`, its Pairs and settings) or `null`, plus `backupProblem` when
  the file exists but cannot be read (treated as missing, and said so);
- `encryptedData`: whether `pikpak:PC-Private` holds anything (`Get-RemoteEntryCount`; a failure to check is an
  error with **Try again**, never a guess).

Then:

1. **Recovery key** (only when `encryptedData`). "Your PikPak has encrypted folders. Type your recovery key to
   open them." One field. **Check key** calls `setup.usekey`, which creates the crypt remote with
   `New-MirrorPrivateRemote -Mode Existing` (it refuses when nothing decrypts) and returns the encrypted folders
   found: for each folder directly in `private:` its name, size and ID file (`Get-GuiRemotePrivateNames`,
   `Get-GuiRemotePrivateInfo`). A wrong key removes the half-made remote and says "That key doesn't open your
   encrypted folders. Check it and try again." **I don't have my key** skips: encrypted folders are not
   restored; the screen says they stay locked in PikPak until the key is entered in Settings.
   **Two forms of the key.** The field takes the app's 30-character recovery key in any case, with or without
   spaces (`ConvertTo-RecoveryKey`). A link "My key is a password and a salt" shows a second field: storage made
   by `Install.ps1` uses a password plus a salt (`password2`), which `key.show` already shows as `kind = 'pair'`.
   **The owner's own storage is of this kind** (checked: their `private` remote has `password2`), so the app must
   support this form (the key is still only asked when `PC-Private` holds data). Typed values go through `Test-NativeArgumentSafe` like the installer's; an unsafe value
   gets the installer's message. Both forms reach `New-MirrorPrivateRemote -Mode Existing` (`-Salt` empty for
   the single key).
2. **Restore your folders** (when there is a backup, or the fallback found anything).

   ```
   Found your folders in PikPak (backed up 20 Nov 2026 from KEN-PC)
     [x] Documents   D:\Documents          2.1 GB
     [x] Music       D:\Music              1.4 GB
     [x] Private     D:\Private      (encrypted)   0.8 GB
     [ ] Old         E:\Old  — drive E: isn't on this PC   [Choose place…]
   About 4.3 GB will come down from PikPak.
     [Restore]   [Start fresh instead]
   ```

   - Synced rows come from the backup's Pairs (or the fallback); encrypted rows from step 1.
   - **Paths under the old user profile move to the new one** *(my call)*: `C:\Users\<old>\<rest>` becomes
     `%USERPROFILE%\<rest>` when the old profile folder does not exist on this PC. This matches how
     `New-MirrorPair` names those places in PikPak (`C-Users/<rest>`, independent of the user name).
   - Each row starts ticked when its path's drive exists, unticked with **Choose place…** when not. Choosing a
     place changes only the PC path: the folder keeps its `Remote` (synced) or `Name` (encrypted) and its `Id`.
   - Sizes come from PikPak (`rclone size`, per folder, loaded after the list shows) *(my call)*. The total is
     what the first syncs download; PikPak's daily limit on the free account applies, so the line says so when
     the total is over the account's daily download allowance.
   - Paused folders are restored paused (encrypted ones too, from the companion file).
   - **Start fresh instead** goes to today's *Choose folders* screen. A confirmation says the old list in PikPak
     will be replaced at the first save (the ID files stay, so a later fallback can still find the folders).
3. **Done.** `setup.finish` runs with `restore`: the chosen entries and the backup's settings instead of the
   generated config.
   - Settings are the backup's, except machine paths: `LocalHolding` and `StateDir` keep the backup's value when
     its drive exists, else the defaults. Account preset limits are not changed.
   - `config\filters.txt` is written from `globalFilters`.
   - The recovery key step does not make a key: the crypt remote already exists from step 1 (today's step
     refuses an existing remote; with `restore` it checks that it is the one `setup.usekey` made and goes on).
   - The other steps are today's (tasks, local folders created when missing, encrypted folders confirmed).
   - The backup is pushed once at the end.
   - The first sync of each folder is a merge. The identity checks from the folder-identity design run as
     usual: a local folder whose ID file has a different ID is skipped with `folder-identity-mismatch`, and the
     PikPak ID file is checked before the merge.

### Fallback: rebuilding the list from ID files

When `backup` is null:

- **Synced folders:** list `.pikpak-sync.json` files under `<Remote>:<MirrorRoot>` (`rclone lsf -R --files-only`
  with an include for that name), then read each (`rclone cat`). Each gives `id`, `name`, `lastPath`; the
  folder's `Remote` is its path under `MirrorRoot`. A file nested under another found folder is ignored (only
  folder tops have ID files). A file whose `kind` is not `synced` or whose JSON is invalid is skipped and logged.
- **Encrypted folders:** step 1 already lists them with their ID files. A folder in `private:` with no ID file
  (synced before the folder-identity change) is shown by its name, unticked, with **Choose place…** (no last
  path known).
- Settings are the defaults of the account preset found at sign-in, as in today's setup. The screen says: "No
  backup of your settings was found. Your folders were found from PikPak; settings are back to defaults."
- The scan can take a while on a large `PC-Mirror`; the screen shows "Looking for your folders in PikPak…"
  with a **Skip** link to today's *Choose folders* screen.

### Entering the key later (Settings)

In Settings, *Encrypted folders*: when there is no `private` remote and `pikpak:PC-Private` holds data, a row
"Your PikPak has encrypted folders this PC can't open yet. **Enter recovery key…**" opens the same key box
(`private.usekey`, same check and same two forms as `setup.usekey`). When the companion file is there, the app
then offers to restore the encrypted folders it lists (same rows as the restore screen) and resumes the pairs
paused for `holdsEncrypted`. Otherwise *Encrypted folders in PikPak* lists them and **Reconnect…** (existing)
connects each one.

## Constraints

- Windows PowerShell 5.1 engine, Tauri UI, the existing bridge (one JSON request, one envelope); secrets only on
  stdin and cleared after use, as `setup.signin` does.
- Free account: every rclone call counts. The backup is a few KB; `backup.push` runs only after a real save,
  and the run uploads only on a hash change.
- Preview mode: every new action has a preview that writes nothing and lists what it would do.
- Tests with mocked rclone, like the existing suites; live tests use files of 1 MB or less.

## Left to the builder

- Exact names of the new actions (`setup.discover`, `setup.usekey`, `private.usekey`, `backup.push`) and of the
  state field.
- How the fallback scan limits its depth or time.
- How the restore screen loads sizes (all at once or row by row).
- Wording, within the house style of the existing screens.
- Updating `docs/RECOVERY.md` and `README.md` to the new restore path.
