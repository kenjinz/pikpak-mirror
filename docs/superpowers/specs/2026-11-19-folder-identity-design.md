# Folder identity: follow moved folders, catch copies, reconnect encrypted folders

Date: 2026-11-19. Status: draft for the owner's approval. The owner decided: the app asks and never follows a
moved folder by itself (for now); when two folders carry the same ID the app tells them and lets them choose,
including keeping both, with a way to give one of them a new ID after a confirmation. The rest are my calls.

## Intent

Today the app knows a folder only by its path in the config. Three things follow from that:

- **A moved or renamed folder is lost.** `D:\abc\xyz` moved to `E:\xyz` is reported "Folder missing, skipped" at
  every sync (safe: nothing is deleted), and the only fix is to add it again. For a synced folder that uploads
  everything again to a new place (`PC-Mirror/E/xyz`) and leaves the old copy (`PC-Mirror/D/abc/xyz`) using the
  6 GiB account.
- **An encrypted folder the app stopped syncing cannot be found again.** "Stop syncing" keeps its data in
  PikPak, but PikPak shows only scrambled names, and the app has no view of `private:`. Adding a folder again
  reconnects it only by luck: its PikPak name is the folder's last path segment, so a different folder that
  happens to have the same name joins the old data, and a name clash (`Album (2)`) misses it.
- **After restructuring, the owner cannot tell which folder was which.**

The owner wants each synced folder to carry its own identity, so that the folder is recognised wherever it is
moved, and so that a sync, once set up, stays exactly that sync.

## Goals

1. **Every synced folder carries an ID.** A small file at the top of the folder, synced to PikPak with the rest,
   names its ID and where it lives in PikPak.
2. **Locate a moved folder.** A folder whose path is gone (and whose drive is connected) shows "Missing" with
   **Locate…** on its row. The owner picks the new place; the app checks the ID and switches the folder to it.
   Nothing is uploaded again.
3. **Recognise a folder that was synced before.** Adding a folder whose ID the app knows (or that PikPak knows)
   offers to reconnect instead of starting a new copy.
4. **Two folders with the same ID are never synced silently.** The app shows both and the owner decides: keep
   one, switch to the other, or keep both, in which case one gets a new ID (after a confirmation) and its own
   place in PikPak.
5. **See and reconnect encrypted folders in PikPak.** Settings lists the encrypted folders that are in PikPak by
   their real names, marks which are connected to a folder on this PC, and offers to reconnect, download or
   delete the ones that are not.
6. **Pause a folder instead of removing it.** A paused folder stays on Home and resumes with a normal sync.

## Non-goals

- Searching the drives for a moved folder. The owner points at it with Locate…. (A later search can reuse the
  same ID check.)
- Following a moved folder automatically. The app asks every time (owner's decision; may change later).
- A PikPak list for synced (readable) folders. Those are readable on the PikPak website already.
- Renaming an encrypted folder's name in PikPak (`private:<Name>`) when its PC folder is renamed. The name stays.
- Several PCs syncing the same folders.
- Carrying a folder's sync history over on Locate (so renames inside a moved folder sync as renames). The owner
  ruled it out for now as not needed: the first sync after Locate stays a merge.

## Anti-goals

- Syncing a different folder into an existing PikPak place because it sits at a known path or has a known name.
  A folder whose ID does not match is never synced into that place without the owner saying so.
- Two configured folders syncing into the same PikPak place.
- The app changing an ID, moving anything in PikPak or switching a folder's path without a confirmation.
- Losing a file during a Locate: the first sync after it is a merge that deletes nothing.

## Approaches

- **A. A marker file in the folder, synced to PikPak (chosen).** Both copies of the folder (PC and PikPak) say
  which folder they are, encrypted inside an encrypted folder. Needed for goal 5 and for recognising folders
  after a PC reinstall. Costs one small file per folder that the app keeps correct.
- **B. A marker on the PC only (not synced).** Moved folders are still recognised, but PikPak has no ID, so
  leftover encrypted folders can only be matched by name: the wrong-folder risk stays.
- **C. No marker; recognise a folder by a fingerprint of its contents.** Nothing added to the folder, but it
  breaks as the contents change and is slow on large folders.

The owner left the choice to me; A.

## Design (my calls unless marked)

### The marker

`.pikpak-sync.json` at the top of each synced folder and each encrypted folder, UTF-8, Hidden attribute set on
the PC (re-set when missing; PikPak does not keep it):

```json
{ "app": "pikpak-mirror", "version": 1, "id": "<GUID>", "kind": "synced|encrypted",
  "name": "<config Name>", "pikpak": "pikpak:PC-Mirror/D/abc/xyz | private:xyz",
  "lastPath": "D:\\abc\\xyz", "updated": "<ISO date>" }
```

- No secrets. `id` is what matters; the rest is for messages and for people reading it.
- The config entry (`Pairs` and `PrivatePaths` items) gets an `Id` field with the same GUID. The config stays
  the source of truth; the marker is the folder's copy of it.
- The marker is synced like any file. The global filters must never exclude it (a test pins this).
- Only the top of a configured folder has a marker. Subfolders do not.
- An encrypted folder's marker is named `.pikpak-encrypted.json` (see *Encrypted folders inside a moved folder*).
  Everywhere below, "marker" means either file.
- Changing a folder's kind keeps its ID; only the descriptive fields (and, for encrypted, the file name) change.

### Giving folders their IDs

- **A newly added folder:** before writing a new ID, the app reads the folder's own marker and the marker at its
  PikPak place (`rclone cat`). The cases are under *Adding a folder*. A new ID is made only when neither has one.
- **Folders configured before this change:** on the app's first start after the update, each entry without `Id`
  gets one in a single config save (with the usual `.bak`), adopting the ID of an existing marker on the PC or in
  PikPak when there is one. The sync script also handles an entry without `Id` by skipping the marker step
  (so a hand-edited config still syncs).
- **Writing the marker:** the sync writes it, for each folder, just before that folder's sync, when it is
  missing or its descriptive fields are out of date. The sync never changes an `id` inside a marker.

### Every sync checks the ID

Before syncing a folder, the sync reads its marker on the PC:

- **Matches the config `Id`:** sync.
- **Missing, and this folder never had one** (state has no `MarkerWritten` for it): write it, then sync. This is
  the one-time case after the update or for a new folder.
- **Missing, but the marker was written before** (state `MarkerWritten`): a different folder may now sit at that
  path (the real one moved and a new one was made there, or another drive took the letter). A normal sync would
  then delete the real folder's files in PikPak. So skip it like a different ID, issue `folder-marker-missing`,
  with **Locate…** and **Use this folder anyway** (which restores the marker and makes the next sync a merge).
  Same treatment when the owner deleted the marker by hand.
- **A different ID:** the folder at that path is not the folder that was set up. Skip it, nothing synced or
  deleted, issue `folder-identity-mismatch`: "<Name>: the folder at <path> is a different folder (it belongs to
  '<marker name>'). Nothing was synced. Open the app to sort it out." The row offers **Locate…** and **Use this
  folder anyway** (confirmation; then the folder's marker gets the config ID and the first sync merges).
- **The PikPak marker** is checked whenever the folder is about to be merged (first sync, after Locate, Repair,
  any resync): if the PikPak place holds a marker with a different ID, skip with `folder-identity-mismatch`
  (PikPak side). A normal run does not read it (one `rclone cat` per folder every 15 minutes is not worth it; a
  normal bisync would see a changed remote marker as a change anyway, and the next merge checks it). A failed
  read skips the folder for that run, with the usual error issue.
- **Two configured folders with the same `Id`** (only possible by hand-editing or a config restored from
  elsewhere): both are skipped with issue `folder-duplicate-id`, and Home shows the same-ID box (below).

### Missing folders and Locate…

- A missing folder whose **drive is not connected** shows "Drive not connected" and simply waits. No Locate.
  (Today's "Folder missing, skipped" message and issue kind stay; the row text distinguishes the two.)
- A missing folder whose **drive is connected** shows "Missing" and **Locate…**. The owner picks a folder:
  - **Its marker has this folder's ID:** the box says "This is '<Name>' (was at <old path>). Use it from now
    on?" Confirm, and the config path changes.
  - **No marker:** "This folder has no ID, so the app can't tell if it is '<Name>'. Use it anyway? The first
    sync merges both sides and deletes nothing." Confirm, and the marker is written with the folder's ID.
  - **A different ID:** refused: "This is '<other name>', not '<Name>'."
  - The usual add rules apply to the new path (not inside another synced or encrypted folder in a way the
    existing rules refuse, not a drive root, and so on).
- **A synced folder's PikPak place** is derived from its PC path today. After Locate, the box has a checkbox,
  ticked: "Also move it in PikPak to PC-Mirror/<new place> (moved inside PikPak, nothing is uploaded)". Ticked,
  the app moves the folder inside PikPak (`rclone moveto`, a server-side move) and updates `Remote`; unticked,
  `Remote` stays and only the PC path changes. If the move fails, nothing changes and the box says why.
  An encrypted folder keeps its `private:<Name>`.
- After a Locate the folder's mapping changed, so the existing identity check makes the next sync a merge
  (resync): only what is missing on either side is copied; files keep their dates, so almost nothing moves.

### Adding a folder (Home and Settings)

Before adding, the app reads the chosen folder's marker, scans one level of the chosen folder's tree for other
markers (see below), and, for the PikPak place the folder would get, reads the marker there.

1. **Its ID belongs to a configured folder whose path is missing:** "This looks like '<Name>', which was at
   <old path>. Same folder, moved?" **Use this one** (exactly Locate…) or **Add as a separate folder** (goes to
   case 2's "keep both").
2. **Its ID belongs to a configured folder whose path exists** (a copy): the same-ID box.
3. **Its ID is unknown to the config but matches a folder in PikPak** (found by the encrypted list, or at the
   synced place it would get): "This folder was synced before, as '<name>' (<size> in PikPak). Reconnect to it?"
   **Reconnect** adds it with that place (and, for an encrypted folder, that `Name`); the first sync merges.
   **Start a new copy** gives it a new ID and a new place.
4. **No marker, but the PikPak place it would get already holds a marker with a different ID, or (encrypted) a
   folder with that name exists:** never joined silently. "PikPak already has a folder called '<name>' that
   belongs to another folder. Reconnect to it, or start a new one?" New gets the next free name.
5. **Nothing found:** added as today, with a new ID.

**The kind recorded in the marker wins over the kind ticked in the box.** A folder whose marker (or PikPak copy)
says encrypted is reconnected as encrypted, and the box says so: "This folder was encrypted before; it will be
reconnected encrypted." It is never added readable from here; to make it readable, reconnect it and then use
Remove encryption (the existing change job). A folder whose marker says synced but is ticked "Encrypt" is
reconnected as synced with the same note; making it encrypted is the existing Make encrypted job, which deals
with the readable copy in PikPak.

**Markers deeper inside the chosen folder** (someone moved `xyz` into a new parent and now adds the parent): the
app lists them in the box: "Inside it is '<Name>', which is synced separately / was synced before." Nested
configured folders follow the existing overlap rules; an unconfigured one is just part of the new folder, and its
marker is left as it is (only the top marker matters). The scan is not depth-limited when the folder size is
measured anyway; otherwise it stops at the same limits the size measurement uses.

### Encrypted folders inside a moved folder: never uploaded readable

A synced folder excludes encrypted folders by their configured paths. If `D:\stuff` (synced) is moved to
`E:\stuff` with the encrypted folder `D:\stuff\Private` inside it, that path is stale, and a Locate of the parent
would upload `Private` readable. Two guards:

1. **The marker excludes it, whatever its path.** An encrypted folder's marker has its own file name,
   `.pikpak-encrypted.json` (same contents, `kind: encrypted`), and every synced folder's sync excludes any
   directory containing that file (`--exclude-if-present .pikpak-encrypted.json`). Checked on 2026-11-19 with
   rclone v1.75.2 on two local folders: bisync honours it on --resync and on normal runs, also for a folder
   moved in after seeding. Encrypted folders' own syncs never get this flag (their top holds that file). When an
   encrypted folder is changed to synced (Remove encryption), its marker is renamed to `.pikpak-sync.json`
   before that folder's sync (the sync writes the kind's file name and removes the other).
2. **Locate and Add notice it.** When the nested scan finds an encrypted marker whose configured folder is
   missing, the box offers to relocate both in one confirmation ("Private moved with it: update it too"). The
   parent is not switched without the inner one.

### The same-ID box (owner's decision)

Shown whenever two folders on the PC carry the same ID: when adding, on Locate…, and from a `folder-duplicate-id`
issue. It shows both paths, sizes and last-changed dates, and offers:

- **Keep <path A> only.** The other is not added (or, from the issue, its config entry is removed). Nothing in
  PikPak changes.
- **Switch to <path B>.** As Locate…: B takes over the folder's ID and PikPak place; A is no longer synced (its
  files stay on the PC).
- **Keep both.** The owner picks which one keeps the current ID and PikPak place (default: the one already
  configured). After a confirmation ("<path> gets a new ID and will be uploaded as a new folder, <size>"), the
  other gets a new ID: its marker is rewritten and it is added as a new folder, with its own place in PikPak (a
  synced folder gets its path-derived place, adjusted with a suffix if that is taken; an encrypted folder gets
  the next free name).

**Give a new ID** is also on every row's menu, with the same confirmation, for the owner to split a folder from
its PikPak copy on purpose. (It moves nothing in PikPak; the folder starts a new copy, and the old one shows up as
not connected in the encrypted list, or stays at its old synced place.)

### Encrypted folders in PikPak (Settings)

A section under the encrypted folders list, loaded when opened (one `rclone lsf --dirs-only private:`, then one
`rclone cat` per folder for its marker; `_holding` left out):

```
Encrypted folders in PikPak
  PrivateMock     12 MB    Connected to D:\PrivateMock
  Album          310 MB    Connected to H:\...\Album
  OldStuff        48 MB    Not connected        [Reconnect…] [Download a copy…] [Delete from PikPak]
```

- **Connected** is by ID (the marker's `id` matches a config entry), or by name for an entry that has no marker
  yet.
- **Reconnect…:** pick a folder on this PC; then the same checks as *Adding a folder* case 3. An empty or new
  folder is the normal choice (everything downloads, within the daily limit); a folder with files merges.
- **Download a copy…:** pick an empty folder; a detached job runs `rclone copy private:<Name> <folder>` within
  the transfer budget and notifies when done. The folder is not added to syncing.
- **Delete from PikPak:** a confirmation naming the folder and size; purges exactly `private:<Name>` (the
  existing purge guard applies: never a root, never `_holding`); it goes to PikPak's trash.
- Without a recovery key on this PC the section says so and lists nothing.
- The "Stop syncing" box of an encrypted folder says: "Its encrypted copy stays in PikPak. You can reconnect it
  or delete it in Settings, Encrypted folders in PikPak."

### Pause a folder (owner asked, 2026-11-19)

"Stop syncing" removes a folder from Home at once; bringing it back means adding it again, which for an
encrypted folder is the risky path above. The owner often only wants a folder to rest for a while.

- Every folder's menu gets **Pause syncing** (next to Stop syncing, not marked danger, no confirm box needed).
- The config entry (`Pairs` / `PrivatePaths` item) gets `Paused = $true`; Resume removes the field.
- A paused folder stays on Home, greyed, pill "Paused", with a **Resume** button on the row.
- The sync skips it entirely: no marker check, no "missing" issue, no notification; it does not count toward
  the run's result, the stale-run warning (`StaleRunDays`) or "needs attention". Its state (`state.json` entry,
  filter file, bisync lists) is kept, so Resume continues with a normal sync, not a merge, and uploads only
  what changed.
- **An encrypted folder stays excluded from any synced folder around it while paused.** The exclusion comes
  from `PrivatePaths` whether or not the entry is paused, so pausing never lets its files out readable.
- Pause and Resume refuse while a sync is running (the existing answer), and work in preview mode.
- The "keep at least one folder" rule does not apply to Pause. When every folder is paused, Home says "All
  folders are paused" instead of an all-good state.
- Its files in the deleted-files area (holding) keep expiring as usual.
- Stop syncing's box mentions the choice: "To stop for a while instead, use Pause syncing."

### Rules that apply throughout

- Every change that touches the config or PikPak refuses while a sync is running (existing "a sync is running"
  answer) and works in preview mode, listing what would happen.
- Live tests use folders of 1 MB or less (free account).

## Left to the builder

- Layout and exact wording, in the app's existing style ("sync", "Encrypted", "Repair").
- Action, function and issue-kind names beyond the two named above, if better names fit the code.
- How sizes in the PikPak list are measured (`rclone size` per folder, or from the listing) and cached.
- Whether the first-start ID migration runs in the app or in the next sync, as long as it is one config save.
- The suffix scheme for a synced folder's place when the path-derived one is taken.
