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

/* ---- LLM (Qwen2.5 via worker process) ---- */
/* Translates text into `target` ("en" or "zh") and writes it to *out_text. */
int32_t LLM_Translate(const char *text, const char *target, char **out_text);

/* ---- LLM: implemented via an out-of-process worker (see state.rs).
 *      RAG: declared for the planned API; currently returns OVC_ERR_NOT_IMPLEMENTED. ---- */
int32_t LLM_Summarize(const char *transcript, char **out_summary);
int32_t LLM_RefineText(const char *text, char **out_text);
int32_t LLM_RefineTextWithKeywords(const char *text, const char *keywords_hint, char **out_text);
int32_t LLM_RefineTextWithKeywordsStages(const char *text, const char *keywords_hint, uint32_t stages, char **out_text);
int32_t RAG_Search(const char *query, char **out_results_json);
int32_t RAG_AddEntry(const char *entry_json);

#ifdef __cplusplus
}
#endif

#endif /* OFFLINE_VOICE_CORE_H */
