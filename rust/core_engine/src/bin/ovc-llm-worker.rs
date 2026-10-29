//! Out-of-process LLM refinement.
//!
//! Two modes:
//!
//! * One-shot (the original): `ovc-llm-worker <task> <model.gguf> [instruction]`
//!   reads the text from stdin, writes the result to stdout, and exits. Exiting
//!   returns all LLM memory (weights, Metal buffers) to the OS, so the parent
//!   process's peak RSS does not include them.
//! * Resident: `ovc-llm-worker serve <socket> <model.gguf>`. Loads the model once
//!   and answers requests over a Unix socket until it has been idle too long or
//!   the process that started it is gone. This is what the app uses: the load and
//!   the KV prefix of every prompt are paid once per session instead of once per
//!   sentence.
//!
//! The one-shot mode is kept as the fallback for a host that cannot use a socket
//! (and for the command-line probes, which drive it directly). Both modes run the
//! same task table (`ipc::run_task`), so a task cannot mean one thing here and
//! another there.
//!
//! `instruction` is, per task: the keywords hint (refine, refine-two-stage,
//! refine-casual, refine-formal), the section instruction (summary), the target
//! language (translate), or the spoken edit instruction (edit). stdin: UTF-8 text.
//! stdout: UTF-8 result. Exit code 0 on success.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

const USAGE: &str = "usage: ovc-llm-worker <refine|refine-two-stage|refine-casual|refine-formal|summary|translate|edit> \
     <model.gguf> [instruction]\n       ovc-llm-worker serve <socket> <model.gguf>";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    }
    if args[1] == "serve" {
        if args.len() < 4 {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
        return serve(Path::new(&args[2]), &PathBuf::from(&args[3]));
    }
    let task = args[1].as_str();
    let model = PathBuf::from(&args[2]);
    let instruction = args.get(3).cloned().unwrap_or_default();
    let mut input = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut input) {
        eprintln!("stdin: {e}");
        return ExitCode::from(2);
    }
    match offline_voice_core::ipc::run_task(task, &model, input.trim(), &instruction) {
        Ok(text) => {
            let mut out = std::io::stdout().lock();
            if out.write_all(text.as_bytes()).and_then(|_| out.flush()).is_err() {
                return ExitCode::from(3);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{}", e.msg);
            ExitCode::from(1)
        }
    }
}

/// Answers requests until the parent goes away or the worker has been idle.
///
/// The two exit conditions are the two ways a resident worker becomes a leak: an
/// app that was quit or killed (the model must not outlive it) and a user who
/// stopped dictating an hour ago (1.3 GB must not stay pinned). `OVC_LLM_IDLE_SECS`
/// overrides the idle limit; `0` means "never idle out", which is what a
/// measurement run wants.
fn serve(socket: &Path, model: &Path) -> ExitCode {
    use std::os::unix::net::{UnixListener, UnixStream};

    // One worker per socket. If a live one is already listening, this process
    // has nothing to do: the app that spawned it will talk to the other one.
    if UnixStream::connect(socket).is_ok() {
        eprintln!("ovc-llm serve: {} already has a worker", socket.display());
        return ExitCode::SUCCESS;
    }
    // Nobody is listening, so a file at that path is left over from a worker that
    // was killed. Bind refuses to reuse it.
    let _ = std::fs::remove_file(socket);
    let listener = match UnixListener::bind(socket) {
        Ok(listener) => listener,
        Err(e) => {
            eprintln!("ovc-llm serve: bind {}: {e}", socket.display());
            return ExitCode::from(1);
        }
    };
    // The socket is a control channel for this user's app, not a service.
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600));
    }
    if let Err(e) = listener.set_nonblocking(true) {
        eprintln!("ovc-llm serve: nonblocking: {e}");
        return ExitCode::from(1);
    }

    let parent = std::os::unix::process::parent_id();
    let idle = idle_limit();
    eprintln!(
        "ovc-llm serve: listening on {} (pid {}, parent {}, idle {})",
        socket.display(),
        std::process::id(),
        parent,
        match idle {
            Some(limit) => format!("{}s", limit.as_secs()),
            None => "never".to_string(),
        }
    );

    let mut last_activity = Instant::now();
    loop {
        if std::os::unix::process::parent_id() != parent {
            eprintln!("ovc-llm serve: parent exited, shutting down");
            break;
        }
        if let Some(limit) = idle {
            if last_activity.elapsed() >= limit {
                eprintln!("ovc-llm serve: idle for {}s, shutting down", limit.as_secs());
                break;
            }
        }
        match listener.accept() {
            Ok((stream, _)) => {
                handle(stream, model);
                // The clock starts when the answer was written, not when the
                // request arrived: a long generation is not idleness.
                last_activity = Instant::now();
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(200));
            }
            // One bad connection is not a reason to drop the model.
            Err(e) => eprintln!("ovc-llm serve: accept: {e}"),
        }
    }

    // Explicit, so the memory is gone before the process is reaped rather than
    // whenever the OS gets around to it.
    offline_voice_core::llm::release_session();
    // The socket file is deliberately left behind. Unlinking it here would race
    // with a replacement worker that bound the same path while this one was
    // shutting down, and a leftover file costs nothing: the next start connects,
    // finds nobody listening, and unlinks it itself (see the top of `serve`).
    ExitCode::SUCCESS
}

fn handle(mut stream: std::os::unix::net::UnixStream, model: &Path) {
    use offline_voice_core::ipc::{self, Response};

    let request = match ipc::read_request(&mut stream) {
        Ok(request) => request,
        // A connect-and-close is how a client checks that the worker is up
        // (`ipc::ping`); it is not a failed request and does not deserve a line.
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return,
        Err(e) => {
            eprintln!("ovc-llm serve: read request: {e}");
            return;
        }
    };
    let response = match ipc::run_task(&request.task, model, &request.text, &request.instruction) {
        Ok(text) => Response { ok: true, body: text },
        Err(e) => {
            eprintln!("ovc-llm serve: {}: {}", request.task, e.msg);
            Response { ok: false, body: e.msg }
        }
    };
    if let Err(e) = ipc::write_response(&mut stream, &response) {
        // The client hung up (the app was quit mid-answer). Nothing to do: the
        // loop keeps the model for the next request.
        eprintln!("ovc-llm serve: write response: {e}");
    }
}

/// How long the worker may sit unused before it drops the model.
///
/// Five minutes: long enough that a pause between sentences, or a user reading
/// what they just got, never pays the load again; short enough that a forgotten
/// worker is not holding a gigabyte for the rest of the afternoon.
fn idle_limit() -> Option<Duration> {
    match std::env::var("OVC_LLM_IDLE_SECS").ok().and_then(|v| v.trim().parse::<u64>().ok()) {
        Some(0) => None,
        Some(secs) => Some(Duration::from_secs(secs)),
        None => Some(Duration::from_secs(300)),
    }
}
