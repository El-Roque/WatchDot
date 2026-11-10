#ifndef WATCHDOT_OPUS_H
#define WATCHDOT_OPUS_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct WatchDotOpus WatchDotOpus;
WatchDotOpus *watchdot_opus_create(void);
void watchdot_opus_free(WatchDotOpus *codec);
/* Mono float 48 kHz, 960 samples. Returns packet bytes, or a negative Opus code. */
int32_t watchdot_opus_encode(WatchDotOpus *codec, const float *pcm, int32_t frames,
                           uint8_t *packet, int32_t capacity);
/* Output capacity up to 5760 mono float frames (120 ms). Returns decoded frames. */
/* NULL packet and zero length conceal exactly capacity frames (multiple of 120). */
int32_t watchdot_opus_decode(WatchDotOpus *codec, const uint8_t *packet, int32_t length,
                           float *pcm, int32_t capacity);
/* Recover an exact gap from the next packet's FEC when present; otherwise PLC.
   Decode that same next packet normally afterward. used_fec is 0 or 1. */
int32_t watchdot_opus_recover(WatchDotOpus *codec, const uint8_t *next, int32_t length,
                            float *pcm, int32_t missing_frames, int32_t *used_fec);
#ifdef __cplusplus
}
#endif
#endif
