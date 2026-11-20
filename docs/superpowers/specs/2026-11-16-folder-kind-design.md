# Choose and change a folder's kind (synced or encrypted)

Date: 2026-11-16. Status: approved by the owner in conversation ("Your idea sounds good"), including the choice
to delete the old PikPak copy by default.

## Intent

A folder is either synced normally (readable in PikPak) or encrypted. Today the choice is hidden in Settings, a
folder added from Home is always uploaded readable, and there is no way to turn an encrypted folder back into a
normal one. The owner wants to choose the kind when adding a folder on Home, and to change it later in both
directions when a folder was added the wrong way.

## Goals

1. **Add from Home with a choice.** After picking the folder, a box shows the path and size and a checkbox
   "Encrypt this folder", unticked by default. Nothing is uploaded before the choice.
2. **Change the kind from Home.** Every folder row has a menu: a synced folder offers "Make encrypted" and
   "Stop syncing"; an encrypted folder offers "Remove encryption" and "Stop syncing".
3. **A change loses nothing.** The folder stays where it is on the PC. Before the switch the app syncs the
   folder one last time in its old form, so a file that exists only in PikPak is not missed.
4. **The old PikPak copy is deleted by default.** The confirm box has a ticked checkbox "Delete the old copy
   from PikPak". Unticked, the old copy stays and the app says where it is.

## Non-goals

- Emptying PikPak's trash. The deleted old copy goes to PikPak's trash; the box says so.
- Moving data inside PikPak between the plain and the encrypted storage. The folder is uploaded again in its new
  form, within the daily transfer limit.
- Changing where the folder is on the PC, or its name.

## Anti-goals

- Deleting the old copy when the last sync in the old form did not succeed, or deleting anything other than
  that one folder's old copy.
- Leaving old sync state behind, so that a later change back would trust lists that describe a copy that no
  longer exists.
- An encrypted folder's files reaching the plain storage because of a half-finished change.

## Approaches

- **A. A change is a background job: last sync, switch, delete old copy, first sync in the new form
  (chosen).** Safe against files that exist only in PikPak; costs one small script.
- **B. Switch the config only (what Settings does today).** No last sync, old copy left behind: a readable copy
  stays in PikPak after "encrypting", and duplicates fill the 6 GiB account.
- **C. Switch and delete the old copy at once, without a last sync.** Simple, but a file uploaded to PikPak
  since the last sync would be deleted unseen.

The owner chose A with deletion on by default.

## Design (my calls unless marked)

### The change job

Runs detached, like Repair, so it survives closing the window. Steps for one folder:

1. **Last sync in the old form**, for that folder only. It must end successfully (exit 0, folder seeded). If it
   does not (a sync is already running, today's transfer limit is reached, the delete safety stop, any error),
   the job stops, changes nothing and notifies: "<Name> was not changed: it could not be synced one last time
   (<reason>)."
2. **Switch the config** (old entry removed, new entry added, encrypted-folder confirmation recorded) in one
   save.
3. **Forget the old form's sync state**: its entry in `state.json`, its filter file and its bisync lists.
   Always, also when the old copy is kept.
4. **Delete the old copy** when asked: exactly `pikpak:<MirrorRoot>/<pair Remote>` for a synced folder, or
   `private:<Name>` for an encrypted one. Never a root. A failure here is reported but does not undo the
   change.
5. **First sync in the new form** (a normal run; it uploads within the daily limit and continues at later runs).
6. A notification says what happened: changed; old copy deleted or kept (and where it is); or why it stopped.

Holding copies (deleted files kept 30 days) of the old form are left alone and expire by themselves.

### Rules

- Synced to encrypted: refused when the folder contains an encrypted folder (existing rule).
- Encrypted to synced: when the encrypted folder sits inside a synced folder, it simply becomes part of that
  synced folder again (existing behaviour of "Remove"); no new entry is made. Otherwise a new synced entry is
  made the same way "Add a folder" makes one.
- The confirm box says what will happen in plain words: readable or not readable by PikPak afterwards; that the
  folder is uploaded again and how big it is; the checkbox for the old copy; that the old copy goes to PikPak's
  trash.
- While a change runs, Home shows it as running; a second change, Repair or "Sync now" started meanwhile gets
  the existing "a sync is running" answer.
- Settings keeps its list of encrypted folders. Its "Add encrypted folder", when the folder is already synced,
  uses the same change job instead of the config-only switch.
- Preview mode changes nothing and lists what would happen.

### Adding from Home

`Add a folder` opens the box. With the checkbox unticked it does what it does today. Ticked, it adds the folder
as an encrypted folder (the existing rules of adding an encrypted folder apply); nothing was uploaded yet, so no
change job is needed.

## Left to the builder

- The box and menu layout and exact wording, in the app's existing style and vocabulary ("sync", "Encrypted").
- How the job reports progress to Home beyond "running".
- Names of new functions, actions and the script.
