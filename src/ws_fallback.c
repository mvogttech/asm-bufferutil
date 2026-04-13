/* ws_fallback.c — portable C/SIMD fallbacks for non-Linux-x64 platforms.
 *
 * Provides the symbols assembled by ws_cpu.asm, ws_mask_asm.asm, and
 * ws_base64_asm.asm on Linux x64.  Used on Windows (MSVC) and macOS (Clang).
 *
 * SIMD dispatch (selected once at init, no per-call branches on the hot path):
 *   AVX2  — 8×32-byte XOR per iteration (256 bytes/iter), runtime-detected
 *   SSE2  — 8×16-byte XOR per iteration (128 bytes/iter), always-on for x64
 *   scalar — 4-byte uint32_t XOR, handles tails / non-x64 platforms
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

/* ── SIMD headers ─────────────────────────────────────────────────────────── */
#if defined(_MSC_VER)
#  include <intrin.h>
#  include <immintrin.h>
#  define HAVE_SSE2 1   /* SSE2 is always available on x86-64 MSVC */
#  ifdef __AVX2__
#    define HAVE_AVX2 1
#  endif
#elif defined(__x86_64__)
#  include <cpuid.h>
#  include <immintrin.h>
#  define HAVE_SSE2 1   /* SSE2 is always available on x86-64 */
#  ifdef __AVX2__
#    define HAVE_AVX2 1
#  endif
#elif defined(__i386__)
#  include <cpuid.h>
#  include <immintrin.h>
#  if defined(__SSE2__)
#    define HAVE_SSE2 1
#  endif
#  ifdef __AVX2__
#    define HAVE_AVX2 1
#  endif
#endif

#ifndef HAVE_SSE2
#  define HAVE_SSE2 0
#endif
#ifndef HAVE_AVX2
#  define HAVE_AVX2 0
#endif

/* ── CPU feature state ────────────────────────────────────────────────────── */

/* cpu_features bitmask (matches ws_cpu.asm layout):
 *   bit 0 = GFNI, bit 1 = PCLMULQDQ, bit 2 = BMI2, bit 3 = LZCNT
 */
uint32_t cpu_features = 0;

/* Set by _init_cpu_features; read by ws_mask / ws_unmask dispatch. */
static int avx2_available = 0;

void _init_cpu_features(void) {
#if defined(_MSC_VER)
    int info[4];
    __cpuid(info, 0);
    int max_leaf = info[0];

    if (max_leaf >= 7) {
        __cpuidex(info, 7, 0);
        if (info[2] & (1 << 8)) cpu_features |= 1;  /* GFNI   */
        if (info[1] & (1 << 8)) cpu_features |= 4;  /* BMI2   */
    }
    if (max_leaf >= 1) {
        __cpuid(info, 1);
        if (info[2] & (1 << 1)) cpu_features |= 2;  /* PCLMUL */

        /* AVX2: OSXSAVE + OS YMM-state save + AVX2 CPUID bit */
        if ((info[2] & (1 << 27)) &&
            ((_xgetbv(0) & 0x6) == 0x6) &&
            max_leaf >= 7) {
            __cpuidex(info, 7, 0);
            if (info[1] & (1 << 5)) avx2_available = 1;
        }
    }
    __cpuid(info, (int)0x80000000u);
    if ((unsigned int)info[0] >= 0x80000001u) {
        __cpuid(info, (int)0x80000001u);
        if (info[2] & (1 << 5)) cpu_features |= 8;  /* LZCNT  */
    }

#elif defined(__x86_64__) || defined(__i386__)
    unsigned int a, b, c, d;
    if (!__get_cpuid(0, &a, &b, &c, &d)) return;
    unsigned int max_leaf = a;

    if (max_leaf >= 7 && __get_cpuid_count(7, 0, &a, &b, &c, &d)) {
        if (c & (1u << 8)) cpu_features |= 1;
        if (b & (1u << 8)) cpu_features |= 4;
    }
    if (max_leaf >= 1 && __get_cpuid(1, &a, &b, &c, &d)) {
        if (c & (1u << 1)) cpu_features |= 2;

        if (c & (1u << 27)) {  /* OSXSAVE */
            unsigned int xcr0;
            __asm__ volatile ("xgetbv" : "=a"(xcr0) : "c"(0) : "edx");
            if ((xcr0 & 0x6) == 0x6 &&
                max_leaf >= 7 &&
                __get_cpuid_count(7, 0, &a, &b, &c, &d) &&
                (b & (1u << 5)))
                avx2_available = 1;
        }
    }
    if (__get_cpuid(0x80000000u, &a, &b, &c, &d) && a >= 0x80000001u)
        if (__get_cpuid(0x80000001u, &a, &b, &c, &d))
            if (c & (1u << 5)) cpu_features |= 8;  /* LZCNT */
#endif
}

/* ── ws_mask ──────────────────────────────────────────────────────────────── */

void ws_mask(const uint8_t *src, const uint8_t *mask_ptr,
             uint8_t *out, size_t offset, size_t length) {
    uint32_t mask32;
    memcpy(&mask32, mask_ptr, 4);
    uint8_t *dest = out + offset;
    size_t i = 0;

/* ---- AVX2 path: 8×32 = 256 bytes/iter ------------------------------------ */
#if HAVE_AVX2
    if (avx2_available) {
        __m256i vmask = _mm256_set1_epi32((int)mask32);

        /* Main loop — 256 bytes per iteration, prefetch 512 bytes ahead */
        for (; i + 256 <= length; i += 256) {
            _mm_prefetch((const char *)(src + i + 512), _MM_HINT_T0);
            __m256i v0 = _mm256_loadu_si256((const __m256i *)(src + i));
            __m256i v1 = _mm256_loadu_si256((const __m256i *)(src + i +  32));
            __m256i v2 = _mm256_loadu_si256((const __m256i *)(src + i +  64));
            __m256i v3 = _mm256_loadu_si256((const __m256i *)(src + i +  96));
            __m256i v4 = _mm256_loadu_si256((const __m256i *)(src + i + 128));
            __m256i v5 = _mm256_loadu_si256((const __m256i *)(src + i + 160));
            __m256i v6 = _mm256_loadu_si256((const __m256i *)(src + i + 192));
            __m256i v7 = _mm256_loadu_si256((const __m256i *)(src + i + 224));
            v0 = _mm256_xor_si256(v0, vmask);
            v1 = _mm256_xor_si256(v1, vmask);
            v2 = _mm256_xor_si256(v2, vmask);
            v3 = _mm256_xor_si256(v3, vmask);
            v4 = _mm256_xor_si256(v4, vmask);
            v5 = _mm256_xor_si256(v5, vmask);
            v6 = _mm256_xor_si256(v6, vmask);
            v7 = _mm256_xor_si256(v7, vmask);
            _mm256_storeu_si256((__m256i *)(dest + i),       v0);
            _mm256_storeu_si256((__m256i *)(dest + i +  32), v1);
            _mm256_storeu_si256((__m256i *)(dest + i +  64), v2);
            _mm256_storeu_si256((__m256i *)(dest + i +  96), v3);
            _mm256_storeu_si256((__m256i *)(dest + i + 128), v4);
            _mm256_storeu_si256((__m256i *)(dest + i + 160), v5);
            _mm256_storeu_si256((__m256i *)(dest + i + 192), v6);
            _mm256_storeu_si256((__m256i *)(dest + i + 224), v7);
        }
        /* 4×32 cleanup — 128 bytes */
        for (; i + 128 <= length; i += 128) {
            __m256i v0 = _mm256_loadu_si256((const __m256i *)(src + i));
            __m256i v1 = _mm256_loadu_si256((const __m256i *)(src + i + 32));
            __m256i v2 = _mm256_loadu_si256((const __m256i *)(src + i + 64));
            __m256i v3 = _mm256_loadu_si256((const __m256i *)(src + i + 96));
            v0 = _mm256_xor_si256(v0, vmask);
            v1 = _mm256_xor_si256(v1, vmask);
            v2 = _mm256_xor_si256(v2, vmask);
            v3 = _mm256_xor_si256(v3, vmask);
            _mm256_storeu_si256((__m256i *)(dest + i),      v0);
            _mm256_storeu_si256((__m256i *)(dest + i + 32), v1);
            _mm256_storeu_si256((__m256i *)(dest + i + 64), v2);
            _mm256_storeu_si256((__m256i *)(dest + i + 96), v3);
        }
        /* 1×32 cleanup — 32 bytes */
        for (; i + 32 <= length; i += 32) {
            __m256i v0 = _mm256_loadu_si256((const __m256i *)(src + i));
            v0 = _mm256_xor_si256(v0, vmask);
            _mm256_storeu_si256((__m256i *)(dest + i), v0);
        }
        /* Scalar tail — 0-31 bytes. i % 4 == 0 here (32 is a multiple of 4). */
        for (; i + 4 <= length; i += 4) {
            uint32_t v; memcpy(&v, src + i, 4); v ^= mask32; memcpy(dest + i, &v, 4);
        }
        if (i < length) { dest[i] = src[i] ^ mask_ptr[0]; i++; }
        if (i < length) { dest[i] = src[i] ^ mask_ptr[1]; i++; }
        if (i < length) { dest[i] = src[i] ^ mask_ptr[2]; }
        return;
    }
#endif

/* ---- SSE2 path: 8×16 = 128 bytes/iter ------------------------------------ */
#if HAVE_SSE2
    {
        __m128i vmask = _mm_set1_epi32((int)mask32);

        /* Main loop — 128 bytes per iteration, prefetch 256 bytes ahead */
        for (; i + 128 <= length; i += 128) {
            _mm_prefetch((const char *)(src + i + 256), _MM_HINT_T0);
            __m128i v0 = _mm_loadu_si128((const __m128i *)(src + i));
            __m128i v1 = _mm_loadu_si128((const __m128i *)(src + i +  16));
            __m128i v2 = _mm_loadu_si128((const __m128i *)(src + i +  32));
            __m128i v3 = _mm_loadu_si128((const __m128i *)(src + i +  48));
            __m128i v4 = _mm_loadu_si128((const __m128i *)(src + i +  64));
            __m128i v5 = _mm_loadu_si128((const __m128i *)(src + i +  80));
            __m128i v6 = _mm_loadu_si128((const __m128i *)(src + i +  96));
            __m128i v7 = _mm_loadu_si128((const __m128i *)(src + i + 112));
            v0 = _mm_xor_si128(v0, vmask);
            v1 = _mm_xor_si128(v1, vmask);
            v2 = _mm_xor_si128(v2, vmask);
            v3 = _mm_xor_si128(v3, vmask);
            v4 = _mm_xor_si128(v4, vmask);
            v5 = _mm_xor_si128(v5, vmask);
            v6 = _mm_xor_si128(v6, vmask);
            v7 = _mm_xor_si128(v7, vmask);
            _mm_storeu_si128((__m128i *)(dest + i),       v0);
            _mm_storeu_si128((__m128i *)(dest + i +  16), v1);
            _mm_storeu_si128((__m128i *)(dest + i +  32), v2);
            _mm_storeu_si128((__m128i *)(dest + i +  48), v3);
            _mm_storeu_si128((__m128i *)(dest + i +  64), v4);
            _mm_storeu_si128((__m128i *)(dest + i +  80), v5);
            _mm_storeu_si128((__m128i *)(dest + i +  96), v6);
            _mm_storeu_si128((__m128i *)(dest + i + 112), v7);
        }
        /* 4×16 cleanup — 64 bytes */
        for (; i + 64 <= length; i += 64) {
            __m128i v0 = _mm_loadu_si128((const __m128i *)(src + i));
            __m128i v1 = _mm_loadu_si128((const __m128i *)(src + i + 16));
            __m128i v2 = _mm_loadu_si128((const __m128i *)(src + i + 32));
            __m128i v3 = _mm_loadu_si128((const __m128i *)(src + i + 48));
            v0 = _mm_xor_si128(v0, vmask);
            v1 = _mm_xor_si128(v1, vmask);
            v2 = _mm_xor_si128(v2, vmask);
            v3 = _mm_xor_si128(v3, vmask);
            _mm_storeu_si128((__m128i *)(dest + i),      v0);
            _mm_storeu_si128((__m128i *)(dest + i + 16), v1);
            _mm_storeu_si128((__m128i *)(dest + i + 32), v2);
            _mm_storeu_si128((__m128i *)(dest + i + 48), v3);
        }
        /* 1×16 cleanup — 16 bytes */
        for (; i + 16 <= length; i += 16) {
            __m128i v0 = _mm_loadu_si128((const __m128i *)(src + i));
            v0 = _mm_xor_si128(v0, vmask);
            _mm_storeu_si128((__m128i *)(dest + i), v0);
        }
    }
#endif

    /* Scalar tail — handles < 16 bytes (SSE2) or all bytes (non-x64) */
    for (; i + 4 <= length; i += 4) {
        uint32_t v; memcpy(&v, src + i, 4); v ^= mask32; memcpy(dest + i, &v, 4);
    }
    if (i < length) { dest[i] = src[i] ^ mask_ptr[0]; i++; }
    if (i < length) { dest[i] = src[i] ^ mask_ptr[1]; i++; }
    if (i < length) { dest[i] = src[i] ^ mask_ptr[2]; }
}

/* ── ws_unmask ────────────────────────────────────────────────────────────── */

void ws_unmask(uint8_t *buf, const uint8_t *mask_ptr, size_t length) {
    uint32_t mask32;
    memcpy(&mask32, mask_ptr, 4);
    size_t i = 0;

/* ---- AVX2 path ------------------------------------------------------------ */
#if HAVE_AVX2
    if (avx2_available) {
        __m256i vmask = _mm256_set1_epi32((int)mask32);

        for (; i + 256 <= length; i += 256) {
            _mm_prefetch((const char *)(buf + i + 512), _MM_HINT_T0);
            __m256i v0 = _mm256_loadu_si256((const __m256i *)(buf + i));
            __m256i v1 = _mm256_loadu_si256((const __m256i *)(buf + i +  32));
            __m256i v2 = _mm256_loadu_si256((const __m256i *)(buf + i +  64));
            __m256i v3 = _mm256_loadu_si256((const __m256i *)(buf + i +  96));
            __m256i v4 = _mm256_loadu_si256((const __m256i *)(buf + i + 128));
            __m256i v5 = _mm256_loadu_si256((const __m256i *)(buf + i + 160));
            __m256i v6 = _mm256_loadu_si256((const __m256i *)(buf + i + 192));
            __m256i v7 = _mm256_loadu_si256((const __m256i *)(buf + i + 224));
            v0 = _mm256_xor_si256(v0, vmask);
            v1 = _mm256_xor_si256(v1, vmask);
            v2 = _mm256_xor_si256(v2, vmask);
            v3 = _mm256_xor_si256(v3, vmask);
            v4 = _mm256_xor_si256(v4, vmask);
            v5 = _mm256_xor_si256(v5, vmask);
            v6 = _mm256_xor_si256(v6, vmask);
            v7 = _mm256_xor_si256(v7, vmask);
            _mm256_storeu_si256((__m256i *)(buf + i),       v0);
            _mm256_storeu_si256((__m256i *)(buf + i +  32), v1);
            _mm256_storeu_si256((__m256i *)(buf + i +  64), v2);
            _mm256_storeu_si256((__m256i *)(buf + i +  96), v3);
            _mm256_storeu_si256((__m256i *)(buf + i + 128), v4);
            _mm256_storeu_si256((__m256i *)(buf + i + 160), v5);
            _mm256_storeu_si256((__m256i *)(buf + i + 192), v6);
            _mm256_storeu_si256((__m256i *)(buf + i + 224), v7);
        }
        for (; i + 128 <= length; i += 128) {
            __m256i v0 = _mm256_loadu_si256((const __m256i *)(buf + i));
            __m256i v1 = _mm256_loadu_si256((const __m256i *)(buf + i + 32));
            __m256i v2 = _mm256_loadu_si256((const __m256i *)(buf + i + 64));
            __m256i v3 = _mm256_loadu_si256((const __m256i *)(buf + i + 96));
            v0 = _mm256_xor_si256(v0, vmask);
            v1 = _mm256_xor_si256(v1, vmask);
            v2 = _mm256_xor_si256(v2, vmask);
            v3 = _mm256_xor_si256(v3, vmask);
            _mm256_storeu_si256((__m256i *)(buf + i),      v0);
            _mm256_storeu_si256((__m256i *)(buf + i + 32), v1);
            _mm256_storeu_si256((__m256i *)(buf + i + 64), v2);
            _mm256_storeu_si256((__m256i *)(buf + i + 96), v3);
        }
        for (; i + 32 <= length; i += 32) {
            __m256i v0 = _mm256_loadu_si256((const __m256i *)(buf + i));
            v0 = _mm256_xor_si256(v0, vmask);
            _mm256_storeu_si256((__m256i *)(buf + i), v0);
        }
        for (; i + 4 <= length; i += 4) {
            uint32_t v; memcpy(&v, buf + i, 4); v ^= mask32; memcpy(buf + i, &v, 4);
        }
        if (i < length) { buf[i] ^= mask_ptr[0]; i++; }
        if (i < length) { buf[i] ^= mask_ptr[1]; i++; }
        if (i < length) { buf[i] ^= mask_ptr[2]; }
        return;
    }
#endif

/* ---- SSE2 path ------------------------------------------------------------ */
#if HAVE_SSE2
    {
        __m128i vmask = _mm_set1_epi32((int)mask32);

        for (; i + 128 <= length; i += 128) {
            _mm_prefetch((const char *)(buf + i + 256), _MM_HINT_T0);
            __m128i v0 = _mm_loadu_si128((const __m128i *)(buf + i));
            __m128i v1 = _mm_loadu_si128((const __m128i *)(buf + i +  16));
            __m128i v2 = _mm_loadu_si128((const __m128i *)(buf + i +  32));
            __m128i v3 = _mm_loadu_si128((const __m128i *)(buf + i +  48));
            __m128i v4 = _mm_loadu_si128((const __m128i *)(buf + i +  64));
            __m128i v5 = _mm_loadu_si128((const __m128i *)(buf + i +  80));
            __m128i v6 = _mm_loadu_si128((const __m128i *)(buf + i +  96));
            __m128i v7 = _mm_loadu_si128((const __m128i *)(buf + i + 112));
            v0 = _mm_xor_si128(v0, vmask);
            v1 = _mm_xor_si128(v1, vmask);
            v2 = _mm_xor_si128(v2, vmask);
            v3 = _mm_xor_si128(v3, vmask);
            v4 = _mm_xor_si128(v4, vmask);
            v5 = _mm_xor_si128(v5, vmask);
            v6 = _mm_xor_si128(v6, vmask);
            v7 = _mm_xor_si128(v7, vmask);
            _mm_storeu_si128((__m128i *)(buf + i),       v0);
            _mm_storeu_si128((__m128i *)(buf + i +  16), v1);
            _mm_storeu_si128((__m128i *)(buf + i +  32), v2);
            _mm_storeu_si128((__m128i *)(buf + i +  48), v3);
            _mm_storeu_si128((__m128i *)(buf + i +  64), v4);
            _mm_storeu_si128((__m128i *)(buf + i +  80), v5);
            _mm_storeu_si128((__m128i *)(buf + i +  96), v6);
            _mm_storeu_si128((__m128i *)(buf + i + 112), v7);
        }
        for (; i + 64 <= length; i += 64) {
            __m128i v0 = _mm_loadu_si128((const __m128i *)(buf + i));
            __m128i v1 = _mm_loadu_si128((const __m128i *)(buf + i + 16));
            __m128i v2 = _mm_loadu_si128((const __m128i *)(buf + i + 32));
            __m128i v3 = _mm_loadu_si128((const __m128i *)(buf + i + 48));
            v0 = _mm_xor_si128(v0, vmask);
            v1 = _mm_xor_si128(v1, vmask);
            v2 = _mm_xor_si128(v2, vmask);
            v3 = _mm_xor_si128(v3, vmask);
            _mm_storeu_si128((__m128i *)(buf + i),      v0);
            _mm_storeu_si128((__m128i *)(buf + i + 16), v1);
            _mm_storeu_si128((__m128i *)(buf + i + 32), v2);
            _mm_storeu_si128((__m128i *)(buf + i + 48), v3);
        }
        for (; i + 16 <= length; i += 16) {
            __m128i v0 = _mm_loadu_si128((const __m128i *)(buf + i));
            v0 = _mm_xor_si128(v0, vmask);
            _mm_storeu_si128((__m128i *)(buf + i), v0);
        }
    }
#endif

    for (; i + 4 <= length; i += 4) {
        uint32_t v; memcpy(&v, buf + i, 4); v ^= mask32; memcpy(buf + i, &v, 4);
    }
    if (i < length) { buf[i] ^= mask_ptr[0]; i++; }
    if (i < length) { buf[i] ^= mask_ptr[1]; i++; }
    if (i < length) { buf[i] ^= mask_ptr[2]; }
}

/* ── ws_find_header ───────────────────────────────────────────────────────── */

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

/* ── ws_base64_encode ─────────────────────────────────────────────────────── */

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
