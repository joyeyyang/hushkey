import Foundation

/// The terms from `config.keywords` that the retrieval (embedding) model
/// considers relevant to `text`, best first.
///
/// Empty when the model is absent — callers must treat the embedding step as
/// optional, and the cleanup pass falls back to the full keyword list.
///
/// ## Why this is a rule prefilter and not a cosine ranking (yet)
///
/// The intended retrieval pass is the engine's EmbeddingGemma screen
/// (`core_engine/src/embed.rs`, `embed::screen`), which embeds the transcript as
/// a query and every term as a document, then keeps the terms above a cosine
/// threshold. **That pass is not reachable from Swift today:** `embed` is not
/// declared in `core_engine/src/lib.rs`, and `offline_voice_core.h` has no
/// `Embed_*` / `Screen_*` symbol — the only RAG entry points there
/// (`RAG_Search`, `RAG_AddEntry`) are documented as `OVC_ERR_NOT_IMPLEMENTED`.
/// Inventing a symbol that the dylib does not export would fail at link time, so
/// this function deliberately does only what the ABI can back up:
///
///  * it confirms the embedding model file is present, and returns `[]` when it
///    is not (the documented "model absent" case), and
///  * when it IS present, it applies the same cheap lexical prefilter that
///    `embed.rs` uses to shrink the candidate set before it embeds anything —
///    so a caller that installs the model still gets a narrowed list rather than
///    the whole vocabulary.
///
/// The moment the ABI grows a screen call, this is the one function to rewrite;
/// nothing else in the kit depends on how the filter is computed.
public func relevantTerms(for text: String, in config: VoiceInputConfig) throws -> [String] {
    let keywords = config.keywords
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !keywords.isEmpty else { return [] }

    // Model absent -> the embedding step is optional. Saying "nothing to filter
    // with" makes the caller keep every term, exactly as before.
    guard FileManager.default.fileExists(atPath: config.embeddingModelURL.path) else {
        return []
    }

    // The engine owns the model, the prompt prefixes, the cosine floor and the
    // term-vector cache; this call is the whole interface to it. It returns nil
    // when the engine faulted, which is also "keep everything" -- a screening
    // failure must never cost the user a term.
    return (try? CoreABI.relevantTerms(text, terms: keywords)) ?? []
}

/// Clauses of `text` that the engine reads as an instruction about the text
/// itself ("把前面那句刪掉"), in the order they appear.
///
/// Same contract as `relevantTerms(for:in:)`: empty when the model is absent or
/// when nothing qualified. The caller may pass these to the model as the
/// instruction it should obey and then remove.
public func editInstructions(in text: String, config: VoiceInputConfig) -> [String] {
    guard FileManager.default.fileExists(atPath: config.embeddingModelURL.path) else {
        return []
    }
    return (try? CoreABI.editClauses(text)) ?? []
}
