#include "WatchDotOpus.h"
#include "opus.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static void prove_fec(void) {
    int status;
    OpusEncoder *encoder = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &status);
    assert(encoder && status == OPUS_OK);
    assert(opus_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(1)) == OPUS_OK);
    assert(opus_encoder_ctl(encoder, OPUS_SET_PACKET_LOSS_PERC(20)) == OPUS_OK);
    assert(opus_encoder_ctl(encoder, OPUS_SET_BITRATE(24000)) == OPUS_OK);
    assert(opus_encoder_ctl(encoder, OPUS_SET_MAX_BANDWIDTH(OPUS_BANDWIDTH_WIDEBAND)) == OPUS_OK);
    uint8_t packets[80][1275];
    int lengths[80], selected = -1;
    float input[960], recovered[5760], concealed[5760];
    for (int frame = 0; frame < 80; frame++) {
        for (int i = 0; i < 960; i++) input[i] = (0.07f + frame * 0.001f) * sinf(6.2831853f * (170 + frame * 3) * (frame * 960 + i) / 48000);
        lengths[frame] = opus_encode_float(encoder, input, 960, packets[frame], 1275);
        assert(lengths[frame] > 0);
        if (frame >= 20 && selected < 0 && opus_packet_has_lbrr(packets[frame], lengths[frame]) > 0) selected = frame;
    }
    assert(selected >= 20);
    WatchDotOpus *fec = watchdot_opus_create(), *plc = watchdot_opus_create();
    assert(fec && plc);
    for (int frame = 0; frame < selected - 1; frame++) {
        assert(watchdot_opus_decode(fec, packets[frame], lengths[frame], recovered, 5760) == 960);
        assert(watchdot_opus_decode(plc, packets[frame], lengths[frame], concealed, 5760) == 960);
    }
    int used = 0;
    assert(watchdot_opus_recover(fec, packets[selected], lengths[selected], recovered, 960, &used) == 960);
    assert(used == 1);
    assert(watchdot_opus_decode(plc, NULL, 0, concealed, 960) == 960);
    double difference = 0;
    for (int i = 0; i < 960; i++) {
        assert(isfinite(recovered[i]));
        difference += fabs((double)recovered[i] - concealed[i]);
    }
    assert(difference > 0.000001);
    assert(watchdot_opus_decode(fec, packets[selected], lengths[selected], recovered, 5760) == 960);
    const uint8_t silence[] = {0xf8, 0xff, 0xfe};
    assert(watchdot_opus_recover(fec, silence, 3, recovered, 960, &used) == 960);
    assert(used == 0);
    watchdot_opus_free(fec); watchdot_opus_free(plc); opus_encoder_destroy(encoder);
}

int main(void) {
    WatchDotOpus *codec = watchdot_opus_create();
    assert(codec);
    float input[960], output[5760];
    uint8_t packet[1275];
    int concealed = 0;
    for (int frame = 0; frame < 30; frame++) {
        for (int i = 0; i < 960; i++) input[i] = 0.1f * sinf(6.2831853f * 220 * (frame * 960 + i) / 48000);
        int length = watchdot_opus_encode(codec, input, 960, packet, 1275);
        assert(length > 0);
        int count;
        if (frame == 10) {
            count = watchdot_opus_decode(codec, NULL, 0, output, 960);
            concealed += count;
        } else count = watchdot_opus_decode(codec, packet, length, output, 5760);
        assert(count == 960);
        for (int i = 0; i < count; i++) assert(isfinite(output[i]) && fabsf(output[i]) <= 1.01f);
    }
    assert(concealed == 960);
    assert(watchdot_opus_decode(codec, NULL, 0, output, 5760) == 5760);
    assert(watchdot_opus_decode(codec, NULL, 0, output, 121) < 0);
    assert(watchdot_opus_decode(codec, packet, 0, output, 960) < 0);
    watchdot_opus_free(codec);
    prove_fec();
    puts("{\"result\":\"passed\",\"realFrames\":29,\"concealedSamples\":960,\"maximumGapFrames\":5760,\"fecRecovery\":true,\"fecDiffersFromPLC\":true,\"noFECFallback\":true}");
    return 0;
}
