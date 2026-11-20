//! Besides the usual Tauri build step, embeds the PowerShell engine into the app.
//!
//! Only an allowlist goes in: every `*.ps1` under `scripts\`, plus the two config templates. The
//! owner's real `config\mirror.config.psd1` (private paths) must never be embedded.
//! Writes `$OUT_DIR/engine_bundle.rs` with `FILES` (relative path with `/`, bytes) and `HASH`
//! (FNV-1a 64 of every path and content, in sorted path order, as 16 hex digits).

use std::path::{Path, PathBuf};
use std::{env, fs};

const CONFIG_FILES: [&str; 2] = ["config/mirror.config.sample.psd1", "config/filters.txt"];

fn collect_scripts(dir: &Path, rel: &str, out: &mut Vec<(String, PathBuf)>) {
    let entries = fs::read_dir(dir).unwrap_or_else(|e| panic!("cannot read {}: {e}", dir.display()));
    for entry in entries {
        let entry = entry.expect("directory entry");
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = entry.path();
        let rel_path = format!("{rel}/{name}");
        if path.is_dir() {
            collect_scripts(&path, &rel_path, out);
        } else if name.ends_with(".ps1") {
            out.push((rel_path, path));
        }
    }
}

fn fnv1a(hash: &mut u64, bytes: &[u8]) {
    for b in bytes {
        *hash ^= u64::from(*b);
        *hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
}

fn main() {
    tauri_build::build();

    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    // gui/src-tauri -> gui -> repo root
    let repo = manifest.parent().and_then(Path::parent).expect("repo root above gui/src-tauri");

    let mut files: Vec<(String, PathBuf)> = Vec::new();
    collect_scripts(&repo.join("scripts"), "scripts", &mut files);
    for rel in CONFIG_FILES {
        let path = repo.join(rel);
        assert!(path.is_file(), "{} is needed to build the app", path.display());
        files.push((rel.to_string(), path));
    }
    files.sort_by(|a, b| a.0.cmp(&b.0));

    println!("cargo:rerun-if-changed={}", repo.join("scripts").display());
    for rel in CONFIG_FILES {
        println!("cargo:rerun-if-changed={}", repo.join(rel).display());
    }

    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut table = String::from("pub static FILES: &[(&str, &[u8])] = &[\n");
    for (rel, path) in &files {
        let bytes = fs::read(path).unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
        fnv1a(&mut hash, rel.as_bytes());
        fnv1a(&mut hash, &[0]);
        fnv1a(&mut hash, &bytes);
        fnv1a(&mut hash, &[0]);
        table.push_str(&format!(
            "    ({rel:?}, include_bytes!({:?}) as &[u8]),\n",
            path.to_string_lossy()
        ));
    }
    table.push_str("];\n");
    table.push_str(&format!("pub const HASH: &str = \"{hash:016x}\";\n"));

    let out = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR")).join("engine_bundle.rs");
    fs::write(&out, table).unwrap_or_else(|e| panic!("cannot write {}: {e}", out.display()));
}
