#include "c-api.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Read 16 kHz mono PCM from stdin and write only the transcript to stdout.
int main(void) {
    SherpaOnnxOnlineRecognizerConfig config = {0};
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.transducer.encoder = "encoder.onnx";
    config.model_config.transducer.decoder = "decoder.onnx";
    config.model_config.transducer.joiner = "joiner.onnx";
    config.model_config.tokens = "tokens.txt";
    config.model_config.modeling_unit = "cjkchar+bpe";
    config.model_config.bpe_vocab = "bpe.vocab";
    config.model_config.num_threads = 2;
    config.model_config.provider = "cpu";
    config.decoding_method = "modified_beam_search";
    config.max_active_paths = 8;
    config.hotwords_buf = "CODEX\nGITHUB\nAPI";
    config.hotwords_buf_size = (int32_t)strlen(config.hotwords_buf);
    config.hotwords_score = 2;

    const SherpaOnnxOnlineRecognizer *recognizer = SherpaOnnxCreateOnlineRecognizer(&config);
    if (!recognizer) return 2;
    const SherpaOnnxOnlineStream *stream = SherpaOnnxCreateOnlineStream(recognizer);
    if (!stream) {
        SherpaOnnxDestroyOnlineRecognizer(recognizer);
        return 2;
    }

    int16_t pcm[4096];
    float samples[4096];
    size_t total = 0;
    size_t count;
    while ((count = fread(pcm, sizeof(pcm[0]), 4096, stdin)) != 0) {
        total += count;
        if (total > 16000 * 50) break;
        for (size_t i = 0; i < count; ++i) samples[i] = pcm[i] / 32768.0f;
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, samples, (int32_t)count);
    }

    int status = 3;
    if (!ferror(stdin) && total > 0 && total <= 16000 * 50) {
        // The streaming encoder needs trailing context to emit the final words.
        float padding[24000] = {0};
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, padding, 24000);
        SherpaOnnxOnlineStreamInputFinished(stream);
        while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) {
            SherpaOnnxDecodeOnlineStream(recognizer, stream);
        }
        const SherpaOnnxOnlineRecognizerResult *result =
            SherpaOnnxGetOnlineStreamResult(recognizer, stream);
        if (result) {
            if (result->text && fputs(result->text, stdout) >= 0) status = 0;
            SherpaOnnxDestroyOnlineRecognizerResult(result);
        }
    }
    SherpaOnnxDestroyOnlineStream(stream);
    SherpaOnnxDestroyOnlineRecognizer(recognizer);
    return status;
}
