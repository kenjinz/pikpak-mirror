# PikPak Mirror — live verification (Task 10)

Run 2026-10-24 on the free test account (6 GiB), rclone v1.75.2, WinFsp 2.1, Windows 11 Pro.
Config: `config/mirror.test.local.psd1` (gitignored). Every remote root sits under `PikPakMirror-Test/`.
- `pikpak` = alias of the pre-existing remote `Pikpak remote:`
- `private-test` = crypt with a throwaway key
- pair `T1`: `D:\pikpak-test\Sync` ⇄ `Test/Sync`
- private `D:\pikpak-test\Secret`
- `RunBudgetGB=1`, `HoldingDays=1` (the validator rejects 0, so prune was tested with a planted old date folder)

## Spec §8 checklist

| # | Check | Result |
|---|---|---|
| 1 | Add/edit/delete/rename on the PC → PikPak | **PASS**. Overwritten, deleted and renamed-away files went to `PC-Holding/2026-10-24/T1/...` |
| 2 | Changes in PikPak → PC | **PASS**, simulated with rclone writes to the remote (add, edit, delete, rename). Old local versions went to `D:\pikpak-test-holding\2026-10-24\T1\...`. Not yet repeated from the phone app. |
| 3 | Deleted files in both holding areas; prune | **PASS**. Planted `2026-09-01` folders were removed from local, remote and private holding. Today's folder stayed, including a file with a 2024 modtime (C1 fix). |
| 4 | Edit on both sides keeps both versions | **FAIL → fixed.** PikPak reports no modtimes (`Precision` = ModTimeNotSupported), so bisync ignores `--conflict-resolve newer` and renames both copies. Now `--conflict-resolve path1`. Re-test: PC version keeps the name, phone version is `c2.txt.conflict1`. |
| 5 | Local folder missing | **PASS**. Pair skipped, "Folder missing" toast, no remote deletes (36 files kept). |
| 6 | Remote emptied | **PASS (safety)**. Exit 7 "empty current Path2 listing", 0 local deletes. Gap fixed: plain-language toast, `Invoke-Sync.ps1 -Resync <Name>` (re-test: restored remote, then a clean normal run), README "A folder keeps failing". |
| 7 | Private: gibberish names; readable on Q: | **PASS**. `PC-Private/rlk74…/omkg2…`; `Q:\Secret\sub\note.txt` reads back; writing to Q: fails with "write protected". |
| 8 | Offload | **PASS**. File and folder: gone locally, present in `Archive/Test/Sync/...`, absent from `PC-Mirror`; next bisync "No changes found". |
| 9 | Kill rclone mid-upload → next run completes | **FAIL → fixed (3 problems):** (a) stale bisync `.lck` blocked runs for 2 h → cleared while holding our lock (verified live); (b) killed run counted 0 bytes → bytes = max(stats, Σ Copied sizes) + `--stats 30s`; (c) PikPak keeps hidden unfinished uploads that block those file names ("uploaded file name mismatch"). Not deletable with rclone, still present after 40 min. Ctrl+C / normal shutdown cleans up (verified). Detected now, with toast, auto-resync and README "Stuck uploads" (rename on the PC). Re-test: toast names `part1.bin`, everything else synced; after renaming the file on the PC the next run was clean. |
| 10 | Budget stops the run | **FAIL → fixed (root cause: units).** rclone reads a bare `--max-transfer` number as KiB, so `8589934592` meant 8 PiB and the budget never applied. Now `<bytes>B`. Also: inside bisync the cutoff is exit 7 + "must resync" (never 8), so a budget hit is now a quiet stop + `--resync` next run. `cautious` mode (overshoot ≤ 3 in-flight files), MonthlyBudgetGB 230. Re-test: 150 MB left, 6×40 MB → 4 uploaded, quiet stop (`Skipped: budget`), next run uploaded the other 2 and was seeded again. |
| 11 | Log off/on → mount + sync | **Deferred to go-live** (tasks are registered by the user's Install.ps1 run). Start-Mount: both drives up in ~4 s and stay up after the script exits. |
| 12 | Many-small-files timing | 300 tiny files uploaded in 5 m 11 s (≈1 file/s); `lsf -R --fast-list` of 310 entries 1.8 s. a folder of 230,679 small files → ≈64 h first upload. Decision: stays a priority-5 pair (runs last; seeded pairs first). |

## Amendment checks

| Check | Result |
|---|---|
| `copyto --ignore-existing` sentinel on an existing object | PASS (exit 0). `touch` on it fails: "can't set modified time". |
| single-file check against the parent folder | PASS (offload of `archive-file.bin`) |
| brace exclude syntax on PikPak | PASS (check 3) |
| `move`/`moveto` with `--backup-dir` | PASS (offload) |
| bisync `--ignore-case` | PASS (all runs) |
| exit 8 mid-bisync, then clean next run | bisync reports a budget cutoff as exit 7 (never 8). Handled: quiet stop + `--resync` next run. Verified live. |
| final JSON stats line parsed | PASS (TransferredBytes matched the 169 MiB first upload) |
| old file deleted on the phone stays in holding | PASS (2024-modtime file kept in today's holding) |

## Other observations
- winget has no rclone 1.75.2 (max 1.75.1). Install.ps1 now downloads the official zip and checks its SHA256.
- PikPak's MD5 is empty in listings (`lsf --hash MD5`), which confirms size+modtime compare.
- Same-size edits made on the PikPak side are not detected (size-only on Path2). Documented.

## Open items
- **PikPak MCP (Step 1):** waiting for the MCP address from the user (PikPak *Settings → Access & Integrations → MCP*).
- **Check 2 from the phone app:** optional user check, to confirm the app's uploads behave like rclone's.
- **Check 11 (log off/on):** at go-live, after the user's own `Install.ps1` run registers the tasks.
- **Hidden unfinished uploads:** re-checked 2026-10-25 (~18 h later) with 30-byte files: all three names still refused ("got part2(1).bin"). PikPak does **not** expire them; renaming on the PC (README "Stuck uploads") is the fix.
- **PikPak trash and quota:** 5.2 GiB used vs 3.45 GiB live + 0.58 GiB trash. `--pikpak-use-trash=false` did not keep deleted files out of the trash listing. Check whether emptying the trash in the PikPak app frees space.
- **Remote `pikpak`:** on this PC it is an alias of `Pikpak remote:`. If the same account is upgraded to Premium, nothing changes. For a different account, delete the alias and run Install.ps1.
- **Cleanup when done:** `rclone purge pikpak:PikPakMirror-Test`, delete `D:\pikpak-test`, `D:\pikpak-test-holding`, `D:\pikpak-parked`, `%LOCALAPPDATA%\PikPakMirror-Test`, `rclone config delete private-test`, and `Stop-Process -Name rclone` for the test mounts.
