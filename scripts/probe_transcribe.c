/*
 * End-to-end transcription through the shipped core dylib, over a WAV file.
 *
 * asr_probe (Rust) only reports which model file the engine opened. This drives
 * the exact C ABI sequence main.swift drives -- Core_Initialize, ASR_Start,
 * ASR_SubmitAudio, ASR_Stop -- against target/release/liboffline_voice_core.dylib,
 * so "Dolphin is installed" becomes "the app's engine transcribes with Dolphin".
 *
 * build: clang -O2 probe_transcribe.c -o probe_transcribe \
 *          -L target/release -loffline_voice_core \
 *          -Wl,-rpath,<abs path>/target/release
 * run:   DYLD_LIBRARY_PATH=target/release ./probe_transcribe clip.wav <models-dir>
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern int Core_Initialize(const char *models_dir);
extern int Agent_Load(const char *name);
extern int ASR_Start(void);
extern int ASR_SubmitAudio(const float *pcm, size_t n, uint32_t sample_rate);
extern int ASR_Stop(char **out);
extern void Core_FreeString(char *s);
extern char *Core_GetLastError(void);

typedef struct {
  uint64_t model_bytes;
  uint64_t peak_rss_bytes;
  uint64_t baseline_rss_bytes;
} Usage;
extern int Memory_GetUsage(Usage *out);

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static uint32_t rd32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

/* Mono PCM16 / float32 only: the probe clips are 16 kHz mono, and silently
   resampling something else would invalidate the RTF it prints. */
static float *read_wav(const char *path, int32_t *out_n, uint32_t *out_rate) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *buf = malloc((size_t)size);
  if (!buf || fread(buf, 1, (size_t)size, f) != (size_t)size) {
    fclose(f);
    free(buf);
    return NULL;
  }
  fclose(f);

  if (size < 44 || memcmp(buf, "RIFF", 4) || memcmp(buf + 8, "WAVE", 4)) {
    free(buf);
    return NULL;
  }
  int channels = 0, bits = 0, is_float = 0;
  uint32_t rate = 0;
  const unsigned char *data = NULL;
  size_t data_len = 0;
  size_t pos = 12;
  while (pos + 8 <= (size_t)size) {
    uint32_t len = rd32(buf + pos + 4);
    const unsigned char *body = buf + pos + 8;
    if (!memcmp(buf + pos, "fmt ", 4) && len >= 16) {
      uint16_t tag = rd16(body);
      channels = rd16(body + 2);
      rate = rd32(body + 4);
      bits = rd16(body + 14);
      is_float = tag == 3;
    } else if (!memcmp(buf + pos, "data", 4)) {
      data = body;
      data_len = len;
    }
    pos += 8 + len + (len & 1);
  }
  if (!data || !channels || !rate) {
    free(buf);
    return NULL;
  }

  int32_t frames;
  float *out;
  if (is_float && bits == 32) {
    frames = (int32_t)(data_len / 4);
    out = (float *)data;
  } else if (!is_float && bits == 16) {
    frames = (int32_t)(data_len / 2);
    out = malloc((size_t)frames * sizeof(float));
    const int16_t *src = (const int16_t *)data;
    for (int32_t i = 0; i < frames; i++) out[i] = src[i] / 32768.0f;
  } else {
    fprintf(stderr, "unsupported wav: float=%d bits=%d\n", is_float, bits);
    free(buf);
    return NULL;
  }

  if (channels > 1) {
    int32_t mono_n = frames / channels;
    float *mono = malloc((size_t)mono_n * sizeof(float));
    for (int32_t i = 0; i < mono_n; i++) {
      float sum = 0;
      for (int c = 0; c < channels; c++) sum += out[(size_t)i * channels + c];
      mono[i] = sum / channels;
    }
    out = mono;
    frames = mono_n;
  }
  /* Copy so the buffer can be freed uniformly; the memcpy is noise next to ASR. */
  float *copy = malloc((size_t)frames * sizeof(float));
  memcpy(copy, out, (size_t)frames * sizeof(float));

  *out_n = frames;
  *out_rate = rate;
  return copy;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: probe_transcribe <file.wav> <models-dir>\n");
    return 2;
  }
  int32_t n = 0;
  uint32_t rate = 0;
  float *pcm = read_wav(argv[1], &n, &rate);
  if (!pcm) {
    fprintf(stderr, "could not read %s\n", argv[1]);
    return 2;
  }
  double seconds = (double)n / rate;

  double t0 = now();
  int rc = Core_Initialize(argv[2]);
  double t_load = now() - t0;
  if (rc != 0) {
    char *e = Core_GetLastError();
    fprintf(stderr, "Core_Initialize failed (%d): %s\n", rc, e ? e : "?");
    if (e) Core_FreeString(e);
    return 1;
  }

  /* The engine treats the ASR model as lazily loaded, exactly like the app. */
  if (Agent_Load("asr") != 0) {
    char *e = Core_GetLastError();
    fprintf(stderr, "Agent_Load(asr) failed: %s\n", e ? e : "?");
    if (e) Core_FreeString(e);
    return 1;
  }

  double t1 = now();
  if (ASR_Start() != 0) {
    fprintf(stderr, "ASR_Start failed\n");
    return 1;
  }
  if (ASR_SubmitAudio(pcm, (size_t)n, rate) != 0) {
    fprintf(stderr, "ASR_SubmitAudio failed\n");
    return 1;
  }
  char *text = NULL;
  rc = ASR_Stop(&text);
  double t_asr = now() - t1;
  if (rc != 0) {
    fprintf(stderr, "ASR_Stop failed (%d)\n", rc);
    return 1;
  }

  Usage u = {0};
  int have = Memory_GetUsage(&u) == 0;

  printf("wav: %s (%.3fs, %u Hz)\n", argv[1], seconds, rate);
  printf("load=%.3fs asr=%.3fs rtf=%.3f\n", t_load, t_asr, t_asr / seconds);
  if (have) {
    printf("model_bytes=%llu peak_rss=%llu MB baseline_rss=%llu MB\n",
           (unsigned long long)u.model_bytes,
           (unsigned long long)(u.peak_rss_bytes / 1048576),
           (unsigned long long)(u.baseline_rss_bytes / 1048576));
  }
  printf("text: %s\n", text ? text : "(null)");
  if (text) Core_FreeString(text);
  return 0;
}
