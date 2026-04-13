/* ws_fallback.c — portable C fallbacks for non-Linux-x64 platforms.
 *
 * Provides the symbols assembled by ws_cpu.asm, ws_mask_asm.asm, and
 * ws_base64_asm.asm on Linux x64.  Used on Windows (MSVC) and macOS (Clang).
 *
 * Symbols provided:
 *   cpu_features        — feature bitmask global (matches ws_cpu.asm layout)
 *   _init_cpu_features  — populate cpu_features via CPUID
 *   ws_mask             — XOR-mask src -> out+offset
 *   ws_unmask           — XOR-unmask buf in place
 *   ws_find_header      — HTTP header substring search
 *   ws_base64_encode    — RFC 4648 §4 base64 encoder
 */
#include <stdint.h>
#include <string.h>

#ifdef _MSC_VER
#  include <intrin.h>
#elif defined(__x86_64__) || defined(__i386__)
#  include <cpuid.h>
#endif

/* cpu_features bitmask (same bit layout as ws_cpu.asm):
 *   bit 0 = GFNI      (CPUID leaf 7, sub 0: ECX bit  8)
 *   bit 1 = PCLMULQDQ (CPUID leaf 1:        ECX bit  1)
 *   bit 2 = BMI2      (CPUID leaf 7, sub 0: EBX bit  8)
 *   bit 3 = LZCNT     (CPUID leaf 0x80000001: ECX bit 5)
 */
uint32_t cpu_features = 0;

void _init_cpu_features(void) {
#if defined(_MSC_VER)
    int info[4];
    __cpuid(info, 0);
    int max_leaf = info[0];
    if (max_leaf >= 7) {
        __cpuidex(info, 7, 0);
        if (info[2] & (1 << 8)) cpu_features |= 1;  /* GFNI */
        if (info[1] & (1 << 8)) cpu_features |= 4;  /* BMI2 */
    }
    if (max_leaf >= 1) {
        __cpuid(info, 1);
        if (info[2] & (1 << 1)) cpu_features |= 2;  /* PCLMULQDQ */
    }
    __cpuid(info, (int)0x80000000u);
    if ((unsigned int)info[0] >= 0x80000001u) {
        __cpuid(info, (int)0x80000001u);
        if (info[2] & (1 << 5)) cpu_features |= 8;  /* LZCNT */
    }
#elif defined(__x86_64__) || defined(__i386__)
    unsigned int a, b, c, d;
    if (__get_cpuid(0, &a, &b, &c, &d)) {
        unsigned int max_leaf = a;
        if (max_leaf >= 7 && __get_cpuid_count(7, 0, &a, &b, &c, &d)) {
            if (c & (1u << 8)) cpu_features |= 1;
            if (b & (1u << 8)) cpu_features |= 4;
        }
        if (max_leaf >= 1 && __get_cpuid(1, &a, &b, &c, &d))
            if (c & (1u << 1)) cpu_features |= 2;
        if (__get_cpuid(0x80000000u, &a, &b, &c, &d) && a >= 0x80000001u)
            if (__get_cpuid(0x80000001u, &a, &b, &c, &d))
                if (c & (1u << 5)) cpu_features |= 8;
    }
#endif
}

/* ws_mask — copy src[0..length) XOR mask to out[offset..offset+length).
 * mask_ptr points to a 4-byte mask that repeats every 4 bytes.
 */
void ws_mask(const uint8_t *src, const uint8_t *mask_ptr,
             uint8_t *out, size_t offset, size_t length) {
    uint32_t mask32;
    memcpy(&mask32, mask_ptr, 4);
    uint8_t *dest = out + offset;
    size_t i = 0;
    for (; i + 4 <= length; i += 4) {
        uint32_t v;
        memcpy(&v, src + i, 4);
        v ^= mask32;
        memcpy(dest + i, &v, 4);
    }
    if (i < length) { dest[i] = src[i] ^ mask_ptr[0]; i++; }
    if (i < length) { dest[i] = src[i] ^ mask_ptr[1]; i++; }
    if (i < length) { dest[i] = src[i] ^ mask_ptr[2]; }
}

/* ws_unmask — XOR buf[0..length) with repeating 4-byte mask, in place. */
void ws_unmask(uint8_t *buf, const uint8_t *mask_ptr, size_t length) {
    uint32_t mask32;
    memcpy(&mask32, mask_ptr, 4);
    size_t i = 0;
    for (; i + 4 <= length; i += 4) {
        uint32_t v;
        memcpy(&v, buf + i, 4);
        v ^= mask32;
        memcpy(buf + i, &v, 4);
    }
    if (i < length) { buf[i] ^= mask_ptr[0]; i++; }
    if (i < length) { buf[i] ^= mask_ptr[1]; i++; }
    if (i < length) { buf[i] ^= mask_ptr[2]; }
}

/* ws_find_header — find needle in buf; returns byte offset just after needle,
 * or -1 if not found.
 */
int64_t ws_find_header(const uint8_t *buf, size_t len,
                       const uint8_t *needle, size_t needle_len) {
    if (needle_len == 0 || needle_len > len) return -1;
    size_t limit = len - needle_len;
    for (size_t i = 0; i <= limit; i++) {
        if (memcmp(buf + i, needle, needle_len) == 0)
            return (int64_t)(i + needle_len);
    }
    return -1;
}

/* ws_base64_encode — RFC 4648 §4 base64 (standard alphabet, '=' padding).
 * Returns bytes written, always ceil(len/3)*4.
 */
static const char b64_alpha[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

size_t ws_base64_encode(const uint8_t *in, size_t len, uint8_t *out) {
    size_t i = 0, o = 0;
    for (; i + 2 < len; i += 3, o += 4) {
        uint32_t v = ((uint32_t)in[i]   << 16) |
                     ((uint32_t)in[i+1] <<  8) | in[i+2];
        out[o]   = (uint8_t)b64_alpha[(v >> 18) & 0x3F];
        out[o+1] = (uint8_t)b64_alpha[(v >> 12) & 0x3F];
        out[o+2] = (uint8_t)b64_alpha[(v >>  6) & 0x3F];
        out[o+3] = (uint8_t)b64_alpha[ v        & 0x3F];
    }
    if (i < len) {
        uint32_t v = (uint32_t)in[i] << 16;
        if (i + 1 < len) v |= (uint32_t)in[i+1] << 8;
        out[o]   = (uint8_t)b64_alpha[(v >> 18) & 0x3F];
        out[o+1] = (uint8_t)b64_alpha[(v >> 12) & 0x3F];
        out[o+2] = (i + 1 < len) ? (uint8_t)b64_alpha[(v >> 6) & 0x3F] : '=';
        out[o+3] = '=';
        o += 4;
    }
    return o;
}
