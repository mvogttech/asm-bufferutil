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
