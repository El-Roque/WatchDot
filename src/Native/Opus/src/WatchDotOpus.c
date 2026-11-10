#include "WatchDotOpus.h"
#include "opus.h"
#include <stdlib.h>

struct WatchDotOpus { OpusEncoder *encoder; OpusDecoder *decoder; };

WatchDotOpus *watchdot_opus_create(void) {
    WatchDotOpus *codec = calloc(1, sizeof(*codec));
    if (!codec) return NULL;
    int status = OPUS_OK;
    codec->encoder = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &status);
    if (!codec->encoder || status != OPUS_OK) goto failure;
    codec->decoder = opus_decoder_create(48000, 1, &status);
    if (!codec->decoder || status != OPUS_OK) goto failure;
    if (opus_encoder_ctl(codec->encoder, OPUS_SET_BITRATE(24000)) != OPUS_OK) goto failure;
    if (opus_encoder_ctl(codec->encoder, OPUS_SET_COMPLEXITY(5)) != OPUS_OK) goto failure;
    if (opus_encoder_ctl(codec->encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE)) != OPUS_OK) goto failure;
    return codec;
failure:
    watchdot_opus_free(codec);
    return NULL;
}

void watchdot_opus_free(WatchDotOpus *codec) {
    if (!codec) return;
    if (codec->encoder) opus_encoder_destroy(codec->encoder);
    if (codec->decoder) opus_decoder_destroy(codec->decoder);
    free(codec);
}

int32_t watchdot_opus_encode(WatchDotOpus *codec, const float *pcm, int32_t frames,
                           uint8_t *packet, int32_t capacity) {
    if (!codec || !pcm || !packet || frames != 960 || capacity < 1 || capacity > 1275) return OPUS_BAD_ARG;
    return opus_encode_float(codec->encoder, pcm, frames, packet, capacity);
}

int32_t watchdot_opus_decode(WatchDotOpus *codec, const uint8_t *packet, int32_t length,
                           float *pcm, int32_t capacity) {
    const int conceal = packet == NULL && length == 0;
    if (!codec || !pcm || capacity < 120 || capacity > 5760) return OPUS_BAD_ARG;
    if (conceal) {
        if (capacity % 120 != 0) return OPUS_BAD_ARG;
    } else if (!packet || length < 1 || length > 2000) return OPUS_BAD_ARG;
    return opus_decode_float(codec->decoder, packet, length, pcm, capacity, 0);
}

int32_t watchdot_opus_recover(WatchDotOpus *codec, const uint8_t *next, int32_t length,
                            float *pcm, int32_t missing_frames, int32_t *used_fec) {
    if (!codec || !next || !pcm || !used_fec || length < 1 || length > 2000 ||
        missing_frames < 120 || missing_frames > 5760 || missing_frames % 120 != 0) return OPUS_BAD_ARG;
    *used_fec = 0;
    const int has_fec = opus_packet_has_lbrr(next, length);
    if (has_fec < 0) return has_fec;
    *used_fec = has_fec > 0;
    return opus_decode_float(codec->decoder, has_fec > 0 ? next : NULL,
        has_fec > 0 ? length : 0, pcm, missing_frames, has_fec > 0 ? 1 : 0);
}
