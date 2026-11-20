# Release v0.1: Single-`.exe` Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish GitHub Release `v0.1.0` whose only download is one `PikPak-Sync-v0.1.0-windows-x64.exe` that works on a clean PC, built by GitHub Actions.

**Architecture:** `build.rs` embeds the PowerShell engine into the Tauri `.exe`; at start-up, when no scripts folder is found by the existing lookup, the app unpacks it to `%LOCALAPPDATA%\PikPakSync\` and uses that as the repo root. A tag-triggered workflow tests, builds with `cargo tauri build --no-bundle` and publishes the Release.

**Tech Stack:** Rust 2021 (Tauri 2.12, no new crates), PowerShell 5.1 + Pester 5.7.1, GitHub Actions (`windows-latest`).

**Spec:** [docs/superpowers/specs/2026-11-20-release-single-exe-design.md](../specs/2026-11-20-release-single-exe-design.md)

## Global Constraints

- Work on branch `release/single-exe` in a worktree under `.worktrees/` (the repo already uses that folder). Do not touch `main` until the owner confirms (Task 5).
- Engine root is exactly `%LOCALAPPDATA%\PikPakSync\` (no space). State and logs stay in `%LOCALAPPDATA%\PikPakMirror` (unchanged).
- Lookup order is exactly: `PIKPAK_BACKUP_REPO` -> walk up from the `.exe` -> unpacked engine root. The first two are unchanged code.
- Never overwrite or delete `config\mirror.config.psd1`, `.bak`, `.original`. `config\filters.txt` is written only if missing; `config\mirror.config.sample.psd1` is always refreshed.
- Embed only an allowlist: every `*.ps1` under `scripts\`, plus `config\mirror.config.sample.psd1` and `config\filters.txt`. Nothing else (the owner's real config holds private paths and must never be embedded).
- No new Cargo dependencies. Windows only. Artifact name `PikPak-Sync-v<version>-windows-x64.exe` plus `.sha256`.
- Build the release with `cargo tauri build --no-bundle`, never a bare `cargo build --release`.
- Live tests keep files at 1 MB or less (owner's rule); this plan does no live PikPak calls.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Commit locally only; pushing and tagging happen in Task 5 after the owner says yes.

## Review Focus

1. Upgrade while the old scripts are in use (a sync is running): keep the old engine, report an error, leave no half-state. Test in Task 1.
2. The user's edited `filters.txt` and their `mirror.config.psd1` survive an upgrade. Test in Task 1.
3. Two copies of the `.exe` started at once both try the first unpack: no corrupt engine. Test in Task 1 (lock).
4. Profile path with a space and an accented letter: unpack and the PowerShell bridge still work. Checked in Task 4.
5. Tag `v0.2.0` while the app version is `0.1.0`: the workflow must fail before building. Test in Task 3.

---

### Task 1: Engine embedding and unpacking

**Files:**
- Modify: `gui/src-tauri/build.rs`
- Create: `gui/src-tauri/src/engine.rs`
- Modify: `gui/src-tauri/src/main.rs` (add `mod engine;` only; wiring is Task 2)

**Interfaces:**
- Produces (`engine.rs`):
  - `pub struct Bundle<'a> { pub files: &'a [(&'a str, &'a [u8])], pub hash: &'a str }`. File paths are relative with forward slashes: `scripts/Invoke-GuiAction.ps1`, `config/filters.txt`.
  - `pub fn embedded() -> Bundle<'static>`: the build-time bundle.
  - `pub fn engine_root() -> Option<PathBuf>`: `%LOCALAPPDATA%\PikPakSync`, or `None` when `LOCALAPPDATA` is unset or empty.
  - `pub fn ensure_unpacked(root: &Path, bundle: &Bundle) -> Result<(), String>`.
  - `pub const BRIDGE_REL: &str = "scripts/Invoke-GuiAction.ps1"`.
- `build.rs` writes `$OUT_DIR/engine_bundle.rs` defining `pub static FILES: &[(&str, &[u8])]` (using `include_bytes!` with absolute paths) and `pub const HASH: &str` (FNV-1a 64 over each path and its bytes in sorted path order, as 16 hex digits). It prints `cargo:rerun-if-changed` for `../../scripts` and for both config files. `tauri_build::build()` still runs.

- [ ] **Step 1: Write the failing tests** in `engine.rs` (`#[cfg(test)] mod tests`, own temp-dir helper under `std::env::temp_dir()` with the pid and a name; hand-made `Bundle`s, not the embedded one):
  - `fresh_unpack_writes_scripts_config_and_marker`: all bundle files exist under `root`; `root/engine.hash` contains the hash.
  - `same_hash_is_a_no_op`: tamper with one unpacked script, call again with the same bundle, tampered content is still there.
  - `new_hash_refreshes_scripts_and_removes_stale_files`: bundle v2 drops one script and changes another; afterwards the dropped file is gone and the changed one is new.
  - `upgrade_keeps_user_config`: put `config/mirror.config.psd1` (`mine`) and an edited `config/filters.txt` in root; upgrade; both unchanged, while `config/mirror.config.sample.psd1` is refreshed.
  - `locked_old_scripts_keep_the_old_engine`: hold `scripts/a.ps1` open with `OpenOptionsExt::share_mode(1)` (read-share only); upgrade returns `Err`, old content and old `engine.hash` are intact, and `scripts.new` / `scripts.old` do not linger. Drop the handle, upgrade again, it succeeds.
  - `second_process_waits_for_the_lock`: create `root/engine.lock` by hand, start `ensure_unpacked` on a thread, remove the lock after 300 ms, it then completes `Ok`. A lock file older than 60 s is treated as stale and replaced.
  - `embedded_bundle_matches_the_allowlist`: `embedded().files` contains `scripts/Invoke-GuiAction.ps1`, `scripts/lib/GuiActions.ps1`, `config/mirror.config.sample.psd1`, `config/filters.txt`; every path is `scripts/*.ps1`-style (`.ps1` under `scripts/`) or one of the two config files; none is `config/mirror.config.psd1`; `hash` is 16 hex digits.
- [ ] **Step 2: Run** `cargo test --manifest-path gui/src-tauri/Cargo.toml engine` -> fails to compile (module missing).
- [ ] **Step 3: Implement** `build.rs` and `engine.rs` as specified. In `ensure_unpacked`: take `engine.lock` with `create_new` (wait up to 10 s polling every 50 ms; a lock older than 60 s is stale and removed), release it on every exit path; return early when `engine.hash` equals the bundle hash and `BRIDGE_REL` exists; otherwise write the new `scripts` to `scripts.new`, then rename `scripts` -> `scripts.old`, `scripts.new` -> `scripts`, remove `scripts.old` (best effort); if the second rename fails, rename `scripts.old` back and return `Err`. Write the config files per Global Constraints, and write `engine.hash` last. Errors are plain `String`s that name the path.
- [ ] **Step 4: Run** the same command -> all `engine` tests pass. Then `cargo test --manifest-path gui/src-tauri/Cargo.toml` -> the whole suite still passes.
- [ ] **Step 5: Commit** (include the design doc and this plan): `git add docs gui/src-tauri/build.rs gui/src-tauri/src/engine.rs gui/src-tauri/src/main.rs` then `git commit -m "Embed the PowerShell engine in the app and unpack it on first run"`.

### Task 2: Use the unpacked engine as the last lookup step

**Files:**
- Modify: `gui/src-tauri/src/engine.rs`, `gui/src-tauri/src/main.rs:69-72`

**Interfaces:**
- Consumes: `engine::engine_root`, `engine::ensure_unpacked`, `engine::embedded`, `bridge::resolve_repo_root`, `bridge::log`.
- Produces: `pub fn embedded_root() -> Option<PathBuf>`: `ensure_unpacked(engine_root, embedded())`; on `Ok` returns the root; on `Err` logs it with `bridge::log` and returns the root only if its `BRIDGE_REL` still exists (old engine kept), else `None`.

- [ ] **Step 1: Write the failing test** `embedded_root_from(root, bundle)` variant: a testable `fn embedded_root_in(root: &Path, bundle: &Bundle) -> Option<PathBuf>` with tests `returns_root_after_unpack` and `returns_old_root_when_upgrade_fails_but_bridge_exists` (reuse the lock-holding trick) and `returns_none_when_nothing_usable` (unwritable root, e.g. a path under an existing regular file).
- [ ] **Step 2: Run** `cargo test --manifest-path gui/src-tauri/Cargo.toml embedded_root` -> FAIL (missing).
- [ ] **Step 3: Implement** `embedded_root_in` and `embedded_root`; in `main()` change to `bridge::resolve_repo_root().or_else(engine::embedded_root)`, keeping the existing "no repo folder" log line for the `None` case.
- [ ] **Step 4: Run** the full `cargo test --manifest-path gui/src-tauri/Cargo.toml` -> PASS.
- [ ] **Step 5: Commit:** `git commit -am "Fall back to the unpacked engine when no scripts folder is found"`.

### Task 3: Release workflow and version check

**Files:**
- Create: `.github/scripts/check-version.ps1`, `.github/workflows/release.yml`, `.github/release-notes.md`

**Interfaces:**
- `check-version.ps1 [-Tag <string>]`: reads `version` from `gui/src-tauri/tauri.conf.json` and `Cargo.toml`; exit 1 with a clear message if they differ, or if `-Tag` is given and is not `v<version>`; prints the version on success. Run from the repo root regardless of the caller's folder.

- [ ] **Step 1: Write the failing check:** run `powershell -NoProfile -File .github/scripts/check-version.ps1 -Tag v0.2.0` -> must exit non-zero once the script exists (today: file missing).
- [ ] **Step 2: Implement** `check-version.ps1`, then run it with `-Tag v0.2.0` (expect exit 1, message names both versions) and `-Tag v0.1.0` (expect exit 0, prints `0.1.0`).
- [ ] **Step 3: Write `release.yml`.** Triggers: `push` tags `v*`, and `workflow_dispatch`. Top-level `permissions: contents: read`; the publish step's job gets `contents: write`. One job on `windows-latest`, steps in this order: checkout; `check-version.ps1` (with `-Tag ${{ github.ref_name }}` only on tag pushes); `Install-Module Pester -RequiredVersion 5.7.1 -Force -SkipPublisherCheck` then `tests\run.ps1` in `shell: powershell`; Rust stable toolchain; `Swatinem/rust-cache` with workspace `gui/src-tauri`; `cargo test` in `gui/src-tauri`; `cargo install tauri-cli --version "^2.12" --locked` (skipped when already cached); `cargo tauri build --no-bundle` in `gui/src-tauri`; copy `gui/src-tauri/target/release/pikpak-backup.exe` to `PikPak-Sync-v<version>-windows-x64.exe`, write its `.sha256` (`<hash>  <name>` format); `actions/upload-artifact` of both (dry runs download from here); on tag pushes only, `gh release create $tag <exe> <sha256> --title "PikPak Sync v<version>" --notes-file .github/release-notes.md`. Pin actions by major version (`actions/checkout@v4`).
- [ ] **Step 4: Write `release-notes.md`:** what the app is (two lines), "download the `.exe` and run it", SmartScreen "More info, Run anyway" because it is unsigned, needs WebView2 (Windows 11 and current Windows 10 have it) and internet on first run (rclone download), how to verify the `.sha256` with `Get-FileHash`, where it keeps things (`%LOCALAPPDATA%\PikPakSync`, `%LOCALAPPDATA%\PikPakMirror`).
- [ ] **Step 5: Validate:** parse the YAML (`python -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" .github/workflows/release.yml`, or `actionlint` if available) and read it once against the step list above.
- [ ] **Step 6: Commit:** `git add .github && git commit -m "Add the release workflow: test, build the single exe, publish on a v* tag"`.

### Task 4: Local end-to-end check of the lone `.exe`

**Files:** none changed unless a defect is found (fix it in the file that owns it, with a test).

- [ ] **Step 1: Check the owner's app is not interfering:** `Get-Process pikpak-backup` (if running, leave it running; the test build below uses a different app identifier so it is not handed over to that copy).
- [ ] **Step 2: Build into a scratch folder** (never over `gui\src-tauri\target`, which the live app may be running from): `$env:CARGO_TARGET_DIR = '<scratchpad>\e2e-target'; cargo tauri build --no-bundle --config '{"identifier":"local.pikpakbackup.e2e"}'` in `gui/src-tauri`.
- [ ] **Step 3: Run it alone:** copy only the built `.exe` into an empty folder, make a temp folder `<scratchpad>\pikpak e2e ñ` and start the `.exe` with `LOCALAPPDATA` set to it (env var unset for `PIKPAK_BACKUP_REPO`) and `--preview-setup`. Wait a few seconds. Expected: `<temp>\PikPakSync\scripts\Invoke-GuiAction.ps1`, `...\config\mirror.config.sample.psd1`, `...\engine.hash` exist; no `mirror.config.psd1` exists; `<temp>\PikPakMirror\logs\gui.log` has no "no repo folder" line.
- [ ] **Step 2b: Ask the bridge a question:** pick a read-only action name from `scripts/lib/GuiActions.ps1` and run `'{"action":"<name>","args":{},"preview":true}' | powershell -NoProfile -File <temp>\PikPakSync\scripts\Invoke-GuiAction.ps1`. Expected: one JSON envelope on stdout (`"ok":true` or a clean error code, not `internal`). This proves PowerShell runs the unpacked scripts from a path with a space and an accent.
- [ ] **Step 3: Upgrade check:** edit `<temp>\PikPakSync\config\filters.txt`, create a dummy `mirror.config.psd1`, change one source script and rebuild, run the new `.exe` again: the script is refreshed, both config files are untouched.
- [ ] **Step 4: Clean up:** stop the test process (by PID, not by name), delete the temp folders. The owner's real `%LOCALAPPDATA%\PikPakSync` must not exist afterwards unless it did before.
- [ ] **Step 5:** Record what passed in `docs/superpowers/notes/dev-ledger.md` (one short entry) and commit: `git commit -am "Note the single-exe end-to-end check"`.

### Task 5: Docs, then publish (owner confirms first)

**Files:**
- Create: `README.md` (repo front page: what it is, "Download" link to the latest Release, SmartScreen note, link to `docs/README.md`)
- Modify: `docs/README.md` (new "Download and run" section before "Build it"; reword the installed-copy / `PIKPAK_BACKUP_REPO` text so it says the downloaded `.exe` needs no variable), `docs/OPEN-REQUIREMENTS.md` (R10 now "single exe for other PCs built; second-PC setup still untested")

- [ ] **Step 1: Write the docs** as above in plain language (the owner's README style: short sentences, commands in PowerShell blocks).
- [ ] **Step 2: Run the whole suite one last time:** `powershell -NoProfile -File tests\run.ps1` and `cargo test --manifest-path gui/src-tauri/Cargo.toml` -> both pass. Fix anything found on the way, with a stated reason.
- [ ] **Step 3: Commit:** `git add README.md docs && git commit -m "Document the download-and-run release"`.
- [ ] **Step 4: STOP and ask the owner** before anything leaves this PC: merge `release/single-exe` into `main` and push, run the workflow once by hand (`gh workflow run release.yml`) and read the result with `gh run watch`, then, only after they say yes, `git tag v0.1.0` and push the tag. Report the run result and any tests that behaved differently on the runner.
- [ ] **Step 5 (after the tag run is green):** open the Release page with `gh release view v0.1.0`, confirm it lists exactly the `.exe` and `.sha256`, download the `.exe` into a clean folder and check its SHA-256 against the file. Update the owner's memory note `pikpak-mirror-status.md` with the release.
