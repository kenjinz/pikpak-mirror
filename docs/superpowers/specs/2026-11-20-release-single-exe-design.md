# Release v0.1: one downloadable `.exe`, built by GitHub Actions

Date: 2026-11-20. Status: awaiting approval. Size: small-to-medium (a Rust shell change, a build script, one workflow, docs).

## Intent and why

The owner made the repo public and wants to publish **v0.1** so anyone can **download one file and run it**.
Today the `.exe` is only a thin Tauri shell: the real work is the PowerShell engine in `scripts\`, which the
app finds by walking up from its own folder (`bridge.rs: resolve_repo_root`) or via `PIKPAK_BACKUP_REPO`. A copy of
the `.exe` on its own cannot work. The release must be built on a free GitHub Actions runner (the repo is public).

## Goals

- A GitHub Release `v0.1.0` with **one** file to download: `PikPak-Sync-v0.1.0-windows-x64.exe`, plus a `.sha256`.
- Download, double-click, the app starts and the first-run setup works. No env var, no folder to keep, no installer.
- The build is made by Actions from a tag (`v*`), and fails when the tests fail or the tag does not match the app version.
- Upgrading (run a newer `.exe`) replaces the engine and keeps the user's config.

## Non-goals / anti-goals

- No code signing (costs money; SmartScreen will warn: "More info, Run anyway". Said in the release notes).
- No installer, no auto-update, no Linux/macOS, no change to what the engine does.
- Must not break the owner's live install (scheduled task points at `G:\pikpak-mirror\scripts`, config lives in the repo).
  The existing lookup order stays first: env var, then walk up from the `.exe`.
- Must never overwrite or delete the user's `mirror.config.psd1` (or its `.bak` / `.original`).

## Approaches considered

1. **Single `.exe` with the engine embedded (chosen by the owner).** The `.exe` carries `scripts\` and the config templates and unpacks them on first run.
2. A zip with `.exe` + `scripts\` + `config\`. Rejected: not one file; the scheduled task breaks if the folder moves.
3. An NSIS installer with bundled resources. Rejected: not "run only", bigger change.

## Design

**Embedding.** `gui/src-tauri/build.rs` walks `scripts\` (all files) and `config\mirror.config.sample.psd1` and
`config\filters.txt`, and generates a table of `(relative path, bytes via include_bytes!)` in `OUT_DIR`, plus a hash of all
contents. No new crate is needed. Cargo re-runs it when those files change.

**Where it unpacks.** `%LOCALAPPDATA%\PikPakSync\` is the engine root (name has no space, my call). Inside it: `scripts\`,
`config\`, and a marker file `engine.hash`. The root has the same shape as the repo, so the engine needs no change: the
scheduled task, `Convert-Folder.ps1`, etc. all resolve from `RepoRoot`. State and logs stay where they are
(`%LOCALAPPDATA%\PikPakMirror`, from the config's `StateDir`).

**When it unpacks.** At start-up, only when no root was found by the existing lookup (env var, walk-up), and only when
`engine.hash` is missing or differs from the embedded hash, or `scripts\Invoke-GuiAction.ps1` is missing. Unpack writes
the new `scripts\` next to the old one and swaps it in; the sample config and `filters.txt` are written
(`filters.txt` only if missing, so the user's edits survive; the sample is always refreshed). `mirror.config.psd1` is never touched.
If the swap fails (for example a sync is running from the old scripts), keep the old engine, log it, and try again at the next start.

**Lookup order becomes:** `PIKPAK_BACKUP_REPO` -> walk up from the `.exe` (dev builds) -> the unpacked engine root.

**CI: `.github/workflows/release.yml`**, trigger `push` of tags `v*` (and `workflow_dispatch` for a dry run that
builds and tests but publishes nothing). On `windows-latest`:
1. Check the tag equals the version in `tauri.conf.json` and `Cargo.toml`; fail if not.
2. Install Pester 5.7.1 and run `tests\run.ps1`; run `cargo test`.
3. `cargo tauri build --no-bundle` (not a bare `cargo build --release`: that would give a dev-mode window), with a Cargo cache.
4. Rename the `.exe`, write the SHA-256, create the Release with `gh release create` and attach both. Notes mention SmartScreen, WebView2 and the first-run rclone download.

**Docs.** README gets a short "Download and run" section; the "installed copy needs `PIKPAK_BACKUP_REPO`" text and R10 in
`OPEN-REQUIREMENTS.md` are updated.

## Verification (before tagging)

- Rust unit tests for the unpack/upgrade logic (fresh, unchanged, changed hash keeps config, locked swap keeps old).
- Build the release `.exe` locally, copy it alone to an empty folder, run it with `LOCALAPPDATA` pointed at a temp
  folder and `--preview-setup`, and confirm the engine unpacks and the bridge answers. (Temp `LOCALAPPDATA` keeps the
  owner's live install untouched.)
- A `workflow_dispatch` dry run on GitHub, then tag `v0.1.0`.

## Left to the builder

Exact table/hash format in `build.rs`; how to cache the Tauri CLI install in CI; release-notes wording.

## Risks the owner should know

- Pester/Rust tests were written for the owner's PC; some may behave differently on the runner. If so I fix or
  skip those with a stated reason, and tell the owner, rather than weaken the gate silently.
- Needs the Microsoft WebView2 runtime (built into Windows 11 and current Windows 10).
- Needs internet on first run (rclone is downloaded and SHA-checked by the existing setup).
