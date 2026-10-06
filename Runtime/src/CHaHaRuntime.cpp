#include "CHaHaRuntime.h"
#include "llama.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <sys/sysctl.h>

using Clock = std::chrono::steady_clock;
struct haha_cancellation { std::atomic<bool> requested{false}; };
struct haha_engine {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    std::string path;
};

namespace {
constexpr int context_size = 4096;
constexpr int batch_size = 256;
double elapsed(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}
bool cancelled(haha_cancellation * c) { return c && c->requested.load(std::memory_order_relaxed); }
bool abort_decode(void * p) { return cancelled(static_cast<haha_cancellation *>(p)); }
bool load_progress(float, void * p) { return !cancelled(static_cast<haha_cancellation *>(p)); }
char * copy_string(const std::string & s) {
    auto p = static_cast<char *>(std::malloc(s.size() + 1));
    if (p) std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}
int fail(int code, const char * message, char ** error) {
    if (error) *error = copy_string(message);
    return code;
}
int threads() {
    int n = 0;
    size_t len = sizeof(n);
    if (sysctlbyname("hw.perflevel0.physicalcpu", &n, &len, nullptr, 0) != 0 || n < 1)
        n = static_cast<int>(std::thread::hardware_concurrency());
    return std::clamp(n, 1, 8);
}
std::vector<llama_token> tokenize(const llama_vocab * vocab, const std::string & text, bool special) {
    int n = llama_tokenize(vocab, text.data(), static_cast<int>(text.size()), nullptr, 0, false, special);
    if (n == 0) return {};
    if (n > 0) throw std::runtime_error("Unexpected tokenizer result");
    std::vector<llama_token> tokens(-n);
    n = llama_tokenize(vocab, text.data(), static_cast<int>(text.size()), tokens.data(),
                       static_cast<int>(tokens.size()), false, special);
    if (n < 0) throw std::runtime_error("Could not tokenize text");
    tokens.resize(n);
    return tokens;
}
// Do not emit an incomplete multi-byte scalar across a Swift callback boundary.
size_t complete_utf8_prefix(const std::string & s) {
    size_t i = 0;
    while (i < s.size()) {
        unsigned char ch = s[i];
        size_t count = ch < 0x80 ? 1 : ch >= 0xc2 && ch <= 0xdf ? 2 :
                       ch >= 0xe0 && ch <= 0xef ? 3 : ch >= 0xf0 && ch <= 0xf4 ? 4 : 0;
        if (!count) return std::string::npos;
        if (i + count > s.size()) return i;
        for (size_t j = 1; j < count; ++j)
            if ((static_cast<unsigned char>(s[i + j]) & 0xc0) != 0x80) return std::string::npos;
        if (count > 1) {
            auto second = static_cast<unsigned char>(s[i + 1]);
            if ((ch == 0xe0 && second < 0xa0) || (ch == 0xed && second > 0x9f) ||
                (ch == 0xf0 && second < 0x90) || (ch == 0xf4 && second > 0x8f)) return std::string::npos;
        }
        i += count;
    }
    return i;
}
struct ContextCleanup {
    llama_context * context;
    ~ContextCleanup() {
        // Erase request KV data while keeping allocation for the next paragraph.
        llama_set_abort_callback(context, nullptr, nullptr);
        llama_memory_clear(llama_get_memory(context), true);
    }
};
void runtime_log(ggml_log_level level, const char * message, void *) {
    if (level == GGML_LOG_LEVEL_ERROR || level == GGML_LOG_LEVEL_WARN) std::fputs(message, stderr);
}
}

extern "C" {
haha_engine * haha_engine_create(void) {
    static std::once_flag once;
    std::call_once(once, [] { llama_log_set(runtime_log, nullptr); llama_backend_init(); });
    return new (std::nothrow) haha_engine();
}
void haha_engine_unload(haha_engine * engine) {
    if (!engine) return;
    if (engine->context) llama_free(engine->context);
    if (engine->model) llama_model_free(engine->model);
    engine->context = nullptr;
    engine->model = nullptr;
    engine->path.clear();
}
void haha_engine_destroy(haha_engine * engine) { haha_engine_unload(engine); delete engine; }
haha_cancellation * haha_cancellation_create(void) { return new (std::nothrow) haha_cancellation(); }
void haha_cancellation_request(haha_cancellation * c) { if (c) c->requested.store(true, std::memory_order_relaxed); }
void haha_cancellation_destroy(haha_cancellation * c) { delete c; }
void haha_string_free(char * s) { std::free(s); }
const char * haha_runtime_version(void) {
    return "llama.cpp STQ 1e411d8f5a1e23525fa3265dfb4bd76265465397 + legacy stride16 mapping; CPU ARM NEON; context 4096";
}

int32_t haha_engine_translate(haha_engine * engine, const char * model_path,
    const char * prompt, int32_t max_output_tokens, haha_cancellation * cancellation,
    haha_token_callback callback, void * user_data, char ** output, char ** error,
    haha_metrics * metrics) {
    if (output) *output = nullptr;
    if (error) *error = nullptr;
    if (metrics) *metrics = {};
    if (!engine || !model_path || !prompt || !output || !cancellation)
        return fail(HAHA_INVALID_ARGUMENT, "Missing runtime argument", error);
    if (max_output_tokens < 1 || max_output_tokens > context_size)
        return fail(HAHA_INVALID_ARGUMENT, "Invalid output token limit", error);
    if (cancelled(cancellation)) return HAHA_CANCELLED;
    try {
        const auto start = Clock::now();
        if (!engine->model || engine->path != model_path) {
            haha_engine_unload(engine);
            auto mp = llama_model_default_params();
            mp.n_gpu_layers = 0; // STQ1_0 is an ARM NEON CPU kernel.
            mp.progress_callback = load_progress;
            mp.progress_callback_user_data = cancellation;
            engine->model = llama_model_load_from_file(model_path, mp);
            if (!engine->model) return cancelled(cancellation) ? HAHA_CANCELLED :
                fail(HAHA_MODEL_ERROR, "The model could not be loaded. Verify the model and download checksum.", error);
            char architecture[128] = {};
            llama_model_meta_val_str(engine->model, "general.architecture", architecture, sizeof(architecture));
            if (std::strcmp(architecture, "hunyuan-dense") != 0) {
                haha_engine_unload(engine);
                return fail(HAHA_MODEL_ERROR, "This engine requires an approved Hy-MT2 dense GGUF model.", error);
            }
            auto cp = llama_context_default_params();
            cp.n_ctx = context_size;
            cp.n_batch = batch_size;
            cp.n_ubatch = batch_size;
            cp.n_threads = cp.n_threads_batch = threads();
            cp.abort_callback = abort_decode;
            cp.abort_callback_data = cancellation;
            cp.no_perf = false;
            engine->context = llama_init_from_model(engine->model, cp);
            if (!engine->context) {
                haha_engine_unload(engine);
                return fail(HAHA_MODEL_ERROR, "Insufficient memory or incompatible model context.", error);
            }
            engine->path = model_path;
            if (metrics) metrics->load_seconds = elapsed(start);
        }
        auto ctx = engine->context;
        ContextCleanup clear{ctx};
        llama_set_abort_callback(ctx, abort_decode, cancellation);
        llama_memory_clear(llama_get_memory(ctx), true);
        const auto vocab = llama_model_get_vocab(engine->model);
        // Official chat_template.jinja, single user message, add_generation_prompt=true.
        auto tokens = tokenize(vocab, "<｜hy_begin▁of▁sentence｜><｜hy_User｜>", true);
        auto content = tokenize(vocab, prompt, false);
        auto suffix = tokenize(vocab, "<｜hy_Assistant｜>", true);
        tokens.insert(tokens.end(), content.begin(), content.end());
        tokens.insert(tokens.end(), suffix.begin(), suffix.end());
        if (tokens.size() + 32 >= context_size)
            return fail(HAHA_CONTEXT_LIMIT, "Text is too long; split it into smaller paragraphs.", error);
        if (metrics) metrics->prompt_tokens = static_cast<int>(tokens.size());
        auto sp = llama_sampler_chain_default_params();
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_chain_init(sp), llama_sampler_free);
        // Tencent recommended settings. Fixed RNG seed gives reproducible diagnostics.
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.05f, 0.0f, 0.0f));
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(20));
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(0.6f, 1));
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(0.7f));
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(42));
        const auto generation_start = Clock::now();
        for (size_t offset = 0; offset < tokens.size(); offset += batch_size) {
            if (cancelled(cancellation)) return HAHA_CANCELLED;
            int count = static_cast<int>(std::min(static_cast<size_t>(batch_size), tokens.size() - offset));
            auto batch = llama_batch_get_one(tokens.data() + offset, count);
            int status = llama_decode(ctx, batch);
            if (status != 0) return cancelled(cancellation) ? HAHA_CANCELLED :
                fail(HAHA_INFERENCE_ERROR, "The model could not process this paragraph.", error);
        }
        std::string result, pending;
        const int available = std::min(max_output_tokens, context_size - static_cast<int>(tokens.size()));
        for (int i = 0; i < available; ++i) {
            if (cancelled(cancellation)) return HAHA_CANCELLED;
            auto token = llama_sampler_sample(sampler.get(), ctx, -1);
            if (llama_vocab_is_eog(vocab, token)) {
                if (!pending.empty()) return fail(HAHA_INFERENCE_ERROR, "The model returned incomplete UTF-8 text.", error);
                *output = copy_string(result);
                if (metrics) metrics->generation_seconds = elapsed(generation_start);
                return *output ? HAHA_OK : fail(HAHA_INFERENCE_ERROR, "Out of memory", error);
            }
            if (i == 0 && metrics) metrics->first_token_seconds = elapsed(start);
            if (metrics) ++metrics->generated_tokens;
            char small[256];
            int n = llama_token_to_piece(vocab, token, small, sizeof(small), 0, false);
            if (n < 0) {
                std::vector<char> large(-n);
                n = llama_token_to_piece(vocab, token, large.data(), static_cast<int>(large.size()), 0, false);
                if (n < 0) return fail(HAHA_INFERENCE_ERROR, "Could not decode token", error);
                pending.append(large.data(), n);
            } else pending.append(small, n);
            size_t valid = complete_utf8_prefix(pending);
            if (valid == std::string::npos)
                return fail(HAHA_INFERENCE_ERROR, "The model returned invalid UTF-8 text.", error);
            if (valid) {
                result.append(pending, 0, valid);
                if (callback) callback(pending.data(), valid, user_data);
                pending.erase(0, valid);
            }
            if (cancelled(cancellation)) return HAHA_CANCELLED;
            auto batch = llama_batch_get_one(&token, 1);
            int status = llama_decode(ctx, batch);
            if (status != 0) return cancelled(cancellation) ? HAHA_CANCELLED :
                fail(HAHA_INFERENCE_ERROR, "The model stopped unexpectedly.", error);
        }
        return fail(HAHA_OUTPUT_LIMIT, "The translation reached its output limit; split this paragraph and retry.", error);
    } catch (const std::exception & e) {
        return fail(HAHA_INFERENCE_ERROR, e.what(), error);
    } catch (...) {
        return fail(HAHA_INFERENCE_ERROR, "Unexpected inference failure", error);
    }
}
}
