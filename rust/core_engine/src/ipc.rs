//! The protocol between the core and the resident LLM worker.
//!
//! One request is one task: three length-prefixed strings (task, instruction,
//! text). One reply is a status byte and one length-prefixed body. The framing is
//! hand-rolled on purpose -- both ends are this repository, the payloads are
//! UTF-8 strings, and a serialisation crate would be a dependency bought for six
//! lines of `u32::to_be_bytes`.
//!
//! This is not the C ABI. Nothing outside the engine talks this protocol: the
//! worker is an implementation detail of `state::run_task_once`, and a build that
//! cannot use a socket falls back to spawning the worker for one task, which is
//! what the engine did before this module existed.

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use crate::error::{EngineError, ErrorCode};

pub type Result<T, E = EngineError> = std::result::Result<T, E>;

/// The largest single field the reader will accept. A corrupt length must not
/// turn into a multi-gigabyte allocation; real fields are bounded by the context
/// window long before they reach this.
const MAX_FIELD: u32 = 16 * 1024 * 1024;

/// The three strings of one task, in the order the worker's positional contract
/// already used (`task model instruction`, with the text on stdin).
pub struct Request {
    pub task: String,
    pub instruction: String,
    pub text: String,
}

/// The worker's answer. `ok == false` carries the error message the one-shot
/// worker used to print on stderr.
pub struct Response {
    pub ok: bool,
    pub body: String,
}

/// Where the resident worker for `model` listens.
///
/// The name carries a hash of the model path rather than the path itself: a
/// model swapped on disk must not be answered by a worker still holding the old
/// weights, and a `sun_path` is about a hundred bytes -- too short for a
/// directory name, comfortable for sixteen hex digits. The path is canonicalised
/// first so two callers spelling the same file differently find one worker.
pub fn socket_path(model: &Path) -> PathBuf {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    let canonical = std::fs::canonicalize(model).unwrap_or_else(|_| model.to_path_buf());
    let mut hasher = DefaultHasher::new();
    canonical.hash(&mut hasher);
    std::env::temp_dir().join(format!("ovc-llm-{:016x}.sock", hasher.finish()))
}

/// One round trip to the worker at `socket`.
///
/// A connect failure is the caller's cue to start a worker (or fall back); an
/// answer with `ok == false` is a real error from the model and must NOT be
/// retried, because the second attempt would produce the same failure twice as
/// slowly.
pub fn request(socket: &Path, request: &Request) -> io::Result<Response> {
    use std::os::unix::net::UnixStream;
    use std::time::Duration;

    let mut stream = UnixStream::connect(socket)?;
    // A wedged worker (a stalled Metal backend has done this) would otherwise
    // hang the app's whole core queue. The timeout is the load plus a long
    // generation on the slowest machine this ships on, not a latency budget.
    stream.set_read_timeout(Some(Duration::from_secs(300)))?;
    stream.set_write_timeout(Some(Duration::from_secs(30)))?;
    write_request(&mut stream, request)?;
    read_response(&mut stream)
}

/// Whether something is listening at `socket` right now.
///
/// A connect is enough: the worker binds before it loads a model, so "listening"
/// is exactly the state the caller is waiting for.
pub fn ping(socket: &Path) -> io::Result<()> {
    use std::os::unix::net::UnixStream;
    UnixStream::connect(socket).map(|_| ())
}

/// Whether an exchange failed before the worker could answer, as opposed to
/// answering with an error. Only the former is worth retrying somewhere else.
pub fn unreachable(error: &io::Error) -> bool {
    use std::io::ErrorKind::*;
    matches!(error.kind(), NotFound | ConnectionRefused | ConnectionReset | BrokenPipe | TimedOut | UnexpectedEof)
}

pub fn write_request<W: Write>(w: &mut W, request: &Request) -> io::Result<()> {
    write_field(w, &request.task)?;
    write_field(w, &request.instruction)?;
    write_field(w, &request.text)?;
    w.flush()
}

pub fn read_request<R: Read>(r: &mut R) -> io::Result<Request> {
    Ok(Request {
        task: read_field(r)?,
        instruction: read_field(r)?,
        text: read_field(r)?,
    })
}

pub fn write_response<W: Write>(w: &mut W, response: &Response) -> io::Result<()> {
    w.write_all(&[u8::from(!response.ok)])?;
    write_field(w, &response.body)?;
    w.flush()
}

pub fn read_response<R: Read>(r: &mut R) -> io::Result<Response> {
    let mut status = [0u8; 1];
    r.read_exact(&mut status)?;
    Ok(Response { ok: status[0] == 0, body: read_field(r)? })
}

fn write_field<W: Write>(w: &mut W, value: &str) -> io::Result<()> {
    let bytes = value.as_bytes();
    let len = u32::try_from(bytes.len()).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "field too long"))?;
    w.write_all(&len.to_be_bytes())?;
    w.write_all(bytes)
}

fn read_field<R: Read>(r: &mut R) -> io::Result<String> {
    let mut header = [0u8; 4];
    r.read_exact(&mut header)?;
    let len = u32::from_be_bytes(header);
    if len > MAX_FIELD {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "field length out of range"));
    }
    let mut bytes = vec![0u8; len as usize];
    r.read_exact(&mut bytes)?;
    String::from_utf8(bytes).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "field is not UTF-8"))
}

/// The task names, answered by the same functions the in-process path calls.
///
/// One copy, used by both of the worker's modes. It used to be written out twice
/// (the worker binary and `state::run_in_process`); a third copy for the socket
/// server would have made "which task names exist" a question with three
/// answers, so the binary now calls this instead of repeating it.
pub fn run_task(task: &str, model: &Path, text: &str, instruction: &str) -> Result<String> {
    match task {
        "refine" => crate::llm::refine_with_keywords(model, text, instruction),
        "refine-two-stage" => crate::llm::refine_two_stage(model, text, instruction),
        // The tone tasks are separate names rather than an extra argument,
        // because the worker's contract is positional (`task model instruction`)
        // and the instruction slot already carries the keywords hint.
        "refine-casual" => crate::llm::refine_with_tone(model, text, instruction, crate::llm::Tone::Casual),
        "refine-formal" => crate::llm::refine_with_tone(model, text, instruction, crate::llm::Tone::Formal),
        "summary" => crate::llm::summarize_one(model, instruction, text),
        "translate" => crate::llm::translate(model, text, instruction),
        "edit" => crate::llm::edit_with_instruction(model, text, instruction),
        // Not a task: a request with no text that only loads the weights, so the
        // app can prewarm through the same channel as everything else.
        "warm" => crate::llm::warm_session(model).map(|()| String::new()),
        other => Err(EngineError::new(
            ErrorCode::Internal,
            format!("unknown LLM task: {other}"),
        )),
    }
}
