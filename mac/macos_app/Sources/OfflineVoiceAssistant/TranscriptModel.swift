import Foundation

/// Where a stretch of speech came from.
///
/// Meeting mode records two audio routes separately — the microphone and the
/// system-audio tap — so this is a fact about the recording route, not a guess
/// about who was talking. There is deliberately no third case: diarization
/// across several remote speakers is out of scope, and inventing "unknown"
/// would only push that guess into the UI.
enum Speaker: String, Codable, Sendable, CaseIterable {
    case me
    case other

    /// Shown in the transcript window, the SRT export and the Markdown export.
    var label: String {
        switch self {
        case .me: return "我"
        case .other: return "對方"
        }
    }
}

/// One utterance: exactly what the ASR returned for one VAD segment.
///
/// `index` is 1-based, assigned once when the segment arrives, and never
/// renumbered while the session lives. Edit instructions address sentences by
/// this number ("把第 3 句改短一點"), so renumbering mid-session would silently
/// point a pending instruction at a different sentence.
struct TranscriptSegment: Identifiable, Codable, Sendable, Equatable {
    var index: Int
    var speaker: Speaker
    /// Seconds from the start of the session.
    var start: TimeInterval
    var end: TimeInterval
    var text: String

    var id: Int { index }

    var duration: TimeInterval { max(0, end - start) }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A complete recording, raw text only.
///
/// This is the source of truth for the transcript window, the speaker-split
/// export and the SRT. The polished summary lives beside it, never replaces it:
/// the user asked to see what they actually said.
struct TranscriptDocument: Codable, Sendable, Equatable {
    var startedAt: Date
    var endedAt: Date
    var segments: [TranscriptSegment]

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    /// Concatenated speech, no speaker labels — what goes to the LLM.
    ///
    /// Joining is language-aware on purpose: Chinese segments must not be
    /// separated by spaces, English ones must. The rule is per boundary, so a
    /// mixed sentence still comes out readable.
    var plainText: String {
        Self.join(segments.map(\.text))
    }

    /// Readable transcript with speaker labels, one paragraph per speaker turn.
    /// Consecutive segments from the same speaker are merged.
    func labelledText() -> String {
        guard !segments.isEmpty else { return "" }
        var lines: [String] = []
        var current: Speaker = segments[0].speaker
        var buffer: [String] = [segments[0].text]
        for segment in segments.dropFirst() {
            if segment.speaker == current {
                buffer.append(segment.text)
            } else {
                lines.append("\(current.label)：\(Self.join(buffer))")
                current = segment.speaker
                buffer = [segment.text]
            }
        }
        lines.append("\(current.label)：\(Self.join(buffer))")
        return lines.joined(separator: "\n")
    }

    /// Numbered lines, for an edit instruction that has to name its sentence.
    func numberedText() -> String {
        segments.map { "\($0.index). \($0.text)" }.joined(separator: "\n")
    }

    static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if out.isEmpty {
                out = piece
            } else if usesCJK(out.last!), usesCJK(piece.first!) {
                out += piece
            } else {
                out += " " + piece
            }
        }
        return out
    }

    static func usesCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }
}
