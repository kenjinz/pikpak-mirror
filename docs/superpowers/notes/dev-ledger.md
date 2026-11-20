# SDD ledger — plan: docs/superpowers/plans/2026-10-24-pikpak-mirror.md

Scope this session: Part 1 = Tasks 1–8 (user instruction). Stop after Task 8 + Part-1 review; report before Task 9.
Spec: docs/superpowers/specs/2026-10-24-pikpak-mirror-design.md (reachable).
Branch: feat/part1-engine (from main 14cd2d5 — docs-only initial commit).

## Pre-flight scan

| Tasks | Produces → consumes | Finding |
|---|---|---|
| T1→T2,T6 | Get-MirrorConfig keys → New-PairFilterRules -GlobalRulesPath | No config key for filters.txt path. R1 |
| T1 | .gitignore create vs setup already created .gitignore | T1 must append. R2 |
| T1 | Step 1 git init vs repo already initialised in setup | R2 |
| T3→T5 | builders take -LogFile → Invoke-Rclone reads value after `--log-file` | Tests don't pin `--log-file`; private sync needs JSON stats too. R3 |
| T3 | New-PrivateSyncArgs: budget but no bwlimit/cutoff | Spec 5.3 bwlimit for evening use applies to all uploads. R4 |
| T4→T6 | State.Pairs shape → Run.ps1 reads Seeded/FilterHash | Shape unspecified (hashtable vs object). R5 |
| T4 | Get-RunBudget "applying the month reset" | Mutating vs pure ambiguous. R6 |
| T5 | Send-MirrorToast -Title -Message "failures written to the log" | Needs config for log path. R7 |
| T6→T7 | filters file `<StateDir>\filters\<Name>.txt` → T7 "pair's current filters file" | No shared helper named. R8 |
| T6 | step 4 budget 0 "stop" vs test "Invoke-Rclone 0 times" | Consistent (stop = skip prune too). OK |
| T6 | step 5 exit 8 → step 7 | Consistent with "exit 8 keeps pair unseeded and stops remaining pairs". OK |
| T7 | forced bisync budget | Unspecified. R9 |
| T7 | copy/check args | No builder in T3; build in Archive.ps1. R10 |
| T8 | Confirm-PrivatePaths uses `rclone lsf` output | Invoke-Rclone returns no stdout. R11 |
| T1..T8 each | self-consistency of tests vs code vs files | T1–T5, T7, T8 internally consistent; T6 consistent after R8. |

## Rulings
- R1 Ruling: add config key `GlobalFiltersFile='filters.txt'`; Get-MirrorConfig resolves relative paths in it against the config file's directory to an absolute path — the filter file must be locatable from any working dir — cost if wrong: one extra key.
- R2 Ruling: repo + .gitignore already created in setup (contains `.superpowers/`, `.claude/settings.local.json`); T1 skips `git init` and appends `logs/`, `*.local.psd1`, `.pikpak-*` — cost: none.
- R3 Ruling: New-BisyncArgs, New-PrivateSyncArgs, New-PruneArgs, New-ArchiveMoveArgs all emit `--log-file <LogFile>`; bisync and private sync also emit `--use-json-log --stats-log-level NOTICE` — budget accounting needs bytes from every transferring command — cost: none.
- R4 Ruling: New-PrivateSyncArgs also emits `--cutoff-mode soft` and `--bwlimit <BwLimit>` — spec 5.3 evening bandwidth protection — cost: private seed slightly slower in evenings.
- R5 Ruling: State is a PSCustomObject; `Pairs` is a hashtable name → hashtable @{Seeded;FilterHash;LastExit;LastRun}; `NotifiedUnmapped` string[] — cost: refactor in T6 if wrong.
- R6 Ruling: Get-RunBudget is pure (computes as-if reset when Month ≠ Now's month); only Add-TransferredBytes mutates — cost: none.
- R7 Ruling: Send-MirrorToast gets optional `-Config`; on failure it calls Write-MirrorLog when Config given, else Write-Warning — cost: none.
- R8 Ruling: T6 produces `Update-PairFilterFile -Config -Pair -> pscustomobject @{ Path; Hash }` in Run.ps1 (writes `<StateDir>\filters\<Name>.txt`); T7 reuses it — cost: none.
- R9 Ruling: T7's forced bisync uses `RunBudgetGB` bytes (not monthly remainder) and records transferred bytes via Add-TransferredBytes + Save-MirrorState — an offload bisync transfers ~nothing; refusing offload at month-end budget would be wrong — cost: tiny budget overshoot.
- R10 Ruling: T7 builds copy/copyto and `check --size-only --one-way` args inside Archive.ps1, each with `--log-file` — cost: none.
- R11 Ruling: Confirm-PrivatePaths calls `& rclone lsf` directly (interactive, untested script) — cost: none.

## Progress
- Task 1: Ruling: pair name `Music (C-Users)` for C:\Users\Alex\Music (brief's "Name = folder name" collides with D:\Music under the duplicate rule) — names must be unique; cost if wrong: rename + one filters file.
- Task 1: Ruling: callers must wrap `@(Test-MirrorConfig ...)` (errors emitted unrolled) — carry into T6 dispatch — cost: none.
- Task 1: minor (deferred): _load.ps1 silently skips missing lib files (fail loud instead).
- Task 1: minor (deferred): Config.Tests New-TempConfig leaves pmcfg-* temp dirs (no cleanup).
- Task 1: minor (deferred): duplicate/_holding test asserts count only, not messages.
- Task 1: minor (deferred): undefined %VAR% left literal without validation error.
- Task 1: minor (deferred): ConvertTo-PrefixKey null error when Local/Path missing (validator could report cleanly).
- Task 1: complete (commits 14cd2d5..ae5ab15, review clean)
- Ruling: tests run with `-ExecutionPolicy Bypass` (machine policy blocks unsigned scripts) — added to constraints; Install/tasks already use Bypass — cost: none.
- Ruling (R12/R13 added to constraints): filter files UTF-8 no BOM; array-returning funcs emit unrolled.
- Task 2: minor (deferred): no test for non-ASCII global rule read from BOM-less file; Get-TextHash lacks empty/non-ASCII tests; cosmetic Where-Object in loop.
- Task 2: complete (commits ae5ab15..94e247e, review clean)
- Task 3: minor (deferred): Join-Path on D:\ paths throws on machines without D: (tests not portable); use string concat/[IO.Path]::Combine.
- Task 3: minor (deferred): --max-transfer 0 emitted if BudgetBytes 0 — T6 skips at 0, T7 uses RunBudgetGB (R9); no guard in builder.
- Task 3: minor (deferred): P:/Q: + VFS sizes hardcoded (constraints dictate; no config keys).
- Task 3: complete (commits 94e247e..f2627b9, review clean)
- Task 4: minor (deferred, triage at final review): $script:BytesPerGB read at call time — if called from a different script scope the budget silently becomes 0 (stall); prefer literal 1GB.
- Task 4: minor (deferred): Move-Item -Force not atomic; [IO.File]::Replace would be.
- Task 4: minor (deferred): corrupt state.json throws (fail-loud, no message); unparseable LastSuccess => stale=true.
- Task 4: minor (deferred): Test-StaleSuccess ignores DateTimeKind (UTC vs local skew if later stored as Z).
- Task 4: minor (deferred): no guard on negative Bytes; fractional RunBudgetGB rounding.
- Task 4: complete (commits f2627b9..f7dd466, review clean)
- Task 5: ⚠️ resolved by controller: toast visual confirmation pending — ask user at Part-1 report whether a "PikPak Mirror / test" notification appeared.
- Task 5: Ruling: rclone log paths are unique per invocation (T6 uses `<StateDir>\logs\yyyy-MM-dd\HHmmss-<label>.log`) — Invoke-Rclone reads the whole file — cost if wrong: stale NeedsResync/Bytes.
- Task 5: minor (deferred): log-file uniqueness contract undocumented; relative-path PS vs .NET split (latent); $global:LASTEXITCODE overwrite; log read twice; `--log-file=path` form unsupported; 127 test relies on emptying PATH.
- Task 5: complete (commits f7dd466..c2766fb, review clean)
- Task 6: Ruling: accept implementer decisions — config errors / unconfirmed private add Errors (exit 1); prune exit 3 = OK; failed sentinel touch skips pair + Error; exit 8 leaves FilterHash unchanged too; per-pair exception continues, private-sync exception aborts run (state saved) — all conservative — cost if wrong: extra toasts/retries.
- Task 6: minor (deferred): test gaps — private-sync exit 8 stopping pairs; failing private sync lets pairs run; failed touch skip; Name tie-break sort; stale (non-null) PrivateConfirmedHash; exit-8 test doesn't assert FilterHash/'budget' Skipped; Invoke-Sync.ps1 exit codes only parse-checked.
- Task 6: minor (deferred): per-pair catch doesn't record LastExit/LastRun (brief: "always record").
- Task 6: minor (deferred): filter-change toast repeats every run until exit 0 (noisy, safe).
- Task 6: minor (deferred, triage): Remove-OldLogs leaves empty date dirs; with ErrorActionPreference=Stop an inaccessible old log aborts steps 8–10 (state still saved, exit 1).
- Task 6: complete (commits c2766fb..ed89c68, review clean)
- Task 7: Ruling: offload target that is an ANCESTOR of any private path is rejected (`contains a private folder`), no filters on copy/check — filters on an explicit file target could silently skip+delete it — cost if wrong: user can't offload parents of private folders (must offload siblings individually).
- Task 7: Ruling: promote reviewer Minor 3 to Important — directory targets containing reparse points (junctions/symlinks) are rejected before any rclone call — PS 5.1 Remove-Item -Recurse can traverse junctions and delete outside data (anti-goal: data loss) — cost: can't offload such dirs.
- Task 7: minor (deferred): single-file `rclone check` unverified against real rclone (fail-safe) — verify in Task 10 live test.
- Task 7: minor (deferred): empty subdirs not copied (no --create-empty-src-dirs); Save-MirrorState throw after delete reports failure; duplicate lock-refused log lines; offload copy has no bwlimit; copy/copyto carry --use-json-log (accepted).
- Task 7: note: implementer smoke test left empty dirs C:\nonexistent-xx\state (its deletion was blocked) — surface to user, controller does not delete.
- Task 7: fix round 1/5 (2 addressed, 0 open — private-ancestor guard; reparse-point refusal; commits 6fa491f..a997de6)
- Task 7: minor (deferred): OneDrive placeholders carry ReparsePoint → offload refused (fail-closed; OneDrive folders aren't pairs); unreadable subdir silently skipped by Test-HasReparsePoint.
- Task 7: complete (commits ed89c68..a997de6, review clean)
- Task 8: Ruling (load-bearing, cross-task → final review fix wave): ConvertTo-MirrorPath (Config.ps1) must normalise `/` to `\` — a forward-slash PrivatePath matches no pair, so it would NOT be excluded from plain bisync (private files uploaded plain; anti-goal) — cost if wrong: none.
- Task 8: minor (deferred): size sum undercounts unreadable subdirs; Confirm-PrivatePaths read-modify-write without run lock; missing private path can be confirmed; lsf flow untested.
- Task 8: fix round 1/5 (1 addressed, 0 open — plain-copy check exit-code handling; commits 8b65288..ef72a16)
- Task 8: complete (commits a997de6..ef72a16, review clean)
- Part 1 final review: dispatched (14cd2d5..HEAD)
- Final review (Part 1): With fixes — 3 Critical (C1 prune-by-age empties holding; C2 path spelling/case leaks private; C3 re-touch sentinel stalls seeding), 7 Important, 9 Minor.
- Ruling: C1 prune by date-folder exclude list (spec intent = 30-day window beats spec's literal --min-age) — cost: none.
- Ruling: C2 normalise paths (trim, env, / → \, GetFullPath, strip trailing space/dot) + reject unrooted/%-paths + bisync --ignore-case — cost: none.
- Ruling: C3 sentinel via copyto --ignore-existing — cost: none.
- Ruling: I1 private excludes first; I2 reject file private paths; I3 validator hardening (roots, overlaps, names, budgets); I4 file check against parent; I5 offload bwlimit + remaining budget, refuse at 0; I6 pair Identity hash → resync on mapping change; I7 --log-level INFO.
- Ruling: must-fix ledger — literal 1GB; Confirm-PrivatePaths under lock.
- Ruling: M1, M2 (BudgetPauseNotified), M3, M6 (archive backup-dir), M7 (re-check before delete), M9 (via I3) done; seeded pairs run before unseeded (reviewer rec. 3) — cost: priority order only applies among seeded/unseeded groups.
- Ruling: DEFERRED M4, M5, M8 and ledger can-wait minors — low risk, fail-closed.
- Final fix wave: dispatched (findings file final-fix-wave.md)
- Final fix wave: 1 dispatch, 1 scoped re-review — all findings ADDRESSED, no new Critical/Important (commits ef72a16..788a186); 257/257 tests; real config validates 0 errors.
- Final: parked — `_archive` not reserved as a pair name (holding namespace collision) — Ruling: real config has no such pair; reserve in Part 2 — cost: unlikely overwrite of held copy.
- Final: parked — seeded pair needing resync sorts in the seeded group and can starve later incremental pairs — Ruling: rare (filter/identity change only); revisit if seen live — cost: delayed incrementals for some evenings.
- Final: parked — bare-root guard lets `pikpak:/` through — Ruling: unreachable (Join-RemotePath strips, validator rejects) — cost: none today.
- Final: parked (out-of-scope) — after an offload abort post-move, next bisync moves unchanged local files to local holding — Ruling: no data loss (archive + 30-day holding), message overstates "kept" — fix wording in Part 2 docs.
- Final: parked (out-of-scope) — lsf plain-copy check uses config case (deferred M8) and name validation allows control chars / trailing dot — Ruling: deferred to Part 2 — cost: rare false "no plain copy".
- Spec/plan amended with Part 1 rulings (4a2c68a). Part 1 DONE; workspace kept for Part 2 (Tasks 9–10).

## Part 2 (Task 9)
| Task | Check | Finding |
|---|---|---|
| T9 | Sync task created enabled vs testing phase on real config | Would run nightly on real config before test/go-live. R14 |
| T9 | no tests specified | Untestable orchestration; builders should be pure + tested. R15 |
| T9 | secrets handling unspecified | R16 |
| T9 | -WhatIf with Read-Host prompts | R17 |
| T9 ↔ parked | `_archive` reserved name; README wording | R18, R19 |
| T9 ↔ T3 | New-MountArgs has no --log-file; Start-Mount appends | consistent |
| T9 ↔ T10 | real install "using free test account" | step 2/3 are user-run (interactive secrets) — Ruling: implementer does Steps 1 & 4 only; controller hands Steps 2–3 to user — cost: none |
- Ruling R14–R19 recorded in global-constraints.md.
- Task 9: Ruling: promote reviewer Minors 2 (half-made remote on failed config create), 3 (`"` in password → refuse with clear message), 5 (mount at logon: PT30S delay + Start-Mount retry 3×10s), 7 (RECOVERY quoting), 8a (winget --accept-* flags) into fix round 1 — they hit the user's imminent first install — cost: small extra diff.
- Task 9: minor (deferred): task idempotency compares only Execute/Args/trigger count; mount logs grow forever (age-based cleanup); Start-Mount Write-MirrorLog not try/catch; version warning text when unparseable.
- Task 9: fix round 1/5 (6 addressed, 0 open — README private guidance + M2,M3,M5,M7,M8a; commits 01823a2..afd52b0)
- Task 9: parked — Start-Mount kills a mount not visible within 15 s (×3) — Ruling: follows my instruction; raise per-try wait to 30 s if a slow first mount is seen in the live check — cost: possible false "mount failed" toast on first logon.
- Task 9: complete (commits 4a2c68a..afd52b0, review clean) — brief Steps 2–3 (real install, mount check) handed to the user.
- Task 9 follow-up: Ruling: docs commands use `powershell -NoProfile -ExecutionPolicy Bypass -File` (machine policy blocks direct script runs; user would fail at step 1) — controller-verified diff (doc-only) — commit 1250d06.

## Part 3 — Task 10 (live verification), started 2026-10-24
- User: "help install everything you need and then start part 3" (Install.ps1 not run by user).
- Finding: winget has no Rclone.Rclone 1.75.2 (max 1.75.1 after source update) → Install.ps1 line 168 would fail. Ruling: controller installed official v1.75.2 zip from downloads.rclone.org (SHA256 8a9db2ba…f818 verified against SHA256SUMS) to %LOCALAPPDATA%\Programs\rclone + user PATH; Install.ps1 gets the same fallback in Step 4 — cost: none.
- Ruling: pre-existing remote `[Pikpak remote]` (free 6 GiB account, ~12 MiB used) is the test account; `pikpak` created as `type=alias remote="Pikpak remote:"` (no credential copy, the original untouched) — why: user asked me to install without them typing secrets — cost if wrong: delete the alias and run Install.ps1.
- Ruling: test crypt remote `private-test` (crypt over pikpak:PikPakMirror-Test/PC-Private, random throwaway key, never shown) — real `private` stays a user ceremony at go-live — cost: Q: test covers the mechanism, not the user's key.
- Ruling: plan says `HoldingDays=0` but validator requires positive → test uses HoldingDays=1 and verifies prune with a planted old date folder — cost: none.
- Ruling: all test roots live under `PikPakMirror-Test/` (MirrorRoot/HoldingRoot/ArchiveRoot/PC-Private) so cleanup is one purge; StateDir %LOCALAPPDATA%\PikPakMirror-Test; LocalHolding D:\pikpak-test-holding.
- Live: checks 1,2(rclone-side),3,5,6,7,8 PASS; 12 measured (300 tiny files upload 5m11s ≈1 file/s; lsf 310 entries 1.8s; a folder of 230,679 small files ≈ 64 h first upload).
- Live finding: pikpak Precision=ModTimeNotSupported, no MD5 → bisync ignores --conflict-resolve newer (both renamed) and detects Path2 changes by size only. Ruling: `--conflict-resolve path1` (PC = master keeps the name, other kept as .conflictN) — cost if wrong: flip flag. Same-size phone edits undetected: documented limitation.
- Live finding: emptied remote → exit 7 "empty current Path2 listing", no deletes, but no user repair path. Ruling: `Invoke-Sync.ps1 -Resync <Name>` + plain-language toasts + README "A folder keeps failing".
- Fix wave 1 (F1–F5): commits 5d5d0f9, 2034667, 53cd7d1, 6a74af9; 328 tests; review APPROVED (minors 1,6 → wave 2; 2–5 accepted; 7 settled live: -Resync repaired the emptied remote).
- Live: check 4 re-test PASS with path1; check 8 PASS (file+dir offload, next bisync "No changes found").
- Live finding (check 9): kill mid-upload → next run "prior lock file found" (.lck) until --max-lock 2h; and killed run counted 0 bytes. Ruling: fix wave 2 G1 clear stale .lck while holding sync.lock (single-instance ⇒ stale), G2 bytes = max(stats, Σ Copied sizes) + --stats 30s — cost: none.
- Ruling (spec §7 many-small-files folder): keep as priority-5 bisync pair — runs last, seeded pairs first, so a ~64 h seed over many evenings starves nothing; revisit if PikPak rate-limits — offered user the zip alternative.
- Fix wave 2 (G1–G4): e719ead (trailer amended to Opus), review APPROVED; reviewer minors 1–2 fixed by controller 7032411 (.lck exact ext, locked-file survive); 3–7 accepted.
- Live: G1 verified (stale .lck removed, logged). G2 verified indirectly (TransferredBytes now advances on partial runs).
- Live finding (check 9 aftermath): a hard kill leaves hidden PENDING PikPak entries; later uploads fail "uploaded file name mismatch … got part1(1).bin" → bisync must-resync. rclone lists only PHASE_TYPE_COMPLETE; no rclone command can delete them; still stuck after 40 min; Ctrl+C (graceful) cleans up (verified); uploading under another name works. Ruling: J2 detect + toast + auto-resync next run + README "Stuck uploads" (rename on PC) — cost: one stuck file needs a user rename.
- Live finding (check 10): soft cutoff overshoots (1 GB budget → 1.25 GB); cautious only exact with --transfers 1 (local test). Ruling: cautious + default transfers, MonthlyBudgetGB 230 (20 GB margin) — cost if wrong: one end-of-month overshoot ≤3 files.
- Local finding: bisync (normal and --resync) hitting --max-transfer exits 7 + "Must run --resync", never 8. Ruling: J1 treat BudgetHit as a quiet budget stop and set Seeded=false so the next run resyncs (seeding already works that way) — cost: deletions in that window can resurrect once (documented).
- Fix wave 3 (J0–J4) dispatched.
- Fix wave 3: 6480856 (J0), 201d170 (J1–J4), 353 tests; review CHANGES REQUESTED on finding 1 (`& < >` JSON-escaped) — Ruling: not real, rclone 1.75.2 JSON log writes `Tom & Jerry é.txt` literally (verified) — no change. Minor 3 fixed (offload BudgetHit gated on exit≠0). Minors 2 (repeat identity toast during multi-night resync), 4, 5 parked — cosmetic / accepted trade-off.
- Live finding (root cause of check 10): rclone SizeSuffix reads a bare number as KiB → `--max-transfer 8589934592` = 8 PiB; budget never applied. Fixed: `<bytes>B` everywhere (commit 2310467). Re-test PASS (quiet stop, resume, reseeded). Stuck-upload path PASS (toast, rename fixes).
- 2026-10-25 free-account go-live (no Premium): config cut to the Documents pair + mock private folder `D:\PrivateMock`, RunBudgetGB 1, MonthlyBudgetGB 30; other pairs commented out (restore with Premium).
- 2026-10-25 fixed (K1, b4e16bf): mapping-changed and filter-change toasts fire once per change (NotifiedIdentity / NotifiedFilterHash in pair state), resolving "repeat identity toast during multi-night resync" and Task 6 "filter-change toast repeats". Start-Mount per-try wait 15 s → 30 s (Task 9 parked item). 356 tests.
- 2026-10-25 live finding: hidden unfinished uploads (`big2/part2–4.bin`) still block their names ~18 h later (30-byte probe: "uploaded file name mismatch … got part2(1).bin"). PikPak does not expire them; rename-on-PC (README "Stuck uploads") stays the fix.
- 2026-10-25 live finding: `rclone delete --pikpak-use-trash=false` (override applied, `{jTRHh}`) still left the files listed under `--pikpak-trashed-only`. Not adopted. Account showed 5.2 GiB used vs 3.45 live + 0.58 trash → trash and/or hidden stubs occupy quota. Open: does emptying the trash in the PikPak app free the space? Matters on a 6 GiB account (prune → trash).
- 2026-11-20 single-exe release (branch release/single-exe): the engine is embedded in the exe and unpacks to `%LOCALAPPDATA%\PikPakSync`. End-to-end check of the lone release exe (scratch build, app identifier `local.pikpakbackup.e2e`, `LOCALAPPDATA` pointed at a folder named `pikpak e2e ñ`, `PIKPAK_BACKUP_REPO` unset): unpacked scripts, templates and `engine.hash`; no `mirror.config.psd1` created; no lock left; the unpacked bridge answered `status` (clean `config-missing`) and `folders.suggest` (`ok:true`) from that path. Upgrade (stale hash, tampered script, extra stale script, edited `filters.txt`, own `mirror.config.psd1` + `.bak`): scripts refreshed, stale file removed, template refreshed, own files kept. Ruling: upgrade checked by making the unpacked engine look old instead of rebuilding with a source change — same exe code path, no source edit to revert — cost if wrong: none. The owner's running app and `G:\pikpak-mirror` were not touched.
