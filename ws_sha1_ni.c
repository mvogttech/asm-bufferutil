/* ws_sha1_ni.c — SHA-1 with Intel SHA-NI
 * Re-derived from Intel whitepaper, counting exactly 20 sha1rnds4 calls.
 * Pattern: E0/E1 ping-pong, msg schedule runs from rounds 4-55.
 */
#include <stdint.h>
#include <string.h>
#include <immintrin.h>
#include <cpuid.h>

int ws_has_sha_ni(void) {
    unsigned int a,b,c,d;
    if (__get_cpuid_count(7,0,&a,&b,&c,&d)) return (b>>29)&1;
    return 0;
}

static void sha1_ni_block(uint32_t state[5], const uint8_t data[64]) {
    __m128i ABCD, ABCD_SAVE, E0, E0_SAVE, E1;
    __m128i MSG0, MSG1, MSG2, MSG3;
    const __m128i MASK = _mm_set_epi64x(0x0001020304050607ULL, 0x08090a0b0c0d0e0fULL);

    ABCD = _mm_shuffle_epi32(_mm_loadu_si128((const __m128i*)state), 0x1B);
    E0   = _mm_set_epi32(state[4], 0, 0, 0);
    ABCD_SAVE = ABCD; E0_SAVE = E0;

    MSG0 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)(data+0)),  MASK);
    MSG1 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)(data+16)), MASK);
    MSG2 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)(data+32)), MASK);
    MSG3 = _mm_shuffle_epi8(_mm_loadu_si128((const __m128i*)(data+48)), MASK);

    /* --- 20 rounds of sha1rnds4 = 80 SHA-1 rounds --- */

    /* R0-3: load MSG0 */
    E0 = _mm_add_epi32(E0, MSG0);
    E1 = ABCD;
    ABCD = _mm_sha1rnds4_epu32(ABCD, E0, 0);                          /* 1 */

    /* R4-7: load MSG1, start msg sched for MSG0 */
    E1 = _mm_sha1nexte_epu32(E1, MSG1); E0 = ABCD;
    ABCD = _mm_sha1rnds4_epu32(ABCD, E1, 0);                          /* 2 */
    MSG0 = _mm_sha1msg1_epu32(MSG0, MSG1);

    /* R8-11: load MSG2 */
    E0 = _mm_sha1nexte_epu32(E0, MSG2); E1 = ABCD;
    ABCD = _mm_sha1rnds4_epu32(ABCD, E0, 0);                          /* 3 */
    MSG1 = _mm_sha1msg1_epu32(MSG1, MSG2);
    MSG0 = _mm_xor_si128(MSG0, MSG2);

    /* R12-15: load MSG3, finish MSG0 schedule */
    E1 = _mm_sha1nexte_epu32(E1, MSG3); E0 = ABCD;
    MSG0 = _mm_sha1msg2_epu32(MSG0, MSG3);
    ABCD = _mm_sha1rnds4_epu32(ABCD, E1, 0);                          /* 4 */
    MSG2 = _mm_sha1msg1_epu32(MSG2, MSG3);
    MSG1 = _mm_xor_si128(MSG1, MSG3);

    /* From here: steady-state pattern. Each round group:
     * nexte, msg2, rnds4, msg1, xor. MSG vars rotate: 0→1→2→3→0.
     * imm changes: 0(r0-19), 1(r20-39), 2(r40-59), 3(r60-79) */

    /* R16-19 */ E0=_mm_sha1nexte_epu32(E0,MSG0); E1=ABCD; MSG1=_mm_sha1msg2_epu32(MSG1,MSG0); ABCD=_mm_sha1rnds4_epu32(ABCD,E0,0); MSG3=_mm_sha1msg1_epu32(MSG3,MSG0); MSG2=_mm_xor_si128(MSG2,MSG0); /* 5 */
    /* R20-23 */ E1=_mm_sha1nexte_epu32(E1,MSG1); E0=ABCD; MSG2=_mm_sha1msg2_epu32(MSG2,MSG1); ABCD=_mm_sha1rnds4_epu32(ABCD,E1,1); MSG0=_mm_sha1msg1_epu32(MSG0,MSG1); MSG3=_mm_xor_si128(MSG3,MSG1); /* 6 */
    /* R24-27 */ E0=_mm_sha1nexte_epu32(E0,MSG2); E1=ABCD; MSG3=_mm_sha1msg2_epu32(MSG3,MSG2); ABCD=_mm_sha1rnds4_epu32(ABCD,E0,1); MSG1=_mm_sha1msg1_epu32(MSG1,MSG2); MSG0=_mm_xor_si128(MSG0,MSG2); /* 7 */
    /* R28-31 */ E1=_mm_sha1nexte_epu32(E1,MSG3); E0=ABCD; MSG0=_mm_sha1msg2_epu32(MSG0,MSG3); ABCD=_mm_sha1rnds4_epu32(ABCD,E1,1); MSG2=_mm_sha1msg1_epu32(MSG2,MSG3); MSG1=_mm_xor_si128(MSG1,MSG3); /* 8 */
    /* R32-35 */ E0=_mm_sha1nexte_epu32(E0,MSG0); E1=ABCD; MSG1=_mm_sha1msg2_epu32(MSG1,MSG0); ABCD=_mm_sha1rnds4_epu32(ABCD,E0,1); MSG3=_mm_sha1msg1_epu32(MSG3,MSG0); MSG2=_mm_xor_si128(MSG2,MSG0); /* 9 */
    /* R36-39 */ E1=_mm_sha1nexte_epu32(E1,MSG1); E0=ABCD; MSG2=_mm_sha1msg2_epu32(MSG2,MSG1); ABCD=_mm_sha1rnds4_epu32(ABCD,E1,1); MSG0=_mm_sha1msg1_epu32(MSG0,MSG1); MSG3=_mm_xor_si128(MSG3,MSG1); /* 10 */
    /* R40-43 */ E0=_mm_sha1nexte_epu32(E0,MSG2); E1=ABCD; MSG3=_mm_sha1msg2_epu32(MSG3,MSG2); ABCD=_mm_sha1rnds4_epu32(ABCD,E0,2); MSG1=_mm_sha1msg1_epu32(MSG1,MSG2); MSG0=_mm_xor_si128(MSG0,MSG2); /* 11 */
    /* R44-47 */ E1=_mm_sha1nexte_epu32(E1,MSG3); E0=ABCD; MSG0=_mm_sha1msg2_epu32(MSG0,MSG3); ABCD=_mm_sha1rnds4_epu32(ABCD,E1,2); MSG2=_mm_sha1msg1_epu32(MSG2,MSG3); MSG1=_mm_xor_si128(MSG1,MSG3); /* 12 */
    /* R48-51 */ E0=_mm_sha1nexte_epu32(E0,MSG0); E1=ABCD; MSG1=_mm_sha1msg2_epu32(MSG1,MSG0); ABCD=_mm_sha1rnds4_epu32(ABCD,E0,2); MSG3=_mm_sha1msg1_epu32(MSG3,MSG0); MSG2=_mm_xor_si128(MSG2,MSG0); /* 13 */
    /* R52-55 */ E1=_mm_sha1nexte_epu32(E1,MSG1); E0=ABCD; MSG2=_mm_sha1msg2_epu32(MSG2,MSG1); ABCD=_mm_sha1rnds4_epu32(ABCD,E1,2); MSG0=_mm_sha1msg1_epu32(MSG0,MSG1); MSG3=_mm_xor_si128(MSG3,MSG1); /* 14 */
    /* R56-59 */ E0=_mm_sha1nexte_epu32(E0,MSG2); E1=ABCD; MSG3=_mm_sha1msg2_epu32(MSG3,MSG2); ABCD=_mm_sha1rnds4_epu32(ABCD,E0,2); MSG1=_mm_sha1msg1_epu32(MSG1,MSG2); MSG0=_mm_xor_si128(MSG0,MSG2); /* 15 */
    /* R60-63: last msg2, no more msg1/xor needed */
    E1=_mm_sha1nexte_epu32(E1,MSG3); E0=ABCD; MSG0=_mm_sha1msg2_epu32(MSG0,MSG3); ABCD=_mm_sha1rnds4_epu32(ABCD,E1,3); MSG2=_mm_sha1msg1_epu32(MSG2,MSG3); MSG1=_mm_xor_si128(MSG1,MSG3); /* 16 */
    /* R64-67 */ E0=_mm_sha1nexte_epu32(E0,MSG0); E1=ABCD; MSG1=_mm_sha1msg2_epu32(MSG1,MSG0); ABCD=_mm_sha1rnds4_epu32(ABCD,E0,3); MSG3=_mm_sha1msg1_epu32(MSG3,MSG0); MSG2=_mm_xor_si128(MSG2,MSG0); /* 17 */
    /* R68-71 */ E1=_mm_sha1nexte_epu32(E1,MSG1); E0=ABCD; MSG2=_mm_sha1msg2_epu32(MSG2,MSG1); ABCD=_mm_sha1rnds4_epu32(ABCD,E1,3); /* 18 — no more msg1/xor */
    /* R72-75 */ E0=_mm_sha1nexte_epu32(E0,MSG2); E1=ABCD; MSG3=_mm_sha1msg2_epu32(MSG3,MSG2); ABCD=_mm_sha1rnds4_epu32(ABCD,E0,3); /* 19 */
    /* R76-79 */ E1=_mm_sha1nexte_epu32(E1,MSG3); E0=ABCD; ABCD=_mm_sha1rnds4_epu32(ABCD,E1,3); /* 20 */
    E0=_mm_sha1nexte_epu32(E0,_mm_setzero_si128());

    ABCD = _mm_add_epi32(ABCD, ABCD_SAVE);
    E0   = _mm_add_epi32(E0, E0_SAVE);
    _mm_storeu_si128((__m128i*)state, _mm_shuffle_epi32(ABCD, 0x1B));
    state[4] = (uint32_t)_mm_extract_epi32(E0, 3);
}

void ws_sha1_ni(const uint8_t *msg, size_t len, uint8_t out[20]) {
    uint8_t padded[128];
    memset(padded, 0, 128);
    if (len) memcpy(padded, msg, len);
    padded[len] = 0x80;
    int nblocks;
    if (len <= 55) {
        nblocks = 1;
        uint64_t bits = (uint64_t)len << 3;
        for (int i = 0; i < 8; i++) padded[63-i] = (uint8_t)(bits >> (i*8));
    } else {
        nblocks = 2;
        uint64_t bits = (uint64_t)len << 3;
        for (int i = 0; i < 8; i++) padded[127-i] = (uint8_t)(bits >> (i*8));
    }
    uint32_t state[5] = {0x67452301,0xEFCDAB89,0x98BADCFE,0x10325476,0xC3D2E1F0};
    for (int b = 0; b < nblocks; b++) sha1_ni_block(state, padded + b*64);
    for (int i = 0; i < 5; i++) {
        out[i*4+0]=(uint8_t)(state[i]>>24); out[i*4+1]=(uint8_t)(state[i]>>16);
        out[i*4+2]=(uint8_t)(state[i]>>8);  out[i*4+3]=(uint8_t)(state[i]);
    }
}
