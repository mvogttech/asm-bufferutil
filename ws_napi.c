/* ws_napi.c — N-API wrapper for all WebSocket acceleration functions */
#include <node_api.h>
#include <assert.h>
#include <stdint.h>
#include <string.h>

/* Assembly functions (ws_mask_asm.asm) */
extern void _init_cpu_features(void);
extern void ws_mask(const uint8_t *src, const uint8_t *mask,
                    uint8_t *out, size_t offset, size_t length);
extern void ws_unmask(uint8_t *buf, const uint8_t *mask, size_t length);
extern int64_t ws_find_header(const uint8_t *buf, size_t len,
                               const uint8_t *needle, size_t needle_len);
extern size_t ws_base64_encode(const uint8_t *in, size_t len, uint8_t *out);

/* CPU feature bitmask populated by _init_cpu_features() in ws_cpu.asm */
extern uint32_t cpu_features;

/* Internal CRC32 — SSE4.2 based, not N-API exported */
extern uint32_t ws_crc32(const uint8_t *buf, size_t len, uint32_t init);

/* C functions (ws_sha1_ni.c) */
extern int  ws_has_sha_ni(void);
extern void ws_sha1_ni(const uint8_t *msg, size_t len, uint8_t out[20]);

static napi_value Mask(napi_env env, napi_callback_info info) {
    size_t argc = 5; napi_value argv[5];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    uint8_t *src, *mask, *out; size_t sl, ml, ol;
    uint32_t offset, length;
    napi_get_buffer_info(env, argv[0], (void**)&src, &sl);
    napi_get_buffer_info(env, argv[1], (void**)&mask, &ml);
    napi_get_buffer_info(env, argv[2], (void**)&out, &ol);
    napi_get_value_uint32(env, argv[3], &offset);
    napi_get_value_uint32(env, argv[4], &length);
    ws_mask(src, mask, out, offset, length);
    return NULL;
}

static napi_value Unmask(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    uint8_t *buf, *mask; size_t bl, ml;
    napi_get_buffer_info(env, argv[0], (void**)&buf, &bl);
    napi_get_buffer_info(env, argv[1], (void**)&mask, &ml);
    ws_unmask(buf, mask, bl);
    return NULL;
}

static napi_value Sha1(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    uint8_t *data; size_t dl;
    napi_get_buffer_info(env, argv[0], (void**)&data, &dl);
    uint8_t hash[20];
    ws_sha1_ni(data, dl, hash);
    napi_value result; void *rd;
    napi_create_buffer_copy(env, 20, hash, &rd, &result);
    return result;
}

static napi_value FindHeader(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    uint8_t *buf, *needle; size_t bl, nl;
    napi_get_buffer_info(env, argv[0], (void**)&buf, &bl);
    napi_get_buffer_info(env, argv[1], (void**)&needle, &nl);
    int64_t result = ws_find_header(buf, bl, needle, nl);
    napi_value ret;
    napi_create_int64(env, result, &ret);
    return ret;
}

static napi_value Base64Encode(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    uint8_t *data; size_t dl;
    napi_get_buffer_info(env, argv[0], (void**)&data, &dl);
    uint8_t out[256]; /* max output for our use case */
    size_t olen = ws_base64_encode(data, dl, out);
    napi_value result; void *rd;
    napi_create_buffer_copy(env, olen, out, &rd, &result);
    return result;
}

static napi_value Init(napi_env env, napi_value exports) {
    _init_cpu_features();

    struct { const char *name; napi_callback cb; } fns[] = {
        {"mask",         Mask},
        {"unmask",       Unmask},
        {"sha1",         Sha1},
        {"findHeader",   FindHeader},
        {"base64Encode", Base64Encode},
    };

    for (int i = 0; i < 5; i++) {
        napi_value fn;
        napi_create_function(env, NULL, 0, fns[i].cb, NULL, &fn);
        napi_set_named_property(env, exports, fns[i].name, fn);
    }

    napi_value sha_val;
    napi_create_int32(env, ws_has_sha_ni(), &sha_val);
    napi_set_named_property(env, exports, "hasShaNi", sha_val);

    napi_value feats_val;
    napi_create_uint32(env, cpu_features, &feats_val);
    napi_set_named_property(env, exports, "cpuFeatures", feats_val);

    return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
