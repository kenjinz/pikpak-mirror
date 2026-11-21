# Automatic restore after sign-in

Date: 2026-11-21. Status: approved by the owner on 2026-11-21 (in chat: "yes, make it restore automatically").
Amends `2026-11-21-folder-list-backup-design.md`. Size: a small change; the restore code exists.

## Intent

The owner re-downloads the app for every new version and wants a fresh install to come back exactly as before,
with no list to confirm: sign in, done. A brand-new user still gets a normal setup, and the backup file is
created at the first save (already true).

## What changes

1. **Backup found → restore without asking.** After sign-in, when `setup.discover` returns a backup, setup does
   not show the *Found your folders* list. After the key step (below) it runs `setup.finish` with `restore`
   straight away: every folder in the backup (synced and encrypted), at its resolved path, with the backup's
   settings and filters. Folders keep their `Id`, `Remote`, `Name` and paused state, as today.
2. **Key step unchanged in substance.** This PC's rclone has a key that opens the data → used, nothing asked.
   PikPak holds encrypted data and there is no key → the existing key screen (key, or password + salt, or
   **I don't have my key**). This is the only question a restore can ask.
3. **Folders whose drive is missing are restored too**, at their old path, not skipped and not guessed. The sync
   already handles them: "Drive not connected" (no Locate) or "Folder not found" with **Locate…** on Home, and
   nothing is deleted. *(my call: keeps "exactly the previous state"; the owner points them elsewhere later.)*
4. **Missing folders on a present drive are created empty** by the restore (new PC, or wiped disk), so the first
   sync (a merge) downloads them from PikPak. Today the restore never creates them, and the sync then skips them
   as "Folder missing" forever. Created only when the drive exists; never for a drive that is missing.
5. **The end of setup says what happened**: "Restored N folders from your backup of <date>." plus, when some were
   left paused (encrypted folder inside, key skipped) or have a missing drive, one line each naming them.
6. **No backup in PikPak** (only ID files found by the scan) → unchanged: the *Found your folders* list with ticks,
   because the scan cannot know the settings or which synced folders hold encrypted ones.
7. **Start fresh** stays reachable: a quiet link on the restoring screen, "Set up from scratch instead", before
   `setup.finish` runs (it goes to *Choose folders*, with the existing replace-the-old-list confirmation).

## Unchanged safety rules

The identity checks (ID file match on the PC and in PikPak before a merge), the pause rule for synced folders
holding encrypted folders, never deleting or replacing a key, and the first sync being a merge all stay as built.

## Left to the builder

Wording within the house style; how the restoring screen shows progress; tests for the engine part (folder
creation: drive present → created; drive missing → not created and not an error).
