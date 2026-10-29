/*
 * offline_voice_core.h — C ABI for the offline AI voice assistant core.
 *
 * Ownership
 *   - Input `const char*` / `const float*` are borrowed for the duration of the call.
 *   - Output `char**` strings are allocated by the core. Free each with Core_FreeString.
 *   - Core_GetLastError returns an owned string (or NULL). Free with Core_FreeString.
 *
 * Threading
 *   - All calls serialize on one internal mutex; they are safe from any thread.
 *   - Last-error text is stored per calling thread.
 *
 * Status codes
 *   - 0 means success; any other value is one of the OvcStatus codes below.
 */
#ifndef OFFLINE_VOICE_CORE_H
#define OFFLINE_VOICE_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum OvcStatus {
  OVC_OK = 0,
  OVC_ERR_INVALID_ARG = 1,
  OVC_ERR_NOT_LOADED = 2,
  OVC_ERR_NOT_IMPLEMENTED = 3,
  OVC_ERR_MODEL_LOAD = 4,
  OVC_ERR_INFERENCE = 5,
  OVC_ERR_INVALID_STATE = 6,
  OVC_ERR_INTERNAL = 7
} OvcStatus;

typedef struct OvcMemoryUsage {
  uint64_t model_bytes;     /* on-disk bytes of loaded model files */
  uint64_t peak_rss_bytes;  /* process peak RSS (not current RSS) */
} OvcMemoryUsage;

/* ---- Core ---- */
int32_t Core_Initialize(const char *models_dir);
int32_t Core_Shutdown(void);
char *Core_GetLastError(void);
void Core_FreeString(char *s);

/* ---- Agent / model management ---- */
/* name: "asr" is implemented; "llm" and "rag" return OVC_ERR_NOT_IMPLEMENTED. */
int32_t Agent_Load(const char *name);
int32_t Agent_Unload(const char *name);
int32_t Memory_Unload(void);
int32_t Memory_GetUsage(OvcMemoryUsage *out);

/* ---- ASR (SenseVoice, 16 kHz mono float32) ---- */
int32_t ASR_Start(void);
int32_t ASR_SubmitAudio(const float *pcm, size_t n, uint32_t sample_rate);
/* Same, but tags the route the audio came from: 0 = microphone, 1 = system
 * audio. Speech from the two routes is segmented separately, which is what lets
 * a meeting transcript attribute each sentence to 我 or 對方 without guessing. */
int32_t ASR_SubmitTagged(const float *pcm, size_t n, uint32_t sample_rate, uint32_t speaker);
/* Committed transcript so far; excludes audio that has not been segmented yet. */
int32_t ASR_GetResult(char **out_text);
/* Live preview of the transcript so far. Consumes nothing and no longer
 * re-decodes anything, so it is cheap enough to poll while recording. */
int32_t ASR_Peek(char **out_text);
/* Decodes remaining audio, ends the session, returns the full transcript. */
int32_t ASR_Stop(char **out_text);
/* Decodes the utterances that closed since the previous call. Writes a JSON
 * array of only the new segments, `[]` when nothing is ready:
 *   [{"index":1,"speaker":0,"start":1.234,"end":2.987,"text":"..."}]
 * `index` is 1-based and stable for the session; times are seconds from the
 * start of the session. Call it from a timer, not from the audio callback:
 * it decodes synchronously, which takes a few hundred milliseconds per
 * utterance. */
int32_t ASR_TakeSegments(char **out_json);

/* ---- LLM: implemented via an out-of-process worker (see state.rs). ---- */
int32_t LLM_Summarize(const char *transcript, char **out_summary);
int32_t LLM_RefineText(const char *text, char **out_text);
int32_t LLM_RefineTextWithKeywords(const char *text, const char *keywords_hint, char **out_text);
int32_t LLM_RefineTextWithKeywordsStages(const char *text, const char *keywords_hint, uint32_t stages, char **out_text);
/* Refine in a chosen register: `tone` is "casual", "normal" or "formal".
 * NULL, empty or anything else means "normal". `stages` is honoured for "normal"
 * only; the other two are single-pass by design (their prompt carries the
 * register, and the two-stage shape's first pass has no notion of it). */
int32_t LLM_RefineTextWithTone(const char *text, const char *keywords_hint, const char *tone, uint32_t stages, char **out_text);
/* Checks a model's answer before the caller treats it as the user's own text.
 * `raw` is what the model was given (the transcript, or the draft for an edit),
 * `refined` its answer; `mode` is "edit" for the spoken-edit path and anything
 * else for the cleanup; `tone` adds the register rule ("casual"/"normal"/"formal",
 * NULL = normal). Writes "" to *out_reason when the answer may be used, or a short
 * reason (for a log, not for the user) when it may not. Pure arithmetic on the
 * core side: no model call, no measurable cost. Free with Core_FreeString. */
int32_t LLM_CheckOutput(const char *raw, const char *refined, const char *mode, const char *tone, char **out_reason);
/* The .gguf that answered the most recent LLM task, or "" when none has run.
 * A downgrade is invisible in the answer -- the core retries with a smaller model
 * and returns its text -- so this is how a caller learns which one actually
 * served the request. Free the result with Core_FreeString. */
int32_t LLM_LastModelName(char **out_name);
/* Translates text into `target` ("en" or "zh") and writes it to *out_text. */
int32_t LLM_Translate(const char *text, const char *target, char **out_text);
/* Applies a spoken edit instruction ("把第二點改成禮拜五") to an existing text and
 * returns the whole edited text. The core numbers the lines itself. */
int32_t LLM_EditText(const char *text, const char *instruction, char **out_text);
/* Loads the LLM now instead of on the next task. Call it when a recording starts:
 * the seconds of loading then happen while the user is still speaking. Idempotent,
 * and a no-op when the model is already resident. On macOS this starts the
 * resident worker; on iOS it loads the model in-process. */
int32_t LLM_Prewarm(void);
/* Drops the loaded model and returns its memory to the OS (iOS background,
 * memory warnings). The next task loads again; nothing is left half-initialised.
 * Always succeeds. */
int32_t LLM_ReleaseModel(void);

#ifdef __cplusplus
}
#endif

#endif /* OFFLINE_VOICE_CORE_H */
