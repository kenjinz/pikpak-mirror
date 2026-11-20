# PikPak Mirror — Design

> Status: approved design (2026-10-24). Next: implementation plan via `superpowers:writing-plans`.

## 1. Intent — why this exists

The user wants PikPak (cheap: Premium = 10 TB for ~$10/month) to be the cloud home for almost everything
on their Windows PC — mainly **images, videos and music** (top priority: images and music; re-downloading is
possible but slow). PikPak has no sync client, so we build automation on top of **rclone** (no custom sync engine).

What they really want, as uncovered:
- **Safety copy** of the PC that runs itself, with a way to undo mistakes (deletes kept 30 days).
- **Two-way sync**: files added/changed/deleted in PikPak (phone, other PC, cloud downloads) show up on the PC.
- **No double local storage**: everything not synced locally is still *browsable* from the PC as a drive letter
  and from the phone via the PikPak app — "lying in bed, browsing" is a real use case.
- **Privacy for genuinely private files** without losing phone browsing for ordinary media.

## 2. Goals / non-goals / anti-goals

**Goals**
- Nightly (evening) unattended two-way sync between chosen local folders and PikPak, plain (unencrypted).
- Separate encrypted (rclone crypt) one-way backup of the user's private folders.
- Offload: move files to a cloud-only PikPak Archive to free local disk without losing the cloud copy.
- 30-day recoverable holding area for deleted/overwritten files, on both sides.
- `P:` drive on the PC showing PikPak (plain area + decrypted private area) without local storage.
- Silent operation; Windows toast notification only on failure (or prolonged "no successful run").
- PikPak official MCP wired into this project as a dev/ops helper for Claude Code.
- Works for a second PC as a *browser/contributor* (P: drive + drop files into synced folders), not a second master.

**Non-goals**
- Full system / bare-metal image of Windows; installed programs; games; source code.
- Automated upload into **PikPak Vault** (impossible today: Vault is phone-app only, no API/WebDAV/CLI access,
  no server-side move into Vault). The user curates Vault by hand from the phone.
- A GUI/tray app or dashboard.
- Encrypting the general media library (decided against: PikPak does not proactively scan private files, and
  encryption would kill phone browsing).
- Third-party rclone MCP servers (both candidates are immature; Claude uses the rclone CLI directly instead).

**Anti-goals (would be failure even if it "works")**
- A sync run that mass-deletes local files (e.g. because PikPak returned an empty listing or a drive was missing).
- Private files ever reaching PikPak unencrypted.
- Upload saturating the connection while the user is gaming/working in the evening.
- Losing the crypt password → private backup unreadable forever.
- Hitting PikPak quota caps so hard that browsing slows to ~100 KB/s for weeks.

## 3. Facts & constraints (researched 2026-10-24)

**This PC**
| Drive | Use | Size used |
|---|---|---|
| C: | Windows + user profile `C:\Users\Alex` | 446 GB |
| D: | Main data (`Film`, `Music`, `Songs`, `Holiday Photos`, `Small Files`, `New folder`, …) | 1.27 TB |
| F:/H: | Games — excluded | — |
| G: | Dev/code — excluded (this project lives at `G:\pikpak-mirror`) | — |
- rclone **not installed**; winget available. Latest stable rclone: **v1.75.2** (2026-10-09).
- PC is on **evenings only** (shut down/asleep otherwise).
- Phone: **Android**. User will have **PikPak Premium** by the time the project is ready (develop/test on a free account).

**PikPak**
- Premium: 10 TB, monthly quota 1 TB upload / 4 TB downstream; speed cap 20 MB/s (Global).
- **Connected Apps (rclone, WebDAV, CLI) share only 25% of quota → ~250 GB upload / ~1 TB downstream per month.**
  Over the cap, speed drops to ~100 KB/s. Free accounts: 6 GB storage, 5 GB/day for connected apps.
- Private files are not proactively scanned (only shared links; known-CSAM hashing excepted).
  User Agreement §3.8 still mentions termination for "unofficial software" while the FAQ explicitly names rclone — accepted risk.
- Official **WebDAV** (Premium): cannot permanently delete or empty Trash. Kept as fallback backend.
- **rclone `pikpak` backend**: Tier 1; stores modtime on upload, cannot change modtime afterwards;
  **MD5 hashes not returned in practice (rclone issue #9826)** → compare by **size + modtime**, never checksum.
- **PikPak MCP**: remote MCP server; address copied from *Settings → Access & Integrations → MCP*; browser authorization;
  default perms: read, upload, organize, create cloud-download tasks. Alpha (Aug 2026) — availability may vary.
- **Vault**: E2E encrypted, 100 GB with Premium, expandable via Additional Storage; phone apps; no automation path.

**Local data scope (initial)**
- Included: all of `D:\` **except** `D:\Game`, `D:\One drive`, and temp junk (`msdownld.tmp`, `OneDriveTemp`,
  `.__capcut_export_temp_folder_*`). ≈ 870 GB.
- Included: `C:\Users\Alex\{Documents,Pictures,Videos,Music}` *(my call — user said "everything except code")*.
  `Downloads` excluded *(my call: short-lived installers would burn the upload budget)*.
- **Private paths**: the user's private files already live in a few specific folders (to be named during setup).
  Those folders are excluded from the plain sync and go to the encrypted backup instead (see 5.2).
- Global excludes: `Thumbs.db`, `desktop.ini`, `~$*`, `*.tmp`, `*.partial`, `$RECYCLE.BIN`, `System Volume Information`.

## 4. Decisions made with the user

1. **Tool**: rclone is the core. No custom sync engine.
2. **Encryption**: media stays **plain** (browsable in PikPak app). A local **Private** folder gets an **rclone crypt** backup.
   User additionally hand-uploads phone-viewable private items into **PikPak Vault**.
3. **Two-way sync**: full — adds, edits, deletes, renames flow both directions.
4. **Deletes/overwrites**: kept recoverable **30 days**, then purged.
5. **Schedule**: runs while the PC is on in the evening; catches up missed runs; interrupted uploads resume next run.
6. **Mode**: invisible; Windows notification only on problems.
7. **Second PC**: P: drive to browse + may add files into synced folders; this PC remains the master.
8. **PikPak MCP**: wired into this project as dev/ops helper. **No rclone MCP** (Claude runs the rclone CLI directly).
9. **Private files**: already in a few specific folders; those folders become the encrypted set.
10. **Offload**: yes — a cloud-only **Archive** in PikPak; offloading frees local space without deleting the cloud copy.

Builder-check calls (mine, flagged for the user to verify):
- PikPak account is created with **email + password** (not Google/Apple sign-in) — rclone needs a password.
- Vault curation = **copy** into Vault, never *move* out of `PC-Mirror` (a move = deletion → PC copy purged after 30 days).
- Files added on the phone / via cloud download reach the PC **only if saved under `PC-Mirror/...`**; everything else in
  PikPak (Archive, cloud-download default folder, phone camera backup) stays cloud-only and is browsed via `P:`/app.

## 5. Architecture

```
            ┌──────────── this PC (master) ─────────────┐
D:\Music …  │ rclone bisync (plain, size+modtime) ◄────►│  pikpak:/PC-Mirror/D/Music …
C:\Users\…  │                                            │  pikpak:/PC-Mirror/C-Users/…
private dirs│ rclone sync ──► crypt ─────────────────────►│  pikpak:/PC-Private (encrypted names+content)
offload     │ Move-ToArchive (server-side move) ────────►│  pikpak:/Archive (cloud-only)
            │ rclone mount  P:\  ◄── pikpak:/  (+ private:/ decrypted, read-only)
            └───────────────────────────────────────────┘
holding area: local  D:\.pikpak-holding\YYYY-MM-DD\...    remote pikpak:/PC-Holding/YYYY-MM-DD/...
phone: PikPak app browses PC-Mirror directly; Vault = manual, separate.
```

### 5.1 rclone remotes (in `%APPDATA%\rclone\rclone.conf`)
- `pikpak` — type `pikpak`, user's account.
- `private` — type `crypt`, wraps `pikpak:/PC-Private`, filename + directory-name encryption, password + salt.
- (fallback, not used by default) `pikpak-dav` — type `webdav` against PikPak official WebDAV.

### 5.2 Sync jobs (each a "pair" in config)
- **Pairs** = one rclone `bisync` per top-level folder (e.g. `D:\Music` ⇄ `pikpak:/PC-Mirror/D/Music`), so a failure or
  `--resync` in one folder doesn't touch others, and priority ordering is possible.
- bisync flags (baseline): `--compare size,modtime`, `--conflict-resolve newer --conflict-loser num`,
  `--backup-dir1 <local holding>/<date>`, `--backup-dir2 pikpak:/PC-Holding/<date>`,
  `--max-delete 10` (percent; abort if more), `--check-access` with `RCLONE_TEST` sentinel files on both sides,
  `--resilient --recover`, `--max-lock 2h`, `--fast-list` where supported, filter file for excludes.
- **Private**: config holds a list `PrivatePaths` (the user's existing private folders, e.g. `D:\New folder (3)` — real
  list entered during setup). Each is (a) **excluded** from every plain bisync pair via generated filter rules, and
  (b) one-way synced: `rclone sync <path> private:/<name> --backup-dir private:/_holding/<date>` (holding stays inside
  crypt, so it stays encrypted). One-way: phone can't write into crypt anyway.
- **Safety gate**: `Invoke-Sync.ps1` refuses to run any plain pair until `PrivatePathsConfirmed = $true` is set in config
  (set by the installer after the user names/confirms the folders). Each run re-checks that no plain pair's source
  contains a private path (path-prefix check) and aborts with a toast if one does. Private set is seeded **first**.
- **Archive (offload)**: `pikpak:/Archive` mirrors the `PC-Mirror` folder structure but is outside any sync pair
  (cloud-only). `scripts/Move-ToArchive.ps1 <local path>`:
  1. ensure the path is fully uploaded (`rclone check --size-only` against its `PC-Mirror` counterpart; upload if not);
  2. server-side move `pikpak:/PC-Mirror/<rel>` → `pikpak:/Archive/<rel>`;
  3. delete the local copy (no local holding needed — cloud copy exists);
  4. next bisync sees the item gone on both sides → no-op.
  Plus an Explorer right-click entry "Offload to PikPak Archive" (HKCU shell verb) calling the script. Restoring = copy
  back from `P:\Archive\...` into the local folder. If server-side move isn't supported by the pikpak backend, fall back
  to copy-then-delete (builder verifies).
- **Pruning**: each run deletes everything in the three holding areas except the date folders of the last `HoldingDays` days (`rclone delete <holding> --exclude "/{<today>,…}/**" --rmdirs`). Pruning goes by the holding folder's date, never by file age, because moved files keep their original modtime.
- **First run / seeding**: bisync `--resync` per pair, ordered by priority: photos (`Holiday Photos`, Pictures) → music
  (`Music`, `Songs`, `Soundtracks…`, `Lessons`) → documents → videos/rest.

### 5.3 Quota & bandwidth management
- Per-run upload budget via `--max-transfer` (default **8 GB/run ≈ 250 GB/month**) with `--cutoff-mode soft`, so seeding
  spreads out (~3.5 months for ~870 GB) instead of tripping the 100 KB/s penalty. Configurable.
- `--bwlimit` timetable so evening use isn't hurt (default: e.g. 2 MB/s up during 18:00–23:00, unlimited otherwise;
  configurable). Exact numbers = builder's call after measuring the user's line.
- Remaining budget tracking: script records bytes uploaded per calendar month in a state file and skips/limits runs
  near the cap; warns via toast at 90%.

### 5.4 Scheduling (Windows Task Scheduler)
- Task `PikPakMirror-Sync`: triggers = at logon (+15 min delay) **and** daily 20:00; "run as soon as possible after a
  missed start"; "do not start a new instance" if running; run only when user logged on (needs user profile + mount).
- Task `PikPakMirror-Mount`: at logon, runs `rclone mount` for `P:` (requires **WinFsp**), with `--vfs-cache-mode full`,
  bounded cache (`--vfs-cache-max-size 20G`, `--vfs-cache-max-age 24h`) on D:, `--read-only` for the private mount.
- Single-instance lock file; graceful stop on shutdown is not required (bisync `--recover` handles interruptions).

### 5.5 Notifications & logs
- Logs: `%LOCALAPPDATA%\PikPakMirror\logs\YYYY-MM-DD.log` (rclone `--log-file`, `--log-level INFO`), kept 60 days.
- Toast (via PowerShell + Windows notification API; BurntToast module acceptable) on: any job error, bisync abort
  (max-delete / check-access / needs resync), quota ≥90%, no successful run for 3 days.

### 5.6 PikPak MCP (dev/ops)
- Project-scoped `.mcp.json` in `G:\pikpak-mirror` with an HTTP MCP server entry named `pikpak`, URL taken from the
  user's PikPak settings (added once the account exists; `claude mcp add --transport http --scope project pikpak <url>`).
- Used by Claude to verify uploads, inspect folder layout, check storage, and later to create cloud-download tasks.
- Not used by the scheduled jobs.

### 5.7 Second PC
- Same installer with a `-Role Viewer` switch: installs rclone + WinFsp, configures `pikpak` and `private` remotes,
  mounts `P:` at logon. No bisync jobs. Files it writes via `P:` into `PC-Mirror` reach the master via bisync.

### 5.8 Key safety
- Setup prints the crypt password + salt once and walks the user through saving them in a password manager and on paper;
  `docs/RECOVERY.md` explains restoring on a fresh PC.
- rclone.conf stays in the user profile (crypt secrets are only obscured there — accepted; PC compromise = game over anyway).

## 6. Project layout (`G:\pikpak-mirror`, git repo)

```
config/mirror.config.psd1     # pairs, priorities, excludes, budget, bwlimit, holding days, private path
config/filters.txt            # rclone filter rules
scripts/Install.ps1           # winget rclone + WinFsp, rclone config walkthrough, tasks, sentinel files
scripts/Invoke-Sync.ps1       # main job: lock, budget, per-pair bisync, private sync, prune, notify
scripts/Start-Mount.ps1       # P: mount(s)
scripts/Get-Status.ps1        # last runs, errors, quota used — for humans & Claude
scripts/Move-ToArchive.ps1    # offload a local file/folder to cloud-only Archive (+ Explorer context-menu verb)
scripts/lib/*.ps1             # config loading, logging, toast, quota state
tests/*.Tests.ps1             # Pester: config parsing, command-line building, budget logic
docs/RECOVERY.md, README.md
.mcp.json                     # PikPak MCP (added after account exists)
```
- Language: **PowerShell 5.1** (built in; matches the machine). Scripts build rclone argument lists; logic is unit-tested
  with Pester by asserting generated arguments (no real network in unit tests).

## 7. Left to the builder
- Exact bwlimit numbers, toast mechanism, log format, state-file format.
- Whether a folder of very many tiny files (230k) stays a normal bisync pair or becomes weekly one-way, if listing/transfer
  proves too slow (test it).
- Whether to try **seeding faster** by uploading plain media with the official PikPak desktop app (full 1 TB/month
  quota) and then `bisync --resync --compare size` — only if a small test proves rclone accepts it without re-uploading.
- Switching a pair to the WebDAV fallback if the pikpak backend misbehaves.

## 8. Verification
1. Pester unit tests pass (`Invoke-Pester tests`).
2. On a **free test account** with a scratch folder (`D:\pikpak-test`, a few hundred MB incl. nested dirs, unicode names):
   - first `--resync`; add/edit/delete/rename on PC → appears in PikPak; same from PikPak web/phone → appears on PC;
   - deleted file lands in both holding areas and survives there for HoldingDays even if the file itself is years old; prune removes date folders older than N (test with `HoldingDays=1` and a back-dated folder);
   - conflict (edit both sides) keeps both versions;
   - simulate empty remote / missing drive → run aborts with toast, no local deletes;
   - private: file appears encrypted in PikPak web UI, readable via `P:`; a private folder is never present in plain
     `PC-Mirror`; with `PrivatePathsConfirmed = $false` the plain pairs refuse to run;
   - offload: `Move-ToArchive` on a test file → gone locally, present in `P:\Archive`, absent from `PC-Mirror`,
     next bisync is a no-op;
   - kill the job mid-upload → next run recovers;
   - budget: tiny `--max-transfer` stops the run cleanly and records usage.
3. Task Scheduler: log off/on → mount appears, sync runs; missed 20:00 run fires after next logon.
4. Claude checks results through PikPak MCP (folder listing matches local) and `rclone check --size-only`.
5. Then switch config to Premium account + real folders, seed in priority order, watch the first week of logs.
