# SDD ledger — plan: docs/superpowers/plans/2026-10-25-desktop-app.md

Spec: docs/superpowers/specs/2026-10-25-desktop-app-design.md
Worktree: G:\pikpak-mirror-app (branch feat/desktop-app, base 47cea30 = main; docs commit bd51c6a)
Baseline: 355 passed, 1 failed (Config.Tests.ps1:131 "J3 ... 20 GB margin", expects MonthlyBudgetGB 230, shipped free-account config has 30). Same failure on main.

## Pre-flight scan

| Tasks | Shared file / interface | Finding |
|---|---|---|
| 1 → 5 | `state.LastRunInfo {Started, Finished, Result, Issues[{Pair, Kind, Message, Log}]}` | consistent |
| 1 → 7 | `Test-SyncRunning -StateDir` | consistent |
| 2 → 3 | `New-MirrorTaskSpec -SyncTime -SyncAtLogon`, `New-CryptRemoteArgs` optional salt | consistent |
| 2 → 4 | `config/mirror.config.psd1` gains SyncTime/SyncAtLogon; Task 4 round-trips the shipped config | consistent (Task 4 key order already lists both) |
| 2 → 7 | `New-RecoveryKey` (setup.newkey) | consistent; `ConvertTo-RecoveryKey` only used by console restore (Task 3) |
| 3 → 7 | InstallSteps functions, `-WhatIf` for preview | consistent |
| 4 → 7 | `Save-MirrorConfig`, `New-MirrorPair`, `Get-RawMirrorConfig` | consistent |
| 5 → 7 | `Get-GuiStatus -Facts`, `Get-BudgetPreset` | consistent |
| 6 → 7 | `ConvertTo-HoldingItems`, `Get-RestoreTarget` | consistent |
| 7 → 8–11 | bridge contract table | consistent; Task 8 `app_info.pc_name` used by Task 10 |
| 8 → 10 | `tauri-plugin-fs` for key file | consistent |
| Task 1 self | tests vs code | consistent |
| Task 2 self | edits config + Config.Tests (same file as J3 failure) | see Ruling R2 |
| Task 3 self | Install.ps1 -WhatIf live check | consistent, read-only |
| Task 4 self | psd1 written UTF-8 *with* BOM vs global R12 (no BOM) | R12 is for files rclone reads; psd1 is read by PowerShell → no conflict |
| Task 5 self | consistent |
| Task 6 self | consistent |
| Task 7 self | live smoke `status` read-only | consistent |
| Task 8 self | `cargo tauri dev` needs tauri-cli | see Ruling R4 |
| Task 9 self | live checks write worktree config, but live sync runs main checkout's config/scripts | see Ruling R1 |
| Task 10 self | preview only | consistent |
| Task 11 self | schedule live check re-registers PikPakMirror-Sync from worktree path | see Ruling R1 |
| 9–11 | UI cannot be seen by subagents | see Ruling R5 |

Ruling R1: No live check may run `Register-MirrorTasks` / `Register-MirrorOffloadMenu` / `Install.ps1` (non-WhatIf) from the worktree — it would repoint the live scheduled tasks and Explorer menu at G:\pikpak-mirror-app. Allowed live actions: read-only bridge calls, Enable/Disable-ScheduledTask (doesn't change the action path), Start-ScheduledTask, offload/restore of ≤1 KB test files inside Documents, config writes to the *worktree* config only (then reverted). Schedule-time change, folder add + real backup of a new folder, and setup become post-merge checks listed in Task 12 docs — why: protects the live backup — cost if wrong: those checks happen later, after merge.
Ruling R2: Baseline J3 failure is pre-existing (free-account config vs Premium test); not fixed in this branch; "full suite PASS" means no failures other than J3 — why: out of scope, config is intentionally free-account — cost if wrong: one red test stays until Premium go-live (R1 in OPEN-REQUIREMENTS).
Ruling R3: Rust toolchain: cargo is at %USERPROFILE%\.cargo\bin and may not be on PATH in new shells; implementers prepend it. MSVC 14.44 Build Tools installed.
Ruling R4: Task 8 implementer may `cargo install tauri-cli --version "^2" --locked` (user-level dev tool, toolchain install already approved by the user) — cost if wrong: a few minutes of build time.
Ruling R5: UI tasks (9–11) verify by: bridge calls from PowerShell for every action the screen uses, `cargo build` + app launch without errors, and `gui/ui` opened in a browser with a stub `__TAURI__` is NOT required; the final visual check is done by the user — cost if wrong: visual bugs found later by the user.

## Execution
Task 1: ⚠️ resolved by controller — Save-MirrorState depth 5 covers LastRunInfo.Issues[n] (state→LastRunInfo→Issues→item→value = 4); Invoke-Rclone mocks: suite 377/1(J3) passes.
Task 1: minor (deferred): catch→'other' issue has no test (Run.ps1:245-249)
Task 1: minor (deferred): corrupt state.json → no LastRunInfo written; UI should treat unreadable state as not-ok
Task 1: minor (deferred): whitespace typo `$stuck =New-Object` Runtime.ps1:283
Task 1: minor (deferred): State test asserts +07:00 string exactly (timezone-sensitive only if coerced)
Ruling R6: Test-SyncRunning opens sync.lock exclusively; a scheduled sync starting in that instant skips its whole run as 'locked' (missed nightly backup). Task 7 replaces its body with a non-intrusive check (a powershell process whose command line contains Invoke-Sync.ps1, via Win32_Process) keeping name/signature, and updates its test — why: the app polls every 10–60 s, so the race is real over months — cost if wrong: one CIM query per poll.
Task 1: complete (commits bd51c6a..e4cbc66, review clean)
Ruling R7: plan's example key '...fu8ls' contained L, which the spec's no-look-alike alphabet excludes; alphabet stays as specified, implementer's corrected test data ('...fu8ts') stands — why: spec is binding — cost if wrong: none (prototype key is mock text).
Task 2: ⚠️ resolved — config→New-MirrorTaskSpec wiring is Task 3 (Register-MirrorTasks); carried in Task 3 dispatch.
Task 2: minor (deferred): SyncTime regex `$`/`\d` could be `\z`/`[0-9]` (Config.ps1:60)
Task 2: minor (deferred): New-MirrorTaskSpec doesn't validate -SyncTime itself
Task 2: minor (deferred): no test pins exclusion of 0/1/I/L nor New-RecoveryKey→ConvertTo-RecoveryKey round-trip
Task 2: complete (commits e4cbc66..8a83335, review clean)
Task 3: note for Task 7 — New-MirrorPikPakRemote / New-MirrorPrivateRemote don't check existence; bridge must check `rclone listremotes` (Test-RemoteListed) first. Register-MirrorTasks gained optional -Kind All|Sync|Mount; results may carry Details[].
Task 3: ⚠️ resolved — Get-MirrorConfig returns a hashtable (Import-PowerShellDataFile); old b-branch did check PC-Private before generating (see minor below); -WhatIf output claim accepted from implementer evidence.
Task 3: minor (deferred): winget output now | Out-Null (console change; failure text lost)
Task 3: minor (deferred): console option b) now generates+shows key before the New-mode PC-Private refusal (old code refused first) — kinder pre-check
Task 3: minor (deferred): Install.ps1 ShouldProcess + function ShouldProcess double-prompts under -Confirm
Task 3: minor (deferred): 'rclone v1.75.2' hard-coded in InstallSteps.ps1:484
Task 3: minor (deferred): wording "try again" vs "run Install.ps1 again"; warning/[done] order swapped
Task 3: minor (deferred): test gaps — SHA256 mismatch, config-create rollback, New with listing -1, unsafe chars, offload menu create path, Install.ps1 output
Task 3: fix round 1/5 (1 addressed, 0 open — empty email binding error; commits f601ba6..06784bc)
Task 3: minor (deferred): -WhatIf message with empty email reads "...for " (cosmetic)
Task 3: complete (commits 8a83335..06784bc, review clean)
Task 4: ⚠️ resolved — implementer reported suite 404/1(J3) incl. shipped-config round-trip; drive-root case: Test-MirrorConfig overlap check refuses a D:\ pair next to other D: pairs.
Task 4: minor (deferred): Save-MirrorConfig — WriteAllText outside try; .tmp left if Copy/Move throws (target intact)
Task 4: minor (deferred): non-ASCII/apostrophe round-trip not tested through Save-MirrorConfig + Get-MirrorConfig; BOM/CRLF not asserted
Task 4: minor (deferred): overlap test only parent/child here (same folder / case covered by Test-MirrorConfig tests?)
Task 4: minor (deferred): New-MirrorPair — no drive-root test; UNC path unguarded
Task 4: note for Task 7 — ConvertTo-PsdLiteral handles only [hashtable]; bridge must convert JSON PSCustomObjects (recursively) to hashtables/arrays before Save-MirrorConfig (else garbage text → validator refuses)
Task 4: minor (deferred): double formatting could emit 1E+20
Task 4: complete (commits 06784bc..9106ee5, review clean)
Task 5: ⚠️ resolved — Get-MirrorStatus zeroes UsedGB when State.Month ≠ current month (Status.ps1:15); Test-StaleSuccess returns $false for empty LastSuccess (State.ps1:124).
Ruling R8: Situation 'ok' only when LastRunInfo.Result -eq 'ok' (spec anti-goal 1 overrides the plan's fall-through). New situations: 'partial' (Result budget-stopped; tone ok; title "Part of your backup is done"; detail "PikPak's upload limit for one evening was reached. The rest carries on at the next backup.") placed after 'first'; 'waiting' (LastRunInfo $null but LastSuccess set — this PC until the new engine runs once; tone ok; title "Waiting for the next backup"; detail "Last backup: <when>. Full details appear after the next backup.") placed where 'never' is; unknown/empty Result → 'attention' with title "Your last backup didn't finish" — why: plan's precedence let "backed up" through after non-ok runs — cost if wrong: two extra situations for the UI (Task 9 renders Title/Detail/Tone generically).
Ruling R9: folder-missing issues → pill "Folder not found" (warn) and a headline 'missing' situation (tone warn; title "<Pair> wasn't found"; detail "The folder <Local> wasn't there at the last backup, so it was skipped. Plug in the drive, or remove the folder from the backup.") placed right after 'attention' — why: green "backed up" next to a skipped folder contradicts anti-goal 1 — cost if wrong: unplugged USB folders show warn until next run.
Ruling R10: keep implementer's pill order (sync running → "Backing up" even for unseeded pairs); add a test — why: more truthful while running — cost if wrong: none.
Task 5: minor (deferred): missing tests — delete-safety title, previous-month month-paused ignored, Finished=$null + month-paused, mixed pair/non-pair issues
Task 5: minor (deferred): month-paused detail "the most this app uploads in a month" may be inaccurate when Result-driven with UsedGB < BudgetGB
Task 5: minor (deferred): Get-GuiStatus not pure (Get-MirrorStatus reads disk for Unmapped) — documented in comment
Task 5: minor (deferred): ConvertTo-GuiDate RoundtripKind shows UTC clock time for 'Z' strings (engine writes local offsets)
Task 5: fix round 1/5 (3 addressed, 0 open — ok only when Result ok (R8), folder-missing (R9), running pill (R10); commits 7644b19..6d9267b). Controller ran the disputed focused test: passes (Gui.ps1:94 override).
Task 5: minor (deferred): Gui.ps1:84 `elseif ($syncRunning)` branch now redundant with the line-94 override
Task 5: complete (commits 9106ee5..6d9267b, review clean)
Task 6: minor (deferred): coverage — case-insensitive pair match, lenient date '2026-1-5', forward-slash path in Get-RestoreTarget, trailing-dot name
Task 6: note for Task 7 — restore write should use CreateNew semantics (check-then-use gap after Get-RestoreTarget)
Task 6: minor (deferred): first report lacked RED/GREEN output; self-review skipped
Ruling R11: Task 6 fix round 1 also asks for PSCustomObject entry support (reviewer Minor) — why: same function, the bridge passes ConvertFrom-Json objects — cost if wrong: a few lines.
Task 6: fix round 1/5 (2 addressed, 0 open — traversal guard, PSCustomObject entries; commits 241c23e..0bc1386)
Task 6: minor (deferred): PSCustomObject property read would throw under Set-StrictMode if rclone omitted IsDir (low risk)
Task 6: complete (commits 6d9267b..0bc1386, review clean)
Task 7: note — actions live in new scripts\lib\GuiActions.ps1 (allowed by dispatch); envelope may carry top-level `warning`; sync.start refused while paused; mount.set off kills rclone mount processes (UI must warn); setup.finish not re-runnable once config exists.
Ruling R12 (Task 7 I-1): setup.finish runs every fallible remote step (rclone present, account reachable, PC-Private empty, create crypt remote when a key is given) BEFORE writing the config; when the config already exists a real run is refused unless args.resume = true, which skips the config write and re-runs the remaining idempotent steps (tasks, menu, folders, confirmation, mount) on the existing config. Task 10 offers "Try again" with resume — why: no dead end after a mid-way failure — cost if wrong: one extra arg.
Ruling R13 (Task 7 I-2): Invoke-GuiAction.ps1 calls Update-SessionPath right after loading the libs — why: bridge processes inherit the app's stale PATH — cost if wrong: none.
Ruling R14 (Task 7 I-3): setup.signin with an existing remote and a password: resolve alias one level to the real remote, run `rclone config update <real> user <email> pass <pw> --obscure --non-interactive` (R16-style args, captured), then verify with about; on auth failure keep the old config entry unchanged if possible (restore not required) and return auth. After any successful sign-in delete the about cache (gui-about.json) — why: re-sign-in loop; this PC's pikpak is an alias of 'Pikpak remote' — cost if wrong: password passed as rclone arg (already accepted under R16).
Ruling R15: `about` rclone call gets `--contimeout 10s --timeout 30s` (reviewer Minor) — why: a stalled status poll freezes Home — cost if wrong: slow networks may report 'network' spuriously.
Task 7: minor (deferred): schedule.set can half-apply (config saved before Register-MirrorTasks)
Task 7: minor (deferred): offload catch-all hides unexpected errors as ok:true/offloaded:false with raw text, no log
Task 7: minor (deferred): key.show says "not set up" when rclone config dump fails
Task 7: minor (deferred): Test-SyncRunning false on CIM failure; matches any process mentioning Invoke-Sync.ps1
Task 7: minor (deferred): listremotes exit code ignored (:1015, :1121)
Task 7: minor (deferred): raw exception text in install-failure messages (:1009, :1013); outer catch logs unredacted message (Invoke-GuiAction.ps1:47)
Task 7: minor (deferred): Copy-GuiCreateNew drops first error; mount.set off kills rclone without warning (UI must warn — Task 11)
Task 7: minor (deferred): folders.add/remove response shape differs under preview ({pairs,preview} vs array)
Task 7: minor (deferred): duplicated private-name generation and exists-scriptblock; GuiActions.ps1 1186 lines
Task 7: minor (deferred): test gaps — cloud restore, holding.list warning, preview of sync/mount/restore/offload/private.*, mount.set on, Measure-GuiFolder limit, Stop-GuiMounts regex, signin existing remote, child-process Write-Host
Task 7: note — sign-in with a different email than the existing remote is refused (Change account is out of scope per spec); Task 10 must send resume:true on setup retry; crypt-remote-created-then-config-write-fails needs manual 'rclone config delete private' (unlikely).
Task 7: fix round 1/5 (3 addressed, 0 open — setup resume R12, PATH R13, re-sign-in R14, about timeouts R15; commits 4f5e2c4..05f843f)
Task 7: complete (commits 0bc1386..05f843f, review clean)
Task 8: notes for Tasks 9–11 — CSP blocks inline onclick (use addEventListener); gui_action always takes {action,args,preview}; extra command set_tray_paused exists; human look needed: tray art, tray menu actions, min size.
Ruling R16 (Task 8 I-1): bridge child timeout per action — default 120 s; setup.signin & setup.finish 30 min (rclone download + winget); offload 60 min; mount.start 3 min; folders.size = maxSeconds (default 20) + 30 s; on timeout kill the child (tree), return Err("internal: timed out"), log it, and the tray busy flag is always cleared — why: hung child stalls UI calls and tray forever — cost if wrong: a very slow legit call is cut off and reported.
Task 8: minor (deferred): opener scope `**` (could be $HOME/** and P:\**)
Task 8: minor (deferred): child stdout/stderr logged on failure could carry secrets only if bridge crash text echoes them
Task 8: minor (deferred): gui_action calls not serialized (parallel PowerShells)
Task 8: minor (deferred): tray failure dialogs could stack
Task 8: note — a mount.start that times out (3 min) kills the bridge's process tree, including any rclone mount it started (acceptable: timeout means the mount didn't come up).
Task 8: fix round 1/5 (1 addressed, 0 open — per-action deadline + tree kill + busy guard; commits f504894..0197687)
Task 8: minor (deferred): stdin write not covered by deadline (small requests); reader threads not joined (exit at EOF)
Task 8: complete (commits 05f843f..0197687, review clean)
Ruling R17: Task 9's brief live check "add D:\pikpak-gui-test and Back up now → Up to date" conflicts with R1 (the live sync reads G:\pikpak-mirror's config, not the worktree's). Replace with: folder add/remove verified in the worktree config only (then reverted); Back up now verified by sync.start → status shows running then a new LastRunInfo; restore verified with a ≤1 KB file in C:\Users\Alex\Documents (create → Back up now → delete → Back up now → appears in holding.list cloud → Restore); offload with another ≤1 KB file in Documents — why: protects the live backup — cost if wrong: add-folder end-to-end becomes a post-merge check.
Task 9: notes for the user at the end — two 58-byte test files remain in PikPak (one in Archive, one in PC-Holding, auto-pruned in 30 days); PikPak "used" dropped 5.2→4.2 GB during checks (not caused by tests; likely trash cleanup, cf. OPEN-REQUIREMENTS R3); opening P: uses file:///P:/ via a capability entry (opener path check fails on WinFsp drives); offload tip says "Offload to PikPak Archive" (real menu label).
Task 9: ⚠️ resolved — bridge field shapes confirmed by Task 7 review + implementer live checks; P: via file:///P:/ live-verified by implementer; visual fidelity → user check.
Task 9: minor (deferred, user-facing — final review should fix): holding.list failure shows "No deleted files" (false reassurance) app.js:762-782
Task 9: minor (deferred, user-facing — final review should fix): double restore possible while another restore in flight app.js:807-824
Task 9: minor (deferred): folder menu open → list not re-rendered on close (app.js:514)
Task 9: minor (deferred): render error inside poll reported as add/remove failure; updateTray skipped
Task 9: minor (deferred): call() drops envelope warning except holding.list
Task 9: minor (deferred): .fname long-name overflow (needs overflow-wrap:anywhere)
Task 9: minor (deferred): offload leftovers — stale list on return, size printed twice, "From undefined"
Task 9: minor (deferred): copy "Backed-up folders" heading → neutral "Your folders" (anti-goal 1 spirit)
Task 9: minor (deferred): app.js 756 lines; consider per-screen modules
Ruling R18: Task 10 also changes bridge.js so an `internal: timed out` rejection shows "This is taking longer than expected. Check again in a few minutes; it may still finish." instead of "couldn't start its helper" (Task 9 minor 6, plan-mandated text) — why: setup.finish/offload are long and the helper message is misleading — cost if wrong: one string.
Task 9: complete (commits 0197687..8dfa176, review clean)
Task 10: implementer died (API 403 on opus) after committing d7a08f4, before writing its report/verification; Ruling R19: dispatch a fresh implementer (sonnet) to verify d7a08f4 against the brief, run the preview verification + no-change proof, fix gaps if any, and write the report — why: avoid redoing committed work — cost if wrong: one extra dispatch.
Ruling R20 (Task 10 I-1): a ticked row whose size failed to measure blocks Continue, shows "Couldn't measure this folder" with a "Measure again" link; when any chosen size is a lower bound (complete:false) the space line says "at least <n>" — why: unknown size could exceed free space unseen — cost if wrong: user must re-measure or untick.
Ruling R21 (Task 10 I-2): after setup.finish rejects with `internal: timed out`, show "Setup may still be finishing in the background. You can try again in a few minutes." and keep Try again disabled for 5 minutes (countdown text not required) — why: avoid two concurrent setup.finish runs — cost if wrong: a 5-minute wait after a genuine hang.
Task 10: minor (deferred): preview failed-step heuristic fragile (setup.js:1109-1111)
Task 10: minor (deferred): settingsWritten not set when finish throws after config write → Back still shown
Task 10: minor (deferred): RUN_BUDGET_GB / SYNC_TIME hardcoded copies of backend presets (setup.js:612-613)
Task 10: minor (deferred): setup.key not cleared when the user backs out of Private
Task 10: minor (deferred): Print/Copy not gated in preview
Task 10: minor (deferred): setup.js 630 lines; key-sheet builder could split out
Task 10: minor (deferred): key screen "Step 3 of 4" hardcoded (index.html ~517), not updated by updateStepNumbers
Task 10: fix round 1/5 (1 addressed, 1 open — R21 hold bypassed via Back→Continue → showDone→runFinish(false); commits d7a08f4..a5854a8)
Task 10: fix round 2/5 (1 addressed, 0 open — state-level retry hold; commits a5854a8..7fb57b0)
Task 10: minor (deferred): setup.timedOut / retryTimer not reset when setup restarts via Sign in again
Task 10: complete (commits 8dfa176..7fb57b0, review clean)
Ruling R22 (Task 11 live checks vs R1): from the worktree, schedule.set with syncTime/syncAtLogon re-registers the live task at the worktree path → verify those only with preview:true; pause/resume may be checked live ONLY if schedule.set {paused} merely Enables/Disables the task (implementer must confirm in GuiActions.ps1 first; else preview only) and must end Resumed; mount.set off not run live (warning dialog verified by reading code); Advanced save only to the worktree config, then `git checkout config/`; key.show live but never copy/print the key. Schedule time change + drive toggles become post-merge checks (Task 12 docs) — why: protect the live backup — cost if wrong: those checks happen after merge.
Task 11: notes — autostart not toggled live; 'Pikpak remote' config hash changed (token refresh by live engine/mount, not by implementer); prototype's Sign out / Remove app buttons omitted (not in spec Settings list).
Ruling R23 (Task 11 I-1): reviewer partly wrong — Test-MirrorConfig requires positive whole numbers for RunBudgetGB/MonthlyBudgetGB/HoldingDays (Config.ps1:112), so a fractional config can't exist and integer-only is correct. Fix only the mismatch: inputs use inputmode="numeric", the inline error says "Use a whole number", MaxDeletePercent accepts whole numbers 1–100 — cost if wrong: none.
Ruling R24 (Task 11 I-2): keep last-known evening hours in settings state (default 18:00–23:00), restore them when the switch is turned on, and disable the hour fields while the switch is off (so "Saved." never covers unsaved hours).
Ruling R25 (Task 11 I-3): toggleKey captures a token before awaiting key.show and discards the result if Settings was left/hidden meanwhile (key never reaches DOM/state off-screen).
Task 11: minor (deferred): go-easy off overwrites a custom BwLimit without warning
Task 11: minor (deferred): failed loadSchedule/loadMount/loadAutostart leave stale switch values
Task 11: minor (deferred): set_tray_paused failures swallowed
Task 11: minor (deferred): whileBusy drops focus; numberField replaces only first comma; changeTime .then outside try
Task 11: fix round 1/5 (3 addressed, 0 open — R23 numeric, R24 hours state, R25 key token; commits 5729cff..fc6d308)
Task 11: minor (deferred): unsaved hour edits discarded when switch turned off before Save
Task 11: complete (commits 7fb57b0..fc6d308, review clean)
Task 12: ⚠️ resolved — Show recovery key shows Password + Salt for kind 'pair' (Task 11 review verified settings.js); 505 = 504 passed + J3; nsis path → controller is running cargo tauri build.
Task 12: minor (deferred): README.md:317 double parentheses; README.md:258 clumsy "(The app can do this…)"; HANDOFF.md:31 section name; R2 symmetry in tables
Controller check: `cargo tauri build` OK (1m01s); exe gui\src-tauri\target\release\pikpak-backup.exe (12.3 MB); installer gui\src-tauri\target\release\bundle\nsis\PikPak Backup_0.1.0_x64-setup.exe (2.47 MiB) — README path confirmed. Note (final review): an installed copy (outside the repo) only finds the scripts via PIKPAK_BACKUP_REPO (documented README.md:33); without it the app can't start its helper.
Task 12: fix round 1/5 (1 addressed, 0 open — backspace in cargo path; commits 62977ea..a6ca3d6); implementer's tab scan = 0.
Task 12: complete (commits fc6d308..a6ca3d6, review clean)
Final review (opus): With fixes — 0 Critical, 6 Important (delete-safety advice backwards; no-private-remote prune fails nightly + private.add without remote; key sheet describes nonexistent app restore + Install.ps1 a) no key normalisation; docs lead to worktree exe/installer; write actions not serialized; listremotes exit ignored → could delete live pikpak remote), must-fix minors T9 holding-fail + double restore. Ruling R26: one fix wave covers Important 1–6 + minors 7–11 (mount timeouts 5 min, .gitignore .bak/.original/.tmp, empty Local text) per final-fix-brief.md; all other deferred minors can wait (reviewer triage) — cost if wrong: they stay as known minors.
Final fix wave: commits a6ca3d6..30861a3 (fd5ac33 engine, 21d9a91 bridge, 8d06941 install, e246207 ui, e2c0830 shell, c25dffb docs, 30861a3 .gitignore); Pester 513/1(J3), cargo 18 + 2 ignored, clippy clean. Notes: Install.ps1 a) still compares the two typed entries as typed (spaces differ → mismatch); private:_holding not pruned when no private folders remain; Gui rows gained IssueKind; Settings key sheet keeps password+salt wording for 'pair' keys; pre-existing cargo fmt diffs.
Final fix wave re-review: all 11 addressed, no new Critical/Important breakage. Branch clean at 30861a3.
