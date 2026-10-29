import UniformTypeIdentifiers

/// What the document picker offers when the user imports a recording.
///
/// The Mac drags a file onto its window and the same reader takes whatever
/// AVFoundation can open; a phone needs the picker told, and a picker that only
/// offers `.wav` would look broken to anyone whose recorder writes `.m4a` — which
/// is every voice memo app on iOS.
enum AudioImport {
    static var allowed: [UTType] {
        [.audio, .mpeg4Audio, .wav, .aiff, .mp3]
    }
}
