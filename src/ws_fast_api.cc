/* ws_fast_api.cc — V8 C++ API wrapper for WebSocket acceleration functions
 *
 * Replaces ws_napi.c with direct V8 C++ API calls. This avoids the
 * N-API dispatch layer overhead (~7 napi_* calls per mask invocation)
 * by using inline node::Buffer::Data() and direct args[N] access.
 */

#include <node.h>
#include <node_buffer.h>
#include <cstdint>
#include <cstddef>

extern "C" {
    void _init_cpu_features(void);
    void ws_mask(const uint8_t *src, const uint8_t *mask,
                 uint8_t *out, size_t offset, size_t length);
    void ws_unmask(uint8_t *buf, const uint8_t *mask, size_t length);
    int64_t ws_find_header(const uint8_t *buf, size_t len,
                            const uint8_t *needle, size_t needle_len);
    size_t ws_base64_encode(const uint8_t *in, size_t len, uint8_t *out);
    extern uint32_t cpu_features;
    int  ws_has_sha_ni(void);
    void ws_sha1_ni(const uint8_t *msg, size_t len, uint8_t out[20]);
}

/* ====================================================================
 * Function callbacks — direct V8 C++ API
 * ==================================================================== */

static void Mask(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto ctx = args.GetIsolate()->GetCurrentContext();
    auto *src  = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[0]));
    auto *mask = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[1]));
    auto *out  = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[2]));
    uint32_t offset = args[3]->Uint32Value(ctx).FromJust();
    uint32_t length = args[4]->Uint32Value(ctx).FromJust();
    ws_mask(src, mask, out, offset, length);
}

static void Unmask(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto *buf  = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[0]));
    auto  bl   = node::Buffer::Length(args[0]);
    auto *mask = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[1]));
    ws_unmask(buf, mask, bl);
}

static void Sha1(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto *isolate = args.GetIsolate();
    auto *data = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[0]));
    auto  len  = node::Buffer::Length(args[0]);
    auto result = node::Buffer::New(isolate, 20).ToLocalChecked();
    ws_sha1_ni(data, len,
               reinterpret_cast<uint8_t*>(node::Buffer::Data(result)));
    args.GetReturnValue().Set(result);
}

static void FindHeader(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto *isolate = args.GetIsolate();
    auto *buf    = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[0]));
    auto  bl     = node::Buffer::Length(args[0]);
    auto *needle = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[1]));
    auto  nl     = node::Buffer::Length(args[1]);
    int64_t offset = ws_find_header(buf, bl, needle, nl);
    args.GetReturnValue().Set(
        v8::Number::New(isolate, static_cast<double>(offset)));
}

static void Base64Encode(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto *isolate = args.GetIsolate();
    auto *data    = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[0]));
    auto  len     = node::Buffer::Length(args[0]);
    size_t max_out = (len + 2) / 3 * 4;
    auto result = node::Buffer::New(isolate, max_out).ToLocalChecked();
    ws_base64_encode(data, len,
                     reinterpret_cast<uint8_t*>(node::Buffer::Data(result)));
    args.GetReturnValue().Set(result);
}

/* ====================================================================
 * Batch operations — amortize V8 call overhead across many frames
 *
 * Uses packed buffers so the inner C loop has ZERO V8 API calls —
 * just pointer arithmetic and ws_unmask/ws_mask assembly calls.
 * ==================================================================== */

/* batchUnmask(data, offsets, lengths, masks, count)
 *   data:    Buffer — packed frame payloads (unmasked in-place)
 *   offsets: Buffer — uint32_t[] byte offsets into data for each frame
 *   lengths: Buffer — uint32_t[] byte lengths for each frame
 *   masks:   Buffer — 4 bytes per frame, concatenated
 *   count:   Number — number of frames
 */
static void BatchUnmask(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto ctx = args.GetIsolate()->GetCurrentContext();
    auto *data    = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[0]));
    auto *offsets = reinterpret_cast<uint32_t*>(node::Buffer::Data(args[1]));
    auto *lengths = reinterpret_cast<uint32_t*>(node::Buffer::Data(args[2]));
    auto *masks   = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[3]));
    uint32_t count = args[4]->Uint32Value(ctx).FromJust();

    for (uint32_t i = 0; i < count; i++) {
        ws_unmask(data + offsets[i], masks + i * 4, lengths[i]);
    }
}

/* batchMask(src, dst, offsets, lengths, masks, count)
 *   src:     Buffer — packed source payloads
 *   dst:     Buffer — packed output buffer (masked data written here)
 *   offsets: Buffer — uint32_t[] byte offsets (same for src and dst)
 *   lengths: Buffer — uint32_t[] byte lengths for each frame
 *   masks:   Buffer — 4 bytes per frame, concatenated
 *   count:   Number — number of frames
 */
static void BatchMask(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto ctx = args.GetIsolate()->GetCurrentContext();
    auto *src     = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[0]));
    auto *dst     = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[1]));
    auto *offsets = reinterpret_cast<uint32_t*>(node::Buffer::Data(args[2]));
    auto *lengths = reinterpret_cast<uint32_t*>(node::Buffer::Data(args[3]));
    auto *masks   = reinterpret_cast<uint8_t*>(node::Buffer::Data(args[4]));
    uint32_t count = args[5]->Uint32Value(ctx).FromJust();

    for (uint32_t i = 0; i < count; i++) {
        ws_mask(src + offsets[i], masks + i * 4,
                dst + offsets[i], 0, lengths[i]);
    }
}

/* ====================================================================
 * Module initialization
 * ==================================================================== */

NODE_MODULE_INIT(/* exports, module, context */) {
    auto *isolate = context->GetIsolate();

    _init_cpu_features();

    struct { const char *name; v8::FunctionCallback cb; } fns[] = {
        {"mask",         Mask},
        {"unmask",       Unmask},
        {"sha1",         Sha1},
        {"findHeader",   FindHeader},
        {"base64Encode", Base64Encode},
        {"batchUnmask",  BatchUnmask},
        {"batchMask",    BatchMask},
    };

    for (auto& fn : fns) {
        auto tmpl = v8::FunctionTemplate::New(isolate, fn.cb);
        exports->Set(context,
            v8::String::NewFromUtf8(isolate, fn.name).ToLocalChecked(),
            tmpl->GetFunction(context).ToLocalChecked()).Check();
    }

    exports->Set(context,
        v8::String::NewFromUtf8Literal(isolate, "hasShaNi"),
        v8::Integer::New(isolate, ws_has_sha_ni())).Check();
    exports->Set(context,
        v8::String::NewFromUtf8Literal(isolate, "cpuFeatures"),
        v8::Integer::NewFromUnsigned(isolate, cpu_features)).Check();
}
