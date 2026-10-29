/*
 * offline_voice_core.h — platform-side configuration for the offline core.
 *
 * This header is NOT a second copy of the ABI. The entry points live in
 * `rust/core_engine/include/offline_voice_core.h`; what is here is the shape a
 * platform layer (Swift, Kotlin, C++) fills in around them: how it captures
 * audio, where the models are, and what it gets back. Keeping the two files
 * apart is deliberate -- the ABI is implemented and tested, these structs are
 * the contract the platform layer is written against, and folding them into the
 * ABI header would make a design note look like an implemented call.
 *
 * Ownership: every `char *` in these structs is owned by the core and freed
 * with `Core_FreeString`, the same rule as the ABI header's outputs. A platform
 * layer never frees or keeps them past the call that produced them.
 *
 * Status: 0 means success; anything else is an `OvcStatus` value from the ABI
 * header (`OVC_ERR_INVALID_ARG`, `OVC_ERR_MODEL_LOAD`, ...). It is spelled as
 * `int32_t` here so this header stays includable without the ABI header.
 */
#ifndef OVC_PLATFORM_INTERFACES_H
#define OVC_PLATFORM_INTERFACES_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* How a platform captures audio before handing it to `ASR_SubmitAudio`.
 *
 * The recogniser is 16 kHz mono float32, and a platform that records at 48 kHz
 * stereo must convert before the call -- the core does not resample. The chunk
 * size is the platform's own; 100 ms is what the iOS and macOS recorders use,
 * because a longer chunk makes the live preview lag and a shorter one spends
 * the time in call overhead. `vad_aggressiveness` is platform-side (0 = off):
 * the core segments speech itself, so this only decides how much silence the
 * platform bothers to send. */
typedef struct OVCAudioConfig {
  uint32_t sample_rate;        /* 16000; the only rate the recogniser accepts */
  uint32_t channels;           /* 1 = mono; the platform downmixes */
  uint32_t frames_per_chunk;   /* 1600 = 100 ms at 16 kHz */
  uint32_t vad_aggressiveness; /* 0..3, 0 = platform VAD off */
} OVCAudioConfig;

/* Where the models are and how much machine to give them.
 *
 * `models_root` is the directory handed to `Core_Initialize`, borrowed for the
 * duration of the call. `gpu_layers` is the macOS default of 99 (every layer on
 * Metal) and 0 on a device that has no GPU path; the core clamps it to the
 * model's layer count. Zero for `context_size` or `threads` means "the core's
 * default", which is what every caller passes today. */
typedef struct OVCModelConfig {
  const char *models_root;
  int32_t gpu_layers;
  uint32_t context_size;
  uint32_t threads;
} OVCModelConfig;

/* What one call produced: a status, the text, and (on failure) why.
 *
 * `text` and `detail` are exclusive in practice -- a successful call fills
 * `text`, a failed one fills `detail` -- but both may be NULL, which is what a
 * cancelled call returns. The reason string is for a log, not for the user: the
 * product's fallback is the raw transcript, and "only kept 12% of the words
 * used" is not something to show a person. */
typedef struct OVCResult {
  int32_t status;
  char *text;
  char *detail;
} OVCResult;

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OVC_PLATFORM_INTERFACES_H */
