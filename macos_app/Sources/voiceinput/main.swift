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
    var llmModel: String?
    var worker: URL?
    var polishEnabled = true
    /// `--is-edit`: a line to classify, printed as yes/no and nothing else.
    var isEdit: String?
    /// `--edit`: the instruction; the text it applies to arrives on stdin.
    var editInstruction: String?
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
  --llm <file>            bare LLM filename inside models/llm/
  --no-polish             skip the AI cleanup pass entirely
  --is-edit <text>        print yes/no: does this line read as a spoken edit?
  --edit <instruction>    edit the text read from stdin (whole stream) and print it
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

// MARK: - Edit

/// Applies one spoken edit to the text on stdin and prints the result.
///
/// The whole stream is read as UTF-8 rather than one line: the target is a draft,
/// and a draft is allowed to be several lines. `applyVoiceEdit` returns nil when
/// it cannot edit — the worker is missing, or the model answered with nothing
/// usable — and that is reported as a failure rather than printed as text, so a
/// script never pastes an empty line over a good draft.
func runEdit(instruction: String, config: VoiceInputConfig) -> Never {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let target = String(data: data, encoding: .utf8) else {
        fail("the text on stdin is not valid UTF-8", code: 1)
    }
    let engine = makeEngine(config)
    guard let edited = applyVoiceEdit(instruction, to: target, config: config) else {
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
    runEdit(instruction: instruction, config: config)
}

guard !opts.files.isEmpty else {
    fail("no input file given (try --help)", code: 1)
}

// `prepare()` throws on a real install problem; report it as one line rather
// than a stack of core chatter.
func makeEngine(_ config: VoiceInputConfig) -> VoiceInputEngine {
    do {
        let engine = try VoiceInputEngine(config: config)
        try engine.prepare()
        return engine
    } catch {
        fail("could not start the engine: \(error)", code: 2)
    }
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
