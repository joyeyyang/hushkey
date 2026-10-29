import Foundation
import VoiceInputKit

// `voiceinput` — a command-line proof that the whole voice-input method is
// callable from outside the GUI app. It links `VoiceInputKit`, builds a
// `VoiceInputConfig`, and drives files (and, optionally, the cursor) through it.
//
// The argument parser is hand-rolled on purpose: one small file should not drag
// in a dependency, and the surface is a dozen flags.

// MARK: - Output helpers

/// Failures go to stderr as one line so a script can read them, and the exit
/// status is non-zero so a script can branch on it.
func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("voiceinput: " + message + "\n").utf8))
    exit(code)
}

// MARK: - Options

enum OutputMode {
    /// Header + refined text, for a human reading the terminal.
    case human
    /// Refined text only, for piping.
    case refined
    /// Verbatim transcript only, for piping.
    case raw
}

struct Options {
    var modelsDirectory: URL?
    var files: [URL] = []
    var keywords: [String] = []
    var addKeyword: String?
    var listKeywords = false
    var selftest = false
    var paste = false
    var mode: OutputMode = .human
    var translateTarget = "auto"
    var refineStages: UInt32 = 0
    /// The cleanup's register. The three accepted values are the core's, and a
    /// typo is an error here (see `parseArguments`) so a measurement run cannot
    /// silently measure the default three times.
    var refineTone = "normal"
    /// `--refine`: clean the text on stdin and print the result.
    var refineOnly = false
    var llmModel: String?
    var worker: URL?
    var polishEnabled = true
    /// `--is-edit`: a line to classify, printed as yes/no and nothing else.
    var isEdit: String?
    /// `--edit`: the instruction; the text it applies to arrives on stdin.
    var editInstruction: String?
    /// `--region`: which part of the stdin text the instruction is about.
    var editRegion: PromptEditRegion = .whole
    /// `--select A:B`: the character range for `--region selection`.
    var editSelection: String?
    /// `--summarize`: the transcript to summarise; it arrives on stdin.
    var summarize = false
}

let usage = """
usage: voiceinput [options] <audio-file> [...]

  --models <dir>          model tree root (default: standard Application Support path)
  --transcribe <file>     print the refined text only
  --raw <file>            print the verbatim transcript only
  --keyword <term>        add a proper-noun hint for this run (repeatable)
  --list-keywords         print the stored keyword list and exit
  --add-keyword <term>    append a term to the stored list and print it
  --translate <auto|off|en|zh>  language handling (default auto)
  --refine-stages <0|1|2> cleanup passes; 0 lets the engine decide (default 0)
  --tone <casual|normal|formal>  register of the cleanup (default normal)
  --refine                clean the text read from stdin and print it
  --llm <file>            bare LLM filename inside models/llm/
  --no-polish             skip the AI cleanup pass entirely
  --is-edit <text>        print yes/no: does this line read as a spoken edit?
  --edit <instruction>    edit the text read from stdin (whole stream) and print it
  --region <whole|line:N|selection>
                          which part of that text the instruction is about
                          (default whole; selection needs --select A:B)
  --select <A:B>          character offsets of the selected region
  --summarize             summarise the transcript read from stdin (meeting sections)
  --paste                 also paste the refined text at the cursor (needs Accessibility)
  --selftest              run a built-in check and print PASS/FAIL
  --help                  this text
"""

func parseArguments(_ args: [String]) -> Options {
    var opts = Options()
    var i = 0

    // A flag that takes one value; reports a clean usage error when it is last.
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("\(flag) requires a value", code: 1) }
        return args[i]
    }

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--help", "-h":
            print(usage)
            exit(0)
        case "--models":
            opts.modelsDirectory = URL(fileURLWithPath: value("--models"))
        // The file may follow the flag or come later as a positional: both
        // readings are natural to type, and rejecting one of them is a papercut.
        case "--transcribe":
            opts.mode = .refined
            if i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                opts.files.append(URL(fileURLWithPath: value("--transcribe")))
            }
        case "--raw":
            opts.mode = .raw
            if i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                opts.files.append(URL(fileURLWithPath: value("--raw")))
            }
        case "--keyword":
            opts.keywords.append(value("--keyword"))
        case "--list-keywords":
            opts.listKeywords = true
        case "--add-keyword":
            opts.addKeyword = value("--add-keyword")
        case "--translate":
            opts.translateTarget = value("--translate")
        case "--refine-stages":
            let raw = value("--refine-stages")
            guard let n = UInt32(raw), n <= 2 else {
                fail("--refine-stages expects 0, 1 or 2, got \"\(raw)\"", code: 1)
            }
            opts.refineStages = n
        case "--tone":
            let raw = value("--tone")
            // Stricter than the core on purpose: the core falls back to
            // "normal" so a settings typo never costs a dictation, but a flag
            // is a request, and a script comparing three registers must not get
            // three copies of "normal".
            guard ["casual", "normal", "formal"].contains(raw) else {
                fail("--tone expects casual, normal or formal, got \"\(raw)\"", code: 1)
            }
            opts.refineTone = raw
        case "--refine":
            opts.refineOnly = true
        case "--llm":
            opts.llmModel = value("--llm")
        case "--worker":
            opts.worker = URL(fileURLWithPath: value("--worker"))
        case "--no-polish":
            opts.polishEnabled = false
        case "--is-edit":
            opts.isEdit = value("--is-edit")
        case "--edit":
            opts.editInstruction = value("--edit")
        case "--region":
            let raw = value("--region")
            guard let region = PromptEditRegion.parse(raw) else {
                fail("--region expects whole, line:N or selection, got \"\(raw)\"", code: 1)
            }
            opts.editRegion = region
        case "--select":
            opts.editSelection = value("--select")
        case "--summarize":
            opts.summarize = true
        case "--paste":
            opts.paste = true
        case "--selftest":
            opts.selftest = true
        default:
            if arg.hasPrefix("--") { fail("unknown option \(arg)", code: 1) }
            opts.files.append(URL(fileURLWithPath: arg))
        }
        i += 1
    }
    return opts
}

// MARK: - Config

/// Builds the run's config from stored keywords plus any `--keyword` values.
func makeConfig(_ opts: Options) -> VoiceInputConfig {
    var keywords = KeywordStore.load()
    for extra in opts.keywords where !keywords.contains(extra) {
        keywords.append(extra)
    }
    return VoiceInputConfig(
        modelsDirectory: opts.modelsDirectory ?? VoiceInputConfig.defaultModelsDirectory(),
        keywords: keywords,
        refineStages: opts.refineStages,
        refineTone: opts.refineTone,
        translateTarget: opts.translateTarget,
        llmModel: opts.llmModel,
        workerExecutable: opts.worker,
        polishEnabled: opts.polishEnabled
    )
}

// MARK: - Selftest

/// A check small enough to run anywhere and complete enough to catch a broken
/// install: it constructs the engine (validates config and that the module
/// links), initialises the core, verifies the ASR model is on disk, and calls
/// the manifest. LLM files are reported but optional —
/// a missing cleanup model degrades to the raw transcript, not a failure.
func runSelfTest(config: VoiceInputConfig) -> Int32 {
    var ok = true
    let fm = FileManager.default

    print("models directory: \(config.modelsDirectory.path)")
    let modelsExists = fm.fileExists(atPath: config.modelsDirectory.path)
    print("  exists: \(modelsExists ? "yes" : "NO")")
    if !modelsExists { ok = false }

    func count(_ sub: String) -> Int {
        let dir = config.modelsDirectory.appendingPathComponent(sub, isDirectory: true)
        return (try? fm.contentsOfDirectory(atPath: dir.path).count) ?? 0
    }

    let asr = count("asr")
    print("  asr files: \(asr)\(asr == 0 ? "  <-- missing" : "")")
    if asr == 0 { ok = false }

    let llm = count("llm")
    print("  llm files: \(llm)\(llm == 0 ? "  (optional; cleanup will fall back)" : "")")


    print("engine:")
    do {
        let engine = try VoiceInputEngine(config: config)
        try engine.prepare()
        print("  core initialize + load ASR: ok")
        engine.shutdown()
    } catch {
        print("  core initialize + load ASR: FAILED — \(error)")
        ok = false
    }

    print(ok ? "PASS" : "FAIL")
    return ok ? 0 : 3
}

// MARK: - Transcribe

/// Runs one file through the engine. Returns the refined text so `--paste` can
/// reuse it, and prints according to the chosen mode.
@discardableResult
func transcribe(_ url: URL, engine: VoiceInputEngine, opts: Options) -> String {
    if opts.mode == .human {
        print("# \(url.lastPathComponent)")
    }
    do {
        let result = try engine.transcribe(fileAt: url) { _, status in
            // Progress is for a human; suppress it when the output is piped.
            if opts.mode == .human {
                FileHandle.standardError.write(Data(("\r  \(status)          ").utf8))
            }
        }
        if opts.mode == .human {
            FileHandle.standardError.write(Data("\r".utf8))
        }
        switch opts.mode {
        case .human:
            print(result.refined)
            print()
        case .refined:
            print(result.refined)
        case .raw:
            print(result.raw)
        }
        if result.segments.isEmpty && result.raw.isEmpty && opts.mode == .human {
            FileHandle.standardError.write(Data("voiceinput: no speech recognised in \(url.lastPathComponent)\n".utf8))
        }
        return result.refined
    } catch {
        fail("\(url.lastPathComponent): \(error)", code: 2)
    }
}

// MARK: - Summarize

/// Summarises the transcript on stdin and prints the meeting sections.
///
/// The meeting path's second step, and the same one the app runs: a finished
/// transcript in, the 摘要／待辦／決議 sections out. It is a SEPARATE step
/// from the cleanup chain on purpose -- the cleanup asks for one tidy line,
/// and a meeting transcript run through it comes back condensed and wrong
/// about what was said.
///
/// The transcript is read whole from stdin, because a meeting transcript is
/// several lines and a draft is one.
///
/// The script is normalised first (the recogniser emits Simplified, and the
/// summary prompt follows the transcript's language), and the answer is
/// normalised again for the same reason -- the model may echo Simplified even
/// when asked not to.
///
/// A failure is reported as a failure, not printed as text: a script must not
/// file an empty summary as if it were one.
func runSummarize(config: VoiceInputConfig) -> Never {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let raw = String(data: data, encoding: .utf8) else {
        fail("the transcript on stdin is not valid UTF-8", code: 1)
    }
    let transcript = VoiceText.toTraditional(
        raw.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !transcript.isEmpty else {
        fail("the transcript on stdin is empty", code: 1)
    }
    let engine = makeEngine(config)
    defer { engine.shutdown() }
    guard let answer = try? engine.summarize(transcript), !answer.isEmpty else {
        fail("could not summarise the transcript (no usable result)", code: 1)
    }
    print(VoiceText.toTraditional(answer))
    exit(0)
}

// MARK: - Refine

/// Cleans the text on stdin and prints the result.
///
/// The same cleanup the app runs, on a known sentence, so the three registers
/// (`--tone`) can be compared without a microphone and without changing a
/// setting back and forth. Deliberately the THROWING path
/// (`VoiceInputEngine.refine`) rather than `refineTranscript`: a failed pass has
/// to be a non-zero exit, not the input printed back as if the model had
/// answered.
///
/// The script is normalised first, exactly as the dictation path does, so a
/// Simplified transcript is compared the way it would be in production.
func runRefine(config: VoiceInputConfig) -> Never {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let raw = String(data: data, encoding: .utf8) else {
        fail("the text on stdin is not valid UTF-8", code: 1)
    }
    let text = VoiceText.toTraditional(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !text.isEmpty else {
        fail("the text on stdin is empty", code: 1)
    }
    let engine = makeEngine(config)
    defer { engine.shutdown() }
    guard let refined = try? engine.refine(text), !refined.isEmpty else {
        fail("could not refine the text (no usable result)", code: 1)
    }
    print(VoiceText.toTraditional(refined))
    exit(0)
}

// MARK: - Engine

/// Builds the engine the way every path needs it: config validated, core
/// initialised, ASR loaded. `prepare()` throws on a real install problem; report
/// it as one line rather than a stack of core chatter.
func makeEngine(_ config: VoiceInputConfig) -> VoiceInputEngine {
    do {
        let engine = try VoiceInputEngine(config: config)
        try engine.prepare()
        return engine
    } catch {
        fail("could not start the engine: \(error)", code: 2)
    }
}

// MARK: - Edit

/// Applies one spoken edit to the text on stdin and prints the result.
///
/// The whole stream is read as UTF-8 rather than one line: the target is a draft,
/// and a draft is allowed to be several lines. `applyVoiceEdit` returns nil when
/// it cannot edit — the worker is missing, or the model answered with nothing
/// usable — and that is reported as a failure rather than printed as text, so a
/// script never pastes an empty line over a good draft.
func runEdit(instruction: String,
             region: PromptEditRegion,
             selection raw: String?,
             config: VoiceInputConfig) -> Never {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let target = String(data: data, encoding: .utf8) else {
        fail("the text on stdin is not valid UTF-8", code: 1)
    }
    // A `selection` region is a range in the text that arrived, so the caller
    // states it as character offsets. Anything else is about the whole draft,
    // and the region only decides WHERE -- never what the instruction says.
    var selection: Range<String.Index>?
    if region == .selection {
        guard let raw,
              case let parts = raw.split(separator: ":"), parts.count == 2,
              let start = Int(parts[0]), let end = Int(parts[1]),
              start >= 0, end > start,
              let lower = target.index(target.startIndex, offsetBy: start, limitedBy: target.endIndex),
              let upper = target.index(target.startIndex, offsetBy: end, limitedBy: target.endIndex)
        else {
            fail("--region selection needs --select A:B (character offsets into stdin)", code: 1)
        }
        selection = lower..<upper
    }
    let engine = makeEngine(config)
    guard let edited = applyVoiceEdit(instruction, to: target,
                                      region: region,
                                      selection: selection,
                                      config: config) else {
        engine.shutdown()
        fail("could not apply the edit (no usable result)", code: 1)
    }
    engine.shutdown()
    print(edited)
    exit(0)
}

// MARK: - Entry point

let opts = parseArguments(Array(CommandLine.arguments.dropFirst()))
let config = makeConfig(opts)

if opts.listKeywords {
    for keyword in KeywordStore.load() {
        print(keyword)
    }
    exit(0)
}

if let add = opts.addKeyword {
    let list = KeywordStore.add(add)
    print(list.joined(separator: "\n"))
    exit(0)
}

if opts.selftest {
    exit(runSelfTest(config: config))
}

// `--is-edit` is a pure classification: no engine, no stdin, just the verdict a
// script branches on.
if let spoken = opts.isEdit {
    print(isVoiceEditInstruction(spoken) ? "yes" : "no")
    exit(0)
}

if let instruction = opts.editInstruction {
    runEdit(instruction: instruction,
            region: opts.editRegion,
            selection: opts.editSelection,
            config: config)
}

if opts.summarize {
    runSummarize(config: config)
}

if opts.refineOnly {
    runRefine(config: config)
}

guard !opts.files.isEmpty else {
    fail("no input file given (try --help)", code: 1)
}

let engine = makeEngine(config)

var lastRefined = ""
for file in opts.files {
    lastRefined = transcribe(file, engine: engine, opts: opts)
}

if opts.paste, !lastRefined.isEmpty {
    if insertAtCursor(lastRefined) {
        FileHandle.standardError.write(Data("voiceinput: pasted at cursor\n".utf8))
    } else {
        FileHandle.standardError.write(Data(
            "voiceinput: could not paste (\(CursorInserter.lastOutcome.rawValue)); text is on the clipboard\n".utf8))
    }
}

engine.shutdown()
exit(0)
