/*
 * Thin shim over sherpa-onnx's C API for offline recognition.
 * Using the upstream header keeps struct layouts correct; Rust only sees
 * opaque pointers and plain scalars.
 *
 * Two model families are wired: Dolphin (CTC, 40 languages + 22 Chinese
 * dialects incl. Minnan) and SenseVoice (the previous default, kept as a
 * fallback for installs that predate the switch).
 */
#include <stdlib.h>
#include <string.h>

#include "sherpa-onnx/c-api/c-api.h"

/* kind: OVC_ASR_SENSE_VOICE (0) or OVC_ASR_DOLPHIN (1). */
#define OVC_ASR_SENSE_VOICE 0
#define OVC_ASR_DOLPHIN 1

void *ovc_asr_create(const char *model, const char *tokens, int32_t num_threads, int32_t kind) {
  SherpaOnnxOfflineRecognizerConfig cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.feat_config.sample_rate = 16000;
  cfg.feat_config.feature_dim = 80;
  cfg.model_config.tokens = tokens;
  cfg.model_config.num_threads = num_threads;
  cfg.model_config.provider = "cpu";
  cfg.decoding_method = "greedy_search";

  if (kind == OVC_ASR_DOLPHIN) {
    /* Dolphin carries its language/region tokens in the vocabulary and works
       them out itself, so there is no language hint to set here -- unlike
       SenseVoice's `language` field. */
    cfg.model_config.dolphin.model = model;
    cfg.model_config.model_type = "dolphin";
  } else {
    cfg.model_config.sense_voice.model = model;
    cfg.model_config.sense_voice.language = "auto";
    cfg.model_config.sense_voice.use_itn = 1;
    cfg.model_config.model_type = "sense_voice";
  }

  return (void *)SherpaOnnxCreateOfflineRecognizer(&cfg);
}

/* Returns a malloc'd UTF-8 string (caller frees with free()), or NULL on failure. */
char *ovc_asr_decode(void *rec, const float *samples, int32_t n, int32_t sample_rate) {
  const SherpaOnnxOfflineRecognizer *r = (const SherpaOnnxOfflineRecognizer *)rec;
  const SherpaOnnxOfflineStream *s = SherpaOnnxCreateOfflineStream(r);
  if (!s) return NULL;
  SherpaOnnxAcceptWaveformOffline(s, sample_rate, samples, n);
  SherpaOnnxDecodeOfflineStream(r, s);
  const SherpaOnnxOfflineRecognizerResult *res = SherpaOnnxGetOfflineStreamResult(s);
  char *out = NULL;
  if (res) {
    out = strdup(res->text ? res->text : "");
    SherpaOnnxDestroyOfflineRecognizerResult(res);
  }
  SherpaOnnxDestroyOfflineStream(s);
  return out;
}

void ovc_asr_destroy(void *rec) {
  SherpaOnnxDestroyOfflineRecognizer((const SherpaOnnxOfflineRecognizer *)rec);
}
