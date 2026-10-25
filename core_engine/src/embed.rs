//! Google EmbeddingGemma 300M (QAT Q4_0, `gemma-embedding`) embeddings, run as a
//! pre-pass before the refinement LLM.
//!
//! Two jobs, both of which shrink what the LLM has to look at:
//!
//!  * **Keyword relevance.** Every term the user keeps is pasted into the refine
//!    system prompt today. Embedding the transcript and the terms and keeping
//!    only the ones that clear a cosine threshold drops the terms the transcript
//!    never touched, so a small model's attention is not spent on them.
//!  * **Spoken-edit screening.** A spoken instruction about the text itself
//!    ("把前面那句刪掉") has to reach the LLM as an explicit instruction rather
//!    than as something the model might notice. Finding those clauses here, with
//!    a cheap rule prefilter plus embeddings, is more reliable than hoping a
//!    1.5B model picks them out of ordinary speech.
//!
//! `screen` does both in ONE model load, on one shared context.
//!
//! Why the three prefixes are named constants: EmbeddingGemma is trained with a
//! task instruction in front of every string, so a query and a document are
//! embedded differently on purpose. Using the wrong prefix does not error -- it
//! silently degrades every similarity -- so they are copied verbatim from the
//! model card and never spelled inline.

use std::collections::{HashMap, HashSet};
use std::num::NonZeroU32;
use std::path::Path;
use std::sync::OnceLock;

use llama_cpp_2::context::params::{LlamaContextParams, LlamaPoolingType};
use llama_cpp_2::context::LlamaContext;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::LlamaModel;

use crate::error::{EngineError, ErrorCode};

type Result<T, E = EngineError> = std::result::Result<T, E>;

/// EmbeddingGemma's trained context is 2048 tokens, and the pooled vector covers
/// exactly the tokens that fit. Sized to the model so a long transcript is
/// embedded from its head instead of failing the dictation; term, exemplar and
/// clause strings are all far shorter than this.
const EMBED_N_CTX: u32 = 2048;

/// A spoken clause to be matched against the user's terms is a QUERY; each term
/// is a DOCUMENT. (Verbatim from the model card.)
const QUERY_PREFIX: &str = "task: search result | query: ";
const DOC_PREFIX: &str = "title: none | text: ";
/// The edit screening runs as classification, which is SYMMETRIC -- the same
/// prefix goes on the clause and on every exemplar. (Verbatim from the model card.)
const CLASSIFY_PREFIX: &str = "task: classification | query: ";

/// A clause is only "edit-shaped" if it is short enough to be one -- a spoken
/// instruction about the text is a handful of characters ("把前面那句刪掉").
/// Longer strings are content, and content is what we must NOT flag.
pub const MAX_CLAUSE_CHARS: usize = 24;

/// Cues that make a short clause *possibly* an instruction. This list is the
/// whole point of the cheap prefilter: it is deliberately tight, because every
/// clause that gets through it is embedded, and precision is the requirement.
/// Ordinary speech should never reach the embedding step at all.
///
/// The Chinese cues are substrings (刪 covers 刪掉/刪除); the English ones are
/// matched case-insensitively against the lowercased clause.
const EDIT_CUES: &[&str] = &[
    // A cue is a NECESSARY condition, not a sufficient one: measured against real
    // dictation, plain speech reaches 0.60-0.65 similarity to an instruction
    // exemplar while a genuine instruction phrased with an unseen word reaches
    // 0.51, so similarity ALONE cannot separate the two classes. The cue keeps
    // ordinary speech away from the threshold; the threshold then only has to
    // separate "cue word used as an instruction" from "cue word used literally"
    // (我不要再等了 vs 第二點不要).
    "刪",
    "去掉",
    "拿掉",
    "不要",
    "不用",
    "改成",
    "改為",
    "換成",
    "換句",
    "加上",
    "補",
    "簡短",
    "短一點",
    "長話短說",
    "翻",
    "開頭",
    "結尾",
    "delete",
    "remove",
    "change",
    "instead",
];

/// Headroom over the caller's retrieval threshold before a clause counts as an
/// instruction.
///
/// Retained from the first cut, when the gate was "retrieval threshold + margin".
/// The measurement showed that coupling was wrong -- the two jobs need different
/// bars (0.38 for terms against 0.72 for instructions) -- so the caller now passes
/// `edit_min_score` explicitly and this is zero. It stays because reading the two
/// numbers side by side is how the next person will see why they diverge.
pub const EDIT_MARGIN: f32 = 0.0;

/// Exemplar instruction phrasings, in Traditional Chinese, covering the shapes
/// a speaker actually uses: delete a named/numbered item, replace a value,
/// rephrase, reorder, shorten, add, translate. Short on purpose -- each one is
/// embedded on every screening pass, and a small, sharp set separates better
/// than a long tail. English instructions are caught by the prefilter, not here.
pub const EDIT_EXEMPLARS: [&str; 21] = [
    "把前面那句刪掉",
    "這句不要",
    "第二點刪掉",
    "後面那半段不用",
    "把地點那句拿掉",
    "這句拿掉",
    "拿掉那句",
    "講短一點",
    "簡單說就好",
    "長話短說",
    "換句話說",
    "時間改成四點",
    "改成下週三",
    "換成禮拜五",
    "順序倒過來",
    "幫我翻成英文",
    "幫我翻成中文",
    "幫我補上日期",
    "加上我的名字",
    "開頭加一句",
    "結尾那句不要",
];

/// One embedded sentence plus the index it came from, so callers can keep pairs
/// together. Public convenience for the wiring; this module never builds one
/// (`select_top` returns bare indices instead), hence the allow.
#[allow(dead_code)]
pub struct Scored {
    pub index: usize,
    pub score: f32,
}

/// What the screening pass found. Both lists may be empty.
pub struct ScreenResult {
    /// Terms from the user's list that are actually relevant to `text`, best first.
    pub ranked_terms: Vec<String>,
    /// Clauses of `text` that read as an instruction about the text itself.
    pub edit_clauses: Vec<String>,
    /// The best edit-similarity seen, for logging and for tuning the threshold.
    pub top_edit_score: f32,
}

// ---- Backend ----------------------------------------------------------------

/// Same shape as `llm::backend`: one process-wide init, its failure remembered
/// so every later call reports the same thing. The duplicate `OnceLock` is
/// deliberate -- the one in `llm` is module-private -- and harmless: statics are
/// never dropped, so `LlamaBackend::init()` runs at most twice and never paired
/// with a free.
static BACKEND: OnceLock<std::result::Result<LlamaBackend, String>> = OnceLock::new();

fn backend() -> Result<&'static LlamaBackend> {
    BACKEND
        .get_or_init(|| LlamaBackend::init().map_err(|e| e.to_string()))
        .as_ref()
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("llama backend init: {e}")))
}

/// Load the embedding model. One call per public entry point, never per string.
fn load_model(model_path: &Path) -> Result<LlamaModel> {
    let be = backend()?;
    LlamaModel::load_from_file(be, model_path, &LlamaModelParams::default())
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("{}: {e}", model_path.display())))
}

/// L2-normalise in place, so `cosine` can be a plain dot product. A zero vector
/// (no tokens pooled) is left alone; `cosine` then reads it as 0.0 rather than
/// dividing by zero.
fn l2_normalize(v: &mut [f32]) {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for x in v.iter_mut() {
            *x /= norm;
        }
    }
}

// ---- One loaded model, one shared context -----------------------------------

/// An embedding session: a borrowed model plus ONE context reused for every
/// string.
///
/// A fresh context per string was the alternative. It is also correct, but each
/// context allocates its own KV cache and `screen` embeds ~15+ strings
/// (transcript, missing terms, exemplars, clauses), so sharing one is the
/// cheaper shape and it is safe as long as every decode starts from a clean
/// sequence -- `embed` clears the cache before each one. That clear is the only
/// thing keeping the pooling from reading the previous string's tokens.
struct Embedder<'m> {
    model: &'m LlamaModel,
    ctx: LlamaContext<'m>,
}

impl<'m> Embedder<'m> {
    fn new(model: &'m LlamaModel) -> Result<Self> {
        let be = backend()?;
        let params = LlamaContextParams::default()
            .with_embeddings(true)
            .with_pooling_type(LlamaPoolingType::Mean)
            .with_n_ctx(NonZeroU32::new(EMBED_N_CTX))
            .with_n_batch(EMBED_N_CTX);
        let ctx = model.new_context(be, params).map_err(|e| {
            EngineError::new(ErrorCode::ModelLoad, format!("llama embedding context: {e}"))
        })?;
        Ok(Self { model, ctx })
    }

    /// Embed one `prefix + text` and return its L2-normalised pooled vector.
    fn embed(&mut self, prefix: &str, text: &str) -> Result<Vec<f32>> {
        let full = format!("{prefix}{text}");
        // add_special = true (BOS) and parse_special = true, matching the LLM
        // path's tokenizer call so the two agree on what a string tokenises to.
        let mut tokens = self.model.vocab().tokenize(full.as_bytes(), true, true);
        if tokens.is_empty() {
            // Not reachable for a non-empty string (BOS is always added), but an
            // empty sequence would have nothing to pool.
            return Err(EngineError::new(ErrorCode::Inference, "embedding: text tokenised to nothing"));
        }
        if tokens.len() > EMBED_N_CTX as usize {
            tokens.truncate(EMBED_N_CTX as usize);
        }

        // Each string must start from a clean sequence: pooling reads seq 0 of
        // the LAST decoded batch, and a leftover KV entry from the previous
        // string would leak into it.
        self.ctx.clear_kv_cache();

        let mut batch = LlamaBatch::new(EMBED_N_CTX as usize, 1);
        for (i, token) in tokens.iter().enumerate() {
            // logits = false: we want the pooled embedding, not per-token logits.
            batch.add(*token, i as i32, &[0], false).map_err(|e| {
                EngineError::new(ErrorCode::Inference, format!("embedding batch add: {e}"))
            })?;
        }
        self.ctx
            .decode(&mut batch)
            .map_err(|e| EngineError::new(ErrorCode::Inference, format!("embedding decode: {e}")))?;

        let mut vec = self
            .ctx
            .embeddings_seq_ith(0)
            .map_err(|e| EngineError::new(ErrorCode::Inference, format!("embedding read: {e}")))?
            .to_vec();
        l2_normalize(&mut vec);
        Ok(vec)
    }

    /// Embed a run of strings with the same prefix. Generic over the element so
    /// both `&[String]` (terms, clauses) and `&[&str]` (the baked-in exemplars)
    /// can be passed without copying.
    fn embed_many<S: AsRef<str>>(&mut self, prefix: &str, texts: &[S]) -> Result<Vec<Vec<f32>>> {
        let mut out = Vec::with_capacity(texts.len());
        for text in texts {
            out.push(self.embed(prefix, text.as_ref())?);
        }
        Ok(out)
    }
}

/// Shared body of `embed_documents` / `embed_queries`.
fn embed_all(model_path: &Path, prefix: &str, texts: &[String]) -> Result<Vec<Vec<f32>>> {
    // No strings means no reason to touch the model at all.
    if texts.is_empty() {
        return Ok(Vec::new());
    }
    let model = load_model(model_path)?;
    let mut embedder = Embedder::new(&model)?;
    embedder.embed_many(prefix, texts)
}

/// L2-normalised embeddings for `texts`, as documents. One model load for the whole batch.
pub fn embed_documents(model_path: &Path, texts: &[String]) -> Result<Vec<Vec<f32>>> {
    embed_all(model_path, DOC_PREFIX, texts)
}

/// L2-normalised embeddings for `texts`, as queries.
pub fn embed_queries(model_path: &Path, texts: &[String]) -> Result<Vec<Vec<f32>>> {
    embed_all(model_path, QUERY_PREFIX, texts)
}

/// Cosine similarity of two already-normalised vectors (a plain dot product,
/// clamped to [-1, 1]).
///
/// A length mismatch returns 0.0 instead of panicking: callers compare vectors
/// from a cache file and from a live model, and "not comparable" must read as
/// "not similar", never as a crash mid-dictation.
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    dot.clamp(-1.0, 1.0)
}

// ---- Pure selection helpers -------------------------------------------------

/// Indices of `scores` at or above `min_score`, best first, at most `k`.
///
/// Ties break by the LOWER index, so the order is deterministic for a given
/// input -- the same term list always ranks the same way, and a test can pin it.
pub fn select_top(scores: &[f32], min_score: f32, k: usize) -> Vec<usize> {
    let mut idx: Vec<usize> = (0..scores.len()).filter(|&i| scores[i] >= min_score).collect();
    idx.sort_by(|&a, &b| {
        scores[b]
            .partial_cmp(&scores[a])
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.cmp(&b))
    });
    idx.truncate(k);
    idx
}

/// Split on the punctuation a spoken clause can end at.
fn split_clauses(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    for (i, c) in text.char_indices() {
        if matches!(
            c,
            '，' | ',' | '。' | '.' | '！' | '!' | '？' | '?' | '；' | ';' | '：' | ':' | '\n'
        ) {
            out.push(&text[start..i]);
            start = i + c.len_utf8();
        }
    }
    out.push(&text[start..]);
    out
}

/// Cheap rule prefilter: the clauses of `text` short enough to be an instruction
/// AND carrying one of `EDIT_CUES`. No embedding happens here -- this exists to
/// keep ordinary speech away from the expensive, similarity-driven step.
///
/// The returned strings are the ORIGINAL clause text (trimmed), not a scored or
/// normalised form, so a survivor can be handed straight to the LLM.
pub fn clause_candidates(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for raw in split_clauses(text) {
        let clause = raw.trim();
        if clause.is_empty() {
            continue;
        }
        // Lowercasing leaves CJK untouched but makes the English cues fire on
        // "Delete"/"Remove" as well as "delete".
        let lowered = clause.to_lowercase();
        // EVERY cue is visited, not just the first one found: a run-on dictation
        // can carry two instructions ("把地點那句拿掉還有時間改成四點"), and stopping
        // at the first cue would silently swallow the second.
        let short = clause.chars().count() <= MAX_CLAUSE_CHARS;
        for cue in EDIT_CUES {
            if !lowered.contains(cue) {
                continue;
            }
            if short {
                push_unique(&mut out, clause.to_string());
                break;
            }
            // A recogniser emits running text with no punctuation at all, so a
            // whole dictation arrives as ONE "clause" that would be discarded for
            // its length -- which is exactly how the first version of this
            // screening silently did nothing in production while looking fine on
            // hand-written tests. Instead, cut a short window around each cue,
            // which is the only part that can be an instruction.
            for window in cue_windows(clause, cue) {
                push_unique(&mut out, window);
            }
        }
    }
    out
}

/// Short slices of a run-on clause, each centred on one occurrence of `cue`.
///
/// Bounded to `MAX_CLAUSE_CHARS` so every candidate is the same kind of object
/// the exemplars are: a phrase, not a paragraph.
fn cue_windows(clause: &str, cue: &str) -> Vec<String> {
    let lowered = clause.to_lowercase();
    let chars: Vec<char> = clause.chars().collect();
    // `to_lowercase` can change byte length (not char count), so locate cues on a
    // char vector of the lowered form and map back by character index.
    let lowered_chars: Vec<char> = lowered.chars().collect();
    let cue_chars: Vec<char> = cue.chars().collect();
    let mut out = Vec::new();
    if cue_chars.is_empty() || lowered_chars.len() != chars.len() {
        return out;
    }
    let before = 8usize;
    let mut i = 0usize;
    while i + cue_chars.len() <= lowered_chars.len() {
        if lowered_chars[i..i + cue_chars.len()] == cue_chars[..] {
            let start = i.saturating_sub(before);
            let end = (i + cue_chars.len() + 10).min(chars.len());
            let window: String = chars[start..end].iter().collect();
            let trimmed = window.trim();
            if !trimmed.is_empty() {
                out.push(trimmed.chars().take(MAX_CLAUSE_CHARS).collect());
            }
            i += cue_chars.len();
        } else {
            i += 1;
        }
    }
    out
}

fn push_unique(out: &mut Vec<String>, candidate: String) {
    if !out.contains(&candidate) {
        out.push(candidate);
    }
}

/// Embed the exemplar set (and optionally the caller's terms) and write the
/// cache, without screening anything.
///
/// The first dictation after an install otherwise pays for every exemplar: ~20
/// short embeddings is seconds of CPU, and it lands on the one call the user is
/// waiting for. Warming it off the dictation path moves that cost to startup.
/// A no-op when the cache already covers everything.
pub fn warm(model_path: &Path, cache_path: Option<&Path>, terms: &[String]) -> Result<usize> {
    let model = load_model(model_path)?;
    let mut embedder = Embedder::new(&model)?;
    // Any short string gives the model's real output width, and the exemplars are
    // what we are about to embed anyway.
    let dim = embedder.embed(CLASSIFY_PREFIX, EDIT_EXEMPLARS[0])?.len();
    let model_name = model_file_name(model_path);

    let mut store: HashMap<String, Vec<f32>> = HashMap::new();
    if let Some(path) = cache_path {
        for (key, vector) in load_cached_terms(path, &model_name, dim) {
            store.entry(key).or_insert(vector);
        }
    }

    // Two TODO lists, because the two jobs are embedded under different prefixes
    // and the cache keeps them in separate namespaces. Keeping the plain text here
    // (rather than the cache key) is what stops a namespaced string from being
    // embedded as if it were the phrase.
    let mut exemplars_todo: Vec<String> = Vec::new();
    for exemplar in EDIT_EXEMPLARS {
        if !store.contains_key(&exemplar_key(exemplar)) {
            exemplars_todo.push(exemplar.to_string());
        }
    }
    let mut terms_todo: Vec<String> = Vec::new();
    for term in terms {
        if !store.contains_key(term.as_str()) && !terms_todo.contains(term) {
            terms_todo.push(term.clone());
        }
    }

    let mut computed = 0usize;
    if !exemplars_todo.is_empty() {
        let vectors = embedder.embed_many(CLASSIFY_PREFIX, &exemplars_todo)?;
        computed += exemplars_todo.len();
        for (exemplar, vector) in exemplars_todo.iter().zip(vectors) {
            store.insert(exemplar_key(exemplar), vector);
        }
    }
    if !terms_todo.is_empty() {
        let vectors = embedder.embed_many(DOC_PREFIX, &terms_todo)?;
        computed += terms_todo.len();
        for (term, vector) in terms_todo.iter().zip(vectors) {
            store.insert(term.clone(), vector);
        }
    }

    if let Some(path) = cache_path {
        let mut keys: Vec<String> = Vec::new();
        let mut vectors: Vec<Vec<f32>> = Vec::new();
        // Only the terms passed in are kept, so a keyword the user removed falls
        // out of the cache on the next warm-up.
        for key in EDIT_EXEMPLARS
            .iter()
            .map(|e| exemplar_key(e))
            .chain(terms.iter().cloned())
        {
            if keys.contains(&key) {
                continue;
            }
            if let Some(vector) = store.get(key.as_str()) {
                keys.push(key);
                vectors.push(vector.clone());
            }
        }
        store_cached_terms(path, &model_name, dim, &keys, &vectors);
    }
    Ok(computed)
}

// ---- Term-vector cache ------------------------------------------------------

/// First line of the cache file. The `1` is the format version; the model file
/// name and the vector width follow. A file whose header does not name the model
/// being used (or its width) is ignored and rebuilt rather than trusted.
const CACHE_MAGIC: &str = "# ovc-embed 1";

/// Cache key for an exemplar phrase.
///
/// The cache is keyed by text, but an exemplar is embedded with the
/// classification prefix while a term is embedded with the document prefix, so
/// the same string would need two different vectors. A leading unit separator
/// keeps the two namespaces apart -- and cannot appear in a term, which is why it
/// is used here rather than a printable marker.
fn exemplar_key(exemplar: &str) -> String {
    format!("\u{1}{exemplar}")
}

fn cache_header(model_name: &str, dim: usize) -> String {
    format!("{CACHE_MAGIC} {model_name} {dim}")
}

/// A parsed cache file. `model_name` and `dim` are the identity of the vectors,
/// so a file written by a different model (or a different quantisation of it) is
/// recognised as foreign instead of being mixed in.
struct CacheFile {
    model_name: String,
    dim: usize,
    entries: Vec<(String, Vec<f32>)>,
}

/// Parse a cache file. `None` means "this is not a cache we can use", which the
/// callers treat as an empty cache: every failure is a rebuild, never a miss.
fn parse_cache(text: &str) -> Option<CacheFile> {
    let mut lines = text.lines();
    let header = lines.next()?;
    let rest = header.strip_prefix(CACHE_MAGIC)?;
    // `rsplit_once` so a model file name containing spaces still parses: the
    // width is the only field that may not contain one.
    let (model_name, dim) = rest.trim().rsplit_once(' ')?;
    let dim: usize = dim.parse().ok()?;
    if dim == 0 {
        return None;
    }
    let model_name = model_name.trim().to_string();
    if model_name.is_empty() {
        return None;
    }
    let mut entries = Vec::new();
    for line in lines {
        if line.trim().is_empty() {
            continue;
        }
        // A malformed entry is dropped, not fatal: the rest of the file is still
        // a valid cache, and the missing vector is simply recomputed.
        let Some((key, values)) = line.split_once('\t') else { continue };
        let Some(vector) = parse_vector(values) else { continue };
        if key.is_empty() || vector.len() != dim {
            continue;
        }
        entries.push((key.to_string(), vector));
    }
    Some(CacheFile { model_name, dim, entries })
}

fn parse_vector(s: &str) -> Option<Vec<f32>> {
    let mut out = Vec::new();
    for part in s.split(',') {
        out.push(part.trim().parse::<f32>().ok()?);
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// Render the cache file. A term that cannot survive one line is skipped rather
/// than escaped: it could never be found again by its own text.
fn format_cache(model_name: &str, dim: usize, terms: &[String], vectors: &[Vec<f32>]) -> String {
    let mut out = cache_header(model_name, dim);
    out.push('\n');
    for (term, vector) in terms.iter().zip(vectors.iter()) {
        if term.is_empty()
            || term.contains('\t')
            || term.contains('\n')
            || term.contains('\r')
            || vector.len() != dim
        {
            continue;
        }
        out.push_str(term);
        out.push('\t');
        let joined: Vec<String> = vector.iter().map(|v| v.to_string()).collect();
        out.push_str(&joined.join(","));
        out.push('\n');
    }
    out
}

/// The bare file name of a model, which is what the cache header records: the
/// path may move between installs, the file's identity does not.
fn model_file_name(model_path: &Path) -> String {
    model_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default()
}

/// Vectors from the cache that belong to this model and this width. Anything else
/// (a foreign model, a malformed file, a missing file) yields an empty list.
fn load_cached_terms(path: &Path, model_name: &str, dim: usize) -> Vec<(String, Vec<f32>)> {
    let Ok(text) = std::fs::read_to_string(path) else { return Vec::new() };
    let Some(parsed) = parse_cache(&text) else { return Vec::new() };
    if parsed.model_name != model_name || parsed.dim != dim {
        return Vec::new();
    }
    parsed.entries
}

/// Write the cache. A failure is reported on stderr and otherwise ignored: the
/// cache only ever saves work, so losing it must not fail a dictation.
fn store_cached_terms(
    path: &Path,
    model_name: &str,
    dim: usize,
    terms: &[String],
    vectors: &[Vec<f32>],
) {
    // The cache lives in a dot-directory beside the models, which nothing else
    // creates; a missing parent must not turn into a failed write on the first
    // dictation after install.
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let text = format_cache(model_name, dim, terms, vectors);
    if let Err(e) = std::fs::write(path, text) {
        eprintln!("ovc-embed: cache write {}: {e}", path.display());
    }
}

// ---- The whole screening pass ----------------------------------------------

/// The whole screening pass in ONE model load: rank `terms` against `text`, and
/// find the clauses of `text` that look like edit instructions.
///
/// Three separate policies are the caller's, never defaulted here: how many terms
/// may survive (`top_k`), how similar a term must be to count as mentioned
/// (`min_score`), and how similar a clause must be to an instruction exemplar
/// before it is named as one (`edit_min_score`). The last two sit more than a
/// factor of two apart, and the measurement behind that gap is in `crate::state`.
pub fn screen(
    model_path: &Path,
    cache_path: Option<&Path>,
    terms: &[String],
    text: &str,
    top_k: usize,
    min_score: f32,
    edit_min_score: f32,
) -> Result<ScreenResult> {
    // The rule prefilter runs first and for free, so this early return costs
    // nothing when there is nothing to screen.
    let clauses = clause_candidates(text);
    // Which candidates are whole clauses rather than windows cut out of a run-on
    // dictation. Only the whole ones are safe to quote back to the model: a window
    // starts and ends mid-phrase ("季時程把地點那句拿掉我還沒確定另外稿我會"), and
    // measured, the model cannot match such a fragment to the transcript and keeps
    // it as content instead of obeying it. A window still counts towards the
    // detection score -- it is evidence that SOMETHING was asked for -- it is just
    // never quoted.
    let whole_clauses: HashSet<String> = split_clauses(text)
        .iter()
        .map(|c| c.trim().to_string())
        .filter(|c| !c.is_empty() && c.chars().count() <= MAX_CLAUSE_CHARS)
        .collect();
    if terms.is_empty() && clauses.is_empty() {
        return Ok(ScreenResult {
            ranked_terms: Vec::new(),
            edit_clauses: Vec::new(),
            top_edit_score: 0.0,
        });
    }

    let model = load_model(model_path)?;
    let mut embedder = Embedder::new(&model)?;
    let model_name = model_file_name(model_path);

    // The transcript is embedded as the query for the term ranking, and its width
    // is also the model's real output width -- which is what the cache header is
    // validated against, so nothing is guessed from model metadata.
    //
    // It is embedded even when there are no terms, because the exemplar vectors
    // are cached and a cache can only be validated with a known width.
    let query = embedder.embed(QUERY_PREFIX, text)?;
    let dim = query.len();

    // One cache read serves both jobs: the user's terms and the baked-in exemplar
    // set are both fixed strings that change only when the keywords are edited or
    // the code is rebuilt. Without this the exemplars alone cost ~20 embeddings on
    // every dictation.
    let mut store: HashMap<String, Vec<f32>> = HashMap::new();
    let mut cached_keys: HashSet<String> = HashSet::new();
    if let Some(path) = cache_path {
        for (key, vector) in load_cached_terms(path, &model_name, dim) {
            cached_keys.insert(key.clone());
            store.entry(key).or_insert(vector);
        }
    }

    // ---- Keyword relevance --------------------------------------------------
    let mut ranked_terms = Vec::new();
    let mut embedded_terms: Vec<String> = Vec::new();
    if !terms.is_empty() {
        let mut to_embed: Vec<String> = Vec::new();
        let mut queued: HashSet<&str> = HashSet::new();
        for term in terms {
            if store.contains_key(term.as_str()) || !queued.insert(term.as_str()) {
                continue;
            }
            to_embed.push(term.clone());
        }
        let fresh: Vec<Vec<f32>> = embedder.embed_many(DOC_PREFIX, &to_embed)?;
        for (term, vector) in to_embed.iter().zip(fresh) {
            store.insert(term.clone(), vector);
        }
        embedded_terms = to_embed;

        let scores: Vec<f32> = terms
            .iter()
            .map(|term| match store.get(term.as_str()) {
                Some(vector) if !vector.is_empty() => cosine(&query, vector),
                _ => f32::NEG_INFINITY,
            })
            .collect();
        ranked_terms =
            select_top(&scores, min_score, top_k).into_iter().map(|i| terms[i].clone()).collect();
    }

    // ---- Spoken-edit screening ---------------------------------------------
    let mut edit_clauses = Vec::new();
    let mut top_edit_score = 0.0f32;
    let mut embedded_exemplars: Vec<String> = Vec::new();
    if !clauses.is_empty() {
        // Same prefix on both sides: classification is symmetric.
        let missing: Vec<String> = EDIT_EXEMPLARS
            .iter()
            .filter(|e| !store.contains_key(&exemplar_key(e)))
            .map(|e| e.to_string())
            .collect();
        let fresh = embedder.embed_many(CLASSIFY_PREFIX, &missing)?;
        for (exemplar, vector) in missing.iter().zip(fresh) {
            store.insert(exemplar_key(exemplar), vector);
        }
        embedded_exemplars = missing;

        let vectors: Vec<&Vec<f32>> = EDIT_EXEMPLARS
            .iter()
            .filter_map(|e| store.get(&exemplar_key(e)))
            .collect();
        let candidates = embedder.embed_many(CLASSIFY_PREFIX, &clauses)?;

        let mut best_overall = f32::NEG_INFINITY;
        for (clause, vector) in clauses.iter().zip(candidates.iter()) {
            // A clause is an instruction if it is close to ANY one shape of an
            // instruction -- they are alternatives, not one prototype.
            let best = vectors.iter().map(|e| cosine(vector, e)).fold(f32::NEG_INFINITY, f32::max);
            best_overall = best_overall.max(best);
            if best >= edit_min_score && whole_clauses.contains(clause) {
                edit_clauses.push(clause.clone());
            }
        }
        // Recorded whatever the verdict, so the caller can log it and tune the
        // threshold against real dictations.
        top_edit_score = best_overall;
    }

    // ---- Cache write-back ---------------------------------------------------
    // Only when something was actually added or the key set changed. An unchanged
    // pass leaves the file alone, so a dictation does not write to disk.
    if let Some(path) = cache_path {
        let mut write_keys: Vec<String> = Vec::new();
        let mut write_vectors: Vec<Vec<f32>> = Vec::new();
        let mut seen: HashSet<String> = HashSet::new();
        for term in terms {
            if !seen.insert(term.clone()) {
                continue;
            }
            if let Some(vector) = store.get(term.as_str()) {
                write_keys.push(term.clone());
                write_vectors.push(vector.clone());
            }
        }
        // The exemplars ride along in the same file, namespaced; they are a
        // fixed, small set.
        for exemplar in EDIT_EXEMPLARS {
            let key = exemplar_key(exemplar);
            if !seen.insert(key.clone()) {
                continue;
            }
            if let Some(vector) = store.get(&key) {
                write_keys.push(key);
                write_vectors.push(vector.clone());
            }
        }
        let dropped = cached_keys.len() != write_keys.len()
            || write_keys.iter().any(|k| !cached_keys.contains(k));
        if !embedded_terms.is_empty() || !embedded_exemplars.is_empty() || dropped {
            store_cached_terms(path, &model_name, dim, &write_keys, &write_vectors);
        }
    }

    Ok(ScreenResult { ranked_terms, edit_clauses, top_edit_score })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-6
    }

    #[test]
    fn cosine_of_identical_vectors_is_one() {
        assert!(approx(cosine(&[0.6, 0.8], &[0.6, 0.8]), 1.0));
    }

    #[test]
    fn cosine_of_orthogonal_vectors_is_zero() {
        assert!(approx(cosine(&[1.0, 0.0], &[0.0, 1.0]), 0.0));
    }

    #[test]
    fn cosine_of_opposite_vectors_is_minus_one() {
        assert!(approx(cosine(&[1.0, 0.0], &[-1.0, 0.0]), -1.0));
    }

    #[test]
    fn cosine_is_clamped_and_never_panics_on_a_length_mismatch() {
        // Callers assume normalised input; an unnormalised pair must still land
        // inside [-1, 1] rather than returning 2.0.
        assert!(approx(cosine(&[1.0, 1.0], &[1.0, 1.0]), 1.0));
        // A cached vector of another width is "not comparable", not a crash.
        assert!(approx(cosine(&[1.0, 0.0], &[1.0]), 0.0));
        assert!(approx(cosine(&[], &[1.0]), 0.0));
    }

    #[test]
    fn select_top_filters_orders_caps_and_breaks_ties_by_lower_index() {
        let scores = [0.9, 0.2, 0.9, 0.5, 0.95];
        // Best first; the two 0.9s keep their original order.
        assert_eq!(select_top(&scores, 0.0, 5), vec![4, 0, 2, 3, 1]);
        // Below-threshold entries are dropped.
        assert_eq!(select_top(&scores, 0.6, 10), vec![4, 0, 2]);
        // The k cap applies AFTER ordering.
        assert_eq!(select_top(&scores, 0.0, 2), vec![4, 0]);
        // k = 0 and an impossible threshold both mean "nothing".
        assert!(select_top(&scores, 0.0, 0).is_empty());
        assert!(select_top(&scores, 2.0, 5).is_empty());
        // A score exactly at the threshold is kept.
        assert_eq!(select_top(&[0.5], 0.5, 1), vec![0]);
    }

    #[test]
    fn clause_candidates_keep_a_short_delete_instruction() {
        let text = "下週三下午三點開會，地點在二樓會議室，把地點那句刪掉，我還沒確定";
        assert_eq!(clause_candidates(text), vec!["把地點那句刪掉".to_string()]);
    }

    #[test]
    fn clause_candidates_ignore_ordinary_speech() {
        // 開會 contains none of the cues, so nothing reaches the embedding step.
        assert!(clause_candidates("我今天要去開會").is_empty());
        assert!(clause_candidates("我們下午三點討論預算，記得帶筆電").is_empty());
    }

    /// A clause at or under the limit is passed through whole.
    #[test]
    fn clause_candidates_pass_a_short_clause_through_unchanged() {
        let kept = format!("{}刪", "字".repeat(MAX_CLAUSE_CHARS - 1));
        assert_eq!(kept.chars().count(), MAX_CLAUSE_CHARS);
        assert_eq!(clause_candidates(&kept), vec![kept.clone()]);
    }

    /// A recogniser writes running text with no punctuation, so a whole dictation
    /// arrives as one "clause". The first version of this screening dropped it for
    /// its length and therefore did nothing at all in production while passing
    /// hand-written tests; a window around the cue is the fix, and this test is the
    /// one that would have caught it.
    #[test]
    fn a_run_on_dictation_yields_a_window_around_the_cue() {
        let run_on = "呃就是明天下午三點要跟小林開會討論第四季時程把地點那句拿掉我還沒確定另外稿我會先更新";
        assert!(run_on.chars().count() > MAX_CLAUSE_CHARS);
        let found = clause_candidates(run_on);
        assert_eq!(found.len(), 1, "one cue, one window");
        let window = &found[0];
        assert!(window.contains("拿掉"), "the window must carry the cue: {window}");
        assert!(window.chars().count() <= MAX_CLAUSE_CHARS, "windows stay phrase-sized: {window}");
        assert!(window.contains("地點"), "and enough context to be readable: {window}");
    }

    #[test]
    fn clause_candidates_match_english_cues_case_insensitively() {
        assert_eq!(clause_candidates("please Delete that"), vec!["please Delete that".to_string()]);
        // A long English clause gets the same window treatment as a Chinese one.
        let long = "we should probably remove it from the list before the meeting because it is stale";
        let found = clause_candidates(long);
        assert_eq!(found.len(), 1);
        assert!(found[0].contains("remove"));
        assert!(found[0].chars().count() <= MAX_CLAUSE_CHARS);
    }

    /// Two cues in one run-on clause are two candidates: they are different
    /// instructions and each has to be judged on its own.
    #[test]
    fn two_cues_in_one_clause_become_two_windows() {
        let run_on = "明天開會的時候把地點那句拿掉還有時間改成四點我已經跟對方確認過了";
        let found = clause_candidates(run_on);
        assert_eq!(found.len(), 2, "{found:?}");
        assert!(found.iter().any(|w| w.contains("拿掉")));
        assert!(found.iter().any(|w| w.contains("改成")));
    }

    #[test]
    fn cache_header_round_trips_through_parse() {
        let header = cache_header("gemma-embedding-300m-q4_0.gguf", 768);
        assert_eq!(header, "# ovc-embed 1 gemma-embedding-300m-q4_0.gguf 768");
        let parsed = parse_cache(&header).expect("a bare header must parse");
        assert_eq!(parsed.model_name, "gemma-embedding-300m-q4_0.gguf");
        assert_eq!(parsed.dim, 768);
        assert!(parsed.entries.is_empty());
    }

    #[test]
    fn cache_round_trips_terms_and_vectors() {
        let terms = vec!["EmbeddingGemma".to_string(), "玉山金控".to_string()];
        let vectors = vec![vec![0.5f32, -0.25, 0.125], vec![1.0f32, 0.0, 0.5]];
        let text = format_cache("model.gguf", 3, &terms, &vectors);

        let parsed = parse_cache(&text).expect("a written cache must parse");
        assert_eq!(parsed.model_name, "model.gguf");
        assert_eq!(parsed.dim, 3);
        assert_eq!(parsed.entries.len(), 2);
        assert_eq!(parsed.entries[0].0, "EmbeddingGemma");
        assert_eq!(parsed.entries[0].1, vec![0.5f32, -0.25, 0.125]);
        assert_eq!(parsed.entries[1].0, "玉山金控");
        assert_eq!(parsed.entries[1].1, vec![1.0f32, 0.0, 0.5]);
    }

    #[test]
    fn cache_write_skips_terms_that_cannot_be_one_line() {
        let terms =
            vec!["good".to_string(), "bad\tterm".to_string(), "bad\nterm".to_string()];
        let vectors = vec![vec![1.0f32], vec![2.0f32], vec![3.0f32]];
        let text = format_cache("m.gguf", 1, &terms, &vectors);

        let parsed = parse_cache(&text).expect("the header survives a skipped term");
        assert_eq!(parsed.entries.len(), 1);
        assert_eq!(parsed.entries[0].0, "good");
    }

    #[test]
    fn parse_cache_rejects_a_foreign_or_malformed_header() {
        assert!(parse_cache("").is_none());
        assert!(parse_cache("just some text\n").is_none());
        // A different format version is not ours.
        assert!(parse_cache("# ovc-embed 2 m.gguf 3\n").is_none());
        // A header without a width is malformed.
        assert!(parse_cache("# ovc-embed 1 m.gguf\n").is_none());
        // Width zero is not a real model.
        assert!(parse_cache("# ovc-embed 1 m.gguf 0\n").is_none());
    }

    #[test]
    fn parse_cache_drops_entries_whose_width_disagrees_with_the_header() {
        let text = "# ovc-embed 1 m.gguf 3\nterm\t1,2\nother\t1,2,3\n";
        let parsed = parse_cache(text).expect("the header is fine");
        assert_eq!(parsed.entries.len(), 1);
        assert_eq!(parsed.entries[0].0, "other");
    }
}
