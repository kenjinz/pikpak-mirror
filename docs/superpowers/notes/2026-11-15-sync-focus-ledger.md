# Sync-focus ledger

## Task 0: baseline and live crypt bisync check (2026-11-15)

### Baseline (branch feat/sync-focus, before any code change)

`tests\run.ps1` (Pester 5.7.1): Passed 513, Failed 1, Skipped 0, Inconclusive 0, NotRun 0.
Failing: `J3: the shipped config keeps a 20 GB margin under the ~250 GB app limit` (known, pre-existing, Config.Tests.ps1).

### Setup

- rclone v1.75.2. `Test-SyncRunning -StateDir <StateDir>`: False. `PikPakMirror-Sync` was **enabled** (state Ready) before the check; disabled during it.
- Flags: `New-BisyncArgs` set minus `--max-transfer`, `--bwlimit`, `--filters-file`; `--use-json-log`/`--stats` dropped, `-v --log-file` used instead.
  Flags used: `--compare size,modtime --conflict-resolve path1 --conflict-loser num --max-delete 10 --backup-dir1 <scratch>\hold --backup-dir2 private:_holding/_synctest --cutoff-mode cautious --ignore-case --workdir <scratch>\bisync --max-lock 2h --check-access --resilient --recover`.
- `--check-access` needs `RCLONE_TEST` on both sides: it was placed locally and copied once with `rclone copyto RCLONE_TEST private:_synctest/RCLONE_TEST` before check 1.
- Scratch: a scratch folder (`t0`) (logs `log-*.txt`, runner `run.ps1`).

### Checks

| # | Command (bisync args as above, local `<scratch>\synctest` <-> `private:_synctest`) | Observed | Result |
|---|---|---|---|
| 1 | `bisync ... --resync` with a.txt b.txt c.txt (+RCLONE_TEST) | "Bisync successful", 3 files transferred. `rclone lsf private:_synctest` lists a/b/c.txt. `rclone lsf pikpak:PC-Private -R` shows only scrambled names, no plain `a.txt` | PASS |
| 2 | add `d.txt` locally; `bisync ...` | exit 0, `d.txt` listed in `private:_synctest` | PASS |
| 3 | `rclone copyto e-src.txt private:_synctest/new.txt`; `bisync ...` | exit 0, `new.txt` present locally | PASS |
| 4 | `rclone cryptdecode --reverse private: _synctest/b.txt` -> `<encrypted dir name>/<encrypted file name>`; decoded back to `_synctest/b.txt`; `rclone deletefile pikpak:PC-Private/<that>`; `bisync ...` | First run with `--max-delete 10`: exit 1, `ERROR : Safety abort: too many deletes (>10%, 1 of 6) on Path2 "private:_synctest/". Run with --force if desired.` (1 of 6 files is 16%, a size artifact of the tiny test set, not a crypt problem). Re-run with `--max-delete 50` (only flag changed): exit 0, `b.txt: Moved into backup dir`, `<scratch>\hold\b.txt` exists, local b.txt gone | PASS (needed `--max-delete 50` for the 6-file set) |
| 5 | delete local `c.txt`; `bisync ... --max-delete 50` | exit 0, `c.txt: Moved (server-side)` / `Moved into backup dir`; `rclone lsf private:_holding/_synctest -R` -> `c.txt`; gone from `private:_synctest` | PASS |
| 6 | empty local except RCLONE_TEST; `bisync ... --max-delete 50 --resync` | exit 0, "Bisync successful"; local has a.txt d.txt new.txt RCLONE_TEST back; remote still a.txt d.txt new.txt RCLONE_TEST (nothing deleted remotely) | PASS |

Notes: bisync works on the crypt remote with the production flag set. The only deviation was `--max-delete` raised to 50 for checks 4b-6 because the test set has 6 files; production percentages on real folders are unaffected. PikPak modtime limits did not cause failures.

### Cleanup

- `rclone delete private:_synctest --rmdirs` exit 0; `rclone delete private:_holding/_synctest --rmdirs` exit 0.
- Empty leftover dirs `private:_synctest`, `private:_holding/_synctest` and `private:_holding` (all created by this check, none existed before) removed with `rclone rmdir`. `rclone lsf private:` shows only the pre-existing `.iv-previews/ ImageVisualizerEval/ PrivateMock/`.
- Nothing else touched on the account. PikPak may keep the deleted tiny files in its own trash (not visible via rclone, a few hundred bytes).
- Scratch folder on PC left in place (tiny files and logs).

### Final state

`PikPakMirror-Sync` re-enabled; state Ready (was enabled before). `PikPakMirror-Mount` untouched.

## Task 9: docs, build (2026-11-16)

### Docs

`docs\README.md` rewritten (two kinds of folder, hourly sync and the interval setting, daily and monthly limits, deleted files for both kinds, Repair, second-app rule, one-time cleanup and hand cleanup, removal). `docs\RECOVERY.md` (new PC: Install.ps1 with the recovery key, add folders again, Repair or `rclone copy`; PC-side deleted-file copies are lost with the disk). `docs\OPEN-REQUIREMENTS.md` (R4, V5 and the drive part of V2 dropped; R8 covered; R1 uses `DailyBudgetGB`; new checks V10 to V18). `docs\HANDOFF.md` (what changed, not merged, "after you merge to main" checklist).

### Suite and build

- `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1`: Passed 582, Failed 1, Skipped 0. The one failure is `J3: the shipped config keeps a 20 GB margin under the ~250 GB app limit` (known).
- `cargo test` (gui\src-tauri): 24 passed, 0 failed, 2 ignored.
- `cargo tauri build` (gui): success in 2m 33s. App: `gui\src-tauri\target\release\pikpak-backup.exe`. Installer: `gui\src-tauri\target\release\bundle\nsis\PikPak Sync_0.1.0_x64-setup.exe` (2.49 MiB). Neither was started.

### Live check on the real install: deferred until after merge

Not done in this task, by the controller's decision. It will be done with the owner after the merge, with files of a few KB in new check folders (one synced, one encrypted). Still to check:
1. Start the built app: `P:`/`Q:` gone, task `PikPakMirror-Mount` and the right-click entry gone, `PikPakMirror-Sync` repeats hourly.
2. Wait for one scheduled run; it happens by itself.
3. Synced folder: a file uploaded in the PikPak web app arrives on the PC; a file deleted on the PC appears in "Get back a deleted file" and restores.
4. Encrypted folder: PikPak shows only scrambled names; a scrambled file deleted in the PikPak web app disappears from the PC at the next sync and appears in the deleted list; restoring it brings it back and the next sync uploads it.
5. Empty the encrypted folder on the PC, sync (stops with "the PC folder is empty"), press Repair: the files come back.
6. Two syncs with the same unsolved problem: one notification.
7. Also: the daily limit stop, the old autostart entry migration, the first two-way run of `PrivateMock`.
8. Remove the two check folders from the app; list what is left in PikPak for the owner to delete.
