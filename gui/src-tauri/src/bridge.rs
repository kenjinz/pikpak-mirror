//! Runs the PowerShell bridge (`scripts\Invoke-GuiAction.ps1`) for the page.
//! Thin on purpose: build the request, start PowerShell without a console
//! window, hand back the one JSON envelope it prints. No business logic here.

use serde_json::{json, Value};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::async_runtime::Mutex as AsyncMutex;

/// Env var that points the app at a repo folder (overrides the walk-up search).
pub const REPO_ENV: &str = "PIKPAK_BACKUP_REPO";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const LOG_MAX_BYTES: u64 = 1024 * 1024;
const LOG_CLIP_CHARS: usize = 8000;

fn script_path(root: &Path) -> PathBuf {
    root.join("scripts").join("Invoke-GuiAction.ps1")
}

/// Walks up from `start` to the first folder that holds `scripts\Invoke-GuiAction.ps1`.
pub fn find_repo_root(start: &Path) -> Option<PathBuf> {
    start
        .ancestors()
        .find(|dir| script_path(dir).is_file())
        .map(Path::to_path_buf)
}

/// `PIKPAK_BACKUP_REPO` when it holds the bridge script, else walk up from the exe's folder.
pub fn resolve_repo_root() -> Option<PathBuf> {
    if let Some(value) = std::env::var_os(REPO_ENV).filter(|v| !v.is_empty()) {
        let root = PathBuf::from(value);
        if script_path(&root).is_file() {
            return Some(root);
        }
        log(&format!(
            "{REPO_ENV} is set to '{}' but it has no scripts\\Invoke-GuiAction.ps1; looking next to the app instead",
            root.display()
        ));
    }
    let exe = std::env::current_exe().ok()?;
    find_repo_root(exe.parent()?)
}

/// The one-line request written to the bridge's stdin. Missing args become `{}`.
pub fn request_json(action: &str, args: &Value, preview: bool) -> String {
    let args = if args.is_null() { json!({}) } else { args.clone() };
    json!({ "action": action, "args": args, "preview": preview }).to_string()
}

/// Reads the envelope from the bridge's stdout: the last non-empty line must be one
/// JSON object. Anything before it is ignored (defensive against stray output).
/// The error text never repeats the raw output; that goes to the log only.
pub fn parse_envelope(stdout: &str) -> Result<Value, String> {
    let line = stdout
        .lines()
        .map(|l| l.trim().trim_start_matches('\u{feff}'))
        .rfind(|l| !l.is_empty())
        .ok_or_else(|| "internal: the PikPak Sync helper gave no answer".to_string())?;
    match serde_json::from_str::<Value>(line) {
        Ok(v) if v.is_object() => Ok(v),
        _ => Err("internal: the PikPak Sync helper gave an answer the app couldn't read".to_string()),
    }
}

fn powershell_exe() -> PathBuf {
    if let Some(root) = std::env::var_os("SystemRoot") {
        let exe = PathBuf::from(root)
            .join("System32")
            .join("WindowsPowerShell")
            .join("v1.0")
            .join("powershell.exe");
        if exe.is_file() {
            return exe;
        }
    }
    PathBuf::from("powershell.exe")
}

fn clip(text: &str) -> String {
    let mut out: String = text.chars().take(LOG_CLIP_CHARS).collect();
    if out.len() < text.len() {
        out.push_str(" [...]");
    }
    out
}

/// How long one action may run before PowerShell is stopped (ruling R16).
pub fn action_timeout(action: &str, args: &Value) -> Duration {
    match action {
        "setup.signin" | "setup.finish" => Duration::from_secs(30 * 60),
        "private.remoteList" | "private.deleteRemote" | "folders.locate" => Duration::from_secs(300),
        "folders.size" => {
            let max = args["maxSeconds"]
                .as_f64()
                .filter(|s| s.is_finite() && *s > 0.0)
                .unwrap_or(20.0);
            Duration::from_secs_f64(max + 30.0)
        }
        _ => Duration::from_secs(120),
    }
}

/// Actions that change the config file, rclone's settings, the schedule or files. They run one
/// at a time (each reads, changes and writes whole files); reads stay concurrent.
pub fn is_write_action(action: &str) -> bool {
    matches!(
        action,
        "config.save"
            | "folders.add"
            | "folders.remove"
            | "folders.convert"
            | "private.add"
            | "private.remove"
            | "schedule.set"
            | "setup.signin"
            | "setup.finish"
            | "holding.restore"
            | "sync.repair"
            | "cleanup"
            | "folders.ensureIds"
            | "folders.pause"
            | "folders.resume"
            | "folders.locate"
            | "folders.adopt"
            | "folders.newId"
            | "private.download"
            | "private.deleteRemote"
    )
}

/// Held for the whole child run of every write action, from the page and the tray alike.
static WRITE_LOCK: AsyncMutex<()> = AsyncMutex::const_new(());

/// A finished child (`output`) or one stopped at its deadline (`output: None`).
pub struct ChildRun {
    pub pid: u32,
    pub output: Option<Output>,
}

/// Reads a pipe to the end on its own thread into a shared buffer, so a full pipe
/// can never block the child and whatever arrived is usable even if the pipe stays open.
fn drain<R: Read + Send + 'static>(mut pipe: R) -> (Arc<Mutex<Vec<u8>>>, mpsc::Receiver<()>) {
    let buffer = Arc::new(Mutex::new(Vec::new()));
    let (done_tx, done_rx) = mpsc::channel();
    let sink = Arc::clone(&buffer);
    std::thread::spawn(move || {
        let mut chunk = [0u8; 8192];
        loop {
            match pipe.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => sink.lock().unwrap().extend_from_slice(&chunk[..n]),
            }
        }
        let _ = done_tx.send(());
    });
    (buffer, done_rx)
}

/// Stops the process and everything it started (`taskkill /T /F`), then the child itself.
fn kill_tree(child: &mut Child) {
    let taskkill = std::env::var_os("SystemRoot")
        .map(|r| PathBuf::from(r).join("System32").join("taskkill.exe"))
        .filter(|p| p.is_file())
        .unwrap_or_else(|| PathBuf::from("taskkill.exe"));
    let _ = Command::new(taskkill)
        .args(["/T", "/F", "/PID", &child.id().to_string()])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .status();
    let _ = child.kill();
    let _ = child.wait();
}

/// Starts `cmd` with no console window, writes `input` to stdin and closes it, drains
/// stdout/stderr concurrently, and stops the whole process tree at `deadline`.
pub fn run_child(mut cmd: Command, input: &[u8], deadline: Duration) -> std::io::Result<ChildRun> {
    let started = Instant::now();
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()?;
    let pid = child.id();
    let (stdout, stdout_done) = drain(child.stdout.take().expect("piped stdout"));
    let (stderr, stderr_done) = drain(child.stderr.take().expect("piped stderr"));
    if let Some(mut stdin) = child.stdin.take() {
        // A child that exits without reading closes the pipe; that's not our error.
        let _ = stdin.write_all(input);
        // stdin is dropped (closed) here so the script sees end of input.
    }

    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if started.elapsed() >= deadline {
            kill_tree(&mut child);
            return Ok(ChildRun { pid, output: None });
        }
        std::thread::sleep(Duration::from_millis(50));
    };

    // The pipes close when the child exits, unless something it started detached
    // still holds them; give the readers a short grace period, then take what arrived.
    let grace = Instant::now() + Duration::from_secs(2);
    for done in [&stdout_done, &stderr_done] {
        let _ = done.recv_timeout(grace.saturating_duration_since(Instant::now()));
    }
    let take = |b: &Arc<Mutex<Vec<u8>>>| std::mem::take(&mut *b.lock().unwrap());
    Ok(ChildRun {
        pid,
        output: Some(Output { status, stdout: take(&stdout), stderr: take(&stderr) }),
    })
}

/// Runs one bridge action and returns its envelope as-is (the page reads `ok`).
/// Fails with `internal: ...` when PowerShell can't start, exits non-zero, prints
/// something that isn't an envelope, or runs past its deadline (`action_timeout`);
/// the raw output is logged, never returned. The request (which may carry a
/// password) is never logged.
/// For plain threads (the tray): a write action waits for the write lock here.
pub fn run(repo_root: Option<&Path>, action: &str, args: &Value, preview: bool) -> Result<Value, String> {
    let _write = is_write_action(action).then(|| WRITE_LOCK.blocking_lock());
    run_with_deadline(repo_root, action, args, preview, action_timeout(action, args))
}

/// `run` for the page's commands: a write action awaits the write lock without holding a
/// thread, then the child runs on the blocking pool with the lock held until it ends.
pub async fn run_async(repo_root: Option<PathBuf>, action: String, args: Value, preview: bool) -> Result<Value, String> {
    let _write = if is_write_action(&action) { Some(WRITE_LOCK.lock().await) } else { None };
    tauri::async_runtime::spawn_blocking(move || {
        let deadline = action_timeout(&action, &args);
        run_with_deadline(repo_root.as_deref(), &action, &args, preview, deadline)
    })
    .await
    .map_err(|e| {
        log(&format!("bridge task failed: {e}"));
        "internal: the app couldn't finish that request".to_string()
    })?
}

fn run_with_deadline(
    repo_root: Option<&Path>,
    action: &str,
    args: &Value,
    preview: bool,
    deadline: Duration,
) -> Result<Value, String> {
    let root = repo_root.ok_or_else(|| {
        log(&format!("{action}: no repo folder with scripts\\Invoke-GuiAction.ps1 was found (set {REPO_ENV} to point at it)"));
        "internal: the app couldn't find the PikPak Sync scripts folder".to_string()
    })?;
    let request = request_json(action, args, preview);

    let mut cmd = Command::new(powershell_exe());
    cmd.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(script_path(root))
        .current_dir(root);
    let run = run_child(cmd, request.as_bytes(), deadline).map_err(|e| {
        log(&format!("{action}: couldn't start PowerShell: {e}"));
        "internal: the app couldn't start PowerShell".to_string()
    })?;
    let Some(output) = run.output else {
        log(&format!(
            "{action}: timed out after {} s; PowerShell (pid {}) and what it started were stopped",
            deadline.as_secs_f64(),
            run.pid
        ));
        return Err("internal: timed out".to_string());
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    if !output.status.success() {
        let code = output.status.code().map_or("none".to_string(), |c| c.to_string());
        log(&format!(
            "{action}: PowerShell exited with code {code}\nstdout: {}\nstderr: {}",
            clip(stdout.trim()),
            clip(stderr.trim())
        ));
        return Err(format!("internal: the PikPak Sync helper stopped with an error (code {code})"));
    }

    parse_envelope(&stdout).inspect_err(|_| {
        log(&format!(
            "{action}: unreadable answer\nstdout: {}\nstderr: {}",
            clip(stdout.trim()),
            clip(stderr.trim())
        ));
    })
}

#[cfg(test)]
thread_local! {
    /// Tests log here instead of the user's real gui.log.
    static TEST_LOG: std::cell::RefCell<Option<PathBuf>> = const { std::cell::RefCell::new(None) };
}

fn log_path() -> Option<PathBuf> {
    #[cfg(test)]
    {
        if let Some(path) = TEST_LOG.with(|t| t.borrow().clone()) {
            return Some(path);
        }
    }
    let base = std::env::var_os("LOCALAPPDATA").filter(|v| !v.is_empty())?;
    Some(PathBuf::from(base).join("PikPakMirror").join("logs").join("gui.log"))
}

/// Appends a line to `<StateDir>\logs\gui.log` (`%LOCALAPPDATA%\PikPakMirror`).
/// Keeps one old file (`gui.log.1`) once the log passes 1 MB. Never fails the caller.
pub fn log(message: &str) {
    let Some(path) = log_path() else { return };
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    if fs::metadata(&path).map(|m| m.len() > LOG_MAX_BYTES).unwrap_or(false) {
        let _ = fs::rename(&path, path.with_extension("log.1"));
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&path) {
        let stamp = chrono::Local::now().format("%Y-%m-%d %H:%M:%S");
        let _ = write!(file, "[{stamp}] {}\r\n", message.replace('\n', "\r\n"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use std::path::PathBuf;
    use std::time::Duration;

    /// A fresh temp folder; this thread logs to gui.log inside it, not the real log.
    fn temp_tree(name: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!(
            "pikpak-backup-test-{}-{}",
            name,
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();
        TEST_LOG.with(|t| *t.borrow_mut() = Some(base.join("gui.log")));
        base
    }

    #[test]
    fn find_repo_root_walks_up() {
        let base = temp_tree("walk");
        let repo = base.join("repo");
        fs::create_dir_all(repo.join("scripts")).unwrap();
        fs::write(repo.join("scripts").join("Invoke-GuiAction.ps1"), "#").unwrap();
        let deep = repo.join("gui").join("src-tauri").join("target").join("debug");
        fs::create_dir_all(&deep).unwrap();

        assert_eq!(find_repo_root(&deep), Some(repo.clone()));
        assert_eq!(find_repo_root(&repo), Some(repo.clone()));

        let elsewhere = base.join("other").join("deeper");
        fs::create_dir_all(&elsewhere).unwrap();
        assert_eq!(find_repo_root(&elsewhere), None);

        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn request_json_has_action_args_preview() {
        let text = request_json("folders.size", &json!({"path": "D:\\Nhạc", "maxSeconds": 20}), true);
        assert!(!text.contains('\n'), "one line on stdin");
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["action"], "folders.size");
        assert_eq!(v["args"]["path"], "D:\\Nhạc");
        assert_eq!(v["args"]["maxSeconds"], 20);
        assert_eq!(v["preview"], true);

        // Missing args (null from the page) become an empty object.
        let v: serde_json::Value =
            serde_json::from_str(&request_json("status", &serde_json::Value::Null, false)).unwrap();
        assert_eq!(v["args"], json!({}));
        assert_eq!(v["preview"], false);
    }

    #[test]
    fn parse_envelope_rejects_non_json() {
        let err = parse_envelope("WARNING: something broke\r\n").unwrap_err();
        assert!(err.starts_with("internal:"), "got {err}");
        assert!(!err.contains("something broke"), "raw text is never shown: {err}");

        assert!(parse_envelope("").unwrap_err().starts_with("internal:"));
        // A JSON value that is not an object is not an envelope.
        assert!(parse_envelope("[1,2]").unwrap_err().starts_with("internal:"));
    }

    #[test]
    fn parse_envelope_takes_last_line_when_noise_precedes() {
        let out = "some noise\r\nmore noise {\r\n{\"ok\":true,\"data\":{\"x\":1}}\r\n\r\n";
        let v = parse_envelope(out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["x"], 1);

        // Error envelopes are returned as-is; the page reads `ok`.
        let v = parse_envelope("{\"ok\":false,\"error\":{\"code\":\"locked\",\"message\":\"m\"}}").unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"]["code"], "locked");
    }

    #[test]
    fn run_without_repo_root_is_internal_error() {
        let base = temp_tree("noroot");
        let err = run(None, "status", &json!({}), false).unwrap_err();
        assert!(err.starts_with("internal:"), "got {err}");
        let logged = fs::read_to_string(base.join("gui.log")).unwrap();
        assert!(logged.contains(REPO_ENV), "log: {logged}");
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn run_with_broken_script_is_internal_error_not_raw_text() {
        let base = temp_tree("broken");
        fs::create_dir_all(base.join("scripts")).unwrap();
        fs::write(
            base.join("scripts").join("Invoke-GuiAction.ps1"),
            "Write-Output 'not json at all'\r\nexit 3\r\n",
        )
        .unwrap();
        let err = run(Some(&base), "status", &json!({}), false).unwrap_err();
        assert!(err.starts_with("internal:"), "got {err}");
        assert!(!err.contains("not json"), "raw text is never shown: {err}");
        let logged = fs::read_to_string(base.join("gui.log")).unwrap();
        assert!(logged.contains("code 3") && logged.contains("not json at all"), "log: {logged}");

        fs::write(base.join("scripts").join("Invoke-GuiAction.ps1"), "Write-Output 'still not json'\r\n").unwrap();
        let err = run(Some(&base), "status", &json!({}), false).unwrap_err();
        assert!(err.starts_with("internal:"), "got {err}");
        let logged = fs::read_to_string(base.join("gui.log")).unwrap();
        assert!(logged.contains("still not json"), "log: {logged}");
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn action_timeout_table() {
        let none = json!({});
        assert_eq!(action_timeout("status", &none), Duration::from_secs(120));
        assert_eq!(action_timeout("config.save", &none), Duration::from_secs(120));
        assert_eq!(action_timeout("setup.signin", &none), Duration::from_secs(30 * 60));
        assert_eq!(action_timeout("setup.finish", &none), Duration::from_secs(30 * 60));
        assert_eq!(action_timeout("folders.size", &none), Duration::from_secs(20 + 30));
        assert_eq!(action_timeout("folders.size", &json!({"maxSeconds": 45})), Duration::from_secs(45 + 30));
        assert_eq!(action_timeout("folders.size", &json!({"maxSeconds": 2.5})), Duration::from_secs_f64(2.5 + 30.0));
        // Nonsense maxSeconds falls back to the default 20.
        assert_eq!(action_timeout("folders.size", &json!({"maxSeconds": -3})), Duration::from_secs(20 + 30));
        assert_eq!(action_timeout("folders.size", &json!({"maxSeconds": "x"})), Duration::from_secs(20 + 30));
        assert_eq!(action_timeout("private.remoteList", &none), Duration::from_secs(300));
        assert_eq!(action_timeout("private.deleteRemote", &none), Duration::from_secs(300));
        assert_eq!(action_timeout("folders.locate", &none), Duration::from_secs(300));
    }

    #[test]
    fn write_action_table() {
        for a in [
            "config.save",
            "folders.add",
            "folders.remove",
            "folders.convert",
            "private.add",
            "private.remove",
            "schedule.set",
            "setup.signin",
            "setup.finish",
            "holding.restore",
            "sync.repair",
            "cleanup",
            "folders.ensureIds",
            "folders.pause",
            "folders.resume",
            "folders.locate",
            "folders.adopt",
            "folders.newId",
            "private.download",
            "private.deleteRemote",
        ] {
            assert!(is_write_action(a), "{a} is a write action");
        }
        for a in [
            "status",
            "config.get",
            "folders.size",
            "folders.convertReview",
            "private.review",
            "schedule.get",
            "sync.start",
            "holding.list",
            "key.show",
            "setup.newkey",
            "folders.suggest",
            "about",
            "nope",
            "folders.identify",
            "folders.locateReview",
            "private.remoteList",
        ] {
            assert!(!is_write_action(a), "{a} is not a write action");
        }
    }

    /// A repo whose bridge sleeps `ms`, records its own start and end (ticks) in
    /// scripts\t-<pid>.txt, then answers ok.
    fn sleeping_repo(name: &str, ms: u32) -> PathBuf {
        let base = temp_tree(name);
        fs::create_dir_all(base.join("scripts")).unwrap();
        let script = format!(
            "$s = [DateTime]::UtcNow.Ticks\r\nStart-Sleep -Milliseconds {ms}\r\n$e = [DateTime]::UtcNow.Ticks\r\n\
             Set-Content -LiteralPath (Join-Path $PSScriptRoot ('t-' + $PID + '.txt')) -Value \"$s $e\"\r\n\
             '{{\"ok\":true,\"data\":{{}}}}'\r\n"
        );
        fs::write(base.join("scripts").join("Invoke-GuiAction.ps1"), script).unwrap();
        base
    }

    /// The (start, end) of every bridge run in a `sleeping_repo`, ordered by start.
    fn runs_of(base: &Path) -> Vec<(i64, i64)> {
        let mut runs: Vec<(i64, i64)> = fs::read_dir(base.join("scripts"))
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().starts_with("t-"))
            .map(|e| {
                let text = fs::read_to_string(e.path()).unwrap();
                let mut it = text.split_whitespace().map(|n| n.parse::<i64>().unwrap());
                (it.next().unwrap(), it.next().unwrap())
            })
            .collect();
        runs.sort();
        runs
    }

    /// Runs `action` twice at the same time through `run_async`; both must answer ok.
    fn run_two_at_once(base: &Path, action: &str) {
        let root = base.to_path_buf();
        let (a, b) = tauri::async_runtime::block_on(async {
            let a = tauri::async_runtime::spawn(run_async(Some(root.clone()), action.to_string(), json!({}), false));
            let b = tauri::async_runtime::spawn(run_async(Some(root.clone()), action.to_string(), json!({}), false));
            (a.await.unwrap(), b.await.unwrap())
        });
        assert_eq!(a.unwrap()["ok"], true);
        assert_eq!(b.unwrap()["ok"], true);
    }

    #[test]
    fn write_actions_never_overlap() {
        let base = sleeping_repo("writes", 1500);
        run_two_at_once(&base, "config.save");
        let runs = runs_of(&base);
        assert_eq!(runs.len(), 2, "runs: {runs:?}");
        assert!(runs[1].0 >= runs[0].1, "the second write started before the first ended: {runs:?}");
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn read_actions_run_side_by_side() {
        let base = sleeping_repo("reads", 3000);
        run_two_at_once(&base, "status");
        let runs = runs_of(&base);
        assert_eq!(runs.len(), 2, "runs: {runs:?}");
        assert!(runs[1].0 < runs[0].1, "reads waited for each other: {runs:?}");
        let _ = fs::remove_dir_all(&base);
    }

    fn pid_alive(pid: u32) -> bool {
        let out = Command::new("tasklist")
            .args(["/FI", &format!("PID eq {pid}"), "/NH", "/FO", "CSV"])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).contains(&format!("\"{pid}\""))
    }

    #[test]
    fn run_child_kills_a_child_past_its_deadline() {
        let mut cmd = Command::new(powershell_exe());
        cmd.args(["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 10"]);
        let started = std::time::Instant::now();
        let run = run_child(cmd, b"", Duration::from_secs(1)).unwrap();
        assert!(run.output.is_none(), "timed out");
        assert!(started.elapsed() < Duration::from_secs(8), "did not wait for the sleep");
        assert!(!pid_alive(run.pid), "child {} still alive", run.pid);
    }

    #[test]
    fn run_child_kills_the_whole_tree() {
        let base = temp_tree("tree");
        let pid_file = base.join("inner.pid");
        let inner = base.join("inner.ps1");
        let outer = base.join("outer.ps1");
        fs::write(&inner, format!("$PID | Set-Content -LiteralPath '{}'\r\nStart-Sleep 60\r\n", pid_file.display())).unwrap();
        fs::write(&outer, format!("& '{}' -NoProfile -File '{}'\r\n", powershell_exe().display(), inner.display())).unwrap();
        let mut cmd = Command::new(powershell_exe());
        cmd.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]).arg(&outer);
        let run = run_child(cmd, b"", Duration::from_secs(6)).unwrap();
        assert!(run.output.is_none(), "timed out");
        let inner_pid: u32 = fs::read_to_string(&pid_file).expect("inner started").trim().parse().unwrap();
        std::thread::sleep(Duration::from_millis(500));
        assert!(!pid_alive(run.pid), "outer {} still alive", run.pid);
        assert!(!pid_alive(inner_pid), "grandchild {inner_pid} still alive");
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn run_child_drains_large_output() {
        // ~2 MB on stdout and stderr: more than any pipe buffer, must not deadlock.
        let mut cmd = Command::new(powershell_exe());
        cmd.args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "$s = 'x' * 1000; foreach ($i in 1..2000) { [Console]::Out.WriteLine($s); [Console]::Error.WriteLine($s) }",
        ]);
        let run = run_child(cmd, b"", Duration::from_secs(60)).unwrap();
        let output = run.output.expect("finished");
        assert!(output.stdout.len() >= 2_000_000, "stdout {}", output.stdout.len());
        assert!(output.stderr.len() >= 2_000_000, "stderr {}", output.stderr.len());
    }

    #[test]
    fn run_times_out_with_internal_timed_out_and_logs_one_line() {
        let base = temp_tree("slow");
        fs::create_dir_all(base.join("scripts")).unwrap();
        fs::write(base.join("scripts").join("Invoke-GuiAction.ps1"), "Start-Sleep 10\r\n").unwrap();
        let err = run_with_deadline(Some(&base), "setup.signin", &json!({"password": "hunter2"}), false, Duration::from_secs(1))
            .unwrap_err();
        assert_eq!(err, "internal: timed out");
        let logged = fs::read_to_string(base.join("gui.log")).unwrap();
        assert!(logged.contains("setup.signin") && logged.contains("timed out"), "log: {logged}");
        assert!(!logged.contains("hunter2"), "request never logged: {logged}");
        assert_eq!(logged.lines().count(), 1, "one line: {logged}");
        let _ = fs::remove_dir_all(&base);
    }

    /// Live, read-only: runs the repo's real bridge with `status`.
    /// `cargo test --manifest-path gui/src-tauri/Cargo.toml -- --ignored`
    #[test]
    #[ignore]
    fn live_status_returns_an_envelope() {
        let _log = temp_tree("live-status");
        let here = Path::new(env!("CARGO_MANIFEST_DIR"));
        let root = find_repo_root(here).expect("repo root above gui/src-tauri");
        let v = run(Some(&root), "status", &json!({}), false).expect("envelope");
        assert_eq!(v["ok"], true, "envelope: {v}");
        assert!(v["data"]["Tone"].is_string(), "envelope: {v}");
    }

    /// Live: an unknown action comes back as a bad-request envelope (Ok, not Err).
    #[test]
    #[ignore]
    fn live_unknown_action_is_bad_request_envelope() {
        let _log = temp_tree("live-nope");
        let here = Path::new(env!("CARGO_MANIFEST_DIR"));
        let root = find_repo_root(here).expect("repo root above gui/src-tauri");
        let v = run(Some(&root), "nope", &json!({}), false).expect("envelope");
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"]["code"], "bad-request");
    }
}
