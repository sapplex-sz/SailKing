#ifndef CHAHA_RUNTIME_H
#define CHAHA_RUNTIME_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct haha_engine haha_engine;
typedef struct haha_cancellation haha_cancellation;
typedef void (*haha_token_callback)(const char * utf8, size_t length, void * user_data);
typedef struct haha_metrics {
    double load_seconds;
    double first_token_seconds;
    double generation_seconds;
    int32_t prompt_tokens;
    int32_t generated_tokens;
} haha_metrics;
enum haha_status {
    HAHA_OK = 0, HAHA_CANCELLED = 1, HAHA_INVALID_ARGUMENT = 2,
    HAHA_MODEL_ERROR = 3, HAHA_CONTEXT_LIMIT = 4, HAHA_INFERENCE_ERROR = 5,
    HAHA_OUTPUT_LIMIT = 6
};

/* An engine is serial-use only. Cancellation is safe from any other thread. */
haha_engine * haha_engine_create(void);
void haha_engine_destroy(haha_engine * engine);
void haha_engine_unload(haha_engine * engine);
haha_cancellation * haha_cancellation_create(void);
void haha_cancellation_request(haha_cancellation * cancellation);
void haha_cancellation_destroy(haha_cancellation * cancellation);

/* Uses the official Hy-MT2 single-user chat template, with no system message.
   prompt is a translation instruction containing the source text. Stream chunks
   are complete UTF-8 and incremental. output/error are malloc-owned; free them
   with haha_string_free. On limit/error the function never reports success. */
int32_t haha_engine_translate(haha_engine * engine, const char * model_path,
    const char * prompt, int32_t max_output_tokens,
    haha_cancellation * cancellation, haha_token_callback callback,
    void * user_data, char ** output, char ** error, haha_metrics * metrics);
void haha_string_free(char * value);
const char * haha_runtime_version(void);

#ifdef __cplusplus
}
#endif
#endif
